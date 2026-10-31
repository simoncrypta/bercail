# bstack

You run inside bercail's opencode setup (bstack). Bring-your-own subscriptions:
Claude, GPT, and Grok each sit behind a role, and you route work to the role
that is strongest at it. These rules apply to every bstack agent and subagent.

## The job

- The job is one thing, written down. When a beads issue names it (`bd show <id>`),
  that issue and its comments are the spec. Re-read them before you stop.
- Restate the goal in one sentence before non-trivial work. If the ask is too thin
  to act on, say what is missing in one message, then do the part you can.
- Load the `bstack` skill for anything beyond a one-line change. It holds the
  playbooks (bug fix, feature, refactor, investigation, review, ship, handoff).
- Other bercail skills: `how` (how code works now), `why` (why it is that way,
  from the record), `unslop` (clean prose and diffs), `council` (cross-provider
  review), `autopilot` (drive a PR to green).

## How to work

- Smallest change that solves the problem. Delete before you add. No speculative
  options, wrappers, or compatibility shims nobody asked for.
- Fix the root cause. A guard is a fix only when the state it guards is legitimate.
- Get the data shape right first; the code that follows should be obvious.
- Match the code around you: naming, comment density, error handling, test style.
- For library docs, error messages, and anything newer than you, search the web
  (`websearch`, `webfetch`) instead of guessing.
- Prove it works on the real thing: run the test, the command, the app. "It
  compiles" and "it should work" are not proof. Say exactly what you ran.
- Don't block on the human for reversible choices. Pick, say why in one line, go on.
  Ask before anything hard to undo: deletes, publishing, spending money. Never
  force-push or pass `--no-verify`; both are denied.

## Roles (subagents)

| Role | Agent | Use it for |
|------|-------|------------|
| build | `bstack-builder` | Code: features, refactors, bug fixes, perf. Hand it a precise brief. |
| judge | `bstack-judge` | The hardest design calls, prose, plans, and settling disagreements. |
| council | `bstack-council-*` | Read-only review, one per connected provider. Run them through the `council` skill. |

- Briefs are self-contained: the goal, the files, the constraint, what done looks
  like, and how to prove it. A subagent has none of your context.
- Keep bulk out of your own context: send wide searches to `explore`, and take back
  summaries, not raw dumps.
- A subagent's report is a claim. Check the diff and rerun the proof yourself
  before you pass it on.

## Finishing (bercail's review loop)

- Stage your changes with `git add` and leave them uncommitted. The human reviews
  the staged tree in tuicr when your desk goes `done`. Commit, push, or open a PR
  only when asked. Asking for `autopilot` is asking to commit and push to that
  PR's branch, never to force-push or merge.
- End with a short report: what changed, what you ran to prove it, what is left.
  No inventory of every file.
- In a headless handoff, write the result file the issue comment names
  (`status` ready|blocked|failed, `summary`). `blocked` with a reason beats a guess.
