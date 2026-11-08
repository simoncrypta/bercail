// Real Pi, offline provider: a bash tool call for git push --force must be blocked.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../", import.meta.url));
const pi = process.env.PI_GUARD_BIN || "pi";
const dir = mkdtempSync(join(tmpdir(), "pi-guard-"));
try {
  mkdirSync(join(dir, "agent"), { recursive: true });
  writeFileSync(join(dir, "agent/settings.json"), JSON.stringify({ retry: { enabled: false }, compaction: { enabled: false } }));
  const env = { ...process.env, HOME: dir, PI_CODING_AGENT_DIR: join(dir, "agent"), PI_OFFLINE: "1" };
  delete env.BERCAIL_ROLE;
  delete env.HC_TERMINAL_ID;
  const args = [
    "--offline", "--no-extensions", "--no-skills", "--no-prompt-templates", "--no-context-files", "--no-mcp",
    "--mode", "json", "-p",
    "-e", resolve(root, "bstack/pi/extensions/guard.ts"),
    "-e", resolve(root, "tests/pi_guard_provider.ts"),
    "--model", "fake-guard/model",
    "Push the branch.",
  ];
  const result = spawnSync(pi, args, { env, cwd: dir, encoding: "utf8", timeout: 30000 });
  assert.equal(result.error, undefined, String(result.error));
  assert.doesNotMatch(result.stderr, /Failed to load extension/i, result.stderr);
  assert.match(result.stdout, /Force-push is blocked/, `stdout: ${result.stdout}\nstderr: ${result.stderr}`);
  assert.doesNotMatch(result.stdout, /No configured push destination|Everything up-to-date/, "the push must not run");
  console.log("PASS: real Pi blocked git push --force");
} catch (error) {
  console.error(`Artifacts: ${dir}`);
  throw error;
}
rmSync(dir, { recursive: true, force: true });
