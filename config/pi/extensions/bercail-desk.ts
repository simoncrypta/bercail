// The desk's Pi session, written when the session starts. The wrapper owns the
// record and its heartbeat; this only fills session and cwd, and only on the
// record that names this process. An ephemeral session cannot be resumed, so
// it stores an empty session and claims nothing. Every Pi that loads this,
// desk or not, also claims the session it has open.
//
// It also takes `bercail desk model` requests: a file, not a message, so no
// chat text from another agent can switch the desk's model.
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { chmodSync, mkdirSync, readFileSync, renameSync, statSync, unlinkSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";

type Env = Record<string, string | undefined>;
// What applyDesk may write: the terminal and process the record must name.
type Gate = { address?: string; pid: number; session: unknown; cwd?: unknown };
type Fields = { session: string; cwd?: string };
type Claim = { pid: number; start_ticks: string; sessions: string[] };
type ModelRequest = { id: string; pid: number; model?: unknown };
type ModelResult =
  | { status: "switched"; from: string; model: string }
  | { status: "refused"; from: string; reason: string };

// /proc/self/stat field 22. comm (field 2) is wrapped in parentheses and may
// contain spaces, so the count starts after the last ")".
export function startTicks(stat: unknown): string | null {
  if (typeof stat !== "string") return null;
  const end = stat.lastIndexOf(")");
  if (end < 0) return null;
  const ticks = stat
    .slice(end + 2)
    .trim()
    .split(/\s+/)[19];
  return typeof ticks === "string" && /^\d+$/.test(ticks) ? ticks : null;
}

export function deskRecordPath(env: Env | undefined): string | null {
  const id = env && env.HC_TERMINAL_ID;
  if (!id || /[/\\\0]/.test(id)) return null;
  const root = env.XDG_STATE_HOME || (env.HOME ? join(env.HOME, ".local/state") : "");
  if (!root) return null;
  return join(root, "bercail/desk-sessions", `${id}.json`);
}

// desk-commands/<address>.json: the request `bercail desk model` writes.
// <address>.done.json: what became of it.
export function modelRequestPath(env: Env): string | null {
  const record = deskRecordPath(env);
  return record && join(dirname(dirname(record)), "desk-commands", `${env.HC_TERMINAL_ID}.json`);
}

export function claimPath(env: Env | undefined, pid: unknown, platform = "linux"): string | null {
  if (platform !== "linux" || !env || !env.XDG_RUNTIME_DIR) return null;
  if (typeof pid !== "number" || !Number.isInteger(pid) || pid <= 0) return null;
  return join(env.XDG_RUNTIME_DIR, "bercail/open-sessions", `${pid}.json`);
}

// null: leave the file alone (missing, foreign, stale, or already current).
export function deskNext(value: unknown, { address, pid, session, cwd }: Gate): Record<string, any> | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const record = value as Record<string, any>;
  if (!address || record.address !== address) return null;
  if (record.pid !== pid) return null;
  if (typeof session !== "string") return null;
  const next: Record<string, any> = { ...record, session };
  if (typeof cwd === "string" && cwd) next.cwd = cwd;
  if (next.session === record.session && next.cwd === record.cwd) return null;
  return next;
}

// undefined file: ephemeral, cannot be resumed. A path is stored even before
// Pi has written it.
export function deskFields(sessionFile: string | undefined, sessionId: unknown, cwd: unknown): Fields | null {
  if (sessionFile === undefined) {
    const fields: Fields = { session: "" };
    if (typeof cwd === "string" && cwd) fields.cwd = cwd;
    return fields;
  }
  if (typeof sessionId !== "string" || !sessionId) return null;
  const fields: Fields = { session: sessionId };
  if (typeof cwd === "string" && cwd) fields.cwd = cwd;
  return fields;
}

// One session at a time. Ephemeral claims nothing.
export function sessionIDs(sessionFile: string | undefined, sessionId: unknown): string[] {
  if (sessionFile === undefined || typeof sessionId !== "string" || !sessionId) return [];
  return [sessionId];
}

function readJSON(path: string): Record<string, any> | null {
  try {
    const value = JSON.parse(readFileSync(path, "utf8"));
    if (!value || typeof value !== "object" || Array.isArray(value)) return null;
    return value;
  } catch {
    return null;
  }
}

export function writeAtomic(path: string, text: string, mode?: number): void {
  mkdirSync(dirname(path), { recursive: true });
  const tmp = `${path}.tmp-${process.pid}-${Math.random().toString(16).slice(2)}`;
  let keep = mode;
  try {
    keep = statSync(path).mode;
  } catch {}
  writeFileSync(tmp, text, { mode: 0o600, flag: "wx" });
  try {
    chmodSync(tmp, keep ?? 0o600);
    renameSync(tmp, path);
  } catch (err) {
    try {
      unlinkSync(tmp);
    } catch {}
    throw err;
  }
}

export function applyDesk(path: string, gate: Gate): boolean {
  try {
    const record = readJSON(path);
    if (!record) return false;
    const next = deskNext(record, gate);
    if (!next) return false;
    writeAtomic(path, `${JSON.stringify(next)}\n`);
    return true;
  } catch {
    return false;
  }
}

export function applyClaim(path: string, doc: Claim): boolean {
  try {
    const prev = readJSON(path);
    if (
      prev &&
      prev.pid === doc.pid &&
      prev.start_ticks === doc.start_ticks &&
      JSON.stringify(prev.sessions) === JSON.stringify(doc.sessions)
    ) {
      return false;
    }
    writeAtomic(
      path,
      `${JSON.stringify({ pid: doc.pid, start_ticks: doc.start_ticks, sessions: doc.sessions })}\n`,
      0o600,
    );
    return true;
  } catch {
    return false;
  }
}

function publish(ctx: ExtensionContext): void {
  try {
    const file = ctx.sessionManager.getSessionFile();
    const id = file === undefined ? "" : ctx.sessionManager.getSessionId();
    const fields = deskFields(file, id, ctx.cwd);
    const claim = claimPath(process.env, process.pid, process.platform);
    if (claim && (file === undefined || fields)) {
      let ticks: string | null = null;
      try {
        ticks = startTicks(readFileSync("/proc/self/stat", "utf8"));
      } catch {}
      if (ticks) applyClaim(claim, { pid: process.pid, start_ticks: ticks, sessions: sessionIDs(file, id) });
    }
    const record = deskRecordPath(process.env);
    if (record && fields) {
      applyDesk(record, {
        address: process.env.HC_TERMINAL_ID,
        pid: process.pid,
        session: fields.session,
        cwd: fields.cwd,
      });
    }
  } catch {}
}

// provider/id[:thinking] as pi --list-models names it, or null.
export function parseModel(text: unknown): { provider: string; id: string; thinking: string } | null {
  if (typeof text !== "string") return null;
  const m = /^([^/\s]+)\/(\S+?)(?::(off|minimal|low|medium|high|xhigh|max))?$/.exec(text);
  return m ? { provider: m[1]!, id: m[2]!, thinking: m[3] || "" } : null;
}

// The record's args with --model set to MODEL, so a restore comes back on it.
export function withModel(args: unknown, model: string): unknown[] {
  const out: unknown[] = Array.isArray(args) ? [...args] : [];
  for (let i = 0; i < out.length; i++) {
    if (out[i] === "--model" && i + 1 < out.length) {
      out[i + 1] = model;
      return out;
    }
    const arg = out[i];
    if (typeof arg === "string" && arg.startsWith("--model=")) {
      out[i] = `--model=${model}`;
      return out;
    }
  }
  return ["--model", model, ...out];
}

// The request, when it is for this process. Renamed before it is read, so a
// newer one written meanwhile is not lost. Another pid's request is stale.
export function takeRequest(path: string, pid: number): ModelRequest | null {
  const taken = `${path}.taken-${pid}`;
  try {
    renameSync(path, taken);
  } catch {
    return null;
  }
  try {
    const request = readJSON(taken);
    if (!request || request.pid !== pid || typeof request.id !== "string") return null;
    return request as ModelRequest;
  } finally {
    try {
      unlinkSync(taken);
    } catch {}
  }
}

function current(pi: ExtensionAPI, ctx: ExtensionContext): string {
  const model = ctx.model;
  return model ? `${model.provider}/${model.id}:${pi.getThinkingLevel()}` : "";
}

// Switches to the request's model, or says why not. Without a thinking level
// the desk keeps its own: setModel resets it, so it is set again (Pi clamps it
// to what the model supports).
export async function switchModel(
  pi: ExtensionAPI,
  ctx: ExtensionContext,
  request: ModelRequest,
): Promise<ModelResult> {
  const from = current(pi, ctx);
  const level = pi.getThinkingLevel();
  const want = parseModel(request.model);
  if (!want) return { status: "refused", from, reason: `not provider/model[:thinking]: ${String(request.model)}` };
  const model = ctx.modelRegistry.find(want.provider, want.id);
  if (!model) return { status: "refused", from, reason: `Pi has no model ${want.provider}/${want.id}` };
  if (!(await pi.setModel(model)))
    return { status: "refused", from, reason: `no login for ${want.provider}/${want.id}` };
  pi.setThinkingLevel((want.thinking || level) as typeof level);
  return { status: "switched", from, model: `${model.provider}/${model.id}:${pi.getThinkingLevel()}` };
}

// Logged in the session, the record, and the bercail.model label, so restore
// and `bercail shep brief` show the model the desk runs on now.
async function takeModelRequest(pi: ExtensionAPI, ctx: ExtensionContext): Promise<void> {
  const env = process.env;
  const path = modelRequestPath(env);
  if (!path) return;
  const request = takeRequest(path, process.pid);
  if (!request) return;
  const result = { id: request.id, ...(await switchModel(pi, ctx, request)) };
  if (result.status === "switched") {
    pi.appendEntry("bercail-desk-model", { from: result.from, to: result.model, by: "bercail desk model" });
    const record = deskRecordPath(env);
    const prev = record && readJSON(record);
    if (prev && prev.address === env.HC_TERMINAL_ID && prev.pid === process.pid) {
      try {
        writeAtomic(record, `${JSON.stringify({ ...prev, args: withModel(prev.args, result.model) })}\n`);
      } catch {}
    }
    try {
      await pi.exec("hc", ["label", env.HC_TERMINAL_ID!, `bercail.model=${result.model}`], { timeout: 5000 });
    } catch {}
    if (ctx.hasUI) ctx.ui.notify(`bercail desk model: ${result.from} → ${result.model}`, "info");
  } else if (ctx.hasUI) {
    ctx.ui.notify(`bercail desk model refused: ${result.reason}`, "warning");
  }
  try {
    writeAtomic(path.replace(/\.json$/, ".done.json"), `${JSON.stringify(result)}\n`, 0o600);
  } catch {}
}

// Only between runs: a run in flight finishes on the model it started with.
export function modelWatch(pi: ExtensionAPI, ctx: ExtensionContext): () => Promise<void> {
  let busy = false;
  return async () => {
    if (busy || !ctx.isIdle()) return;
    busy = true;
    try {
      await takeModelRequest(pi, ctx);
    } catch {
    } finally {
      busy = false;
    }
  };
}

// /new and /resume replace the runtime and fire session_start again. Shutdown
// must not clear the session: a reboot still needs it.
export default function (pi: ExtensionAPI) {
  let timer: ReturnType<typeof setInterval> | undefined;
  pi.on("session_start", (_event, ctx) => {
    publish(ctx);
    if (timer || !modelRequestPath(process.env)) return;
    timer = setInterval(modelWatch(pi, ctx), 1000);
    timer.unref?.();
  });
  pi.on("session_info_changed", (_event, ctx) => {
    publish(ctx);
  });
  pi.on("session_shutdown", () => {
    clearInterval(timer);
    timer = undefined;
  });
}
