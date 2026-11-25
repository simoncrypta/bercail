// A commit or merge card keeps its pick through a clean rebase onto the moved trunk, where
// the repo's policy says rebase_keeps_pick, and only then: the card was asked with that
// pin, the change is one patch with the same patch-id, and git's own replay of the asked
// tree onto the new trunk is exactly the live tree. Anything else stays stale as before.
// The fixture is tests/shep_question_cli_fixture.ts.
import { execFileSync, spawnSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, test } from "vite-plus/test";
import { dir, repo, env, json, git, ok, spec, pick } from "./shep_question_cli_fixture.ts";

const policy = (rebase_keeps_pick: boolean) =>
  json(join(dir, "policy.json"), { repo, root: repo, trusted: true, policy: { rebase_keeps_pick } });
const check = (token = "Q1@1") => ok("check", undefined, [token]);
const trunkDir = () => join(dir, "trunk");
// Another desk's work lands on the trunk, from a checkout of its own.
function land(file: string, content: string) {
  writeFileSync(join(trunkDir(), file), content);
  execFileSync("git", ["-C", trunkDir(), "add", file], { env });
  execFileSync("git", ["-C", trunkDir(), "commit", "-qm", `trunk: ${file}`], { env });
  return execFileSync("git", ["-C", trunkDir(), "rev-parse", "HEAD"], { env, encoding: "utf8" }).trim();
}
const ten = (first = "1", last = "10") => [first, ..."23456789".split(""), last].join("\n") + "\n";
// The desk's branch off the trunk, and the trunk checked out beside it.
function desk() {
  const trunk = git("branch", "--show-current");
  git("switch", "-qc", "topic");
  git("worktree", "add", "-q", trunkDir(), trunk);
  return trunk;
}
const hasObject = (oid: string) => spawnSync("git", ["-C", repo, "cat-file", "-e", oid], { env }).status === 0;

describe("a staged change on the trunk", () => {
  test("carried onto the moved trunk keeps its pick, which records the live tree", () => {
    policy(true);
    const trunk = desk();
    writeFileSync(join(repo, "file"), "the change\n");
    git("add", "file");
    const asked = ok("create", spec({ base: trunk, action: "commit" }));
    expect(asked).toMatchObject({ rebaseKeepsPick: true, target: { branch: "refs/heads/topic" } });
    const onto = land("other", "another desk's work\n");
    // The desk catches up with its change still staged: nothing ever wrote the asked tree.
    git("merge", "-q", "--ff-only", trunk);
    expect(hasObject(asked.target.stagedTree)).toBe(false);
    const fresh = check();
    expect(fresh).toMatchObject({
      status: "fresh",
      reasons: [],
      rebased: { base: asked.target.base, onto, tree: fresh.current.stagedTree },
    });
    expect(fresh.current.stagedTree).not.toBe(asked.target.stagedTree);
    expect(pick("p1", "yes")).toMatchObject({
      accepted: true,
      question: { answer: { head: onto, stagedTree: fresh.current.stagedTree } },
    });
  });

  test("is stale with the policy off now, and on a card asked before the repo opted in", () => {
    policy(false);
    const trunk = desk();
    writeFileSync(join(repo, "file"), "the change\n");
    git("add", "file");
    expect(ok("create", spec({ base: trunk, action: "commit" }))).not.toHaveProperty("rebaseKeepsPick");
    policy(true);
    ok("create", spec({ requestId: "pinned", topic: "pinned", base: trunk, action: "commit" }));
    land("other", "another desk's work\n");
    git("merge", "-q", "--ff-only", trunk);
    const stale = ["head changed", "stagedTree changed", "base changed"];
    expect(check("Q1@1")).toMatchObject({ status: "stale", reasons: stale });
    expect(check("Q1@1")).not.toHaveProperty("rebased");
    expect(check("Q2@1")).toMatchObject({ status: "fresh", rebased: {} });
    policy(false);
    expect(check("Q2@1")).toMatchObject({ status: "stale", reasons: stale });
  });

  test("changed after the rebase is stale", () => {
    policy(true);
    const trunk = desk();
    writeFileSync(join(repo, "file"), "the change\n");
    git("add", "file");
    ok("create", spec({ base: trunk, action: "commit" }));
    land("other", "another desk's work\n");
    git("merge", "-q", "--ff-only", trunk);
    writeFileSync(join(repo, "file"), "the change, and more\n");
    git("add", "file");
    expect(check()).toMatchObject({ status: "stale", reasons: ["head changed", "stagedTree changed", "base changed"] });
  });

  test("on a base that is not the trunk is stale", () => {
    policy(true);
    desk();
    git("branch", "release");
    writeFileSync(join(repo, "file"), "the change\n");
    git("add", "file");
    ok("create", spec({ base: "release", action: "commit" }));
    execFileSync("git", ["-C", trunkDir(), "switch", "-q", "release"], { env });
    land("other", "release work\n");
    git("merge", "-q", "--ff-only", "release");
    expect(check()).toMatchObject({ status: "stale", reasons: ["head changed", "stagedTree changed", "base changed"] });
  });
});

describe("a staged change on the trunk, as the desk carries it", () => {
  function staged(action: string) {
    policy(true);
    const trunk = desk();
    writeFileSync(join(repo, "file"), "the change\n");
    git("add", "file");
    ok("create", spec({ base: trunk, action }));
    land("other", "another desk's work\n");
    return trunk;
  }
  const nextJob = () => {
    writeFileSync(join(repo, "next"), "the next job\n");
    git("add", "next");
  };

  test("a merge card still staged on the moved trunk keeps its pick, the index its tree", () => {
    const trunk = staged("merge");
    git("merge", "-q", "--ff-only", trunk);
    const fresh = check();
    expect(fresh).toMatchObject({ status: "fresh", rebased: { tree: fresh.current.stagedTree } });
  });

  test("a merge card committed once, then rebased, keeps its pick, whatever is staged next", () => {
    const trunk = staged("merge");
    git("commit", "-qm", "the candidate");
    git("rebase", "-q", trunk);
    nextJob();
    expect(check()).toMatchObject({ status: "fresh", rebased: { tree: git("rev-parse", "HEAD^{tree}") } });
  });

  test("a commit card whose patch is committed once on the moved trunk keeps its pick, until more is staged", () => {
    const trunk = staged("commit");
    git("merge", "-q", "--ff-only", trunk);
    git("commit", "-qm", "the candidate");
    expect(check()).toMatchObject({ status: "fresh", rebased: { tree: git("rev-parse", "HEAD^{tree}") } });
    nextJob();
    expect(check()).toMatchObject({ status: "stale" });
  });

  test("a merge card's commit undone back to staged on the moved trunk is stale", () => {
    policy(true);
    const trunk = desk();
    writeFileSync(join(repo, "file"), "the change\n");
    git("commit", "-qam", "the candidate");
    ok("create", spec({ base: trunk, action: "merge" }));
    land("other", "another desk's work\n");
    git("reset", "-q", "--hard", trunk);
    writeFileSync(join(repo, "file"), "the change\n");
    git("add", "file");
    expect(check()).toMatchObject({ status: "stale" });
    expect(check()).not.toHaveProperty("rebased");
  });
});

describe("one commit rebased onto the moved trunk", () => {
  function committed(attributes = "") {
    writeFileSync(join(repo, "lines"), ten());
    writeFileSync(join(repo, ".gitattributes"), attributes);
    git("add", "lines", ".gitattributes");
    git("commit", "-qm", "ten lines");
    const trunk = desk();
    writeFileSync(join(repo, "lines"), ten("one"));
    git("commit", "-qam", "the candidate");
    ok("create", spec({ base: trunk, action: "merge" }));
    return trunk;
  }
  // The desk rebuilds its commit on the trunk's tip by hand, both changes in, as a rebase that
  // took every hunk would: same message, same patch.
  function rebuilt(trunk: string, first = "one") {
    git("reset", "-q", "--hard", trunk);
    writeFileSync(join(repo, "lines"), ten(first, "ten"));
    git("commit", "-qam", "the candidate");
  }

  test("with the same patch, replayed clean, keeps its pick, the person's LGTM as it was", () => {
    policy(true);
    const trunk = committed();
    const { answer } = pick("p1", "yes").question;
    land("lines", ten("1", "ten"));
    rebuilt(trunk);
    expect(check()).toMatchObject({ status: "fresh", rebased: { tree: git("rev-parse", "HEAD^{tree}") } });
    expect(ok("get", undefined, ["Q1@1"])).toMatchObject({ status: "answered", answer });
  });

  test("with only whitespace changed, which patch-id ignores, is stale", () => {
    policy(true);
    const trunk = committed();
    land("lines", ten("1", "ten"));
    rebuilt(trunk, "o ne");
    expect(check()).toMatchObject({ status: "stale", reasons: ["head changed", "stagedTree changed", "base changed"] });
  });

  test("with the same patch-id but a replay git would not merge clean is stale", () => {
    policy(true);
    // -merge: the trunk's last line and the job's first never merge, though the patch is the same.
    const trunk = committed("lines -merge\n");
    land("lines", ten("1", "ten"));
    rebuilt(trunk);
    expect(check()).toMatchObject({ status: "stale", reasons: ["head changed", "stagedTree changed", "base changed"] });
  });

  test("through a conflict resolved by hand is stale", () => {
    policy(true);
    const trunk = committed();
    land("lines", ten("uno"));
    expect(spawnSync("git", ["-C", repo, "rebase", "-q", trunk], { env }).status).not.toBe(0);
    writeFileSync(join(repo, "lines"), ten("one"));
    git("add", "lines");
    execFileSync("git", ["-C", repo, "-c", "core.editor=true", "rebase", "--continue"], { env, stdio: "ignore" });
    expect(check()).toMatchObject({ status: "stale" });
    expect(check()).not.toHaveProperty("rebased");
  });

  test("as a series of two commits is stale, though each rebases clean", () => {
    policy(true);
    const trunk = committed();
    writeFileSync(join(repo, "more"), "a second commit\n");
    git("add", "more");
    git("commit", "-qm", "a second commit");
    land("other", "another desk's work\n");
    git("rebase", "-q", trunk);
    expect(check()).toMatchObject({ status: "stale" });
    expect(check()).not.toHaveProperty("rebased");
  });
});

describe("a deadline on a rebased card", () => {
  // The scratch ledger's card, asked an hour ago and due a minute ago.
  function due() {
    const file = join(env.BERCAIL_SHEP_STATE!, "questions.json");
    const ledger = JSON.parse(readFileSync(file, "utf8"));
    const past = (minutes: number) => new Date(Date.now() - minutes * 60000).toISOString();
    for (const q of ledger.questions) Object.assign(q, { createdAt: past(60), deadline: past(1) });
    writeFileSync(file, JSON.stringify(ledger));
  }
  function asked() {
    policy(true);
    const trunk = desk();
    writeFileSync(join(repo, "file"), "the change\n");
    git("add", "file");
    ok(
      "create",
      spec({
        kind: "action",
        base: trunk,
        action: "commit",
        reversible: true,
        recommendation: { choice: "yes", why: "w" },
      }),
    );
    due();
    return trunk;
  }

  test("never defaults it, and the person can still pick it", () => {
    const trunk = asked();
    land("other", "another desk's work\n");
    git("merge", "-q", "--ff-only", trunk);
    expect(check()).toMatchObject({ status: "fresh", rebased: {} });
    expect(ok("expire")).toEqual([]);
    expect(ok("get", undefined, ["Q1@1"]).status).toBe("pending");
    expect(pick("p1", "no")).toMatchObject({ accepted: true, question: { answer: { choice: "no" } } });
  });

  test("a default the person has not said OK to is stale after a rebase", () => {
    const trunk = asked();
    expect(ok("expire")).toEqual(["Q1@1"]);
    land("other", "another desk's work\n");
    git("merge", "-q", "--ff-only", trunk);
    expect(check()).toMatchObject({ status: "stale", reasons: ["head changed", "stagedTree changed", "base changed"] });
    expect(ok("answer", { requestId: "ok", token: "Q1@1", source: "panel picker", outcome: "ok" })).toMatchObject({
      accepted: false,
      reason: "changed since it defaulted: head changed, stagedTree changed, base changed",
    });
  });
});
