// Real Pi with offline providers, no subscriptions or API requests: for each
// scenario, bstack's fallback extension switches models (or does not) after
// Pi's own retries, keeps the desk's thinking level, and logs what it did.
// Usage: PI_FALLBACK_BIN=PI node tests/pi_fallback_live.ts
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, copyFileSync, rmSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

type Event = {
  type?: string;
  event?: string;
  model?: string;
  id?: string;
  provider?: string;
  reasoning?: string;
  role?: string;
  userTurns?: number;
  at: number;
  messages: { role?: string; content?: unknown; stopReason?: string }[];
};
type SessionEntry = {
  type?: string;
  provider?: string;
  thinkingLevel?: string;
  customType?: string;
  display?: unknown;
  content?: unknown;
  data?: { text?: string };
  details?: { dead?: Record<string, unknown>; skipped?: string[] };
};
type Dead = { provider?: string; model?: string };

const root = fileURLToPath(new URL("../", import.meta.url));
const pi = process.env.PI_FALLBACK_BIN || "pi";
const version = spawnSync(pi, ["--version"], { encoding: "utf8" }).stdout.trim();
const [major, minor] = version.split(".").map(Number);
assert.ok(major > 1 || (major === 1 && minor >= 5), `tests require real Pi >=1.5 (found ${version})`);
const tmp = mkdtempSync(join(tmpdir(), "pi-fallback-"));
try {
  for (const scenario of [
    "429",
    "401",
    "403",
    "400",
    "500",
    "context",
    "usage",
    "bridge",
    "bridge-auth",
    "bridge-success",
    "bridge-warning",
    "retry-success",
    "stale",
    "abort",
    "missing-auth",
    "bridge-missing-auth",
    "bridge-metered",
    "bridge-subscription",
    "bridge-oauth-token",
    "exhaustion",
    "configured-order",
    "tool-no-loop",
    "user-reset",
    "followup-reset",
    "new-user-reset",
    "empty-order",
    "default-order",
    "tui-status",
    "status-only-400",
    "status-only-401",
    "status-only-403",
    "restore",
    "no-restore",
    "dead-402",
    "dead-credits",
    "plan-window",
    "model-window",
    "role-exhaustion",
  ]) {
    const dir = join(tmp, scenario);
    mkdirSync(join(dir, "profile/extensions"), { recursive: true });
    mkdirSync(join(dir, "agent"), { recursive: true });
    mkdirSync(join(dir, "bin"));
    copyFileSync(join(root, "bstack/pi/extensions/fallback.ts"), join(dir, "profile/extensions/fallback.ts"));
    // The desk runs fake-a at high; the fallback models carry other levels, which must not win.
    const deskFirst = [
      "tool-no-loop",
      "user-reset",
      "followup-reset",
      "new-user-reset",
      "restore",
      "no-restore",
      "dead-402",
      "dead-credits",
    ].includes(scenario);
    const twoTurns = ["new-user-reset", "restore", "no-restore", "dead-402", "dead-credits"].includes(scenario);
    writeFileSync(
      join(dir, "profile/models"),
      `claude=${deskFirst ? "fake-a" : "fake-c"}/model\ngpt=${scenario === "missing-auth" ? "fake-unlogged" : scenario.startsWith("bridge-") && ["bridge-missing-auth", "bridge-metered", "bridge-subscription", "bridge-oauth-token"].includes(scenario) ? "claude-bridge" : "fake-b"}/model#low\ngrok=fake-c/model:medium\n`,
    );
    // Most cases limit candidates to GPT/Grok; default-order is covered separately below.
    if (scenario !== "default-order")
      writeFileSync(
        join(dir, "profile/fallback"),
        scenario === "empty-order"
          ? ""
          : deskFirst
            ? "claude\ngpt\ngrok\n"
            : ["plan-window", "model-window"].includes(scenario)
              ? "fake-a/other\ngpt\ngrok\n"
              : "gpt\ngrok\n",
      );
    writeFileSync(
      join(dir, "agent/settings.json"),
      JSON.stringify({ retry: { enabled: true, maxRetries: 2, baseDelayMs: 5 }, compaction: { enabled: false } }),
    );
    const auth =
      scenario === "bridge-metered"
        ? { loggedIn: true, authMethod: "api_key_helper" }
        : scenario === "bridge-subscription"
          ? { loggedIn: true, authMethod: "claude.ai" }
          : scenario === "bridge-oauth-token"
            ? { loggedIn: true, authMethod: "oauth_token" }
            : { loggedIn: false };
    writeFileSync(join(dir, "bin/claude"), `#!/bin/sh\nprintf '%s\\n' '${JSON.stringify(auth)}'\n`, { mode: 0o755 });
    // A stand-in hc: the child's parent is t-lead, and every call is logged.
    writeFileSync(
      join(dir, "bin/hc"),
      `#!/bin/sh\nprintf '%s\\n' "$*" >>'${join(dir, "hc.log")}'\n[ "$1" = get ] && printf '%s\\n' '{"parent":"t-lead"}'\nexit 0\n`,
      { mode: 0o755 },
    );
    const env: NodeJS.ProcessEnv = {
      ...process.env,
      HOME: dir,
      XDG_STATE_HOME: join(dir, "state"),
      PI_CODING_AGENT_DIR: join(dir, "agent"),
      PI_FALLBACK_CASE: scenario,
      PI_FALLBACK_LOG: join(dir, "events.jsonl"),
      PI_OFFLINE: "1",
      PATH: `${dir}/bin:${process.env.PATH}`,
    };
    delete env.HC_TERMINAL_ID;
    delete env.PI_FALLBACK_MISSING_KEY;
    delete env.BERCAIL_ROLE;
    if (scenario === "role-exhaustion") Object.assign(env, { BERCAIL_ROLE: "builder", HC_TERMINAL_ID: "t-child" });
    const args = [
      "--offline",
      "--no-extensions",
      "--no-skills",
      "--no-prompt-templates",
      "--no-context-files",
      "--no-builtin-tools",
      "--no-mcp",
      "--mode",
      "json",
      "--session",
      join(dir, "session.jsonl"),
      "-e",
      join(dir, "profile/extensions/fallback.ts"),
      "-e",
      resolve(root, "tests/pi_fallback_provider.ts"),
      "--model",
      "fake-a/model:high",
      "-p",
      "Finish the original request.",
      ...(twoTurns ? ["Second real user turn"] : []),
    ];
    let command = pi;
    if (scenario === "tui-status") {
      command = "script";
      env.HC_TERMINAL_ID = "t-offline-test";
      env.PI_PROGRAM_STATUS = "1";
      env.PI_FALLBACK_TUI_SHUTDOWN = "1";
      args.splice(args.indexOf("--mode"), 2);
      args.splice(args.indexOf("-p"), 1);
      const quote = (s: string) => `'${s.replaceAll("'", "'\\''")}'`;
      const shellCommand = [pi, ...args].map(quote).join(" ");
      args.splice(0, args.length, "-qefc", shellCommand, "/dev/null");
    }
    const result = spawnSync(command, args, {
      env,
      cwd: dir,
      encoding: "utf8",
      timeout: 30000,
      maxBuffer: 8 * 1024 * 1024,
    });
    writeFileSync(join(dir, "stdout.jsonl"), result.stdout || "");
    writeFileSync(join(dir, "stderr.log"), result.stderr || "");
    assert.equal(result.error, undefined, `${scenario}: ${result.error}`);
    assert.doesNotMatch(
      result.stderr,
      /Failed to load extension|extension.*error|without runnable model context/i,
      `${scenario}: ${result.stderr}`,
    );
    const events: Event[] = readFileSync(join(dir, "events.jsonl"), "utf8")
      .trim()
      .split("\n")
      .map((line) => JSON.parse(line));
    const requests = events.filter((e) => e.type === "request");
    const switches = events.filter((e) => e.event === "model_select");
    const session: SessionEntry[] = readFileSync(join(dir, "session.jsonl"), "utf8")
      .trim()
      .split("\n")
      .map((line) => JSON.parse(line));
    const noSwitch = [
      "401",
      "403",
      "400",
      "500",
      "context",
      "bridge-auth",
      "bridge-success",
      "bridge-warning",
      "retry-success",
      "stale",
      "abort",
      "empty-order",
      "status-only-400",
      "status-only-401",
      "status-only-403",
    ].includes(scenario);
    if (noSwitch) assert.equal(switches.length, 0, `${scenario}: must not switch`);
    else {
      assert.ok(switches.length > 0, `${scenario}: must switch; ${result.stderr}`);
      const target = ["missing-auth", "bridge-missing-auth", "bridge-metered", "default-order"].includes(scenario)
        ? "fake-c"
        : ["bridge-subscription", "bridge-oauth-token"].includes(scenario)
          ? "claude-bridge"
          : scenario === "model-window"
            ? "fake-a"
            : "fake-b";
      assert.equal(switches[0].model, target, scenario);
      // Pi's setModel resets thinking to its default (medium); the desk's :high must stay, over the models file's #low and :medium.
      assert.deepEqual(
        [...new Set(requests.map((e) => e.reasoning))],
        ["high"],
        `${scenario}: every request at the desk's thinking level`,
      );
      assert.equal(
        session.filter((e) => e.type === "thinking_level_change").at(-1)?.thinkingLevel,
        "high",
        `${scenario}: session ends at the desk's level`,
      );
      assert.ok(
        session.some((e) => e.type === "model_change" && e.provider === target),
        `${scenario}: model persisted`,
      );
      assert.ok(
        session.some((e) => e.type === "custom_message" && e.customType === "bercail-fallback" && e.display),
        `${scenario}: visible session note`,
      );
      if (!["exhaustion", "role-exhaustion"].includes(scenario))
        assert.match(result.stdout, /PI_FALLBACK_OK/, `${scenario}: turn finishes`);
    }
    if (["429", "stale", "retry-success", "exhaustion"].includes(scenario)) {
      assert.equal(
        requests.filter((e) => e.provider === "fake-a").length,
        scenario === "retry-success" ? 2 : scenario === "stale" ? 2 : 3,
        `${scenario}: native retry budget`,
      );
    }
    if (scenario === "tui-status") {
      // oxlint-disable-next-line no-control-regex -- an OSC 7501 record is ESC ] ... BEL or ST.
      const records = [...result.stdout.matchAll(/\x1b\]7501;([^\x07\x1b]+)(?:\x07|\x1b\\)/g)].map((m) => m[1]);
      assert.equal(records.filter((r) => r.includes("id=bercail-fallback")).length, 0, "Pi owns program status");
      const done = records.find((r) => r.startsWith("state=done:app=pi:msg="));
      assert.ok(done, `Pi done status missing: ${records.join(" | ")}`);
      assert.match(
        Buffer.from(done.split("msg=")[1], "base64").toString(),
        /fallback: fake-b\/model/,
        "session name carries the switch",
      );
      assert.match(result.stdout, /fallback: fake-b\/model/, "real Pi footer status");
    }
    if (scenario === "429") {
      const firstSwitch = events.findIndex((e) => e.event === "model_select");
      assert.equal(
        events.slice(0, firstSwitch).filter((e) => e.type === "request").length,
        3,
        "switch only after retry exhaustion",
      );
      assert.ok(requests[2].at - requests[0].at >= 10, "Pi retry backoff precedes fallback");
      const next = requests.find((e) => e.provider === "fake-b");
      assert.ok(
        next!.messages.some(
          (m) => m.role === "user" && JSON.stringify(m.content).includes("Finish the original request"),
        ),
        "original request preserved",
      );
      assert.equal(
        next!.messages.some((m) => m.role === "assistant" && m.stopReason === "error"),
        false,
        "failed assistant omitted",
      );
      assert.equal(events.filter((e) => e.event === "before_agent_start").length, 1, "same user run");
      assert.equal(events.filter((e) => e.event === "agent_settled").length, 1, "settles only after continuation");
    }
    if (scenario === "exhaustion") {
      assert.equal(requests.length, 9, "each configured provider attempted once with native retries");
      assert.ok(
        session.some(
          (e) =>
            e.type === "custom" &&
            e.customType === "bercail-fallback-error" &&
            /fallback exhausted/.test(e.data?.text ?? ""),
        ),
        "clear persisted exhaustion error",
      );
      assert.equal(
        session.some((e) => e.type === "custom_message" && e.customType === "bercail-fallback-error"),
        false,
        "exhaustion is not a later user turn",
      );
    }
    if (scenario === "empty-order")
      assert.ok(
        session.some(
          (e) =>
            e.type === "custom" &&
            e.customType === "bercail-fallback-error" &&
            /no candidates/.test(e.data?.text ?? ""),
        ),
        "empty order stops clearly",
      );
    if (scenario === "tool-no-loop") {
      assert.deepEqual(
        switches.map((e) => e.model),
        ["fake-b", "fake-c"],
        "fallback attempts survive tool turns",
      );
      assert.equal(events.filter((e) => e.type === "tool").length, 1, "real tool executed");
    }
    if (["user-reset", "followup-reset", "new-user-reset"].includes(scenario)) {
      assert.deepEqual(
        switches.map((e) => e.model),
        ["fake-b", "fake-a"],
        "a user message after the reset goes back to the desk's model",
      );
      assert.equal(
        events.filter((e) => e.event === "message_start" && e.role === "user").length,
        2,
        "two real user messages",
      );
      assert.equal(
        events.filter((e) => e.event === "before_agent_start").length,
        scenario === "new-user-reset" ? 2 : 1,
        "queued messages reset without before_agent_start",
      );
    }
    const turn2 = requests.filter((e) => e.userTurns === 2);
    const restores = session.filter((e) => e.type === "custom" && e.customType === "bercail-fallback-restore");
    if (scenario === "restore") {
      assert.deepEqual(
        switches.map((e) => `${e.model}/${e.id}`),
        ["fake-b/model", "fake-a/model"],
        "falls back, then back to the desk's model",
      );
      assert.deepEqual(
        turn2.map((e) => `${e.provider}:${e.reasoning}`),
        ["fake-a:high"],
        "the next user turn runs on the desk's model at its level",
      );
      assert.equal(restores.length, 1, "the switch back is logged");
      assert.match(
        restores[0]!.data!.text!,
        /back to fake-a\/model \(thinking high\) from fake-b\/model/,
        "restore note",
      );
      assert.equal(
        session.filter((e) => e.type === "model_change").at(-1)?.provider,
        "fake-a",
        "session ends on the desk's model",
      );
    }
    if (scenario === "no-restore") {
      assert.deepEqual(
        switches.map((e) => e.model),
        ["fake-b", "fake-c"],
        "a still-limited desk model is skipped",
      );
      assert.equal(
        turn2.some((e) => e.provider === "fake-a"),
        false,
        "no request to the desk's model before its limit lifts",
      );
      assert.equal(restores.length, 0, "no restore while limited");
    }
    if (["dead-402", "dead-credits"].includes(scenario)) {
      assert.deepEqual(
        switches.map((e) => e.model),
        ["fake-b", "fake-c"],
        "the dead model is skipped on the next fallback",
      );
      assert.equal(
        turn2.some((e) => e.provider === "fake-a"),
        false,
        "a dead desk model is not restored or retried",
      );
      assert.equal(requests.filter((e) => e.provider === "fake-a").length, 1, "dead is not a limit: no native retries");
      const dead: Dead[] = readFileSync(join(dir, "state/bercail/fallback-dead.jsonl"), "utf8")
        .trim()
        .split("\n")
        .map((line) => JSON.parse(line));
      assert.deepEqual(
        dead.map((e) => [e.provider, e.model]),
        [["fake-a", "fake-a/model"]],
        "one dead record for doctor",
      );
      assert.ok(
        session.some(
          (e) =>
            e.type === "custom_message" &&
            e.customType === "bercail-fallback" &&
            String(e.content).startsWith("Dead model: switched fake-a/model"),
        ),
        "the note says dead",
      );
      assert.ok(
        session.some((e) => e.type === "custom_message" && e.details?.dead?.["fake-a"]),
        "dead providers in the note's details",
      );
    }
    if (scenario === "plan-window") {
      assert.equal(
        requests.some((e) => e.id === "other"),
        false,
        "a plan-wide window skips the other model on that plan",
      );
      assert.ok(
        session.some(
          (e) =>
            e.type === "custom_message" && e.details?.skipped?.some((s) => s.startsWith("fake-a/other: limited until")),
        ),
        "says why it skipped it",
      );
    }
    if (scenario === "model-window")
      assert.equal(switches[0].id, "other", "a one-model window tries the other model on the same plan first");
    if (scenario === "role-exhaustion") {
      const hc = readFileSync(join(dir, "hc.log"), "utf8");
      assert.match(hc, /^get t-child --json$/m, "asks hc for its parent");
      assert.match(
        hc,
        /^send t-lead builder t-child stopped: Rate limit: fallback exhausted .*Do this part yourself\.$/m,
        "tells the lead it stopped",
      );
    }
    if (scenario === "exhaustion") assert.equal(existsSync(join(dir, "hc.log")), false, "the lead tells no one");
    console.log(`PASS: real Pi ${scenario} (${requests.length} requests, ${switches.length} switches)`);
  }
} catch (error) {
  console.error(`Artifacts: ${tmp}`);
  throw error;
}
rmSync(tmp, { recursive: true, force: true });
