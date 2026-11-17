import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, expect, test } from "vite-plus/test";
import { pick, closed } from "../shep/pi/discuss.ts";
import { QuestionStore, tokenOf } from "../shep/pi/questions.ts";
import { checkQuestion } from "../shep/pi/question-target.ts";
import { scopedQuestionSpec, type ScopedQuestionInput } from "../shep/pi/scoped-questions.ts";

let dir: string;
let repo: string;
let bare: string;
let state: string;
let saved: NodeJS.ProcessEnv;
let store: QuestionStore;
const json = (path: string, value: unknown) => writeFileSync(path, JSON.stringify(value));
const git = (...args: string[]) =>
  execFileSync("git", ["-C", repo, ...args], {
    env: process.env,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  }).trim();
const input = (): ScopedQuestionInput => ({
  kind: "scoped-authorization",
  repo,
  issue: "app-1",
  topic: "feature",
  desk: "t9",
  base: "main",
  pr: "https://github.com/test/app/pull/1",
  remote: "origin",
  actions: ["commit", "publish-fast-forward"],
  expiresAt: "2099-01-01T00:00:00Z",
  origin: { event: "fixture", session: "shep-session", entry: null },
});
function create(overrides: Partial<ScopedQuestionInput> = {}, requestId = "create") {
  const intent = { ...input(), ...overrides };
  const spec = scopedQuestionSpec(store, intent);
  return store.create(requestId, intent, () => spec);
}
function fake(name: string, body: string) {
  writeFileSync(join(dir, "bin", name), `#!/bin/sh\nprintf '%s %s\\n' '${name}' "$*" >> '${dir}/argv'\n${body}\n`, {
    mode: 0o755,
  });
}
beforeEach(() => {
  saved = process.env;
  process.env = Object.fromEntries(
    Object.entries(saved).filter(
      ([key]) => !/^(HC_|HERDR_|BERCAIL_|BEADS_|BD_|GIT_|XDG_)/.test(key) && key !== "BASH_ENV",
    ),
  );
  dir = mkdtempSync(join(tmpdir(), "shep-scoped-picker-"));
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
  state = join(dir, "questions");
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
    start_ticks: stat
      .slice(stat.lastIndexOf(")") + 2)
      .trim()
      .split(/\s+/)[19],
    sessions: ["desk-session"],
  });
  const terminal = {
    address: "t9",
    state: "live",
    cwd: repo,
    foreground: { pid: process.pid, cwd: repo },
    labels: { "bercail.role": "agent", "bercail.issue": "app-1", "bercail.space": "sp1" },
    records: { "desk-session": { app: "pi" } },
  };
  json(join(dir, "terminal.json"), terminal);
  json(join(dir, "terminals.json"), {
    terminals: [
      terminal,
      {
        address: "shell",
        state: "live",
        cwd: repo,
        pid: process.ppid,
        foreground: { pid: process.ppid, name: "bash", cwd: repo },
        reported: false,
        records: {},
        labels: { "bercail.space": "sp1" },
      },
    ],
  });
  json(join(dir, "policy.json"), {
    repo,
    root: repo,
    trusted: true,
    sha256: "one",
    sources: { review: "local" },
    policy: { commit: "allow", push: "main", integrate: "direct", review: "by-stakes", high_stakes: [] },
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
  json(join(dir, "job.json"), [{ id: "app-1", status: "open" }]);
  fake(
    "hc",
    `case "$1" in get) /bin/cat '${dir}/terminal.json';; ls) /bin/cat '${dir}/terminals.json';; *) exit 2;; esac`,
  );
  fake("bd", `test "$1 $2 $3" = 'show app-1 --json' || exit 2\n/bin/cat '${dir}/job.json'`);
  fake("gh", `case "$1 $2" in 'pr view') /bin/cat '${dir}/pr.json';; 'api --hostname') printf '[]';; *) exit 2;; esac`);
  fake(
    "bercail",
    `case "$1 $2" in 'policy show') /bin/cat '${dir}/policy.json';; 'describe check') /bin/cat '${dir}/describe.json';; *) exit 2;; esac`,
  );
  for (const name of ["gt", "origin", "entire"]) fake(name, "exit 97");
  const tree = git("write-tree");
  mkdirSync(join(repo, ".bercail"));
  writeFileSync(
    join(repo, ".bercail/description.md"),
    `---\ntitle: Feature\ntree: ${tree}\nbase: ${git("rev-parse", "main")}\n---\nChecked candidate.\n`,
  );
  json(join(repo, ".bercail/validate.json"), {
    tree,
    checks: [{ kind: "test", command: "fixture", exit_code: 0, evidence: "passed" }],
  });
  json(join(dir, "describe.json"), {
    file: join(repo, ".bercail/description.md"),
    tree,
    current_tree: tree,
    stale: false,
    fails: [],
    change: { review: "required", high_stakes: ["file"] },
  });
  store = new QuestionStore(state);
});
afterEach(() => {
  process.env = saved;
  rmSync(dir, { recursive: true, force: true });
});

test("supported panel picker resolves the actual target and creates one durable grant", async () => {
  const q = create();
  expect(q.authorization!.scope).toMatchObject({ repo: join(repo, ".git"), endpoint: bare, session: "desk-session" });
  expect(q.brief).toContain(bare);
  const first = await pick(state, "pick", tokenOf(q), q.authorization!.allowChoice, "panel picker");
  expect(first.accepted).toBe(true);
  expect((await pick(state, "pick", tokenOf(q), q.authorization!.allowChoice, "panel picker")).accepted).toBe(true);
  expect(new QuestionStore(state).scopedSnapshot().grants).toHaveLength(1);
  expect(readdirSync(join(state, "inbox"))).toHaveLength(1);
  expect(readFileSync(join(dir, "argv"), "utf8")).not.toMatch(/^(gt|origin|entire) /m);
});

test("CLI scoped creation ignores caller-asserted scope and uses the live resolver", () => {
  const q = JSON.parse(
    execFileSync(process.execPath, [join(saved.PWD || process.cwd(), "shep/pi/question-cli.ts"), "create"], {
      env: { ...process.env, BERCAIL_SHEP_STATE: state },
      encoding: "utf8",
      input: JSON.stringify({ ...input(), requestId: "cli-create", authorization: { scope: { repo: "/forged" } } }),
    }),
  );
  expect(q.kind).toBe("scoped-authorization");
  expect(q.authorization.scope.repo).toBe(join(repo, ".git"));
  expect(q.authorization.scope.endpoint).toBe(bare);
  expect(store.scopedSnapshot().grants).toEqual([]);
});

test("source and freshness claims through the old answer API cannot mint a grant", () => {
  const q = create();
  const result = store.answer("forged", tokenOf(q), q.authorization!.allowChoice, "panel picker", {
    status: "fresh",
    reasons: [],
    current: { head: null, stagedTree: null },
  });
  expect(result.accepted).toBe(false);
  expect(result.question.status).toBe("pending");
  expect(store.scopedSnapshot().grants).toEqual([]);
});

test("reply proposals and Discuss closure notify without creating authority", () => {
  const q = create();
  store.propose("reply", tokenOf(q), q.authorization!.allowChoice, "interactive:verified");
  expect(closed(state, tokenOf(q), "opening")).toBe(true);
  expect(store.snapshot().questions[0]!.status).toBe("pending");
  expect(store.scopedSnapshot().grants).toEqual([]);
});

test("stage-only pick creates no grant despite permissive independent policy", async () => {
  const q = create();
  expect((await pick(state, "stage", tokenOf(q), q.authorization!.stageOnlyChoice, "discuss picker")).accepted).toBe(
    true,
  );
  expect(store.scopedSnapshot().grants).toEqual([]);
});

test("a changed endpoint is not accepted by the supported picker", async () => {
  const q = create();
  const other = join(dir, "other.git");
  git("init", "--bare", "-q", other);
  git("remote", "set-url", "origin", other);
  expect((await pick(state, "pick", tokenOf(q), q.authorization!.allowChoice, "panel picker")).accepted).toBe(false);
  expect(store.scopedSnapshot().grants).toEqual([]);
});

test("observing changed scope while reviewing ends the grant even if the binding returns", async () => {
  const q = create();
  await pick(state, "grant", tokenOf(q), q.authorization!.allowChoice, "panel picker");
  const grant = store.scopedSnapshot().grants[0]!;
  const review = create({ kind: "candidate-review", grantId: grant.id }, "review");
  git("remote", "set-url", "origin", join(dir, "missing.git"));
  expect((await checkQuestion(review, state)).fresh).toBe(false);
  git("remote", "set-url", "origin", bare);
  expect(store.scopedSnapshot().grants[0]!.state).toBe("ended");
  expect((await pick(state, "review-pick", tokenOf(review), review.review!.allowChoice, "panel picker")).accepted).toBe(
    false,
  );
  expect(store.scopedSnapshot().reviews).toEqual([]);
});

test("expired pending question cannot be activated", async () => {
  const q = create({ expiresAt: "2000-01-01T00:00:00Z" });
  expect((await pick(state, "pick", tokenOf(q), q.authorization!.allowChoice, "panel picker")).accepted).toBe(false);
  expect(store.scopedSnapshot().grants).toEqual([]);
});

test("candidate-review picker records only the checked candidate and rejects changed evidence", async () => {
  const q = create();
  await pick(state, "grant", tokenOf(q), q.authorization!.allowChoice, "panel picker");
  const grant = store.scopedSnapshot().grants[0]!;
  const review = create({ kind: "candidate-review", grantId: grant.id }, "review");
  expect((await checkQuestion(review, state)).status).toBe("fresh");
  expect(
    (await pick(state, "review-pick", tokenOf(review), review.review!.allowChoice, "discuss picker")).accepted,
  ).toBe(true);
  expect(store.scopedSnapshot().reviews).toHaveLength(1);
  const next = create({ kind: "candidate-review", grantId: grant.id }, "review-next");
  writeFileSync(join(repo, ".bercail/description.md"), "changed description\n");
  expect((await pick(state, "stale-pick", tokenOf(next), next.review!.allowChoice, "panel picker")).accepted).toBe(
    false,
  );
  expect(store.scopedSnapshot().reviews).toHaveLength(1);
  expect(store.scopedSnapshot().grants[0]!.state).toBe("active");
});
