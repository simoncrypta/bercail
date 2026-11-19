// Durable work intent belongs to the issue. The file queue only transports data
// to its original Pi; neither an outcome nor a message grants shipping authority.
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
type Request = {
  id: string;
  sequence: number;
  payload: string;
  outcome: string;
  stage: string;
  message: string;
  authoring: string;
  status: string;
  next: string;
  reason?: string;
  receipt?: unknown;
  candidate?: { head: string; tree: string };
  publication?: { target: string; head: string };
};
type Task = {
  v: number;
  repo: string;
  target: string;
  aliases?: string[];
  owner: Owner | null;
  branch: string;
  requests: Request[];
  forkReason?: string;
  adoptions?: Adoption[];
};
// A new desk on a gone owner's checkout, and why. The desks it names are gone.
type Adoption = {
  request: string;
  reason: string;
  at: string;
  path: string;
  branch: string;
  from: { desk: string; session: string; space: string }[];
};
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
function save(repo: string, value: any, task: Task): void {
  // Keep unrelated metadata. A failed/uncertain bd write stops dispatch before
  // any external effect; retry reads the durable reservation first.
  const file = join(
    git(repo, "rev-parse", "--path-format=absolute", "--git-common-dir"),
    "bercail-task.lock/metadata.json",
  );
  const current = issue(repo, value.id);
  if (current.metadata?.bercail_task?.requests?.some((r: Request) => !task.requests.some((ours) => ours.id === r.id)))
    throw new Error("task changed outside the repository reservation; inspect it without dropping newer work");
  // bd 1.3.1 --metadata merges inside the storage transaction. Submit only
  // this namespace; resubmitting other keys would overwrite concurrent edits.
  writeFileSync(file, JSON.stringify({ bercail_task: task }), { mode: 0o600 });
  try {
    bd(repo, "update", value.id, "--metadata", `@${file}`, "--status", "in_progress", "--json");
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
  return { path, branch, from };
}
function findOwner(
  repo: string,
  id: string,
  target: string,
  saved?: Owner | null,
  fork = false,
  history = records(repo),
  adopt = false,
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
    throw new Error("ambiguous owners; reconcile the original desks explicitly, no launch occurred");
  if (!candidates.length) {
    if ((saved || handoffs.length) && !adopt)
      throw new Error("original owner missing/stale; inspect the recorded checkout/space, no replacement was started");
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
function queue(repo: string, id: string, owner: Owner, request: Request): string {
  const dir = join(state(), "desk-follow-ups", owner.desk);
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  const path = join(
    dir,
    `${String(request.sequence).padStart(9, "0")}-${createHash("sha256").update(`${repo}\0${id}\0${request.id}`).digest("hex")}.json`,
  );
  if (!existsSync(path))
    writeFileSync(
      path,
      JSON.stringify({ v: 1, repo, issue: id, owner, request, delivery: "queued", authority: false }) + "\n",
      { mode: 0o600, flag: "wx" },
    );
  return path;
}
function pending(r: Request): boolean {
  return r.status !== "complete";
}
function effectsFor(owner: Owner, repo: string, id: string, request: Request): any[] {
  const entries = readFileSync(owner.session_file, "utf8")
    .trim()
    .split("\n")
    .map((line) => JSON.parse(line));
  const byID = new Map(entries.filter((e) => e.type !== "session").map((e) => [e.id, e]));
  const active = new Set<string>();
  const runtimeRoot = process.env.XDG_STATE_HOME || join(process.env.HOME!, ".local/state");
  const loaded = json(join(runtimeRoot, "bercail/runtime", `${owner.pid}.json`));
  if (
    loaded.pid !== owner.pid ||
    loaded.start_ticks !== owner.start_ticks ||
    loaded.session !== owner.session ||
    loaded.session_file !== owner.session_file ||
    !loaded.leaf
  )
    throw new Error(
      "original runtime's active-leaf evidence missing/stale; physical JSONL tail is not an active branch",
    );
  let leaf = loaded.leaf;
  while (leaf && byID.has(leaf) && !active.has(leaf)) {
    active.add(leaf);
    leaf = byID.get(leaf).parentId;
  }
  const branch = entries.filter((e) => active.has(e.id));
  const same = (d: any) => d?.repo === repo && d.issue === id && d.requestId === request.id && d.authority === false;
  if (!branch.some((e) => e.type === "custom_message" && e.customType === "bercail-task-work" && same(e.details)))
    throw new Error(
      "request has no complete matching persisted work message in the original active session; queued/submitted is not execution",
    );
  return branch
    .filter(
      (e) =>
        e.type === "custom" &&
        e.customType === "bercail-task-effect" &&
        same(e.data) &&
        e.data.session === owner.session,
    )
    .map((e) => e.data)
    .filter(
      (d) =>
        d.exit_code === 0 &&
        branch.some(
          (e) =>
            e.type === "message" &&
            e.message?.role === "toolResult" &&
            e.message.toolCallId === d.toolCallId &&
            !e.message.isError &&
            e.message.structuredContent?.exit_code === 0,
        ),
    );
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
// Start the visible desk for request. timeout runs the spawn in its own process
// group and kills the whole group when time runs out, so nothing it started is
// still on its way to a desk when the request turns UNKNOWN.
function create(repo: string, value: any, task: Task, request: Request, opts: Spawn): any {
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
          request.stage,
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
    request.status = "awaiting-session";
    request.next = `Created ${result.path}, space ${result.space}, desk ${result.desk}; inspect startup then dispatch the next request in that original session`;
    delete request.reason;
    Object.assign(request, { creation: result });
    // Startup may still be loading. Do not invent a session or call restore.
    task.branch = result.branch;
    save(repo, value, task);
    return { status: request.status, creation: result, authority: false };
  } catch (error) {
    request.status = "unknown";
    request.reason = String(error);
    request.next =
      "Retry this requestId: it finishes a creation that left no desk and no handoffs.jsonl line, else says what to inspect";
    save(repo, value, task);
    throw error;
  }
}

export function taskCommand(op: string, input: any): any {
  if (!input || typeof input !== "object" || !input.repo || !/^[a-z0-9][a-z0-9._-]*$/i.test(input.issue || ""))
    throw new Error("pass explicit repo and issue as JSON on stdin");
  const allowed = new Set([
    "repo",
    "issue",
    "target",
    "requestId",
    "outcome",
    "stage",
    "message",
    "authoring",
    "branch",
    "forkReason",
    "adoptReason",
    "targets",
    "universe",
    "reason",
    "next",
    "proof",
    "session",
    "desk",
  ]);
  if (Object.keys(input).some((key) => !allowed.has(key)) || JSON.stringify(input).length > 65536)
    throw new Error("unknown task field or request exceeds 64KiB");
  if (input.authoring !== undefined && typeof input.authoring !== "string")
    throw new Error("authoring must be the requested command string");
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
    let task: Task | undefined = value.metadata?.bercail_task;
    if (op === "status")
      return task || { status: "unknown", next: "No tracked request; inspect the issue and original handoff" };
    if (op === "dispatch") {
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
        !["stage", "local", "publish", "cleanup"].includes(input.outcome) ||
        !["bstack", "autopilot"].includes(input.stage || "bstack") ||
        typeof input.message !== "string" ||
        !input.message.trim()
      )
        throw new Error("dispatch needs outcome stage|local|publish|cleanup and a work message");
      const adopting = input.adoptReason !== undefined;
      if (adopting && (typeof input.adoptReason !== "string" || !input.adoptReason.trim() || input.forkReason))
        throw new Error(
          "adoptReason must say why a new desk takes over the gone owner's checkout (and cannot go with forkReason)",
        );
      if (task && task.repo !== repo) throw new Error("issue belongs to another repository; no transfer");
      if (task && task.target !== target && !task.aliases?.includes(target)) {
        if (task.target !== `task:${value.id}` || !target.startsWith("pr:") || !task.owner)
          throw new Error(
            "issue already owns another logical target; use a separate issue with an explicit forkReason",
          );
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
      const payload = createHash("sha256")
        .update(
          JSON.stringify({
            repo,
            issue: value.id,
            target,
            outcome: input.outcome,
            stage: input.stage || "bstack",
            message: input.message,
            authoring: input.authoring || "",
            branch: input.branch || "",
            forkReason: input.forkReason || "",
            adoptReason: input.adoptReason || "",
            targets: input.targets || null,
            universe: input.universe || null,
          }),
        )
        .digest("hex");
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
      const prior = task?.requests.find((r) => r.id === input.requestId);
      if (prior) {
        if (prior.payload !== payload) throw new Error("requestId payload changed; this is not a retry");
        // The spawn of an UNKNOWN creation has ended. When it left no desk and
        // no handoffs line, finish it in its clean worktree, or start it again.
        if (
          prior.status === "unknown" &&
          !task!.owner &&
          prior === task!.requests.at(-1) &&
          !task!.adoptions?.some((a) => a.request === prior.id)
        ) {
          const pr = target.startsWith("pr:") ? prFacts(repo, target) : null;
          const existing = !!pr && !pr.isCrossRepository && pr.headRefName === task!.branch;
          let path: string | null;
          try {
            // An older dispatch saved autopilot requests it then started as bstack, on any branch.
            if (prior.stage === "autopilot" && !existing)
              throw new Error(
                `stage autopilot starts a desk only on ${target}'s own branch, and ${task!.branch} is not it`,
              );
            path = leftover(repo, value.id, task!.branch, history, existing ? pr!.headRefOid : "");
          } catch (error) {
            const why = (error as Error).message;
            return { ...prior, owner: null, authority: false, retry: true, next: `Not finished: ${why}` };
          }
          prior.status = "creating";
          prior.next = path
            ? `Finishing the partial creation in ${path}`
            : "Starting the creation again: the last one left no worktree";
          save(repo, value, task!);
          const done = create(repo, value, task!, prior, {
            existing,
            reuse: !!path,
            released,
            adoption: null,
            forkReason: task!.forkReason,
          });
          return { ...done, retry: true };
        }
        // Repair only a missing queue file after a durable acceptance, never a
        // claimed/submitted send or a launch with an uncertain native result.
        if (prior.status === "awaiting-session" && !task!.owner) {
          const created = (prior as any).creation;
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
          prior.status = "queued";
          prior.next = "Original startup confirmed; work and its receipts remain outstanding";
          save(repo, value, task!);
        }
        if (prior.status === "queued" && task!.owner) {
          const original = findOwner(repo, value.id, target, task!.owner, !!task!.forkReason, history);
          if (!original) throw new Error("original owner missing; request remains outstanding");
          save(repo, value, task!);
          queue(repo, value.id, original, prior);
        }
        return { ...prior, owner: task!.owner, authority: false, retry: true };
      }
      const owner = findOwner(
        repo,
        value.id,
        target,
        task?.owner,
        !!(task?.forkReason || input.forkReason),
        history,
        adopting,
      );
      if (adopting && owner)
        throw new Error(
          `live original owner ${owner.desk}; continue it with a normal dispatch, adoption is only for a gone owner`,
        );
      // The latest creation: an adoption's desk replaced the first one.
      const creation = task?.requests.findLast((r) => (r as any).creation) as
        | (Request & { creation?: any })
        | undefined;
      if (owner && creation?.creation?.session && owner.session !== creation.creation.session)
        throw new Error("original startup session changed; no transfer to a replacement");
      if (input.branch && (owner || task) && input.branch !== (owner?.branch || task?.branch))
        throw new Error(
          "branch differs from original task; continue the original checkout or fork to a separate issue with a reason",
        );
      if (task && !owner && (!adopting || task.requests.some((r) => r.status === "creating" || r.status === "unknown")))
        throw new Error(
          "creation outcome UNKNOWN; retry its own requestId to finish a partial creation, or inspect the worktree/space facts; do not launch another",
        );
      const adoption = adopting ? adoptable(repo, value.id, target, task, history, input) : null;
      const request: Request = {
        id: input.requestId,
        sequence: task?.requests.length || 0,
        payload,
        outcome: input.outcome,
        stage: input.stage || "bstack",
        message: input.message,
        authoring: input.authoring || "",
        status: owner ? "queued" : "creating",
        next: owner
          ? "Original desk processes this work; validation and requested receipts still outstanding"
          : "Inspect visible creation result",
      };
      if (input.outcome === "cleanup" && (!Array.isArray(input.targets) || !input.targets.length))
        throw new Error(
          "cleanup needs a finite explicit target subset and an execution owner; an inventory is not a receipt",
        );
      task ||= {
        v: 1,
        repo,
        target,
        owner,
        branch: owner?.branch || adoption?.branch || input.branch || "",
        requests: [],
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
      const checkout = owner?.cwd || adoption?.path || repo;
      Object.assign(request, {
        candidate: { head: git(checkout, "rev-parse", "HEAD"), tree: git(checkout, "write-tree") },
      });
      if (input.outcome === "publish" && target.startsWith("pr:")) {
        try {
          const baseline = JSON.parse(
            run(bin("gh"), ["pr", "view", target.slice(3), "--json", "headRefOid"], owner?.cwd || repo),
          );
          if (/^[a-f0-9]{40,64}$/.test(baseline.headRefOid))
            request.publication = { target, head: baseline.headRefOid };
        } catch {
          /* Unknown baseline does not stop dispatch to the original owner. */
        }
      }
      if (input.outcome === "cleanup") {
        if (input.authoring)
          throw new Error(
            "cleanup cannot discard requested authoring; dispatch authoring as a separate local/publish request in the same issue",
          );
        const native = JSON.parse(run(process.env.HERDR_APP_BIN || "herdr-app", ["ls"], repo));
        if (!Array.isArray(native.spaces))
          throw new Error("native OPEN snapshot UNKNOWN; audit is not an execution target snapshot");
        const targets = input.targets.map((t: any) => {
          const space = native.spaces.find((s: any) => s.id === t.space);
          if (!space || (t.generation && t.generation !== (space.generation || space.id)))
            throw new Error("cleanup target/generation not in the observed native OPEN snapshot");
          const disposition = t.disposition || "CLOSE";
          if (!["CLOSE", "KEEP", "PROTECTED"].includes(disposition) || (disposition !== "CLOSE" && !t.reason?.trim()))
            throw new Error(
              "cleanup target disposition must be CLOSE, or an explicitly requested KEEP/PROTECTED with its reason",
            );
          return {
            space: space.id,
            generation: space.generation || space.id,
            disposition,
            reason: t.reason || "",
            snapshot: space,
          };
        });
        if (new Set(targets.map((t: any) => t.space)).size !== targets.length)
          throw new Error("duplicate cleanup target");
        if (input.universe && !["subset", "current"].includes(input.universe))
          throw new Error("universe must be subset or current");
        if (input.universe === "current" && targets.length !== native.spaces.length)
          throw new Error("requested subset is not the current OPEN universe");
        Object.assign(request, {
          targets,
          universe: input.universe || "subset",
          open_at_dispatch: native.spaces.map((s: any) => s.id),
        });
      }
      if (adoption) {
        // The gone owner's requests stay its own: none is delivered to the new session.
        for (const r of task.requests.filter((r) => pending(r) && r.status !== "blocked"))
          Object.assign(r, {
            status: "blocked",
            reason: `original owner gone; its checkout was adopted by request ${request.id}, so this request did not move to the new session`,
            next: "Dispatch it again as a new request if the adopting desk should do it",
          });
        task.branch = adoption.branch;
        task.adoptions = [
          ...(task.adoptions || []),
          { request: request.id, reason: input.adoptReason.trim(), at: new Date().toISOString(), ...adoption },
        ];
      }
      task.owner = owner;
      task.requests.push(request);
      save(repo, value, task); // Reopen before delivery, so even an interrupted send protects unpublished work.
      if (owner) {
        const path = queue(repo, value.id, owner, request);
        return { status: "queued", owner, path, authority: false };
      }
      return create(repo, value, task, request, {
        existing,
        reuse: false,
        released,
        adoption,
        forkReason: input.forkReason ? String(input.forkReason) : undefined,
        adoptReason: adoption ? input.adoptReason.trim() : undefined,
      });
    }
    if (!task) throw new Error("no durable requested outcome on this issue; dispatch it explicitly first");
    const request = task.requests.find((r) => r.id === input.requestId);
    if (!request) throw new Error("unknown requestId; old turns/reports cannot complete a new request");
    if (request.status === "complete" && (op === "receipt" || op === "block"))
      return { ...task, outstanding: task.requests.filter(pending).length, authority: false, retry: true };
    if (op === "block") {
      if (!input.reason || !input.next) throw new Error("block needs the precise reason and next action");
      request.status = "blocked";
      request.reason = String(input.reason);
      request.next = String(input.next);
    } else if (op === "receipt") {
      if (!task.owner) throw new Error("no verified execution owner; an audit cannot complete cleanup");
      let owner: Owner | null;
      let alive = false;
      try {
        alive = processTicks(task.owner.pid) === task.owner.start_ticks;
      } catch {}
      if (request.outcome === "cleanup" && !alive) {
        // Receipt-only reconciliation of the already-bound owner, not an owner
        // transfer or permission to execute after normal native closure.
        owner = task.owner;
        const header = JSON.parse(readFileSync(owner.session_file, "utf8").split("\n")[0]!);
        if (
          header.id !== owner.session ||
          header.cwd !== owner.cwd ||
          git(owner.cwd, "branch", "--show-current") !== owner.branch
        )
          throw new Error("closed original owner's persisted context is stale; cleanup remains UNKNOWN");
      } else {
        const released = supersededBy(allIssues(repo), value.id);
        const history = records(repo).filter((r) => !released.has(r.issue));
        owner = findOwner(repo, value.id, task.target, task.owner, !!task.forkReason, history);
      }
      if (!owner || input.session !== owner.session || input.desk !== owner.desk)
        throw new Error("receipt must name the original execution owner/session (not authorization)");
      const head = git(owner.cwd, "rev-parse", "HEAD");
      const tree = git(owner.cwd, "write-tree");
      const proof = input.proof;
      const effects = effectsFor(owner, repo, value.id, request);
      const validation = effects.find(
        (e) =>
          e.command === proof?.validation?.command &&
          e.before.head === head &&
          e.before.tree === tree &&
          e.after.head === head &&
          e.after.tree === tree,
      );
      if (!validation)
        throw new Error(
          "fresh successful validation in this request/session for the current head/tree is required; old describe/CI/caller claims are not evidence",
        );
      if (
        !proof ||
        proof.head !== head ||
        proof.tree !== tree ||
        proof.validation?.head !== head ||
        proof.validation?.tree !== tree ||
        proof.validation?.exit_code !== 0 ||
        !proof.validation.command
      )
        throw new Error("fresh validation for this head and staged tree is required");
      if (request.outcome === "cleanup") {
        const targets = (request as any).targets;
        if (!Array.isArray(proof.results) || proof.results.length !== targets.length)
          throw new Error("per-target custody/closure receipts required, not an inventory or planned subset");
        const native = JSON.parse(run(process.env.HERDR_APP_BIN || "herdr-app", ["ls"], repo));
        if (!Array.isArray(native.spaces)) throw new Error("native OPEN spaces UNKNOWN");
        for (const target of targets) {
          const r = proof.results.find((x: any) => x.space === target.space && x.generation === target.generation);
          if (!r?.custody || !["CLOSED", "EXTERNAL", "KEEP", "PROTECTED", "UNKNOWN", "PARTIAL"].includes(r.status))
            throw new Error("each original target needs its generation, actual result and custody");
          if (["CLOSED", "EXTERNAL"].includes(r.status) && target.disposition !== "CLOSE")
            throw new Error(
              "explicitly retained target is not retained; report PARTIAL/UNKNOWN rather than successful closure",
            );
          if (["CLOSED", "EXTERNAL"].includes(r.status) && native.spaces.some((s: any) => s.id === r.space))
            throw new Error("target is still OPEN; RECENT/history is not OPEN closure");
          if (
            r.status === "CLOSED" &&
            !effects.some(
              (e) =>
                e.close === target.space &&
                e.open_before?.some(
                  (s: any) => s.id === target.space && (s.generation || s.id) === target.generation,
                ) &&
                !e.open_after?.some((s: any) => s.id === target.space),
            )
          )
            throw new Error(
              "missing observed native closure receipt from this original execution owner; an audit/inventory is not execution (use EXTERNAL only for independently observed external closure)",
            );
          if (["KEEP", "PROTECTED"].includes(r.status) && target.disposition !== r.status)
            throw new Error(
              "requested closure is still outstanding; a receipt cannot silently weaken it to KEEP/PROTECTED",
            );
          if (
            ["KEEP", "PROTECTED"].includes(r.status) &&
            !native.spaces.some((s: any) => s.id === r.space && (s.generation || s.id) === target.generation)
          )
            throw new Error("KEEP/protected target changed; inspect custody, do not report it closed");
        }
        proof.open = native.spaces.map((s: any) => s.id);
        proof.history =
          "RECENT/history not counted as OPEN; future delivery queue and completed processes are not global closure gates";
        if (proof.results.some((r: any) => ["UNKNOWN", "PARTIAL"].includes(r.status))) {
          request.status = "partial";
          request.receipt = proof;
          request.next = "Resolve the named partial/unknown targets with their original custody";
          save(repo, value, task);
          return task;
        }
      } else {
        if (request.outcome === "local" && (!request.candidate?.head || head === request.candidate.head))
          throw new Error("requested new authored head is still outstanding");
        const recorded = json(join(owner.cwd, ".bercail/validate.json"));
        if (
          recorded.tree !== tree ||
          !recorded.checks?.some(
            (check: any) =>
              ["test", "verify-skill"].includes(check.kind) &&
              check.command === proof.validation.command &&
              check.exit_code === 0,
          )
        )
          throw new Error(
            "validation command must match the candidate's recorded /validate checks, not an arbitrary successful command",
          );
        // This job tracks exact authoring intent. It does not invent a native
        // authoring effect contract from command text or Git objects.
        if (request.authoring)
          throw new Error(
            `native authoring receipt unavailable for ${request.authoring}; keep this request blocked in its original owner, with the exact next action`,
          );
        // A claim in prose is insufficient even for stage-only work.
        run(process.env.BERCAIL_SHEP_BIN || "bercail", ["describe", "check", owner.cwd], repo, 5000);
        if (
          request.outcome !== "stage" &&
          (git(owner.cwd, "rev-parse", "HEAD^{tree}") !== tree ||
            git(owner.cwd, "status", "--porcelain", "--untracked-files=all"))
        )
          throw new Error("requested authoring remains outstanding; the current changes are not all authored");
        if (request.outcome === "publish") {
          if (!request.publication || request.publication.target !== task.target)
            throw new Error(
              "publication baseline UNKNOWN; keep this original request blocked, do not infer fresh publication from old reports",
            );
          if (head === request.publication.head)
            throw new Error(
              "unchanged old published/green head is not this follow-up's outcome; the requested new PR head remains outstanding",
            );
          const remote = git(owner.cwd, "ls-remote", "--exit-code", "origin", `refs/heads/${owner.branch}`).split(
            /\s+/,
          )[0];
          if (remote !== head) throw new Error("requested new head is not published");
          if (!task.target.startsWith("pr:"))
            throw new Error("publication/new-head CI receipt currently supports explicit GitHub PR targets only");
          const pr = JSON.parse(
            run(
              bin("gh"),
              ["pr", "view", task.target.slice(3), "--json", "headRefOid,headRefName,statusCheckRollup"],
              owner.cwd,
            ),
          );
          if (
            pr.headRefOid !== head ||
            pr.headRefName !== owner.branch ||
            !pr.statusCheckRollup?.length ||
            !pr.statusCheckRollup.every(
              (c: any) => ["SUCCESS", "NEUTRAL", "SKIPPED"].includes(c.conclusion) || c.state === "SUCCESS",
            )
          )
            throw new Error("new-head CI is not proven green; old green PR does not complete this request");
        }
      }
      request.status = "complete";
      request.receipt = proof;
      request.next = "Requested outcome proven for this candidate; no shipping authority created";
    } else throw new Error("usage: bercail shep task dispatch|status|block|receipt (JSON on stdin)");
    save(repo, value, task);
    return { ...task, outstanding: task.requests.filter(pending).length, authority: false };
  } finally {
    rmSync(lock, { recursive: true });
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    console.log(JSON.stringify(taskCommand(process.argv[2] || "", JSON.parse(readFileSync(0, "utf8")))));
  } catch (error) {
    console.error(`bercail shep task: ${(error as Error).message}`);
    process.exitCode = 1;
  }
}
