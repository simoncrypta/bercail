---
# managed by bercail (bstack). `bercail update` rewrites this file; delete this line to keep your own.
description: Watch a PR's CI and review threads, fix what is real, push, and stop when it is green
agent: bstack-autopilot
---
Load the `autopilot` skill and follow it. The PR: $ARGUMENTS

If no PR is given, use the PR for the current branch. Its scripts are in the skill's `scripts/` folder.
