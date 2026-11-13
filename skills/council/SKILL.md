---
name: council
description: >-
  Adversarial review on request: one read-only reviewer per provider tries to
  break a change, each finding must come with a run, and only findings a rerun
  confirms are reported. Use only when someone asks for /council or "council";
  /validate and ordinary review do not run it.
---

# council

Different providers miss different bugs. The council puts each one on the same
change. A finding counts only when a run shows it and your rerun shows it again.

## 1. The target

- Default: the uncommitted change, `git diff HEAD` (staged and unstaged), plus
  untracked files from `git status --short`.
- A branch: `git diff <base>...HEAD`. A PR: `gh pr diff <n>` and `gh pr view <n>`.
- Write a brief: what the change is for (the beads issue or PR body), the diff
  command to run, the files that matter, and how to run the tests.

## 2. Convene

Launch every `bstack-council-*` subagent that exists (one per provider), in
parallel, with the same brief and the reviewer rules below. Do not tell them
what the others said.

With one seat, say so in the report. Each reviewer is a
`bstack-council-<family>` template from `hc templates`, started as a sibling
terminal the way your instructions say. bercail update renders one per provider
with a model. With none (no provider has a model), review it
yourself by the same rules and say the panel did not run.

## Reviewer rules

- Try to break the change: wrong behavior, missed cases, broken callers, races,
  security holes, data loss, tests that pass for the wrong reason.
- Prove each finding with a run: a failing test, a repro, or command output.
  Give the exact command and what it printed. Scratch files go in /tmp.
- A finding you cannot show with a run is not a finding. Leave it out.
- Leave out style, naming, and YAGNI.
- Report each one as: severity (blocker, major, minor), `file:line`, what breaks,
  the command, its output. With nothing proven, say `no findings` and list what
  you ran.

## 3. Rerun every finding

A finding is a claim until you rerun it. Run its command yourself, in this
checkout, and compare the output.

- Keep what the rerun confirms.
- Drop everything else, and do not report it: a finding that does not reproduce,
  has no run, or is style, naming, or YAGNI. There is no `unverified` list.
- Merge duplicates. Two providers finding the same bug raises confidence, not severity.
- Reviewers disagreeing is settled by the rerun, not by another opinion.

## 4. Fix and loop

- When the ask includes fixing, fix the findings you kept, then run the council
  again on the new diff.
- Stop when a round has no confirmed blocker or major finding, or after three
  rounds. Report what is still open after the third.

## 5. Report

Worst first, one line each: severity, `file:line`, what breaks, the command you
reran, and which providers found it. Then one line: the providers on the council
and the number of rounds. Change nothing outside the fixes you were asked to make.
