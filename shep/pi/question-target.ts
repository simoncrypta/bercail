import { execFileSync } from "node:child_process";
import { readFileSync, realpathSync } from "node:fs";
import { join } from "node:path";
import type { Question, QuestionPush, QuestionTarget } from "./questions.ts";

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
// The checked-out branch as its full ref (a short name can be ambiguous), or null
// when HEAD is detached.
function branch(cwd: string): string | null {
  try {
    return git(cwd, "symbolic-ref", "-q", "HEAD");
  } catch {
    return null;
  }
}
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

// The named desk's space and session, or why it cannot be bound. A desk problem is a
// warning on the card, never a refusal: the question binds to the repo and issue.
function deskFacts(desk: string, issue: string | null, worktree: string): { space: string; session: string } | string {
  const state = process.env.XDG_STATE_HOME || join(process.env.HOME!, ".local/state");
  let record;
  try {
    record = JSON.parse(readFileSync(join(state, "bercail/desk-sessions", `${desk}.json`), "utf8"));
  } catch {}
  if (!record || typeof record !== "object") return `desk ${desk} has no desk session record`;
  let live;
  try {
    live = JSON.parse(run("hc", ["get", desk, "--json"], worktree));
  } catch {}
  if (!live || typeof live !== "object") return `desk ${desk} is gone`;
  if (record.address !== desk || live.address !== desk || live.state !== "live" || live.reason != null)
    return `desk ${desk} is gone or not live at its recorded address`;
  const same = (path: unknown) => {
    try {
      return realpathSync(path as string) === worktree;
    } catch {
      return false;
    }
  };
  if (!same(record.cwd) || !same(live.foreground?.cwd || live.cwd)) return `desk ${desk} is not in the target worktree`;
  if (
    live.labels?.["bercail.role"] !== "agent" ||
    (record.issue || null) !== issue ||
    (live.labels?.["bercail.issue"] || null) !== issue
  )
    return `desk ${desk} belongs to another job`;
  if (typeof record.space !== "string" || !record.space || record.space !== live.labels?.["bercail.space"])
    return `desk ${desk}'s space does not match its session record`;
  const recorded =
    typeof record.session === "string" &&
    Object.hasOwn(live.records ?? {}, record.session) &&
    live.records[record.session]?.app === "pi";
  if (record.harness !== "pi" || !record.session || (!recorded && !claimsSession(record, live)))
    return `desk ${desk}'s Pi session could not be verified`;
  return { space: record.space, session: record.session };
}

// The trail `trail:<n>` names in the checkout's Entire project, as `bercail job id` reads
// it (lib/jobs.ts, bercail's one trail reader): its ID, which an answer holds to (another
// project's trail N is another job), and its URL, for the card's link. A trail the project
// does not have refuses, as an issue from another repo does.
function trailFacts(id: string, worktree: string): { trailId: string; url: string } {
  let shown;
  try {
    shown = JSON.parse(run(process.env.BERCAIL_SHEP_BIN || "bercail", ["job", "id", id, "--repo", worktree], worktree));
  } catch (error) {
    fail(`bercail job id ${id}: ${((error as { stderr?: string }).stderr || (error as Error).message).trim()}`);
  }
  if (
    shown?.id !== id ||
    typeof shown.trail_id !== "string" ||
    !shown.trail_id ||
    typeof shown.url !== "string" ||
    !shown.url.startsWith("https://")
  )
    fail(`${id} does not match the repo's Entire trail`);
  return { trailId: shown.trail_id, url: shown.url };
}

// The target and its desk warnings.
function inspectTarget(input: TargetInput): { target: QuestionTarget; warnings: string[] } {
  if (!["planning", "review", "action"].includes(input.kind)) fail("invalid kind");
  text(input.repo, "repo");
  text(input.topic, "topic");
  for (const field of ["issue", "desk", "base", "action"] as const) nullable(input[field], field);
  if (input.kind !== "planning") {
    text(input.issue, "issue");
    text(input.base, "base");
    text(input.action, "action");
  }
  const worktree = realpathSync(git(realpathSync(input.repo), "rev-parse", "--show-toplevel"));
  const repo = identity(worktree);
  let trail: { trailId: string; url: string } | null = null;
  if (input.issue !== null) {
    if (input.issue.startsWith("-")) fail("invalid issue id");
    if (input.issue.startsWith("trail:")) trail = trailFacts(input.issue, worktree);
    else {
      const jobs = JSON.parse(run("bd", ["show", input.issue, "--json"], worktree));
      if (!Array.isArray(jobs) || jobs.length !== 1 || jobs[0]?.id !== input.issue)
        fail("issue does not match the repo's beads job");
    }
  }
  const warnings: string[] = [];
  let facts: { space: string; session: string } | null = null;
  if (input.desk !== null) {
    if (!/^[a-zA-Z0-9_-]+$/.test(input.desk)) fail("desk must be an explicit terminal address");
    const found = deskFacts(input.desk, input.issue, worktree);
    if (typeof found === "string") warnings.push(found);
    else facts = found;
  } else if (input.kind !== "planning" || input.issue !== null)
    warnings.push("no desk: bound to the repo and issue only");
  const target: QuestionTarget = {
    repo,
    issue: input.issue,
    topic: input.topic,
    worktree,
    desk: input.desk,
    // Only a desk that checks out lends its space and session (Discuss branches it).
    space: facts?.space ?? null,
    session: facts?.session ?? null,
    // A planning question is about the plan, not a commit: new commits leave it fresh.
    branch: input.kind === "planning" ? null : branch(worktree),
    head: input.kind === "planning" ? null : commit(worktree, "HEAD"),
    stagedTree: input.kind === "planning" ? null : git(worktree, "write-tree"),
    baseRef: input.base,
    base: input.base === null ? null : commit(worktree, input.base),
    action: input.action,
    ...trail,
  };
  return { target, warnings };
}

export const captureTarget = (input: TargetInput): QuestionTarget => inspectTarget(input).target;

// What an answer holds to: the job, the staged tree, the base and HEAD as below. Not
// the desk, whose problems are warnings, nor the trail's link.
const UNBOUND = new Set<keyof QuestionTarget>(["space", "session", "url"]);

// The approved tree was committed: `now` is one commit, with `old` its only parent and
// the approved tree its tree. Anything more (other commits, a merge, an amend) is new work.
// It reads the commit object's own headers, which replace refs and grafts cannot fake.
function committedOnce(cwd: string, old: string, now: string, tree: string | null): boolean {
  try {
    const head = git(cwd, "--no-replace-objects", "cat-file", "commit", now).split("\n\n")[0]!;
    const parents = [...head.matchAll(/^parent (\S+)$/gm)].map((m) => m[1]);
    return parents.length === 1 && parents[0] === old && /^tree (\S+)$/m.exec(head)?.[1] === tree;
  } catch {
    return false;
  }
}

// The repo a folder belongs to, as a question's target names it.
export const repoOf = (dir: string): string => identity(realpathSync(dir));

// The commits an answer approves a push of: the answered HEAD, and the live HEAD a
// fresh check saw when it is the one commit of the reviewed tree on it.
export function approvedCommits(question: Question, head: string | null): string[] {
  const { answer, target } = question;
  if (!answer?.head || !target.worktree) return [];
  const committed =
    head && head !== answer.head && committedOnce(target.worktree, answer.head, head, answer.stagedTree);
  return committed ? [answer.head, head] : [answer.head];
}

// The commit an object a push names peels to, read in dir without replace refs; a tag
// must be a tag object. Null when it is not that kind of object.
export function peeled(dir: string, oid: string, kind: "commit" | "tag"): string | null {
  try {
    if (git(dir, "--no-replace-objects", "rev-parse", "--verify", "--end-of-options", `${oid}^{${kind}}`) !== oid)
      return null;
    return git(dir, "--no-replace-objects", "rev-parse", "--verify", "--end-of-options", `${oid}^{commit}`);
  } catch {
    return null;
  }
}

// The push URLs a card can show: an absolute path, ssh with no password, or http(s) or
// git:// with no user. None holds a query, a fragment, a space or a control character.
const showable = [
  /^\/[^\s?#]*$/,
  /^file:\/\/\/[^\s?#]*$/,
  /^[\w.-]+@[\w.-]+:[^\s?#]*$/,
  /^(ssh|git\+ssh|ssh\+git):\/\/([\w.-]+@)?[\w.-]+(:\d+)?\/[^\s?#]*$/,
  /^(https?|git):\/\/[\w.-]+(:\d+)?\/[^\s?#@]*$/,
];

// A remote's one push URL, as git push uses it (insteadOf and pushInsteadOf applied).
// A remote group, several push URLs, or one the card cannot show (it may hold a
// credential) refuses; the message never holds the URL.
export function pushUrl(dir: string, remote: string): string {
  if (!/^[A-Za-z0-9][\w.-]*$/.test(remote)) fail("push.remote must be the remote's name");
  let urls: string[];
  try {
    urls = git(dir, "remote", "get-url", "--push", "--all", "--", remote).split("\n").filter(Boolean);
  } catch {
    fail(`${remote} is not a remote of ${dir}`);
  }
  if (urls!.length !== 1) fail(`${remote} must push to one URL, not ${urls!.length}`);
  const url = urls![0]!;
  // eslint-disable-next-line no-control-regex
  if (/[\u0000-\u001f\u007f-\u009f]/.test(url) || !showable.some((shape) => shape.test(url)))
    fail(`${remote}'s push URL is not one the card can show: a path, ssh, or https with no credential or query`);
  return url;
}

// A question's target, and its push as Shep gave it with the URL its remote pushes to
// now. The store checks the rest.
export function withTarget(
  target: QuestionTarget,
  push: Omit<QuestionPush, "url"> | null | undefined,
): { target: QuestionTarget; push?: QuestionPush } {
  if (push == null) return { target };
  const worktree = target.worktree;
  if (typeof push !== "object" || !worktree) return fail("push needs an object and the target's worktree");
  return {
    target,
    push: { approves: push.approves, remote: push.remote, refs: push.refs, url: pushUrl(worktree, push.remote) },
  };
}

// Why a push from dir to remote could send more, or elsewhere, than the card said: its
// URL changed, config adds tags or other repos' pushes, or config could not be read.
// Null when it cannot.
export function pushConfigProblem(dir: string, remote: string, url: string): string | null {
  // git config exits 1 for a key that is not set; anything else is a read that failed.
  const config = (key: string, bool: boolean) => {
    try {
      return git(dir, "config", ...(bool ? ["--type=bool"] : []), "--get", key);
    } catch (error) {
      if ((error as { status?: number }).status === 1) return "";
      throw new Error(`could not read ${key}`, { cause: error });
    }
  };
  try {
    if (pushUrl(dir, remote) !== url) return `${remote} no longer pushes to the URL the card showed`;
    if (config("push.followTags", true) === "true") return "push.followTags would push tags too";
    if (!["", "no", "check"].includes(config("push.recurseSubmodules", false)))
      return "push.recurseSubmodules would push submodules too";
    if (config("submodule.recurse", true) === "true") return "submodule.recurse would push submodules too";
  } catch (error) {
    return (error as Error).message;
  }
  return null;
}

// [policy] merge_reversible for the target's checkout, as bercail policy show reads it:
// unset, untrusted, or unreadable is false.
export function mergeReversible(target: QuestionTarget): boolean {
  if (!target.worktree) return false;
  try {
    const shown = JSON.parse(
      run(process.env.BERCAIL_SHEP_BIN || "bercail", ["policy", "show", "--json", target.worktree], target.worktree),
    );
    return shown?.policy?.merge_reversible === true;
  } catch {
    return false;
  }
}

// A guard card: fresh while it is pending, not expired, and the operation pins to the
// same facts now (bercail guard check, the guard's own pinning). No repo policy applies.
function checkGuard(question: Question) {
  const guard = question.guard!;
  const reasons: string[] = [];
  let unavailable = false;
  if (question.status === "superseded" || question.status === "withdrawn")
    reasons.push(`question is ${question.status}`);
  else if (question.status === "pending") {
    if (Date.parse(guard.expires) <= Date.now()) reasons.push(`expired at ${guard.expires}`);
    else
      try {
        const shown = JSON.parse(
          execFileSync(process.env.BERCAIL_SHEP_BIN || "bercail", ["guard", "check"], {
            input: JSON.stringify({ op: guard.op, facts: guard.facts }),
            encoding: "utf8",
            timeout: 60000,
            stdio: ["pipe", "pipe", "pipe"],
          }),
        );
        if (!Array.isArray(shown?.reasons) || !shown.reasons.every((r: unknown) => typeof r === "string"))
          fail("bercail guard check printed no reasons");
        reasons.push(...shown.reasons);
      } catch (error) {
        unavailable = true;
        reasons.push(`target unavailable: ${(error as Error).message.split("\n")[0]}`);
      }
  }
  return {
    token: `${question.id}@${question.revision}`,
    fresh: reasons.length === 0,
    status: unavailable ? "unavailable" : reasons.length ? "stale" : "fresh",
    authority: false as const,
    reasons,
    warnings: [] as string[],
    current: question.target,
    policy: { status: "unavailable" as const, reason: "a guard card follows the guard, not a repo policy" },
  };
}

export async function checkQuestion(question: Question) {
  if (question.kind === "guard") return checkGuard(question);
  const target = question.target;
  const reasons: string[] = [];
  let current: QuestionTarget | null = null;
  let warnings: string[] = [];
  let unavailable = false;
  // An answer is acted on after it: only a revision that no longer applies is stale.
  if (question.status === "superseded" || question.status === "withdrawn")
    reasons.push(`question is ${question.status}`);
  try {
    text(target.worktree, "worktree");
    ({ target: current, warnings } = inspectTarget({
      kind: question.kind,
      repo: target.worktree,
      issue: target.issue,
      topic: target.topic,
      desk: target.desk,
      base: target.baseRef,
      action: target.action,
    }));
    // An approval names the staged tree, not HEAD: committing that tree on the asked
    // HEAD and branch keeps it, and so moves a base named HEAD or that branch. A
    // question asked before branches were kept gets no such pass.
    const { branch } = target;
    const committed =
      typeof branch === "string" &&
      branch === current.branch &&
      target.head !== current.head &&
      committedOnce(target.worktree, target.head!, current.head!, target.stagedTree);
    const followsHead =
      typeof branch === "string" &&
      ["HEAD", branch, branch.replace(/^refs\/heads\//, "")].includes(target.baseRef!) &&
      target.base === target.head &&
      current.base === current.head;
    for (const key of Object.keys(target) as (keyof QuestionTarget)[]) {
      if (UNBOUND.has(key) || target[key] === current[key]) continue;
      if (key === "head" && committed) continue;
      if (key === "base" && committed && followsHead) continue;
      reasons.push(`${key} changed`);
    }
    // Never rebound: a desk now on another session is said, and Discuss keeps the asked one.
    if (target.session && current.session && current.session !== target.session)
      warnings.push(`desk ${target.desk} runs another session than when Shep asked`);
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
    warnings,
    current,
    policy,
  };
}
