---
description: Watch a PR's CI and review threads, fix what is real, push, and stop when it is green
---
Drive this PR to green: $ARGUMENTS

If no PR is given, use the PR for the current branch.

If `$BERCAIL_ROLE` is `autopilot`, load the `autopilot` skill and follow it. Its scripts are in the skill's `scripts/` folder.

Otherwise start the `bstack-autopilot` template as an interactive sibling terminal, the way your instructions say, in the PR's checkout, and label it `bercail.role=bstack-autopilot`. Only that role may push. Wait for its report and pass it on. When `$HC_TERMINAL_ID` is empty, ask the person to open a Herdr desk and stop. A headless `handoff-spawn --stage autopilot --worktree` runs Pi single-agent.
