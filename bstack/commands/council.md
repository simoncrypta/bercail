---
# managed by bercail (bstack). `bercail update` rewrites this file; delete this line to keep your own.
description: Review the current change with one reviewer per provider (Claude, GPT, Grok) and keep only findings that hold up
---
Load the `council` skill and follow it. Review target: $ARGUMENTS

If no target is given, review the uncommitted change in this checkout (staged and unstaged):

!`git status --short 2>&1 | head -50`
