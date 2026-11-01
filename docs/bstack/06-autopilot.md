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

A failure counts as a flake only when the log shows it and the same check passed
recently. It gets one rerun. A second failure is real.

## Review threads

A thread is a claim, like a council finding. Autopilot reads the code it points
at, and:

- **right and clear:** fixes it, pushes, and replies with the commit. It
  resolves the thread when a bot opened it; a person resolves their own.
- **wrong or already handled:** replies with the `file:line`, the run, or the
  test. It does not change code to quiet a bot.
- **a person's call** (scope, product, taste): leaves it and lists it for you.

## What it may do

Asking for autopilot is asking it to commit and push to the PR's branch. In
opencode it runs as `bstack-autopilot`, which may commit and push without asking.
It may not force-push, push to `main` or `master`, pass `--no-verify`, or merge.
Force-push and `--no-verify` are opencode policies, which no agent or approval can
lift; the rest are denied in the agent's permissions.

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
[stage](../handoff.md), as `bstack-autopilot`, in the PR's checkout. Other headless stages reject
every commit, push, and merge, so this is the only one that can push.

Next: [Run jobs in parallel](./07-handoff.md).
