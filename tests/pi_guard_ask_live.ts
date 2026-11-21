// Real Pi as Shep (BERCAIL_ROLE=shep), offline provider, in a throwaway HOME: a push the
// guard would ask about is handed to a guard card and Shep's turn goes on. While the
// card waits, Shep answers a message and a desk event. A panel Allow lands the pinned
// commit once and the guard event reaches Shep; a Deny, and a branch moved before the
// pick, push nothing. No confirm dialog is ever requested.
// Usage: node tests/pi_guard_ask_live.ts ROOT PI
import assert from "node:assert/strict";
import { execFileSync, spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { mkdirSync, mkdtempSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { setTimeout as delay } from "node:timers/promises";

const [ROOT, PI] = process.argv.slice(2).map((arg) => resolve(arg));
const base = mkdtempSync(join(tmpdir(), "guard-ask-live."));
const state = join(base, "state");
const inbox = join(state, "bercail/shep/inbox");
const repo = join(base, "repo");
const origin = join(base, "origin.git");
const bin = join(base, "bin");
const bercail = join(ROOT, "bin/bercail");
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
  BERCAIL_ROLE: "shep",
  BERCAIL_SHEP_INBOX: inbox,
  BERCAIL_BIN: bercail,
  BERCAIL_GUARD_ASK_POLL_MS: "200",
  HC_TERMINAL_ID: "shep-live",
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
mkdirSync(inbox, { recursive: true });
mkdirSync(bin);
// hc run starts the worker in the background, as the Herdr server would; notify-send logs.
writeFileSync(
  join(bin, "hc"),
  `#!/bin/sh\nprintf 'hc %s\\n' "$*" >> '${base}/hc.log'\n[ "$1" = run ] || exit 1\nwhile [ "$#" -gt 0 ] && [ "$1" != -- ]; do shift; done\nshift\nnohup "$@" >> '${base}/worker.log' 2>&1 &\n`,
  { mode: 0o755 },
);
writeFileSync(join(bin, "notify-send"), `#!/bin/sh\nprintf '%s\\n' "$*" >> '${base}/notices.log'\n`, { mode: 0o755 });
const git = (...args: string[]) => execFileSync("git", ["-C", repo, ...args], { env, encoding: "utf8" }).trim();
execFileSync("git", ["init", "-q", "-b", "main", repo], { env });
execFileSync("git", ["init", "-q", "--bare", origin], { env });
execFileSync("git", ["-C", origin, "config", "core.logAllRefUpdates", "always"], { env });
git("commit", "-q", "--allow-empty", "-m", "one");
git("branch", "feature");
git("remote", "add", "origin", origin);
const workspace = join(base, "workspace");
mkdirSync(workspace);

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
    join(ROOT, "shep/pi/inbox.ts"),
    "-e",
    join(ROOT, "tests/pi_guard_ask_provider.ts"),
  ],
  { env, cwd: workspace, stdio: "pipe" },
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
async function prompt(message: string) {
  const id = `req-${++serial}`;
  pi.stdin.write(`${JSON.stringify({ type: "prompt", id, message })}\n`);
  const response = await until(`prompt ${message}`, () => records.find((r) => r.id === id && r.type === "response"));
  assert.equal(response.success, true, JSON.stringify(response));
}
// The assistant's replies so far, as text.
const replies = () =>
  records
    .filter((r) => r.type === "message_end" && r.message?.role === "assistant")
    .map((r) => (r.message.content ?? []).map((part: any) => part.text ?? "").join(""));
const replied = (label: string, test: (text: string) => boolean) => until(label, () => replies().find(test));
const ledger = () => JSON.parse(execFileSync(bercail, ["shep", "question", "json"], { env, encoding: "utf8" }));
const card = (ticket: string) =>
  until(`the card of ${ticket}`, () => ledger().questions.find((q: any) => q.guard?.ticket === ticket));
const pick = (q: any, choice: string) =>
  JSON.parse(
    execFileSync(bercail, ["shep", "question", "answer"], {
      env,
      encoding: "utf8",
      input: JSON.stringify({
        requestId: `pick-${q.id}`,
        token: `${q.id}@${q.revision}`,
        choice,
        source: "panel picker",
      }),
    }),
  );
const pushes = () => {
  try {
    return execFileSync("git", ["-C", origin, "reflog", "show", "--format=%H", "refs/heads/feature"], {
      env,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    })
      .split("\n")
      .filter(Boolean).length;
  } catch {
    return 0;
  }
};
// Shep hands off a push: the tool result says so, and its ticket names the worker.
async function handOff(n: number): Promise<string> {
  const before = replies().length;
  const started = Date.now();
  await prompt(`RUN git -C ${repo} push origin feature`);
  const said = await replied(`hand-off ${n}`, (text) => replies().indexOf(text) >= before && text.startsWith("ECHO "));
  assert.match(said, /^ECHO Handed off, not run: the person answers this push of .* on a Decisions card/, said);
  // Its turn ended at once: no person answered anything in Shep's session.
  assert.ok(Date.now() - started < 15000, `the hand-off took ${Date.now() - started} ms`);
  return /guard-ask-([0-9a-f]{12})/.exec(said)![1];
}

try {
  await until("Pi's RPC session", () => records.length > 0 || pi.pid, 10000);
  // 1. A push by branch name to a remote whose policy asks goes to a guard card.
  const first = await handOff(1);
  const q = await card(first);
  assert.deepEqual(q.options, ["Allow", "Deny"]);
  // 2. While the card waits, Shep answers the person and a desk event.
  await prompt("PING 1");
  await replied("an answer while the card waits", (text) => text === "ECHO PING 1");
  const desk = {
    source: "bercail",
    kind: "finished",
    event_id: "desk-1:finished:1",
    text: "app-1: Fix login. Desk desk-1 finished.",
    agent: { address: "desk-1" },
    space: { id: "space-1", repo: "app", checkout_path: repo },
    desk: { issue: "app-1", issue_title: "Fix login" },
  };
  writeFileSync(join(inbox, "desk.json.tmp"), `${JSON.stringify(desk)}\n`);
  renameSync(join(inbox, "desk.json.tmp"), join(inbox, "desk.json"));
  await replied("the desk event while the card waits", (text) => text.includes("[event desk-1:finished:1]"));
  assert.equal(pushes(), 0, "nothing pushed before the Allow");
  // 3. Allow on the panel: the pinned commit lands once, and the guard event reaches Shep.
  assert.equal(pick(q, "Allow").accepted, true);
  await replied("the guard event of the Allow", (text) => text.includes(`[event guard:${first}]`));
  assert.ok(replies().some((text) => text.includes(`you handed off ran on the person's Allow, exit 0`)));
  assert.equal(
    execFileSync("git", ["-C", origin, "rev-parse", "refs/heads/feature"], { env, encoding: "utf8" }).trim(),
    git("rev-parse", "feature"),
  );
  assert.equal(pushes(), 1);
  // 4. A Deny, and a branch moved before the pick, push nothing.
  git("commit", "-q", "--allow-empty", "-m", "two");
  git("branch", "-f", "feature", "HEAD");
  const denied = await handOff(2);
  pick(await card(denied), "Deny");
  await replied(
    "the guard event of the Deny",
    (text) => text.includes(`[event guard:${denied}]`) && text.includes("was denied by the person; nothing ran"),
  );
  const stale = await handOff(3);
  await card(stale);
  git("commit", "-q", "--allow-empty", "-m", "three");
  git("branch", "-f", "feature", "HEAD");
  await replied(
    "the guard event of the stale card",
    (text) => text.includes(`[event guard:${stale}]`) && text.includes("refspecs changed"),
  );
  assert.equal(pushes(), 1, "a Deny or a stale card pushed");
  // Never a confirm: the guard asked no dialog of Shep's session.
  assert.equal(records.filter((r) => r.type === "extension_ui_request" && r.method === "confirm").length, 0);
  console.log("guard-ask live proof: passed");
  rmSync(base, { recursive: true, force: true });
} catch (error) {
  console.error(`hc.log and worker.log are in ${base}; Pi stderr: ${stderr}`);
  throw error;
} finally {
  pi.kill("SIGKILL");
}
