---
# managed by bercail (bstack). `bercail update` rewrites this file; delete this line to keep your own.
description: Writes code from a precise brief (feature, refactor, bug fix, perf) and proves it with the command the brief names. Give it the goal, files, constraints, and what done looks like.
mode: subagent
model: @build@
color: "#4f9cf9"
permissions:
  - action: shell
    resource: "git commit *"
    effect: deny
  - action: shell
    resource: "git push *"
    effect: deny
---
