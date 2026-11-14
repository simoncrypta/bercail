// Decision table for bercail's Pi guard. No Pi process.
import { spawnSync } from "node:child_process";
import { expect, test } from "vite-plus/test";
import guard, {
  type GuardInput,
  type Policy,
  decideBash,
  decideTool,
  defaultPolicy,
  isReviewWorktree,
  policyFromJson,
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

// A test cannot stop a loop in its own process, so this one runs the guard in a
// child node killed after 5 seconds: a hang fails the case instead of the run.
function decideInChild(command: string, input: GuardInput): Decision {
  const guardUrl = new URL("../bstack/pi/extensions/guard.ts", import.meta.url).href;
  const script = `import { readFileSync } from "node:fs";
    const { decideBash } = await import(${JSON.stringify(guardUrl)});
    const { command, input } = JSON.parse(readFileSync(0, "utf8"));
    process.stdout.write(JSON.stringify(decideBash(command, input)));`;
  const run = spawnSync(process.execPath, ["--input-type=module", "-e", script], {
    input: JSON.stringify({ command, input }),
    encoding: "utf8",
    timeout: 5000,
  });
  assertEqual(run.signal, null, `${command} hung the guard`);
  assertEqual(run.status, 0, run.stderr);
  return JSON.parse(run.stdout);
}

test("a $( or backtick the tokenizer can't close is blocked, and does not hang", () => {
  // Seen live: Shep froze on id=$(bd create --body-file - <<'EOF' with an apostrophe
  // in the body; readBalanced gave up and tokenize spun on the $ forever.
  const unclosed = [
    "id=$(bd create --body-file - <<'EOF'\nit's here\nEOF\n); echo $id",
    "echo `git status",
    // Bash runs each of these. Checking the rest as the sub's body read main) for main.
    "x=$(echo \\'; git push origin main)",
    "x=$(cat <<'EOF'\nit's\nEOF\ngit push origin main)",
    "x=$(echo \\'; gh pr merge 1)",
    "x=$(echo \\'; git push --no-verify)",
    "x=$(echo \\'; git push origin --delete main)",
    "x=$(echo \\'; bercail policy trust)",
  ];
  for (const command of unclosed) {
    const got = decideInChild(command, auto);
    assertEqual(got.action, "block", `${command} → ${JSON.stringify(got)}`);
    assertMatch(got.reason ?? "", /Write the body to a file/);
  }
  allowed("id=$(bd create --body-file - <<'EOF'\nit is here\nEOF\n); echo $id", headless);
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
    // eval joins its words and runs them, like bash -c.
    blocked("eval git push --force", input, /Force-push/);
    blocked("eval 'git push' --force", input, /Force-push/);
    blocked("eval -- git push --force", input, /Force-push/);
    blocked("eval gh pr merge 3", input, /gh pr merge/);
    blocked("eval entire trail approve 3", input, /person's call/);
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

// Entire: reads pass, a trail publish is a push, approve and merge are the
// person's, and so are setup, login and anything that rewrites or deletes.
for (const command of [
  "entire status",
  "entire why lib/desk.sh:12",
  "entire trail show",
  "entire trail list --project gh/simoncrypta",
  "entire trail finding",
  "entire trail finding list --severity high",
  "entire checkpoint explain 01M7BPKH122DK761RTTN58R0Z0",
  "entire cp list",
  "entire session current",
  "entire auth status",
  "entire agent-help trail",
  "entire repo view /gh/o/r",
]) {
  test(`entire read: ${command}`, () => {
    for (const role of roleNames) allowed(command, at(role, policies.default));
  });
}
// Roles the policy table leaves out: the builder sibling, background Shep
// (BERCAIL_ROLE=shep-bg, tests/shep.bats), and Shep with nobody at its screen.
const offTable: Record<string, GuardInput> = Object.fromEntries(
  [
    ["builder", "builder", true],
    ["shep-bg", "shep-bg", true],
    ["headless shep", "shep", false],
  ].map(([name, role, hasUI]) => [
    name,
    { ...at("desk", policies.loosest), role: role as string, hasUI: hasUI as boolean },
  ]),
);
const everyoneBut = (shep: boolean) => [
  ...roleNames.filter((role) => shep || role !== "shep").map((role) => at(role, policies.loosest)),
  ...Object.values(offTable),
];
// Shep merges a trail when the person asks: the guard asks, since a project
// trail can merge a change in another repo, which no checkout's policy covers.
for (const command of [
  "entire trail merge",
  "entire trail merge 3",
  "entire trail merge lesentiel/1 --json",
  "entire --context work trail merge",
  "entire trail --branch feature merge",
  "entire trail merge --repo gh/o/r 1",
  "entire trail merge --dry-run",
  "entire trail merge --help",
  "entire trail merge 3 -- --force",
  "export GIT_TERMINAL_PROMPT=0\nentire trail merge",
  "entire trail merge 3 2>&1",
]) {
  test(`only Shep merges a trail, and it asks: ${command}`, () => {
    asked(command, at("shep", policies.loosest));
    asked(command, at("shep", policies.default));
    for (const input of everyoneBut(false)) blocked(command, input, /person's call/);
  });
}
for (const [command, reason] of [
  ["entire trail merge 3 --force --yes", /no --force/],
  ["entire trail merge --dry-run --force", /no --force/],
  ["entire trail merge 3 --force=false", /no --force/],
  ["entire trail --unknown-flag merge 3", /no flag before merge/],
  ["entire --json 3 trail merge", /no flag before merge/],
  ["entire --json status trail merge 3", /no flag before merge/],
  ["entire -v agent-help trail merge", /no flag before merge/],
  ["entire trail --unknown-flag merge finding dismiss 2", /no flag before merge/],
  ["entire trail finding dismiss 2 merge", /no flag before merge/],
] as const) {
  test(`a forced merge, or one a flag could hide, is blocked for Shep too: ${command}`, () => {
    blocked(command, at("shep", policies.loosest), reason);
    // The words as written may stop another role first, as an unknown command.
    for (const input of everyoneBut(false)) blocked(command, input);
  });
}
for (const command of [
  "entire trail approve 3 -m ok",
  "entire trail approve 3 -m --help",
  "entire trail approve 3 -m -h",
  "entire trail --unknown-flag show approve",
  "entire trail --unknown-flag merge approve 3",
  "entire trail merge approve",
  "entire --verbose agent-help trail approve 3",
  "/usr/local/bin/entire trail approve",
  "entire api -X POST /api/v1/trails/3/merge",
  "entire api -X PUT '/api/v1/repos/{owner}/{repo}/trails/3/approvals'",
  "entire api /api/v1/trails/3 -f action=merge",
  // A dismissed finding can clear a merge gate (bercail-1vv).
  "entire trail finding dismiss 2",
  "entire trail finding dismiss 2 -m -h",
  "entire trail finding dismiss 2 -m --help",
  "entire trail --unknown-flag finding dismiss 2",
  "entire api -X POST /api/v1/trails/3/findings/2/dismiss",
  "entire api /api/v1/trails/3/findings/2 -f status=dismissed",
]) {
  test(`approving a trail, dismissing a finding, or merging through entire api, is the person's: ${command}`, () => {
    for (const input of everyoneBut(true)) blocked(command, input, /person's call/);
  });
}
test("unclassified entire api calls ask, but agent-help stays a read", () => {
  asked("entire api /api/v1/clusters", at("shep", policies.loosest));
  allowed("entire agent-help trail merge", at("desk", policies.loosest));
});
for (const [command, reason] of [
  ["entire enable --agent pi", /Suggest it to the person/],
  ["entire disable --uninstall", /Suggest it to the person/],
  ["entire configure --local --skip-push-sessions", /Suggest it to the person/],
  ["entire agent add pi --force", /Suggest it to the person/],
  ["entire login", /Suggest it to the person/],
  ["entire repo mirror add /gh/o/r", /Suggest it to the person/],
  ["entire repo remote add origin --override", /Suggest it to the person/],
  ["entire checkpoint delete 01M7BPKH122DK761RTTN58R0Z0", /deletes checkpoints/],
  ["entire session attach 01a1 --force", /amends a commit/],
  ["entire session resume feature -f", /amends a commit/],
  ["entire sessions attach 01a1 --force", /amends a commit/],
  ["entire session attach 01a1 -fa pi", /amends a commit/],
  ["entire enable --agent pi --initial-commit-message -h", /Suggest it to the person/],
  ["entire configure --checkpoint-remote --help", /Suggest it to the person/],
] as const) {
  test(`entire setup, rewrites and deletes are blocked: ${command}`, () => {
    for (const role of roleNames) blocked(command, at(role, policies.loosest), reason);
  });
}
for (const command of [
  "entire trail create --title x",
  "entire trail link 3",
  "entire trail ci-pr",
  "entire checkpoint push",
]) {
  test(`entire publish follows the push policy: ${command}`, () => {
    for (const [name, fields] of Object.entries(policies)) {
      for (const role of roleNames) {
        const expected = ["judge", "council"].includes(role)
          ? "block"
          : role === "autopilot" || ["branch", "main"].includes(fields.push ?? "")
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
test("entire trail writes are like gh pr edit; unknown commands ask", () => {
  for (const command of [
    "entire trail update --body x",
    "entire trail ready",
    "entire trail finding reply 1 --body x",
    "entire trail finding resolve 2",
  ]) {
    for (const role of ["desk", "shep", "headless", "autopilot"] as const) allowed(command, at(role, policies.default));
    blocked(command, at("judge", policies.default), /read-only/);
  }
  for (const command of ["entire checkpoint explain 01M7 --generate", "entire dispatch", "entire session stop"]) {
    asked(command, at("desk", policies.loosest));
    blocked(command, at("headless", policies.loosest));
    blocked(command, at("autopilot", policies.loosest));
    blocked(command, at("council", policies.loosest));
  }
});
test("entire --repo does not lend cwd trust, and a trail checkout moves the branch", () => {
  asked("entire trail create --repo gh/o/r --title x", at("desk", policies.loosest));
  blocked("entire trail create --repo gh/o/r --title x", at("headless", policies.loosest), /headless run/);
  asked("entire trail checkout 3 && git push", at("desk", policies.branch));
  asked("entire trail create --title x --checkout && git push", at("desk", policies.branch));
});

// Brain and Graph, as entire brain …, entire graph …, or the plugin binary itself.
for (const command of [
  'entire brain brief "fix the lease gate" --json',
  "entire brain recall retry --json --k 5",
  "entire-brain recall retry --locus src/lease.ts",
  "/home/u/.local/share/entire/plugins/bin/entire-brain status --json",
  "entire brain query --source history retries",
  "entire brain inspect code runPiDesk",
  "entire brain memories storage status",
  "entire brain memories tree --path preferences",
  "entire graph query 'where is the retry policy'",
  "entire-graph impact runPiDesk --repo .",
  "entire plugin list",
  "entire plugin info brain",
]) {
  test(`brain and graph read: ${command}`, () => {
    for (const role of roleNames) allowed(command, at(role, policies.default));
  });
}
for (const command of ["entire brain refresh delta", "entire-brain refresh seed --agent none", "entire graph index"]) {
  test(`a local brain refresh is a write, not a read: ${command}`, () => {
    for (const role of ["desk", "shep", "headless", "autopilot"] as const) allowed(command, at(role, policies.default));
    for (const role of ["judge", "council"] as const) blocked(command, at(role, policies.default), /read-only/);
  });
}
for (const command of [
  'entire brain remember "retries back off" --path conventions.retry',
  'entire-brain remember "retries back off" --path=conventions.retry --json',
  "entire brain memories retract 01JX",
]) {
  test(`only Shep records a memory; everyone else proposes it: ${command}`, () => {
    allowed(command, at("shep", policies.loosest));
    for (const role of roleNames.filter((r) => r !== "shep"))
      blocked(command, at(role, policies.loosest), /Propose it/);
  });
}
for (const [command, reason] of [
  ['entire brain remember "retries back off"', /tokens/],
  ["entire brain remember x --kind --path", /tokens/],
  ["entire brain distill --dry-run", /tokens/],
  ["entire brain recall retry --expand", /tokens/],
  ["entire-brain refresh seed --agent claude-code", /tokens/],
  ["entire brain patterns skills form 3", /tokens/],
  ["entire brain setup --no-backfill --no-daemon", /Suggest it/],
  ["entire-brain setup", /Suggest it/],
  ["entire-brain connect", /Suggest it/],
  ["entire-graph setup --repo .", /Suggest it/],
  ["entire brain memories sync", /Suggest it/],
  ["entire brain remember x --path p --global", /Suggest it/],
  ["entire brain brief x --graph-binary ./evil", /Suggest it/],
  ["entire brain recall x --agent command --agent-command sh", /Suggest it/],
  ["entire brain workspace watch", /Suggest it/],
  ["entire plugin install brain --yes", /Suggest it/],
  ["entire plugin upgrade brain", /Suggest it/],
] as const) {
  test(`brain setup, sync and model calls are the person's: ${command}`, () => {
    for (const role of roleNames) blocked(command, at(role, policies.loosest), reason);
  });
}
test("an unknown brain or graph command, or a flag before its subcommand, asks a desk", () => {
  for (const command of [
    "entire brain inspect graph-ui",
    "entire brain hook pre-edit src/a.ts",
    "entire brain memories bogus",
    "entire graph index --report GRAPH_REPORT.md",
    "entire-brain --workspace status setup --backfill --yes",
    "entire brain --json status setup",
    "entire brain memories --json status sync",
  ]) {
    asked(command, at("desk", policies.loosest));
    for (const role of ["headless", "autopilot", "council"] as const) blocked(command, at(role, policies.loosest));
  }
});
test("graph verify's --test and --setup are checked as bash, in its --repo", () => {
  for (const role of roleNames) {
    allowed("entire graph verify --test 'npm test' --setup 'npm ci'", at(role, policies.loosest));
    blocked("entire graph verify --test 'git push --force'", at(role, policies.loosest), /Force-push/);
    blocked(
      "entire-graph verify --setup='entire-brain connect' --test 'npm test'",
      at(role, policies.loosest),
      /Suggest it/,
    );
  }
  allowed("entire graph verify --test 'git push origin main'", at("desk", policies.main, "main"));
  asked("entire graph verify --repo /other --test 'git push origin main'", at("desk", policies.main, "main"));
});

test("in an Entire repo, pushing every branch is blocked: shadow branches hold unredacted snapshots", () => {
  for (const role of ["desk", "shep", "headless"] as const) {
    for (const command of ["git push --all origin", "git push --branches", "git push origin 'refs/heads/*'"]) {
      blocked(command, at(role, { push: "main", entire: true }), /shadow branches/);
      allowed(command, at(role, { push: "main" }));
    }
    allowed("git push origin feature", at(role, { push: "main", entire: true }));
  }
});

test("policy show --json says whether Entire is on; the guard takes it as it is", () => {
  const json = { repo: "/m", scratch: false, prompt: "", sources: {} };
  const policyJson = { commit: "allow", push: "main", agent_may_release: false } as const;
  assertEqual(policyFromJson({ ...json, entire: true, policy: policyJson }).entire, true);
  assertEqual(policyFromJson({ ...json, policy: policyJson }).entire, false);
});

test("a review worktree's project files are never trusted; other folders are left to Pi", async () => {
  assertEqual(isReviewWorktree("/home/u/Work/app.review-12"), true);
  assertEqual(isReviewWorktree("/home/u/Work/app.review-12/lib"), true);
  assertEqual(isReviewWorktree("/home/u/Work/app.reviews-12"), false);
  assertEqual(isReviewWorktree("/home/u/Work/app.review"), false);
  assertEqual(isReviewWorktree("/home/u/Work/app"), false);
  const handlers: Record<string, (event: { cwd: string }) => Promise<unknown>> = {};
  guard({
    on: (name: string, handler: (event: { cwd: string }) => Promise<unknown>) => (handlers[name] = handler),
  } as never);
  assertDeepEqual(await handlers.project_trust({ cwd: "/home/u/Work/app.review-3" }), { trusted: "no" });
  assertDeepEqual(await handlers.project_trust({ cwd: "/home/u/Work/app" }), { trusted: "undecided" });
});
