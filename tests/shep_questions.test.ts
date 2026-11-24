import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import {
  existsSync,
  linkSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  renameSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
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
    const done = new Promise<string>((resolve, reject) => {
      child.on("error", reject);
      child.on("exit", (code, signal) =>
        code === 0 || signal === "SIGKILL" ? resolve(output) : reject(new Error(`worker exit ${code}: ${errors}`)),
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
    expect(() => store.create("forged", { ...fields(), trusted: true } as any, resolveSpec)).toThrow(
      /trusted: unexpected field/,
    );
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

  test("a corrupt ledger's error names the record and the field that failed", () => {
    const q = store.create("q", fields(), resolveSpec);
    store.propose("r", tokenOf(q), "yes", "text");
    store.answer("pick", tokenOf(q), "yes", "panel picker", {
      status: "fresh",
      reasons: [],
      current: { head: "a".repeat(40), stagedTree: "b".repeat(40) },
    });
    const file = join(state, "questions.json");
    const good = JSON.parse(readFileSync(file, "utf8"));
    const refused = (edit: (ledger: any) => void) => {
      const ledger = structuredClone(good);
      edit(ledger);
      const raw = JSON.stringify(ledger);
      writeFileSync(file, raw);
      expect(() => store.create("next", fields("next"), resolveSpec)).toThrow(/not overwritten$/);
      expect(readFileSync(file, "utf8")).toBe(raw);
      try {
        store.snapshot();
      } catch (error) {
        return (error as Error).message.replace(/^Question store: /, "");
      }
    };
    expect(refused((l) => (l.questions[0].surprise = 1))).toBe(
      "corrupt questions.json at Q1@1 (questions[0].surprise): unexpected field; not overwritten",
    );
    // Only the answer's receipt, deep in its result: the question record itself is sound.
    expect(refused((l) => (l.requests.at(-1).result.question.answer.extra = true))).toBe(
      "corrupt questions.json at request pick (requests[2].result.question.answer.extra): unexpected field; not overwritten",
    );
    expect(refused((l) => (l.requests.at(-1).result.accepted = "yes"))).toBe(
      "corrupt questions.json at request pick (requests[2].result.accepted): not a boolean; not overwritten",
    );
    expect(refused((l) => (l.questions[0].prompt = 5))).toBe(
      "corrupt questions.json at Q1@1 (questions[0].prompt): expected nonempty text; not overwritten",
    );
    expect(refused((l) => delete l.questions[0].answer.at)).toBe(
      "corrupt questions.json at Q1@1 (questions[0].answer.at): missing field; not overwritten",
    );
    expect(refused((l) => (l.questions[0].createdAt = "not a date"))).toBe(
      "corrupt questions.json at Q1@1 (questions[0].createdAt): invalid time; not overwritten",
    );
    expect(refused((l) => (l.questions[0].proposals = null))).toBe(
      "corrupt questions.json at Q1@1 (questions[0].proposals): not a list; not overwritten",
    );
    expect(refused((l) => (l.version = 2))).toBe("corrupt questions.json at version: unknown version; not overwritten");
    expect(refused((l) => (l.questions[0].target = "x"))).toBe(
      "corrupt questions.json at Q1@1 (questions[0].target): not an object; not overwritten",
    );
    expect(refused((l) => (l.questions[0] = null))).toBe(
      "corrupt questions.json at questions[0]: not an object; not overwritten",
    );
    expect(refused((l) => (l.questions[0].id = "Q0"))).toBe(
      "corrupt questions.json at questions[0].id: invalid question id; not overwritten",
    );
    expect(refused((l) => l.requests.push(l.requests[0]))).toBe(
      "corrupt questions.json at request q (requests[3]): duplicate request id; not overwritten",
    );
    // Node's own JSON.parse message quotes the file's first bytes: the store's never does.
    writeFileSync(file, "sensitive content near the first byte");
    expect(() => store.snapshot()).toThrow(
      /^Question store: corrupt questions\.json: not valid JSON; not overwritten$/,
    );
  });

  test("a process whose questions.ts changed since it loaded says to restart it, not that the ledger is corrupt", () => {
    // An old module that does not know guard.defaults, as before 4df4756, and a ledger the real one wrote.
    const real = readFileSync(fileURLToPath(new URL("../shep/pi/questions.ts", import.meta.url)), "utf8");
    const old = real.replace('["defaults"]', "[]");
    expect(old).not.toBe(real);
    const copy = join(dir, "code", "questions.ts");
    mkdirSync(join(dir, "code"));
    writeFileSync(copy, old);
    const ticket = "0123456789ab";
    store.create(
      "guard",
      {
        ...fields("guard", "guard"),
        options: ["Allow", "Deny"],
        guard: {
          ticket,
          worker: `guard-ask-${ticket}`,
          op: { kind: "push" },
          facts: {},
          expires: "2026-11-14T13:00:00.000Z",
          defaults: { why: "a private remote" },
        },
      },
      resolveSpec,
    );
    const raw = readFileSync(join(state, "questions.json"), "utf8");
    const script = `
      import { writeFileSync } from "node:fs";
      const { QuestionStore } = await import(${JSON.stringify(pathToFileURL(copy).href)});
      const store = new QuestionStore(process.argv[1]);
      const read = () => { try { store.snapshot(); return "read"; } catch (error) { return error.message; } };
      const before = read();
      writeFileSync(${JSON.stringify(copy)}, ${JSON.stringify(real)});
      const after = read();
      // Bytes no reader can parse are not a reason to restart.
      const ledger = process.argv[1] + "/questions.json";
      writeFileSync(ledger, "{");
      const torn = read();
      writeFileSync(ledger, ${JSON.stringify(raw)});
      console.log(JSON.stringify([before, after, torn]));`;
    const run = spawnSync(process.execPath, ["--input-type=module", "-e", script, state], { encoding: "utf8" });
    expect(run.stderr).toBe("");
    const [before, after, torn] = JSON.parse(run.stdout);
    expect(torn).toBe("Question store: corrupt questions.json: not valid JSON; not overwritten");
    expect(before).toBe(
      "Question store: corrupt questions.json at Q1@1 (questions[0].guard.defaults): unexpected field; not overwritten",
    );
    expect(after).toBe(
      `Question store: this process cannot validate questions.json at Q1@1 (questions[0].guard.defaults): unexpected field, and ${copy} changed since this process loaded it: restart it and retry before considering a repair; not overwritten`,
    );
    expect(new QuestionStore(state).snapshot().questions[0].guard?.defaults).toEqual({ why: "a private remote" });
    expect(readFileSync(join(state, "questions.json"), "utf8")).toBe(raw);
  });

  test("each write keeps the three states before it, and a refused read keeps none", () => {
    const file = join(state, "questions.json");
    const kept = (n: number) => join(state, `questions.json.${n}`);
    store.create("a", fields("a"), resolveSpec);
    expect(existsSync(kept(1))).toBe(false);
    const states = [readFileSync(file, "utf8")];
    for (const topic of ["b", "c", "d", "e"]) {
      store.create(topic, fields(topic), resolveSpec);
      states.push(readFileSync(file, "utf8"));
    }
    expect([1, 2, 3].map((n) => readFileSync(kept(n), "utf8"))).toEqual([states[3], states[2], states[1]]);
    expect(existsSync(kept(4))).toBe(false);
    for (const n of [1, 2, 3]) expect(statSync(kept(n)).mode & 0o777).toBe(0o600);
    writeFileSync(file, "{");
    expect(() => store.create("f", fields("f"), resolveSpec)).toThrow(/corrupt/);
    expect([1, 2, 3].map((n) => readFileSync(kept(n), "utf8"))).toEqual([states[3], states[2], states[1]]);
  });

  test.each([
    ["after its link: .1 is the primary's own inode", true],
    ["before its link: .1 is missing", false],
  ])("a write retried after one that stopped mid-rotation, %s, keeps the three states before it", (_, linked) => {
    const file = join(state, "questions.json");
    const kept = (n: number) => join(state, `questions.json.${n}`);
    for (const topic of ["a", "b", "c", "d"]) store.create(topic, fields(topic), resolveSpec);
    const before = readFileSync(file, "utf8");
    const older = [readFileSync(kept(1), "utf8"), readFileSync(kept(2), "utf8")];
    renameSync(kept(2), kept(3));
    renameSync(kept(1), kept(2));
    if (linked) linkSync(file, kept(1));
    store.create("e", fields("e"), resolveSpec);
    expect([1, 2, 3].map((n) => readFileSync(kept(n), "utf8"))).toEqual([before, ...older]);
    expect(statSync(kept(1)).ino).not.toBe(statSync(file).ino);
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
    // As a planning card is asked: no HEAD or staged tree.
    target: { ...fields(topic).target, action: null, head: null, stagedTree: null },
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
  // One-way words that once decided the door; now only the card's kind, action and push do.
  const words = {
    prompt: "Push it, tag it and post it?",
    options: ["auth", "git push -f origin main"],
    brief: "Approve, publish, then clean up the trail. Deploy for $12.",
  };
  // The planning card for docs/plans/one-pick-landing.md, refused three times for its words.
  const plan = {
    prompt: "Plan the one-pick landing now?",
    options: ["Plan it now", "Later"],
    recommendation: { choice: "Plan it now", why: "Shep spends turns on each landing" },
    brief: "A land card's pick lets a worker commit, publish, link the trail and clean up the desk. Plan only.",
  };
  test.each([
    ["two-way", "a planning pick", {}, false],
    ["two-way", "a planning pick", plan, false],
    ["two-way", "a planning pick", words, false],
    ["two-way", "a local commit", action("commit", "Commit the staged change?"), false],
    ["two-way", "a local commit", { ...action("commit", "Commit it?"), brief: "Then push it to master." }, false],
    ["two-way", "a merge where the policy says merge_reversible", action("merge", "Merge it to master?"), true],
    ["two-way", "a merge where the policy says merge_reversible", action("land", "Land it on master?"), true],
    ["one-way", "a merge where the policy does not say merge_reversible", action("land", "Land it on master?"), false],
    ["one-way", "an LGTM", { ...action("review staged work", "Ready?"), kind: "review" }, true],
    ["one-way", "an action no two-way row names", action("deploy", "Ready?"), true],
    ["one-way", "an action no two-way row names", action("git push -f origin main", "Land it?"), true],
    ["one-way", "an action no two-way row names", action("stage-only review", "Review it?"), true],
    ["one-way", "an action no two-way row names", { target: { ...fields().target, action: "commit" } }, true],
    ["one-way", "an action no two-way row names", { target: { ...fields().target, action: "land" } }, true],
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

  // Calm words, and a policy that would let a merge default: the kind or the push still decides.
  const calm = { ...fields(), prompt: "Which desk starts first?", options: ["auth", "search"] };
  const push = { approves: "auth", remote: "origin", refs: ["refs/heads/main"], url: "git@example.com:a/b.git" };
  test.each([
    ["a guard or land card", { ...calm, kind: "guard", target: { ...calm.target, action: null } }],
    // The land card step 5 adds: its own kind, not action land.
    ["a guard or land card", { ...calm, kind: "land", target: { ...calm.target, action: null } }],
    ["a push", { ...calm, kind: "action", push, target: { ...calm.target, action: "merge" } }],
  ] as [string, QuestionSpec][])("a card is one-way whatever its words say: %s", (row, spec) => {
    expect(door(spec, () => true)).toMatchObject({ door: "one-way", row });
  });

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

  // A push question's answer, fresh, and the push the guard claims with it.
  const pushed = () => {
    const spec = { ...fields("push", "review"), options: ["Push it", "Not yet"] };
    const push = { approves: "Push it", remote: "origin", refs: ["refs/heads/master"], url: "/srv/app.git" };
    const q = store.create("push", { ...spec, push }, resolveSpec);
    store.answer("pick", tokenOf(q), "Push it", "panel picker", live);
    return {
      token: tokenOf(q),
      claim: { remote: "origin", refspecs: [`${"a".repeat(40)}^{commit}:refs/heads/master`] },
    };
  };
  const live = { status: "fresh", reasons: [], current: { head: "a".repeat(40), stagedTree: "b".repeat(40) } };

  test("an answer's push is claimed once, while fresh, and only for the push it approves", () => {
    const { token, claim } = pushed();
    expect(store.claimPush(token, { ...live, status: "stale", reasons: ["head changed"] }, claim)).toMatchObject({
      accepted: false,
      reason: "changed since it was answered: head changed",
    });
    expect(() => store.claimPush(token, live, { ...claim, remote: "upstream" })).toThrow(/approved remote and refs/);
    expect(store.claimPush(token, live, claim)).toMatchObject({ accepted: true, question: { pushed: claim } });
    expect(new QuestionStore(state).claimPush(token, live, claim)).toMatchObject({
      accepted: false,
      reason: expect.stringMatching(/^its push was already claimed at /),
    });
    // A Discuss pick of the approving choice approves nothing: an agent can type there.
    const discussed = store.create(
      "discussed",
      {
        ...fields("discussed", "review"),
        options: ["Push it", "Not yet"],
        push: { approves: "Push it", remote: "origin", refs: ["refs/heads/master"], url: "/srv/app.git" },
      },
      resolveSpec,
    );
    store.answer("d", tokenOf(discussed), "Push it", "discuss picker", live);
    expect(store.claimPush(tokenOf(discussed), live, claim)).toMatchObject({
      accepted: false,
      reason: "not the person's approving answer on the panel",
    });
    // The other choice, or a question with no push, approves nothing.
    const other = store.create(
      "other",
      {
        ...fields("other", "review"),
        options: ["Push it", "Not yet"],
        push: { approves: "Push it", remote: "origin", refs: ["refs/heads/master"], url: "/srv/app.git" },
      },
      resolveSpec,
    );
    store.answer("no", tokenOf(other), "Not yet", "panel picker", live);
    expect(store.claimPush(tokenOf(other), live, claim)).toMatchObject({
      accepted: false,
      reason: "not the person's approving answer on the panel",
    });
  });

  test("simultaneous claims of one answer's push let exactly one push run", async () => {
    const { token, claim } = pushed();
    const workers = Array.from({ length: 4 }, () => start("claim", { token, check: live, claim }));
    await Promise.all(workers.map((p) => p.ready));
    workers.forEach((p) => p.child.stdin!.end("go"));
    const outputs = await Promise.all(workers.map((p) => p.done));
    expect(outputs.filter((o) => o.trim().endsWith("true"))).toHaveLength(1);
  }, 15000);

  // A land card on one worktree, branch and job, and the person's pick on it.
  const pinned: NonNullable<QuestionSpec["land"]> = {
    url: "git@github.com:o/app.git",
    ciRef: "refs/heads/bercail-land/login/0123456789ab",
    policyTrust: null,
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
  };
  const landCard = (requestId: string, target: Partial<QuestionSpec["target"]> = {}, extra = {}): string => {
    const spec: QuestionSpec = {
      kind: "land",
      prompt: "Land the login fix?",
      options: ["Ship it", "Not yet"],
      origin: { event: `land-${requestId}`, session: "shep-session", entry: null },
      target: {
        repo: "/canonical/main",
        issue: "app-1",
        topic: "land-app-1",
        worktree: "/canonical/main.login",
        desk: "desk-1",
        space: "space-1",
        session: "desk-session",
        action: "land",
        branch: "refs/heads/login",
        head: "a".repeat(40),
        stagedTree: "b".repeat(40),
        base: "a".repeat(40),
        baseRef: "master",
        ...target,
      },
      land: { ...pinned, handoffBranch: (target.branch ?? "refs/heads/login").slice("refs/heads/".length) },
      ...extra,
    };
    return tokenOf(store.create(requestId, spec, resolveSpec));
  };
  const ship = (token: string, choice = "Ship it", source: "panel picker" | "discuss picker" = "panel picker") =>
    store.answer(`pick-${token}-${choice}-${source}`, token, choice, source, live);

  test("a land card offers Ship it or Not yet, the LGTM when review is required, and pins every fact", () => {
    const lgtm = { required: true, highStakes: ["lib/land.sh"] };
    const land = (changes: Record<string, unknown>) => ({ land: { ...pinned, ...changes } });
    landCard("one");
    const refused: [string, Partial<QuestionSpec["target"]>, Record<string, unknown>, RegExp][] = [
      [
        "recommended",
        {},
        { recommendation: { choice: "Ship it", why: "green" } },
        /no recommendation, default or push/,
      ],
      ["reversible", {}, { reversible: true }, /no recommendation, default or push/],
      ["other choices", {}, { options: ["Yes", "No"] }, /offers Ship it and Not yet only/],
      ["one joined choice", {}, { options: ["Ship it,Not yet"] }, /offers Ship it and Not yet only/],
      ["dirty", {}, land({ clean: false }), /nothing unstaged or untracked/],
      ["unregistered", {}, land({ registered: false }), /a linked worktree git lists/],
      [
        "the trunk itself",
        { branch: "refs/heads/master" },
        land({ handoffBranch: "master" }),
        /never the trunk itself/,
      ],
      ["a HEAD off the trunk", { head: "c".repeat(40) }, {}, /HEAD is the trunk's commit on the remote/],
      ["another handoff branch", {}, land({ handoffBranch: "other" }), /the one its job's handoff record names/],
      [
        "no handoff branch, on a branch named null",
        { branch: "refs/heads/null" },
        land({ handoffBranch: null }),
        /the one its job's handoff record names/,
      ],
      ["no desk", { desk: null, space: null, session: null }, {}, /expected nonempty text/],
      ["commit action", { action: "commit" }, {}, /action land/],
      ["no ci", {}, land({ requiredCi: [] }), /required_ci/],
      [
        "no ci id",
        {},
        land({ requiredCi: [{ path: ".github/workflows/ci.yml", id: null }] }),
        /requiredCi\[0\]\.id: a required_ci workflow needs its GitHub ID/,
      ],
      ["lgtm, no reviewer", {}, { ...land({ review: lgtm }), options: ["LGTM, ship it", "Not yet"] }, /nonempty/],
      ["lgtm, plain choices", {}, land({ review: lgtm, reviewer: "Simon" }), /offers LGTM, ship it and Not yet/],
      ["reviewer, no review", {}, land({ reviewer: "Simon" }), /reviewer only when review is required/],
    ];
    for (const [id, target, extra, why] of refused) expect(() => landCard(id, target, extra), id).toThrow(why);
    const token = landCard(
      "lgtm",
      { issue: "app-2", worktree: "/w/2", branch: "refs/heads/b2" },
      { ...land({ review: lgtm, reviewer: "Simon", handoffBranch: "b2" }), options: ["LGTM, ship it", "Not yet"] },
    );
    expect(store.snapshot().questions.map(tokenOf)).toEqual(["Q1@1", token]);
  });

  test("a land claim needs the person's Ship it on the panel, once, with no other chain for the worktree, branch or job", () => {
    const first = landCard("first");
    // Discuss can talk, not pick: an agent can type into it.
    expect(ship(first, "Ship it", "discuss picker")).toMatchObject({
      accepted: false,
      reason: "a land card is answered on the panel card only",
    });
    const notShipped = "not the person's Ship it on a land card's panel";
    expect(store.claimLand(first)).toMatchObject({ accepted: false, reason: notShipped });
    const declined = landCard("declined", { issue: "app-2", worktree: "/w/2", branch: "refs/heads/b2" });
    expect(ship(declined, "Not yet").accepted).toBe(true);
    expect(store.claimLand(declined)).toMatchObject({ accepted: false, reason: notShipped });
    ship(first);
    // Shep's list shows the Not yet as a pick to act on, never the Ship it its worker acts on.
    const listed = projection(store.snapshot());
    expect(listed).toContain(`${declined} Land the login fix? -> Not yet`);
    expect(listed).not.toContain(`${first} Land the login fix?`);
    expect(() => store.claimLand("Q1@2")).toThrow(/unknown question revision/);
    expect(store.claimLand(first)).toMatchObject({
      accepted: true,
      question: { landing: { claim: { at: expect.any(String) } } },
    });
    expect(new QuestionStore(state).claimLand(first).reason).toMatch(/^its chain was already claimed at /);
  });

  test("a second land card for the same worktree, branch or job is refused while one waits or lands", () => {
    const first = landCard("first");
    const others: [string, Partial<QuestionSpec["target"]>][] = [
      ["worktree", { issue: "app-3", branch: "refs/heads/b3" }],
      ["branch", { issue: "app-4", worktree: "/w/4" }],
      ["job", { worktree: "/w/5", branch: "refs/heads/b5" }],
    ];
    const refusedWhile = (what: string, n: number) => {
      for (const [id, target] of others)
        expect(() => landCard(`${id}-${n}`, target), `${id}, ${what}`).toThrow(
          `Q1@1 is ${what} for the same worktree, branch or job`,
        );
    };
    refusedWhile("pending", 1);
    ship(first);
    refusedWhile("landing", 2);
    store.claimLand(first);
    refusedWhile("landing", 3);
    // Another repo's, and one asked once the chain ended.
    landCard("other repo", { repo: "/canonical/other" });
    store.landResult(first, { outcome: "changed", commit: null, warnings: [], log: "/state/land/Q1-1.log" });
    expect(landCard("after", others[0]![1])).toBe("Q3@1");
    // A declined card waits on no one.
    ship("Q3@1", "Not yet");
    expect(landCard("after decline", others[1]![1])).toBe("Q4@1");
  });

  test("a claim waits while another chain runs for the same worktree, branch or job, in a ledger that has two", () => {
    const first = landCard("first");
    const second = landCard("second", { issue: "app-2", worktree: "/w/2", branch: "refs/heads/b2" });
    ship(first);
    ship(second);
    expect(store.claimLand(first).accepted).toBe(true);
    // An older ledger, or one edited, can hold two such cards: the claim still refuses.
    for (const key of ["worktree", "branch", "issue"] as const) {
      const file = join(state, "questions.json");
      const saved = JSON.parse(readFileSync(file, "utf8"));
      const own = { issue: "app-2", worktree: "/w/2", branch: "refs/heads/b2" };
      saved.questions[1].target = { ...saved.questions[0].target, ...own, [key]: saved.questions[0].target[key] };
      saved.questions[1].land.handoffBranch = saved.questions[1].target.branch.slice("refs/heads/".length);
      writeFileSync(file, JSON.stringify(saved));
      expect(store.claimLand(second), key).toMatchObject({
        accepted: false,
        reason: "Q1@1's chain is running for the same worktree, branch or job",
      });
    }
    store.landResult(first, { outcome: "changed", commit: null, warnings: [], log: "/state/land/Q1-1.log" });
    expect(store.claimLand(second).accepted).toBe(true);
  });

  test("a start reservation is recorded once per attempt, before any claim, and grants nothing", () => {
    const token = landCard("one");
    const notShipped = "not the person's Ship it on a land card's panel";
    expect(store.reserveLand(token, 1)).toMatchObject({ accepted: false, reason: notShipped });
    ship(token);
    expect(store.reserveLand(token, 1)).toMatchObject({
      accepted: true,
      question: { landing: { starts: [{ terminal: "land-q1-1", at: "2026-11-14T12:00:00.000Z" }], steps: [] } },
    });
    expect(store.reserveLand(token, 1).reason).toBe("start 1 is not the next one, 2");
    expect(store.reserveLand(token, 3).reason).toBe("start 3 is not the next one, 2");
    expect(new QuestionStore(state).reserveLand(token, 2).accepted).toBe(true);
    // A reservation is not a claim: the chain still needs its one claim, and then takes no start.
    expect(store.landStep(token, "check").reason).toBe("its chain is not claimed");
    expect(store.claimLand(token).accepted).toBe(true);
    expect(store.reserveLand(token, 3).reason).toMatch(/^its chain was already claimed at /);
    const declined = landCard("declined", { issue: "app-2", worktree: "/w/2", branch: "refs/heads/b2" });
    ship(declined, "Not yet");
    expect(store.reserveLand(declined, 1)).toMatchObject({ accepted: false, reason: notShipped });
    expect(store.snapshot().questions[0]!.landing!.starts).toHaveLength(2);
  });

  test("a claimed chain records its steps in order and one result at the last of them, told once", () => {
    const token = landCard("one");
    ship(token);
    const result = { outcome: "landed" as const, commit: "c".repeat(40), warnings: [], log: "/state/land/Q1-1.log" };
    expect(store.landResult(token, result).reason).toBe("its chain is not claimed");
    store.claimLand(token);
    for (const [step, detail] of [
      ["check"],
      ["commit"],
      ["push"],
      ["ci", "1 of 2 runs passed"],
      ["ci", "2 of 2 runs passed"],
    ])
      expect(store.landStep(token, step as "ci", detail).accepted).toBe(true);
    expect(store.landStep(token, "commit").reason).toBe("commit cannot follow ci");
    expect(store.landStep(token, "sync").reason).toBe("sync cannot follow ci");
    expect(() => store.landStep(token, "deploy" as "ci")).toThrow(/unknown land step/);
    expect(store.landTold(token).reason).toBe("its chain has no result");
    // Landed means the trunk push ran.
    expect(store.landResult(token, result).reason).toBe("landed only once the chain is past its trunk push");
    store.landStep(token, "trunk");
    expect(() => store.landResult(token, { ...result, commit: null })).toThrow(/landed only past the trunk push/);
    expect(() => store.landResult(token, { ...result, outcome: "merged" as "landed" })).toThrow(/known outcome/);
    expect(store.landResult(token, result)).toMatchObject({
      accepted: true,
      question: { landing: { result: { ...result, step: "trunk", at: expect.any(String) } } },
    });
    expect(store.landResult(token, { ...result, outcome: "unknown" }).reason).toBe("its chain already ended: landed");
    expect(store.landStep(token, "close").reason).toBe("its chain ended: landed");
    expect(store.landTold(token)).toMatchObject({ accepted: true, question: { landing: { result: { told: true } } } });
    expect(new QuestionStore(state).landTold(token).reason).toBe("its result was already told");
    // A chain that recorded no step ends at none.
    const bare = landCard("bare", { issue: "app-2", worktree: "/w/2", branch: "refs/heads/b2" });
    ship(bare);
    store.claimLand(bare);
    expect(store.landStep(bare, "ci").reason).toBe("ci cannot follow the claim");
    expect(
      store.landResult(bare, { ...result, outcome: "unknown", commit: null }).question.landing!.result!.step,
    ).toBeNull();
  });

  test("a ledger edited to break a land card's rules fails closed on reload", () => {
    const at = "2026-11-14T12:00:00.000Z";
    const claimed = { starts: [], steps: [], claim: { at } };
    const cases: [string, (q: any[]) => void][] = [
      ["a chain on a declined card", (q) => ((q[0].answer.choice = "Not yet"), (q[0].landing = claimed))],
      ["a Discuss pick", (q) => (q[0].answer.source = "discuss picker")],
      [
        "two running chains on one worktree",
        (q) => ((q[1].target.worktree = q[0].target.worktree), (q[0].landing = claimed), (q[1].landing = claimed)),
      ],
      ["an unknown first step", (q) => (q[0].landing = { ...claimed, steps: [{ step: "deploy", at }] })],
      [
        "landed before the trunk push",
        (q) =>
          (q[0].landing = {
            ...claimed,
            steps: [{ step: "check", at }],
            result: { outcome: "landed", step: "check", commit: "c".repeat(40), warnings: [], log: "/l", at },
          }),
      ],
    ];
    for (const [name, edit] of cases) {
      rmSync(state, { recursive: true, force: true });
      for (const [id, target] of [
        ["one", {}],
        ["two", { issue: "app-2", worktree: "/w/2", branch: "refs/heads/b2" }],
      ] as const)
        ship(landCard(id, target));
      const file = join(state, "questions.json");
      const saved = JSON.parse(readFileSync(file, "utf8"));
      edit(saved.questions);
      writeFileSync(file, JSON.stringify(saved));
      expect(() => new QuestionStore(state).snapshot(), name).toThrow(/corrupt questions\.json/);
    }
  });

  test("simultaneous tells of one result write its land event once", async () => {
    const token = landCard("one");
    ship(token);
    store.claimLand(token);
    store.landResult(token, { outcome: "changed", commit: null, why: "stagedTree changed", warnings: [], log: "/l" });
    // Each writer counts its own write: the inbox rename runs under the ledger's lock.
    const workers = Array.from({ length: 4 }, () => start("land-tell", { token }));
    await Promise.all(workers.map((p) => p.ready));
    workers.forEach((p) => p.child.stdin!.end("go"));
    const outputs = await Promise.all(workers.map((p) => p.done));
    expect(outputs.filter((o) => o.trim().endsWith("true"))).toHaveLength(1);
    expect(outputs.join("").match(/^wrote$/gm)).toHaveLength(1);
    expect(readdirSync(join(state, "inbox"))).toEqual(["land-Q1-1.json"]);
    expect(JSON.parse(readFileSync(join(state, "inbox", "land-Q1-1.json"), "utf8"))).toMatchObject({
      event_id: "land:Q1@1",
      outcome: "changed",
      why: "stagedTree changed",
    });
  }, 15000);

  test("simultaneous reservations of one attempt, and simultaneous claims, each let exactly one through", async () => {
    const token = landCard("one");
    ship(token);
    for (const [mode, input] of [
      ["land-reserve", { token, attempt: 1 }],
      ["land-claim", { token }],
    ] as const) {
      const workers = Array.from({ length: 4 }, () => start(mode, input));
      await Promise.all(workers.map((p) => p.ready));
      workers.forEach((p) => p.child.stdin!.end("go"));
      const outputs = await Promise.all(workers.map((p) => p.done));
      expect(
        outputs.filter((o) => o.trim().endsWith("true")),
        mode,
      ).toHaveLength(1);
    }
    expect(store.snapshot().questions[0]!.landing!.starts).toHaveLength(1);
  }, 15000);

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
