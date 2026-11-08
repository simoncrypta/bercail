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

## 0. The backend and PR

Read `git` (`gh` | `gt` | `origin`) from the handoff skill's
`scripts/handoff-spawn --info` in this checkout. Never run `gt` to detect it.
Use the same backend for checkout, stack updates, and publication:

| Backend | Checkout and stack updates |
|---------|----------------------------|
| `gh` | For a stack, `gh stack checkout`, `gh stack sync`, and `gh stack submit`. Independent branches use `gh pr checkout` and `git push`. |
| `gt` | `gt get` to fetch the stack, then `gt submit` to publish fixes. Use `gt create` or `gt track` only when adding a branch. |
| `origin` | `origin stack get`, `origin stack restack`, and `origin stack push --all`. Local parents use `origin stack track --onto`; child PRs use `origin pr create --stack-on`, not just `--base`. |

Never hand-make a PR merely based on another PR's branch, and never run `gt`
in a `gh` or `origin` repo. Do not rewrite someone else's stack members. If
native sync/restack needs a force-push or an unauthorized branch update, stop
and report it; autopilot's no-force-push and no-merge rules still apply.

The snapshot helper and GitHub commands below apply to `gh` and `gt` only.
For `origin`, use `origin pr view`, `origin pr checks`, `origin pr requirements`,
`origin pr thread`, and `origin pr watch` instead. Read `origin agent prompt ci`
and `origin agent prompt review` for this installed CLI's flags and JSON fields.
Apply the same fix/check/reply loop and stopping rules; do not call GitHub
GraphQL, `gh run`, or the GitHub snapshot helper for an Origin PR.

- `scripts/pr-state.sh [--pr N]` prints one JSON snapshot: `checks`, `failing`
  (with run ids), `pending`, `threads` (unresolved, last word not yours),
  `mergeable`, and `next`.
- No PR for this branch: stop and say so. Open one only when asked.
- Check out the PR's branch in this worktree through the backend above.
  Uncommitted work that is not yours: stop, do not stash it.

## 1. Loop on `next`

Run `pr-state.sh`, do what `next` says, push, then run it again.

| `next` | Do |
|--------|----|
| `conflicts` | For an independent `gh` branch, `git fetch origin <base> && git merge origin/<base>`; resolve from both sides' intent, test, commit, push. For a stack, use the backend's stack update commands above, not a plain merge into one layer. Stop if publication requires a force-push. |
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
