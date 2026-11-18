# Shep workflow repair

## What went wrong

Three independent facts had been treated as one: the task someone asked for,
the process doing it, and the permission to perform its next action. A new
handoff could start another worker instead of continuing the original session.
An old done report or closed issue could hide a later amend-and-publish request.
A background issue's prose could ask a general coding profile to perform
interactive authoring without a visible desk.

The installation added another ambiguity. Source, installed instructions and
an already-running Pi could contain different bytes under the same version.
A filesystem hash establishes current file contents, not what that process
loaded. A status string naming a model/provider fallback does not establish an
execution-surface fallback: verify the actual space, process and session.

## Product boundaries

[`bercail shep task`](../shep.md#task-ownership-and-requested-outcomes) stores requested
outcomes in the existing beads issue. A repository reservation covers canonical
main/worktree aliases and logical PR/task targets. A deliberate exploration uses
a separate issue and explicit reason. This is a local repository protocol, not
a distributed lock for unrelated machines or arbitrary external database writers.

Continuation uses Pi's `sendMessage` custom DATA message with
`deliverAs: "followUp"`, delivered only while the original Pi is idle. The
consumer checks the persisted original desk/space/process/session/checkout and
branch. It claims before sending. A lost acknowledgement is UNKNOWN, not a
reason to send again, replace a process or type an approval. Exact-session claims
from competing processes are ambiguous regardless of their role labels.

Completion is separate from delivery and from issue status. Successful execution
must belong to that request on the runtime-reported active session leaf. The
physical JSONL tail can contain an abandoned branch. Validation binds the
recorded checks to the current head/staged tree. Local authoring requires a new
local head. Publication compares with the PR head observed at dispatch, then
checks the remote and current PR head/CI. This permits an already-authored but
unpublished commit without accepting an unchanged old green PR. Canonical
receipts stay visible independently of supplemental readback comments. Exact native authoring remains deliberately blocked:
this repair adds neither a Graphite effect contract nor a native write executor.
The original worker records the native blocker and next action instead.

Cleanup captures a finite native OPEN set and its incarnations. Default CLOSE
intent cannot silently become KEEP/PROTECTED in a receipt; retention must have
been explicitly requested with a reason. CLOSED requires observed execution and
current absence. EXTERNAL means independently observed closure without worker
attribution. UNKNOWN/PARTIAL do not complete the request. Persisted original
context may reconcile a terminal cleanup receipt after native closure ended Pi;
this is not permission to adopt a replacement. RECENT history and future queued
messages are not OPEN targets or global vetoes on normal closure.

Shep disables automatic skill discovery and names its intended skills.
Background wait/admin workers have observation, bounded wait and issue-report
tools, not a general shell or coding fallback. Those restrictions are not an OS
sandbox. Existing guard, approval and shipping policy still apply.

Runtime diagnostics compare source/install resources and show available
evaluated startup markers and prompt hashes. Missing instrumentation, including
the guard generation, stays UNKNOWN. No diagnostic installs or reloads anything.

## Proof and limits

The checked transport model in `tests/statechart/shep-task/` has six states and
eight edges. The replay covers every edge against the actual consumer and
rejects planted unknown-send replay and stale-session delivery. It does not
model repository reservation, process races, metadata durability or external
effects. CLI regressions cover those supported boundaries separately.

The offline real-Pi proof delivers two follow-ups to one process/session and
observes actual bash result/candidate events using a read-only Git command.
Unit tests use disposable Git checkouts, fake native CLIs and isolated stores.
Neither proof establishes a real publication, native authoring operation,
production cleanup, loaded guard revision or coordinated runtime rollout.

Rollout is separate: review the staged source, then deliberately update and
restart the intended processes. Never infer that existing sessions evaluated
this patch merely because their installed files now match it.
