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
import { closed, expireDue, pick } from "../shep/pi/discuss.ts";
import { claim, eventLine } from "../shep/pi/inbox.ts";
import register, { EXPIRE_MS } from "../shep/pi/question-commands.ts";
import { QuestionStore, tokenOf, type QuestionSpec } from "../shep/pi/questions.ts";

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
    '- Nobody picked by the deadline: the two-way door defaulted to your recommendation "auth" (default after timeout, not the person\'s choice; never an LGTM or reviewer; run question check before you act) for Q1@1 "Which desk starts first?" (topic plan). Nothing was discussed. [event decision:Q1-1]',
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
