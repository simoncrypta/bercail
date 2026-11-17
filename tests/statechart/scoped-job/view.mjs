export const title = "Scoped job authority: grants are not candidate reviews";
export const state = (v) => {
  if (v.grant === "none") return v.preflight;
  if (!v.verified) return "Unauthorized grant";
  if (!v.startReviewed) return "Stale review used";
  if (v.executions > 1) return "Publication replayed";
  if (v.receipt === "inspect") return `${v.grant}: inspect outcome`;
  if (v.receipt === "applying") return `${v.grant}: applying`;
  if (v.grant !== "active") return v.grant;
  return v.preflight === "ordinary" || v.review === v.candidate ? "Active: ready" : "Active: needs review";
};
export const step = (action, _from, to) =>
  ({
    Start: "Caller 1 starts",
    Finish:
      to.receipt === "no-effect"
        ? "Quiescent no effect"
        : to.receipt === "conflict"
          ? "Conflict proven"
          : "Verified success",
    DeniedStart: "Grant denied",
    NoGrantBlocked: "No grant",
    ResumeBlocked: "Target quarantined",
    EndedCannotResume: "Cannot revive",
    PreflightSupported: "Feasible: review",
    PreflightOrdinary: "Feasible: ordinary",
    PreflightBlocked: "Unsupported",
    ExplicitStageOnly: "Stage-only pick",
    SupportedPick: "Explicit pick",
    ForgedIngress: "Forged input",
    ReviewPick: "Candidate LGTM",
    CandidateChanges: "Candidate changes",
    Pause: "Facts unavailable",
    Resume: "Same facts proven",
    Revoke: "Revoke",
    ExpireAtStart: "Expired at start",
    OwnershipChanges: "Owner changes",
    StartCallerTwo: "Caller 2 starts",
    SecondCallerBlocked: "Target quarantined",
    StaleReviewBlocked: "Review required",
    PayloadMismatchBlocked: "Payload rejected",
    DuplicateRequest: "Duplicate request",
    Timeout: "Response lost",
    Restart: "Process restarts",
    InspectUnavailable: "Still unknown",
    ReplayAfterTimeout: "Resend uncertain",
    Idle: "No action",
  })[action] ?? action;
