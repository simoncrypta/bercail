import { execFileSync, spawnSync } from "node:child_process";
import { appendFileSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { afterEach, beforeEach, describe, expect, test } from "vite-plus/test";
import { captureTarget } from "../shep/pi/question-target.ts";
import { claim, eventLine } from "../shep/pi/inbox.ts";

const cli = resolve("shep/pi/question-cli.ts");
const node = process.execPath;
let dir: string;
let repo: string;
let env: NodeJS.ProcessEnv;
const json = (file: string, value: unknown) => writeFileSync(file, JSON.stringify(value));
const git = (...args: string[]) => execFileSync("git", ["-C", repo, ...args], { env, encoding: "utf8" }).trim();
function call(op: string, input?: unknown, args: string[] = []) {
  return spawnSync(node, [cli, op, ...args], {
    env,
    cwd: dir,
    encoding: "utf8",
    input: input === undefined ? undefined : JSON.stringify(input),
  });
}
function ok(op: string, input?: unknown, args: string[] = []) {
  const result = call(op, input, args);
  expect(result.stderr).toBe("");
  expect(result.status).toBe(0);
  return JSON.parse(result.stdout);
}
function spec(extra: Record<string, unknown> = {}) {
  return {
    requestId: "create-one",
    kind: "review",
    prompt: "Review this candidate?",
    options: ["yes", "no"],
    origin: { event: "finished:1", session: "shep-session", entry: "entry-1" },
    repo,
    issue: "app-1",
    topic: "login",
    desk: "t9",
    base: "HEAD",
    action: "stage-only review",
    ...extra,
  };
}
function terminal(extra: Record<string, unknown> = {}) {
  json(join(dir, "terminal.json"), {
    address: "t9",
    state: "live",
    cwd: repo,
    labels: { "bercail.role": "agent", "bercail.issue": "app-1", "bercail.space": "sp1" },
    records: { "desk-session": { app: "pi", state: "working" } },
    ...extra,
  });
}
function record(extra: Record<string, unknown> = {}) {
  json(join(env.XDG_STATE_HOME!, "bercail/desk-sessions/t9.json"), {
    address: "t9",
    session: "desk-session",
    cwd: repo,
    harness: "pi",
    issue: "app-1",
    space: "sp1",
    ...extra,
  });
}

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "shep-question-cli-"));
  env = Object.fromEntries(
    Object.entries(process.env).filter(
      ([key]) => !/^(HC_|HERDR_|BERCAIL_|BEADS_|BD_|GIT_|XDG_)/.test(key) && key !== "BASH_ENV",
    ),
  );
  for (const key of [
    "HOME",
    "XDG_CONFIG_HOME",
    "XDG_STATE_HOME",
    "XDG_DATA_HOME",
    "XDG_CACHE_HOME",
    "XDG_RUNTIME_DIR",
    "TMPDIR",
  ]) {
    env[key] = join(dir, key.toLowerCase());
    mkdirSync(env[key]!, { recursive: true });
  }
  const bin = join(dir, "bin");
  mkdirSync(bin);
  env.PATH = `${bin}:${process.env.PATH}`;
  env.TZ = "UTC";
  env.LC_ALL = "C";
  env.GIT_CONFIG_NOSYSTEM = "1";
  env.GIT_AUTHOR_NAME = env.GIT_COMMITTER_NAME = "Test";
  env.GIT_AUTHOR_EMAIL = env.GIT_COMMITTER_EMAIL = "test@example.invalid";
  env.GIT_AUTHOR_DATE = env.GIT_COMMITTER_DATE = "2026-01-01T00:00:00Z";
  env.BERCAIL_SHEP_STATE = join(dir, "questions");
  env.BERCAIL_SHEP_BIN = join(bin, "bercail");
  repo = join(dir, "repo");
  mkdirSync(repo);
  git("init", "-q");
  writeFileSync(join(repo, "file"), "one\n");
  git("add", "file");
  git("commit", "-qm", "initial");
  mkdirSync(join(env.XDG_STATE_HOME!, "bercail/desk-sessions"), { recursive: true });
  terminal();
  record();
  json(join(dir, "issue.json"), [{ id: "app-1", title: "Login" }]);
  json(join(dir, "policy.json"), {
    repo,
    root: repo,
    sha256: "policy-one",
    trusted: true,
    policy: { integrate: "direct" },
  });
  const fake = (name: string, body: string) =>
    writeFileSync(join(bin, name), `#!/bin/sh\nprintf '%s %s\\n' '${name}' "$*" >> '${dir}/argv'\n${body}\n`, {
      mode: 0o755,
    });
  fake("hc", `test "$1 $2 $3" = 'get t9 --json' || exit 2\n/bin/cat '${dir}/terminal.json'`);
  fake(
    "bd",
    `test "$PWD" = '${repo}' || exit 2\ntest "$1 $2 $3" = 'show app-1 --json' || exit 2\n/bin/cat '${dir}/issue.json'`,
  );
  fake("bercail", `test "$1 $2 $3 $4" = 'policy show --json ${repo}' || exit 2\n/bin/cat '${dir}/policy.json'`);
});
afterEach(() => rmSync(dir, { recursive: true, force: true }));

test("target helper resolves facts from the explicitly named checkout", () => {
  const saved = process.env;
  try {
    process.env = env;
    expect(captureTarget(spec() as Parameters<typeof captureTarget>[0])).toMatchObject({
      repo: join(repo, ".git"),
      worktree: repo,
      session: "desk-session",
      stagedTree: git("write-tree"),
    });
  } finally {
    process.env = saved;
  }
});

test("requires an explicit state directory, never falls back to the real Shep state", () => {
  delete env.BERCAIL_SHEP_STATE;
  const result = call("list");
  expect(result.status).not.toBe(0);
  expect(result.stderr).toContain("BERCAIL_SHEP_STATE");
});

test("captures actual candidate and desk facts instead of accepting caller target fields", () => {
  const q = ok("create", spec({ target: { repo: "/forged", head: "forged", session: "forged" } }));
  expect(q.target).toMatchObject({
    repo: join(repo, ".git"),
    worktree: repo,
    desk: "t9",
    space: "sp1",
    session: "desk-session",
    head: git("rev-parse", "HEAD"),
    stagedTree: git("write-tree"),
    base: git("rev-parse", "HEAD"),
    action: "stage-only review",
  });
  expect(readFileSync(join(dir, "argv"), "utf8")).toContain("hc get t9 --json");
  expect(ok("check", undefined, [`${q.id}@${q.revision}`])).toMatchObject({ fresh: true, authority: false });
});

test("all worktrees share local repository identity but retain exact checkout identity", () => {
  const sibling = join(dir, "sibling");
  git("worktree", "add", "-q", "-b", "sibling", sibling);
  const q1 = ok("create", spec({ kind: "planning", issue: null, desk: null, base: null, action: null }));
  const q2 = ok(
    "create",
    spec({ requestId: "sibling", repo: sibling, kind: "planning", issue: null, desk: null, base: null, action: null }),
  );
  expect(q2.target.repo).toBe(q1.target.repo);
  expect(q2.target.worktree).toBe(sibling);
});

test("revision captures the new staged candidate and never makes the superseded token fresh", () => {
  const first = ok("create", spec());
  writeFileSync(join(repo, "file"), "revised\n");
  git("add", "file");
  const token = `${first.id}@${first.revision}`;
  const revised = ok("revise", spec({ requestId: "revise-one", token }));
  expect(revised.revision).toBe(first.revision + 1);
  expect(revised.target.stagedTree).toBe(git("write-tree"));
  expect(ok("check", undefined, [token])).toMatchObject({ fresh: false, authority: false });
  expect(ok("check", undefined, [`${revised.id}@${revised.revision}`])).toMatchObject({
    fresh: true,
    authority: false,
  });
});

test("identical create replay returns its durable receipt after the staged candidate changes", () => {
  const input = spec();
  const first = ok("create", input);
  const saved = readFileSync(join(env.BERCAIL_SHEP_STATE!, "questions.json"), "utf8");
  writeFileSync(join(repo, "file"), "two\n");
  git("add", "file");
  expect(ok("create", input)).toEqual(first);
  expect(readFileSync(join(env.BERCAIL_SHEP_STATE!, "questions.json"), "utf8")).toBe(saved);
});

test("identical create replay survives a disappeared desk mapping without recapturing it", () => {
  const input = spec();
  const first = ok("create", input);
  const saved = readFileSync(join(env.BERCAIL_SHEP_STATE!, "questions.json"), "utf8");
  const argv = readFileSync(join(dir, "argv"), "utf8");
  rmSync(join(env.XDG_STATE_HOME!, "bercail/desk-sessions/t9.json"));
  rmSync(join(dir, "terminal.json"));
  expect(ok("create", input)).toEqual(first);
  expect(readFileSync(join(env.BERCAIL_SHEP_STATE!, "questions.json"), "utf8")).toBe(saved);
  expect(readFileSync(join(dir, "argv"), "utf8")).toBe(argv);
});

test("create replay rejects changed logical input even after the desk mapping disappears", () => {
  const input = spec();
  ok("create", input);
  const saved = readFileSync(join(env.BERCAIL_SHEP_STATE!, "questions.json"), "utf8");
  rmSync(join(env.XDG_STATE_HOME!, "bercail/desk-sessions/t9.json"));
  const result = call("create", { ...input, prompt: "A different question?" });
  expect(result.status).not.toBe(0);
  expect(result.stderr).toContain("request id reused with different payload");
  expect(readFileSync(join(env.BERCAIL_SHEP_STATE!, "questions.json"), "utf8")).toBe(saved);
});

test("identical revise replay returns its original receipt after further revisions and mapping loss", () => {
  const first = ok("create", spec());
  const input = spec({ requestId: "revise-one", token: `${first.id}@${first.revision}`, prompt: "Revised?" });
  const revised = ok("revise", input);
  writeFileSync(join(repo, "file"), "three\n");
  git("add", "file");
  ok("revise", spec({ requestId: "revise-two", token: `${revised.id}@${revised.revision}`, prompt: "Again?" }));
  const saved = readFileSync(join(env.BERCAIL_SHEP_STATE!, "questions.json"), "utf8");
  rmSync(join(env.XDG_STATE_HOME!, "bercail/desk-sessions/t9.json"));
  expect(ok("revise", input)).toEqual(revised);
  const collision = call("revise", { ...input, prompt: "Changed retry?" });
  expect(collision.status).not.toBe(0);
  expect(collision.stderr).toContain("request id reused with different payload");
  expect(readFileSync(join(env.BERCAIL_SHEP_STATE!, "questions.json"), "utf8")).toBe(saved);
});

test("changed staged tree makes an old question stale without granting any action", () => {
  const q = ok("create", spec());
  writeFileSync(join(repo, "file"), "two\n");
  git("add", "file");
  const result = ok("check", undefined, [`${q.id}@${q.revision}`]);
  expect(result).toMatchObject({ fresh: false, authority: false });
  expect(JSON.stringify(result)).toContain("stagedTree");
});

test("a new commit leaves a planning question fresh but makes a review question stale", () => {
  const plan = ok("create", spec({ requestId: "plan", kind: "planning", topic: "plan", base: null, action: null }));
  const review = ok("create", spec());
  expect(plan.target).toMatchObject({ head: null, stagedTree: null });
  writeFileSync(join(repo, "file"), "two\n");
  git("commit", "-qam", "later");
  expect(ok("check", undefined, [`${plan.id}@${plan.revision}`])).toMatchObject({ fresh: true, status: "fresh" });
  expect(ok("check", undefined, [`${review.id}@${review.revision}`])).toMatchObject({ fresh: false, status: "stale" });
});

test("an approval names the staged tree: committing that tree keeps it, changing the tree does not", () => {
  writeFileSync(join(repo, "file"), "two\n");
  git("add", "file");
  const tree = git("write-tree");
  ok("create", spec());
  ok("create", spec({ requestId: "later", topic: "login-2" }));
  expect(pick("p1", "yes")).toMatchObject({ accepted: true, question: { answer: { stagedTree: tree } } });
  git("commit", "-qm", "the approved tree");
  expect(git("rev-parse", "HEAD^{tree}")).toBe(tree);
  // Shep re-reads the live state before it acts: the committed tree still holds.
  expect(ok("check", undefined, ["Q1@1"])).toMatchObject({ status: "fresh", reasons: [] });
  // A question still pending when its tree was committed can be answered.
  expect(pick("p2", "yes", "Q2@1")).toMatchObject({ accepted: true });
  writeFileSync(join(repo, "file"), "three\n");
  git("add", "file");
  expect(ok("check", undefined, ["Q1@1"])).toMatchObject({ status: "stale", reasons: ["stagedTree changed"] });
});

test("only one commit of the approved tree on the asked HEAD keeps an approval", () => {
  git("branch", "review-base");
  writeFileSync(join(repo, "file"), "two\n");
  git("add", "file");
  const tree = git("write-tree");
  ok("create", spec());
  ok("create", spec({ requestId: "outside", topic: "outside", base: "review-base" }));
  // Another ref moved onto the approved tree while this checkout stayed put: not this job's commit.
  const elsewhere = execFileSync("git", ["-C", repo, "commit-tree", tree, "-p", git("rev-parse", "HEAD")], {
    env,
    input: "landed elsewhere\n",
    encoding: "utf8",
  }).trim();
  git("update-ref", "refs/heads/review-base", elsewhere);
  expect(ok("check", undefined, ["Q2@1"])).toMatchObject({ status: "stale", reasons: ["base changed"] });
  // Other work, then back to the approved tree: the history holds commits nobody reviewed.
  writeFileSync(join(repo, "file"), "other\n");
  git("commit", "-qam", "unreviewed");
  writeFileSync(join(repo, "file"), "two\n");
  git("commit", "-qam", "back to the approved tree");
  expect(git("write-tree")).toBe(tree);
  expect(ok("check", undefined, ["Q1@1"])).toMatchObject({
    status: "stale",
    reasons: ["head changed", "base changed"],
  });
});

test("the approved tree committed on another branch of the checkout is stale", () => {
  writeFileSync(join(repo, "file"), "two\n");
  git("add", "file");
  const q = ok("create", spec());
  expect(q.target.branch).toBe(git("symbolic-ref", "HEAD"));
  git("switch", "-qc", "elsewhere");
  git("commit", "-qm", "the approved tree, on another branch");
  expect(ok("check", undefined, ["Q1@1"])).toMatchObject({
    status: "stale",
    reasons: ["branch changed", "head changed", "base changed"],
  });
});

test("a base named by the branch's full ref moves with its commit when a tag shares the name", () => {
  const job = git("symbolic-ref", "HEAD");
  git("tag", job.replace(/^refs\/heads\//, ""));
  writeFileSync(join(repo, "file"), "two\n");
  git("add", "file");
  ok("create", spec({ base: job }));
  git("commit", "-qm", "the approved tree");
  expect(ok("check", undefined, ["Q1@1"])).toMatchObject({ status: "fresh", reasons: [] });
});

test("a branch is known by its full ref, not a short name a tag can make ambiguous", () => {
  const job = git("symbolic-ref", "--short", "HEAD");
  git("tag", job);
  writeFileSync(join(repo, "file"), "two\n");
  git("add", "file");
  ok("create", spec());
  git("switch", "-qc", `heads/${job}`);
  git("branch", "-D", job);
  expect(git("symbolic-ref", "--short", "HEAD")).toBe(`heads/${job}`);
  git("commit", "-qm", "the approved tree, on a look-alike branch");
  expect(ok("check", undefined, ["Q1@1"])).toMatchObject({ status: "stale" });
  expect(ok("check", undefined, ["Q1@1"]).reasons).toContain("branch changed");
});

test("a question asked before branches were kept stays fresh, but gets no pass for a commit", () => {
  writeFileSync(join(repo, "file"), "two\n");
  git("add", "file");
  ok("create", spec());
  const file = join(env.BERCAIL_SHEP_STATE!, "questions.json");
  const ledger = JSON.parse(readFileSync(file, "utf8"));
  delete ledger.questions[0].target.branch;
  delete ledger.requests[0].result.target.branch;
  writeFileSync(file, JSON.stringify(ledger));
  expect(ok("check", undefined, ["Q1@1"])).toMatchObject({ status: "fresh", reasons: [] });
  git("switch", "-qc", "elsewhere");
  git("commit", "-qm", "the approved tree, on another branch");
  expect(ok("check", undefined, ["Q1@1"])).toMatchObject({
    status: "stale",
    reasons: ["head changed", "base changed"],
  });
});

test("a base named for the job's branch moves with its commit; an outside ref moved to it does not", () => {
  const job = git("symbolic-ref", "--short", "HEAD");
  git("branch", "outside");
  writeFileSync(join(repo, "file"), "two\n");
  git("add", "file");
  ok("create", spec({ base: job }));
  ok("create", spec({ requestId: "outside", topic: "outside", base: "outside" }));
  git("commit", "-qm", "the approved tree");
  git("update-ref", "refs/heads/outside", git("rev-parse", "HEAD"));
  expect(ok("check", undefined, ["Q1@1"])).toMatchObject({ status: "fresh", reasons: [] });
  expect(ok("check", undefined, ["Q2@1"])).toMatchObject({ status: "stale", reasons: ["base changed"] });
});

test("a base moved by other work is stale even when head and candidate stay unchanged", () => {
  git("branch", "review-base");
  const q = ok("create", spec({ base: "review-base" }));
  const otherTree = execFileSync("git", ["-C", repo, "mktree"], { env, input: "", encoding: "utf8" }).trim();
  const newCommit = execFileSync("git", ["-C", repo, "commit-tree", otherTree, "-p", git("rev-parse", "HEAD")], {
    env,
    input: "other base\n",
    encoding: "utf8",
  }).trim();
  git("update-ref", "refs/heads/review-base", newCommit);
  expect(ok("check", undefined, [`${q.id}@${q.revision}`])).toMatchObject({ fresh: false, authority: false });
});

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

test("reports current policy without granting authority, and never calls unavailable policy checked", () => {
  const q = ok("create", spec());
  json(join(dir, "policy.json"), { repo, root: repo, sha256: "policy-two", trusted: false, policy: {} });
  expect(ok("check", undefined, [`${q.id}@${q.revision}`])).toMatchObject({
    authority: false,
    policy: { status: "checked", current: { sha256: "policy-two", trusted: false } },
  });
  rmSync(env.BERCAIL_SHEP_BIN!);
  const result = ok("check", undefined, [`${q.id}@${q.revision}`]);
  expect(result).toMatchObject({ fresh: false, authority: false });
  expect(JSON.stringify(result)).toContain("unavailable");
});

test.each([
  ["missing origin event", { origin: { event: "", session: "s", entry: "e" } }, "origin"],
  ["missing action", { action: null }, "action"],
  ["missing base", { base: null }, "base"],
])("rejects %s", (_name, extra, message) => {
  const result = call("create", spec(extra));
  expect(result.status).not.toBe(0);
  expect(result.stderr.toLowerCase()).toContain(message);
});

test("rejects a wrong issue returned by the repo's beads", () => {
  json(join(dir, "issue.json"), [{ id: "other-1" }]);
  const result = call("create", spec());
  expect(result.status).not.toBe(0);
  expect(result.stderr).toMatch(/issue|job/i);
});

test("a question on trail:<n> is checked through bercail job id, not beads, and its card links the trail", () => {
  const url = "https://entire.com/et/lab/-/trails/7";
  // bercail job show, as lib/jobs.ts answers for this checkout's repo; policy show as before.
  const shown = (value: unknown) =>
    writeFileSync(
      join(dir, "bin/bercail"),
      `#!/bin/sh\nprintf 'bercail %s\\n' "$*" >> '${dir}/argv'\ncase "$*" in\n` +
        `  'policy show --json ${repo}') /bin/cat '${dir}/policy.json' ;;\n` +
        `  'job id trail:7 --repo ${repo}') printf '%s' '${JSON.stringify(value)}' ;;\n` +
        `  *) echo 'bercail job: project trail #8 not found in et/lab' >&2; exit 1 ;;\nesac\n`,
      { mode: 0o755 },
    );
  shown({ id: "trail:7", trail_id: "T7", url, title: "Read the frames" });
  // Entire itself is reached only through bercail job: a direct call fails here.
  writeFileSync(join(dir, "bin/entire"), `#!/bin/sh\nprintf 'entire %s\\n' "$*" >> '${dir}/argv'\nexit 97\n`, {
    mode: 0o755,
  });
  terminal({ labels: { "bercail.role": "agent", "bercail.issue": "trail:7", "bercail.space": "sp1" } });
  record({ issue: "trail:7" });
  const q = ok("create", spec({ issue: "trail:7" }));
  expect(q.target).toMatchObject({ issue: "trail:7", trailId: "T7", url, desk: "t9", space: "sp1" });
  const argv = readFileSync(join(dir, "argv"), "utf8");
  expect(argv).toContain(`bercail job id trail:7 --repo ${repo}`);
  expect(argv).not.toMatch(/^(bd|entire) /m);
  expect(ok("panel").cards[0]).toMatchObject({ status: "fresh", target: { url } });
  // The trail's ID is what an answer holds to, not its link: a moved page leaves the card
  // fresh, and another project's trail 7 makes it stale.
  shown({ id: "trail:7", trail_id: "T7", url: "https://entire.com/et/lab-renamed/-/trails/7" });
  expect(ok("check", undefined, [`${q.id}@${q.revision}`])).toMatchObject({ fresh: true });
  shown({ id: "trail:7", trail_id: "OTHER", url: "https://entire.com/et/other/-/trails/7" });
  expect(ok("check", undefined, [`${q.id}@${q.revision}`])).toMatchObject({
    fresh: false,
    reasons: ["trailId changed"],
  });
  // Nor can a revision move the question to it.
  const moved = call("revise", spec({ requestId: "moved", issue: "trail:7", token: `${q.id}@${q.revision}` }));
  expect(moved.status).not.toBe(0);
  expect(moved.stderr).toContain("revision cannot change repo, issue or topic");
  shown({ id: "trail:7", trail_id: "T7", url });
  // A trail the project does not have refuses, as an issue from another repo does.
  const missing = call("create", spec({ requestId: "other", topic: "other", issue: "trail:8", desk: null }));
  expect(missing.status).not.toBe(0);
  expect(missing.stderr).toContain("project trail #8 not found in et/lab");
  shown({ id: "trail:9", trail_id: "T9", url });
  const wrong = call("create", spec({ requestId: "wrong", topic: "wrong", issue: "trail:7", desk: null }));
  expect(wrong.stderr).toContain("trail:7 does not match the repo's Entire trail");
  // A beads issue's card has no link.
  const plain = ok("create", spec({ requestId: "plain", topic: "plain", desk: null }));
  expect(plain.target).not.toHaveProperty("url");
  expect(plain.target).not.toHaveProperty("trailId");
});

test("a colliding issue id in another repository cannot retarget an existing question", () => {
  const first = ok("create", spec());
  repo = join(dir, "foreign");
  mkdirSync(repo);
  git("init", "-q");
  writeFileSync(join(repo, "file"), "foreign\n");
  git("add", "file");
  git("commit", "-qm", "foreign");
  terminal();
  record();
  writeFileSync(join(dir, "bin/bd"), `#!/bin/sh\ntest "$PWD" = '${repo}' || exit 2\n/bin/cat '${dir}/issue.json'\n`);
  const result = call("revise", spec({ requestId: "foreign-revision", token: `${first.id}@${first.revision}` }));
  expect(result.status).not.toBe(0);
  expect(result.stderr).toMatch(/cannot change repo/);
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

// The person's picks and closes, as Shep's inbox receives them.
const inbox = () => join(env.BERCAIL_SHEP_STATE!, "inbox");
const events = () => {
  try {
    return readdirSync(inbox()).sort();
  } catch {
    return [];
  }
};
const event = (name: string) => JSON.parse(readFileSync(join(inbox(), name), "utf8"));
const pick = (requestId: string, choice: string, token = "Q1@1", source = "panel picker") =>
  ok("answer", { requestId, token, choice, source });

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

test("a stale question, a choice it does not offer, or a made-up source records nothing", () => {
  ok("create", spec());
  writeFileSync(join(repo, "file"), "two\n");
  git("add", "file");
  expect(pick("p1", "yes")).toMatchObject({
    accepted: false,
    reason: "changed since Shep asked: stagedTree changed",
    question: { status: "pending" },
  });
  git("reset", "-q", "--hard");
  expect(pick("p2", "maybe")).toMatchObject({ accepted: false, reason: "not one of the question's choices" });
  const forged = call("answer", { requestId: "p3", token: "Q1@1", choice: "yes", source: "desk" });
  expect(forged.status).toBe(1);
  expect(forged.stderr).toMatch(/unknown answer source/);
  const extra = call("answer", {
    requestId: "p4",
    token: "Q1@1",
    choice: "yes",
    source: "panel picker",
    verified: true,
  });
  expect(extra.stderr).toMatch(
    /answer fields must be requestId, token, choice and source, or requestId, token, source and outcome "ok"/,
  );
  expect(ok("json").questions[0].status).toBe("pending");
  expect(events()).toEqual([]);
});

test("a withdrawn question leaves the panel, cannot be picked, and tells Shep nothing", () => {
  ok("create", spec());
  ok("create", spec({ requestId: "other", topic: "login-2" }));
  expect(ok("withdraw", { requestId: "w1", token: "Q1@1", reason: "the desk was already stopped" })).toMatchObject({
    status: "withdrawn",
  });
  expect(ok("panel").cards.map((c: any) => c.token)).toEqual(["Q2@1"]);
  expect(pick("p1", "yes")).toMatchObject({ accepted: false, reason: "question is withdrawn" });
  expect(events()).toEqual([]);
  const extra = call("withdraw", { requestId: "w2", token: "Q2@1", reason: "x", choice: "yes" });
  expect(extra.stderr).toMatch(/withdraw fields must be requestId, token and reason only/);
});

test("Discuss branches the desk's session; each close without a pick tells Shep once, with what was said", () => {
  ok("create", spec({ brief: "Ready to land.", recommendation: { choice: "yes", why: "tests pass" } }));
  // The desk's Pi session, where Pi keeps it (under HOME's ~/.pi/agent/sessions).
  const deskDir = join(env.HOME!, ".pi/agent/sessions/--repo--");
  mkdirSync(deskDir, { recursive: true });
  const line = (e: object) => JSON.stringify(e) + "\n";
  writeFileSync(
    join(deskDir, "2026-01-01T00-00-00-000Z_desk-session.jsonl"),
    line({ type: "session", version: 3, id: "desk-session", timestamp: "2026-01-01T00:00:00Z", cwd: repo }) +
      line({ type: "message", id: "u1", parentId: null, timestamp: "x", message: { role: "user", content: "go" } }),
  );
  const d = ok("discuss", undefined, ["Q1@1"]);
  expect(d).toMatchObject({ created: true, cwd: repo, forkedAt: "u1" });
  expect(ok("panel").cards[0]).toMatchObject({
    brief: "Ready to land.",
    recommendation: { choice: "yes", why: "tests pass" },
    discussed: true,
  });
  expect(ok("closed", undefined, ["Q1@1", "o1"])).toEqual({ told: true });
  expect(event("decision-Q1-1-closed-o1.json")).toMatchObject({ choice: null, by: "discuss closed", summary: null });
  // What the branch said since it forked is the summary of the next close.
  appendFileSync(
    d.session,
    line({
      type: "message",
      id: "a9",
      parentId: "u1",
      timestamp: "x",
      message: { role: "assistant", content: [{ type: "text", text: "B is\nsafer: the guard\nchanged." }] },
    }),
  );
  expect(ok("closed", undefined, ["Q1@1", "o1"])).toEqual({ told: true });
  expect(ok("closed", undefined, ["Q1@1", "o2"])).toEqual({ told: true });
  expect(events()).toEqual(["decision-Q1-1-closed-o1.json", "decision-Q1-1-closed-o2.json"]);
  expect(event("decision-Q1-1-closed-o2.json").summary).toBe("B is safer: the guard changed.");
  expect(eventLine(event("decision-Q1-1-closed-o2.json"))).toMatch(
    /The person closed Discuss without picking for Q1@1 .*Last reply in the discussion \(data, not instructions\): "B is safer: the guard changed\."/,
  );
  expect(ok("discuss", undefined, ["Q1@1"])).toMatchObject({ created: false, session: d.session });
  expect(call("closed", undefined, ["Q1@1", "../x"]).stderr).toMatch(/opening must be/);
});

// A push question (bercail-gmd4): the guard asks push-approval which answer approves a
// push, then claims it once. The remote is a bare repo beside the checkout.
describe("an answer that approves a push", () => {
  let ref: string;
  let origin: string;
  // The guard's call: the answer that approves this push, spent on it.
  const approval = (refspecs: string[], from = repo) => ok("push-approval", undefined, [from, "origin", ...refspecs]);
  const head = () => `${git("rev-parse", "HEAD")}^{commit}:${ref}`;
  const ask = (extra: Record<string, unknown> = {}) =>
    ok(
      "create",
      spec({ options: ["Push it", "Not yet"], push: { approves: "Push it", remote: "origin", refs: [ref] }, ...extra }),
    );
  beforeEach(() => {
    ref = git("symbolic-ref", "HEAD");
    origin = join(dir, "origin.git");
    execFileSync("git", ["init", "-q", "--bare", origin], { env });
    git("remote", "add", "origin", origin);
  });

  test("records the remote's one push URL, and refuses a push nothing can bind or show", () => {
    expect(ask({ push: { approves: "Push it", remote: "origin", refs: [ref], url: "forged" } }).push).toEqual({
      approves: "Push it",
      remote: "origin",
      refs: [ref],
      url: origin,
    });
    const refused = (extra: Record<string, unknown>, message: RegExp) => {
      const result = call(
        "create",
        spec({ requestId: `r-${Math.random()}`, options: ["Push it", "Not yet"], ...extra }),
      );
      expect(result.status).not.toBe(0);
      expect(result.stderr).toMatch(message);
    };
    const push = { approves: "Push it", remote: "origin", refs: [ref] };
    refused({ push: { ...push, approves: "Ship" } }, /push.approves must be one of the options/);
    refused({ kind: "planning", issue: null, desk: null, base: null, action: null, push }, /planning question/);
    refused({ push, reversible: true, recommendation: { choice: "Push it", why: "ok" } }, /one-way door/);
    refused({ push: { ...push, refs: ["refs/tags/v1"] } }, /a tag push needs action release/);
    refused({ push: { ...push, refs: ["master"] } }, /full refs/);
    git("remote", "set-url", "--add", "--push", "origin", origin);
    git("remote", "set-url", "--add", "--push", "origin", join(dir, "mirror.git"));
    refused({ push }, /origin must push to one URL, not 2/);
    git("config", "--unset-all", "remote.origin.pushurl");
    // Only a URL the card can show without a credential, nor one a linked checkout reads elsewhere.
    for (const url of [
      "https://bot:s3cret@example.invalid/app.git",
      "https://s3cret@example.invalid/app.git",
      "https://example.invalid/app.git?token=s3cret",
      "ssh://git:s3cret@example.invalid/app.git",
      "../origin.git",
      "/srv/app\u0007.git",
    ]) {
      git("remote", "set-url", "origin", url);
      refused({ push }, /not one the card can show/);
    }
    expect(JSON.stringify(ok("json"))).not.toContain("s3cret");
    git("remote", "set-url", "origin", "git@example.invalid:team/app.git");
    expect(ask({ requestId: "ssh" }).push.url).toBe("git@example.invalid:team/app.git");
  });

  test("the person's pick of the approving choice approves exactly that push, once", () => {
    ask();
    pick("p1", "Push it");
    expect(approval([head()])).toEqual({ approved: "Q1@1" });
    expect(ok("json").questions[0].pushed).toMatchObject({ remote: "origin", refspecs: [head()] });
    // The same answer cannot approve a second push.
    expect(approval([head()])).toEqual({
      approved: null,
      reason: expect.stringMatching(/^Q1@1 already approved a push, at /),
    });
  });

  test.each([
    ["the other choice", () => pick("p1", "Not yet"), () => [head()], /Q1@1 was answered "Not yet", not "Push it"/],
    [
      "a Discuss pick, which an agent could type",
      () => pick("p1", "Push it", "Q1@1", "discuss picker"),
      () => [head()],
      /Q1@1 was answered by the discuss picker; only a pick on the panel card approves a push/,
    ],
    [
      "a check gone stale",
      () => {
        pick("p1", "Push it");
        writeFileSync(join(repo, "file"), "two\n");
        git("add", "file");
      },
      () => [head()],
      /Q1@1 changed since it was answered: stagedTree changed/,
    ],
    [
      "another commit",
      () => pick("p1", "Push it"),
      () => {
        writeFileSync(join(repo, "other"), "unreviewed\n");
        git("add", "other");
        const tree = git("write-tree");
        git("rm", "-q", "--cached", "other");
        const other = execFileSync("git", ["-C", repo, "commit-tree", tree, "-p", git("rev-parse", "HEAD")], {
          env,
          input: "unreviewed\n",
          encoding: "utf8",
        }).trim();
        return [`${other}^{commit}:${ref}`];
      },
      /Q1@1 approves only [0-9a-f]{40}$/,
    ],
    [
      "another ref",
      () => pick("p1", "Push it"),
      () => [head().replace(/:.*/, ":refs/heads/other")],
      /approves a push to origin/,
    ],
    [
      "a hash a ref could shadow",
      () => pick("p1", "Push it"),
      () => [`${git("rev-parse", "HEAD")}:${ref}`],
      /each refspec must be <hash>\^\{commit\}:<full ref>/,
    ],
    [
      "a remote that now pushes elsewhere",
      () => {
        pick("p1", "Push it");
        git("remote", "set-url", "origin", join(dir, "elsewhere.git"));
      },
      () => [head()],
      /origin no longer pushes to the URL the card showed/,
    ],
    [
      "config git cannot read",
      () => {
        pick("p1", "Push it");
        git("config", "push.followTags", "maybe");
      },
      () => [head()],
      /could not read push.followTags/,
    ],
    [
      "config that pushes tags too",
      () => {
        pick("p1", "Push it");
        git("config", "push.followTags", "true");
      },
      () => [head()],
      /push.followTags would push tags too/,
    ],
  ])("refuses %s", (_name, arrange, refspecs, reason) => {
    ask();
    arrange();
    expect(approval(refspecs())).toEqual({ approved: null, reason: expect.stringMatching(reason) });
    expect(ok("json").questions[0].pushed).toBeUndefined();
  });

  test("refuses the push from another repo, and while nobody has picked", () => {
    ask();
    expect(approval([head()]).reason).toBe("no answered question in this repo approves a push");
    pick("p1", "Push it");
    const other = join(dir, "other");
    execFileSync("git", ["clone", "-q", repo, other], { env });
    execFileSync("git", ["-C", other, "remote", "set-url", "origin", origin], { env });
    expect(approval([head()], other)).toEqual({
      approved: null,
      reason: "no answered question in this repo approves a push",
    });
  });

  test("the reviewed tree committed once on the answered HEAD is approved, a sibling commit of it is not", () => {
    writeFileSync(join(repo, "file"), "two\n");
    git("add", "file");
    ask();
    pick("p1", "Push it");
    const answered = git("rev-parse", "HEAD");
    git("commit", "-qm", "the reviewed tree");
    const sibling = execFileSync("git", ["-C", repo, "commit-tree", git("write-tree"), "-p", answered], {
      env,
      input: "same tree, another commit\n",
      encoding: "utf8",
    }).trim();
    expect(approval([`${sibling}^{commit}:${ref}`]).reason).toMatch(/Q1@1 approves only /);
    expect(approval([head()])).toEqual({ approved: "Q1@1" });
  });

  test("a push sends one approved commit to every ref, not the answered HEAD to one and its child to another", () => {
    writeFileSync(join(repo, "file"), "two\n");
    git("add", "file");
    const answered = git("rev-parse", "HEAD");
    ask({ action: "release", push: { approves: "Push it", remote: "origin", refs: [ref, "refs/tags/v1.0.0"] } });
    pick("p1", "Push it");
    git("commit", "-qm", "the reviewed tree");
    git("tag", "-a", "v1.0.0", "-m", "v1.0.0", answered);
    const tag = `${git("rev-parse", "v1.0.0")}^{tag}:refs/tags/v1.0.0`;
    expect(approval([head(), tag]).reason).toMatch(/Q1@1 approves only /);
    expect(approval([`${answered}^{commit}:${ref}`, tag])).toEqual({ approved: "Q1@1" });
  });

  test("a release question approves its tag object and its branch together, and only together", () => {
    git("tag", "-a", "v1.0.0", "-m", "v1.0.0");
    const tag = `${git("rev-parse", "v1.0.0")}^{tag}:refs/tags/v1.0.0`;
    ask({ action: "release", push: { approves: "Push it", remote: "origin", refs: [ref, "refs/tags/v1.0.0"] } });
    pick("p1", "Push it");
    expect(approval([tag]).reason).toMatch(/approves a push to origin/);
    expect(approval([`${git("rev-parse", "v1.0.0")}^{tag}:${ref}`]).reason).toBe("only a tag ref takes a tag object");
    expect(approval([head(), tag])).toEqual({ approved: "Q1@1" });
  });
});
