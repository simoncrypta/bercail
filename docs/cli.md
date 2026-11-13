# commands

The `bercail` CLI, the shell helpers, and the skills your agents call by name. `bercail help` prints a short version in your terminal, keys included.

## install / CLI

| Command | What |
|---------|------|
| `bercail install` | Full install from the release mise or packslip unpacked |
| `./install.sh` | Full install |
| `./install.sh --yes` (`-y`) | Non-interactive |
| `./install.sh --help` | Installer help |
| `bercail help` | This reference |
| `bercail doctor` | Deps, Herdr layout, mod and keys, skills, webhook sinks and follower |
| `bercail bstack setup` / `status` | [bstack](bstack.md): Pi on your own plans. No subcommand = `status` |
| `bercail config get <section> <key>` | A `config.toml` value as bercail reads it: `bercail config get layout review`, `bercail config get 'policy."~/Work/some-repo"' commit`. An array prints as JSON. Prints nothing and exits 1 when the key is not set |
| `bercail desk restore` / `--dry-run` | Bring back the desk agents a reboot or a core restart took, each on its session in its own space. See [desks after a reboot](config.md#desks-after-a-reboot). `--dry-run` lists each desk and what would happen to it |
| `bercail update` | Re-sync configs, Herdr layout and mods, helper, skills, and bstack; restart the notify follower. `--force` (`-f`) also replaces a changed layout and the worktrunk config, and writes the shell block despite conflicts |
| `bercail review-pr <PR url-or-branch>` / `run` / `card` / `ui` / `state` / `select` / `checkout` / `rereview` / `open` / `dir` | Review a whole PR stack by intent and decisions: one visible review desk session, cards and a stack summary beside its worktree. See [review](review.md#someone-elses-pr-bercail-review-pr) |
| `bercail reconfigure` | Re-read `config.toml`, refresh skills |
| `bercail dry-run` | Show what install would do, without doing it |
| `bercail uninstall` | Remove managed files and the shell marker |
| `bercail notify status` / `add NAME` / `repo add NAME [REPO]` / `repo remove NAME REPO` / `check [PATH]` / `test NAME` / `run` | [Agent status webhooks](shep.md#agent-status-webhooks). No subcommand = `status`; `run` is the follower the desk mod keeps alive |
| `bercail policy show [--json] [repo]` / `trust [repo]` / `untrust [repo]` | A repo's [git policy](config.md#git-policy-per-repo): each value and where it came from; trust the repo's `.bercail/policy.toml` so its looser values count, or forget it |
| `bercail shep status` / `run` / `bg --issue ID [--cwd DIR]` | [Shep on Pi](shep.md#shep-on-pi): its session folder, desk events, and live background Sheps. No subcommand = `status`; `run` is what the Shep view starts; `bg` starts a [background Shep](shep.md#background-sheps) |
| `bercail shep repos [--json]` / `board` / `brief ISSUE [--repo DIR] [--budget CHARS]` | [What Shep knows](shep.md#what-shep-knows): your known repos, one line per open job and what waits on you, and one issue's desk, state and latest report, cut short |
| `bercail shep remember "RULE" [--scope SCOPE]` / `list` / `forget N` | Shep's [standing rules](shep.md#standing-rules), kept across sessions and compactions |

## shell

[worktrunk](https://github.com/max-sixty/worktrunk) creates the tree; a Herdr space follows.

| Command | What |
|---------|------|
| `dev` | Open the Herdr app if needed, show the space for `$PWD` (made if missing), and start its desk agent if it has none |
| `wtc [branch]` | Create (or switch to) the worktree for `branch` + its space. New branches start from HEAD. With no branch, the current one moves to a new worktree and this checkout goes back to the default branch |
| `wts [branch]` (or `wt.`) | Switch worktree (fzf if omitted) |
| `wtd [branch]` | Force-remove the worktree (default: the current branch) + close its space |

## skills

Call by name. Skills install to `~/.agents/skills`, with a link to each in `~/.pi/agent/skills`, where Pi looks.

| Skill | What |
|-------|------|
| `handoff` | Run a beads issue on a stage, headless or as a `--branch` desk (`--base` stacks it on a parent branch). See [handoff](handoff.md) |
| `review` | Wait for **human** tuicr notes; publish to GitHub only if asked. See [review](review.md) |
| `bstack` | Playbooks for rigorous work, routed by role. See [bstack](bstack.md) |
| `council` | Adversarial review on request; only findings a rerun confirms are reported |
| `how` / `why` | How code works now; why it is that way, from git, PRs, and beads. Read-only |
| `unslop` | Clean machine-writing tells out of prose and a diff |
| `autopilot` | Drive an open PR to green: CI, review threads, conflicts. Pushes; never merges |
| `desk-restore` | Put a desk with no record back on its session by hand, matched by folder and content |
| `unit-testing` | F.I.R.S.T. rules for writing and reviewing tests: a temp HOME, fakes on PATH, a run that fails without the change |

autopilot's PR snapshot, `pr-state.sh`, is in [Ship with autopilot](bstack/06-autopilot.md#what-it-does). The review helpers:

```bash
~/.agents/skills/review/scripts/wait-comments.sh --repo . [--timeout N]
~/.agents/skills/review/scripts/publish-github.sh --repo . \
  [--event comment|approve|request-changes] [--body TEXT] [--dry-run]
```

Manual skill install: `npx skills add simoncrypta/bercail --skill handoff -g`
