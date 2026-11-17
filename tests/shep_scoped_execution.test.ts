import { execFileSync, spawn } from "node:child_process";
import { once } from "node:events";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, watch, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, expect, test } from "vite-plus/test";
import { captureCandidate, captureJobScope, feasibility } from "../shep/pi/scoped-target.ts";
import { executeScoped, inspectScoped } from "../shep/pi/scoped-execution.ts";
import { QuestionStore } from "../shep/pi/questions.ts";
import type { JobScope, ScopedAction, ScopedCandidate } from "../shep/pi/scoped-types.ts";
import { SCOPED_CAPABILITY } from "../shep/pi/scoped-types.ts";

let dir: string;
let repo: string;
let bare: string;
let saved: NodeJS.ProcessEnv;
const json = (path: string, value: unknown) => writeFileSync(path, JSON.stringify(value));
const git = (...args: string[]) =>
  execFileSync("git", ["-C", repo, ...args], {
    env: process.env,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  }).trim();
const caller = () => ({ cwd: repo, desk: "t9", session: "desk-session", role: "lead" });
const input = () => ({
  repo,
  issue: "app-1",
  topic: "feature",
  desk: "t9",
  base: "main",
  pr: "https://github.com/test/app/pull/1",
  remote: "origin",
});
function fake(name: string, body: string) {
  writeFileSync(join(dir, "bin", name), `#!/bin/sh\nprintf '%s %s\\n' '${name}' "$*" >> '${dir}/argv'\n${body}\n`, {
    mode: 0o755,
  });
}
function terminal(extra: Record<string, unknown> = {}) {
  const value = {
    address: "t9",
    state: "live",
    cwd: repo,
    foreground: { pid: process.pid, cwd: repo, name: "pi" },
    labels: { "bercail.role": "agent", "bercail.issue": "app-1", "bercail.space": "sp1" },
    records: { "desk-session": { app: "pi", state: "working" } },
    ...extra,
  };
  json(join(dir, "terminal.json"), value);
  json(join(dir, "terminals.json"), { terminals: [value] });
}
function artifacts() {
  const tree = git("write-tree");
  mkdirSync(join(repo, ".bercail"), { recursive: true });
  writeFileSync(
    join(repo, ".bercail/description.md"),
    `---\ntitle: Feature\nagent: Pi, fixture-model\ntree: ${tree}\nbase: ${git("rev-parse", "main")}\n---\nA checked feature.\n`,
  );
  json(join(repo, ".bercail/validate.json"), {
    tree,
    checks: [{ kind: "unit", command: "fixture", exit_code: 0, evidence: "passed" }],
  });
  json(join(dir, "describe.json"), {
    file: join(repo, ".bercail/description.md"),
    tree,
    current_tree: tree,
    stale: false,
    fails: [],
    change: { review: "optional", high_stakes: [] },
  });
}
beforeEach(() => {
  saved = process.env;
  process.env = Object.fromEntries(
    Object.entries(saved).filter(
      ([key]) => !/^(HC_|HERDR_|BERCAIL_|BEADS_|BD_|GIT_|XDG_)/.test(key) && key !== "BASH_ENV",
    ),
  );
  dir = mkdtempSync(join(tmpdir(), "shep-scoped-execution-"));
  for (const key of [
    "HOME",
    "XDG_CONFIG_HOME",
    "XDG_STATE_HOME",
    "XDG_DATA_HOME",
    "XDG_CACHE_HOME",
    "XDG_RUNTIME_DIR",
    "TMPDIR",
  ]) {
    process.env[key] = join(dir, key.toLowerCase());
    mkdirSync(process.env[key]!, { recursive: true });
  }
  mkdirSync(join(dir, "bin"));
  process.env.PATH = `${join(dir, "bin")}:${saved.PATH}`;
  Object.assign(process.env, {
    TZ: "UTC",
    LC_ALL: "C",
    GIT_CONFIG_NOSYSTEM: "1",
    GIT_AUTHOR_NAME: "Test",
    GIT_COMMITTER_NAME: "Test",
    GIT_AUTHOR_EMAIL: "test@example.invalid",
    GIT_COMMITTER_EMAIL: "test@example.invalid",
    GIT_AUTHOR_DATE: "2026-01-01T00:00:00Z",
    GIT_COMMITTER_DATE: "2026-01-01T00:00:00Z",
  });
  repo = join(dir, "repo");
  bare = join(dir, "remote.git");
  mkdirSync(repo);
  git("init", "-q", "-b", "main");
  writeFileSync(join(repo, "file"), "one\n");
  git("add", "file");
  git("commit", "-qm", "initial");
  git("init", "--bare", "-q", bare);
  git("remote", "add", "origin", bare);
  git("checkout", "-qb", "feature");
  git("push", "-q", "origin", "HEAD:refs/heads/feature");
  mkdirSync(join(process.env.XDG_STATE_HOME!, "bercail/desk-sessions"), { recursive: true });
  json(join(process.env.XDG_STATE_HOME!, "bercail/desk-sessions/t9.json"), {
    address: "t9",
    cwd: repo,
    harness: "pi",
    issue: "app-1",
    space: "sp1",
    session: "desk-session",
    pid: process.pid,
  });
  writeFileSync(
    join(process.env.XDG_STATE_HOME!, "bercail/handoffs.jsonl"),
    JSON.stringify({
      path: repo,
      branch: "feature",
      issue: "app-1",
      desk: "t9",
      space: "sp1",
      git: "gh",
      stage: "bstack",
      harness: "pi",
    }) + "\n",
  );
  mkdirSync(join(process.env.XDG_RUNTIME_DIR!, "bercail/open-sessions"), { recursive: true });
  const stat = readFileSync(`/proc/${process.pid}/stat`, "utf8");
  json(join(process.env.XDG_RUNTIME_DIR!, `bercail/open-sessions/${process.pid}.json`), {
    pid: process.pid,
    start_ticks: stat.slice(stat.lastIndexOf(")") + 2).split(/\s+/)[19],
    sessions: ["desk-session"],
  });
  terminal();
  json(join(dir, "policy.json"), {
    repo,
    root: repo,
    trusted: true,
    sha256: "one",
    sources: { review: "local" },
    policy: { integrate: "direct", review: "by-stakes", high_stakes: [] },
  });
  json(join(dir, "pr.json"), {
    url: input().pr,
    state: "OPEN",
    headRefName: "feature",
    baseRefName: "main",
    baseRefOid: git("rev-parse", "main"),
    headRepository: { name: "app", nameWithOwner: "test/app", url: bare },
    headRepositoryOwner: { login: "test" },
  });
  fake(
    "hc",
    `case "$1" in get) /bin/cat '${dir}/terminal.json';; ls) /bin/cat '${dir}/terminals.json';; *) exit 2;; esac`,
  );
  fake("bd", `test "$1 $2 $3" = 'show app-1 --json' || exit 2\nprintf '[{"id":"app-1","status":"open"}]'`);
  fake("gh", `case "$1 $2" in 'pr view') /bin/cat '${dir}/pr.json';; 'api --hostname') printf '[]';; *) exit 2;; esac`);
  fake(
    "bercail",
    `case "$1 $2" in 'policy show') /bin/cat '${dir}/policy.json';; 'describe check') /bin/cat '${dir}/describe.json';; 'describe commit') printf 'Feature\\n\\nA checked feature.\\n\\nWritten with bercail; fixture provenance\\n';; *) exit 2;; esac`,
  );
  for (const name of ["gt", "origin", "entire"]) fake(name, "exit 97");
  artifacts();
});
afterEach(() => {
  process.env = saved;
  rmSync(dir, { recursive: true, force: true });
});

test("early feasibility resolves the exact gh job without native publication", () => {
  expect(feasibility(input())).toMatchObject({
    supported: true,
    scope: {
      repo: join(repo, ".git"),
      worktree: repo,
      headRef: "refs/heads/feature",
      baseRef: "refs/heads/main",
      endpoint: bare,
      backend: "gh",
      session: "desk-session",
    },
  });
  const argv = readFileSync(join(dir, "argv"), "utf8");
  expect(argv).toContain("gh pr view");
  expect(argv).not.toMatch(/^(gt|origin|entire) /m);
});

function authorize(actions: ScopedAction[] = ["commit", "publish-fast-forward"]) {
  const scope = captureJobScope(input());
  const store = new QuestionStore(join(dir, "questions"));
  const target = {
    repo: scope.repo,
    worktree: repo,
    issue: scope.issue,
    topic: "feature",
    desk: scope.desk,
    space: scope.space,
    session: scope.session,
    head: null,
    stagedTree: null,
    base: scope.baseOid,
    baseRef: scope.baseRef,
    action: "scoped job",
  };
  const spec = {
    kind: "scoped-authorization" as const,
    prompt: "Allow this exact job?",
    options: ["Allow", "Stage only"],
    origin: { event: "fixture", session: "shep-session", entry: null },
    target,
    authorization: {
      scope,
      actions,
      expiresAt: "2099-01-01T00:00:00.000Z",
      allowChoice: "Allow",
      stageOnlyChoice: "Stage only",
    },
  };
  const q = store.create("ask-grant", spec, (value) => value);
  store.answerScoped("pick-grant", `${q.id}@${q.revision}`, "Allow", "panel picker", () => ({
    status: "fresh",
    reasons: [],
    current: { head: null, stagedTree: null },
    scope,
  }));
  return { store, scope, grantId: store.scopedSnapshot().grants[0].id };
}
function change() {
  writeFileSync(join(repo, "file"), "two\n");
  git("add", "file");
  artifacts();
}
function review(store: QuestionStore, scope: JobScope, grantId: string, candidate: ScopedCandidate) {
  const target = {
    repo: scope.repo,
    worktree: repo,
    issue: scope.issue,
    topic: "feature",
    desk: scope.desk,
    space: scope.space,
    session: scope.session,
    head: candidate.head,
    stagedTree: candidate.tree,
    base: candidate.base,
    baseRef: scope.baseRef,
    action: "candidate review",
  };
  const spec = {
    kind: "candidate-review" as const,
    prompt: "Review this candidate?",
    options: ["LGTM", "No"],
    origin: { event: "fixture-review", session: "shep-session", entry: null },
    target,
    review: { grantId, candidate, allowChoice: "LGTM" },
  };
  const q = store.create("ask-review", spec, (value) => value);
  store.answerScoped("pick-review", `${q.id}@${q.revision}`, "LGTM", "panel picker", () => ({
    status: "fresh",
    reasons: [],
    current: { head: candidate.head, stagedTree: candidate.tree },
    scope,
    candidate,
  }));
}

test("structured commit runs hooks, verifies one parent/tree and remains prompt-free on duplicate", async () => {
  const { store, scope, grantId } = authorize();
  change();
  const candidate = captureCandidate(scope).candidate;
  writeFileSync(join(repo, ".git/hooks/pre-commit"), `#!/bin/sh\nprintf hook >> '${dir}/hooks'\n`, { mode: 0o755 });
  const request = { requestId: "commit-one", grantId, action: "commit" as const, candidate };
  const receipt = await executeScoped(store, request, caller());
  expect(receipt.state).toBe("succeeded");
  expect(receipt.result).toBe(git("rev-parse", "HEAD"));
  expect(git("show", "-s", "--format=%T %P", "HEAD")).toBe(`${candidate.tree} ${candidate.head}`);
  expect(await executeScoped(store, request, caller())).toEqual(receipt);
  expect(readFileSync(join(dir, "hooks"), "utf8")).toBe("hook");
  expect(git("show", "-s", "--format=%B", "HEAD")).toContain(
    "Written with bercail (Pi, fixture-model); not yet reviewed",
  );
});

test("fast-forward publication pushes one immutable feature ref and never follows tags", async () => {
  const { store, scope, grantId } = authorize();
  change();
  const candidate = captureCandidate(scope).candidate;
  expect(
    (await executeScoped(store, { requestId: "commit", grantId, action: "commit", candidate }, caller())).state,
  ).toBe("succeeded");
  git("tag", "-a", "v-test", "-m", "not authorized");
  const published = captureCandidate(scope).candidate;
  const request = { requestId: "publish", grantId, action: "publish-fast-forward" as const, candidate: published };
  const receipt = await executeScoped(store, request, caller());
  expect(receipt).toMatchObject({ state: "succeeded", result: published.head });
  expect(git("ls-remote", "--refs", bare)).toBe(`${published.head}\trefs/heads/feature`);
  expect(await executeScoped(store, request, caller())).toEqual(receipt);
});

test.each(["gt", "origin", "entire"])(
  "preflight rejects configured %s backend without invoking a native CLI",
  (backend) => {
    writeFileSync(join(process.env.XDG_CONFIG_HOME!, "bercail.tmp"), "");
    mkdirSync(join(process.env.XDG_CONFIG_HOME!, "bercail"));
    writeFileSync(join(process.env.XDG_CONFIG_HOME!, "bercail/config.toml"), `[git]\n"${repo}" = "${backend}"\n`);
    expect(feasibility(input())).toMatchObject({ supported: false });
    expect(readFileSync(join(dir, "argv"), "utf8")).not.toMatch(/^(gt|origin|entire) /m);
  },
);

test.each([
  ["remote.origin.pushurl", "https://github.com/test/other.git"],
  ["remote.origin.push", "+refs/heads/*:refs/heads/*"],
  ["remote.origin.mirror", "true"],
  ["remote.origin.receivepack", "evil"],
  ["push.followTags", "true"],
  ["push.default", "matching"],
  ["push.recurseSubmodules", "on-demand"],
  ["alias.push", "!evil"],
  ["url.https://example.invalid/.insteadOf", "https://github.com/"],
  ["protocol.ext.allow", "always"],
])("preflight rejects publication indirection %s", (key, value) => {
  git("config", key, value);
  expect(feasibility(input())).toMatchObject({ supported: false });
});

test("multiple push URLs are unsupported even when the first is the intended endpoint", () => {
  git("config", "--add", "remote.origin.pushurl", bare);
  git("config", "--add", "remote.origin.pushurl", bare);
  expect(feasibility(input())).toMatchObject({
    supported: false,
    reason: expect.stringContaining("exactly one push URL"),
  });
});

test("URL credentials are rejected without executing a forge lookup", () => {
  git("remote", "set-url", "origin", "https://token:secret@github.com/test/app.git");
  expect(feasibility(input())).toMatchObject({ supported: false, reason: expect.stringContaining("credential-free") });
  expect(readFileSync(join(dir, "argv"), "utf8")).not.toContain("gh ");
});

test("a terminal in the same worktree conflicts even without matching labels", () => {
  const owner = JSON.parse(readFileSync(join(dir, "terminal.json"), "utf8"));
  json(join(dir, "terminals.json"), {
    terminals: [
      owner,
      {
        address: "t10",
        state: "live",
        cwd: repo,
        foreground: { cwd: repo, pid: process.pid + 1 },
        records: {},
        labels: {},
      },
    ],
  });
  expect(feasibility(input())).toMatchObject({
    supported: false,
    reason: expect.stringContaining("can write this worktree"),
  });
});

test("reused PID claim with wrong start ticks is not the current foreground owner", () => {
  json(join(process.env.XDG_RUNTIME_DIR!, `bercail/open-sessions/${process.pid}.json`), {
    pid: process.pid,
    start_ticks: "0",
    sessions: ["desk-session"],
  });
  expect(feasibility(input())).toMatchObject({ supported: false, reason: expect.stringContaining("owner changed") });
});

test("changed handoff mapping ends an existing grant before effects", async () => {
  const { store, scope, grantId } = authorize();
  change();
  const candidate = captureCandidate(scope).candidate;
  writeFileSync(
    join(process.env.XDG_STATE_HOME!, "bercail/handoffs.jsonl"),
    JSON.stringify({
      path: repo,
      branch: "feature",
      issue: "app-other",
      desk: "t9",
      space: "sp1",
      git: "gh",
      harness: "pi",
    }) + "\n",
  );
  await expect(
    executeScoped(store, { requestId: "commit", grantId, action: "commit", candidate }, caller()),
  ).rejects.toThrow("mapping changed");
  expect(store.scopedSnapshot().grants[0].state).toBe("ended");
  expect(git("rev-parse", "HEAD")).toBe(candidate.head);
});

test("temporarily unavailable owner facts pause rather than end the grant", async () => {
  const { store, scope, grantId } = authorize();
  change();
  const candidate = captureCandidate(scope).candidate;
  fake("hc", "exit 3");
  await expect(
    executeScoped(store, { requestId: "commit", grantId, action: "commit", candidate }, caller()),
  ).rejects.toThrow();
  expect(store.scopedSnapshot().grants[0].state).toBe("paused");
});

test.each(["session", "desk", "cwd", "role"])("caller %s cannot inherit another desk grant", async (field) => {
  const { store, scope, grantId } = authorize();
  change();
  const candidate = captureCandidate(scope).candidate;
  const impostor = { ...caller(), [field]: field === "cwd" ? dir : "other" };
  await expect(
    executeScoped(store, { requestId: "commit", grantId, action: "commit", candidate }, impostor),
  ).rejects.toThrow("exact authorized");
  expect(store.scopedSnapshot().actions).toHaveLength(0);
});

test("a stale candidate cannot be committed and does not revoke the stable grant", async () => {
  const { store, scope, grantId } = authorize();
  change();
  const candidate = captureCandidate(scope).candidate;
  writeFileSync(join(repo, "file"), "three\n");
  git("add", "file");
  artifacts();
  await expect(
    executeScoped(store, { requestId: "commit", grantId, action: "commit", candidate }, caller()),
  ).rejects.toThrow("candidate changed");
  expect(store.scopedSnapshot().grants[0].state).toBe("active");
});

test("policy-driven high-stakes candidate requires exact review, then carries content review to publication", async () => {
  const policy = JSON.parse(readFileSync(join(dir, "policy.json"), "utf8"));
  policy.policy.review = "always";
  json(join(dir, "policy.json"), policy);
  const { store, scope, grantId } = authorize();
  change();
  const check = JSON.parse(readFileSync(join(dir, "describe.json"), "utf8"));
  check.change.review = "required";
  json(join(dir, "describe.json"), check);
  const candidate = captureCandidate(scope).candidate;
  await expect(
    executeScoped(store, { requestId: "commit", grantId, action: "commit", candidate }, caller()),
  ).rejects.toThrow("review required");
  review(store, scope, grantId, candidate);
  expect(
    (await executeScoped(store, { requestId: "commit", grantId, action: "commit", candidate }, caller())).state,
  ).toBe("succeeded");
  expect(git("show", "-s", "--format=%B", "HEAD")).toContain("reviewed via Decisions picker");
  expect(git("show", "-s", "--format=%B", "HEAD")).not.toContain("Reviewed-by:");
  const published = captureCandidate(scope).candidate;
  expect(
    (
      await executeScoped(
        store,
        { requestId: "publish", grantId, action: "publish-fast-forward", candidate: published },
        caller(),
      )
    ).state,
  ).toBe("succeeded");
});

test("a hook-mutated private tree never becomes the authorized feature tip", async () => {
  const { store, scope, grantId } = authorize();
  change();
  const candidate = captureCandidate(scope).candidate;
  writeFileSync(join(repo, ".git/hooks/pre-commit"), "#!/bin/sh\nprintf evil > hook-added\ngit add hook-added\n", {
    mode: 0o755,
  });
  const receipt = await executeScoped(store, { requestId: "commit", grantId, action: "commit", candidate }, caller());
  expect(receipt.state).toBe("conflict");
  expect(git("rev-parse", "HEAD")).toBe(candidate.head);
  expect(store.scopedSnapshot().grants[0].state).toBe("ended");
});

test("merge state and unsupported structured fields cannot gain effects", async () => {
  const { store, scope, grantId } = authorize();
  change();
  const candidate = captureCandidate(scope).candidate;
  await expect(
    executeScoped(
      store,
      { requestId: "compound", grantId, action: "commit", candidate, command: "git push --force; evil" } as never,
      caller(),
    ),
  ).rejects.toThrow("structured");
  writeFileSync(join(repo, ".git/MERGE_HEAD"), candidate.head);
  await expect(
    executeScoped(store, { requestId: "merge", grantId, action: "commit", candidate }, caller()),
  ).rejects.toThrow("merge/rewrite");
  expect(store.scopedSnapshot().actions).toHaveLength(0);
});

test.each([".env", ".env.production", "credentials.json", "config/live.toml", ".bercail/policy.toml"])(
  "secret/config candidate path %s cannot be committed",
  (path) => {
    const { scope } = authorize();
    mkdirSync(join(repo, path.substring(0, path.lastIndexOf("/")) || "."), { recursive: true });
    writeFileSync(join(repo, path), "secret\n");
    git("add", path);
    artifacts();
    expect(() => captureCandidate(scope)).toThrow("secrets/config paths");
  },
);

test("remote advance before start ends the grant without overwriting the remote", async () => {
  const { store, scope, grantId } = authorize();
  change();
  const candidate = captureCandidate(scope).candidate;
  expect(
    (await executeScoped(store, { requestId: "commit", grantId, action: "commit", candidate }, caller())).state,
  ).toBe("succeeded");
  const published = captureCandidate(scope).candidate;
  const other = execFileSync(
    "git",
    ["-C", repo, "commit-tree", `${candidate.head}^{tree}`, "-p", candidate.head, "-m", "external"],
    { env: process.env, encoding: "utf8" },
  ).trim();
  git("push", "-q", "origin", `${other}:refs/heads/feature`);
  await expect(
    executeScoped(
      store,
      { requestId: "publish", grantId, action: "publish-fast-forward", candidate: published },
      caller(),
    ),
  ).rejects.toThrow("not a known ancestor");
  expect(git("ls-remote", "--refs", bare)).toBe(`${other}\trefs/heads/feature`);
  expect(store.scopedSnapshot().grants[0].state).toBe("ended");
});

test("unfinished commit recovers by inspecting the actual checked parent/tree without a second commit", async () => {
  const { store, scope, grantId } = authorize();
  change();
  const candidate = captureCandidate(scope).candidate;
  store.beginScopedAction("lost", grantId, "commit", candidate, scope, () => new Date().toISOString(), false, {
    remoteHead: null,
    capability: SCOPED_CAPABILITY,
  });
  git("commit", "-qm", "effect before receipt lost");
  const head = git("rev-parse", "HEAD");
  store.prepareScopedCommit("lost", head);
  const receipt = await inspectScoped(new QuestionStore(join(dir, "questions")), "lost", caller());
  expect(receipt).toMatchObject({ state: "succeeded", result: head });
  expect(await executeScoped(store, { requestId: "lost", grantId, action: "commit", candidate }, caller())).toEqual(
    receipt,
  );
  expect(git("rev-list", "--count", "main..HEAD")).toBe("1");
});

test("uncertain publication remains quarantined even when the candidate is visible; duplicate never pushes", async () => {
  const { store, scope, grantId } = authorize();
  change();
  git("commit", "-qm", "fixture candidate");
  const candidate = captureCandidate(scope).candidate;
  store.beginScopedAction(
    "lost",
    grantId,
    "publish-fast-forward",
    candidate,
    scope,
    () => new Date().toISOString(),
    false,
    { remoteHead: scope.baseOid, capability: SCOPED_CAPABILITY },
  );
  git("push", "-q", "origin", `${candidate.head}:${scope.headRef}`);
  writeFileSync(join(repo, ".git/hooks/pre-push"), `#!/bin/sh\nprintf forbidden > '${dir}/resent'\nexit 1\n`, {
    mode: 0o755,
  });
  expect((await inspectScoped(new QuestionStore(join(dir, "questions")), "lost", caller())).state).toBe("inspect");
  expect(
    (await executeScoped(store, { requestId: "lost", grantId, action: "publish-fast-forward", candidate }, caller()))
      .state,
  ).toBe("inspect");
  await expect(
    executeScoped(store, { requestId: "new", grantId, action: "publish-fast-forward", candidate }, caller()),
  ).rejects.toThrow("inspection");
  expect(() => readFileSync(join(dir, "resent"))).toThrow();
});

test("publication quarantine survives endpoint errors, grant replacement and restored configuration", async () => {
  const { store, scope, grantId } = authorize();
  change();
  git("commit", "-qm", "fixture candidate");
  const candidate = captureCandidate(scope).candidate;
  store.beginScopedAction(
    "lost",
    grantId,
    "publish-fast-forward",
    candidate,
    scope,
    () => new Date().toISOString(),
    false,
    { remoteHead: scope.baseOid, capability: SCOPED_CAPABILITY },
  );
  git("config", "remote.origin.mirror", "true");
  expect((await inspectScoped(store, "lost", caller())).state).toBe("inspect");
  expect(store.scopedSnapshot().grants[0].state).toBe("ended");
  git("config", "--unset", "remote.origin.mirror");
  const spec = {
    kind: "scoped-authorization" as const,
    prompt: "Replacement?",
    options: ["Allow", "Stage only"],
    origin: { event: "replacement", session: "shep", entry: null },
    target: {
      repo: scope.repo,
      worktree: repo,
      issue: scope.issue,
      topic: "feature",
      desk: scope.desk,
      space: scope.space,
      session: scope.session,
      head: null,
      stagedTree: null,
      base: scope.baseOid,
      baseRef: scope.baseRef,
      action: "job",
    },
    authorization: {
      scope,
      actions: ["publish-fast-forward" as const],
      expiresAt: "2099-01-01T00:00:00.000Z",
      allowChoice: "Allow",
      stageOnlyChoice: "Stage only",
    },
  };
  const q = store.create("replacement", spec, (value) => value);
  store.answerScoped("replacement-pick", `${q.id}@${q.revision}`, "Allow", "panel picker", () => ({
    status: "fresh",
    reasons: [],
    current: { head: null, stagedTree: null },
    scope,
  }));
  const replacement = store.scopedSnapshot().grants[1];
  await expect(
    executeScoped(
      store,
      { requestId: "new", grantId: replacement.id, action: "publish-fast-forward", candidate },
      caller(),
    ),
  ).rejects.toThrow("inspection");
  expect(store.scopedSnapshot().actions[0].state).toBe("inspect");
});

test("closed job invalidates a grant instead of inheriting its old mapping", async () => {
  const { store, scope, grantId } = authorize();
  change();
  const candidate = captureCandidate(scope).candidate;
  fake("bd", `printf '[{"id":"app-1","status":"closed"}]'`);
  await expect(
    executeScoped(store, { requestId: "commit", grantId, action: "commit", candidate }, caller()),
  ).rejects.toThrow("closed");
  expect(store.scopedSnapshot().grants[0].state).toBe("ended");
});

test("a hook-mutated commit message is rejected before final feature ref CAS", async () => {
  const { store, scope, grantId } = authorize();
  change();
  const candidate = captureCandidate(scope).candidate;
  writeFileSync(join(repo, ".git/hooks/commit-msg"), '#!/bin/sh\nprintf "unexpected message\\n" > "$1"\n', {
    mode: 0o755,
  });
  const receipt = await executeScoped(store, { requestId: "commit", grantId, action: "commit", candidate }, caller());
  expect(receipt.state).toBe("conflict");
  expect(git("rev-parse", "HEAD")).toBe(candidate.head);
});

test("remote advancement after preflight is rejected by the actual nonforce Git ref update", async () => {
  const { store, scope, grantId } = authorize();
  change();
  const candidate = captureCandidate(scope).candidate;
  expect(
    (await executeScoped(store, { requestId: "commit", grantId, action: "commit", candidate }, caller())).state,
  ).toBe("succeeded");
  const published = captureCandidate(scope).candidate;
  writeFileSync(
    join(repo, ".git/hooks/pre-push"),
    `#!/bin/sh\nset -e\nother=$(git --git-dir='${bare}' commit-tree '${candidate.head}^{tree}' -p '${candidate.head}' -m external)\ngit --git-dir='${bare}' update-ref refs/heads/feature "$other"\n`,
    { mode: 0o755 },
  );
  const receipt = await executeScoped(
    store,
    { requestId: "publish", grantId, action: "publish-fast-forward", candidate: published },
    caller(),
  );
  expect(receipt.state).toBe("conflict");
  expect(store.scopedSnapshot().grants[0].state).toBe("ended");
  expect(git("ls-remote", "--refs", bare)).not.toContain(published.head);
});

test("native local gh-stack membership is unsupported before edits", () => {
  json(join(repo, ".git/gh-stack"), { stacks: [{ branches: [{ branch: "feature", pullRequest: { number: 1 } }] }] });
  expect(feasibility(input())).toMatchObject({
    supported: false,
    reason: expect.stringContaining("gh-stack publication"),
  });
});

test("remote gh-stack membership is unsupported before edits", () => {
  fake("gh", `case "$1" in pr) /bin/cat '${dir}/pr.json';; api) printf '[{"id":"stack"}]';; *) exit 2;; esac`);
  expect(feasibility(input())).toMatchObject({ supported: false, reason: expect.stringContaining("remote gh-stack") });
});

test.each([".graphite_repo_config", ".graphite_metadata.db"])(
  "ambiguous native marker %s never falls back to gh",
  (path) => {
    writeFileSync(join(repo, ".git", path), "unreadable native metadata");
    expect(feasibility(input())).toMatchObject({
      supported: false,
      reason: expect.stringContaining("unsupported or ambiguous"),
    });
  },
);

test("invalid backend override never silently selects gh", () => {
  mkdirSync(join(process.env.XDG_CONFIG_HOME!, "bercail"));
  writeFileSync(join(process.env.XDG_CONFIG_HOME!, "bercail/config.toml"), `[git]\n"${repo}" = "unknown"\n`);
  expect(feasibility(input())).toMatchObject({ supported: false });
});

test("outgoing intermediate secret add/delete cannot hide behind a clean net tree", async () => {
  const { store, scope, grantId } = authorize();
  writeFileSync(join(repo, "credentials.json"), "must not publish\n");
  git("add", "credentials.json");
  git("commit", "-qm", "temporary secret");
  git("rm", "-q", "credentials.json");
  writeFileSync(join(repo, "file"), "safe net diff\n");
  git("add", "file");
  git("commit", "-qm", "remove secret");
  artifacts();
  const candidate = {
    head: git("rev-parse", "HEAD"),
    tree: git("write-tree"),
    base: scope.baseOid,
    description: "a".repeat(64),
    evidence: "b".repeat(64),
  };
  expect(feasibility(input())).toMatchObject({
    supported: false,
    reason: expect.stringContaining("secrets/config paths"),
  });
  await expect(
    executeScoped(store, { requestId: "publish", grantId, action: "publish-fast-forward", candidate }, caller()),
  ).rejects.toThrow("secrets/config paths");
  expect(git("ls-remote", "--refs", bare)).toBe(`${scope.baseOid}\trefs/heads/feature`);
});

test("an outgoing merge commit is unsupported even when the final net tree is ordinary", () => {
  const { scope } = authorize();
  git("checkout", "-qb", "side");
  writeFileSync(join(repo, "side"), "side\n");
  git("add", "side");
  git("commit", "-qm", "side");
  git("checkout", "-q", "feature");
  change();
  git("commit", "-qm", "feature");
  git("merge", "--no-ff", "-qm", "merge", "side");
  artifacts();
  expect(feasibility(input())).toMatchObject({
    supported: false,
    reason: expect.stringContaining("merge/root histories"),
  });
  expect(git("ls-remote", "--refs", bare)).toBe(`${scope.baseOid}\trefs/heads/feature`);
});

test("paused same-owner grant resumes only after identical facts and fresh candidate checks", async () => {
  const { store, scope, grantId } = authorize();
  change();
  const candidate = captureCandidate(scope).candidate;
  fake("hc", "exit 3");
  await expect(
    executeScoped(store, { requestId: "commit", grantId, action: "commit", candidate }, caller()),
  ).rejects.toThrow();
  expect(store.scopedSnapshot().grants[0].state).toBe("paused");
  fake(
    "hc",
    `case "$1" in get) /bin/cat '${dir}/terminal.json';; ls) /bin/cat '${dir}/terminals.json';; *) exit 2;; esac`,
  );
  expect(
    (await executeScoped(store, { requestId: "commit", grantId, action: "commit", candidate }, caller())).state,
  ).toBe("succeeded");
  expect(store.scopedSnapshot().grants[0].state).toBe("active");
});

async function crashExecutorAt(
  mode: "hook" | "ref",
  store: QuestionStore,
  grantId: string,
  candidate: ScopedCandidate,
) {
  const gate = join(dir, "gate");
  const marker = join(dir, "barrier");
  execFileSync("mkfifo", [gate], { env: process.env });
  if (mode === "hook")
    writeFileSync(
      join(repo, ".git/hooks/pre-commit"),
      `#!/bin/sh\nprintf ready > '${marker}'\nread -r reply < '${gate}'\n`,
      { mode: 0o755 },
    );
  else {
    const realGit = execFileSync("which", ["git"], { env: process.env, encoding: "utf8" }).trim();
    fake(
      "git",
      `'${realGit}' "$@"\nrc=$?\nif test "$1 $2 $3" = 'update-ref -m scoped checked commit'; then printf ready > '${marker}'; read -r reply < '${gate}'; fi\nexit "$rc"`,
    );
  }
  const script = join(dir, "executor.mjs");
  writeFileSync(
    script,
    `import { QuestionStore } from ${JSON.stringify(new URL("../shep/pi/questions.ts", import.meta.url).href)};\nimport { executeScoped } from ${JSON.stringify(new URL("../shep/pi/scoped-execution.ts", import.meta.url).href)};\nawait executeScoped(new QuestionStore(${JSON.stringify(join(dir, "questions"))}), ${JSON.stringify({ requestId: "crash", grantId, action: "commit", candidate })}, ${JSON.stringify(caller())});\n`,
  );
  const ready = new Promise<void>((resolve, reject) => {
    const watcher = watch(dir, () => {
      if (existsSync(marker)) {
        clearTimeout(timer);
        watcher.close();
        resolve();
      }
    });
    const timer = setTimeout(() => {
      watcher.close();
      reject(new Error("executor barrier not reached"));
    }, 10000);
  });
  const child = spawn(process.execPath, [script], { cwd: repo, env: process.env, stdio: "ignore" });
  try {
    await ready;
    const died = once(child, "exit");
    child.kill("SIGKILL");
    await died;
    let retained = false;
    try {
      await inspectScoped(store, "crash", caller());
    } catch (error) {
      retained = (error as Error).message.includes("lock is unavailable");
    }
    writeFileSync(gate, "go\n");
    const lockDir = join(process.env.XDG_STATE_HOME!, "bercail/scoped-locks");
    execFileSync("flock", ["--exclusive", "--wait", "5", join(lockDir, readdirSync(lockDir)[0]), "true"], {
      env: process.env,
    });
    const receipt = await inspectScoped(new QuestionStore(join(dir, "questions")), "crash", caller());
    return { retained, receipt };
  } finally {
    child.kill("SIGKILL");
  }
}

test("SIGKILL during hooks retains the execution FD and recovery removes only its dead owner's index lock", async () => {
  const { store, scope, grantId } = authorize();
  change();
  const candidate = captureCandidate(scope).candidate;
  const { retained, receipt } = await crashExecutorAt("hook", store, grantId, candidate);
  expect(retained).toBe(true);
  expect(receipt.state).toBe("inspect");
  expect(git("rev-parse", "HEAD")).toBe(candidate.head);
  expect(existsSync(join(repo, ".git/index.lock"))).toBe(false);
  expect(
    (await executeScoped(store, { requestId: "crash", grantId, action: "commit", candidate }, caller())).state,
  ).toBe("inspect");
});

test("SIGKILL after ref CAS recovers the one checked commit without replaying it", async () => {
  const { store, scope, grantId } = authorize();
  change();
  const candidate = captureCandidate(scope).candidate;
  const { retained, receipt } = await crashExecutorAt("ref", store, grantId, candidate);
  expect(retained).toBe(true);
  expect(receipt).toMatchObject({ state: "succeeded", result: git("rev-parse", "HEAD") });
  expect(git("rev-list", "--count", "main..HEAD")).toBe("1");
  expect(existsSync(join(repo, ".git/index.lock"))).toBe(false);
  expect(
    (await executeScoped(store, { requestId: "crash", grantId, action: "commit", candidate }, caller())).state,
  ).toBe("succeeded");
});

test("inspection leaves an unrelated Git index.lock untouched", async () => {
  const { store, scope, grantId } = authorize();
  change();
  const candidate = captureCandidate(scope).candidate;
  store.beginScopedAction("lost", grantId, "commit", candidate, scope, () => new Date().toISOString(), false, {
    remoteHead: null,
    capability: SCOPED_CAPABILITY,
  });
  writeFileSync(join(repo, ".git/index.lock"), "foreign git lock");
  expect((await inspectScoped(store, "lost", caller())).state).toBe("inspect");
  expect(readFileSync(join(repo, ".git/index.lock"), "utf8")).toBe("foreign git lock");
});

test("an inaccessible replacement endpoint still ends the observed old config binding permanently", async () => {
  const { store, scope, grantId } = authorize();
  change();
  const candidate = captureCandidate(scope).candidate;
  git("remote", "set-url", "origin", join(dir, "missing.git"));
  await expect(
    executeScoped(store, { requestId: "commit", grantId, action: "commit", candidate }, caller()),
  ).rejects.toThrow("policy/config scope binding changed");
  expect(store.scopedSnapshot().grants[0].state).toBe("ended");
  git("remote", "set-url", "origin", bare);
  await expect(
    executeScoped(store, { requestId: "commit", grantId, action: "commit", candidate }, caller()),
  ).rejects.toThrow("ended");
});

test.each([
  ["before the start claim", 2],
  ["after the claim but before an effect", 3],
] as const)("a closed PR observed %s ends the grant without effects", async (_phase, pass) => {
  const { store, scope, grantId } = authorize();
  change();
  const candidate = captureCandidate(scope).candidate;
  const run = (requestId: string) =>
    executeScoped(store, { requestId, grantId, action: "commit", candidate }, caller());
  writeFileSync(join(repo, ".git/hooks/pre-commit"), `#!/bin/sh\nprintf started > '${dir}/hook-started'\n`, {
    mode: 0o755,
  });
  writeFileSync(join(dir, "counter"), "0\n");
  const pr = JSON.parse(readFileSync(join(dir, "pr.json"), "utf8"));
  pr.state = "CLOSED";
  json(join(dir, "closed-pr.json"), pr);
  fake(
    "gh",
    `case "$1" in api) printf '[]';; pr) n=$(/bin/cat '${dir}/counter'); n=$((n+1)); printf '%s' "$n" > '${dir}/counter'; if test "$n" -eq '${pass}'; then /bin/cat '${dir}/closed-pr.json'; else /bin/cat '${dir}/pr.json'; fi;; *) exit 2;; esac`,
  );
  if (pass === 2) {
    await expect(run("commit")).rejects.toThrow("PR repository/head/base binding changed");
    expect(store.scopedSnapshot().actions).toEqual([]);
  } else {
    expect(await run("commit")).toMatchObject({ state: "no-effect", expectedCommit: null });
  }
  expect(store.scopedSnapshot().grants[0].state).toBe("ended");
  expect(git("rev-parse", "HEAD")).toBe(candidate.head);
  expect(existsSync(join(dir, "hook-started"))).toBe(false);
  fake("gh", `case "$1" in api) printf '[]';; pr) /bin/cat '${dir}/pr.json';; *) exit 2;; esac`);
  if (pass === 3) expect(await run("commit")).toEqual(store.scopedSnapshot().actions[0]);
  await expect(run("new-commit")).rejects.toThrow("ended");
  expect(git("rev-parse", "HEAD")).toBe(candidate.head);
  expect(existsSync(join(dir, "hook-started"))).toBe(false);
});

test("a differently labelled writer in a worktree subdirectory also conflicts", () => {
  mkdirSync(join(repo, "nested"));
  const owner = JSON.parse(readFileSync(join(dir, "terminal.json"), "utf8"));
  json(join(dir, "terminals.json"), {
    terminals: [owner, { address: "t10", state: "live", cwd: join(repo, "nested"), records: {}, labels: {} }],
  });
  expect(feasibility(input())).toMatchObject({
    supported: false,
    reason: expect.stringContaining("can write this worktree"),
  });
});

test("an unlisted live process claim in the worktree is still a competing writer", async () => {
  const child = spawn(process.execPath, ["-e", "process.stdout.write('ready'); process.stdin.resume()"], {
    cwd: repo,
    env: process.env,
    stdio: ["pipe", "pipe", "pipe"],
  });
  try {
    await once(child.stdout!, "data");
    const stat = readFileSync(`/proc/${child.pid}/stat`, "utf8");
    json(join(process.env.XDG_RUNTIME_DIR!, `bercail/open-sessions/${child.pid}.json`), {
      pid: child.pid,
      start_ticks: stat
        .slice(stat.lastIndexOf(")") + 2)
        .trim()
        .split(/\s+/)[19],
      sessions: ["sibling-session"],
    });
    expect(feasibility(input())).toMatchObject({
      supported: false,
      reason: expect.stringContaining("can write this worktree"),
    });
  } finally {
    const died = once(child, "exit");
    child.kill("SIGKILL");
    await died;
  }
});

test.each(["line", "trailer", "none"])(
  "commit provenance follows %s policy using only stamped agent and durable review source",
  async (provenance) => {
    const policy = JSON.parse(readFileSync(join(dir, "policy.json"), "utf8"));
    policy.policy.provenance = provenance;
    policy.policy.review = "always";
    json(join(dir, "policy.json"), policy);
    const { store, scope, grantId } = authorize();
    change();
    const check = JSON.parse(readFileSync(join(dir, "describe.json"), "utf8"));
    check.change.review = "required";
    json(join(dir, "describe.json"), check);
    const candidate = captureCandidate(scope).candidate;
    review(store, scope, grantId, candidate);
    expect(
      (await executeScoped(store, { requestId: "commit", grantId, action: "commit", candidate }, caller())).state,
    ).toBe("succeeded");
    const message = git("show", "-s", "--format=%B", "HEAD");
    if (provenance === "line")
      expect(message).toContain("Written with bercail (Pi, fixture-model); reviewed via Decisions picker");
    else if (provenance === "trailer")
      expect(message).toContain("Assisted-by: bercail (Pi, fixture-model)\nReview-source: Decisions picker");
    else expect(message).toBe("Feature\n\nA checked feature.");
    expect(message).not.toContain("Reviewed-by:");
  },
);

test("a config rebinding while begin waits on the ledger lock is rejected before effect start", async () => {
  const { store, scope, grantId } = authorize();
  change();
  const candidate = captureCandidate(scope).candidate;
  const realFlock = execFileSync("which", ["flock"], { env: process.env, encoding: "utf8" }).trim();
  const realGit = execFileSync("which", ["git"], { env: process.env, encoding: "utf8" }).trim();
  const gate = join(dir, "claim-gate");
  const locked = join(dir, "claim-locked");
  const marker = join(dir, "claim-marker");
  execFileSync("mkfifo", [gate, locked], { env: process.env });
  writeFileSync(join(dir, "flock-counter"), "0");
  const holder = join(dir, "ledger-holder.sh");
  writeFileSync(
    holder,
    `#!/bin/sh\nprintf ready > '${locked}'\nread -r reply < '${gate}'\n'${realGit}' -C '${repo}' config core.scopedProbe changed\n`,
    { mode: 0o755 },
  );
  fake(
    "flock",
    `if test "$1 $2 $3 $4" = '-x -w 10 3'; then n=$(/bin/cat '${dir}/flock-counter'); n=$((n+1)); printf '%s' "$n" > '${dir}/flock-counter'; if test "$n" -eq 4; then '${realFlock}' --exclusive '${dir}/questions/questions.lock' '${holder}' </dev/null >/dev/null 2>&1 & read -r reply < '${locked}'; printf ready > '${marker}'; fi; fi\nexec '${realFlock}' "$@"`,
  );
  writeFileSync(join(repo, ".git/hooks/pre-commit"), `#!/bin/sh\nprintf forbidden > '${dir}/effect-started'\n`, {
    mode: 0o755,
  });
  const script = join(dir, "claim-executor.mjs");
  writeFileSync(
    script,
    `import { QuestionStore } from ${JSON.stringify(new URL("../shep/pi/questions.ts", import.meta.url).href)}; import { executeScoped } from ${JSON.stringify(new URL("../shep/pi/scoped-execution.ts", import.meta.url).href)}; console.log(JSON.stringify(await executeScoped(new QuestionStore(${JSON.stringify(join(dir, "questions"))}), ${JSON.stringify({ requestId: "waited", grantId, action: "commit", candidate })}, ${JSON.stringify(caller())})));`,
  );
  const ready = new Promise<void>((resolve, reject) => {
    const watcher = watch(dir, () => {
      if (existsSync(marker)) {
        clearTimeout(timer);
        watcher.close();
        resolve();
      }
    });
    const timer = setTimeout(() => {
      watcher.close();
      reject(new Error("ledger wait barrier not reached"));
    }, 10000);
  });
  const child = spawn(process.execPath, [script], { cwd: repo, env: process.env, stdio: ["ignore", "pipe", "pipe"] });
  let output = "";
  let errors = "";
  child.stdout.on("data", (chunk) => {
    output += chunk.toString();
  });
  child.stderr.on("data", (chunk) => {
    errors += chunk.toString();
  });
  try {
    const finished = once(child, "close");
    await ready;
    writeFileSync(gate, "go\n");
    const [code] = await finished;
    expect(errors).toBe("");
    expect(code).toBe(0);
    expect(JSON.parse(output).state).toBe("no-effect");
    expect(store.scopedSnapshot().grants[0].state).toBe("ended");
    expect(git("rev-parse", "HEAD")).toBe(candidate.head);
    expect(existsSync(join(dir, "effect-started"))).toBe(false);
  } finally {
    child.kill("SIGKILL");
  }
});

test.each([
  "https://user:pr-secret@github.com/test/app/pull/1",
  "https://github.com/test/app/pull/1?secret=pr-secret",
  "https://github.com/test/app/pull/1#pr-secret",
])("PR addressing rejects credentials/query/fragment before argv: %s", (pr) => {
  const result = feasibility({ ...input(), pr });
  expect(result).toMatchObject({ supported: false });
  expect(JSON.stringify(result)).not.toContain("pr-secret");
  expect(existsSync(join(dir, "argv"))).toBe(false);
});

test("rewrite-config key credentials are not printed in a refusal", () => {
  git("config", "url.https://user:config-secret@example.invalid/.insteadOf", "https://github.com/");
  const result = feasibility(input());
  expect(result).toMatchObject({ supported: false });
  expect(JSON.stringify(result)).not.toContain("config-secret");
  expect(readFileSync(join(dir, "argv"), "utf8")).not.toContain("config-secret");
});

test("the owning space's proven idle Shell is not a competing writer", () => {
  const owner = JSON.parse(readFileSync(join(dir, "terminal.json"), "utf8"));
  json(join(dir, "terminals.json"), {
    terminals: [
      owner,
      {
        address: "t8",
        state: "live",
        cwd: repo,
        pid: 900,
        foreground: { pid: 900, name: "bash", cwd: repo },
        reported: false,
        records: {},
        labels: { "herdr.space": "sp1" },
      },
    ],
  });
  expect(feasibility(input())).toMatchObject({ supported: true });
});

test("a Shell running a foreground command in the owning worktree is a competing writer", () => {
  const owner = JSON.parse(readFileSync(join(dir, "terminal.json"), "utf8"));
  json(join(dir, "terminals.json"), {
    terminals: [
      owner,
      {
        address: "t8",
        state: "live",
        cwd: repo,
        pid: 900,
        foreground: { pid: 901, name: "git", cwd: repo },
        reported: false,
        records: {},
        labels: { "herdr.space": "sp1" },
      },
    ],
  });
  expect(feasibility(input())).toMatchObject({
    supported: false,
    reason: expect.stringContaining("can write this worktree"),
  });
});

test("an unrelated matching parent/tree commit is not blessed without the durable prepared OID", async () => {
  const { store, scope, grantId } = authorize();
  change();
  const candidate = captureCandidate(scope).candidate;
  store.beginScopedAction("lost", grantId, "commit", candidate, scope, () => new Date().toISOString(), false, {
    remoteHead: null,
    capability: SCOPED_CAPABILITY,
  });
  git("commit", "-qm", "unrelated external replacement message");
  const receipt = await inspectScoped(store, "lost", caller());
  expect(receipt.state).toBe("conflict");
  expect(store.scopedSnapshot().grants[0].state).toBe("ended");
});

test("a different replacement OID is not blessed even when its parent/tree match a prepared commit", async () => {
  const { store, scope, grantId } = authorize();
  change();
  const candidate = captureCandidate(scope).candidate;
  store.beginScopedAction("lost", grantId, "commit", candidate, scope, () => new Date().toISOString(), false, {
    remoteHead: null,
    capability: SCOPED_CAPABILITY,
  });
  const prepared = git("commit-tree", candidate.tree, "-p", candidate.head, "-m", "checked fixture commit");
  store.prepareScopedCommit("lost", prepared);
  git("commit", "-qm", "unrelated external replacement message");
  const receipt = await inspectScoped(store, "lost", caller());
  expect(receipt.state).toBe("conflict");
  expect(receipt.result).not.toBe(git("rev-parse", "HEAD"));
});

test("an unknown or recovering foreground pauses a same-worktree grant instead of assuming idle", async () => {
  const { store, scope, grantId } = authorize();
  change();
  const candidate = captureCandidate(scope).candidate;
  const owner = JSON.parse(readFileSync(join(dir, "terminal.json"), "utf8"));
  json(join(dir, "terminals.json"), {
    terminals: [
      owner,
      {
        address: "t8",
        state: "live",
        cwd: repo,
        pid: 900,
        foreground: null,
        reason: "recovering",
        records: {},
        labels: {},
      },
    ],
  });
  await expect(
    executeScoped(store, { requestId: "commit", grantId, action: "commit", candidate }, caller()),
  ).rejects.toThrow("can write this worktree");
  expect(store.scopedSnapshot().grants[0].state).toBe("paused");
});

test("revocation before start denies commit", async () => {
  const { store, scope, grantId } = authorize();
  change();
  const candidate = captureCandidate(scope).candidate;
  store.revokeGrant(grantId, "person revoked");
  await expect(
    executeScoped(store, { requestId: "commit", grantId, action: "commit", candidate }, caller()),
  ).rejects.toThrow("ended");
  expect(git("rev-parse", "HEAD")).toBe(candidate.head);
});
