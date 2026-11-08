---
# managed by bercail (bstack). `bercail update` rewrites this file; delete this line to keep your own.
description: Finish the current work for review - prove it with tests, the repo's verify skill and formal checks, stage it, and report
---
Get the current work ready for my review in tuicr. $ARGUMENTS

!`git status --short 2>&1 | head -50`

Verify skill: !`ls "$(git rev-parse --show-toplevel 2>/dev/null)"/.agents/skills/verify-*/SKILL.md 2>/dev/null || echo none`

Fix what fails at each step, then rerun that step. Note every command, its exit code, and where its evidence is.

1. Re-read the job (the beads issue when there is one) and check each part of it is done.
2. Run the tests that cover the diff.
3. When the verify skill above is not `none`, read it and follow it from launch to cleanup.
4. Run any formal check whose coverage the diff touches: a `statechart` spec in `.bercail/statechart/` or committed in the repo. When none covers it, say so.
5. When a beads issue names the job, ask `bstack-judge` one question, giving it the issue and the diff: does the diff match the issue? It names what is missing or was never asked for, and it changes nothing.
6. Run the `unslop` skill on the diff: debug output, dead code, narrating comments, unrelated edits.
7. Stage everything with `git add`. Do not commit or push.
8. Report: what changed, each check with its exit code and evidence path, the judge's answer, what is left. In a headless handoff, also put the checks in the result file's `verification` array.
