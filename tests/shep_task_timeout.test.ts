// shep task dispatch on a busy machine: bd gets more time as the load per core
// grows, and a bd call that still runs out says to retry the identical request.
import { execFileSync } from "node:child_process";
import { chmodSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, expect, test, vi } from "vite-plus/test";
import { patience, taskCommand } from "../lib/shep-task.ts";

// Which bd call runs out of time: "before" it runs, or "after" it wrote.
const slow = vi.hoisted(() => ({ when: (_args: string[]): "before" | "after" | null => null }));
vi.mock("node:child_process", async (importOriginal) => {
  const actual = await importOriginal<typeof import("node:child_process")>();
  return {
    ...actual,
    execFileSync: (command: string, args: string[], options: any) => {
      const when = command === process.env.BD_BIN ? slow.when(args) : null;
      if (when === "after") actual.execFileSync(command, args, options);
      if (when) throw Object.assign(new Error("spawnSync bd ETIMEDOUT"), { code: "ETIMEDOUT" });
      return actual.execFileSync(command, args, options);
    },
  };
});

let dir = "";
let repo = "";
const request = () => ({
  repo,
  issue: "app-1",
  target: "task:app-1",
  requestId: "r1",
  message: "Fix it",
  branch: "fix",
});
const issue = () => JSON.parse(readFileSync(join(dir, "app-1.json"), "utf8"));
const script = (name: string, body: string) => {
  writeFileSync(join(dir, name), `#!/usr/bin/env bash\n${body}\n`);
  chmodSync(join(dir, name), 0o755);
  return join(dir, name);
};

// A repo, its issue in a file that a bd stand-in reads and writes, no live
// desks, and a handoff-spawn that only says it ran.
beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "task-timeout-"));
  repo = join(dir, "repo");
  execFileSync("git", ["init", "-q", repo]);
  writeFileSync(join(dir, "app-1.json"), JSON.stringify({ id: "app-1", title: "Repair login", status: "open" }));
  vi.stubEnv("TASK_DIR", dir);
  vi.stubEnv(
    "BD_BIN",
    script(
      "bd",
      `file="$TASK_DIR/$2.json"
case "$1" in
  show) cat "$file" ;;
  list) jq -s . "$TASK_DIR"/*.json ;;
  update) shift 2
    while (($#)); do
      case "$1" in
        --metadata) jq --slurpfile m "\${2#@}" '.metadata = ((.metadata // {}) + $m[0])' "$file" >"$file.new"; shift 2 ;;
        --status) jq --arg s "$2" '.status = $s' "$file" >"$file.new"; shift 2 ;;
        *) shift; continue ;;
      esac
      mv "$file.new" "$file"
    done
    cat "$file" ;;
esac`,
    ),
  );
  vi.stubEnv("HC_BIN", script("hc", `echo '{"terminals":[]}'`));
  vi.stubEnv("BERCAIL_HANDOFF_SPAWN", script("spawn", `touch "$TASK_DIR/spawned"; exit 1`));
});
afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
  slow.when = () => null;
});

test("bd's time limit grows with the load per core, from 10 seconds to a minute", () => {
  expect(patience(0.5, 16)).toBe(10_000);
  expect(patience(32, 16)).toBe(20_000);
  expect(patience(300, 16)).toBe(60_000);
});

test("a bd call that runs out of time says to retry the identical request, and frees the dispatch lock", () => {
  slow.when = (args) => (args[0] === "show" ? "before" : null);
  expect(() => taskCommand("dispatch", request())).toThrow(
    /^bd show did not answer in [0-9.]+s \(load [0-9.]+\); this request may be partly recorded, so retry the identical request \(the same JSON\), never a reworded one$/,
  );
  expect(existsSync(join(repo, ".git/bercail-task.lock"))).toBe(false);
});

test("a reservation bd records and then times out on is left UNKNOWN, so its retry starts the desk", () => {
  // The first reservation and the retry's reservation each time out once bd wrote them.
  let updates = 0;
  slow.when = (args) => (args[0] === "update" && [1, 3].includes(++updates) ? "after" : null);
  expect(() => taskCommand("dispatch", request())).toThrow(/^bd update did not answer/);
  expect(issue().metadata.bercail_task.creation).toMatchObject({ id: "r1", status: "unknown" });
  expect(existsSync(join(dir, "spawned"))).toBe(false);
  expect(() => taskCommand("dispatch", request())).toThrow(/^bd update did not answer/);
  expect(issue().metadata.bercail_task.creation).toMatchObject({ id: "r1", status: "unknown" });
  expect(existsSync(join(dir, "spawned"))).toBe(false);
  // The next retry finds no desk and no worktree, so it runs handoff-spawn,
  // which fails here once it has said so.
  expect(() => taskCommand("dispatch", request())).toThrow(/spawn/);
  expect(existsSync(join(dir, "spawned"))).toBe(true);
});
