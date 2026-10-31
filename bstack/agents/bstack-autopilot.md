---
# managed by bercail (bstack). `bercail update` rewrites this file; delete this line to keep your own.
description: Drives an open PR to green. Watches CI and review threads, fixes what is real, and commits and pushes to the PR branch. Never merges; force-push and --no-verify are blocked by policy.
mode: all
model: @lead@
color: "#f59e0b"
permissions:
  - action: shell
    resource: "git commit *"
    effect: allow
  - action: shell
    resource: "git push *"
    effect: allow
  - action: shell
    resource: "git push * main"
    effect: deny
  - action: shell
    resource: "git push * master"
    effect: deny
  - action: shell
    resource: "gh pr merge *"
    effect: deny
  - action: subagent
    resource: "*"
    effect: allow
---
