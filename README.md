# bercail

**an ADE on [herdr](https://herdr.dev).**

Bercail is an agentic development environment on the [Herdr app](https://herdr.dev) and herdr-core (`hc`), built for working in parallel with control and observability. One git worktree, one Herdr space. Each space has a desk: one agent that stays on the left while you switch shell, review, and files. You see when each agent is working, blocked, or done. Agents stage their changes and leave them uncommitted; when the agent goes `done`, [tuicr](https://github.com/agavra/tuicr) opens those uncommitted changes and watches further edits. You review in the terminal; comments stay human vs AI; push to GitHub only when you ask.

**Bercail is built to be orchestrated by a Grok bot.** [Shep](#shep-the-grok-bot) is that bot: a public Grok bot that runs bercail for you. The agentic workflow here (beads issues, named stages, result files, review when a desk is done) is optimized for Shep as the orchestrator. Bercail does the local work; Shep decides what happens next.

Claude Code, Codex CLI, and cursor-agent are equal harnesses. Bercail does not prefer one, pick one, or fall back from one to another. A handoff is a [beads](https://beads.gascity.com/) issue: Shep writes it, and the agent's whole prompt is one line pointing at that issue.

Omarchy, Ubuntu/Debian, macOS. Installer and CLI: `bercail`.

<img width="2133" height="1386"  alt="desk agent, review, files"  src="https://github.com/user-attachments/assets/ec959b30-ba4a-4013-bd9f-00972d82d3cd" />

- **the desk** — each space's agent (claude, codex, or grok, picked on the desk) is an hc terminal, not a tab. Tabs move around it, and it keeps running when the window closes.
- **one worktree, one space** — [worktrunk](https://github.com/max-sixty/worktrunk) creates the tree; a Herdr space follows.
- **control and observability** — every agent is working, blocked, done, or idle. Review opens on `done`. You choose what gets a GitHub comment.
- **review when the agent is done** — `tuicr -w` on the staged, uncommitted work the agent left for you (watching). Other people's PRs open with `tuicr pr`. `Ctrl+Shift+R` anytime.
- **handoff is parallel, not a chat fork** — one beads issue per job, run headless or in a sibling worktree with its own desk. See [handoff](#handoff).
- **keyboard and mouse** — `Ctrl+Shift` keys like the rest of the Herdr app. Click the file tree; `j`/`k` in tuicr.

```
┌──────────────┬────────────────────────────┬─────────┐
│ desk agent   │ Shell  |  Review*  | …     │ files   │
│ Ctrl+Shift+A │ tuicr on agent done        │ changes │
│              │ Ctrl+Shift+S / R           │ +F / +G │
└──────────────┴────────────────────────────┴─────────┘
```

## Shep, the Grok bot

**[Shep](https://x.ai/bot/Yber1TlDZinVy6FQZcPsF) is the Grok bot that orchestrates bercail.** It orchestrates coding agents in the Herdr app through bercail: it writes beads issues, hands them to claude, codex, or cursor-agent, and pings you when a desk is ready to review.

Bercail's workflow is designed around Shep. Shep owns the workflow; bercail runs what Shep asks for and reports back in files Shep reads:

1. Shep writes the job as a beads issue (`bd create`): the ask, the repo, links, and any "plan only" note.
2. Shep picks a stage for that issue and runs `handoff-spawn --stage start|codex|cursor --issue ID` (see [handoff](#handoff)). bercail never picks the stage and never falls back to another one.
3. bercail checks `bd` and the issue, adds a `bd comment` with the worktree (and, headless, the result file), and starts that one harness with a one-line prompt pointing at the issue.
4. For a `--branch` desk, Shep hears from the desk through [agent status webhooks](#agent-status-webhooks), or follows it with `hc wait <desk>` (`desk` and `space` are in the spawn JSON). A headless run opens nothing in the app: `handoff-spawn` returns when it ends, and Shep reads `.bercail/handoff-result.json` (`ready`, `blocked`, or `failed`), resumes the session if needed, and tells you when the desk is ready.

Shep runs the same workflow whichever harness works the issue.

Bercail works without Shep, but Shep is the intended orchestrator. To do Shep's part by hand, write the issue with `bd create`, then run the same `handoff-spawn` command.

### agent status webhooks

`bercail notify run` follows the desk agents (hc terminals labelled `bercail.role=agent`) with `hc events` and posts their status changes to webhooks, one sink per bot. The desk mod keeps it running as the hidden hc terminal `bercail-notify`. It sends only these:

- `finished`: working or blocked → done or idle
- `blocked`: once each time the agent blocks

Sinks are `~/.config/bercail/notify.d/<name>.toml` (`chmod 600`; see [`notify.sink.example`](config/agentic-dev/notify.sink.example)). They filter by space name glob, repo, and kind. The key is sent through a private header file, never through argv. A 401 or 403 is recorded and logged; `bercail notify status` and `bercail doctor` show it. Without sinks the follower idles. `bercail update` restarts a running follower so it runs the new code. `bercail doctor` flags a live follower that missed a desk finishing or blocking.

`bercail notify add NAME` sets up a sink in one step. It prompts for the webhook URL and the sender key (hidden), writes the file with mode 600, and sends a test. The running follower picks the new sink up on its next delivery, without a restart. A 401 or 403 means the key or the auth mode is wrong.

```bash
bercail notify add work-shep                       # paste the URL, then the key
bercail notify add work-shep --auth bearer --all-repos --notify finished
printf '%s\n%s\n' "$URL" "$KEY" | bercail notify add work-shep --yes   # no terminal
bercail notify status          # sinks, filters, last HTTP code; never prints url or key
bercail notify test work-shep
```

`notify add` options: `--auth both|bearer|x-automation-key|none` (default `both`), `--repos LIST` (default: the current checkout's repo, or every repo outside a checkout), `--all-repos`, `--spaces GLOBS`, `--notify finished,blocked` (default both), and `--yes` to replace an existing sink without asking. Without `--yes` it shows the existing sink redacted and asks first. With no terminal it reads the URL, then the key, one per line from stdin; `BERCAIL_NOTIFY_URL` and `BERCAIL_NOTIFY_KEY` skip their prompt. It never takes the key as an argument, so the key stays out of shell history and the process list.

Older sink files may have a `panes = agent` line. `agent_status/v2` has no panes: the key is ignored, and the follower drops the line when it starts.

Each POST body is `bercail.agent_status/v2`:

```json
{"source":"bercail","schema":"bercail.agent_status/v2","kind":"finished","sink":"work-shep",
 "at":"2026-10-29T22:42:00Z","event_id":"t9:finished:1793312520:4242",
 "agent":{"address":"t9","app":"claude-code","status":"done","previous_status":"working","title":"..."},
 "space":{"id":"sp98de","name":"Render-preview_Leftlane_app","repo":"leftlane_app","checkout_path":"/path/desk","linked":true},
 "desk":{"branch":"feat/render","issue":"lef2745-2vs","stage":"start","harness":"claude",
         "result":{"status":"ready","summary":"...","session_id":"..."}}}
```

`agent.address` is the hc terminal (`hc get`/`hc read` it). `desk.issue`, `stage`, and `harness` come from the matching `handoffs.jsonl` record. `desk.result` is the checkout's `.bercail/handoff-result.json` when one exists (usually `null`: headless runs have no desk terminal, so they send nothing).

## install

Current release: [v0.9.4](https://github.com/simoncrypta/bercail/releases/tag/v0.9.4).

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

mise holds back each new release for its first 24 hours (`minimum_release_age`), so right after a release `mise use` still installs the previous one. To take a newer release sooner, pin it: `mise use -g packslip:github.com/simoncrypta/bercail@0.9.4`.

The first install trusts the repository's signer, and later installs must match it. `bercail install` runs the release's own `install.sh`. mise or packslip keeps the `bercail` command, so the installer does not copy a second one into `~/.local/bin`. Upgrade with `mise up` (or `packslip install` again), then `bercail update`.

curl is still supported. It reads the repository tip and does not need a release:

```bash
curl -fsSL https://setup.simoncrypta.dev/install.sh | bash
```

`--yes` is non-interactive (`bercail install --yes` too). From a clone: `./install.sh`.

Bercail runs on the Herdr app. When it is missing, the installer runs [herdr.dev](https://herdr.dev)'s own installer (`~/.local`, no sudo), which brings herdr-core (`hc`); the app keeps both updated after that. The installer copies the bercail layout and its desk mod into `~/.config/herdr-app` and adds its keys to `keys.json`. Switch to it once with `Ctrl+Shift+L` → bercail.

The layout is also shared on its own at [herdr.dev/layouts](https://herdr.dev/layouts/): [`bercail/`](bercail) holds the layout, the desk mod, its keys, and a [RECIPE.md](bercail/RECIPE.md). Added that way you get the desk and Review, without worktrees, handoff, or webhooks. It needs the Herdr app (`herdr-app`, `~/.config/herdr-app`), not the `herdr` terminal and its `herdr plugin` system.

From 0.8 (the Herdr terminal and its layout plugin): run the full install once (`bercail install`, or the curl line) so it adds the Herdr app; `bercail update` alone doesn't install dependencies. bercail no longer touches `~/.config/herdr`, the old plugin, or the `herdr` binary; remove them when you no longer need them. Webhook sinks in `notify.d` keep working, but their payload is now `bercail.agent_status/v2` (see [agent status webhooks](#agent-status-webhooks)).

Then, in a repo:

```bash
dev          # this directory's space, with its desk agent
# or: t      # open the Herdr app
```

An empty desk offers claude, codex, and grok; it remembers the last pick, and `Ctrl+Shift+A` starts that one. Before the first pick, `Ctrl+Shift+A` starts `[agent] command` from `~/.config/bercail/config.toml` (cursor-agent by default). Handoff stages do not read either; each stage names its own binary.

## handoff

The job lives in a beads issue. [Shep](#shep-the-grok-bot), the Grok bot, creates the issue (`bd create`), then runs `handoff-spawn` with the issue id and a stage. `--stage` and `--issue` are both required; bercail has no default harness and no fallthrough.

| Stage | Binary | Headless argv (the last word is the prompt) |
|-------|--------|-----------------------------------------------|
| `start` | claude | `claude --print --model claude-opus-5-5 --output-format json …` |
| `codex` | codex | `codex exec --json --sandbox workspace-write …` |
| `cursor` | cursor-agent | `cursor-agent --print --output-format json --trust --force …` |

```bash
bd create "Fix the login timeout" --description "..."     # Shep (the Grok bot) writes the issue
~/.agents/skills/handoff/scripts/handoff-spawn --info      # facts as JSON, incl. beads

# headless: nothing opens in the Herdr app; result is <worktree>/.bercail/handoff-result.json
~/.agents/skills/handoff/scripts/handoff-spawn --stage codex --issue ID --worktree PATH [--dry-run]
~/.agents/skills/handoff/scripts/handoff-spawn --stage start --issue ID --worktree PATH --resume SESSION

# sibling worktree with its own space; the desk runs the stage's binary
~/.agents/skills/handoff/scripts/handoff-spawn --branch NAME --stage cursor --issue ID [--dirty|--clean] [--space ID]
```

- **Prompt** — one line pointing at the issue (`Your job is beads issue <id>. Run bd show <id> …`), the same for every harness.
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
| `bercail doctor` | Deps, Herdr layout, mod and keys, skills, webhook sinks and follower |
| `bercail harness` | JSON: which of claude, codex, cursor-agent are on PATH (reports, does not choose) |
| `bercail update` | Re-sync configs, Herdr layout and mod, helper, skills (`--force` also replaces a changed layout) |
| `bercail reconfigure` | Re-read `config.toml`, refresh skills |
| `bercail dry-run` | Show install actions, write nothing |
| `bercail uninstall` | Remove managed files and the shell marker |
| `bercail notify status` / `add NAME` / `test NAME` | [Agent status webhooks](#agent-status-webhooks) |

### shell

| Command | What |
|---------|------|
| `dev` (or `d`) | Show the Herdr space for `$PWD` (made if missing) and start its desk agent |
| `t` | Open the Herdr app |
| `wtc [branch]` | Create worktree + its space |
| `wts [branch]` | Switch worktree (fzf if omitted) |
| `wtd [branch]` | Remove worktree + close its space |

### skills

Call by name. Skills install to `~/.agents/skills`; bercail adds a link where the configured agent looks elsewhere (`~/.claude/skills`, `~/.codex/skills`, …).

| Skill | What |
|-------|------|
| `handoff` | Run a beads issue on a stage (`--stage start|codex|cursor --issue ID`), headless or as a `--branch` desk. See [handoff](#handoff) |
| `review` | Wait for **human** tuicr notes; publish to GitHub only if asked |

```bash
# review helpers
~/.agents/skills/review/scripts/wait-comments.sh --repo . [--timeout N]
~/.agents/skills/review/scripts/publish-github.sh --repo . \
  [--event comment|approve|request-changes] [--body TEXT] [--dry-run]
```

Manual skill install: `npx skills add simoncrypta/bercail --skill handoff -g`

### review

Review is a tab in the space. Own work → `tuicr -w` (uncommitted only, watching; agents stage and never commit unreviewed work, and a clean tree does not auto-open); someone else's PR on this checkout → `tuicr pr <n>`. It opens when the desk agent finishes, or with `Ctrl+Shift+R`; `auto_review = false` keeps only the key. A live Review tab is not restarted — tuicr's diff watch keeps it current. An agent opens and closes it with `herdr-app do bercail-desk.review:$HC_TERMINAL_ID` and `bercail-desk.close-review:$HC_TERMINAL_ID`.

## keys

In the bercail layout (`~/.config/herdr-app/keys.json`, section `layout:bercail`):

| Key | Action |
|-----|--------|
| `Ctrl+Shift+A` | Focus the desk agent, or start it |
| `Ctrl+Shift+R` | Review |
| `Ctrl+Shift+S` | Shell tab |
| `Ctrl+Shift+F` / `G` | Show or hide files / changes |
| `Ctrl+Alt+Left` / `Right` | Move between panes; left from the leftmost pane reaches the desk |
| `Alt+Up` / `Down` | Previous/next space: repos and other spaces, skipping worktree spaces |
| `Ctrl+Alt+Up` / `Down` | Previous/next space of this repo: its main checkout and worktrees, as the sidebar nests them |
| `Alt+Shift+Up` / `Down` | Previous/next agent, desks included, in sidebar order |
| `Ctrl+Shift+Q` | Close this space |

`bercail update` keeps the keys you changed in that section (and warns about them); `bercail doctor` lists them, and any `terminal` key that takes one of bercail's.

The rest are the Herdr app's: `Ctrl+Shift+T`/`W` new/close tab, `Ctrl+Shift+O`/`E` split, `Ctrl+Shift+X` close pane, `Ctrl+Shift+Z` zoom, `Alt+1`…`9` tabs, `Alt+H`/`J`/`K`/`L` panes, `Ctrl+Shift+B` sidebar, `Ctrl+Shift+L` layout, `Ctrl+Shift+?` all keys.

## config

`~/.config/bercail/config.toml`:

```toml
[agent]
command = "cursor-agent"

[layout]
review = "tuicr"
auto_review = true
```

Also: `~/.config/herdr-app/layouts/bercail.json` and `mods/bercail-desk/` (the app rewrites the layout as you use it, so `bercail update` replaces it only when bercail ships a new one), worktrunk hooks, `~/.agents/skills/{handoff,review}`.

## platforms

On Omarchy: mise first, `omarchy pkg add`, optional `SUPER+ALT+RETURN` → open or focus the Herdr app, fcitx5 `Ctrl+Alt+H/J` hint keys cleared. On Ubuntu: mise then apt (`git fzf jq curl`); worktrunk, beads, tuicr from upstream. On macOS: mise first; Homebrew stays on PATH as fallback (`brew shellenv`, then mise shims prepended). Hyprland: same optional `SUPER+ALT+RETURN` binding.

## dependencies

Installed if missing: the [Herdr app](https://herdr.dev) with herdr-core (`herdr-app`, `hc`, from herdr.dev's installer), git, worktrunk (`wt`), [beads](https://beads.gascity.com/) (`bd`), fzf, jq, [tuicr](https://github.com/agavra/tuicr) ≥ 0.20.0. `bercail doctor` checks each one.

worktrunk and beads install the same way: skip if present, else mise, else Homebrew (`brew install worktrunk` / `brew install beads`), else upstream (worktrunk's GitHub release; the [beads installer](https://raw.githubusercontent.com/gastownhall/beads/main/scripts/install.sh), which puts `bd` in `/usr/local/bin` when writable, else `~/.local/bin`).

[Claude Code](https://docs.anthropic.com/en/docs/claude-code), [Codex CLI](https://github.com/openai/codex), and cursor-agent are optional. Install the ones you want Shep to use; `bercail harness` reports which are on PATH.

## development

```bash
shellcheck install.sh lib/*.sh bin/bercail config/shell/bercail.inc.sh config/worktrunk/herdr-layout.sh
herdr-app check bercail/mods/bercail-desk
for t in tests/*_test.sh; do bash "$t" || break; done
./install.sh --help
bercail dry-run
npm run deploy   # Cloudflare Pages (CI deploys master)
```

## license

MIT — [LICENSE](LICENSE).
