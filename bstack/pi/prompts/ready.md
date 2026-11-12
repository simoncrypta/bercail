---
description: Finish the current work for review - prove it with tests and the repo's verify skill, stage it, and report
---
Get the current work ready for my review in tuicr. $ARGUMENTS

Start by running `git status --short 2>&1 | head -50`, then look for this repo's verify skill: `ls "$(git rev-parse --show-toplevel)"/.agents/skills/verify-*/SKILL.md`.

Fix what fails at each step, then rerun that step. Note every command, its exit code, and where its evidence is.

1. Re-read the job (the beads issue when there is one) and check each part of it is done.
2. Run the tests that cover the diff. Check new and changed tests against the `unit-testing` skill's review list: each fails without the change and touches no real state. Read `git` (`gh` | `gt` | `origin`) from `handoff-spawn --info`; dependent branches must use that backend's stack commands (`gh stack init/add/submit/sync`, `gt create/track/submit/get`, or `origin stack track/get/restack/push` and `origin pr create --stack-on`). Never run `gt` in a `gh` repo or hand-make a PR merely based on another PR's branch. This readiness check does not authorize submitting, pushing, or merging.
3. When the repo has a verify skill, read it and follow it from launch to cleanup.
4. When a beads issue names the job, ask `bstack-judge` one question, giving it the issue and the diff: does the diff match the issue? It names what is missing or was never asked for, and it changes nothing.
5. Run the `unslop` skill on the diff: debug output, dead code, narrating comments, unrelated edits.
6. Stage everything with `git add`. Do not commit or push, whatever the repo's git policy allows; it says how once someone asks.
7. Report: what changed, each check with its exit code and evidence path, the judge's answer, what is left. In a headless handoff, also put the checks in the result file's `verification` array.
