// Real Pi, offline provider: the guard blocks git push --force, and follows a
// repo's trusted git policy (commit and push go through and are logged; an
// untrusted repo is blocked again in a headless run).
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
const env = {
  ...process.env,
  HOME: dir,
  XDG_STATE_HOME: join(dir, "state"),
  XDG_CONFIG_HOME: join(dir, "config"),
  PI_CODING_AGENT_DIR: join(dir, "agent"),
  PI_OFFLINE: "1",
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

function runPi(cwd, commands) {
  const args = [
    "--offline", "--no-extensions", "--no-skills", "--no-prompt-templates", "--no-context-files", "--no-mcp",
    "--mode", "json", "-p",
    "-e", resolve(root, "bstack/pi/extensions/guard.ts"),
    "-e", resolve(root, "tests/pi_guard_provider.ts"),
    "--model", "fake-guard/model",
    "Do the git work.",
  ];
  const result = spawnSync(pi, args, { env: { ...env, PI_GUARD_COMMANDS: JSON.stringify(commands) }, cwd, encoding: "utf8", timeout: 60000 });
  assert.equal(result.error, undefined, String(result.error));
  assert.doesNotMatch(result.stderr, /Failed to load extension/i, result.stderr);
  return result;
}

function git(cwd, ...args) {
  const result = spawnSync("git", args, { env, cwd, encoding: "utf8" });
  assert.equal(result.status, 0, `git ${args.join(" ")}: ${result.stderr}`);
  return result.stdout.trim();
}

try {
  mkdirSync(join(dir, "agent"), { recursive: true });
  writeFileSync(join(dir, "agent/settings.json"), JSON.stringify({ retry: { enabled: false }, compaction: { enabled: false } }));

  let result = runPi(dir, ["git push --force"]);
  assert.match(result.stdout, /Force-push is blocked/, `stdout: ${result.stdout}\nstderr: ${result.stderr}`);
  assert.doesNotMatch(result.stdout, /No configured push destination|Everything up-to-date/, "the push must not run");
  console.log("PASS: real Pi blocked git push --force");

  // A repo whose policy lets commits and branch pushes through, with a local bare remote.
  const repo = join(dir, "repo");
  const remote = join(dir, "remote.git");
  git(dir, "init", "-q", "--bare", remote);
  git(dir, "init", "-q", "-b", "main", repo);
  git(repo, "remote", "add", "origin", remote);
  mkdirSync(join(repo, ".bercail"));
  writeFileSync(join(repo, ".bercail/policy.toml"), 'commit = "allow"\npush = "branch"\nrules = "Squash nothing."\n');
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
  assert.match(result.stdout, /Force-push is blocked/, out);
  assert.match(result.stdout, /headless run stages/, out);
  assert.notEqual(spawnSync("git", ["rev-parse", "--verify", "-q", "main"], { env, cwd: remote }).status, 0, "the push to main must not run");
  assert.match(result.stdout, /policy-in-prompt=yes/, out);
  const log = readFileSync(join(dir, "state/bercail/guard-approvals.jsonl"), "utf8").trim().split("\n").map((line) => JSON.parse(line));
  assert.deepEqual(log.map((entry) => entry.command), ["git commit -qm 'add a'", "git push -q origin feature"]);
  assert.match(log[0].approved[0], /commit = allow \(repo\)/);
  assert.match(log[1].approved[0], /push = branch \(repo\)/);
  console.log("PASS: real Pi let a trusted policy's commit and push through, logged them, and still blocked force and main");

  const untrust = spawnSync(bercail, ["policy", "untrust", repo], { env, encoding: "utf8" });
  assert.equal(untrust.status, 0, untrust.stderr);
  writeFileSync(join(repo, "b.txt"), "b\n");
  git(repo, "add", "b.txt");
  result = runPi(repo, ["git commit -qm 'add b'"]);
  assert.match(result.stdout, /headless run stages/, `stdout: ${result.stdout}`);
  assert.equal(git(repo, "log", "-1", "--format=%s"), "add a");
  assert.equal(existsSync(join(dir, "state/bercail/guard-approvals.jsonl")) && readFileSync(join(dir, "state/bercail/guard-approvals.jsonl"), "utf8").trim().split("\n").length, 2);
  console.log("PASS: real Pi blocked the commit again once the repo was untrusted");
} catch (error) {
  console.error(`Artifacts: ${dir}`);
  throw error;
}
rmSync(dir, { recursive: true, force: true });
