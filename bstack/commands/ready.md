---
# managed by bercail (bstack). `bercail update` rewrites this file; delete this line to keep your own.
description: Finish the current work for review - prove it, run the council, stage it, and report
---
Get the current work ready for my review in tuicr. $ARGUMENTS

!`git status --short 2>&1 | head -50`

1. Re-read the job (the beads issue when there is one) and check each part of it is done.
2. Prove it on the real thing: run the tests and the command or app path the change touches. Fix what fails.
3. Run the `council` skill on the change. Fix the findings that hold up.
4. Run the `unslop` skill on the diff: debug output, dead code, narrating comments, unrelated edits.
5. Stage everything with `git add`. Do not commit or push.
6. Report in five lines or fewer: what changed, what you ran, what the council found, what is left.
