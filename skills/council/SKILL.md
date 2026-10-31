---
name: council
description: >-
  Reviews a change with one read-only reviewer per connected provider (Claude,
  GPT, Grok) in parallel, checks every finding, and keeps only the ones that
  hold up. Loops until no blocker is left. Use to review a diff, branch, or PR,
  before calling work ready, or when asked for "council" or a second opinion.
---

# council

Different providers miss different bugs. The council puts each connected one on
the same change, then you check each finding before you believe it.

## 1. The target

- Default: the uncommitted change, `git diff HEAD` (staged and unstaged), plus
  untracked files from `git status --short`.
- A branch: `git diff <base>...HEAD`. A PR: `gh pr diff <n>` and `gh pr view <n>`.
- Write a brief: what the change is for (the beads issue or PR body), the diff
  command to run, the files that matter, and how to run the tests.

## 2. Convene

Launch every `bstack-council-*` subagent that exists (one per connected provider),
in parallel, with the same brief. Do not tell them what the others said.

With only one provider connected, the council is one reviewer: say so in the report.
Outside opencode there are no council agents: review it yourself, with the
reviewer rules below, and say the council was skipped.

## 3. Check every finding

A finding is a claim until you check it.

- Read the code at the `file:line` it names. Run the repro or the test when it
  depends on behavior.
- Keep: shown by a run, or plain from the code. Drop: wrong, already handled, or
  style only. Mark `unverified` what you could not settle either way.
- Merge duplicates. Two providers finding the same bug raises confidence, not severity.
- When two reviewers disagree on a finding that matters, ask `bstack-judge` to
  settle it with the evidence from both.

## 4. Fix and loop

- When the task is to get the change ready, fix the findings you kept, then run
  the council again on the new diff.
- Stop when a round has no kept blocker or major finding, or after three rounds.
  Report what is still open after the third.

## 5. Report

Worst first, one line each: severity, `file:line`, what breaks, how it was shown,
and which providers found it. Then one line: the providers on the council and
the number of rounds. Change nothing outside the fixes you were asked to make.
