---
name: handoff
description: >-
  Routes a named handoff stage via scripts/handoff-spawn. The job is a beads
  issue (bd); the agent prompt is one line pointing at it. Stage start is one headless claude
  process. Stage codex is one headless `codex exec` process. Stage cursor is
  one headless `cursor-agent --print` process. Stage bstack is one headless
  `pi -p` process (opencode only when `[bstack] harness = "opencode"`); stage
  autopilot is the same run with `BERCAIL_ROLE=autopilot`, which may commit and
  push a PR's fixes. None of those open anything in
  the Herdr app. `--branch` makes a sibling worktree with its own Herdr app
  space whose desk agent runs the stage's binary. Shep owns the workflow;
  bercail adds no per-harness mode.
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
`herdr_env` (this shell is an hc terminal), `socket`, `main_checkout`, `cwd`,
`branch`, `dirty`, `git` (`gh` | `gt` | `origin`), `graphite` (legacy,
true only for `gt`), `default_copy`, `helper`, `space` (the
app space the user is looking at), `beads`.

- If `herdr` is false and you need `--branch`, report that the Herdr app is not open and stop.
  Headless stages do not need it.
- If `beads` is false, report that bd is missing and stop.
- If `main_checkout` is false, report that and stop (do not spawn from a linked worktree).
- `main_checkout` means the primary git worktree, not “on trunk”.

Never put the user's ask on the spawn command line; it goes in the beads issue.
Never `python -c`, never a wrapper `.sh`, never `handoff-spawn <branch> -- <prompt>`.
Auto-review rejects those as unbound executable content.


## The job is a beads issue

Shep writes the job as a beads issue first (`bd create`, `bd show <id>`). The
issue holds the ask, the repo, links, and any plan-only note. There are no
prompt files, briefs, or pending prompts. The agent's whole prompt is one line
pointing at the issue (`Your job is beads issue <id>: <title>. Run bd show <id> …`,
or the id alone when bd has no title), the same for claude, codex, and cursor-agent. Shep owns the workflow
(planning, review, which harness); bercail has no cursor-only mode.

Each real handoff adds a `bd comment` to the issue with what the agent needs
from bercail: the worktree, and for headless stages the result file and
session id. `--info` reports `beads` (bd on PATH). bercail install and update
install beads; the command is `bd`.

## Headless stages (claude, Codex, cursor-agent, or Pi)

Shep runs these. They do not open anything in the Herdr app. Bercail has no preference
among claude, codex, and cursor-agent; the caller names the stage or
`--binary`. `--stage start` is one `claude --print` process. `bercail harness`
lists claude, codex, and cursor-agent with `present` and a local `model_hint`.
It does not choose. Missing CLIs are `present: false`, not an error.
`--stage codex` or `--binary codex` is one
`codex exec --json` process (`-m` when the table has a model; resume is
`codex exec resume`). `--stage cursor` or `--binary cursor-agent` is one
`cursor-agent --print --output-format json` process (`--model` when the table
has a model; resume is `--resume <session_id>`). `--stage bstack` is one
`pi -p --mode json --session-id <uuid>` process on the lead's profile, unless
`[bstack] harness = "opencode"`, which keeps `opencode run --format json
--agent bstack`. `--binary pi` on start uses the claude family model and on
codex the gpt family; cursor and bstack use the lead. `--binary opencode` still
runs opencode and keeps that provider (start: claude, codex: gpt). Pi has no
`--add-dir`. It mints the session uuid up front; resume passes the same
`--session-id`. An opencode `ses_` id cannot be resumed on Pi. `--stage
autopilot` is the same Pi run with `BERCAIL_ROLE=autopilot` (or opencode's
`bstack-autopilot` when that harness is selected): it may commit and push, and
the guard blocks a push to main or master, a force-push, and a merge. Point
`--worktree` at the PR's checkout (headless only). claude gets `Bash(bd *)` so
it can run bd in `--print`. When bd's `.beads` is outside the worktree (a
linked worktree), claude, codex, and cursor-agent get `--add-dir` for it.

If the requested harness, bd, or the issue is missing, the stage writes
`<worktree>/.bercail/handoff-result.json` with status `blocked`, starts
nothing, and exits nonzero. It does not fall through to another harness. The
agent writes the same result file (`status`, `summary`, and bercail fills
`session_id`), with an optional `verification` array of
`{kind: test|verify-skill|statechart, command, exit_code, evidence}`; bercail
drops a malformed array and keeps the rest of the result. When the run stops on a plan usage limit, bercail adds `reason`:
`usage-limit`. It does not rerun or switch plans. Read that file. Do not scrape
terminal output. For Codex,
`session_id` is the JSONL `thread.started` thread id. For cursor-agent, it is
the print JSON `session_id`. For Pi, it is the uuid bercail passed, or the
session header's id when Pi reports a different one. When there is no resumable session (blocked before
codex or cursor-agent ran, or no id in its log), `session_id` is `none`;
`--resume` refuses it.

```bash
bercail harness
"$HOME/.agents/skills/handoff/scripts/handoff-spawn" \
  --stage start --issue <id> --worktree <checkout> [--binary claude|codex|cursor-agent|opencode|pi] [--dry-run]
"$HOME/.agents/skills/handoff/scripts/handoff-spawn" \
  --stage start --issue <id> --worktree <checkout> --resume <session_id>
"$HOME/.agents/skills/handoff/scripts/handoff-spawn" \
  --stage codex --issue <id> --worktree <checkout> [--resume <session_id>] [--dry-run]
"$HOME/.agents/skills/handoff/scripts/handoff-spawn" \
  --stage cursor --issue <id> --worktree <checkout> [--resume <session_id>] [--dry-run]
"$HOME/.agents/skills/handoff/scripts/handoff-spawn" \
  --stage bstack --issue <id> --worktree <checkout> [--resume <uuid>] [--dry-run]
"$HOME/.agents/skills/handoff/scripts/handoff-spawn" \
  --stage autopilot --issue <id> --worktree <the PR's checkout> [--resume <uuid>]
```

`--resume` continues that session. It does not touch any desk agent. `--dry-run` prints
the argv as JSON for any of the three stages, even when that binary or bd is
not on PATH (`present`, `bd_present`). It does not run the harness, check the
issue, or comment; it may ask `bd context` where `.beads` is. Arena,
implement, and the Composer review pane are not stages yet. Add a row to
`scripts/handoff-stages.sh` later.

## Spawn a `--branch` desk

Run the **resolved script directly** (absolute path below). Set the process
working directory to `cwd` from `--info`. Flags only.

```bash
"$HOME/.agents/skills/handoff/scripts/handoff-spawn" \
  --branch <name> --stage start|codex|cursor|bstack --issue <id> --clean --space <id>
```

- `--space <id>` is optional (`--workspace` is the same flag): the app space to keep on screen. By
  default the user stays on whatever space they are looking at.
- `--dirty` / `--clean` override `default_copy`.
- `--base <branch>` is optional: dependent issues stack on the parent's branch via `--base` (`wt switch --create --base`), then register the parent with the `git` backend from `--info`: `gh stack`, `gt track`, or `origin stack track`. Without it the branch is cut from the default branch. Publish and update through that backend's stack commands, never a hand-made PR merely based on another PR's branch. See [git-workflow.md](resources/git-workflow.md). Never run `gt` unless `git` is `gt`.
- Plan-only work is a line in the issue, not a flag.
## The desk (`--branch`)

`--branch` makes a sibling worktree (`wt switch --create`), opens a Herdr app
space on it (worktrunk's post-start hook), and starts that space's desk agent:
an hc terminal running the named stage's binary (claude, codex,
cursor-agent, or pi) with a one-line prompt pointing at the issue as its first message, labelled
`bercail.role=agent`, `bercail.space=<space id>`, and, when known, `bercail.issue` and `bercail.issue_title`. The bercail layout shows
it in the desk column. `--stage` is required; bercail has no default harness.
A missing binary fails before any worktree is made. A desk already running in
that space is replaced. `wt remove <branch>` closes the space and its desk.

## After a `--branch` spawn

The script prints JSON: `ok`, `label`, `path`, `branch`, `issue`, `issue_title`
(when known), `agent_started`, `dirty_copied`, `graphite`, `stage`, `harness`, `space` (the
child's Herdr app space) and `desk` (the desk agent's hc address). It appends that line to
`~/.local/state/agentic-dev/handoffs.jsonl` whenever the sibling exists.

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
`resources/herdr-control.md` (herdr-app and hc), `resources/keys.md` (keys,
for user questions only).
