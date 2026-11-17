import type { QuestionTarget } from "./questions.ts";

export type ScopedAction = "commit" | "publish-fast-forward";
export interface JobScope {
  repo: string;
  worktree: string;
  issue: string;
  pr: string;
  headRef: string;
  baseRef: string;
  baseOid: string;
  remote: string;
  endpoint: string;
  backend: string;
  desk: string;
  space: string;
  session: string;
  owner: string;
  mapping: string;
  policy: string;
}
export interface ScopedGrant {
  id: string;
  question: string;
  scope: JobScope;
  actions: ScopedAction[];
  expiresAt: string;
  revision: number;
  state: "active" | "paused" | "ended";
  reason: string | null;
}
export interface ScopedCandidate {
  head: string;
  tree: string;
  base: string;
  description: string;
  evidence: string;
}
export interface ScopedAuthorization {
  scope: JobScope;
  actions: ScopedAction[];
  expiresAt: string;
  allowChoice: string;
  stageOnlyChoice: string;
}
export interface CandidateReviewSpec {
  grantId: string;
  candidate: ScopedCandidate;
  allowChoice: string;
}
export interface ScopedReview {
  id: string;
  question: string;
  grantId: string;
  scope: JobScope;
  candidate: ScopedCandidate;
  at: string;
}
export type ScopedActionState = "applying" | "inspect" | "succeeded" | "no-effect" | "conflict";
export const SCOPED_CAPABILITY = "gh-single-ref-fast-forward/v1";
export interface ScopedEffectObservation {
  remoteHead: string | null;
  capability: string;
}
export interface ScopedActionReceipt extends ScopedEffectObservation {
  requestId: string;
  payload: string;
  grantId: string;
  grantRevision: number;
  expectedCommit: string | null;
  action: ScopedAction;
  candidate: ScopedCandidate;
  state: ScopedActionState;
  result: string | null;
}
export interface ScopedSnapshot {
  grants: ScopedGrant[];
  reviews: ScopedReview[];
  actions: ScopedActionReceipt[];
}
export interface ScopedAnswerCheck {
  status: string;
  reasons: string[];
  current: Pick<QuestionTarget, "head" | "stagedTree"> | null;
  scope?: JobScope;
  candidate?: ScopedCandidate;
}
