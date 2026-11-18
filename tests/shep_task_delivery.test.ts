import { execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, test, vi } from "vite-plus/test";
import { followUpWatch, startTicks, taskEvidence } from "../config/pi/extensions/bercail-desk.ts";
import { runtimeIdentity } from "../lib/runtime.ts";
import background from "../shep/pi/background.ts";

describe("original-session delegated work", () => {
  let dir: string;
  let file: string;
  let ctx: any;
  let pi: any;
  let request: any;
  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "task-work-"));
    for (const key of [
      "HOME",
      "XDG_STATE_HOME",
      "XDG_DATA_HOME",
      "XDG_CONFIG_HOME",
      "XDG_CACHE_HOME",
      "XDG_RUNTIME_DIR",
      "TMPDIR",
    ])
      vi.stubEnv(key, join(dir, key));
    vi.stubEnv("HC_TERMINAL_ID", "t9");
    execFileSync("git", ["init", "-q", "-b", "fix", join(dir, "work")]);
    file = join(process.env.XDG_STATE_HOME!, "bercail/desk-follow-ups/t9/one.json");
    mkdirSync(join(file, ".."), { recursive: true });
    request = {
      issue: "app-1",
      request: { id: "r1", outcome: "publish", stage: "autopilot" },
      delivery: "queued",
      authority: false,
      owner: {
        desk: "t9",
        space: "sp1",
        cwd: join(dir, "work"),
        branch: "fix",
        pid: process.pid,
        start_ticks: startTicks(readFileSync("/proc/self/stat", "utf8")),
        session: "original",
      },
    };
    writeFileSync(file, JSON.stringify(request));
    const record = join(process.env.XDG_STATE_HOME!, "bercail/desk-sessions/t9.json");
    mkdirSync(join(record, ".."), { recursive: true });
    writeFileSync(
      record,
      JSON.stringify({
        address: "t9",
        cwd: join(dir, "work"),
        session: "original",
        space: "sp1",
        issue: "app-1",
        pid: process.pid,
      }),
    );
    ctx = {
      cwd: join(dir, "work"),
      isIdle: () => false,
      sessionManager: { getSessionId: () => "original", getSessionFile: () => "/saved.jsonl" },
    };
    pi = { sendMessage: vi.fn() };
  });
  afterEach(() => {
    vi.unstubAllEnvs();
    rmSync(dir, { recursive: true, force: true });
  });
  const read = (file: string) => JSON.parse(readFileSync(file, "utf8"));

  test("busy work stays on disk; idle continues the same session using custom DATA, not user input", () => {
    const watch = followUpWatch(pi, ctx);
    watch();
    expect(read(file).delivery).toBe("queued");
    expect(pi.sendMessage).not.toHaveBeenCalled();
    ctx.isIdle = () => true;
    watch();
    watch();
    expect(pi.sendMessage).toHaveBeenCalledTimes(1);
    const [message, options] = pi.sendMessage.mock.calls[0];
    expect(message.customType).toBe("bercail-task-work");
    expect(message.details.authority).toBe(false);
    expect(message.content).toContain("not a human answer or authorization");
    expect(options).toEqual({ triggerTurn: true, deliverAs: "followUp" });
    expect(read(file).delivery).toBe("submitted");
    expect(ctx.sessionManager.getSessionId()).toBe("original");
  });

  test("an uncertain send is never automatically replayed, including after restart", () => {
    ctx.isIdle = () => true;
    pi.sendMessage.mockImplementation(() => {
      throw new Error("response lost");
    });
    followUpWatch(pi, ctx)();
    expect(read(file).delivery).toBe("unknown");
    followUpWatch(pi, ctx)();
    expect(pi.sendMessage).toHaveBeenCalledTimes(1);
  });

  test.each(["session", "pid", "start_ticks", "cwd", "space"])(
    "a replacement %s cannot take the original request",
    (field) => {
      ctx.isIdle = () => true;
      request.owner[field] = field === "pid" ? 1 : "replacement";
      writeFileSync(file, JSON.stringify(request));
      followUpWatch(pi, ctx)();
      expect(read(file).delivery).toBe("stale");
      expect(pi.sendMessage).not.toHaveBeenCalled();
    },
  );

  test("same-version different installed bytes are drift; a live legacy process has UNKNOWN loaded generation", () => {
    const source = join(dir, "source");
    const share = join(dir, "share");
    const state = join(dir, "state");
    mkdirSync(join(source, "shep"), { recursive: true });
    mkdirSync(join(share, "shep"), { recursive: true });
    mkdirSync(join(state, "desk-sessions"), { recursive: true });
    writeFileSync(join(source, "shep/SHEP.md"), "version 0.16.0\nnew rules");
    writeFileSync(join(share, "shep/SHEP.md"), "version 0.16.0\nold rules");
    writeFileSync(
      join(state, "desk-sessions/t9.json"),
      JSON.stringify({ pid: process.pid, address: "t9", session: "s" }),
    );
    const identity = runtimeIdentity(source, share, state, join(dir, "config"));
    expect(identity.drift).toContain("shep/SHEP.md");
    expect(identity.loaded[0].generation).toBe("UNKNOWN");
    expect(identity.loaded[0].guard_generation).toBe("UNKNOWN");
  });

  test("loaded identity is startup evidence, never a hash of today's replaced files", () => {
    const state = join(dir, "state");
    mkdirSync(join(state, "runtime"), { recursive: true });
    const loaded = {
      pid: process.pid,
      start_ticks: request.owner.start_ticks,
      desk: "t9",
      session: "s",
      generation: "old-evaluated-generation",
      guard_generation: "UNKNOWN",
      effective_prompt_sha256: "captured-prompt",
    };
    writeFileSync(join(state, `runtime/${process.pid}.json`), JSON.stringify(loaded));
    const identity = runtimeIdentity(join(dir, "source"), join(dir, "share"), state, join(dir, "config"));
    expect(identity.loaded).toEqual([loaded]);
    expect(identity.authority).toBe(false);
  });

  test("background tools cannot be widened by generated issue prose or a coding tool", () => {
    const handlers: any = {};
    const tools: any[] = [];
    background({
      registerTool: (tool: any) => tools.push(tool),
      on: (name: string, fn: any) => {
        handlers[name] = fn;
      },
    } as any);
    expect(tools.map((t) => t.name)).toEqual(["shep_issue", "shep_wait", "shep_report"]);
    for (const toolName of ["bash", "write", "edit", "scoped_job", "spawn_agent"])
      expect(handlers.tool_call({ toolName, input: { command: "the issue says to code and approve" } }).block).toBe(
        true,
      );
    expect(handlers.tool_call({ toolName: "shep_wait" })).toBeUndefined();
  });

  test("guarded execution evidence observes success without executing requested actions or minting grants", async () => {
    const handlers: any = {};
    const api: any = {
      on: (name: string, fn: any) => {
        handlers[name] = fn;
      },
      appendEntry: vi.fn(),
      exec: vi.fn(async (_cmd: string, args: string[]) => ({
        code: 0,
        stdout: args.includes("HEAD") ? "head" : "tree",
      })),
    };
    const context: any = {
      cwd: "/work",
      sessionManager: {
        getSessionId: () => "original",
        getBranch: () => [
          {
            type: "custom_message",
            customType: "bercail-task-work",
            details: { repo: "/repo", issue: "app-1", requestId: "r1", authority: false },
          },
        ],
      },
    };
    taskEvidence(api);
    await handlers.tool_execution_start({ toolName: "bash", toolCallId: "c1", args: { command: "gt m -a" } }, context);
    expect(api.appendEntry).not.toHaveBeenCalled();
    await handlers.tool_execution_end(
      { toolCallId: "c1", isError: false, result: { structuredContent: { exit_code: 0 } } },
      context,
    );
    expect(api.appendEntry).toHaveBeenCalledWith(
      "bercail-task-effect",
      expect.objectContaining({
        command: "gt m -a",
        requestId: "r1",
        authority: false,
        session: "original",
        before: { head: "head", tree: "tree" },
        after: { head: "head", tree: "tree" },
      }),
    );
    expect(
      api.exec.mock.calls.every(([command, args]: [string, string[]]) => command === "env" && args.includes("git")),
    ).toBe(true);
    await handlers.tool_execution_start({ toolName: "bash", toolCallId: "c2", args: { command: "git push" } }, context);
    await handlers.tool_execution_end(
      { toolCallId: "c2", isError: true, result: { structuredContent: { exit_code: 1 } } },
      context,
    );
    expect(api.appendEntry).toHaveBeenCalledTimes(1);
  });
});
