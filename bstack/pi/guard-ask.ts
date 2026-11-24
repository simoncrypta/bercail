// The guard's model-free worker for an ask it handed off from Shep's session
// (docs/plans/shep-free-guard.md). No Pi and no model: no turn can rewrite what it runs.
//   bercail guard ask <ticket>   put the card up, wait for the person, run it once on Allow
//   bercail guard check          a guard card's live check: {op, facts} on stdin, {reasons} out
//   bercail guard decide         the guard's decision on a command as Shep: {command, cwd} on stdin
import { execFileSync, spawn } from "node:child_process";
import { closeSync, mkdirSync, openSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  argvText,
  changedFacts,
  cleanEnv,
  decideLive,
  factsDir,
  guardAsks,
  guardDefault,
  guardOperation,
  markStart,
  onDisk,
  opTarget,
  opWhat,
  pinOperation,
  policyFromJson,
  readOut,
  runOf,
  stateDir,
  ticketId,
  urlText,
  type GuardDefault,
  type GuardFacts,
  type GuardInput,
  type GuardOp,
  type GuardTicket,
} from "./extensions/guard.ts";

const bin = () => process.env.BERCAIL_BIN || "bercail";
const poll = () => Number(process.env.BERCAIL_GUARD_ASK_POLL_MS) || 3000;
const runLimit = 3600 * 1000;
// The longest a card that defaults may go unwatched before its deadline, or wait after it:
// many polls. And the time a card must have left when it goes up to default (the
// ledger's GUARD_WINDOW).
const watchGap = 5 * 60 * 1000;
const guardWindow = 50 * 60 * 1000;
type Outcome = "ran" | "unknown" | "denied" | "expired" | "withdrawn" | "changed" | "refused" | "failed";

// bercail shep question OP, its JSON input on stdin: the ledger's only door.
function question(args: string[], input?: unknown): any {
  const out = execFileSync(bin(), ["shep", "question", ...args], {
    input: input === undefined ? "" : JSON.stringify(input),
    encoding: "utf8",
    timeout: 60000,
    stdio: ["pipe", "pipe", "pipe"],
  });
  return JSON.parse(out);
}

// The one guard event, written whole into Shep's inbox as bercail land writes its own.
// defaulted: nobody answered, and the card's default to Allow was recorded at its deadline.
function report(
  ticket: GuardTicket,
  outcome: Outcome,
  extra: { exit?: number; why?: string; log?: string; defaulted?: true } = {},
) {
  const inbox = join(stateDir(), "shep", "inbox");
  mkdirSync(inbox, { recursive: true, mode: 0o700 });
  const event = {
    source: "bercail",
    schema: "bercail.guard_ask/v1",
    kind: "guard",
    sink: "shep",
    at: new Date().toISOString(),
    event_id: `guard:${ticket.id}`,
    terminal: `guard-ask-${ticket.id}`,
    operation: ticket.op.kind,
    target: opTarget(ticket.facts),
    outcome,
    ...extra,
  };
  const file = join(inbox, `guard-${ticket.id}.json`);
  writeFileSync(`${file}.tmp`, `${JSON.stringify(event)}\n`, { mode: 0o600 });
  renameSync(`${file}.tmp`, file);
  console.log(`${outcome}${extra.why ? `: ${extra.why}` : ""}`);
}

// HH:MM of an ISO time on this machine's clock, as the panel shows it.
function clock(iso: string): string {
  const d = new Date(iso);
  return `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
}

// What happens when nobody answers by the deadline, for the card and the notice.
const atDeadline = (ticket: GuardTicket, cls: GuardDefault) =>
  cls.defaults
    ? `It defaults to Allow at ${clock(ticket.expires)}: nobody answering by then counts as an Allow, because ${cls.why}, if that still holds then.`
    : `It waits for you: nobody answering by ${clock(ticket.expires)} counts as a Deny, because ${cls.why}.`;

// What the card says: the operation and every fact it is pinned to, and its deadline.
function brief(ticket: GuardTicket, cls: GuardDefault): string {
  const f = ticket.facts;
  const facts =
    f.kind === "command"
      ? `${argvText(f.argv)} in ${f.dir}, as these ${f.argv.length} words with no shell`
      : f.kind === "cleanup" && "gone" in f
        ? `bercail cleanup --gone ${f.path}, the gone checkout a handoff of ${f.repo} names (branch ${f.branch ?? "none"}): it records it as retired and removes nothing`
        : f.kind === "cleanup"
          ? `bercail cleanup of ${f.worktree} (branch ${f.branch ?? "detached"}, HEAD ${f.head})`
          : f.kind === "trail merge"
            ? `${f.job ? `bercail job merge ${f.job} --change` : "entire trail merge"} ${f.change} in ${f.checkout}: trail ${f.trailId}, head ${f.head}, into ${f.base}${f.job ? `, then closes ${f.job} once no change is open` : ""}`
            : `git push from ${f.dir} (git dir ${f.gitDir}) to ${urlText(f.url)}: ${f.refspecs.join(", ")}`;
  return `Shep ran: ${ticket.command}. On Allow, its worker guard-ask-${ticket.id} runs ${facts}, once, and only if none of that has changed. ${atDeadline(ticket, cls)}`;
}

// The facts the operation pins to now, and what changed, or why it no longer pins.
async function changed(op: GuardOp, was: GuardFacts): Promise<string[]> {
  try {
    return changedFacts(was, await pinOperation(op));
  } catch (error) {
    return [`no longer pins: ${(error as Error).message}`];
  }
}

const sleep = (ms: number) => new Promise((done) => setTimeout(done, ms));

// The guard's decision on Shep's command now, as role shep with the person asked out of
// band, and its lookups made with the same reads the guard's are.
async function decideNow(ticket: Pick<GuardTicket, "command" | "cwd">) {
  const home = process.env.HOME;
  const config =
    process.env.BERCAIL_CONFIG ||
    join(process.env.XDG_CONFIG_HOME || join(home ?? "", ".config"), "bercail/config.toml");
  const input: GuardInput = {
    role: "shep",
    hasUI: true,
    cwd: ticket.cwd,
    home,
    protectedFiles: [
      join(stateDir(), "policy-trust.json"),
      join(stateDir(), "shep/questions.json"),
      join(stateDir(), "shep/questions.lock"),
      config,
    ],
    protectedDirs: [join(stateDir(), "shep"), guardAsks()],
    todoFiles: [join(config, "..", "todo.json")],
    readOnlyWrites: { tmp: ["/tmp"], root: ticket.cwd, exists: onDisk },
  };
  return decideLive("bash", ticket.command, input, undefined, {
    branch: (dir) => readOut("git", ["-C", dir, "rev-parse", "--abbrev-ref", "HEAD"], dir).catch(() => ""),
    policy: async (dir) =>
      policyFromJson(
        await readOut(bin(), ["policy", "show", "--json", dir], dir)
          .then((out) => JSON.parse(out))
          .catch(() => undefined),
      ),
    entireHelp: async (key) => {
      const out = await readOut("entire", ["agent-help", ...(key ? [key] : []), "--json"], ticket.cwd).catch(
        () => "{}",
      );
      const subs = (JSON.parse(out) as { subcommands?: { name?: unknown; audience?: unknown }[] }).subcommands ?? [];
      return subs
        .filter((sub) => sub.audience === "read-only" && typeof sub.name === "string")
        .map((s) => s.name as string);
    },
  });
}

// The pinned argv, once: its own process group, stdin closed, output to the log, an hour at most.
function run(ticket: GuardTicket, log: string): Promise<{ exit?: number }> {
  const { argv, cwd } = runOf(ticket.facts);
  const fd = openSync(log, "a", 0o600);
  return new Promise((done) => {
    const child = spawn(argv[0], argv.slice(1), { cwd, env: cleanEnv(), stdio: ["ignore", fd, fd], detached: true });
    // A worker told to stop ends the group first, so nothing runs on unwatched.
    const end = () => {
      try {
        process.kill(-child.pid!, "SIGKILL");
      } catch {}
    };
    const limit = setTimeout(end, runLimit);
    for (const signal of ["SIGTERM", "SIGINT", "SIGHUP"] as const) process.on(signal, end);
    child.on("error", (error) => {
      clearTimeout(limit);
      writeFileSync(fd, `${error.message}\n`);
      done({ exit: 127 });
    });
    child.on("exit", (code) => {
      clearTimeout(limit);
      closeSync(fd);
      done(code === null ? {} : { exit: code });
    });
  });
}

async function ask(id: string) {
  if (!ticketId.test(id)) throw new Error(`${id} is not a guard ticket`);
  const ticket = JSON.parse(readFileSync(join(guardAsks(), `${id}.json`), "utf8")) as GuardTicket;
  if (ticket.id !== id) throw new Error(`ticket ${id} names another id`);
  // The guard gave up on this start: no card.
  if (markStart(id, "started") !== "started") return console.log("void: the guard refused it before this started");
  try {
    await handle(ticket);
  } catch (error) {
    // Nothing ran: run() reports its own end, and nothing after it throws. A card it put
    // up, even one whose reply it lost, leaves the panel: no worker would act on it.
    try {
      const own = question(["pending"]).pending.find((q: any) => q.guard?.ticket === id && q.status === "pending");
      if (own)
        question(["withdraw"], {
          requestId: `guard-${id}-failed`,
          token: `${own.id}@${own.revision}`,
          reason: "its worker stopped",
        });
    } catch {}
    report(ticket, "failed", {
      why: String((error as { stderr?: string }).stderr || error)
        .trim()
        .split("\n")[0],
    });
  }
}

async function handle(ticket: GuardTicket) {
  const id = ticket.id;
  const worker = `guard-ask-${id}`;
  // Whether nobody answering counts as an Allow: read before the card goes up, so the card
  // says it. A card going up with less than most of its hour left waits for the person.
  const read = await guardDefault(ticket.facts);
  const cls: GuardDefault =
    Date.parse(ticket.expires) - Date.now() < guardWindow
      ? { defaults: false, why: "its card went up with less than most of its hour left" }
      : read;
  const card = question(["guard-create"], {
    requestId: `guard-${id}`,
    prompt: ticket.reason,
    brief: brief(ticket, cls),
    origin: { event: `guard:${id}`, session: ticket.shep.session || "unknown", entry: null },
    // The card binds to the repo whose policy speaks for it.
    dir: factsDir(ticket.facts),
    guard: {
      ticket: id,
      worker,
      op: ticket.op,
      facts: ticket.facts,
      expires: ticket.expires,
      ...(cls.defaults ? { defaults: { why: cls.why } } : {}),
    },
  });
  // The card's own word on its default: a replayed create keeps the first one.
  const said: string | undefined = card.guard?.defaults?.why;
  const token = `${card.id}@${card.revision}`;
  // The panel often starts hidden: a desktop notice says a card is up. Not awaited.
  try {
    const when = said ? `It defaults to Allow at ${clock(ticket.expires)}.` : "It waits for you.";
    spawn("notify-send", ["Bercail", `Decisions: allow ${opWhat(ticket.facts)}? ${when}`], {
      stdio: "ignore",
      detached: true,
    })
      .on("error", () => {})
      .unref();
  } catch {}
  const withdraw = (reason: string) => {
    try {
      question(["withdraw"], { requestId: `guard-${id}-withdraw`, token, reason });
      return true;
    } catch {
      return false;
    }
  };
  // When the worker last saw the card pending before its deadline. A default needs it seen
  // in the last minutes before its deadline and acted on in the first minutes after:
  // a machine that slept through it gave the person no hour, or acts on a stale reading.
  let seenAt = 0;
  const watched = (now: number) =>
    Date.parse(ticket.expires) - seenAt <= watchGap && now - Date.parse(ticket.expires) <= watchGap;
  for (;;) {
    const q = question(["get", token]);
    const now = Date.now();
    if (q.status === "withdrawn") return report(ticket, "withdrawn", { why: q.withdrawal?.reason });
    if (q.status === "answered") {
      if (q.answer.choice !== "Allow") return report(ticket, "denied");
      break;
    }
    if (q.status !== "pending") return report(ticket, "failed", { why: `its card is ${q.status}` });
    if (Date.parse(ticket.expires) <= now) {
      // A card that said it defaults reads the class and the facts again: the same reading,
      // nothing moved, and the ledger records the default unless the person's pick came first.
      let why = "nobody answered within the hour";
      const unwatched = "its card was not watched through its deadline (the machine slept, or the worker was late)";
      if (said && !watched(now)) why = unwatched;
      else if (said) {
        const reading = await guardDefault(ticket.facts);
        const moved = await changed(ticket.op, ticket.facts);
        if (reading.defaults && reading.why === said && !moved.length) {
          if (!watched(Date.now())) why = unwatched;
          else {
            const took = question(["guard-default", token, id], { why: reading.why });
            if (took.accepted) break;
            // The person's pick or Close came first: read the card again. A refusal of a
            // card still pending never changes, so it expires as a Deny.
            if (took.question?.status !== "pending") continue;
            why = `nobody answered, and the ledger refused its default: ${took.reason}`;
          }
        } else why = `nobody answered, and at the deadline ${moved.length ? moved.join(", ") : reading.why}`;
      }
      if (withdraw(`expired: ${why}`)) return report(ticket, "expired", said ? { why } : {});
      continue;
    }
    seenAt = now;
    const moved = await changed(ticket.op, ticket.facts);
    if (moved.length) {
      if (withdraw(`changed since it was asked: ${moved.join(", ")}`))
        return report(ticket, "changed", { why: moved.join(", ") });
      continue;
    }
    await sleep(poll());
  }
  // Once claimed, never run again: a second worker, or a restart, stops here.
  const claim = question(["guard-claim", token, id]);
  if (!claim.accepted) return console.log(`not run: ${claim.reason}`);
  // What the claim took, the person's Allow or the card's default, decides the checks and the event.
  const defaulted: { defaulted?: true } =
    claim.question.answer.source === "guard default at expiry" ? { defaulted: true } : {};
  // What the card showed is what runs: a ticket rewritten since then runs nothing.
  if (JSON.stringify(JSON.parse(readFileSync(join(guardAsks(), `${id}.json`), "utf8"))) !== JSON.stringify(ticket))
    return report(ticket, "changed", { why: "its ticket changed since the card went up", ...defaulted });
  const { decision } = await decideNow(ticket);
  if (decision.action === "block") return report(ticket, "refused", { why: decision.reason, ...defaulted });
  const again = guardOperation(ticket.command, ticket.cwd, process.env.HOME);
  if (typeof again === "string" || JSON.stringify(again) !== JSON.stringify(ticket.op))
    return report(ticket, "changed", { why: "the command no longer reads as the same operation", ...defaulted });
  const moved = await changed(ticket.op, ticket.facts);
  if (moved.length) return report(ticket, "changed", { why: moved.join(", "), ...defaulted });
  // A default runs only while it still reads as the card said, right before the run, and
  // soon after its deadline.
  if (defaulted.defaulted) {
    const reading = await guardDefault(ticket.facts);
    if (!reading.defaults || reading.why !== said)
      return report(ticket, "expired", {
        why: `nobody answered, and right before the run ${reading.why}`,
        ...defaulted,
      });
    if (Date.now() - Date.parse(ticket.expires) > 2 * watchGap)
      return report(ticket, "expired", {
        why: "nobody answered, and it came too long after its deadline",
        ...defaulted,
      });
  }
  const log = join(guardAsks(), `${id}.log`);
  const ran = await run(ticket, log);
  if (ran.exit === undefined) report(ticket, "unknown", { why: "killed before it finished", log, ...defaulted });
  else report(ticket, "ran", { exit: ran.exit, log, ...defaulted });
}

// A guard card's live check: what changed since its facts were pinned.
async function check() {
  const { op, facts } = JSON.parse(readFileSync(0, "utf8"));
  if (!["cleanup", "trail merge", "push", "command"].includes(op?.kind) || op.kind !== facts?.kind)
    throw new Error("check reads {op, facts} of one guard operation on stdin");
  console.log(JSON.stringify({ reasons: await changed(op, facts) }));
}

// What the guard decides on a command Shep would run, and the operation and facts it pins
// to, for the land worker's veto before each effect (lib/land.sh). It reads; it runs nothing.
async function decide() {
  const { command, cwd } = JSON.parse(readFileSync(0, "utf8"));
  if (typeof command !== "string" || typeof cwd !== "string" || !command || !cwd)
    throw new Error("decide reads {command, cwd} on stdin");
  const { decision } = await decideNow({ command, cwd });
  const op = guardOperation(command, cwd, process.env.HOME);
  let facts: GuardFacts | null = null;
  let why: string | null = typeof op === "string" ? op : null;
  if (typeof op !== "string")
    try {
      facts = await pinOperation(op);
    } catch (error) {
      why = (error as Error).message;
    }
  console.log(
    JSON.stringify({
      action: decision.action,
      reason: "reason" in decision ? (decision.reason ?? null) : null,
      op: typeof op === "string" ? null : op,
      facts,
      why,
    }),
  );
}

async function main() {
  const [cmd, ...args] = process.argv.slice(2);
  if (cmd === "ask" && args.length === 1) return ask(args[0]);
  if (cmd === "check" && !args.length) return check();
  if (cmd === "decide" && !args.length) return decide();
  throw new Error("usage: bercail guard ask <ticket> | bercail guard check | bercail guard decide");
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((error) => {
    console.error(`bercail guard: ${(error as Error).message}`);
    process.exitCode = 1;
  });
}
