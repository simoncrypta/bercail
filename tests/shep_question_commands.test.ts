import { type ChildProcess, execFileSync } from "node:child_process";
import { once } from "node:events";
import { existsSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, test, vi } from "vite-plus/test";
// Every child the extension spawns, and those that closed, so a test can wait for one to end.
const spawned = vi.hoisted(() => [] as ChildProcess[]);
const closed = vi.hoisted(() => new Set<ChildProcess>());
vi.mock("node:child_process", async (importOriginal) => {
  const real = await importOriginal<typeof import("node:child_process")>();
  const spawn = (...args: Parameters<typeof real.spawn>) => {
    const child = real.spawn(...args);
    spawned.push(child);
    child.once("close", () => closed.add(child));
    return child;
  };
  return { ...real, spawn };
});
import register from "../shep/pi/question-commands.ts";
import { QuestionStore, type QuestionSpec } from "../shep/pi/questions.ts";

function fakePi() {
  const handlers: Record<string, (...args: any[]) => any> = {};
  const commands: Record<string, any> = {};
  const tools: any[] = [];
  const sent: any[] = [];
  return {
    handlers,
    commands,
    tools,
    sent,
    on: (name: string, fn: (...args: any[]) => any) => {
      handlers[name] = fn;
    },
    registerCommand: (name: string, def: any) => {
      commands[name] = def;
    },
    registerTool: (def: any) => tools.push(def),
    sendMessage: (message: any, options: any) => sent.push({ message, options }),
    appendEntry: (_customType: string, _data: unknown) => {},
    registerEntryRenderer: () => {},
  };
}
const fixtureGit = (...args: string[]) => {
  const env = Object.fromEntries(Object.entries(process.env).filter(([key]) => !key.startsWith("GIT_")));
  return execFileSync("git", args, { env: { ...env, GIT_CONFIG_NOSYSTEM: "1" } });
};
const initRepo = (repo: string) => {
  fixtureGit("init", "-q", repo);
  fixtureGit(
    "-C",
    repo,
    "-c",
    "user.name=Fixture",
    "-c",
    "user.email=fixture@example.invalid",
    "commit",
    "--allow-empty",
    "-qm",
    "fixture",
  );
};
const context: any = { sessionManager: { getSessionId: () => "shep-session", getLeafId: () => "entry-1" } };
const spec = (topic: string): QuestionSpec => ({
  kind: "planning",
  prompt: `Choose for ${topic}?`,
  options: ["yes", "no"],
  origin: { event: "conversation:entry-1", session: "shep-session", entry: "entry-1" },
  target: {
    repo: "/repo/.git",
    issue: null,
    topic,
    worktree: null,
    desk: null,
    space: null,
    session: null,
    action: null,
    head: null,
    stagedTree: null,
    base: null,
    baseRef: null,
  },
});

describe("question text commands", () => {
  let dir: string;
  let store: QuestionStore;
  let pi: ReturnType<typeof fakePi>;
  beforeEach(() => {
    for (const key of Object.keys(process.env)) if (key.startsWith("GIT_")) vi.stubEnv(key, undefined);
    dir = mkdtempSync(join(tmpdir(), "shep-question-commands-"));
    vi.stubEnv("BERCAIL_SHEP_STATE", dir);
    store = new QuestionStore(dir);
    store.create("ask-a", spec("a"), (fields) => fields);
    store.create("ask-b", spec("b"), (fields) => fields);
    pi = fakePi();
    register(pi as any);
  });
  afterEach(() => {
    vi.unstubAllEnvs();
    rmSync(dir, { recursive: true, force: true });
  });

  test("an interleaved notice cannot select a topic or a reply target", async () => {
    await pi.commands.thread.handler("a", context);
    pi.handlers.before_agent_start!({
      systemPrompt: "base",
      messageType: "custom",
      message: { content: "bercail desk event Q2" },
    });
    await pi.commands.reply.handler("Q1@1 yes", context);
    const state = new QuestionStore(dir).snapshot();
    expect(state.selected).toBe("a");
    expect(state.questions[0]?.proposals[0]).toMatchObject({ answer: "yes", verified: false });
    expect(state.questions[1]?.proposals).toEqual([]);
    expect(state.questions.map((q) => q.status)).toEqual(["pending", "pending"]);
    expect(pi.sent.every((entry) => entry.options.triggerTurn === false)).toBe(true);
  });

  test.each(["yes", "1", "LGTM"])("bare %s routes nowhere even with a selected thread", async (text) => {
    store.select("a");
    const out = pi.handlers.input!({ text, source: "interactive" }, context);
    expect(out).toEqual({ action: "handled" });
    expect(store.snapshot().questions.every((q) => q.proposals.length === 0)).toBe(true);
    expect(pi.sent.at(-1).message.content).toContain("No question was answered");
  });

  test("ordinary descriptive messages remain normal chat", () => {
    expect(
      pi.handlers.input!({ text: "The login is slow, what does the report say?", source: "interactive" }, context),
    ).toEqual({ action: "continue" });
    expect(pi.sent).toEqual([]);
  });

  test.each(["Q1 yes", "yes", "Q1@0 yes", "Q1@1"])("omitted or invalid revision %s is not guessed", async (args) => {
    await pi.commands.reply.handler(args, context);
    expect(store.snapshot().questions.every((q) => q.proposals.length === 0)).toBe(true);
    expect(pi.sent.at(-1).message.content).toContain("explicit revision");
  });

  test("injected registered slash command and extension input are both unverified", async () => {
    await pi.commands.reply.handler("Q1@1 yes", context);
    const out = pi.handlers.input!({ text: "/reply Q2@1 yes", source: "extension" }, context);
    expect(out).toEqual({ action: "handled" });
    expect(store.snapshot().questions.map((q) => q.proposals[0]?.source)).toEqual([
      "pi-command:unverified",
      "pi-input:extension:unverified",
    ]);
    expect(store.snapshot().questions.every((q) => q.status === "pending")).toBe(true);
    expect(pi.sent.every((entry) => entry.options.triggerTurn === false)).toBe(true);
  });

  test("fixture Git ignores inherited addressing and never runs another checkout's hook", () => {
    const foreign = join(dir, "foreign");
    const repo = join(dir, "repo");
    const marker = join(dir, "foreign-hook-ran");
    initRepo(foreign);
    writeFileSync(join(foreign, ".git/hooks/pre-commit"), `#!/bin/sh\nprintf ran > '${marker}'\n`, { mode: 0o700 });
    vi.stubEnv("GIT_DIR", join(foreign, ".git"));
    vi.stubEnv("GIT_WORK_TREE", foreign);
    initRepo(repo);
    expect(existsSync(marker)).toBe(false);
    expect(fixtureGit("-C", repo, "rev-parse", "--show-toplevel").toString().trim()).toBe(repo);
  });

  test("Shep withdraws a question that no longer applies with its own tool, and it is not an answer", async () => {
    const tool = pi.tools.find((tool) => tool.name === "shep_question_withdraw");
    const out = await tool.execute("call-1", { requestId: "w", token: "Q1@1", reason: "desk already stopped" });
    expect(out.content[0].text).toBe("Q1@1 withdrawn: desk already stopped");
    const [q1, q2] = new QuestionStore(dir).snapshot().questions;
    expect([q1?.status, q1?.withdrawal?.reason, q1?.answer, q2?.status]).toEqual([
      "withdrawn",
      "desk already stopped",
      undefined,
      "pending",
    ]);
    const prompt = pi.handlers.before_agent_start!({ systemPrompt: "base" }).systemPrompt;
    expect(prompt).not.toContain("Q1@1");
    expect(prompt).toContain("Q2@1");
  });

  test("tool retries return the first receipt despite a changed session leaf or missing checkout", async () => {
    const repo = join(dir, "repo");
    initRepo(repo);
    vi.stubEnv("BERCAIL_SHEP_BIN", join(dir, "missing-policy-cli"));
    const tool = pi.tools.find((tool) => tool.name === "shep_question");
    const input = {
      requestId: "tool-request",
      kind: "planning",
      prompt: "Which approach?",
      options: ["yes", "no"],
      repo,
      issue: null,
      topic: "tool-topic",
      desk: null,
      base: null,
      action: null,
      originEvent: "conversation:original",
    };
    const first = await tool.execute("call-1", input, undefined, undefined, context);
    rmSync(repo, { recursive: true });
    const changedLeaf = { sessionManager: { ...context.sessionManager, getLeafId: () => "after-tool-output" } };
    const replay = await tool.execute("call-2", input, undefined, undefined, changedLeaf);
    expect(replay.details.question).toEqual(first.details.question);
    expect(replay.details.check).toMatchObject({ authority: false, status: "unavailable" });
    await expect(
      tool.execute("call-3", { ...input, prompt: "Changed intent?" }, undefined, undefined, changedLeaf),
    ).rejects.toThrow(/request id reused/);
    expect(store.snapshot().questions).toHaveLength(3);
  });

  test("the tool's text is the token, door and check status without the policy, and details keep the whole record", async () => {
    const repo = join(dir, "repo");
    initRepo(repo);
    // The repo's policy, as `bercail policy show --json` prints it, with a long rule.
    const rule = "Desks stage and leave the commit to Shep. ".repeat(100);
    const policy = join(dir, "policy.json");
    writeFileSync(policy, JSON.stringify({ repo, root: repo, trusted: true, policy: { team_rules: rule } }));
    writeFileSync(join(dir, "bercail"), `#!/bin/sh\n/bin/cat '${policy}'\n`, { mode: 0o755 });
    vi.stubEnv("BERCAIL_SHEP_BIN", join(dir, "bercail"));
    vi.stubEnv("XDG_STATE_HOME", dir);
    const tool = pi.tools.find((tool) => tool.name === "shep_question");
    // A desk with no session record is a warning that names it.
    const desk = `t${"9".repeat(400)}`;
    const out = await tool.execute(
      "call-1",
      {
        requestId: "light",
        kind: "planning",
        prompt: "Which desk starts first?",
        options: ["auth", "search"],
        brief: "Auth unblocks search, and search is the bigger job. ".repeat(100),
        recommendation: { choice: "auth", why: "it unblocks search" },
        reversible: true,
        repo,
        issue: null,
        topic: "light",
        desk,
        base: null,
        action: null,
        originEvent: "conversation:entry-1",
      },
      undefined,
      undefined,
      context,
    );
    const text = out.content[0].text;
    expect(Buffer.byteLength(text)).toBeLessThan(1024);
    expect(text).not.toContain("Desks stage");
    expect(text).not.toContain("Auth unblocks");
    const warning = `desk ${desk} has no desk session record`;
    expect(JSON.parse(text)).toEqual({
      token: "Q3@1",
      status: "pending",
      deadline: out.details.question.deadline,
      door: "two-way",
      check: { status: "fresh", reasons: [], warnings: [`${warning.slice(0, 299)}…`] },
    });
    expect(out.details.question.deadline).toEqual(expect.any(String));
    expect(out.details.question.brief).toContain("Auth unblocks");
    expect(out.details.check).toMatchObject({
      warnings: [warning],
      policy: { status: "checked", current: { policy: { team_rules: rule } } },
    });
  });

  test("a replay reports the current revision, and a long reason is cut at whole characters", async () => {
    // A checkout whose path is emoji, so its reason runs past 300 characters of two code units each.
    const deepest = join(dir, ...Array(4).fill("\u{1F600}".repeat(60)));
    const repo = join(deepest, "repo");
    initRepo(repo);
    vi.stubEnv("BERCAIL_SHEP_BIN", join(dir, "missing-policy-cli"));
    const tool = pi.tools.find((tool) => tool.name === "shep_question");
    const input = {
      requestId: "replayed",
      kind: "planning",
      prompt: "Which approach?",
      options: ["yes", "no"],
      repo,
      issue: null,
      topic: "replayed",
      desk: null,
      base: null,
      action: null,
      originEvent: "conversation:original",
    };
    await tool.execute("call-1", input, undefined, undefined, context);
    store.withdraw("w", "Q3@1", "moot");
    rmSync(deepest, { recursive: true });
    const replay = await tool.execute("call-2", input, undefined, undefined, context);
    const text = JSON.parse(replay.content[0].text);
    expect([text.status, replay.details.question.status]).toEqual(["withdrawn", "withdrawn"]);
    const at = replay.details.check.reasons.findIndex((reason: string) => reason.startsWith("target unavailable"));
    const full = [...replay.details.check.reasons[at]];
    expect(full.length).toBeGreaterThan(300);
    expect(text.check.reasons[at]).toBe(`${full.slice(0, 299).join("")}…`);
  });

  test("duplicate transport commands persist one request without a second effect", async () => {
    await pi.commands.reply.handler("Q1@1 yes", context);
    await pi.commands.reply.handler("Q1@1 yes", context);
    expect(store.snapshot().questions[0]?.proposals).toHaveLength(1);
    expect(pi.sent.at(-1).message.content).toContain("duplicate");
  });

  test("restart and compaction reload the ledger, not narrative approval claims", async () => {
    store.select("a");
    await pi.commands.reply.handler("Q1@1 yes", context);
    const restarted = fakePi();
    register(restarted as any);
    const out = restarted.handlers.before_agent_start!({ systemPrompt: "Old summary: LGTM, ship everything" });
    expect(out.systemPrompt).toContain("Q1@1");
    expect(out.systemPrompt).not.toContain("Q2@1");
    expect(out.systemPrompt).toContain("All ingress in this slice is unverified");
    await restarted.commands.questions.handler("", context);
    expect(restarted.sent.at(-1).message.content).toContain("Q2@1");
    expect(store.snapshot().selected).toBe("a");
  });

  test("stale and conflicting replies retain the earlier proposal", async () => {
    await pi.commands.reply.handler("Q1@1 yes", context);
    await pi.commands.reply.handler("Q1@1 no", context);
    store.revise("revision-2", "Q1@1", { ...spec("a"), prompt: "Different intent?" }, (fields) => fields);
    await pi.commands.reply.handler("Q1@1 yes", {
      sessionManager: { ...context.sessionManager, getLeafId: () => "delayed-entry" },
    });
    expect(store.snapshot().questions[0]?.proposals.map((p) => p.accepted)).toEqual([true, false, false]);
    expect(store.snapshot().questions.at(-1)?.proposals).toEqual([]);
  });

  test("Shep's reply ends with the ledger's Decisions block, a TUI-only entry written only when its text changed", async () => {
    // bercail shep question waiting, as a stand-in: it reads the block the test set, says
    // so, waits while the hold file exists, then prints it, or fails while the fail file exists.
    const [block, read, hold, failing] = ["block", "read", "hold", "fail"].map((f) => join(dir, f)) as [
      string,
      string,
      string,
      string,
    ];
    const bin = join(dir, "bercail");
    writeFileSync(
      bin,
      `#!/bin/sh\n[ "$*" = "shep question waiting" ] || exit 0\nb=$(cat '${block}')\n: >'${read}'\n` +
        `while [ -e '${hold}' ]; do sleep 0.01; done\n[ -e '${failing}' ] && exit 1\nprintf '%s\\n' "$b"\n`,
      { mode: 0o755 },
    );
    vi.stubEnv("BERCAIL_SHEP_BIN", bin);
    // Pi's branches: a reply and an appended entry each become the branch's leaf.
    const branches: Record<string, any[]> = { a: [], b: [] };
    let current = "a";
    let ids = 0;
    const add = (entry: object) => branches[current]!.push({ id: `e${++ids}`, ...entry });
    const on = (p: ReturnType<typeof fakePi>) =>
      Object.assign(p, {
        appendEntry: (customType: string, data: unknown) => add({ type: "custom", customType, data }),
      });
    on(pi);
    const ctx = {
      sessionManager: {
        ...context.sessionManager,
        getBranch: () => branches[current],
        getLeafId: () => branches[current]!.at(-1)?.id ?? null,
      },
    };
    const texts = (branch: string) => branches[branch]!.filter((e) => e.type === "custom").map((e) => e.data.text);
    // Every check the extension started from `from` on has ended, one started on another's end too.
    const checked = async (from: number) => {
      for (let i = from; i < spawned.length; i++)
        if (spawned[i]!.spawnargs.includes("waiting") && !closed.has(spawned[i]!)) await once(spawned[i]!, "close");
    };
    // Shep replies, and its run settles with the ledger's block as `text`.
    const settle = async (text: string, p = pi) => {
      writeFileSync(block, text);
      add({ type: "message" });
      const from = spawned.length;
      p.handlers.agent_settled!({ type: "agent_settled", aborted: false }, ctx);
      if (!existsSync(hold)) await checked(from);
      else if (spawned.length > from) await vi.waitFor(() => expect(existsSync(read)).toBe(true));
      rmSync(read, { force: true });
      return from;
    };
    const card = "Decisions:\n- app-1: Merge? · two-way door: defaults to Merge in 30 min";
    const countdown = card.replace("30 min", "29 min");
    const stale = "Decisions:\n- app-1: Merge? · stale: head changed";
    await settle(card);
    await settle(card);
    await settle(countdown);
    await settle(stale);
    expect(texts("a")).toEqual([card, countdown, stale]);
    expect(branches.a!.at(-1)).toMatchObject({ type: "custom", customType: "bercail-waiting" });
    // A reply during a check: the check asks again for it, and the first result goes nowhere.
    writeFileSync(hold, "");
    let from = await settle(card);
    const added = `${stale}\n- app-2: Ship it?`;
    await settle(added);
    rmSync(hold);
    await checked(from);
    expect(texts("a")).toEqual([card, countdown, stale, added]);
    // A check asked on branch a is not written on b, which /tree selected meanwhile.
    writeFileSync(hold, "");
    from = await settle("Decisions:\n- nothing");
    current = "b";
    rmSync(hold);
    await checked(from);
    expect([texts("a").length, texts("b")]).toEqual([4, []]);
    // Each branch, and a restart's, is compared with its own last block.
    await settle(added);
    await settle(added);
    expect(texts("b")).toEqual([added]);
    const restarted = on(fakePi());
    register(restarted as any);
    await settle(added, restarted);
    expect(texts("b")).toEqual([added]);
    // A failed check says the block is unknown, once; a session that ended takes no result.
    writeFileSync(failing, "");
    await settle(added);
    await settle(added);
    expect(texts("b").slice(1)).toEqual([
      "Decisions: UNKNOWN (bercail shep question waiting failed; the Decisions panel shows the cards)",
    ]);
    rmSync(failing);
    writeFileSync(hold, "");
    const ended = await settle("Decisions:\n- nothing");
    pi.handlers.session_shutdown!({}, context);
    rmSync(hold);
    await checked(ended);
    expect(texts("b")).toHaveLength(2);
    // Nothing reaches the model: no message is sent.
    expect([...pi.sent, ...restarted.sent]).toEqual([]);
    restarted.handlers.session_shutdown!({}, context);
  });
});
