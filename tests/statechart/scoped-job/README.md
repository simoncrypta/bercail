# Scoped job authorization lifecycle proof

Accepted lifecycle: **bercail-qsoa: Scoped job authorization: commits and
fast-forward publication without repeat prompts**, Q55@1. `ScopedJob.tla`
models the durable `QuestionStore` lifecycle, not an authentication protocol or
Git transport.

## Run

Already-installed TLC 1.7.4 and Java are required. Nothing here installs tools.

```sh
bash tests/statechart/scoped-job/check.sh
node_modules/.bin/vp test tests/shep_scoped_statechart.test.ts
```

`check.sh` checks `full.cfg` and `replay.cfg`, requires a counterexample for each
planted bug, then regenerates TLC's complete replay graph and `sha256sums`.
Reports and bug-path charts go to a new directory under
`/tmp/bercail-qsoa-build/model/` (`MODEL_OUT` changes that root). The checksums
cover the model, every config, the view and graph. The graph also records its
model/config hashes. The test rejects stale inputs.

Both positive configs have the same bounds: one grant, one durable request, two
candidates and two callers. They explore **511 states and 4,540 edges**, including
self-loops that reject actions. The positive graph exceeds the chart tool's
500-state display budget, so its report lists the checked rules without drawing
a chart. Negative runs draw their shortest bug paths.

## What is checked

- Durable grant status is `active`, `paused` or `ended`. Candidate review and
  action receipt status are separate. A changed candidate does not end a grant.
- Supported picker acceptance creates authority. Pending questions, forged
  source/freshness claims through the old answer method and proposals do not.
- Unsupported preflight stays blocked. Explicit stage-only acceptance creates no
  commit/publication grant. Feasible ordinary actions need no candidate LGTM;
  high-stakes actions require the exact current candidate review.
- Expiry and ownership changes end authority at the serialized start boundary.
  Revocation before start denies it. Revocation after start does not pretend to
  cancel effects or erase receipts. Ended grants cannot resume.
- Two cooperating callers compete for one target. A durable unfinished receipt
  rejects another request, including after the process lock is lost.
- A request ID binds its payload. Duplicate unfinished requests enter inspection,
  not another effects call. Terminal receipts remain idempotent.
- Timeout/restart needs inspection. Unavailable inspection stays unresolved.
  Success, no-effect and conflict transitions require a fake executor's explicit
  quiescent-outcome fact. Ownership/expiry/revocation alone never turn an
  unresolved receipt into a terminal conflict or clear its quarantine.

The invariants are `TypeOK`, `SupportedIngressOnly`, `StageOnlyIsNotGrant`,
`FreshCandidateReview`, `AuthorizedAtStart`, `NoAutomaticReplay`,
`QuarantineRetained`, `ChangedBindingEndsGrant`, `ClaimHasReceipt` and
`RequestIdentityRetained`. TLC also checks deadlocks. There is no eventual-progress
claim: the person or remote evidence may remain unavailable indefinitely.

## Real-code replay

The test walks every edge from TLC's graph. A breadth-first traversal produces
source checkpoints by calling real `QuestionStore` methods. Each edge starts a
fresh store over an isolated copy of a source checkpoint, calls the corresponding
method and compares the durable grant, question, review and receipt with TLC's
destination. It never writes a model-generated ledger or calls a duplicate
reducer. Self-loops still run their rejection/idempotence checks. Receipt audit
facts freeze the grant revision at start and retain the original remote-head and
backend-capability observations, even when a duplicate caller observes a new
remote head. These audit facts do not change logical request identity. The fake
executor explicitly supplies a null remote head because remote state is not modeled.
The representative publication receipt must also retain `expectedCommit:null`.
Commit preparation and the exact commit-CAS recovery boundary are outside this model.

Every test gets its own HOME, XDG directories, runtime directory and TMPDIR. Desk
and live-state variables are cleared. Live commands are failing stand-ins on
PATH; only the installed `flock` runs through a logged boundary. The relatively
slow graph test exercises real flock/fsync transactions rather than mocking the
store.

## Bounds and exclusions

Picker identity, resolver freshness, backend feasibility, current ownership
facts, the executor's OS execution lock and quiescent remote outcomes are
**environment assumptions** here. The replay checks ledger quarantine and
serialized receipts, not the actual two-process execution lock or endpoint
fast-forward enforcement. Seeing an old remote OID does not establish quiescence.

The representative request is `publish-fast-forward`. The model does not cover
actual Git/network effects, commit-to-publication review carry-forward, multiple
grants/requests/targets, restored/regranted-owner quarantine, malformed ledger
recovery, every scope field, pending-question revisions/withdrawal, unmanaged
writers, or remote metadata races. Dedicated ledger, resolver, picker and executor
tests cover their own contracts. This bounded model cannot establish those claims.

## Planted bugs

- `bug-ingress.cfg`: unchecked ingress mints a grant. Breaks
  `SupportedIngressOnly` after preflight and forged input.
- `bug-stale-review.cfg`: an old candidate's review permits start. Breaks
  `FreshCandidateReview` after pick, review, candidate change and start.
- `bug-replay.cfg`: an unlocked uncertain request is resent. Breaks
  `NoAutomaticReplay` after an ordinary start and lost response/restart.

For the implementation check, scratch copies of `questions.ts` were separately
changed to route old `.answer` into the trusted seam, accept any candidate with
an old review, and return `duplicate:false` for a lost-response receipt. The
replay rejected each at its corresponding graph edge. These are deliberately
broken copies, not reported production defects. The build report contains the
commands and evidence paths.
