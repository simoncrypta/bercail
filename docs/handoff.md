# handoff

Handoff is parallel, not a chat fork: one beads issue per job, run headless or in a sibling worktree with its own desk.

The job lives in a [beads](https://beads.gascity.com/) issue. [Shep](shep.md), the Grok bot, creates the issue (`bd create`), then runs `handoff-spawn` with the issue id and a stage. `--stage` and `--issue` are both required; bercail has no default harness and no fallthrough.

| Stage | Binary | Headless argv (the last word is the prompt) |
|-------|--------|-----------------------------------------------|
| `start` | claude | `claude --print --model <opus> --output-format json --permission-mode acceptEdits …` (`<opus>` is the Opus 5.5 id from Claude's local model catalog, else the `opus` alias) |
| `codex` | codex | `codex exec --json --sandbox workspace-write …` |
| `cursor` | cursor-agent | `cursor-agent --print --output-format json --trust --force …` |
| `bstack` | opencode | `opencode run --format json --agent bstack [--model <lead>] …` (asks are rejected: no commit, push, or merge) |
| `autopilot` | opencode | `opencode run --format json --agent bstack-autopilot [--model <lead>] …` (commits and pushes a PR's fixes; headless only) |

```bash
bd create "Fix the login timeout" --description "..."     # Shep (the Grok bot) writes the issue
~/.agents/skills/handoff/scripts/handoff-spawn --info      # facts as JSON, incl. beads

# headless: nothing opens in the Herdr app; result is <worktree>/.bercail/handoff-result.json
~/.agents/skills/handoff/scripts/handoff-spawn --stage codex --issue ID --worktree PATH [--dry-run]
~/.agents/skills/handoff/scripts/handoff-spawn --stage start --issue ID --worktree PATH --resume SESSION

# sibling worktree with its own space; the desk runs the stage's binary
~/.agents/skills/handoff/scripts/handoff-spawn --branch NAME --stage cursor --issue ID [--dirty|--clean] [--space ID] [--base BRANCH]
```

`--base BRANCH` cuts the desk branch from BRANCH instead of the default branch, so a dependent issue's desk stacks on its parent's branch (Graphite, when the repo uses it, tracks BRANCH as the parent). It works only with `--branch`, and stage `autopilot` can't take `--branch`: give it `--worktree` on the PR's checkout.

**Prompt.** One line pointing at the issue, the same for every harness: ``Your job is beads issue <id>. Run `bd show <id>` (read its comments too) and do the work it describes.``

**Context.** Before it starts the agent, bercail adds a `bd comment` to the issue with the worktree and, headless, the result file and session id. A worktree's `.beads/redirect` points `bd` at the main checkout's database, so every comment lands in one store.

**Result.** A headless run leaves its CLI log in `<worktree>/.bercail/start.log` and `{status: ready|blocked|failed, summary, session_id}`. A plan usage limit also sets `reason` to `usage-limit`, so Shep can propose another plan. Bercail does not switch or rerun. Read that file, not terminal output. `--resume SESSION` continues the same session (`claude --resume`, `codex exec resume`, `cursor-agent --resume`, `opencode run --session`).

**Blocked, not switched.** Headless, if the stage's binary, `bd`, or the issue is missing, the result is `blocked` and nothing starts. With `--branch`, `handoff-spawn` exits 1 before it makes a worktree. Bercail never falls through to another harness. `--binary claude|codex|cursor-agent|opencode` runs a headless stage on another CLI only when you ask (with `opencode`, `start` stays on Claude and `codex` on GPT, through your opencode plans; stage `autopilot` takes only `opencode`).

**Dry run.** `--dry-run` prints the exact argv for any stage, even when that binary is not installed.

**Which harnesses?** `bercail harness` reports which of claude, codex, cursor-agent, and opencode are on PATH, with a local model hint. It does not choose.

Each `--branch` spawn is logged in `${XDG_STATE_HOME:-~/.local/state}/agentic-dev/handoffs.jsonl`; headless runs are not logged there. Follow a `--branch` desk through [agent status webhooks](shep.md#agent-status-webhooks) or with `hc wait <desk>`; `desk` and `space` (and `base`, when set) are in the spawn JSON.
