---------------------------- MODULE ScopedJob ----------------------------
EXTENDS Naturals, TLC
\* Accepted bercail-qsoa lifecycle, Q55@1; implementation baseline
\* 4d59ff54b513d656f05b6ae5900ee3e7f278dd0f plus questions.ts/scoped-types.ts.
\* Durable grant, candidate review and action receipt are independent records.
\* The resolver/picker and execution lock are environment boundaries, NOT an
\* authentication proof or proof of remote fast-forward/endpoint enforcement.
\* One grant, one request, two candidates/callers. No automatic renewal,
\* review carry-forward, actual Git/network effects, unmanaged writers, or
\* eventual progress assumptions: remote inspection may remain unavailable.
CONSTANTS MaxCandidate, WithRaces, BugIngress, BugStaleReview, BugReplay
VARIABLES preflight, grant, verified, candidate, review, expired, owner,
          receipt, payloadCandidate, lock, executions, startAllowed, startReviewed
vars == <<preflight, grant, verified, candidate, review, expired, owner,
          receipt, payloadCandidate, lock, executions, startAllowed, startReviewed>>

Init == /\ preflight = "unchecked" /\ grant = "none" /\ verified = FALSE
        /\ candidate = 1 /\ review = 0 /\ expired = FALSE /\ owner = 1
        /\ receipt = "none" /\ payloadCandidate = 0 /\ lock = 0
        /\ executions = 0 /\ startAllowed = TRUE /\ startReviewed = TRUE

PreflightSupported == /\ preflight = "unchecked" /\ preflight' = "pending"
  /\ UNCHANGED <<grant, verified, candidate, review, expired, owner, receipt,
                  payloadCandidate, lock, executions, startAllowed, startReviewed>>
PreflightOrdinary == /\ preflight = "unchecked" /\ preflight' = "ordinary"
  /\ UNCHANGED <<grant, verified, candidate, review, expired, owner, receipt,
                  payloadCandidate, lock, executions, startAllowed, startReviewed>>
PreflightBlocked == /\ preflight = "unchecked" /\ preflight' = "blocked"
  /\ UNCHANGED <<grant, verified, candidate, review, expired, owner, receipt,
                  payloadCandidate, lock, executions, startAllowed, startReviewed>>
ExplicitStageOnly == /\ preflight = "blocked" /\ preflight' = "stage-only"
  /\ UNCHANGED <<grant, verified, candidate, review, expired, owner, receipt,
                  payloadCandidate, lock, executions, startAllowed, startReviewed>>
SupportedPick == /\ preflight \in {"pending", "ordinary"} /\ grant = "none"
  /\ grant' = "active" /\ verified' = TRUE
  /\ UNCHANGED <<preflight, candidate, review, expired, owner, receipt,
                  payloadCandidate, lock, executions, startAllowed, startReviewed>>
ForgedIngress == /\ preflight \in {"pending", "ordinary"} /\ grant = "none"
  /\ grant' = (IF BugIngress THEN "active" ELSE grant)
  /\ UNCHANGED <<preflight, verified, candidate, review, expired, owner, receipt,
                  payloadCandidate, lock, executions, startAllowed, startReviewed>>
ReviewPick == /\ grant = "active" /\ review # candidate
  /\ review' = candidate
  /\ UNCHANGED <<preflight, grant, verified, candidate, expired, owner, receipt,
                  payloadCandidate, lock, executions, startAllowed, startReviewed>>
CandidateChanges == /\ grant \in {"active", "paused"} /\ candidate < MaxCandidate
  /\ candidate' = candidate + 1
  /\ UNCHANGED <<preflight, grant, verified, review, expired, owner, receipt,
                  payloadCandidate, lock, executions, startAllowed, startReviewed>>
Pause == /\ grant = "active" /\ grant' = "paused"
  /\ UNCHANGED <<preflight, verified, candidate, review, expired, owner, receipt,
                  payloadCandidate, lock, executions, startAllowed, startReviewed>>
Resume == /\ grant = "paused" /\ owner = 1 /\ ~expired
  /\ receipt \notin {"applying", "inspect"} /\ grant' = "active"
  /\ UNCHANGED <<preflight, verified, candidate, review, expired, owner, receipt,
                  payloadCandidate, lock, executions, startAllowed, startReviewed>>
Revoke == /\ grant \in {"active", "paused"} /\ grant' = "ended"
  /\ UNCHANGED <<preflight, verified, candidate, review, expired, owner, receipt,
                  payloadCandidate, lock, executions, startAllowed, startReviewed>>
\* Expiry is checked at the serialized start boundary, not just preflight.
ExpireAtStart == /\ grant \in {"active", "paused"} /\ ~expired
  /\ expired' = TRUE /\ grant' = "ended"
  /\ UNCHANGED <<preflight, verified, candidate, review, owner, receipt,
                  payloadCandidate, lock, executions, startAllowed, startReviewed>>
OwnershipChanges == /\ grant \in {"active", "paused"} /\ owner = 1
  /\ owner' = 2 /\ grant' = "ended"
  /\ UNCHANGED <<preflight, verified, candidate, review, expired, receipt,
                  payloadCandidate, lock, executions, startAllowed, startReviewed>>

Start(caller) == /\ grant = "active" /\ ~expired /\ owner = 1
  /\ receipt = "none" /\ lock = 0
  /\ (preflight = "ordinary" \/ review = candidate \/ (BugStaleReview /\ review # 0))
  /\ receipt' = "applying" /\ payloadCandidate' = candidate
  /\ lock' = caller /\ executions' = executions + 1
  /\ startAllowed' = (grant = "active" /\ ~expired /\ owner = 1 /\ verified)
  /\ startReviewed' = (preflight = "ordinary" \/ review = candidate)
  /\ UNCHANGED <<preflight, grant, verified, candidate, review, expired, owner>>
StartCallerOne == Start(1)
StartCallerTwo == /\ WithRaces /\ Start(2)
\* A cooperating second caller cannot claim a different request while the
\* target is quarantined, even if the process execution lock was lost.
SecondCallerBlocked == /\ grant = "active" /\ receipt \in {"applying", "inspect"}
  /\ UNCHANGED vars
StaleReviewBlocked == /\ preflight = "pending" /\ grant = "active" /\ review # candidate
  /\ UNCHANGED vars
PayloadMismatchBlocked == /\ receipt # "none" /\ UNCHANGED vars
DeniedStart == /\ grant \in {"paused", "ended"}
  /\ UNCHANGED vars
NoGrantBlocked == /\ grant = "none" /\ UNCHANGED vars
ResumeBlocked == /\ grant = "paused" /\ receipt \in {"applying", "inspect"}
  /\ UNCHANGED vars
EndedCannotResume == /\ grant = "ended" /\ UNCHANGED vars
\* A duplicate unfinished request is inspect, never a second effects call.
DuplicateRequest == /\ receipt # "none"
  /\ receipt' = (IF receipt = "applying" THEN "inspect" ELSE receipt)
  /\ UNCHANGED <<preflight, grant, verified, candidate, review, expired, owner,
                  payloadCandidate, lock, executions, startAllowed, startReviewed>>
Timeout == /\ receipt = "applying" /\ receipt' = "inspect" /\ lock' = 0
  /\ UNCHANGED <<preflight, grant, verified, candidate, review, expired, owner,
                  payloadCandidate, executions, startAllowed, startReviewed>>
Restart == /\ receipt \in {"applying", "inspect"} /\ lock # 0
  /\ receipt' = "inspect" /\ lock' = 0
  /\ UNCHANGED <<preflight, grant, verified, candidate, review, expired, owner,
                  payloadCandidate, executions, startAllowed, startReviewed>>
InspectUnavailable == /\ receipt = "inspect" /\ UNCHANGED vars
\* These outcomes require the external executor's authoritative quiescence /
\* result inspection. Seeing the old remote OID alone is NOT NoEffect proof.
Finish(outcome) == /\ receipt \in {"applying", "inspect"}
  /\ receipt' = outcome /\ lock' = 0
  /\ grant' = (IF outcome = "conflict" THEN "ended" ELSE grant)
  /\ UNCHANGED <<preflight, verified, candidate, review, expired, owner,
                  payloadCandidate, executions, startAllowed, startReviewed>>
VerifiedSuccess == Finish("succeeded")
ProvenNoEffect == Finish("no-effect")
InspectedConflict == Finish("conflict")
ReplayAfterTimeout == /\ BugReplay /\ receipt = "inspect" /\ lock = 0 /\ executions = 1
  /\ executions' = 2
  /\ UNCHANGED <<preflight, grant, verified, candidate, review, expired, owner,
                  receipt, payloadCandidate, lock, startAllowed, startReviewed>>
Idle == UNCHANGED vars

Next == PreflightSupported \/ PreflightOrdinary \/ PreflightBlocked \/ ExplicitStageOnly
     \/ SupportedPick \/ ForgedIngress \/ ReviewPick \/ CandidateChanges
     \/ Pause \/ Resume \/ Revoke \/ ExpireAtStart \/ OwnershipChanges
     \/ StartCallerOne \/ StartCallerTwo \/ SecondCallerBlocked
     \/ StaleReviewBlocked \/ PayloadMismatchBlocked \/ DeniedStart
     \/ NoGrantBlocked \/ ResumeBlocked \/ EndedCannotResume \/ DuplicateRequest
     \/ Timeout \/ Restart \/ InspectUnavailable \/ VerifiedSuccess
     \/ ProvenNoEffect \/ InspectedConflict \/ ReplayAfterTimeout \/ Idle
Spec == Init /\ [][Next]_vars

TypeOK == /\ preflight \in {"unchecked", "pending", "ordinary", "blocked", "stage-only"}
  /\ grant \in {"none", "active", "paused", "ended"}
  /\ verified \in BOOLEAN /\ candidate \in 1..MaxCandidate /\ review \in 0..MaxCandidate
  /\ expired \in BOOLEAN /\ owner \in {1,2}
  /\ receipt \in {"none", "applying", "inspect", "succeeded", "no-effect", "conflict"}
  /\ payloadCandidate \in 0..MaxCandidate /\ lock \in {0,1,2}
  /\ executions \in 0..2 /\ startAllowed \in BOOLEAN /\ startReviewed \in BOOLEAN
\* Only supported explicit acceptance can create durable authority.
SupportedIngressOnly == grant # "none" => verified
\* Blocked feasibility and explicit stage-only are not commit/publication grants.
StageOnlyIsNotGrant == preflight \in {"unchecked", "blocked", "stage-only"} => grant = "none"
\* Review is separate, bound to the candidate at the actual start boundary.
FreshCandidateReview == startReviewed
\* Revocation/expiry/ownership are ordered at start; later revocation does not
\* pretend an already-started effect was cancelled.
AuthorizedAtStart == startAllowed
\* The durable request can never independently run its effects twice.
NoAutomaticReplay == executions <= 1
\* Ending authority never clears the unfinished target quarantine.
QuarantineRetained == receipt \in {"applying", "inspect"} => payloadCandidate # 0
\* Expiry or changed ownership permanently ends this grant, never transfers it.
ChangedBindingEndsGrant == (expired \/ owner # 1) => grant = "ended"
\* A target execution claim is backed by a durable unfinished receipt.
ClaimHasReceipt == lock # 0 => receipt \in {"applying", "inspect"}
\* Neither revocation nor restart may erase the durable action's identity.
RequestIdentityRetained == executions # 0 => (receipt # "none" /\ payloadCandidate # 0)
=============================================================================
