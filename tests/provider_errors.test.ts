import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vite-plus/test";
import fallback from "../bstack/pi/extensions/fallback.ts";
import { classifyProviderError, providerErrorFromLog } from "../bstack/pi/extensions/provider-error.ts";

let dir: string;
beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "provider-errors-"));
  for (const key of Object.keys(process.env))
    if (/^(HC_|HERDR_|BERCAIL_|BEADS_|BD_)/.test(key) || key === "BASH_ENV") vi.stubEnv(key, undefined);
  for (const key of [
    "HOME",
    "XDG_CONFIG_HOME",
    "XDG_STATE_HOME",
    "XDG_DATA_HOME",
    "XDG_CACHE_HOME",
    "XDG_RUNTIME_DIR",
    "TMPDIR",
  ])
    vi.stubEnv(key, dir);
  mkdirSync(join(dir, "bin"));
  writeFileSync(
    join(dir, "bin/hc"),
    `#!/bin/sh\nprintf '%s\\n' "$*" >>'${dir}/hc.log'\n[ "$1" = get ] && printf '%s\\n' '{"parent":"lead","labels":{"bercail.issue":"example-237","bercail.issue_title":"Offline review"}}'\nexit 0\n`,
    { mode: 0o755 },
  );
  vi.stubEnv("PATH", `${dir}/bin:${process.env.PATH}`);
  vi.stubEnv("HC_TERMINAL_ID", "child");
  vi.stubEnv("BERCAIL_ROLE", "judge");
});
afterEach(() => {
  vi.unstubAllEnvs();
  rmSync(dir, { recursive: true, force: true });
});

// A host event fixture, not a model/provider. External notifications still execute the PATH fake.
function host(branch: any[]) {
  const handlers = new Map<string, Function>();
  const api: any = {
    on: (name: string, handler: Function) => handlers.set(name, handler),
    getThinkingLevel: () => "high",
    appendEntry: (customType: string, data: unknown) =>
      branch.push({ type: "custom", customType, data, id: `entry-${branch.length}` }),
    exec: async (name: string, args: string[]) => {
      const out = spawnSync(name, args, { encoding: "utf8" });
      return { code: out.status, stdout: out.stdout, stderr: out.stderr };
    },
  };
  const ctx: any = {
    model: { provider: "offline", id: "model" },
    ui: { notify: vi.fn(), setStatus: vi.fn() },
    sessionManager: { getBranch: () => branch, getSessionId: () => "session-237" },
  };
  fallback(api);
  return { emit: (name: string, event: unknown = {}) => handlers.get(name)?.(event, ctx), ctx };
}
const error = {
  role: "assistant",
  provider: "offline",
  model: "model",
  stopReason: "error",
  errorMessage: "content was flagged for possible cybersecurity risk; 429; Bearer secret-canary-237",
};

describe("provider failure episodes", () => {
  it("deduplicates parent notices across duplicate boundaries and restart while retaining distinct attempts", async () => {
    const branch: any[] = [{ type: "message", id: "user-1", message: { role: "user" } }];
    let fixture = host(branch);
    await fixture.emit("session_start");
    await fixture.emit("turn_start");
    await fixture.emit("turn_end", { message: error, messageEntryId: "attempt-1" });
    await fixture.emit("turn_end", { message: error, messageEntryId: "attempt-1" });
    await fixture.emit("turn_start");
    await fixture.emit("turn_end", { message: error, messageEntryId: "attempt-2" });
    await fixture.emit("agent_before_settle", { outcome: "error" });
    await fixture.emit("agent_before_settle", { outcome: "error" });
    fixture = host(branch);
    await fixture.emit("session_start");
    await fixture.emit("agent_before_settle", { outcome: "error" });
    const attempts = branch.filter((entry) => entry.customType === "bercail-provider-error");
    expect(attempts.map((entry) => entry.data.attempt_id)).toEqual(["attempt-1", "attempt-2"]);
    expect(new Set(attempts.map((entry) => entry.data.episode_id)).size).toBe(1);
    const notices = readFileSync(join(dir, "hc.log"), "utf8")
      .split("\n")
      .filter((line) => line.startsWith("send "));
    expect(notices).toHaveLength(1);
    expect(notices[0]).toContain("example-237: Offline review");
    expect(notices[0]).toContain("phase unknown; candidate unknown");
    expect(notices[0]).not.toMatch(/secret-canary|Do this part yourself/);
    expect(JSON.stringify(attempts)).not.toContain("secret-canary");
  });

  it("preserves a blocked episode through native success but gives a distinct explicit user entry its own episode", async () => {
    const branch: any[] = [{ type: "message", id: "user-1", message: { role: "user" } }];
    const fixture = host(branch);
    await fixture.emit("session_start");
    await fixture.emit("turn_end", { message: error, messageEntryId: "attempt-1" });
    await fixture.emit("turn_start");
    await fixture.emit("turn_end", {
      message: { ...error, stopReason: "stop", errorMessage: undefined },
      messageEntryId: "success-1",
    });
    expect(await fixture.emit("agent_before_settle", { outcome: "completed" })).toEqual({ continue: false });
    branch.push({ type: "message", id: "user-2", message: { role: "user" } });
    await fixture.emit("message_start", { message: { role: "user" } });
    await fixture.emit("turn_end", { message: error, messageEntryId: "attempt-2" });
    await fixture.emit("agent_before_settle", { outcome: "error" });
    const attempts = branch.filter((entry) => entry.customType === "bercail-provider-error");
    expect(new Set(attempts.map((entry) => entry.data.episode_id)).size).toBe(2);
    expect(
      readFileSync(join(dir, "hc.log"), "utf8")
        .split("\n")
        .filter((line) => line.startsWith("send ")),
    ).toHaveLength(2);
  });
});

it.each([
  ["content was flagged for possible cybersecurity risk; 401; quota exceeded", 401, "provider_safety_block"],
  ["401 authentication expired; rate_limit_error", 401, "auth_expired_or_denied"],
  ["invalid rate_limit configuration", 200, "unknown_provider_error"],
  ["opaque failure", 200, "unknown_provider_error"],
  ["429 rate_limit_error", 429, "usage_limit"],
  ["network error; 500", 500, "transient_transport"],
  ["model_refusal", 200, "model_refusal"],
])("classifies failed message %s without guessing quota", (message, status, reason) => {
  expect(classifyProviderError({ role: "assistant", stopReason: "error", errorMessage: message }, { status })).toBe(
    reason,
  );
});

it("selects final assistant for recovered quota, but never erases an earlier safety block", () => {
  const line = (message: unknown) => JSON.stringify({ type: "message_end", message });
  const success = line({ role: "assistant", stopReason: "stop" });
  expect(
    providerErrorFromLog(`${line({ ...error, errorMessage: "429 rate_limit_error" })}\n${success}`),
  ).toBeUndefined();
  expect(providerErrorFromLog(`${line(error)}\n${success}`)?.reason).toBe("provider_safety_block");
});
