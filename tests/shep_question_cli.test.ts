// Question-cli.ts's targets and their freshness: the facts a question pins (its policy,
// issue and trail among them), its create and revise replays, and what makes it stale,
// a merge pick's steps included.
// The fixture is tests/shep_question_cli_fixture.ts.
import { execFileSync } from "node:child_process";
import { mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, test } from "vite-plus/test";
import { captureTarget } from "../shep/pi/question-target.ts";
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
  setRepo,
  pick,
} from "./shep_question_cli_fixture.ts";

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

// A merge or land pick names several steps (commit, update the branch, merge): each step
// Shep takes on the approved tree keeps it fresh, and nothing else does (bercail-0w3q).
describe("a merge pick stays fresh across its own steps, and only those", () => {
  const commitTree = (input: string, ...parents: string[]) =>
    execFileSync("git", ["-C", repo, "commit-tree", git("write-tree"), ...parents.flatMap((p) => ["-p", p])], {
      env,
      input,
      encoding: "utf8",
    }).trim();
  // trunk gets other work, and the job branch carries one reviewed commit.
  function branches() {
    const job = git("symbolic-ref", "--short", "HEAD");
    git("branch", "trunk");
    writeFileSync(join(repo, "file"), "job\n");
    git("commit", "-qam", "the job's work");
    git("switch", "-q", "trunk");
    writeFileSync(join(repo, "other"), "trunk\n");
    git("add", "other");
    git("commit", "-qm", "trunk's new work");
    git("switch", "-q", job);
  }
  const check = () => ok("check", undefined, ["Q1@1"]);

  test("commit with the merged base as second parent, then push: fresh; a second commit: stale", () => {
    branches();
    const remote = join(dir, "remote.git");
    execFileSync("git", ["init", "-q", "--bare", remote], { env });
    git("remote", "add", "origin", remote);
    const base = git("rev-parse", "trunk");
    // The desk merged trunk in; Shep's commit of that staged tree finishes the merge.
    git("merge", "-q", "--no-commit", "--no-ff", "trunk");
    expect(ok("create", spec({ base, action: "merge" })).target.mergeHead).toBe(base);
    pick("p1", "yes");
    git("commit", "-qm", "merge trunk");
    expect(git("rev-list", "--parents", "-n1", "HEAD").split(" ").slice(1)).toEqual([git("rev-parse", "HEAD^"), base]);
    expect(check()).toMatchObject({ status: "fresh", reasons: [] });
    git("push", "-q", "origin", "HEAD");
    expect(check()).toMatchObject({ status: "fresh", reasons: [] });
    writeFileSync(join(repo, "file"), "more\n");
    git("commit", "-qam", "more work nobody reviewed");
    expect(check()).toMatchObject({
      status: "stale",
      reasons: ["head changed", "stagedTree changed", "mergeHead changed"],
    });
  });

  test("the approved tree with a second parent other than the asked base is stale", () => {
    branches();
    const asked = git("rev-parse", "HEAD");
    git("merge", "-q", "--no-commit", "--no-ff", "trunk");
    ok("create", spec({ base: asked, action: "merge" }));
    const unreviewed = git("commit-tree", git("rev-parse", "trunk^{tree}"), "-p", "trunk", "-m", "unreviewed");
    git("update-ref", "HEAD", commitTree("same tree, other parent\n", asked, unreviewed));
    expect(check()).toMatchObject({ status: "stale", reasons: ["head changed"] });
  });

  test("the asked base as second parent is stale when no merge of it was under way at ask", () => {
    branches();
    const asked = git("rev-parse", "HEAD");
    const base = git("rev-parse", "trunk");
    git("merge", "-q", "--squash", "trunk");
    expect(ok("create", spec({ base, action: "merge" })).target).not.toHaveProperty("mergeHead");
    git("update-ref", "HEAD", commitTree("a merge nobody asked about\n", asked, base));
    expect(check()).toMatchObject({ status: "stale", reasons: ["head changed"] });
  });

  test("once the approved tree is committed, the desk staging its next job leaves it fresh", () => {
    writeFileSync(join(repo, "file"), "two\n");
    git("add", "file");
    const tree = git("write-tree");
    ok("create", spec({ action: "merge" }));
    ok("create", spec({ requestId: "land", topic: "land", action: "land" }));
    ok("create", spec({ requestId: "commit", topic: "commit", action: "commit" }));
    git("commit", "-qm", "the approved tree");
    writeFileSync(join(repo, "file"), "next job\n");
    git("add", "file");
    expect(check()).toMatchObject({ status: "fresh", reasons: [] });
    // A land runs bercail land, which commits what is staged: the index stays bound.
    expect(ok("check", undefined, ["Q2@1"])).toMatchObject({ status: "stale", reasons: ["stagedTree changed"] });
    // The pick records the tree it approved, not the next job's.
    expect(pick("p1", "yes")).toMatchObject({ accepted: true, question: { answer: { stagedTree: tree } } });
    // A commit card's step is the commit: the next index is not what it approved.
    expect(ok("check", undefined, ["Q3@1"])).toMatchObject({ status: "stale", reasons: ["stagedTree changed"] });
    git("commit", "-qm", "the next job");
    expect(check()).toMatchObject({
      status: "stale",
      reasons: ["head changed", "stagedTree changed", "base changed"],
    });
  });

  test("before the commit, a merge started after the ask is stale, though the index is the same", () => {
    branches();
    writeFileSync(join(repo, "file"), "two\n");
    git("add", "file");
    ok("create", spec({ action: "merge" }));
    ok("create", spec({ requestId: "commit", topic: "commit", action: "commit" }));
    // As git merge --no-commit leaves it: the index the same, trunk to be its second parent.
    writeFileSync(join(repo, ".git/MERGE_HEAD"), `${git("rev-parse", "trunk")}\n`);
    expect(check()).toMatchObject({ status: "stale", reasons: ["mergeHead changed"] });
    expect(ok("check", undefined, ["Q2@1"])).toMatchObject({ status: "stale", reasons: ["mergeHead changed"] });
  });

  test("before the commit, a changed index is still stale", () => {
    writeFileSync(join(repo, "file"), "two\n");
    git("add", "file");
    ok("create", spec({ action: "merge" }));
    writeFileSync(join(repo, "file"), "unreviewed\n");
    git("add", "file");
    expect(check()).toMatchObject({ status: "stale", reasons: ["stagedTree changed"] });
  });

  test("a merge card on a committed HEAD ignores the next job staged on top until it is committed", () => {
    ok("create", spec({ action: "merge" }));
    writeFileSync(join(repo, "file"), "next job\n");
    git("add", "file");
    expect(check()).toMatchObject({ status: "fresh", reasons: [] });
    git("commit", "-qm", "the next job");
    expect(check().status).toBe("stale");
  });

  test("trunk moved ahead with a clean merge stays fresh; a conflict, a rewrite or a land card is stale", () => {
    branches();
    const ahead = git("rev-parse", "trunk");
    git("update-ref", "refs/heads/trunk", git("rev-parse", "trunk^"));
    ok("create", spec({ base: "trunk", action: "merge" }));
    ok("create", spec({ requestId: "land", topic: "land", base: "trunk", action: "land" }));
    const pinned = git("rev-parse", "trunk");
    git("update-ref", "refs/heads/trunk", ahead);
    expect(check()).toMatchObject({ status: "fresh", reasons: [] });
    expect(ok("check", undefined, ["Q2@1"])).toMatchObject({ status: "stale", reasons: ["base changed"] });
    // trunk rewritten: the new tip does not hold the pinned base.
    git("update-ref", "refs/heads/trunk", git("commit-tree", git("rev-parse", "trunk^{tree}"), "-m", "rewritten"));
    expect(check()).toMatchObject({ status: "stale", reasons: ["base changed"] });
    // trunk ahead, but its change to file conflicts with the job's.
    git("switch", "-q", "trunk");
    git("reset", "-q", "--hard", pinned);
    writeFileSync(join(repo, "file"), "trunk's own\n");
    git("commit", "-qam", "conflicting work");
    git("switch", "-q", "-");
    expect(check()).toMatchObject({ status: "stale", reasons: ["base changed"] });
  });

  test("trunk moved ahead is stale when an attribute makes the merge conflict", () => {
    writeFileSync(join(repo, "lines"), "a\nb\nc\nd\ne\n");
    writeFileSync(join(repo, ".gitattributes"), "lines -merge\n");
    git("add", "lines", ".gitattributes");
    git("commit", "-qm", "lines that never merge");
    git("branch", "trunk");
    writeFileSync(join(repo, "lines"), "job\nb\nc\nd\ne\n");
    git("commit", "-qam", "the job's first line");
    ok("create", spec({ base: "trunk", action: "merge" }));
    // trunk's last line: plain text would merge clean, -merge says it conflicts.
    git("switch", "-q", "trunk");
    writeFileSync(join(repo, "lines"), "a\nb\nc\nd\ntrunk\n");
    git("commit", "-qam", "trunk's last line");
    git("switch", "-q", "-");
    expect(check()).toMatchObject({ status: "stale", reasons: ["base changed"] });
    // The desk's next job drops the attribute: the merge still reads trunk's.
    writeFileSync(join(repo, ".gitattributes"), "");
    git("add", ".gitattributes");
    expect(check()).toMatchObject({ status: "stale", reasons: ["base changed"] });
  });

  test("trunk moved ahead is stale when config names a merge driver, which a check never runs", () => {
    branches();
    const ahead = git("rev-parse", "trunk");
    git("update-ref", "refs/heads/trunk", git("rev-parse", "trunk^"));
    ok("create", spec({ base: "trunk", action: "merge" }));
    git("update-ref", "refs/heads/trunk", ahead);
    git("config", "merge.default", "text");
    expect(check()).toMatchObject({ status: "stale", reasons: ["base changed"] });
  });

  test("trunk moved ahead before the approved tree is committed is stale, though HEAD alone merges clean", () => {
    branches();
    const ahead = git("rev-parse", "trunk");
    git("update-ref", "refs/heads/trunk", git("rev-parse", "trunk^"));
    writeFileSync(join(repo, "other"), "candidate\n");
    git("add", "other");
    ok("create", spec({ base: "trunk", action: "merge" }));
    // trunk's new work adds the file the staged candidate adds: no conflict with HEAD, one with the candidate.
    git("update-ref", "refs/heads/trunk", ahead);
    expect(check()).toMatchObject({ status: "stale", reasons: ["base changed"] });
  });
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
  setRepo(join(dir, "foreign"));
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
