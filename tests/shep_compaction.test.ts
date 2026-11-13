// Shep's compaction extension with no Pi: the summary it assembles from the
// board, the rules and the model's decisions, each way it falls back to Pi's
// own compaction, the log, and the rollover switch. A fake ctx and model.
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, test, vi } from "vite-plus/test";
import register, {
  DECISIONS,
  INSTRUCTIONS,
  assemble,
  compactor,
  decisionsOf,
  newDay,
  rulesOf,
  seed,
} from "../shep/pi/compaction.ts";

// No Pi to serialize with, as in a Shep test outside Pi: the real handler falls back.
vi.mock("@earendil-works/pi-coding-agent", () => {
  throw new Error("no Pi package");
});

const BOARD =
  "~/Work/app: 1 job\n- app-1: Fix the login · desk t9 blocked · login\nWaiting on the person:\n- nothing\n";
const RULES = ["- 2026-11-11 [app] Merge to main", "- 2026-11-11 [all] Never block"];

function event(over: Record<string, unknown> = {}): any {
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
  };
}

// A model that records what it was asked and answers with `reply`.
function ctx(reply: unknown): any {
  const calls: any[] = [];
  return {
    calls,
    model: { provider: "fake", id: "lead", maxTokens: 900 },
    modelRegistry: {
      complete: async (model: unknown, context: unknown, options: unknown) => {
        calls.push({ model, context, options });
        if (reply instanceof Error) throw reply;
        return reply;
      },
    },
  };
}

const answer = (text: string, extra = {}) => ({
  content: [{ type: "text", text }],
  stopReason: "stop",
  usage: { input: 10, output: 5 },
  ...extra,
});

function deps(over: Record<string, unknown> = {}) {
  const logs: string[] = [];
  const serialized: unknown[][] = [];
  return {
    logs,
    serialized,
    board: async () => BOARD,
    rules: () => RULES,
    serialize: (messages: unknown[]) => {
      serialized.push(messages);
      return "[User]: old\n[Assistant]: prefix";
    },
    log: (line: string) => logs.push(line),
    now: () => new Date("2026-11-12T03:00:00.000Z"),
    ...over,
  };
}

describe("the summary is the board, the rules, and the model's decisions only", () => {
  const run = async () => {
    const d = deps();
    const c = ctx(answer("### Decisions\n- ship app-1 after review\n### Open questions\n- none"));
    const ev = event({
      preparation: {
        ...event().preparation,
        previousSummary: `# old\n\n${DECISIONS}\n\n### Decisions\n- keep the old rule`,
      },
    });
    const out = await compactor(d)(ev, c);
    return { d, c, ev, out, s: out?.compaction?.summary ?? "" };
  };

  test("board, then rules, then the model's decisions", async () => {
    const { s } = await run();
    expect(s).toMatch(/^# Shep's state at compaction \(2026-11-12T03:00:00\.000Z\)/);
    expect(s).toContain("- app-1: Fix the login · desk t9 blocked · login");
    expect(s).toContain(RULES.join("\n"));
    expect(s.indexOf("## Job board")).toBeLessThan(s.indexOf("## Standing rules"));
    expect(s.indexOf("## Standing rules")).toBeLessThan(s.indexOf(DECISIONS));
    expect(s.trimEnd().endsWith("- ship app-1 after review\n### Open questions\n- none")).toBe(true);
  });

  test("Pi's cut point, token count, usage and details pass through", async () => {
    const { out } = await run();
    expect(out?.compaction).toMatchObject({
      firstKeptEntryId: "e42",
      tokensBefore: 123456,
      usage: { input: 10 },
      details: { by: "bercail-shep" },
    });
  });

  test("the model gets the conversation and only the earlier decisions, told to leave out job state", async () => {
    const { d, c, ev } = await run();
    expect(d.serialized[0], "the summarized messages and the split turn's prefix").toHaveLength(2);
    const sent: string = c.calls[0]?.context?.messages?.[0]?.content?.[0]?.text ?? "";
    expect(sent.startsWith(INSTRUCTIONS)).toBe(true);
    expect(sent).toMatch(/Leave out job state/);
    expect(sent).toContain("<conversation>\n[User]: old\n[Assistant]: prefix\n</conversation>");
    expect(sent).toContain("<previous-summary>\n### Decisions\n- keep the old rule\n</previous-summary>");
    expect(sent).not.toContain("# old");
    expect(c.calls[0].options.maxTokens).toBe(900);
    expect(c.calls[0].options.signal).toBe(ev.signal);
  });

  test("nothing is logged on success", async () => {
    const { d } = await run();
    expect(d.logs).toEqual([]);
  });
});

describe("any failure falls back to Pi's compaction, with a log line", () => {
  test.each([
    ["the model throws", () => deps(), () => ctx(new Error("rate limited")), /rate limited/],
    [
      "the model errors",
      () => deps(),
      () => ctx(answer("", { stopReason: "error", errorMessage: "overloaded" })),
      /overloaded/,
    ],
    ["the model writes nothing", () => deps(), () => ctx(answer("   ")), /no summary/],
    [
      "the board fails",
      () =>
        deps({
          board: async () => {
            throw new Error("bercail shep board failed: hc");
          },
        }),
      () => ctx(answer("x")),
      /board failed/,
    ],
    ["the board is empty", () => deps({ board: async () => "\n" }), () => ctx(answer("x")), /board was empty/],
    [
      "serializing fails",
      () =>
        deps({
          serialize: () => {
            throw new Error("no pi");
          },
        }),
      () => ctx(answer("x")),
      /no pi/,
    ],
    ["no model", () => deps(), () => ({ ...ctx(answer("x")), model: undefined }), /no model/],
  ])("%s", async (_name, makeDeps, makeCtx, why) => {
    const d = makeDeps();
    const out = await compactor(d)(event({ reason: "threshold" }), makeCtx());
    expect(out).toBeUndefined();
    expect(d.logs).toHaveLength(1);
    expect(d.logs[0]).toMatch(/^threshold compaction: Pi's default summary instead of Shep's/);
    expect(d.logs[0]).toMatch(why);
  });

  test("the model is not called when the board fails", async () => {
    const d = deps({
      board: async () => {
        throw new Error("down");
      },
    });
    const c = ctx(answer("x"));
    await compactor(d)(event(), c);
    expect(c.calls).toHaveLength(0);
  });
});

describe("earlier decisions, rules, new days, and the rollover seed", () => {
  test("Pi's summary is kept whole", () => {
    expect(decisionsOf(undefined)).toBe("");
    expect(decisionsOf("## Goal\nPi wrote this")).toBe("## Goal\nPi wrote this");
  });

  test("rules are the bullet lines; no rules says so", () => {
    expect(rulesOf("# head\n\n- a\nnot a rule\n- b\n")).toEqual(["- a", "- b"]);
    expect(assemble({ board: "b", rules: [], decisions: "d", at: "t" })).toContain("- none yet");
  });

  test("a new day is a different local date", () => {
    expect(newDay("2026-11-11T23:00:00", new Date("2026-11-12T08:00:00"))).toBe(true);
    expect(newDay("2026-11-12T01:00:00", new Date("2026-11-12T08:00:00"))).toBe(false);
    expect(newDay(undefined, new Date())).toBe(false);
    expect(newDay("garbage", new Date())).toBe(false);
  });

  test("the seed names the previous session, /resume, the board and the rules", () => {
    const s = seed({ board: "B", rules: RULES, previous: "/s/old.jsonl", at: "t" });
    expect(s).toContain("/s/old.jsonl");
    expect(s).toContain("/resume");
    expect(s).toContain("B");
    expect(s).toContain(RULES[0]);
  });
});

function fakePi() {
  const handlers: Record<string, (...args: any[]) => any> = {};
  const commands: Record<string, unknown> = {};
  const sent: { text: string; options: any }[] = [];
  return {
    handlers,
    commands,
    sent,
    on: (name: string, fn: (...args: any[]) => any) => {
      handlers[name] = fn;
    },
    registerCommand: (name: string, def: unknown) => {
      commands[name] = def;
    },
    sendUserMessage: (text: string, options: unknown) => sent.push({ text, options }),
  };
}

const idle = (c: object, header: string) => ({
  ...c,
  isIdle: () => true,
  sessionManager: { getHeader: () => ({ timestamp: header }) },
});
const tick = () => new Promise((r) => setTimeout(r, 20));

describe("registration, the log, and the rollover switch, through the default export", () => {
  let dir: string;
  const logLines = () => readFileSync(join(dir, "compaction.log"), "utf8").trim().split("\n");
  const shep = (rollover: "0" | "1") => {
    vi.stubEnv("BERCAIL_SHEP_ROLLOVER", rollover);
    const pi = fakePi();
    register(pi as any);
    return pi;
  };

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "shep-compaction-"));
    vi.stubEnv("BERCAIL_SHEP_STATE", dir);
    const board = join(dir, "bercail");
    writeFileSync(board, `#!/bin/sh\n[ "$1 $2" = "shep board" ] && printf '%s' '${BOARD.replace(/\n/g, "\\n")}'\n`);
    chmodSync(board, 0o755);
    vi.stubEnv("BERCAIL_SHEP_BIN", board);
    writeFileSync(join(dir, "preferences.md"), `# head\n\n${RULES.join("\n")}\n`);
  });

  afterEach(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  test("without Shep's state nothing registers", () => {
    vi.stubEnv("BERCAIL_SHEP_STATE", undefined);
    const pi = fakePi();
    register(pi as any);
    expect(Object.keys(pi.handlers)).toEqual([]);
  });

  test("a fallback, a failure and a compaction each log a line", async () => {
    const pi = shep("0");
    const out = await pi.handlers.session_before_compact!(event({ reason: "threshold" }), ctx(answer("x")));
    pi.handlers.session_compact_failed!({
      reason: "overflow",
      errorMessage: "context too long",
      aborted: false,
      fromExtension: false,
    });
    pi.handlers.session_compact!({ reason: "manual", fromExtension: true });
    const log = logLines();
    expect(out).toBeUndefined();
    expect(log).toHaveLength(3);
    expect(log[0]).toMatch(/^\d{4}-\d\d-\d\dT[^ ]+ threshold compaction: Pi's default summary instead of Shep's/);
    expect(log[1]).toMatch(/overflow compaction failed: context too long$/);
    expect(log[2]).toMatch(/manual compaction: Shep's summary \(board, rules, decisions\)$/);
  });

  test("rollover on: a threshold compaction is skipped for a rollover, once per session; /compact still compacts", async () => {
    const pi = shep("1");
    const now = new Date().toISOString();
    const skipped = await pi.handlers.session_before_compact!(
      event({ reason: "threshold" }),
      idle(ctx(answer("x")), now),
    );
    await tick();
    expect(skipped?.cancel).toBe(true);
    expect(pi.sent).toHaveLength(1);
    expect(pi.sent[0]).toMatchObject({ text: "/shep-rollover", options: { expandPromptTemplates: true } });
    expect(pi.commands["shep-rollover"], "the command it sends is Shep's own").toBeDefined();
    pi.handlers.session_compact_failed!({ reason: "threshold", aborted: true, fromExtension: false });
    const manual = await pi.handlers.session_before_compact!(event({ reason: "manual" }), ctx(answer("x")));
    expect(manual?.cancel).not.toBe(true);
    const again = await pi.handlers.session_before_compact!(
      event({ reason: "threshold" }),
      idle(ctx(answer("x")), now),
    );
    await tick();
    expect(pi.sent, "one try per session").toHaveLength(1);
    expect(again?.cancel, "after it, threshold compaction runs again").not.toBe(true);
    const lines = logLines();
    expect(lines.some((l) => l.endsWith("threshold compaction skipped: a rollover instead"))).toBe(true);
    expect(
      lines.some((l) => /failed/.test(l)),
      "a skip is logged as a skip, not a failure",
    ).toBe(false);
  });

  test("rollover off: a session from an earlier day does not roll over", async () => {
    const pi = shep("0");
    await pi.handlers.agent_end?.({}, idle({}, "2020-01-01T12:00:00"));
    await tick();
    expect(pi.sent).toHaveLength(0);
  });

  test("a session from an earlier day rolls over once; the session's own day does not", async () => {
    const pi = shep("1");
    pi.handlers.agent_end!({}, idle({}, new Date().toISOString()));
    await tick();
    expect(pi.sent).toHaveLength(0);
    pi.handlers.agent_end!({}, idle({}, "2020-01-01T12:00:00"));
    await tick();
    pi.handlers.agent_end!({}, idle({}, "2020-01-01T12:00:00"));
    await tick();
    expect(pi.sent).toHaveLength(1);
  });

  test("no rollover while Pi is busy; it starts once Pi is idle", async () => {
    const pi = shep("1");
    let busy = true;
    pi.handlers.agent_end!(
      {},
      { isIdle: () => !busy, sessionManager: { getHeader: () => ({ timestamp: "2020-01-01T12:00:00" }) } },
    );
    await tick();
    expect(pi.sent).toHaveLength(0);
    busy = false;
    await vi.waitFor(() => expect(pi.sent).toHaveLength(1), { timeout: 2000 });
  });
});
