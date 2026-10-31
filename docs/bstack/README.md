# The bstack guide

bstack is bercail's opencode: one harness, your own Claude, ChatGPT, and X
subscriptions behind it, and bercail's loop on top. The agent writes the code, stages it,
and stops. You review it in tuicr. When the PR is open, autopilot gets it green.

The habit this guide teaches: say what you want and how you'll know it's done.
bstack picks the playbook, routes each step to the model that is best at it, and
shows you the evidence.

1. [Set up bstack](./01-setup.md). Connect your plans; models are picked for you.
2. [Work with the bstack agent](./02-the-bstack-agent.md). Playbooks, roles, and what a good prompt holds.
3. [Understand the code](./03-understand.md). `/how`, `/why`, and taking over someone else's branch.
4. [Build and clean the change](./04-build-and-clean.md). The build playbooks and `/unslop`.
5. [Review it](./05-review.md). `/council`, `/ready`, and tuicr.
6. [Ship with autopilot](./06-autopilot.md). A PR to green: CI, review threads, conflicts.
7. [Run jobs in parallel](./07-handoff.md). Beads issues, sibling desks, and headless runs.
8. [Make it yours](./08-make-it-yours.md). Pin models, change roles, keep your own files.
9. [Recipes and pitfalls](./09-recipes-and-pitfalls.md). Prompts to copy and mistakes to skip.

Read them in order once. After that, each page stands alone.

## If you only remember one thing

Give the goal and a check:

```text
the export writes duplicate rows when a retry lands mid-run. repro first, then fix it and prove it.
```

You don't need to name a playbook or a skill. "repro first" and a way to check
the result are enough for the bug fix playbook to take over.

This guide is shaped after the [pstack guide](https://github.com/cursor/plugins/tree/main/pstack/docs/guide).

Next: [Set up bstack](./01-setup.md).
