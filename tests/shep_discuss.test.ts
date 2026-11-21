// Discuss branches (shep/pi/discuss.ts) from fake Shep and desk sessions in a scratch
// state dir and Pi agent dir, read back with Pi's own SessionManager.
import { SessionManager } from "@earendil-works/pi-coding-agent";
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, expect, test, vi } from "vite-plus/test";
import register, { branchPath, openDiscussion } from "../shep/pi/discuss.ts";

// The live check, as the test sets it: /pick and pick() run it before recording.
const check = vi.hoisted(() => ({ status: "fresh", reasons: [] as string[] }));
vi.mock("../shep/pi/question-target.ts", () => ({
  checkQuestion: async () => ({ ...check, current: { head: null, stagedTree: null } }),
}));
import { QuestionStore, type Question, type QuestionSpec } from "../shep/pi/questions.ts";

let dir: string;
let state: string;
beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "shep-discuss-"));
  state = join(dir, "state");
  vi.stubEnv("PI_CODING_AGENT_DIR", join(dir, "agent"));
});
afterEach(() => {
  vi.unstubAllEnvs();
  rmSync(dir, { recursive: true, force: true });
});

let n = 0;
const entry = (parentId: string | null, message: Record<string, unknown>, id = `e${++n}`) => ({
  type: "message",
  id,
  parentId,
  timestamp: "2026-11-15T12:00:00.000Z",
  message: { timestamp: 0, ...message },
});
const user = (p: string | null, text: string, id?: string) => entry(p, { role: "user", content: text }, id);
const said = (p: string | null, text: string, id?: string) =>
  entry(p, { role: "assistant", content: [{ type: "text", text }], stopReason: "stop" }, id);
const asks = (p: string | null, call: string, id?: string) =>
  entry(p, { role: "assistant", content: [{ type: "toolCall", id: call, name: "shep_question", arguments: {} }] }, id);
const result = (p: string | null, call: string, id?: string) =>
  entry(p, { role: "toolResult", toolCallId: call, toolName: "shep_question", content: [] }, id);

function session(path: string, id: string, cwd: string, entries: object[]) {
  mkdirSync(join(path, ".."), { recursive: true });
  const header = { type: "session", version: 3, id, timestamp: "2026-11-15T12:00:00.000Z", cwd };
  writeFileSync(path, [header, ...entries].map((e) => JSON.stringify(e)).join("\n") + "\n");
}

function ask(
  target: Partial<QuestionSpec["target"]>,
  origin: QuestionSpec["origin"],
  extra: Partial<QuestionSpec> = {},
): Question {
  const spec: QuestionSpec = {
    kind: "planning",
    prompt: "Which job first?",
    options: ["A", "B"],
    origin,
    target: {
      repo: "/r/.git",
      issue: null,
      topic: "plan",
      worktree: "/r",
      desk: null,
      space: null,
      session: null,
      action: null,
      head: null,
      stagedTree: null,
      base: null,
      baseRef: null,
      ...target,
    },
    ...extra,
  };
  return new QuestionStore(state).create(`r${++n}`, {}, () => spec);
}

// What Pi would send: each message's role and text.
const roles = (file: string) =>
  SessionManager.open(file)
    .buildSessionContext()
    .messages.map((m) => {
      const content = (m as { content?: unknown }).content;
      const text = Array.isArray(content) ? content.map((c) => c.text ?? c.type).join(" ") : content;
      return `${m.role}:${JSON.stringify(text ?? "")}`;
    });

test("a chat question branches Shep's session at the turn that asked it; Shep's file is only read", () => {
  // Shep's turn: the person asks, Shep calls shep_question (the origin entry), gets the
  // result, says it in words. Then the session goes on to other things.
  const shepFile = join(state, "pi-sessions", "2026-11-15T12-00-00-000Z_shep-1.jsonl");
  session(shepFile, "shep-1", join(state, "workspace"), [
    user(null, "what next?", "u1"),
    asks("u1", "c1", "a1"),
    result("a1", "c1", "r1"),
    // An extension's state entry inside the turn does not end it.
    { type: "custom", id: "x1", parentId: "r1", timestamp: "2026-11-15T12:00:00.000Z", customType: "ext", data: {} },
    said("x1", "I asked you: A or B?", "a2"),
    user("a2", "later news", "u2"),
    said("u2", "unrelated", "a3"),
  ]);
  const before = readFileSync(shepFile, "utf8");
  const q = ask({}, { event: "chat", session: "shep-1", entry: "a1" });
  const d = openDiscussion(state, q);
  expect(d.created).toBe(true);
  expect(d.cwd).toBe(join(state, "workspace"));
  expect(d.forkedAt).toBe("a2");
  expect(d.session.startsWith(join(state, "discuss", "sessions") + "/")).toBe(true);
  expect(readdirSync(join(state, "pi-sessions"))).toEqual(["2026-11-15T12-00-00-000Z_shep-1.jsonl"]);
  expect(readFileSync(shepFile, "utf8")).toBe(before);
  // Pi opens the branch as the conversation up to the question, nothing after it.
  const sm = SessionManager.open(d.session);
  expect(sm.getHeader()).toMatchObject({ parentSession: shepFile, cwd: join(state, "workspace") });
  expect(sm.getLeafId()).toBe("a2");
  expect(roles(d.session)).toEqual([
    'user:"what next?"',
    'assistant:"toolCall"',
    'toolResult:""',
    'assistant:"I asked you: A or B?"',
  ]);
  // A closed modal reopens on the same branch, with what was said in it.
  writeFileSync(d.session, readFileSync(d.session, "utf8") + JSON.stringify(user("a2", "why A?", "u9")) + "\n");
  const again = openDiscussion(state, q);
  expect(again).toMatchObject({ created: false, session: d.session });
  expect(SessionManager.open(again.session).getLeafId()).toBe("u9");
});

test("a desk question branches the desk's own session at its last complete entry", () => {
  const deskFile = join(dir, "agent", "sessions", "--r--", "2026-11-15T11-00-00-000Z_desk-7.jsonl");
  session(deskFile, "desk-7", "/r", [
    user(null, "Your job is beads issue app-1.", "u1"),
    said("u1", "Done; staged for review.", "a1"),
    user("a1", "also check the docs", "u2"),
    // Mid-turn: a tool call with no result yet is cut back, with what led to it kept.
    entry("u2", { role: "assistant", content: [{ type: "toolCall", id: "c7", name: "bash", arguments: {} }] }, "a2"),
  ]);
  const before = readFileSync(deskFile, "utf8");
  const q = ask(
    { desk: "t9", session: "desk-7", worktree: "/r" },
    { event: "finished:1", session: "shep-1", entry: "x" },
  );
  const d = openDiscussion(state, q);
  expect(d).toMatchObject({ cwd: "/r", source: deskFile, forkedAt: "u2" });
  expect(roles(d.session)).toEqual([
    'user:"Your job is beads issue app-1."',
    'assistant:"Done; staged for review."',
    'user:"also check the docs"',
  ]);
  expect(readFileSync(deskFile, "utf8")).toBe(before);
});

test("a branch says what it is missing instead of starting on the wrong session", () => {
  const gone = ask({}, { event: "chat", session: "nope", entry: "a1" });
  expect(() => openDiscussion(state, gone)).toThrow(/Shep's session nope is gone/);
  const desk = ask({ desk: "t9", session: "gone-desk" }, { event: "e", session: "s", entry: null });
  expect(() => openDiscussion(state, desk)).toThrow(/desk's Pi session gone-desk is gone/);
  expect(() => branchPath([user(null, "x", "u1") as never], "zz")).toThrow(/entry zz is not in the session/);
});

// The branch's Pi: its commands, hooks and UI, faked.
function branchPi(token: string) {
  vi.stubEnv("BERCAIL_SHEP_STATE", state);
  vi.stubEnv("BERCAIL_DISCUSS_TOKEN", token);
  const commands: Record<string, (args: string, ctx: unknown) => Promise<unknown>> = {};
  const hooks: Record<string, (event: unknown, ctx?: unknown) => unknown> = {};
  register({
    registerCommand: (name: string, c: { handler: never }) => (commands[name] = c.handler),
    on: (name: string, f: never) => (hooks[name] = f),
  } as never);
  const seen = { notes: [] as string[], selects: [] as string[][], shutdown: 0, pick: undefined as string | undefined };
  const ctx = {
    hasUI: true,
    ui: {
      notify: (text: string) => seen.notes.push(text),
      select: async (_title: string, options: string[]) => (seen.selects.push(options), seen.pick),
      setWidget: () => {},
    },
    shutdown: () => seen.shutdown++,
  };
  return { pick: () => commands.pick!("", ctx), hooks, seen };
}

test("/pick in the branch shows Shep's pick, refuses a stale question, and records once", async () => {
  ask({}, { event: "chat", session: "s", entry: null }, { recommendation: { choice: "B", why: "smaller" } });
  const b = branchPi("Q1@1");
  expect((b.hooks.before_agent_start!({ systemPrompt: "base" }) as { systemPrompt: string }).systemPrompt).toMatch(
    /## Discuss branch\n.*you cannot run commands, edit, spawn or message desks, commit, merge, push/s,
  );
  check.status = "stale";
  check.reasons = ["stagedTree changed"];
  await b.pick();
  expect(b.seen.notes).toEqual(["Can't answer: stagedTree changed. Shep must ask again."]);
  expect(b.seen.selects).toEqual([]);
  check.status = "fresh";
  check.reasons = [];
  b.seen.pick = "2. B  (Shep recommends: smaller)";
  await b.pick();
  expect(b.seen.selects).toEqual([["1. A", "2. B  (Shep recommends: smaller)"]]);
  expect(new QuestionStore(state).snapshot().questions[0]).toMatchObject({
    status: "answered",
    answer: { choice: "B", source: "discuss picker" },
  });
  expect(readdirSync(join(state, "inbox"))).toEqual(["decision-Q1-1.json"]);
  expect(b.seen.shutdown).toBe(1);
  await b.pick();
  expect(b.seen.notes.at(-1)).toBe("Not recorded: question is answered.");
  expect(readdirSync(join(state, "inbox"))).toEqual(["decision-Q1-1.json"]);
});

test("a push question's branch says only a pick on the panel card approves the push, at the picker too", async () => {
  vi.stubEnv("BERCAIL_SHEP_STATE", state);
  const push = { approves: "Push it", remote: "origin", refs: ["refs/heads/master"], url: "/srv/app.git" };
  const [head, stagedTree, base] = ["a", "b", "c"].map((c) => c.repeat(40));
  ask(
    { issue: "app-1", action: "land", head, stagedTree, base, baseRef: "master" },
    { event: "chat", session: "s", entry: null },
    { kind: "action", options: ["Push it", "Not yet"], push },
  );
  const b = branchPi("Q1@1");
  const widgets: string[][] = [];
  b.hooks.session_start!({}, { hasUI: true, ui: { setWidget: (_id: string, lines: string[]) => widgets.push(lines) } });
  expect(widgets[0]).toContain(
    'Picking "Push it" on the panel card lets Shep push the answered commit to origin (/srv/app.git): refs/heads/master, once. A /pick here does not approve the push.',
  );
  b.seen.pick = undefined;
  await b.pick();
  expect(b.seen.selects).toEqual([["1. Push it  (approves the push only on the panel card)", "2. Not yet"]]);
});
