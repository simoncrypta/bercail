import { execFileSync, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, readFileSync, readdirSync, readlinkSync, realpathSync } from "node:fs";
import { isAbsolute, join } from "node:path";
import { fileURLToPath } from "node:url";
import { captureTarget } from "./question-target.ts";
import type { JobScope, ScopedCandidate } from "./scoped-types.ts";

export interface JobScopeInput {
  repo: string;
  issue: string;
  topic: string;
  desk: string;
  base: string;
  pr: string;
  remote: string;
}
export class ScopeError extends Error {
  readonly disposition: "ended" | "paused";
  constructor(message: string, disposition: "ended" | "paused" = "ended") {
    super(`Scoped job: ${message}`);
    this.disposition = disposition;
  }
}
export class CandidateError extends Error {
  constructor(message: string) {
    super(`Scoped candidate: ${message}`);
  }
}
function fail(message: string): never {
  throw new ScopeError(message);
}
function candidateFail(message: string): never {
  throw new CandidateError(message);
}
function candidateRead(path: string): Buffer {
  try {
    return readFileSync(path);
  } catch {
    return candidateFail("description/evidence unavailable; run validation");
  }
}
export function digest(value: string | Buffer): string {
  return createHash("sha256").update(value).digest("hex");
}
export function canonical(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  if (value && typeof value === "object")
    return `{${Object.entries(value)
      .sort(([a], [b]) => a.localeCompare(b))
      .map(([k, v]) => `${JSON.stringify(k)}:${canonical(v)}`)
      .join(",")}}`;
  return JSON.stringify(value);
}
export function scopedEnv(extra: NodeJS.ProcessEnv = {}): NodeJS.ProcessEnv {
  return {
    ...Object.fromEntries(
      Object.entries(process.env).filter(
        ([key]) => !/^(BEADS_|BD_|GIT_)/.test(key) || /^GIT_(AUTHOR_|COMMITTER_|CONFIG_NOSYSTEM$)/.test(key),
      ),
    ),
    GIT_TERMINAL_PROMPT: "0",
    ...extra,
  };
}
export function scopedRun(command: string, args: string[], cwd: string): string {
  try {
    return execFileSync(command, args, {
      cwd,
      env: scopedEnv(),
      encoding: "utf8",
      timeout: 5000,
      maxBuffer: 1024 * 1024,
      stdio: ["ignore", "pipe", "pipe"],
    }).trim();
  } catch {
    throw new ScopeError(`${command} facts unavailable`, "paused");
  }
}
export const scopedGit = (cwd: string, ...args: string[]) => scopedRun("git", args, cwd);
const json = (path: string) => JSON.parse(readFileSync(path, "utf8"));
function required(value: unknown, name: string): asserts value is string {
  if (typeof value !== "string" || !value.trim() || /[\0\r\n]/.test(value))
    fail(`${name} must be nonempty single-line text`);
}
const stateDir = () => process.env.XDG_STATE_HOME || join(process.env.HOME!, ".local/state");

export function readScopedPolicy(worktree: string) {
  const value = JSON.parse(
    scopedRun(process.env.BERCAIL_SHEP_BIN || "bercail", ["policy", "show", "--json", worktree], worktree),
  );
  if (
    !value?.policy ||
    !value.sources ||
    typeof value.trusted !== "boolean" ||
    realpathSync(value.root) !== worktree ||
    realpathSync(scopedGit(value.repo, "rev-parse", "--path-format=absolute", "--git-common-dir")) !==
      realpathSync(scopedGit(worktree, "rev-parse", "--path-format=absolute", "--git-common-dir"))
  )
    fail("policy is not for this checkout");
  if (!["always", "by-stakes", "none"].includes(value.policy.review) || !Array.isArray(value.policy.high_stakes))
    fail("review policy unavailable");
  return value;
}

function policyFingerprint(worktree: string, policy: unknown): string {
  return digest(
    canonical({ policy, gitConfig: digest(scopedGit(worktree, "config", "--null", "--show-origin", "--list")) }),
  );
}

// Reject indirection rather than guessing which configured effects an explicit refspec overrides.
export function publicationEndpoint(worktree: string, remote: string): string {
  if (!/^[a-zA-Z0-9][a-zA-Z0-9_-]*$/.test(remote)) fail("invalid remote name");
  const config = scopedGit(worktree, "config", "--null", "--list");
  for (const item of config.split("\0").filter(Boolean)) {
    const key = item.slice(0, item.indexOf("\n")).toLowerCase();
    if (
      /^(url\.|alias\.|protocol\.|push\.|remote\.pushdefault$|core\.(sshcommand|gitproxy)$|ssh\.|submodule\.|extensions\.)/.test(
        key,
      ) ||
      /^remote\..*\.(push|mirror|receivepack|uploadpack|vcs|proxy|pushoption)$/.test(key) ||
      /^branch\..*\.pushremote$/.test(key)
    )
      fail("unsupported publication config");
  }
  const urls = scopedGit(worktree, "remote", "get-url", "--push", "--all", remote).split("\n");
  if (urls.length !== 1 || !urls[0]) fail("exactly one push URL is required");
  const effective = urls[0];
  const raw = scopedGit(worktree, "config", "--null", "--get-all", `remote.${remote}.url`).split("\0").filter(Boolean);
  const pushes = config
    .split("\0")
    .filter((item) => item.startsWith(`remote.${remote}.pushurl\n`))
    .map((item) => item.slice(item.indexOf("\n") + 1));
  if (raw.length !== 1 || pushes.length > 1 || effective !== (pushes[0] || raw[0]))
    fail("remote URL is ambiguous or rewritten");
  if (isAbsolute(effective)) {
    const endpoint = realpathSync(effective);
    if (scopedGit(worktree, "--git-dir", endpoint, "rev-parse", "--is-bare-repository") !== "true")
      fail("local endpoint is not bare");
    return endpoint;
  }
  let url: URL;
  try {
    url = new URL(effective);
  } catch {
    return fail("unsupported endpoint transport");
  }
  if (
    url.protocol !== "https:" ||
    url.username ||
    url.password ||
    url.search ||
    url.hash ||
    !/^\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+(?:\.git)?$/.test(url.pathname)
  )
    fail("endpoint must be credential-free HTTPS or an absolute local bare repository");
  return url.href;
}

function denyPaths(paths: string[], candidate = false) {
  if (
    paths.some((path) =>
      /(^|\/)(\.env(?:\.[^/]*)?|\.git|\.ssh|\.aws|\.gnupg|credentials(?:\.[^/]*)?|secrets?(?:\.[^/]*)?)(\/|$)|^(?:\.bercail|config)\//i.test(
        path,
      ),
    )
  )
    (candidate ? candidateFail : fail)("secrets/config paths are outside scoped commit/publication authority");
}

export function checkOutgoingHistory(scope: Pick<JobScope, "worktree" | "endpoint" | "headRef">, head = "HEAD") {
  const output = scopedGit(scope.worktree, "ls-remote", "--refs", "--", scope.endpoint, scope.headRef);
  const rows = output.split("\n");
  const match = /^([a-f0-9]{40}|[a-f0-9]{64})\t(.+)$/.exec(rows[0]);
  if (rows.length !== 1 || !match || match[2] !== scope.headRef) fail("exact existing remote feature ref unavailable");
  const remote = match[1];
  scopedGit(scope.worktree, "cat-file", "-e", `${remote}^{commit}`);
  const ancestor = spawnSync("git", ["merge-base", "--is-ancestor", remote, head], {
    cwd: scope.worktree,
    env: scopedEnv(),
    timeout: 5000,
    stdio: "ignore",
  });
  if (ancestor.status !== 0) fail("remote feature ref is not a known ancestor of the candidate");
  const history = scopedGit(scope.worktree, "rev-list", "--parents", `${remote}..${head}`).split("\n").filter(Boolean);
  for (const row of history) {
    const parts = row.split(" ");
    if (parts.length !== 2) fail("outgoing merge/root histories are outside scoped publication authority");
    denyPaths(
      scopedGit(
        scope.worktree,
        "diff-tree",
        "--no-commit-id",
        "--no-renames",
        "-r",
        "--name-only",
        "-z",
        parts[0],
        "--",
      )
        .split("\0")
        .filter(Boolean),
    );
  }
}

function ownership(worktree: string, repo: string, headRef: string, desk: string, session: string, space: string) {
  const record = json(join(stateDir(), "bercail/desk-sessions", `${desk}.json`));
  const live = JSON.parse(scopedRun("hc", ["get", desk, "--json"], worktree));
  const pid = live.foreground?.pid;
  if (!Number.isSafeInteger(pid) || pid < 1 || record.pid !== pid || !process.env.XDG_RUNTIME_DIR)
    fail("exact foreground owner is not recorded");
  const stat = readFileSync(`/proc/${pid}/stat`, "utf8");
  const ticks = stat
    .slice(stat.lastIndexOf(")") + 2)
    .trim()
    .split(/\s+/)[19];
  const boot = readFileSync("/proc/sys/kernel/random/boot_id", "utf8").trim();
  const claim = json(join(process.env.XDG_RUNTIME_DIR, "bercail/open-sessions", `${pid}.json`));
  if (
    !/^\d+$/.test(ticks || "") ||
    claim.pid !== pid ||
    claim.start_ticks !== ticks ||
    (claim.boot_id !== undefined && claim.boot_id !== boot) ||
    !Array.isArray(claim.sessions) ||
    claim.sessions.length !== 1 ||
    claim.sessions[0] !== session ||
    record.session !== session ||
    record.space !== space
  )
    fail("foreground process/session owner changed");
  const listing = JSON.parse(scopedRun("hc", ["ls", "--json"], worktree));
  if (!Array.isArray(listing.terminals)) fail("terminal ownership listing unavailable");
  if (listing.terminals.filter((t: { address?: string }) => t.address === desk).length !== 1)
    fail("owner missing from terminal listing");
  const competingCwd = (cwd: string, uncertain = false) => {
    const conflict = (message: string): never => {
      throw new ScopeError(message, uncertain ? "paused" : "ended");
    };
    const path = realpathSync(cwd);
    if (path === worktree || path.startsWith(`${worktree}/`))
      conflict("another terminal/process can write this worktree");
    const probe = spawnSync("git", ["rev-parse", "--is-inside-work-tree"], {
      cwd: path,
      env: scopedEnv(),
      encoding: "utf8",
      timeout: 5000,
      stdio: ["ignore", "pipe", "pipe"],
    });
    if (probe.error || probe.signal) throw new ScopeError("competing writer facts unavailable", "paused");
    if (probe.status !== 0) return;
    const otherRepo = realpathSync(scopedGit(path, "rev-parse", "--path-format=absolute", "--git-common-dir"));
    if (otherRepo === repo && scopedGit(path, "symbolic-ref", "HEAD") === headRef)
      conflict("another terminal/process can write this repository/ref");
  };
  for (const terminal of listing.terminals) {
    if (terminal.address === desk || terminal.state !== "live") continue;
    const idleShell =
      terminal.reason == null &&
      ["bash", "zsh", "fish", "sh", "dash", "ksh"].includes(terminal.foreground?.name) &&
      terminal.foreground.pid === terminal.pid &&
      !terminal.reported &&
      Object.keys(terminal.records || {}).length === 0;
    if (idleShell) continue;
    const uncertain = terminal.reason != null || !terminal.foreground;
    if (Object.hasOwn(terminal.records || {}, session) || terminal.foreground?.pid === pid)
      throw new ScopeError("another terminal claims this session/owner", uncertain ? "paused" : "ended");
    const cwd = terminal.foreground?.cwd || terminal.cwd;
    if (typeof cwd !== "string") throw new ScopeError("competing terminal cwd unavailable", "paused");
    competingCwd(cwd, uncertain);
  }
  const claims = join(process.env.XDG_RUNTIME_DIR, "bercail/open-sessions");
  for (const file of readdirSync(claims).filter((name) => /^\d+\.json$/.test(name))) {
    if (file === `${pid}.json`) continue;
    const other = json(join(claims, file));
    if (!Number.isSafeInteger(other.pid) || file !== `${other.pid}.json` || !Array.isArray(other.sessions))
      throw new ScopeError("writer claim malformed", "paused");
    let otherTicks: string;
    try {
      const stat = readFileSync(`/proc/${other.pid}/stat`, "utf8");
      otherTicks = stat
        .slice(stat.lastIndexOf(")") + 2)
        .trim()
        .split(/\s+/)[19];
    } catch {
      continue;
    }
    if (
      other.start_ticks !== otherTicks ||
      (other.boot_id !== undefined && other.boot_id !== boot) ||
      !other.sessions.length
    )
      continue;
    if (other.sessions.includes(session)) fail("another live process claims this session");
    competingCwd(readlinkSync(`/proc/${other.pid}/cwd`));
  }
  return { pid, ticks, boot };
}

export function captureJobScope(input: JobScopeInput): JobScope {
  try {
    for (const [key, value] of Object.entries(input)) required(value, key);
    if (Object.keys(input).sort().join() !== ["repo", "issue", "topic", "desk", "base", "pr", "remote"].sort().join())
      fail("invalid scope input fields");
    if (
      Object.keys(process.env).some((key) =>
        /^GIT_(DIR|WORK_TREE|COMMON_DIR|INDEX_FILE|OBJECT_DIRECTORY|ALTERNATE_OBJECT_DIRECTORIES|NAMESPACE|CONFIG_COUNT|CONFIG_PARAMETERS|CONFIG_KEY_\d+|CONFIG_VALUE_\d+)$/.test(
          key,
        ),
      )
    )
      fail("inherited git addressing/config is unsupported");
    let prUrl: URL;
    try {
      prUrl = new URL(input.pr);
    } catch {
      return fail("explicit canonical credential-free PR URL required");
    }
    if (
      prUrl.protocol !== "https:" ||
      prUrl.username ||
      prUrl.password ||
      prUrl.search ||
      prUrl.hash ||
      prUrl.href !== input.pr ||
      !/^[A-Za-z0-9.-]+$/.test(prUrl.host) ||
      !/^\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\/pull\/[1-9]\d*$/.test(prUrl.pathname)
    )
      fail("explicit canonical credential-free PR URL required");
    const target = captureTarget({
      kind: "planning",
      repo: input.repo,
      issue: input.issue,
      topic: input.topic,
      desk: input.desk,
      base: input.base,
      action: null,
    });
    const worktree = target.worktree!;
    const jobs = JSON.parse(scopedRun("bd", ["show", input.issue, "--json"], worktree));
    if (
      !Array.isArray(jobs) ||
      jobs.length !== 1 ||
      jobs[0].id !== input.issue ||
      !["open", "in_progress", "blocked", "deferred"].includes(jobs[0].status)
    )
      fail("job is completed, closed, or its status cannot authorize work");
    const headRef = scopedGit(worktree, "symbolic-ref", "HEAD");
    const baseRef = input.base.startsWith("refs/heads/") ? input.base : `refs/heads/${input.base}`;
    for (const ref of [headRef, baseRef]) scopedGit(worktree, "check-ref-format", ref);
    if (
      !headRef.startsWith("refs/heads/") ||
      headRef === baseRef ||
      /^refs\/heads\/(main|master|release(?:[/-].*)?)$/.test(headRef)
    )
      fail("only a full feature head ref is supported");
    const endpoint = publicationEndpoint(worktree, input.remote);
    // Do not let native-host detection run an Origin CLI probe in a gh-only adapter.
    const origin = scopedGit(worktree, "remote", "get-url", "origin");
    if (/^entire:|origin(?:-[a-z0-9]+)?\.cursor\.com/i.test(origin)) fail("native origin/entire backend unsupported");
    if (
      [".graphite_repo_config", ".graphite_metadata.db"].some((name) => existsSync(join(target.repo, name))) ||
      scopedGit(worktree, "for-each-ref", "--format=%(refname)", "refs/branch-metadata/")
    )
      fail("Graphite tracking/configuration is unsupported or ambiguous");
    const backend = scopedRun(
      "bash",
      [
        "--noprofile",
        "--norc",
        "-c",
        'source "$1"; config="$(_git_backend_config_file)"; if [[ -f "$config" ]]; then toml_records "$config" | jq -se \'all(.[]; (has("error") | not)) and all(.[] | select(.section == ["git"]); has("value") and (.value | IN("gh", "gt", "origin", "entire")))\' >/dev/null || exit 1; fi; git_backend "$2"',
        "scoped-backend",
        fileURLToPath(new URL("../../lib/git-backend.sh", import.meta.url)),
        worktree,
      ],
      worktree,
    );
    if (backend !== "gh") fail(`backend ${backend} cannot prove exact-ref fast-forward publication`);
    const pr = JSON.parse(
      scopedRun(
        "gh",
        [
          "pr",
          "view",
          input.pr,
          "--json",
          "url,state,headRefName,baseRefName,baseRefOid,headRepository,headRepositoryOwner",
        ],
        worktree,
      ),
    );
    const baseOid = scopedGit(worktree, "rev-parse", "--verify", "--end-of-options", `${baseRef}^{commit}`);
    if (
      pr.url !== input.pr ||
      pr.state !== "OPEN" ||
      `refs/heads/${pr.headRefName}` !== headRef ||
      `refs/heads/${pr.baseRefName}` !== baseRef ||
      pr.baseRefOid !== baseOid ||
      !pr.headRepository?.name ||
      !pr.headRepositoryOwner?.login
    )
      fail("PR repository/head/base binding changed");
    const catalog = join(target.repo, "gh-stack");
    if (existsSync(catalog)) {
      const value = json(catalog);
      if (
        !Array.isArray(value.stacks) ||
        value.stacks.some((stack: { branches?: unknown }) => !Array.isArray(stack.branches))
      )
        fail("gh-stack catalog unreadable");
      if (
        value.stacks.some((stack: { branches: { branch?: string; pullRequest?: { number?: number } }[] }) =>
          stack.branches.some(
            (branch) =>
              branch.branch === headRef.slice(11) || String(branch.pullRequest?.number) === input.pr.split("/").at(-1),
          ),
        )
      )
        fail("native gh-stack publication is unsupported");
    }
    const parts = prUrl.pathname.split("/");
    const stacks = JSON.parse(
      scopedRun(
        "gh",
        ["api", "--hostname", prUrl.hostname, `repos/${parts[1]}/${parts[2]}/stacks?pull_request=${parts[4]}`],
        worktree,
      ),
    );
    if (!Array.isArray(stacks)) fail("remote gh-stack membership unavailable");
    if (stacks.length) fail("native remote gh-stack publication is unsupported");
    if (isAbsolute(endpoint)) {
      if (pr.headRepository.url !== endpoint) fail("PR head repository does not match endpoint");
    } else {
      const url = new URL(endpoint);
      const name = `${pr.headRepositoryOwner.login}/${pr.headRepository.name}`;
      if (url.pathname.replace(/^\//, "").replace(/\.git$/, "") !== name || new URL(input.pr).host !== url.host)
        fail("PR head repository does not match endpoint");
    }
    const owner = ownership(worktree, target.repo, headRef, input.desk, target.session!, target.space!);
    const records = readFileSync(join(stateDir(), "bercail/handoffs.jsonl"), "utf8")
      .trim()
      .split("\n")
      .filter(Boolean)
      .map((line) => JSON.parse(line));
    const mapping = records.findLast((record) => record.path === worktree || record.desk === input.desk);
    if (!mapping) throw new ScopeError("handoff mapping unavailable", "paused");
    if (
      mapping.path !== worktree ||
      mapping.branch !== headRef.slice(11) ||
      mapping.issue !== input.issue ||
      mapping.desk !== input.desk ||
      mapping.space !== target.space ||
      mapping.git !== backend ||
      mapping.harness !== "pi"
    )
      fail("handoff mapping changed");
    checkOutgoingHistory({ worktree, endpoint, headRef });
    const policy = readScopedPolicy(worktree);
    return {
      repo: target.repo,
      worktree,
      issue: input.issue,
      pr: pr.url,
      headRef,
      baseRef,
      baseOid,
      remote: input.remote,
      endpoint,
      backend,
      desk: input.desk,
      space: target.space!,
      session: target.session!,
      owner: digest(
        canonical({ ...owner, headRepository: pr.headRepository, headRepositoryOwner: pr.headRepositoryOwner }),
      ),
      mapping: digest(canonical(mapping)),
      policy: policyFingerprint(worktree, policy),
    };
  } catch (error) {
    if (error instanceof ScopeError) throw error;
    if (
      /^Question target: (?:desk (?:is gone|cwd|belongs|space|session)|issue does not match)/.test(
        (error as Error).message,
      )
    )
      throw new ScopeError((error as Error).message);
    throw new ScopeError(`target facts unavailable: ${(error as Error).message}`, "paused");
  }
}

export function refreshJobScope(scope: JobScope): JobScope {
  // A definite local rebinding must not hide behind an unavailable replacement endpoint.
  const worktree = realpathSync(scopedGit(scope.worktree, "rev-parse", "--show-toplevel"));
  const repo = realpathSync(scopedGit(worktree, "rev-parse", "--path-format=absolute", "--git-common-dir"));
  if (
    worktree !== scope.worktree ||
    repo !== scope.repo ||
    scopedGit(worktree, "symbolic-ref", "HEAD") !== scope.headRef ||
    scopedGit(worktree, "rev-parse", "--verify", `${scope.baseRef}^{commit}`) !== scope.baseOid
  )
    fail("local repo/head/base scope binding changed");
  if (policyFingerprint(worktree, readScopedPolicy(worktree)) !== scope.policy)
    fail("local policy/config scope binding changed");
  const records = readFileSync(join(stateDir(), "bercail/handoffs.jsonl"), "utf8")
    .trim()
    .split("\n")
    .filter(Boolean)
    .map((line) => JSON.parse(line));
  const mapping = records.findLast((record) => record.path === scope.worktree || record.desk === scope.desk);
  if (mapping && digest(canonical(mapping)) !== scope.mapping) fail("handoff mapping changed");
  const current = captureJobScope({
    repo: scope.worktree,
    issue: scope.issue,
    topic: scope.issue,
    desk: scope.desk,
    base: scope.baseRef,
    pr: scope.pr,
    remote: scope.remote,
  });
  if (canonical(current) !== canonical(scope)) fail("stable scope binding changed");
  return current;
}

export function captureCandidate(scope: JobScope): { candidate: ScopedCandidate; reviewRequired: boolean } {
  refreshJobScope(scope);
  const head = scopedGit(scope.worktree, "rev-parse", "--verify", "HEAD^{commit}");
  const tree = scopedGit(scope.worktree, "write-tree");
  const description = candidateRead(join(scope.worktree, ".bercail/description.md"));
  const evidence = candidateRead(join(scope.worktree, ".bercail/validate.json"));
  const check = spawnSync(process.env.BERCAIL_SHEP_BIN || "bercail", ["describe", "check", "--json", scope.worktree], {
    cwd: scope.worktree,
    env: scopedEnv(),
    encoding: "utf8",
    timeout: 5000,
    maxBuffer: 1024 * 1024,
    stdio: ["ignore", "pipe", "pipe"],
  });
  if (check.error || check.signal || check.status !== 0) candidateFail("describe check unavailable or failed");
  const value = JSON.parse(check.stdout);
  const validation = JSON.parse(evidence.toString());
  if (
    value.file !== join(scope.worktree, ".bercail/description.md") ||
    value.stale !== false ||
    value.tree !== tree ||
    value.current_tree !== tree ||
    !Array.isArray(value.fails) ||
    value.fails.length ||
    !["required", "optional"].includes(value.change?.review) ||
    validation.tree !== tree ||
    !Array.isArray(validation.checks) ||
    !validation.checks.length ||
    validation.checks.some((c: { exit_code?: number }) => c.exit_code !== 0)
  )
    candidateFail("description/evidence is not fresh and successful for the candidate");
  const policy = readScopedPolicy(scope.worktree);
  if (policyFingerprint(scope.worktree, policy) !== scope.policy)
    fail("policy/config changed during candidate capture");
  const paths = scopedGit(scope.worktree, "diff", "--cached", "--no-renames", "--name-only", "-z", scope.baseOid, "--")
    .split("\0")
    .filter(Boolean);
  denyPaths(paths, true);
  if (policy.policy.review === "always" && value.change.review !== "required")
    fail("describe check disagrees with review policy");
  if (
    scopedGit(scope.worktree, "rev-parse", "HEAD") !== head ||
    scopedGit(scope.worktree, "write-tree") !== tree ||
    !description.equals(readFileSync(join(scope.worktree, ".bercail/description.md"))) ||
    !evidence.equals(readFileSync(join(scope.worktree, ".bercail/validate.json")))
  )
    candidateFail("candidate changed during capture");
  return {
    candidate: { head, tree, base: scope.baseOid, description: digest(description), evidence: digest(evidence) },
    reviewRequired: value.change.review === "required",
  };
}

/** Read-only, candidate-independent feasibility; call before editing, not just before publishing. */
export function feasibility(
  input: JobScopeInput,
): { supported: true; scope: JobScope } | { supported: false; reason: string } {
  try {
    return { supported: true, scope: captureJobScope(input) };
  } catch (error) {
    return { supported: false, reason: (error as Error).message };
  }
}
