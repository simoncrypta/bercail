import { spawnSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { closeSync, fsyncSync, mkdirSync, openSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { isAbsolute, join, normalize } from "node:path";
import type {
  CandidateReviewSpec,
  JobScope,
  ScopedAction,
  ScopedActionReceipt,
  ScopedActionState,
  ScopedAnswerCheck,
  ScopedAuthorization,
  ScopedCandidate,
  ScopedEffectObservation,
  ScopedGrant,
  ScopedSnapshot,
} from "./scoped-types.ts";
import { SCOPED_CAPABILITY } from "./scoped-types.ts";
export { SCOPED_CAPABILITY } from "./scoped-types.ts";
export type * from "./scoped-types.ts";

export interface QuestionTarget {
  repo: string;
  issue: string | null;
  topic: string;
  worktree: string | null;
  desk: string | null;
  space: string | null;
  session: string | null;
  action: string | null;
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
  kind: "planning" | "review" | "action" | "scoped-authorization" | "candidate-review";
  authorization?: ScopedAuthorization;
  review?: CandidateReviewSpec;
  prompt: string;
  options: string[];
  origin: QuestionOrigin;
  target: QuestionTarget;
  /** What is decided and why now, in Shep's words, for the card. */
  brief?: string;
  /** Shep's pick among options, with one line of why. */
  recommendation?: { choice: string; why: string };
}
/** Who recorded an answer: the person's pick on a card or in a Discuss branch. */
export const ANSWER_SOURCES = ["panel picker", "discuss picker"] as const;
export interface QuestionAnswer {
  requestId: string;
  choice: string;
  source: (typeof ANSWER_SOURCES)[number];
  at: string;
  /** The candidate the live check saw when the person picked. */
  head: string | null;
  stagedTree: string | null;
}
/** Shep's: the question no longer applies. Not an answer. */
export interface QuestionWithdrawal {
  requestId: string;
  reason: string;
  at: string;
}
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
  /** Present once withdrawn, and only then. */
  withdrawal?: QuestionWithdrawal;
}
export interface QuestionSnapshot {
  version: 1 | 2;
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
type State = QuestionSnapshot & { requests: Receipt[] } & Partial<ScopedSnapshot>;

function fail(message: string): never {
  throw new Error(`Question store: ${message}`);
}
function text(value: unknown): asserts value is string {
  if (typeof value !== "string" || !value.trim()) fail("expected nonempty text");
}
function shape(value: unknown, keys: string[]): asserts value is Record<string, unknown> {
  if (
    !value ||
    typeof value !== "object" ||
    Array.isArray(value) ||
    Object.keys(value).sort().join() !== [...keys].sort().join()
  )
    fail("invalid fields");
}
// Keys an older ledger may lack: present with a value, or absent.
const optional = (value: Record<string, unknown>, keys: string[]) => keys.filter((key) => value[key] !== undefined);
function spec(value: unknown): asserts value is QuestionSpec {
  const v = value as Record<string, unknown>;
  shape(value, [
    "kind",
    "prompt",
    "options",
    "origin",
    "target",
    ...optional(v ?? {}, ["brief", "recommendation", "authorization", "review"]),
  ]);
  if (!["planning", "review", "action", "scoped-authorization", "candidate-review"].includes(value.kind as string))
    fail("invalid kind");
  if (
    (value.kind === "scoped-authorization") !== (value.authorization !== undefined) ||
    (value.kind === "candidate-review") !== (value.review !== undefined)
  )
    fail("typed question payload required, and only for its kind");
  text(value.prompt);
  if (!Array.isArray(value.options)) fail("invalid options");
  value.options.forEach(text);
  if (value.brief !== undefined) text(value.brief);
  if (value.recommendation !== undefined) {
    shape(value.recommendation, ["choice", "why"]);
    text(value.recommendation.why);
    if (!value.options.includes(value.recommendation.choice)) fail("recommendation must be one of the options");
  }
  shape(value.origin, ["event", "session", "entry"]);
  text(value.origin.event);
  text(value.origin.session);
  if (value.origin.entry !== null) text(value.origin.entry);
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
  shape(value.target, keys);
  for (const key of keys)
    if (
      value.target[key] !== null ||
      !(value.kind === "planning" || (value.kind === "scoped-authorization" && ["head", "stagedTree"].includes(key))) ||
      key === "repo" ||
      key === "topic"
    )
      text(value.target[key]);
  const repo = value.target.repo as string;
  if (!isAbsolute(repo) || normalize(repo) !== repo)
    fail("repo must be a canonical absolute identity path supplied by the caller");
  if (value.target.worktree !== null && !isAbsolute(value.target.worktree as string)) fail("worktree must be absolute");
  if (value.authorization !== undefined) {
    shape(value.authorization, ["scope", "actions", "expiresAt", "allowChoice", "stageOnlyChoice"]);
    jobScope(value.authorization.scope);
    allowedActions(value.authorization.actions);
    date(value.authorization.expiresAt);
    for (const key of ["allowChoice", "stageOnlyChoice"]) {
      text(value.authorization[key]);
      if (!value.options.includes(value.authorization[key])) fail("authorization choice must be an option");
    }
    if (value.authorization.allowChoice === value.authorization.stageOnlyChoice)
      fail("distinct authorization choices required");
    if (!scopeTarget(value.authorization.scope, value.target as unknown as QuestionTarget))
      fail("scope differs from question target");
  }
  if (value.review !== undefined) {
    shape(value.review, ["grantId", "candidate", "allowChoice"]);
    text(value.review.grantId);
    scopedCandidate(value.review.candidate);
    if (!value.options.includes(value.review.allowChoice)) fail("review choice must be an option");
    if (!candidateTarget(value.review.candidate, value.target as unknown as QuestionTarget))
      fail("candidate differs from question target");
  }
}
function question(value: unknown): asserts value is Question {
  const v = value as Record<string, unknown>;
  const keys = ["id", "revision", "status", "createdAt", "proposals", "kind", "prompt", "options", "origin", "target"];
  shape(value, [
    ...keys,
    ...optional(v ?? {}, ["brief", "recommendation", "authorization", "review", "answer", "withdrawal"]),
  ]);
  const { id, revision, status, createdAt, proposals, answer, withdrawal, ...fields } = value;
  spec(fields);
  if (
    typeof id !== "string" ||
    !/^Q[1-9]\d*$/.test(id) ||
    !Number.isSafeInteger(Number(id.slice(1))) ||
    !Number.isSafeInteger(revision) ||
    (revision as number) < 1
  )
    fail("invalid question revision");
  if (!STATUSES.includes(status as string)) fail("invalid status");
  text(createdAt);
  if (!Number.isFinite(Date.parse(createdAt)) || !Array.isArray(proposals)) fail("invalid question history");
  for (const p of proposals) {
    shape(p, [
      "requestId",
      "answer",
      "source",
      "at",
      "verified",
      "accepted",
      ...(p?.reason === undefined ? [] : ["reason"]),
    ]);
    text(p.requestId);
    text(p.answer);
    text(p.source);
    text(p.at);
    if (p.verified !== false || typeof p.accepted !== "boolean" || !Number.isFinite(Date.parse(p.at)))
      fail("invalid unverified proposal");
    if (!p.accepted) text(p.reason);
  }
  if ((status === "answered") !== (answer !== undefined)) fail("an answered question needs its answer, and only it");
  if (answer !== undefined) {
    shape(answer, ["requestId", "choice", "source", "at", "head", "stagedTree"]);
    text(answer.requestId);
    text(answer.at);
    if (!fields.options.includes(answer.choice as string)) fail("answer is not one of the options");
    if (!ANSWER_SOURCES.includes(answer.source as QuestionAnswer["source"])) fail("unknown answer source");
    for (const key of ["head", "stagedTree"]) if (answer[key] !== null) text(answer[key]);
    if (!Number.isFinite(Date.parse(answer.at as string))) fail("invalid answer time");
  }
  if ((status === "withdrawn") !== (withdrawal !== undefined))
    fail("a withdrawn question needs its withdrawal, and only it");
  if (withdrawal !== undefined) {
    shape(withdrawal, ["requestId", "reason", "at"]);
    text(withdrawal.requestId);
    text(withdrawal.reason);
    if (!Number.isFinite(Date.parse(withdrawal.at as string))) fail("invalid withdrawal time");
  }
}
function validate(value: unknown): asserts value is State {
  const v = value as Record<string, unknown>;
  shape(value, [
    "version",
    "questions",
    "selected",
    "requests",
    ...(v?.version === 2 ? ["grants", "reviews", "actions"] : []),
  ]);
  if (![1, 2].includes(value.version as number) || !Array.isArray(value.questions) || !Array.isArray(value.requests))
    fail("invalid state version or history");
  if (value.selected !== null) text(value.selected);
  const latest = new Map<string, Question>();
  for (const q of value.questions) {
    question(q);
    if (value.version === 1 && typed(q)) fail("typed questions require version 2");
    const previous = latest.get(q.id);
    if (
      q.revision !== (previous?.revision ?? 0) + 1 ||
      (previous && (previous.status !== "superseded" || !sameScope(previous, q)))
    )
      fail("invalid revision history");
    latest.set(q.id, q);
  }
  if ([...latest.values()].some((q) => q.status === "superseded")) fail("missing current revision");
  if (value.selected !== null && !value.questions.some((q) => q.target.topic === value.selected))
    fail("unknown selected topic");
  const ids = new Set<string>();
  for (const r of value.requests) {
    shape(r, ["requestId", "payload", "result"]);
    text(r.requestId);
    text(r.payload);
    if (ids.has(r.requestId)) fail("duplicate request id");
    ids.add(r.requestId);
    if (r.result && typeof r.result === "object" && "question" in r.result) {
      const result = r.result as ProposalResult;
      // An answer receipt has no duplicate flag; a reply receipt has one.
      const keys = ["question", "accepted", ...optional(result as never, ["duplicate", "reason"])];
      shape(result, keys);
      question(result.question);
      if (typeof result.accepted !== "boolean" || !["undefined", "boolean"].includes(typeof result.duplicate))
        fail("invalid reply receipt");
      if (!result.accepted) text(result.reason);
    } else question(r.result);
  }
  if (value.version === 2) validateScoped(value as unknown as State & ScopedSnapshot, ids);
}
const sameScope = (a: QuestionSpec, b: QuestionSpec) =>
  ["repo", "issue", "topic"].every(
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

const typed = (q: Pick<QuestionSpec, "kind">) => ["scoped-authorization", "candidate-review"].includes(q.kind);
const scopeKeys = [
  "repo",
  "worktree",
  "issue",
  "pr",
  "headRef",
  "baseRef",
  "baseOid",
  "remote",
  "endpoint",
  "backend",
  "desk",
  "space",
  "session",
  "owner",
  "mapping",
  "policy",
];
function date(value: unknown): asserts value is string {
  text(value);
  if (!Number.isFinite(Date.parse(value)) || new Date(value).toISOString() !== value) fail("expected ISO date");
}
function jobScope(value: unknown): asserts value is JobScope {
  shape(value, scopeKeys);
  scopeKeys.forEach((key) => text(value[key]));
  for (const key of ["repo", "worktree"])
    if (!isAbsolute(value[key] as string) || normalize(value[key] as string) !== value[key])
      fail("scope paths must be canonical absolute paths");
  if (value.backend !== "gh") fail("unsupported scoped backend");
  try {
    const url = new URL(value.pr as string);
    if (!["https:", "http:"].includes(url.protocol) || url.username || url.password) fail("invalid PR URL");
  } catch {
    fail("invalid PR URL");
  }
}
function scopedCandidate(value: unknown): asserts value is ScopedCandidate {
  const keys = ["head", "tree", "base", "description", "evidence"];
  shape(value, keys);
  keys.forEach((key) => text(value[key]));
}
function allowedActions(value: unknown): asserts value is ScopedAction[] {
  if (
    !Array.isArray(value) ||
    !value.length ||
    new Set(value).size !== value.length ||
    value.some((action) => !["commit", "publish-fast-forward"].includes(action))
  )
    fail("invalid scoped actions");
}
const equal = (a: unknown, b: unknown) => canonical(a) === canonical(b);
const scopeTarget = (scope: JobScope, target: QuestionTarget) =>
  ["repo", "worktree", "issue", "desk", "space", "session", "baseRef"].every(
    (key) => scope[key as keyof JobScope] === target[key as keyof QuestionTarget],
  );
const candidateTarget = (candidate: ScopedCandidate, target: QuestionTarget) =>
  candidate.head === target.head && candidate.tree === target.stagedTree && candidate.base === target.base;
// A replacement grant/session cannot shed an unresolved local or remote operation.
const sameExecutionTarget = (a: JobScope, b: JobScope) =>
  (a.repo === b.repo && (a.worktree === b.worktree || a.headRef === b.headRef)) ||
  (a.endpoint === b.endpoint && a.headRef === b.headRef);
const unfinished = (r: ScopedActionReceipt) => r.state === "applying" || r.state === "inspect";
function upgrade(state: State): asserts state is State & ScopedSnapshot {
  if (state.version === 1) {
    state.version = 2;
    state.grants = [];
    state.reviews = [];
    state.actions = [];
  }
}
function transition(grant: ScopedGrant, state: ScopedGrant["state"], reason: string | null) {
  if (grant.state === state && grant.reason === reason) return;
  grant.state = state;
  grant.reason = reason;
  grant.revision++;
}
function reviewedCandidate(
  state: State & ScopedSnapshot,
  grantId: string,
  action: ScopedAction,
  candidate: ScopedCandidate,
): boolean {
  const exact = (value: ScopedCandidate) =>
    state.reviews.some((review) => review.grantId === grantId && equal(review.candidate, value));
  if (exact(candidate)) return true;
  // A checked single-parent commit may mechanically transfer its exact review
  // to publication, never to another commit or changed content/evidence.
  return (
    action === "publish-fast-forward" &&
    state.actions.some(
      (receipt) =>
        receipt.grantId === grantId &&
        receipt.action === "commit" &&
        receipt.state === "succeeded" &&
        receipt.result === candidate.head &&
        oid(receipt.result) &&
        JSON.parse(receipt.payload)[5] === true &&
        equal({ ...receipt.candidate, head: candidate.head }, candidate) &&
        exact(receipt.candidate),
    )
  );
}
const oid = (value: unknown): value is string =>
  typeof value === "string" && /^(?:[0-9a-f]{40}|[0-9a-f]{64})$/.test(value);
function effectObservation(value: unknown): asserts value is ScopedEffectObservation {
  shape(value, ["remoteHead", "capability"]);
  if (value.remoteHead !== null && !oid(value.remoteHead)) fail("invalid observed remote head");
  if (value.capability !== SCOPED_CAPABILITY) fail("unsupported scoped capability");
}
const actionPayload = (
  grantId: string,
  action: ScopedAction,
  candidate: ScopedCandidate,
  scope: JobScope,
  reviewRequired: boolean,
) => canonical(["scoped-action", grantId, action, candidate, scope, reviewRequired]);
function blockedTarget(state: State & ScopedSnapshot, scope: JobScope) {
  return state.actions.some(
    (r) => unfinished(r) && sameExecutionTarget(state.grants.find((g) => g.id === r.grantId)!.scope, scope),
  );
}
function validateScoped(state: State & ScopedSnapshot, requestIds: Set<string>) {
  if (![state.grants, state.reviews, state.actions].every(Array.isArray)) fail("invalid scoped history");
  const ids = new Set<string>();
  const origin = (token: unknown, kind: QuestionSpec["kind"], choice: string) => {
    const q = state.questions.find((q) => tokenOf(q) === token);
    if (!q || q.kind !== kind || !q.answer || q.answer.choice !== choice) fail("invalid scoped question linkage");
    const receipt = state.requests.find((r) => r.requestId === q.answer!.requestId);
    if (
      !receipt ||
      receipt.payload !== canonical(["answerScoped", token, choice, q.answer.source]) ||
      !("question" in receipt.result) ||
      !receipt.result.accepted ||
      !equal({ ...receipt.result.question, proposals: q.proposals }, q) ||
      !equal(receipt.result.question.proposals, q.proposals.slice(0, receipt.result.question.proposals.length))
    )
      fail("invalid scoped acceptance receipt");
    return q;
  };
  for (const g of state.grants) {
    shape(g, ["id", "question", "scope", "actions", "expiresAt", "revision", "state", "reason"]);
    text(g.id);
    text(g.question);
    jobScope(g.scope);
    allowedActions(g.actions);
    date(g.expiresAt);
    if (!["active", "paused", "ended"].includes(g.state) || !Number.isSafeInteger(g.revision) || g.revision < 1)
      fail("invalid grant state");
    if (g.reason !== null) text(g.reason);
    if ((g.state === "active") !== (g.reason === null)) fail("invalid grant reason");
    const q = state.questions.find((q) => tokenOf(q) === g.question);
    if (!q?.authorization) fail("missing authorization question");
    origin(g.question, "scoped-authorization", q.authorization.allowChoice);
    if (
      g.id !== `grant:${g.question}` ||
      ids.has(g.id) ||
      !equal(g.scope, q.authorization.scope) ||
      !equal(g.actions, q.authorization.actions) ||
      g.expiresAt !== q.authorization.expiresAt ||
      Date.parse(q.answer!.at) >= Date.parse(g.expiresAt)
    )
      fail("invalid grant linkage");
    ids.add(g.id);
  }
  for (const r of state.reviews) {
    shape(r, ["id", "question", "grantId", "scope", "candidate", "at"]);
    text(r.id);
    text(r.question);
    text(r.grantId);
    jobScope(r.scope);
    scopedCandidate(r.candidate);
    date(r.at);
    const q = state.questions.find((q) => tokenOf(q) === r.question);
    const g = state.grants.find((g) => g.id === r.grantId);
    if (!q?.review || !g) fail("missing review linkage");
    origin(r.question, "candidate-review", q.review.allowChoice);
    if (
      r.id !== `review:${r.question}` ||
      ids.has(r.id) ||
      q.review.grantId !== g.id ||
      !equal(r.scope, g.scope) ||
      !scopeTarget(g.scope, q.target) ||
      !equal(r.candidate, q.review.candidate) ||
      r.at !== q.answer!.at ||
      Date.parse(r.at) >= Date.parse(g.expiresAt)
    )
      fail("invalid review linkage");
    ids.add(r.id);
  }
  for (const q of state.questions) {
    if (
      q.authorization &&
      q.answer?.choice === q.authorization.allowChoice &&
      !state.grants.some((g) => g.question === tokenOf(q))
    )
      fail("missing answered grant");
    if (q.review && q.answer?.choice === q.review.allowChoice && !state.reviews.some((r) => r.question === tokenOf(q)))
      fail("missing answered review");
  }
  for (const r of state.actions) {
    shape(r, [
      "requestId",
      "payload",
      "grantId",
      "grantRevision",
      "expectedCommit",
      "remoteHead",
      "capability",
      "action",
      "candidate",
      "state",
      "result",
    ]);
    effectObservation({ remoteHead: r.remoteHead, capability: r.capability });
    text(r.requestId);
    text(r.payload);
    text(r.grantId);
    scopedCandidate(r.candidate);
    allowedActions([r.action]);
    if (r.expectedCommit !== null && (r.action !== "commit" || !oid(r.expectedCommit)))
      fail("invalid expected commit OID");
    if (!["applying", "inspect", "succeeded", "no-effect", "conflict"].includes(r.state)) fail("invalid action state");
    if (r.result !== null) text(r.result);
    if (r.state === "applying" && r.result !== null) fail("applying action has no result");
    if (requestIds.has(r.requestId)) fail("duplicate request id");
    requestIds.add(r.requestId);
    const g = state.grants.find((g) => g.id === r.grantId);
    if (
      !g ||
      !g.actions.includes(r.action) ||
      !Number.isSafeInteger(r.grantRevision) ||
      r.grantRevision < 1 ||
      r.grantRevision > g.revision
    )
      fail("invalid action grant linkage");
    let p: unknown;
    try {
      p = JSON.parse(r.payload);
    } catch {
      fail("invalid action fingerprint");
    }
    if (
      !Array.isArray(p) ||
      p.length !== 6 ||
      typeof p[5] !== "boolean" ||
      r.payload !== actionPayload(r.grantId, r.action, r.candidate, g.scope, p[5])
    )
      fail("invalid action fingerprint");
    if (r.state === "succeeded" && r.action === "commit" && (!oid(r.result) || r.result !== r.expectedCommit))
      fail("successful commit receipt needs exact prepared expected OID");
    if (p[5] && !reviewedCandidate(state, g.id, r.action, r.candidate)) fail("missing action review linkage");
  }
}

// Guard preflight must not wait for an executor or create authority files. Rename
// publication gives this reader one whole validated snapshot, or a closed failure.
export function readQuestionState(dir: string): QuestionSnapshot & ScopedSnapshot {
  let state: State;
  try {
    state = JSON.parse(readFileSync(join(dir, "questions.json"), "utf8"));
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT")
      return { version: 1, questions: [], selected: null, grants: [], reviews: [], actions: [] };
    fail("unreadable or corrupt questions.json");
  }
  validate(state);
  return {
    version: state.version,
    questions: state.questions,
    selected: state.selected,
    grants: state.grants ?? [],
    reviews: state.reviews ?? [],
    actions: state.actions ?? [],
  };
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
      let state: State;
      let raw: string;
      try {
        raw = readFileSync(join(this.dir, "questions.json"), "utf8");
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
        raw = JSON.stringify({ version: 1, questions: [], selected: null, requests: [] });
      }
      try {
        state = JSON.parse(raw);
        validate(state);
      } catch {
        fail("corrupt questions.json; restore it before continuing (not overwritten)");
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
          renameSync(temp, join(this.dir, "questions.json"));
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
      if (state.actions?.some((r) => r.requestId === requestId)) fail("request id reused with different payload");
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

  create<T>(requestId: string, intent: T, resolveSpec: (intent: T) => QuestionSpec): Question {
    return this.request(requestId, ["create", intent], (state) => {
      const fields = resolveSpec(intent);
      spec(fields);
      if (typed(fields)) upgrade(state);
      const id = `Q${state.questions.reduce((max, q) => Math.max(max, Number(q.id.slice(1))), 0) + 1}`;
      const q: Question = {
        ...structuredClone(fields),
        id,
        revision: 1,
        status: "pending",
        createdAt: new Date().toISOString(),
        proposals: [],
      };
      state.questions.push(q);
      return q;
    });
  }

  revise<T>(requestId: string, token: string, intent: T, resolveSpec: (intent: T) => QuestionSpec): Question {
    return this.request(requestId, ["revise", token, intent], (state) => {
      const fields = resolveSpec(intent);
      spec(fields);
      if (typed(fields)) upgrade(state);
      const previous = this.find(state, token);
      if (previous.status !== "pending") fail("stale or closed question revision");
      if (!sameScope(previous, fields)) fail("revision cannot change repo, issue or topic; create a new question");
      previous.status = "superseded";
      const q: Question = {
        ...structuredClone(fields),
        id: previous.id,
        revision: previous.revision + 1,
        status: "pending",
        createdAt: new Date().toISOString(),
        proposals: [],
      };
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
  // moot) leaves the panel and can never be answered. It records no answer and no event.
  withdraw(requestId: string, token: string, reason: string): Question {
    text(reason);
    return this.request(requestId, ["withdraw", token, reason], (state) => {
      const q = this.find(state, token);
      if (q.status !== "pending") fail(`question is ${q.status}; only a pending question can be withdrawn`);
      q.status = "withdrawn";
      q.withdrawal = { requestId, reason, at: new Date().toISOString() };
      return q;
    });
  }

  scopedSnapshot(): ScopedSnapshot {
    return this.locked((state) => ({
      grants: state.grants ?? [],
      reviews: state.reviews ?? [],
      actions: state.actions ?? [],
    }));
  }

  // Only the supported picker calls this seam. The resolver is a short local
  // recheck under the ledger lock, never a network call or an identity claim.
  answerScoped(
    requestId: string,
    token: string,
    choice: string,
    source: QuestionAnswer["source"],
    resolve: () => ScopedAnswerCheck,
  ): AnswerResult {
    text(choice);
    if (!ANSWER_SOURCES.includes(source)) fail("unknown answer source");
    return this.request(requestId, ["answerScoped", token, choice, source], (state) => {
      const q = this.find(state, token);
      const reject = (reason: string): AnswerResult => ({ question: q, accepted: false, reason });
      if (!typed(q)) return reject("not a scoped question");
      if (q.status !== "pending") return reject(`question is ${q.status}`);
      if (!q.options.includes(choice)) return reject("not one of the question's choices");
      const check = resolve();
      shape(check, [
        "status",
        "reasons",
        "current",
        ...optional((check ?? {}) as unknown as Record<string, unknown>, ["scope", "candidate"]),
      ]);
      if (
        typeof check?.status !== "string" ||
        !Array.isArray(check.reasons) ||
        check.reasons.some((reason) => typeof reason !== "string")
      )
        fail("invalid scoped check");
      if (check.status !== "fresh" || !check.current)
        return reject(`changed since Shep asked: ${check.reasons.join(", ") || "not checked"}`);
      shape(check.current, ["head", "stagedTree"]);
      for (const key of ["head", "stagedTree"] as const) if (check.current[key] !== null) text(check.current[key]);
      if (check.scope !== undefined) jobScope(check.scope);
      if (check.candidate !== undefined) scopedCandidate(check.candidate);
      const at = new Date().toISOString();
      let grant: ScopedGrant | undefined;
      if (q.authorization) {
        if (Date.parse(at) >= Date.parse(q.authorization.expiresAt)) return reject("scoped question expired");
        if (!check.scope || !equal(check.scope, q.authorization.scope)) return reject("scope changed or unavailable");
      } else {
        grant = state.grants?.find((g) => g.id === q.review!.grantId);
        if (!grant || grant.state !== "active" || Date.parse(at) >= Date.parse(grant.expiresAt))
          return reject("grant unavailable or expired");
        if (!check.scope || !equal(check.scope, grant.scope) || !scopeTarget(grant.scope, q.target))
          return reject("scope changed or unavailable");
        if (
          !check.candidate ||
          !equal(check.candidate, q.review!.candidate) ||
          check.current.head !== check.candidate.head ||
          check.current.stagedTree !== check.candidate.tree
        )
          return reject("candidate changed or unavailable");
      }
      q.status = "answered";
      q.answer = { requestId, choice, source, at, head: check.current.head, stagedTree: check.current.stagedTree };
      upgrade(state);
      if (q.authorization && choice === q.authorization.allowChoice) {
        state.grants.push({
          id: `grant:${token}`,
          question: token,
          scope: structuredClone(q.authorization.scope),
          actions: [...q.authorization.actions],
          expiresAt: q.authorization.expiresAt,
          revision: 1,
          state: "active",
          reason: null,
        });
      } else if (q.review && choice === q.review.allowChoice) {
        state.reviews.push({
          id: `review:${token}`,
          question: token,
          grantId: grant!.id,
          scope: structuredClone(grant!.scope),
          candidate: structuredClone(q.review.candidate),
          at,
        });
      }
      return { question: q, accepted: true };
    });
  }

  beginScopedAction(
    requestId: string,
    grantId: string,
    action: ScopedAction,
    candidate: ScopedCandidate,
    scope: JobScope,
    now: () => string,
    reviewRequired: boolean,
    observation: ScopedEffectObservation,
  ): ScopedActionReceipt & { duplicate: boolean } {
    text(requestId);
    text(grantId);
    allowedActions([action]);
    scopedCandidate(candidate);
    jobScope(scope);
    if (typeof now !== "function") fail("live clock callback required");
    if (typeof reviewRequired !== "boolean") fail("explicit review requirement needed");
    effectObservation(observation);
    const outcome = this.locked((state): { error: string } | (ScopedActionReceipt & { duplicate: boolean }) => {
      if (state.requests.some((r) => r.requestId === requestId)) fail("request id reused with different payload");
      const old = state.actions?.find((r) => r.requestId === requestId);
      if (old) {
        if (old.payload !== actionPayload(grantId, action, candidate, scope, reviewRequired))
          fail("request id reused with different payload");
        // Unfinished duplicates are inspection requests, never permission to replay.
        if (old.state === "applying") old.state = "inspect";
        return { ...old, duplicate: true };
      }
      const grant = state.grants?.find((g) => g.id === grantId);
      if (!grant || grant.state === "ended") return { error: "grant unavailable or ended" };
      const at = now();
      date(at);
      if (Date.parse(at) >= Date.parse(grant.expiresAt)) {
        transition(grant, "ended", "expired");
        return { error: "grant expired" };
      }
      if (!equal(grant.scope, scope)) {
        transition(grant, "ended", "scope changed");
        return { error: "grant scope changed" };
      }
      if (grant.state !== "active") return { error: "grant paused" };
      if (!grant.actions.includes(action)) return { error: "action outside grant" };
      const scoped = state as State & ScopedSnapshot;
      if (blockedTarget(scoped, scope)) return { error: "unfinished action requires inspection" };
      if (reviewRequired && !reviewedCandidate(scoped, grantId, action, candidate))
        return { error: "fresh exact candidate review required" };
      const receipt: ScopedActionReceipt = {
        requestId,
        payload: actionPayload(grantId, action, candidate, scope, reviewRequired),
        grantId,
        grantRevision: grant.revision,
        expectedCommit: null,
        remoteHead: observation.remoteHead,
        capability: observation.capability,
        action,
        candidate: structuredClone(candidate),
        state: "applying",
        result: null,
      };
      scoped.actions.push(receipt);
      return { ...receipt, duplicate: false };
    }, true);
    if ("error" in outcome) fail(outcome.error);
    return outcome;
  }

  // The executor verifies the detached commit before recording its immutable OID,
  // and records it before the feature-ref CAS so recovery cannot bless a lookalike.
  prepareScopedCommit(requestId: string, expectedCommit: string): ScopedActionReceipt {
    text(requestId);
    if (!oid(expectedCommit)) fail("full expected commit OID required");
    return this.locked((ledger) => {
      const receipt = ledger.actions?.find((r) => r.requestId === requestId) ?? fail("unknown action request");
      if (receipt.action !== "commit" || !unfinished(receipt)) fail("only an unfinished commit can be prepared");
      if (receipt.expectedCommit !== null && receipt.expectedCommit !== expectedCommit)
        fail("expected commit OID is immutable");
      receipt.expectedCommit = expectedCommit;
      return receipt;
    }, true);
  }

  endScopedAction(
    requestId: string,
    state: Exclude<ScopedActionState, "applying">,
    result: string | null,
  ): ScopedActionReceipt {
    text(requestId);
    if (!["inspect", "succeeded", "no-effect", "conflict"].includes(state)) fail("invalid action completion state");
    if (result !== null) text(result);
    return this.locked((ledger) => {
      const receipt = ledger.actions?.find((r) => r.requestId === requestId) ?? fail("unknown action request");
      if (!unfinished(receipt)) {
        if (receipt.state !== state || receipt.result !== result) fail("terminal receipt cannot change");
        return receipt;
      }
      if (state === "succeeded" && receipt.action === "commit" && (!oid(result) || result !== receipt.expectedCommit))
        fail("successful commit receipt needs exact prepared expected OID");
      receipt.state = state;
      receipt.result = result;
      if (state === "conflict")
        transition(
          ledger.grants!.find((g) => g.id === receipt.grantId)!,
          "ended",
          result ?? "action conflict",
        );
      return receipt;
    }, true);
  }

  revokeGrant(id: string, reason: string): ScopedGrant {
    text(id);
    text(reason);
    return this.locked((state) => {
      const grant = state.grants?.find((g) => g.id === id) ?? fail("unknown grant");
      if (grant.state !== "ended") transition(grant, "ended", reason);
      return grant;
    }, true);
  }

  pauseGrant(id: string, reason: string): ScopedGrant {
    text(id);
    text(reason);
    return this.locked((state) => {
      const grant = state.grants?.find((g) => g.id === id) ?? fail("unknown grant");
      if (grant.state === "ended") fail("grant ended");
      transition(grant, "paused", reason);
      return grant;
    }, true);
  }

  resumeGrant(id: string, scope: JobScope, now: () => string): ScopedGrant {
    text(id);
    jobScope(scope);
    if (typeof now !== "function") fail("live clock callback required");
    return this.locked((state) => {
      const grant = state.grants?.find((g) => g.id === id) ?? fail("unknown grant");
      if (grant.state === "ended") fail("grant ended");
      const at = now();
      date(at);
      if (Date.parse(at) >= Date.parse(grant.expiresAt)) transition(grant, "ended", "expired");
      else if (!equal(grant.scope, scope)) transition(grant, "ended", "scope changed");
      else {
        if (blockedTarget(state as State & ScopedSnapshot, scope)) fail("unfinished action requires inspection");
        transition(grant, "active", null);
      }
      return grant;
    }, true);
  }

  // The person's pick: once per revision, one of its options, and only when the live
  // check the caller ran just before found the candidate unchanged (fresh). A local
  // user-owned record, not proof of who picked (docs/shep.md, "Answering").
  answer(
    requestId: string,
    token: string,
    choice: string,
    source: QuestionAnswer["source"],
    check: { status: string; reasons: string[]; current: Pick<QuestionTarget, "head" | "stagedTree"> | null },
  ): AnswerResult {
    if (!ANSWER_SOURCES.includes(source)) fail("unknown answer source");
    text(choice);
    return this.request(requestId, ["answer", token, choice, source], (state) => {
      const q = this.find(state, token);
      const reason = typed(q)
        ? "typed questions require the trusted scoped picker path"
        : q.status !== "pending"
          ? `question is ${q.status}`
          : !q.options.includes(choice)
            ? "not one of the question's choices"
            : check.status !== "fresh" || !check.current
              ? `changed since Shep asked: ${check.reasons.join(", ") || "not checked"}`
              : undefined;
      if (reason) return { question: q, accepted: false, reason };
      q.status = "answered";
      q.answer = {
        requestId,
        choice,
        source,
        at: new Date().toISOString(),
        head: check.current!.head,
        stagedTree: check.current!.stagedTree,
      };
      return { question: q, accepted: true };
    });
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
    const row = `${tokenOf(q)} [${q.kind}] ${line(q.prompt, 160)} | options=${line(q.options.join(" / "), 100)} | ${target} | proposed=${line(answer ?? "none", 100)} (${q.proposals.length} unverified proposals)`;
    if (lines.join("\n").length + row.length > 15500) break;
    lines.push(row);
  }
  lines.push(
    `${pending.length} pending; ${pending.length - lines.length + 1} omitted. Reply with /reply Qn@revision answer; bare replies never select a target.`,
    "Shortened fields end in …; full targets and history: bercail shep questions --json.",
  );
  // The person's picks, newest first: the record of an answer, whatever became of its event.
  const answered = snapshot.questions
    .filter((q) => q.answer)
    .sort((a, b) => b.answer!.at.localeCompare(a.answer!.at))
    .slice(0, 10);
  if (answered.length) {
    lines.push("Answered by the person's pick (a local record, not proof of identity; act on it once):");
    for (const q of answered)
      lines.push(
        `${tokenOf(q)} ${line(q.prompt, 120)} -> ${line(q.answer!.choice, 80)} (${q.answer!.source}, ${q.answer!.at}) topic=${line(q.target.topic, 64)}`,
      );
  }
  return lines.join("\n");
}
