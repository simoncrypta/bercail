---
# managed by bercail (bstack). `bercail update` rewrites this file; delete this line to keep your own.
description: Read-only decisions pass on a bercail review-pr run dir, producing one JSON block
agent: bstack-pr-review
---
Review the PR in this bercail review-pr run dir and follow your instructions: $ARGUMENTS

If no run dir is given, use the current PR's run dir in this stack. `bercail review-pr <url>` makes it. `bercail review-pr run` runs this pass headless and keeps its JSON for the card.
