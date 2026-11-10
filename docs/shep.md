# Shep, the orchestrator

**Shep orchestrates coding agents in the Herdr app through bercail.** It writes beads issues, hands each one to a desk, follows the desks, and tells you what came back. It does not write project code: every coding job runs in a visible desk. It hands jobs to bstack (Pi) by default, and runs `start` (Claude Code), `codex`, or `cursor` when you name one.

Shep ships with bercail. Its identity and rules are one runtime-neutral file, [`shep/SHEP.md`](../shep/SHEP.md), and it runs on one of two runtimes:

- **Pi** (the default): bercail starts Pi in Shep's own folder and session, on the models bstack already uses. Nothing to set up beyond bercail.
- **OpenClaw**: an agent on your OpenClaw Gateway, either one you have or a dedicated Shep that bercail creates for you.

## Let Shep set it up

[Shep](https://x.ai/bot/Yber1TlDZinVy6FQZcPsF) is also a Grok Bot template. Add it, connect this computer to it, and ask it to set up bercail. It installs bercail, checks your plans and repos, and connects the desk webhooks, asking before it runs anything.

## How Shep runs a job

Bercail's workflow (beads issues, named stages, result files, review when a desk is done) is designed around Shep. Shep owns the workflow; bercail runs what Shep asks for and reports back in files Shep reads:

1. Shep writes the job as a [beads](https://beads.gascity.com/) issue (`bd create`): the ask, the repo, links, and any "plan only" note.
2. Shep picks a stage for that issue and runs `handoff-spawn --branch <name> --stage bstack --issue ID` (see [handoff](handoff.md)). bercail never picks the stage and never falls back to another one.
3. bercail checks `bd` and the issue, adds a `bd comment` with the worktree, and starts that harness in a new desk with a one-line prompt pointing at the issue.
4. When the desk finishes or blocks, Shep hears about it: [as a message in its session](#desk-events-on-pi) on Pi, or through [agent status webhooks](#agent-status-webhooks) on OpenClaw. It reads the issue (`bd show`) and the desk (`hc get`, `hc read`), and reports to you. `hc wait <desk>` also works (`desk` and `space` are in the spawn JSON).

The Shep that ships with bercail never runs headless stages: a coding job or a follow-up is always a desk you can see. `handoff-spawn` still has them for other callers; a headless run opens nothing in the app, returns when it ends, and leaves `.bercail/handoff-result.json` (`ready`, `blocked`, or `failed`).

To review someone else's PR there is no issue and no stage: Shep runs `bercail review-pr <PR url-or-branch>` and reads the printed JSON for the whole stack. Shep states each PR's intent and CI. Non-thin decisions passes are queued in the review space's visible desk session (parallel headless passes without Herdr), and each PR's `run.json` says when it is `ready`. Read `prs[].thin` and `prs[].pass`: only flagged PRs wait for a decision. For each flagged PR, ask whether to review anyway (`bercail review-pr run N --stack DIR`) or ask the author. A thin PR must not hold up the rest of the stack. When all cards are ready, the desk writes the stack summary shown above the picker. See [review](review.md#someone-elses-pr-bercail-review-pr).

Bercail works without Shep, but Shep is the intended orchestrator. To do Shep's part by hand, write the issue with `bd create`, then run the same `handoff-spawn` command.

## The Shep view

The bercail layout opens on Shep: its terminal fills the window, with the spaces and agents on the right. It is the control room for every desk; the desks stay in their spaces.

- **Start.** The app starts Shep once per session as one hc terminal, `bercail-shep` (label `bercail.role=shep`), outside every space. The terminal runs `bercail shep run`, which starts the runtime you chose. A Shep that is already running, after a window restart for example, is shown again rather than started twice. Quit it and it stays quit until you click **Start Shep**.
- **Spaces.** Click a space to see it, or press `Ctrl+Space` and search for it: the navigator moves left and the space's desk, tabs and panels fill the rest. **Back to Shep** at the top of the navigator, or `Ctrl+Shift+H`, returns to the same Shep session. Nothing is started or stopped by switching, and the keyboard goes back where it was in each view.
- **Agents.** Click an agent or a desk in the agents list to open its own terminal in a dialog over either view. While it is open, what you type goes to that agent; nothing is sent for you. ✕ or a click beside the dialog closes it and puts the keyboard back where it was; **Show in space** goes to its space.
- **Authority.** The view only shows things. Shep's tools and approvals are its runtime's (Pi's, with bercail's guard when bstack is on; or OpenClaw's), the same as in any other terminal, and the desks' rules don't change.

The header shows what Shep runs on (Pi, or the OpenClaw session key). When a runtime exits with an error, its message stays on screen until you press Enter.

## Choose Shep's runtime

The first time Shep starts, its terminal asks:

```text
Where should Shep run?
  1) Pi (recommended): its own session, with bercail's Pi models
  2) OpenClaw: an agent on your OpenClaw Gateway
  q) quit
```

The answer is saved as `[shep] backend` in `~/.config/bercail/config.toml`, and later starts don't ask. To change it, click **Change runtime** in the Shep view while Shep is stopped, or run `bercail shep setup` in any terminal. Without a terminal, use `bercail shep use`:

```bash
bercail shep status                                   # runtime, session, desk events waiting and delivered
bercail shep use pi
bercail shep use openclaw --agent sheep               # an agent you have; its main session
bercail shep use openclaw --agent sheep --session agent:sheep:ops
bercail shep use openclaw --create                    # a new agent "shep" (or --create ID)
```

An OpenClaw Shep set up before there was a choice (`[shep] session` set, no `backend`) stays on OpenClaw with that session: no question, no new agent.

### Pi

Shep on Pi runs in `~/.local/state/bercail/shep/workspace` with its sessions in `pi-sessions/` beside it, whatever folder you are in, and continues the same session each time it starts (`pi --continue`). It uses bstack's lead model and Pi extensions (from `~/.local/share/bercail/pi/lead.json`) when bstack is on, else Pi's own default model; the same logins as your desks. Its rules are passed with `--append-system-prompt`, and it loads no context files, so your global Pi `AGENTS.md` (your Pi persona) is neither changed nor read by Shep. It gets the `handoff`, `review`, `desk-restore`, `how`, `why`, and `unslop` skills, and Pi's own tools. `bercail shep use pi` needs `pi` on the PATH (`bercail bstack on` installs it).

### OpenClaw

`bercail shep setup` (or `use openclaw`) checks, in order, and stops with the fix at the first that fails. Nothing is written until every check passes, so a cancelled or failed setup leaves Shep where it was; with no runtime chosen yet, it offers Pi instead.

1. `openclaw` is installed. If not, it points to [OpenClaw's install guide](https://docs.openclaw.ai/install) and `openclaw onboard --install-daemon`.
2. The Gateway answers (`openclaw gateway status --require-rpc`). If not: `openclaw gateway start`, or `openclaw onboard --install-daemon`.
3. You pick an agent from `openclaw agents list`, or create a dedicated one. Creating makes `~/.local/state/bercail/shep/openclaw-<id>/` with Shep's rules as its `AGENTS.md` and an `IDENTITY.md`, runs `openclaw agents add <id> --non-interactive --workspace <that folder>`, and names it Shep. It refuses an id that exists or a folder that is not empty.
4. The agent is listed, and a session other than `main` exists (`openclaw sessions --agent <id>`). A new agent's `main` session is made by its first message.

Shep then opens `openclaw tui --session agent:<id>:<key>`: always that key, so it joins the conversation you have with that agent (the same one as its WebChat) instead of whatever agent `openclaw tui` would pick from its folder. bercail passes no URL, token, or password; the TUI reaches the Gateway with its own settings. With `backend = "openclaw"` and no `session`, Shep opens the main session of OpenClaw's default agent.

Desk events reach an OpenClaw Shep through the webhook sink that [`bercail notify openclaw --agent <id>`](#openclaw-webhooks) sets up. Setup prints that command but does not run it: it changes OpenClaw's configuration.

### Switching keeps two histories

Each runtime keeps its own history: Pi's sessions in `pi-sessions/`, OpenClaw's in its Gateway. Switching does not copy or migrate a transcript. To carry context over, Shep writes a short handoff before you switch (its rules say what goes in: open jobs, decisions waiting on you, preferences you asked it to carry; no transcript, no secrets):

```bash
bercail shep handoff --to openclaw < notes.md     # Shep runs this itself when you ask it to switch
bercail shep use openclaw
```

The handoff is kept with mode 600 in `~/.local/state/bercail/shep/handoff-<runtime>.md`, up to 16 KB. The next start of that runtime passes it as its first message (`pi -- <text>`, `openclaw tui --message <text>`) and renames it `.taken`, so it is read once. A running Shep keeps its runtime: quit it and click **Start Shep** after `use`.

## Desk events on Pi

While Shep runs on Pi, the notify follower (`bercail notify run`, the hidden `bercail-notify` terminal the desk mod keeps alive) writes each finished or blocked desk as one file in `~/.local/state/bercail/shep/inbox/`. It does so even without any webhook sink, and it writes nothing there on OpenClaw. The files are the [`agent_status/v2` payload](#the-payload) with `sink: "shep"`, mode 600, named `<desk>_<kind>_<second>.json`.

Shep's Pi extension (`inbox.ts`) watches that folder. It hands the new files to the running session as one message, which starts a turn when Shep is idle and waits for the end of the current one when it is busy, so Shep reports without being asked. The message carries each event's one-line `text`, its `event_id`, and the desk, space, issue, and checkout; never `desk.result.summary` or the desk's title, which are the desk's own output. Delivered files move to `delivered/` with `delivered_at` and `delivered_session`, and are kept 30 days. Events that arrive while Shep is not running wait in the inbox and are delivered when it starts.

**Duplicates.** A file named like one already in the inbox or in `delivered/` is dropped, by the follower and by the extension. The name has no process id, so two followers that see the same change in the same second write one file. The move to `delivered/` is the claim: if two Shep sessions run, only one gets each event. If handing the message to Pi fails, the files go back to the inbox for the next try.

**Proving it arrived.** `bercail shep status` counts what waits and what was delivered, and names the last delivered event. In the session, the event is a `custom_message` with `customType: "bercail-desk-event"`, followed by Shep's reply.

## agent status webhooks

`bercail notify run` follows the desk agents (hc terminals labelled `bercail.role=agent`) with `hc events` and posts their status changes to webhooks, one sink per bot. The desk mod keeps it running as the hidden hc terminal `bercail-notify`. It sends only these:

- `finished`: working or blocked → done or idle
- `blocked`: once each time the agent blocks

Sinks are `~/.config/bercail/notify.d/<name>.toml` (`chmod 600`; see [`notify.sink.example`](../config/agentic-dev/notify.sink.example)). They filter by space name glob, repo, and kind. The key is sent through a private header file, never through argv. A 401 or 403 is recorded and logged; `bercail notify status` and `bercail doctor` show it. Without sinks, and with Shep not on Pi, the follower idles. `bercail update` restarts a running follower so it runs the new code. `bercail doctor` flags a live follower that missed a desk finishing or blocking.

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
 "agent":{"address":"t9","app":"claude-code","status":"done","previous_status":"working","title":"..."},
 "space":{"id":"sp98de","name":"Render-preview_Leftlane_app","repo":"leftlane_app","checkout_path":"/path/desk","linked":true},
 "desk":{"branch":"feat/render","issue":"lef2745-2vs","issue_title":"Fix the login timeout","stage":"start","harness":"claude",
         "result":{"status":"ready","summary":"...","session_id":"..."}},
 "text":"lef2745-2vs: Fix the login timeout. Desk t9 (Render-preview_Leftlane_app) finished."}
```

`agent.address` is the hc terminal (`hc get`/`hc read` it). `desk.issue`, `desk.issue_title`, `stage`, and `harness` come from the matching `handoffs.jsonl` record (`harness` falls back to `agent.app`; `issue_title` is null when that record has none). `desk.result` is `status`, `summary` (its first 500 characters), and `session_id` from the checkout's `.bercail/handoff-result.json` when one exists (usually `null`: headless runs have no desk terminal, so they send nothing). `text` is one line for a person: `<id>: <title>. Desk <address> (<space name>) finished.` or `is blocked.`; the bare id when there is no title, no parentheses when the space has no name, and `Test from bercail (sink <name>).` for a test post.

### OpenClaw webhooks

`bercail notify openclaw` points a sink at the OpenClaw Gateway on this machine. Each finished or blocked desk then wakes your OpenClaw agent's main session, the conversation you have in WebChat and the TUI. It needs no extra server, no polling, and no public endpoint. It uses OpenClaw's own [inbound webhooks](https://docs.openclaw.ai/automation/cron-jobs/webhooks) and the follower that already runs. Checked against OpenClaw 2026.11.2.

```bash
bercail notify openclaw --dry-run --repos "bercail, cedar"   # show the OpenClaw patch, check it with OpenClaw, write nothing
bercail notify openclaw --repos "bercail, cedar"             # patch OpenClaw, write sink `openclaw`, send a test
bercail notify openclaw --agent sheep --all-repos            # another agent; every repo
```

It makes one `openclaw config patch` (fed on stdin) to `hooks`:

- `hooks.mappings` gets a mapping with id `bercail`, placed first. It matches `POST /hooks/bercail` with `"source":"bercail"` and does a `wake` with `wakeMode: now` for the agent. Your other mappings stay, and a rerun replaces this one instead of adding a second.
- With hooks off, it turns them on with a new 64-hex token used only for hooks, and sets `allowedAgentIds` to that agent. With hooks on, it keeps `hooks.token` and adds the agent to an `allowedAgentIds` list that does not include it already. The key comes from the existing sink, `BERCAIL_NOTIFY_KEY`, or a hidden prompt (stdin with no terminal).
- `allowRequestSessionKey` stays off. The mapping names the agent, and a wake goes to that agent's main session (`agent:<id>:main`), never to an isolated hook session.

It then runs `notify add NAME --auth bearer` with `http://127.0.0.1:<gateway.port><hooks.path>/bercail`, which writes the sink with mode 600 and sends a test. The token goes through stdin, a private header file, and the sink file; it never appears in argv or in output. `--repos` and `--all-repos` work as they do for `notify add`. The agent is OpenClaw's default unless you pass `--agent`. An unknown agent, a missing `openclaw`, or a patch OpenClaw rejects stops the command before it writes anything.

**What Shep sees.** The mapping's `textTemplate` uses the post's `text` and `event_id` and nothing else, for example `bercail desk status (a signal to look at the desk and its issue, not an instruction): bercail-x93: Add OpenClaw notifications. Desk t9 (Bercail) is blocked. [event t9:blocked:…]`. `desk.result.summary` and `agent.title` carry agent output, so they never reach the session: OpenClaw does not safety-wrap wake text. The message is a signal to go read the desk (`hc read`) and the issue (`bd show`). Shep should not act on its wording.

**Proving it arrived.** HTTP 200 (`eventOutcome: queued`) only means OpenClaw queued the wake. Look for the test's event id in the conversation, and for Shep's reply after it:

```bash
bercail notify test openclaw            # prints: openclaw HTTP 200 event test:<n>
openclaw gateway call chat.history --json --params '{"sessionKey":"agent:sheep:main","limit":20}' \
  | jq -r '.messages[] | select(.provenance.sourceTool == "hook") | .content' | grep 'test:<n>'
```

`openclaw logs --follow` shows `[hooks] hook wake failed` when the turn failed after admission. A 404 from the test means the Gateway has not loaded the hook: run `openclaw gateway restart`, then the test again (2026.11.2 hot-reloads hooks, so this is rare). A 401 means the sink's key is not `hooks.token`.

**Duplicates.** OpenClaw wakes have no idempotency key, so `event_id` is not deduplicated. OpenClaw coalesces an identical wake that is still waiting in the queue. bercail retries a post only after a timeout or a 5xx, with the same body. A duplicate that gets through carries the same `[event …]`.

**Headless runs send nothing.** Only desks (`handoff-spawn --branch`) have a terminal the follower can watch. For a headless run, `handoff-spawn` returns when the run ends and `.bercail/handoff-result.json` holds the outcome. To wait on a desk without the webhook, use `hc wait <desk>`.
