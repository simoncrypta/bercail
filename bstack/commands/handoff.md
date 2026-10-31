---
# managed by bercail (bstack). `bercail update` rewrites this file; delete this line to keep your own.
description: Hand a job to a parallel desk or a headless run as a beads issue
---
Load the `handoff` skill and follow it. The job: $ARGUMENTS

1. Write the job as a beads issue first (`bd create`), with the ask, the repo, links, and what done looks like. The issue is the whole spec; never put the ask on the spawn command line.
2. Pick the stage from the ask: `bstack` runs it through opencode on the bstack lead's model. Use `--binary opencode` with `--stage start` (Claude) or `--stage codex` (GPT) to run that provider through opencode instead. To get a PR green, use `--stage autopilot` with `--worktree` on the PR's checkout (`wt list`): it is the only stage that may push.
3. A job with its own branch gets `--branch NAME`, so it opens a sibling desk. Anything else runs headless.
4. Report the spawn JSON (or the result file of a headless run) and stop.
