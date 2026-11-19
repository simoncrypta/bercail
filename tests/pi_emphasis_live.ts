// pi-emphasis on the installed Pi, live: runs the lead a bercail install deployed
// into HOME (its lead.json, the extensions and prompt it names) in a terminal, on
// a fake model. Passes when the model was sent pi-emphasis's reply rules and its
// [[Done]] is drawn as a pill. The bridge comes from npm and the lead's model needs
// a login, so those two are swapped for the fake model; nothing else changes.
// Usage: node tests/pi_emphasis_live.ts ROOT PI HOME
import { existsSync, mkdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { Term, fail, fails, killAll, pass, waitFor } from "./live_term.ts";

const [ROOT, PI, HOME] = process.argv.slice(2) as [string, string, string];
// What the pill shows once escapes are stripped: its check icon, a no-break space, the word.
const PILL = "\uf00c\u00a0Done";

async function body(): Promise<void> {
  const lead: string[] = JSON.parse(readFileSync(join(HOME, ".local/share/bercail/pi/lead.json"), "utf8"));
  const args: string[] = [];
  for (let i = 1; i < lead.length; i++) {
    const [flag, value] = [lead[i]!, lead[i + 1]];
    if (flag === "--model" || (flag === "-e" && value?.startsWith("npm:"))) i++;
    else args.push(flag);
  }
  if (!args.some((a) => a.endsWith("/extensions/pi-emphasis/index.ts")))
    return fail(`the deployed lead does not load pi-emphasis: ${JSON.stringify(lead)}`);
  const run = join(HOME, "pi-emphasis-live");
  const work = join(run, "work");
  mkdirSync(work, { recursive: true });
  const probe = join(run, "context.json");
  const env: NodeJS.ProcessEnv = Object.fromEntries(
    Object.entries(process.env).filter(
      ([k]) => !k.startsWith("PI_") && !k.startsWith("HC_") && !k.startsWith("BERCAIL_"),
    ),
  );
  Object.assign(env, {
    HOME,
    XDG_CONFIG_HOME: join(HOME, ".config"),
    XDG_STATE_HOME: join(HOME, ".local/state"),
    XDG_DATA_HOME: join(HOME, ".local/share"),
    XDG_CACHE_HOME: join(HOME, ".cache"),
    TERM: "xterm-256color",
    COLORTERM: "truecolor",
    PI_OFFLINE: "1",
    PI_EMPHASIS_PROBE: probe,
    __MISE_BASH_ENV_LOADED: "1",
  });
  const argv = [PI, ...args, "-e", join(ROOT, "tests/pi_emphasis_provider.ts"), "--model", "fake-emphasis/model"];
  const tui = await Term.start(argv, { env, cwd: work, log: join(run, "terminal.log") });
  if (!(await waitFor("Pi's TUI", () => tui.screenSince(0).includes("fake-emphasis"), { term: tui }))) return;
  if (tui.screenSince(0).includes("Failed to load extension"))
    return fail(`an extension failed: ${tui.screenSince(0)}`);
  const mark = tui.size();
  await tui.type("Report on the check.");
  if (!(await waitFor("the model's turn", () => existsSync(probe), { term: tui }))) return;
  if (readFileSync(probe, "utf8").includes("These rules shape replies written to the user in this terminal"))
    pass("the model got pi-emphasis's reply rules");
  else fail("the system prompt has no reply rules from pi-emphasis");
  if (await waitFor("the pill on screen", () => tui.screenSince(mark).includes(PILL), { term: tui })) {
    if (tui.screenSince(mark).includes("[[Done]]")) fail("[[Done]] also shows as typed");
    else pass("[[Done]] is drawn as a pill");
  }
  await tui.stop();
}

try {
  await body();
} catch (err) {
  fail(String((err as Error)?.stack ?? err));
} finally {
  killAll();
}
if (fails.length) {
  console.error(`${fails.length} failed; the terminal is in ${join(HOME, "pi-emphasis-live/terminal.log")}`);
  process.exit(1);
}
