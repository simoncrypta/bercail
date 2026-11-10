# Shep, the Grok Bot

**[Shep](https://x.ai/bot/Yber1TlDZinVy6FQZcPsF) is the Grok Bot template that orchestrates bercail.** It orchestrates coding agents in the Herdr app through bercail: it writes beads issues, hands them to a desk, and pings you when the desk is ready to review. By default it hands a job to bstack (opencode). It runs `start` (Claude Code), `codex`, or `cursor` when you name one.

## Let Shep set it up

Shep is a Grok Bot template. Add it, connect this computer to it, and ask it to set up bercail. It installs bercail, checks your plans and repos, and connects the desk webhooks, asking before it runs anything.

## How Shep runs a job

Bercail's workflow (beads issues, named stages, result files, review when a desk is done) is designed around Shep. Shep owns the workflow; bercail runs what Shep asks for and reports back in files Shep reads:

1. Shep writes the job as a [beads](https://beads.gascity.com/) issue (`bd create`): the ask, the repo, links, and any "plan only" note.
2. Shep picks a stage for that issue and runs `handoff-spawn --stage start|codex|cursor|bstack|autopilot --issue ID` (see [handoff](handoff.md)). bercail never picks the stage and never falls back to another one.
3. bercail checks `bd` and the issue, adds a `bd comment` with the worktree (and, headless, the result file), and starts that one harness with a one-line prompt pointing at the issue.
4. For a `--branch` desk, Shep hears from the desk through [agent status webhooks](#agent-status-webhooks), or follows it with `hc wait <desk>` (`desk` and `space` are in the spawn JSON). A headless run opens nothing in the app: `handoff-spawn` returns when it ends, and Shep reads `.bercail/handoff-result.json` (`ready`, `blocked`, or `failed`), resumes the session if needed, and tells you when the desk is ready.

Shep runs the same workflow whichever harness works the issue.

To review someone else's PR there is no issue and no stage: Shep runs `bercail review-pr <PR url-or-branch>` and reads the printed JSON for the whole stack. Shep states each PR's intent and CI. Non-thin decisions passes are queued in the review space's visible desk session (parallel headless passes without Herdr), and each PR's `run.json` says when it is `ready`. Read `prs[].thin` and `prs[].pass`: only flagged PRs wait for a decision. For each flagged PR, ask whether to review anyway (`bercail review-pr run N --stack DIR`) or ask the author. A thin PR must not hold up the rest of the stack. When all cards are ready, the desk writes the stack summary shown above the picker. See [review](review.md#someone-elses-pr-bercail-review-pr).

Bercail works without Shep, but Shep is the intended orchestrator. To do Shep's part by hand, write the issue with `bd create`, then run the same `handoff-spawn` command.

## agent status webhooks

`bercail notify run` follows the desk agents (hc terminals labelled `bercail.role=agent`) with `hc events` and posts their status changes to webhooks, one sink per bot. The desk mod keeps it running as the hidden hc terminal `bercail-notify`. It sends only these:

- `finished`: working or blocked → done or idle
- `blocked`: once each time the agent blocks

Sinks are `~/.config/bercail/notify.d/<name>.toml` (`chmod 600`; see [`notify.sink.example`](../config/agentic-dev/notify.sink.example)). They filter by space name glob, repo, and kind. The key is sent through a private header file, never through argv. A 401 or 403 is recorded and logged; `bercail notify status` and `bercail doctor` show it. Without sinks the follower idles. `bercail update` restarts a running follower so it runs the new code. `bercail doctor` flags a live follower that missed a desk finishing or blocking.

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

### OpenClaw

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
