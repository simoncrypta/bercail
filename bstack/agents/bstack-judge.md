---
# managed by bercail (bstack). `bercail update` rewrites this file; delete this line to keep your own.
description: The strongest reasoner. Use for the hardest changes, design decisions, plans, prose, and for settling a disagreement between reviewers.
mode: subagent
model: @judge@
color: "#a78bfa"
permissions:
  - action: shell
    resource: "git commit *"
    effect: deny
  - action: shell
    resource: "git push *"
    effect: deny
---
