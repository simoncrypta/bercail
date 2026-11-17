import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, test, vi } from "vite-plus/test";
import { QuestionStore, readQuestionState, tokenOf, type QuestionSpec } from "../shep/pi/questions.ts";

const scope = {
  repo: "/repo",
  worktree: "/repo.job",
  issue: "app-1",
  pr: "https://github.com/owner/repo/pull/1",
  headRef: "refs/heads/job",
  baseRef: "refs/heads/master",
  baseOid: "base",
  remote: "origin",
  endpoint: "git@github.com:owner/repo.git",
  backend: "gh",
  desk: "desk",
  space: "space",
  session: "session",
  owner: "owner",
  mapping: "mapping",
  policy: "policy-digest",
};
const candidate = { head: "head", tree: "tree", base: "base", description: "description", evidence: "tests passed" };
const now = "2026-11-16T12:00:00.000Z";
const expiresAt = "2026-11-16T13:00:00.000Z";
const observation = { remoteHead: null, capability: "gh-single-ref-fast-forward/v1" };
const fresh = () => ({
  status: "fresh",
  reasons: [],
  current: { head: candidate.head, stagedTree: candidate.tree },
  scope,
  candidate,
});
const fields = (): QuestionSpec => ({
  kind: "scoped-authorization",
  prompt: "Allow this job to commit and publish fast-forward?",
  options: ["Allow", "Stage only", "No"],
  origin: { event: "event", session: "shep", entry: null },
  target: {
    repo: scope.repo,
    issue: scope.issue,
    topic: "job",
    worktree: scope.worktree,
    desk: scope.desk,
    space: scope.space,
    session: scope.session,
    action: "scoped job",
    head: candidate.head,
    stagedTree: candidate.tree,
    base: candidate.base,
    baseRef: scope.baseRef,
  },
  authorization: {
    scope,
    actions: ["commit", "publish-fast-forward"],
    expiresAt,
    allowChoice: "Allow",
    stageOnlyChoice: "Stage only",
  },
});
const flock = spawnSync("which", ["flock"], { encoding: "utf8" }).stdout.trim();

describe("scoped question authority ledger", () => {
  let dir: string;
  let state: string;
  let store: QuestionStore;
  const children: ChildProcess[] = [];
  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "shep-scoped-"));
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
    for (const name of ["hc", "gh", "bd", "pi", "curl", "git"])
      writeFileSync(join(bin, name), "#!/bin/sh\nexit 97\n", { mode: 0o700 });
    if (!flock) throw new Error("flock required");
    writeFileSync(join(bin, "flock"), `#!/bin/sh\nprintf 'lock\\n' >> "$HOME/flock.log"\nexec '${flock}' "$@"\n`, {
      mode: 0o700,
    });
    vi.stubEnv("PATH", bin);
    vi.stubEnv("TZ", "UTC");
    vi.stubEnv("LC_ALL", "C");
    vi.useFakeTimers({ toFake: ["Date"] });
    vi.setSystemTime(now);
    state = join(dir, "state");
    store = new QuestionStore(state);
  });
  afterEach(() => {
    for (const child of children.splice(0)) if (child.exitCode === null) child.kill("SIGKILL");
    vi.useRealTimers();
    vi.unstubAllEnvs();
    rmSync(dir, { recursive: true, force: true });
  });

  function ask(spec = fields(), id = "ask") {
    return store.create(id, spec, (s) => s);
  }
  function grant() {
    const q = ask();
    expect(store.answerScoped("pick", tokenOf(q), "Allow", "panel picker", fresh).accepted).toBe(true);
    return store.scopedSnapshot().grants[0];
  }
  function begin(id: string, grantId: string, reviewRequired = false, next = candidate, binding = scope, at = now) {
    return store.beginScopedAction(id, grantId, "commit", next, binding, () => at, reviewRequired, observation);
  }
  function review(grantId: string, next = candidate) {
    const { authorization: _authorization, ...plain } = fields();
    const q = ask(
      { ...plain, kind: "candidate-review", review: { grantId, candidate: next, allowChoice: "Allow" } },
      "review",
    );
    return store.answerScoped("review-pick", tokenOf(q), "Allow", "discuss picker", () => ({
      ...fresh(),
      candidate: next,
    }));
  }
  function writer(method: string, args: unknown[]) {
    const script = `
      import { QuestionStore } from ${JSON.stringify(new URL("../shep/pi/questions.ts", import.meta.url).href)};
      const RealDate = Date;
      globalThis.Date = class extends RealDate { constructor(value = ${JSON.stringify(now)}) { super(value); } };
      const store = new QuestionStore(${JSON.stringify(state)});
      process.stdout.write('ready\\n');
      process.stdin.once('data', () => {
        const args = ${JSON.stringify(args)};
        if (${JSON.stringify(method)} === 'beginScopedAction') { const at = args[5]; args[5] = () => at; args.push(${JSON.stringify(observation)}); }
        try { process.stdout.write(JSON.stringify({ value: store[${JSON.stringify(method)}](...args${method === "answerScoped" ? `, () => (${JSON.stringify(fresh())})` : ""}) }) + '\\n'); }
        catch (error) { process.stdout.write(JSON.stringify({ error: error.message }) + '\\n'); }
        process.stdin.destroy();
      });`;
    const child = spawn(process.execPath, ["--input-type=module", "-e", script], { stdio: ["pipe", "pipe", "pipe"] });
    children.push(child);
    let output = "";
    let errors = "";
    const ready = new Promise<void>((resolve, reject) => {
      child.stdout!.on("data", (chunk) => {
        output += chunk.toString();
        if (output.includes("ready\n")) resolve();
      });
      child.on("error", reject);
      child.on("exit", () => {
        if (!output.includes("ready\n")) reject(new Error(errors));
      });
    });
    child.stderr!.on("data", (chunk) => {
      errors += chunk.toString();
    });
    const done = new Promise<any>((resolve, reject) => {
      child.on("error", reject);
      child.on("exit", (code) => {
        if (code !== 0) reject(new Error(errors));
        else {
          try {
            resolve(JSON.parse(output.split("\n")[1]));
          } catch (error) {
            reject(error);
          }
        }
      });
    });
    void done.catch(() => {});
    return { child, ready, done };
  }
  async function race(calls: { method: string; args: unknown[] }[]) {
    const writers = calls.map(({ method, args }) => writer(method, args));
    await Promise.all(writers.map((w) => w.ready));
    writers.forEach((w) => w.child.stdin!.end("go"));
    return Promise.all(writers.map((w) => w.done));
  }
  function corrupt(change: (data: any) => void) {
    const path = join(state, "questions.json");
    const data = JSON.parse(readFileSync(path, "utf8"));
    change(data);
    const raw = JSON.stringify(data);
    writeFileSync(path, raw);
    expect(() => store.scopedSnapshot()).toThrow(/corrupt/);
    expect(readFileSync(path, "utf8")).toBe(raw);
  }

  test("first typed create migrates existing version one before a pick and reload grants nothing", () => {
    const { authorization: _authorization, ...plain } = fields();
    const old = ask({ ...plain, kind: "action" }, "old");
    const path = join(state, "questions.json");
    expect(JSON.parse(readFileSync(path, "utf8")).version).toBe(1);

    expect(() => ask()).not.toThrow();
    const persisted = readFileSync(path, "utf8");
    expect(JSON.parse(persisted)).toMatchObject({
      version: 2,
      questions: [old, { id: "Q2", kind: "scoped-authorization", status: "pending" }],
      grants: [],
      reviews: [],
      actions: [],
    });
    store = new QuestionStore(state);
    expect(store.snapshot().version).toBe(2);
    expect(store.snapshot().questions).toEqual(JSON.parse(persisted).questions);
    expect(store.scopedSnapshot()).toEqual({ grants: [], reviews: [], actions: [] });
    expect(readQuestionState(state)).toMatchObject({
      version: 2,
      questions: [old, { id: "Q2", status: "pending" }],
      grants: [],
      reviews: [],
      actions: [],
    });
    expect(readFileSync(path, "utf8")).toBe(persisted);
    expect(readFileSync(join(process.env.HOME!, "flock.log"), "utf8")).toContain("lock");
  });
  test("invalid typed create leaves existing version one bytes and receipts unchanged", () => {
    const { authorization: _authorization, ...plain } = fields();
    const old = ask({ ...plain, kind: "action" }, "old");
    const path = join(state, "questions.json");
    const before = readFileSync(path, "utf8");
    const invalid = fields();
    invalid.authorization!.scope = { ...scope, backend: "gt" };

    expect(() => ask(invalid)).toThrow(/unsupported scoped backend/);
    expect(readFileSync(path, "utf8")).toBe(before);
    store = new QuestionStore(state);
    expect(store.snapshot()).toEqual({ version: 1, questions: [old], selected: null });
    expect(store.scopedSnapshot()).toEqual({ grants: [], reviews: [], actions: [] });
    expect(ask()).toMatchObject({ id: "Q2", kind: "scoped-authorization", status: "pending" });
  });
  test("read-only guard inspection creates no directory and takes no lock", () => {
    expect(readQuestionState(state)).toEqual({
      version: 1,
      questions: [],
      selected: null,
      grants: [],
      reviews: [],
      actions: [],
    });
    expect(existsSync(state)).toBe(false);
    grant();
    const before = readFileSync(join(state, "questions.json"), "utf8");
    writeFileSync(join(dir, "bin/flock"), "#!/bin/sh\nexit 1\n", { mode: 0o700 });
    expect(readQuestionState(state).grants[0].state).toBe("active");
    expect(readFileSync(join(state, "questions.json"), "utf8")).toBe(before);
  });
  test("stable grant questions do not require a candidate and later proposals do not erase authority", () => {
    const spec = fields();
    spec.target.head = null;
    spec.target.stagedTree = null;
    const q = ask(spec);
    expect(
      store.answerScoped("pick", tokenOf(q), "Allow", "panel picker", () => ({
        ...fresh(),
        current: { head: null, stagedTree: null },
      })).accepted,
    ).toBe(true);
    expect(store.propose("late-proposal", tokenOf(q), "No", "transcript").accepted).toBe(false);
    expect(store.scopedSnapshot().grants[0].state).toBe("active");
  });
  test("ordinary version one reads, mutations and answers never migrate or produce grants", () => {
    const { authorization: _authorization, ...plain } = fields();
    const spec: QuestionSpec = { ...plain, kind: "action" };
    const q = ask(spec);
    const path = join(state, "questions.json");
    const before = readFileSync(path, "utf8");
    const locks = readFileSync(join(process.env.HOME!, "flock.log"), "utf8");
    expect(readQuestionState(state)).toEqual({
      version: 1,
      questions: [q],
      selected: null,
      grants: [],
      reviews: [],
      actions: [],
    });
    expect(readFileSync(path, "utf8")).toBe(before);
    expect(readFileSync(join(process.env.HOME!, "flock.log"), "utf8")).toBe(locks);
    store = new QuestionStore(state);
    const unchangedVersion = () => {
      expect(store.snapshot().version).toBe(1);
      const persisted = JSON.parse(readFileSync(path, "utf8"));
      expect(persisted.version).toBe(1);
      for (const key of ["grants", "reviews", "actions"]) expect(persisted).not.toHaveProperty(key);
      expect(store.scopedSnapshot()).toEqual({ grants: [], reviews: [], actions: [] });
    };
    unchangedVersion();
    store.select(spec.target.topic);
    unchangedVersion();
    expect(store.propose("proposal", tokenOf(q), "Allow", "text-command").accepted).toBe(true);
    unchangedVersion();
    const revised = store.revise("revise", tokenOf(q), { ...spec, prompt: "Still proceed?" }, (s) => s);
    unchangedVersion();
    expect(store.answer("old", tokenOf(revised), "Allow", "panel picker", fresh()).accepted).toBe(true);
    unchangedVersion();
    const withdrawn = ask(spec, "withdrawn");
    unchangedVersion();
    expect(store.withdraw("withdraw", tokenOf(withdrawn), "closed discuss").status).toBe("withdrawn");
    unchangedVersion();
    expect(store.snapshot().version).toBe(1);
    expect(store.scopedSnapshot().grants).toEqual([]);
    ask(fields(), "typed");
    expect(store.scopedSnapshot().grants).toEqual([]);
  });
  test("old source-only answer and unverified proposals cannot mint typed grants", () => {
    const q = ask();
    store.propose("proposal", tokenOf(q), "Allow", "panel picker verified:true transcript");
    expect(store.answer("forged", tokenOf(q), "Allow", "panel picker", fresh())).toMatchObject({ accepted: false });
    expect(store.scopedSnapshot().grants).toEqual([]);
    expect(store.snapshot().questions[0].status).toBe("pending");
  });
  test("trusted picker resolves under lock exactly once and duplicate picks mint one durable grant", () => {
    const q = ask();
    let resolved = 0;
    const resolver = () => {
      resolved++;
      expect(spawnSync(flock, ["-n", join(state, "questions.lock"), process.execPath, "-e", ""]).status).toBe(1);
      return fresh();
    };
    const first = store.answerScoped("pick", tokenOf(q), "Allow", "panel picker", resolver);
    store = new QuestionStore(state);
    expect(
      store.answerScoped("pick", tokenOf(q), "Allow", "panel picker", () => {
        throw new Error("must not resolve replay");
      }),
    ).toEqual(first);
    expect(resolved).toBe(1);
    expect(store.scopedSnapshot().grants).toMatchObject([
      { question: tokenOf(q), scope, actions: ["commit", "publish-fast-forward"], state: "active", revision: 1 },
    ]);
    expect(() => store.answerScoped("pick", tokenOf(q), "No", "panel picker", fresh)).toThrow(/request id reused/);
  });
  test.each(["Stage only", "No"])("%s records a pick but grants no action", (choice) => {
    const q = ask();
    expect(store.answerScoped("pick", tokenOf(q), choice, "panel picker", fresh).accepted).toBe(true);
    expect(store.scopedSnapshot().grants).toEqual([]);
  });
  test.each(["revise", "withdraw", "expire", "changed", "missing scope"])(
    "picker rejects %s without a grant",
    (mode) => {
      const q = ask();
      if (mode === "revise") store.revise("rev", tokenOf(q), fields(), (s) => s);
      if (mode === "withdraw") store.withdraw("withdraw", tokenOf(q), "closed discuss");
      if (mode === "expire") vi.setSystemTime(expiresAt);
      const resolver = () =>
        mode === "changed"
          ? { ...fresh(), scope: { ...scope, session: "replacement" } }
          : mode === "missing scope"
            ? { status: "fresh", reasons: [], current: fresh().current, candidate }
            : fresh();
      expect(store.answerScoped("pick", tokenOf(q), "Allow", "panel picker", resolver).accepted).toBe(false);
      expect(store.scopedSnapshot().grants).toEqual([]);
    },
  );
  test("unavailable or malformed resolver facts fail closed without an accepted pick", () => {
    const q = ask();
    expect(
      store.answerScoped("unavailable", tokenOf(q), "Allow", "panel picker", () => ({
        status: "unavailable",
        reasons: ["offline"],
        current: null,
      })).accepted,
    ).toBe(false);
    expect(() =>
      store.answerScoped(
        "bad",
        tokenOf(q),
        "Allow",
        "panel picker",
        () => ({ ...fresh(), scope: { ...scope, verified: true } }) as any,
      ),
    ).toThrow();
    expect(store.scopedSnapshot().grants).toEqual([]);
  });
  test("action receipts survive restart and duplicate actions never authorize replay", () => {
    const g = grant();
    const first = begin("act", g.id);
    expect(first).toMatchObject({
      requestId: "act",
      grantId: g.id,
      candidate,
      state: "applying",
      result: null,
      duplicate: false,
    });
    store = new QuestionStore(state);
    expect(begin("act", g.id)).toMatchObject({ state: "inspect", duplicate: true });
    expect(() => begin("another", g.id)).toThrow(/unfinished|inspect/);
    store.prepareScopedCommit("act", "a".repeat(40));
    store.endScopedAction("act", "succeeded", "a".repeat(40));
    expect(begin("act", g.id)).toMatchObject({ state: "succeeded", duplicate: true });
    expect(begin("next", g.id, false, { ...candidate, tree: "new tree" })).toMatchObject({ duplicate: false });
    expect(store.scopedSnapshot().grants[0].state).toBe("active");
  });
  test("receipt freezes execution grant revision and backend observation across later revocation", () => {
    const g = grant();
    store.pauseGrant(g.id, "offline");
    store.resumeGrant(g.id, scope, () => now);
    const started = begin("audit", g.id);
    expect(started).toMatchObject({ grantRevision: 3, remoteHead: null, capability: "gh-single-ref-fast-forward/v1" });
    store.revokeGrant(g.id, "person revoked");
    expect(begin("audit", g.id)).toMatchObject({
      grantRevision: 3,
      remoteHead: null,
      capability: "gh-single-ref-fast-forward/v1",
      duplicate: true,
      state: "inspect",
    });
    expect(store.scopedSnapshot().grants[0].revision).toBe(4);
  });
  test("a successful commit must equal the immutable prepared exact commit OID", () => {
    const g = grant();
    const started = begin("prepared", g.id);
    expect(started).toHaveProperty("expectedCommit", null);
    const expected = "a".repeat(40);
    const replacement = "b".repeat(40);
    expect(() => store.endScopedAction("prepared", "succeeded", expected)).toThrow(/expected|prepared/);
    expect(store.prepareScopedCommit("prepared", expected)).toMatchObject({
      expectedCommit: expected,
      state: "applying",
    });
    expect(store.prepareScopedCommit("prepared", expected)).toMatchObject({ expectedCommit: expected });
    expect(() => store.prepareScopedCommit("prepared", replacement)).toThrow(/immutable|different/);
    store.endScopedAction("prepared", "inspect", "lost response; inspect exact prepared commit");
    store = new QuestionStore(state);
    expect(begin("prepared", g.id)).toMatchObject({ expectedCommit: expected, state: "inspect", duplicate: true });
    expect(() => store.endScopedAction("prepared", "succeeded", replacement)).toThrow(/expected|prepared/);
    expect(store.endScopedAction("prepared", "succeeded", expected)).toMatchObject({
      expectedCommit: expected,
      result: expected,
    });
    expect(() => store.prepareScopedCommit("prepared", expected)).toThrow(/unfinished|terminal/);
  });
  test("publication cannot prepare a commit and malformed commit preparations fail closed", () => {
    const g = grant();
    store.beginScopedAction("publish", g.id, "publish-fast-forward", candidate, scope, () => now, false, observation);
    expect(() => store.prepareScopedCommit("publish", "a".repeat(40))).toThrow(/commit/);
    store.endScopedAction("publish", "no-effect", "not sent");
    begin("commit", g.id);
    expect(() => store.prepareScopedCommit("commit", "not an OID")).toThrow(/OID/);
    expect(store.scopedSnapshot().actions.map((receipt) => receipt.expectedCommit)).toEqual([null, null]);
  });
  test("a persisted publication receipt cannot carry an expected commit", () => {
    const g = grant();
    store.beginScopedAction("publish", g.id, "publish-fast-forward", candidate, scope, () => now, false, observation);
    corrupt((data) => {
      data.actions[0].expectedCommit = "a".repeat(40);
    });
  });
  test("execution observation is strict and immutable for duplicate request IDs", () => {
    const g = grant();
    const observed = { ...observation, remoteHead: "b".repeat(40) };
    expect(
      store.beginScopedAction("audit", g.id, "commit", candidate, scope, () => now, false, observed),
    ).toMatchObject(observed);
    expect(
      store.beginScopedAction("audit", g.id, "commit", candidate, scope, () => now, false, observation),
    ).toMatchObject({ ...observed, duplicate: true, state: "inspect" });
    for (const malformed of [
      undefined,
      { ...observation, capability: "unknown" },
      { ...observation, remoteHead: "not an OID" },
      { ...observation, verified: true },
    ]) {
      expect(() =>
        store.beginScopedAction("bad", g.id, "commit", candidate, scope, () => now, false, malformed as any),
      ).toThrow();
    }
    expect(store.scopedSnapshot().actions).toHaveLength(1);
  });
  test("execution clock is read under the ledger lock and expiry ends authority before a receipt", () => {
    const g = grant();
    let read = 0;
    const clock = () => {
      read++;
      expect(spawnSync(flock, ["-n", join(state, "questions.lock"), process.execPath, "-e", ""]).status).toBe(1);
      return expiresAt;
    };
    expect(() =>
      store.beginScopedAction("expired", g.id, "commit", candidate, scope, clock, false, observation),
    ).toThrow(/expired/);
    expect(read).toBe(1);
    expect(store.scopedSnapshot()).toMatchObject({ grants: [{ state: "ended", reason: "expired" }], actions: [] });
  });
  test("receipt request IDs bind every action payload field and share the question namespace", () => {
    const g = grant();
    begin("act", g.id);
    expect(() => begin("act", g.id, false, { ...candidate, tree: "other" })).toThrow(/different payload/);
    expect(() => begin("act", g.id, true)).toThrow(/different payload/);
    expect(() => begin("act", g.id, false, candidate, { ...scope, owner: "other" })).toThrow(/different payload/);
    expect(() =>
      store.beginScopedAction("act", g.id, "publish-fast-forward", candidate, scope, () => now, false, observation),
    ).toThrow(/different payload/);
    expect(() => begin("pick", g.id)).toThrow(/request id reused/);
    expect(() => ask(fields(), "act")).toThrow(/request id reused/);
  });
  test.each(Object.keys(scope))("changed scope field %s cannot use an existing grant", (key) => {
    const g = grant();
    expect(() =>
      begin("act", g.id, false, candidate, {
        ...scope,
        [key]:
          key === "repo" || key === "worktree"
            ? "/other"
            : key === "pr"
              ? "https://github.com/owner/repo/pull/2"
              : key === "backend"
                ? "gt"
                : "other",
      }),
    ).toThrow();
    expect(store.scopedSnapshot().actions).toEqual([]);
  });
  test("action outside the grant and missing required review are rejected", () => {
    const spec = fields();
    spec.authorization!.actions = ["commit"];
    const q = ask(spec);
    store.answerScoped("pick", tokenOf(q), "Allow", "panel picker", fresh);
    const g = store.scopedSnapshot().grants[0];
    expect(() =>
      store.beginScopedAction("publish", g.id, "publish-fast-forward", candidate, scope, () => now, false, observation),
    ).toThrow(/action/);
    expect(() => begin("commit", g.id, true)).toThrow(/review/);
    expect(() =>
      store.beginScopedAction(
        "missing-policy",
        g.id,
        "commit",
        candidate,
        scope,
        () => now,
        undefined as any,
        observation,
      ),
    ).toThrow();
  });
  test.each(Object.keys(candidate))("candidate review cannot carry forward changed %s", (key) => {
    const g = grant();
    expect(review(g.id).accepted).toBe(true);
    expect(() => begin("changed", g.id, true, { ...candidate, [key]: "changed" })).toThrow(/review/);
    expect(begin("exact", g.id, true).duplicate).toBe(false);
  });
  test("verified reviewed commit carries review only to exact publication candidate", () => {
    const g = grant();
    review(g.id);
    begin("commit", g.id, true);
    expect(() => store.endScopedAction("commit", "succeeded", "not an OID")).toThrow(/OID/);
    const committed = "a".repeat(40);
    store.prepareScopedCommit("commit", committed);
    store.endScopedAction("commit", "succeeded", committed);
    const next = { ...candidate, head: committed };
    expect(() => begin("another-commit", g.id, true, next)).toThrow(/review/);
    expect(
      store.beginScopedAction("publish", g.id, "publish-fast-forward", next, scope, () => now, true, observation)
        .duplicate,
    ).toBe(false);
    store.endScopedAction("publish", "succeeded", committed);
    for (const key of Object.keys(next)) {
      expect(() =>
        store.beginScopedAction(
          `changed-${key}`,
          g.id,
          "publish-fast-forward",
          { ...next, [key]: "changed" },
          scope,
          () => now,
          true,
          observation,
        ),
      ).toThrow(/review/);
    }
  });
  test.each(["no-effect", "inspect", "unchecked"])("%s commit cannot transfer a candidate review", (mode) => {
    const g = grant();
    review(g.id);
    begin("commit", g.id, mode !== "unchecked");
    const committed = "a".repeat(40);
    if (mode === "unchecked") store.prepareScopedCommit("commit", committed);
    store.endScopedAction("commit", mode === "unchecked" ? "succeeded" : (mode as "no-effect" | "inspect"), committed);
    expect(() =>
      store.beginScopedAction(
        "publish",
        g.id,
        "publish-fast-forward",
        { ...candidate, head: committed },
        scope,
        () => now,
        true,
        observation,
      ),
    ).toThrow(/review|unfinished/);
  });
  test("candidate review cannot outlive grant revocation", () => {
    const g = grant();
    const { authorization: _authorization, ...plain } = fields();
    const q = ask(
      { ...plain, kind: "candidate-review", review: { grantId: g.id, candidate, allowChoice: "Allow" } },
      "review",
    );
    store.revokeGrant(g.id, "person revoked");
    expect(store.answerScoped("review-pick", tokenOf(q), "Allow", "panel picker", fresh).accepted).toBe(false);
    expect(store.scopedSnapshot().reviews).toEqual([]);
  });
  test.each(["revoke", "expire", "pause"])(
    "%s before begin prevents effects and restart does not restore authority",
    (mode) => {
      const g = grant();
      if (mode === "revoke") store.revokeGrant(g.id, "person revoked");
      if (mode === "pause") store.pauseGrant(g.id, "offline");
      store = new QuestionStore(state);
      expect(() => begin("act", g.id, false, candidate, scope, mode === "expire" ? expiresAt : now)).toThrow(
        /grant|expired/,
      );
      expect(store.scopedSnapshot().actions).toEqual([]);
    },
  );
  test("revoke after begin does not erase uncertainty or allow a replacement grant to bypass quarantine", () => {
    const g = grant();
    begin("act", g.id);
    store.revokeGrant(g.id, "stop");
    const q = ask(fields(), "replacement");
    store.answerScoped("replacement-pick", tokenOf(q), "Allow", "panel picker", fresh);
    const replacement = store.scopedSnapshot().grants[1];
    expect(() => begin("replacement-act", replacement.id)).toThrow(/unfinished|inspect/);
    store.endScopedAction("act", "no-effect", "executor proved no request remains");
    expect(begin("replacement-act", replacement.id).duplicate).toBe(false);
    expect(store.scopedSnapshot().grants[0].state).toBe("ended");
  });
  test("pause resumes only identical unexpired scope and ended grants never revive", () => {
    const g = grant();
    store.pauseGrant(g.id, "offline");
    expect(store.resumeGrant(g.id, scope, () => now).state).toBe("active");
    store.pauseGrant(g.id, "offline again");
    expect(store.resumeGrant(g.id, { ...scope, owner: "replacement" }, () => now).state).toBe("ended");
    expect(() => store.resumeGrant(g.id, scope, () => now)).toThrow(/ended/);
  });
  test("resume expires at the boundary and outstanding receipts prevent resume", () => {
    const g = grant();
    begin("act", g.id);
    store.pauseGrant(g.id, "offline");
    expect(() => store.resumeGrant(g.id, scope, () => now)).toThrow(/unfinished|inspect/);
    store.endScopedAction("act", "no-effect", "proven no effect");
    expect(store.resumeGrant(g.id, scope, () => expiresAt).state).toBe("ended");
  });
  test("terminal receipts are immutable and conflicts end the grant", () => {
    const g = grant();
    begin("act", g.id);
    store.endScopedAction("act", "inspect", "lost response");
    expect(() => begin("next", g.id)).toThrow(/unfinished|inspect/);
    const done = store.endScopedAction("act", "conflict", "unexpected head");
    expect(store.endScopedAction("act", "conflict", "unexpected head")).toEqual(done);
    expect(() => store.endScopedAction("act", "succeeded", "claim success")).toThrow(/terminal/);
    expect(store.scopedSnapshot().grants[0].state).toBe("ended");
  });
  test.each([
    (s: any) => {
      s.grants[0].scope.owner = "forged";
    },
    (s: any) => {
      s.grants[0].question = "Q99@1";
    },
    (s: any) => {
      s.grants[0].actions.push("force");
    },
    (s: any) => {
      s.grants[0].revision = 0;
    },
    (s: any) => {
      s.actions[0].candidate.tree = "forged";
    },
    (s: any) => {
      s.actions[0].grantId = "missing";
    },
    (s: any) => {
      s.actions[0].payload = "forged";
    },
    (s: any) => {
      s.actions[0].verified = true;
    },
    (s: any) => {
      s.actions[0].grantRevision = 0;
    },
    (s: any) => {
      s.actions[0].grantRevision = s.grants[0].revision + 1;
    },
    (s: any) => {
      s.actions[0].remoteHead = "not an OID";
    },
    (s: any) => {
      s.actions[0].capability = "unknown";
    },
    (s: any) => {
      s.actions[0].expectedCommit = "not an OID";
    },
    (s: any) => {
      s.actions[0].state = "succeeded";
      s.actions[0].result = "a".repeat(40);
    },
    (s: any) => {
      s.actions[0].expectedCommit = "b".repeat(40);
      s.actions[0].state = "succeeded";
      s.actions[0].result = "a".repeat(40);
    },
    (s: any) => {
      s.reviews[0].candidate.description = "forged";
    },
    (s: any) => {
      s.questions[0].authorization.extra = true;
    },
    (s: any) => {
      s.version = 1;
    },
    (s: any) => {
      s.version = 3;
    },
  ])("malformed nested authority fails closed without overwriting it (%#)", (change) => {
    const g = grant();
    review(g.id);
    begin("act", g.id, true);
    corrupt(change);
  });
  test.each(["same", "different"])("simultaneous %s request IDs authorize at most one execution", async (mode) => {
    const g = grant();
    const results = await race(
      ["first", mode === "same" ? "first" : "second"].map((id) => ({
        method: "beginScopedAction",
        args: [id, g.id, "commit", candidate, scope, now, false],
      })),
    );
    expect(results.filter((r) => r.value?.duplicate === false)).toHaveLength(1);
    expect(
      mode === "same"
        ? results.filter((r) => r.value?.duplicate === true)
        : results.filter((r) => /unfinished/.test(r.error)),
    ).toHaveLength(1);
    expect(store.scopedSnapshot().actions).toHaveLength(1);
  });
  test("revocation racing begin is linearized and any started receipt remains durable", async () => {
    const g = grant();
    const results = await race([
      { method: "beginScopedAction", args: ["act", g.id, "commit", candidate, scope, now, false] },
      { method: "revokeGrant", args: [g.id, "person revoked"] },
    ]);
    expect(results[1].value.state).toBe("ended");
    expect(store.scopedSnapshot().grants[0].state).toBe("ended");
    expect(store.scopedSnapshot().actions).toHaveLength(results[0].value ? 1 : 0);
    if (results[0].error) expect(results[0].error).toMatch(/ended/);
  });
  test("concurrent picker acceptance resolves once and mints exactly one grant", async () => {
    const q = ask();
    const answers = await race(
      [1, 2].map(() => ({ method: "answerScoped", args: ["same-pick", tokenOf(q), "Allow", "panel picker"] })),
    );
    expect(answers.map((a) => a.value.accepted)).toEqual([true, true]);
    expect(store.scopedSnapshot().grants).toHaveLength(1);
  });
  test("failed locks never resolve the picker or write authority", () => {
    const q = ask();
    let resolved = false;
    writeFileSync(join(dir, "bin/flock"), "#!/bin/sh\nexit 1\n", { mode: 0o700 });
    expect(() =>
      store.answerScoped("pick", tokenOf(q), "Allow", "panel picker", () => {
        resolved = true;
        return fresh();
      }),
    ).toThrow(/lock/);
    expect(resolved).toBe(false);
  });
});
