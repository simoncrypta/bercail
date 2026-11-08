---
description: Hand a job to a parallel desk as a beads issue
---
Load the `handoff` skill and follow it. The job: $ARGUMENTS

1. Write the job as a beads issue first (`bd create`), with the ask, the repo, links, and what done looks like. The issue is the whole spec; never put the ask on the spawn command line.
2. Every handoff opens an interactive desk. Use `--branch NAME --stage bstack --issue ID` for a job with its own branch. The current script still launches opencode for stage `bstack`; do not claim it starts Pi until the desk launcher supports it.
3. For a scoped task in the current checkout, start an interactive `hc` sibling using the appropriate bstack template, the way your instructions say. For a PR, use `bstack-autopilot` in its checkout. Do not use a one-shot print mode or the script's `--worktree` mode.
4. Report the desk or sibling address and stop. When `$HC_TERMINAL_ID` is empty, ask the person to open a Herdr desk first.
