// Shep's compaction extension with no Pi: the summary it assembles from the
// board, the rules and the model's decisions, each way it falls back to Pi's
// own compaction, the log, and the rollover switch. A fake ctx and model.
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

const root = new URL("..", import.meta.url)
const { compactor, assemble, decisionsOf, rulesOf, newDay, seed, DECISIONS, INSTRUCTIONS, default: register } =
  await import(new URL("./shep/pi/compaction.ts", root).href)

let failed = 0
function expect(cond, message) {
  if (cond) return
  failed += 1
  console.error(`FAIL: ${message}`)
}

const BOARD = "~/Work/app: 1 job\n- app-1: Fix the login · desk t9 blocked · login\nWaiting on the person:\n- nothing\n"
const RULES = ["- 2026-11-11 [app] Merge to main", "- 2026-11-11 [all] Never block"]

function event(over = {}) {
  return {
    reason: "manual",
    signal: new AbortController().signal,
    preparation: {
      messagesToSummarize: [{ role: "user", content: "old" }],
      turnPrefixMessages: [{ role: "assistant", content: "prefix" }],
      previousSummary: undefined,
      firstKeptEntryId: "e42",
      tokensBefore: 123456,
    },
    ...over,
  }
}

// A model that records what it was asked and answers with `reply`.
function ctx(reply) {
  const calls = []
  return {
    calls,
    model: { provider: "fake", id: "lead", maxTokens: 900 },
    modelRegistry: {
      complete: async (model, context, options) => {
        calls.push({ model, context, options })
        if (reply instanceof Error) throw reply
        return reply
      },
    },
  }
}

const answer = (text, extra = {}) => ({ content: [{ type: "text", text }], stopReason: "stop", usage: { input: 10, output: 5 }, ...extra })

function deps(over = {}) {
  const logs = [], serialized = []
  return {
    logs, serialized,
    board: async () => BOARD,
    rules: () => RULES,
    serialize: (messages) => { serialized.push(messages); return "[User]: old\n[Assistant]: prefix" },
    log: (line) => logs.push(line),
    now: () => new Date("2026-11-12T03:00:00.000Z"),
    ...over,
  }
}

// The summary: board, rules, decisions, in that order; Pi's ids pass through.
{
  const d = deps(), c = ctx(answer("### Decisions\n- ship app-1 after review\n### Open questions\n- none"))
  const ev = event({ preparation: { ...event().preparation, previousSummary: `# old\n\n${DECISIONS}\n\n### Decisions\n- keep the old rule` } })
  const out = await compactor(d)(ev, c)
  const s = out?.compaction?.summary ?? ""
  expect(s.startsWith("# Shep's state at compaction (2026-11-12T03:00:00.000Z)"), `summary head: ${s.slice(0, 80)}`)
  expect(s.includes("- app-1: Fix the login · desk t9 blocked · login"), "the board is in the summary")
  expect(s.includes(RULES.join("\n")), "the rules are in the summary")
  expect(s.indexOf("## Job board") < s.indexOf("## Standing rules") && s.indexOf("## Standing rules") < s.indexOf(DECISIONS),
    "board, then rules, then decisions")
  expect(s.trimEnd().endsWith("- ship app-1 after review\n### Open questions\n- none"), "the model's decisions close the summary")
  expect(out.compaction.firstKeptEntryId === "e42" && out.compaction.tokensBefore === 123456, "Pi's cut point and token count pass through")
  expect(out.compaction.usage?.input === 10 && out.compaction.details?.by === "bercail-shep", `usage and details: ${JSON.stringify(out.compaction)}`)
  expect(d.serialized[0]?.length === 2, "both the summarized messages and the split turn's prefix are serialized")
  const sent = c.calls[0]?.context?.messages?.[0]?.content?.[0]?.text ?? ""
  expect(sent.startsWith(INSTRUCTIONS) && /Leave out job state/.test(sent), "the model is told to leave out job state")
  expect(sent.includes("<conversation>\n[User]: old\n[Assistant]: prefix\n</conversation>"), "the conversation goes to the model")
  expect(sent.includes("<previous-summary>\n### Decisions\n- keep the old rule\n</previous-summary>") && !sent.includes("# old"),
    "only the previous summary's decisions go back to the model")
  expect(c.calls[0].options.maxTokens === 900 && c.calls[0].options.signal === ev.signal, `options: ${JSON.stringify(c.calls[0].options)}`)
  expect(d.logs.length === 0, `logged on success: ${d.logs}`)
  console.log("PASS: the summary is the board, the rules, and the model's decisions only")
}

// Every failure returns nothing (Pi compacts its own way) and logs why.
{
  const cases = [
    ["the model throws", deps(), ctx(new Error("rate limited")), /rate limited/],
    ["the model errors", deps(), ctx(answer("", { stopReason: "error", errorMessage: "overloaded" })), /overloaded/],
    ["the model writes nothing", deps(), ctx(answer("   ")), /no summary/],
    ["the board fails", deps({ board: async () => { throw new Error("bercail shep board failed: hc") } }), ctx(answer("x")), /board failed/],
    ["the board is empty", deps({ board: async () => "\n" }), ctx(answer("x")), /board was empty/],
    ["serializing fails", deps({ serialize: () => { throw new Error("no pi") } }), ctx(answer("x")), /no pi/],
    ["no model", deps(), { ...ctx(answer("x")), model: undefined }, /no model/],
  ]
  for (const [name, d, c, why] of cases) {
    const out = await compactor(d)(event({ reason: "threshold" }), c)
    expect(out === undefined, `${name}: returned ${JSON.stringify(out)}`)
    expect(d.logs.length === 1 && d.logs[0].startsWith("threshold compaction: Pi's default summary instead of Shep's") && why.test(d.logs[0]),
      `${name}: log ${JSON.stringify(d.logs)}`)
  }
  const d = deps({ board: async () => { throw new Error("down") } }), c = ctx(answer("x"))
  await compactor(d)(event(), c)
  expect(c.calls.length === 0, "the model is not called when the board fails")
  console.log("PASS: any failure falls back to Pi's compaction, with a log line")
}

// The pieces.
expect(decisionsOf(undefined) === "" && decisionsOf("## Goal\nPi wrote this") === "## Goal\nPi wrote this", "Pi's summary is kept whole")
expect(rulesOf("# head\n\n- a\nnot a rule\n- b\n").join() === "- a,- b", "rules are the bullet lines")
expect(assemble({ board: "b", rules: [], decisions: "d", at: "t" }).includes("- none yet"), "no rules says so")
expect(newDay("2026-11-11T23:00:00", new Date("2026-11-12T08:00:00")) && !newDay("2026-11-12T01:00:00", new Date("2026-11-12T08:00:00"))
  && !newDay(undefined, new Date()) && !newDay("garbage", new Date()), "a new day is a different local date")
const s = seed({ board: "B", rules: RULES, previous: "/s/old.jsonl", at: "t" })
expect(s.includes("/s/old.jsonl") && s.includes("/resume") && s.includes("B") && s.includes(RULES[0]), `seed: ${s}`)
console.log("PASS: earlier decisions, rules, new days, and the rollover seed")

// Registration, the log, and the rollover switch, through the default export.
const dir = mkdtempSync(join(tmpdir(), "shep-compaction-"))
function fakePi() {
  const handlers = {}, commands = {}, sent = []
  return {
    handlers, commands, sent,
    on: (name, fn) => { handlers[name] = fn },
    registerCommand: (name, def) => { commands[name] = def },
    sendUserMessage: (text, options) => sent.push({ text, options }),
  }
}
delete process.env.BERCAIL_SHEP_STATE
let pi = fakePi()
register(pi)
expect(Object.keys(pi.handlers).length === 0, `registered without Shep's state: ${Object.keys(pi.handlers)}`)

process.env.BERCAIL_SHEP_STATE = dir
process.env.BERCAIL_SHEP_ROLLOVER = "0"
const board = join(dir, "bercail")
writeFileSync(board, `#!/bin/sh\n[ "$1 $2" = "shep board" ] && printf '%s' '${BOARD.replace(/\n/g, "\\n")}'\n`)
chmodSync(board, 0o755)
process.env.BERCAIL_SHEP_BIN = board
writeFileSync(join(dir, "preferences.md"), `# head\n\n${RULES.join("\n")}\n`)
pi = fakePi()
register(pi)
expect(["session_before_compact", "session_compact", "session_compact_failed"].every((n) => pi.handlers[n]) && !pi.handlers.agent_end,
  `handlers: ${Object.keys(pi.handlers)}`)
expect(pi.commands["shep-rollover"], "the /shep-rollover command is registered")
// Plain node has no Pi package to serialize with: the real handler falls back.
const out = await pi.handlers.session_before_compact(event({ reason: "threshold" }), ctx(answer("x")))
pi.handlers.session_compact_failed({ reason: "overflow", errorMessage: "context too long", aborted: false, fromExtension: false })
pi.handlers.session_compact({ reason: "manual", fromExtension: true })
const log = readFileSync(join(dir, "compaction.log"), "utf8").trim().split("\n")
expect(out === undefined && log.length === 3, `fallback and log: ${JSON.stringify(out)} ${log}`)
expect(/^\d{4}-\d\d-\d\dT[^ ]+ threshold compaction: Pi's default summary instead of Shep's/.test(log[0]), `log 1: ${log[0]}`)
expect(log[1].endsWith("overflow compaction failed: context too long"), `log 2: ${log[1]}`)
expect(log[2].endsWith("manual compaction: Shep's summary (board, rules, decisions)"), `log 3: ${log[2]}`)
console.log("PASS: registered only for Shep; failures and compactions are logged")

process.env.BERCAIL_SHEP_ROLLOVER = "1"
const idle = (c, header) => ({ ...c, isIdle: () => true, sessionManager: { getHeader: () => ({ timestamp: header }) } })
const tick = () => new Promise((r) => setTimeout(r, 20))
const now = new Date().toISOString()
pi = fakePi()
register(pi)
const skipped = await pi.handlers.session_before_compact(event({ reason: "threshold" }), idle(ctx(answer("x")), now))
await tick()
expect(skipped?.cancel === true, `rollover on: a threshold compaction is skipped: ${JSON.stringify(skipped)}`)
expect(pi.sent.length === 1 && pi.sent[0].text === "/shep-rollover" && pi.sent[0].options?.expandPromptTemplates === true,
  `the skipped compaction starts a rollover: ${JSON.stringify(pi.sent)}`)
pi.handlers.session_compact_failed({ reason: "threshold", aborted: true, fromExtension: false })
const manual = await pi.handlers.session_before_compact(event({ reason: "manual" }), ctx(answer("x")))
expect(manual?.cancel !== true, "rollover on: /compact still compacts")
const again = await pi.handlers.session_before_compact(event({ reason: "threshold" }), idle(ctx(answer("x")), now))
await tick()
expect(pi.sent.length === 1 && again?.cancel !== true, "one try per session; after it, threshold compaction runs again")
const lines = readFileSync(join(dir, "compaction.log"), "utf8").trim().split("\n").slice(3)
expect(lines.some((l) => l.endsWith("threshold compaction skipped: a rollover instead")) && !lines.some((l) => /failed/.test(l)),
  `a skip is logged as a skip, not a failure: ${lines}`)
pi = fakePi()
register(pi)
pi.handlers.agent_end({}, idle({}, now))
await tick()
expect(pi.sent.length === 0, "no rollover on the session's own day")
pi.handlers.agent_end({}, idle({}, "2020-01-01T12:00:00"))
await tick()
pi.handlers.agent_end({}, idle({}, "2020-01-01T12:00:00"))
await tick()
expect(pi.sent.length === 1, `a session from an earlier day rolls over, once: ${pi.sent.length}`)
let busy = true
pi = fakePi()
register(pi)
pi.handlers.agent_end({}, { isIdle: () => !busy, sessionManager: { getHeader: () => ({ timestamp: "2020-01-01T12:00:00" }) } })
await tick()
expect(pi.sent.length === 0, "no rollover while Pi is busy")
busy = false
await new Promise((r) => setTimeout(r, 300))
expect(pi.sent.length === 1, "the rollover starts once Pi is idle")
console.log("PASS: rollover replaces threshold compaction and starts each new day, once per session, when Pi is idle")

rmSync(dir, { recursive: true, force: true })
if (failed) process.exit(1)
