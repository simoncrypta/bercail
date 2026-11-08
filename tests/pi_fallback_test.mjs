import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, copyFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../", import.meta.url));
const pi = process.env.PI_FALLBACK_BIN || "pi";
const version = spawnSync(pi, ["--version"], { encoding: "utf8" }).stdout.trim();
const [major, minor] = version.split(".").map(Number);
assert.ok(major > 1 || (major === 1 && minor >= 5), `tests require real Pi >=1.5 (found ${version})`);
const tmp = mkdtempSync(join(tmpdir(), "pi-fallback-"));
try {
  for (const scenario of ["429", "401", "403", "400", "500", "context", "usage", "bridge", "bridge-auth", "bridge-success", "bridge-warning", "retry-success", "stale", "abort", "missing-auth", "bridge-missing-auth", "bridge-metered", "bridge-subscription", "bridge-oauth-token", "exhaustion", "configured-order", "tool-no-loop", "user-reset", "followup-reset", "new-user-reset", "empty-order", "default-order", "tui-status", "status-only-400", "status-only-401", "status-only-403"]) {
    const dir = join(tmp, scenario);
    mkdirSync(join(dir, "profile/extensions"), { recursive: true });
    mkdirSync(join(dir, "agent"), { recursive: true });
    mkdirSync(join(dir, "bin"));
    copyFileSync(join(root, "bstack/pi/extensions/fallback.ts"), join(dir, "profile/extensions/fallback.ts"));
    writeFileSync(join(dir, "profile/models"), `claude=${["tool-no-loop", "user-reset", "followup-reset", "new-user-reset"].includes(scenario) ? "fake-a" : "fake-c"}/model\ngpt=${scenario === "missing-auth" ? "fake-unlogged" : scenario.startsWith("bridge-") && ["bridge-missing-auth", "bridge-metered", "bridge-subscription", "bridge-oauth-token"].includes(scenario) ? "claude-bridge" : "fake-b"}/model#high\ngrok=fake-c/model:medium\n`);
    // Most cases limit candidates to GPT/Grok; default-order is covered separately below.
    if (scenario !== "default-order") writeFileSync(join(dir, "profile/fallback"), scenario === "empty-order" ? "" : ["tool-no-loop", "user-reset", "followup-reset", "new-user-reset"].includes(scenario) ? "claude\ngpt\ngrok\n" : "gpt\ngrok\n");
    writeFileSync(join(dir, "agent/settings.json"), JSON.stringify({ retry: { enabled: true, maxRetries: 2, baseDelayMs: 5 }, compaction: { enabled: false } }));
    const auth = scenario === "bridge-metered" ? { loggedIn: true, authMethod: "api_key_helper" } : scenario === "bridge-subscription" ? { loggedIn: true, authMethod: "claude.ai" } : scenario === "bridge-oauth-token" ? { loggedIn: true, authMethod: "oauth_token" } : { loggedIn: false };
    writeFileSync(join(dir, "bin/claude"), `#!/bin/sh\nprintf '%s\\n' '${JSON.stringify(auth)}'\n`, { mode: 0o755 });
    const env = { ...process.env, HOME: dir, PI_CODING_AGENT_DIR: join(dir, "agent"), PI_FALLBACK_CASE: scenario, PI_FALLBACK_LOG: join(dir, "events.jsonl"), PI_OFFLINE: "1", PATH: `${dir}/bin:${process.env.PATH}` };
    delete env.HC_TERMINAL_ID;
    delete env.PI_FALLBACK_MISSING_KEY;
    const args = ["--offline", "--no-extensions", "--no-skills", "--no-prompt-templates", "--no-context-files", "--no-builtin-tools", "--no-mcp", "--mode", "json", "--session", join(dir, "session.jsonl"), "-e", join(dir, "profile/extensions/fallback.ts"), "-e", resolve(root, "tests/pi_fallback_provider.ts"), "--model", "fake-a/model", "-p", "Finish the original request.", ...(scenario === "new-user-reset" ? ["Second real user turn"] : [])];
    let command = pi;
    if (scenario === "tui-status") {
      command = "script";
      env.HC_TERMINAL_ID = "t-offline-test";
      env.PI_PROGRAM_STATUS = "1";
      env.PI_FALLBACK_TUI_SHUTDOWN = "1";
      args.splice(args.indexOf("--mode"), 2);
      args.splice(args.indexOf("-p"), 1);
      const quote = s => `'${s.replaceAll("'", "'\\''")}'`;
      const shellCommand = [pi, ...args].map(quote).join(" ");
      args.splice(0, args.length, "-qefc", shellCommand, "/dev/null");
    }
    const result = spawnSync(command, args, { env, cwd: dir, encoding: "utf8", timeout: 30000, maxBuffer: 8 * 1024 * 1024 });
    writeFileSync(join(dir, "stdout.jsonl"), result.stdout || "");
    writeFileSync(join(dir, "stderr.log"), result.stderr || "");
    assert.equal(result.error, undefined, `${scenario}: ${result.error}`);
    assert.doesNotMatch(result.stderr, /Failed to load extension|extension.*error|without runnable model context/i, `${scenario}: ${result.stderr}`);
    const events = readFileSync(join(dir, "events.jsonl"), "utf8").trim().split("\n").map(JSON.parse);
    const requests = events.filter(e => e.type === "request");
    const switches = events.filter(e => e.event === "model_select");
    const session = readFileSync(join(dir, "session.jsonl"), "utf8").trim().split("\n").map(JSON.parse);
    const noSwitch = ["401", "403", "400", "500", "context", "bridge-auth", "bridge-success", "bridge-warning", "retry-success", "stale", "abort", "empty-order", "status-only-400", "status-only-401", "status-only-403"].includes(scenario);
    if (noSwitch) assert.equal(switches.length, 0, `${scenario}: must not switch`);
    else {
      assert.ok(switches.length > 0, `${scenario}: must switch; ${result.stderr}`);
      const target = ["missing-auth", "bridge-missing-auth", "bridge-metered", "default-order"].includes(scenario) ? "fake-c" : ["bridge-subscription", "bridge-oauth-token"].includes(scenario) ? "claude-bridge" : "fake-b";
      assert.equal(switches[0].model, target, scenario);
      if (scenario !== "default-order") assert.equal(requests.find(e => e.provider === target)?.reasoning, target === "fake-c" ? "medium" : "high", `${scenario}: configured #effort/:effort`);
      assert.ok(session.some(e => e.type === "model_change" && e.provider === target), `${scenario}: model persisted`);
      assert.ok(session.some(e => e.type === "custom_message" && e.customType === "bercail-fallback" && e.display), `${scenario}: visible session note`);
      if (scenario !== "exhaustion") assert.match(result.stdout, /PI_FALLBACK_OK/, `${scenario}: turn finishes`);
    }
    if (["429", "stale", "retry-success", "exhaustion"].includes(scenario)) {
      assert.equal(requests.filter(e => e.provider === "fake-a").length, scenario === "retry-success" ? 2 : scenario === "stale" ? 2 : 3, `${scenario}: native retry budget`);
    }
    if (scenario === "tui-status") {
      const records = [...result.stdout.matchAll(/\x1b\]7501;([^\x07\x1b]+)(?:\x07|\x1b\\)/g)].map(m => m[1]);
      assert.equal(records.filter(r => r.includes("id=bercail-fallback")).length, 0, "Pi owns program status");
      const done = records.find(r => r.startsWith("state=done:app=pi:msg="));
      assert.ok(done, `Pi done status missing: ${records.join(" | ")}`);
      assert.match(Buffer.from(done.split("msg=")[1], "base64").toString(), /fallback: fake-b\/model/, "session name carries the switch");
      assert.match(result.stdout, /fallback: fake-b\/model/, "real Pi footer status");
    }
    if (scenario === "429") {
      const firstSwitch = events.findIndex(e => e.event === "model_select");
      assert.equal(events.slice(0, firstSwitch).filter(e => e.type === "request").length, 3, "switch only after retry exhaustion");
      assert.ok(requests[2].at - requests[0].at >= 10, "Pi retry backoff precedes fallback");
      const next = requests.find(e => e.provider === "fake-b");
      assert.ok(next.messages.some(m => m.role === "user" && JSON.stringify(m.content).includes("Finish the original request")), "original request preserved");
      assert.equal(next.messages.some(m => m.role === "assistant" && m.stopReason === "error"), false, "failed assistant omitted");
      assert.equal(events.filter(e => e.event === "before_agent_start").length, 1, "same user run");
      assert.equal(events.filter(e => e.event === "agent_settled").length, 1, "settles only after continuation");
    }
    if (scenario === "exhaustion") {
      assert.equal(requests.length, 9, "each configured provider attempted once with native retries");
      assert.ok(session.some(e => e.type === "custom" && e.customType === "bercail-fallback-error" && /fallback exhausted/.test(e.data?.text ?? "")), "clear persisted exhaustion error");
      assert.equal(session.some(e => e.type === "custom_message" && e.customType === "bercail-fallback-error"), false, "exhaustion is not a later user turn");
    }
    if (scenario === "empty-order") assert.ok(session.some(e => e.type === "custom" && e.customType === "bercail-fallback-error" && /no candidates/.test(e.data?.text ?? "")), "empty order stops clearly");
    if (scenario === "tool-no-loop") {
      assert.deepEqual(switches.map(e => e.model), ["fake-b", "fake-c"], "fallback attempts survive tool turns");
      assert.equal(events.filter(e => e.type === "tool").length, 1, "real tool executed");
    }
    if (["user-reset", "followup-reset", "new-user-reset"].includes(scenario)) {
      assert.deepEqual(switches.map(e => e.model), ["fake-b", "fake-a"], "new user message resets attempted models");
      assert.equal(events.filter(e => e.event === "message_start" && e.role === "user").length, 2, "two real user messages");
      assert.equal(events.filter(e => e.event === "before_agent_start").length, scenario === "new-user-reset" ? 2 : 1, "queued messages reset without before_agent_start");
    }
    console.log(`PASS: real Pi ${scenario} (${requests.length} requests, ${switches.length} switches)`);
  }
} catch (error) {
  console.error(`Artifacts: ${tmp}`);
  throw error;
}
rmSync(tmp, { recursive: true, force: true });
