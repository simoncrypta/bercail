// Disposable Pi TUI: the extension records the session without a subscription.
// Usage: node tests/desk_session_pi_live.ts ROOT PI
import { chmodSync, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { isDeepStrictEqual } from "node:util";
import { Term, fail, fails, pass, sleep, waitFor } from "./live_term.ts";

const [ROOT, PI] = process.argv.slice(2) as [string, string];
const EXT = join(ROOT, "config/pi/extensions/bercail-desk.ts");
const PROVIDER = join(ROOT, "tests/desk_session_pi_provider.ts");
const TOKEN = "desk-pi-ping";
const WORK = `/tmp/desk-session-pi.${process.pid}`;
const TUIS: Term[] = [];

type Record = { [k: string]: unknown };

async function killAll(): Promise<void> {
  for (const tui of TUIS) tui.signal("SIGTERM");
  await sleep(200);
  for (const tui of TUIS) {
    tui.signal("SIGKILL");
    tui.proc.stdin!.destroy();
  }
}

function childEnv(base: NodeJS.ProcessEnv, extra: NodeJS.ProcessEnv = {}): NodeJS.ProcessEnv {
  const drop = new Set([
    "HC_TERMINAL_ID",
    "HC_SESSION",
    "HC_TERMINAL_SOCKET",
    "BASH_ENV",
    "PI_CODING_AGENT_DIR",
    "PI_SESSION_ID",
    "PI_SESSION_FILE",
    "PI_PROVIDER",
    "PI_MODEL",
    "PI_REASONING_LEVEL",
    "PI_OFFLINE",
  ]);
  const env: NodeJS.ProcessEnv = Object.fromEntries(Object.entries(process.env).filter(([k]) => !drop.has(k)));
  return { ...env, ...base, ...extra, TERM: "xterm-256color", COLORTERM: "truecolor", PI_OFFLINE: "1" };
}

function startTicks(pid: number): string {
  const text = readFileSync(`/proc/${pid}/stat`, "utf8");
  return text.slice(text.lastIndexOf(")") + 2).split(/\s+/)[19]!;
}

function recordText(address: string, pid: number, harness: string): string {
  return (
    JSON.stringify({
      address,
      session: "",
      cwd: "/stale",
      harness,
      issue: "bercail-1",
      space: "sp1",
      args: ["--verbose"],
      pid,
    }) + "\n"
  );
}

const quote = (s: string) => `'${s.replaceAll("'", `'\\''`)}'`;

// Pi's TUI in the project dir. With RECORD, a wrapper writes the desk's record,
// naming its own pid, then execs Pi, as bercail's desk wrapper does.
async function tuiStart(
  env: NodeJS.ProcessEnv,
  args: string[],
  { record, address, harness = "pi" }: { record?: string; address?: string; harness?: string } = {},
): Promise<Term> {
  const n = TUIS.length;
  const log = join(WORK, `terminal-${address ?? "bare"}-${n}.log`);
  let argv = [PI, ...args];
  if (record !== undefined) {
    const wrap = join(WORK, `wrap-${address}-${n}.sh`);
    writeFileSync(
      wrap,
      "#!/bin/bash\n" +
        "set -euo pipefail\n" +
        `p=${quote(record)}\n` +
        'mkdir -p "$(dirname "$p")"\n' +
        `jq -cn --arg addr ${quote(address!)} --arg harness ${quote(harness)} --argjson pid $$ ` +
        `'{address: $addr, session: "", cwd: "/stale", harness: $harness, issue: "bercail-1", space: "sp1", ` +
        `args: ["--verbose"], pid: $pid}' >"$p"\n` +
        'chmod 640 "$p"\n' +
        `exec ${quote(PI)} "$@"\n`,
      { mode: 0o755 },
    );
    argv = [wrap, ...args];
  }
  const tui = await Term.start(argv, { env, cwd: join(WORK, "project"), log });
  TUIS.push(tui);
  return tui;
}

// Like Popen.wait(timeout): true once the program has exited.
async function exitWithin(tui: Term, timeout: number): Promise<boolean> {
  const deadline = Date.now() + timeout * 1000;
  while (!tui.exited() && Date.now() < deadline) await sleep(100);
  return tui.exited();
}

const readJson = (path: string): Record => JSON.parse(readFileSync(path, "utf8"));

function piArgs(sessionDir: string, extra: string[] = []): string[] {
  return [
    "--offline",
    "-ne",
    "-e",
    PROVIDER,
    "-e",
    EXT,
    "--model",
    "fake/model",
    "--thinking",
    "off",
    "--session-dir",
    sessionDir,
    "--no-skills",
    "--no-prompt-templates",
    "--no-context-files",
    "--no-mcp",
    "--no-tools",
    ...extra,
  ];
}

function sessionFile(sessionDir: string, sessionId: string): string | null {
  const matches = readdirSync(sessionDir, { recursive: true, encoding: "utf8" }).filter((p) =>
    p.endsWith(`_${sessionId}.jsonl`),
  );
  return matches.length === 1 ? join(sessionDir, matches[0]!) : null;
}

function dump(tui?: Term): void {
  if (!tui) return;
  let text: string;
  try {
    text = readFileSync(tui.log, "utf8");
  } catch {
    return;
  }
  console.error("--- terminal ---");
  console.error(text.slice(-2000));
}

const mode = (path: string) => statSync(path).mode & 0o777;

async function main(): Promise<void> {
  const run = WORK;
  if (existsSync(run)) {
    console.error(`temp exists: ${run}`);
    process.exit(1);
  }
  const home = join(run, "home");
  const state = join(run, "state");
  const runtime = join(run, "run");
  const project = join(run, "project");
  const sessions = join(run, "sessions");
  for (const path of [
    home,
    state,
    runtime,
    project,
    sessions,
    join(run, "data"),
    join(run, "cache"),
    join(home, ".config"),
  ])
    mkdirSync(path, { recursive: true });
  chmodSync(runtime, 0o700);
  writeFileSync(join(project, "README"), "desk pi proof\n");
  const base: NodeJS.ProcessEnv = {
    HOME: home,
    XDG_CONFIG_HOME: join(home, ".config"),
    XDG_DATA_HOME: join(run, "data"),
    XDG_STATE_HOME: state,
    XDG_CACHE_HOME: join(run, "cache"),
    XDG_RUNTIME_DIR: runtime,
  };
  const records = join(state, "bercail/desk-sessions");
  const record = join(records, "t9.json");
  const env = childEnv(base, { HC_TERMINAL_ID: "t9" });

  let tui = await tuiStart(env, piArgs(sessions), { record, address: "t9", harness: "pi" });
  let claim = join(runtime, "bercail/open-sessions", `${tui.pid}.json`);

  const recorded = () => {
    const data = readJson(record);
    return typeof data.session === "string" && data.session !== "";
  };
  if (!(await waitFor("session id recorded at startup", recorded, { timeout: 30, term: tui }))) return dump(tui);
  let data = readJson(record);
  const session = data.session as string;
  await sleep(600);
  await tui.send(TOKEN + "\r");

  const filed = () => {
    const path = sessionFile(sessions, session);
    return path !== null && readFileSync(path, "utf8").includes(TOKEN);
  };
  if (!(await waitFor("session file named with the recorded id", filed, { timeout: 30, term: tui }))) return dump(tui);
  data = readJson(record);
  if (data.cwd !== project) fail(`cwd was not the dir Pi ran in: ${String(data.cwd)}`);
  if (
    data.issue !== "bercail-1" ||
    !isDeepStrictEqual(data.args, ["--verbose"]) ||
    data.space !== "sp1" ||
    data.address !== "t9" ||
    data.harness !== "pi" ||
    data.pid !== tui.pid
  )
    fail(`record metadata changed: ${JSON.stringify(data)}`);
  if (mode(record) !== 0o640) fail(`record mode changed: 0o${mode(record).toString(8)}`);
  let claimed = readJson(claim);
  if (claimed.pid !== tui.pid || claimed.start_ticks !== startTicks(tui.pid))
    fail(`claim ticks do not match this process: ${JSON.stringify(claimed)}`);
  if (!isDeepStrictEqual(claimed.sessions, [session])) fail(`claim is not the one session: ${JSON.stringify(claimed)}`);
  if (mode(claim) !== 0o600) fail(`claim mode is not 0600: 0o${mode(claim).toString(8)}`);
  const saved = sessionFile(sessions, session)!;
  if (fails.length) return dump(tui);
  pass("startup recorded the session id, its directory, and the open-session claim");

  await tui.send("/quit\r");
  if (!(await exitWithin(tui, 15))) {
    fail(" /quit did not exit");
    return dump(tui);
  }
  if (readJson(record).session !== session) {
    fail(`exit cleared the session: ${JSON.stringify(readJson(record))}`);
    return;
  }
  pass("quitting leaves the session to be resumed");

  tui = await tuiStart(env, piArgs(sessions, ["--session-id", session]), { record, address: "t9", harness: "pi" });
  claim = join(runtime, "bercail/open-sessions", `${tui.pid}.json`);

  const resumed = () => {
    const data = readJson(record);
    // The previous process left the same id behind. This run's wrapper
    // rewrites pid first, so the new pid is what proves this process wrote.
    return (
      data.pid === tui.pid &&
      data.session === session &&
      data.cwd === project &&
      readFileSync(saved, "utf8").includes(TOKEN)
    );
  };
  if (!(await waitFor("resumed session id recorded", resumed, { timeout: 30, term: tui }))) return dump(tui);
  const resumedClaim = existsSync(claim) ? readJson(claim) : null;
  if (!resumedClaim || !isDeepStrictEqual(resumedClaim.sessions, [session]) || resumedClaim.pid !== tui.pid)
    fail(`resumed claim is not the same session: ${JSON.stringify(resumedClaim)}`);
  else pass("--session-id records the same id and keeps the earlier message");

  await sleep(600);
  await tui.send("/new\r");
  const renewed = () => {
    const current = readJson(record).session;
    return typeof current === "string" && current !== "" && current !== session;
  };
  if (!(await waitFor("/new moves the recorded session", renewed, { timeout: 15, term: tui }))) {
    await tui.send("\r");
    if (!(await waitFor("/new moves the recorded session", renewed, { timeout: 15, term: tui }))) return dump(tui);
  }
  const newId = readJson(record).session as string;
  claimed = readJson(claim);
  if (!isDeepStrictEqual(claimed.sessions, [newId])) fail(`/new did not move the claim: ${JSON.stringify(claimed)}`);
  else pass(`/new moved the recorded session to ${newId}`);
  await tui.send("/quit\r");
  if (!(await exitWithin(tui, 15))) tui.signal("SIGTERM");

  const foreign = join(records, "t-other.json");
  const expected = recordText("t-other", 0, "other");
  writeFileSync(foreign, expected);
  const other = await tuiStart(childEnv(base, { HC_TERMINAL_ID: "t-other" }), piArgs(sessions), { address: "t-other" });
  const otherClaim = join(runtime, "bercail/open-sessions", `${other.pid}.json`);
  const claimedOnly = () => existsSync(otherClaim) && readJson(otherClaim).pid === other.pid;
  if (await waitFor("foreign desk still publishes a claim", claimedOnly, { timeout: 30, term: other })) {
    const text = readFileSync(foreign, "utf8");
    if (text !== expected)
      fail(`a foreign record was overwritten: ${JSON.stringify(text)} != ${JSON.stringify(expected)}`);
    else pass("a stale record is left byte-for-byte alone");
  } else dump(other);
  other.signal("SIGTERM");
}

try {
  await main();
} catch (err) {
  fail(`${(err as Error).name}: ${(err as Error).message}`);
} finally {
  await killAll();
}
if (fails.length) {
  console.error(`left ${WORK}`);
  process.exit(1);
}
rmSync(WORK, { recursive: true, force: true });
process.exit(0);
