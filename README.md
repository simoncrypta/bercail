# bercail

**an ADE on [herdr](https://herdr.dev).**

Bercail is an agentic development environment: Herdr-based, cursor-agent focused, built for working in parallel with control and observability. One git worktree, one Herdr workspace. [cursor-agent](https://cursor.com) stays on the left while you switch shell, review, and files. You see when each agent is working, blocked, or done. When it goes `done`, [hunk](https://github.com/modem-dev/hunk) opens the whole branch vs main. `handoff` clones that desk onto a sibling worktree and starts a [pstack](https://github.com/cursor/plugins/tree/main/pstack) child (`/poteto-mode`). You review in the terminal; comments stay human vs AI; push to GitHub only when you ask.

Omarchy, Ubuntu/Debian, macOS. Installer and CLI: `bercail`.

<img width="2138" height="1386" alt="sticky agent, review, files" src="https://github.com/user-attachments/assets/52d372ae-a51f-4260-b95f-d9daa3b335c1" />

- **sticky agent** — cursor-agent does not live in a tab. Tabs move around it.
- **one worktree, one workspace** — [worktrunk](https://github.com/max-sixty/worktrunk) creates the tree; Herdr follows.
- **control and observability** — every pane is working, blocked, or idle. Review opens on `done`. You choose what gets a GitHub comment.
- **review when the agent is done** — `hunk diff origin/main --watch` on a feature branch (working tree vs main). `prefix+2` anytime.
- **handoff is parallel, not a chat fork** — sibling checkout, optional dirty copy, always cursor-agent + pstack. Install pstack in Cursor: `/add-plugin pstack`.
- **keyboard and mouse** — prefix is `Ctrl-Space` (Omarchy tmux). Click the file tree; `j`/`k` in hunk.

```
┌──────────────┬────────────────────────────┬─────────┐
│ cursor-agent │ shell  |  review*  |  edit │ files   │
│ sticky       │ hunk on agent done / +2    │ git     │
│ prefix+1     │ prefix+2 / +3 / +4         │ +4 / +g │
└──────────────┴────────────────────────────┴─────────┘
```

## install

```bash
curl -fsSL https://setup.simoncrypta.dev/install.sh | bash
```

`--yes` is non-interactive. From a clone: `./install.sh`.

Then, in a repo:

```bash
dev          # attach this directory
# or: t      # launch herdr
# then prefix+d
```

Default sticky agent is **cursor-agent**. There is no picker. Another command in the left pane is `[agent] command` in `~/.config/bercail/config.toml`, then `bercail reconfigure`. Handoff children stay cursor-agent + `/poteto-mode`.

## commands

### install / CLI

| Command | What |
|---------|------|
| `./install.sh` | Full install |
| `./install.sh --yes` | Non-interactive |
| `./install.sh --help` | Installer help |
| `bercail help` | This reference |
| `bercail doctor` | Deps, plugin, skills, pstack, Herdr integration |
| `bercail update` | Re-sync configs, helper, skills (`--force` ok) |
| `bercail reconfigure` | Re-read `config.toml`, refresh skills/integrations |
| `bercail dry-run` | Show install actions, write nothing |
| `bercail uninstall` | Remove managed files and the shell marker |

### shell

| Command | What |
|---------|------|
| `dev` | Attach or switch the Herdr workspace for `$PWD` |
| `d` | Apply the sticky-agent layout (inside Herdr only) |
| `t` | `herdr` |
| `wtc [branch]` | Create worktree + Herdr workspace |
| `wts [branch]` | Switch worktree (fzf if omitted) |
| `wtd [branch]` | Remove worktree + close Herdr workspace |

### skills (agent pane)

Call by name. Cursor reads `~/.agents/skills`.

| Skill | What |
|-------|------|
| `handoff` | Spawn a sibling worktree; child is cursor-agent + `/poteto-mode` |
| `review` | Wait for **human** hunk notes; publish to GitHub only if asked |

```bash
# handoff (parent: --info, then spawn — never put the prompt on argv)
~/.agents/skills/handoff/scripts/handoff-spawn --info
~/.agents/skills/handoff/scripts/handoff-spawn --stash-prompt
~/.agents/skills/handoff/scripts/handoff-spawn --branch NAME \
  [--dirty|--clean] [--plan] [--workspace ID] \
  [--take-pending|--prompt-file PATH]

# review helpers
~/.agents/skills/review/scripts/wait-comments.sh --repo . [--timeout N]
~/.agents/skills/review/scripts/publish-github.sh --repo . \
  [--event comment|approve|request-changes] [--body TEXT] [--dry-run]
```

`--info` includes `pstack`. If it is false, install pstack in Cursor (`/add-plugin pstack`) and still spawn.

Manual skill install: `npx skills add simoncrypta/agentic-dev-setup --skill handoff -g`

### layout plugin

`herdr plugin action invoke agentic-dev.layout.<action>`

| Action | Key |
|--------|-----|
| `apply` / `create` | `prefix+d` |
| `focus-agent` / `start-agent` | `prefix+1` |
| `select-review` | `prefix+2` |
| `select-shell` | `prefix+3` |
| `select-files` | `prefix+4` |
| `select-source-control` | sidebar git |
| `refresh-review` | sidebar `v` |
| `close-review` / `close-tab` | `prefix+k` |
| `close-pane` | `prefix+x` |
| `toggle-sidebar` | — |
| `open-editor` | click a file |
| `select-tab-1` … `select-tab-9` | `Alt+1`…`9` (Option on macOS) |
| `select-prev-tab` / `select-next-tab` | `Alt+Left` / `Alt+Right` |

Review launch: feature branch → `hunk diff origin/main --watch --agent-notes`; on main → `hunk diff --watch --agent-notes`. `auto_review = false` disables the agent-done hook.

## keys

Prefix is **`Ctrl-Space`**. Linux: [`config/herdr/config.toml`](config/herdr/config.toml) (Alt). macOS: [`config/herdr/config.macos.toml`](config/herdr/config.macos.toml) (Option).

Native Herdr owns splits, workspaces, detach. This plugin owns the sticky layout. [herdr-worktrunk](https://github.com/devashish2203/herdr-worktrunk) owns worktree pickers. `prefix+shift+d` is Herdr close-workspace, so remove is `prefix+shift+r`. Close this workspace: `prefix+shift+k`. Child worktrees stay open unless `herdr workspace close --group`.

| Key | Action |
|-----|--------|
| `prefix+d` | Apply / ensure layout |
| `prefix+1` | Focus agent (recreate if dead) |
| `prefix+2` | Review |
| `prefix+3` | Shell |
| `prefix+4` | Files |
| `Alt+1`…`9` | Tab N (Option on macOS) |
| `prefix+c` | New tab |
| `prefix+k` | Close file tab or Review |
| `prefix+shift+t` | Rename tab |
| `prefix+n` / `p` | Next / previous tab |
| `Alt+Left` / `Right` | Previous / next tab |
| `Alt+Up` / `Down` | Previous / next workspace |
| `prefix+w` | Workspace picker |
| `prefix+shift+n` | New workspace |
| `prefix+shift+w` | Rename workspace |
| `prefix+shift+k` | Close this workspace |
| `prefix+shift+q` | Detach |
| `prefix+h` / `v` | Split below / beside |
| `prefix+x` | Close pane |
| `prefix+z` | Zoom pane |
| `Ctrl+Alt+arrows` | Focus pane (Ctrl+Option on macOS) |
| `prefix+shift+g` | Worktree from default branch |
| `prefix+shift+c` | Worktree from current branch |
| `prefix+shift+r` | Remove worktree |
| `prefix+q` | Reload Herdr config |

`prefix+1`…`4` no-op until `prefix+d` has created a layout. Missing agent pane is recreated on the next tab switch or `prefix+1`.

## config

`~/.config/bercail/config.toml`:

```toml
[agent]
command = "cursor-agent"

[layout]
review = "hunk diff"
auto_review = true
# editor = "nvim"   # else $EDITOR / $VISUAL (macOS: nano, then vi)
```

Also: `~/.config/herdr/config.toml`, worktrunk hooks, `~/.agents/skills/{handoff,review}`.

## plugin only

Already on Herdr and only want the layout:

```bash
herdr plugin install simoncrypta/agentic-dev-setup/plugins/agentic-layout --ref v0.4.0
```

Needs Herdr 0.9+, `jq`, a Rust toolchain, hunk. Copy keys from [`config/herdr/config.toml`](config/herdr/config.toml). Set `close_tab = ""` and `close_pane = ""`. Full install also adds shell commands, CLI, skills, worktrunk hooks, and desktop fixes.

Plugins run as your user. Skim [`plugins/agentic-layout/herdr-plugin.toml`](plugins/agentic-layout/herdr-plugin.toml) and [`layout.sh`](plugins/agentic-layout/layout.sh). Prefer no `--yes` the first time.

```bash
herdr plugin list
herdr plugin action invoke agentic-dev.layout.create
```

Local: `cargo build --release -p herdr-sidebar` in `plugins/agentic-layout`, then `herdr plugin link …`.

## linux

On Omarchy: mise first, `omarchy pkg add`, native `SUPER+CTRL+RETURN` → Herdr, optional `SUPER+ALT+RETURN` remap, fcitx5 `Ctrl+Alt+H/J` hint keys cleared. On Ubuntu: mise then apt (`git fzf jq lazygit curl`); herdr, worktrunk, hunk from upstream. Hyprland: same optional `SUPER+ALT+RETURN` binding.

## dependencies

Installed if missing: [herdr](https://herdr.dev) 0.9+ (`herdr integration install cursor`), worktrunk, fzf, jq, lazygit, [hunk](https://github.com/modem-dev/hunk) ≥ 0.20.1, cursor-agent. pstack is a Cursor plugin, not a package: `/add-plugin pstack`.

## development

```bash
shellcheck install.sh lib/*.sh bin/bercail config/shell/bercail.inc.sh plugins/agentic-layout/layout.sh
./install.sh --help
bercail dry-run
npm run deploy   # Cloudflare Pages
```

## license

MIT — [LICENSE](LICENSE).
