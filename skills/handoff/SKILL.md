---
name: handoff
description: >-
  Routes a named handoff stage via scripts/handoff-spawn. The job is a beads
  issue (bd); the agent prompt is only its id. Stage start is one headless claude
  process. Stage codex is one headless `codex exec` process. Stage cursor is
  one headless `cursor-agent --print` process. None of those open a Herdr pane.
  `--branch` clones a sticky pane running the stage's binary. Shep owns the
  workflow; bercail adds no per-harness mode.
  Use when the user asks to hand off, plan a job, or spawn parallel features.
  Call by name: handoff.
compatibility: Requires bd (beads), herdr, wt (worktrunk), and the sticky-agent Herdr layout helpers.
---

# handoff

Do not inspect git, Graphite, Herdr, or worktrees yourself. Run `--info`, then spawn.

```bash
"$HOME/.agents/skills/handoff/scripts/handoff-spawn" --info
```

That JSON is the only context you need: `herdr`, `herdr_env`, `socket`,
`main_checkout`, `cwd`, `branch`, `dirty`, `graphite`,
`default_copy`, `helper`, `workspace`, `beads`.

- If `herdr` is false, report that and stop.
- If `beads` is false, report that bd is missing and stop.
- If `main_checkout` is false, report that and stop (do not spawn from a linked worktree).
- `main_checkout` means the primary git worktree, not “on trunk”.

Never put the user's ask on the spawn command line; it goes in the beads issue.
Never `python -c`, never a wrapper `.sh`, never `handoff-spawn <branch> -- <prompt>`.
Auto-review rejects those as unbound executable content.


## The job is a beads issue

Shep writes the job as a beads issue first (`bd create`, `bd show <id>`). The
issue holds the ask, the repo, links, and any plan-only note. There are no
prompt files, briefs, or pending prompts. The agent's whole prompt is the issue
id, the same for claude, codex, and cursor-agent. Shep owns the workflow
(planning, review, which harness); bercail has no cursor-only mode.

Each real handoff adds a `bd comment` to the issue with what the agent needs
from bercail: the worktree, and for headless stages the result file and
session id. `--info` reports `beads` (bd on PATH). bercail install and update
install beads; the command is `bd`.

## Headless stages (claude, Codex, or cursor-agent)

Shep runs these. They do not open a TUI in Herdr. Bercail has no preference
among claude, codex, and cursor-agent; the caller names the stage or
`--binary`. `--stage start` is one `claude --print` process. `bercail harness`
lists claude, codex, and cursor-agent with `present` and a local `model_hint`.
It does not choose. Missing CLIs are `present: false`, not an error.
`--stage codex` or `--binary codex` is one
`codex exec --json` process (`-m` when the table has a model; resume is
`codex exec resume`). `--stage cursor` or `--binary cursor-agent` is one
`cursor-agent --print --output-format json` process (`--model` when the table
has a model; resume is `--resume <session_id>`). claude gets `Bash(bd *)` so
it can run bd in `--print`. When bd's `.beads` is outside the worktree (a
linked worktree), every harness gets `--add-dir` for it.

If the requested harness, bd, or the issue is missing, the stage writes
`<worktree>/.bercail/handoff-result.json` with status `blocked`, starts
nothing, and exits nonzero. It does not fall through to another harness. The
agent writes the same result file (`status`, `summary`, and bercail fills
`session_id`). Read that file. Do not scrape terminal output. For Codex,
`session_id` is the JSONL `thread.started` thread id. For cursor-agent, it is
the print JSON `session_id`. When there is no resumable session (blocked before
codex or cursor-agent ran, or no id in its log), `session_id` is `none`;
`--resume` refuses it.

```bash
bercail harness
"$HOME/.agents/skills/handoff/scripts/handoff-spawn" \
  --stage start --issue <id> --worktree <checkout> [--binary claude|codex|cursor-agent] [--dry-run]
"$HOME/.agents/skills/handoff/scripts/handoff-spawn" \
  --stage start --issue <id> --worktree <checkout> --resume <session_id>
"$HOME/.agents/skills/handoff/scripts/handoff-spawn" \
  --stage codex --issue <id> --worktree <checkout> [--resume <session_id>] [--dry-run]
"$HOME/.agents/skills/handoff/scripts/handoff-spawn" \
  --stage cursor --issue <id> --worktree <checkout> [--resume <session_id>] [--dry-run]
```

`--resume` continues that session. It does not kill a pane. `--dry-run` prints
the argv as JSON for any of the three stages, even when that binary or bd is
not on PATH (`present`, `bd_present`). It does not run the harness, check the
issue, or comment; it may ask `bd context` where `.beads` is. Arena,
implement, and the Composer review pane are not stages yet. Add a row to
`scripts/handoff-stages.sh` later.

## Spawn a `--branch` pane

Run the **resolved script directly** (absolute path below). Set the process
working directory to `cwd` from `--info`. Flags only.

```bash
"$HOME/.agents/skills/handoff/scripts/handoff-spawn" \
  --branch <name> --stage start|codex|cursor --issue <id> --clean --workspace <id>
```

- `--workspace` is required when `herdr_env` is false (socket-only parent).
  Use `workspace` from `--info` or the parent Herdr id (e.g. `w26`).
- `--dirty` / `--clean` override `default_copy`.
- Plan-only work is a line in the issue, not a flag.
- Do not `herdr pane run` this spawn. `--info` via pane run is fine.

## Sticky pane (`--branch`)

`--branch` clones a sibling worktree with a sticky pane running the named
stage's binary: claude, codex, or cursor-agent. `--stage` is required; bercail
has no default harness. A missing binary fails before any worktree is made.

## After a `--branch` spawn

The script prints JSON: `label`, `path`, `branch`, `issue`, `agent_started`,
`dirty_copied`, `graphite`. It appends that line to
`~/.local/state/agentic-dev/handoffs.jsonl` whenever the sibling exists.

Report that tuple and stop. If the script exits nonzero before creating a
worktree, report the error and stop. Do not `pane run` the child, `agent prompt`,
paste, send-keys, or focus the child.

## When not to use

- Ordinary coding in the **current** worktree with no handoff.
- Herdr unreachable (`herdr` is false).
- Pure Worktrunk config/hook questions — escalate hook approvals to the user.

## Other Herdr / Worktrunk control

Not the spawn path: `resources/herdr-control.md`, `resources/worktrunk.md`,
`resources/keys.md`, `resources/babysit.md`.
