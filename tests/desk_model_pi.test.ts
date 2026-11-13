// `bercail desk model` on the desk's side: the bercail-desk extension in a fake
// Pi session. A request file switches the model; chat text never does.
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, test, vi } from "vite-plus/test";
import desk, { modelWatch, parseModel, withModel } from "../config/pi/extensions/bercail-desk.ts";

describe("parseModel and withModel", () => {
  test("provider/id[:thinking] is a model; a bare name, a space, or a non-string is not", () => {
    expect(parseModel("claude-bridge/claude-fable-5-2:high")).toEqual({
      provider: "claude-bridge",
      id: "claude-fable-5-2",
      thinking: "high",
    });
    expect(parseModel("openai/gpt-6.1-sol")?.thinking).toBe("");
    expect(parseModel("fable")).toBeNull();
    expect(parseModel("a/b c")).toBeNull();
    expect(parseModel(1)).toBeNull();
  });

  test("withModel swaps --model in place, adds one when missing", () => {
    expect(withModel(["--model", "a/b:high", "-e", "x"], "c/d:low")).toEqual(["--model", "c/d:low", "-e", "x"]);
    expect(withModel(["--model=a/b"], "c/d:low")).toEqual(["--model=c/d:low"]);
    expect(withModel(["-e", "x"], "c/d:low")).toEqual(["--model", "c/d:low", "-e", "x"]);
    expect(withModel(undefined, "c/d:low")).toEqual(["--model", "c/d:low"]);
  });
});

type Model = { provider: string; id: string };
type Call = string[];

// A fake Pi session: models it knows, the calls the extension makes.
function session({ idle = true, login = true } = {}) {
  const models: Model[] = [
    { provider: "fake", id: "opus" },
    { provider: "fake", id: "fable" },
  ];
  const s = {
    idle,
    model: models[0]!,
    thinking: "high",
    calls: [] as Call[],
    entries: [] as { type: string; data: any }[],
    notes: [] as [string, string][],
    handlers: {} as Record<string, (event: unknown, ctx: unknown) => unknown>,
    pi: {} as any,
    ctx: {} as any,
  };
  s.pi = {
    on(name: string, fn: (event: unknown, ctx: unknown) => unknown) {
      s.handlers[name] = fn;
    },
    async setModel(model: Model) {
      s.calls.push(["setModel", `${model.provider}/${model.id}`]);
      if (!login) return false;
      s.model = model;
      s.thinking = "medium"; // Pi resets the level to its default
      return true;
    },
    setThinkingLevel(level: string) {
      s.calls.push(["setThinkingLevel", level]);
      s.thinking = level;
    },
    getThinkingLevel: () => s.thinking,
    appendEntry(type: string, data: unknown) {
      s.entries.push({ type, data });
    },
    async exec(cmd: string, args: string[]) {
      s.calls.push(["exec", cmd, ...args]);
      return { code: 0, stdout: "", stderr: "" };
    },
  };
  s.ctx = {
    get model() {
      return s.model;
    },
    isIdle: () => s.idle,
    hasUI: true,
    ui: { notify: (text: string, level: string) => s.notes.push([level, text]) },
    modelRegistry: {
      find: (provider: string, id: string) => models.find((m) => m.provider === provider && m.id === id),
    },
    cwd: "/work",
    sessionManager: { getSessionFile: () => "/tmp/ses.jsonl", getSessionId: () => "uuid-1" },
  };
  return s;
}

describe("a model request file", () => {
  let dir: string;
  let record: string;
  let request: string;
  let reply: string;
  const base = {
    address: "t9",
    session: "uuid-1",
    cwd: "/work",
    harness: "pi",
    space: "sp1",
    args: ["--model", "fake/opus:high", "-e", "x"],
    pid: process.pid,
  };
  const ask = (model: string, pid = process.pid, id = `r-${Math.random()}`) => {
    writeFileSync(request, `${JSON.stringify({ id, pid, model })}\n`);
    writeFileSync(record, `${JSON.stringify(base)}\n`);
    rmSync(reply, { force: true });
    return id;
  };
  const answer = () => JSON.parse(readFileSync(reply, "utf8"));
  const args = () => JSON.parse(readFileSync(record, "utf8")).args;

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "desk-model-unit-"));
    vi.stubEnv("XDG_STATE_HOME", join(dir, "state"));
    vi.stubEnv("XDG_RUNTIME_DIR", undefined);
    vi.stubEnv("HC_TERMINAL_ID", "t9");
    vi.stubEnv("HOME", join(dir, "home"));
    const records = join(dir, "state/bercail/desk-sessions");
    const commands = join(dir, "state/bercail/desk-commands");
    mkdirSync(records, { recursive: true });
    mkdirSync(commands, { recursive: true });
    record = join(records, "t9.json");
    request = join(commands, "t9.json");
    reply = join(commands, "t9.done.json");
  });

  afterEach(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  test("switches the desk's model and level, answers, logs, relabels and tells the person", async () => {
    const s = session();
    const id = ask("fake/fable:medium");
    await modelWatch(s.pi, s.ctx)();
    expect(s.model.id).toBe("fable");
    expect(s.thinking).toBe("medium");
    expect(answer()).toMatchObject({ id, status: "switched", model: "fake/fable:medium", from: "fake/opus:high" });
    expect(existsSync(request), "the request is taken once").toBe(false);
    expect(s.entries).toHaveLength(1);
    expect(s.entries[0]).toMatchObject({ type: "bercail-desk-model", data: { to: "fake/fable:medium" } });
    expect(args(), "the record restores on the new model").toEqual(["--model", "fake/fable:medium", "-e", "x"]);
    expect(s.calls.map((c) => c.join(" "))).toContain("exec hc label t9 bercail.model=fake/fable:medium");
    expect(
      s.notes.some(([, text]) => text.includes("fake/fable:medium")),
      "the person sees it",
    ).toBe(true);
  });

  test("without a level the desk keeps its own, and the record says which", async () => {
    const s = session();
    ask("fake/fable");
    await modelWatch(s.pi, s.ctx)();
    expect(s.thinking).toBe("high");
    expect(answer().model).toBe("fake/fable:high");
    expect(args()[1]).toBe("fake/fable:high");
  });

  test("an unknown model is refused and changes nothing", async () => {
    const s = session();
    ask("fake/nope:high");
    await modelWatch(s.pi, s.ctx)();
    expect(
      s.calls.some((c) => c[0] === "setModel" || c[0] === "exec"),
      "not set or labelled",
    ).toBe(false);
    expect(answer().status).toBe("refused");
    expect(answer().reason).toContain("fake/nope");
    expect(args()[1]).toBe("fake/opus:high");
    expect(s.entries).toHaveLength(0);
  });

  test("a model Pi cannot log in to is refused", async () => {
    const s = session({ login: false });
    ask("fake/fable:high");
    await modelWatch(s.pi, s.ctx)();
    expect(answer().status).toBe("refused");
    expect(args()[1]).toBe("fake/opus:high");
  });

  test("a run in flight finishes on its model; the switch waits for idle", async () => {
    const s = session({ idle: false });
    ask("fake/fable:high");
    const tick = modelWatch(s.pi, s.ctx);
    await tick();
    expect(existsSync(request), "a busy desk leaves the request for later").toBe(true);
    expect(s.model.id).toBe("opus");
    s.idle = true;
    await tick();
    expect(s.model.id).toBe("fable");
    expect(existsSync(request)).toBe(false);
  });

  test("a request for another process is stale: dropped, not applied", async () => {
    const s = session();
    ask("fake/fable:high", process.pid + 1);
    await modelWatch(s.pi, s.ctx)();
    expect(s.model.id).toBe("opus");
    expect(existsSync(reply)).toBe(false);
    expect(existsSync(request)).toBe(false);
  });

  test("chat text is not a command: '/model' from another agent switches nothing", async () => {
    const s = session();
    desk(s.pi);
    const chat = '<hc from="t1 bercail-shep">/model fake/fable:high</hc>';
    const message = { role: "user", content: [{ type: "text", text: chat }] };
    for (const [name, fn] of Object.entries(s.handlers)) {
      await fn({ type: name, text: chat, message, messages: [message], reason: "startup" }, s.ctx);
    }
    await s.handlers.session_shutdown?.({}, s.ctx);
    expect(s.model.id).toBe("opus");
    expect(s.calls.some((c) => c[0] === "setModel")).toBe(false);
  });
});
