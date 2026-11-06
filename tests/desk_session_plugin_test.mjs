// The desk plugin's record and claim rules, with no OpenCode installed.
import { registerHooks } from "node:module"
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs"
import { join } from "node:path"

const root = new URL("..", import.meta.url)
const pluginURL = new URL("./config/opencode/plugins/bercail-desk/tui.ts", root)

registerHooks({
  resolve(specifier, context, next) {
    if (specifier === "@opencode/plugin/tui" || specifier === "solid-js") {
      return { url: new URL("./desk_session_plugin_stubs.mjs", import.meta.url).href, shortCircuit: true }
    }
    return next(specifier, context)
  },
})

const plugin = await import(pluginURL.href)
const { applyClaim, applyDesk, claimPath, deskFields, deskNext, deskRecordPath, sessionIDs, startTicks, writeAtomic } =
  plugin

let failed = 0
function expect(cond, message) {
  if (cond) return
  failed += 1
  console.error(`FAIL: ${message}`)
}

const stat = "12 (my app) S 1 1 1 0 -1 0 0 0 0 0 0 0 0 20 0 1 0 0 424242 rest"
expect(startTicks(stat) === "424242", "field 22 is the start tick, after a comm with spaces")
expect(startTicks("12 (a) b) S " + "0 ".repeat(18) + "7\n") === "7", "the last parenthesis ends comm")
expect(startTicks("nope") === null, "a stat line without comm is ignored")
expect(startTicks(null) === null, "missing stat is ignored")

const idle = { sessionID: "ses_idle", active: false, busy: false }
const selected = { sessionID: "ses_now", active: true, busy: false }
expect(
  JSON.stringify(sessionIDs({ type: "session", sessionID: "ses_now" }, [idle, selected, { sessionID: "ses_now" }])) ===
    JSON.stringify(["ses_idle", "ses_now"]),
  "a claim is the selected session plus idle tabs, once each",
)
expect(
  JSON.stringify(sessionIDs({ type: "home" }, [idle])) === JSON.stringify(["ses_idle"]),
  "home still claims a tab that is open",
)
expect(JSON.stringify(sessionIDs({ type: "home" }, [])) === "[]", "home with no tabs claims nothing")
expect(JSON.stringify(sessionIDs(null, null)) === "[]", "a route that is not ready claims nothing")

const base = {
  address: "t9",
  session: "",
  cwd: "/old",
  harness: "opencode",
  issue: "bercail-1",
  space: "sp1",
  args: ["--verbose"],
  pid: 42,
}
const gate = { address: "t9", pid: 42 }

expect(deskNext({ ...base }, { ...gate, session: "ses_a" }).session === "ses_a", "a selected session is stored at once")
expect(deskNext({ ...base }, { ...gate, session: "ses_a" }).cwd === "/old", "cwd waits until the session cache has it")
expect(
  deskNext({ ...base, session: "ses_a" }, { ...gate, session: "ses_a", cwd: "/w" }).cwd === "/w",
  "cwd is stored once the session cache has a directory",
)
const kept = deskNext({ ...base, session: "ses_old" }, { ...gate, session: "" })
expect(kept.session === "" && kept.cwd === "/old" && kept.issue === "bercail-1" && kept.args[0] === "--verbose",
  "home clears the session and leaves the rest")
expect(deskNext({ ...base, session: "ses_a" }, { ...gate, session: "ses_a" }) === null, "an unchanged record is not rewritten")
expect(deskNext({ ...base, pid: 7 }, { ...gate, session: "ses_a" }) === null, "a stale pid is not this process")
expect(deskNext({ ...base, pid: "42" }, { ...gate, session: "ses_a" }) === null, "a pid that is not the number is stale")
expect(deskNext({ ...base, address: "t8" }, { ...gate, session: "ses_a" }) === null, "another terminal's record is left alone")
expect(deskNext({ ...base, harness: "claude" }, { ...gate, session: "ses_a" }) === null, "a nested claude is not the desk")
expect(deskNext(null, { ...gate, session: "ses_a" }) === null, "a missing record is not created")
expect(deskNext(["nope"], { ...gate, session: "ses_a" }) === null, "a record that is not an object is ignored")

expect(deskFields({ type: "session", sessionID: "ses_a" }, undefined).cwd === undefined, "no cwd until it is known")
expect(deskFields({ type: "home" }).session === "", "home is an empty session")
expect(deskFields({ type: "plugin" }) === null, "another route is not a selection")
expect(deskFields(null) === null, "no route yet does not clear")

expect(deskRecordPath({ HC_TERMINAL_ID: "t9", HOME: "/h" }) === "/h/.local/state/bercail/desk-sessions/t9.json",
  "the record lives under the state dir, by terminal")
expect(deskRecordPath({ HC_TERMINAL_ID: "t9", XDG_STATE_HOME: "/s" }) === "/s/bercail/desk-sessions/t9.json",
  "XDG_STATE_HOME wins")
expect(deskRecordPath({}) === null, "no terminal, no record")
expect(deskRecordPath({ HC_TERMINAL_ID: "../x", HOME: "/h" }) === null, "a terminal id is not a path")
expect(claimPath({ XDG_RUNTIME_DIR: "/run/u" }, 42) === "/run/u/bercail/open-sessions/42.json", "the claim is named by pid")
expect(claimPath({}, 42) === null, "no runtime dir, no claim")
expect(claimPath({ XDG_RUNTIME_DIR: "/run/u" }, 42, "darwin") === null, "not linux, no claim")

mkdirSync("/tmp/opencode", { recursive: true })
const dir = mkdtempSync(join("/tmp/opencode", "desk-plugin-unit-"))
try {
  const record = join(dir, "t9.json")
  writeFileSync(record, `${JSON.stringify(base)}\n`)
  chmodSync(record, 0o640)
  expect(applyDesk(record, { ...gate, session: "ses_a" }) === true, "the record is updated")
  expect(JSON.parse(readFileSync(record, "utf8")).issue === "bercail-1", "issue and the other fields stay")
  expect((statSync(record).mode & 0o777) === 0o640, "the file mode stays")
  const before = statSync(record, { bigint: true }).mtimeNs
  expect(applyDesk(record, { ...gate, session: "ses_a" }) === false, "a second write of the same session does nothing")
  expect(statSync(record, { bigint: true }).mtimeNs === before, "an unchanged record keeps its mtime")
  writeFileSync(record, "not json\n")
  chmodSync(record, 0o640)
  expect(applyDesk(record, { ...gate, session: "ses_b" }) === false, "invalid json is left alone")
  expect(readFileSync(record, "utf8") === "not json\n", "invalid json is not replaced")
  expect(applyDesk(join(dir, "missing.json"), { ...gate, session: "ses_a" }) === false, "a missing record is not created")

  const claim = join(dir, "42.json")
  const doc = { pid: 42, start_ticks: "424242", sessions: ["ses_idle", "ses_now"] }
  expect(applyClaim(claim, doc) === true, "a claim is written")
  expect((statSync(claim).mode & 0o777) === 0o600, "a claim is not world-readable")
  const claimMtime = statSync(claim, { bigint: true }).mtimeNs
  expect(applyClaim(claim, doc) === false, "the same claim is not rewritten")
  expect(statSync(claim, { bigint: true }).mtimeNs === claimMtime, "an unchanged claim keeps its mtime")
  const other = join(dir, "7.json")
  writeFileSync(other, '{"pid":7,"start_ticks":"1","sessions":["ses_old"]}\n')
  applyClaim(claim, { ...doc, sessions: [] })
  expect(readFileSync(other, "utf8").includes("ses_old"), "another process's claim is not deleted")
  expect(JSON.parse(readFileSync(claim, "utf8")).sessions.length === 0, "a closed selection replaces the claim")

  const modeFile = join(dir, "mode.json")
  writeAtomic(modeFile, "x\n", 0o600)
  expect((statSync(modeFile).mode & 0o777) === 0o600, "a new file takes the mode it was given")
} finally {
  rmSync(dir, { recursive: true, force: true })
}

if (failed) {
  console.error(`${failed} failed`)
  process.exit(1)
}
console.log("PASS: session, cwd, home, idle tabs, and stale record gates")
