import { spawn, spawnSync } from "node:child_process";
import {
  closeSync,
  existsSync,
  fstatSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  openSync,
  readFileSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { join } from "node:path";
import type { QuestionStore } from "./questions.ts";
import type { JobScope, ScopedAction, ScopedActionReceipt, ScopedCandidate } from "./scoped-types.ts";
import { SCOPED_CAPABILITY } from "./scoped-types.ts";
import {
  canonical,
  CandidateError,
  captureCandidate,
  digest,
  publicationEndpoint,
  refreshJobScope,
  readScopedPolicy,
  scopedEnv,
  scopedGit,
  ScopeError,
} from "./scoped-target.ts";

export interface ScopedRequest {
  requestId: string;
  grantId: string;
  action: ScopedAction;
  candidate: ScopedCandidate;
}
export interface ScopedCaller {
  cwd: string;
  desk: string;
  session: string;
  role: string;
}
type Store = Pick<
  QuestionStore,
  | "snapshot"
  | "scopedSnapshot"
  | "beginScopedAction"
  | "prepareScopedCommit"
  | "endScopedAction"
  | "revokeGrant"
  | "pauseGrant"
  | "resumeGrant"
>;
function fail(reason: string): never {
  throw new ScopeError(reason);
}
function callerMatches(scope: JobScope, caller: ScopedCaller) {
  if (
    Object.keys(caller).sort().join() !== ["cwd", "desk", "session", "role"].sort().join() ||
    !["", "lead", "builder", "autopilot"].includes(caller.role) ||
    realpathSync(caller.cwd) !== scope.worktree ||
    caller.desk !== scope.desk ||
    caller.session !== scope.session
  )
    fail("caller is not the exact authorized writing desk/session");
}
function requestShape(request: ScopedRequest) {
  const keys = ["requestId", "grantId", "action", "candidate"];
  if (
    Object.keys(request).sort().join() !== keys.sort().join() ||
    !["commit", "publish-fast-forward"].includes(request.action) ||
    typeof request.requestId !== "string" ||
    !request.requestId.trim() ||
    typeof request.grantId !== "string" ||
    !request.grantId.trim()
  )
    fail("only a structured scoped action is accepted");
  const candidate = request.candidate;
  if (
    !candidate ||
    Object.keys(candidate).sort().join() !== ["head", "tree", "base", "description", "evidence"].sort().join() ||
    [candidate.head, candidate.tree, candidate.base].some(
      (value) => typeof value !== "string" || !/^(?:[a-f0-9]{40}|[a-f0-9]{64})$/.test(value),
    ) ||
    [candidate.description, candidate.evidence].some(
      (value) => typeof value !== "string" || !/^[a-f0-9]{64}$/.test(value),
    )
  )
    fail("invalid immutable candidate");
}
function lockTarget(scope: JobScope): () => void {
  const dir = join(process.env.XDG_STATE_HOME || join(process.env.HOME!, ".local/state"), "bercail/scoped-locks");
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  const fd = openSync(join(dir, `${digest(canonical([scope.repo, scope.endpoint, scope.headRef]))}.lock`), "a", 0o600);
  const locked = spawnSync("flock", ["--exclusive", "--nonblock", "3"], {
    env: scopedEnv(),
    stdio: ["ignore", "pipe", "pipe", fd],
    timeout: 5000,
  });
  if (locked.status !== 0 || locked.error) {
    closeSync(fd);
    throw new ScopeError("target is executing or its lock is unavailable", "paused");
  }
  // The child gets this open-file description too, so parent death cannot free a live local executor's lock.
  const release = () => closeSync(fd);
  return Object.assign(release, { fd });
}
function assertNoRewriteState(scope: JobScope) {
  const gitDir = scopedGit(scope.worktree, "rev-parse", "--absolute-git-dir");
  if (
    ["MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply", "sequencer"].some((name) =>
      existsSync(join(gitDir, name)),
    )
  )
    fail("merge/rewrite/sequencer state is outside the grant");
}
function commitMessage(state: Store, grantId: string, scope: JobScope, candidate: ScopedCandidate): string {
  const bytes = readFileSync(join(scope.worktree, ".bercail/description.md"));
  if (
    digest(bytes) !== candidate.description ||
    digest(readFileSync(join(scope.worktree, ".bercail/validate.json"))) !== candidate.evidence
  )
    fail("description/evidence changed");
  const match = /^---\r?\n([\s\S]*?)\r?\n---\r?\n([\s\S]*)$/.exec(bytes.toString());
  let title = match?.[1].match(/^title:\s*(.+)$/m)?.[1].trim();
  if (!title || !match) fail("checked description has no title/body");
  if (title.startsWith('"')) title = JSON.parse(title);
  else if (title.startsWith("'") && title.endsWith("'")) title = title.slice(1, -1).replace(/''/g, "'");
  if (typeof title !== "string" || !title || title.includes("\n")) fail("invalid checked title");
  const agent = match[1].match(/^agent: (.*)$/m)?.[1].trim() || "";
  const by = `bercail${agent ? ` (${agent})` : ""}`;
  const review = state
    .scopedSnapshot()
    .reviews.find(
      (value) =>
        value.grantId === grantId &&
        canonical(value.scope) === canonical(scope) &&
        canonical(value.candidate) === canonical(candidate),
    );
  const question =
    review && state.snapshot().questions.find((value) => `${value.id}@${value.revision}` === review.question);
  const source = question && question.answer?.source;
  const channel =
    source === "panel picker" ? "Decisions picker" : source === "discuss picker" ? "Discuss picker" : null;
  const provenance = readScopedPolicy(scope.worktree).policy.provenance || "line";
  const lines =
    provenance === "none"
      ? []
      : provenance === "trailer"
        ? [`Assisted-by: ${by}`, ...(channel ? [`Review-source: ${channel}`] : [])]
        : [`Written with ${by}; ${channel ? `reviewed via ${channel}` : "not yet reviewed"}`];
  return `${title}\n\n${match[2].trim()}${lines.length ? `\n\n${lines.join("\n")}` : ""}\n`;
}
function remoteHead(scope: JobScope): string | null {
  if (publicationEndpoint(scope.worktree, scope.remote) !== scope.endpoint) fail("publication endpoint changed");
  const output = scopedGit(scope.worktree, "ls-remote", "--refs", "--", scope.endpoint, scope.headRef);
  if (!output) return null;
  const rows = output.split("\n");
  const match = /^([a-f0-9]{40}|[a-f0-9]{64})\t(.+)$/.exec(rows[0]);
  if (rows.length !== 1 || !match || match[2] !== scope.headRef) fail("remote returned an ambiguous ref");
  return match[1];
}
function indexIsTree(scope: JobScope, tree: string): boolean {
  return (
    spawnSync("git", ["diff", "--cached", "--quiet", tree, "--"], {
      cwd: scope.worktree,
      env: scopedEnv(),
      timeout: 5000,
      stdio: "ignore",
    }).status === 0
  );
}
function commitResult(scope: JobScope, candidate: ScopedCandidate, expected?: string): string | null {
  if (scopedGit(scope.worktree, "symbolic-ref", "HEAD") !== scope.headRef) fail("commit head ref changed");
  const head = scopedGit(scope.worktree, "rev-parse", "HEAD");
  if (head === candidate.head) return null;
  if (!expected || head !== expected) fail("unexpected local HEAD does not match the durable verified commit OID");
  const parts = scopedGit(scope.worktree, "show", "-s", "--format=%T %P", head).split(" ");
  if (
    parts.length !== 2 ||
    parts[0] !== candidate.tree ||
    parts[1] !== candidate.head ||
    !indexIsTree(scope, candidate.tree)
  )
    fail("commit result differs from the authorized parent/tree or index");
  return head;
}
interface EffectResult {
  code: number | null;
  interrupted: boolean;
  output: string;
}
function effect(
  scope: JobScope,
  args: string[],
  fd: number,
  signal?: AbortSignal,
  extra: NodeJS.ProcessEnv = {},
  input?: string,
): Promise<EffectResult> {
  return new Promise((resolve) => {
    const child = spawn("git", args, {
      cwd: scope.worktree,
      env: scopedEnv(extra),
      stdio: ["pipe", "pipe", "pipe", fd],
    });
    let output = "";
    let interrupted = false;
    const stop = () => {
      interrupted = true;
      child.kill("SIGKILL");
    };
    const timer = setTimeout(stop, 15000);
    signal?.addEventListener("abort", stop, { once: true });
    for (const stream of [child.stdout, child.stderr])
      stream?.on("data", (data: Buffer) => {
        if (output.length < 1024 * 1024) output += data.toString();
      });
    child.stdin?.on("error", () => {});
    child.stdin?.end(input);
    child.once("error", () => {
      interrupted = true;
    });
    child.once("close", (code) => {
      clearTimeout(timer);
      signal?.removeEventListener("abort", stop);
      resolve({ code, interrupted, output });
    });
    if (signal?.aborted) stop();
  });
}
function bindingFailure(state: Store, grantId: string, error: unknown) {
  const message = (error as Error).message;
  if (error instanceof ScopeError && error.disposition === "ended") state.revokeGrant(grantId, message);
  else state.pauseGrant(grantId, message);
}

/** Executes only a fresh durable start. A duplicate is an inspection, never a retry. */
export async function executeScoped(
  state: Store,
  request: ScopedRequest,
  caller: ScopedCaller,
  signal?: AbortSignal,
): Promise<ScopedActionReceipt> {
  requestShape(request);
  const snapshot = state.scopedSnapshot();
  const grant = snapshot.grants.find((value) => value.id === request.grantId) || fail("unknown grant");
  callerMatches(grant.scope, caller);
  const release = lockTarget(grant.scope) as (() => void) & { fd: number };
  try {
    const prior = state.scopedSnapshot().actions.find((value) => value.requestId === request.requestId);
    if (prior) {
      if (
        prior.grantId !== request.grantId ||
        prior.action !== request.action ||
        canonical(prior.candidate) !== canonical(request.candidate)
      )
        fail("request id reused with different payload");
      return inspectLocked(state, prior, grant.scope);
    }
    let fresh: ReturnType<typeof captureCandidate>;
    let observedRemoteHead: string | null = null;
    try {
      fresh = captureCandidate(grant.scope);
      callerMatches(grant.scope, caller);
      assertNoRewriteState(grant.scope);
      if (canonical(fresh.candidate) !== canonical(request.candidate))
        throw new CandidateError("candidate changed since requested");
      if (request.action === "commit") {
        if (scopedGit(grant.scope.worktree, "rev-parse", "HEAD^{tree}") === request.candidate.tree)
          throw new CandidateError("empty commits are outside the grant");
      } else {
        if (scopedGit(grant.scope.worktree, "rev-parse", "HEAD^{tree}") !== request.candidate.tree)
          throw new CandidateError("publication requires an already committed candidate");
        // A read is not the enforcement: the push below still relies on Git's non-force ref update.
        const before = remoteHead(grant.scope);
        observedRemoteHead = before;
        if (!before) fail("feature ref must already exist at the endpoint");
        const ancestor = spawnSync("git", ["merge-base", "--is-ancestor", before, request.candidate.head], {
          cwd: grant.scope.worktree,
          env: scopedEnv(),
          timeout: 5000,
          stdio: "ignore",
        });
        if (ancestor.status !== 0) fail("remote feature ref is not a known ancestor of the candidate");
      }
      const finalCandidate = captureCandidate(grant.scope);
      if (
        canonical(finalCandidate.candidate) !== canonical(request.candidate) ||
        finalCandidate.reviewRequired !== fresh.reviewRequired
      )
        throw new CandidateError("candidate/review changed immediately before start");
    } catch (error) {
      if (!(error instanceof CandidateError)) bindingFailure(state, grant.id, error);
      throw error;
    }
    if (signal?.aborted) throw new ScopeError("execution aborted before start", "paused");
    // Pause is not renewal: identical live bindings and an unexpired, unquarantined grant may resume.
    if (state.scopedSnapshot().grants.find((value) => value.id === grant.id)?.state === "paused")
      state.resumeGrant(grant.id, grant.scope, () => new Date().toISOString());
    // No network or hooks under the ledger lock. This durable claim orders revoke/expiry against start.
    const started = state.beginScopedAction(
      request.requestId,
      request.grantId,
      request.action,
      request.candidate,
      grant.scope,
      () => new Date().toISOString(),
      fresh.reviewRequired,
      { remoteHead: observedRemoteHead, capability: SCOPED_CAPABILITY },
    );
    if (started.duplicate) return inspectLocked(state, started, grant.scope);
    let temporary: string | undefined;
    let indexLock: { fd: number; path: string } | undefined;
    let effectsStarted = false;
    try {
      const postClaim = captureCandidate(grant.scope);
      assertNoRewriteState(grant.scope);
      if (
        canonical(postClaim.candidate) !== canonical(request.candidate) ||
        postClaim.reviewRequired !== fresh.reviewRequired
      )
        throw new CandidateError("candidate/review changed while claiming execution");
      if (signal?.aborted) throw new CandidateError("aborted before any commit/publication process started");
      let result: EffectResult;
      if (request.action === "commit") {
        const message = commitMessage(state, grant.id, grant.scope, request.candidate);
        const gitDir = scopedGit(grant.scope.worktree, "rev-parse", "--absolute-git-dir");
        const lockPath = join(gitDir, "index.lock");
        indexLock = { fd: openSync(lockPath, "wx", 0o600), path: lockPath };
        writeFileSync(
          indexLock.fd,
          canonical({
            kind: "scoped-index-lock",
            requestId: request.requestId,
            scope: digest(canonical(grant.scope)),
            pid: process.pid,
            ticks: processTicks(process.pid),
            boot: readFileSync("/proc/sys/kernel/random/boot_id", "utf8").trim(),
          }),
        );
        temporary = mkdtempSync(join(process.env.XDG_RUNTIME_DIR!, "scoped-index-"));
        const index = join(temporary, "index");
        writeFileSync(join(temporary, "HEAD"), `${request.candidate.head}\n`, { mode: 0o600 });
        writeFileSync(join(temporary, "commondir"), `${grant.scope.repo}\n`, { mode: 0o600 });
        const privateEnv = {
          GIT_DIR: temporary,
          GIT_COMMON_DIR: grant.scope.repo,
          GIT_WORK_TREE: grant.scope.worktree,
          GIT_INDEX_FILE: index,
        };
        const prepared = spawnSync("git", ["read-tree", request.candidate.tree], {
          cwd: grant.scope.worktree,
          env: scopedEnv(privateEnv),
          timeout: 5000,
          stdio: "ignore",
        });
        if (prepared.status !== 0)
          return state.endScopedAction(
            request.requestId,
            "no-effect",
            "private index preparation failed before commit",
          );
        // Commit detached first: hooks cannot make an unchecked parent/tree the authorized feature tip.
        effectsStarted = true;
        result = await effect(grant.scope, ["commit", "-F", "-"], release.fd, signal, privateEnv, message);
        if (result.interrupted)
          return state.endScopedAction(
            request.requestId,
            "inspect",
            "commit outcome interrupted; inspect before any further action",
          );
        const detached = readFileSync(join(temporary, "HEAD"), "utf8").trim();
        if (detached === request.candidate.head && result.code !== 0 && !commitResult(grant.scope, request.candidate))
          return state.endScopedAction(
            request.requestId,
            "no-effect",
            "authorized HEAD unchanged after completed detached commit failure",
          );
        if (
          !/^(?:[a-f0-9]{40}|[a-f0-9]{64})$/.test(detached) ||
          scopedGit(grant.scope.worktree, "show", "-s", "--format=%T %P", detached) !==
            `${request.candidate.tree} ${request.candidate.head}` ||
          !indexIsTree(grant.scope, request.candidate.tree) ||
          scopedGit(grant.scope.worktree, "symbolic-ref", "HEAD") !== grant.scope.headRef
        )
          fail("hook or external writer changed the checked commit parent/tree/index/ref");
        if (result.code !== 0)
          return state.endScopedAction(request.requestId, "inspect", "detached commit completion uncertain");
        if (scopedGit(grant.scope.worktree, "show", "-s", "--format=%B", detached) !== message.trim())
          fail("hook changed the checked commit message");
        refreshJobScope(grant.scope);
        if (commitMessage(state, grant.id, grant.scope, request.candidate) !== message)
          fail("checked description/provenance changed during hooks");
        // Persist the exact verified object before CAS, so recovery cannot bless an unrelated replacement commit.
        state.prepareScopedCommit(request.requestId, detached);
        result = await effect(
          grant.scope,
          ["update-ref", "-m", "scoped checked commit", grant.scope.headRef, detached, request.candidate.head],
          release.fd,
          signal,
        );
        if (result.interrupted)
          return state.endScopedAction(request.requestId, "inspect", "commit ref update outcome interrupted");
        const committed = commitResult(grant.scope, request.candidate, detached);
        if (committed === detached && result.code === 0)
          return state.endScopedAction(request.requestId, "succeeded", committed);
        return state.endScopedAction(request.requestId, "inspect", "commit returned without a verified ref update");
      }
      effectsStarted = true;
      result = await effect(
        grant.scope,
        [
          "-c",
          "push.followTags=false",
          "-c",
          `remote.${grant.scope.remote}.mirror=false`,
          "push",
          "--no-follow-tags",
          "--",
          grant.scope.endpoint,
          `${request.candidate.head}:${grant.scope.headRef}`,
        ],
        release.fd,
        signal,
      );
      const actual = remoteHead(grant.scope);
      if (!result.interrupted && result.code === 0 && actual === request.candidate.head)
        return state.endScopedAction(request.requestId, "succeeded", actual);
      // A completed Git rejection is evidence, unlike a timeout/nonzero exit by itself.
      if (
        !result.interrupted &&
        /^ ! \[(?:rejected|remote rejected)\].*\((?:non-fast-forward|fetch first|failed to update ref|incorrect old value provided)\)\s*$/m.test(
          result.output,
        )
      )
        return state.endScopedAction(request.requestId, "conflict", "remote rejected non-fast-forward publication");
      return state.endScopedAction(request.requestId, "inspect", "remote completion is uncertain; no automatic resend");
    } catch (error) {
      if (!effectsStarted) {
        if (!(error instanceof CandidateError)) bindingFailure(state, grant.id, error);
        return state.endScopedAction(
          request.requestId,
          "no-effect",
          "rejected before any commit/publication process started",
        );
      }
      if (error instanceof ScopeError && error.disposition === "ended") {
        if (request.action === "commit") return state.endScopedAction(request.requestId, "conflict", error.message);
        state.revokeGrant(grant.id, error.message);
      }
      return state.endScopedAction(request.requestId, "inspect", "outcome unavailable; no automatic resend");
    } finally {
      if (indexLock) {
        const held = fstatSync(indexLock.fd);
        try {
          const current = lstatSync(indexLock.path);
          if (held.dev === current.dev && held.ino === current.ino) rmSync(indexLock.path);
        } finally {
          closeSync(indexLock.fd);
        }
      }
      if (temporary) rmSync(temporary, { recursive: true, force: true });
    }
  } finally {
    release();
  }
}

function processTicks(pid: number): string | null {
  try {
    const stat = readFileSync(`/proc/${pid}/stat`, "utf8");
    return (
      stat
        .slice(stat.lastIndexOf(")") + 2)
        .trim()
        .split(/\s+/)[19] || null
    );
  } catch {
    return null;
  }
}
function recoverIndexLock(scope: JobScope, receipt: ScopedActionReceipt) {
  const path = join(scopedGit(scope.worktree, "rev-parse", "--absolute-git-dir"), "index.lock");
  if (!existsSync(path)) return;
  const before = lstatSync(path);
  if (!before.isFile() || before.isSymbolicLink()) return;
  let owner;
  try {
    owner = JSON.parse(readFileSync(path, "utf8"));
  } catch {
    return;
  }
  if (
    owner.kind !== "scoped-index-lock" ||
    owner.requestId !== receipt.requestId ||
    owner.scope !== digest(canonical(scope)) ||
    !Number.isSafeInteger(owner.pid) ||
    typeof owner.ticks !== "string" ||
    typeof owner.boot !== "string"
  )
    return;
  const boot = readFileSync("/proc/sys/kernel/random/boot_id", "utf8").trim();
  if (owner.boot === boot && processTicks(owner.pid) === owner.ticks) return;
  const current = lstatSync(path);
  if (current.dev === before.dev && current.ino === before.ino) rmSync(path);
}
function inspectLocked(state: Store, receipt: ScopedActionReceipt, scope: JobScope): ScopedActionReceipt {
  if (!["applying", "inspect"].includes(receipt.state)) return receipt;
  // Even seeing C (or old E) cannot prove an interrupted remote request has quiesced.
  const pending = state.endScopedAction(
    receipt.requestId,
    "inspect",
    receipt.result || "recovered unfinished execution; never replay automatically",
  );
  try {
    recoverIndexLock(scope, receipt);
    if (receipt.action === "publish-fast-forward") {
      remoteHead(scope);
      return pending;
    }
    const expected = receipt.expectedCommit || undefined;
    const committed = commitResult(scope, receipt.candidate, expected);
    return committed ? state.endScopedAction(receipt.requestId, "succeeded", committed) : pending;
  } catch (error) {
    if (error instanceof ScopeError && error.disposition === "ended") {
      if (receipt.action === "commit") return state.endScopedAction(receipt.requestId, "conflict", error.message);
      state.revokeGrant(receipt.grantId, error.message);
    }
    return pending;
  }
}

/** Recovery reads Git/remote state and may reconcile receipts; it NEVER commits or pushes. */
export async function inspectScoped(
  state: Store,
  requestId: string,
  caller?: ScopedCaller,
): Promise<ScopedActionReceipt> {
  const snapshot = state.scopedSnapshot();
  const receipt = snapshot.actions.find((value) => value.requestId === requestId) || fail("unknown action request");
  const grant = snapshot.grants.find((value) => value.id === receipt.grantId) || fail("unknown grant");
  if (caller) callerMatches(grant.scope, caller);
  const release = lockTarget(grant.scope);
  try {
    return inspectLocked(state, receipt, grant.scope);
  } finally {
    release();
  }
}
