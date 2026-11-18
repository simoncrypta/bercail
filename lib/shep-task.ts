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
function live(repo: string): any[] {
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
    .filter(
      (t: any) => t.state === "live" && t.labels?.["bercail.role"] === "agent" && t.labels?.["bercail.shep"] !== "bg",
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
function findOwner(
  repo: string,
  id: string,
  target: string,
  saved?: Owner | null,
  fork = false,
  history = records(repo),
): Owner | null {
  const handoffs = history.filter((r) => r.issue === id || (!fork && r.target === target));
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
    if (saved || handoffs.length)
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
      if (task && task.repo !== repo) throw new Error("issue belongs to another repository; no transfer");
      if (task && task.target !== target && !task.aliases?.includes(target)) {
        if (task.target !== `task:${value.id}` || !target.startsWith("pr:") || !task.owner)
          throw new Error(
            "issue already owns another logical target; use a separate issue with an explicit forkReason",
          );
        const pr = JSON.parse(
          run(bin("gh"), ["pr", "view", target.slice(3), "--json", "headRefName,isCrossRepository"], repo),
        );
        if (pr.isCrossRepository || pr.headRefName !== task.owner.branch)
          throw new Error("new PR is not bound to the original owner's branch; no target or session transfer");
        task.aliases = [...(task.aliases || []), task.target];
        task.target = target;
      }
      const history = records(repo);
      if (target.startsWith("pr:") && history.some((r) => (!r.target || r.target.startsWith("task:")) && r.branch)) {
        const pr = JSON.parse(
          run(bin("gh"), ["pr", "view", target.slice(3), "--json", "headRefName,isCrossRepository"], repo),
        );
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
            targets: input.targets || null,
            universe: input.universe || null,
          }),
        )
        .digest("hex");
      const all = bd(repo, "list", "--all", "--json", "--limit", "0");
      if (!Array.isArray(all)) throw new Error("bd ownership lookup unavailable; no launch occurred");
      const aliases = all.filter(
        (i: any) =>
          i.id !== value.id &&
          i.metadata?.bercail_task?.repo === repo &&
          (i.metadata.bercail_task.target === target || i.metadata.bercail_task.aliases?.includes(target)),
      );
      const other = history.filter((r) => r.issue !== value.id && r.target === target);
      if ((aliases.length || other.length) && !input.forkReason)
        throw new Error(
          `logical target already owned by ${aliases[0]?.id || other[0]?.issue}; continue that issue, or use an explicit forkReason on a separate exploration issue`,
        );
      const prior = task?.requests.find((r) => r.id === input.requestId);
      if (prior) {
        if (prior.payload !== payload) throw new Error("requestId payload changed; this is not a retry");
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
      const owner = findOwner(repo, value.id, target, task?.owner, !!(task?.forkReason || input.forkReason), history);
      const creation = task?.requests.find((r) => (r as any).creation) as (Request & { creation?: any }) | undefined;
      if (owner && creation?.creation?.session && owner.session !== creation.creation.session)
        throw new Error("original startup session changed; no transfer to a replacement");
      if (input.branch && (owner || task) && input.branch !== (owner?.branch || task?.branch))
        throw new Error(
          "branch differs from original task; continue the original checkout or fork to a separate issue with a reason",
        );
      if (task && !owner)
        throw new Error("creation outcome UNKNOWN; inspect partial worktree/space facts, do not retry launch");
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
        branch: owner?.branch || input.branch || "",
        requests: [],
        ...(input.forkReason ? { forkReason: String(input.forkReason) } : {}),
      };
      if (!owner && !task.branch) throw new Error("no existing owner; pass branch explicitly for a new visible desk");
      Object.assign(request, {
        candidate: { head: git(owner?.cwd || repo, "rev-parse", "HEAD"), tree: git(owner?.cwd || repo, "write-tree") },
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
      task.owner = owner;
      task.requests.push(request);
      save(repo, value, task); // Reopen before delivery, so even an interrupted send protects unpublished work.
      if (owner) {
        const path = queue(repo, value.id, owner, request);
        return { status: "queued", owner, path, authority: false };
      }
      const spawn =
        process.env.BERCAIL_HANDOFF_SPAWN || join(process.env.HOME!, ".agents/skills/handoff/scripts/handoff-spawn");
      try {
        const result = JSON.parse(
          run(
            "env",
            [
              "BERCAIL_TASK_RESERVED=1",
              spawn,
              "--branch",
              task.branch,
              "--stage",
              "bstack",
              "--issue",
              value.id,
              "--target",
              target,
              "--clean",
              ...(input.forkReason ? ["--fork-reason", String(input.forkReason)] : []),
            ],
            repo,
            30000,
          ),
        );
        if (!result.ok || !result.agent_started || !result.path || !result.space || !result.desk || !result.session)
          throw new Error(`partial visible creation: ${JSON.stringify(result)}`);
        const t = JSON.parse(run(bin("hc"), ["get", result.desk, "--json"], repo));
        if (
          t.state !== "live" ||
          t.labels?.["bercail.space"] !== result.space ||
          realpathSync(t.cwd) !== realpathSync(result.path)
        )
          throw new Error(`visible tuple unconfirmed: ${JSON.stringify(result)}`);
        request.status = "awaiting-session";
        request.next = `Created ${result.path}, space ${result.space}, desk ${result.desk}; inspect startup then dispatch the next request in that original session`;
        Object.assign(request, { creation: result });
        // Startup may still be loading. Do not invent a session or call restore.
        task.branch = result.branch;
        save(repo, value, task);
        return { status: request.status, creation: result, authority: false };
      } catch (error) {
        request.status = "unknown";
        request.reason = String(error);
        request.next =
          "Inspect handoffs.jsonl and the branch/worktree/space; do not retry creation or replace the desk";
        save(repo, value, task);
        throw error;
      }
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
      } else owner = findOwner(repo, value.id, task.target, task.owner, !!task.forkReason);
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
