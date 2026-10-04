---
name: handoff
description: >-
  Routes a named handoff stage via scripts/handoff-spawn. Intake (handoff-brief)
  writes one job brief before any harness. Stage start is one headless claude
  process, not a Herdr pane. Stage cursor is the parallel sibling worktree:
  sticky layout, cursor-agent with /poteto-mode. Use when the user asks to hand
  off, plan a job, or spawn parallel features. Call by name: handoff.
compatibility: Requires herdr, wt (worktrunk), and the sticky-agent Herdr layout helpers.
---

# handoff

Do not inspect git, Graphite, Herdr, or worktrees yourself. Run `--info`, then spawn.

```bash
"$HOME/.agents/skills/handoff/scripts/handoff-spawn" --info
```

That JSON is the only context you need: `herdr`, `herdr_env`, `socket`,
`main_checkout`, `cwd`, `branch`, `dirty`, `graphite`, `pstack`,
`default_copy`, `helper`, `workspace`, `pending_prompt`.

- If `herdr` is false, report that and stop.
- If `main_checkout` is false, report that and stop (do not spawn from a linked worktree).
- `main_checkout` means the primary git worktree, not “on trunk”.
- If `pstack` is false, tell the user to install it in Cursor (`/add-plugin pstack`). The cursor stage still starts cursor-agent with `/poteto-mode`. Other stages do not.

Never put the original user prompt on the spawn command line. Never `python -c`,
never a wrapper `.sh`, never `handoff-spawn <branch> -- <prompt>`. Auto-review
rejects those as unbound executable content.


## Intake (not a stage)

A Linear issue, a direct ask, or a note all become one job brief before any
harness runs. Do not put the ask on argv.

```bash
"$HOME/.agents/skills/handoff/scripts/handoff-brief" \
  --source ask|linear|note --worktree <checkout> --repo <url-or-path> \
  --ask-file <path> [--link <url>]
```

That writes `<worktree>/.bercail/job-brief.json` (`ask`, `repo`, `links`, `source`).

## Start stage (headless claude)

Shep runs this. It does not open a claude TUI in Herdr. It execs one `claude --print`
process. The process restates the ask, pushes back when the brief is thin, and
writes `<worktree>/.bercail/handoff-result.json` (`status`, `summary`, `session_id`).
Read that file. Do not scrape terminal output.

```bash
"$HOME/.agents/skills/handoff/scripts/handoff-spawn" \
  --stage start --worktree <checkout> [--dry-run]
"$HOME/.agents/skills/handoff/scripts/handoff-spawn" \
  --stage start --worktree <checkout> --resume <session_id>
```

`--resume` continues that session. It does not kill a pane. `--dry-run` prints
the argv as JSON and does not exec. Arena, implement, and the Composer review
pane are not stages yet. Add a row to `scripts/handoff-stages.sh` later.

## Spawn (Grok Bot / machine shell / Auto-review)

1. Write the **original user prompt** as plain text to `pending_prompt` from
   `--info` (a file-write tool, not a new script).
2. Run the **resolved script directly** (absolute path below). Set the process
   working directory to `cwd` from `--info`. Flags only.

```bash
"$HOME/.agents/skills/handoff/scripts/handoff-spawn" \
  --branch <name> --clean --workspace <id> --take-pending
```

- `--workspace` is required when `herdr_env` is false (socket-only parent).
  Use `workspace` from `--info` or the parent Herdr id (e.g. `w26`).
- `--dirty` / `--clean` override `default_copy`.
- `--plan` — add “Plan/design only; do not implement yet.”
- Do not `herdr pane run` this spawn. `--info` via pane run is fine; spawn-with-prompt
  via pane run is what Auto-review binds.

`--take-pending` consumes and deletes the pending file.

## Spawn (already inside a Herdr pane TTY)

Stdin is allowed when it is not a TTY (heredoc). Still no `-- prompt` on argv.

```bash
"$HOME/.agents/skills/handoff/scripts/handoff-spawn" --branch <name> --clean <<'EOF'
<original user prompt only>
EOF
```

## Cursor stage (parallel sibling)

`--branch` defaults to stage `cursor`: sibling worktree, optional dirty copy,
sticky pane. The stage table sets `WT_HERDR_AGENT_CMD`. `/poteto-mode` is
prefixed only because that stage's binary is cursor-agent.

## After a cursor-stage spawn

The script prints JSON: `label`, `path`, `branch`, `task`, `agent_started`,
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
