import { captureTarget } from "./question-target.ts";
import { QuestionStore, tokenOf, type Question, type QuestionSpec } from "./questions.ts";
import { captureCandidate, captureJobScope, refreshJobScope, ScopeError } from "./scoped-target.ts";
import type { ScopedAction, ScopedAnswerCheck } from "./scoped-types.ts";

export interface ScopedQuestionInput {
  kind: "scoped-authorization" | "candidate-review";
  repo: string;
  issue: string;
  topic: string;
  desk: string;
  base: string;
  pr: string;
  remote: string;
  actions?: ScopedAction[];
  expiresAt?: string;
  grantId?: string;
  origin: QuestionSpec["origin"];
}

// Scope and candidate come from the resolver, never a caller's displayed claims.
export function scopedQuestionSpec(store: QuestionStore, input: ScopedQuestionInput): QuestionSpec {
  const { repo, issue, topic, desk, base, pr, remote } = input;
  const scope = captureJobScope({ repo, issue, topic, desk, base, pr, remote });
  const target = captureTarget({
    ...input,
    base: scope.baseRef,
    kind: input.kind === "scoped-authorization" ? "planning" : "review",
    action: "scoped job authorization",
  });
  if (input.kind === "scoped-authorization") {
    if (!input.actions?.length || !input.expiresAt) throw new Error("Scoped question needs actions and an expiry");
    const expiresAt = new Date(input.expiresAt).toISOString();
    const allowChoice = `Allow ${input.actions.join(" and ")} until ${expiresAt}`;
    const stageOnlyChoice = "Stage only; no commits or publication";
    return {
      kind: input.kind,
      prompt: `Authorize ${scope.issue} on ${scope.pr}?`,
      brief: `Only the listed actions and exact bindings below. No rewrite, other refs, hooks bypass or release. Candidate review stays separate.\n${JSON.stringify(scope)}\nActions: ${input.actions.join(", ")}. Expires: ${expiresAt}.`,
      options: [allowChoice, stageOnlyChoice, "Decline"],
      origin: input.origin,
      target,
      authorization: { scope, actions: input.actions, expiresAt, allowChoice, stageOnlyChoice },
    };
  }
  const grant = store.scopedSnapshot().grants.find((g) => g.id === input.grantId);
  if (
    !grant ||
    grant.state !== "active" ||
    Object.keys(scope).some((k) => grant.scope[k as keyof typeof scope] !== scope[k as keyof typeof scope])
  )
    throw new Error("Candidate review needs the active grant's identical live scope");
  const { candidate } = captureCandidate(scope);
  const allowChoice = "LGTM for this exact candidate only";
  return {
    kind: input.kind,
    prompt: `Review candidate for ${scope.issue} on ${scope.pr}?`,
    brief: `This review grants no new actions. Changed content, base, description or evidence requires another review.\n${JSON.stringify({ grantId: grant.id, scope, candidate })}`,
    options: [allowChoice, "Not approved"],
    origin: input.origin,
    target,
    review: { grantId: grant.id, candidate, allowChoice },
  };
}

export async function checkScopedQuestion(question: Question, state?: string) {
  const reasons: string[] = [];
  const check: ScopedAnswerCheck = { status: "unavailable", reasons, current: null };
  if (question.status !== "pending") reasons.push(`question is ${question.status}`);
  try {
    const target = question.target;
    if (!target.worktree || !target.issue || !target.desk || !target.baseRef)
      throw new Error("incomplete scoped target");
    if (!state) throw new Error("question state unavailable");
    const store = new QuestionStore(state);
    const grants = store.scopedSnapshot().grants;
    // A review uses its grant, not a caller-supplied scope or historical answer scan.
    const grant = grants.find((g) =>
      question.review ? g.id === question.review.grantId : g.question === tokenOf(question),
    );
    const expected = question.authorization?.scope ?? grant?.scope;
    const invalidate = (reason: string) => {
      if (grant) store.revokeGrant(grant.id, reason);
      if (store.snapshot().questions.find((q) => tokenOf(q) === tokenOf(question))?.status === "pending")
        store.withdraw(`stale-scoped:${tokenOf(question)}`, tokenOf(question), reason);
    };
    if (!expected) throw new Error("scoped authority unavailable");
    if (grant && (grant.state !== "active" || Date.parse(grant.expiresAt) <= Date.now()))
      reasons.push("grant is not active or has expired");
    let scope;
    try {
      scope = refreshJobScope(expected);
    } catch (error) {
      if (error instanceof ScopeError && error.disposition === "ended") invalidate(error.message);
      else if (grant) store.pauseGrant(grant.id, (error as Error).message);
      throw error;
    }
    check.scope = scope;
    if (question.authorization && Date.parse(question.authorization.expiresAt) <= Date.now())
      reasons.push("authorization question expired");
    if (question.review) {
      let captured;
      try {
        captured = captureCandidate(scope);
      } catch (error) {
        if (error instanceof ScopeError) {
          if (error.disposition === "ended") invalidate(error.message);
          else if (grant) store.pauseGrant(grant.id, error.message);
        }
        throw error;
      }
      const { candidate } = captured;
      for (const key of Object.keys(question.review.candidate) as (keyof typeof candidate)[])
        if (candidate[key] !== question.review.candidate[key]) reasons.push(`${key} changed`);
      check.candidate = candidate;
      check.current = { head: candidate.head, stagedTree: candidate.tree };
    } else check.current = { head: null, stagedTree: null };
    check.status = reasons.length ? "stale" : "fresh";
  } catch (error) {
    reasons.push(`target unavailable: ${(error as Error).message}`);
  }
  return { ...check, token: tokenOf(question), fresh: check.status === "fresh", authority: false as const };
}
