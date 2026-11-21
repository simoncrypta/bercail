import { spawnSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { closeSync, fsyncSync, mkdirSync, openSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { isAbsolute, join, normalize } from "node:path";
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
  kind: "planning" | "review" | "action";
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
}
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
export interface QuestionAnswer {
  requestId: string;
  choice: string;
  source: (typeof ANSWER_SOURCES)[number] | typeof DEFAULT_SOURCE;
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
    ...optional(v ?? {}, ["brief", "recommendation", "reversible", "push"]),
  ]);
  if (!["planning", "review", "action"].includes(value.kind as string)) fail("invalid kind");
  text(value.prompt);
  if (!Array.isArray(value.options)) fail("invalid options");
  value.options.forEach(text);
  if (value.brief !== undefined) text(value.brief);
  if (value.recommendation !== undefined) {
    shape(value.recommendation, ["choice", "why"]);
    text(value.recommendation.why);
    if (!value.options.includes(value.recommendation.choice)) fail("recommendation must be one of the options");
  }
  if (value.reversible !== undefined && value.reversible !== true) fail("reversible is true or absent");
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
  shape(value.target, [...keys, ...optional(value.target as Record<string, unknown>, ["branch", "trailId", "url"])]);
  if (value.target.branch != null) text(value.target.branch);
  if (value.target.trailId !== undefined) text(value.target.trailId);
  if (value.target.url !== undefined) text(value.target.url);
  // The desk is optional for every kind: a question binds to its repo and issue.
  const desk = ["desk", "space", "session"];
  for (const key of keys)
    if (
      value.target[key] !== null ||
      (value.kind !== "planning" && !desk.includes(key)) ||
      key === "repo" ||
      key === "topic"
    )
      text(value.target[key]);
  const repo = value.target.repo as string;
  if (!isAbsolute(repo) || normalize(repo) !== repo)
    fail("repo must be a canonical absolute identity path supplied by the caller");
  if (value.target.worktree !== null && !isAbsolute(value.target.worktree as string)) fail("worktree must be absolute");
  if (value.push !== undefined) push(value as unknown as QuestionSpec);
}
// The guard matches these as they are written in the command (guard.ts hashRefspec).
const refName = /^refs\/(heads|tags)\/[\w./-]+$/;
// A push approval: one of the choices, on a question that binds to a commit, never a
// default, with a tag only on a release question.
function push(value: QuestionSpec) {
  const p = value.push;
  shape(p, ["approves", "remote", "refs", "url"]);
  if (!value.options.includes(p.approves as string)) fail("push.approves must be one of the options");
  if (value.kind === "planning") fail("a planning question binds to no commit, so it cannot approve a push");
  if (value.reversible) fail("a push is a one-way door: ask it without reversible");
  text(p.remote);
  if (!/^[A-Za-z0-9][\w.-]*$/.test(p.remote as string)) fail("push.remote must be the remote's name");
  text(p.url);
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
      "deadline",
      "told",
      "answer",
      "settled",
      "withdrawal",
      "pushed",
    ]),
  ]);
  const { id, revision, status, createdAt, deadline, told, proposals, answer, settled, withdrawal, pushed, ...fields } =
    value;
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
  if (deadline !== undefined) {
    text(deadline);
    if (!fields.reversible || !fields.recommendation || !(Date.parse(deadline) > Date.parse(createdAt)))
      fail("only a reversible question with a recommendation has a deadline, after it was asked");
  }
  if (told !== undefined && (told !== true || (answer as QuestionAnswer | undefined)?.source !== DEFAULT_SOURCE))
    fail("only a default is told");
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
  // A default Shep withdrew (moot, or its reversal handled) keeps its record.
  const kept =
    status === "withdrawn" &&
    (answer as QuestionAnswer | undefined)?.source === DEFAULT_SOURCE &&
    (settled as QuestionSettlement | undefined)?.outcome !== "ok";
  if (status === "answered" ? answer === undefined : answer !== undefined && !kept)
    fail("an answered question needs its answer, and only it");
  if (answer !== undefined) {
    shape(answer, ["requestId", "choice", "source", "at", "head", "stagedTree"]);
    text(answer.requestId);
    text(answer.at);
    if (!fields.options.includes(answer.choice as string)) fail("answer is not one of the options");
    if (answer.source === DEFAULT_SOURCE) {
      if (
        deadline === undefined ||
        answer.choice !== fields.recommendation?.choice ||
        Date.parse(answer.at as string) < Date.parse(deadline as string)
      )
        fail("a default is the recommendation, taken at or after the deadline");
    } else if (!ANSWER_SOURCES.includes(answer.source as (typeof ANSWER_SOURCES)[number]))
      fail("unknown answer source");
    for (const key of ["head", "stagedTree"]) if (answer[key] !== null) text(answer[key]);
    if (!Number.isFinite(Date.parse(answer.at as string))) fail("invalid answer time");
  }
  if (settled !== undefined) {
    const a = answer as QuestionAnswer | undefined;
    if (a?.source !== DEFAULT_SOURCE) fail("only a default is settled");
    shape(settled, [
      "requestId",
      "outcome",
      "choice",
      "source",
      "at",
      "head",
      "stagedTree",
      ...optional(settled as Record<string, unknown>, ["told"]),
    ]);
    text(settled.requestId);
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
    for (const key of ["head", "stagedTree"]) if (settled[key] !== null) text(settled[key]);
    if (!(Date.parse(settled.at as string) >= Date.parse(a.at))) fail("invalid settlement time");
  }
  if ((status === "withdrawn") !== (withdrawal !== undefined))
    fail("a withdrawn question needs its withdrawal, and only it");
  if (withdrawal !== undefined) {
    shape(withdrawal, ["requestId", "reason", "at"]);
    text(withdrawal.requestId);
    text(withdrawal.reason);
    if (!Number.isFinite(Date.parse(withdrawal.at as string))) fail("invalid withdrawal time");
  }
  if (pushed !== undefined) {
    const a = answer as QuestionAnswer | undefined;
    if (!fields.push || !a || a.choice !== fields.push.approves)
      fail("only the person's approving answer is claimed by a push");
    shape(pushed, ["at", "remote", "refspecs"]);
    const refs = Array.isArray(pushed.refspecs) ? pushed.refspecs.map((spec) => String(spec).split(":")[1]) : [];
    if (
      !Number.isFinite(Date.parse(pushed.at as string)) ||
      pushed.remote !== fields.push.remote ||
      canonical(refs.sort()) !== canonical([...fields.push.refs].sort())
    )
      fail("a push claim names the approved remote and refs");
  }
}
function validate(value: unknown): asserts value is State {
  shape(value, ["version", "questions", "selected", "requests"]);
  if (value.version !== 1 || !Array.isArray(value.questions) || !Array.isArray(value.requests))
    fail("invalid state version or history");
  if (value.selected !== null) text(value.selected);
  const latest = new Map<string, Question>();
  for (const q of value.questions) {
    question(q);
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
}
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
// table. An action question's action is its effect, from a closed set: commit, or
// merge/land; the helper captured its candidate. A planning pick has no action. The
// prompt, choices and brief can only make it stricter: a one-way word there wins, and
// so does a merge or commit word without that action. What no row names is one-way.
export type Door = { door: "one-way" | "two-way"; row: string; hit: string };
const ONE_WAY: [string, RegExp][] = [
  ["force push", /\bforce[- ]?push\w*|--force\b|\bpush\b[^\n]*\s-f\b/i],
  [
    "publishing to a forge",
    /\b(push|pushes|pushed|pushing|submit|submits|submitted|publish|publishes|published|publishing|trail|trails|pull request)\b/i,
  ],
  ["an LGTM or approval", /\b(lgtm|approve|approves|approved|approval|reviewed-by)\b/i],
  ["a release or tag", /\b(release|releases|released|releasing|tag|tags|tagged|tagging|ship|ships|shipped)\b/i],
  [
    "a deletion",
    /\b(delete|deletes|deleted|deleting|deletion|remove|removes|removed|removing|rm|clean|cleans|cleaned|destroy|destroys|destroyed|wipe|wipes|wiped|purge|purges|purged|reset|prune)\b/i,
  ],
  [
    "money",
    /[$€£]|\b(money|pay|pays|paid|paying|payment|purchase|purchases|purchased|buy|buys|bought|spend|spends|spent|spending|refund|invoice|billing|subscription)\b/i,
  ],
  [
    "an outward post",
    /\b(post|posts|posted|posting|tweet|tweets|email|emails|emailed|announce|announces|announced|comment|comments|commented|send|sends|sending|reply|replies)\b/i,
  ],
  ["a device or deploy action", /\b(device|devices|deploy|deploys|deployed|deploying|deployment)\b/i],
];
const MERGE = /\b(merge|merges|merged|merging|land|lands|landed|landing)\b/i;
const COMMIT = /\b(commit|commits|committed|committing)\b/i;
const ACTIONS = new Set(["commit", "merge", "land"]);
// mergeReversible: whether the repo's trusted policy says merge_reversible = true;
// asked only for a merge or land.
export function door(
  q: Pick<QuestionSpec, "kind" | "prompt" | "options" | "brief" | "target">,
  mergeReversible: () => boolean,
): Door {
  if (q.kind === "review") return { door: "one-way", row: "an LGTM", hit: "a review question" };
  const words = [q.prompt, ...q.options, q.brief ?? ""].join("\n");
  for (const [row, pattern] of ONE_WAY) {
    const hit = pattern.exec(words);
    if (hit) return { door: "one-way", row, hit: hit[0] };
  }
  const action = q.target.action;
  if (action !== null && (q.kind !== "action" || !ACTIONS.has(action)))
    return { door: "one-way", row: "an action no two-way row names", hit: action };
  const merge = MERGE.exec(words)?.[0];
  if (merge && action !== "merge" && action !== "land")
    return { door: "one-way", row: "a merge asked without action merge or land", hit: merge };
  const commit = COMMIT.exec(words)?.[0];
  if (commit && action !== "commit")
    return { door: "one-way", row: "a commit asked without action commit", hit: commit };
  if (action === "merge" || action === "land")
    return mergeReversible()
      ? { door: "two-way", row: "a merge where the policy says merge_reversible", hit: action }
      : { door: "one-way", row: "a merge where the policy does not say merge_reversible", hit: action };
  return action === "commit"
    ? { door: "two-way", row: "a local commit", hit: action }
    : { door: "two-way", row: "a planning pick", hit: q.prompt };
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
  // and the Reverse, and records no answer and no event.
  withdraw(requestId: string, token: string, reason: string): Question {
    text(reason);
    return this.request(requestId, ["withdraw", token, reason], (state) => {
      const q = this.find(state, token);
      const open = q.status === "pending" || (q.answer?.source === DEFAULT_SOURCE && q.settled?.outcome !== "ok");
      if (!open || q.status === "withdrawn")
        fail(
          `question is ${q.status}; only a pending question, or a default without the person's OK, can be withdrawn`,
        );
      q.status = "withdrawn";
      q.withdrawal = { requestId, reason, at: new Date().toISOString() };
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
      const reason =
        q.status !== "pending"
          ? `question is ${q.status}`
          : !q.options.includes(choice)
            ? "not one of the question's choices"
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
        head: check.current!.head,
        stagedTree: check.current!.stagedTree,
      };
      return { question: q, accepted: true };
    });
  }

  // The deadline passed with no pick: the ledger, not Shep, records Shep's
  // recommendation as DEFAULT_SOURCE, once, and only when the live check the caller
  // ran just before found the question unchanged and, with the policy it read, still
  // a two-way door. The caller checks a due question.
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

  // The decision event of its default, or of the person's OK or Reverse on it, is
  // written: the caller wrote it, or found it there.
  told(token: string, which: "default" | "settled" = "default"): void {
    this.locked((state) => {
      const q = this.find(state, token);
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
    "Shortened fields end in …; full targets and history: bercail shep questions --json.",
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
