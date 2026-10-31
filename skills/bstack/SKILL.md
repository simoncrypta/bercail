---
name: bstack
description: >-
  bercail's playbooks for rigorous work on opencode with your own Claude, GPT,
  and Grok subscriptions: investigation, bug fix, feature, refactor, review,
  ship, handoff, and takeover. Routes code to the builder, hard calls to the judge,
  and review to the council. Use at the start of any non-trivial task, or when
  asked which bstack playbook or role fits.
---

# bstack

Pick the playbook that matches the task. Copy its steps into your todo list
before you start, then work through them in order. Roles and finishing rules are
in bstack's instructions (`~/.config/opencode/bstack/instructions.md`).

Outside opencode (Claude Code, Codex, cursor-agent) there are no `bstack-*`
subagents: do the role's work yourself in this session and say so once.

## Pick a playbook

| Task | Playbook |
|------|----------|
| How does X work, why is Y like this, are we sure | investigation |
| Something is broken | bug fix |
| New or changed behavior | feature |
| Same behavior, better shape | refactor |
| Review a diff, a branch, or a PR | review |
| A PR is open: get it green and answered | ship |
| Several independent jobs, or one that needs its own branch | handoff |
| Finish someone else's branch, PR, or agent session | takeover |

None fits: write a five-step playbook for this task in your todo list first,
each step ending in something you can check.

## investigation

1. Restate the question in one sentence.
2. What the code does: the `how` skill. Why it is that way, or whether a reason
   still holds: the `why` skill. Both: `how` first.
3. Answer with `file:line` evidence. Say what you checked and what you did not.
4. Change nothing. When the findings point at a fix, start it as its own task.

## bug fix

1. Reproduce it. Write the exact command, input, and output. No repro: say so
   and stop at a diagnosis.
2. Find the first place the state goes wrong, not where it surfaces.
3. When there is a cheap test path, write the failing test first.
4. Fix at the root (`bstack-builder` for a mechanical fix, `bstack-judge` when the
   cause is subtle).
5. Rerun the repro and the tests. Both must change for the right reason.
6. Finish with `/ready`.

## feature

1. Name the data shape first: the types, the state, who reads and writes it.
2. Settle the interface from the caller's side before the inside. On a hard
   design fork, ask `bstack-judge`, or sketch two versions and compare.
3. Build it in small steps that each end green (`bstack-builder`, with a brief per step).
4. Drive the real path the user takes: the CLI, the app, the endpoint.
5. Finish with `/ready`.

## refactor

1. Pin the current behavior: run the tests, or add one where coverage is thin.
2. Before you remove something whose reason is unclear, run `why` on it.
3. Move callers to the new shape and delete the old one in the same change. No
   compatibility layer unless the issue asks for one.
4. Prefer a script or codemod over hand edits for anything repeated.
5. The same tests pass, unchanged. Finish with `/ready`.

## review

1. Get the target: the uncommitted diff, `git diff <base>...HEAD`, or `gh pr diff <n>`.
2. Run the `council` skill on it.
3. Report only findings that hold up, worst first, with `file:line`.
4. Post to GitHub only when asked (the `review` skill's `publish-github.sh`).

## ship

The person reviewed in tuicr, committed, and opened the PR. Now:

1. Run the `autopilot` skill on the PR. It is the ask to commit and push fixes.
2. It loops on CI and review threads until the PR is green or it needs a person.
3. Report the state and stop. Never merge.

## handoff

1. One beads issue per job (`bd create`). The issue is the spec; it says what
   done looks like.
2. Run the `handoff` skill. Stage `bstack` runs on the lead's model through
   opencode; `--binary opencode` with `--stage start` or `--stage codex` runs
   Claude or GPT through opencode. `--branch NAME` opens a sibling desk; without
   it the run is headless.
3. Report the spawn JSON and stop. Follow a desk with `hc wait <desk>`; read a
   headless run's `.bercail/handoff-result.json`.

## takeover

1. Read everything first: the issue, the PR and its threads, the branch's
   commits, the last agent's result file or transcript.
2. Rebase on the current base. Drop work that is already merged or no longer needed.
3. Finish the remaining part with the playbook that fits it.
4. Keep the original author's credit (`Co-authored-by:` when you commit, if asked to).
