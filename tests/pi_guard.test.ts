// Decision table for bercail's Pi guard. No Pi process.
import { expect, test } from "vite-plus/test";
import {
  type GuardInput,
  type Policy,
  decideBash,
  decideTool,
  defaultPolicy,
  redact,
} from "../bstack/pi/extensions/guard.ts";

const assertEqual = (got: unknown, want: unknown, message?: string) => expect(got, message).toBe(want);
const assertDeepEqual = (got: unknown, want: unknown, message?: string) => expect(got, message).toStrictEqual(want);
const assertMatch = (got: string, re: RegExp, message?: string) => expect(got, message).toMatch(re);

// No policy file: the defaults, looked up for every dir the tests use.
const none = {
  "/work": defaultPolicy,
  "/tmp/repo": defaultPolicy,
  "/other": defaultPolicy,
  "/repo/sub": defaultPolicy,
};
const headless = { role: "", hasUI: false, cwd: "/work", policies: none };
const tui = { role: "", hasUI: true, cwd: "/work", policies: none };
const auto = { role: "autopilot", hasUI: false, cwd: "/work", branches: { "/work": "feature" }, policies: none };
const judge = { role: "judge", hasUI: true, cwd: "/work", policies: none };
const council = { role: "council", hasUI: false, cwd: "/work", policies: none };

// Every field a test reads off a decision, whichever action it is.
type Decision = { action: string; reason?: string; dir?: string; approved?: string[] };

function decision(command: string, input: GuardInput): Decision {
  return decideBash(command, input);
}

function blocked(command: string, input: GuardInput, pattern?: RegExp) {
  const got = decision(command, input);
  assertEqual(got.action, "block", `${command} → ${JSON.stringify(got)}`);
  if (pattern) assertMatch(got.reason ?? "", pattern, command);
}

function allowed(command: string, input: GuardInput) {
  assertEqual(decision(command, input).action, "allow", command);
}

function asked(command: string, input: GuardInput) {
  const got = decision(command, input);
  assertEqual(got.action, "ask", `${command} → ${JSON.stringify(got)}`);
}

test("blocked: force-push, mirror, deleting main, --no-verify, PR merges, headless commits, main pushes, read-only roles", () => {
  blocked("git push --force", auto, /Force-push/);
  blocked("git push -f origin feature", auto, /Force-push/);
  blocked("git push --force-with-lease", auto, /Force-push/);
  blocked("git push --force-if-includes origin feature", headless, /Force-push/);
  blocked("git push --mirror", auto, /mirror/);
  blocked("git push origin +feature", auto, /starting with \+/);
  blocked("git push origin +HEAD:feature", auto, /starting with \+/);
  blocked("git push --delete main", auto, /Deleting main or master/);
  blocked("git push -d master", auto, /Deleting main or master/);
  blocked("git push origin --delete refs/heads/main", auto, /Deleting main or master/);
  blocked("git commit --no-verify -m x", auto, /--no-verify/);
  blocked("git commit -n -m x", auto, /--no-verify/);
  blocked("git push --no-verify origin feature", auto, /--no-verify/);
  blocked("git merge --no-verify feature", headless, /--no-verify/);
  blocked("git rebase --no-verify feature", tui, /--no-verify/);
  blocked("gh pr merge", auto, /gh pr merge/);
  blocked("gh pr merge 12 --squash", headless, /gh pr merge/);
  blocked("sudo git push --force", auto, /Force-push/);
  blocked("FOO=1 command env -u BAR git push --force", auto, /Force-push/);
  blocked("git status && git push --force", auto, /Force-push/);
  blocked("echo ok | git push --force origin feature", headless, /Force-push/);
  blocked("bash -c 'git push --force'", auto, /Force-push/);
  blocked('echo "$(git push --force)"', auto, /Force-push/);
  blocked("git commit -m 'leave it'", headless, /headless run stages/);
  blocked("git push origin feature", headless, /headless run stages/);
  blocked("git push", { ...auto, branches: { "/work": "main" } }, /main or master/);
  blocked("git push origin", { ...auto, branches: { "/work": "master" } }, /main or master/);
  blocked("git push origin main", auto, /main or master/);
  blocked("git push main", auto, /main or master/);
  blocked("git push origin HEAD:main", auto, /main or master/);
  blocked("git push origin feature:refs/heads/master", auto, /main or master/);
  blocked("git push origin refs/heads/main", auto, /main or master/);
  blocked("git push", { ...auto, branches: { "/work": "" } }, /Could not read the current branch/);
  blocked("git add .", judge, /read-only/);
  blocked("git commit -m x", council, /read-only/);
  blocked("git reset --hard", judge, /read-only/);
  blocked("git checkout -- .", council, /read-only/);
  blocked("git restore --staged .", judge, /read-only/);
});

test("asked: a desk's commit, a builder's push", () => {
  asked("git commit -m 'ship'", tui);
  asked("git push origin feature", { ...tui, role: "builder" });
});

test("allowed: reads, autopilot's branch pushes and commits, quoted text, git -C", () => {
  allowed("git status", headless);
  allowed("git diff", judge);
  allowed("git push origin feature", auto);
  allowed("git push -u origin feature", auto);
  allowed("git commit -m 'ship'", auto);
  allowed("git push --delete feature", auto);
  allowed('echo "git push --force"', headless);
  allowed("git -C /tmp/repo push origin feature", auto);
});

test("git -C to a dir without a known branch asks for that dir's branch", () => {
  const nested = decision("git -C ../other push", { ...auto, branches: {} });
  assertEqual(nested.action, "need-branch", JSON.stringify(nested));
  assertEqual(nested.dir, "/other");

  const abs = decision("git -C /repo/sub push", { ...auto, branches: {} });
  assertEqual(abs.action, "need-branch");
  assertEqual(abs.dir, "/repo/sub");
});

test("a heredoc body is data, but a command substitution in it runs", () => {
  // A heredoc body is data. Seen live: autopilot's summary quoted `git push --force origin feat`.
  allowed(
    "cat > /tmp/s.txt <<'EOF'\nNot attempted: `git push --force origin feat` and git push origin HEAD:main.\nEOF\npython3 -c 'print(1)'",
    auto,
  );
  allowed('cat <<-"END" >x\n\tgit commit --no-verify\n\tEND', headless);
  blocked("cat <<EOF\n$(git push --force)\nEOF", auto, /Force-push/);
  blocked("cat <<'EOF' >x\ntext\nEOF\ngit push --force", auto, /Force-push/);
});

test("edit and write are blocked for read-only roles only", () => {
  assertEqual(decideTool("edit", undefined, judge).action, "block");
  assertEqual(decideTool("write", undefined, council).action, "block");
  assertEqual(decideTool("edit", undefined, headless).action, "allow");
  assertEqual(decideTool("write", undefined, auto).action, "allow");
  assertEqual(decideTool("read", undefined, judge).action, "allow");
});

// A repo's policy, as lib/policy.sh hands it over (untrusted loosening already
// back to the defaults). Each policy value × role × command.
const policy = (fields: Partial<Policy>): Policy => ({ ...defaultPolicy, repo: "/work", from: {}, ...fields });
type Role = "desk" | "shep" | "headless" | "autopilot" | "judge" | "council";
const roles: Record<Role, GuardInput> = {
  desk: { role: "", hasUI: true, cwd: "/work" },
  shep: { role: "shep", hasUI: true, cwd: "/work" },
  headless: { role: "", hasUI: false, cwd: "/work" },
  autopilot: { role: "autopilot", hasUI: false, cwd: "/work" },
  judge: { role: "judge", hasUI: true, cwd: "/work" },
  council: { role: "council", hasUI: false, cwd: "/work" },
};
const roleNames = Object.keys(roles) as Role[];
const at = (role: Role, fields: Partial<Policy>, branch = "feature"): GuardInput => ({
  ...roles[role],
  policies: { "/work": policy(fields) },
  branches: { "/work": branch },
});
type PolicyName = "default" | "commit" | "branch" | "main" | "release" | "loosest";
const policies: Record<PolicyName, Partial<Policy>> = {
  default: {},
  commit: { commit: "allow" },
  branch: { push: "branch" },
  main: { push: "main" },
  release: { agentMayRelease: true },
  loosest: { commit: "allow", push: "main", agentMayRelease: true },
};
// [command, branch, desk's answer under each policy in the order above]
const policyNames = Object.keys(policies) as PolicyName[];
const commands: [string, string, string[]][] = [
  ["git commit -m x", "feature", ["ask", "allow", "ask", "ask", "ask", "allow"]],
  ["git push origin feature", "feature", ["ask", "ask", "allow", "allow", "ask", "allow"]],
  ["git push", "feature", ["ask", "ask", "allow", "allow", "ask", "allow"]],
  ["git push origin main", "feature", ["ask", "ask", "ask", "allow", "ask", "allow"]],
  ["git push", "main", ["ask", "ask", "ask", "allow", "ask", "allow"]],
  ["git push", "", ["ask", "ask", "ask", "allow", "ask", "allow"]],
  ["git tag v1.2.0", "feature", ["ask", "ask", "ask", "ask", "allow", "allow"]],
  ["git tag -a v1.2.0 -m release", "feature", ["ask", "ask", "ask", "ask", "allow", "allow"]],
  ["git push origin v1.2.0", "feature", ["ask", "ask", "ask", "ask", "allow", "allow"]],
  ["git push origin refs/tags/v1.2.0", "feature", ["ask", "ask", "ask", "ask", "allow", "allow"]],
  ["git push --tags", "feature", ["ask", "ask", "ask", "ask", "allow", "allow"]],
  ["git push --follow-tags origin feature", "feature", ["ask", "ask", "ask", "ask", "ask", "allow"]],
  ["gh release create v1.2.0", "feature", ["ask", "ask", "ask", "ask", "allow", "allow"]],
];
// Autopilot keeps its own rules: commit, push its branch, never main, no release unless allowed.
const autopilotAnswer = (command: string, branch: string, name: PolicyName) => {
  if (/tag|release|v1\.2\.0/.test(command)) return policies[name].agentMayRelease ? "allow" : "block";
  if (/main/.test(command) || branch === "main") return "block";
  if (branch === "") return command.endsWith("push") ? "block" : "allow";
  return "allow";
};
for (const [command, branch, answers] of commands) {
  test(`policy table: ${command} on ${JSON.stringify(branch)}`, () =>
    policyNames.forEach((name, i) => {
      const want: Record<Role, string | undefined> = {
        desk: answers[i],
        shep: answers[i],
        headless: answers[i] === "ask" ? "block" : answers[i],
        autopilot: autopilotAnswer(command, branch, name),
        judge: "block",
        council: "block",
      };
      for (const role of roleNames) {
        const got = decision(command, at(role, policies[name], branch));
        assertEqual(
          got.action,
          want[role],
          `${role} / ${name} / ${command} on ${JSON.stringify(branch)} → ${JSON.stringify(got)}`,
        );
      }
    }));
}

// Under the loosest policy the hard blocks still hold, for every role.
for (const role of roleNames) {
  test(`under the loosest policy the hard blocks still hold: ${role}`, () => {
    const input = at(role, policies.loosest);
    blocked("git push --force origin feature", input, /Force-push/);
    blocked("git push origin +feature", input, /starting with \+/);
    blocked("git push --mirror", input, /mirror/);
    blocked("git push origin --delete main", input, /Deleting main/);
    blocked("git commit --no-verify -m x", input, /--no-verify/);
    blocked("git -c core.hooksPath=/dev/null commit -m x", input, /core.hooksPath/);
    blocked("gh pr merge 3 --squash", input, /gh pr merge/);
    blocked("bercail policy trust .", input, /person's call/);
    blocked("~/.local/bin/bercail policy trust", input, /person's call/);
  });
}

test("an auto-approval says why, for the log", () => {
  // An auto-approval says why, for the log.
  const why = decision("git commit -m x", {
    ...at("desk", { commit: "allow" }),
    policies: { "/work": policy({ commit: "allow", from: { commit: "repo" } }) },
  });
  assertDeepEqual(why.approved, ["/work: commit = allow (repo)"]);
  const two = decision("git commit -m x && git push origin feature", at("desk", policies.loosest));
  assertEqual(two.approved?.length, 2, JSON.stringify(two));
  assertEqual(decision("git commit -m x && git push origin feature", at("desk", policies.commit)).action, "ask");
  assertEqual(decision("git status", at("desk", policies.loosest)).approved, undefined);
});

test("the policy is looked up per git dir; a dir the guard cannot place gets the default", () => {
  // The policy is looked up per git dir; a dir the guard cannot place gets the default.
  assertDeepEqual(decision("git commit -m x", { ...tui, policies: {} }), { action: "need-policy", dir: "/work" });
  assertDeepEqual(decision("git -C /other commit -m x", { ...tui, policies: {} }), {
    action: "need-policy",
    dir: "/other",
  });
  const split = {
    ...roles.desk,
    home: "/home/me",
    policies: {
      "/work": policy({ commit: "allow" }),
      "/other": defaultPolicy,
      "/home/me/w": policy({ commit: "allow" }),
    },
  };
  allowed("git commit -m x", split);
  asked("git -C /other commit -m x", split);
  asked("git -C ../other commit -m x", split);
  asked("cd /other && git commit -m x", split);
  asked("cd ../other; git commit -m x", split);
  allowed("cd /other && cd /work && git commit -m x", split);
  allowed("cd ~/w && git commit -m x", split);
  asked('cd "$REPO" && git commit -m x', split);
  asked("cd - && git commit -m x", split);
  asked("pushd /tmp && popd && git commit -m x", split);
  allowed("(git status) && echo ok", split);
  asked("(cd /work && git status); git commit -m x", { ...split, cwd: "/other" });
  allowed("(cd /work && git commit -m x)", { ...split, cwd: "/other" });
  asked("git --git-dir=/other/.git commit -m x", split);
  asked("git --work-tree /other commit -m x", split);
  asked("GIT_DIR=/other/.git git commit -m x", split);
  asked("env GIT_WORK_TREE=/other git commit -m x", split);
  asked("gh release create v1 -R someone/else", { ...split, policies: { "/work": policy({ agentMayRelease: true }) } });
  allowed("bash -c 'cd /work && git commit -m x'", { ...split, cwd: "/other" });
  asked("bash -c 'cd /other && git commit -m x'", split);
});

// A scratch repo (temp dir, no remote, no policy): commits go through, pushes still ask.
const scratch = (role: Role): GuardInput => ({
  ...roles[role],
  cwd: "/tmp/s",
  policies: { "/tmp/s": policy({ scratch: true, repo: "/tmp/s" }) },
});
test("a scratch repo: commits go through, pushes still ask", () => {
  allowed("git commit -m x", scratch("desk"));
  allowed("git commit -m x", scratch("headless"));
  assertMatch(decision("git commit -m x", scratch("desk")).approved?.[0] ?? "", /scratch/);
  asked("git push /tmp/bare.git HEAD:feature", scratch("desk"));
  blocked("git commit -m x", scratch("judge"), /read-only/);
  blocked("git commit --no-verify -m x", scratch("desk"), /--no-verify/);
});

// The commands desks ran on 2026-11-13 that made the guard ask (bercail-7ih).
const t1d9 =
  'cd "$(mktemp -d)" && export HOME=$PWD/h XDG_STATE_HOME=$PWD/h/s GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@x && mkdir -p $HOME && B=/w/bin/bercail && git init -q r && cd r && git remote add origin https://x/y.git && git commit -q --allow-empty -m i && git add . && $B describe check --json | jq -c .change';
const t1d3 = `set -e; T=$(mktemp -d); export HOME=$T/home XDG_CONFIG_HOME=$T/cfg XDG_STATE_HOME=$T/state GIT_CONFIG_GLOBAL=$T/gc; mkdir -p $HOME; git config --global user.email t@e; git config --global user.name t
B=$PWD/bin/bercail; cd $T; git init -q -b main r; cd r; mkdir .github; printf '# Summary\\n\\nLoom:\\n' > .github/pull_request_template.md; git add .; git commit -qm init
echo hi > a.txt; git add a.txt`;
test("a repo the same command made with git init under mktemp -d: commits go through, remote or not", () => {
  for (const command of [
    t1d9,
    t1d3,
    "T=$(mktemp -d); cd $T; git init r; cd r; git commit -m x",
    'T=$(mktemp -d /tmp/x.XXXX) && git init -q "$T/r" && git -C "${T}/r" commit -m x',
    "cd `mktemp -d` && git init && git commit -m x",
  ]) {
    allowed(command, roles.desk);
    allowed(command, roles.headless);
    assertMatch(decision(command, roles.desk).approved?.[0] ?? "", /git init under mktemp -d/, command);
  }
});
test("mktemp -d evidence that does not reach the commit's repo still asks", () => {
  for (const command of [
    'cd "$DIR" && git init && git commit -m x',
    'cd "$(mktemp -d)" && git commit -m x',
    'cd "$(mktemp)" && git init && git commit -m x',
    'cd "$(mktemp -d)" && git init r && git commit -m x',
    "T=$(mktemp -d); git init $T; cd $T/..; git commit -m x",
    "T=$(mktemp -d); git init $T; T=/work; cd $T && git commit -m x",
    "T=$(mktemp -d); git init $T; for T in /work; do cd $T && git commit -m x; done",
    "false && T=$(mktemp -d); git init $T; cd $T; git commit -m x",
    "T=$(mktemp -d) | cat; git init $T; cd $T; git commit -m x",
    "T=$(mktemp -d); git init $T; source env.sh; cd $T; git commit -m x",
    "T=$(mktemp -d); git init --separate-git-dir /work/.git $T; cd $T; git commit -m x",
    'cd "$(mktemp -d)" && git init && export GIT_DIR=/work/.git && git commit -m x',
    "T=$(mktemp -d); git init $T; cd /work; git commit -m x",
    "T=$(mktemp -d); git init $T; git -C /work commit -m x",
    // The judge's recheck: a $ the shell leaves alone, a dry run, code that may not run.
    "T=$(mktemp -d); git init -q $T; bash -c 'git -C \"$T\" commit -qm x'",
    "T=$(mktemp -d); git init -q $T; cd '$T'; git commit -m x",
    "T=$(mktemp -d); git init -q $T; cd \\$T; git commit -m x",
    'cd "$(mktemp -du)"; git init -q; git commit -m x',
    'cd "$(mktemp -d --dry-run)"; git init -q; git commit -m x',
    "T=$(mktemp -d); git init -q $T\nin_t() {\n cd $T\n}\ngit commit -m x",
    'if [ -n "$X" ]; then\n T=$(mktemp -d)\nfi\ngit init -q $T; git -C "$T" commit -m x',
    'cd "$(mktemp -d)"; [ -n "$X" ] && git init -q; git commit -m x',
    'cd "$(mktemp -d)"; git init -q || true; git commit -m x',
    'cd "$(mktemp -d)"; git init -q | cat; git commit -m x',
    "T=$(mktemp -d); git init -q $T; cp -r fixtures $T/ && cd $T; git add -A; git commit -qm x",
    'T=$(mktemp -d); git init -q $T; [ -n "$X" ] && cd $T; git commit -qm x',
  ]) {
    asked(command, { ...roles.desk, policies: none });
  }
  blocked('cd "$(mktemp -d; git push --force)"', roles.desk, /Force-push/);
  allowed('T=$(mktemp -d); git init -q $T; bash -c "git -C $T commit -qm x"', roles.desk);
});
test("a GIT_CONFIG variable keeps gh and gt from borrowing the folder's policy", () => {
  asked("GIT_CONFIG_GLOBAL=/tmp/gc gh pr create", at("desk", policies.branch));
  asked("export GIT_CONFIG_GLOBAL=/tmp/gc; gt submit", at("desk", policies.branch));
});
test("a repo made under mktemp -d still asks before a push or a tag", () => {
  const made =
    'cd "$(mktemp -d)" && git init -q r && cd r && git remote add origin https://x/y.git && git commit -qm i';
  asked(`${made} && git push -u origin feature`, roles.desk);
  asked(`${made} && git tag v1.0.0`, roles.desk);
  blocked(`${made} && git push origin feature`, roles.headless, /headless run stages/);
  // A clone is not a repo the command made: its commit and its push ask.
  const clone = 'cd "$(mktemp -d)" && git clone -q https://github.com/o/r r && cd r && git commit -qm x';
  asked(clone, roles.desk);
  asked("cd /tmp/clone && git push origin feature", { ...roles.desk, policies: { "/tmp/clone": defaultPolicy } });
});
test("a cd in a pipe or in the background moves nothing the guard can trust", () => {
  const fromWork = {
    ...scratch("desk"),
    cwd: "/work",
    policies: { ...scratch("desk").policies, "/work": defaultPolicy },
  };
  allowed("cd /tmp/s; git commit -m x", fromWork);
  asked("cd /tmp/s | cat; git commit -m x", fromWork);
  asked("cd /tmp/s & git commit -m x", fromWork);
});

test("reading tags is not a release", () => {
  // Reading tags is not a release.
  allowed("git tag", tui);
  allowed("git tag -l 'v*'", tui);
  allowed("git tag --list", tui);
  allowed("git tag --contains abc123", tui);
  allowed("git tag -n5", tui);
  asked("git tag -d v1.0.0", tui);
  asked("git push origin --delete v1.0.0", tui);
  allowed("gh release list", tui);
  blocked("git tag v1.0.0", judge, /read-only/);
});

test("the files that decide the guard's answers are the person's to edit; secrets are redacted", () => {
  // The files that decide the guard's answers are the person's to edit.
  const guarded = {
    ...tui,
    home: "/h",
    protectedFiles: ["/h/.local/state/bercail/policy-trust.json", "/h/.config/bercail/config.toml"],
  };
  assertEqual(decideTool("write", undefined, guarded, "~/.local/state/bercail/policy-trust.json").action, "block");
  assertEqual(decideTool("edit", undefined, guarded, "/h/.config/bercail/config.toml").action, "block");
  assertEqual(decideTool("edit", undefined, guarded, "/work/.bercail/policy.toml").action, "allow");

  assertEqual(
    redact("git push https://bot:ghp_secret@github.com/o/r.git main"),
    "git push https://***@github.com/o/r.git main",
  );
});

test("a delete is a delete however it is spelled", () => {
  // Ways around a policy the judge found. A delete is a delete however it is spelled.
  for (const role of ["desk", "headless", "shep"] as const) {
    blocked("git push origin :main", at(role, policies.loosest), /Deleting main/);
    blocked("git push origin :refs/heads/master", at(role, policies.loosest), /Deleting main/);
  }
  allowed("git push origin :old-feature", at("desk", policies.branch));
});
test("--all, --branches, and globs may push main: not a branch push", () => {
  // --all, --branches, and globs may push main: not a branch push.
  for (const command of [
    "git push --all origin",
    "git push --branches origin",
    "git push origin 'refs/heads/*'",
    "git push origin 'refs/heads/*:refs/heads/*'",
  ]) {
    asked(command, at("desk", policies.branch));
    blocked(command, at("autopilot", policies.default), /main or master/);
    allowed(command, at("desk", policies.main));
  }
});
test("the branch read before the command runs is stale once a part of it switches", () => {
  // The branch read before the command runs is stale once a part of it switches.
  for (const command of [
    "git checkout main && git push",
    "git switch main; git push origin HEAD",
    "git rebase main && git push",
    "gh pr checkout 3 && git push",
    "gt checkout main && git push",
  ]) {
    asked(command, at("desk", policies.branch));
    blocked(command, at("autopilot", policies.default), /Could not read the current branch/);
  }
  allowed("git status && git push", at("desk", policies.branch));
});
test("config that changes what a later push or commit does is blocked under any policy", () => {
  // Config that changes what a later push or commit does is blocked under any policy.
  for (const command of [
    "git config remote.origin.push '+HEAD:refs/heads/main' && git push",
    "git config remote.origin.mirror true && git push",
    "git config set push.default matching",
    "git config core.hooksPath /dev/null && git commit -m x",
    "git config --global alias.ci 'commit --no-verify'",
    "git config include.path /tmp/evil",
    "git -c alias.ci=commit ci -m x",
    "git -c remote.origin.push=+HEAD:main push",
    "GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null git commit -m x",
    "GIT_CONFIG_PARAMETERS=\"'remote.origin.push'='+HEAD:main'\" git push",
  ]) {
    for (const role of ["desk", "headless", "autopilot"] as const)
      blocked(command, at(role, policies.loosest), /core.hooksPath|without the guard seeing it/);
  }
  allowed("git config --get remote.origin.push", at("desk", policies.default));
  allowed("git config user.name me", at("desk", policies.default));
});
test("a GIT_DIR set or exported anywhere in the command: the guard cannot place git", () => {
  // A GIT_DIR set or exported anywhere in the command: the guard cannot place git.
  for (const command of [
    "export GIT_DIR=/other/.git; git commit -m x",
    "GIT_DIR=/other/.git; git commit -m x",
    "declare -x GIT_WORK_TREE=/other && git commit -m x",
    "export GIT_INDEX_FILE=/tmp/i && git commit -m x",
  ]) {
    asked(command, at("desk", policies.commit));
  }
  asked("cd /tmp/s && export GIT_DIR=/work/.git && git commit -m x", scratch("desk"));
  asked("export GIT_DIR=/work/.git; echo $(git commit -m x)", at("desk", policies.commit));
});
test("trust and the files behind the guard, through bash too", () => {
  // Trust and the files behind the guard, through bash too. A seatbelt, not a sandbox.
  blocked("b=bercail; $b policy trust .", at("desk", policies.default), /person's call/);
  const files = {
    ...at("desk", policies.default),
    home: "/h",
    protectedFiles: ["/h/.local/state/bercail/policy-trust.json", "/h/.config/bercail/config.toml"],
  };
  blocked(
    `printf '[policy."/work"]\ncommit = "allow"\n' >> ~/.config/bercail/config.toml`,
    files,
    /decides what bercail's guard/,
  );
  blocked("echo '{}' >~/.local/state/bercail/policy-trust.json", files, /decides what bercail's guard/);
  blocked("sed -i s/ask/allow/ ~/.config/bercail/config.toml", files, /decides what bercail's guard/);
  blocked("cp /tmp/x ~/.local/state/bercail/policy-trust.json", files, /decides what bercail's guard/);
  allowed("cat ~/.config/bercail/config.toml", files);
});
test("a release through the API is a release", () => {
  // A release through the API is a release.
  asked("gh api -X POST repos/o/r/releases -f tag_name=v1", at("desk", policies.main));
  asked("gh api repos/o/r/git/refs/tags -f ref=refs/tags/v1 -f sha=abc", at("desk", policies.main));
  allowed("gh api repos/o/r/releases/latest", at("desk", policies.default));
  allowed("gh api -X POST repos/o/r/releases -f tag_name=v1", at("desk", policies.release));
});

test("the judge's recheck: eval and source carry on, aliases may move the branch, git by path is git", () => {
  // The judge's recheck: what eval and source set carries on; aliases may move the branch; git by path is git.
  asked("eval 'export GIT_DIR=/other/.git'; git commit -m x", at("desk", policies.commit));
  asked("cd /tmp/s && eval 'export GIT_DIR=/work/.git' && git commit -m x", scratch("desk"));
  asked("source /tmp/env.sh && git commit -m x", at("desk", policies.commit));
  asked(". /tmp/env.sh; git commit -m x", at("desk", policies.commit));
  asked("read GIT_DIR <<< /work/.git && export GIT_DIR && git commit -m x", scratch("desk"));
  asked("eval 'git checkout main'; git push", at("desk", policies.branch));
  asked("git co main && git push", at("desk", policies.branch));
  blocked("git co main && git push", at("autopilot", policies.default), /Could not read the current branch/);
  blocked("/usr/bin/git push --force origin main", at("desk", policies.loosest), /Force-push/);
  blocked("/usr/bin/gh pr merge 3", at("desk", policies.loosest), /gh pr merge/);
  blocked("/bin/bash -c 'git push --force'", at("desk", policies.loosest), /Force-push/);
  allowed("git fetch && git pull && git push", at("desk", policies.branch));
});

// A2: shell prefixes must not hide a command, but arguments remain data.
for (const command of [
  "if true; then git push --force; fi",
  "if git push --force; then true; fi",
  "if false; then true; else git push --force; fi",
  "while git push --force; do true; done",
  "until git push --force; do true; done",
  "while true; do git push --force; done",
  "{ git push --force; }",
  "! git push --force",
  "time git push --force",
  "exec git push --force",
  "nohup git push --force",
  "setsid git push --force",
  "nice git push --force",
  "timeout 5 git push --force",
  "xargs git push --force",
  "time -p git push --force",
  "exec -a worker git push --force",
  "nice -n 5 git push --force",
  "timeout -k 2s 5s git push --force",
  "xargs -n 1 -P 2 git push --force",
  "nohup setsid nice -n 5 timeout 5 git push --force",
  "/usr/bin/timeout 5 git push --force",
  "/usr/bin/nice -n 5 git push --force",
  "/usr/bin/xargs -n 1 git push --force",
]) {
  test(`shell prefix checks ${command}`, () => blocked(command, auto, /Force-push/));
}
for (const command of [
  'echo "time git push --force"',
  "printf '%s' 'gt submit'",
  "xargs echo git push --force",
  "timeout 5 git status",
  "nice -n 5 git diff",
]) {
  test(`shell prefix allows reading: ${command}`, () => allowed(command, judge));
}

const publishers = [
  "gt submit",
  "gh stack submit",
  "gh pr create --fill",
  "origin stack push --all",
  "origin pr create",
];
const committers = ["gt create -m x", "gt modify -c -m x"];
for (const command of [...publishers, ...committers]) {
  test(`publisher policy matrix: ${command}`, () => {
    const isCommit = committers.includes(command);
    for (const [name, fields] of Object.entries(policies)) {
      for (const role of roleNames) {
        const expected = ["judge", "council"].includes(role)
          ? "block"
          : role === "autopilot"
            ? "allow"
            : (isCommit ? fields.commit === "allow" : ["branch", "main"].includes(fields.push ?? ""))
              ? "allow"
              : role === "headless"
                ? "block"
                : "ask";
        const got = decision(command, at(role, fields));
        assertEqual(got.action, expected, `${role} / ${name} / ${command} → ${JSON.stringify(got)}`);
      }
    }
  });
}
for (const command of publishers) {
  test(`publisher on main or unknown branch: ${command}`, () => {
    for (const branch of ["main", "master", ""]) {
      asked(command, at("desk", policies.branch, branch));
      allowed(command, at("desk", policies.main, branch));
      blocked(command, at("autopilot", policies.default, branch), /main or master|Could not read/);
    }
  });
}
for (const command of [
  "gt merge",
  "gh api -X PUT repos/o/r/pulls/5/merge",
  "gh api --method=PUT /repos/o/r/pulls/5/merge",
  "gh api repos/o/r/pulls/5/merge -f merge_method=squash",
  "gh api --hostname forge.example repos/o/r/pulls/5/merge -X PUT",
  "gh api -X GET -X PUT repos/o/r/pulls/5/merge",
  "gh api -X GET --method=PUT repos/o/r/pulls/5/merge",
  "gh api --method=GET --method=PUT repos/o/r/pulls/5/merge",
  "gh api -X PUT -t '--method=GET' repos/o/r/pulls/5/merge",
  "gh api -X PUT -q '--method=GET' repos/o/r/pulls/5/merge",
  "gh api -X PUT --preview '--method=GET' repos/o/r/pulls/5/merge",
  "gh repo sync --force",
  "gt submit --force",
  "gt submit --stack --force",
]) {
  test(`publisher hard block: ${command}`, () => {
    for (const role of roleNames) blocked(command, at(role, policies.loosest), /merge|Force/);
  });
}
for (const command of [
  "gh api repos/o/r/pulls/5/merge",
  "gh api -X GET repos/o/r/pulls/5/merge",
  "gh api --method=GET repos/o/r/pulls/5/merge -f ignored=true",
  "gh api -X PUT -X GET repos/o/r/pulls/5/merge",
  "gh api -X GET -f '--method=PUT' repos/o/r/pulls/5/merge",
  "gt log",
  "gh stack status",
  "origin stack list",
]) {
  test(`publisher read stays allowed: ${command}`, () => allowed(command, judge));
}
for (const command of [
  "gh pr create -R someone/else --fill",
  "gh -R someone/else pr create --fill",
  "gh pr create -Rsomeone/else --fill",
  "gh stack submit --repo=someone/else",
  "gh --repo someone/else stack submit",
  "origin pr create --repo someone/else",
  "origin --repo=someone/else stack push --all",
  "gt -C /other create -m x",
  "gt --cwd=/other submit",
  "gh --hostname forge.example pr create --fill",
  "GIT_DIR=/other/.git gt create -m x",
]) {
  test(`publisher does not inherit cwd trust: ${command}`, () => {
    asked(command, at("desk", policies.loosest));
    blocked(command, at("headless", policies.loosest), /headless run/);
  });
}
for (const command of [
  "gt checkout main && gh pr create",
  "gh pr checkout 3 && origin stack push",
  "git switch main; gt submit",
  "gh -R o/r pr checkout 3 && gt submit",
  "gh --repo=o/r pr checkout 3 && gt submit",
]) {
  test(`publisher respects branch invalidation: ${command}`, () => {
    asked(command, at("desk", policies.branch));
    blocked(command, at("autopilot", policies.default), /Could not read/);
  });
}
