// The background Shep's extension with no Pi: it pins the brief it was started
// with, and its trail wait runs against a fake entire on PATH.
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, expect, test, vi } from "vite-plus/test";
import register from "../shep/pi/background.ts";

const HEAD = "81fdc496d3fbdac99d2703b5fbd191e49de4dfc0";
let dir: string;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "shep-bg-"));
  vi.stubEnv("BERCAIL_ISSUE", "bc-1");
});

afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllEnvs();
  rmSync(dir, { recursive: true, force: true });
});

// Registers the extension on a fake Pi: its handlers, tools and pinned entries.
function start() {
  const handlers: Record<string, (event?: any) => any> = {};
  const tools: Record<string, any> = {};
  const entries: [string, any][] = [];
  register({
    registerTool: (tool: any) => (tools[tool.name] = tool),
    on: (name: string, fn: () => void) => (handlers[name] = fn),
    appendEntry: (type: string, data: unknown) => entries.push([type, data]),
  } as any);
  return { handlers, tools, entries };
}

// `entire trail show --json` for change lesentiel/31: its head, whether it is
// mergeable, and its one blocking gate's status.
function show(head: string, mergeable: boolean, rwx: string) {
  return JSON.stringify({
    number: 32,
    changes: [
      {
        repository: "lesentiel",
        number: 31,
        status: "open",
        current: true,
        mergeability: {
          head_sha: head,
          mergeable,
          gates: [
            { gate_key: "rwx", blocking: true, status: rwx },
            { gate_key: "up_to_date", blocking: false, status: "skipped" },
          ],
        },
      },
    ],
  });
}

// A fake entire on PATH that logs each argv and answers the Nth `trail show`
// with the Nth reply, then the last one again.
function fakeEntire(...replies: string[]) {
  const bin = join(dir, "bin");
  mkdirSync(bin);
  replies.forEach((reply, i) => writeFileSync(join(dir, `reply-${i + 1}`), reply));
  writeFileSync(
    join(bin, "entire"),
    `#!/usr/bin/env bash
printf '%s\\n' "$*" >>"${dir}/entire.log"
n=$(wc -l <"${dir}/entire.log")
f="${dir}/reply-$n"; [[ -f "$f" ]] || f="${dir}/reply-${replies.length}"
cat "$f"
`,
  );
  chmodSync(join(bin, "entire"), 0o755);
  vi.stubEnv("PATH", `${bin}:${process.env.PATH}`);
  return () => (existsSync(join(dir, "entire.log")) ? readFileSync(join(dir, "entire.log"), "utf8") : "");
}

// Runs one shep_wait call to its end, moving the poll's clock on whenever it pauses.
async function wait(args: Record<string, string>) {
  vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
  let settled = false;
  const run = start().tools.shep_wait.execute("call-1", args, undefined);
  run.then(
    () => (settled = true),
    () => (settled = true),
  );
  while (!settled) {
    await new Promise((resolve) => setImmediate(resolve));
    await vi.advanceTimersByTimeAsync(30000);
  }
  return run;
}

test("session_start pins the brief named by BERCAIL_BG_BRIEF", () => {
  const brief = join(dir, "BACKGROUND.md");
  writeFileSync(brief, "Wait and report.\n");
  vi.stubEnv("BERCAIL_BG_BRIEF", brief);
  const { handlers, entries } = start();
  handlers.session_start();
  expect(entries).toEqual([["bercail-background-profile", { generation: "shep-bg-2", brief: "Wait and report.\n" }]]);
});

test("session_start without BERCAIL_BG_BRIEF names the variable and how to start the worker", () => {
  vi.stubEnv("BERCAIL_BG_BRIEF", "");
  const { handlers, entries } = start();
  expect(() => handlers.session_start()).toThrow(
    "BERCAIL_BG_BRIEF is unset; start the background Shep with bercail shep bg, which passes it",
  );
  expect(entries).toEqual([]);
});

test("the worker gets bash and shep_wait, and no edit, write or agent tool", () => {
  const { handlers, tools } = start();
  expect(Object.keys(tools)).toEqual(["shep_wait"]);
  for (const toolName of ["bash", "read", "shep_wait"]) expect(handlers.tool_call({ toolName })).toBeUndefined();
  for (const toolName of ["write", "edit", "spawn_agent"]) expect(handlers.tool_call({ toolName }).block).toBe(true);
});

// bercail-qni9: wait for a trail's gates on the expected head, then report;
// the merge is Shep's, after the person's yes.
test("a trail wait reads the gates until they pass on the expected head, and never merges", async () => {
  const unknown = JSON.stringify({
    changes: [{ repository: "lesentiel", number: 31, status: "open", mergeability: null }],
  });
  const log = fakeEntire(unknown, show(HEAD, false, "pending"), show(HEAD, true, "passed"));
  const result = await wait({ kind: "trail", target: "lesentiel/31", head: HEAD.slice(0, 12) });
  expect(result.content[0].text).toBe(
    `ready: lesentiel/31 at ${HEAD}: every blocking gate passed. Report it on the issue and stop; Shep runs the follow-up, such as the merge.`,
  );
  expect(log()).toBe("trail show lesentiel/31 --json\n".repeat(3));
});

test("a trail wait stops when the head moves, even with the gates passing", async () => {
  const log = fakeEntire(show(HEAD, false, "pending"), show("0123456789abcdef", true, "passed"));
  await expect(wait({ kind: "trail", target: "32", head: HEAD })).rejects.toThrow(
    `moved: lesentiel/31 is at 0123456789abcdef, not ${HEAD}. Report it on the issue and stop.`,
  );
  expect(log()).toBe("trail show 32 --json\n".repeat(2));
});

test("a trail wait stops when a blocking gate fails", async () => {
  fakeEntire(show(HEAD, false, "failed"));
  await expect(wait({ kind: "trail", target: "32", head: HEAD })).rejects.toThrow(
    `failed: lesentiel/31 at ${HEAD}: rwx failed. Report it on the issue and stop.`,
  );
});

test("a cancelled trail wait stops its entire call and is not ready", async () => {
  const bin = join(dir, "bin");
  mkdirSync(bin);
  writeFileSync(join(bin, "entire"), `#!/usr/bin/env bash\ntouch "${dir}/started"\nexec sleep 60\n`);
  chmodSync(join(bin, "entire"), 0o755);
  vi.stubEnv("PATH", `${bin}:${process.env.PATH}`);
  const abort = new AbortController();
  const run = start().tools.shep_wait.execute("call-1", { kind: "trail", target: "32", head: HEAD }, abort.signal);
  await vi.waitFor(() => expect(existsSync(join(dir, "started"))).toBe(true));
  abort.abort();
  await expect(run).rejects.toThrow("wait cancelled; outcome incomplete");
});

test("a trail wait with no head, or a target that is not a trail, runs nothing", async () => {
  const log = fakeEntire(show(HEAD, true, "passed"));
  for (const args of [
    { kind: "trail", target: "32" },
    { kind: "trail", target: "32", head: "main" },
    { kind: "trail", target: "--force", head: HEAD },
  ])
    await expect(start().tools.shep_wait.execute("call-1", args, undefined)).rejects.toThrow(
      "a trail wait needs target <n> or <repo>/<n>, and head: the commit its gates must pass on",
    );
  expect(log()).toBe("");
});
