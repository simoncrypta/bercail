// Real Pi as a desk's lead (no BERCAIL_ROLE, HC_TERMINAL_ID set), offline provider, in a
// throwaway HOME with a stand-in hc and bd: a push of the branch its handoff record names
// asks nothing; a push of main asks, and bin/bercail desk answer answers that confirm from
// outside the desk, a No (refused with its reason, nothing pushed, a comment on the issue)
// and then a Yes (it runs, with a warning). Pi's own dialog closes when the answer lands.
// Usage: node tests/pi_desk_answer_live.ts ROOT PI
import assert from "node:assert/strict";
import { execFileSync, spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { setTimeout as delay } from "node:timers/promises";

const [ROOT, PI] = process.argv.slice(2).map((arg) => resolve(arg));
const base = mkdtempSync(join(tmpdir(), "desk-answer-live."));
const state = join(base, "state");
const repo = join(base, "repo");
const origin = join(base, "origin.git");
const bin = join(base, "bin");
const bercail = join(ROOT, "bin/bercail");
const desk = "desk-live";
const env: NodeJS.ProcessEnv = {
  HOME: join(base, "home"),
  XDG_CONFIG_HOME: join(base, "config"),
  XDG_STATE_HOME: state,
  XDG_DATA_HOME: join(base, "data"),
  XDG_CACHE_HOME: join(base, "cache"),
  XDG_RUNTIME_DIR: join(base, "runtime"),
  TMPDIR: join(base, "tmp"),
  PI_CODING_AGENT_DIR: join(base, "agent"),
  PI_OFFLINE: "1",
  PI_SKIP_VERSION_CHECK: "1",
  PI_TELEMETRY: "0",
  PATH: `${bin}:${dirname(process.execPath)}:/usr/bin:/bin`,
  TZ: "UTC",
  LC_ALL: "C",
  TERM: "dumb",
  BERCAIL_BIN: bercail,
  BERCAIL_DESK_ANSWER_POLL_MS: "100",
  HC_TERMINAL_ID: desk,
  HC_BIN: join(bin, "hc"),
  GIT_CONFIG_GLOBAL: join(base, "gitconfig"),
  GIT_CONFIG_NOSYSTEM: "1",
  GIT_AUTHOR_NAME: "t",
  GIT_AUTHOR_EMAIL: "t@example.com",
  GIT_COMMITTER_NAME: "t",
  GIT_COMMITTER_EMAIL: "t@example.com",
};
for (const key of ["HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME", "TMPDIR", "PI_CODING_AGENT_DIR"])
  mkdirSync(env[key]!, { recursive: true });
mkdirSync(env.XDG_RUNTIME_DIR!, { recursive: true, mode: 0o700 });
mkdirSync(join(state, "bercail/desk-sessions"), { recursive: true });
mkdirSync(bin);
// hc knows one live desk; bd logs each comment.
writeFileSync(
  join(bin, "hc"),
  `#!/bin/sh\n[ "$1 $2" = "get ${desk}" ] || exit 3\nprintf '%s\\n' '{"address":"${desk}","state":"live","labels":{"bercail.role":"agent"}}'\n`,
  { mode: 0o755 },
);
writeFileSync(join(bin, "bd"), `#!/bin/sh\nprintf '%s\\n' "$*" >> '${base}/bd.log'\n`, { mode: 0o755 });
const git = (...args: string[]) => execFileSync("git", ["-C", repo, ...args], { env, encoding: "utf8" }).trim();
execFileSync("git", ["init", "-q", "-b", "main", repo], { env });
execFileSync("git", ["init", "-q", "--bare", "-b", "trunk", origin], { env });
git("commit", "-q", "--allow-empty", "-m", "one");
git("checkout", "-q", "-b", "feature");
git("remote", "add", "origin", origin);
// origin's server names its default branch, trunk: with none it can read, a desk's own push asks.
git("push", "-q", "origin", "main:refs/heads/trunk");
writeFileSync(
  join(state, "bercail/handoffs.jsonl"),
  `${JSON.stringify({ v: 1, desk, path: repo, branch: "feature", issue: "app-1", repo })}\n`,
);

const records: any[] = [];
let stderr = "";
const pi: ChildProcessWithoutNullStreams = spawn(
  PI,
  [
    "--mode",
    "rpc",
    "--offline",
    "--no-extensions",
    "--no-skills",
    "--no-context-files",
    "--no-prompt-templates",
    "--no-themes",
    "--no-mcp",
    "--model",
    "fake-shep/model",
    "--session-dir",
    join(base, "sessions"),
    "-e",
    join(ROOT, "bstack/pi/extensions/guard.ts"),
    "-e",
    join(ROOT, "tests/pi_guard_ask_provider.ts"),
  ],
  { env, cwd: repo, stdio: "pipe" },
);
let pending = "";
pi.stdout.setEncoding("utf8");
pi.stdout.on("data", (text: string) => {
  pending += text;
  for (let at = pending.indexOf("\n"); at !== -1; at = pending.indexOf("\n")) {
    const line = pending.slice(0, at).trim();
    pending = pending.slice(at + 1);
    if (line) records.push(JSON.parse(line));
  }
});
pi.stderr.on("data", (text: Buffer) => (stderr += text.toString()));

async function until<T>(label: string, check: () => T | undefined | false, ms = 30000): Promise<T> {
  const end = Date.now() + ms;
  for (;;) {
    assert.equal(pi.exitCode, null, `Pi exited: ${stderr}`);
    const value = check();
    if (value) return value;
    if (Date.now() > end) throw new Error(`deadline waiting for ${label}`);
    await delay(50);
  }
}
let serial = 0;
async function run(command: string) {
  const id = `req-${++serial}`;
  const before = replies().length;
  pi.stdin.write(`${JSON.stringify({ type: "prompt", id, message: `RUN ${command}` })}\n`);
  const response = await until(`prompt ${command}`, () => records.find((r) => r.id === id && r.type === "response"));
  assert.equal(response.success, true, JSON.stringify(response));
  return () =>
    replies()
      .slice(before)
      .find((text) => text.startsWith("ECHO "));
}
const replies = () =>
  records
    .filter((r) => r.type === "message_end" && r.message?.role === "assistant")
    .map((r) => (r.message.content ?? []).map((part: any) => part.text ?? "").join(""));
const confirms = () => records.filter((r) => r.type === "extension_ui_request" && r.method === "confirm");
const onOrigin = (ref: string) => {
  try {
    return execFileSync("git", ["-C", origin, "rev-parse", "--verify", "-q", ref], { env, encoding: "utf8" }).trim();
  } catch {
    return "";
  }
};
const cli = (...args: string[]) =>
  execFileSync(bercail, ["desk", ...args], { env, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
const promptFile = join(state, "bercail/desk-prompts", `${desk}.json`);
// The prompt the desk publishes while its confirm waits; the desk record names its Pi.
async function waiting() {
  const asked = confirms().length;
  await until("the desk's confirm", () => confirms().length > asked && existsSync(promptFile));
  const prompt = JSON.parse(readFileSync(promptFile, "utf8"));
  writeFileSync(
    join(state, "bercail/desk-sessions", `${desk}.json`),
    JSON.stringify({
      address: desk,
      session: prompt.session,
      cwd: repo,
      harness: "pi",
      issue: "app-1",
      pid: prompt.pid,
    }),
  );
  const shown = JSON.parse(cli("prompt", desk));
  assert.equal(shown.id, prompt.id);
  assert.equal(shown.command, "git push origin main");
  return prompt.id as string;
}

try {
  // 1. Its own branch, named by its handoff record: no confirm.
  const own = await run("git push origin feature");
  const ownSaid = await until("the own-branch push", own);
  assert.equal(confirms().length, 0, `a confirm for its own branch: ${ownSaid}`);
  assert.equal(onOrigin("refs/heads/feature"), git("rev-parse", "feature"));
  // 2. main asks; a No from outside refuses it with its reason, and goes on the issue.
  const no = await run("git push origin main");
  const first = await waiting();
  assert.match(cli("answer", desk, "no", "--prompt", first, "--reason", "the person picked no push"), /answered No/);
  const noSaid = await until("the refusal", no);
  assert.match(noSaid, /Answered No from outside the desk \(bercail desk answer\): the person picked no push/);
  assert.equal(onOrigin("refs/heads/main"), "", "main was pushed after a No");
  assert.match(readFileSync(join(base, "bd.log"), "utf8"), /^comment app-1 bercail desk answer: answered No to desk /m);
  assert.ok(!existsSync(promptFile), "the prompt is gone once answered");
  // An answer to that closed prompt is refused, and nothing is written.
  assert.throws(() => cli("answer", desk, "yes", "--prompt", first), /the prompt you read is gone/);
  // 3. Asked again: a new id. A Yes from outside runs it, with a warning in its result.
  const yes = await run("git push origin main");
  const second = await waiting();
  assert.notEqual(second, first);
  cli("answer", desk, "yes", "--prompt", second);
  const yesSaid = await until("the push after a Yes", yes);
  assert.match(yesSaid, /answered Yes from outside the desk/);
  assert.equal(onOrigin("refs/heads/main"), git("rev-parse", "main"));
  console.log("desk-answer live proof: passed");
  rmSync(base, { recursive: true, force: true });
} catch (error) {
  console.error(`files are in ${base}; Pi stderr: ${stderr}`);
  throw error;
} finally {
  pi.kill("SIGKILL");
}
