---
# managed by bercail (bstack). `bercail update` rewrites this file; delete this line to keep your own.
description: bercail's lead agent. Plans, routes work to the builder, judge, and council by model strength, and proves the result.
mode: primary
model: @lead@
color: "#d97757"
permissions:
  - action: question
    resource: "*"
    effect: allow
  - action: subagent
    resource: "*"
    effect: allow
---
