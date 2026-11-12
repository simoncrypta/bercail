# Shep, the orchestrator

**Shep orchestrates coding agents in the Herdr app through bercail.** It writes beads issues, hands each one to a desk, follows the desks, and tells you what came back. It does not write project code: every coding job runs in a visible desk. It hands jobs to bstack, on Pi.

Shep ships with bercail. Its rules are one file, [`shep/SHEP.md`](../shep/SHEP.md), and it runs on Pi: bercail starts Pi in Shep's own folder and session, on the models bstack already uses. Nothing to set up beyond bercail.

## Let Shep set it up

[Shep](https://x.ai/bot/Yber1TlDZinVy6FQZcPsF) is also a Grok Bot template. Add it, connect this computer to it, and ask it to set up bercail. It installs bercail, checks your plans and repos, and connects the desk webhooks, asking before it runs anything.

## How Shep runs a job

Bercail's workflow (beads issues, named stages, result files, review when a desk is done) is designed around Shep. Shep owns the workflow; bercail runs what Shep asks for and reports back in files Shep reads:

1. Shep writes the job as a [beads](https://beads.gascity.com/) issue (`bd create`): the ask, the repo, links, and any "plan only" note.
2. Shep picks a stage for that issue and runs `handoff-spawn --branch <name> --stage bstack --issue ID` (see [handoff](handoff.md)). bercail never picks the stage and never falls back to another one.
3. bercail checks `bd` and the issue, adds a `bd comment` with the worktree, and starts Pi in a new desk with a one-line prompt pointing at the issue.
4. When the desk finishes or blocks, Shep hears about it [as a message in its session](#desk-events). It reads the [brief](#briefs-and-the-board) for the issue (its desk's state, the question when it is blocked, the latest report, cut short) and reports to you. `hc wait <desk>` also works (`desk` and `space` are in the spawn JSON).

The Shep that ships with bercail never runs headless stages: a coding job or a code follow-up is always a desk you can see. Waiting is different: Shep never blocks its own thread on CI, a deploy, a desk, or a release, and hands that to a [background Shep](#background-sheps). `handoff-spawn` still has headless stages for other callers; a headless run opens nothing in the app, returns when it ends, and leaves `.bercail/handoff-result.json` (`ready`, `blocked`, or `failed`).

To review someone else's PR there is no issue and no stage: Shep runs `bercail review-pr <PR url-or-branch>` and reads the printed JSON for the whole stack. Shep states each PR's intent and CI. Non-thin decisions passes are queued in the review space's visible desk session (parallel headless passes without Herdr), and each PR's `run.json` says when it is `ready`. Read `prs[].thin` and `prs[].pass`: only flagged PRs wait for a decision. For each flagged PR, ask whether to review anyway (`bercail review-pr run N --stack DIR`) or ask the author. A thin PR must not hold up the rest of the stack. When all cards are ready, the desk writes the stack summary shown above the picker. See [review](review.md#someone-elses-pr-bercail-review-pr).

Bercail works without Shep, but Shep is the intended orchestrator. To do Shep's part by hand, write the issue with `bd create`, then run the same `handoff-spawn` command.

## The Shep view

The bercail layout opens on Shep: its terminal fills the window, with the spaces and agents on the right. It is the control room for every desk; the desks stay in their spaces.

- **Start.** The app starts Shep once per session as one hc terminal, `bercail-shep` (label `bercail.role=shep`), outside every space. The terminal runs `bercail shep run`, which starts Shep on Pi. A Shep that is already running, after a window restart for example, is shown again rather than started twice. Quit it and it stays quit until you click **Start Shep**.
- **Spaces.** Click a space to see it, or press `Ctrl+Space` and search for it: the navigator moves left and the space's desk, tabs and panels fill the rest. **Back to Shep** at the top of the navigator, or `Ctrl+Shift+H`, returns to the same Shep session. Nothing is started or stopped by switching, and the keyboard goes back where it was in each view.
- **Agents.** Click an agent or a desk in the agents list to open its own terminal in a dialog over either view. While it is open, what you type goes to that agent; nothing is sent for you. ✕ or a click beside the dialog closes it and puts the keyboard back where it was; **Show in space** goes to its space.
- **Authority.** The view only shows things. Shep's tools and approvals are Pi's (with bercail's guard when bstack is on), the same as in any other terminal, and the desks' rules don't change. With bstack on, Shep loads the same guard as the desks, so a repo's trusted [git policy](config.md#git-policy-per-repo) lets Shep's commits and pushes there through as it does a desk's. Shep sits in its own folder, not a repo, so instead of a policy in its prompt it runs `bercail policy show <repo>` before it commits, merges, pushes, or releases.

When Pi exits with an error, its message stays on screen until you press Enter.

## Shep on Pi

Shep on Pi runs in `~/.local/state/bercail/shep/workspace` with its sessions in `pi-sessions/` beside it, whatever folder you are in, and continues the same session each time it starts (`pi --continue`). It uses bstack's lead model and Pi extensions (from `~/.local/share/bercail/pi/lead.json`) when bstack is on, else Pi's own default model; the same logins as your desks. Its rules and its [start context](#what-shep-knows) are passed with `--append-system-prompt`, and it loads no context files, so your global Pi `AGENTS.md` (your Pi persona) is neither changed nor read by Shep. Two Pi extensions of its own come with it: `inbox.ts` for [desk events](#desk-events) and `compaction.ts` for [compaction](#compaction). It gets the `handoff`, `review`, `desk-restore`, `how`, `why`, and `unslop` skills, and Pi's own tools. It needs `pi` on the PATH (`bercail bstack on` installs it).

```bash
bercail shep status      # Pi's session folder, desk events waiting and delivered, live background Sheps
bercail shep repos       # your known repos: git backend, policy trust, open issues (--json too)
bercail shep board       # one line per open job across those repos, then what waits on you
bercail shep brief ID    # one issue: its desk and state, the question it is blocked on, the latest report
bercail shep list        # Shep's standing rules: remember "RULE" [--scope S] adds one, forget N drops one
```

An older `~/.config/bercail/config.toml` may still have `backend` and `session` under `[shep]`. bercail no longer reads them; delete them whenever you like. The keys `[shep]` holds now are for [compaction](#compaction).

## What Shep knows

Shep's session is one long conversation, and most of it is tool output. What it needs to know for good sits outside it, in files bercail keeps, so a compaction or a new session loses none of it.

### Known repos

Shep needs no list of your repos to keep up. bercail works it out each time from what it already knows:

- the `[git]`, `[graphite]` and `[policy."<path>"]` keys of `config.toml`,
- trusted policies (`~/.local/state/bercail/policy-trust.json`),
- handoff records (`~/.local/state/bercail/handoffs.jsonl`); a record whose worktree is gone gives its main checkout, from the `<main>.<branch>` name `handoff-spawn` uses,
- the folders of live desks,
- and `~/.local/state/bercail/shep/repos`, one path per line (`#` starts a comment), for a repo bercail has not seen yet.

Each folder becomes its main checkout; one that is no longer a git checkout drops out. `bercail shep repos` prints a line per repo: the path, its git backend (as `handoff-spawn` picks it), its [policy](config.md#git-policy-per-repo) (`policy trusted`, `policy untrusted`, or `no policy`), its open issues (not closed; `no beads` when it has no `.beads` or `bd` does not answer within 10 seconds), and where bercail saw it. `--json` gives the same as an array.

### Briefs and the board

`bercail shep brief <id>` is what Shep reads for a desk event, in place of `bd show` and `hc read --lines 60`:

```
app-1: Fix the login timeout
in_progress P1 bug · labels auth · repo ~/Work/app
desk t9 blocked · space Login-timeout_App (sp98de) · branch login-timeout · worktree ~/Work/app.login-timeout
desk t9 is blocked; its screen ends with:
  | Allow git push origin login-timeout? (y/n)
(the whole screen: hc read t9 --lines 60)
latest report: comment 2 of 2, Desk at 2026-11-11 00:43 (812 characters):
Staged, uncommitted. What changed: …
```

The repo is `--repo DIR`, else the issue's handoff record, its live desk, or the known repo whose `bd` has it. The desk is the live terminal labelled with the issue, else the record's (`gone` when it has ended). A desk [handed off with `--model`](handoff.md) ends its line with `model <provider/id:thinking>`, from its `bercail.model` label, or the record's when it has ended. A blocked desk adds the last 15 lines of its screen, where its question is. The report is the latest comment that is not the handoff note. One longer than `--budget` characters (1500 by default) keeps its first two thirds and its last third, and says how much was cut and that `bd comments <id>` has the rest. Measured on three real issues, a brief was 1,600 to 2,000 characters (about 400 to 500 tokens) against 31,000 to 54,000 for `bd show` plus `hc read --lines 60`: 16 to 33 times smaller.

`bercail shep board` lists one line per open job across the known repos: `<id>: <title>`, its status when not `open`, its desk and state, its branch, and its model when it was handed off with `--model`. A job is an issue that is not closed and has a live desk, or is `in_progress` or `blocked`. A repo's other open issues are a count, with how many of them were handed off to a desk that has since ended. Then: the repos with no jobs, desks still open on closed or unknown issues, and **Waiting on the person**: blocked desks, finished desks to review, and finished background Sheps to report and end.

### Standing rules

A rule you give Shep in conversation ("merge bercail work straight to master", "you may answer cm0's prompts") would otherwise live only in its session. Shep records it as soon as you say it, and tells you:

```bash
bercail shep remember "Merge finished desk work straight to master and push" --scope bercail
bercail shep list        # 1. 2026-11-11 [bercail] Merge finished desk work straight to master and push
bercail shep forget 1
```

They live in `~/.local/state/bercail/shep/preferences.md`, one `- DATE [SCOPE] RULE` line each; `--scope` is a repo, an issue, a desk, or `all` (the default). The same rule and scope twice is kept once. A rule for everyone who uses bercail belongs in [`shep/SHEP.md`](../shep/SHEP.md) or a repo's [policy](config.md#git-policy-per-repo) instead.

### The start context

Each `bercail shep run` writes `~/.local/state/bercail/shep/context.md` and hands it to Pi with `--append-system-prompt`: the known repos, one short line each, and the standing rules. A restart picks up repos and rules that changed while Shep was down.

## Compaction

Pi compacts a session when its context passes `window - reserveTokens`: it summarizes the older part and keeps the most recent `keepRecentTokens` word for word. Pi's defaults (16384 and 20000) let Shep's 1M-token window fill to about 984k tokens first, which Shep's single session never reached. Shep gets its own numbers, and its own summary.

### Settings

bercail writes Shep's compaction into its workspace's `.pi/settings.json`, which Pi reads as project settings, and Shep leaves `~/.pi/agent/settings.json` alone (bstack's [bridge reserve](bstack.md#how-it-runs) lives there):

```json
{"compaction": {"enabled": true, "keepRecentTokens": 50000,
  "modelOverrides": {"claude-bridge/claude-opus-5-5": {"keepRecentTokens": 50000, "reserveTokens": 750000}}}}
```

Pi loads project settings only from a folder you trust, and `--no-context-files` does not change that: without trust they are skipped, or Pi asks. Shep's workspace is a folder only bercail writes to, so Shep starts Pi with `--approve`, which trusts it for that process and saves nothing. Other keys in that file are kept; bercail rewrites `compaction` at each start, from `config.toml`:

```toml
[shep]
compact_at = 250000   # context tokens at which Pi compacts Shep; 0 leaves Pi's threshold
keep_recent = 50000   # recent tokens kept word for word
rollover = false      # true: a fresh session instead of a threshold compaction, and each new day
```

`compact_at` becomes `reserveTokens = window - compact_at` for the lead model, with its window from `pi --list-models` (1M for Opus 5.5, so 750000). Why 250k: most of Shep's context is `bd`, `hc` and log output that is stale once a job moves on, and every turn sends all of it again; past a quarter of the window that costs time and money for nothing, and a compaction starts over from a fresh board. Why 50k: the last several desk events and your last exchanges stay as they were, briefs included, while the summary is rebuilt. When bercail cannot place `compact_at` (not a number, not below the window, or a window `pi --list-models` does not show), Pi's threshold applies and bercail says why at start. On a model whose window is 250k or less, the default `compact_at` leaves Pi's threshold without a word. On a `claude-bridge` model the reserve is never below bstack's 40000, so a `compact_at` within 40k of the window compacts at `window - 40000` instead, before Claude Code refuses the prompt. Changes take effect at Shep's next start.

### The summary

`compaction.ts` builds the summary Pi saves, for `/compact` and for automatic compaction alike, from three parts:

1. **The job board**, from `bercail shep board` at that moment. It replaces whatever the old messages said about jobs.
2. **The standing rules**, from `preferences.md`.
3. **Decisions and open questions** from the part being compacted, written by the lead model from Pi's `serializeConversation` text. It is told to leave out job state, which the board covers, and to carry over the previous summary's decisions unless they were settled.

If any part fails (the board, the model, an empty answer), it returns nothing and Pi compacts the default way: the session is never lost. Each compaction, each fallback with its reason, and each failed compaction (`session_compact_failed`) is a line in `~/.local/state/bercail/shep/compaction.log`.

### Rollover

With `rollover = true`, Shep does not compact forever. When the context passes `compact_at`, it skips that compaction and, as soon as Shep is idle, starts a fresh session whose first message is the board and the rules and names the previous session's file. The first turn on a new day does the same. `/shep-rollover` in Shep does it by hand, whatever the setting. A rollover that fails (the board does not build, say) is logged, and compaction takes over again until Shep restarts.

To go back to the old session, run `/resume` in Shep and pick it; the rollover's first message names its file. Once you write in it, it is the most recent session in `pi-sessions/`, so `bercail shep run` continues it from then on.

## Background Sheps

Shep never watches, waits, polls, or sleeps on anything itself. When something needs waiting on (a CI run, a deploy, a desk, a release), or a step you approved has to happen once it is done, Shep writes it as a beads issue (what to wait for, what to do after, when to stop, what not to do), starts a background Shep on it, tells you in one line, and goes back to you.

```bash
bercail shep bg --issue bercail-ow2                    # from the issue's repo
bercail shep bg --issue bercail-ow2 --cwd ~/Work/bercail
```

It prints `{address, name, cwd, issue, issue_title}`. The background Shep is one hc terminal named `shep-bg-<id>`, started in the background with no space, so nothing in the app moves or takes focus; the agents list shows it. It runs `bercail-desk-agent` on the same Pi setup as a desk (bstack's lead from `lead.json` when bstack is on, with the guard, so the repo's [git policy](config.md#git-policy-per-repo) applies), plus a brief of its own, [`shep/BACKGROUND.md`](../shep/BACKGROUND.md): do only what the issue says, never ask in its terminal (post on the issue with `bd comment` and stop instead), post the result as a `bd comment`, and close the issue only when it says to. Its first message is one line pointing at the issue. A second `bg` for an issue whose background Shep is still live is refused.

Its labels are `bercail.role=agent`, `bercail.shep=bg`, `bercail.issue`, and `bercail.issue_title`, with no `bercail.space`. The notify follower treats it like a desk, so its finish or block reaches Shep as a [desk event](#desk-events) whose text says `Background Shep <address>` and whose `agent.role` is `shep-bg`. It is started with `--no-notify`, so hc types nothing into Shep's prompt, `--outlive-parent`, so restarting Shep does not end the wait, and `--rm`. Once Shep has reported a finished one, `hc kill <name>` ends and removes it; killing it sends no second event.

It runs with `BERCAIL_ROLE=shep-bg`. The guard treats that role like a desk's lead: the repo's policy decides, and a step the policy leaves to you stops at the guard's question. Nobody watches that terminal, so the question turns it blocked, Shep tells you, and you answer it there: click it in the agents list. The role is how the guard's approval log (`guard-approvals.jsonl`) tells it apart.

## Desk events

Once Shep has started for the first time (its first start makes `~/.local/state/bercail/shep/inbox/`), the notify follower (`bercail notify run`, the hidden `bercail-notify` terminal the desk mod keeps alive) writes each finished or blocked desk as one file in that folder. It does so even without any webhook sink. The files are the [`agent_status/v2` payload](#the-payload) with `sink: "shep"`, mode 600, named `<desk>_<kind>_<second>.json`.

Shep's Pi extension (`inbox.ts`) watches that folder. It hands the new files to the running session as one message, which starts a turn when Shep is idle and waits for the end of the current one when it is busy, so Shep reports without being asked. The message carries each event's one-line `text`, its `event_id`, and the desk, space, issue, and checkout; never `desk.result.summary` or the desk's title, which are the desk's own output. Delivered files move to `delivered/` with `delivered_at` and `delivered_session`, and are kept 30 days. Events that arrive while Shep is not running wait in the inbox and are delivered when it starts.

**Duplicates.** A file named like one already in the inbox or in `delivered/` is dropped, by the follower and by the extension. The name has no process id, so two followers that see the same change in the same second write one file. The move to `delivered/` is the claim: if two Shep sessions run, only one gets each event. If handing the message to Pi fails, the files go back to the inbox for the next try.

**Proving it arrived.** `bercail shep status` counts what waits and what was delivered, and names the last delivered event. In the session, the event is a `custom_message` with `customType: "bercail-desk-event"`, followed by Shep's reply.

## agent status webhooks

`bercail notify run` follows the desk agents (hc terminals labelled `bercail.role=agent`) with `hc events` and posts their status changes to webhooks, one sink per bot. The desk mod keeps it running as the hidden hc terminal `bercail-notify`. It sends only these:

- `finished`: working or blocked → done or idle
- `blocked`: once each time the agent blocks

Sinks are `~/.config/bercail/notify.d/<name>.toml` (`chmod 600`; see [`notify.sink.example`](../config/agentic-dev/notify.sink.example)). They filter by space name glob, repo, and kind. The key is sent through a private header file, never through argv. A 401 or 403 is recorded and logged; `bercail notify status` and `bercail doctor` show it. Without sinks, and before Shep's first start, the follower idles. `bercail update` restarts a running follower so it runs the new code. `bercail doctor` flags a live follower that missed a desk finishing or blocking.

### Add a sink

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

`notify add` options: `--auth both|bearer|x-automation-key|none` (default `both`), `--repos LIST` (default: the current checkout's repo, or every repo outside a checkout), `--all-repos`, `--spaces GLOBS`, `--notify finished,blocked` (default both), and `--yes` to replace an existing sink without asking. If the sink exists, it shows it redacted first; without `--yes` it asks on a terminal and refuses without one. With no terminal it reads the URL, then the key, one per line from stdin; `BERCAIL_NOTIFY_URL` and `BERCAIL_NOTIFY_KEY` skip their prompt. It never takes the key as an argument, so the key stays out of shell history and the process list.

### Repos no sink covers

A desk in a repo that no enabled sink covers posts nowhere, so bercail says so. `handoff-spawn --branch` prints one warning on stderr with the `bercail notify repo add` command that fixes it (the spawn still goes ahead), and `bercail doctor` lists each repo with a live desk that no sink covers. `bercail notify check [PATH]` runs the same check by hand. With no sinks at all there is nothing to warn about. `notify repo add` and `remove` change only the sink's `repos` line. On an `--all-repos` sink they do nothing and say so. `remove` refuses to take out the last repo of a sink with no `spaces` filter, because no repos and no spaces means every repo.

Older sink files may have a `panes = agent` line. `agent_status/v2` has no panes: the key is ignored, and the follower drops the line when it starts.

### The payload

Each POST body is `bercail.agent_status/v2`:

```json
{"source":"bercail","schema":"bercail.agent_status/v2","kind":"finished","sink":"work-shep",
 "at":"2026-10-29T22:42:00Z","event_id":"t9:finished:1793312520:4242",
 "agent":{"address":"t9","app":"pi","status":"done","previous_status":"working","title":"...","role":"desk"},
 "space":{"id":"sp98de","name":"Render-preview_Leftlane_app","repo":"leftlane_app","checkout_path":"/path/desk","linked":true},
 "desk":{"branch":"feat/render","issue":"lef2745-2vs","issue_title":"Fix the login timeout","stage":"bstack","harness":"pi",
         "result":{"status":"ready","summary":"...","session_id":"..."}},
 "text":"lef2745-2vs: Fix the login timeout. Desk t9 (Render-preview_Leftlane_app) finished."}
```

`agent.address` is the hc terminal (`hc get`/`hc read` it). `agent.role` is `desk`, or `shep-bg` for a [background Shep](#background-sheps). `desk.issue` and `desk.issue_title` are the terminal's `bercail.issue` and `bercail.issue_title` labels when it has them. `desk.issue`, `desk.issue_title`, `stage`, and `harness` otherwise come from the matching `handoffs.jsonl` record (`harness` falls back to `agent.app`; `issue_title` is null when that record has none); a record or result for another issue than the labels name is left out. `desk.result` is `status`, `summary` (its first 500 characters), and `session_id` from the checkout's `.bercail/handoff-result.json` when one exists (usually `null`: headless runs have no desk terminal, so they send nothing). `text` is one line for a person: `<id>: <title>. Desk <address> (<space name>) finished.` or `is blocked.` (`Background Shep <address>` for a background Shep); the bare id when there is no title, no parentheses when the space has no name, and `Test from bercail (sink <name>).` for a test post.

**Headless runs send nothing.** Only desks (`handoff-spawn --branch`) have a terminal the follower can watch. For a headless run, `handoff-spawn` returns when the run ends and `.bercail/handoff-result.json` holds the outcome. To wait on a desk without the webhook, use `hc wait <desk>`.
