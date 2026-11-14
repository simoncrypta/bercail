import { execFileSync } from "node:child_process";
import { readFileSync, realpathSync } from "node:fs";
import { join } from "node:path";
import type { Question, QuestionTarget } from "./questions.ts";

export interface TargetInput {
  kind: "planning" | "review" | "action";
  repo: string;
  issue: string | null;
  topic: string;
  desk: string | null;
  base: string | null;
  action: string | null;
}
const fail = (message: string): never => {
  throw new Error(`Question target: ${message}`);
};
function text(value: unknown, field: string): asserts value is string {
  if (typeof value !== "string" || !value.trim()) fail(`${field} must be nonempty`);
}
function nullable(value: unknown, field: string) {
  if (value !== null) text(value, field);
}
function run(command: string, args: string[], cwd: string): string {
  // Neither inherited git addressing nor a global beads database may redirect a target.
  const env = Object.fromEntries(
    Object.entries(process.env).filter(
      ([key]) =>
        !/^(BEADS_|BD_|GIT_(DIR|WORK_TREE|COMMON_DIR|INDEX_FILE|OBJECT_DIRECTORY|ALTERNATE_OBJECT_DIRECTORIES|NAMESPACE)$)/.test(
          key,
        ),
    ),
  );
  return execFileSync(command, args, {
    cwd,
    env,
    encoding: "utf8",
    timeout: 5000,
    maxBuffer: 1024 * 1024,
    stdio: ["ignore", "pipe", "pipe"],
  }).trim();
}
const git = (cwd: string, ...args: string[]) => run("git", args, cwd);
const identity = (cwd: string) => realpathSync(git(cwd, "rev-parse", "--path-format=absolute", "--git-common-dir"));
function commit(cwd: string, ref: string): string {
  return git(cwd, "rev-parse", "--verify", "--end-of-options", `${ref}^{commit}`);
}

// An idle hc may omit records. Only this desk's exact foreground process claim
// can replace them; a matching session open in some other terminal cannot.
function claimsSession(record: { pid?: number; session: string }, live: { foreground?: { pid?: number } }): boolean {
  const pid = record.pid;
  if (!Number.isInteger(pid) || !pid || pid < 1 || live.foreground?.pid !== pid || !process.env.XDG_RUNTIME_DIR)
    return false;
  try {
    const claim = JSON.parse(
      readFileSync(join(process.env.XDG_RUNTIME_DIR, "bercail/open-sessions", `${pid}.json`), "utf8"),
    );
    const stat = readFileSync(`/proc/${pid}/stat`, "utf8");
    const ticks = stat
      .slice(stat.lastIndexOf(")") + 2)
      .trim()
      .split(/\s+/)[19];
    return (
      claim.pid === pid &&
      /^\d+$/.test(ticks ?? "") &&
      claim.start_ticks === ticks &&
      Array.isArray(claim.sessions) &&
      claim.sessions.includes(record.session)
    );
  } catch {
    return false;
  }
}

export function captureTarget(input: TargetInput): QuestionTarget {
  if (!["planning", "review", "action"].includes(input.kind)) fail("invalid kind");
  text(input.repo, "repo");
  text(input.topic, "topic");
  for (const field of ["issue", "desk", "base", "action"] as const) nullable(input[field], field);
  if ((input.kind !== "planning" || input.issue !== null) && input.desk === null)
    fail("explicit desk required for a job, review or action question");
  if (input.kind !== "planning") {
    text(input.issue, "issue");
    text(input.base, "base");
    text(input.action, "action");
  }
  const worktree = realpathSync(git(realpathSync(input.repo), "rev-parse", "--show-toplevel"));
  const repo = identity(worktree);
  if (input.issue !== null) {
    if (input.issue.startsWith("-")) fail("invalid issue id");
    const jobs = JSON.parse(run("bd", ["show", input.issue, "--json"], worktree));
    if (!Array.isArray(jobs) || jobs.length !== 1 || jobs[0]?.id !== input.issue)
      fail("issue does not match repo-scoped beads job");
  }
  let space: string | null = null;
  let session: string | null = null;
  if (input.desk !== null) {
    if (!/^[a-zA-Z0-9_-]+$/.test(input.desk)) fail("desk must be an explicit terminal address");
    const state = process.env.XDG_STATE_HOME || join(process.env.HOME!, ".local/state");
    const record = JSON.parse(readFileSync(join(state, "bercail/desk-sessions", `${input.desk}.json`), "utf8"));
    const live = JSON.parse(run("hc", ["get", input.desk, "--json"], worktree));
    if (record.address !== input.desk || live.address !== input.desk || live.state !== "live" || live.reason != null)
      fail("desk is gone or not live at its recorded address");
    if (realpathSync(record.cwd) !== worktree || realpathSync(live.foreground?.cwd || live.cwd) !== worktree)
      fail("desk cwd does not match the target worktree");
    if (
      live.labels?.["bercail.role"] !== "agent" ||
      (record.issue || null) !== input.issue ||
      (live.labels?.["bercail.issue"] || null) !== input.issue
    )
      fail("desk belongs to another issue/job");
    text(record.space, "record space");
    text(record.session, "record session");
    if (record.space !== live.labels?.["bercail.space"]) fail("desk space does not match its session record");
    const recorded = Object.hasOwn(live.records ?? {}, record.session) && live.records[record.session]?.app === "pi";
    if (record.harness !== "pi" || (!recorded && !claimsSession(record, live)))
      fail("desk session is gone or does not match live records");
    space = record.space;
    session = record.session;
  }
  return {
    repo,
    issue: input.issue,
    topic: input.topic,
    worktree,
    desk: input.desk,
    space,
    session,
    head: commit(worktree, "HEAD"),
    stagedTree: git(worktree, "write-tree"),
    baseRef: input.base,
    base: input.base === null ? null : commit(worktree, input.base),
    action: input.action,
  };
}

export async function checkQuestion(question: Question) {
  const target = question.target;
  const reasons: string[] = [];
  let current: QuestionTarget | null = null;
  let unavailable = false;
  if (question.status !== "pending") reasons.push(`question is ${question.status}`);
  try {
    text(target.worktree, "worktree");
    current = captureTarget({
      kind: question.kind,
      repo: target.worktree,
      issue: target.issue,
      topic: target.topic,
      desk: target.desk,
      base: target.baseRef,
      action: target.action,
    });
    for (const key of Object.keys(target) as (keyof QuestionTarget)[]) {
      if (target[key] !== current[key]) reasons.push(`${key} changed`);
    }
  } catch (error) {
    unavailable = true;
    reasons.push(`target unavailable: ${(error as Error).message}`);
  }
  let policy: { status: "checked"; current: unknown } | { status: "unavailable"; reason: string };
  try {
    text(target.worktree, "worktree");
    const value = JSON.parse(
      run(process.env.BERCAIL_SHEP_BIN || "bercail", ["policy", "show", "--json", target.worktree], target.worktree),
    );
    if (
      !value ||
      typeof value.policy !== "object" ||
      value.policy === null ||
      Array.isArray(value.policy) ||
      typeof value.root !== "string" ||
      realpathSync(value.root) !== target.worktree ||
      typeof value.repo !== "string" ||
      identity(value.repo) !== target.repo
    )
      fail("policy does not describe the target repo/worktree");
    policy = { status: "checked", current: value };
  } catch (error) {
    unavailable = true;
    policy = { status: "unavailable", reason: (error as Error).message };
    reasons.push("policy unavailable; not checked");
  }
  return {
    token: `${question.id}@${question.revision}`,
    fresh: reasons.length === 0,
    status: unavailable ? "unavailable" : reasons.length ? "stale" : "fresh",
    authority: false as const,
    reasons,
    current,
    policy,
  };
}
