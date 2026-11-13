// `bercail desk model` on the desk's side: the bercail-desk extension in a fake
// Pi session. A request file switches the model; chat text never does.
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { join } from "node:path"

const root = new URL("..", import.meta.url)
const ext = await import(new URL("./config/pi/extensions/bercail-desk.ts", root).href)
const { modelRequestPath, modelWatch, parseModel, withModel } = ext

let failed = 0
function expect(cond, message) {
  if (cond) return
  failed += 1
  console.error(`FAIL: ${message}`)
}

const p = parseModel("claude-bridge/claude-fable-5-2:high")
expect(p && p.provider === "claude-bridge" && p.id === "claude-fable-5-2" && p.thinking === "high", "provider, id and thinking")
expect(parseModel("openai/gpt-6.1-sol").thinking === "", "no thinking suffix")
expect(parseModel("fable") === null && parseModel("a/b c") === null && parseModel(1) === null, "not a model")
expect(JSON.stringify(withModel(["--model", "a/b:high", "-e", "x"], "c/d:low")) === '["--model","c/d:low","-e","x"]',
  "--model is swapped in place")
expect(JSON.stringify(withModel(["--model=a/b"], "c/d:low")) === '["--model=c/d:low"]', "--model= is swapped")
expect(JSON.stringify(withModel(["-e", "x"], "c/d:low")) === '["--model","c/d:low","-e","x"]', "no --model gets one")
expect(JSON.stringify(withModel(undefined, "c/d:low")) === '["--model","c/d:low"]', "no args")

// A fake Pi session: models it knows, the calls the extension makes.
function session({ idle = true, login = true } = {}) {
  const models = [
    { provider: "fake", id: "opus" },
    { provider: "fake", id: "fable" },
  ]
  const s = { idle, model: models[0], thinking: "high", calls: [], entries: [], notes: [], handlers: {} }
  s.pi = {
    on(name, fn) {
      s.handlers[name] = fn
    },
    async setModel(model) {
      s.calls.push(["setModel", `${model.provider}/${model.id}`])
      if (!login) return false
      s.model = model
      s.thinking = "medium" // Pi resets the level to its default
      return true
    },
    setThinkingLevel(level) {
      s.calls.push(["setThinkingLevel", level])
      s.thinking = level
    },
    getThinkingLevel: () => s.thinking,
    appendEntry(type, data) {
      s.entries.push({ type, data })
    },
    async exec(cmd, args) {
      s.calls.push(["exec", cmd, ...args])
      return { code: 0, stdout: "", stderr: "" }
    },
  }
  s.ctx = {
    get model() {
      return s.model
    },
    isIdle: () => s.idle,
    hasUI: true,
    ui: { notify: (text, level) => s.notes.push([level, text]) },
    modelRegistry: { find: (provider, id) => models.find((m) => m.provider === provider && m.id === id) },
    cwd: "/work",
    sessionManager: { getSessionFile: () => "/tmp/ses.jsonl", getSessionId: () => "uuid-1" },
  }
  return s
}

const dir = mkdtempSync(join("/tmp", "desk-model-unit-"))
const saved = {}
for (const key of ["XDG_STATE_HOME", "XDG_RUNTIME_DIR", "HC_TERMINAL_ID", "HOME"]) saved[key] = process.env[key]
try {
  process.env.XDG_STATE_HOME = join(dir, "state")
  delete process.env.XDG_RUNTIME_DIR
  process.env.HC_TERMINAL_ID = "t9"
  process.env.HOME = join(dir, "home")
  const records = join(dir, "state/bercail/desk-sessions")
  const commands = join(dir, "state/bercail/desk-commands")
  mkdirSync(records, { recursive: true })
  mkdirSync(commands, { recursive: true })
  const record = join(records, "t9.json")
  const request = join(commands, "t9.json")
  const reply = join(commands, "t9.done.json")
  expect(modelRequestPath(process.env) === request, "the request sits beside the records, by terminal")
  const base = { address: "t9", session: "uuid-1", cwd: "/work", harness: "pi", space: "sp1",
    args: ["--model", "fake/opus:high", "-e", "x"], pid: process.pid }
  const ask = (model, pid = process.pid, id = `r-${Math.random()}`) => {
    writeFileSync(request, `${JSON.stringify({ id, pid, model })}\n`)
    writeFileSync(record, `${JSON.stringify(base)}\n`)
    rmSync(reply, { force: true })
    return id
  }
  const answer = () => JSON.parse(readFileSync(reply, "utf8"))
  const args = () => JSON.parse(readFileSync(record, "utf8")).args

  // The switch.
  let s = session()
  let id = ask("fake/fable:medium")
  await modelWatch(s.pi, s.ctx)()
  expect(s.model.id === "fable" && s.thinking === "medium", "the desk runs on the new model and level")
  expect(answer().id === id && answer().status === "switched" && answer().model === "fake/fable:medium"
    && answer().from === "fake/opus:high", `the answer names both models: ${readFileSync(reply, "utf8")}`)
  expect(!existsSync(request), "the request is taken once")
  expect(s.entries.length === 1 && s.entries[0].type === "bercail-desk-model" && s.entries[0].data.to === "fake/fable:medium",
    "the switch is logged in the session")
  expect(JSON.stringify(args()) === '["--model","fake/fable:medium","-e","x"]', "the record restores on the new model")
  expect(s.calls.some((c) => c.join(" ") === "exec hc label t9 bercail.model=fake/fable:medium"), "the label follows")
  expect(s.notes.some(([, text]) => text.includes("fake/fable:medium")), "the person sees it")

  // Without a level the desk keeps its own, and the record says which.
  s = session()
  ask("fake/fable")
  await modelWatch(s.pi, s.ctx)()
  expect(s.thinking === "high", "no level keeps the desk's level")
  expect(answer().model === "fake/fable:high" && args()[1] === "fake/fable:high", "the kept level is recorded")

  // An unknown model is refused and changes nothing.
  s = session()
  ask("fake/nope:high")
  await modelWatch(s.pi, s.ctx)()
  expect(!s.calls.some((c) => c[0] === "setModel" || c[0] === "exec"), "an unknown model is not set or labelled")
  expect(answer().status === "refused" && answer().reason.includes("fake/nope"), "the refusal says which")
  expect(args()[1] === "fake/opus:high" && s.entries.length === 0, "the record and session are left alone")

  // A model Pi cannot log in to is refused.
  s = session({ login: false })
  ask("fake/fable:high")
  await modelWatch(s.pi, s.ctx)()
  expect(answer().status === "refused" && args()[1] === "fake/opus:high", "no login, no switch")

  // A run in flight finishes on its model; the switch waits for idle.
  s = session({ idle: false })
  ask("fake/fable:high")
  const tick = modelWatch(s.pi, s.ctx)
  await tick()
  expect(existsSync(request) && s.model.id === "opus", "a busy desk leaves the request for later")
  s.idle = true
  await tick()
  expect(s.model.id === "fable" && !existsSync(request), "it switches once idle")

  // A request for another process is stale: dropped, not applied.
  s = session()
  ask("fake/fable:high", process.pid + 1)
  await modelWatch(s.pi, s.ctx)()
  expect(s.model.id === "opus" && !existsSync(reply) && !existsSync(request), "a stale request is dropped")

  // Chat text is not a command: '/model' in a message from another agent switches nothing.
  s = session()
  rmSync(request, { force: true })
  ext.default(s.pi)
  const chat = '<hc from="t1 bercail-shep">/model fake/fable:high</hc>'
  const message = { role: "user", content: [{ type: "text", text: chat }] }
  for (const [name, fn] of Object.entries(s.handlers)) {
    await fn({ type: name, text: chat, message, messages: [message], reason: "startup" }, s.ctx)
  }
  expect(typeof s.handlers.session_start === "function" && s.handlers.input === undefined,
    "the extension reads no input")
  s.handlers.session_shutdown?.({}, s.ctx)
  expect(s.model.id === "opus" && !s.calls.some((c) => c[0] === "setModel"), "a /model message does not switch")
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
console.log("PASS: desk model switch, refusals, idle gate, and chat text")
