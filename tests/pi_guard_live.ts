// Real Pi, offline provider: the guard blocks git push --force, runs a commit
// with a warning in its result, follows a repo's trusted push policy (logged),
// refuses the push again in a headless run once the repo is untrusted, and
// refuses a judge's and a background Shep's commit. Warnings and refusals land
// in guard-warnings.jsonl.
// Usage: PI_GUARD_BIN=PI node tests/pi_guard_live.ts
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, mkdirSync, readFileSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../", import.meta.url));
const pi = process.env.PI_GUARD_BIN || "pi";
const dir = mkdtempSync(join(tmpdir(), "pi-guard-"));
const bercail = resolve(root, "bin/bercail");
const env: NodeJS.ProcessEnv = {
  ...process.env,
  HOME: dir,
  XDG_STATE_HOME: join(dir, "state"),
  XDG_CONFIG_HOME: join(dir, "config"),
  PI_CODING_AGENT_DIR: join(dir, "agent"),
  PI_OFFLINE: "1",
  TMPDIR: dir,
  BERCAIL_BIN: bercail,
  GIT_CONFIG_GLOBAL: join(dir, "gitconfig"),
  GIT_CONFIG_NOSYSTEM: "1",
  GIT_AUTHOR_NAME: "t",
  GIT_AUTHOR_EMAIL: "t@example.com",
  GIT_COMMITTER_NAME: "t",
  GIT_COMMITTER_EMAIL: "t@example.com",
};
delete env.BERCAIL_ROLE;
delete env.HC_TERMINAL_ID;
delete env.BERCAIL_CONFIG;

function runPi(cwd: string, commands: string[], extra: NodeJS.ProcessEnv = {}) {
  const args = [
    "--offline",
    "--no-extensions",
    "--no-skills",
    "--no-prompt-templates",
    "--no-context-files",
    "--no-mcp",
    "--mode",
    "json",
    "-p",
    "-e",
    resolve(root, "bstack/pi/extensions/guard.ts"),
    "-e",
    resolve(root, "tests/pi_guard_provider.ts"),
    "--model",
    "fake-guard/model",
    "Do the git work.",
  ];
  const result = spawnSync(pi, args, {
    env: { ...env, ...extra, PI_GUARD_COMMANDS: JSON.stringify(commands) },
    cwd,
    encoding: "utf8",
    timeout: 60000,
  });
  assert.equal(result.error, undefined, String(result.error));
  assert.doesNotMatch(result.stderr, /Failed to load extension/i, result.stderr);
  return result;
}

function git(cwd: string, ...args: string[]) {
  const result = spawnSync("git", args, { env, cwd, encoding: "utf8" });
  assert.equal(result.status, 0, `git ${args.join(" ")}: ${result.stderr}`);
  return result.stdout.trim();
}

try {
  mkdirSync(join(dir, "agent"), { recursive: true });
  writeFileSync(
    join(dir, "agent/settings.json"),
    JSON.stringify({ retry: { enabled: false }, compaction: { enabled: false } }),
  );

  let result = runPi(dir, ["git push --force"]);
  assert.match(result.stdout, /Force-push is blocked/, `stdout: ${result.stdout}\nstderr: ${result.stderr}`);
  assert.doesNotMatch(result.stdout, /No configured push destination|Everything up-to-date/, "the push must not run");
  console.log("PASS: real Pi blocked git push --force");

  // op read piped into a command: with no op here the pipe would still run it.
  const fed = join(dir, "fed");
  result = runPi(dir, [`op read op://v/i/p | touch ${fed}`]);
  assert.match(result.stdout, /still runs on an empty value/, `stdout: ${result.stdout}\nstderr: ${result.stderr}`);
  assert.equal(existsSync(fed), false, "the consumer must not run");
  console.log("PASS: real Pi blocked op read piped into a command");

  // A repo whose policy lets branch pushes through, with a local bare remote.
  const repo = join(dir, "repo");
  const remote = join(dir, "remote.git");
  git(dir, "init", "-q", "--bare", remote);
  git(dir, "init", "-q", "-b", "main", repo);
  git(repo, "remote", "add", "origin", remote);
  mkdirSync(join(repo, ".bercail"));
  writeFileSync(join(repo, ".bercail/policy.toml"), 'push = "branch"\nrules = "Squash nothing."\n');
  git(repo, "add", ".");
  git(repo, "commit", "-qm", "init");
  git(repo, "switch", "-qc", "feature");
  const trust = spawnSync(bercail, ["policy", "trust", repo], { env, encoding: "utf8" });
  assert.equal(trust.status, 0, trust.stderr);

  writeFileSync(join(repo, "a.txt"), "a\n");
  git(repo, "add", "a.txt");
  result = runPi(repo, [
    "git commit -qm 'add a'",
    "git push -q origin feature",
    "git push --force origin feature",
    "git push origin feature:main",
  ]);
  const out = `stdout: ${result.stdout}\nstderr: ${result.stderr}`;
  assert.equal(git(repo, "log", "-1", "--format=%s"), "add a", out);
  assert.equal(git(remote, "rev-parse", "feature"), git(repo, "rev-parse", "HEAD"), out);
  assert.match(result.stdout, /bercail guard warning: This commit ran, but desks stage/, out);
  assert.match(result.stdout, /Force-push is blocked/, out);
  assert.match(result.stdout, /headless run stages/, out);
  assert.notEqual(
    spawnSync("git", ["rev-parse", "--verify", "-q", "main"], { env, cwd: remote }).status,
    0,
    "the push to main must not run",
  );
  assert.match(result.stdout, /policy-in-prompt=yes/, out);
  const lines = (name: string) =>
    readFileSync(join(dir, "state/bercail", name), "utf8")
      .trim()
      .split("\n")
      .map((line) => JSON.parse(line) as { command: string; approved?: string[]; kind?: string });
  const log = lines("guard-approvals.jsonl");
  assert.deepEqual(
    log.map((entry) => entry.command),
    ["git push -q origin feature"],
  );
  assert.match(log[0].approved?.[0] ?? "", /push = branch \(repo\)/);
  // The force-push and op read refusals above come first.
  assert.deepEqual(
    lines("guard-warnings.jsonl")
      .slice(2)
      .map((entry) => [entry.kind, entry.command]),
    [
      ["warning", "git commit -qm 'add a'"],
      ["refusal", "git push --force origin feature"],
      ["refusal", "git push origin feature:main"],
    ],
  );
  console.log(
    "PASS: real Pi ran a commit with a warning, let a trusted policy's push through, logged both, and still blocked force and main",
  );

  // Untrusted, the repo asks before a push: a headless commit still runs with a
  // warning, and the push is refused.
  const untrust = spawnSync(bercail, ["policy", "untrust", repo], { env, encoding: "utf8" });
  assert.equal(untrust.status, 0, untrust.stderr);
  writeFileSync(join(repo, "b.txt"), "b\n");
  git(repo, "add", "b.txt");
  const before = git(remote, "rev-parse", "feature");
  result = runPi(repo, ["git commit -qm 'add b'", "git push -q origin feature"]);
  assert.match(result.stdout, /bercail guard warning: This commit ran/, `stdout: ${result.stdout}`);
  assert.match(result.stdout, /headless run stages/, `stdout: ${result.stdout}`);
  assert.equal(git(repo, "log", "-1", "--format=%s"), "add b");
  assert.equal(git(remote, "rev-parse", "feature"), before, "the push must not run");
  console.log("PASS: real Pi ran a headless commit with a warning in a repo that asks, and refused its push");

  // The judge and background Shep never commit.
  writeFileSync(join(repo, "c.txt"), "c\n");
  git(repo, "add", "c.txt");
  for (const role of ["judge", "shep-bg"]) {
    result = runPi(repo, ["git commit -qm 'add c'"], { BERCAIL_ROLE: role });
    assert.match(result.stdout, /read-only|does not commit/, `${role} stdout: ${result.stdout}`);
    assert.equal(git(repo, "log", "-1", "--format=%s"), "add b", role);
  }
  const kinds = lines("guard-warnings.jsonl").map((entry) => entry.kind);
  assert.deepEqual(kinds.slice(-4), ["warning", "refusal", "refusal", "refusal"], kinds.join(" "));
  console.log("PASS: real Pi refused a judge's commit and a background Shep's, and logged each");
} catch (error) {
  console.error(`Artifacts: ${dir}`);
  throw error;
}
rmSync(dir, { recursive: true, force: true });
