---
description: Prove the current work with tests and the repo's verify skill, write its description, stage it, and report. It never commits or publishes
---
Validate the current work for my review in tuicr. $ARGUMENTS

Start by running `git status --short 2>&1 | head -50`, then look for this repo's verify skill: `ls "$(git rev-parse --show-toplevel)"/.agents/skills/verify-*/SKILL.md`.

Fix what fails at each step, then rerun that step. Note every command, its exit code, and where its evidence is.

1. Re-read the job (the beads issue when there is one) and check each part of it is done.
2. Run the tests that cover the diff. Check new and changed tests against the `unit-testing` skill's review list: each fails without the change and touches no real state.
3. When the repo has a verify skill, read it and follow it from launch to cleanup.
4. Run the `unslop` skill on the diff: debug output, dead code, narrating comments, unrelated edits.
5. Stage everything with `git add`. Desks stage their work for the person's review; Shep or the person commits and integrates it the way the repo's git policy says. So stage, and do not commit, even when the policy lets agents commit.
6. Write the description with the `describe` skill: `.bercail/validate.json` with the checks from steps 2 and 3 for the staged tree, then `.bercail/description.md`, then `bercail describe stamp` and `bercail describe check`. Fix every failure. The check's `the change:` line gives its size and stakes. Over the repo's diff budget is a warning, not a failure: split the change when it is several, or say in the description why it is one.
7. Ask `bstack-judge`, every time, giving it the staged diff (`git diff --cached`), `.bercail/description.md`, `.bercail/validate.json`, and the beads issue when there is one. Does the diff do what the issue asks, or, without an issue, what the description's intent says? Is every claim in the description backed by the diff or by `validate.json`? What in the diff could be removed or is not needed: a new abstraction, option, wrapper or file nothing requires? It changes nothing. Fix what is missing, never asked for, or not backed, then redo the steps it touches. What could be removed is a finding to weigh, not a failure, unless it is work the job never asked for.
8. Report: what changed, its size and stakes (the check's `the change:` line; say plainly when the person must review it before it lands), each check with its exit code and evidence path, the judge's answer, the description as `bercail describe title` and `bercail describe body` print it, and what is left. In a headless handoff, also put the checks in the result file's `verification` array.

/validate never commits, pushes, or opens a PR. Publishing is a separate ask, done the way the `describe` skill and the git policy say.
