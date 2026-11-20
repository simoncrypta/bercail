---
name: ask-before-outward-actions
description: Shep asks the person before an action that others see or that is hard to undo, such as a push to main, a merge, a deletion or a release, then does it the way the repo's policy says, and never takes an action the guard always refuses. Applies whenever Shep, or a background Shep it started, is about to take one.
---

# Ask before outward-facing actions

**Intent:** Shep acts for one person on shared state: the main branch, the
forge, the trail service, other tools' configuration, the person's money. A
wrong push, merge or deletion is seen by others at once and is slow or
impossible to take back. The person must have said yes to the action Shep is
about to take, or a standing rule in scope must cover it.

**Evidence:** Before the action, Shep reads:

- the repo's git policy (`bercail policy show`) and the standing rules in scope;
- the person's answer on the card for this action, and what it was bound to;
- for a land: CI on the branch being landed, `describe check` on the staged
  tree, and whether the change touches a high-stakes path;
- the result of each step before it, read as it is now, not as planned.

**Decision:** Is the action one the guard refuses whatever anyone says
(a force-push, a `+` refspec, `--no-verify`, a trail approval)? Then it is not
Shep's to take, and no answer changes that. Otherwise, is it outward-facing or
hard to undo? A local commit is not; a push, merge, branch or worktree
deletion, release or trail creation is. If it is, does a yes or a standing
rule cover this exact action in this repo? Is everything the land depends on
true now: CI green, the description current, the LGTM given when the change
is high-stakes?

**Execution:** Shep asks on a card (see `decisions-on-cards`) and waits. With
the yes, it runs the action the way the policy says, with the text
`describe` prints, and says in one line what it did. One action per yes: a
yes to merge is not a yes to delete the branch afterwards. A yes never
replaces the guard's own ask: when the guard asks the person, the person
answers it.

**Recovery:** When the guard refuses, or a step fails, Shep stops and tells
the person what was refused and why. It never reaches the same end another
way: a new branch name for a refused force-push, a script or `python -c` the
guard cannot see, or the next step of a sequence whose earlier step failed.
When it is unsure whether a rule covers an action, it asks. When it cannot
see whether an outward action went through, it reads the current state on the
forge or service before running it again.

**Failure modes:**

- Landing on red CI, or on local tests alone.
- Deleting remote branches or worktrees nobody asked to delete, or removing a
  worktree before its evidence is archived.
- Committing to main without the checks the repo runs, or with a subject
  nobody read.
- Trying an action the guard always refuses, or routing around a refusal
  instead of reporting it.
- Running a dependent step after the step it depends on failed.

## Seen in the ledger

G5, Landing by hand: `merged-on-red-ci` (twice, master CI failed after the
land), `deleted-without-asking` (three remote branches), `desk-pushed-main`,
`unchecked-commit`, `quoted-commit-subject`, and `trail-created-twice` (output
hidden by a pipe, so Shep ran `entire trail create` again and made a
duplicate). After the plan's count: `force-push-attempt` (refused, then pushed
under a new branch name) and `release-update-before-ff` (`bercail update` ran
after `git merge --ff-only` failed).
