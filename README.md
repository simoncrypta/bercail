# bercail

**an ADE on [herdr](https://herdr.dev).**

Bercail is an agentic development environment on the [Herdr app](https://herdr.dev) and herdr-core (`hc`), built for working in parallel with control and observability. One git worktree, one Herdr space. Each space has a desk: one agent that stays on the left while you switch shell, review, and files. You see when each agent is working, blocked, or done. Agents stage their changes and leave them uncommitted; when the agent goes `done`, [tuicr](https://github.com/agavra/tuicr) opens those uncommitted changes and watches further edits. You review in the terminal; comments stay human vs AI; push to GitHub only when you ask.

**Bercail is built to be orchestrated by a Grok bot.** [Shep](#shep-the-grok-bot) is that bot: a public Grok bot that runs bercail for you. The agentic workflow here (beads issues, named stages, result files, review when a desk is done) is optimized for Shep as the orchestrator. Bercail does the local work; Shep decides what happens next.

**New installs run [bstack](#bstack): one harness, [opencode](https://github.com/anomalyco/opencode), on your own Claude, ChatGPT, and X subscriptions.** Claude Code, Codex CLI, and cursor-agent stay equal harnesses beside it. Bercail does not prefer one for a handoff, pick one, or fall back from one to another. A handoff is a [beads](https://beads.gascity.com/) issue: Shep writes it, and the agent's whole prompt is one line pointing at that issue.

Omarchy, Ubuntu/Debian, macOS. Installer and CLI: `bercail`.

<img width="2133" height="1386"  alt="desk agent, review, files"  src="https://github.com/user-attachments/assets/ec959b30-ba4a-4013-bd9f-00972d82d3cd" />

- **the desk** — each space's agent (bstack when it is on, else your `[agent] command`) is pinned beside the tabs. It is an hc terminal, so it keeps running when the window closes.
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

## bstack

**bstack is bercail's opinionated opencode.** opencode v2 signs in with a Claude plan (Claude Agent), a ChatGPT plan, and an X subscription, so one harness runs all three, on subscriptions you already pay for. bstack sets opencode up the way bercail works: the job is a beads issue, agents stage and leave changes uncommitted for tuicr, and each kind of work goes to the model that is best at it. Ideas from [pstack](https://github.com/cursor/plugins/tree/main/pstack) (rigor, playbooks, roles by model strength, `how`/`why`/`unslop`), [cursor-team-kit](https://github.com/cursor/plugins/tree/main/cursor-team-kit) (babysit-pr and CI loops, which became autopilot), [tstack](https://github.com/t3dotgg/tstack) (a council of providers), and [gstack](https://github.com/garrytan/gstack), on top of Shep's handoff workflow.

```bash
bercail bstack setup     # installs opencode, connects your plans; models are picked for you
bercail bstack status    # what is connected, which model each role uses
dev                      # the desk starts opencode as the bstack agent
```

`setup` asks before each sign-in (`opencode auth login claude-agent`, `openai`, `xai --method device`) and does not ask about models: each connected plan gets its newest model (Claude's `opus` alias, the newest GPT Sol, the newest plain Grok release) at `effort` (default `high`, or the next level down when a model stops short). `bercail update` picks again, so a new release reaches bstack without you doing anything, and `bercail doctor` says when a plan or model changed since the last update. To pin a model, set `claude`, `gpt`, or `grok` under `[bstack]` in `config.toml`; `bercail bstack status` shows each one as `auto` or `pinned`. `--yes` connects nothing. In opencode, `/bstack-setup` shows the same state and says what to run.

| Role | opencode agent | Default provider | For |
|------|----------------|------------------|-----|
| lead | `bstack` (primary, the default agent) | claude | Plans, routes, proves, reports |
| build | `bstack-builder` | grok | Code from a precise brief |
| judge | `bstack-judge` | claude | The hardest calls, design, prose |
| council | `bstack-council-<provider>` | every connected plan | Read-only review, one per provider |

A role names a provider (`claude`, `gpt`, `grok`) or a full opencode model id. When its provider isn't connected, it takes the next one that is (build: grok, then gpt, then claude), so bstack works on one plan and spreads out as you connect more. With none connected, agents use the session's model.

- **Commands** — `/how` and `/why` (how code works, and why it is that way, from git, PRs, and beads), `/council` (each provider reviews the change; only findings that hold up are kept), `/unslop` (clean machine-writing tells out of text or the diff), `/ready` (prove it, run the council, unslop, stage it, report), `/autopilot` (watch a PR's CI and review threads, fix and push until green), `/handoff` (write the beads issue and spawn it), `/bstack-setup`.
- **Skills** — `bstack` (playbooks: investigation, bug fix, feature, refactor, review, ship, handoff, takeover), `how`, `why`, `unslop`, `council`, and `autopilot`, in `~/.agents/skills`, which opencode reads directly. They work in other harnesses too, without the subagents.
- **Autopilot** — the one agent that commits and pushes without asking (`bstack-autopilot`), and only to the PR's branch: no force-push, no `--no-verify`, no merge. It stops when checks pass and no review thread waits on you, and leaves product calls to a person.
- **Guide** — [docs/bstack](docs/bstack/README.md) walks through setup, the playbooks, review, shipping, and handoff, with prompts to copy.
- **Handoff** — stage `bstack` runs `opencode run --agent bstack` headless on the lead's model; it can't commit, push, or merge. Stage `autopilot` runs `bstack-autopilot` on a PR's checkout and pushes its fixes. `--binary opencode` runs `start` (Claude) or `codex` (GPT) through your opencode plans instead. See [handoff](#handoff).
- **Files** — `~/.config/opencode/opencode.jsonc` (default agent, bstack's instructions, ask before commit and push, policies that hard-deny force-push and `--no-verify` even in headless runs, keyless web search, the todo tool, background compaction), `agents/bstack*.md`, `commands/`, and `bstack/instructions.md`. Each carries a `managed by bercail (bstack)` line; delete that line and bercail leaves the file alone. Your own settings go in `opencode.json`, which opencode loads under the `.jsonc`. bstack never touches a file without the line.
- **On and off** — new installs turn it on (`./install.sh --no-bstack` to skip). An existing install keeps its config until `bercail bstack on`, which also moves the desk default from cursor-agent to opencode. `bercail bstack off` removes only bstack's files.

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
bercail notify repo add work-shep              # add this checkout's repo to the sink
bercail notify repo remove work-shep myapp
```

A desk in a repo that no enabled sink covers posts nowhere, so bercail says so. `handoff-spawn --branch` prints one warning on stderr with the `bercail notify repo add` command that fixes it (the spawn still goes ahead), and `bercail doctor` lists each repo with a live desk that no sink covers. `bercail notify check [PATH]` runs the same check by hand. With no sinks at all there is nothing to warn about. `notify repo add` and `remove` change only the sink's `repos` line. On an `--all-repos` sink they do nothing and say so. `remove` refuses to take out a sink's last repo, because an empty list means every repo.

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

With bstack on, every space starts its desk as bstack (opencode with your terminal's colors), shown in the desk column. Quit it and it stays quit; `Ctrl+Shift+A` starts it again. With bstack off, `Ctrl+Shift+A` starts `[agent] command` from `~/.config/bercail/config.toml`. Handoff stages do not read either; each stage names its own binary.

## handoff

The job lives in a beads issue. [Shep](#shep-the-grok-bot), the Grok bot, creates the issue (`bd create`), then runs `handoff-spawn` with the issue id and a stage. `--stage` and `--issue` are both required; bercail has no default harness and no fallthrough.

| Stage | Binary | Headless argv (the last word is the prompt) |
|-------|--------|-----------------------------------------------|
| `start` | claude | `claude --print --model claude-opus-5-5 --output-format json …` |
| `codex` | codex | `codex exec --json --sandbox workspace-write …` |
| `cursor` | cursor-agent | `cursor-agent --print --output-format json --trust --force …` |
| `bstack` | opencode | `opencode run --format json --agent bstack --model <lead> …` (asks are rejected: no commit, push, or merge) |
| `autopilot` | opencode | `opencode run --format json --agent bstack-autopilot --model <lead> …` (commits and pushes a PR's fixes; headless only) |

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
- **Result** — a headless run leaves `{status: ready|blocked|failed, summary, session_id}`. A plan usage limit also sets `reason` to `usage-limit`, so Shep can propose another plan. Bercail does not switch or rerun. Read that file, not terminal output. `--resume SESSION` continues the same session (`claude --resume`, `codex exec resume`, `cursor-agent --resume`, `opencode run --session`).
- **Blocked, not switched** — if the stage's binary, `bd`, or the issue is missing, the result is `blocked` and nothing starts. Bercail never falls through to another harness. `--binary claude|codex|cursor-agent|opencode` runs a headless stage on another CLI only when you ask (with `opencode`, `start` stays on Claude and `codex` on GPT, through your opencode plans).
- **Dry run** — `--dry-run` prints the exact argv for any stage, even when that binary is not installed.
- `bercail harness` reports which of claude, codex, cursor-agent, and opencode are on PATH, with a local model hint. It does not choose.

## commands

### install / CLI

| Command | What |
|---------|------|
| `bercail install` | Full install from the release mise or packslip unpacked |
| `./install.sh` | Full install |
| `./install.sh --yes` | Non-interactive |
| `./install.sh --no-bstack` | New install without bstack (desk default stays cursor-agent) |
| `./install.sh --help` | Installer help |
| `bercail help` | This reference |
| `bercail doctor` | Deps, Herdr layout, mod and keys, skills, webhook sinks and follower |
| `bercail harness` | JSON: which of claude, codex, cursor-agent, opencode are on PATH (reports, does not choose) |
| `bercail bstack setup` / `status` / `on` / `off` | [bstack](#bstack): opencode on your own plans |
| `bercail update` | Re-sync configs, Herdr layout and mod, helper, skills (`--force` also replaces a changed layout) |
| `bercail reconfigure` | Re-read `config.toml`, refresh skills |
| `bercail dry-run` | Show install actions, write nothing |
| `bercail uninstall` | Remove managed files and the shell marker |
| `bercail notify status` / `add NAME` / `repo add NAME` / `repo remove NAME REPO` / `check [PATH]` / `test NAME` | [Agent status webhooks](#agent-status-webhooks) |

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
| `handoff` | Run a beads issue on a stage (`--stage start|codex|cursor|bstack|autopilot --issue ID`), headless or as a `--branch` desk. See [handoff](#handoff) |
| `review` | Wait for **human** tuicr notes; publish to GitHub only if asked |
| `bstack` | Playbooks for rigorous work, routed by role. See [bstack](#bstack) |
| `council` | One reviewer per connected provider; keep only findings that hold up |
| `how` / `why` | How code works now; why it is that way, from git, PRs, and beads. Read-only |
| `unslop` | Clean machine-writing tells out of prose and a diff |
| `autopilot` | Drive an open PR to green: CI, review threads, conflicts. Pushes; never merges |

```bash
# autopilot: one JSON snapshot of a PR (checks, open threads, next step); --wait polls
~/.agents/skills/autopilot/scripts/pr-state.sh [--pr N] [--wait SECONDS]

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
command = "opencode"

[layout]
review = "tuicr"
auto_review = true

[bstack]
enabled = true
claude = ""                          # empty: auto; an opencode id pins one
gpt = ""
grok = ""
lead = "claude"                      # a provider or a full opencode model id
build = "grok"
judge = "claude"
```

Also: `~/.config/herdr-app/layouts/bercail.json` and `mods/bercail-desk/` (the app rewrites the layout as you use it, so `bercail update` replaces it only when bercail ships a new one), worktrunk hooks, `~/.agents/skills/{handoff,review,bstack,council,autopilot,how,why,unslop}`, and bstack's files in `~/.config/opencode`.

## platforms

On Omarchy: mise first, `omarchy pkg add`, optional `SUPER+ALT+RETURN` → open or focus the Herdr app, fcitx5 `Ctrl+Alt+H/J` hint keys cleared, and a post-update hook (`~/.config/omarchy/hooks/post-update.d/bercail.hook`): after `omarchy-update`, it fast-forwards the clone bercail was installed from and runs `bercail update` without prompting (each question takes its default, no). It skips with one line when offline, dirty, off master/main, or diverged. Herdr updates itself; `bercail doctor` says when a downloaded Herdr waits on a window restart. On Ubuntu: mise then apt (`git fzf jq curl`); worktrunk, beads, tuicr from upstream. On macOS: mise first; Homebrew stays on PATH as fallback (`brew shellenv`, then mise shims prepended). Hyprland: same optional `SUPER+ALT+RETURN` binding.

## dependencies

Installed if missing: the [Herdr app](https://herdr.dev) with herdr-core (`herdr-app`, `hc`, from herdr.dev's installer), git, worktrunk (`wt`), [beads](https://beads.gascity.com/) (`bd`), fzf, jq, [tuicr](https://github.com/agavra/tuicr) ≥ 0.20.0. `bercail doctor` checks each one.

worktrunk and beads install the same way: skip if present, else mise, else Homebrew (`brew install worktrunk` / `brew install beads`), else upstream (worktrunk's GitHub release; the [beads installer](https://raw.githubusercontent.com/gastownhall/beads/main/scripts/install.sh), which puts `bd` in `/usr/local/bin` when writable, else `~/.local/bin`).

With bstack on: [opencode](https://github.com/anomalyco/opencode) v2 (mise, else `brew install anomalyco/tap/opencode-v2`). Its Claude Agent sign-in runs [Claude Code](https://docs.anthropic.com/en/docs/claude-code), so a Claude plan needs `claude` too.

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
