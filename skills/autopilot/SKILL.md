---
name: autopilot
description: >-
  Drives an open PR to green: watches CI and review comments, fixes what is real,
  answers what is not, merges the base on conflicts, and pushes each fix. Stops
  when checks pass and no thread waits on you, or when it needs a person. Use
  when asked to babysit, watch, or land a PR, fix CI, or answer review comments.
---

# autopilot

Asking for autopilot is the ask to commit and push to the PR's branch. That is
the exception to "stage, do not commit". It never force-pushes, never merges
the PR, never pushes to the base branch, and never passes `--no-verify`.

In opencode, `/autopilot` runs as the `bstack-autopilot` agent, which may commit
and push without asking. Other harnesses ask at each push.

## 0. The PR

- `scripts/pr-state.sh [--pr N]` prints one JSON snapshot: `checks`, `failing`
  (with run ids), `pending`, `threads` (unresolved, last word not yours),
  `mergeable`, and `next`.
- No PR for this branch: stop and say so. Open one only when asked.
- Check out the PR's branch in this worktree (`gh pr checkout N` when it is not).
  Uncommitted work that is not yours: stop, do not stash it.

## 1. Loop on `next`

Run `pr-state.sh`, do what `next` says, push, then run it again.

| `next` | Do |
|--------|----|
| `conflicts` | `git fetch origin <base> && git merge origin/<base>`. Resolve each file from both sides' intent, run the tests, commit the merge, push. No rebase: it needs a force-push. |
| `fix-ci` | Take one failing check. `gh run view <run> --log-failed`. Reproduce locally with the same command. Fix the cause, run it again, commit, push. |
| `answer-threads` | Section 2. |
| `wait-ci` | `pr-state.sh --wait 900`. It returns when a check finishes, a thread arrives, or the head moves (exit 124 on timeout: run it again). |
| `green` | Stop. Section 3. |
| `merged`, `closed` | Stop and say so. |

One failure per commit. Re-run `pr-state.sh` after every push: a new head
starts new checks, and a fix can fail a different job.

A failure is a flake only when the log shows it (a timeout, a network error, a
runner that died) and the same check passed on a recent run of this code. Rerun
it once with `gh run rerun <run> --failed`. A second failure is real.

## 2. Review threads

Each thread is a claim. Check it like a council finding: read the code at its
`path:line`, run it when it is about behavior.

- **Right and clear:** fix it, push, then reply in the thread with what changed
  and the commit (`addPullRequestReviewThreadReply`). Resolve it
  (`resolveReviewThread`) only when a bot opened it; a person resolves their own.
- **Wrong or already handled:** reply with the evidence (`file:line`, the run,
  the test). Do not change code to quiet it.
- **Needs a person** (product calls, scope, taste, a question to the author):
  do not guess. Leave it, list it in the report.

Replies go through `gh api graphql`:

```bash
gh api graphql -f query='mutation($t: ID!, $b: String!) {
  addPullRequestReviewThreadReply(input: {pullRequestReviewThreadId: $t, body: $b}) { comment { url } }
}' -F t="$thread_id" -f b="$reply"
gh api graphql -f query='mutation($t: ID!) { resolveReviewThread(input: {threadId: $t}) { thread { id } } }' -F t="$thread_id"
```

Group the fixes from one review into one commit when they touch the same code.
Write replies and commit messages with the `unslop` skill: short, plain, no
thanks-for-the-catch.

## 3. Stop

Stop and report when `next` is `green`, `merged`, or `closed`, or:

- the same check fails after two real fix attempts,
- a fix needs a change the PR is not about (say what, do not do it),
- every open thread needs a person,
- 10 pushes in one run.

Report in five lines or fewer: the PR, the state (`green` or what blocks it),
what you pushed (commit subjects), the threads you answered, and what waits on
a person. Do not merge. Say "ready to merge" when it is.

## Inside bercail

- Watch from a desk: `/autopilot` in opencode, or hand it off as its own job
  (a beads issue that names the PR, then `handoff-spawn --stage autopilot
  --issue <id> --worktree <the PR's checkout>`). Headless runs reject every
  "ask", so the `bstack` stage cannot push; `autopilot` runs `bstack-autopilot`.
- The person's tuicr review comes before the PR, not after: autopilot answers
  GitHub, not tuicr.
