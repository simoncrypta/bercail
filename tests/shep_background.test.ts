// The background Shep's session_start with no Pi: it pins the brief it was
// started with, and names the fix when the brief path never reached it.
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, expect, test, vi } from "vite-plus/test";
import register from "../shep/pi/background.ts";

let dir: string;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "shep-bg-"));
  vi.stubEnv("BERCAIL_ISSUE", "bc-1");
  vi.stubEnv("BERCAIL_BG_KIND", "wait");
});

afterEach(() => {
  vi.unstubAllEnvs();
  rmSync(dir, { recursive: true, force: true });
});

// Registers the extension on a fake Pi and returns its session_start handler and pinned entries.
function start() {
  const handlers: Record<string, () => void> = {};
  const entries: [string, any][] = [];
  register({
    registerTool: () => {},
    on: (name: string, fn: () => void) => (handlers[name] = fn),
    appendEntry: (type: string, data: unknown) => entries.push([type, data]),
  } as any);
  return { run: handlers.session_start, entries };
}

test("session_start pins the brief named by BERCAIL_BG_BRIEF", () => {
  const brief = join(dir, "BACKGROUND.md");
  writeFileSync(brief, "Assigned observation only.\n");
  vi.stubEnv("BERCAIL_BG_BRIEF", brief);
  const { run, entries } = start();
  run();
  expect(entries).toEqual([
    ["bercail-background-profile", { kind: "wait", generation: "wait-admin-1", brief: "Assigned observation only.\n" }],
  ]);
});

test("session_start without BERCAIL_BG_BRIEF names the variable and how to start the worker", () => {
  vi.stubEnv("BERCAIL_BG_BRIEF", "");
  const { run, entries } = start();
  expect(run).toThrow("BERCAIL_BG_BRIEF is unset; start the background Shep with bercail shep bg, which passes it");
  expect(entries).toEqual([]);
});
