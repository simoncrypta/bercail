// Shep's guard asks (docs/plans/shep-free-guard.md): which command is one operation the
// guard can hand off, and what it pins. Real git in a temp HOME; entire is a stand-in.
import { execFileSync } from "node:child_process";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  realpathSync,
  rmSync,
  statSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, expect, test, vi } from "vite-plus/test";
import guard, { changedFacts, guardOperation, markStart, pinOperation } from "../bstack/pi/extensions/guard.ts";

let dir: string;
let repo: string;
let origin: string;
const git = (...args: string[]) => execFileSync("git", ["-C", repo, ...args], { encoding: "utf8" }).trim();
const op = (command: string, cwd = "/nowhere") => {
  const got = guardOperation(command, cwd, dir);
  if (typeof got === "string") throw new Error(`${command}: ${got}`);
  return got;
};
const pin = (command: string, cwd?: string) => pinOperation(op(command, cwd));
// The trail entire trail show prints: changes with their state, head and base.
const trail = (changes: Record<string, unknown>[]) =>
  writeFileSync(join(dir, "trail.json"), JSON.stringify({ id: "01TRAIL", number: 41, changes }));
const change = (number: number, extra: Record<string, unknown> = {}) => ({
  repository: "app",
  number,
  status: "open",
  base: "main",
  current: null,
  mergeability: { head_sha: "f".repeat(40) },
  ...extra,
});

beforeEach(() => {
  dir = realpathSync(mkdtempSync(join(tmpdir(), "guard-ask-")));
  for (const key of Object.keys(process.env)) if (/^(GIT_|BERCAIL_|HC_)/.test(key)) vi.stubEnv(key, undefined);
  vi.stubEnv("HOME", dir);
  vi.stubEnv("XDG_CONFIG_HOME", join(dir, "config"));
  vi.stubEnv("GIT_CONFIG_NOSYSTEM", "1");
  vi.stubEnv("GIT_AUTHOR_NAME", "Test");
  vi.stubEnv("GIT_COMMITTER_NAME", "Test");
  vi.stubEnv("GIT_AUTHOR_EMAIL", "test@example.invalid");
  vi.stubEnv("GIT_COMMITTER_EMAIL", "test@example.invalid");
  const bin = join(dir, "bin");
  mkdirSync(bin);
  writeFileSync(
    join(bin, "entire"),
    `#!/bin/sh\nprintf '%s|%s\\n' "$PWD" "$*" >> '${dir}/entire.argv'\ncat '${dir}/trail.json'\n`,
    { mode: 0o755 },
  );
  vi.stubEnv("ENTIRE_BIN", join(bin, "entire"));
  repo = join(dir, "repo");
  origin = join(dir, "origin.git");
  execFileSync("git", ["init", "-q", "-b", "main", repo]);
  execFileSync("git", ["init", "-q", "--bare", origin]);
  git("commit", "-q", "--allow-empty", "-m", "one");
  git("branch", "feature");
  git("remote", "add", "origin", origin);
});
afterEach(() => {
  vi.unstubAllEnvs();
  rmSync(dir, { recursive: true, force: true });
});

test("a push pins its checkout, the remote's URL and each commit to its full branch", async () => {
  const head = git("rev-parse", "HEAD");
  const facts = {
    kind: "push",
    dir: repo,
    gitDir: join(repo, ".git"),
    url: origin,
    refspecs: [`${head}:refs/heads/feature`],
  };
  expect(await pin(`git -C ${repo} push origin feature`)).toStrictEqual(facts);
  // The folder a cd names, a relative -C, and each way a refspec names its branch.
  expect(await pin(`cd ${repo} && git push origin feature`)).toStrictEqual(facts);
  expect(await pin("git -C repo push origin feature", dir)).toStrictEqual(facts);
  expect(
    await pin(`git -C ${repo} push origin HEAD feature:refs/heads/other ${head}^{commit}:refs/heads/third`),
  ).toMatchObject({
    refspecs: [`${head}:refs/heads/main`, `${head}:refs/heads/other`, `${head}:refs/heads/third`],
  });
});

test("a cleanup pins the worktree's real path, branch and HEAD; a trail merge, its one change", async () => {
  const worktree = join(dir, "repo.topic");
  git("worktree", "add", "-q", worktree, "feature");
  symlinkSync(worktree, join(dir, "link"));
  expect(await pin(`bercail cleanup ${join(dir, "link")}`)).toStrictEqual({
    kind: "cleanup",
    worktree,
    branch: "refs/heads/feature",
    head: git("rev-parse", "HEAD"),
  });
  const merged = {
    kind: "trail merge",
    checkout: repo,
    trailId: "01TRAIL",
    change: "app/7",
    head: "f".repeat(40),
    base: "main",
  };
  // A project trail's one open change, among closed and merged ones.
  trail([change(6, { status: "merged" }), change(7)]);
  expect(await pin(`cd ${repo} && entire trail merge 41`)).toStrictEqual(merged);
  // Through a change, or the branch: the change show says it came through.
  trail([change(6), change(7, { current: true })]);
  expect(await pin(`cd ${repo} && entire trail merge app/7`)).toStrictEqual(merged);
  expect(await pin(`cd ${repo} && entire trail merge`)).toStrictEqual(merged);
  // From a linked worktree: entire reads its branch's change there, and it merges in the main checkout.
  expect(await pin(`cd ${worktree} && entire trail merge`)).toStrictEqual(merged);
  expect(readFileSync(join(dir, "entire.argv"), "utf8").trim().split("\n").at(-1)).toBe(
    `${worktree}|trail show --json`,
  );
});

test.each([
  ["a second command", (r: string) => `git -C ${r} push origin feature; true`],
  ["a pipe", (r: string) => `git -C ${r} push origin feature | cat`],
  ["two cds", (r: string) => `cd / && cd ${r} && git push origin feature`],
  ["a substitution", (r: string) => `git -C ${r} push origin $(echo feature)`],
  ["a variable", (r: string) => `git -C ${r} push $REMOTE feature`],
  ["quoting", (r: string) => `git -C ${r} push origin 'feature'`],
  ["a redirect", (r: string) => `git -C ${r} push origin feature 2>/dev/null`],
  ["a flag", (r: string) => `git -C ${r} push -q origin feature`],
  ["an env prefix", (r: string) => `GIT_SSH_COMMAND=ssh git -C ${r} push origin feature`],
  ["no refspec", (r: string) => `git -C ${r} push origin`],
  ["a URL for a remote", (r: string) => `git -C ${r} push /srv/other.git feature`],
  ["a cleanup flag", (r: string) => `bercail cleanup --force ${r}`],
  ["a trail merge flag", (r: string) => `cd ${r} && entire trail merge 41 --force`],
  ["another command", (r: string) => `rm -rf ${r}`],
  ["a relative folder with no cwd", () => "git -C repo push origin feature"],
  ["a folder with ..", (r: string) => `git -C ${r}/../repo push origin feature`],
  ["a cd with ..", (r: string) => `cd ${r}/.. && entire trail merge 41`],
  ["a cleanup with ..", (r: string) => `bercail cleanup ${r}/../repo.topic`],
])("%s is not one operation", (_name, command) => {
  expect(typeof guardOperation(command(repo), _name.includes("no cwd") ? undefined : "/", dir)).toBe("string");
});

test.each([
  ["a git -C to a folder it cannot read", async () => `git -C ${join(dir, "missing")} push origin feature`, /missing/],
  [
    "a remote with two push URLs",
    async () => {
      git("remote", "set-url", "--add", "--push", "origin", origin);
      git("remote", "set-url", "--add", "--push", "origin", join(dir, "mirror.git"));
      return `git -C ${repo} push origin feature`;
    },
    /must push to one URL, not 2/,
  ],
  [
    "a URL with a credential",
    async () => {
      git("remote", "set-url", "origin", "https://bot:s3cret@example.invalid/app.git");
      return `git -C ${repo} push origin feature`;
    },
    /not one a card can show/,
  ],
  [
    "a URL a url.* rule rewrites again",
    async () => {
      // git sends to the rewritten URL, which a push to it as written rewrites once more.
      execFileSync("git", ["init", "-q", "--bare", join(dir, "rewritten.git")]);
      git("config", `url.${join(dir, "rewritten.git")}.insteadOf`, origin);
      git("config", `url.${join(dir, "third.git")}.pushInsteadOf`, join(dir, "rewritten"));
      return `git -C ${repo} push origin feature`;
    },
    /rewrites origin's push URL/,
  ],
  [
    "a URL a rule with a space in its key rewrites again",
    async () => {
      // git sends to rewritten.git, which a rule keyed by a URL with a space rewrites once more.
      execFileSync("git", ["init", "-q", "--bare", join(dir, "rewritten.git")]);
      git("config", `url.${join(dir, "rewritten.git")}.insteadOf`, origin);
      git("config", `url.${join(dir, "with space.git")}.pushInsteadOf`, join(dir, "rewritten"));
      return `git -C ${repo} push origin feature`;
    },
    /rewrites origin's push URL/,
  ],
  [
    "a local URL through ..",
    async () => {
      git("remote", "set-url", "origin", `${dir}/repo/../origin.git`);
      return `git -C ${repo} push origin feature`;
    },
    /names a folder with \. or \.\./,
  ],
  [
    "a file:// URL, whose %-escapes git decodes",
    async () => {
      git("remote", "set-url", "origin", `file://${origin}`);
      return `git -C ${repo} push origin feature`;
    },
    /is a file:\/\/ URL; set it to the repo's path/,
  ],
  [
    "a tag",
    async () => {
      git("tag", "v1");
      return `git -C ${repo} push origin v1`;
    },
    /does not push to a branch/,
  ],
  ["a hash to a short name", async () => `git -C ${repo} push origin ${git("rev-parse", "HEAD")}:feature`, /short/],
  // git matches a short destination against the remote's refs: a tag v1 there gets the push.
  ["a branch to a short name", async () => `git -C ${repo} push origin feature:v1`, /write refs\/heads\/v1/],
  [
    "a branch remote.<name>.push maps elsewhere",
    async () => {
      git("config", "remote.origin.push", "refs/heads/feature:refs/heads/other");
      return `git -C ${repo} push origin feature`;
    },
    /remote.<name>.push decides where feature goes/,
  ],
  ["a delete", async () => `git -C ${repo} push origin :feature`, /not one source/],
  ["one branch twice", async () => `git -C ${repo} push origin feature feature`, /same branch twice/],
  ["a cleanup of a folder inside a worktree", async () => `bercail cleanup ${join(repo, ".git")}`, /./],
  [
    "a trail with several open changes",
    async () => {
      trail([change(6), change(7)]);
      return `cd ${repo} && entire trail merge 41`;
    },
    /2 open changes; name one/,
  ],
  [
    "a change with no head yet",
    async () => {
      trail([change(7, { current: true, mergeability: null })]);
      return `cd ${repo} && entire trail merge app/7`;
    },
    /no one open change/,
  ],
  [
    "a trail entire cannot show",
    async () => {
      chmodSync(join(dir, "bin/entire"), 0o644);
      return `cd ${repo} && entire trail merge 41`;
    },
    /entire trail show failed/,
  ],
])("%s does not pin", async (_name, setup, why) => {
  await expect(pinOperation(op(await setup(), "/"))).rejects.toThrow(why);
});

test("each pinned fact that moves is named: a -C destination, the push URL, the trail's open change", async () => {
  const other = join(dir, "other");
  execFileSync("git", ["clone", "-q", repo, other]);
  execFileSync("git", ["-C", other, "remote", "set-url", "origin", origin]);
  // The same words and cwd, but the folder -C names now points elsewhere.
  symlinkSync(repo, join(dir, "here"));
  const push = op(`git -C ${join(dir, "here")} push origin main`);
  const was = await pinOperation(push);
  rmSync(join(dir, "here"));
  symlinkSync(other, join(dir, "here"));
  expect(changedFacts(was, await pinOperation(push))).toStrictEqual(["dir changed", "gitDir changed"]);
  // A local remote through a symlink is pinned by its real path: moving the link moves the URL.
  execFileSync("git", ["init", "-q", "--bare", join(dir, "second.git")]);
  symlinkSync(origin, join(dir, "link.git"));
  git("remote", "set-url", "origin", join(dir, "link.git"));
  const linked = await pinOperation(op(`git -C ${repo} push origin main`));
  expect(linked).toMatchObject({ url: origin });
  rmSync(join(dir, "link.git"));
  symlinkSync(join(dir, "second.git"), join(dir, "link.git"));
  expect(changedFacts(linked, await pinOperation(op(`git -C ${repo} push origin main`)))).toStrictEqual([
    "url changed",
  ]);
  git("remote", "set-url", "origin", join(dir, "elsewhere.git"));
  execFileSync("git", ["init", "-q", "--bare", join(dir, "elsewhere.git")]);
  const fromRepo = op(`git -C ${repo} push origin main`);
  const atRepo = await pinOperation(fromRepo);
  git("remote", "set-url", "origin", origin);
  expect(changedFacts(atRepo, await pinOperation(fromRepo))).toStrictEqual(["url changed"]);
  trail([change(6, { status: "merged" }), change(7)]);
  const merge = op(`cd ${repo} && entire trail merge 41`);
  const before = await pinOperation(merge);
  trail([change(6, { status: "merged" }), change(8)]);
  expect(changedFacts(before, await pinOperation(merge))).toStrictEqual(["change changed"]);
  trail([change(6, { status: "merged" }), change(7, { mergeability: { head_sha: "e".repeat(40) } })]);
  expect(changedFacts(before, await pinOperation(merge))).toStrictEqual(["head changed"]);
});

// The guard in Shep's session (BERCAIL_ROLE=shep) or a desk's: exec stands in for
// bercail policy show, entire agent-help, push-approval and hc run; hc does what `hc` says.
function session(role: string, hc: (args: string[]) => { code: number; stderr?: string } = () => ({ code: 1 })) {
  vi.stubEnv("BERCAIL_ROLE", role);
  vi.stubEnv("XDG_STATE_HOME", join(dir, "state"));
  const handlers: Record<string, (event: unknown, ctx: unknown) => Promise<unknown>> = {};
  const exec = vi.fn(async (cmd: string, args: string[]) => {
    if (cmd === "hc") return { stdout: "", stderr: "", ...hc(args) };
    if (args[0] === "policy")
      return { code: 0, stdout: JSON.stringify({ repo: args.at(-1), policy: { push: "ask" } }), stderr: "" };
    if (args[0] === "shep") return { code: 0, stdout: JSON.stringify({ approved: approve }), stderr: "" };
    return { code: 0, stdout: "{}", stderr: "" };
  });
  const confirm = vi.fn(async () => false);
  guard({ on: (name: string, handler: never) => (handlers[name] = handler), registerTool() {}, exec } as never);
  const ctx = { hasUI: true, cwd: repo, ui: { confirm }, sessionManager: { getSessionId: () => "shep-session" } };
  let calls = 0;
  const bash = async (command: string) => {
    const id = `c${calls++}`;
    await handlers.message_end({ message: { role: "assistant", content: [{ type: "toolCall", id }] } }, ctx);
    return (await handlers.tool_call({ toolName: "bash", toolCallId: id, input: { command } }, ctx)) as
      | { block: true; reason: string }
      | undefined;
  };
  return { bash, confirm, exec };
}
let approve: string | null = null;
const asks = () => join(dir, "state/bercail/guard-asks");
// Every kind of ask the guard makes in Shep's session today.
const askFixtures = () => [
  `git -C ${repo} push origin feature`,
  `git -C ${repo} tag v1.0.0`,
  `git -C ${repo} push origin feature && git -C ${repo} push origin main`,
  "gh release create v1.0.0",
  "gh pr create --fill",
  `bercail cleanup ${repo}`,
  `cd ${repo} && entire trail merge 41`,
  "entire brain distill --dry-run",
  "entire frob",
  Array.from({ length: 9 }, (_, i) => `git -C /r${i} push origin f`).join("; "),
];

test("Shep's session never waits on a guard confirm: every ask is handed off or refused", async () => {
  const shep = session("shep");
  trail([change(7)]);
  for (const command of askFixtures()) {
    const got = await shep.bash(command);
    expect(got, command).toMatchObject({
      block: true,
      reason: expect.stringMatching(/Shep's session never waits on a confirm|Handed off/),
    });
  }
  expect(shep.confirm).not.toHaveBeenCalled();
  // A desk keeps today's dialog for each of them, but for a trail merge, which only Shep runs.
  const desk = session("");
  for (const command of askFixtures()) {
    const before = desk.confirm.mock.calls.length;
    await desk.bash(command);
    expect(desk.confirm.mock.calls.length - before, command).toBe(command.includes("trail merge") ? 0 : 1);
  }
});

test("an ask handed off writes its ticket and starts its worker, which Shep is told of", async () => {
  let argv: string[] = [];
  const shep = session("shep", (args) => {
    argv = args;
    markStart(args.at(-1)!, "started");
    return { code: 0 };
  });
  const got = await shep.bash(`git -C ${repo} push origin feature`);
  const [name] = readdirSync(asks()).filter((n) => n.endsWith(".json"));
  const id = name.slice(0, -5);
  expect(got).toStrictEqual({
    block: true,
    reason: `Handed off, not run: the person answers this push of ${origin} refs/heads/feature on a Decisions card, and the worker guard-ask-${id} runs it only on their Allow, within the hour. Tell the person in one line that the card is up. Do not retry it, wait for it or run it another way; your turn goes on. Its outcome comes back as a guard event; report it then.`,
  });
  expect(argv).toStrictEqual([
    "run",
    "--bg",
    "--name",
    `guard-ask-${id}`,
    "--cwd",
    asks(),
    "--outlive-parent",
    "--no-notify",
    "--rm",
    "--",
    "env",
    "BERCAIL_ROLE=shep",
    `XDG_STATE_HOME=${join(dir, "state")}`,
    `ENTIRE_BIN=${join(dir, "bin/entire")}`,
    "bercail",
    "guard",
    "ask",
    id,
  ]);
  const ticket = JSON.parse(readFileSync(join(asks(), name), "utf8"));
  expect(statSync(join(asks(), name)).mode & 0o777).toBe(0o600);
  expect(ticket).toMatchObject({
    id,
    command: `git -C ${repo} push origin feature`,
    cwd: repo,
    reason: "Allow this push to origin: feature? No keeps it local for the person.",
    op: { kind: "push", dir: repo, remote: "origin", refspecs: ["feature"] },
    facts: { kind: "push", url: origin, refspecs: [`${git("rev-parse", "feature")}:refs/heads/feature`] },
    shep: { session: "shep-session" },
  });
  expect(Date.parse(ticket.expires) - Date.parse(ticket.at)).toBe(3600000);
  // Its folder is the guard's: no agent writes a ticket, or starts a worker on one.
  const forged = await shep.bash(`echo '{}' > ${join(asks(), "0123456789ab.json")}`);
  expect(forged).toMatchObject({
    block: true,
    reason: expect.stringMatching(/decides what bercail's guard lets through/),
  });
  for (const command of [`bercail guard ask ${id}`, "bercail shep question guard-claim Q1@1 x"])
    expect(await shep.bash(command), command).toMatchObject({
      block: true,
      reason: expect.stringMatching(/the guard's/),
    });
});

test.each([
  [
    "a ticket it cannot write",
    () => writeFileSync(join(dir, "state/bercail/guard-asks"), ""),
    () => ({ code: 0 }),
    /could not write its ticket/,
  ],
  [
    "a worker hc cannot start",
    () => {},
    () => ({ code: 1, stderr: "no server\n" }),
    /hc could not start guard-ask-[0-9a-f]{12}: no server/,
  ],
  [
    "a worker that never says it started",
    () => {},
    () => ({ code: 0 }),
    /guard-ask-[0-9a-f]{12} did not start within 0 s/,
  ],
])("%s is refused, and a late worker finds its ticket void", async (_name, setup, hc, why) => {
  vi.stubEnv("BERCAIL_GUARD_ASK_WAIT_MS", "300");
  mkdirSync(join(dir, "state/bercail"), { recursive: true });
  setup();
  const shep = session("shep", hc);
  const got = await shep.bash(`git -C ${repo} push origin feature`);
  expect(got).toMatchObject({ block: true, reason: expect.stringMatching(why) });
  expect(got?.reason).toMatch(/Shep's session never waits on a confirm/);
  for (const name of existsSync(asks()) && statSync(asks()).isDirectory() ? readdirSync(asks()) : [])
    if (name.endsWith(".json")) expect(markStart(name.slice(0, -5), "started")).toBe("void");
  expect(shep.confirm).not.toHaveBeenCalled();
});

test("a push the person's answer approves runs in Shep's session with no handoff", async () => {
  approve = "Q7@1";
  try {
    const shep = session("shep");
    const head = git("rev-parse", "HEAD");
    expect(await shep.bash(`git -C ${repo} push origin ${head}^{commit}:refs/heads/main`)).toBeUndefined();
    expect(shep.exec.mock.calls.some(([cmd]) => cmd === "hc")).toBe(false);
    expect(existsSync(asks())).toBe(false);
  } finally {
    approve = null;
  }
});
