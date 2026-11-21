import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { afterEach, beforeEach, describe, expect, test, vi } from "vite-plus/test";
import { door, QuestionStore, projection, tokenOf, type QuestionSpec } from "../shep/pi/questions.ts";

const worker = fileURLToPath(new URL("./shep_questions_worker.ts", import.meta.url));
const flock = spawnSync("which", ["flock"], { encoding: "utf8" }).stdout.trim();
const resolveSpec = (fields: QuestionSpec): QuestionSpec => fields;
const fields = (topic = "alpha", kind: QuestionSpec["kind"] = "planning"): QuestionSpec => ({
  kind,
  prompt: `Choose ${topic}?`,
  options: ["yes", "no"],
  origin: { event: `event-${topic}`, session: "shep-session", entry: null },
  target: {
    repo: "/canonical/main",
    issue: "app-1",
    topic,
    worktree: "/canonical/main.topic",
    desk: "desk-1",
    space: "space-1",
    session: "desk-session",
    action: "review staged work",
    head: "a".repeat(40),
    stagedTree: "b".repeat(40),
    base: "c".repeat(40),
    baseRef: "master",
  },
});

describe("durable targeted questions", () => {
  let dir: string;
  let state: string;
  let store: QuestionStore;
  const children: ChildProcess[] = [];
  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "shep-questions-"));
    for (const key of Object.keys(process.env))
      if (/^(HC_|HERDR_|BERCAIL_|BEADS_|BD_)/.test(key) || key === "BASH_ENV") vi.stubEnv(key, undefined);
    for (const key of [
      "HOME",
      "XDG_CONFIG_HOME",
      "XDG_STATE_HOME",
      "XDG_DATA_HOME",
      "XDG_CACHE_HOME",
      "XDG_RUNTIME_DIR",
      "TMPDIR",
    ]) {
      const path = join(dir, key);
      mkdirSync(path);
      vi.stubEnv(key, path);
    }
    const bin = join(dir, "bin");
    mkdirSync(bin);
    for (const name of ["hc", "gh", "bd", "pi", "curl", "notify-send", "git"])
      writeFileSync(join(bin, name), "#!/bin/sh\nexit 97\n", { mode: 0o700 });
    if (!flock) throw new Error("These OS lock tests require flock, as does the store");
    writeFileSync(join(bin, "flock"), `#!/bin/sh\nprintf 'flock\\n' >> "$HOME/flock.log"\nexec '${flock}' "$@"\n`, {
      mode: 0o700,
    });
    vi.stubEnv("PATH", bin);
    vi.stubEnv("TZ", "UTC");
    vi.stubEnv("LC_ALL", "C");
    state = join(dir, "state");
    store = new QuestionStore(state);
    vi.useFakeTimers({ toFake: ["Date"] });
    vi.setSystemTime("2026-11-14T12:00:00.000Z");
  });
  afterEach(() => {
    for (const child of children.splice(0)) if (child.exitCode === null) child.kill("SIGKILL");
    vi.useRealTimers();
    vi.unstubAllEnvs();
    rmSync(dir, { recursive: true, force: true });
  });

  function start(mode: string, input: unknown) {
    const child = spawn(process.execPath, [worker, state, mode, JSON.stringify(input)], {
      stdio: ["pipe", "pipe", "pipe"],
      env: process.env,
    });
    children.push(child);
    let output = "";
    let errors = "";
    const marker = mode.startsWith("crash-") ? "commit-boundary\n" : "ready\n";
    const ready = new Promise<void>((resolve, reject) => {
      child.stdout!.on("data", (chunk) => {
        output += chunk.toString();
        if (output.includes(marker)) resolve();
      });
      child.on("error", reject);
      child.on("exit", () => {
        if (!output.includes(marker)) reject(new Error(`worker exited before ready: ${errors}`));
      });
    });
    child.stderr!.on("data", (chunk) => {
      errors += chunk.toString();
    });
    const done = new Promise<void>((resolve, reject) => {
      child.on("error", reject);
      child.on("exit", (code, signal) =>
        code === 0 || signal === "SIGKILL" ? resolve() : reject(new Error(`worker exit ${code}: ${errors}`)),
      );
    });
    // Start observing both promises immediately, even when startup fails.
    void done.catch(() => {});
    return { child, ready, done };
  }

  test("interleaved topics and replies never change explicit selection, even after restart", () => {
    const a = store.create("a", fields(), resolveSpec);
    store.select("alpha");
    const b = store.create("b", fields("beta"), resolveSpec);
    store.propose("reply", tokenOf(a), "yes", "text-command");
    expect(new QuestionStore(state).snapshot()).toMatchObject({
      selected: "alpha",
      questions: [{ id: "Q1" }, { id: "Q2" }],
    });
    expect(b.target.topic).toBe("beta");
    expect(() => store.select("unknown")).toThrow(/unknown topic/);
    store.select(null);
    expect(store.snapshot().selected).toBeNull();
    expect(readFileSync(join(process.env.HOME!, "flock.log"), "utf8")).toContain("flock");
  });

  test("injected sources and a claimed trusted boolean cannot confer authority", () => {
    const q = store.create("q", fields("review", "review"), resolveSpec);
    const result = store.propose("injected", tokenOf(q), "LGTM", "trusted-human: hc injected user-role");
    expect(result.accepted).toBe(true);
    expect(result.question.status).toBe("pending");
    expect(result.question.proposals).toEqual([
      {
        requestId: "injected",
        answer: "LGTM",
        source: "trusted-human: hc injected user-role",
        at: "2026-11-14T12:00:00.000Z",
        verified: false,
        accepted: true,
      },
    ]);
    expect(() => store.create("forged", { ...fields(), trusted: true } as any, resolveSpec)).toThrow(/invalid fields/);
    expect(new QuestionStore(state).snapshot().questions[0].status).toBe("pending");
  });

  test("a candidate revision invalidates delayed replies and preserves rejected history", () => {
    const original = fields("review", "review");
    const a = store.create("a", original, resolveSpec);
    store.propose("first", tokenOf(a), "yes", "text");
    const next = store.revise(
      "rev",
      tokenOf(a),
      {
        ...original,
        target: { ...original.target, stagedTree: "d".repeat(40) },
      },
      resolveSpec,
    );
    const late = store.propose("late", tokenOf(a), "yes", "text");
    expect(late).toMatchObject({ accepted: false, reason: "stale or closed question revision" });
    expect(store.snapshot().questions).toMatchObject([
      { id: "Q1", revision: 1, status: "superseded", proposals: [{ accepted: true }, { accepted: false }] },
      { id: "Q1", revision: 2, status: "pending", proposals: [] },
    ]);
    expect(tokenOf(next)).toBe("Q1@2");
    expect(() => store.revise("stale", tokenOf(a), original, resolveSpec)).toThrow(/stale/);
  });

  test.each(["Q1", "yes", "Q1@0", "Q01@1", "Q1@01", "Q1@1 extra", "Q1@1\n", "Q2@1"])(
    "reply token %j cannot guess a target",
    (token) => {
      store.create("a", fields(), resolveSpec);
      expect(() => store.propose("r", token, "yes", "text")).toThrow(/token|required|unknown/);
      expect(store.snapshot().questions[0].proposals).toEqual([]);
    },
  );

  test("duplicate request replay survives restart and rejects any changed payload", () => {
    const a = store.create("a", fields(), resolveSpec);
    const token = tokenOf(a);
    expect(store.create("a", fields(), resolveSpec)).toEqual(a);
    const first = store.propose("reply", token, "yes", "text");
    const restarted = new QuestionStore(state);
    expect(restarted.propose("reply", token, "yes", "text")).toEqual({ ...first, duplicate: true });
    for (const [answer, source] of [
      ["no", "text"],
      ["yes", "other"],
    ])
      expect(() => restarted.propose("reply", token, answer, source)).toThrow(/request id reused/);
    expect(() => restarted.create("reply", fields(), resolveSpec)).toThrow(/request id reused/);
    expect(() => restarted.create("a", fields("different"), resolveSpec)).toThrow(/request id reused/);
    expect(restarted.snapshot().questions).toHaveLength(1);
    expect(restarted.snapshot().questions[0].proposals).toHaveLength(1);
  });

  test("create receipt fingerprints logical intent and never resolves matching or conflicting replays", () => {
    const intent = { topic: "alpha", prompt: "Choose?" };
    const first = store.create("lazy", intent, ({ topic, prompt }) => ({ ...fields(topic), prompt }));
    const saved = readFileSync(join(state, "questions.json"), "utf8");
    const unavailable = () => {
      throw new Error("target disappeared");
    };
    const restarted = new QuestionStore(state);
    expect(restarted.create("lazy", { prompt: "Choose?", topic: "alpha" }, unavailable)).toEqual(first);
    expect(() => restarted.create("lazy", { ...intent, prompt: "Changed?" }, unavailable)).toThrow(/request id reused/);
    expect(readFileSync(join(state, "questions.json"), "utf8")).toBe(saved);
  });

  test("failed resolution or an invalid resolved spec leaves no question or receipt", () => {
    const intent = { topic: "alpha" };
    expect(() =>
      store.create("resolve", intent, () => {
        throw new Error("target unavailable");
      }),
    ).toThrow(/target unavailable/);
    expect(() => store.create("resolve", intent, () => ({ ...fields(), prompt: "" }))).toThrow(/nonempty/);
    const first = store.create("resolve", intent, ({ topic }) => fields(topic));
    expect(store.snapshot().questions).toEqual([first]);
  });

  test("revision request replay is idempotent even after a subsequent revision", () => {
    const initial = fields();
    const q = store.create("q", initial, resolveSpec);
    const changed = { ...initial, prompt: "Changed intent?" };
    const rev = store.revise("rev", tokenOf(q), changed, resolveSpec);
    store.revise("rev2", tokenOf(rev), { ...changed, prompt: "Changed again?" }, resolveSpec);
    expect(new QuestionStore(state).revise("rev", tokenOf(q), changed, resolveSpec)).toEqual(rev);
    expect(() => store.revise("rev", tokenOf(q), initial, resolveSpec)).toThrow(/request id reused/);
    expect(store.snapshot().questions.map((q) => [tokenOf(q), q.status])).toEqual([
      ["Q1@1", "superseded"],
      ["Q1@2", "superseded"],
      ["Q1@3", "pending"],
    ]);
  });

  test("repeated answers are harmless and conflicts are retained without replacing the first", () => {
    const q = store.create("a", fields(), resolveSpec);
    const token = tokenOf(q);
    store.propose("yes", token, "yes", "text");
    expect(store.propose("again", token, "yes", "agent")).toMatchObject({ accepted: true, duplicate: true });
    expect(store.propose("no", token, "no", "text")).toMatchObject({
      accepted: false,
      duplicate: false,
      reason: expect.stringContaining("conflicting"),
    });
    expect(store.snapshot().questions[0]).toMatchObject({
      status: "pending",
      proposals: [
        { answer: "yes", verified: false, accepted: true },
        { answer: "yes", verified: false, accepted: true },
        { answer: "no", verified: false, accepted: false },
      ],
    });
  });

  test.each(["repo", "issue", "topic"] as const)("revising %s cannot cross-route a stable question", (key) => {
    const spec = fields();
    const q = store.create("a", spec, resolveSpec);
    expect(() =>
      store.revise(
        "rev",
        tokenOf(q),
        {
          ...spec,
          target: { ...spec.target, [key]: key === "repo" ? "/other/repo" : "other" },
        },
        resolveSpec,
      ),
    ).toThrow(/cannot change repo, issue or topic/);
    expect(store.snapshot().questions).toEqual([q]);
  });

  test("same issue id in different repositories produces independent targets", () => {
    const spec = fields();
    const a = store.create("a", spec, resolveSpec);
    const b = store.create("b", { ...spec, target: { ...spec.target, repo: "/other/repo" } }, resolveSpec);
    store.propose("r", tokenOf(b), "yes", "text");
    expect(store.snapshot().questions).toMatchObject([
      { id: a.id, target: { repo: "/canonical/main" }, proposals: [] },
      { id: b.id, target: { repo: "/other/repo" }, proposals: [{ answer: "yes" }] },
    ]);
  });

  test("planning permits legitimate nulls while review and action require every target field but the desk's", () => {
    const spec = fields();
    const nullable = {
      ...spec.target,
      issue: null,
      worktree: null,
      desk: null,
      space: null,
      session: null,
      action: null,
      head: null,
      stagedTree: null,
      base: null,
      baseRef: null,
    };
    expect(store.create("planning", { ...spec, target: nullable }, resolveSpec).target).toEqual(nullable);
    const deskless = { ...spec.target, desk: null, space: null, session: null };
    for (const kind of ["review", "action"] as const)
      expect(store.create(`deskless-${kind}`, { ...spec, kind, target: deskless }, resolveSpec).target).toEqual(
        deskless,
      );
    for (const kind of ["review", "action"] as const)
      for (const key of Object.keys(spec.target).filter((k) => !["desk", "space", "session"].includes(k))) {
        expect(() =>
          store.create(
            `bad-${kind}-${key}`,
            { ...spec, kind, target: { ...spec.target, [key]: null } } as any,
            resolveSpec,
          ),
        ).toThrow(/nonempty/);
      }
    expect(store.snapshot().questions).toHaveLength(3);
  });

  test.each([
    { kind: "other" },
    { prompt: " " },
    { options: [""] },
    { options: "yes" },
    { origin: { event: "a", session: "b" } },
    { origin: { event: "", session: "b", entry: null } },
    { target: { ...fields().target, repo: "relative" } },
    { target: { ...fields().target, repo: "/repo/../other" } },
    { target: { ...fields().target, topic: "" } },
    { target: { ...fields().target, worktree: "relative" } },
  ])("malformed runtime spec %j fails without a partial mutation", (bad) => {
    expect(() => store.create("bad", { ...fields(), ...bad } as any, resolveSpec)).toThrow();
    expect(store.snapshot().questions).toEqual([]);
  });

  test("only planning, review and action questions exist; the old candidate-review kind is refused", () => {
    expect(() => store.create("old", { ...fields(), kind: "candidate-review" } as any, resolveSpec)).toThrow(
      /invalid kind/,
    );
    expect(store.snapshot()).toEqual({ version: 1, questions: [], selected: null });
  });

  test("returned objects and input objects cannot mutate persisted state", () => {
    const spec = fields();
    const q = store.create("q", spec, resolveSpec);
    spec.target.repo = "/mutated";
    q.target.topic = "mutated";
    const snapshot = store.snapshot();
    snapshot.questions[0].options.push("mutated");
    expect(new QuestionStore(state).snapshot().questions[0]).toMatchObject({
      target: { repo: "/canonical/main", topic: "alpha" },
      options: ["yes", "no"],
    });
    expect(statSync(join(state, "questions.json")).mode & 0o777).toBe(0o600);
  });

  test.each([
    "{",
    JSON.stringify({ version: 2, questions: [], selected: null, requests: [] }),
    // A version 2 ledger held grants, which no code reads now: refused, not ignored.
    JSON.stringify({ version: 2, questions: [], selected: null, requests: [], grants: [], reviews: [], actions: [] }),
  ])("corrupt state fails closed and is not overwritten", (raw) => {
    mkdirSync(state);
    writeFileSync(join(state, "questions.json"), raw);
    expect(() => store.snapshot()).toThrow(/corrupt/);
    expect(() => store.create("q", fields(), resolveSpec)).toThrow(/corrupt/);
    expect(readFileSync(join(state, "questions.json"), "utf8")).toBe(raw);
  });

  test("a forged verified proposal in the persisted file fails closed", () => {
    const q = store.create("q", fields(), resolveSpec);
    store.propose("r", tokenOf(q), "yes", "text");
    const raw = readFileSync(join(state, "questions.json"), "utf8").replaceAll('"verified":false', '"verified":true');
    writeFileSync(join(state, "questions.json"), raw);
    expect(() => store.snapshot()).toThrow(/corrupt/);
    expect(readFileSync(join(state, "questions.json"), "utf8")).toBe(raw);
  });

  test("only a whole answer of one of the options, from a known source, reads as answered", () => {
    const q = store.create("q", { ...fields(), recommendation: { choice: "yes", why: "w" } }, (f) => f);
    const check = { status: "fresh", reasons: [], current: { head: "h", stagedTree: "t" } };
    expect(store.answer("a", tokenOf(q), "yes", "panel picker", check).accepted).toBe(true);
    const good = readFileSync(join(state, "questions.json"), "utf8");
    for (const forged of [
      good.replace(/,"answer":\{[^}]*\}/, ""), // answered with no answer
      good.replace('"choice":"yes","source"', '"choice":"merge it","source"'), // not an option
      good.replace('"source":"panel picker"', '"source":"desk"'), // an unknown source
      good.replace('"status":"answered"', '"status":"pending"'), // an answer on a pending question
    ]) {
      expect(forged).not.toBe(good);
      writeFileSync(join(state, "questions.json"), forged);
      expect(() => store.snapshot()).toThrow(/corrupt/);
    }
    writeFileSync(join(state, "questions.json"), good);
    expect(() =>
      store.create("bad", {}, () => ({ ...fields("b"), recommendation: { choice: "maybe", why: "w" } })),
    ).toThrow(/recommendation must be one of the options/);
  });

  test("a withdrawn question keeps Shep's reason, leaves the projection, and can never be answered", () => {
    const q = store.create("q", fields(), resolveSpec);
    const fresh = { status: "fresh", reasons: [], current: { head: "h", stagedTree: "t" } };
    expect(store.withdraw("w", tokenOf(q), "the desk was already stopped")).toMatchObject({
      status: "withdrawn",
      withdrawal: { requestId: "w", reason: "the desk was already stopped", at: expect.any(String) },
    });
    expect(store.withdraw("w", tokenOf(q), "the desk was already stopped").status).toBe("withdrawn");
    expect(() => store.withdraw("w2", tokenOf(q), "again")).toThrow(/question is withdrawn/);
    expect(store.answer("a", tokenOf(q), "yes", "panel picker", fresh)).toMatchObject({
      accepted: false,
      reason: "question is withdrawn",
    });
    expect(() => store.revise("r", tokenOf(q), {}, () => fields())).toThrow(/stale or closed/);
    const [saved] = store.snapshot().questions;
    expect(saved).not.toHaveProperty("answer");
    expect(projection(store.snapshot())).toMatch(/^0 pending/m);
    expect(projection(store.snapshot())).not.toContain("Answered by");
    // An answered question cannot be withdrawn; a forged withdrawal without its record fails closed.
    const b = store.create("b", fields("beta"), resolveSpec);
    store.answer("a2", tokenOf(b), "yes", "panel picker", fresh);
    expect(() => store.withdraw("w3", tokenOf(b), "moot")).toThrow(/question is answered/);
    const raw = readFileSync(join(state, "questions.json"), "utf8");
    writeFileSync(join(state, "questions.json"), raw.replace(/,"withdrawal":\{[^}]*\}/, ""));
    expect(() => store.snapshot()).toThrow(/corrupt/);
  });

  // A reversible planning pick (no action): Shep's recommendation is what it defaults to.
  const reversible = (topic = "alpha", extra: Partial<QuestionSpec> = {}): QuestionSpec => ({
    ...fields(topic),
    target: { ...fields(topic).target, action: null },
    prompt: "Which desk starts first?",
    options: ["auth", "search"],
    recommendation: { choice: "auth", why: "it unblocks search" },
    reversible: true,
    ...extra,
  });
  const fresh = { status: "fresh", reasons: [], current: { head: null, stagedTree: null } };

  // The decision-timeout matrix, one case per row (docs/shep.md, "Reversible questions").
  // merges: what the repo's policy says about merge_reversible.
  const action = (act: string, prompt: string): Partial<QuestionSpec> => ({
    kind: "action",
    prompt,
    options: ["yes", "wait"],
    recommendation: { choice: "yes", why: "w" },
    target: { ...fields().target, action: act },
  });
  test.each([
    ["two-way", "a planning pick", {}, false],
    ["two-way", "a local commit", action("commit", "Commit the staged change?"), false],
    ["two-way", "a merge where the policy says merge_reversible", action("merge", "Merge it to master?"), true],
    ["two-way", "a merge where the policy says merge_reversible", action("land", "Land it on master?"), true],
    ["one-way", "a merge where the policy does not say merge_reversible", action("land", "Land it on master?"), false],
    ["one-way", "a merge asked without action merge or land", { prompt: "Land it now?" }, true],
    ["one-way", "a merge asked without action merge or land", action("commit", "Commit, then merge?"), true],
    ["one-way", "an LGTM", { ...action("review staged work", "Ready?"), kind: "review" }, true],
    ["one-way", "an LGTM or approval", { prompt: "Approve the guard change?" }, true],
    ["one-way", "force push", { prompt: "Force push it to master?" }, true],
    ["one-way", "force push", { options: ["auth", "git push -f origin main"] }, true],
    ["one-way", "publishing to a forge", { prompt: "Push it to master now?" }, true],
    ["one-way", "publishing to a forge", { options: ["auth", "git push origin main extra-branch"] }, true],
    ["one-way", "publishing to a forge", { options: ["auth", "gt submit"] }, true],
    ["one-way", "publishing to a forge", { brief: "Auth first; then create the trail." }, true],
    ["one-way", "a release or tag", { prompt: "Tag v0.18 tonight?" }, true],
    ["one-way", "a deletion", { brief: "Search first removes the old worktree." }, true],
    ["one-way", "money", { prompt: "Buy the domain for $12?" }, true],
    ["one-way", "an outward post", { prompt: "Post the summary on the PR?" }, true],
    ["one-way", "an outward post", { prompt: "Send the vendor our confirmation?" }, true],
    ["one-way", "a device or deploy action", { prompt: "Deploy to the HA box?" }, true],
    ["one-way", "an action no two-way row names", action("git push -f origin main", "Land it?"), true],
    ["one-way", "an action no two-way row names", action("git clean -fd", "Tidy the worktree?"), true],
    ["one-way", "an action no two-way row names", action("stage-only review", "Review it?"), true],
    ["one-way", "an action no two-way row names", { target: { ...fields().target, action: "commit" } }, true],
    ["one-way", "an action no two-way row names", { target: { ...fields().target, action: "land" } }, true],
    ["one-way", "a commit asked without action commit", { prompt: "Commit it now?" }, true],
  ] as ["one-way" | "two-way", string, Partial<QuestionSpec>, boolean][])(
    "a %s door: %s (%j)",
    (way, row, extra, merges) => {
      const spec = reversible("alpha", extra);
      const create = () =>
        store.create(
          "q",
          {},
          () => spec,
          () => merges,
        );
      if (way === "two-way") {
        expect(create().deadline).toBe("2026-11-14T12:30:00.000Z");
        expect(door(spec, () => merges).row).toBe(row);
        return;
      }
      expect(create).toThrow(`one-way door (${row}: `);
      // A refusal leaves nothing behind; the same question without reversible just waits.
      expect(store.snapshot().questions).toEqual([]);
      const { reversible: _r, ...plain } = spec;
      expect(store.create("q2", {}, () => plain)).not.toHaveProperty("deadline");
    },
  );

  test("a reversible question needs a recommendation, and a merge is one-way when the caller says nothing", () => {
    const { recommendation: _r, ...bare } = reversible();
    expect(() => store.create("q", {}, () => bare)).toThrow(/a reversible question needs a recommendation/);
    expect(() => store.create("m", {}, () => reversible("m", action("merge", "Merge it now?")))).toThrow(
      /one-way door \(a merge where the policy does not say merge_reversible/,
    );
  });

  test("at the deadline a merge defaults only if the policy still says merge_reversible", () => {
    const spec = reversible("m", action("merge", "Merge it now?"));
    const q = store.create(
      "q",
      {},
      () => spec,
      () => true,
    );
    vi.setSystemTime("2026-11-14T12:30:00.000Z");
    const policy = (merge_reversible: unknown) => ({ status: "checked", current: { policy: { merge_reversible } } });
    for (const p of [policy(false), policy(undefined), { status: "unavailable" }, undefined])
      expect(store.expire(tokenOf(q), { ...fresh, policy: p })).toMatchObject({
        accepted: false,
        reason: "now a one-way door: a merge where the policy does not say merge_reversible",
      });
    expect(store.expire(tokenOf(q), { ...fresh, policy: policy(true) }).accepted).toBe(true);
  });

  test("a reversible planning choice gets a deadline: 30 minutes, or [shep] decision_timeout, and 0 never", () => {
    const q = store.create("q", {}, () => reversible());
    expect(q).toMatchObject({ reversible: true, createdAt: "2026-11-14T12:00:00.000Z" });
    expect(q.deadline).toBe("2026-11-14T12:30:00.000Z");
    expect(projection(store.snapshot())).toContain("| defaults to auth at 2026-11-14T12:30:00.000Z");
    // Keep or skip a step that publishes nothing is a planning choice too.
    expect(
      store.create("k", {}, () =>
        reversible("keep", {
          prompt: "Keep or skip the docs step?",
          options: ["keep", "skip"],
          recommendation: { choice: "skip", why: "w" },
        }),
      ).deadline,
    ).toBe("2026-11-14T12:30:00.000Z");
    // A revision gets its own deadline from when it was asked.
    vi.setSystemTime("2026-11-14T12:20:00.000Z");
    expect(store.revise("r", tokenOf(q), {}, () => reversible()).deadline).toBe("2026-11-14T12:50:00.000Z");
    vi.stubEnv("BERCAIL_SHEP_DECISION_TIMEOUT", "5");
    expect(store.create("five", {}, () => reversible("beta")).deadline).toBe("2026-11-14T12:25:00.000Z");
    vi.stubEnv("BERCAIL_SHEP_DECISION_TIMEOUT", "0");
    expect(store.create("never", {}, () => reversible("gamma"))).not.toHaveProperty("deadline");
    vi.stubEnv("BERCAIL_SHEP_DECISION_TIMEOUT", "soon");
    expect(() => store.create("bad", {}, () => reversible("delta"))).toThrow(
      /\[shep\] decision_timeout must be a whole number of minutes, not soon/,
    );
    // Only a reversible question with a recommendation may carry a deadline.
    const raw = readFileSync(join(state, "questions.json"), "utf8");
    writeFileSync(join(state, "questions.json"), raw.replace(',"reversible":true', ""));
    expect(() => store.snapshot()).toThrow(/corrupt/);
  });

  test("past its deadline it takes the recommendation once, as the default, never as the person's pick", () => {
    const q = store.create("q", {}, () => reversible());
    const token = tokenOf(q);
    vi.setSystemTime("2026-11-14T12:29:59.000Z");
    expect(store.expire(token, fresh)).toMatchObject({ accepted: false, question: { status: "pending" } });
    vi.setSystemTime("2026-11-14T12:30:00.000Z");
    // A changed question waits for the person past its deadline.
    const stale = { status: "stale", reasons: ["worktree changed"], current: null };
    expect(store.expire(token, stale)).toMatchObject({
      accepted: false,
      reason: "changed since Shep asked: worktree changed",
    });
    expect(store.expire(token, fresh)).toMatchObject({ accepted: true, question: { status: "answered" } });
    expect(store.snapshot().questions[0]!.answer).toEqual({
      requestId: "default:Q1@1",
      choice: "auth",
      source: "default after timeout",
      at: "2026-11-14T12:30:00.000Z",
      head: null,
      stagedTree: null,
    });
    // Once: a second expiry, and the person's pick after it, change nothing.
    expect(store.expire(token, fresh).accepted).toBe(false);
    expect(store.answer("p", token, "search", "panel picker", fresh)).toMatchObject({
      accepted: false,
      reason: "question is answered",
    });
    // Nobody records a default by the person's door.
    expect(() => store.answer("p2", token, "auth", "default after timeout" as never, fresh)).toThrow(
      /unknown answer source/,
    );
    const view = projection(store.snapshot());
    expect(view).not.toContain("Answered by the person's pick");
    expect(view).toMatch(
      /Defaulted to your recommendation after the deadline \(not the person's choice, never an LGTM/,
    );
    expect(view).toContain("Q1@1 Which desk starts first? -> auth (default after timeout, 2026-11-14T12:30:00.000Z)");
    // A default is the recommendation, at or after the deadline; anything else fails closed.
    const good = readFileSync(join(state, "questions.json"), "utf8");
    for (const forged of [
      good.replace('"choice":"auth","source"', '"choice":"search","source"'),
      good.replace('"at":"2026-11-14T12:30:00.000Z","head"', '"at":"2026-11-14T12:10:00.000Z","head"'),
    ]) {
      expect(forged).not.toBe(good);
      writeFileSync(join(state, "questions.json"), forged);
      expect(() => store.snapshot()).toThrow(/corrupt/);
    }
  });

  test("an OK in the ledger is the person's, on a default only, keeping its choice; anything else fails closed", () => {
    const q = store.create("q", {}, () => reversible());
    const token = tokenOf(q);
    vi.setSystemTime("2026-11-14T12:30:00.000Z");
    store.expire(token, fresh);
    vi.setSystemTime("2026-11-14T12:40:00.000Z");
    expect(store.settle("ok", token, "ok", null, "panel picker", fresh)).toMatchObject({ accepted: true });
    const good = readFileSync(join(state, "questions.json"), "utf8");
    const settled = '"settled":{"requestId":"ok","outcome":"ok","choice":"auth","source":"panel picker"';
    expect(good).toContain(settled);
    for (const forged of [
      good.replace(settled, settled.replace('"choice":"auth"', '"choice":"search"')),
      good.replace(settled, settled.replace('"panel picker"', '"default after timeout"')),
      good.replace(settled, settled.replace('"outcome":"ok"', '"outcome":"lgtm"')),
      good.replace('"at":"2026-11-14T12:40:00.000Z"', '"at":"2026-11-14T12:20:00.000Z"'),
      // On the person's own pick, not a default.
      good.replaceAll('"source":"default after timeout"', '"source":"panel picker"').replace(',"told":true', ""),
    ]) {
      expect(forged).not.toBe(good);
      writeFileSync(join(state, "questions.json"), forged);
      expect(() => store.snapshot()).toThrow(/corrupt/);
    }
  });

  test("a Reverse in the ledger names another choice or none, and a withdrawn question keeps only a default", () => {
    const token = tokenOf(store.create("q", {}, () => reversible()));
    const picked = tokenOf(store.create("p", {}, () => fields("plain")));
    vi.setSystemTime("2026-11-14T12:30:00.000Z");
    store.expire(token, fresh);
    store.answer("pick", picked, "yes", "panel picker", fresh);
    expect(() => store.settle("r2", token, "ok", "search", "panel picker", fresh)).toThrow(/an OK names no choice/);
    expect(store.settle("r", token, "reversed", "search", "panel picker", fresh)).toMatchObject({ accepted: true });
    store.withdraw("w", token, "handled");
    const good = readFileSync(join(state, "questions.json"), "utf8");
    expect(() => store.snapshot()).not.toThrow();
    const settled = '"outcome":"reversed","choice":"search"';
    expect(good).toContain(settled);
    for (const forged of [
      good.replace(settled, '"outcome":"reversed","choice":"auth"'),
      good.replace(settled, '"outcome":"reversed","choice":"neither"'),
      // A withdrawn question with the person's own answer.
      good.replace(
        '"status":"answered","createdAt"',
        '"status":"withdrawn","withdrawal":{"requestId":"w2","reason":"x","at":"2026-11-14T12:30:00.000Z"},"createdAt"',
      ),
    ]) {
      expect(forged).not.toBe(good);
      writeFileSync(join(state, "questions.json"), forged);
      expect(() => store.snapshot()).toThrow(/corrupt/);
    }
  });

  test("past a two-way door's deadline the person's pick is refused, unless it is no longer two-way", () => {
    const plan = store.create("a", {}, () => reversible("a"));
    const merge = store.create(
      "m",
      {},
      () => reversible("m", action("merge", "Merge it now?")),
      () => true,
    );
    vi.setSystemTime("2026-11-14T12:30:00.000Z");
    expect(store.answer("p1", tokenOf(plan), "search", "panel picker", fresh)).toMatchObject({
      accepted: false,
      reason: "past its deadline: it takes Shep's recommendation, auth",
    });
    // The policy no longer says merge_reversible: it will not default, so the person picks.
    expect(store.answer("p2", tokenOf(merge), "wait", "panel picker", fresh).accepted).toBe(true);
  });

  test("the person's pick before the deadline wins, and a plain or withdrawn question never defaults", () => {
    const picked = store.create("a", {}, () => reversible("a"));
    const plain = store.create("b", {}, () => ({ ...fields("b"), recommendation: { choice: "yes", why: "w" } }));
    const withdrawn = store.create("c", {}, () => reversible("c"));
    vi.setSystemTime("2026-11-14T12:10:00.000Z");
    expect(store.answer("p", tokenOf(picked), "search", "panel picker", fresh).accepted).toBe(true);
    store.withdraw("w", tokenOf(withdrawn), "moot");
    vi.setSystemTime("2026-11-14T15:00:00.000Z");
    for (const q of [picked, plain, withdrawn]) expect(store.expire(tokenOf(q), fresh).accepted).toBe(false);
    expect(store.snapshot().questions.map((q) => [q.status, q.answer?.source ?? null])).toEqual([
      ["answered", "panel picker"],
      ["pending", null],
      ["withdrawn", null],
    ]);
    // Only a default is ever told; a forged told on the person's pick fails closed.
    expect(() => store.told(tokenOf(picked))).toThrow(/only a default is told/);
    const raw = readFileSync(join(state, "questions.json"), "utf8");
    writeFileSync(
      join(state, "questions.json"),
      raw.replace('"status":"answered",', '"status":"answered","told":true,'),
    );
    expect(() => store.snapshot()).toThrow(/corrupt/);
  });

  test("lock acquisition failure never falls back to an unlocked write", () => {
    writeFileSync(join(dir, "bin/flock"), "#!/bin/sh\nexit 1\n", { mode: 0o700 });
    expect(() => store.create("q", fields(), resolveSpec)).toThrow(/cannot acquire lock/);
    expect(existsSync(join(state, "questions.json"))).toBe(false);
  });

  test("separate simultaneous writers allocate unique ids without dropping records", async () => {
    const workers = Array.from({ length: 8 }, (_, i) =>
      start("create", { requestId: `writer-${i}`, spec: fields(`topic-${i}`) }),
    );
    await Promise.all(workers.map((p) => p.ready));
    workers.forEach((p) => p.child.stdin!.end("go"));
    await Promise.all(workers.map((p) => p.done));
    const snapshot = store.snapshot();
    expect(snapshot.questions).toHaveLength(8);
    expect(new Set(snapshot.questions.map((q) => q.id)).size).toBe(8);
    expect(snapshot.questions.map((q) => q.target.topic).sort()).toEqual(
      Array.from({ length: 8 }, (_, i) => `topic-${i}`),
    );
    expect(snapshot.selected).toBeNull();
  }, 15000);

  test("simultaneous conflicting replies retain both proposals but accept only one", async () => {
    const q = store.create("q", fields(), resolveSpec);
    const workers = ["yes", "no"].map((answer) => start("reply", { requestId: answer, token: tokenOf(q), answer }));
    await Promise.all(workers.map((p) => p.ready));
    workers.forEach((p) => p.child.stdin!.end("go"));
    await Promise.all(workers.map((p) => p.done));
    const saved = store.snapshot().questions[0];
    expect(saved.status).toBe("pending");
    expect(saved.proposals).toHaveLength(2);
    expect(saved.proposals.filter((p) => p.accepted)).toHaveLength(1);
    expect(saved.proposals.every((p) => p.verified === false)).toBe(true);
  }, 15000);

  test.each(["crash-write", "crash-before", "crash-after"])(
    "%s recovers a complete snapshot and kernel releases the dead writer lock",
    async (mode) => {
      store.create("existing", fields(), resolveSpec);
      store.select("alpha");
      const input = { requestId: "interrupted", spec: fields("beta") };
      const stopped = start(mode, input);
      await stopped.ready;
      const contender = spawnSync(flock, ["-n", join(state, "questions.lock"), process.execPath, "-e", ""], {
        env: process.env,
      });
      expect(contender.status).toBe(1);
      stopped.child.kill("SIGKILL");
      await stopped.done;
      const restarted = new QuestionStore(state);
      expect(restarted.snapshot().questions).toHaveLength(mode === "crash-after" ? 2 : 1);
      expect(restarted.create(input.requestId, input.spec, resolveSpec)).toMatchObject({ id: "Q2", revision: 1 });
      expect(restarted.snapshot()).toMatchObject({ selected: "alpha", questions: [{ id: "Q1" }, { id: "Q2" }] });
      expect(readdirSync(state).filter((f) => f.endsWith(".tmp")).length).toBe(mode === "crash-after" ? 0 : 1);
    },
    15000,
  );

  test("simultaneous repeated request ids create exactly one durable question", async () => {
    const workers = Array.from({ length: 4 }, () => start("create", { requestId: "same", spec: fields() }));
    await Promise.all(workers.map((p) => p.ready));
    workers.forEach((p) => p.child.stdin!.end("go"));
    await Promise.all(workers.map((p) => p.done));
    expect(store.snapshot().questions).toHaveLength(1);
    expect(new QuestionStore(state).create("same", fields(), resolveSpec).id).toBe("Q1");
  }, 15000);

  test("projection is bounded, labels unverified proposals and sanitizes terminal controls", () => {
    const spec = fields();
    const snapshot = {
      version: 1 as const,
      selected: "alpha\n\x1b[31m",
      questions: Array.from({ length: 1000 }, (_, i) => ({
        ...spec,
        id: `Q${i + 1}`,
        revision: 1,
        status: "pending" as const,
        createdAt: "2026-11-14T12:00:00.000Z",
        prompt: "p".repeat(10000),
        proposals: [],
      })),
    };
    const summary = projection(snapshot);
    expect(summary.length).toBeLessThan(20000);
    expect(summary).not.toContain("\x1b");
    expect(summary).toContain("Q1@1");
    expect(summary).toContain("980 omitted");
    expect(summary).toContain("all proposals unverified; no action authority");
    expect(summary).not.toContain("Q21@1");
    for (const q of snapshot.questions) {
      q.target = Object.fromEntries(
        Object.keys(q.target).map((key) => [key, "x".repeat(10000)]),
      ) as unknown as QuestionSpec["target"];
      q.options = ["x".repeat(10000)];
    }
    expect(projection(snapshot).length).toBeLessThan(16000);
  });
});
