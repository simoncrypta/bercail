---
description: Hand a job to a parallel desk as a beads issue
---
Load the `handoff` skill and follow it. The job: $ARGUMENTS

1. Write the job as a beads issue first (`bd create`), with the ask, the repo, links, and what done looks like. The issue is the whole spec; never put the ask on the spawn command line.
2. Every handoff opens an interactive desk. Use `--branch NAME --stage bstack --issue ID` for a job with its own branch. A headless `--stage bstack --worktree` runs Pi single-agent. `--stage autopilot` is that Pi run for a PR's checkout.
3. For a scoped task in the current checkout, start an interactive `hc` sibling using the appropriate bstack template, the way your instructions say. For a PR, use `bstack-autopilot` in its checkout. Prefer that desk over a one-shot print mode.
4. Report the desk or sibling address and stop. When `$HC_TERMINAL_ID` is empty, ask the person to open a Herdr desk first.
