# handoff

Handoff is parallel, not a chat fork: one beads issue per job, run headless or in a sibling worktree with its own desk.

The job lives in a [beads](https://beads.gascity.com/) issue. [Shep](shep.md), bercail's orchestrator, creates the issue (`bd create`), then runs `handoff-spawn` with the issue id and a stage. `--stage` and `--issue` are both required; bercail has no default stage and no fallthrough. Stages are `bstack` and `autopilot`. Both run Pi.

| Stage | Binary | Headless argv (the last word is the prompt) |
|-------|--------|-----------------------------------------------|
| `bstack` | pi | `pi -p --mode json --session-id <uuid> …` on the lead profile (asks are rejected: no commit, push, or merge) |
| `autopilot` | pi | the same argv with `BERCAIL_ROLE=autopilot` (commits and pushes a PR's fixes; headless only) |

```bash
bd create "Fix the login timeout" --description "..."     # Shep writes the issue
~/.agents/skills/handoff/scripts/handoff-spawn --info      # facts as JSON, incl. beads

# headless: nothing opens in the Herdr app; result is <worktree>/.bercail/handoff-result.json
~/.agents/skills/handoff/scripts/handoff-spawn --stage bstack --issue ID --worktree PATH [--dry-run]
~/.agents/skills/handoff/scripts/handoff-spawn --stage bstack --issue ID --worktree PATH --resume SESSION
~/.agents/skills/handoff/scripts/handoff-spawn --stage autopilot --issue ID --worktree PATH

# sibling worktree with its own space; the desk runs Pi's lead
~/.agents/skills/handoff/scripts/handoff-spawn --branch NAME --stage bstack --issue ID [--dirty|--clean] [--space ID] [--base BRANCH]

# either, on another Pi model than the lead's
~/.agents/skills/handoff/scripts/handoff-spawn ... --model claude-bridge/claude-fable-5-2:high
```

`--base BRANCH` cuts the desk branch from BRANCH instead of the default branch, so a dependent issue's desk stacks on its parent's branch. The [git backend](#git-backend) registers that parent with `gh stack`, `gt track`, or `origin stack track`. It works only with `--branch`, and stage `autopilot` can't take `--branch`: give it `--worktree` on the PR's checkout. `--branch` needs bstack on (`[bstack] enabled = true`) and a Pi lead profile.

**Model.** `--model PROVIDER/MODEL[:thinking]` runs one agent, desk or headless, on that Pi model. Only the lead's `--model` changes; its extensions, guard, prompts, skills, and instructions stay. A desk gets it as `bercail-desk-agent --model`, which swaps the model in the lead's argv. A `:thinking` suffix (`off`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max`) is kept as given; without one, the lead's level is added (`claude-bridge/claude-fable-5-2` becomes `claude-bridge/claude-fable-5-2:high` on a `:high` lead). Before anything starts, bercail runs `pi --offline --list-models` with the lead's extensions, since one of them can add the provider, and refuses a model Pi does not list, before any worktree, comment, or result file. A desk on another model is labelled `bercail.model=<model>`, and its spawn JSON and `handoffs.jsonl` line carry `model`, so `bercail shep brief` and `bercail shep board` show it. Its desk record keeps the swapped `--model`, so [`bercail desk restore`](config.md#desks-after-a-reboot) brings it back on the same model. The builder, judge, council, and autopilot templates it starts keep their own models (`bercail bstack status`).

**Prompt.** One line pointing at the issue: ``Your job is beads issue <id>: <title>. Run `bd show <id>` (read its comments too) and do the work it describes.`` The title is the issue's, truncated to 60 characters. When bd has none, the sentence keeps the id only: ``Your job is beads issue <id>. Run `bd show <id>` (read its comments too) and do the work it describes.``

**Context.** Before it starts the agent, bercail adds a `bd comment` to the issue with the worktree and, headless, the result file and session id. A worktree's `.beads/redirect` points `bd` at the main checkout's database, so every comment lands in one store.

**Result.** A headless run leaves its CLI log in `<worktree>/.bercail/start.log` and `{status: ready|blocked|failed, summary, session_id}`, plus `issue` and, when known, `issue_title`, and an optional `verification` array of `{kind: test|verify-skill, command, exit_code, evidence}` from `/ready` (a malformed array is dropped; the rest of the result stands). A plan usage limit also sets `reason` to `usage-limit`, so Shep can propose another plan. Bercail does not switch or rerun. Read that file, not terminal output. `--resume SESSION` continues the same Pi session (`pi --session-id`). The id is a uuid. `session_id` is the uuid bercail passed, or the session header's id when Pi reports a different one.

**Blocked, not switched.** Headless, if `pi`, `bd`, or the issue is missing, the result is `blocked` and nothing starts. With `--branch`, bstack off or a missing lead profile makes `handoff-spawn` exit 1 before it makes a worktree. Bercail never falls through to another stage.

**Dry run.** `--dry-run` prints the exact argv even when `pi` is not installed, and does not check `--model`. A missing lead profile fails the dry run and writes no result.

Each `--branch` spawn is logged in `${XDG_STATE_HOME:-~/.local/state}/agentic-dev/handoffs.jsonl`; headless runs are not logged there. Follow a `--branch` desk through [agent status webhooks](shep.md#agent-status-webhooks) or with `hc wait <desk>`; `desk`, `space`, and, when known, `issue_title` (and `base` and `model`, when set) are in the spawn JSON.

## Git backend

`handoff-spawn --info` reports `"git": "gh"`, `"gt"`, or `"origin"`.
Use that backend throughout the job. `graphite` remains for one release,
derived as `git == "gt"`, so existing callers keep working.

Detection order is: a per-repo `[git]` override, a legacy `[graphite]` override,
real Graphite tracking, an Origin repo, then `gh`. Keys are main-checkout
paths; linked worktrees share the choice. New overrides use:

```toml
[git]
"~/Work/bercail" = "gh"
"~/Work/stacked-repo" = "gt"
"~/Work/origin-repo" = "origin"
```

`[git]` takes precedence over `[graphite]`, whose `true`/`false` still maps to
`gt`/`gh`. Detection never runs `gt`.

Origin detection first checks the remote's exact host and repo path
(`origin.cursor.com` or `origin-<environment>.cursor.com`). Only those repos
get a bounded `origin repo view --json mirrorStatus` lookup: `no-mirror` and
`outbound` select Origin; other reported statuses select GitHub. A missing CLI
or failed lookup warns and falls back to `gh`; set `[git]` to settle an unknown
result before publishing. Ordinary GitHub repos make no Origin API call.

| Backend | Dependent branches and publishing |
|---------|-----------------------------------|
| `gh` | `gh stack init` adopts existing parent/child branches; `gh stack add` extends a stack. Publish with `gh stack submit`; update with `gh stack sync`. |
| `gt` | `gt create` or `gt track --parent` records branches; `gt submit` publishes and `gt get` fetches stack updates. |
| `origin` | `origin stack track --onto` records local parents. Publish child PRs with `origin pr create --stack-on <parent-PR> --status open`; update with `origin stack get`, `origin stack restack`, and `origin stack push --all`. |

Never hand-make a dependent PR that merely targets another PR's branch, and
never run `gt` in a `gh` repo. Handoff stages work without committing or
publishing; these commands do not authorize a push. Autopilot may commit and
push to its PR branch, never merge.

### Graphite

With `--branch`, a repo that uses Graphite gets `gt track` on the new branch and a line in the agent's handoff comment telling it to use `gt`.

Any `gt` command initializes the repo it runs in, so a stray one must not turn this on. A repo counts as Graphite when `gt` tracks a branch other than trunk. A repo that only has Graphite's config file doesn't count. The spawn prints a note because a real Graphite repo looks the same once its last stack is merged. The check reads `.graphite_metadata.db` with `sqlite3`. Without `sqlite3`, or if the file can't be read, the spawn skips Graphite and warns. Install `sqlite3` or use the override below.

To decide for a repo yourself, add its main checkout to `~/.config/bercail/config.toml`. Linked worktrees follow it.

```toml
[graphite]
"~/Work/leftlane_app" = true         # a Graphite repo with no stack right now
"~/Work/bercail" = false             # gt once ran here, but you don't use it
```

Tracking can't stop a spawn. Each `gt` call is killed after 30 seconds (`HANDOFF_GT_TIMEOUT`). If `--base` is untracked, bercail tracks it on trunk and retries, then falls back to trunk. On any other failure, such as a locked Graphite database, it changes nothing, so your stack stays as it was. If tracking still fails, or `gt` hangs, the spawn prints a warning with the `gt track` command to run, and the desk still starts.
