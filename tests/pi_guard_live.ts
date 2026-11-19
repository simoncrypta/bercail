// Real Pi, offline provider: the guard blocks git push --force, and follows a
// repo's trusted git policy (commit and push go through and are logged; an
// untrusted repo is blocked again in a headless run), and a desk secret reaches op
// through the shim and nothing else.
// Usage: PI_GUARD_BIN=PI node tests/pi_guard_live.ts
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  chmodSync,
  copyFileSync,
  existsSync,
  mkdtempSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  writeFileSync,
  rmSync,
} from "node:fs";
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

function runPi(
  cwd: string,
  commands: string[],
  extra: NodeJS.ProcessEnv = {},
  guard = resolve(root, "bstack/pi/extensions/guard.ts"),
) {
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
    guard,
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
  assert.notEqual(
    spawnSync("git", ["rev-parse", "--verify", "-q", "main"], { env, cwd: remote }).status,
    0,
    "the push to main must not run",
  );
  assert.match(result.stdout, /policy-in-prompt=yes/, out);
  const log: { command: string; approved: string[] }[] = readFileSync(
    join(dir, "state/bercail/guard-approvals.jsonl"),
    "utf8",
  )
    .trim()
    .split("\n")
    .map((line) => JSON.parse(line));
  assert.deepEqual(
    log.map((entry) => entry.command),
    ["git commit -qm 'add a'", "git push -q origin feature"],
  );
  assert.match(log[0].approved[0], /commit = allow \(repo\)/);
  assert.match(log[1].approved[0], /push = branch \(repo\)/);
  console.log(
    "PASS: real Pi let a trusted policy's commit and push through, logged them, and still blocked force and main",
  );

  const untrust = spawnSync(bercail, ["policy", "untrust", repo], { env, encoding: "utf8" });
  assert.equal(untrust.status, 0, untrust.stderr);
  writeFileSync(join(repo, "b.txt"), "b\n");
  git(repo, "add", "b.txt");
  result = runPi(repo, ["git commit -qm 'add b'"]);
  assert.match(result.stdout, /headless run stages/, `stdout: ${result.stdout}`);
  assert.equal(git(repo, "log", "-1", "--format=%s"), "add a");
  assert.equal(
    existsSync(join(dir, "state/bercail/guard-approvals.jsonl")) &&
      readFileSync(join(dir, "state/bercail/guard-approvals.jsonl"), "utf8").trim().split("\n").length,
    2,
  );
  console.log("PASS: real Pi blocked the commit again once the repo was untrusted");

  // A throwaway repo the command makes under mktemp -d, fake remote and all: the
  // commit goes through, the push does not.
  const scratch = `cd "$(mktemp -d)" && git init -q r && cd r && git remote add origin https://x/y.git && git commit -q --allow-empty -m scratch && git log -1 --format=scratch-commit=%s`;
  result = runPi(dir, [scratch, `${scratch} && git push -q origin HEAD:feature`]);
  assert.match(result.stdout, /scratch-commit=scratch/, `stdout: ${result.stdout}`);
  assert.match(result.stdout, /headless run stages/, `stdout: ${result.stdout}`);
  const approvals = readFileSync(join(dir, "state/bercail/guard-approvals.jsonl"), "utf8").trim().split("\n");
  assert.equal(approvals.length, 3, approvals.join("\n"));
  assert.match(JSON.parse(approvals[2]).approved[0], /git init under mktemp -d/);
  console.log("PASS: real Pi let a commit in a repo made under mktemp -d through, and blocked its push");

  // A desk secret: a dummy token in a 0600 file, and a fake op that says whether it got it.
  const token = `ops_dummy-${process.pid}-${Date.now()}`;
  const secrets = join(dir, "secrets");
  mkdirSync(secrets, { mode: 0o700 });
  writeFileSync(join(secrets, "ds-agents.op"), `${token}\n`, { mode: 0o600 });
  const fakeBin = join(dir, "fake-bin");
  mkdirSync(fakeBin);
  writeFileSync(join(fakeBin, "op"), `#!/bin/sh\n[ "$OP_SERVICE_ACCOUNT_TOKEN" = "${token}" ] && echo op-got-token\n`);
  // Where you cannot write it, as the shim requires of the real op.
  chmodSync(join(fakeBin, "op"), 0o555);
  chmodSync(fakeBin, 0o555);
  const ds = join(dir, "ds-repo");
  git(dir, "init", "-q", "-b", "main", ds);
  mkdirSync(join(dir, "config/bercail"), { recursive: true });
  writeFileSync(
    join(dir, "config/bercail/config.toml"),
    `[desk_secrets."${ds}"]\nop_service_account = "${join(secrets, "ds-agents.op")}"\n`,
  );
  // The guard finds the shim beside its own folder, and the shim runs op from fixed
  // system paths: a scratch profile whose shim runs the fake op instead.
  const profile = join(dir, "profile");
  mkdirSync(join(profile, "extensions"), { recursive: true });
  mkdirSync(join(profile, "op-shim"));
  const guard = join(profile, "extensions/guard.ts");
  copyFileSync(resolve(root, "bstack/pi/extensions/guard.ts"), guard);
  copyFileSync(resolve(root, "bstack/pi/extensions/scoped-job.ts"), join(profile, "extensions/scoped-job.ts"));
  const fixed = "for candidate in /usr/bin/op /usr/local/bin/op /opt/homebrew/bin/op; do";
  const shim = readFileSync(resolve(root, "bstack/pi/op-shim/op"), "utf8");
  assert.ok(shim.includes(fixed), "the shim no longer names where op is");
  writeFileSync(join(profile, "op-shim/op"), shim.replace(fixed, `for candidate in ${join(fakeBin, "op")}; do`));
  chmodSync(join(profile, "op-shim/op"), 0o755);
  const withOp = { PATH: `${fakeBin}:${process.env.PATH}` };
  // The guard does not read a script file: this sees the shell's whole environment.
  writeFileSync(join(dir, "env-check.sh"), `env | grep -q '${token}' && echo env-has-token || echo env-clean\n`);
  result = runPi(
    ds,
    [
      "printf 'op-is=%s\\n' \"$(command -v op)\"; op whoami",
      `sh ${join(dir, "env-check.sh")}`,
      "env | wc -l",
      `cat ${join(secrets, "ds-agents.op")}`,
      "op item list",
    ],
    withOp,
    guard,
  );
  const dsOut = `stdout: ${result.stdout}\nstderr: ${result.stderr}`;
  assert.match(result.stdout, new RegExp(`op-is=${profile}/op-shim/op`), dsOut);
  assert.match(result.stdout, /op-got-token/, dsOut);
  assert.match(result.stdout, /env-clean/, dsOut);
  assert.match(result.stdout, /printing the environment/, dsOut);
  assert.match(result.stdout, /op shim alone/, dsOut);
  assert.match(result.stdout, /listing the vault/, dsOut);
  const sessions = (folder: string): string[] =>
    readdirSync(folder, { withFileTypes: true }).flatMap((entry) =>
      entry.isDirectory() ? sessions(join(folder, entry.name)) : [readFileSync(join(folder, entry.name), "utf8")],
    );
  for (const text of [result.stdout, result.stderr, ...sessions(join(dir, "agent"))])
    assert.equal(text.includes(token), false, "the token reached Pi's output or its session files");
  result = runPi(
    ds,
    ["printf 'op-is=%s\\n' \"$(command -v op)\"; op whoami || true"],
    { ...withOp, BERCAIL_ROLE: "judge" },
    guard,
  );
  assert.match(result.stdout, new RegExp(`op-is=${fakeBin}/op`), `stdout: ${result.stdout}`);
  assert.doesNotMatch(result.stdout, /op-got-token/, `stdout: ${result.stdout}`);
  console.log(
    "PASS: real Pi in a repo with a desk secret: op got the token through the shim, the shell and session never did, and the judge had no shim",
  );
} catch (error) {
  console.error(`Artifacts: ${dir}`);
  throw error;
}
if (existsSync(join(dir, "fake-bin"))) chmodSync(join(dir, "fake-bin"), 0o755);
rmSync(dir, { recursive: true, force: true });
