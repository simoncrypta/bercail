# commands

The `bercail` CLI, the shell helpers, and the skills your agents call by name. `bercail help` prints a short version in your terminal, keys included.

## install / CLI

| Command | What |
|---------|------|
| `bercail install` | Full install from the release mise or packslip unpacked |
| `./install.sh` | Full install |
| `./install.sh --yes` (`-y`) | Non-interactive |
| `./install.sh --no-bstack` | New install without bstack (desk default stays cursor-agent) |
| `./install.sh --bstack` | New install with bstack (the default) |
| `./install.sh --help` | Installer help |
| `bercail help` | This reference |
| `bercail doctor` | Deps, Herdr layout, mod and keys, skills, webhook sinks and follower |
| `bercail harness` | JSON: which of claude, codex, cursor-agent, opencode are on PATH (reports, does not choose) |
| `bercail bstack setup` / `status` / `on` / `off` | [bstack](bstack.md): opencode on your own plans. No subcommand = `status` |
| `bercail update` | Re-sync configs, Herdr layout and mods, helper, skills, and bstack; restart the notify follower. `--force` (`-f`) also replaces a changed layout and the worktrunk config, and writes the shell block despite conflicts |
| `bercail reconfigure` | Re-read `config.toml`, refresh skills |
| `bercail dry-run` | Show what install would do, without doing it |
| `bercail uninstall` | Remove managed files and the shell marker |
| `bercail notify status` / `add NAME` / `repo add NAME [REPO]` / `repo remove NAME REPO` / `check [PATH]` / `test NAME` / `run` | [Agent status webhooks](shep.md#agent-status-webhooks). No subcommand = `status`; `run` is the follower the desk mod keeps alive |

## shell

[worktrunk](https://github.com/max-sixty/worktrunk) creates the tree; a Herdr space follows.

| Command | What |
|---------|------|
| `dev` (or `d`) | Open the Herdr app if needed, show the space for `$PWD` (made if missing), and start its desk agent if it has none |
| `t` | Open the Herdr app |
| `wtc [branch]` | Create (or switch to) the worktree for `branch` + its space. New branches start from HEAD. With no branch, the current one moves to a new worktree and this checkout goes back to the default branch |
| `wts [branch]` (or `wt.`) | Switch worktree (fzf if omitted) |
| `wtd [branch]` | Force-remove the worktree (default: the current branch) + close its space |

## skills

Call by name. Skills install to `~/.agents/skills`; bercail adds a link where the configured agent looks elsewhere (`~/.claude/skills`, `~/.codex/skills`, …).

| Skill | What |
|-------|------|
| `handoff` | Run a beads issue on a stage, headless or as a `--branch` desk (`--base` stacks it on a parent branch). See [handoff](handoff.md) |
| `review` | Wait for **human** tuicr notes; publish to GitHub only if asked. See [review](review.md) |
| `bstack` | Playbooks for rigorous work, routed by role. See [bstack](bstack.md) |
| `council` | One reviewer per connected provider; keep only findings that hold up |
| `how` / `why` | How code works now; why it is that way, from git, PRs, and beads. Read-only |
| `unslop` | Clean machine-writing tells out of prose and a diff |
| `autopilot` | Drive an open PR to green: CI, review threads, conflicts. Pushes; never merges |

autopilot's PR snapshot, `pr-state.sh`, is in [Ship with autopilot](bstack/06-autopilot.md#what-it-does). The review helpers:

```bash
~/.agents/skills/review/scripts/wait-comments.sh --repo . [--timeout N]
~/.agents/skills/review/scripts/publish-github.sh --repo . \
  [--event comment|approve|request-changes] [--body TEXT] [--dry-run]
```

Manual skill install: `npx skills add simoncrypta/bercail --skill handoff -g`
