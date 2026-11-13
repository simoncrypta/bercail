// Disposable Pi TUI desk on a fake provider: `bercail desk model` switches it
// from opus to fable and back, the footer and session show each switch, and an
// hc chat message that says /model switches nothing.
// Usage: node tests/desk_model_pi_live.ts ROOT PI
import { spawnSync } from "node:child_process";
import { chmodSync, mkdirSync, readFileSync, readdirSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { isDeepStrictEqual } from "node:util";
import { Term, fail, fails, pass, sleep, waitFor } from "./live_term.ts";

const [ROOT, PI] = process.argv.slice(2) as [string, string];
const EXT = join(ROOT, "config/pi/extensions/bercail-desk.ts");
const PROVIDER = join(ROOT, "tests/desk_model_pi_provider.ts");

type Entry = {
  type?: string;
  provider?: string;
  modelId?: string;
  customType?: string;
  data?: { to?: string };
  message?: { role?: string; model?: string };
};

const entries = (path: string): Entry[] =>
  readFileSync(path, "utf8")
    .split("\n")
    .filter((line) => line.trim())
    .map((line) => JSON.parse(line));

async function main(run: string): Promise<void> {
  const home = join(run, "home");
  const state = join(run, "state");
  const project = join(run, "project");
  const sessions = join(run, "sessions");
  const fake = join(run, "bin");
  for (const path of [join(home, ".config"), join(home, ".local/share/bercail/pi"), state, project, sessions, fake])
    mkdirSync(path, { recursive: true });
  mkdirSync(join(run, "run"), { mode: 0o700 });
  chmodSync(join(run, "run"), 0o700);
  const hcLog = join(run, "hc.log");
  // hc: t9 is a live desk; labels are logged.
  writeFileSync(
    join(fake, "hc"),
    "#!/bin/bash\n" +
      `printf '%s\\n' "$*" >>${hcLog}\n` +
      "[[ $1 == get ]] || exit 0\n" +
      `echo '{"address":"t9","state":"live","labels":{"bercail.role":"agent","bercail.space":"sp1"}}'\n`,
    { mode: 0o755 },
  );
  symlinkSync(PI, join(fake, "pi"));
  writeFileSync(
    join(home, ".local/share/bercail/pi/lead.json"),
    JSON.stringify(["pi", "--model", "fake/opus:high", "-e", PROVIDER]),
  );
  const env: NodeJS.ProcessEnv = Object.fromEntries(
    Object.entries(process.env).filter(([k]) => !k.startsWith("HC_") && !k.startsWith("PI_")),
  );
  Object.assign(env, {
    HOME: home,
    XDG_CONFIG_HOME: join(home, ".config"),
    XDG_STATE_HOME: state,
    XDG_DATA_HOME: join(run, "data"),
    XDG_CACHE_HOME: join(run, "cache"),
    XDG_RUNTIME_DIR: join(run, "run"),
    PATH: `${fake}:${env.PATH}`,
    HC_TERMINAL_ID: "t9",
    HC_BIN: join(fake, "hc"),
    PI_OFFLINE: "1",
    TERM: "xterm-256color",
    COLORTERM: "truecolor",
    BERCAIL_DESK_MODEL_WAIT: "15",
  });
  const record = join(state, "bercail/desk-sessions/t9.json");
  mkdirSync(join(state, "bercail/desk-sessions"), { recursive: true });
  // The wrapper's part: the record names this pid, then Pi takes it over.
  const wrap = join(run, "desk.sh");
  writeFileSync(
    wrap,
    "#!/bin/bash\n" +
      `printf '{"address":"t9","session":"","cwd":"${project}","harness":"pi","space":"sp1",` +
      `"args":["--model","fake/opus:high"],"pid":%s}\\n' $$ >${record}\n` +
      `exec pi --offline -ne -e ${PROVIDER} -e ${EXT} --model fake/opus:high --session-dir ${sessions} ` +
      "--no-skills --no-prompt-templates --no-context-files --no-tools\n",
    { mode: 0o755 },
  );
  const tui = await Term.start([wrap], { env, cwd: project, log: join(run, "terminal.log") });
  try {
    const recorded = () => JSON.parse(readFileSync(record, "utf8"));
    if (!(await waitFor("the desk records its session", () => recorded().session, { timeout: 30, term: tui }))) return;
    const session: string = recorded().session;
    await sleep(1000);
    await tui.send("ping one\r", 20);
    const sessionFile = (): string => {
      const name = readdirSync(sessions, { recursive: true, encoding: "utf8" }).find((p) =>
        p.endsWith(`_${session}.jsonl`),
      );
      if (!name) throw new Error(`no session file for ${session}`);
      return join(sessions, name);
    };
    const lastIsAnswer = (text: string) => () =>
      readFileSync(sessionFile(), "utf8").includes(text) &&
      entries(sessionFile()).at(-1)?.message?.role === "assistant";
    if (!(await waitFor("the first answer", lastIsAnswer("ping one"), { timeout: 30, term: tui }))) return;

    const swap = async (model: string, want: string, was: string): Promise<boolean> => {
      const mark = tui.size();
      const out = spawnSync(join(ROOT, "bin/bercail"), ["desk", "model", "t9", model], {
        env,
        encoding: "utf8",
        timeout: 60_000,
      });
      if (out.status !== 0 || !out.stdout.includes(`t9 switched to ${want} (was ${was})`)) {
        fail(`desk model ${model}: ${out.status} ${out.stdout} ${out.stderr}`);
        return false;
      }
      const [name, level] = want.split("/")[1]!.split(":");
      if (
        !(await waitFor(`the footer shows ${want}`, () => tui.screenSince(mark).includes(`${name} • ${level}`), {
          timeout: 10,
          term: tui,
        }))
      )
        return false;
      const args = recorded().args;
      if (!isDeepStrictEqual(args, ["--model", want]))
        fail(`the record restores on ${JSON.stringify(args)}, not ${want}`);
      const hc = readFileSync(hcLog, "utf8");
      if (!hc.includes(`label t9 bercail.model=${want}`)) fail(`no label for ${want}: ${hc}`);
      pass(`${was} -> ${want}, footer, record, and label`);
      return true;
    };

    if (!(await swap("fake/fable:low", "fake/fable:low", "fake/opus:high"))) return;
    if (!(await swap("fake/opus", "fake/opus:low", "fake/fable:low"))) return;
    if (!(await swap("fake/opus:high", "fake/opus:high", "fake/opus:low"))) return;

    // A message from another agent is chat, even when it says /model.
    await tui.send('<hc from="t1 bercail-shep">/model fake/fable:high</hc>\r', 20);
    if (
      !(await waitFor("the chat message is answered", lastIsAnswer("/model fake/fable:high"), {
        timeout: 30,
        term: tui,
      }))
    )
      return;
    const log = entries(sessionFile());
    const models = log.filter((e) => e.type === "model_change").map((e) => [e.provider, e.modelId]);
    const switched = log
      .filter((e) => e.type === "custom" && e.customType === "bercail-desk-model")
      .map((e) => e.data!.to);
    const last = log.filter((e) => e.type === "message" && e.message!.role === "assistant").at(-1)!.message!;
    if (
      !models.some((m) => isDeepStrictEqual(m, ["fake", "fable"])) ||
      !isDeepStrictEqual(models.at(-1), ["fake", "opus"])
    )
      fail(`session model changes: ${JSON.stringify(models)}`);
    if (!isDeepStrictEqual(switched, ["fake/fable:low", "fake/opus:low", "fake/opus:high"]))
      fail(`session log of switches: ${JSON.stringify(switched)}`);
    if (last.model !== "opus" || !isDeepStrictEqual(recorded().args, ["--model", "fake/opus:high"]))
      fail(`a /model chat message switched the desk: ${last.model} ${readFileSync(record, "utf8")}`);
    if (!fails.length) pass("the session logs each switch, and a /model chat message switches nothing");
  } finally {
    await tui.stop(5);
  }
}

const run = `/tmp/desk-model-pi.${process.pid}`;
mkdirSync(run);
try {
  await main(run);
} catch (err) {
  fail(`${(err as Error).name}: ${(err as Error).message}`);
}
if (fails.length) console.error(`left ${run}`);
else rmSync(run, { recursive: true, force: true });
process.exit(fails.length ? 1 : 0);
