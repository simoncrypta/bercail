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
 "desk":{"branch":"feat/render","issue":"lef2745-2vs","stage":"start","harness":"claude",
         "result":{"status":"ready","summary":"...","session_id":"..."}}}
```

`agent.address` is the hc terminal (`hc get`/`hc read` it). `desk.issue`, `stage`, and `harness` come from the matching `handoffs.jsonl` record (`harness` falls back to `agent.app`). `desk.result` is `status`, `summary` (its first 500 characters), and `session_id` from the checkout's `.bercail/handoff-result.json` when one exists (usually `null`: headless runs have no desk terminal, so they send nothing).
