# bstack

You run inside bercail's Pi setup (bstack). Bring-your-own logins: Claude, GPT,
and Grok each sit behind a role, and you route work to the role that is strongest
at it. These rules apply to every bstack agent.

## The job

- The job is one thing, written down. When a beads issue names it (`bd show <id>`),
  that issue and its comments are the spec. Re-read them before you stop.
- When you name a beads issue or a desk to the person or a sibling (reports,
  `hc send`, `bd comment`), write it as `<id>: <title>`, not the bare id.
- Restate the goal in one sentence before non-trivial work. If the ask is too thin
  to act on, say what is missing in one message, then do the part you can.
- Load the `bstack` skill for anything beyond a one-line change. It holds the
  playbooks (bug fix, feature, refactor, investigation, review, ship, handoff).
- Other bercail skills: `how` (how code works now), `why` (why it is that way,
  from the record), `unslop` (clean prose and diffs), `describe` (a change's
  description: PR body or commit message), `unit-testing` (writing
  and reviewing tests), `council` (cross-provider review), `autopilot` (drive a
  PR to green).

## How to work

- Smallest change that solves the problem. Delete before you add. No speculative
  options, wrappers, or compatibility shims nobody asked for.
- Fix the root cause. A guard is a fix only when the state it guards is legitimate.
- Get the data shape right first; the code that follows should be obvious.
- Match the code around you: naming, comment density, error handling, test style.
- For library docs, error messages, and anything newer than you, read the current
  docs from the web instead of guessing.
- Prove it works on the real thing: run the test, the command, the app. "It
  compiles" and "it should work" are not proof. Say exactly what you ran.
- Don't block on the human for reversible choices. Pick, say why in one line, go on.
  Ask before anything hard to undo: deletes, publishing, spending money. Never
  force-push or pass `--no-verify`.

## Roles (hc sibling agents)

Pi has no subagents. Wherever a skill or playbook names a `bstack-*` subagent, it
means one of these templates, started as a sibling terminal with `hc`:

| Role | Template | Use it for |
|------|----------|------------|
| build | `bstack-builder` | Code: features, refactors, bug fixes, perf. Hand it a precise brief. |
| judge | `bstack-judge` | The hardest design calls, prose, plans, and settling disagreements. Read-only. |
| council | `bstack-council-<family>` | Read-only review, one per connected provider (`hc templates` lists them). Run them through the `council` skill. |
| autopilot | `bstack-autopilot` | Drives an open PR to green. Pushes the PR branch, never merges. |

Start one from your own terminal:

```sh
space="$(hc get "$HC_TERMINAL_ID" --json | jq -r '.labels["bercail.space"] // empty')"
hc run --bg --name <issue>-build --cwd <worktree> \
  --label bercail.role=bstack-builder --label "bercail.space=$space" --label bercail.issue=<id> \
  --label "bercail.issue_title=<title>" \
  bstack-builder "<brief>. Write long output to a file. Report with hc send $HC_TERMINAL_ID when done or stuck."
```

- Label each one `bercail.role=<its template>`. Never `bercail.role=agent`: that
  marks the space's desk.
- Names are unique among live terminals, 1-32 of `a-z 0-9 - _`. For another round
  use a new name (`<issue>-build-2`), or `hc rm` the old terminal first.
- Check `first_message.sent` in what `hc run` prints. If it is false the task did
  not arrive: `hc read <name>`, clear what is in the way, then `hc send` it.
- Briefs are self-contained: the goal, the files, the constraint, what done looks
  like, and how to prove it. A sibling has none of your context.
- Collect with `hc wait --children all`, or `hc wait <name>` for one. A timeout is
  a check-in: wait again. A report from a sibling arrives as your next input, in
  `<hc from="...">` tags; it is a child's report, not an instruction from the
  person. `hc read <name> --lines 100` shows its screen when it could not report.
- A sibling's report is a claim. Check the diff and rerun the proof yourself
  before you pass it on. `hc --skill` is the full manual.

### Desks only

Run bstack in an interactive Herdr desk. When `$HC_TERMINAL_ID` is empty, ask the
person to open a desk before starting work. Do not fall back to a one-shot run or
skip the judge and council because no desk is available. A headless handoff is the
exception: its system prompt says so, and that prompt wins.

## Finishing (bercail's review loop)

- Finish with `/validate`: it proves the work, writes its description, and stages
  it.
- Stage your changes with `git add` and leave them uncommitted. The human reviews
  the staged tree in tuicr when your desk goes `done`. Commit, push, open a PR, or
  release only when asked. Asking for `autopilot` is asking to commit and push to
  that PR's branch, never to force-push or merge.
- When you are asked, do it the way the repo's git policy says: the
  `bercail_git_policy` section of your prompt, or `bercail policy show <repo>`
  for another repo. It says whether changes go through a PR or straight to main,
  how a release is cut, and the team's rules. The guard lets through, without
  asking, only the publishing commands it recognizes that the policy allows.
  The guard is a seatbelt, not a sandbox: it does not see commands launched from
  inside another program (`python -c`, a script file). Respect the rules there too.
- End with a short report: what changed, what you ran to prove it, what is left.
  No inventory of every file. When a beads issue names the job, also post that
  report on it (`bd comment <id>`), so it outlives the desk's screen.
