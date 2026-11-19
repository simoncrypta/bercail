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
  shape(value, ["kind", "prompt", "options", "origin", "target", ...optional(v ?? {}, ["brief", "recommendation"])]);
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
    if (value.target[key] !== null || value.kind !== "planning" || key === "repo" || key === "topic")
      text(value.target[key]);
  const repo = value.target.repo as string;
  if (!isAbsolute(repo) || normalize(repo) !== repo)
    fail("repo must be a canonical absolute identity path supplied by the caller");
  if (value.target.worktree !== null && !isAbsolute(value.target.worktree as string)) fail("worktree must be absolute");
}
function question(value: unknown): asserts value is Question {
  const v = value as Record<string, unknown>;
  const keys = ["id", "revision", "status", "createdAt", "proposals", "kind", "prompt", "options", "origin", "target"];
  shape(value, [...keys, ...optional(v ?? {}, ["brief", "recommendation", "answer", "withdrawal"])]);
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

  create<T>(requestId: string, intent: T, resolveSpec: (intent: T) => QuestionSpec): Question {
    return this.request(requestId, ["create", intent], (state) => {
      const fields = resolveSpec(intent);
      spec(fields);
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
      const reason =
        q.status !== "pending"
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
