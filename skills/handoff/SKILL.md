---
name: handoff
description: >-
  Spawns main-repo to worktree feature handoffs in Herdr via scripts/handoff-spawn:
  sibling worktree, optional dirty copy, sticky layout, cursor-agent with /poteto-mode
  and the original prompt. Any parent agent can call it; the child is always
  cursor-agent. Use when the user asks to hand off, spawn parallel features or
  worktrees. Call by name: handoff.
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
- If `pstack` is false, tell the user to install it in Cursor (`/add-plugin pstack`). Still spawn; the child is cursor-agent with `/poteto-mode`.

Never put the original user prompt on the spawn command line. Never `python -c`,
never a wrapper `.sh`, never `handoff-spawn <branch> -- <prompt>`. Auto-review
rejects those as unbound executable content.

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

## After spawn

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
