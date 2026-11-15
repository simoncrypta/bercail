// Discuss, live: the installed Pi on a branch of a scratch Shep session, run with the
// argv `bercail shep discuss` builds (shep_discuss_argv) and a fake model. The model
// gets only the read-only tools and the conversation up to the question; its bash
// call (hc send) is refused and runs nothing; Shep's session is only read.
// Usage: node tests/shep_discuss_live.ts ROOT PI
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { isDeepStrictEqual } from "node:util";

const [ROOT, PI] = process.argv.slice(2) as [string, string];
const fail = (msg: string): never => {
  console.error(`FAIL: ${msg}`);
  process.exit(1);
};
const eq = (got: unknown, want: unknown, what: string) =>
  isDeepStrictEqual(got, want) || fail(`${what}: ${JSON.stringify(got)}`);

const tmp = mkdtempSync(join(tmpdir(), "shep-discuss-live-"));
try {
  const state = join(tmp, "state/bercail/shep");
  const bin = join(tmp, "bin");
  const env: NodeJS.ProcessEnv = {
    PATH: `${bin}:${dirname(PI)}:/usr/bin:/bin`,
    HOME: join(tmp, "home"),
    XDG_STATE_HOME: join(tmp, "state"),
    XDG_CONFIG_HOME: join(tmp, "config"),
    PI_CODING_AGENT_DIR: join(tmp, "agent"),
    SHEP_DISCUSS_SEEN: join(tmp, "seen.jsonl"),
    PI_OFFLINE: "1",
    TERM: "dumb",
  };
  for (const d of [bin, env.HOME!, env.XDG_CONFIG_HOME!, join(state, "pi-sessions"), join(state, "workspace")])
    mkdirSync(d, { recursive: true });
  // This node for the question helper, and a stand-in hc that leaves a mark if anything runs it.
  symlinkSync(process.execPath, join(bin, "node"));
  writeFileSync(join(bin, "hc"), `#!/bin/sh\necho "$@" >> '${tmp}/hc-ran'\n`, { mode: 0o755 });
  // bercail's share, as deploy lays it out: Shep's files and bstack's lead.
  const share = join(env.HOME!, ".local/share/bercail");
  mkdirSync(join(share, "pi"), { recursive: true });
  symlinkSync(join(ROOT, "shep"), join(share, "shep"));
  writeFileSync(
    join(share, "pi/lead.json"),
    JSON.stringify([
      "pi",
      "--model",
      "fake-discuss/model",
      "-e",
      join(ROOT, "tests/shep_discuss_provider.ts"),
      "-e",
      join(ROOT, "bstack/pi/extensions/guard.ts"),
    ]),
  );
  // Shep's session: the turn that asked (a1 calls shep_question, a2 says it), then later news.
  const line = (e: object) => JSON.stringify(e) + "\n";
  const msg = (id: string, parentId: string | null, message: object) =>
    line({
      type: "message",
      id,
      parentId,
      timestamp: "2026-11-15T12:00:00.000Z",
      message: { timestamp: 0, ...message },
    });
  const shepFile = join(state, "pi-sessions", "2026-11-15T12-00-00-000Z_shep-1.jsonl");
  const shep =
    line({
      type: "session",
      version: 3,
      id: "shep-1",
      timestamp: "2026-11-15T12:00:00.000Z",
      cwd: join(state, "workspace"),
    }) +
    msg("u1", null, { role: "user", content: "what next?" }) +
    msg("a1", "u1", {
      role: "assistant",
      content: [{ type: "toolCall", id: "c1", name: "shep_question", arguments: {} }],
      stopReason: "toolUse",
    }) +
    msg("r1", "a1", {
      role: "toolResult",
      toolCallId: "c1",
      toolName: "shep_question",
      content: [{ type: "text", text: "Q1@1" }],
      isError: false,
    }) +
    msg("a2", "r1", { role: "assistant", content: [{ type: "text", text: "A or B?" }], stopReason: "stop" }) +
    msg("u2", "a2", { role: "user", content: "later news" });
  writeFileSync(shepFile, shep);
  const { QuestionStore } = await import(join(ROOT, "shep/pi/questions.ts"));
  new QuestionStore(state).create("r1", {}, () => ({
    kind: "planning",
    prompt: "A or B?",
    options: ["A", "B"],
    brief: "Two plans.",
    recommendation: { choice: "A", why: "smaller" },
    origin: { event: "chat", session: "shep-1", entry: "a1" },
    target: {
      ...Object.fromEntries(
        ["issue", "worktree", "desk", "space", "session", "action", "head", "stagedTree", "base", "baseRef"].map(
          (k) => [k, null],
        ),
      ),
      repo: "/r/.git",
      topic: "plan",
    },
  }));

  // The branch, and the argv bercail shep discuss runs on it.
  const libs = ["common", "bstack", "shep"].map((l) => `source '${ROOT}/lib/${l}.sh'`).join("; ");
  const built = spawnSync(
    "bash",
    [
      "-c",
      `${libs}; out="$(shep_question discuss Q1@1)" || exit 1; shep_discuss_argv Q1@1 "$(jq -r .session <<<"$out")"; printf '%s\\0' "\${SHEP_DISCUSS_ARGV[@]}"`,
    ],
    { env, encoding: "utf8" },
  );
  if (built.status !== 0) fail(`argv: ${built.stderr}`);
  const argv = built.stdout.split("\0").slice(0, -1);
  const branch = argv[argv.indexOf("--session") + 1]!;
  const run = spawnSync(argv[0]!, [...argv.slice(1), "-p", "Why A?"], {
    env,
    cwd: join(state, "workspace"),
    encoding: "utf8",
    timeout: 60000,
  });
  if (run.status !== 0) fail(`pi exited ${run.status}: ${run.stderr}`);
  if (!run.stdout.includes("A is smaller; B is safer.")) fail(`pi printed: ${run.stdout}`);

  const seen = readFileSync(env.SHEP_DISCUSS_SEEN!, "utf8")
    .trim()
    .split("\n")
    .map((l) => JSON.parse(l));
  eq(seen[0].tools, ["find", "grep", "ls", "read"], "the branch's tools");
  if (!/## Discuss branch/.test(seen[0].system)) fail("the branch was not told what it is");
  // First turn: the conversation up to the question (through its tool result and reply), then the person's message.
  eq(
    seen[0].messages,
    [
      ["user", "what next?"],
      ["assistant", "[toolCall]"],
      ["toolResult", "Q1@1"],
      ["assistant", "A or B?"],
      ["user", "Why A?"],
    ],
    "what the branch's first turn sends",
  );
  const refused = seen[1].messages.at(-1);
  if (refused[0] !== "toolResult" || !/bash/i.test(refused[1]))
    fail(`bash was not refused: ${JSON.stringify(refused)}`);
  try {
    fail(`hc ran: ${readFileSync(join(tmp, "hc-ran"), "utf8")}`);
  } catch (e) {
    if ((e as NodeJS.ErrnoException).code !== "ENOENT") throw e;
  }
  eq(readFileSync(shepFile, "utf8"), shep, "Shep's session after the branch ran");
  eq(readdirSync(join(state, "pi-sessions")), ["2026-11-15T12-00-00-000Z_shep-1.jsonl"], "Shep's sessions folder");
  if (!readFileSync(branch, "utf8").includes("A is smaller; B is safer."))
    fail("the branch did not keep its discussion");
  console.log("ok: real Pi discusses on a read-only branch at the question; Shep's session is untouched");
} finally {
  rmSync(tmp, { recursive: true, force: true });
}
