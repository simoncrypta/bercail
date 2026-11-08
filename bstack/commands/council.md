---
# managed by bercail (bstack). `bercail update` rewrites this file; delete this line to keep your own.
description: Adversarial review on request. Reviewers must prove each finding with a run, and only findings a rerun confirms are reported
---
Load the `council` skill and follow it. Review target: $ARGUMENTS

If no target is given, review the uncommitted change in this checkout (staged and unstaged):

!`git status --short 2>&1 | head -50`
