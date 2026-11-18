// Every TLC transport edge replays on followUpWatch. This does not model task
// ownership resolution or external effects; those have isolated CLI regressions.
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, expect, test, vi } from "vite-plus/test";
import { followUpWatch, startTicks } from "../config/pi/extensions/bercail-desk.ts";

const root = join(import.meta.dirname, "..");
const spec = join(import.meta.dirname, "statechart/shep-task");
const implementation = join(root, "config/pi/extensions/bercail-desk.ts");
const graph = JSON.parse(readFileSync(join(spec, "graph.json"), "utf8")) as {
  states: { start: boolean; vars: { phase: string; bound: boolean; attempts: number } }[];
  steps: [number, string, number][];
};
const paths = new Map<number, number[]>(graph.states.flatMap((s, i) => (s.start ? [[i, []]] : [])));
const queue = [...paths.keys()];
while (queue.length) {
  const at = queue.shift()!;
  graph.steps.forEach(([from, , to], k) => {
    if (from !== at || paths.has(to)) return;
    paths.set(to, [...paths.get(at)!, k]);
    queue.push(to);
  });
}
let dir: string;
beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "task-model-"));
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
});
afterEach(() => {
  vi.unstubAllEnvs();
  rmSync(dir, { recursive: true, force: true });
});

function everyEdge(watch: typeof followUpWatch): string[] {
  const mismatches: string[] = [];
  for (const [k, [from]] of graph.steps.entries()) {
    const state = join(process.env.XDG_STATE_HOME!, "bercail");
    rmSync(state, { recursive: true, force: true });
    const file = join(state, "desk-follow-ups/t9/0000000000-request.json");
    mkdirSync(join(file, ".."), { recursive: true });
    mkdirSync(join(state, "desk-sessions"));
    writeFileSync(
      join(state, "desk-sessions/t9.json"),
      JSON.stringify({
        address: "t9",
        cwd: join(dir, "work"),
        session: "original",
        space: "sp1",
        issue: "app-1",
        pid: process.pid,
      }),
    );
    const intent = join(state, "intent.json");
    writeFileSync(intent, '{"outcome":"publish","status":"outstanding"}');
    let session = "original";
    let attempts = 0;
    let uncertain = false;
    const ctx: any = {
      cwd: join(dir, "work"),
      isIdle: () => true,
      sessionManager: { getSessionId: () => session, getSessionFile: () => "/saved" },
    };
    const api: any = {
      sendMessage: (message: any) => {
        expect(JSON.parse(readFileSync(file, "utf8")).delivery).toBe("unknown");
        expect(message.customType).toBe("bercail-task-work");
        expect(message.details.authority).toBe(false);
        attempts++;
        if (uncertain) throw new Error("lost response");
      },
    };
    for (const edge of [...paths.get(from)!, k]) {
      const [, action, to] = graph.steps[edge];
      if (action === "Accept")
        writeFileSync(
          file,
          JSON.stringify({
            delivery: "queued",
            issue: "app-1",
            repo: "/repo",
            authority: false,
            request: { id: "r1" },
            owner: {
              desk: "t9",
              space: "sp1",
              pid: process.pid,
              start_ticks: startTicks(readFileSync("/proc/self/stat", "utf8")),
              cwd: join(dir, "work"),
              branch: "fix",
              session: "original",
            },
          }),
        );
      else if (action === "ChangeSession") session = "replacement";
      else {
        uncertain = action === "Uncertain";
        watch(api, ctx)();
      }
      const got = {
        phase: existsSync(file) ? JSON.parse(readFileSync(file, "utf8")).delivery : "idle",
        bound: session === "original",
        attempts,
      };
      const want = graph.states[to].vars;
      if (got.phase !== want.phase || got.bound !== want.bound || got.attempts !== want.attempts)
        mismatches.push(`edge ${edge} ${action}: model ${JSON.stringify(want)}, code ${JSON.stringify(got)}`);
      expect(readFileSync(intent, "utf8")).toBe('{"outcome":"publish","status":"outstanding"}');
    }
  }
  return mismatches;
}

test("the checked transport graph and code have not drifted", () => {
  const sums = readFileSync(join(spec, "sha256.txt"), "utf8").trim().split("\n");
  for (const line of sums) {
    const [hash, path] = line.split(/\s+/);
    expect(
      createHash("sha256")
        .update(readFileSync(join(root, path)))
        .digest("hex"),
      `rerun tests/statechart/shep-task/check.sh for ${path}`,
    ).toBe(hash);
  }
});
test("every edge in TLC's graph matches the real original-session consumer", () => {
  expect(everyEdge(followUpWatch)).toEqual([]);
});
test.each([
  ['request.delivery !== "queued"', '!["queued", "unknown"].includes(request.delivery)'],
  ["owner.session !== ctx.sessionManager.getSessionId()", "false"],
])("the replay rejects the planted bug: %s", async (before, after) => {
  const original = readFileSync(implementation, "utf8");
  expect(original.split(before)).toHaveLength(2);
  const code = stripTypeScriptTypes(original.replace(before, after));
  const plant = await import(`data:text/javascript;base64,${Buffer.from(code).toString("base64")}`);
  expect(everyEdge(plant.followUpWatch).length).toBeGreaterThan(0);
});
