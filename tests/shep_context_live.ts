// Shep's context on Pi, live: `bercail shep run` starts the installed Pi in a
// terminal, in a temp HOME, on a scripted offline model. It proves that Pi loads
// Shep's workspace settings, that /compact gives a summary with the job board,
// a standing rule added while Shep runs, and the model's decisions, that the
// session goes on after it, that Pi compacts on its own once the context passes
// [shep] compact_at, and that rollover moves Shep to a fresh, seeded session.
// Usage: node tests/shep_context_live.ts ROOT PI
import { spawnSync } from "node:child_process";
import {
  appendFileSync,
  copyFileSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { join } from "node:path";
import { isDeepStrictEqual } from "node:util";
import { Term, fail, fails, killAll, pass, sleep, waitFor } from "./live_term.ts";

const [ROOT, PI] = process.argv.slice(2) as [string, string];
const COMPACT_AT = 20000;

type Message = { role?: string; content?: unknown };
type Entry = {
  type?: string;
  message?: Message;
  summary?: string;
  details?: { by?: string; reason?: string };
  tokensBefore?: number;
};

function sessionFiles(sessions: string): string[] {
  return readdirSync(sessions, { recursive: true, encoding: "utf8" })
    .filter((p) => p.endsWith(".jsonl"))
    .map((p) => join(sessions, p))
    .sort((a, b) => statSync(a).mtimeMs - statSync(b).mtimeMs);
}

function entries(path: string): Entry[] {
  const out: Entry[] = [];
  for (const line of readFileSync(path, "utf8").split("\n")) {
    try {
      out.push(JSON.parse(line));
    } catch {}
  }
  return out;
}

function textOf(msg: Message): string {
  const c = msg.content;
  if (typeof c === "string") return c;
  if (Array.isArray(c))
    return c
      .filter((p): p is { text?: string } => typeof p === "object" && p !== null)
      .map((p) => p.text ?? "")
      .join("\n");
  return "";
}

const replies = (path: string): string[] =>
  entries(path)
    .filter((e) => e.type === "message" && e.message?.role === "assistant")
    .map((e) => textOf(e.message!));

const compactions = (path: string): Entry[] => entries(path).filter((e) => e.type === "compaction");

function run(cmd: string, args: string[], opts: Parameters<typeof spawnSync>[2] = {}): void {
  const r = spawnSync(cmd, args, opts);
  if (r.status !== 0) throw new Error(`${cmd} ${args.join(" ")} exited ${r.status ?? r.signal}`);
}

async function body(dir: string): Promise<void> {
  const home = join(dir, "home");
  const state = join(dir, "state");
  const binp = join(dir, "bin");
  const share = join(home, ".local/share/bercail/shep");
  for (const p of [
    join(home, ".config/bercail"),
    join(state, "bercail/shep"),
    binp,
    join(share, "pi"),
    join(home, ".local/share/bercail/pi"),
  ])
    mkdirSync(p, { recursive: true });
  symlinkSync(PI, join(binp, "pi"));
  for (const rel of ["SHEP.md", "pi/inbox.ts", "pi/compaction.ts"])
    copyFileSync(join(ROOT, "shep", rel), join(share, rel));
  writeFileSync(
    join(home, ".local/share/bercail/pi/lead.json"),
    JSON.stringify(["pi", "--model", "fake/model:high", "-e", join(ROOT, "tests/shep_context_provider.ts")]),
  );
  const config = join(home, ".config/bercail/config.toml");
  writeFileSync(config, `[shep]\ncompact_at = ${COMPACT_AT}\nkeep_recent = 2000\n`);
  // One known repo, from Shep's extras file, with one job in its beads.
  const repo = join(dir, "app");
  run("git", ["init", "-q", repo], { stdio: "inherit" });
  mkdirSync(join(repo, ".beads"));
  writeFileSync(join(state, "bercail/shep/repos"), `${repo}\n`);
  writeFileSync(
    join(binp, "bd"),
    `#!/bin/sh\n[ "$1" = list ] && printf '%s\\n' '[{"id":"live-1","title":"Live job","status":"in_progress"}]'\n`,
    { mode: 0o755 },
  );
  writeFileSync(join(binp, "hc"), `#!/bin/sh\n[ "$1" = ls ] && printf '{"terminals":[]}\\n'\nexit 0\n`, {
    mode: 0o755,
  });

  const env: NodeJS.ProcessEnv = Object.fromEntries(
    Object.entries(process.env).filter(
      ([k]) => !k.startsWith("PI_") && !k.startsWith("HC_") && !k.startsWith("BERCAIL_") && k !== "BASH_ENV",
    ),
  );
  Object.assign(env, {
    HOME: home,
    XDG_CONFIG_HOME: join(home, ".config"),
    XDG_STATE_HOME: state,
    XDG_DATA_HOME: join(dir, "data"),
    XDG_CACHE_HOME: join(dir, "cache"),
    PATH: `${binp}:/usr/bin:/bin`,
    TERM: "xterm-256color",
    PI_OFFLINE: "1",
    HERDR_APP_BIN: join(dir, "no-herdr-app"),
    __MISE_BASH_ENV_LOADED: "1",
  });
  const shepDir = join(state, "bercail/shep");
  const sessions = join(shepDir, "pi-sessions");
  const bercail = join(ROOT, "bin/bercail");

  const start = async (n: number): Promise<Term> => {
    const log = join(dir, `term${n}.log`);
    const term = await Term.start([bercail, "shep", "run"], { env, cwd: dir, log });
    // A resumed session can initially draw history without its footer. Wait
    // for terminal input mode, not a context meter that needs another redraw.
    await waitFor("Pi's terminal input", () => readFileSync(log).includes("\x1b[?2004h"), { timeout: 60 });
    await sleep(1000);
    return term;
  };

  const answered = (prompt: string, timeout = 60) =>
    waitFor(
      `a reply to '${prompt}'`,
      () => replies(sessionFiles(sessions).at(-1)!).some((r) => r.startsWith(`Shep ok: ${prompt}`)),
      { timeout },
    );

  let shep = await start(1);
  const settings = JSON.parse(readFileSync(join(shepDir, "workspace/.pi/settings.json"), "utf8"));
  const want = {
    enabled: true,
    keepRecentTokens: 2000,
    modelOverrides: { "fake/model": { keepRecentTokens: 2000, reserveTokens: 64000 - COMPACT_AT } },
  };
  if (!isDeepStrictEqual(settings.compaction, want)) fail(`settings: ${JSON.stringify(settings)}`);
  const term1 = readFileSync(join(dir, "term1.log"));
  if (term1.includes("Trust") && term1.includes("project")) fail("Pi asked to trust Shep's workspace");
  await shep.type("hello");
  if (!(await answered("hello"))) return;
  const session = sessionFiles(sessions).at(-1)!;
  if (compactions(session).length) fail("compacted before the context reached compact_at");
  pass("Shep starts on its workspace settings, with no trust question");

  // A rule added while Shep runs is in the next summary. "medium" gives
  // /compact more than keep_recent to summarize.
  await shep.type("medium");
  await waitFor("the medium reply", () => replies(session).some((r) => r.startsWith("Shep medium:")), { timeout: 60 });
  await shep.type("then");
  await answered("then");
  run(bercail, ["shep", "remember", "LIVE-RULE: merge app work straight to main", "--scope", "app"], {
    env,
    stdio: ["inherit", "ignore", "inherit"],
  });
  await shep.type("/compact");
  if (!(await waitFor("the /compact entry", () => compactions(session).length === 1, { timeout: 60 }))) return;
  let c = compactions(session)[0]!;
  const s = c.summary ?? "";
  for (const wantText of [
    "- live-1: Live job [in_progress] · no desk · -",
    "[app] LIVE-RULE: merge app work straight to main",
    "LIVE-DECISION: ship live-1 once reviewed",
  ])
    if (!s.includes(wantText)) fail(`/compact summary lacks '${wantText}': ${s}`);
  if (c.details?.by !== "bercail-shep" || c.details?.reason !== "manual")
    fail(`compaction details: ${JSON.stringify(c.details)}`);
  await shep.type("after compact");
  if ((await answered("after compact")) && sessionFiles(sessions).at(-1) === session)
    pass("/compact writes the board, the new rule and the decisions; the session goes on");
  const log = readFileSync(join(shepDir, "compaction.log"), "utf8");
  if (!log.includes("manual compaction: Shep's summary")) fail(`compaction.log: ${log}`);

  // Past compact_at, Pi compacts on its own, with Shep's summary.
  await shep.type("big");
  await waitFor("the big reply", () => replies(session).some((r) => r.startsWith("Shep big:")), { timeout: 60 });
  await shep.type("next");
  if (await waitFor("a threshold compaction", () => compactions(session).length === 2, { timeout: 90 })) {
    c = compactions(session)[1]!;
    if (c.details?.reason !== "threshold" || !(c.summary ?? "").includes("- live-1: Live job"))
      fail(`threshold compaction: ${JSON.stringify(c.details)} ${(c.summary ?? "").slice(0, 300)}`);
    else if ((c.tokensBefore ?? 0) <= COMPACT_AT) fail(`compacted under compact_at: tokensBefore ${c.tokensBefore}`);
    else pass(`past compact_at (${c.tokensBefore} > ${COMPACT_AT} tokens) Pi compacts with Shep's summary`);
  }
  await answered("next", 90);
  await shep.stop(10);

  // Rollover on: the next threshold starts a fresh session seeded with the
  // board and the rules; the old one stays on disk.
  appendFileSync(config, "rollover = true\n");
  shep = await start(2);
  await shep.type("big");
  if (!(await waitFor("a rollover session", () => sessionFiles(sessions).length === 2, { timeout: 90 }))) return;
  const fresh = sessionFiles(sessions).at(-1)!;
  const first = entries(fresh)
    .filter((e) => e.type === "message")
    .map((e) => textOf(e.message!));
  const seedText = first[0] ?? "";
  if (
    !(
      seedText.startsWith("bercail rollover") &&
      seedText.includes(session) &&
      seedText.includes("- live-1: Live job") &&
      seedText.includes("LIVE-RULE")
    )
  )
    fail(`rollover seed: ${seedText.slice(0, 400)}`);
  if (compactions(session).length !== 2)
    fail(`the rollover compacted the old session too: ${compactions(session).length}`);
  await shep.type("in the new session");
  if ((await answered("in the new session")) && sessionFiles(sessions).at(-1) === fresh)
    pass("rollover starts a fresh session seeded with the board and the rules; the old one is kept");
  await shep.stop(10);
}

const dir = `/tmp/shep-context-live.${process.pid}`;
mkdirSync(dir);
try {
  await body(dir);
} finally {
  killAll();
  if (!fails.length && !process.env.KEEP) rmSync(dir, { recursive: true, force: true });
  else console.error(`kept: ${dir}`);
}
process.exit(fails.length ? 1 : 0);
