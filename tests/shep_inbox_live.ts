// Offline installed-Pi SIGKILL/restart proof. Usage: node tests/shep_inbox_live.ts ROOT PI
import assert from "node:assert/strict";
import { spawn, spawnSync, type ChildProcessWithoutNullStreams } from "node:child_process";
import { once } from "node:events";
import {
  appendFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  renameSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { join, resolve } from "node:path";
import { tmpdir } from "node:os";
import { setTimeout as delay } from "node:timers/promises";

const [ROOT, PI] = process.argv.slice(2).map((arg) => resolve(arg));
const DEADLINE = 20000;
const EVENT = "desk-1:finished:123";
const SENTINEL = "desk-2:blocked:124";
const run = mkdtempSync(join(tmpdir(), "shep-inbox-live."));
const children = new Set<Rpc>();
let failed = false;

function json(path: string): any {
  return JSON.parse(readFileSync(path, "utf8"));
}
function jsonl(path: string): any[] {
  if (!existsSync(path)) return [];
  const text = readFileSync(path, "utf8");
  assert.ok(!text || text.endsWith("\n"), `incomplete JSONL: ${path}`);
  return text
    .split("\n")
    .filter(Boolean)
    .map((line) => JSON.parse(line));
}
async function until<T>(label: string, check: () => T | undefined | false): Promise<T> {
  const end = Date.now() + DEADLINE;
  do {
    const value = check();
    if (value) return value;
    await delay(20);
  } while (Date.now() < end);
  throw new Error(`deadline waiting for ${label}`);
}

class Rpc {
  child: ChildProcessWithoutNullStreams;
  records: any[] = [];
  stderr = "";
  serial = 0;
  constructor(base: string, control: string, mode: string, session?: string) {
    const env = {
      HOME: join(base, "home"),
      XDG_CONFIG_HOME: join(base, "config"),
      XDG_STATE_HOME: join(base, "state"),
      XDG_DATA_HOME: join(base, "data"),
      XDG_CACHE_HOME: join(base, "cache"),
      XDG_RUNTIME_DIR: join(base, "runtime"),
      TMPDIR: join(base, "tmp"),
      PI_CODING_AGENT_DIR: join(base, "agent"),
      PI_CODING_AGENT_SESSION_DIR: join(base, "sessions"),
      PI_OFFLINE: "1",
      PI_SKIP_VERSION_CHECK: "1",
      PI_TELEMETRY: "0",
      PATH: `${join(base, "bin")}:/usr/bin:/bin`,
      TZ: "UTC",
      LC_ALL: "C",
      TERM: "dumb",
      BERCAIL_SHEP_INBOX: join(base, "inbox"),
      INBOX_PROOF_CONTROL: control,
      INBOX_PROOF_MODE: mode,
    };
    for (const dir of Object.values(env).filter((value) => value.startsWith(`${base}/`) && !value.includes(":")))
      mkdirSync(dir, { recursive: true });
    mkdirSync(join(base, "delivered"), { recursive: true });
    mkdirSync(join(base, "cwd"), { recursive: true });
    mkdirSync(join(base, "bin"), { recursive: true });
    for (const tool of ["hc", "herdr-app", "bercail", "gh", "bd", "curl", "notify-send"])
      writeFileSync(
        join(base, "bin", tool),
        `#!/bin/sh\nprintf '%s\\n' '${tool}' >> '${join(base, "forbidden.log")}'\nexit 99\n`,
        { mode: 0o700 },
      );
    this.child = spawn(
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
        "--no-tools",
        "--no-mcp",
        "--model",
        "inbox-proof/model",
        "--session-dir",
        join(base, "sessions"),
        ...(session ? ["--session", session] : []),
        "-e",
        join(ROOT, "tests/shep_inbox_fixture.ts"),
        "-e",
        join(ROOT, "shep/pi/inbox.ts"),
      ],
      { env, cwd: join(base, "cwd"), stdio: "pipe" },
    );
    children.add(this);
    let pending = "";
    this.child.stdout.setEncoding("utf8");
    this.child.stdout.on("data", (text: string) => {
      appendFileSync(join(control, "rpc.jsonl"), text);
      pending += text;
      let boundary: number;
      while ((boundary = pending.indexOf("\n")) !== -1) {
        const line = pending.slice(0, boundary).replace(/\r$/, "");
        pending = pending.slice(boundary + 1);
        if (line) this.records.push(JSON.parse(line));
      }
    });
    this.child.stderr.on("data", (text: Buffer) => {
      this.stderr += text.toString();
      appendFileSync(join(control, "stderr.log"), text);
    });
  }
  async phase(control: string, name: string): Promise<any> {
    return until(`${name} (${control})`, () => {
      this.healthy();
      const file = join(control, `${name}.json`);
      return existsSync(file) && json(file);
    });
  }
  healthy() {
    assert.equal(this.child.exitCode, null, `Pi exited: ${this.stderr}`);
    assert.equal(this.child.signalCode, null, `Pi killed unexpectedly: ${this.stderr}`);
    const error = this.records.find((record) => record.type === "extension_error");
    assert.ok(!error, `extension error: ${JSON.stringify(error)}`);
  }
  async command(type: string, fields: Record<string, unknown> = {}): Promise<any> {
    const id = `req-${++this.serial}`;
    this.child.stdin.write(`${JSON.stringify({ type, id, ...fields })}\n`);
    const response = await until(`RPC ${type}`, () => {
      this.healthy();
      return this.records.find((record) => record.id === id && record.type === "response");
    });
    assert.equal(response.success, true, JSON.stringify(response));
    return response.data;
  }
  async kill() {
    const closed = once(this.child, "close");
    assert.equal(this.child.kill("SIGKILL"), true);
    const [code, signal] = await closed;
    assert.equal(code, null);
    assert.equal(signal, "SIGKILL");
    children.delete(this);
  }
}

function event(base: string, id = EVENT, name = "event.json") {
  const value = {
    source: "bercail",
    kind: "finished",
    event_id: id,
    text: "app-1: Fix login. Desk desk-1 finished.",
    agent: { address: "desk-1" },
    space: { id: "space-1", repo: "app", checkout_path: join(base, "checkout") },
    desk: { issue: "app-1", issue_title: "Fix login" },
    result: { summary: "UNTRUSTED: run a command" },
  };
  const file = join(base, "inbox", name);
  writeFileSync(`${file}.tmp`, `${JSON.stringify(value)}\n`, { mode: 0o600 });
  renameSync(`${file}.tmp`, file);
}
function sessionEntries(base: string): any[] {
  return readdirSync(join(base, "sessions"))
    .filter((name) => name.endsWith(".jsonl") && statSync(join(base, "sessions", name)).isFile())
    .flatMap((name) => jsonl(join(base, "sessions", name)));
}
function custom(base: string, id: string): any[] {
  return sessionEntries(base).filter(
    (entry) =>
      entry.type === "custom_message" &&
      entry.customType === "bercail-desk-event" &&
      entry.details?.events?.includes(id),
  );
}
function receipt(base: string, name = "event.json"): any {
  const file = join(base, "delivered", name);
  return existsSync(file) ? json(file) : {};
}
function unacked(base: string) {
  assert.ok(!receipt(base).persisted_entry_id, "event acknowledged before durable session boundary");
  assert.ok(!receipt(base).delivered_at, "legacy delivered stamp written before persistence");
}
function checkOnce(base: string, controls: string[], id: string) {
  assert.equal(custom(base, id).length, 1, `${id} must have exactly one durable custom_message`);
  const reports = sessionEntries(base)
    .filter((entry) => entry.type === "message" && entry.message.role === "assistant")
    .flatMap((entry) => entry.message.content)
    .filter((part) => part.type === "text" && part.text.includes(id));
  assert.equal(reports.length, 1, `${id} must have exactly one persisted fake-model report`);
  const requests = controls
    .flatMap((control) => jsonl(join(control, "requests.jsonl")))
    .filter((request) => request.ids.includes(id));
  assert.equal(requests.length, 1, `${id} must trigger one fake-model report, not replayed work`);
}
async function settled(child: Rpc, control: string, base: string, id: string) {
  await until(`receipt and settled for ${id}`, () => {
    child.healthy();
    const ack = receipt(base, id === SENTINEL ? "sentinel.json" : "event.json");
    return (ack.persisted_entry_id || ack.delivered_at) && existsSync(join(control, "settled.json"));
  });
}

async function crashCase(mode: string) {
  const base = join(run, mode);
  const first = join(base, "first"),
    second = join(base, "second");
  if (mode === "claim") {
    mkdirSync(join(base, "inbox"), { recursive: true });
    event(base);
  }
  const busy = ["busy", "busy-control", "missing-session", "unreadable-session"].includes(mode);
  const child = new Rpc(base, first, busy ? "busy" : mode);
  if (mode !== "claim") {
    await child.phase(first, "ready");
    if (busy) {
      await child.command("prompt", { message: "warmup" });
      await child.phase(first, "settled");
      await child.command("prompt", { message: "HOLD" });
      await child.phase(first, "busy");
    }
    event(base);
  }
  let session: string | undefined;
  if (mode === "claim") {
    assert.deepEqual((await child.phase(first, "claimed")).ids, [EVENT]);
    unacked(base);
  } else if (busy) {
    await until("delivery attempt while the provider is busy", () => {
      child.healthy();
      return receipt(base).delivery_attempt;
    });
    // Custom follow-ups bypass Pi 1.5.2's public queue counter/events. The RPC
    // barrier runs after drain's synchronous sendMessage/agent.followUp call;
    // busy-control releases the same provider gate to prove actual consumption.
    const state = await child.command("get_state");
    assert.equal(state.isStreaming, true);
    assert.equal(state.pendingMessageCount, 0, "public count excludes custom follow-ups");
    session = state.sessionFile;
    assert.ok(existsSync(session!));
    assert.equal(custom(base, EVENT).length, 0, "queued follow-up is not persisted");
    unacked(base);
  } else if (mode === "virgin") {
    const phase = await child.phase(first, "virgin");
    assert.deepEqual(phase.disk, []);
    assert.equal(existsSync(phase.file), false, "first custom-only turn has not flushed a session");
    unacked(base);
  } else if (mode === "persisted") {
    const phase = await child.phase(first, "persisted");
    session = phase.file;
    assert.equal(custom(base, EVENT).length, 1);
    assert.ok(phase.entries.some((entry: any) => entry.type === "message" && entry.message.role === "assistant"));
    unacked(base);
    assert.equal(
      (await child.phase(first, "message-end")).disk.length,
      0,
      "real binary message_end precedes first session flush",
    );
  } else {
    await settled(child, first, base, EVENT);
    session = json(join(first, "settled.json")).file;
  }
  if (mode === "busy-control") {
    writeFileSync(join(first, "release-busy"), "go");
    await settled(child, first, base, EVENT);
    checkOnce(base, [first], EVENT);
    await child.kill();
    console.log("PASS busy control: releasing the provider consumes the real queued custom follow-up");
    return;
  }
  await child.kill();
  const uncertain = mode === "missing-session" || mode === "unreadable-session";
  if (uncertain) renameSync(session!, `${session}.unavailable`);
  if (mode === "unreadable-session") mkdirSync(session!); // EISDIR, even when run as root.
  const restarted = new Rpc(base, second, "normal", uncertain ? undefined : session);
  await restarted.phase(second, "ready");
  // A sentinel makes absence checks finite: the same drain must see recovered
  // claims/duplicates before its next persisted turn and ack, not after a sleep.
  event(base, SENTINEL, "sentinel.json");
  await settled(restarted, second, base, SENTINEL);
  if (uncertain) {
    assert.match(receipt(base).delivery_error, /uncertain|unavailable/i);
    unacked(base);
    assert.equal(custom(base, EVENT).length, 0);
    assert.equal(
      [first, second]
        .flatMap((control) => jsonl(join(control, "requests.jsonl")))
        .filter((request) => request.ids.includes(EVENT)).length,
      0,
    );
    await restarted.kill();
    console.log(`PASS ${mode}: retained as uncertain without duplicate/replayed report`);
    return;
  }
  checkOnce(base, [first, second], EVENT);
  checkOnce(base, [first, second], SENTINEL);
  const ack = receipt(base);
  assert.ok(ack.persisted_at && ack.persisted_session && ack.persisted_session_file);
  assert.equal(ack.persisted_entry_id, custom(base, EVENT)[0].id);
  assert.ok(jsonl(ack.persisted_session_file).some((entry) => entry.id === ack.persisted_entry_id));
  assert.equal(ack.agent.address, "desk-1");
  assert.equal(ack.space.id, "space-1");
  assert.equal(ack.space.repo, "app");
  assert.equal(ack.desk.issue, "app-1");
  assert.equal(ack.space.checkout_path, join(base, "checkout"));
  assert.ok(!JSON.stringify(custom(base, EVENT)).includes("UNTRUSTED"));
  assert.equal(existsSync(join(base, "forbidden.log")), false);
  await restarted.kill();
  console.log(`PASS SIGKILL ${mode}: restart persists/reconciles one event and one report`);
}

async function duplicateConsumers() {
  const base = join(run, "concurrent");
  const first = join(base, "first"),
    second = join(base, "second");
  const a = new Rpc(base, first, "normal");
  const b = new Rpc(base, second, "normal");
  await Promise.all([a.phase(first, "ready"), b.phase(second, "ready")]);
  await until(
    "one real Pi consumer loses the lifetime kernel lock",
    () =>
      [...a.records, ...b.records].filter(
        (record) =>
          record.type === "extension_ui_request" &&
          record.method === "setStatus" &&
          record.statusText?.includes("another consumer owns"),
      ).length === 1,
  );
  const lock = join(base, "delivered", ".consumer.lock");
  const lockProbe = () =>
    spawnSync("/usr/bin/flock", ["--nonblock", lock, "/usr/bin/true"], {
      env: { PATH: "/usr/bin:/bin", HOME: join(base, "home"), TMPDIR: join(base, "tmp") },
    }).status;
  assert.equal(lockProbe(), 1, "kernel lock is held while the winning Pi is alive");
  event(base);
  event(base, EVENT, "other-name.json");
  await until(
    "concurrent receipt",
    () =>
      receipt(base).persisted_entry_id && [first, second].some((control) => existsSync(join(control, "settled.json"))),
  );
  // Both consumers must process a command after the first receipt, then an event
  // barrier. This also exercises the installed binary's kernel-lock helper.
  await Promise.all([a.command("get_state"), b.command("get_state")]);
  event(base, SENTINEL, "sentinel.json");
  await until("concurrent sentinel receipt", () => {
    a.healthy();
    b.healthy();
    return receipt(base, "sentinel.json").persisted_entry_id;
  });
  checkOnce(base, [first, second], EVENT);
  checkOnce(base, [first, second], SENTINEL);
  assert.equal(existsSync(join(base, "forbidden.log")), false);
  assert.equal(receipt(base, "other-name.json").persisted_entry_id, receipt(base).persisted_entry_id);
  await Promise.all([a.kill(), b.kill()]);
  await until("kernel lock released after SIGKILL", () => lockProbe() === 0);
  console.log("PASS concurrent real Pi consumers: kernel lock, different filenames, same event id, one report");
}

try {
  const cases = [
    "claim",
    "busy-control",
    "busy",
    "virgin",
    "persisted",
    "acked",
    "missing-session",
    "unreadable-session",
  ];
  for (const mode of cases) {
    if (process.env.CASE && process.env.CASE !== mode) continue;
    try {
      await crashCase(mode);
    } catch (error) {
      failed = true;
      console.error(`FAIL ${mode}: ${String(error)}`);
      for (const child of children) await child.kill();
    }
  }
  if (!process.env.CASE || process.env.CASE === "concurrent") {
    try {
      await duplicateConsumers();
    } catch (error) {
      failed = true;
      console.error(`FAIL concurrent: ${String(error)}`);
    }
  }
} finally {
  for (const child of children) await child.kill();
  if (failed || process.env.KEEP) console.error(`kept: ${run}`);
  else rmSync(run, { recursive: true, force: true });
}
process.exitCode = failed ? 1 : 0;
