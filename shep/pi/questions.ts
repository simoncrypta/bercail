import { spawnSync } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import {
  closeSync,
  fsyncSync,
  linkSync,
  mkdirSync,
  openSync,
  readFileSync,
  renameSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { isAbsolute, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";
export interface QuestionTarget {
  repo: string;
  issue: string | null;
  topic: string;
  worktree: string | null;
  desk: string | null;
  space: string | null;
  session: string | null;
  action: string | null;
  /** The checked-out branch's full ref, null when detached; absent in questions asked before it was kept. */
  branch?: string | null;
  /** When the issue is `trail:<n>`: the trail's Entire ID, and its page for the card. Absent otherwise. */
  trailId?: string;
  url?: string;
  head: string | null;
  stagedTree: string | null;
  base: string | null;
  baseRef: string | null;
}
export interface QuestionOrigin {
  event: string;
  session: string;
  entry: string | null;
}
export interface QuestionSpec {
  kind: "planning" | "review" | "action" | "guard" | "land";
  prompt: string;
  options: string[];
  origin: QuestionOrigin;
  target: QuestionTarget;
  /** What is decided and why now, in Shep's words, for the card. */
  brief?: string;
  /** Shep's pick among options, with one line of why. */
  recommendation?: { choice: string; why: string };
  /** Shep's: the choice can be undone, so the recommendation is taken at the deadline. */
  reversible?: true;
  /** Shep's: picking `approves` lets Shep push the answered commit to `remote`'s `refs`, once, with no second ask. */
  push?: QuestionPush;
  /** A guard card's: the operation its worker runs on the person's Allow. */
  guard?: QuestionGuard;
  /** A land card's facts beyond its target, pinned when it was asked. */
  land?: QuestionLand;
}
/** What a land card pins beside its target, whose baseRef is the trunk and base the
 * trunk's commit on the remote. Read again at the pick and before each effect. */
export interface QuestionLand {
  /** origin's one push URL, and the GitHub repo it names. */
  url: string;
  github: string;
  /** The new branch the chain pushes its commit to for CI, one per card: a retry after a
   * stop never rewrites an earlier card's. Not on the remote when it was asked. */
  ciRef: string;
  /** The sha256 of the staged .bercail/policy.toml when the change edits it: the pick trusts
   * exactly that file once its commit is on the trunk. Null when the policy is untouched. */
  policyTrust: string | null;
  /** The worktree is one git lists, and nothing is unstaged, untracked or hidden from status
   * beside the staged tree: true when it was asked. */
  registered: boolean;
  clean: boolean;
  /** The branch the job's handoff record names: the worktree's, when it was asked. */
  handoffBranch: string;
  /** The description's tree, and the sha256 of the commit text it gives. */
  description: { tree: string; message: string };
  /** The policy as bercail policy show read it: its file's sha256, its trust, and the sha256 of its values. */
  policy: { file: string; trusted: boolean; hash: string };
  /** Each required_ci workflow and its GitHub database ID. */
  requiredCi: { path: string; id: number }[];
  /** The installed bercail the worker runs, by its real path. */
  bercail: string;
  /** Whether the person's LGTM is needed, and the high-stakes paths the change touches. */
  review: { required: boolean; highStakes: string[] };
  /** The person's global user.name for Reviewed-by, when review is required. */
  reviewer: string | null;
}
/** A land card's choices: no recommendation, no default, and the first lands it. */
export const LAND_CHOICES = ["Ship it", "Not yet"];
export const LGTM_LAND_CHOICES = ["LGTM, ship it", "Not yet"];
/** The chain's steps, in order: the facts checked again, then each effect. The job closes
 * last, once its desk is retired and the main checkout synced. */
export const LAND_STEPS = ["check", "commit", "push", "ci", "trunk", "cleanup", "sync", "close"] as const;
export const LAND_OUTCOMES = [
  "changed",
  "refused",
  "ci-failed",
  "ci-timeout",
  "behind",
  "push-failed",
  "unknown",
  "landed",
] as const;
/** A land card's chain after the pick: who started it, the one claim, each step as it starts, one result. */
export interface Landing {
  /** One per attempt to start its worker: the hc terminal, and when. */
  starts: { terminal: string; at: string }[];
  claim?: { at: string };
  steps: { step: (typeof LAND_STEPS)[number]; at: string; detail?: string }[];
  result?: LandResult;
}
export interface LandResult {
  outcome: (typeof LAND_OUTCOMES)[number];
  /** The last step the ledger has, or null when the chain recorded none. */
  step: (typeof LAND_STEPS)[number] | null;
  commit: string | null;
  /** Why it stopped, in the worker's words from facts: absent when it landed. */
  why?: string;
  /** The policy file's sha256 the chain trusted once its commit was on the trunk. */
  trusted?: string;
  warnings: string[];
  log: string;
  at: string;
  /** Its land event is written, so it is never written again. */
  told?: true;
}
/** An ask the guard handed off from Shep's session: its worker runs `op` on `facts`, once. */
export interface QuestionGuard {
  /** The ticket under the state dir's guard-asks/, and the hc terminal that runs it. */
  ticket: string;
  worker: string;
  /** What Shep's command asked, and what it acts on, as the guard pinned them. */
  op: Record<string, unknown>;
  facts: Record<string, unknown>;
  /** Past it, a pick is refused: the card counts as a Deny, or as an Allow when it defaults. */
  expires: string;
  /** The worker found what it runs private or local (guard.ts guardDefault), and the card says
   * so: nobody answering by `expires` counts as an Allow, if it still reads `why` then. Absent
   * on a card that waits for the person, and on cards asked before it was kept. */
  defaults?: { why: string };
}
/** How long before its deadline a guard card must have gone up to default: most of its hour. */
const GUARD_WINDOW = 50 * 60000;
/** How long after its deadline a guard card may still default: its worker acts within minutes. */
const GUARD_LATE = 10 * 60000;
/** A guard card's only choices: no recommendation, and Deny is the safe one. */
export const GUARD_CHOICES = ["Allow", "Deny"];
export interface QuestionPush {
  approves: string;
  remote: string;
  /** Full refs: refs/heads/<branch>, or refs/tags/<tag> on a release question. */
  refs: string[];
  /** The remote's one push URL when Shep asked, as git uses it; never one with credentials. */
  url: string;
}
/** The one push an answer approved: the guard claimed it, so no other push can. */
export interface PushClaim {
  at: string;
  remote: string;
  /** <commit hash>:<full ref>, as the push sent them. */
  refspecs: string[];
}
/** Who recorded an answer: the person's pick on a card or in a Discuss branch. */
export const ANSWER_SOURCES = ["panel picker", "discuss picker"] as const;
/** The only answers that approve a push: an agent can type into a Discuss terminal (hc send), not click the panel. */
export const PUSH_SOURCE: (typeof ANSWER_SOURCES)[number] = "panel picker";
/** The ledger's own answer: no pick by the deadline, so Shep's recommendation. Never the person's. */
export const DEFAULT_SOURCE = "default after timeout";
/** A guard card's own default: nobody answered by its deadline, and what it runs still read
 * private or local. Its worker's to act on (guard-ask.ts matches these words); never the
 * person's, and it takes no OK or Reverse. */
export const GUARD_DEFAULT_SOURCE = "guard default at expiry";
export interface QuestionAnswer {
  requestId: string;
  choice: string;
  source: (typeof ANSWER_SOURCES)[number] | typeof DEFAULT_SOURCE | typeof GUARD_DEFAULT_SOURCE;
  at: string;
  /** The candidate the live check saw when the person picked. */
  head: string | null;
  stagedTree: string | null;
}
/** The person's word on a default, once. OK keeps it as their pick, with the full weight of
 * one; Reverse rejects it, for another of the choices or none. */
export interface QuestionSettlement {
  requestId: string;
  outcome: "ok" | "reversed";
  /** OK: the default's choice. Reversed: another of the choices, or null for none. */
  choice: string | null;
  source: (typeof ANSWER_SOURCES)[number];
  at: string;
  /** The candidate the live check saw when the person said it. */
  head: string | null;
  stagedTree: string | null;
  /** Its decision event is written, so it is never written again. */
  told?: true;
}
/** Shep's: the question no longer applies. Not an answer. With a source, the person's
 * Close on the panel, which Shep is told of. */
export interface QuestionWithdrawal {
  requestId: string;
  reason: string;
  at: string;
  source?: "panel picker";
  /** A Close's decision event is written, so it is never written again. */
  told?: true;
}
/** Why the person's Close withdrew a card. */
export const CLOSE_REASON = "closed by the person on the panel";
export interface AnswerResult {
  question: Question;
  accepted: boolean;
  reason?: string;
}
export interface Question extends QuestionSpec {
  id: string;
  revision: number;
  status: "pending" | "answered" | "superseded" | "withdrawn";
  createdAt: string;
  /** A reversible question with a recommendation: when it takes the recommendation. */
  deadline?: string;
  /** Its default's decision event is written, so it is never written again. */
  told?: true;
  proposals: {
    requestId: string;
    answer: string;
    source: string;
    at: string;
    verified: false;
    accepted: boolean;
    reason?: string;
  }[];
  /** Present once answered, and only then. */
  answer?: QuestionAnswer;
  /** The person's OK or Reverse on a default; present only on one. */
  settled?: QuestionSettlement;
  /** Present once withdrawn, and only then. */
  withdrawal?: QuestionWithdrawal;
  /** Present once the answer's push was claimed, and only then. */
  pushed?: PushClaim;
  /** Present once a guard card's worker claimed its Allow, and only then. */
  guardClaim?: { at: string };
  /** A land card's chain, present from its first start reservation. */
  landing?: Landing;
}
export interface QuestionSnapshot {
  version: 1;
  questions: Question[];
  selected: string | null;
}
export interface ProposalResult {
  question: Question;
  duplicate: boolean;
  accepted: boolean;
  reason?: string;
}
type Receipt = { requestId: string; payload: string; result: Question | ProposalResult | AnswerResult };
const STATUSES = ["pending", "answered", "superseded", "withdrawn"];
type State = QuestionSnapshot & { requests: Receipt[] };

// Why a check failed, and where: a field's path in a spec, or in the ledger the record
// and its path.
class Invalid extends Error {
  readonly why: string;
  readonly where: string;
  constructor(why: string, where = "") {
    super(`Question store: ${where ? `${where}: ` : ""}${why}`);
    this.why = why;
    this.where = where;
  }
}
function fail(why: string, where = ""): never {
  throw new Invalid(why, where);
}
const field = (at: string, key: string) => (at ? `${at}.${key}` : key);
function text(value: unknown, at = ""): asserts value is string {
  if (typeof value !== "string" || !value.trim()) fail("expected nonempty text", at);
}
function shape(value: unknown, keys: string[], at = ""): asserts value is Record<string, unknown> {
  if (!object(value)) fail("not an object", at);
  const extra = Object.keys(value as object).find((key) => !keys.includes(key));
  if (extra !== undefined) fail("unexpected field", field(at, extra));
  const missing = keys.find((key) => !(key in (value as object)));
  if (missing !== undefined) fail("missing field", field(at, missing));
}
const object = (value: unknown) => value !== null && typeof value === "object" && !Array.isArray(value);
// Keys an older ledger may lack: present with a value, or absent.
const optional = (value: unknown, keys: string[]) =>
  object(value) ? keys.filter((key) => (value as Record<string, unknown>)[key] !== undefined) : [];
function spec(value: unknown): asserts value is QuestionSpec {
  const v = value as Record<string, unknown>;
  shape(value, [
    "kind",
    "prompt",
    "options",
    "origin",
    "target",
    ...optional(v ?? {}, ["brief", "recommendation", "reversible", "push", "guard", "land"]),
  ]);
  if (!["planning", "review", "action", "guard", "land"].includes(value.kind as string)) fail("invalid kind", "kind");
  text(value.prompt, "prompt");
  if (!Array.isArray(value.options)) fail("invalid options", "options");
  value.options.forEach((option, i) => text(option, `options[${i}]`));
  if (value.brief !== undefined) text(value.brief, "brief");
  if (value.recommendation !== undefined) {
    shape(value.recommendation, ["choice", "why"], "recommendation");
    text(value.recommendation.why, "recommendation.why");
    if (!value.options.includes(value.recommendation.choice)) fail("recommendation must be one of the options");
  }
  if (value.reversible !== undefined && value.reversible !== true) fail("reversible is true or absent");
  shape(value.origin, ["event", "session", "entry"], "origin");
  text(value.origin.event, "origin.event");
  text(value.origin.session, "origin.session");
  if (value.origin.entry !== null) text(value.origin.entry, "origin.entry");
  const keys = [
    "repo",
    "issue",
    "topic",
    "worktree",
    "desk",
    "space",
    "session",
    "action",
    "head",
    "stagedTree",
    "base",
    "baseRef",
  ];
  shape(value.target, [...keys, ...optional(value.target, ["branch", "trailId", "url"])], "target");
  if (value.target.branch != null) text(value.target.branch, "target.branch");
  if (value.target.trailId !== undefined) text(value.target.trailId, "target.trailId");
  if (value.target.url !== undefined) text(value.target.url, "target.url");
  // The desk is optional for every kind but land: a question binds to its repo and issue.
  // A guard card binds to its pinned facts instead.
  const desk = ["desk", "space", "session"];
  const loose = value.kind === "planning" || value.kind === "guard";
  for (const key of keys)
    if (
      value.target[key] !== null ||
      (!loose && (!desk.includes(key) || value.kind === "land")) ||
      key === "repo" ||
      key === "topic"
    )
      text(value.target[key], `target.${key}`);
  const repo = value.target.repo as string;
  if (!isAbsolute(repo) || normalize(repo) !== repo)
    fail("repo must be a canonical absolute identity path supplied by the caller");
  if (value.target.worktree !== null && !isAbsolute(value.target.worktree as string)) fail("worktree must be absolute");
  if (value.push !== undefined) push(value as unknown as QuestionSpec);
  if ((value.kind === "guard") !== (value.guard !== undefined)) fail("a guard card, and only it, has its guard");
  if (value.guard !== undefined) located(undefined, "guard", () => guard(value as unknown as QuestionSpec));
  if ((value.kind === "land") !== (value.land !== undefined)) fail("a land card, and only it, has its land facts");
  if (value.land !== undefined) located(undefined, "land", () => land(value as unknown as QuestionSpec));
}
const sha = (value: unknown) => typeof value === "string" && /^[0-9a-f]{40}([0-9a-f]{24})?$/.test(value);
// A land card: the commit's facts pinned whole, its CI gate named, and Ship it or Not yet
// with no recommendation, default or push. The first choice is the LGTM when review is required.
function land(value: QuestionSpec) {
  const l = value.land!;
  const t = value.target;
  shape(l, [
    "url",
    "github",
    "ciRef",
    "policyTrust",
    "registered",
    "clean",
    "handoffBranch",
    "description",
    "policy",
    "requiredCi",
    "bercail",
    "review",
    "reviewer",
  ]);
  for (const key of ["url", "github", "bercail"] as const) text(l[key], key);
  if (typeof l.ciRef !== "string" || !/^refs\/heads\/bercail-land\/[\w./-]+\/[0-9a-f]{12}$/.test(l.ciRef))
    fail("a land card pushes for CI to a new branch of its own, refs/heads/bercail-land/<branch>/<id>");
  if (l.policyTrust !== null && !/^[0-9a-f]{64}$/.test(l.policyTrust as string))
    fail("a land card trusts a policy file by its sha256, or none");
  if (l.registered !== true || l.clean !== true)
    fail("a land card is asked on a linked worktree git lists, with nothing unstaged or untracked");
  shape(l.description, ["tree", "message"], "description");
  shape(l.policy, ["file", "trusted", "hash"], "policy");
  shape(l.review, ["required", "highStakes"], "review");
  text(l.policy.file, "policy.file");
  text(l.policy.hash, "policy.hash");
  if (
    typeof l.policy.trusted !== "boolean" ||
    !sha(l.description.tree) ||
    !/^[0-9a-f]{64}$/.test(l.description.message as string) ||
    !isAbsolute(l.bercail) ||
    typeof l.review.required !== "boolean" ||
    !Array.isArray(l.review.highStakes)
  )
    fail("a land card pins its tree, description, policy, bercail and review");
  l.review.highStakes.forEach((path, i) => text(path, `review.highStakes[${i}]`));
  if (!Array.isArray(l.requiredCi) || !l.requiredCi.length)
    fail("a land card waits for the policy's required_ci: name each workflow and its ID");
  for (const [i, run] of l.requiredCi.entries()) {
    shape(run, ["path", "id"], `requiredCi[${i}]`);
    text(run.path, `requiredCi[${i}].path`);
    if (!Number.isSafeInteger(run.id)) fail("a required_ci workflow needs its GitHub ID", `requiredCi[${i}].id`);
  }
  if (l.review.required) text(l.reviewer, "reviewer");
  else if (l.reviewer !== null) fail("a land card names a reviewer only when review is required");
  if (t.action !== "land" || !sha(t.head) || !sha(t.stagedTree) || !sha(t.base) || !t.branch?.startsWith("refs/heads/"))
    fail("a land card targets a branch's HEAD and staged tree, action land, on the trunk's commit");
  if (typeof l.handoffBranch !== "string" || `refs/heads/${l.handoffBranch}` !== t.branch)
    fail("a land card's branch is the one its job's handoff record names");
  if (t.branch === `refs/heads/${t.baseRef}`) fail("a land card lands a desk's branch, never the trunk itself");
  if (t.head !== t.base)
    fail("a land card's HEAD is the trunk's commit on the remote, so its commit has that one parent");
  const choices = l.review.required ? LGTM_LAND_CHOICES : LAND_CHOICES;
  if (
    value.options.length !== choices.length ||
    value.options.some((option, i) => option !== choices[i]) ||
    value.recommendation ||
    value.reversible ||
    value.push
  )
    fail(`a land card offers ${choices.join(" and ")} only, with no recommendation, default or push`);
}
// A guard card: Allow or Deny, nothing Shep recommends, on one ticket. Its own deadline
// is `expires`, where it counts as a Deny, or as an Allow when it says it defaults.
function guard(value: QuestionSpec) {
  const g = value.guard;
  shape(g, [
    "ticket",
    "worker",
    "op",
    "facts",
    "expires",
    ...optional((g ?? {}) as Record<string, unknown>, ["defaults"]),
  ]);
  if (g.defaults !== undefined) {
    shape(g.defaults, ["why"], "defaults");
    text(g.defaults.why, "defaults.why");
  }
  if (typeof g.ticket !== "string" || !/^[0-9a-f]{12}$/.test(g.ticket) || g.worker !== `guard-ask-${g.ticket}`)
    fail("a guard card names its ticket and its worker, guard-ask-<ticket>");
  text(g.expires, "expires");
  if (
    !object(g.op) ||
    !["cleanup", "trail merge", "push", "command"].includes((g.op as { kind?: string }).kind as string) ||
    !object(g.facts) ||
    !Number.isFinite(Date.parse(g.expires as string))
  )
    fail("a guard card holds its operation, its pinned facts and when it expires");
  if (value.options.join() !== GUARD_CHOICES.join() || value.recommendation || value.reversible || value.push)
    fail("a guard card offers Allow and Deny only, with no recommendation, default or push");
}
// The guard matches these as they are written in the command (guard.ts hashRefspec).
const refName = /^refs\/(heads|tags)\/[\w./-]+$/;
// A push approval: one of the choices, on a question that binds to a commit, never a
// default, with a tag only on a release question.
function push(value: QuestionSpec) {
  const p = value.push;
  shape(p, ["approves", "remote", "refs", "url"], "push");
  if (!value.options.includes(p.approves as string)) fail("push.approves must be one of the options");
  if (value.kind === "planning") fail("a planning question binds to no commit, so it cannot approve a push");
  if (value.reversible) fail("a push is a one-way door: ask it without reversible");
  text(p.remote, "push.remote");
  if (!/^[A-Za-z0-9][\w.-]*$/.test(p.remote as string)) fail("push.remote must be the remote's name");
  text(p.url, "push.url");
  if (!Array.isArray(p.refs) || !p.refs.length || new Set(p.refs).size !== p.refs.length)
    fail("push.refs must list each ref once");
  for (const ref of p.refs as unknown[])
    if (typeof ref !== "string" || !refName.test(ref))
      fail("push.refs are full refs: refs/heads/<branch> or refs/tags/<tag>");
  if ((p.refs as string[]).some((ref) => ref.startsWith("refs/tags/")) && value.target.action !== "release")
    fail("a tag push needs action release");
}
function question(value: unknown): asserts value is Question {
  const v = value as Record<string, unknown>;
  const keys = ["id", "revision", "status", "createdAt", "proposals", "kind", "prompt", "options", "origin", "target"];
  shape(value, [
    ...keys,
    ...optional(v ?? {}, [
      "brief",
      "recommendation",
      "reversible",
      "push",
      "guard",
      "land",
      "deadline",
      "told",
      "answer",
      "settled",
      "withdrawal",
      "pushed",
      "guardClaim",
      "landing",
    ]),
  ]);
  const {
    id,
    revision,
    status,
    createdAt,
    deadline,
    told,
    proposals,
    answer,
    settled,
    withdrawal,
    pushed,
    guardClaim,
    landing,
    ...fields
  } = value;
  spec(fields);
  if (!goodId(id)) fail("invalid question id", "id");
  if (!goodRevision(revision)) fail("invalid question revision", "revision");
  if (!STATUSES.includes(status as string)) fail("invalid status", "status");
  text(createdAt, "createdAt");
  if (!Number.isFinite(Date.parse(createdAt))) fail("invalid time", "createdAt");
  if (!Array.isArray(proposals)) fail("not a list", "proposals");
  if (deadline !== undefined) {
    text(deadline, "deadline");
    if (!fields.reversible || !fields.recommendation || !(Date.parse(deadline) > Date.parse(createdAt)))
      fail("only a reversible question with a recommendation has a deadline, after it was asked");
  }
  if (told !== undefined && (told !== true || (answer as QuestionAnswer | undefined)?.source !== DEFAULT_SOURCE))
    fail("only a default is told");
  for (const [i, p] of proposals.entries()) {
    const at = `proposals[${i}]`;
    shape(p, ["requestId", "answer", "source", "at", "verified", "accepted", ...optional(p, ["reason"])], at);
    for (const key of ["requestId", "answer", "source", "at"]) text(p[key], `${at}.${key}`);
    if (p.verified !== false || typeof p.accepted !== "boolean" || !Number.isFinite(Date.parse(p.at as string)))
      fail("invalid unverified proposal", at);
    if (!p.accepted) text(p.reason, `${at}.reason`);
  }
  // A default Shep withdrew (moot, or its reversal handled) keeps its record.
  const kept =
    status === "withdrawn" &&
    (answer as QuestionAnswer | undefined)?.source === DEFAULT_SOURCE &&
    (settled as QuestionSettlement | undefined)?.outcome !== "ok";
  if (status === "answered" ? answer === undefined : answer !== undefined && !kept)
    fail("an answered question needs its answer, and only it");
  if (answer !== undefined) {
    shape(answer, ["requestId", "choice", "source", "at", "head", "stagedTree"], "answer");
    text(answer.requestId, "answer.requestId");
    text(answer.at, "answer.at");
    if (!fields.options.includes(answer.choice as string)) fail("answer is not one of the options");
    if (answer.source === DEFAULT_SOURCE) {
      if (
        deadline === undefined ||
        answer.choice !== fields.recommendation?.choice ||
        Date.parse(answer.at as string) < Date.parse(deadline as string)
      )
        fail("a default is the recommendation, taken at or after the deadline");
    } else if (answer.source === GUARD_DEFAULT_SOURCE) {
      const g = fields.guard;
      if (!g?.defaults || answer.choice !== "Allow" || !(Date.parse(answer.at as string) >= Date.parse(g.expires)))
        fail("a guard default is an Allow on a card that said it defaults, taken at or after its deadline");
    } else if (!ANSWER_SOURCES.includes(answer.source as (typeof ANSWER_SOURCES)[number]))
      fail("unknown answer source");
    for (const key of ["head", "stagedTree"]) if (answer[key] !== null) text(answer[key], `answer.${key}`);
    if (!Number.isFinite(Date.parse(answer.at as string))) fail("invalid answer time");
  }
  if (settled !== undefined) {
    const a = answer as QuestionAnswer | undefined;
    if (a?.source !== DEFAULT_SOURCE) fail("only a default is settled");
    shape(
      settled,
      ["requestId", "outcome", "choice", "source", "at", "head", "stagedTree", ...optional(settled, ["told"])],
      "settled",
    );
    text(settled.requestId, "settled.requestId");
    if (settled.told !== undefined && settled.told !== true) fail("told is true or absent");
    if (
      settled.outcome === "ok"
        ? settled.choice !== a.choice
        : settled.outcome !== "reversed" ||
          (settled.choice !== null &&
            (settled.choice === a.choice || !fields.options.includes(settled.choice as string)))
    )
      fail("an OK keeps the default's choice; a Reverse names another choice or none");
    if (!ANSWER_SOURCES.includes(settled.source as (typeof ANSWER_SOURCES)[number])) fail("unknown answer source");
    for (const key of ["head", "stagedTree"]) if (settled[key] !== null) text(settled[key], `settled.${key}`);
    if (!(Date.parse(settled.at as string) >= Date.parse(a.at))) fail("invalid settlement time");
  }
  if ((status === "withdrawn") !== (withdrawal !== undefined))
    fail("a withdrawn question needs its withdrawal, and only it");
  if (withdrawal !== undefined) {
    shape(withdrawal, ["requestId", "reason", "at", ...optional(withdrawal, ["source", "told"])], "withdrawal");
    text(withdrawal.requestId, "withdrawal.requestId");
    text(withdrawal.reason, "withdrawal.reason");
    if (withdrawal.source !== undefined && withdrawal.source !== PUSH_SOURCE) fail("only the panel closes a card");
    if (withdrawal.told !== undefined && (withdrawal.told !== true || withdrawal.source === undefined))
      fail("told is true, and only on the person's Close");
    if (!Number.isFinite(Date.parse(withdrawal.at as string))) fail("invalid withdrawal time");
  }
  if (pushed !== undefined) {
    const a = answer as QuestionAnswer | undefined;
    if (!fields.push || !a || a.choice !== fields.push.approves)
      fail("only the person's approving answer is claimed by a push");
    shape(pushed, ["at", "remote", "refspecs"], "pushed");
    const refs = Array.isArray(pushed.refspecs) ? pushed.refspecs.map((spec) => String(spec).split(":")[1]) : [];
    if (
      !Number.isFinite(Date.parse(pushed.at as string)) ||
      pushed.remote !== fields.push.remote ||
      canonical(refs.sort()) !== canonical([...fields.push.refs].sort())
    )
      fail("a push claim names the approved remote and refs");
  }
  if (guardClaim !== undefined) {
    const a = answer as QuestionAnswer | undefined;
    if (
      fields.kind !== "guard" ||
      a?.choice !== "Allow" ||
      (a.source !== PUSH_SOURCE && a.source !== GUARD_DEFAULT_SOURCE)
    )
      fail("only the person's Allow on a guard card, or its default, is claimed by its worker");
    shape(guardClaim, ["at"], "guardClaim");
    if (!Number.isFinite(Date.parse(guardClaim.at as string))) fail("invalid guard claim time");
  }
  if (fields.kind === "land" && answer !== undefined && answer.source !== PUSH_SOURCE)
    fail("a land card is answered on the panel only");
  if (landing !== undefined) {
    if (!shipped(value as unknown as Question))
      fail("only the person's Ship it on a land card's panel starts its chain");
    located(undefined, "landing", () => landed(value as unknown as Question));
  }
}
const goodId = (id: unknown): id is string =>
  typeof id === "string" && /^Q[1-9]\d*$/.test(id) && Number.isSafeInteger(Number(id.slice(1)));
const goodRevision = (revision: unknown) => Number.isSafeInteger(revision) && (revision as number) >= 1;
const when = (at: unknown) => typeof at === "string" && Number.isFinite(Date.parse(at));
// The worker's terminal for a land card's revision: hc names are lowercase.
export const landTerminal = (q: Pick<Question, "id" | "revision">) => `land-${q.id.toLowerCase()}-${q.revision}`;
// The person's positive pick on a land card's panel: the only answer its chain acts on.
export const shipped = (q: Question) =>
  q.kind === "land" && q.status === "answered" && q.answer?.choice === q.options[0] && q.answer.source === PUSH_SOURCE;
// Why the chain cannot go from its last step to `step`, or undefined: it starts with the
// check, then stays on a step (a new detail) or moves to the next.
function advance(last: (typeof LAND_STEPS)[number] | undefined, step: (typeof LAND_STEPS)[number]) {
  const from = last === undefined ? -1 : LAND_STEPS.indexOf(last);
  const to = LAND_STEPS.indexOf(step);
  if (to === -1) return "unknown land step";
  if (to !== from && to !== from + 1) return `${step} cannot follow ${last ?? "the claim"}`;
}
// Landed means the trunk push ran: a chain stopped before it ended otherwise.
const pastTrunk = (step: (typeof LAND_STEPS)[number] | null) =>
  step !== null && LAND_STEPS.indexOf(step) >= LAND_STEPS.indexOf("trunk");
// A land card's chain: starts on its own terminal, then a claim before any step or result,
// steps one after another, and a result that names the last step and, when landed, the
// commit, after the trunk push.
function landed(q: Question) {
  const l = q.landing!;
  shape(l, ["starts", "steps", ...optional(l as unknown as Record<string, unknown>, ["claim", "result"])]);
  if (!Array.isArray(l.starts) || !Array.isArray(l.steps)) fail("invalid land chain");
  for (const [i, start] of l.starts.entries()) {
    shape(start, ["terminal", "at"], `starts[${i}]`);
    if (start.terminal !== landTerminal(q) || !when(start.at)) fail("a land start names the card's terminal and when");
  }
  if (l.claim !== undefined) {
    shape(l.claim, ["at"], "claim");
    if (!when(l.claim.at)) fail("invalid land claim time");
  }
  if (!l.claim && (l.steps.length || l.result)) fail("a land chain is claimed before any step or result");
  l.steps.forEach((s, i) => {
    shape(s, ["step", "at", ...optional(s, ["detail"])], `steps[${i}]`);
    if (advance(l.steps[i - 1]?.step, s.step) || !when(s.at)) fail("land steps are known steps, one after another");
    if (s.detail !== undefined) text(s.detail, `steps[${i}].detail`);
  });
  const r = l.result;
  if (r === undefined) return;
  shape(
    r,
    ["outcome", "step", "commit", "warnings", "log", "at", ...optional(r, ["told", "why", "trusted"])],
    "result",
  );
  text(r.log, "result.log");
  if (r.why !== undefined) text(r.why, "result.why");
  if (r.trusted !== undefined && (r.outcome !== "landed" || r.trusted !== q.land!.policyTrust))
    fail("a land result trusts only the card's policy file, once it landed");
  if (
    !LAND_OUTCOMES.includes(r.outcome) ||
    r.step !== (l.steps.at(-1)?.step ?? null) ||
    (r.commit !== null && !sha(r.commit)) ||
    (r.outcome === "landed" && (r.commit === null || !pastTrunk(r.step))) ||
    !Array.isArray(r.warnings) ||
    !when(r.at) ||
    (r.told !== undefined && r.told !== true)
  )
    fail("a land result is a known outcome at the last step, landed only past the trunk push with its commit");
  r.warnings.forEach((warning, i) => text(warning, `result.warnings[${i}]`));
}
// Runs one record's check: a failure names the record, once it has a name, and the field's
// path from the ledger's top.
function located(name: string | undefined, at: string, check: () => void) {
  try {
    check();
  } catch (error) {
    if (!(error instanceof Invalid)) throw error;
    const path = error.where ? `${at}.${error.where}` : at;
    fail(error.why, name ? `${name} (${path})` : path);
  }
}
const named = (q: unknown) =>
  object(q) && goodId((q as Question).id) && goodRevision((q as Question).revision)
    ? tokenOf(q as Question)
    : undefined;
function validate(value: unknown): asserts value is State {
  shape(value, ["version", "questions", "selected", "requests"]);
  if (value.version !== 1) fail("unknown version", "version");
  if (!Array.isArray(value.questions)) fail("not a list", "questions");
  if (!Array.isArray(value.requests)) fail("not a list", "requests");
  if (value.selected !== null) text(value.selected, "selected");
  const latest = new Map<string, Question>();
  for (const [i, q] of value.questions.entries()) {
    const at = `questions[${i}]`;
    located(named(q), at, () => question(q));
    const previous = latest.get(q.id);
    if (
      q.revision !== (previous?.revision ?? 0) + 1 ||
      (previous && (previous.status !== "superseded" || !sameScope(previous, q)))
    )
      fail("invalid revision history", `${tokenOf(q)} (${at})`);
    latest.set(q.id, q);
  }
  const current = [...latest.values()].find((q) => q.status === "superseded");
  if (current) fail("missing current revision", `${tokenOf(current)} (questions[${value.questions.indexOf(current)}])`);
  const running = value.questions.filter(isRunning);
  for (const [i, q] of running.entries()) {
    const other = running.slice(i + 1).find((o) => overlaps(q, o));
    if (other) fail("two land chains run for the same worktree, branch or job", `${tokenOf(q)} and ${tokenOf(other)}`);
  }
  if (value.selected !== null && !value.questions.some((q) => q.target.topic === value.selected))
    fail("unknown selected topic", "selected");
  const ids = new Set<string>();
  for (const [i, r] of value.requests.entries()) {
    const at = `requests[${i}]`;
    shape(r, ["requestId", "payload", "result"], at);
    text(r.requestId, `${at}.requestId`);
    located(`request ${r.requestId}`, at, () => {
      text(r.payload, "payload");
      if (ids.has(r.requestId as string)) fail("duplicate request id");
      ids.add(r.requestId as string);
      if (object(r.result) && "question" in (r.result as object)) {
        const result = r.result as ProposalResult;
        // An answer receipt has no duplicate flag; a reply receipt has one.
        shape(result, ["question", "accepted", ...optional(result, ["duplicate", "reason"])], "result");
        located(undefined, "result.question", () => question(result.question));
        if (typeof result.accepted !== "boolean") fail("not a boolean", "result.accepted");
        if (!["undefined", "boolean"].includes(typeof result.duplicate)) fail("not a boolean", "result.duplicate");
        if (!result.accepted) text(result.reason, "result.reason");
      } else located(undefined, "result", () => question(r.result));
    });
  }
}
// A land chain that was claimed and has no result yet, and whether two such chains would
// act on the same worktree, branch or job of one repo.
const isRunning = (q: Question) => q.landing?.claim !== undefined && !q.landing.result;
// A land card that still waits on the person, or on its worker: a second one for the same
// worktree, branch or job is not asked.
const isOpenLand = (q: Question) => q.kind === "land" && (q.status === "pending" || (shipped(q) && !q.landing?.result));
const overlaps = (a: Pick<Question, "target">, b: Pick<Question, "target">) =>
  a.target.repo === b.target.repo &&
  (["worktree", "branch", "issue"] as const).some((key) => a.target[key] === b.target[key]);
// A trail's ID too: the same trail:<n> in another project is another job.
const sameScope = (a: QuestionSpec, b: QuestionSpec) =>
  ["repo", "issue", "trailId", "topic"].every(
    (key) => a.target[key as keyof QuestionTarget] === b.target[key as keyof QuestionTarget],
  );
const canonical = (value: unknown): string =>
  JSON.stringify(value, (_key, item) =>
    item && typeof item === "object" && !Array.isArray(item)
      ? Object.fromEntries(
          Object.keys(item)
            .sort()
            .map((key) => [key, item[key]]),
        )
      : item,
  );
export const tokenOf = (q: Pick<Question, "id" | "revision">): string => `${q.id}@${q.revision}`;

// The decision-timeout matrix: one-way and two-way doors. A two-way door is cheap to
// walk back, so a reversible question there takes Shep's recommendation at its
// deadline; a one-way door always waits for the person. docs/shep.md keeps the same
// table. The door is what the card can do: its kind, its action from a closed set
// (commit, or merge/land), and whether it carries a push. No word in its prompt,
// choices or brief changes it. What no row names is one-way.
export type Door = { door: "one-way" | "two-way"; row: string; hit: string };
// mergeReversible: whether the repo's trusted policy says merge_reversible = true;
// asked only for a merge or land.
export function door(
  q: Pick<QuestionSpec, "kind" | "prompt" | "push" | "target">,
  mergeReversible: () => boolean,
): Door {
  if (q.kind === "review") return { door: "one-way", row: "an LGTM", hit: "a review question" };
  if (q.kind !== "planning" && q.kind !== "action")
    return { door: "one-way", row: "a guard or land card", hit: q.kind };
  if (q.push) return { door: "one-way", row: "a push", hit: q.push.approves };
  const action = q.target.action;
  if (q.kind === "planning" && action === null) return { door: "two-way", row: "a planning pick", hit: q.prompt };
  if (q.kind === "action" && action === "commit") return { door: "two-way", row: "a local commit", hit: action };
  if (q.kind === "action" && (action === "merge" || action === "land"))
    return mergeReversible()
      ? { door: "two-way", row: "a merge where the policy says merge_reversible", hit: action }
      : { door: "one-way", row: "a merge where the policy does not say merge_reversible", hit: action };
  return { door: "one-way", row: "an action no two-way row names", hit: action ?? q.kind };
}

// merge_reversible as a live check read it: true only when it read a policy that says so.
export const mergesIn = (check: { policy?: { status: string; current?: unknown } }) =>
  check.policy?.status === "checked" &&
  (check.policy.current as { policy?: { merge_reversible?: unknown } })?.policy?.merge_reversible === true;

// [shep] decision_timeout, which bercail passes in: the minutes a reversible question
// waits for the person. 0: it never defaults.
export function decisionTimeout(raw = process.env.BERCAIL_SHEP_DECISION_TIMEOUT): number {
  if (raw === undefined || raw === "") return 30;
  if (!/^\d+$/.test(raw)) fail(`[shep] decision_timeout must be a whole number of minutes, not ${raw}`);
  return Number(raw);
}

// Its deadline passed with no pick: the ledger may take the recommendation.
export const isDue = (q: Question) =>
  q.status === "pending" && q.deadline !== undefined && Date.parse(q.deadline) <= Date.now();

// What the repo's policy says about merges, for a question's target: the caller looks.
export type MergePolicy = (target: QuestionTarget) => boolean;

// A new revision's own fields: a reversible two-way door with a recommendation gets a deadline.
function opened(fields: QuestionSpec, id: string, revision: number, merges: MergePolicy): Question {
  if (fields.reversible) {
    if (!fields.recommendation)
      fail("a reversible question needs a recommendation: it is what the question defaults to");
    const d = door(fields, () => merges(fields.target));
    if (d.door === "one-way")
      fail(`one-way door (${d.row}: "${d.hit}"): it waits for the person; ask it without reversible`);
  }
  const createdAt = new Date();
  const minutes = fields.reversible ? decisionTimeout() : 0;
  return {
    ...structuredClone(fields),
    id,
    revision,
    status: "pending",
    createdAt: createdAt.toISOString(),
    ...(minutes ? { deadline: new Date(createdAt.getTime() + minutes * 60000).toISOString() } : {}),
    proposals: [],
  };
}

// What a live check (checkQuestion) saw, as the store's transitions read it.
type Check = {
  status: string;
  reasons: string[];
  current: Pick<QuestionTarget, "head" | "stagedTree"> | null;
  policy?: { status: string; current?: unknown };
};

// This module's source and its sha256 when it loaded, if it could be read. A deploy that
// replaced it since makes a ledger this process refuses a reason to restart it first.
const hash = (path: string) => createHash("sha256").update(readFileSync(path)).digest("hex");
const loaded = (() => {
  try {
    const path = fileURLToPath(import.meta.url);
    return { path, hash: hash(path) };
  } catch {
    return undefined;
  }
})();
const changed = () => {
  if (!loaded) return false;
  try {
    return hash(loaded.path) !== loaded.hash;
  } catch {
    return true;
  }
};
// A ledger this process will not read. It never echoes the file: Node's JSON.parse error quotes it.
function refuse(error: unknown, parsed: boolean): never {
  const why = !parsed ? "not valid JSON" : error instanceof Invalid ? error.why : "not a valid ledger";
  const at = error instanceof Invalid && error.where ? ` at ${error.where}` : "";
  if (parsed && changed())
    fail(
      `this process cannot validate questions.json${at}: ${why}, and ${loaded!.path} changed since this process loaded it: restart it and retry before considering a repair; not overwritten`,
    );
  fail(`corrupt questions.json${at}: ${why}; not overwritten`);
}
// Keeps the primary, before a write replaces it, as questions.json.1, and the older ones as
// .2 and .3: a hard link, not a copy. A .1 that already is the primary was kept by a write
// that stopped before it replaced it, so the retry keeps nothing new; a missing .1 was
// shifted by one that stopped before the link, or never kept, so the older ones stay.
function keep(primary: string) {
  const now = statSync(primary, { bigint: true });
  const slot = (n: number) => `${primary}.${n}`;
  const absent = (error: unknown) => {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
  };
  let one;
  try {
    one = statSync(slot(1), { bigint: true });
  } catch (error) {
    absent(error);
  }
  if (one && one.dev === now.dev && one.ino === now.ino) return;
  if (one) {
    try {
      renameSync(slot(2), slot(3));
    } catch (error) {
      absent(error);
    }
    renameSync(slot(1), slot(2));
  }
  linkSync(primary, slot(1));
}

// The caller supplies repo identity; this store never probes or changes a checkout.
export class QuestionStore {
  private readonly dir: string;
  constructor(dir: string) {
    this.dir = dir;
  }

  private locked<T>(run: (state: State) => T, write = false): T {
    mkdirSync(this.dir, { recursive: true, mode: 0o700 });
    const lock = openSync(join(this.dir, "questions.lock"), "a", 0o600);
    try {
      // flock uses the inherited open-file description: this process retains the
      // kernel lock after the helper exits, and process death releases it.
      const acquired = spawnSync("flock", ["-x", "-w", "10", "3"], { stdio: ["ignore", "pipe", "pipe", lock] });
      if (acquired.error || acquired.status !== 0)
        fail("cannot acquire lock; install flock or retry when the writer finishes");
      const primary = join(this.dir, "questions.json");
      let state: State;
      let raw: string | undefined;
      try {
        raw = readFileSync(primary, "utf8");
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
      }
      let parsed = false;
      try {
        state = raw === undefined ? { version: 1, questions: [], selected: null, requests: [] } : JSON.parse(raw);
        parsed = true;
        validate(state);
      } catch (error) {
        refuse(error, parsed);
      }
      const result = run(state);
      if (write) {
        validate(state);
        const temp = join(this.dir, `.questions.${process.pid}.${randomUUID()}.tmp`);
        try {
          const fd = openSync(temp, "wx", 0o600);
          try {
            writeFileSync(fd, `${JSON.stringify(state)}\n`);
            fsyncSync(fd);
          } finally {
            closeSync(fd);
          }
          if (raw !== undefined) keep(primary);
          renameSync(temp, primary);
          const fdDir = openSync(this.dir, "r");
          try {
            fsyncSync(fdDir);
          } finally {
            closeSync(fdDir);
          }
        } finally {
          rmSync(temp, { force: true });
        }
      }
      return structuredClone(result);
    } finally {
      closeSync(lock);
    }
  }

  snapshot(): QuestionSnapshot {
    return this.locked(({ version, questions, selected }) => ({ version, questions, selected }));
  }

  select(topic: string | null): void {
    if (topic !== null) text(topic);
    this.locked((state) => {
      if (topic !== null && !state.questions.some((q) => q.target.topic === topic)) fail("unknown topic");
      state.selected = topic;
    }, true);
  }

  private request<T extends Question | ProposalResult | AnswerResult>(
    requestId: string,
    payload: unknown,
    apply: (state: State) => T,
  ): T {
    text(requestId);
    const encoded = canonical(payload);
    return this.locked((state) => {
      const old = state.requests.find((r) => r.requestId === requestId);
      if (old) {
        if (old.payload !== encoded) fail("request id reused with different payload");
        return ("duplicate" in old.result ? { ...old.result, duplicate: true } : old.result) as T;
      }
      const result = apply(state);
      state.requests.push({ requestId, payload: encoded, result: structuredClone(result) });
      return result;
    }, true);
  }

  private find(state: State, token: string): Question {
    if (typeof token !== "string" || !/^Q[1-9]\d*@[1-9]\d*$/.test(token)) fail("explicit Qn@revision token required");
    return state.questions.find((q) => tokenOf(q) === token) ?? fail("unknown question revision");
  }

  create<T>(
    requestId: string,
    intent: T,
    resolveSpec: (intent: T) => QuestionSpec,
    merges: MergePolicy = () => false,
  ): Question {
    return this.request(requestId, ["create", intent], (state) => {
      const fields = resolveSpec(intent);
      spec(fields);
      const open = fields.kind === "land" && state.questions.find((o) => isOpenLand(o) && overlaps(o, fields));
      if (open)
        fail(
          `${tokenOf(open)} is ${open.status === "pending" ? "pending" : "landing"} for the same worktree, branch or job`,
        );
      const id = `Q${state.questions.reduce((max, q) => Math.max(max, Number(q.id.slice(1))), 0) + 1}`;
      const q = opened(fields, id, 1, merges);
      state.questions.push(q);
      return q;
    });
  }

  revise<T>(
    requestId: string,
    token: string,
    intent: T,
    resolveSpec: (intent: T) => QuestionSpec,
    merges: MergePolicy = () => false,
  ): Question {
    return this.request(requestId, ["revise", token, intent], (state) => {
      const fields = resolveSpec(intent);
      spec(fields);
      const previous = this.find(state, token);
      if (previous.status !== "pending") fail("stale or closed question revision");
      if (!sameScope(previous, fields)) fail("revision cannot change repo, issue or topic; create a new question");
      const q = opened(fields, previous.id, previous.revision + 1, merges);
      previous.status = "superseded";
      state.questions.push(q);
      return q;
    });
  }

  propose(requestId: string, token: string, answer: string, source: string): ProposalResult {
    text(answer);
    text(source);
    return this.request(requestId, ["propose", token, answer, source], (state) => {
      const q = this.find(state, token);
      const first = q.proposals.find((p) => p.accepted);
      const reason =
        q.status !== "pending"
          ? "stale or closed question revision"
          : first && first.answer !== answer
            ? "conflicting proposal retained; first proposal unchanged"
            : undefined;
      const duplicate = reason === undefined && first?.answer === answer;
      q.proposals.push({
        requestId,
        answer,
        source,
        at: new Date().toISOString(),
        verified: false,
        accepted: !reason,
        ...(reason ? { reason } : {}),
      });
      return { question: q, duplicate, accepted: !reason, ...(reason ? { reason } : {}) };
    });
  }

  // Shep's: a pending question that no longer applies (its desk stopped, events made it
  // moot) leaves the panel and can never be answered. So does a default without the
  // person's OK: one Shep found moot, or a Reverse Shep has handled. It keeps the default
  // and the Reverse, and records no answer. With a source it is the person's Close: any
  // card that waits on them, whatever its live check says, but never a land card whose
  // chain runs (shipped, so answered). The caller tells Shep of a Close.
  withdraw(requestId: string, token: string, reason: string, source?: "panel picker"): Question {
    text(reason);
    if (source !== undefined && source !== PUSH_SOURCE) fail("only the panel closes a card for the person");
    const payload = source === undefined ? ["withdraw", token, reason] : ["close", token, reason, source];
    return this.request(requestId, payload, (state) => {
      const q = this.find(state, token);
      const open = q.status === "pending" || (q.answer?.source === DEFAULT_SOURCE && q.settled?.outcome !== "ok");
      if (!open || q.status === "withdrawn")
        fail(
          `question is ${q.status}; only a pending question, or a default without the person's OK, can be withdrawn`,
        );
      q.status = "withdrawn";
      q.withdrawal = { requestId, reason, at: new Date().toISOString(), ...(source ? { source } : {}) };
      return q;
    });
  }

  // The person's pick: once per revision, one of its options, and only when the live
  // check the caller ran just before found the candidate unchanged (fresh). A local
  // user-owned record, not proof of who picked (docs/shep.md, "Answering").
  answer(
    requestId: string,
    token: string,
    choice: string,
    source: (typeof ANSWER_SOURCES)[number],
    check: Check,
  ): AnswerResult {
    if (!ANSWER_SOURCES.includes(source)) fail("unknown answer source");
    text(choice);
    return this.request(requestId, ["answer", token, choice, source], (state) => {
      const q = this.find(state, token);
      // A guard or land card: only the panel, which no agent can type into; a guard card's
      // Allow only before it expires. Its Deny grants nothing, so it needs no live check
      // and stands whenever the card is pending: a slow check never lets a default win.
      const veto = q.guard !== undefined && choice === "Deny" && source === PUSH_SOURCE;
      const reason =
        q.status !== "pending"
          ? `question is ${q.status}`
          : !q.options.includes(choice)
            ? "not one of the question's choices"
            : (q.guard || q.land) && source !== PUSH_SOURCE
              ? `a ${q.kind} card is answered on the panel card only`
              : veto
                ? undefined
                : q.guard && Date.parse(q.guard.expires) <= Date.now()
                  ? `it expired at ${q.guard.expires}, which counts as ${q.guard.defaults ? "an Allow if it still reads private or local" : "a Deny"}`
                  : check.status !== "fresh" || !check.current
                    ? `changed since Shep asked: ${check.reasons.join(", ") || "not checked"}`
                    : isDue(q) && door(q, () => mergesIn(check)).door === "two-way"
                      ? `past its deadline: it takes Shep's recommendation, ${q.recommendation!.choice}`
                      : undefined;
      if (reason) return { question: q, accepted: false, reason };
      q.status = "answered";
      q.answer = {
        requestId,
        choice,
        source,
        at: new Date().toISOString(),
        head: check.current?.head ?? null,
        stagedTree: check.current?.stagedTree ?? null,
      };
      return { question: q, accepted: true };
    });
  }

  // The deadline passed with no pick: the ledger, not Shep, records Shep's
  // recommendation as DEFAULT_SOURCE, once, and only when the live check the caller
  // ran just before found the question unchanged and, with the policy it read, still
  // a two-way door. The caller checks a due question. The default authorizes only the
  // card's own action: a local commit, a merge the policy calls reversible, or on a
  // planning card a plan, an order or a scope, and no write.
  expire(token: string, check: Check): AnswerResult {
    return this.locked((state) => {
      const q = this.find(state, token);
      if (!isDue(q)) return { question: q, accepted: false, reason: `question is ${q.status} or not due` };
      if (check.status !== "fresh" || !check.current)
        return { question: q, accepted: false, reason: `changed since Shep asked: ${check.reasons.join(", ")}` };
      const d = door(q, () => mergesIn(check));
      if (d.door === "one-way") return { question: q, accepted: false, reason: `now a one-way door: ${d.row}` };
      q.status = "answered";
      q.answer = {
        requestId: `default:${tokenOf(q)}`,
        choice: q.recommendation!.choice,
        source: DEFAULT_SOURCE,
        at: new Date().toISOString(),
        head: check.current.head,
        stagedTree: check.current.stagedTree,
      };
      return { question: q, accepted: true };
    }, true);
  }

  // The person's word on a default, once per revision, and only while the live check the
  // caller ran just before found the candidate unchanged (fresh). OK makes it their pick,
  // with the full weight of one (an LGTM where the card asked for one). Reverse rejects
  // it, naming another of the choices (their pick) or none (choice null).
  settle(
    requestId: string,
    token: string,
    outcome: QuestionSettlement["outcome"],
    choice: string | null,
    source: (typeof ANSWER_SOURCES)[number],
    check: Check,
  ): AnswerResult {
    if (!ANSWER_SOURCES.includes(source)) fail("unknown answer source");
    if (outcome === "ok" && choice !== null) fail("an OK names no choice: it keeps the default's");
    if (choice !== null) text(choice);
    return this.request(requestId, ["settle", token, outcome, choice, source], (state) => {
      const q = this.find(state, token);
      const reason =
        q.answer?.source !== DEFAULT_SOURCE
          ? `question is ${q.status}, not defaulted: only a default takes OK or Reverse`
          : q.settled
            ? q.settled.outcome === "ok"
              ? "its default already has the person's OK"
              : "its default is already reversed"
            : q.status !== "answered"
              ? `question is ${q.status}`
              : choice !== null && (choice === q.answer.choice || !q.options.includes(choice))
                ? `not another of the question's choices: it defaulted to ${q.answer.choice}`
                : check.status !== "fresh" || !check.current
                  ? `changed since it defaulted: ${check.reasons.join(", ") || "not checked"}`
                  : undefined;
      if (reason) return { question: q, accepted: false, reason };
      q.settled = {
        requestId,
        outcome,
        choice: outcome === "ok" ? q.answer!.choice : choice,
        source,
        at: new Date().toISOString(),
        head: check.current!.head,
        stagedTree: check.current!.stagedTree,
      };
      return { question: q, accepted: true };
    });
  }

  // The guard's: the answer's one push, claimed while the live check the caller ran just
  // before is fresh. A second claim is refused, so one answer approves one push.
  claimPush(token: string, check: Check, claim: Omit<PushClaim, "at">): AnswerResult {
    return this.locked((state) => {
      const q = this.find(state, token);
      const reason = q.pushed
        ? `its push was already claimed at ${q.pushed.at}`
        : q.status !== "answered" || !q.push || q.answer?.choice !== q.push.approves || q.answer.source !== PUSH_SOURCE
          ? "not the person's approving answer on the panel"
          : check.status !== "fresh" || !check.current
            ? `changed since it was answered: ${check.reasons.join(", ") || "not checked"}`
            : undefined;
      if (reason) return { question: q, accepted: false, reason };
      q.pushed = { at: new Date().toISOString(), ...structuredClone(claim) };
      return { question: q, accepted: true };
    }, true);
  }

  // A guard card's worker, at its deadline: nobody answered, the card said it defaults, and
  // the worker read the class again just before and found it unchanged (`why`, the reason
  // the card gave). The ledger records the default, on a pending card only, so the
  // person's pick, made first, stands; only on one that was up for most of its hour, and
  // only in the first minutes after its deadline.
  defaultGuard(token: string, ticket: string, why: string): AnswerResult {
    return this.locked((state) => {
      const q = this.find(state, token);
      const reason =
        q.guard?.ticket !== ticket
          ? "not this ticket's guard card"
          : q.status !== "pending"
            ? `question is ${q.status}`
            : !q.guard.defaults
              ? "it waits for the person: nobody answering counts as a Deny"
              : q.guard.defaults.why !== why
                ? `it no longer reads as it did when asked: ${why}`
                : Date.now() < Date.parse(q.guard.expires)
                  ? `not past its deadline, ${q.guard.expires}`
                  : Date.parse(q.guard.expires) - Date.parse(q.createdAt) < GUARD_WINDOW
                    ? "it went up too late to give the person most of its hour"
                    : Date.now() - Date.parse(q.guard.expires) > GUARD_LATE
                      ? "it is too long past its deadline: its reading is stale"
                      : undefined;
      if (reason) return { question: q, accepted: false, reason };
      q.status = "answered";
      q.answer = {
        requestId: `default:${tokenOf(q)}`,
        choice: "Allow",
        source: GUARD_DEFAULT_SOURCE,
        at: new Date().toISOString(),
        head: null,
        stagedTree: null,
      };
      return { question: q, accepted: true };
    }, true);
  }

  // A guard card's worker: the person's Allow on the panel, picked before the card expired,
  // or its default, recorded at or after it; claimed once for this ticket. A second claim is
  // refused, so the operation runs once.
  claimGuard(token: string, ticket: string): AnswerResult {
    return this.locked((state) => {
      const q = this.find(state, token);
      const a = q.answer;
      const defaulted = a?.source === GUARD_DEFAULT_SOURCE;
      const reason =
        q.guard?.ticket !== ticket
          ? "not this ticket's guard card"
          : q.guardClaim
            ? `its Allow was already claimed at ${q.guardClaim.at}`
            : q.status !== "answered" || a?.choice !== "Allow" || (a.source !== PUSH_SOURCE && !defaulted)
              ? "not the person's Allow on the panel"
              : defaulted
                ? !q.guard.defaults || Date.parse(a.at) < Date.parse(q.guard.expires)
                  ? "a default on a card that did not say it defaults, or before its deadline"
                  : undefined
                : Date.parse(a.at) >= Date.parse(q.guard.expires)
                  ? `picked after it expired at ${q.guard.expires}`
                  : undefined;
      if (reason) return { question: q, accepted: false, reason };
      q.guardClaim = { at: new Date().toISOString() };
      return { question: q, accepted: true };
    }, true);
  }

  // A land card's chain, each step under the ledger's lock. A start reservation names the
  // worker's terminal before it runs, once per attempt: `attempt` is the one after the
  // last, so two sweeps that race start one worker. It grants nothing; the claim does.
  reserveLand(token: string, attempt: number): AnswerResult {
    return this.landing(token, (q, l) => {
      if (l.claim) return `its chain was already claimed at ${l.claim.at}`;
      if (attempt !== l.starts.length + 1) return `start ${attempt} is not the next one, ${l.starts.length + 1}`;
      l.starts.push({ terminal: landTerminal(q), at: new Date().toISOString() });
    });
  }

  // The worker's way in: the person's Ship it on the panel, claimed once, while no other
  // chain runs for the same worktree, branch or job in this repo.
  claimLand(token: string): AnswerResult {
    return this.landing(token, (q, l, state) => {
      if (l.claim) return `its chain was already claimed at ${l.claim.at}`;
      const running = state.questions.find((o) => o !== q && isRunning(o) && overlaps(o, q));
      if (running) return `${tokenOf(running)}'s chain is running for the same worktree, branch or job`;
      l.claim = { at: new Date().toISOString() };
    });
  }

  // The step the claimed chain starts now; the same step again updates what it says.
  landStep(token: string, step: (typeof LAND_STEPS)[number], detail?: string): AnswerResult {
    if (!LAND_STEPS.includes(step)) fail("unknown land step");
    if (detail !== undefined) text(detail);
    return this.landing(token, (_q, l) => {
      if (!l.claim) return "its chain is not claimed";
      if (l.result) return `its chain ended: ${l.result.outcome}`;
      const refused = advance(l.steps.at(-1)?.step, step);
      if (refused) return refused;
      l.steps.push({ step, at: new Date().toISOString(), ...(detail === undefined ? {} : { detail }) });
    });
  }

  // The claimed chain's one result, at the last step the ledger has.
  landResult(
    token: string,
    result: Pick<LandResult, "outcome" | "commit" | "why" | "trusted" | "warnings" | "log">,
  ): AnswerResult {
    return this.landing(token, (_q, l) => {
      if (!l.claim) return "its chain is not claimed";
      if (l.result) return `its chain already ended: ${l.result.outcome}`;
      if (result.outcome === "landed" && !pastTrunk(l.steps.at(-1)?.step ?? null))
        return "landed only once the chain is past its trunk push";
      l.result = {
        outcome: result.outcome,
        step: l.steps.at(-1)?.step ?? null,
        commit: result.commit,
        ...(result.why === undefined ? {} : { why: result.why }),
        ...(result.trusted === undefined ? {} : { trusted: result.trusted }),
        warnings: structuredClone(result.warnings),
        log: result.log,
        at: new Date().toISOString(),
      };
    });
  }

  // The result's land event, written by `publish` under the ledger's lock (which finds it
  // there after a crash, or writes it), then told: once, whoever else tries at the same time.
  landTold(token: string, publish: (q: Question) => void = () => {}): AnswerResult {
    return this.landing(token, (q, l) => {
      if (!l.result) return "its chain has no result";
      if (l.result.told) return "its result was already told";
      publish(q);
      l.result.told = true;
    });
  }

  // One land transition on the person's Ship it: `apply` returns why it is refused, or
  // changes the chain. The ledger checks the whole record before it writes.
  private landing(
    token: string,
    apply: (q: Question, landing: Landing, state: State) => string | undefined,
  ): AnswerResult {
    return this.locked((state) => {
      const q = this.find(state, token);
      if (!shipped(q))
        return { question: q, accepted: false, reason: "not the person's Ship it on a land card's panel" };
      const l = q.landing ?? { starts: [], steps: [] };
      const reason = apply(q, l, state);
      if (reason) return { question: q, accepted: false, reason };
      q.landing = l;
      return { question: q, accepted: true };
    }, true);
  }

  // The decision event of its default, or of the person's OK or Reverse on it, is
  // written: the caller wrote it, or found it there.
  told(token: string, which: "default" | "settled" | "closed" = "default"): void {
    this.locked((state) => {
      const q = this.find(state, token);
      if (which === "closed") {
        if (!q.withdrawal?.source) fail("only the person's Close is told");
        q.withdrawal.told = true;
        return;
      }
      if (q.answer?.source !== DEFAULT_SOURCE || (which === "settled" && !q.settled)) fail("only a default is told");
      if (which === "settled") q.settled!.told = true;
      else q.told = true;
    }, true);
  }
}

export function projection(snapshot: QuestionSnapshot): string {
  // Strip terminal controls from untrusted prompts, targets and proposed answers.
  const line = (value: string, max = 160) => {
    // eslint-disable-next-line no-control-regex
    const flat = value.replace(/[\u0000-\u001f\u007f-\u009f]/g, " ");
    return flat.length > max ? flat.slice(0, max - 1) + "…" : flat;
  };
  const pending = snapshot.questions.filter((q) => q.status === "pending");
  const lines = [
    `Questions (all proposals unverified; no action authority). Selected topic: ${snapshot.selected === null ? "none" : line(snapshot.selected)}`,
  ];
  for (const q of pending.slice(0, 20)) {
    const target = Object.entries(q.target)
      .map(([key, value]) => `${key}=${line(value ?? "none", 64)}`)
      .join(" ");
    const answer = q.proposals.find((p) => p.accepted)?.answer;
    const deadline = q.deadline ? ` | defaults to ${line(q.recommendation!.choice, 80)} at ${q.deadline}` : "";
    const row = `${tokenOf(q)} [${q.kind}] ${line(q.prompt, 160)} | options=${line(q.options.join(" / "), 100)} | ${target} | proposed=${line(answer ?? "none", 100)} (${q.proposals.length} unverified proposals)${deadline}`;
    if (lines.join("\n").length + row.length > 15500) break;
    lines.push(row);
  }
  lines.push(
    `${pending.length} pending; ${pending.length - lines.length + 1} omitted. Reply with /reply Qn@revision answer; bare replies never select a target.`,
    "Shortened fields end in …; full targets and history: bercail shep questions --json --all.",
  );
  // The answers, newest first: the record of an answer, whatever became of its event.
  // A default is never listed as the person's until they said OK to it; one they
  // reversed waits for Shep to undo it and withdraw it.
  const said = (q: Question) =>
    q.settled?.outcome === "ok" ? { ...q.settled, source: `confirmed default, ${q.settled.source}` } : q.answer!;
  const at = (q: Question) => (q.settled ?? q.answer!).at;
  const listed = (kind: "picked" | "defaulted" | "reversed") =>
    snapshot.questions
      .filter(
        (q) =>
          q.status === "answered" &&
          q.kind !== "guard" &&
          // A land card's Ship it is its worker's to act on, and its result comes as a land event.
          !shipped(q) &&
          (q.answer!.source !== DEFAULT_SOURCE || q.settled?.outcome === "ok"
            ? "picked"
            : q.settled
              ? "reversed"
              : "defaulted") === kind,
      )
      .sort((a, b) => at(b).localeCompare(at(a)))
      .slice(0, 10);
  const heads = {
    picked: "Answered by the person's pick (a local record, not proof of identity; act on it once):",
    defaulted:
      "Defaulted to your recommendation after the deadline (not the person's choice, never an LGTM or reviewer; act on it once, and say it was defaulted; its card waits for the person's OK or Reverse):",
    reversed:
      "Reversed by the person (undo what you did on the default, then act on their choice once while question check is fresh, or ask again; then withdraw it with what you did):",
  };
  for (const kind of ["picked", "defaulted", "reversed"] as const) {
    const qs = listed(kind);
    if (qs.length) lines.push(heads[kind]);
    for (const q of qs) {
      const r = said(q);
      const what =
        kind === "reversed"
          ? `reversed ${line(q.answer!.choice, 80)} ${q.settled!.choice === null ? "with no other choice" : `to ${line(q.settled!.choice, 80)}`} (${q.settled!.source}, ${q.settled!.at})`
          : `${line(r.choice!, 80)} (${r.source}, ${r.at})`;
      lines.push(`${tokenOf(q)} ${line(q.prompt, 120)} -> ${what} topic=${line(q.target.topic, 64)}`);
    }
  }
  return lines.join("\n");
}
