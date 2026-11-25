# Ship with autopilot

Once the PR is open, the work is waiting: on CI, on reviewers, on bots. Autopilot
does the waiting for you, and the fixing.

```text
/autopilot
```

It takes the PR for the current branch, or a number (`/autopilot 42`).

## What it does

It runs a loop on one snapshot of the PR:

```bash
~/.agents/skills/autopilot/scripts/pr-state.sh [--repo PATH] [--pr N] [--wait SECONDS]
```

The JSON carries the checks, the failing ones with their run ids, the open
review threads where the last word isn't yours, the merge state, and `next`:

| `next` | Autopilot |
|--------|-----------|
| `conflicts` | merges the base in, resolves, runs the tests, pushes (no rebase: that needs a force-push) |
| `fix-ci` | reads `gh run view --log-failed`, reproduces locally, fixes one failure, pushes |
| `answer-threads` | checks each claim; fixes the right ones, answers the wrong ones with evidence |
| `wait-ci` | waits until a check finishes, a thread arrives, or the head moves |
| `green` | stops and says "ready to merge" |
| `merged`, `closed` | stops and says so |

If checks or review threads cannot be read, the helper exits 3 with a diagnostic
on stderr and no snapshot. Autopilot retries and stops after three consecutive
exit-3 runs. A PR with no checks is still a readable, empty result. `--wait`
retries read failures until its deadline: it exits 3 without a snapshot if the
latest read failed, or 124 with a snapshot if readable checks are still pending.

A failure counts as a flake only when the log shows it and the same check passed
recently. It gets one rerun. A second failure is real.

## Review threads

A thread is a claim, like a judge's finding. Autopilot reads the code it points
at, and:

- **right and clear:** fixes it, pushes, and replies with the commit. It
  resolves the thread when a bot opened it; a person resolves their own.
- **wrong or already handled:** replies with the `file:line`, the run, or the
  test. It does not change code to quiet a bot.
- **a person's call** (scope, product, taste): leaves it and lists it for you.

## What it may do

Asking for autopilot is asking it to commit and push to the PR's branch. It
runs as `bstack-autopilot`, a sibling agent that may commit and push without
asking. It may not force-push, push to `main` or `master`, pass `--no-verify`,
or merge: bstack's guard extension blocks each of those for autopilot. A
restack of the PR's branch is yours to publish: autopilot pins the PR head,
restacks and checks it, then stops with the pinned and new heads and the
`git push --force-with-lease` command for you to run, or for Shep to put on a
[guard card](../shep.md#guard-asks) you allow. It
does not tag or release unless the repo's trusted
[git policy](../config.md#git-policy-per-repo) sets `agent_may_release`.

Before edits it checks whether the configured backend can enforce the job's
exact effects. Graphite's implicit lease-force submit and child restacks are
not plain commits and fast-forwards. An unsupported native path stops, or
continues stage-only after an explicit fallback pick. It never silently switches
backend.

High-stakes review stays the person's. On GitHub and Origin, each fix is a new
commit, and you squash-merge with the description as the message. PR body edits keep
their separate authority and use `bercail describe body`.

It stops when the PR is green, when the same check fails after two real fixes,
when a fix needs a change outside the PR, when every open thread needs a person,
or after 10 pushes. Then it reports: the state, the commits, the threads it
answered, and what waits on you.

## Run it as its own job

Autopilot can take hours. Hand it off and keep your desk:

```text
/handoff watch pr 42 until it's green
```

That writes a beads issue naming the PR and runs it headless on the `autopilot`
[stage](../handoff.md), with autopilot's rules, in the PR's checkout. The
`bstack` stage leaves commit and push to you, so this is the only one that can
push.

Next: [Run jobs in parallel](./07-handoff.md).
