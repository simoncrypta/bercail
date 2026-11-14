---
name: handoff
description: >-
  Routes a named handoff stage via scripts/handoff-spawn. The job is a beads
  issue (bd); the agent prompt is one line pointing at it. Stages are bstack
  and autopilot, both headless Pi (`pi -p`). Autopilot is that run with
  `BERCAIL_ROLE=autopilot` and may commit and push a PR's fixes. Neither opens
  anything in the Herdr app. `--branch` makes a sibling worktree whose desk
  runs Pi's lead. Shep owns the workflow; bercail adds no per-stage mode.
  Use when the user asks to hand off, plan a job, or spawn parallel features.
  Call by name: handoff.
compatibility: Requires bd (beads), wt (worktrunk), the Herdr app (herdr-app) with herdr-core (hc), and bercail's worktrunk helpers.
---

# handoff

Do not inspect git, Graphite, the Herdr app, or worktrees yourself. Run `--info`, then spawn.

```bash
"$HOME/.agents/skills/handoff/scripts/handoff-spawn" --info
```

That JSON is the only context you need: `herdr` (the Herdr app answers),
`herdr_env` (this shell is an hc terminal), `main_checkout`, `cwd`,
`branch`, `dirty`, `git` (`gh` | `gt` | `origin` | `entire`), `entire` (Entire
captures the agents' sessions here), `default_copy`, `helper`,
`space` (the app space the user is looking at), `beads`.

- If `herdr` is false and you need `--branch`, report that the Herdr app is not open and stop.
  Headless stages do not need it.
- If `beads` is false, report that bd is missing and stop.
- If `main_checkout` is false, report that and stop (do not spawn from a linked worktree).
- `main_checkout` means the primary git worktree, not “on trunk”.

Never put the user's ask on the spawn command line; it goes in the beads issue.
Never `python -c`, never a wrapper `.sh`, never argv after `--`.


## The job is a beads issue

Shep writes the job as a beads issue first (`bd create`, `bd show <id>`). The
issue holds the ask, the repo, links, and any plan-only note. There are no
prompt files, briefs, or pending prompts. The agent's whole prompt is one line
pointing at the issue (`Your job is beads issue <id>: <title>. Run bd show <id> …`,
or the id alone when bd has no title). Shep owns the workflow
(planning, review, which stage); bercail has no default stage.

Each real handoff adds a `bd comment` to the issue with what the agent needs
from bercail: the worktree, and for headless stages the result file and
session id. `--info` reports `beads` (bd on PATH). bercail install and update
install beads; the command is `bd`.

## Headless stages (Pi)

Shep runs these. They do not open anything in the Herdr app. Stages are
`bstack` and `autopilot`. Both are one `pi -p --mode json --session-id <uuid>`
process on the lead's profile. Pi mints the session uuid up front; resume
passes the same `--session-id`. `--resume` refuses anything that is not a uuid.
`--stage autopilot` is that run with `BERCAIL_ROLE=autopilot`: it may commit
and push, and the guard blocks a push to main or master, a force-push, and a
merge. Point `--worktree` at the PR's checkout (headless only). Pi has no
`--add-dir`. A linked worktree's `.beads/redirect` points `bd` at the main
checkout, so the agent can still run `bd` there.

If `pi`, bd, or the issue is missing, the stage writes
`<worktree>/.bercail/handoff-result.json` with status `blocked`, starts
nothing, and exits nonzero. It does not fall through to another stage. The
agent writes the same result file (`status`, `summary`, and bercail fills
`session_id`), with an optional `verification` array of
`{kind: test|verify-skill, command, exit_code, evidence}`; bercail
drops a malformed array and keeps the rest of the result. When the run stops on a plan usage limit, bercail adds `reason`:
`usage-limit`. It does not rerun or switch plans. Read that file. Do not scrape
terminal output. `session_id` is the uuid bercail passed, or the session
header's id when Pi reports a different one. When there is no resumable
session, `session_id` is `none`; `--resume` refuses it.

```bash
"$HOME/.agents/skills/handoff/scripts/handoff-spawn" \
  --stage bstack --issue <id> --worktree <checkout> [--resume <uuid>] [--dry-run] [--model <provider/id[:thinking]>]
"$HOME/.agents/skills/handoff/scripts/handoff-spawn" \
  --stage autopilot --issue <id> --worktree <the PR's checkout> [--resume <uuid>] [--model <provider/id[:thinking]>]
```

`--resume` continues that session. It does not touch any desk agent. `--dry-run` prints
the argv as JSON, even when `pi` or bd is
not on PATH (`present`, `bd_present`). It does not run Pi, check the
issue or the model, or comment; it may ask `bd show` for the title. A missing lead profile
fails the dry run and writes no result.

## Spawn a `--branch` desk

Run the **resolved script directly** (absolute path below). Set the process
working directory to `cwd` from `--info`. Flags only.

```bash
"$HOME/.agents/skills/handoff/scripts/handoff-spawn" \
  --branch <name> --stage bstack --issue <id> --clean --space <id>
```

- `--space <id>` is optional: the app space to keep on screen. By
  default the user stays on whatever space they are looking at.
- `--dirty` / `--clean` override `default_copy` (a dirty main checkout is copied, a clean
  one starts from HEAD). The copy is the main checkout's `git diff HEAD` plus its untracked
  files, put in the sibling as unstaged work before the desk starts; nothing is `git add`ed.
- `--base <branch>` is optional: dependent issues stack on the parent's branch via `--base` (`wt switch --create --base`), then register the parent with the `git` backend from `--info`: `gh stack`, `gt track`, or `origin stack track`; `entire` has no stacks, so the trail names its base (`entire trail create --base`). Without it the branch is cut from the default branch. Publish and update through that backend's stack commands, never a hand-made PR merely based on another PR's branch. See [Git backend](#git-backend). Never run `gt` unless `git` is `gt`.
- `--model <provider/id[:thinking]>` is optional: run this one agent on another Pi model, such as
  `claude-bridge/claude-fable-5-2:high`, when the person asks for one. See [Another model](#another-model).
- Plan-only work is a line in the issue, not a flag.
- `--branch` needs bstack's Pi lead profile (`bercail update` writes it). Autopilot cannot take `--branch`.
## The desk (`--branch`)

`--branch` makes a sibling worktree (`wt switch --create`), opens a Herdr app
space on it (worktrunk's post-start hook), and starts that space's desk agent:
an hc terminal running Pi's lead (an empty command, so `bercail-desk-agent`
reads `lead.json`) with a one-line prompt pointing at the issue as its first message, labelled
`bercail.role=agent`, `bercail.space=<space id>`, and, when known, `bercail.issue` and `bercail.issue_title`. The bercail layout shows
it in the desk column. `--stage` is required; bercail has no default stage.
A missing lead profile fails before any worktree is made. A desk already running in
that space is replaced. `wt remove <branch>` closes the space and its desk.

## Another model

`--model <provider/id[:thinking]>` runs one agent, desk or headless, on that Pi
model instead of the lead's. Nothing else in the lead changes: the same
extensions, guard, prompts, skills, and instructions. Name the model as
`pi --list-models` does (`claude-bridge/claude-fable-5-2`). A `:thinking`
suffix (`off`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max`) is kept;
without one, the agent gets the lead's level. Before anything starts, bercail
asks `pi --list-models`, with the lead's extensions loaded, for the model, and
refuses one Pi does not list. A `--dry-run` skips that check.

A desk on another model is labelled `bercail.model=<model>`, its spawn JSON and
`handoffs.jsonl` line carry `model`, and `bercail shep brief` and `bercail shep
board` name it. Its desk record keeps the swapped `--model`, so
`bercail desk restore` brings it back on the same model. The sibling roles it
starts (builder, judge, council, autopilot templates) keep their own models.
Without `--model`, every agent runs the lead's.

## Git backend

`--info` and the spawn JSON report one `git` backend for the repo: `gh`, `gt`,
`origin`, or `entire` (a repo hosted on Entire, where trails are the PRs). Read it; do not detect it yourself, and never probe with `gt`,
which initializes any repo it runs in. A linked worktree uses its main
checkout's choice. How to publish and update a stack on each backend is in
[git-workflow.md](resources/git-workflow.md).

When the spawn warns that it could not tell (an unreadable Graphite store, a
failed Origin lookup) or notes a Graphite config with nothing tracked, the
person settles it in `~/.config/bercail/config.toml`, keyed by main checkout:

```toml
[git]
"~/Work/some-repo" = "gt"   # gh | gt | origin | entire
```

Registering the new branch with `gt` can fail or hang. The spawn then prints a
warning with the `gt track` command to run, and the desk still starts.

## After a `--branch` spawn

The script prints JSON: `ok`, `label`, `path`, `branch`, `issue`, `issue_title`
(when known), `agent_started`, `dirty_copied`, `git`, `stage`, `harness`, `space` (the
child's Herdr app space), `desk` (the desk agent's hc address), and `model` when `--model` was given. It appends that line to
`~/.local/state/bercail/handoffs.jsonl` whenever the sibling exists.

Report that tuple and stop. If the script exits nonzero before creating a
worktree, report the error and stop. Do not `hc send` to the desk agent, type
into it, or switch the user to its space. To see how it is doing, read
it: `hc get <desk>`, `hc wait <desk>`, with `desk` from that JSON (or the
terminal labelled `bercail.space=<space>` in `hc ls`).

## When not to use

- Ordinary coding in the **current** worktree with no handoff.
- `--branch` while the Herdr app is not open (`herdr` is false).
- Pure Worktrunk config/hook questions — escalate hook approvals to the user.

## Other Worktrunk control

Not the spawn path: `resources/worktrunk.md`, `resources/babysit.md`,
`resources/herdr-control.md` (herdr-app and hc).
