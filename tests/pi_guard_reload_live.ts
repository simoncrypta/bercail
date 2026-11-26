// Real Pi in a terminal, offline provider: once its guard file changes on disk, as
// bercail update changes it under a running desk or Shep, the guard refuses the next
// call, Pi reloads it when the turn ends, keeps the session, and the agent goes on
// under the new guard without anyone typing. A replacement that does not load leaves
// the old guard refusing. Headless, the call is refused for good.
// Usage: node tests/pi_guard_reload_live.ts ROOT PI
import { spawnSync } from "node:child_process";
import {
  copyFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { Term, fail, fails, killAll, pass, waitFor } from "./live_term.ts";

const [ROOT, PI] = process.argv.slice(2).map((arg) => resolve(arg));
const dir = mkdtempSync(join(tmpdir(), "guard-reload-live."));
const guard = join(dir, "profile/extensions/guard.ts");
const env: NodeJS.ProcessEnv = {
  ...process.env,
  HOME: dir,
  XDG_STATE_HOME: join(dir, "state"),
  XDG_CONFIG_HOME: join(dir, "config"),
  PI_CODING_AGENT_DIR: join(dir, "agent"),
  PI_OFFLINE: "1",
  PI_SKIP_VERSION_CHECK: "1",
  PI_TELEMETRY: "0",
  TMPDIR: dir,
  TERM: "xterm-256color",
  BERCAIL_BIN: join(ROOT, "bin/bercail"),
};
for (const key of ["BERCAIL_ROLE", "HC_TERMINAL_ID", "BERCAIL_CONFIG"]) delete env[key];

const args = [
  "--offline",
  "--no-extensions",
  "--no-skills",
  "--no-prompt-templates",
  "--no-context-files",
  "--no-mcp",
  "--no-approve",
  "-e",
  guard,
  "-e",
  join(ROOT, "tests/pi_guard_provider.ts"),
  "--model",
  "fake-guard/model",
];
const withCommands = (commands: (string | null)[]) => ({ ...env, PI_GUARD_COMMANDS: JSON.stringify(commands) });
const session = () =>
  readdirSync(join(dir, "agent/sessions"), { recursive: true, encoding: "utf8" })
    .filter((name) => name.endsWith(".jsonl"))
    .map((name) => readFileSync(join(dir, "agent/sessions", name), "utf8"));
// The bash results in the sessions, in order.
const results = () =>
  session()
    .flatMap((text) => text.trim().split("\n"))
    .map((line) => JSON.parse(line))
    .filter((entry) => entry.message?.role === "toolResult")
    .map((entry) => String(entry.message.content?.[0]?.text ?? ""));

// What the guard told the agent, in its own messages.
const told = () =>
  session()
    .flatMap((text) => text.trim().split("\n"))
    .map((line) => JSON.parse(line))
    .filter((entry) => entry.customType === "bercail-guard")
    .map((entry) => JSON.stringify(entry.content));

async function main() {
  mkdirSync(join(dir, "profile/extensions"), { recursive: true });
  mkdirSync(join(dir, "agent"), { recursive: true });
  writeFileSync(
    join(dir, "agent/settings.json"),
    JSON.stringify({ retry: { enabled: false }, compaction: { enabled: false } }),
  );
  const before = join(dir, "ran-on-the-old-guard");
  const after = join(dir, "ran-on-the-new-guard");
  const fresh = () => {
    copyFileSync(join(ROOT, "bstack/pi/extensions/guard.ts"), guard);
    rmSync(join(dir, "agent/sessions"), { recursive: true, force: true });
  };
  // Only the replacement says this, and it says it once it has loaded.
  const marker = `replacement ${process.pid}`;
  const change = `sed -i 's/with the installed rules:/with the installed rules (${marker}):/' ${guard}`;

  // The first call changes the guard; the second is refused; the turn ends, Pi reloads,
  // and the new guard's message starts the next turn, whose call runs.
  fresh();
  let term = await Term.start([PI, ...args], {
    env: withCommands([change, `touch ${before}`, null, `touch ${after}`]),
    cwd: dir,
    log: join(dir, "term.log"),
  });
  if (!(await waitFor("Pi's TUI", () => term.screenSince(0).includes("pi_guard_provider.ts"), { term }))) return;
  await term.type("Do the work.");
  if (await waitFor("the call after the reload", () => existsSync(after), { term, timeout: 30 })) {
    const seen = results();
    if (existsSync(before)) fail("the call on the changed guard ran");
    else if (!seen.some((text) => text.includes("changed on disk after this Pi loaded it")))
      fail(`no refusal for the changed guard: ${JSON.stringify(seen)}`);
    else if (session().length !== 1) fail(`the reload left ${session().length} sessions, not one`);
    else if (!told().some((text) => text.includes(marker)))
      fail("the replacement guard did not load and tell the agent");
    else
      pass("a changed guard refused the next call, Pi loaded the new one in the same session, and the agent went on");
  }
  await term.stop();

  // A replacement that does not load: Pi keeps the old guard, which goes on refusing.
  fresh();
  rmSync(after, { force: true });
  const broken = `printf '\\nthis is not a guard {\\n' >> ${guard}`;
  term = await Term.start([PI, ...args], {
    env: withCommands([broken, `touch ${before}`, null, `touch ${after}`]),
    cwd: dir,
    log: join(dir, "term-broken.log"),
  });
  if (!(await waitFor("Pi's TUI", () => term.screenSince(0).includes("pi_guard_provider.ts"), { term }))) return;
  const mark = term.size();
  await term.type("Do the work.");
  if (await waitFor("the failed load said so", () => term.screenSince(mark).includes("does not load"), { term })) {
    await term.type("Go on.");
    if (await waitFor("the next call refused", () => results().length >= 3, { term })) {
      const seen = results();
      if (existsSync(before) || existsSync(after)) fail("a call ran with a guard file that does not load");
      else if (!seen[2].includes("the new one does not load"))
        fail(`the old guard did not refuse on: ${JSON.stringify(seen)}`);
      else if (readdirSync(join(dir, "profile/extensions")).length !== 1) fail("the load check left a file behind");
      else pass("a replacement that does not load left the old guard in place, refusing every call");
    }
  }
  await term.stop();

  // Headless: no reload, and the call stays refused.
  fresh();
  const headless = spawnSync(PI, [...args, "-p", "Do the work."], {
    env: withCommands([change, `touch ${before}`]),
    cwd: dir,
    encoding: "utf8",
    timeout: 60000,
  });
  if (headless.status !== 0) fail(`headless Pi exited ${headless.status}: ${headless.stderr}`);
  else if (existsSync(before)) fail("a headless call on the changed guard ran");
  else if (!results().some((text) => text.includes("changed on disk after this headless run loaded it")))
    fail(`no headless refusal: ${JSON.stringify(results())}`);
  else pass("headless, a changed guard refused the call and said so");
}

try {
  await main();
} finally {
  killAll();
}
if (fails.length) {
  console.error(`Artifacts: ${dir}`);
  process.exit(1);
}
rmSync(dir, { recursive: true, force: true });
