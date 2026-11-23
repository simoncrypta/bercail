# Worktrunk (condensed, Herdr-adapted)

Worktrunk (`wt`) manages git worktrees. Here each checkout is a Herdr app space; prefer bercail handoffs over tmux/Zellij recipes from upstream Worktrunk docs.

## Two configs

- **User** `~/.config/worktrunk/config.toml` — personal preferences; propose changes, get consent.
- **Project** `<repo>/.config/wt.toml` — team hooks; edit with care; warn on destructive commands.

This layout also uses `~/.config/worktrunk/herdr-layout.sh` and user hooks so `post-start` / `post-remove` open or close the Herdr app space of a sibling checkout. `post-remove` finds the space by the checkout's folder, so it still closes after the checkout switched branches. With no window on this machine, `post-start` makes the space through hc for any connected window to show (docs/handoff.md, "No window on this machine"), and `post-remove` leaves it.

These hooks serve a person's `wt switch`. `handoff-spawn --branch` passes `--no-hooks` and runs the copy and the project's `pre-start` hooks itself, then makes the space and desk. Both name the space `<Branch>_<Repo>` with a slash in the branch as a dash (`Feat-x_Bercail`). The user config's `[step.copy-ignored] exclude` keeps the main checkout's `.beads/*` store and `.bercail/*` evidence out of a person's new worktree. The spawn drops them from a desk's whatever the config says.

## Useful commands

```bash
wt config show
wt list --format=json
wt switch --create <branch>
wt switch <branch>
```

Shell wrappers (when installed): `wtc` / `wts` / `wtd` / `dev`.

## Hook approvals

Worktrunk will not run project hooks/aliases until the user approves them. In non-interactive agent sessions, approval prompts fail.

**Escalate to the user** — tell them to run `wt config approvals add`. Do **not** pass `--yes` to bypass approval for the user (`--yes` is for CI that already owns the hook contents).

## Handoffs

Run `scripts/handoff-spawn --info` then `handoff-spawn` (see
`SKILL.md`). Do not assemble `wt switch` / space create / desk start
yourself.

## Do not

- Invent throwaway branch names. Use `handoff-spawn` for a sibling checkout.
- Approve hooks on the user’s behalf.
