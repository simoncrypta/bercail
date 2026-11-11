// The desk Pi extension's record and claim rules, with no Pi installed.
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs"
import { join } from "node:path"

const root = new URL("..", import.meta.url)
const ext = await import(new URL("./config/pi/extensions/bercail-desk.ts", root).href)
const { applyClaim, applyDesk, claimPath, deskFields, deskNext, deskRecordPath, sessionIDs, startTicks, writeAtomic } =
  ext

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
expect(startTicks("12 (pi) S 1") === null, "a short stat line has no start tick")

const base = {
  address: "t9",
  session: "",
  cwd: "/old",
  harness: "pi",
  issue: "bercail-1",
  space: "sp1",
  args: ["--verbose"],
  pid: 42,
}
const gate = { address: "t9", pid: 42 }

expect(deskNext({ ...base }, { ...gate, session: "ses_a" }).session === "ses_a", "a session id is stored at once")
expect(deskNext({ ...base }, { ...gate, session: "ses_a" }).cwd === "/old", "cwd waits until it is known")
expect(
  deskNext({ ...base, session: "ses_a" }, { ...gate, session: "ses_a", cwd: "/w" }).cwd === "/w",
  "cwd is stored once the session has a directory",
)
const kept = deskNext({ ...base, session: "ses_old" }, { ...gate, session: "" })
expect(kept.session === "" && kept.cwd === "/old" && kept.issue === "bercail-1" && kept.args[0] === "--verbose",
  "an empty session clears only the session")
expect(deskNext({ ...base, session: "ses_a" }, { ...gate, session: "ses_a" }) === null, "an unchanged record is not rewritten")
expect(deskNext({ ...base, pid: 7 }, { ...gate, session: "ses_a" }) === null, "a stale pid is not this process")
expect(deskNext({ ...base, pid: "42" }, { ...gate, session: "ses_a" }) === null, "a pid that is not the number is stale")
expect(deskNext({ ...base, address: "t8" }, { ...gate, session: "ses_a" }) === null, "another terminal's record is left alone")
expect(deskNext({ ...base, harness: "other" }, { ...gate, session: "ses_a" }) === null, "a non-Pi desk is not this Pi")
expect(deskNext(null, { ...gate, session: "ses_a" }) === null, "a missing record is not created")
expect(deskNext(["nope"], { ...gate, session: "ses_a" }) === null, "a record that is not an object is ignored")
expect(deskNext({ ...base }, { ...gate, session: 1 }) === null, "a session that is not a string is ignored")

expect(deskFields(undefined, "nope", "/w").session === "" && deskFields(undefined, "nope", "/w").cwd === "/w",
  "an ephemeral session stores nothing to resume")
expect(JSON.stringify(sessionIDs(undefined, "nope")) === "[]", "an ephemeral session claims nothing")
expect(deskFields("/tmp/ses.jsonl", "", "/w") === null, "a path without an id is not a selection")
expect(deskFields("/tmp/ses.jsonl", "ses_a", undefined).cwd === undefined, "no cwd until it is known")
expect(JSON.stringify(sessionIDs("/tmp/ses.jsonl", "ses_a")) === JSON.stringify(["ses_a"]), "one session is the claim")

expect(deskRecordPath({ HC_TERMINAL_ID: "t9", HOME: "/h" }) === "/h/.local/state/bercail/desk-sessions/t9.json",
  "the record lives under the state dir, by terminal")
expect(deskRecordPath({ HC_TERMINAL_ID: "t9", XDG_STATE_HOME: "/s" }) === "/s/bercail/desk-sessions/t9.json",
  "XDG_STATE_HOME wins")
expect(deskRecordPath({}) === null, "no terminal, no record")
expect(deskRecordPath({ HC_TERMINAL_ID: "../x", HOME: "/h" }) === null, "a terminal id is not a path")
expect(claimPath({ XDG_RUNTIME_DIR: "/run/u" }, 42) === "/run/u/bercail/open-sessions/42.json", "the claim is named by pid")
expect(claimPath({}, 42) === null, "no runtime dir, no claim")
expect(claimPath({ XDG_RUNTIME_DIR: "/run/u" }, 42, "darwin") === null, "not linux, no claim")
expect(claimPath({ XDG_RUNTIME_DIR: "/run/u" }, "42") === null, "a pid that is not a number is not a claim")

const dir = mkdtempSync(join("/tmp", "desk-pi-unit-"))
const saved = {}
for (const key of ["XDG_STATE_HOME", "XDG_RUNTIME_DIR", "HC_TERMINAL_ID", "HOME"]) saved[key] = process.env[key]
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
  const invalid = readFileSync(record, "utf8")
  writeFileSync(record, "not json\n")
  chmodSync(record, 0o640)
  expect(applyDesk(record, { ...gate, session: "ses_b" }) === false, "invalid json is left alone")
  expect(readFileSync(record, "utf8") === "not json\n", "invalid json is not replaced")
  writeFileSync(record, "[]\n")
  expect(applyDesk(record, { ...gate, session: "ses_b" }) === false, "an array record is left alone")
  expect(readFileSync(record, "utf8") === "[]\n", "an array record is not replaced")
  expect(applyDesk(join(dir, "missing.json"), { ...gate, session: "ses_a" }) === false, "a missing record is not created")
  writeFileSync(record, invalid)

  const claim = join(dir, "42.json")
  const doc = { pid: 42, start_ticks: "424242", sessions: ["ses_a"] }
  expect(applyClaim(claim, doc) === true, "a claim is written")
  expect((statSync(claim).mode & 0o777) === 0o600, "a claim is not world-readable")
  const claimMtime = statSync(claim, { bigint: true }).mtimeNs
  expect(applyClaim(claim, doc) === false, "the same claim is not rewritten")
  expect(statSync(claim, { bigint: true }).mtimeNs === claimMtime, "an unchanged claim keeps its mtime")
  expect(JSON.parse(readFileSync(claim, "utf8")).sessions[0] === "ses_a", "the claim lists the open session")

  const modeFile = join(dir, "mode.json")
  writeAtomic(modeFile, "x\n", 0o600)
  expect((statSync(modeFile).mode & 0o777) === 0o600, "a new file takes the mode it was given")

  const state = join(dir, "state")
  const runtime = join(dir, "run")
  mkdirSync(state, { recursive: true })
  mkdirSync(runtime, { mode: 0o700 })
  process.env.XDG_STATE_HOME = state
  process.env.XDG_RUNTIME_DIR = runtime
  process.env.HC_TERMINAL_ID = "t9"
  process.env.HOME = join(dir, "home")
  const live = join(state, "bercail/desk-sessions/t9.json")
  mkdirSync(join(state, "bercail/desk-sessions"), { recursive: true })
  const owned = { ...base, pid: process.pid, harness: "pi", session: "" }
  writeFileSync(live, `${JSON.stringify(owned)}\n`)
  chmodSync(live, 0o640)
  const handlers = {}
  ext.default({
    on(name, fn) {
      handlers[name] = fn
    },
  })
  expect(typeof handlers.session_start === "function" && typeof handlers.session_info_changed === "function",
    "session_start and session_info_changed both publish")
  expect(handlers.session_shutdown === undefined, "shutdown does not publish")
  const ctx = {
    cwd: "/work",
    sessionManager: {
      getSessionFile: () => "/tmp/ses.jsonl",
      getSessionId: () => "uuid-1",
    },
  }
  handlers.session_start({}, ctx)
  const started = JSON.parse(readFileSync(live, "utf8"))
  expect(started.session === "uuid-1" && started.cwd === "/work" && started.issue === "bercail-1",
    "session_start fills session and cwd")
  expect((statSync(live).mode & 0o777) === 0o640, "session_start keeps the record mode")
  const claimFile = join(runtime, "bercail/open-sessions", `${process.pid}.json`)
  expect(JSON.parse(readFileSync(claimFile, "utf8")).sessions[0] === "uuid-1", "session_start claims the session")
  expect((statSync(claimFile).mode & 0o777) === 0o600, "the published claim is 0600")
  ctx.sessionManager.getSessionId = () => "uuid-2"
  handlers.session_info_changed({}, ctx)
  expect(JSON.parse(readFileSync(live, "utf8")).session === "uuid-2", "session_info_changed publishes the new id")
  expect(JSON.parse(readFileSync(claimFile, "utf8")).sessions[0] === "uuid-2", "session_info_changed updates the claim")
  const same = statSync(live, { bigint: true }).mtimeNs
  handlers.session_info_changed({}, ctx)
  expect(statSync(live, { bigint: true }).mtimeNs === same, "the same session is not rewritten from the event")
  ctx.sessionManager.getSessionFile = () => undefined
  ctx.sessionManager.getSessionId = () => "nope"
  handlers.session_start({}, ctx)
  expect(JSON.parse(readFileSync(live, "utf8")).session === "", "an ephemeral session stores an empty id")
  expect(JSON.parse(readFileSync(claimFile, "utf8")).sessions.length === 0, "an ephemeral session claims nothing")
  let threw = false
  try {
    handlers.session_start({}, { sessionManager: { getSessionFile() { throw new Error("boom") } } })
  } catch {
    threw = true
  }
  expect(!threw, "a session error does not escape")
  expect(JSON.parse(readFileSync(live, "utf8")).session === "", "a session error does not clear a stored empty id twice")
  writeFileSync(live, `${JSON.stringify({ ...owned, harness: "other", session: "keep" })}\n`)
  const foreign = readFileSync(live, "utf8")
  ctx.sessionManager.getSessionFile = () => "/tmp/ses.jsonl"
  ctx.sessionManager.getSessionId = () => "uuid-3"
  handlers.session_start({}, ctx)
  expect(readFileSync(live, "utf8") === foreign, "the event leaves a non-Pi record byte-for-byte")
} finally {
  for (const key of Object.keys(saved)) {
    if (saved[key] === undefined) delete process.env[key]
    else process.env[key] = saved[key]
  }
  rmSync(dir, { recursive: true, force: true })
}

if (failed) {
  console.error(`${failed} failed`)
  process.exit(1)
}
console.log("PASS: session, cwd, ephemeral, and stale record gates")
