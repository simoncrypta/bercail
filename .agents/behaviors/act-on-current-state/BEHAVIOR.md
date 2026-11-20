---
name: act-on-current-state
description: Shep reads the current owner, base and state before it acts on an event, a snapshot or a report, and tells the person about each event once. Applies to every desk event, to a board or summary after compaction, and to any action taken on something read earlier.
---

# Act on the current state, and report each event once

**Intent:** Events arrive late, out of order, or twice: a desk's finish, a
blocked report from an hour ago, a board in a compaction summary. The world
has often moved since. A desk may have resumed, the base moved, a merge
started, a credential been replaced. Acting on the old picture starts
duplicate work and lands stale branches. Reporting the same event twice makes
the person reread what they already handled.

**Evidence:** The event's id and whether it was already reported; the desk's
state and latest report from a fresh `bercail shep brief`; the job's current
owner; the fetched base; for a refresh, whether a merge is in progress; for a
credential, whether it still belongs to the thing it is used on.

**Decision:** Is the event new? Does what it describes still hold? Does a live
owner already exist for this job, so the next step is a follow-up to it, not a
new desk? Has the base moved since the desk branched?

**Execution:** Shep reports each new event once, from the fresh brief. It
sends follow-ups to the original desk and session. It asks for a rebase before
landing, not at the merge. A duplicate event gets no report.

**Recovery:** When the recorded desk is gone and its checkout is there,
dispatch adopts it with a new desk in that checkout, and Shep tells the
person. When ownership is unclear (two live desks, two checkouts, an UNKNOWN),
Shep names what it found to the person and asks, instead of starting another
desk. When the brief and the event disagree, the brief wins and Shep says so.

**Failure modes:**

- Reporting the same finish two or three times.
- Starting work from a delayed notice while the original desk had already
  moved on.
- Several checkouts or branches for one PR or one issue.
- Landing a branch made before the base moved.
- Reusing a credential from before a move, then reporting the target as
  broken.

## Seen in the ledger

G6, Stale or repeated events: `stale-base-rebase` (three times),
`duplicate-finish-delivery` (twice, the same report delivered after the job
closed), `stale-notice-drives-duplicate-work`, `duplicate-job-worktree` (four
checkouts for one PR), and `refresh-hits-pending-merge`.

G9: `stale-credential-after-move` (a dead tunnel's token reused, then the
device's tunnel reported broken).
