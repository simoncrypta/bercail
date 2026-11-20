// Dispatch: start a task's first visible desk, or queue a follow-up into the
// original desk's session. The issue keeps who owns the task; the file queue
// carries the message to that Pi. Neither grants shipping authority.
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  readlinkSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { basename, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

type Owner = {
  desk: string;
  space: string;
  cwd: string;
  branch: string;
  session: string;
  session_file: string;
  pid: number;
  start_ticks: string;
};
// What Shep asked for. A retry repeats its id and payload.
type Request = { id: string; payload: string; stage: string; message: string };
// The task's latest desk creation: a retry of its id finishes an UNKNOWN one,
// and a retry once it started binds the new desk and queues its message.
type Creation = Request & {
  status: "creating" | "unknown" | "started";
  next: string;
  reason?: string;
  result?: any;
};
type Task = {
  v: number;
  repo: string;
  target: string;
  aliases?: string[];
  owner: Owner | null;
  branch: string;
  creation?: Creation;
  // Request ids that never reach a desk again: a creation an adoption replaced,
  // and v0.17 requests other than its creation. A queued one finds its file first.
  retired?: string[];
  // Follow-ups saved for owner whose queue file is not written yet, by request
  // id, with their payload. A retry must match it and re-verifies owner; an
  // adoption retires them.
  pending?: Record<string, string>;
  forkReason?: string;
  adoptions?: Adoption[];
  // A v0.17 request ledger; save drops it.
  requests?: any[];
};
// A v0.17 record keeps its creation in the request ledger: the last request that
// started a desk, or was still starting one, unless it was blocked. Its payload
// was hashed another way, so a retry of it is checked on its message and stage.
// Every other request it holds is retired, as v0.17 never sent them again.
function migrated(task: Task | undefined): Task | undefined {
  if (!task || task.creation || !Array.isArray(task.requests)) return task;
  const last = task.requests.findLast(
    (r) =>
      (r.creation && !["blocked", "complete"].includes(r.status)) ||
      ["creating", "unknown", "awaiting-session"].includes(r.status),
  );
  if (last)
    task.creation = {
      id: last.id,
      payload: "",
      stage: last.stage || "bstack",
      message: last.message || "",
      status: last.status === "creating" || last.status === "unknown" ? last.status : "started",
      next: last.next || "",
      ...(last.reason ? { reason: last.reason } : {}),
      ...(last.creation ? { result: last.creation } : {}),
    };
  task.retired = task.requests.filter((r) => r !== last).map((r) => r.id);
  return task;
}
// A new desk on a gone owner's checkout, and why. The desks it names are gone.
// staged: the files staged there, which the person has not reviewed.
type Adoption = {
  request: string;
  reason: string;
  at: string;
  path: string;
  branch: string;
  staged: number;
  from: { desk: string; session: string; space: string }[];
};
// A retry asks for the same work: the same payload, or, for a v0.17 request
// whose payload was hashed another way, the same message and stage.
function same(stored: Request, request: Request): boolean {
  return stored.payload
    ? stored.payload === request.payload
    : stored.message === request.message && (stored.stage || "bstack") === request.stage;
}
const state = () => join(process.env.XDG_STATE_HOME || join(process.env.HOME!, ".local/state"), "bercail");
const bin = (name: string) => process.env[`${name.toUpperCase()}_BIN`] || name;
function run(command: string, args: string[], cwd: string, timeout = 3000, input?: string): string {
  return execFileSync(command, args, {
    cwd,
    timeout,
    env: {
      ...Object.fromEntries(Object.entries(process.env).filter(([k]) => !/^(BD_|BEADS_|GIT_)/.test(k))),
      GIT_TERMINAL_PROMPT: "0",
      GH_PROMPT_DISABLED: "1",
    },
    encoding: "utf8",
    input,
    stdio: ["pipe", "pipe", "pipe"],
    maxBuffer: 4 * 1024 * 1024,
  }).trim();
}
function json(path: string): any {
  return JSON.parse(readFileSync(path, "utf8"));
}
function git(repo: string, ...args: string[]): string {
  return run("git", args, repo);
}
function bd(repo: string, ...args: string[]): any {
  const out = run(process.env.HANDOFF_BD_BIN || bin("bd"), args, repo);
  return out ? JSON.parse(out) : null;
}
function issue(repo: string, id: string): any {
  const raw = bd(repo, "show", id, "--json");
  const value = Array.isArray(raw) ? raw[0] : raw;
  if (value?.id !== id) throw new Error(`bd does not know ${id} in ${repo}`);
  return value;
}
// Write the task and, unless reopen is false, set the issue in progress. Keep
// unrelated metadata. A failed reservation stops dispatch before the desk or
// its queue file sees anything; a retry reads that reservation first.
function save(repo: string, value: any, task: Task, reopen = true): void {
  const file = join(
    git(repo, "rev-parse", "--path-format=absolute", "--git-common-dir"),
    "bercail-task.lock/metadata.json",
  );
  delete task.requests;
  task.v = 2;
  // bd 1.3.1 --metadata merges inside the storage transaction. Submit only
  // this namespace; resubmitting other keys would overwrite concurrent edits.
  writeFileSync(file, JSON.stringify({ bercail_task: task }), { mode: 0o600 });
  try {
    bd(repo, "update", value.id, "--metadata", `@${file}`, ...(reopen ? ["--status", "in_progress"] : []), "--json");
  } finally {
    rmSync(file);
  }
}
export function logicalTarget(text: string): string {
  const pr = /^(?:pr:|https:\/\/github\.com\/[^/]+\/[^/]+\/pull\/)([1-9][0-9]*)\/?$/i.exec(text);
  if (pr) return `pr:${pr[1]}`;
  if (/^task:[a-z0-9][a-z0-9._-]*$/i.test(text)) return text.toLowerCase();
  throw new Error("target must be pr:N, a GitHub PR URL, or task:ID (never a branch name)");
}
function mainOf(path: string): string {
  const first = git(realpathSync(path), "worktree", "list", "--porcelain").split("\n")[0]!;
  return realpathSync(first.slice("worktree ".length));
}
function records(repo: string): any[] {
  const path = join(state(), "handoffs.jsonl");
  if (!existsSync(path)) return [];
  return readFileSync(path, "utf8")
    .split("\n")
    .filter(Boolean)
    .flatMap((line) => {
      let record: any;
      try {
        record = JSON.parse(line);
      } catch {
        throw new Error("malformed handoff record; ownership UNKNOWN, no launch");
      }
      if (!record.path) return [];
      try {
        return mainOf(record.path) === repo ? [record] : [];
      } catch {
        return !record.repo || record.repo === repo ? [{ ...record, unresolved: true }] : [];
      }
    });
}
export function processTicks(pid: number): string {
  const stat = readFileSync(`/proc/${pid}/stat`, "utf8");
  return stat.slice(stat.lastIndexOf(")") + 2).split(/\s+/)[19]!;
}
// Every live terminal in this repository's checkouts, as hc get prints it.
function terminalsIn(repo: string): any[] {
  const snapshot = JSON.parse(run(bin("hc"), ["ls", "--json"], repo));
  if (!Array.isArray(snapshot.terminals)) throw new Error("hc returned no terminal snapshot; owner UNKNOWN");
  // hc ls is a summary with no labels. Read candidates from this repository,
  // then verify their complete records; never infer absence from summary fields.
  return snapshot.terminals
    .filter((t: any) => {
      if (t.state !== "live" || !t.cwd) return false;
      try {
        return mainOf(t.cwd) === repo;
      } catch {
        return false;
      }
    })
    .map((t: any) => JSON.parse(run(bin("hc"), ["get", t.address, "--json"], repo)))
    .filter((t: any) => t.state === "live");
}
function live(repo: string): any[] {
  return terminalsIn(repo).filter(
    (t: any) => t.labels?.["bercail.role"] === "agent" && t.labels?.["bercail.shep"] !== "bg",
  );
}
// The checkout of branch, as git lists it (its folder may be gone), or null.
function worktreeOf(repo: string, branch: string): string | null {
  let path: string | null = null;
  for (const line of git(repo, "worktree", "list", "--porcelain").split("\n")) {
    if (line.startsWith("worktree ")) path = line.slice("worktree ".length);
    else if (line === `branch refs/heads/${branch}` && path) return existsSync(path) ? realpathSync(path) : path;
  }
  return null;
}
// Issues closed with `bd supersede <it> --with <id>`: each hands its target to id.
function supersededBy(all: any[], id: string): Set<string> {
  return new Set(
    all
      .filter(
        (i: any) =>
          i.id !== id &&
          i.status === "closed" &&
          i.dependencies?.some((d: any) => d.type === "supersedes" && d.depends_on_id === id),
      )
      .map((i: any) => i.id),
  );
}
function allIssues(repo: string): any[] {
  const all = bd(repo, "list", "--all", "--json", "--limit", "0");
  if (!Array.isArray(all)) throw new Error("bd ownership lookup unavailable; no launch occurred");
  return all;
}
function prFacts(
  repo: string,
  target: string,
): { headRefName: string; headRefOid: string; isCrossRepository: boolean } {
  return JSON.parse(
    run(bin("gh"), ["pr", "view", target.slice(3), "--json", "headRefName,headRefOid,isCrossRepository"], repo),
  );
}
function verify(repo: string, terminal: any, id: string, saved?: Owner | null): Owner {
  const address = terminal.address;
  if (!/^[a-z0-9_-]+$/i.test(address)) throw new Error("invalid desk address");
  const path = join(state(), "desk-sessions", `${address}.json`);
  if (!existsSync(path)) throw new Error(`missing desk record for ${address}; no replacement was started`);
  const r = json(path);
  const t = JSON.parse(run(bin("hc"), ["get", address, "--json"], repo));
  if (
    t.state !== "live" ||
    r.harness !== "pi" ||
    r.issue !== id ||
    r.address !== address ||
    t.labels?.["bercail.role"] !== "agent" ||
    t.labels?.["bercail.shep"] === "bg" ||
    t.labels?.["bercail.issue"] !== id ||
    t.labels?.["bercail.space"] !== r.space ||
    !r.space ||
    !Number.isSafeInteger(r.pid) ||
    r.pid <= 0 ||
    !r.session ||
    r.follow_up !== 1 ||
    !r.start_ticks ||
    realpathSync(t.cwd) !== realpathSync(r.cwd) ||
    mainOf(r.cwd) !== repo
  ) {
    throw new Error(`stale or unsupported visible owner ${address}; inspect its record/profile, do not replace it`);
  }
  if (processTicks(r.pid) !== r.start_ticks) throw new Error(`stale process for ${address}`);
  if (
    basename(readlinkSync(`/proc/${r.pid}/exe`)) !== "pi" ||
    realpathSync(`/proc/${r.pid}/cwd`) !== realpathSync(r.cwd)
  )
    throw new Error("record does not name a live Pi in the original checkout");
  let foreground = t.foreground?.pid;
  for (let depth = 0; foreground && foreground !== r.pid && depth < 32; depth++) {
    const stat = readFileSync(`/proc/${foreground}/stat`, "utf8");
    foreground = Number(stat.slice(stat.lastIndexOf(")") + 2).split(/\s+/)[1]);
  }
  if (foreground !== r.pid) throw new Error("record PID is not the visible desk's foreground Pi/ancestor");
  const runtime = process.env.XDG_RUNTIME_DIR;
  const claim = runtime && json(join(runtime, "bercail/open-sessions", `${r.pid}.json`));
  if (
    !claim ||
    claim.pid !== r.pid ||
    claim.start_ticks !== r.start_ticks ||
    !claim.sessions?.includes(r.session) ||
    !r.session_file
  )
    throw new Error("original live session claim/file missing or stale");
  for (const file of readdirSync(join(runtime!, "bercail/open-sessions")).filter((f) => f.endsWith(".json"))) {
    const other = json(join(runtime!, "bercail/open-sessions", file));
    if (other.pid === r.pid || !Number.isSafeInteger(other.pid) || !other.sessions?.includes(r.session)) continue;
    let active = false;
    try {
      active =
        processTicks(other.pid) === other.start_ticks && basename(readlinkSync(`/proc/${other.pid}/exe`)) === "pi";
    } catch {}
    if (active)
      throw new Error(
        "ambiguous exact-session process claims, independent of role labels; stop the competing writer before continuing the original session",
      );
  }
  const header = JSON.parse(readFileSync(r.session_file, "utf8").split("\n")[0]!);
  if (header.type !== "session" || header.id !== r.session || realpathSync(header.cwd) !== realpathSync(r.cwd))
    throw new Error("original persisted session header mismatch");
  const owner = {
    desk: address,
    space: r.space,
    cwd: realpathSync(r.cwd),
    branch: git(r.cwd, "branch", "--show-current"),
    session: r.session,
    session_file: realpathSync(r.session_file),
    pid: r.pid,
    start_ticks: r.start_ticks,
  };
  if (saved && (Object.keys(owner) as (keyof Owner)[]).some((key) => owner[key] !== saved[key]))
    throw new Error(
      "original owner/session/branch changed; no request or authority transfers to a replacement session",
    );
  return owner;
}
// An adoption starts a new ownership epoch: the records before it name desks
// that are gone, so they neither own the task nor conflict with its new desk.
function owned(history: any[], id: string, target: string, fork: boolean): any[] {
  const handoffs = history.filter((r) => r.issue === id || (!fork && r.target === target));
  const epoch = handoffs.findLastIndex((r) => r.issue === id && r.adoptReason);
  return epoch < 0 ? handoffs : handoffs.slice(epoch);
}
// The gone owner's one checkout, checked before anything is recorded. A live
// desk there, or two recorded checkouts, stops it: adoption replaces nothing.
function adoptable(repo: string, id: string, target: string, task: Task | undefined, history: any[], input: any) {
  const gone = [
    ...(task?.owner ? [{ ...task.owner, path: task.owner.cwd }] : []),
    ...owned(history, id, target, !!task?.forkReason).filter((r) => r.path),
  ];
  if (!gone.length) throw new Error("nothing recorded to adopt; adoption is only for a recorded owner that is gone");
  const paths = [...new Set(gone.map((r) => (existsSync(r.path) ? realpathSync(r.path) : r.path)))];
  const branches = [...new Set([...gone.map((r) => r.branch), task?.branch, input.branch].filter(Boolean))];
  if (paths.length > 1 || branches.length > 1)
    throw new Error(
      `ambiguous recorded checkouts (${[...paths, ...branches].join(", ")}); reconcile them, no adoption`,
    );
  const [path] = paths;
  const branch = branches[0];
  if (!branch) throw new Error(`no branch recorded for ${path}; inspect it, no adoption`);
  if (path === repo)
    throw new Error("the recorded checkout is the main checkout; adoption takes only a branch worktree");
  if (!existsSync(path))
    throw new Error(`recorded checkout ${path} is gone; adoption continues a checkout, it never creates one`);
  if (mainOf(path) !== repo || git(path, "branch", "--show-current") !== branch)
    throw new Error(`${path} is no longer ${branch} in this repo; inspect it, no adoption`);
  const occupant = live(repo).find((t) => realpathSync(t.cwd) === path);
  if (occupant)
    throw new Error(
      `checkout ${path} has live desk ${occupant.address}; adoption never replaces a live desk: close it, or continue its own task`,
    );
  if (target.startsWith("pr:")) {
    const pr = prFacts(repo, target);
    if (pr.isCrossRepository || pr.headRefName !== branch)
      throw new Error(`${target} is not bound to the adopted branch ${branch}; no adoption`);
  }
  const from = [...new Map(gone.filter((r) => r.desk).map((r) => [r.desk, r])).values()].map((r) => ({
    desk: r.desk,
    session: r.session || "",
    space: r.space || "",
  }));
  // Desks stage for the person's review, so a staged change there is unreviewed.
  const staged = git(path, "diff", "--cached", "--name-only").split("\n").filter(Boolean).length;
  return { path, branch, from, staged };
}
// The live desk that owns the task, or null when none is live: its records
// then name a gone owner, or no owner at all. A recorded desk whose terminal is
// still live is not gone, whatever its labels say.
function findOwner(
  repo: string,
  id: string,
  target: string,
  saved?: Owner | null,
  fork = false,
  history = records(repo),
): Owner | null {
  const handoffs = owned(history, id, target, fork);
  if (handoffs.some((r) => r.unresolved))
    throw new Error("stale/unresolved original checkout record; reconcile it before creating another desk");
  const candidates = live(repo).filter((t) => {
    if (saved?.desk === t.address || handoffs.some((r) => r.desk === t.address)) return true;
    // Labels find candidates, never establish ownership.
    if (t.labels?.["bercail.issue"] !== id) return false;
    try {
      return mainOf(t.cwd) === repo;
    } catch {
      return false;
    }
  });
  if (candidates.length > 1)
    throw new Error(
      `ambiguous owners ${candidates.map((t) => t.address).join(", ")}; reconcile the original desks explicitly, no launch occurred`,
    );
  if (!candidates.length) {
    const recorded = new Set([saved?.desk, ...handoffs.map((r) => r.desk)].filter(Boolean));
    const still = !recorded.size
      ? []
      : JSON.parse(run(bin("hc"), ["ls", "--json"], repo))
          .terminals.filter((t: any) => t.state === "live" && recorded.has(t.address))
          .map((t: any) => t.address);
    if (still.length)
      throw new Error(
        `recorded desk ${still.join(", ")} is still live but not a verifiable desk; inspect it, no adoption or launch occurred`,
      );
    return null;
  }
  const owner = verify(repo, candidates[0], id, saved);
  if (
    handoffs.some(
      (r) =>
        (r.desk && r.desk !== owner.desk) ||
        (r.session && r.session !== owner.session) ||
        (r.space && r.space !== owner.space) ||
        (r.branch && r.branch !== owner.branch) ||
        realpathSync(r.path) !== owner.cwd,
    )
  )
    throw new Error(
      "original handoff mapping conflicts with the live session/space/branch; no adoption or replacement",
    );
  return owner;
}
// A follow-up's file name ends in a hash of the request, so a retry finds it
// under whichever desk it went to, after an adoption too.
const sentAs = (repo: string, id: string, request: Request) =>
  `-${createHash("sha256").update(`${repo}\0${id}\0${request.id}`).digest("hex")}.json`;
function queued(repo: string, id: string, request: Request): { path: string; file: any } | null {
  const root = join(state(), "desk-follow-ups");
  if (!existsSync(root)) return null;
  for (const desk of readdirSync(root, { withFileTypes: true }).filter((d) => d.isDirectory())) {
    const hit = readdirSync(join(root, desk.name)).find((f) => f.endsWith(sentAs(repo, id, request)));
    if (hit) return { path: join(root, desk.name, hit), file: json(join(root, desk.name, hit)) };
  }
  return null;
}
// Write the follow-up for owner's desk; dispatch looked for an earlier one first.
// Its name starts with a number above the desk's others (the time, unless the
// clock went back), so the desk takes them in dispatch order.
function queue(repo: string, id: string, owner: Owner, request: Request): string {
  const dir = join(state(), "desk-follow-ups", owner.desk);
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  const last = Math.max(0, ...readdirSync(dir).map((f) => Number(/^(\d+)-/.exec(f)?.[1] || 0)));
  const path = join(dir, `${String(Math.max(Date.now(), last + 1)).padStart(15, "0")}${sentAs(repo, id, request)}`);
  writeFileSync(
    path,
    JSON.stringify({ v: 2, repo, issue: id, owner, request, delivery: "queued", authority: false }) + "\n",
    { mode: 0o600, flag: "wx" },
  );
  return path;
}

// What a creation whose spawn ended without a desk left: no handoffs.jsonl line
// for the issue (the spawn writes one when it finishes), no desk for it, and at
// most the branch's clean worktree, where only idle shells run. Returns that
// worktree, or null when there is none; throws why the outcome stays UNKNOWN.
function leftover(repo: string, id: string, branch: string, history: any[], prHead: string): string | null {
  if (history.some((r) => r.issue === id))
    throw new Error("handoffs.jsonl has a line for this issue, so the spawn finished; inspect what it says");
  const terminals = terminalsIn(repo);
  const desk = terminals.find((t) => t.labels?.["bercail.issue"] === id);
  if (desk) throw new Error(`terminal ${desk.address} is live for ${id}; inspect it`);
  const path = worktreeOf(repo, branch);
  if (!path) return null;
  if (path === repo) throw new Error(`${branch} is checked out in the main checkout; inspect it`);
  if (!existsSync(path)) throw new Error(`the worktree of ${branch}, ${path}, is gone; run git worktree prune`);
  if (git(path, "status", "--porcelain", "--untracked-files=all"))
    throw new Error(`${path} has changes; inspect them before a desk starts there`);
  const head = git(path, "rev-parse", "HEAD");
  if (prHead && head !== prHead)
    throw new Error(`${path} is at ${head}, not the PR head ${prHead}; remove it (wt remove ${branch}) and retry`);
  const busy = terminals.find(
    (t) =>
      (realpathSync(t.cwd) === path || realpathSync(t.cwd).startsWith(`${path}/`)) &&
      (t.labels?.["bercail.role"] || !/^(ba|z|fi|da|k)?sh$/.test(t.foreground?.name || "")),
  );
  if (busy) throw new Error(`terminal ${busy.address} in ${path} is not an idle shell; inspect it`);
  return path;
}

// Seconds handoff-spawn may run: [shep] spawn_timeout, which bercail passes in.
// A large repo's worktree and its hooks can take minutes.
function spawnTimeout(): number {
  const raw = process.env.BERCAIL_SPAWN_TIMEOUT || "600";
  if (!/^[1-9][0-9]*$/.test(raw))
    throw new Error(`[shep] spawn_timeout must be a whole number of seconds, not ${raw}; no launch occurred`);
  return Number(raw);
}

type Spawn = {
  existing: boolean;
  reuse: boolean;
  released: Set<string>;
  adoption: ReturnType<typeof adoptable> | null;
  forkReason?: string;
  adoptReason?: string;
};
// Start the visible desk for task.creation. timeout runs the spawn in its own
// process group and kills the whole group when time runs out, so nothing it
// started is still on its way to a desk when the creation turns UNKNOWN.
function create(repo: string, value: any, task: Task, opts: Spawn): any {
  const creation = task.creation!;
  const spawn =
    process.env.BERCAIL_HANDOFF_SPAWN || join(process.env.HOME!, ".agents/skills/handoff/scripts/handoff-spawn");
  const secs = spawnTimeout();
  try {
    let out: string;
    try {
      out = run(
        "timeout",
        [
          "--kill-after=10",
          String(secs),
          "env",
          "BERCAIL_TASK_RESERVED=1",
          spawn,
          "--branch",
          task.branch,
          "--stage",
          creation.stage,
          "--issue",
          value.id,
          "--target",
          task.target,
          "--clean",
          ...(opts.forkReason ? ["--fork-reason", opts.forkReason] : []),
          ...(opts.adoption ? ["--adopt-reason", opts.adoptReason!] : []),
          ...(opts.reuse ? ["--reuse-worktree"] : opts.existing ? ["--existing-branch"] : []),
          ...[...opts.released].flatMap((id) => ["--released", id]),
        ],
        repo,
        (secs + 30) * 1000,
      );
    } catch (error: any) {
      if (error?.status === 124 || error?.status === 137)
        throw new Error(
          `handoff-spawn did not finish in ${secs}s ([shep] spawn_timeout) and was stopped; retry this requestId to finish a partial creation`,
        );
      throw error;
    }
    const result = JSON.parse(out);
    if (!result.ok || !result.agent_started || !result.path || !result.space || !result.desk || !result.session)
      throw new Error(`partial visible creation: ${JSON.stringify(result)}`);
    const t = JSON.parse(run(bin("hc"), ["get", result.desk, "--json"], repo));
    if (
      t.state !== "live" ||
      t.labels?.["bercail.space"] !== result.space ||
      realpathSync(t.cwd) !== realpathSync(result.path) ||
      (opts.adoption && realpathSync(result.path) !== opts.adoption.path)
    )
      throw new Error(`visible tuple unconfirmed: ${JSON.stringify(result)}`);
    creation.status = "started";
    creation.next = `Created ${result.path}, space ${result.space}, desk ${result.desk}; its first prompt is the issue. Dispatch follow-ups to it as new requests`;
    delete creation.reason;
    creation.result = result;
    // Startup may still be loading. Do not invent a session or call restore.
    task.branch = result.branch;
    save(repo, value, task);
    return { status: creation.status, creation: result, authority: false };
  } catch (error) {
    creation.status = "unknown";
    creation.reason = String(error);
    creation.next =
      "Retry this requestId: it finishes a creation that left no desk and no handoffs.jsonl line, else says what to inspect";
    save(repo, value, task);
    throw error;
  }
}

function dispatch(op: string, input: any): any {
  if (op !== "dispatch") throw new Error("usage: bercail shep task dispatch (JSON on stdin)");
  if (!input || typeof input !== "object" || !input.repo || !/^[a-z0-9][a-z0-9._-]*$/i.test(input.issue || ""))
    throw new Error("pass explicit repo and issue as JSON on stdin");
  const allowed = new Set([
    "repo",
    "issue",
    "target",
    "requestId",
    "stage",
    "message",
    "branch",
    "forkReason",
    "adoptReason",
  ]);
  const unknown = Object.keys(input).filter((key) => !allowed.has(key));
  if (unknown.length)
    throw new Error(`unknown task field ${unknown.join(", ")}; dispatch takes ${[...allowed].join(", ")}`);
  if (JSON.stringify(input).length > 65536) throw new Error("request exceeds 64KiB");
  if (input.branch) run("git", ["check-ref-format", "--branch", input.branch], process.cwd());
  const repo = mainOf(input.repo);
  const common = git(repo, "rev-parse", "--path-format=absolute", "--git-common-dir");
  const lock = join(common, "bercail-task.lock");
  try {
    mkdirSync(lock, { mode: 0o700 });
  } catch {
    throw new Error(`dispatch lock held: ${lock}; inspect the previous invocation before removing a stale lock`);
  }
  try {
    const value = issue(repo, input.issue);
    let task = migrated(value.metadata?.bercail_task);
    const target = logicalTarget(input.target || "");
    if (/^https:/i.test(input.target)) {
      const slug = /^https:\/\/github\.com\/([^/]+\/[^/]+)\/pull\//i.exec(input.target)?.[1]?.toLowerCase();
      const remote = git(repo, "remote", "get-url", "origin").replace(/\.git$/, "");
      const origin = /github\.com[:/]([^/]+\/[^/]+)$/.exec(remote)?.[1]?.toLowerCase();
      if (!slug || origin !== slug)
        throw new Error("PR URL belongs to another repository; ownership cannot be inferred from its number");
    }
    if (!/^[a-z0-9][a-z0-9._-]{0,99}$/i.test(input.requestId || ""))
      throw new Error("requestId is required; reuse it after an uncertain response, never mint a retry");
    if (
      !["bstack", "autopilot"].includes(input.stage || "bstack") ||
      typeof input.message !== "string" ||
      !input.message.trim()
    )
      throw new Error("dispatch needs a work message, and stage bstack or autopilot");
    const asked = input.adoptReason !== undefined;
    if (asked && (typeof input.adoptReason !== "string" || !input.adoptReason.trim() || input.forkReason))
      throw new Error(
        "adoptReason must say why a new desk takes over the gone owner's checkout (and cannot go with forkReason)",
      );
    if (task && task.repo !== repo) throw new Error("issue belongs to another repository; no transfer");
    if (task && task.target !== target && !task.aliases?.includes(target)) {
      if (task.target !== `task:${value.id}` || !target.startsWith("pr:") || !task.owner)
        throw new Error("issue already owns another logical target; use a separate issue with an explicit forkReason");
      const pr = prFacts(repo, target);
      if (pr.isCrossRepository || pr.headRefName !== task.owner.branch)
        throw new Error("new PR is not bound to the original owner's branch; no target or session transfer");
      task.aliases = [...(task.aliases || []), task.target];
      task.target = target;
    }
    const all = allIssues(repo);
    const released = supersededBy(all, value.id);
    const recorded = records(repo);
    // A superseded issue gives up its target once none of its desks is live.
    if (released.size) {
      const desks = new Set(
        [
          ...recorded.filter((r) => released.has(r.issue)).map((r) => r.desk),
          ...all.filter((i: any) => released.has(i.id)).map((i: any) => i.metadata?.bercail_task?.owner?.desk),
        ].filter(Boolean),
      );
      const still = live(repo).find((t) => released.has(t.labels?.["bercail.issue"]) || desks.has(t.address));
      if (still)
        throw new Error(
          `superseded issue ${still.labels?.["bercail.issue"] || [...released].join(", ")} still has live desk ${still.address}; close it before its target moves`,
        );
    }
    const history = recorded.filter((r) => !released.has(r.issue));
    if (target.startsWith("pr:") && history.some((r) => (!r.target || r.target.startsWith("task:")) && r.branch)) {
      const pr = prFacts(repo, target);
      if (!pr.headRefName || pr.isCrossRepository)
        throw new Error("legacy PR ownership UNKNOWN; cannot infer absence or start a new desk");
      for (const r of history)
        if ((!r.target || r.target.startsWith("task:")) && r.branch === pr.headRefName) r.target = target;
    }
    const request: Request = {
      id: input.requestId,
      payload: createHash("sha256")
        .update(
          JSON.stringify({
            repo,
            issue: value.id,
            target,
            stage: input.stage || "bstack",
            message: input.message,
            branch: input.branch || "",
            forkReason: input.forkReason || "",
            adoptReason: input.adoptReason || "",
          }),
        )
        .digest("hex"),
      stage: input.stage || "bstack",
      message: input.message,
    };
    const aliases = all.filter(
      (i: any) =>
        i.id !== value.id &&
        !released.has(i.id) &&
        i.metadata?.bercail_task?.repo === repo &&
        (i.metadata.bercail_task.target === target || i.metadata.bercail_task.aliases?.includes(target)),
    );
    const other = history.filter((r) => r.issue !== value.id && r.target === target);
    if ((aliases.length || other.length) && !input.forkReason)
      throw new Error(
        `logical target already owned by ${aliases[0]?.id || other[0]?.issue}; continue that issue, close it with bd supersede ${aliases[0]?.id || other[0]?.issue} --with ${value.id}, or use an explicit forkReason on a separate exploration issue`,
      );
    // A retry of a follow-up: it was queued once, and is never sent again.
    const sent = queued(repo, value.id, request);
    if (sent) {
      if (!same({ ...sent.file.request, payload: sent.file.v === 2 ? sent.file.request.payload : "" }, request))
        throw new Error("requestId payload changed; this is not a retry");
      const adopted = task?.adoptions?.find((a) => a.request === input.requestId);
      return {
        status: "queued",
        owner: sent.file.owner,
        path: sent.path,
        delivery: sent.file.delivery,
        authority: false,
        retry: true,
        ...(adopted ? told(adopted, sent.file.owner.desk) : {}),
      };
    }
    if (task?.retired?.includes(input.requestId))
      throw new Error(
        `request ${input.requestId} is retired: it was for a desk whose checkout was adopted, or is v0.17 work with no queue file. Dispatch it again with a new requestId`,
      );
    if (
      task?.pending &&
      Object.hasOwn(task.pending, input.requestId) &&
      task.pending[input.requestId] !== request.payload
    )
      throw new Error("requestId payload changed; this is not a retry");
    const prior = task?.creation?.id === input.requestId ? task?.creation : undefined;
    if (prior) {
      if (!same(prior, request)) throw new Error("requestId payload changed; this is not a retry");
      // The spawn of an UNKNOWN creation has ended. When it left no desk and
      // no handoffs line, finish it in its clean worktree, or start it again.
      if (prior.status === "unknown" && !task!.owner && !task!.adoptions?.some((a) => a.request === prior.id)) {
        const pr = target.startsWith("pr:") ? prFacts(repo, target) : null;
        const existing = !!pr && !pr.isCrossRepository && pr.headRefName === task!.branch;
        let path: string | null;
        try {
          // An autopilot desk starts only on the PR's own branch, on a retry too.
          if (prior.stage === "autopilot" && !existing)
            throw new Error(
              `stage autopilot starts a desk only on ${target}'s own branch, and ${task!.branch} is not it`,
            );
          path = leftover(repo, value.id, task!.branch, history, existing ? pr!.headRefOid : "");
        } catch (error) {
          const why = (error as Error).message;
          return { status: prior.status, owner: null, authority: false, retry: true, next: `Not finished: ${why}` };
        }
        prior.status = "creating";
        prior.next = path
          ? `Finishing the partial creation in ${path}`
          : "Starting the creation again: the last one left no worktree";
        save(repo, value, task!);
        const done = create(repo, value, task!, {
          existing,
          reuse: !!path,
          released,
          adoption: null,
          forkReason: task!.forkReason,
        });
        return { ...done, retry: true };
      }
      // Once the desk started, its own session gets the creation's message.
      if (prior.status === "started" && !task!.owner) {
        const created = prior.result;
        const original = findOwner(repo, value.id, target, null, !!task!.forkReason, history);
        if (
          !original ||
          original.desk !== created.desk ||
          original.space !== created.space ||
          original.session !== created.session ||
          original.cwd !== realpathSync(created.path)
        )
          throw new Error("original startup/session not ready or changed; do not replace it");
        task!.owner = original;
        save(repo, value, task!);
      }
      if (prior.status === "started" && task!.owner) {
        const original = findOwner(repo, value.id, target, task!.owner, !!task!.forkReason, history);
        if (!original)
          throw new Error(
            `original owner ${task!.owner.desk} is gone; this request was for it. Dispatch the work with a new requestId, which adopts its checkout`,
          );
        const path = queue(repo, value.id, original, request);
        // A retry of an adoption tells the person again, in case the first answer was lost.
        const adopted = task!.adoptions?.find((a) => a.request === prior.id);
        return {
          status: "queued",
          owner: original,
          path,
          authority: false,
          retry: true,
          ...(adopted ? told(adopted, original.desk) : {}),
        };
      }
      return { status: prior.status, owner: task!.owner, next: prior.next, authority: false, retry: true };
    }
    const fork = !!(task?.forkReason || input.forkReason);
    const owner = findOwner(repo, value.id, target, task?.owner, fork, history);
    // No live owner, and the records name the desk a spawn started: it is gone,
    // so a new desk adopts its checkout. A failed spawn's record may name a desk
    // it found there but never started; older records have no flags.
    const before = owned(history, value.id, target, fork);
    const started = before.some((r) => r.desk && r.ok !== false && r.agent_started !== false);
    const adopting = !owner && (asked || !!task?.owner || started);
    if (!owner && !adopting && before.length)
      throw new Error("original owner missing/stale; inspect the recorded checkout/space, no replacement was started");
    if (asked && owner)
      throw new Error(
        `live original owner ${owner.desk}; continue it with a normal dispatch, adoption is only for a gone owner`,
      );
    if (owner && task?.creation?.result?.session && owner.session !== task.creation.result.session)
      throw new Error("original startup session changed; no transfer to a replacement");
    if (input.branch && (owner || task) && input.branch !== (owner?.branch || task?.branch))
      throw new Error(
        "branch differs from original task; continue the original checkout or fork to a separate issue with a reason",
      );
    if (task && !owner && (!adopting || ["creating", "unknown"].includes(task.creation?.status || "")))
      throw new Error(
        "creation outcome UNKNOWN; retry its own requestId to finish a partial creation, or inspect the worktree/space facts; do not launch another",
      );
    const adoption = adopting ? adoptable(repo, value.id, target, task, history, input) : null;
    task ||= {
      v: 2,
      repo,
      target,
      owner,
      branch: owner?.branch || adoption?.branch || input.branch || "",
      ...(input.forkReason ? { forkReason: String(input.forkReason) } : {}),
    };
    if (!owner && !task.branch) throw new Error("no existing owner; pass branch explicitly for a new visible desk");
    // A new desk on a PR's own branch starts at its fetched head; the branch is never cut again.
    let existing = false;
    if (!owner && !adoption && target.startsWith("pr:")) {
      const pr = prFacts(repo, target);
      existing = !pr.isCrossRepository && pr.headRefName === task.branch;
    }
    if (!owner && request.stage === "autopilot" && !(adoption ? target.startsWith("pr:") : existing))
      throw new Error(
        "stage autopilot starts a desk only on an open PR's own branch: target pr:N, with branch set to that PR's head branch",
      );
    let record: Adoption | undefined;
    if (adoption) {
      const desks = adoption.from.map((r) => r.desk);
      const gone = desks.length > 1 ? `desks ${desks.join(", ")} are gone` : `desk ${desks[0]} is gone`;
      record = {
        request: request.id,
        reason: asked ? input.adoptReason.trim() : gone,
        at: new Date().toISOString(),
        ...adoption,
      };
      // The gone owner's follow-ups stay queued to its desk: none moves to the new session.
      task.branch = adoption.branch;
      task.adoptions = [...(task.adoptions || []), record];
      task.retired = [
        ...(task.retired || []),
        ...(task.creation ? [task.creation.id] : []),
        ...Object.keys(task.pending || {}),
      ];
      delete task.pending;
    }
    task.owner = owner;
    if (owner) {
      // Reopen before delivery, so the job is on the board while the desk works.
      task.pending = { ...task.pending, [request.id]: request.payload };
      save(repo, value, task);
      const path = queue(repo, value.id, owner, request);
      delete task.pending[request.id];
      if (!Object.keys(task.pending).length) delete task.pending;
      save(repo, value, task, false); // The issue may be closed meanwhile: leave its status.
      return { status: "queued", owner, path, authority: false };
    }
    task.creation = { ...request, status: "creating", next: "Inspect visible creation result" };
    save(repo, value, task);
    const done = create(repo, value, task, {
      existing,
      reuse: false,
      released,
      adoption,
      forkReason: input.forkReason ? String(input.forkReason) : undefined,
      adoptReason: record?.reason,
    });
    return record ? { ...done, ...told(record, done.creation.desk) } : done;
  } finally {
    rmSync(lock, { recursive: true });
  }
}

// The person is told of an adoption, not asked: warning is the line Shep repeats.
function told({ reason, path, branch, from, staged }: Adoption, desk: string) {
  const files = staged
    ? ` It holds ${staged} staged file${staged === 1 ? "" : "s"} the person has not reviewed; the desk names them in its first report and leaves them staged unless asked.`
    : "";
  return {
    adopted: { reason, path, branch, from, staged },
    warning: `Adopted: ${reason}, so desk ${desk} starts a new session in ${path} (${branch}).${files} Tell the person; nothing waits on them.`,
  };
}

// The new desk's Pi is up once its record and its open-session claim name the
// session handoff-spawn pinned: what verify reads.
function up(desk: string, session: string): boolean {
  try {
    const r = json(join(state(), "desk-sessions", `${desk}.json`));
    const claim = json(join(process.env.XDG_RUNTIME_DIR!, "bercail/open-sessions", `${r.pid}.json`));
    return r.session === session && r.follow_up === 1 && !!claim.sessions?.includes(session);
  } catch {
    return false;
  }
}

const READY_SECONDS = 60;

// --wait-ready: once a new desk started, wait for its Pi, then retry the
// request, which binds that session as the owner and queues the message there.
// Shep gets one answer instead of sleeping and retrying.
export function taskCommand(op: string, input: any, flags: string[] = []): any {
  const unknown = flags.filter((flag) => flag !== "--wait-ready");
  if (unknown.length) throw new Error(`unknown flag ${unknown.join(", ")}; dispatch takes --wait-ready`);
  const done = dispatch(op, input);
  if (!flags.includes("--wait-ready") || done.status !== "started") return done;
  const until = Date.now() + READY_SECONDS * 1000;
  while (!up(done.creation.desk, done.creation.session)) {
    if (Date.now() >= until)
      return {
        ...done,
        ready: false,
        next: `desk ${done.creation.desk}'s Pi did not claim its session in ${READY_SECONDS}s; retry this requestId once it is up`,
      };
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 250);
  }
  // The desk exists either way: a refused binding keeps the creation's answer.
  try {
    const { retry: _, ...queued } = dispatch(op, input);
    return { ...done, ...queued, ready: true };
  } catch (error) {
    return { ...done, ready: false, next: `the message was not queued: ${(error as Error).message}` };
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    console.log(
      JSON.stringify(taskCommand(process.argv[2] || "", JSON.parse(readFileSync(0, "utf8")), process.argv.slice(3))),
    );
  } catch (error) {
    console.error(`bercail shep task: ${(error as Error).message}`);
    process.exitCode = 1;
  }
}
