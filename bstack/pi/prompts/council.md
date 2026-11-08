---
description: Review the current change with one reviewer per provider (Claude, GPT, Grok) and keep only findings that hold up
---
Load the `council` skill and follow it. Review target: $ARGUMENTS

If no target is given, review the uncommitted change in this checkout (staged and unstaged). Start by running `git status --short 2>&1 | head -50`.

Each reviewer is a `bstack-council-<family>` template from `hc templates`, started as an interactive sibling terminal the way your instructions say. When `$HC_TERMINAL_ID` is empty, ask the person to open a Herdr desk and stop; do not replace the council with a single-agent review.
