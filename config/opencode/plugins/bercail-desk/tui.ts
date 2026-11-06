// The desk's selected session, written as soon as the TUI shows it. The wrapper
// owns the record and its heartbeat; this only fills session and cwd, and only
// on the record that names this process. Home clears the session: closing a
// tab without quitting would otherwise come back after a reboot. Every full
// TUI, desk or not, also claims the sessions it has open. hc's status is empty
// while a TUI is idle, so a scan of those events misses them.
import { Plugin } from "@opencode/plugin/tui"
import { createEffect } from "solid-js"
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

// The selected session plus every tab, including an idle one that is not selected.
export function sessionIDs(route, tabs) {
  const ids = []
  const add = (id) => {
    if (typeof id === "string" && id && !ids.includes(id)) ids.push(id)
  }
  if (route && route.type === "session") add(route.sessionID)
  if (Array.isArray(tabs)) {
    for (const tab of tabs) add(tab && tab.sessionID)
  }
  ids.sort()
  return ids
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
  if (record.harness !== "opencode") return null
  if (record.pid !== pid) return null
  if (typeof session !== "string") return null
  const next = { ...record, session }
  if (typeof cwd === "string" && cwd) next.cwd = cwd
  if (next.session === record.session && next.cwd === record.cwd) return null
  return next
}

// What the selected route should store. Home forgets the session; anything else
// that is not a session is left alone.
export function deskFields(route, cwd) {
  if (!route) return null
  if (route.type === "home") return { session: "" }
  if (route.type !== "session" || typeof route.sessionID !== "string" || !route.sessionID) return null
  const fields = { session: route.sessionID }
  if (typeof cwd === "string" && cwd) fields.cwd = cwd
  return fields
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
    const route = ctx.ui.router.current()
    let tabs = []
    try {
      const list = ctx.ui.tabs.list()
      if (Array.isArray(list)) tabs = list
    } catch {}
    const selected = route && route.type === "session" ? route.sessionID : undefined
    let cwd
    if (selected) {
      try {
        cwd = ctx.data.session.get(selected)?.location?.directory
      } catch {}
    }
    const claim = claimPath(process.env, process.pid, process.platform)
    if (claim) {
      let ticks = null
      try {
        ticks = startTicks(readFileSync("/proc/self/stat", "utf8"))
      } catch {}
      if (ticks) applyClaim(claim, { pid: process.pid, start_ticks: ticks, sessions: sessionIDs(route, tabs) })
    }
    const record = deskRecordPath(process.env)
    const fields = deskFields(route, cwd)
    if (record && fields) {
      applyDesk(record, { address: process.env.HC_TERMINAL_ID, pid: process.pid, ...fields })
    }
  } catch {}
}

export default Plugin.define({
  id: "bercail.desk",
  setup(ctx) {
    return ctx.ui.slot({
      append: "app",
      render() {
        createEffect(() => publish(ctx))
        return null
      },
    })
  },
})
