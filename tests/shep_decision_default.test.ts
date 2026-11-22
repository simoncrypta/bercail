// A two-way door's default (shep/pi/discuss.ts expireDue, which Shep's question
// extension runs as `bercail shep question expire`): the ledger takes Shep's
// recommendation past the deadline, once, and Shep's inbox gets one decision event that
// says it was not the person's pick.
import type { ChildProcess } from "node:child_process";
import { once } from "node:events";
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, expect, test, vi } from "vite-plus/test";

// The live check, as the test sets it: a default runs it before recording.
const check = vi.hoisted(() => ({ status: "fresh", reasons: [] as string[] }));
vi.mock("../shep/pi/question-target.ts", () => ({
  checkQuestion: async () => ({ ...check, current: { head: null, stagedTree: null } }),
}));
// Every child Shep's runtime spawns, so a test can wait for each one to exit.
const spawned = vi.hoisted(() => [] as ChildProcess[]);
vi.mock("node:child_process", async (importOriginal) => {
  const real = await importOriginal<typeof import("node:child_process")>();
  const spawn = (...args: Parameters<typeof real.spawn>) => {
    const child = real.spawn(...args);
    spawned.push(child);
    return child;
  };
  return { ...real, spawn };
});
import { closed, expireDue, pick, settle } from "../shep/pi/discuss.ts";
import { claim, eventLine } from "../shep/pi/inbox.ts";
import register, { EXPIRE_MS } from "../shep/pi/question-commands.ts";
import { projection, QuestionStore, tokenOf, type QuestionSpec } from "../shep/pi/questions.ts";

let dir: string;
let state: string;
beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "shep-decision-default-"));
  state = join(dir, "state");
  for (const key of Object.keys(process.env)) if (key.startsWith("BERCAIL_")) vi.stubEnv(key, undefined);
  vi.stubEnv("BERCAIL_SHEP_STATE", state);
  check.status = "fresh";
  check.reasons = [];
  spawned.length = 0;
  vi.useFakeTimers({ toFake: ["Date", "setInterval", "clearInterval"] });
  vi.setSystemTime("2026-11-19T12:00:00.000Z");
});
afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllEnvs();
  rmSync(dir, { recursive: true, force: true });
});

const ask = (topic = "plan", reversible = true): string => {
  const spec: QuestionSpec = {
    kind: "planning",
    prompt: "Which desk starts first?",
    options: ["auth", "search"],
    recommendation: { choice: "auth", why: "it unblocks search" },
    ...(reversible ? { reversible: true as const } : {}),
    origin: { event: "conversation:e1", session: "shep-1", entry: "e1" },
    target: {
      repo: "/r/.git",
      issue: null,
      topic,
      worktree: "/r",
      desk: null,
      space: null,
      session: null,
      action: null,
      head: null,
      stagedTree: null,
      base: null,
      baseRef: null,
    },
  };
  return tokenOf(new QuestionStore(state).create(`ask-${topic}`, {}, () => spec));
};
const inbox = () => {
  try {
    return readdirSync(join(state, "inbox")).sort();
  } catch {
    return [];
  }
};
const event = (name: string) => JSON.parse(readFileSync(join(state, "inbox", name), "utf8"));
const confirm = (s: string, requestId: string, token: string, source: "panel picker" | "discuss picker") =>
  settle(s, requestId, token, "ok", null, source);
const answer = (token: string) =>
  new QuestionStore(state).snapshot().questions.find((q) => tokenOf(q) === token)!.answer;

test("a deadline missed while nothing ran fires at the next run, once, with one event that is not the person's", async () => {
  const token = ask();
  ask("other", false);
  expect(await expireDue(state)).toEqual([]);
  // Shep and the panel were down past the deadline; the next run catches up.
  vi.setSystemTime("2026-11-19T14:00:00.000Z");
  const [done] = await Promise.all([expireDue(state), expireDue(state)]).then((runs) => runs.flat());
  expect(done).toMatchObject({ id: "Q1", status: "answered" });
  expect(answer(token)).toMatchObject({ choice: "auth", source: "default after timeout" });
  expect(inbox()).toEqual(["decision-Q1-1.json"]);
  expect(event("decision-Q1-1.json")).toMatchObject({
    kind: "decision",
    event_id: "decision:Q1-1",
    question: { token: "Q1@1", topic: "plan" },
    choice: "auth",
    by: "default after timeout",
  });
  // Delivered once: a later run adds nothing.
  const delivered = join(state, "delivered");
  mkdirSync(delivered);
  const [taken] = claim(join(state, "inbox"), delivered);
  expect(taken!.line).toBe(
    '- Nobody picked by the deadline: the two-way door defaulted to your recommendation "auth" (default after timeout, not the person\'s choice; never an LGTM or reviewer; it authorizes only the card\'s own action: action commit, the local commit; merge or land, that merge; a planning card, no write; run question check before you act) for Q1@1 "Which desk starts first?" (topic plan). Nothing was discussed. [event decision:Q1-1]',
  );
  expect(await expireDue(state)).toEqual([]);
  expect(inbox()).toEqual([]);
  expect(readdirSync(delivered)).toEqual(["decision-Q1-1.json"]);
  expect(new QuestionStore(state).snapshot().questions[1]!.status).toBe("pending");
});

test("a question that changed since Shep asked waits past its deadline, and defaults once it checks fresh", async () => {
  const token = ask();
  vi.setSystemTime("2026-11-19T12:31:00.000Z");
  check.status = "unavailable";
  check.reasons = ["target unavailable: gone"];
  expect(await expireDue(state)).toEqual([]);
  expect(answer(token)).toBeUndefined();
  expect(inbox()).toEqual([]);
  check.status = "fresh";
  check.reasons = [];
  expect((await expireDue(state)).map(tokenOf)).toEqual([token]);
});

test("a default whose event could not be written is sent at a later run, however late, and never twice", async () => {
  const token = ask();
  const told = () => new QuestionStore(state).snapshot().questions[0]!.told;
  vi.setSystemTime("2026-11-19T12:30:00.000Z");
  // The inbox cannot be written: the ledger records the default, the event fails.
  writeFileSync(join(state, "inbox"), "not a folder");
  await expect(expireDue(state)).rejects.toThrow();
  expect(answer(token)?.source).toBe("default after timeout");
  expect(told()).toBeUndefined();
  // A run a month later (Shep was down) sends it, and the ledger marks it told.
  rmSync(join(state, "inbox"));
  vi.setSystemTime("2026-12-19T12:30:00.000Z");
  expect(await expireDue(state)).toEqual([]);
  expect(inbox()).toEqual(["decision-Q1-1.json"]);
  expect(event("decision-Q1-1.json")).toMatchObject({ choice: "auth", by: "default after timeout" });
  expect(told()).toBe(true);
  // Told is never sent again, even once the inbox no longer has it.
  rmSync(join(state, "inbox", "decision-Q1-1.json"));
  await expireDue(state);
  expect(inbox()).toEqual([]);
});

test("a crash between writing the event and marking it told sends nothing twice", async () => {
  ask();
  vi.setSystemTime("2026-11-19T12:30:00.000Z");
  const store = new QuestionStore(state);
  store.expire("Q1@1", { status: "fresh", reasons: [], current: { head: null, stagedTree: null } });
  mkdirSync(join(state, "delivered"), { recursive: true });
  writeFileSync(join(state, "delivered", "decision-Q1-1.json"), '{"already":"delivered"}\n');
  await expireDue(state);
  expect(inbox()).toEqual([]);
  expect(readFileSync(join(state, "delivered", "decision-Q1-1.json"), "utf8")).toBe('{"already":"delivered"}\n');
  expect(store.snapshot().questions[0]!.told).toBe(true);
});

test("Shep's runtime runs the expiry in its own process at start and on its timer, never in a turn", async () => {
  // bercail shep question expire, as a stand-in that logs each run.
  const bin = join(dir, "bercail");
  const log = join(dir, "runs");
  writeFileSync(bin, `#!/bin/sh\nprintf '%s\\n' "$*" >> '${log}'\n`, { mode: 0o755 });
  vi.stubEnv("BERCAIL_SHEP_BIN", bin);
  const handlers: Record<string, (...args: any[]) => any> = {};
  const sent: unknown[] = [];
  register({
    on: (name: string, fn: (...args: any[]) => any) => (handlers[name] = fn),
    registerCommand: () => {},
    registerTool: () => {},
    sendMessage: (m: unknown) => sent.push(m),
  } as any);
  // Wait for each run's exit, bounded only by the test's timeout: the runtime starts no second run
  // while one is still going, so the timer must fire only after the first has exited.
  const runs = () => readFileSync(log, "utf8").trim().split("\n");
  handlers.session_start!({}, {});
  expect(spawned).toHaveLength(1);
  await once(spawned[0]!, "exit");
  expect(runs()).toEqual(["shep question expire"]);
  await vi.advanceTimersByTimeAsync(EXPIRE_MS);
  expect(spawned).toHaveLength(2);
  await once(spawned[1]!, "exit");
  expect(runs()).toEqual(["shep question expire", "shep question expire"]);
  expect(sent).toEqual([]);
  handlers.session_shutdown!({}, {});
  expect(vi.getTimerCount()).toBe(0);
}, 30_000);

test("after a default, Discuss can still tell Shep the person disagrees, and /pick changes nothing", async () => {
  const token = ask();
  vi.setSystemTime("2026-11-19T12:30:00.000Z");
  await expireDue(state);
  expect(await pick(state, "p1", token, "search", "panel picker")).toMatchObject({
    accepted: false,
    reason: "question is answered",
  });
  expect(closed(state, token, "o1")).toBe(true);
  const ev = event("decision-Q1-1-closed-o1.json");
  expect(ev).toMatchObject({ choice: null, by: "discuss closed", defaulted: "auth" });
  expect(eventLine(ev)).toMatch(
    /^- The person closed Discuss on it after it defaulted to "auth"; it was a two-way door, so if they disagree, undo it or ask again for Q1@1 /,
  );
  expect(answer(token)).toMatchObject({ choice: "auth", source: "default after timeout" });
});

test("the person's OK on a default makes it their pick once, with one event, and nothing else takes it", async () => {
  const token = ask();
  const plain = ask("other", false);
  // Not a default yet, or never one: OK records nothing.
  expect(await confirm(state, "ok-early", token, "panel picker")).toMatchObject({
    accepted: false,
    reason: "question is pending, not defaulted: only a default takes OK or Reverse",
  });
  await pick(state, "p1", plain, "search", "panel picker");
  expect(await confirm(state, "ok-picked", plain, "panel picker")).toMatchObject({
    accepted: false,
    reason: "question is answered, not defaulted: only a default takes OK or Reverse",
  });
  vi.setSystemTime("2026-11-19T12:30:00.000Z");
  await expireDue(state);
  // A stale target takes no OK, and the card keeps waiting.
  check.status = "stale";
  check.reasons = ["worktree changed"];
  expect(await confirm(state, "ok-stale", token, "panel picker")).toMatchObject({
    accepted: false,
    reason: "changed since it defaulted: worktree changed",
  });
  check.status = "fresh";
  check.reasons = [];
  await expect(confirm(state, "ok-forged", token, "default after timeout" as never)).rejects.toThrow(
    /unknown answer source/,
  );
  expect(inbox()).toEqual(["decision-Q1-1.json", "decision-Q2-1.json"]);
  vi.setSystemTime("2026-11-19T13:00:00.000Z");
  const result = await confirm(state, "ok-1", token, "discuss picker");
  expect(result).toMatchObject({ accepted: true });
  const q = new QuestionStore(state).snapshot().questions[0]!;
  // The default stays as it was; the OK is its own record, from the person's picker.
  expect(q.answer).toMatchObject({ choice: "auth", source: "default after timeout" });
  expect(q.settled).toEqual({
    requestId: "ok-1",
    outcome: "ok",
    choice: "auth",
    source: "discuss picker",
    at: "2026-11-19T13:00:00.000Z",
    head: null,
    stagedTree: null,
    told: true,
  });
  expect(inbox()).toEqual(["decision-Q1-1-ok.json", "decision-Q1-1.json", "decision-Q2-1.json"]);
  const ev = event("decision-Q1-1-ok.json");
  expect(ev).toMatchObject({ event_id: "decision:Q1-1-ok", choice: "auth", by: "discuss picker", confirmed: true });
  expect(eventLine(ev)).toBe(
    '- The person said OK to the default "auth" in the discuss picker: it is now their pick, as if they had picked it on the card (an LGTM only where the card asked for one); if you already acted on the default, keep that and do not do it again; if not, act on it once as their pick while question check is fresh for Q1@1 "Which desk starts first?" (topic plan). Nothing was discussed. [event decision:Q1-1-ok]',
  );
  // A retry of the same OK is the same record; a second OK is refused; a pick still is.
  expect(await confirm(state, "ok-1", token, "discuss picker")).toMatchObject({ accepted: true });
  expect(await confirm(state, "ok-2", token, "panel picker")).toMatchObject({
    accepted: false,
    reason: "its default already has the person's OK",
  });
  expect(await pick(state, "p2", token, "search", "panel picker")).toMatchObject({ accepted: false });
  expect(new QuestionStore(state).snapshot().questions[0]!.settled?.requestId).toBe("ok-1");
  // Closing Discuss after the OK tells Shep nothing more: the OK said it.
  expect(closed(state, token, "o1")).toBe(false);
  expect(projection(new QuestionStore(state).snapshot())).toContain(
    "Q1@1 Which desk starts first? -> auth (confirmed default, discuss picker, 2026-11-19T13:00:00.000Z)",
  );
});

test("an OK event that is not the person's is dropped, not shown to Shep", () => {
  const base = { source: "bercail", kind: "decision", event_id: "decision:Q1-1-ok", question: { token: "Q1@1" } };
  expect(eventLine({ ...base, choice: "auth", by: "default after timeout", confirmed: true })).toBeNull();
  expect(eventLine({ ...base, choice: "auth", by: "panel picker", confirmed: "yes" })).toBeNull();
});

test("the person's Reverse on a default names another choice or none, once, and its card waits for Shep's withdraw", async () => {
  const token = ask();
  const other = ask("other");
  vi.setSystemTime("2026-11-19T12:30:00.000Z");
  await expireDue(state);
  const reverse = (id: string, t: string, choice: string | null) =>
    settle(state, id, t, "reversed", choice, "panel picker");
  // The default's own choice, or one the question does not offer, is no Reverse; nor is a stale target.
  for (const choice of ["auth", "neither"])
    expect(await reverse(`r-${choice}`, token, choice)).toMatchObject({
      accepted: false,
      reason: "not another of the question's choices: it defaulted to auth",
    });
  check.status = "stale";
  check.reasons = ["base changed"];
  expect(await reverse("r-stale", token, "search")).toMatchObject({
    accepted: false,
    reason: "changed since it defaulted: base changed",
  });
  check.status = "fresh";
  check.reasons = [];
  expect(await reverse("r-1", token, "search")).toMatchObject({ accepted: true });
  expect(await reverse("r-2", other, null)).toMatchObject({ accepted: true });
  const [q1, q2] = new QuestionStore(state).snapshot().questions;
  expect(q1!.answer).toMatchObject({ choice: "auth", source: "default after timeout" });
  expect(q1!.settled).toMatchObject({
    requestId: "r-1",
    outcome: "reversed",
    choice: "search",
    source: "panel picker",
  });
  expect(q2!.settled).toMatchObject({ outcome: "reversed", choice: null });
  const ev = event("decision-Q1-1-reversed.json");
  expect(ev).toMatchObject({
    event_id: "decision:Q1-1-reversed",
    choice: "search",
    by: "panel picker",
    reversed: "auth",
  });
  expect(eventLine(ev)).toBe(
    '- The person reversed the default "auth" in the panel picker, to "search": undo what you did on the default, only what you took, then act on "search" once as their pick while question check is fresh, or ask again; then withdraw the question with what you did, which takes its card off the panel for Q1@1 "Which desk starts first?" (topic plan). Nothing was discussed. [event decision:Q1-1-reversed]',
  );
  expect(eventLine(event("decision-Q2-1-reversed.json"))).toMatch(
    /^- The person reversed the default "auth" in the panel picker, with no other choice: undo what you did on the default, only what you took, then ask again if it still matters; then withdraw /,
  );
  // Reverse twice, or OK after it, is refused; Discuss closing adds nothing.
  expect(await reverse("r-3", token, null)).toMatchObject({
    accepted: false,
    reason: "its default is already reversed",
  });
  expect(await confirm(state, "ok-1", token, "panel picker")).toMatchObject({
    accepted: false,
    reason: "its default is already reversed",
  });
  expect(closed(state, token, "o1")).toBe(false);
  // Shep's list says what to do; once Shep has, its withdraw closes the card and keeps the record.
  const listed = projection(new QuestionStore(state).snapshot());
  expect(listed).toContain("Reversed by the person (undo what you did on the default");
  expect(listed).toContain("Q1@1 Which desk starts first? -> reversed auth to search (panel picker, ");
  expect(listed).toContain("Q2@1 Which desk starts first? -> reversed auth with no other choice (panel picker, ");
  const store = new QuestionStore(state);
  const withdrawn = store.withdraw("w-1", token, "undid the default's step and started search");
  expect(withdrawn).toMatchObject({
    status: "withdrawn",
    answer: { source: "default after timeout" },
    settled: { choice: "search" },
  });
  expect(() => store.withdraw("w-2", token, "again")).toThrow(/question is withdrawn/);
  expect(projection(store.snapshot())).not.toContain("Q1@1 Which desk");
});

test("Shep may withdraw a default the person has not answered, never one they said OK to", async () => {
  const token = ask();
  const confirmed = ask("other");
  vi.setSystemTime("2026-11-19T12:30:00.000Z");
  await expireDue(state);
  await confirm(state, "ok-1", confirmed, "panel picker");
  const store = new QuestionStore(state);
  expect(() => store.withdraw("w-ok", confirmed, "moot")).toThrow(
    /question is answered; only a pending question, or a default without the person's OK, can be withdrawn/,
  );
  expect(store.withdraw("w-1", token, "its desk is gone")).toMatchObject({
    status: "withdrawn",
    answer: { choice: "auth" },
  });
  // Withdrawn, it takes neither OK nor Reverse.
  expect(await confirm(state, "ok-2", token, "panel picker")).toMatchObject({
    accepted: false,
    reason: "question is withdrawn",
  });
});

test("Shep's rules say what it does on an OK and on a Reverse, and the docs list their keys", () => {
  const rules = readFileSync(new URL("../shep/SHEP.md", import.meta.url), "utf8").replace(/\s+/g, " ");
  expect(rules).toContain("Until the person says OK, it is never an LGTM: no `--reviewed-by`.");
  expect(rules).toContain(
    "makes it the person's pick, with the full weight of one: an LGTM where the card asked for one.",
  );
  expect(rules).toContain("Undo what you did on the default, only what you took");
  expect(rules).toContain("Never withdraw it before you have handled it.");
  const docs = readFileSync(new URL("../docs/shep.md", import.meta.url), "utf8");
  expect(docs).toContain("| o | OK a defaulted card: keep its default as your pick |");
  expect(docs).toContain("| r | Reverse a defaulted card, to the picked choice when it is not the default |");
});

test("an OK or Reverse whose event could not be written is sent at Shep's next expire run, once", async () => {
  const token = ask();
  vi.setSystemTime("2026-11-19T12:30:00.000Z");
  await expireDue(state);
  // The inbox cannot be written: the ledger records the Reverse, and says so; the event waits.
  rmSync(join(state, "inbox"), { recursive: true });
  writeFileSync(join(state, "inbox"), "not a folder");
  expect(await settle(state, "r-1", token, "reversed", "search", "panel picker")).toMatchObject({ accepted: true });
  const settled = () => new QuestionStore(state).snapshot().questions[0]!.settled;
  expect(settled()).toMatchObject({ outcome: "reversed", choice: "search" });
  expect(settled()!.told).toBeUndefined();
  // A retry from the panel gets a new request id and is refused; the ledger sends it instead.
  expect(await settle(state, "r-2", token, "reversed", "search", "panel picker")).toMatchObject({ accepted: false });
  rmSync(join(state, "inbox"));
  expect(await expireDue(state)).toEqual([]);
  expect(inbox()).toEqual(["decision-Q1-1-reversed.json"]);
  expect(event("decision-Q1-1-reversed.json")).toMatchObject({
    choice: "search",
    by: "panel picker",
    reversed: "auth",
  });
  expect(settled()!.told).toBe(true);
  // Told is never sent again: not by the next run, nor by a retry of the first request.
  rmSync(join(state, "inbox", "decision-Q1-1-reversed.json"));
  await expireDue(state);
  expect(await settle(state, "r-1", token, "reversed", "search", "panel picker")).toMatchObject({ accepted: true });
  expect(inbox()).toEqual([]);
});
