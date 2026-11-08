// The desk's Pi session, written when the session starts. The wrapper owns the
// record and its heartbeat; this only fills session and cwd, and only on the
// record that names this process. An ephemeral session cannot be resumed, so
// it stores an empty session and claims nothing. Every Pi that loads this,
// desk or not, also claims the session it has open.
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent"
import { chmodSync, mkdirSync, readFileSync, renameSync, statSync, unlinkSync, writeFileSync } from "node:fs"
import { dirname, join } from "node:path"

// /proc/self/stat field 22. comm (field 2) is wrapped in parentheses and may
// contain spaces, so the count starts after the last ")".
export function startTicks(stat) {
  if (typeof stat !== "string") return null
  const end = stat.lastIndexOf(")")
  if (end < 0) return null
  const ticks = stat.slice(end + 2).trim().split(/\s+/)[19]
  return typeof ticks === "string" && /^\d+$/.test(ticks) ? ticks : null
}

export function deskRecordPath(env) {
  const id = env && env.HC_TERMINAL_ID
  if (!id || /[/\\\0]/.test(id)) return null
  const root = env.XDG_STATE_HOME || (env.HOME ? join(env.HOME, ".local/state") : "")
  if (!root) return null
  return join(root, "bercail/desk-sessions", `${id}.json`)
}

export function claimPath(env, pid, platform = "linux") {
  if (platform !== "linux" || !env || !env.XDG_RUNTIME_DIR) return null
  if (!Number.isInteger(pid) || pid <= 0) return null
  return join(env.XDG_RUNTIME_DIR, "bercail/open-sessions", `${pid}.json`)
}

// null: leave the file alone (missing, foreign, stale, or already current).
export function deskNext(record, { address, pid, session, cwd }) {
  if (!record || typeof record !== "object" || Array.isArray(record)) return null
  if (!address || record.address !== address) return null
  if (record.harness !== "pi") return null
  if (record.pid !== pid) return null
  if (typeof session !== "string") return null
  const next = { ...record, session }
  if (typeof cwd === "string" && cwd) next.cwd = cwd
  if (next.session === record.session && next.cwd === record.cwd) return null
  return next
}

// undefined file: ephemeral, cannot be resumed. A path is stored even before
// Pi has written it.
export function deskFields(sessionFile, sessionId, cwd) {
  if (sessionFile === undefined) {
    const fields = { session: "" }
    if (typeof cwd === "string" && cwd) fields.cwd = cwd
    return fields
  }
  if (typeof sessionId !== "string" || !sessionId) return null
  const fields = { session: sessionId }
  if (typeof cwd === "string" && cwd) fields.cwd = cwd
  return fields
}

// One session at a time. Ephemeral claims nothing.
export function sessionIDs(sessionFile, sessionId) {
  if (sessionFile === undefined || typeof sessionId !== "string" || !sessionId) return []
  return [sessionId]
}

function readJSON(path) {
  try {
    const value = JSON.parse(readFileSync(path, "utf8"))
    if (!value || typeof value !== "object" || Array.isArray(value)) return null
    return value
  } catch {
    return null
  }
}

export function writeAtomic(path, text, mode) {
  mkdirSync(dirname(path), { recursive: true })
  const tmp = `${path}.tmp-${process.pid}-${Math.random().toString(16).slice(2)}`
  let keep = mode
  try {
    keep = statSync(path).mode
  } catch {}
  writeFileSync(tmp, text, { mode: 0o600, flag: "wx" })
  try {
    chmodSync(tmp, keep ?? 0o600)
    renameSync(tmp, path)
  } catch (err) {
    try {
      unlinkSync(tmp)
    } catch {}
    throw err
  }
}

export function applyDesk(path, gate) {
  try {
    const record = readJSON(path)
    if (!record) return false
    const next = deskNext(record, gate)
    if (!next) return false
    writeAtomic(path, `${JSON.stringify(next)}\n`)
    return true
  } catch {
    return false
  }
}

export function applyClaim(path, doc) {
  try {
    const prev = readJSON(path)
    if (
      prev &&
      prev.pid === doc.pid &&
      prev.start_ticks === doc.start_ticks &&
      JSON.stringify(prev.sessions) === JSON.stringify(doc.sessions)
    ) {
      return false
    }
    writeAtomic(path, `${JSON.stringify({ pid: doc.pid, start_ticks: doc.start_ticks, sessions: doc.sessions })}\n`, 0o600)
    return true
  } catch {
    return false
  }
}

function publish(ctx) {
  try {
    const file = ctx.sessionManager.getSessionFile()
    const id = file === undefined ? "" : ctx.sessionManager.getSessionId()
    const fields = deskFields(file, id, ctx.cwd)
    const claim = claimPath(process.env, process.pid, process.platform)
    if (claim && (file === undefined || fields)) {
      let ticks = null
      try {
        ticks = startTicks(readFileSync("/proc/self/stat", "utf8"))
      } catch {}
      if (ticks) applyClaim(claim, { pid: process.pid, start_ticks: ticks, sessions: sessionIDs(file, id) })
    }
    const record = deskRecordPath(process.env)
    if (record && fields) {
      applyDesk(record, { address: process.env.HC_TERMINAL_ID, pid: process.pid, session: fields.session, cwd: fields.cwd })
    }
  } catch {}
}

// /new and /resume replace the runtime and fire session_start again. Shutdown
// must not clear the session: a reboot still needs it.
export default function (pi: ExtensionAPI) {
  pi.on("session_start", (_event, ctx) => {
    publish(ctx)
  })
  pi.on("session_info_changed", (_event, ctx) => {
    publish(ctx)
  })
}
