// A desk's guard prompt answered from outside the desk (bercail desk answer), and a desk's
// push of its own branch, which asks nothing. No Pi process, no hc: the extension's handlers
// with stand-ins, and the prompt files under this file's own XDG_STATE_HOME (tests/setup.ts).
import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { expect, test, vi } from "vite-plus/test";
import guard, {
  type DeskPrompt,
  type GuardInput,
  confirmOrAnswer,
  decideBash,
  defaultPolicy,
  deskPrompts,
  changedFacts,
  guardOperation,
  pinOperation,
  runOf,
} from "../bstack/pi/extensions/guard.ts";

const none = { "/work": defaultPolicy, "/other": defaultPolicy };
const own = { path: "/work", branch: "feature", mapped: false };
const desk: GuardInput = {
  role: "",
  hasUI: true,
  cwd: "/work",
  policies: none,
  branches: { "/work": "feature" },
  graphiteAliases: [],
  deskBranch: own,
  alone: true,
};

const decided = (command: string, input: GuardInput = desk) => decideBash(command, input);

test("a desk pushes the branch its handoff record names to origin without asking", () => {
  for (const command of [
    "git push origin feature",
    "git push -u origin feature",
    "git push --set-upstream origin HEAD",
    "git push origin refs/heads/feature",
    "git push origin HEAD:refs/heads/feature",
    "git push origin refs/heads/feature:refs/heads/feature",
  ])
    expect(decided(command), command).toStrictEqual({
      action: "allow",
      approved: ["a desk pushes its own branch (feature), which its handoff record names"],
    });
});

test("a desk's push of anything but its own branch, to origin, from its worktree, asks as before", () => {
  for (const command of [
    "git push origin main",
    "git push origin feature main",
    "git push origin HEAD:main",
    "git push origin other",
    "git push upstream feature",
    "git push https://example.com/r.git feature",
    "git push origin",
    "git push",
    "git push --repo=https://example.com/r.git origin feature",
    "git push --prune origin feature",
    "git push --tags origin feature",
    "git push --follow-tags origin feature",
    "git push --all origin",
    "git push origin :feature",
    "git push --delete origin feature",
    "git push origin feature:",
    "git push origin 'refs/heads/*:refs/heads/*'",
    "git -C /other push origin feature",
    "git -c remote.origin.url=https://example.com/r.git push origin feature",
    "git --git-dir=/work/.git push origin feature",
    // git follows links in a -C folder that the guard reads by name only.
    "git -C /work push origin feature",
    // A short :dst may resolve to a tag of that name on the remote.
    "git push origin HEAD:feature",
    "git push origin feature:feature",
    // Another source to the desk's branch is not its own branch.
    "git push origin main:feature",
    "git push origin other:refs/heads/feature",
    "git push origin refs/tags/v1:refs/heads/feature",
    "git push origin feature:feature main:feature",
  ])
    expect(decided(command).action, command).toBe("ask");
  // Not the whole command, or not the only tool call of its message: what runs beside it
  // may change what deskBranchAt read.
  expect(decided("git status && git push origin feature").action).toBe("ask");
  expect(decided("git push origin feature", { ...desk, alone: false }).action).toBe("ask");
  // On another branch, HEAD is not the desk's.
  expect(decided("git push origin HEAD", { ...desk, branches: { "/work": "other" } }).action).toBe("ask");
  // Force stays refused.
  expect(decided("git push --force origin feature").action).toBe("block");
  expect(decided("git push origin +feature").action).toBe("block");
});

test("where git config maps a refspec with no :dst, a desk's own push names its destination", () => {
  const mapped = { ...desk, deskBranch: { ...own, mapped: true } };
  expect(decided("git push origin feature", mapped).action).toBe("ask");
  expect(decided("git push origin HEAD", mapped).action).toBe("ask");
  expect(decided("git push origin HEAD:refs/heads/feature", mapped).action).toBe("allow");
});

test("only a desk's lead pushes its own branch unasked: a builder or a desk with no record asks", () => {
  expect(decided("git push origin feature", { ...desk, role: "bstack-builder" }).action).toBe("ask");
  expect(decided("git push origin feature", { ...desk, deskBranch: undefined }).action).toBe("ask");
});

test("bercail desk answer is Shep's: a No or a --dry-run runs, a Yes asks, every other role is refused", () => {
  const id = "0b7f3c1e-2a4d-4e5f-8a9b-0c1d2e3f4a5b";
  const shep = { ...desk, role: "shep", deskBranch: undefined };
  const no = `bercail desk answer t1 no --prompt ${id} --reason 'the job says no push'`;
  expect(decided(no, shep)).toMatchObject({ action: "allow", warnings: [expect.stringMatching(/^You answered No/)] });
  expect(decided(`bercail desk answer t1 yes --prompt ${id} --dry-run`, shep)).toStrictEqual({ action: "allow" });
  expect(decided(`bercail desk answer t1 yes --prompt ${id}`, shep)).toMatchObject({ action: "ask" });
  // Any other shape is refused, even for a No: the CLI could read it as another answer.
  for (const odd of [
    `bercail desk answer t1 no --prompt ${id} --reason x > /tmp/out`,
    `echo hi && bercail desk answer t1 no --prompt ${id} --reason x`,
    `bercail desk answer --reason no t1 yes --prompt ${id}`,
    `bercail desk answer t1 yes --prompt ${id} --reason --dry-run`,
    `bercail desk answer t1 yes --prompt ${id} --reason x`,
    `bercail desk answer t1 no --prompt ${id}`,
    `bercail desk answer t1 yes --dry-run --prompt ${id}`,
    `bercail desk answer -x yes --prompt ${id} --dry-run`,
    `sh -c 'bercail desk answer t1 no --prompt ${id} --reason x'`,
  ])
    expect(decided(odd, shep), odd).toMatchObject({
      action: "block",
      reason: expect.stringMatching(/runs only alone/),
    });
  expect(decided(`bercail desk answer t1 no --prompt ${id} --reason --dry-run`, shep).action).toBe("allow");
  for (const role of ["", "bstack-builder", "autopilot", "shep-bg", "discuss", "judge"])
    for (const command of [
      no,
      `bercail desk answer t1 yes --prompt ${id}`,
      `env X=1 /usr/bin/bercail desk answer t1 yes`,
      `bercail desk >/dev/null answer t1 yes --prompt ${id}`,
      `bercail desk 2>&1 answer t1 yes --prompt ${id}`,
      `bercail --x desk answer t1 yes`,
      `bercail desk > /dev/null answer t1 yes --prompt ${id}`,
      `bash bin/bercail desk answer t1 yes --prompt ${id}`,
      `bash -x bin/bercail desk answer t1 yes --prompt ${id}`,
      `bash -o errexit +O extglob -- bin/bercail desk answer t1 yes --prompt ${id}`,
      `bash -xo errexit bin/bercail desk answer t1 yes --prompt ${id}`,
      `xargs bercail desk answer t1 yes --prompt`,
    ])
      expect(decided(command, { ...shep, role }), `${role}: ${command}`).toMatchObject({
        action: "block",
        reason: expect.stringMatching(/^Answering a desk's guard prompt is Shep's/),
      });
});

test("bercail desk prompt, even for a desk named answer, is a read any role runs", () => {
  for (const command of [
    "bercail desk prompt answer",
    "bercail desk prompt t1 > /dev/null",
    "bercail desk prompt answer 2>&1",
    // bercail desk answer as data, not as the program run.
    "printf %s bercail desk answer",
    "echo bercail desk answer t1 yes",
  ])
    expect(decided(command, { ...desk, deskBranch: undefined }), command).toStrictEqual({ action: "allow" });
});

// Shep restarts stale idle desks after an update without asking (lib/desk.sh refuses a busy one).
test("Shep restarts a desk with bercail desk restart, and no card", () => {
  expect(decided("bercail desk restart t1", { ...desk, role: "shep", deskBranch: undefined })).toStrictEqual({
    action: "allow",
  });
});

test("a desk answer's Yes goes to a card only as bercail desk answer DESK yes --prompt ID", () => {
  const id = "0b7f3c1e-2a4d-4e5f-8a9b-0c1d2e3f4a5b";
  expect(guardOperation(`bercail desk answer t1 yes --prompt ${id}`, "/work", "/home")).toStrictEqual({
    kind: "command",
    dir: "/work",
    argv: ["bercail", "desk", "answer", "t1", "yes", "--prompt", id],
  });
  for (const command of [
    `bercail desk answer t1 yes --prompt ${id} --reason x`,
    `bercail desk answer t1 yes --prompt not-an-id`,
    `bercail desk answer t1 --prompt ${id} yes`,
    `bercail desk answer t1 maybe --prompt ${id}`,
  ])
    expect(typeof guardOperation(command, "/work", "/home"), command).toBe("string");
});

test("a desk answer's card pins the prompt waiting now, in the desk's worktree, with what its dry run says", async () => {
  const id = "0b7f3c1e-2a4d-4e5f-8a9b-0c1d2e3f4a5b";
  const reads: string[][] = [];
  const read = (prompt: object) => async (command: string, args: string[], cwd: string) => {
    reads.push([command, ...args, `@${cwd}`]);
    return args[1] === "prompt" ? JSON.stringify(prompt) : "Answer Yes to desk t1's guard prompt";
  };
  const op = { kind: "command" as const, dir: "/", argv: ["bercail", "desk", "answer", "t1", "yes", "--prompt", id] };
  expect(await pinOperation(op, read({ id, cwd: "/" }))).toStrictEqual({
    kind: "command",
    dir: "/",
    argv: ["bercail", "desk", "answer", "t1", "yes", "--prompt", id],
    answer: "Answer Yes to desk t1's guard prompt",
  });
  expect(reads).toStrictEqual([
    ["bercail", "desk", "prompt", "t1", "@/"],
    ["bercail", "desk", "answer", "t1", "yes", "--prompt", id, "--dry-run", "@/"],
  ]);
  // Another prompt waits now: nothing pins.
  await expect(pinOperation(op, read({ id: "other", cwd: "/" }))).rejects.toThrow(/another prompt waiting now/);
});

test("a desk answer's card pinned in Shep's session pins the same in its worker, which runs its own bercail", async () => {
  const id = "0b7f3c1e-2a4d-4e5f-8a9b-0c1d2e3f4a5b";
  const read = async (_command: string, args: string[]) =>
    args[1] === "prompt" ? JSON.stringify({ id, cwd: "/" }) : "Answer Yes to desk t1's guard prompt";
  const op = { kind: "command" as const, dir: "/", argv: ["bercail", "desk", "answer", "t1", "yes", "--prompt", id] };
  // Shep's session leaves BERCAIL_BIN unset; bin/bercail guard sets it to its own path.
  vi.stubEnv("BERCAIL_BIN", undefined);
  const asked = await pinOperation(op, read);
  vi.stubEnv("BERCAIL_BIN", "/opt/bercail/bin/bercail");
  expect(changedFacts(asked, await pinOperation(op, read))).toStrictEqual([]);
  expect(runOf(asked)).toStrictEqual({
    argv: ["/opt/bercail/bin/bercail", "desk", "answer", "t1", "yes", "--prompt", id],
    cwd: "/",
  });
});

// A prompt as the desk's guard publishes it, and a confirm the test settles by hand.
function asking(id = "11111111-2222-4333-8444-555555555555"): DeskPrompt {
  return {
    v: 1,
    id,
    address: "t1",
    pid: process.pid,
    session: "s1",
    cwd: "/work",
    tool: "bash",
    command: "git push origin main",
    reason: "Allow this push to origin: main? No keeps it local for the person.",
    at: "2026-11-25T00:00:00.000Z",
  };
}

function dialog() {
  let settle!: (yes: boolean) => void;
  let signal: AbortSignal | undefined;
  const confirm = vi.fn((_title: string, _message: string, opts?: { signal?: AbortSignal }) => {
    signal = opts?.signal;
    return new Promise<boolean>((done) => {
      settle = done;
      signal?.addEventListener("abort", () => done(false));
    });
  });
  return { confirm, person: (yes: boolean) => settle(yes), aborted: () => signal?.aborted ?? false };
}

const files = (name: string) => join(deskPrompts(), `t1.${name}.json`);
const nonce = "0123456789abcdef0123456789abcdef";
// An answer as bercail desk answer writes it, with its writer's nonce unless the body names one.
const answer = (body: object) => writeFileSync(files("answer"), JSON.stringify({ nonce, ...body }));
const done = (n = nonce) => JSON.parse(readFileSync(files(`done-${n}`), "utf8"));
const receipts = () => readdirSync(deskPrompts()).filter((name) => name.startsWith("t1.done"));
const until = async (ok: () => boolean) => {
  for (let i = 0; i < 200 && !ok(); i++) await new Promise((wait) => setTimeout(wait, 5));
  expect(ok()).toBe(true);
};

function fresh() {
  vi.stubEnv("BERCAIL_DESK_ANSWER_POLL_MS", "5");
  rmSync(deskPrompts(), { recursive: true, force: true });
}

test("an answer to the prompt waiting closes the confirm, and its receipt is written first", async () => {
  fresh();
  const prompt = asking();
  const { confirm, aborted } = dialog();
  const asked = confirmOrAnswer(confirm, "Allow this command?", prompt);
  await until(() => existsSync(join(deskPrompts(), "t1.json")));
  expect(JSON.parse(readFileSync(join(deskPrompts(), "t1.json"), "utf8"))).toStrictEqual(prompt);
  answer({ id: prompt.id, answer: "no", reason: "the job says no push" });
  expect(await asked).toStrictEqual({
    yes: false,
    answer: { id: prompt.id, answer: "no", reason: "the job says no push" },
  });
  expect(aborted()).toBe(true);
  expect(done()).toMatchObject({ id: prompt.id, nonce, status: "taken", answer: "no" });
  expect(existsSync(files("answer")), "taken once").toBe(false);
  expect(existsSync(join(deskPrompts(), "t1.json")), "the prompt is gone once settled").toBe(false);
});

test("the person answering first settles it: an answer written after is never taken", async () => {
  fresh();
  const prompt = asking();
  const { confirm, person } = dialog();
  const asked = confirmOrAnswer(confirm, "Allow this command?", prompt);
  await until(() => existsSync(join(deskPrompts(), "t1.json")));
  person(true);
  // In the same tick as the person's answer: the poll must not take it.
  answer({ id: prompt.id, answer: "no", reason: "too late" });
  expect(await asked).toStrictEqual({ yes: true });
  await new Promise((wait) => setTimeout(wait, 30));
  expect(existsSync(files("answer")), "left for bercail desk answer to take back").toBe(true);
  expect(receipts()).toStrictEqual([]);
});

test("an answer to another prompt, even one with the same command, is refused and the confirm waits", async () => {
  fresh();
  const first = asking("aaaaaaaa-2222-4333-8444-555555555555");
  const second = asking("bbbbbbbb-2222-4333-8444-555555555555");
  const one = dialog();
  const asked = confirmOrAnswer(one.confirm, "Allow this command?", first);
  await until(() => existsSync(join(deskPrompts(), "t1.json")));
  one.person(false);
  expect(await asked).toStrictEqual({ yes: false });
  // The same command asks again: an answer read for the first prompt does not answer it.
  const two = dialog();
  const again = confirmOrAnswer(two.confirm, "Allow this command?", second);
  await until(() => existsSync(join(deskPrompts(), "t1.json")));
  answer({ id: first.id, answer: "yes", reason: "" });
  await until(() => existsSync(files(`done-${nonce}`)));
  expect(done()).toMatchObject({ id: first.id, status: "refused", why: "it answers another prompt" });
  expect(two.aborted()).toBe(false);
  // A No with no reason is refused too.
  const other = "fedcba9876543210fedcba9876543210";
  answer({ id: second.id, answer: "no", reason: " ", nonce: other });
  await until(() => existsSync(files(`done-${other}`)));
  expect(done(other)).toMatchObject({ id: second.id, status: "refused", why: "a no gives its reason" });
  expect(done(), "the first writer's receipt stays its own").toMatchObject({ id: first.id, status: "refused" });
  two.person(true);
  expect(await again).toStrictEqual({ yes: true });
});

test("an answer with no nonce, or whose receipt cannot be written, answers nothing", async () => {
  fresh();
  const prompt = asking();
  const { confirm, person, aborted } = dialog();
  const asked = confirmOrAnswer(confirm, "Allow this command?", prompt);
  await until(() => existsSync(join(deskPrompts(), "t1.json")));
  answer({ id: prompt.id, answer: "no", reason: "x", nonce: "not-hex" });
  await until(() => !existsSync(files("answer")));
  // The receipt's path is taken by a folder: the guard cannot tell its writer, so it acts on nothing.
  mkdirSync(join(files(`done-${nonce}`), "full"), { recursive: true });
  answer({ id: prompt.id, answer: "no", reason: "x" });
  await until(() => !existsSync(files("answer")));
  await new Promise((wait) => setTimeout(wait, 30));
  expect(aborted()).toBe(false);
  person(true);
  expect(await asked).toStrictEqual({ yes: true });
});

test("the extension publishes a desk's prompt and takes an answer: a No refuses with its reason, a Yes runs with a warning", async () => {
  fresh();
  vi.stubEnv("HC_TERMINAL_ID", "t1");
  vi.stubEnv("BERCAIL_ROLE", "");
  const handlers: Record<string, (event: unknown, ctx: unknown) => Promise<unknown>> = {};
  const exec = vi.fn(async (_cmd: string, args: string[]) => ({
    code: 0,
    stdout: JSON.stringify({ repo: args.at(-1), policy: { push: "ask", agent_may_release: false } }),
    stderr: "",
  }));
  const { confirm } = dialog();
  guard({ on: (name: string, handler: never) => (handlers[name] = handler), registerCommand() {}, exec } as never);
  const ctx = { hasUI: true, cwd: "/work", ui: { confirm }, sessionManager: { getSessionId: () => "s1" } };
  const reply = async (body: (prompt: DeskPrompt) => object) => {
    await until(() => existsSync(join(deskPrompts(), "t1.json")));
    const prompt = JSON.parse(readFileSync(join(deskPrompts(), "t1.json"), "utf8")) as DeskPrompt;
    expect(prompt).toMatchObject({ address: "t1", pid: process.pid, session: "s1", tool: "bash", cwd: "/work" });
    answer(body(prompt));
  };
  const refused = handlers.tool_call(
    { toolName: "bash", toolCallId: "p1", input: { command: "git push origin main" } },
    ctx,
  );
  await reply((p) => ({
    id: p.id,
    answer: "no",
    reason: "the person picked commit locally, no push (https://u:s3cr3t@example.com/r)",
  }));
  expect(await refused).toStrictEqual({
    block: true,
    reason:
      "Answered No from outside the desk (bercail desk answer): the person picked commit locally, no push (https://***@example.com/r) It asked: Allow this push to origin: main? No keeps it local for the person. Leave it for the person.",
  });
  for (const log of ["guard-warnings.jsonl", "guard-approvals.jsonl"]) {
    const file = join(process.env.XDG_STATE_HOME!, "bercail", log);
    if (existsSync(file)) expect(readFileSync(file, "utf8"), log).not.toContain("s3cr3t");
  }
  const ran = handlers.tool_call(
    { toolName: "bash", toolCallId: "p2", input: { command: "git push origin main" } },
    ctx,
  );
  await reply((p) => ({ id: p.id, answer: "yes", reason: "" }));
  expect(await ran).toBeUndefined();
  const shown = (await handlers.tool_result(
    { toolName: "bash", toolCallId: "p2", content: [{ type: "text", text: "out" }], isError: false },
    {},
  )) as { content: { text: string }[] };
  expect(shown.content[0].text).toMatch(/^bercail guard warning: This prompt was answered Yes from outside the desk/);
  const approvals = readFileSync(join(process.env.XDG_STATE_HOME!, "bercail/guard-approvals.jsonl"), "utf8");
  expect(approvals).toContain("answered Yes from outside the desk");
});

test("no agent writes a desk's prompt or answer files, or the handoff records, by a tool", async () => {
  vi.stubEnv("BERCAIL_ROLE", "shep");
  const handlers: Record<string, (event: unknown, ctx: unknown) => Promise<unknown>> = {};
  const exec = vi.fn(async () => ({ code: 0, stdout: "{}", stderr: "" }));
  guard({ on: (name: string, handler: never) => (handlers[name] = handler), registerCommand() {}, exec } as never);
  const ctx = { hasUI: false, cwd: "/work", ui: {} };
  const state = join(process.env.XDG_STATE_HOME!, "bercail");
  for (const role of ["shep", ""]) {
    vi.stubEnv("BERCAIL_ROLE", role);
    for (const [toolName, input] of [
      ["write", { path: join(state, "desk-prompts/t1.answer.json") }],
      ["bash", { command: `echo '{}' > ${state}/desk-prompts/t1.answer.json` }],
      ["bash", { command: `echo '{}' >> ${state}/handoffs.jsonl` }],
    ] as const)
      expect(await handlers.tool_call({ toolName, toolCallId: "w", input }, ctx), `${role} ${toolName}`).toMatchObject({
        block: true,
      });
  }
});

test("the extension reads a desk's own branch from its handoff record, and not when it is the trunk", async () => {
  vi.stubEnv("HC_TERMINAL_ID", "t1");
  vi.stubEnv("BERCAIL_ROLE", "");
  const state = join(process.env.XDG_STATE_HOME!, "bercail");
  mkdirSync(state, { recursive: true });
  const record = (branch: string) =>
    writeFileSync(
      join(state, "handoffs.jsonl"),
      [
        JSON.stringify({ desk: "t1", path: "/work", branch: "old" }),
        JSON.stringify({ desk: "t2", path: "/work", branch: "theirs" }),
        JSON.stringify({ desk: "t1", path: "/work", branch }),
        "not json",
      ].join("\n"),
    );
  // The server's default branch, as ls-remote --symref names it; "" when it cannot read one.
  let originHead = "refs/heads/master";
  let config = "";
  // What git remote get-url prints for origin's fetch URL and its push URLs.
  let fetchUrl = "https://example.com/r.git";
  let pushUrls = "https://example.com/r.git";
  // What the branch's own name resolves to.
  let full = "refs/heads/feature";
  const handlers: Record<string, (event: unknown, ctx: unknown) => Promise<unknown>> = {};
  const exec = vi.fn(async (cmd: string, args: string[]) => {
    if (cmd === "git" && args.includes("ls-remote"))
      return { code: originHead ? 0 : 2, stdout: originHead && `ref: ${originHead}\tHEAD\nabc\tHEAD\n`, stderr: "" };
    if (cmd === "git" && args.includes("get-url"))
      return { code: 0, stdout: `${args.includes("--push") ? pushUrls : fetchUrl}\n`, stderr: "" };
    if (cmd === "git" && args.includes("--symbolic-full-name")) return { code: 0, stdout: `${full}\n`, stderr: "" };
    if (cmd === "git" && args.includes("--get-regexp")) return { code: config ? 0 : 1, stdout: config, stderr: "" };
    if (cmd === "git") return { code: 0, stdout: "feature\n", stderr: "" };
    return {
      code: 0,
      stdout: JSON.stringify({ repo: "/work", policy: { push: "ask", agent_may_release: false } }),
      stderr: "",
    };
  });
  const confirm = vi.fn(async () => false);
  guard({ on: (name: string, handler: never) => (handlers[name] = handler), registerCommand() {}, exec } as never);
  const ctx = { hasUI: true, cwd: "/work", ui: { confirm } };
  // Each push is the one tool call of its message, as Pi reports it first, unless told how many.
  const push = async (command: string, calls = 1) => {
    const content = Array.from({ length: calls }, (_, i) => ({ type: "toolCall", id: i ? `q${i}` : "p" }));
    await handlers.message_end({ message: { role: "assistant", content } }, ctx);
    return handlers.tool_call({ toolName: "bash", toolCallId: "p", input: { command } }, ctx);
  };
  record("feature");
  expect(await push("git push -u origin feature")).toBeUndefined();
  expect(confirm).not.toHaveBeenCalled();
  // One of two tool calls Pi runs together: it asks.
  expect(await push("git push origin feature", 2)).toMatchObject({ block: true });
  expect(confirm).toHaveBeenCalledOnce();
  confirm.mockClear();
  // The trunk, by the server's default branch: it asks.
  originHead = "refs/heads/feature";
  expect(await push("git push origin feature")).toMatchObject({ block: true });
  expect(confirm).toHaveBeenCalledOnce();
  // push.default upstream may send it elsewhere: it asks, unless the push names its :dst.
  originHead = "refs/heads/master";
  config = "push.default upstream\n";
  expect(await push("git push origin feature")).toMatchObject({ block: true });
  expect(confirm).toHaveBeenCalledTimes(2);
  expect(await push("git push origin HEAD:refs/heads/feature")).toBeUndefined();
  // Config that makes a push send more (tags, submodules) asks, whatever the refspec.
  config = "push.followtags true\n";
  expect(await push("git push origin HEAD:refs/heads/feature")).toMatchObject({ block: true });
  config = "submodule.recurse true\n";
  expect(await push("git push origin HEAD:refs/heads/feature")).toMatchObject({ block: true });
  config = "push.recursesubmodules check\n";
  expect(await push("git push origin feature")).toBeUndefined();
  expect(confirm).toHaveBeenCalledTimes(4);
  // A default branch it cannot read may be this one: it asks.
  config = "";
  originHead = "";
  expect(await push("git push origin feature")).toMatchObject({ block: true });
  expect(confirm).toHaveBeenCalledTimes(5);
  originHead = "refs/heads/master";
  // A push URL that is not the fetch URL ls-remote read the default from, or two, asks.
  pushUrls = "https://example.com/other.git";
  expect(await push("git push origin feature")).toMatchObject({ block: true });
  pushUrls = "https://example.com/r.git\nhttps://example.com/other.git";
  expect(await push("git push origin feature")).toMatchObject({ block: true });
  // A path may end in a space: the URLs compare byte for byte.
  pushUrls = `${fetchUrl} `;
  expect(await push("git push origin feature")).toMatchObject({ block: true });
  // A path Pi decoded lossily, or two fetch URLs, cannot be told apart: it asks.
  fetchUrl = pushUrls = "/srv/r\uFFFD.git";
  expect(await push("git push origin feature")).toMatchObject({ block: true });
  fetchUrl = "https://example.com/r.git\nhttps://example.com/other.git";
  pushUrls = fetchUrl;
  expect(await push("git push origin feature")).toMatchObject({ block: true });
  fetchUrl = "https://example.com/r.git";
  pushUrls = fetchUrl;
  // A name git resolves to a tag, not the branch, asks.
  full = "refs/tags/feature";
  expect(await push("git push origin feature")).toMatchObject({ block: true });
  expect(confirm).toHaveBeenCalledTimes(11);
  full = "refs/heads/feature";
  expect(await push("git push origin feature")).toBeUndefined();
  // A command that could not be the desk's own push, or one run outside its worktree, asks
  // git nothing about origin: printf push, push's help, another remote, a -C.
  const remoteReads = () =>
    exec.mock.calls.filter(([, args]) => args.includes("ls-remote") || args.includes("get-url"));
  exec.mockClear();
  for (const command of [
    "printf push",
    "git push --help",
    "git push upstream feature",
    "git -C /work push origin feature",
  ])
    await push(command);
  // Nor one of two tool calls of its message.
  await push("git push origin feature", 2);
  expect(remoteReads()).toStrictEqual([]);
  await handlers.message_end({ message: { role: "assistant", content: [{ type: "toolCall", id: "p" }] } }, ctx);
  await handlers.tool_call(
    { toolName: "bash", toolCallId: "p", input: { command: "git push origin feature" } },
    { ...ctx, cwd: "/elsewhere" },
  );
  expect(remoteReads()).toStrictEqual([]);
  // Another terminal's record is not this desk's.
  confirm.mockClear();
  vi.stubEnv("HC_TERMINAL_ID", "t3");
  expect(await push("git push origin feature")).toMatchObject({ block: true });
  expect(confirm).toHaveBeenCalledOnce();
});
