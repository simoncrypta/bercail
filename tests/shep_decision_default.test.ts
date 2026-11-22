// A two-way door's default (shep/pi/discuss.ts expireDue, which Shep's question
// extension runs as `bercail shep question expire`): the ledger takes Shep's
// recommendation past the deadline, once, and Shep's inbox gets one decision event that
// says it was not the person's pick.
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, expect, test, vi } from "vite-plus/test";

// The live check, as the test sets it: a default runs it before recording. A topic in
// `checks` gets its own.
const check = vi.hoisted(() => ({ status: "fresh", reasons: [] as string[] }));
const checks = vi.hoisted(() => ({}) as Record<string, { status: string; reasons: string[] }>);
vi.mock("../shep/pi/question-target.ts", () => ({
  checkQuestion: async (q: { target: { topic: string } }) => ({
    ...(checks[q.target.topic] ?? check),
    current: { head: null, stagedTree: null },
  }),
}));
// The exit of every child Shep's runtime spawns, listened for at spawn so none is missed.
const spawned = vi.hoisted(() => [] as Promise<unknown>[]);
vi.mock("node:child_process", async (importOriginal) => {
  const real = await importOriginal<typeof import("node:child_process")>();
  const spawn = (...args: Parameters<typeof real.spawn>) => {
    const child = real.spawn(...args);
    spawned.push(new Promise((exited) => child.once("exit", exited)));
    return child;
  };
  return { ...real, spawn };
});
import { closed, expireDue, pick, settle } from "../shep/pi/discuss.ts";
import { claim, eventLine } from "../shep/pi/inbox.ts";
import { decisions } from "../shep/pi/question-cli.ts";
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
  for (const topic of Object.keys(checks)) delete checks[topic];
  spawned.length = 0;
  vi.useFakeTimers({ toFake: ["Date", "setInterval", "clearInterval"] });
  vi.setSystemTime("2026-11-19T12:00:00.000Z");
});
afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllEnvs();
  rmSync(dir, { recursive: true, force: true });
});

const ask = (
  topic = "plan",
  reversible = true,
  prompt = "Which desk starts first?",
  where: { issue?: string; space?: string } = {},
): string => {
  const spec: QuestionSpec = {
    kind: "planning",
    prompt,
    options: ["auth", "search"],
    recommendation: { choice: "auth", why: "it unblocks search" },
    ...(reversible ? { reversible: true as const } : {}),
    origin: { event: "conversation:e1", session: "shep-1", entry: "e1" },
    target: {
      repo: "/r/.git",
      issue: where.issue ?? null,
      topic,
      worktree: "/r",
      desk: null,
      space: where.space ?? null,
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

test("the Decisions block lists each pending card, stale and unavailable ones too, and each default not yet OK'd, never a reversal", async () => {
  const okd = ask("okd", true, "OK'd?");
  const reversed = ask("reversed", true, "Reversed?");
  const open = ask("open", true, "Defaulted?");
  const plain = ask("plain", false, "No deadline?");
  vi.setSystemTime("2026-11-19T12:30:00.000Z");
  await expireDue(state);
  await confirm(state, "ok", okd, "panel picker");
  await settle(state, "rev", reversed, "reversed", "search", "panel picker");
  vi.stubEnv("BERCAIL_SHEP_DECISION_TIMEOUT", "90");
  const later = ask("later", true, "Counts down?");
  vi.stubEnv("BERCAIL_SHEP_DECISION_TIMEOUT", undefined);
  const stale = ask("stale", true, "Stale?");
  const gone = ask("gone", false, "Gone?");
  checks.stale = { status: "stale", reasons: ["head changed"] };
  checks.gone = { status: "unavailable", reasons: ["target unavailable: Question target: worktree is gone"] };
  const { questions } = new QuestionStore(state).snapshot();
  expect(await decisions({ questions }, state)).toBe(
    [
      "Decisions:",
      "- r: Defaulted? · defaulted to auth, waits for your OK or Reverse",
      "- r: No deadline?",
      "- r: Counts down? · two-way door: defaults to auth in 1 h 30 min",
      "- r: Stale? · stale: head changed · two-way door: due in 30 min, but it waits for you while it is stale",
      "- r: Gone? · unavailable: target unavailable: Question target: worktree is gone",
    ].join("\n"),
  );
  // The last card answered or withdrawn: nothing waits.
  const store = new QuestionStore(state);
  await pick(state, "p-plain", plain, "auth", "panel picker");
  await pick(state, "p-later", later, "auth", "panel picker");
  for (const token of [open, stale, gone]) store.withdraw(`w-${token}`, token, "moot");
  expect(await decisions(new QuestionStore(state).snapshot(), state)).toBe("Decisions:\n- nothing");
});

test("the Decisions block names a card by its desk's Herdr space, looked up once per while, else its job or folder", async () => {
  // herdr-app ls knows sp1; hc made sp2 and labelled it; nobody knows sp3. Each logs its call.
  const log = join(dir, "lookups");
  const stand = (name: string, body: string) => {
    writeFileSync(join(dir, name), `#!/bin/sh\nprintf '${name} %s\\n' "$*" >> '${log}'\n${body}\n`, { mode: 0o755 });
    vi.stubEnv(name === "herdr-app" ? "HERDR_APP_BIN" : "HC_BIN", join(dir, name));
  };
  stand("herdr-app", `printf '%s\\n' '{"spaces":[{"id":"sp1","name":"Login_App"}]}'`);
  stand(
    "hc",
    `case "$*" in\n"ls --json --label herdr.space=sp2") echo '{"terminals":[{"address":"t2"}]}' ;;\n` +
      `"get t2 --json") echo '{"labels":{"bercail.space_name":"Export_App"}}' ;;\n*) echo '{"terminals":[]}' ;;\nesac`,
  );
  ask("login", false, "Login first?", { issue: "app-1", space: "sp1" });
  ask("export", false, "Export first?", { issue: "app-2", space: "sp2" });
  ask("closed", false, "Closed space?", { issue: "app-3", space: "sp3" });
  ask("plain", false, "No space?");
  const lookups = () => readFileSync(log, "utf8").trim().split("\n");
  const block = [
    "Decisions:",
    "- Login_App: Login first?",
    "- Export_App: Export first?",
    "- app-3: Closed space?",
    "- r: No space?",
  ].join("\n");
  expect(await decisions(new QuestionStore(state).snapshot(), state)).toBe(block);
  const first = [
    "herdr-app ls",
    "hc ls --json --label herdr.space=sp2",
    "hc get t2 --json",
    "hc ls --json --label herdr.space=sp3",
  ];
  expect(lookups()).toEqual(first);
  // The next settle, a space that is gone included, runs no lookup until the names are old.
  vi.setSystemTime(Date.now() + 10 * 60000 - 1000);
  expect(await decisions(new QuestionStore(state).snapshot(), state)).toBe(block);
  expect(lookups()).toEqual(first);
  vi.setSystemTime(Date.now() + 2000);
  stand("herdr-app", `printf '%s\\n' '{"spaces":[{"id":"sp1","name":"Login-renamed_App"}]}'`);
  expect(await decisions(new QuestionStore(state).snapshot(), state)).toContain("- Login-renamed_App: Login first?");
  expect(lookups()).toHaveLength(first.length * 2);
});

test("a land card waits on the person like any card: listed, by its space, until it is picked", async () => {
  writeFileSync(join(dir, "herdr-app"), `#!/bin/sh\necho '{"spaces":[{"id":"sp1","name":"Login_App"}]}'\n`, {
    mode: 0o755,
  });
  vi.stubEnv("HERDR_APP_BIN", join(dir, "herdr-app"));
  const spec: QuestionSpec = {
    kind: "land",
    prompt: "Land the login fix?",
    options: ["Ship it", "Not yet"],
    origin: { event: "land-1", session: "shep-1", entry: null },
    target: {
      repo: "/r/.git",
      issue: "app-1",
      topic: "land-app-1",
      worktree: "/r.login",
      desk: "t9",
      space: "sp1",
      session: "desk-session",
      action: "land",
      branch: "refs/heads/login",
      head: "a".repeat(40),
      stagedTree: "b".repeat(40),
      base: "a".repeat(40),
      baseRef: "master",
    },
    land: {
      url: "git@github.com:o/app.git",
      github: "o/app",
      registered: true,
      clean: true,
      handoffBranch: "login",
      description: { tree: "b".repeat(40), message: "d".repeat(64) },
      policy: { file: "e".repeat(64), trusted: true, hash: "f".repeat(64) },
      requiredCi: [{ path: ".github/workflows/ci.yml", id: 7 }],
      bercail: "/opt/bercail/bin/bercail",
      review: { required: false, highStakes: [] },
      reviewer: null,
    },
  };
  const token = tokenOf(new QuestionStore(state).create("land-1", spec, () => spec));
  expect(await decisions(new QuestionStore(state).snapshot(), state)).toBe(
    "Decisions:\n- Login_App: Land the login fix?",
  );
  expect(await pick(state, "ship", token, "Ship it", "panel picker")).toMatchObject({ accepted: true });
  expect(await decisions(new QuestionStore(state).snapshot(), state)).toBe("Decisions:\n- nothing");
});

test("a Herdr name that is slow to find, or a name cache that cannot be written, never hides a card", async () => {
  const log = join(dir, "lookups");
  for (const name of ["herdr-app", "hc"]) {
    writeFileSync(join(dir, name), `#!/bin/sh\nprintf '${name}\\n' >> '${log}'\ntrap '' TERM\nexec sleep 30\n`, {
      mode: 0o755,
    });
    vi.stubEnv(name === "herdr-app" ? "HERDR_APP_BIN" : "HC_BIN", join(dir, name));
  }
  ask("login", false, "Login first?", { issue: "app-1", space: "sp1" });
  const started = performance.now();
  expect(await decisions(new QuestionStore(state).snapshot(), state)).toBe("Decisions:\n- app-1: Login first?");
  // One budget for every lookup, well inside the board's 4 seconds, and nothing kept from it.
  expect(performance.now() - started).toBeLessThan(3000);
  expect(existsSync(join(state, "space-names.json"))).toBe(false);
  await decisions(new QuestionStore(state).snapshot(), state);
  expect(readFileSync(log, "utf8").split("herdr-app").length - 1).toBe(2);
  // The window answers, but the cache cannot be written: the card is still named and listed.
  writeFileSync(join(dir, "herdr-app"), `#!/bin/sh\necho '{"spaces":[{"id":"sp1","name":"Login_App"}]}'\n`);
  mkdirSync(join(state, "space-names.json"));
  expect(await decisions(new QuestionStore(state).snapshot(), state)).toBe("Decisions:\n- Login_App: Login first?");
  expect(readdirSync(state).filter((f) => f.startsWith("space-names"))).toEqual(["space-names.json"]);
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
    registerEntryRenderer: () => {},
    sendMessage: (m: unknown) => sent.push(m),
  } as any);
  // Wait for each run's exit, bounded only by the test's timeout: the runtime starts no second run
  // while one is still going, so the timer must fire only after the first has exited.
  const runs = () => readFileSync(log, "utf8").trim().split("\n");
  handlers.session_start!({}, {});
  expect(spawned).toHaveLength(1);
  await spawned[0];
  expect(runs()).toEqual(["shep question expire"]);
  await vi.advanceTimersByTimeAsync(EXPIRE_MS);
  expect(spawned).toHaveLength(2);
  await spawned[1];
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
