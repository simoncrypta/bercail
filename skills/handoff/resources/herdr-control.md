# Herdr control (condensed)

Aligned with upstream Herdr agent skill. Installed binary wins: `herdr --help`, group help (`herdr pane`, `herdr agent`, …). Optional: `herdr --skill`.

## Guard

```bash
test "${HERDR_ENV:-}" = 1
```

## Primitives

- **Workspace / tab / pane** — topology
- **Pane commands** — shells, tests, servers, raw IO
- **Agent commands** — recognized coding agents (`idle` / `working` / `blocked` / `done` / `unknown`)

`agent start` needs an existing available shell pane; it does not create layout.

IDs: `w1`, `w1:t1`, `w1:p1`. Prefer `--current` or explicit IDs/names over another client’s UI focus.

```bash
printf '%s\n' "$HERDR_WORKSPACE_ID" "$HERDR_TAB_ID" "$HERDR_PANE_ID"
herdr workspace list
herdr pane list --workspace "$HERDR_WORKSPACE_ID"
herdr agent list
```

## Sibling pane (same worktree)

Default for same-cwd helpers — not a substitute for main→worktree handoff:

```bash
herdr pane split --current --direction right --cwd "$PWD" --no-focus
herdr pane run <pane-id> "just test"
herdr pane wait-output <pane-id> --match "test result" --timeout 120000
herdr pane read <pane-id> --source recent-unwrapped --lines 120
```

## Agent surface

Main-repo → worktree handoff is `scripts/handoff-spawn` only (`resources/handoff.md`).
Do not `herdr agent prompt`, paste, send-keys, or `workspace focus` the child.

Never deliver a handoff task with TUI paste or session control:

```bash
# wrong — steals focus / types into the TUI
herdr workspace focus "$child"
herdr agent focus "$pane"
herdr pane send-keys "$pane" ...
herdr agent prompt "$pane" "$TEXT"
```

Inspect (not a substitute for handoff submit):

```bash
herdr agent read "$pane" --source recent-unwrapped --lines 120
herdr agent rename "$pane" reviewer
```

Prefer `recent-unwrapped` for logs. If alternate-screen output cannot be recovered, ask the agent to write a Markdown file and return only its path.

### Focus

- `herdr worktree create|open` / `herdr workspace create` support `--no-focus` for background subspaces.
- Sticky layout create runs the plugin script directly with `WT_HERDR_LABEL` / `WT_HERDR_WORKDIR` / `HERDR_WORKSPACE_ID` for the child. Do not `herdr plugin action invoke` for background create: that binds the focused parent workspace and drops `WT_HERDR_*`. Plugin id is `agentic-dev.layout` (never `agentic-dev.dev-layout`).
- Worktrunk `post-start` opens layout only (`unset WT_HERDR_AGENT_PROMPT`). `d` / `dev` / `apply` start a clear session of the configured agent. The handoff skill is the only path that starts the child with the task (`wt_herdr_handoff_agent`). Socket-attached parents (no `HERDR_ENV`) pass `--workspace`.
- Create does not `workspace focus` the child. If some Herdr call still moves TUI focus, the helper restores `WT_HERDR_KEEP_FOCUS` (the parent workspace).
- `herdr worktree open --path` needs `--cwd <main-repo>` (or `--workspace` of that repo). Path-only open uses the focused workspace as the source and fails with `not_git_worktree` when that workspace is not a git checkout.
- `herdr workspace focus` does not accept `--json`.

## Worktrees (grouped subspaces)

```bash
herdr worktree list [--cwd PATH | --workspace ID]
herdr worktree create --cwd <main> --branch NAME [--path PATH] [--label TEXT] --no-focus
herdr worktree open --path PATH|--branch NAME [--label TEXT] --no-focus
herdr worktree remove --workspace ID
```

`worktree create` opens a checkout as a workspace and groups it with the parent repo workspace.

## Safety

- `--no-focus` for background work unless asked to switch
- Parse IDs from JSON; do not invent them
- Do not close what you did not create unless asked
- Never `herdr server stop` / kill the main process unless the user explicitly intends that
