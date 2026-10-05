# bercail

**an ADE on [herdr](https://herdr.dev).**

Bercail is an agentic development environment: Herdr-based, built for working in parallel with control and observability. One git worktree, one Herdr workspace. A sticky agent stays on the left while you switch shell, review, and files. You see when each agent is working, blocked, or done. When it goes `done`, [tuicr](https://github.com/agavra/tuicr) opens the whole branch vs main and watches further edits. You review in the terminal; comments stay human vs AI; push to GitHub only when you ask.

**Bercail is built to be orchestrated by a Grok bot.** [Shep](#shep-the-grok-bot) is that bot: a public Grok bot that runs bercail for you. The agentic workflow here (beads issues, named stages, result files, review when a desk is done) is optimized for Shep as the orchestrator. Bercail does the local work; Shep decides what happens next.

Claude Code, Codex CLI, and cursor-agent are equal harnesses. Bercail does not prefer one, pick one, or fall back from one to another. A handoff is a [beads](https://beads.gascity.com/) issue: Shep writes it, and the agent's whole prompt is the issue id.

Omarchy, Ubuntu/Debian, macOS. Installer and CLI: `bercail`.

<img width="2138" height="1386" alt="sticky agent, review, files" src="https://github.com/user-attachments/assets/b58e8e78-c78b-4cc3-9f56-8040d561f2d9" />

- **sticky agent** — the configured agent (cursor-agent by default) does not live in a tab. Tabs move around it.
- **one worktree, one workspace** — [worktrunk](https://github.com/max-sixty/worktrunk) creates the tree; Herdr follows.
- **control and observability** — every pane is working, blocked, or idle. Review opens on `done`. You choose what gets a GitHub comment.
- **review when the agent is done** — `tuicr -r origin/main -w` on a feature branch (working tree vs main, watching). Other people's PRs open with `tuicr pr`. `prefix+2` anytime.
- **handoff is parallel, not a chat fork** — one beads issue per job, run headless or in a sibling worktree with its own sticky pane. See [handoff](#handoff).
- **keyboard and mouse** — prefix is `Ctrl-Space` (Omarchy tmux). Click the file tree; `j`/`k` in tuicr.

```
┌──────────────┬────────────────────────────┬─────────┐
│ agent        │ shell  |  review*  |  edit │ files   │
│ sticky       │ tuicr on agent done / +2   │ git     │
│ prefix+1     │ prefix+2 / +3 / +4         │ +4 / +g │
└──────────────┴────────────────────────────┴─────────┘
```

## Shep, the Grok bot

**[Shep](https://x.ai/bot/QxTrE1a1ESYzE7nfEKc9n) is the Grok bot that orchestrates bercail.** It orchestrates coding agents on Herdr through bercail: it writes beads issues, hands them to claude, codex, or cursor-agent, and pings you when a desk is ready to review.

Bercail's workflow is designed around Shep. Shep owns the workflow; bercail runs what Shep asks for and reports back in files Shep reads:

1. Shep writes the job as a beads issue (`bd create`): the ask, the repo, links, and any "plan only" note.
2. Shep picks a stage for that issue and runs `handoff-spawn --stage start|codex|cursor --issue ID` (see [handoff](#handoff)). bercail never picks the stage and never falls back to another one.
3. bercail checks `bd` and the issue, adds a `bd comment` with the worktree (and, headless, the result file), and starts that one harness with the issue id as its whole prompt.
4. Shep reads `.bercail/handoff-result.json` (`ready`, `blocked`, or `failed`), resumes the session if needed, and tells you when the desk is ready.

Shep runs the same workflow whichever harness works the issue.

Bercail works without Shep, but Shep is the intended orchestrator. To do Shep's part by hand, write the issue with `bd create`, then run the same `handoff-spawn` command.

## install

Current release: [v0.6.2](https://github.com/simoncrypta/bercail/releases/tag/v0.6.2).

Recommended: [mise](https://mise.jdx.dev) + [packslip](https://github.com/jdx/packslip). Each `v*` release publishes `bercail.tar.gz` and a signed `packslip.sigstore.json`. mise checks that signature against this repository and the archive digest before it unpacks anything, and it runs no downloaded code.

```bash
mise use -g packslip:github.com/simoncrypta/bercail   # mise 2026.9.2+
bercail install                                       # full install from that release
```

Without mise, the packslip CLI installs the same release and links `bercail` into `~/.local/bin`:

```bash
packslip install github.com/simoncrypta/bercail      # packslip 1.5.1+
bercail install
```

mise holds back each new release for its first 24 hours (`minimum_release_age`), so right after a release `mise use` still installs the previous one. To take a newer release sooner, pin it: `mise use -g packslip:github.com/simoncrypta/bercail@0.6.2`.

The first install trusts the repository's signer, and later installs must match it. `bercail install` runs the release's own `install.sh`. mise or packslip keeps the `bercail` command, so the installer does not copy a second one into `~/.local/bin`. Upgrade with `mise up` (or `packslip install` again), then `bercail update`.

curl is still supported. It reads the repository tip and does not need a release:

```bash
curl -fsSL https://setup.simoncrypta.dev/install.sh | bash
```

`--yes` is non-interactive (`bercail install --yes` too). From a clone: `./install.sh`.

Then, in a repo:

```bash
dev          # attach this directory
# or: t      # launch herdr
# then prefix+d
```

The sticky pane runs `[agent] command` from `~/.config/bercail/config.toml` (cursor-agent by default; there is no picker). Change it, then `bercail reconfigure`. Handoff stages do not read it; each stage names its own binary.

## handoff

The job lives in a beads issue. [Shep](#shep-the-grok-bot), the Grok bot, creates the issue (`bd create`), then runs `handoff-spawn` with the issue id and a stage. `--stage` and `--issue` are both required; bercail has no default harness and no fallthrough.

| Stage | Binary | Headless argv (the last word is the issue id) |
|-------|--------|-----------------------------------------------|
| `start` | claude | `claude --print --model claude-opus-5-5 --output-format json …` |
| `codex` | codex | `codex exec --json --sandbox workspace-write …` |
| `cursor` | cursor-agent | `cursor-agent --print --output-format json --trust --force …` |

```bash
bd create "Fix the login timeout" --description "..."     # Shep (the Grok bot) writes the issue
~/.agents/skills/handoff/scripts/handoff-spawn --info      # facts as JSON, incl. beads

# headless: no Herdr pane; result is <worktree>/.bercail/handoff-result.json
~/.agents/skills/handoff/scripts/handoff-spawn --stage codex --issue ID --worktree PATH [--dry-run]
~/.agents/skills/handoff/scripts/handoff-spawn --stage start --issue ID --worktree PATH --resume SESSION

# sibling worktree with a sticky pane running the stage's binary
~/.agents/skills/handoff/scripts/handoff-spawn --branch NAME --stage cursor --issue ID [--dirty|--clean] [--workspace ID]
```

- **Prompt** — the issue id, the same for every harness.
- **Context** — before it starts the agent, bercail adds a `bd comment` to the issue with the worktree and, headless, the result file and session id.
- **Result** — a headless run leaves `{status: ready|blocked|failed, summary, session_id}`. Read that file, not terminal output. `--resume SESSION` continues the same session (`claude --resume`, `codex exec resume`, `cursor-agent --resume`).
- **Blocked, not switched** — if the stage's binary, `bd`, or the issue is missing, the result is `blocked` and nothing starts. Bercail never falls through to another harness. `--binary claude|codex|cursor-agent` runs a headless stage on another CLI only when you ask.
- **Dry run** — `--dry-run` prints the exact argv for any stage, even when that binary is not installed.
- `bercail harness` reports which of claude, codex, and cursor-agent are on PATH, with a local model hint. It does not choose.

## commands

### install / CLI

| Command | What |
|---------|------|
| `bercail install` | Full install from the release mise or packslip unpacked |
| `./install.sh` | Full install |
| `./install.sh --yes` | Non-interactive |
| `./install.sh --help` | Installer help |
| `bercail help` | This reference |
| `bercail doctor` | Deps, plugin, skills, Herdr integration |
| `bercail harness` | JSON: which of claude, codex, cursor-agent are on PATH (reports, does not choose) |
| `bercail update` | Re-sync configs, helper, skills (`--force` ok) |
| `bercail reconfigure` | Re-read `config.toml`, refresh skills/integrations |
| `bercail dry-run` | Show install actions, write nothing |
| `bercail uninstall` | Remove managed files and the shell marker |

### shell

| Command | What |
|---------|------|
| `dev` | Attach or switch the Herdr workspace for `$PWD` and start the configured agent |
| `d` | Apply the sticky-agent layout and start the configured agent (inside Herdr only) |
| `t` | `herdr` |
| `wtc [branch]` | Create worktree + Herdr workspace |
| `wts [branch]` | Switch worktree (fzf if omitted) |
| `wtd [branch]` | Remove worktree + close Herdr workspace |

### skills (agent pane)

Call by name. Skills install to `~/.agents/skills`; bercail adds a link where the configured agent looks elsewhere (`~/.claude/skills`, `~/.codex/skills`, …).

| Skill | What |
|-------|------|
| `handoff` | Run a beads issue on a stage (`--stage start|codex|cursor --issue ID`), headless or as a `--branch` pane. See [handoff](#handoff) |
| `review` | Wait for **human** tuicr notes; publish to GitHub only if asked |

```bash
# review helpers
~/.agents/skills/review/scripts/wait-comments.sh --repo . [--timeout N]
~/.agents/skills/review/scripts/publish-github.sh --repo . \
  [--event comment|approve|request-changes] [--body TEXT] [--dry-run]
```

Manual skill install: `npx skills add simoncrypta/bercail --skill handoff -g`

### layout plugin

`herdr plugin action invoke agentic-dev.layout.<action>`

| Action | Key |
|--------|-----|
| `apply` / `create` | `prefix+d` (`apply` starts a clear agent session) |
| `focus-agent` / `start-agent` | `prefix+1` |
| `handoff-agent` | handoff-spawn (child session; prompt is the beads issue id) |
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

Review launch: feature branch → `tuicr -r origin/main -w` (watches committed + uncommitted); on main → `tuicr -w`; someone else's PR on this checkout → `tuicr pr <n>`. Pickr defaults to `tuicr pr {url}`. `auto_review = false` disables the agent-done hook. A live Review pane is not restarted — tuicr's diff watch keeps it current.

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
review = "tuicr"
auto_review = true
# editor = "nvim"   # else $EDITOR / $VISUAL (macOS: nano, then vi)
```

Also: `~/.config/herdr/config.toml`, worktrunk hooks, `~/.agents/skills/{handoff,review}`.

## plugin only

Already on Herdr and only want the layout:

```bash
herdr plugin install simoncrypta/agentic-dev-setup/plugins/agentic-layout --ref v0.6.2
```

Needs Herdr 0.9.3+, `jq`, a Rust toolchain, tuicr. Copy keys from [`config/herdr/config.toml`](config/herdr/config.toml). Set `close_tab = ""` and `close_pane = ""`. Full install also adds shell commands, CLI, skills, worktrunk hooks, and desktop fixes.

Plugins run as your user. Skim [`plugins/agentic-layout/herdr-plugin.toml`](plugins/agentic-layout/herdr-plugin.toml) and [`layout.sh`](plugins/agentic-layout/layout.sh). Prefer no `--yes` the first time.

```bash
herdr plugin list
herdr plugin action invoke agentic-dev.layout.create
```

Local: `cargo build --release -p herdr-sidebar` in `plugins/agentic-layout`, then `herdr plugin link …`.

## linux

On Omarchy: mise first, `omarchy pkg add`, native `SUPER+CTRL+RETURN` → Herdr, optional `SUPER+ALT+RETURN` remap, fcitx5 `Ctrl+Alt+H/J` hint keys cleared. On Ubuntu: mise then apt (`git fzf jq lazygit curl`); herdr, worktrunk, beads, tuicr from upstream. On macOS: mise first; Homebrew stays on PATH as fallback (`brew shellenv`, then mise shims prepended). Hyprland: same optional `SUPER+ALT+RETURN` binding.

## dependencies

Installed if missing: [herdr](https://herdr.dev) 0.9.3+ (`herdr integration install cursor` only if you use Cursor), git, worktrunk (`wt`), [beads](https://beads.gascity.com/) (`bd`), fzf, jq, lazygit, [tuicr](https://github.com/agavra/tuicr) ≥ 0.20.0. `bercail doctor` checks each one.

Not installed: a Rust toolchain. Herdr builds the layout plugin with `cargo build` when bercail installs it, so have `cargo` on PATH (for example `mise use -g rust`) before `bercail install`, or that step fails.

worktrunk and beads install the same way: skip if present, else mise, else Homebrew (`brew install worktrunk` / `brew install beads`), else upstream (worktrunk's GitHub release; the [beads installer](https://raw.githubusercontent.com/gastownhall/beads/main/scripts/install.sh), which puts `bd` in `/usr/local/bin` when writable, else `~/.local/bin`).

[Claude Code](https://docs.anthropic.com/en/docs/claude-code), [Codex CLI](https://github.com/openai/codex), and cursor-agent are optional. Install the ones you want Shep to use; `bercail harness` reports which are on PATH.

## development

```bash
shellcheck install.sh lib/*.sh bin/bercail config/shell/bercail.inc.sh plugins/agentic-layout/layout.sh
./install.sh --help
bercail dry-run
npm run deploy   # Cloudflare Pages
```

## license

MIT — [LICENSE](LICENSE).
