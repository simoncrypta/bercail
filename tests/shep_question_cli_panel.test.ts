// Question-cli.ts's panel and the person's picks: the panel, the desk a card binds,
// planning topics, the reply's authority boundary, two-way doors and their defaults,
// pending, and get.
// The fixture is tests/shep_question_cli_fixture.ts.
import { mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { expect, test } from "vite-plus/test";
import { claim, eventLine } from "../shep/pi/inbox.ts";
import {
  dir,
  repo,
  env,
  json,
  git,
  call,
  ok,
  spec,
  terminal,
  record,
  inbox,
  events,
  event,
  pick,
} from "./shep_question_cli_fixture.ts";

test("panel shows each pending question with its live state and size, and answers nothing", () => {
  writeFileSync(
    join(dir, "bin/bercail"),
    `#!/bin/sh\ncase "$1 $2" in\n"policy show") /bin/cat '${dir}/policy.json' ;;\n` +
      `"describe check") printf '{"change":{"files":2,"lines":347,"stakes":"high","review":"required"}}'; exit 1 ;;\n*) exit 2 ;;\nesac\n`,
    { mode: 0o755 },
  );
  const old = ok("create", spec({ requestId: "old" }));
  writeFileSync(join(repo, "file"), "two\n");
  git("add", "file");
  const current = ok("create", spec({ requestId: "current", topic: "login-2" }));
  ok(
    "create",
    spec({ requestId: "plan", kind: "planning", topic: "plan", issue: null, desk: null, base: null, action: null }),
  );
  const before = readFileSync(join(env.BERCAIL_SHEP_STATE!, "questions.json"), "utf8");
  const view = ok("panel");
  expect(view).toMatchObject({ state: env.BERCAIL_SHEP_STATE, at: expect.any(String) });
  expect(view.cards.map((c: any) => [c.token, c.kind, c.status])).toEqual([
    ["Q1@1", "review", "stale"],
    ["Q2@1", "review", "fresh"],
    ["Q3@1", "planning", "fresh"],
  ]);
  expect(view.cards[0].reasons).toContain("stagedTree changed");
  expect(view.cards[1]).toMatchObject({
    prompt: "Review this candidate?",
    options: ["yes", "no"],
    target: { topic: "login-2", space: "sp1", worktree: repo },
    change: { lines: 347, stakes: "high" },
  });
  expect(view.cards[2].change).toBeNull();
  terminal({ state: "dead" });
  expect(ok("panel").cards.map((c: any) => [c.status, c.warnings])).toEqual([
    ["stale", ["desk t9 is gone or not live at its recorded address"]],
    ["fresh", ["desk t9 is gone or not live at its recorded address"]],
    ["fresh", []],
  ]);
  expect(readFileSync(join(env.BERCAIL_SHEP_STATE!, "questions.json"), "utf8")).toBe(before);
  expect([old.id, current.id]).toEqual(["Q1", "Q2"]);
});

// bercail-shhh's cases: a job whose desk is gone or not its own still reaches the panel,
// bound to its repo and issue, with the desk problem on the card; the pick re-reads it.
test.each([
  [
    "1, a background Shep terminal with no desk record",
    () => {
      rmSync(join(env.XDG_STATE_HOME!, "bercail/desk-sessions/t9.json"));
      terminal({ labels: { "bercail.role": "shep-bg", "bercail.issue": "app-1" } });
    },
    {},
    "desk t9 has no desk session record",
  ],
  ["2, a desk in another folder", () => terminal({ cwd: dir }), {}, "desk t9 is not in the target worktree"],
  [
    "3, a space whose live terminal belongs to another job",
    () => terminal({ labels: { "bercail.role": "agent", "bercail.issue": "other-1", "bercail.space": "sp1" } }),
    {},
    "desk t9 belongs to another job",
  ],
  ["4, a job question with no desk", () => {}, { desk: null }, "no desk: bound to the repo and issue only"],
])("case %s reaches the panel with a warning and can be answered", (_name, arrange, extra, warning) => {
  arrange();
  const q = ok("create", spec(extra));
  expect(q.target).toMatchObject({
    repo: join(repo, ".git"),
    issue: "app-1",
    worktree: repo,
    space: null,
    session: null,
    stagedTree: git("write-tree"),
  });
  expect(ok("panel").cards).toMatchObject([{ token: "Q1@1", status: "fresh", reasons: [], warnings: [warning] }]);
  expect(pick("p1", "yes")).toMatchObject({ accepted: true, question: { status: "answered" } });
});

test.each([
  ["another space", { labels: { "bercail.role": "agent", "bercail.issue": "app-1", "bercail.space": "sp2" } }, "space"],
  [
    "a sibling rather than a desk",
    { labels: { "bercail.role": "bstack-builder", "bercail.issue": "app-1", "bercail.space": "sp1" } },
    "another job",
  ],
  ["a gone terminal", { state: "finished" }, "gone"],
  ["a missing session", { records: {} }, "session could not be verified"],
  ["a terminal alias", { address: "t10" }, "gone"],
])("warns of %s at the named desk and binds none of its session", (_name, extra, warning) => {
  terminal(extra);
  const q = ok("create", spec());
  expect(q.target).toMatchObject({ desk: "t9", space: null, session: null });
  const check = ok("check", undefined, [`${q.id}@${q.revision}`]);
  expect(check).toMatchObject({ status: "fresh", authority: false });
  expect(check.warnings).toEqual([expect.stringContaining(warning)]);
});

test("a desk hc cannot read, or a null desk record, is a warning, not a refusal", () => {
  rmSync(join(dir, "terminal.json"));
  const q = ok("create", spec());
  expect(ok("check", undefined, [`${q.id}@${q.revision}`]).warnings).toEqual(["desk t9 is gone"]);
  json(join(env.XDG_STATE_HOME!, "bercail/desk-sessions/t9.json"), null);
  expect(ok("check", undefined, [`${q.id}@${q.revision}`]).warnings).toEqual(["desk t9 has no desk session record"]);
});

test("an idle desk with null hc records is verified by its exact live process claim", () => {
  const stat = readFileSync(`/proc/${process.pid}/stat`, "utf8");
  const ticks = stat
    .slice(stat.lastIndexOf(")") + 2)
    .trim()
    .split(/\s+/)[19];
  const claims = join(env.XDG_RUNTIME_DIR!, "bercail/open-sessions");
  mkdirSync(claims, { recursive: true });
  json(join(claims, `${process.pid}.json`), { pid: process.pid, start_ticks: ticks, sessions: ["desk-session"] });
  record({ pid: process.pid });
  terminal({ records: null, foreground: { pid: process.pid, cwd: repo } });
  const q = ok("create", spec());
  expect(q.target.session).toBe("desk-session");
  expect(ok("check", undefined, [`${q.id}@${q.revision}`])).toMatchObject({ fresh: true, warnings: [] });
});

test("an old process claim cannot prove a session after PID reuse", () => {
  const claims = join(env.XDG_RUNTIME_DIR!, "bercail/open-sessions");
  mkdirSync(claims, { recursive: true });
  json(join(claims, `${process.pid}.json`), { pid: process.pid, start_ticks: "0", sessions: ["desk-session"] });
  record({ pid: process.pid });
  terminal({ records: null, foreground: { pid: process.pid, cwd: repo } });
  const q = ok("create", spec());
  expect(q.target.session).toBeNull();
  expect(ok("check", undefined, ["Q1@1"]).warnings).toEqual(["desk t9's Pi session could not be verified"]);
});

test("a desk on a replaced session is said on the card and never rebound", () => {
  const q = ok("create", spec());
  record({ session: "replacement" });
  terminal({ records: { replacement: { app: "pi" } } });
  const check = ok("check", undefined, [`${q.id}@${q.revision}`]);
  expect(check).toMatchObject({ fresh: true, current: { session: "replacement" } });
  expect(check.warnings).toEqual(["desk t9 runs another session than when Shep asked"]);
  expect(ok("json").questions[0].target.session).toBe("desk-session");
  rmSync(join(env.XDG_STATE_HOME!, "bercail/desk-sessions/t9.json"));
  expect(ok("check", undefined, [`${q.id}@${q.revision}`]).warnings).toEqual(["desk t9 has no desk session record"]);
});

test("planning topics need no desk, and a job's planning question without one says so", () => {
  const q = ok("create", spec({ kind: "planning", issue: null, desk: null, base: null, action: null }));
  expect(q.target.desk).toBeNull();
  expect(q.target.session).toBeNull();
  expect(ok("check", undefined, ["Q1@1"]).warnings).toEqual([]);
  ok("create", spec({ requestId: "other", topic: "job-plan", kind: "planning", desk: null }));
  expect(ok("check", undefined, ["Q2@1"]).warnings).toEqual(["no desk: bound to the repo and issue only"]);
});

test.each(["approved", "confirmed", "verified", "authority"])(
  "reply rejects caller-supplied %s rather than accepting a verification flag",
  (field) => {
    const q = ok("create", spec());
    const result = call("reply", {
      requestId: "forged",
      token: `${q.id}@${q.revision}`,
      answer: "yes",
      source: "hc",
      [field]: true,
    });
    expect(result.status).not.toBe(0);
    expect(result.stderr).toMatch(/fields/);
  },
);

test("text listing, explicit thread and injected reply retain the unverified authority boundary", () => {
  const q = ok("create", spec());
  const token = `${q.id}@${q.revision}`;
  const reply = ok("reply", {
    requestId: "reply-one",
    token,
    answer: "yes",
    source: "hc:user",
  });
  expect(reply.question.proposals[0]).toMatchObject({ verified: false, answer: "yes", source: "hc:user" });
  expect(ok("json").questions[0].status).toBe("pending");
  ok("thread", undefined, ["login"]);
  expect(call("list").stdout).toContain(token);
  expect(ok("check", undefined, [token]).authority).toBe(false);
  expect(readFileSync(join(dir, "argv"), "utf8")).not.toMatch(/hc (send|keys|run)|merge|push/);
});

test("the person's pick records the choice once against the checked candidate, and Shep gets one event", () => {
  ok("create", spec({ brief: "Ready to land.", recommendation: { choice: "yes", why: "tests pass" } }));
  expect(pick("p1", "yes")).toMatchObject({ accepted: true, question: { status: "answered" } });
  const [q] = ok("json").questions;
  expect(q.answer).toEqual({
    requestId: "p1",
    choice: "yes",
    source: "panel picker",
    at: expect.any(String),
    head: git("rev-parse", "HEAD"),
    stagedTree: git("write-tree"),
  });
  expect(events()).toEqual(["decision-Q1-1.json"]);
  expect(event("decision-Q1-1.json")).toMatchObject({
    source: "bercail",
    kind: "decision",
    event_id: "decision:Q1-1",
    question: { token: "Q1@1", prompt: "Review this candidate?", topic: "login" },
    choice: "yes",
    by: "panel picker",
    summary: null,
  });
  // A retry is the same pick; a second pick, a different choice or not, is refused.
  const delivered = join(env.BERCAIL_SHEP_STATE!, "delivered");
  mkdirSync(delivered);
  expect(claim(inbox(), delivered)).toHaveLength(1);
  expect(pick("p1", "yes")).toMatchObject({ accepted: true });
  expect(pick("p2", "no")).toMatchObject({ accepted: false, reason: "question is answered" });
  expect(pick("p3", "yes", "Q1@1", "discuss picker")).toMatchObject({ accepted: false });
  expect(claim(inbox(), delivered)).toHaveLength(0);
  expect(readdirSync(delivered)).toEqual(["decision-Q1-1.json"]);
  expect(ok("json").questions[0].answer.requestId).toBe("p1");
  // Closing a Discuss modal after the pick adds nothing: the pick said it.
  expect(ok("closed", undefined, ["Q1@1", "o1"])).toEqual({ told: false });
  expect(events()).toEqual([]);
  expect(eventLine(JSON.parse(readFileSync(join(delivered, "decision-Q1-1.json"), "utf8")))).toMatch(
    /^- The person picked "yes" in the panel picker for Q1@1 "Review this candidate\?" \(topic login\)\. Nothing was discussed\. \[event decision:Q1-1\]$/,
  );
  // Shep's every turn shows the answer from the ledger, whatever became of the event.
  expect(call("list").stdout).toMatch(/Q1@1 Review this candidate\? -> yes \(panel picker, /);
});

test("a two-way door counts down on the panel, defaults by expire past its deadline, and stays until the person says OK", () => {
  const plan = (extra: Record<string, unknown> = {}) =>
    spec({
      kind: "planning",
      prompt: "Which desk starts first?",
      options: ["auth", "search"],
      recommendation: { choice: "auth", why: "it unblocks search" },
      reversible: true,
      issue: null,
      desk: null,
      base: null,
      action: null,
      ...extra,
    });
  const refused = call(
    "create",
    spec({ requestId: "lgtm", reversible: true, recommendation: { choice: "yes", why: "w" } }),
  );
  expect(refused.stderr).toMatch(/one-way door \(an LGTM: "a review question"\)/);
  const q = ok("create", plan());
  expect(Date.parse(q.deadline) - Date.parse(q.createdAt)).toBe(30 * 60000);
  ok("create", plan({ requestId: "plain", topic: "plain", reversible: false }));
  let cards = ok("panel").cards;
  expect(cards.map((c: any) => [c.token, c.status, c.deadline, c.defaulted])).toEqual([
    ["Q1@1", "fresh", q.deadline, null],
    ["Q2@1", "fresh", null, null],
  ]);
  expect(ok("expire")).toEqual([]);
  expect(events()).toEqual([]);
  // Time passes with nothing running: the ledger's times are an hour back.
  const file = join(env.BERCAIL_SHEP_STATE!, "questions.json");
  const ledger = JSON.parse(readFileSync(file, "utf8"));
  const hourAgo = Date.now() - 3600000;
  ledger.questions[0].createdAt = new Date(hourAgo).toISOString();
  ledger.questions[0].deadline = new Date(hourAgo + 30 * 60000).toISOString();
  writeFileSync(file, JSON.stringify(ledger));
  // The panel only reads: it shows the due card; Shep's runtime runs expire. Past the
  // deadline the person's pick is refused: the door takes the recommendation.
  expect(pick("late", "search")).toMatchObject({
    accepted: false,
    reason: "past its deadline: it takes Shep's recommendation, auth",
  });
  const due = readFileSync(file, "utf8");
  expect(ok("panel").cards[0]).toMatchObject({ status: "fresh", defaulted: null });
  expect(readFileSync(file, "utf8")).toBe(due);
  expect(ok("expire")).toEqual(["Q1@1"]);
  // Shep checks it before acting: unchanged, it is fresh.
  expect(ok("check", undefined, ["Q1@1"])).toMatchObject({
    status: "fresh",
    reasons: [],
    door: { door: "two-way", row: "a planning pick" },
  });
  cards = ok("panel").cards;
  expect(cards[0]).toMatchObject({ status: "fresh", defaulted: { choice: "auth" }, reasons: [] });
  expect(cards[1].status).toBe("fresh");
  expect(ok("json").questions[0].answer).toMatchObject({ choice: "auth", source: "default after timeout" });
  expect(events()).toEqual(["decision-Q1-1.json"]);
  expect(event("decision-Q1-1.json")).toMatchObject({ choice: "auth", by: "default after timeout" });
  // Once: the next run records nothing more, and nobody picks over it.
  const before = readFileSync(file, "utf8");
  expect(ok("expire")).toEqual([]);
  expect(readFileSync(file, "utf8")).toBe(before);
  expect(pick("p1", "search")).toMatchObject({ accepted: false, reason: "question is answered" });
  expect(
    call("answer", { requestId: "p2", token: "Q2@1", choice: "auth", source: "default after timeout" }).stderr,
  ).toMatch(/unknown answer source/);
  // A day after the default, the card still waits for the person.
  const old = JSON.parse(before);
  old.questions[0].answer.at = new Date(Date.now() - 25 * 3600000).toISOString();
  old.questions[0].createdAt = new Date(Date.now() - 27 * 3600000).toISOString();
  old.questions[0].deadline = new Date(Date.now() - 26 * 3600000).toISOString();
  writeFileSync(file, JSON.stringify(old));
  expect(ok("panel").cards.map((c: any) => [c.token, c.defaulted?.choice ?? null])).toEqual([
    ["Q1@1", "auth"],
    ["Q2@1", null],
  ]);
  // The person's OK: a pick's fields, with an outcome in place of a choice.
  expect(
    call("answer", { requestId: "ok", token: "Q1@1", choice: "auth", source: "panel picker", outcome: "ok" }).stderr,
  ).toMatch(/answer fields must be/);
  expect(ok("answer", { requestId: "ok", token: "Q1@1", source: "panel picker", outcome: "ok" })).toMatchObject({
    accepted: true,
    question: {
      answer: { source: "default after timeout" },
      settled: { outcome: "ok", choice: "auth", source: "panel picker" },
    },
  });
  expect(ok("panel").cards.map((c: any) => c.token)).toEqual(["Q2@1"]);
  expect(event("decision-Q1-1-ok.json")).toMatchObject({ choice: "auth", by: "panel picker", confirmed: true });
  // Shep's every turn lists it with the person's picks, as a confirmed default.
  const list = call("list").stdout;
  expect(list).toMatch(
    /Answered by the person's pick[^\n]*\nQ1@1 Which desk starts first\? -> auth \(confirmed default, panel picker, /,
  );
  expect(list).not.toMatch(/Defaulted to your recommendation/);
});

test("a reversed default stays on the panel as reversed until Shep withdraws it", () => {
  ok(
    "create",
    spec({
      kind: "planning",
      prompt: "Which desk starts first?",
      options: ["auth", "search"],
      recommendation: { choice: "auth", why: "it unblocks search" },
      reversible: true,
      issue: null,
      desk: null,
      base: null,
      action: null,
    }),
  );
  const file = join(env.BERCAIL_SHEP_STATE!, "questions.json");
  const ledger = JSON.parse(readFileSync(file, "utf8"));
  ledger.questions[0].createdAt = new Date(Date.now() - 3600000).toISOString();
  ledger.questions[0].deadline = new Date(Date.now() - 1800000).toISOString();
  ledger.requests = [];
  writeFileSync(file, JSON.stringify(ledger));
  expect(ok("expire")).toEqual(["Q1@1"]);
  expect(call("answer", { requestId: "r", token: "Q1@1", source: "panel picker", outcome: "undo" }).stderr).toMatch(
    /answer fields must be/,
  );
  expect(
    ok("answer", { requestId: "r", token: "Q1@1", choice: "search", source: "panel picker", outcome: "reversed" }),
  ).toMatchObject({ accepted: true, question: { settled: { outcome: "reversed", choice: "search" } } });
  expect(event("decision-Q1-1-reversed.json")).toMatchObject({ choice: "search", reversed: "auth" });
  expect(ok("panel").cards).toMatchObject([
    { token: "Q1@1", defaulted: { choice: "auth" }, reversed: { choice: "search" } },
  ]);
  expect(call("list").stdout).toMatch(/Q1@1 Which desk starts first\? -> reversed auth to search \(panel picker, /);
  ok("withdraw", { requestId: "w", token: "Q1@1", reason: "started search instead" });
  expect(ok("panel").cards).toEqual([]);
  expect(ok("json").questions[0]).toMatchObject({ status: "withdrawn", settled: { choice: "search" } });
});

// A commit card on the staged tree, defaulted: its deadline put an hour back, then expire.
function defaultedCommit() {
  writeFileSync(join(repo, "file"), "two\n");
  git("add", "file");
  ok(
    "create",
    spec({
      kind: "action",
      action: "commit",
      prompt: "Commit the staged change?",
      options: ["Commit it", "Not yet"],
      recommendation: { choice: "Commit it", why: "tests pass" },
      reversible: true,
    }),
  );
  const file = join(env.BERCAIL_SHEP_STATE!, "questions.json");
  const ledger = JSON.parse(readFileSync(file, "utf8"));
  ledger.questions[0].createdAt = new Date(Date.now() - 3600000).toISOString();
  ledger.questions[0].deadline = new Date(Date.now() - 1800000).toISOString();
  ledger.requests = [];
  writeFileSync(file, JSON.stringify(ledger));
  expect(ok("expire")).toEqual(["Q1@1"]);
}

test("a defaulted commit card, after its own commit of the staged tree, accepts the person's OK", () => {
  defaultedCommit();
  git("commit", "-qm", "the default's commit");
  expect(ok("panel").cards).toMatchObject([{ token: "Q1@1", status: "fresh", defaulted: { choice: "Commit it" } }]);
  expect(ok("answer", { requestId: "ok", token: "Q1@1", source: "panel picker", outcome: "ok" })).toMatchObject({
    accepted: true,
    question: { settled: { outcome: "ok", head: git("rev-parse", "HEAD") } },
  });
  expect(ok("panel").cards).toEqual([]);
});

test("a defaulted commit card its action moved to another branch takes no OK, and the person's Close takes it off", () => {
  defaultedCommit();
  // The default's commit went on a stacked branch: more than one commit of the tree on the asked HEAD.
  git("switch", "-qc", "stacked");
  git("commit", "-qm", "the default's commit, stacked");
  expect(ok("panel").cards).toMatchObject([{ token: "Q1@1", status: "stale", defaulted: { choice: "Commit it" } }]);
  expect(ok("answer", { requestId: "ok", token: "Q1@1", source: "panel picker", outcome: "ok" })).toMatchObject({
    accepted: false,
    reason: expect.stringMatching(/^changed since it defaulted: branch changed/),
  });
  expect(
    call("answer", { requestId: "x", token: "Q1@1", choice: "Not yet", source: "panel picker", outcome: "closed" })
      .stderr,
  ).toMatch(/answer fields must be/);
  // The panel's result shape: accepted, as the panel reads it.
  expect(ok("answer", { requestId: "x", token: "Q1@1", source: "panel picker", outcome: "closed" })).toMatchObject({
    accepted: true,
    question: {
      status: "withdrawn",
      answer: { source: "default after timeout" },
      withdrawal: { reason: "closed by the person on the panel", source: "panel picker" },
    },
  });
  expect(ok("panel").cards).toEqual([]);
  expect(ok("pending").pending).toEqual([]);
  expect(event("decision-Q1-1-closed.json")).toMatchObject({
    choice: null,
    by: "panel picker",
    closed: "defaulted",
    defaulted: "Commit it",
  });
});

test("pending lists only the pending cards and the defaults not yet OK'd or reversed", () => {
  const plan = (topic: string, extra: Record<string, unknown> = {}) =>
    ok(
      "create",
      spec({
        requestId: topic,
        topic,
        kind: "planning",
        prompt: `Which desk starts first for ${topic}?`,
        options: ["auth", "search"],
        recommendation: { choice: "auth", why: "it unblocks search" },
        issue: null,
        desk: null,
        base: null,
        action: null,
        ...extra,
      }),
    );
  plan("pending");
  plan("picked");
  plan("withdrawn");
  plan("revised");
  for (const topic of ["defaulted", "confirmed", "reversed"]) plan(topic, { reversible: true });
  pick("p", "search", "Q2@1");
  ok("withdraw", { requestId: "w", token: "Q3@1", reason: "moot" });
  ok(
    "revise",
    spec({
      requestId: "revise",
      token: "Q4@1",
      topic: "revised",
      kind: "planning",
      prompt: "Which desk starts first, now?",
      options: ["auth", "search"],
      issue: null,
      desk: null,
      base: null,
      action: null,
    }),
  );
  const file = join(env.BERCAIL_SHEP_STATE!, "questions.json");
  const ledger = JSON.parse(readFileSync(file, "utf8"));
  for (const q of ledger.questions.filter((q: any) => q.deadline)) {
    q.createdAt = new Date(Date.now() - 3600000).toISOString();
    q.deadline = new Date(Date.now() - 1800000).toISOString();
  }
  ledger.requests = [];
  writeFileSync(file, JSON.stringify(ledger));
  expect(ok("expire")).toEqual(["Q5@1", "Q6@1", "Q7@1"]);
  ok("answer", { requestId: "ok", token: "Q6@1", source: "panel picker", outcome: "ok" });
  ok("answer", { requestId: "r", token: "Q7@1", source: "panel picker", outcome: "reversed" });

  const { pending, landing, ...rest } = ok("pending");
  expect(rest).toEqual({});
  expect(landing).toEqual([]);
  expect(pending.map((q: any) => [`${q.id}@${q.revision}`, q.status, q.answer?.choice ?? null])).toEqual([
    ["Q1@1", "pending", null],
    ["Q5@1", "answered", "auth"],
    ["Q4@2", "pending", null],
  ]);
  expect(pending[0]).toEqual(ok("json").questions[0]);
  expect(ok("json").questions).toHaveLength(8);
});

test("get prints the exact revision and refuses an unknown one", () => {
  ok("create", spec());
  ok("revise", spec({ requestId: "revise", token: "Q1@1", prompt: "Review this other candidate?" }));
  const [first, second] = ok("json").questions;
  expect(ok("get", undefined, ["Q1@1"])).toEqual(first);
  expect(ok("get", undefined, ["Q1@2"])).toEqual(second);
  expect(second).toMatchObject({ revision: 2, prompt: "Review this other candidate?", status: "pending" });
  for (const [args, error] of [
    [["Q1@3"], /unknown question revision/],
    [["Q2@1"], /unknown question revision/],
    [["Q1"], /explicit Qn@revision/],
    [[], /explicit Qn@revision/],
  ] as const) {
    const result = call("get", undefined, [...args]);
    expect([result.status, result.stdout]).toEqual([1, ""]);
    expect(result.stderr).toMatch(error);
  }
});

test("a commit is a two-way door; a merge is one only while the repo's policy says merge_reversible", () => {
  const act = (requestId: string, action: string, prompt: string) =>
    call(
      "create",
      spec({
        requestId,
        kind: "action",
        action,
        prompt,
        topic: requestId,
        reversible: true,
        recommendation: { choice: "yes", why: "w" },
      }),
    );
  const policy = (extra: Record<string, unknown>) =>
    json(join(dir, "policy.json"), {
      repo,
      root: repo,
      sha256: "p",
      trusted: true,
      policy: { integrate: "direct", ...extra },
    });
  expect(JSON.parse(act("commit", "commit", "Commit the staged change?").stdout).deadline).toEqual(expect.any(String));
  for (const value of [undefined, false]) {
    policy(value === undefined ? {} : { merge_reversible: value });
    expect(act(`merge-${value}`, "merge", "Land it?").stderr).toMatch(
      /one-way door \(a merge where the policy does not say merge_reversible: "merge"\)/,
    );
  }
  expect(act("cmd", "git push -f origin main", "Land it?").stderr).toMatch(
    /one-way door \(an action no two-way row names/,
  );
  policy({ merge_reversible: true });
  const merge = JSON.parse(act("merge-true", "merge", "Land it?").stdout);
  expect(merge.deadline).toEqual(expect.any(String));
  // Revoked before its deadline: the panel promises no default for the merge.
  policy({});
  expect(ok("panel").cards.map((c: any) => [c.token, c.deadline === null])).toEqual([
    ["Q1@1", false],
    ["Q2@1", true],
  ]);
  // Past the deadline, the policy is read again: untrusted or turned off, it waits.
  const file = join(env.BERCAIL_SHEP_STATE!, "questions.json");
  const ledger = JSON.parse(readFileSync(file, "utf8"));
  for (const q of ledger.questions) {
    q.createdAt = new Date(Date.now() - 3600000).toISOString();
    q.deadline = new Date(Date.now() - 1800000).toISOString();
  }
  writeFileSync(file, JSON.stringify(ledger));
  policy({});
  expect(ok("expire")).toEqual(["Q1@1"]);
  policy({ merge_reversible: true });
  expect(ok("expire")).toEqual(["Q2@1"]);
  // Turned off after the default: the check says the door is one-way now, so Shep does not act.
  policy({});
  expect(ok("check", undefined, ["Q2@1"])).toMatchObject({
    status: "fresh",
    door: { door: "one-way", row: "a merge where the policy does not say merge_reversible" },
  });
});
