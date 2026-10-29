# Worktrunk (condensed, Herdr-adapted)

Worktrunk (`wt`) manages git worktrees. Here each checkout is a Herdr app space; prefer bercail handoffs over tmux/Zellij recipes from upstream Worktrunk docs.

## Two configs

- **User** `~/.config/worktrunk/config.toml` — personal preferences; propose changes, get consent.
- **Project** `<repo>/.config/wt.toml` — team hooks; edit with care; warn on destructive commands.

This layout also uses `~/.config/worktrunk/herdr-layout.sh` and user hooks so `post-start` / `post-remove` open or close the Herdr app space of a sibling checkout.

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
`resources/handoff.md`). Do not assemble `wt switch` / space create / desk start
yourself.

## Do not

- Use `Agent { isolation: "worktree" }` patterns that invent throwaway branch names when Worktrunk + Herdr already define the path/branch.
- Approve hooks on the user’s behalf.
