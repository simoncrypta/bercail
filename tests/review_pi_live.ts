// review-pr's reviewer on the installed Pi, with a fake model. Headless, review.ts
// blocks a read outside the stack dir. As the review desk (Pi's TUI in a
// terminal), it takes the CLI's turns: bercail's own _review_turn sends one,
// reads its reply, and stops a held one with a cancel.
// Usage: node tests/review_pi_live.ts ROOT PI
import { spawn, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { isDeepStrictEqual } from "node:util";
import { Term, fail, fails, killAll, pass, sleep, waitFor } from "./live_term.ts";

const [ROOT, PI] = process.argv.slice(2) as [string, string];

type Event = { type?: string; message?: { role?: string; content?: unknown[] }; [k: string]: unknown };

function events(path: string): Event[] {
  const out: Event[] = [];
  for (const line of readFileSync(path, "utf8").split("\n")) {
    try {
      out.push(JSON.parse(line));
    } catch {}
  }
  return out;
}

function texts(evs: Event[]): string {
  return evs
    .filter((e) => e.type === "message_end" && e.message?.role === "assistant")
    .flatMap((e) => e.message!.content ?? [])
    .filter((p): p is { text?: string } => typeof p === "object" && p !== null)
    .map((p) => p.text ?? "")
    .join("\n");
}

async function body(run: string): Promise<void> {
  const home = join(run, "home");
  const stack = join(run, "stack");
  mkdirSync(join(home, ".pi/agent"), { recursive: true });
  writeFileSync(
    join(home, ".pi/agent/settings.json"),
    JSON.stringify({ retry: { enabled: false }, compaction: { enabled: false } }),
  );
  mkdirSync(join(stack, "pr-7/abc"), { recursive: true });
  writeFileSync(join(stack, "pr-7/abc/diff.patch"), "+retry\n");
  const secret = join(run, "secret.txt");
  writeFileSync(secret, "OUTSIDE_SECRET\n");
  const env: NodeJS.ProcessEnv = Object.fromEntries(
    Object.entries(process.env).filter(([k]) => !k.startsWith("PI_") && !k.startsWith("HC_") && k !== "BASH_ENV"),
  );
  Object.assign(env, {
    HOME: home,
    PI_CODING_AGENT_DIR: join(home, ".pi/agent"),
    PI_OFFLINE: "1",
    TERM: "xterm-256color",
    __MISE_BASH_ENV_LOADED: "1",
  });
  // The reviewer as review.json has it, on the fake model.
  const argv = [
    PI,
    "--offline",
    "--no-extensions",
    "--no-mcp",
    "--no-skills",
    "--no-prompt-templates",
    "--no-context-files",
    "-e",
    join(ROOT, "tests/review_pi_provider.ts"),
    "-e",
    join(ROOT, "bstack/pi/extensions/review.ts"),
    "--tools",
    "read,grep,find,ls",
    "--model",
    "fake-review/model",
    "--session-dir",
    join(stack, "sessions"),
  ];

  const headless = (prompt: string): string => {
    const r = spawnSync(argv[0]!, [...argv.slice(1), "-p", "--mode", "json", "--", prompt], {
      env,
      cwd: stack,
      encoding: "utf8",
      timeout: 60_000,
    });
    if (r.stderr.includes("Failed to load extension")) fail(`extension did not load: ${r.stderr}`);
    return r.stdout;
  };

  let out = headless(`READ ${secret}`);
  if (out.includes("OUTSIDE_SECRET") || !out.includes("reads only the review stack dir"))
    fail(`a read outside the stack dir was not blocked: ${out.slice(-2000)}`);
  out = headless("READ pr-7/abc/diff.patch");
  if (!out.includes("TOOL_RESULT") || !out.includes("+retry"))
    fail(`a read inside the stack dir failed: ${out.slice(-2000)}`);
  if (!fails.length) pass("headless, review.ts lets the reviewer read the stack dir and nothing outside it");

  // The desk: Pi's TUI in the stack dir, on a session bercail minted.
  const session = "11111111-2222-4333-8444-555555555555";
  await Term.start([...argv, "--session-id", session], { env, cwd: stack, log: join(run, "desk.log") });
  const deskFile = join(stack, "desk/pi.json");
  if (!(await waitFor("desk/pi.json", () => JSON.parse(readFileSync(deskFile, "utf8")).pid > 0))) return;
  const desk = JSON.parse(readFileSync(deskFile, "utf8"));
  if (desk.session !== session) fail(`desk/pi.json names session ${desk.session}, not ${session}`);

  const turnArgs = (out: string, prompt: string) => [
    "-c",
    `set -euo pipefail; source "${ROOT}/lib/common.sh"; source "${ROOT}/lib/review.sh"; ` +
      `R_STACK="${stack}"; _review_turn "$1" "$1.err" "$2" ${session}`,
    "turn",
    out,
    prompt,
  ];

  const passOut = join(stack, "pr-7/abc/pass.jsonl");
  const rc = spawnSync("bash", turnArgs(passOut, "review pr-7"), { env, stdio: "inherit", timeout: 60_000 }).status;
  let evs = events(passOut);
  if (rc !== 0 || !evs.length || !isDeepStrictEqual(evs[0], { type: "session", id: session }))
    fail(`desk turn: rc=${rc} events=${JSON.stringify(evs.slice(0, 2))}`);
  else if (
    !texts(evs).includes("REVIEW_OK review pr-7") ||
    !isDeepStrictEqual(evs.at(-1), { type: "agent_settled", aborted: false })
  )
    fail(`desk turn reply: ${JSON.stringify(evs)}`);
  else pass("the desk takes a turn from _review_turn and writes it in Pi's json shape, on its session");

  const held = join(stack, "summary.jsonl");
  const proc = spawn("bash", turnArgs(held, "HOLD"), { env, stdio: "inherit" });
  const done = () => proc.exitCode !== null || proc.signalCode !== null;
  if (await waitFor("the held turn starts", () => events(held).some((e) => e.type === "session"))) {
    const cancel = spawnSync(
      "bash",
      ["-c", `source "${ROOT}/lib/review.sh"; _review_turn_cancel "$1"`, "cancel", held],
      { env, stdio: "inherit" },
    );
    if (cancel.status !== 0) throw new Error(`_review_turn_cancel exited ${cancel.status}`);
    if (await waitFor("the cancel stops the turn", done, { timeout: 20 })) {
      evs = events(held);
      if (!isDeepStrictEqual(evs.at(-1), { type: "agent_settled", aborted: true }))
        fail(`a cancelled turn: ${JSON.stringify(evs)}`);
      else pass("a cancel aborts the desk's turn");
    }
  }

  // A request whose caller is gone never runs.
  const dead = spawnSync("true").pid;
  const late = join(stack, "late.jsonl");
  const request = join(stack, "desk/inbox/0-late.json");
  writeFileSync(request, JSON.stringify({ prompt: "late", out: late, pid: dead }));
  if (await waitFor("the dead caller's request leaves the inbox", () => !existsSync(request))) {
    await sleep(1000);
    if (existsSync(late)) fail("a request whose caller is gone ran");
    else pass("a request whose caller is gone is dropped");
  }
}

const run = `/tmp/review-pi-live.${process.pid}`;
mkdirSync(run);
try {
  await body(run);
} finally {
  killAll();
  if (!fails.length && !process.env.KEEP) rmSync(run, { recursive: true, force: true });
  else console.error(`kept: ${run}`);
}
process.exit(fails.length ? 1 : 0);
