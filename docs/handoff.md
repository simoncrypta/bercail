# handoff

Handoff is parallel, not a chat fork: one beads issue per job, run headless or in a sibling worktree with its own desk.

The job lives in a [beads](https://beads.gascity.com/) issue. [Shep](shep.md), bercail's orchestrator, creates the issue (`bd create`), then uses [`shep task dispatch`](shep.md#task-ownership-and-requested-outcomes) to resolve the original owner before a first visible handoff. Other callers can run the raw create-only `handoff-spawn` with the issue id and a stage. `--stage` and `--issue` are both required; bercail has no default stage and no fallthrough. Stages are `bstack` and `autopilot`. Both run Pi.

| Stage | Binary | Headless argv (the last word is the prompt) |
|-------|--------|-----------------------------------------------|
| `bstack` | pi | `pi -p --mode json --session-id <uuid> …` on the lead profile (asks are rejected: no commit, push, or merge) |
| `autopilot` | pi | the same argv with `BERCAIL_ROLE=autopilot` (commits and pushes a PR's fixes); with `--branch`, a desk on the PR's existing branch |

```bash
bd create "Fix the login timeout" --description "..."     # Shep writes the issue
~/.agents/skills/handoff/scripts/handoff-spawn --info      # facts as JSON, incl. beads

# headless: nothing opens in the Herdr app; result is <worktree>/.bercail/handoff-result.json
~/.agents/skills/handoff/scripts/handoff-spawn --stage bstack --issue ID --worktree PATH [--dry-run]
~/.agents/skills/handoff/scripts/handoff-spawn --stage bstack --issue ID --worktree PATH --resume SESSION
~/.agents/skills/handoff/scripts/handoff-spawn --stage autopilot --issue ID --worktree PATH

# sibling worktree with its own space; the desk runs Pi's lead
~/.agents/skills/handoff/scripts/handoff-spawn --branch NAME --stage bstack --issue ID [--dirty|--clean] [--space ID] [--base BRANCH]

# a desk on a branch origin already has (a PR's head), checked out at the fetched head
~/.agents/skills/handoff/scripts/handoff-spawn --branch NAME --existing-branch --stage bstack|autopilot --target pr:N --issue ID

# either, on another Pi model than the lead's
~/.agents/skills/handoff/scripts/handoff-spawn ... --model claude-bridge/claude-fable-5-2:high
```

Without `--base`, the desk branch is cut from the current base: handoff-spawn fetches origin's default branch first and starts from it when the local one is behind, so a desk never starts on a base that has moved. A local default branch with commits origin lacks stays the base, and so does main's HEAD for `--dirty`, since the copy is a patch on it. A failed fetch warns and uses the local branch.

`--base BRANCH` cuts the desk branch from BRANCH instead of the default branch, so a dependent issue's desk stacks on its parent's branch. The [git backend](#git-backend) registers that parent with `gh stack`, `gt track`, or `origin stack track`. It works only with `--branch`. `--branch` needs bstack's Pi lead profile, which `bercail update` writes.

**A PR's branch.** `--existing-branch` starts the desk on a branch origin already has, such as an open PR's head: it fetches `origin/NAME` and runs `wt switch NAME`, never `--create`. A local branch that is behind origin's is fast-forwarded first, so the desk never starts on a stale local ref. A local branch with commits origin lacks, or one checked out in another worktree, is refused, and nothing is created. It takes no `--base` and does no stack tracking: the branch already has its place. Stage `autopilot` with `--branch` needs `--target pr:N` and `--existing-branch`: it starts an autopilot desk, `bercail-desk-agent --role autopilot`, which runs Pi's lead with `BERCAIL_ROLE=autopilot` and bstack's autopilot prompt, so the guard lets it commit and push that PR's branch. A `bercail desk restore` brings it back as a plain lead. Without `--branch`, autopilot runs headless on `--worktree`, the PR's checkout.

**Model.** `--model PROVIDER/MODEL[:thinking]` runs one agent, desk or headless, on that Pi model. Only the lead's `--model` changes; its extensions, guard, prompts, skills, and instructions stay. A desk gets it as `bercail-desk-agent --model`, which swaps the model in the lead's argv. A `:thinking` suffix (`off`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max`) is kept as given; without one, the lead's level is added (`claude-bridge/claude-fable-5-2` becomes `claude-bridge/claude-fable-5-2:high` on a `:high` lead). Before anything starts, bercail runs `pi --offline --list-models` with the lead's extensions, since one of them can add the provider, and refuses a model Pi does not list, before any worktree, comment, or result file. A desk on another model is labelled `bercail.model=<model>`, and its spawn JSON and `handoffs.jsonl` line carry `model`, so `bercail shep brief` and `bercail shep board` show it. Its desk record keeps the swapped `--model`, so [`bercail desk restore`](config.md#desks-after-a-reboot) brings it back on the same model. To move a live desk to another model later, use [`bercail desk model`](config.md#a-desks-model). The builder, judge, council, and autopilot templates it starts keep their own models (`bercail bstack status`).

**Prompt.** One line pointing at the issue: ``Your job is beads issue <id>: <title>. Run `bd show <id>` (read its comments too) and do the work it describes.`` The title is the issue's, truncated to 60 characters. When bd has none, the sentence keeps the id only: ``Your job is beads issue <id>. Run `bd show <id>` (read its comments too) and do the work it describes.``

**Context.** Before it starts the agent, bercail adds a `bd comment` to the issue with the worktree and, headless, the result file and session id. A worktree's `.beads/redirect` points `bd` at the main checkout's database, so every comment lands in one store.

**Result.** A headless run leaves its CLI log in `<worktree>/.bercail/start.log` and `{status: ready|blocked|failed, summary, session_id}`, plus `issue` and, when known, `issue_title`, and an optional `verification` array of `{kind: test|verify-skill, command, exit_code, evidence}` from `/validate` (a malformed array is dropped; the rest of the result stands). A plan usage limit also sets `reason` to `usage-limit`. Provider failures expose a typed `provider_error.reason` (see [provider stops](bstack.md#provider-stops-and-incomplete-reviews)), with role, phase, candidate, episode/attempt identity and sanitized evidence references where available. A safety block sets `status: blocked`, `reason: provider_safety_block` and `completion: incomplete`, even when the agent wrote `ready` before its review stopped. Prior verification entries remain evidence for their original candidates, not approval of the unfinished judge. Notifications retain this reason data for the owning job. The runner does not switch or rerun; on a usage limit the loaded Pi profile pauses until the reset (the judge alone moves to its Opus stand-in), and a safety block never pauses or switches. Read that file, not terminal output. `--resume SESSION` continues the same Pi session (`pi --session-id`). The id is a uuid. `session_id` is the uuid bercail passed, or the session header's id when Pi reports a different one.

Before replacing a prior result or `start.log`, the runner moves it into `.bercail/handoff-history/`. A blocked provider result links the old result as `prior_result`; its earlier status is history, not current approval.

**Blocked, not switched.** Headless, if `pi`, `bd`, or the issue is missing, the result is `blocked` and nothing starts. Provider classification also requires the deployed helper and Node.js with built-in TypeScript support (22.19 or newer recommended). The runner checks the actual runtime before starting Pi; a missing or incompatible one blocks with a fix. With `--branch`, a missing lead profile makes `handoff-spawn` exit 1 before it makes a worktree. Bercail never falls through to another stage.

**Dry run.** `--dry-run` prints the exact argv even when `pi` is not installed, and does not check `--model`. A missing lead profile fails the dry run and writes no result.

Each `--branch` spawn appends one line to `${XDG_STATE_HOME:-~/.local/state}/bercail/handoffs.jsonl`: the spawn JSON, plus `v` (the record's version, `1`) and `at` (when, UTC). Records written before v1 have neither. Headless runs are not logged there. Follow a `--branch` desk through [agent status webhooks](shep.md#agent-status-webhooks) or with `hc wait <desk>`; `desk`, `space`, and, when known, `issue_title` (and `base` and `model`, when set) are in the spawn JSON.

Raw visible creation refuses a prior handoff for this repo/issue/target and a
desk already occupying the resolved space. `--target pr:N|task:ID` records the
logical target; deliberate parallel exploration uses a separate issue and
`--fork-reason`. `--adopt-reason TEXT`, passed only by dispatch's
[`adoptReason`](shep.md#task-ownership-and-requested-outcomes) once it has found
the original desk gone, skips step 2 and the dirty copy and stack tracking. It starts the desk,
with a new session, in the existing worktree of `--branch`, and puts TEXT in
the issue comment and the `handoffs.jsonl` line. `--reuse-worktree`, also from
dispatch only, finishes a creation that stopped before its desk: it starts the
desk in the existing clean worktree of `--branch`, with no dirty copy, and no
stack tracking on a PR's branch. `--released ID` (dispatch only,
repeatable) names an issue closed with `bd supersede ID --with` this one, so its
`handoffs.jsonl` lines no longer hold the target. A repository/common-Git lock serializes reservations. The pinned
startup session is included in the result. `ok:true` requires a started agent,
space and desk. Partial creation reports nonzero with available facts; inspect
those facts, never retry into a replacement by hand. Background wait/admin workers
cannot dispatch coding; Shep cannot bypass its original-owner dispatcher.

## What a `--branch` spawn does

For changing `handoff-spawn`; agents follow the [handoff skill](../skills/handoff/SKILL.md) and do not assemble these steps.

1. A space on the main checkout, when no space sits there: one made on that folder (on any machine), or one whose first terminal is there now. It is a plain shell named as `wts` names it (`<Branch>_<Repo>`), with no desk, and the person's shown space stays. The bercail-spaces mod nests the desk's space under it. With no window here, see [No window on this machine](#no-window-on-this-machine).
2. `wt switch --create <branch> --no-cd` (`--base` when given). worktrunk's post-start hook opens a Herdr app space on the sibling. `WT_HERDR_NO_DESK=1` keeps the hook from starting a desk, and `WT_HERDR_KEEP_FOCUS` brings the person's shown space back.
3. The dirty copy, when the main checkout is dirty or `--dirty` is given, and not with `--clean`: `git -C main diff HEAD --binary | git -C sibling apply` (no `--index`), then `cp -a` of each `git ls-files --others --exclude-standard` path. The sibling's index stays empty.
4. The branch is registered with the [git backend](#git-backend): `gt track`, or for a `--base` dependent `gh stack init`/`add` or `origin stack track --onto`.
5. The `bd comment` on the issue: the worktree, stage and do not commit, the backend and its stack commands.
6. The desk: `wt_herdr_handoff_agent` runs `hc run --bg --keep --outlive-parent` of `bercail-desk-agent --prompt <the one line>` under the space's first terminal, labelled `bercail.role=agent`, `bercail.space`, and the issue when known. It refuses a live desk in that space. A failed start keeps the worktree and reports partial facts.
7. The spawn JSON on stdout, appended to `handoffs.jsonl`.

Within the repository reservation, steps 1, 2 and 6 hold a lock per checkout (`flock` on `bercail-space-<hash>.lock` in `$XDG_RUNTIME_DIR`), so two spawns or hooks at once on one checkout make one space and one desk.

### No window on this machine

When `herdr-app status` fails here but hc answers (a laptop's window shows this machine's spaces, or no window is open at all), `--branch` and worktrunk's hooks still make spaces, through hc alone. A space is then a kept Shell, `hc run --bg --keep --no-parent` in the checkout, labelled `herdr.space` and `herdr.tab` with new ids and `bercail.space_name=<Branch>_<Repo>`. The desk is started under it as above. Any Herdr window connected to this machine, now or later, adopts the Shell into a space without showing it. The bercail-spaces mod there names the space from `bercail.space_name` and its first tab `Shell`, until someone renames it.

Without a window here, a checkout's space is found through hc: the Shell bercail made there, else a desk there. A main checkout already has a space when a terminal of any space (they all carry `herdr.space`) or a desk is in it. `wt remove` does not close a space with no window here; close it from the window. With neither a window nor hc, the hook skips the space and `--branch` exits 1 before making a worktree.

## Git backend

`handoff-spawn --info` reports `"git": "gh"`, `"gt"`, `"origin"`, or `"entire"`,
and `"entire": true` where Entire captures the agents' sessions (see
[entire.md](entire.md)).
Use that backend throughout the job. The result of a `--branch` spawn carries
the same `git`.

Detection order is: a per-repo `[git]` override, real Graphite tracking, an
origin hosted on Entire (`entire://<host>/et/<project>/<repo>`), an Origin
repo, then `gh`. A GitHub repo mirrored on Entire (`entire://<host>/gh/...`)
stays `gh`: GitHub holds its PRs. Keys are main-checkout paths; linked worktrees share
the choice:

```toml
[git]
"~/Work/bercail" = "gh"
"~/Work/stacked-repo" = "gt"
"~/Work/origin-repo" = "origin"
```

Detection never runs `gt`.

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
| `entire` | No stacks. The child's trail names its parent branch (`entire trail create --base <parent>`); once the parent lands, `entire trail retarget --base <trunk>` moves it. |

Never hand-make a dependent PR that merely targets another PR's branch, and
never run `gt` in a `gh` repo. Handoff stages work without committing or
publishing; these commands do not authorize a push. Autopilot may commit and
push to its PR branch, never merge.

Check native publication feasibility before edits. A scoped commit/fast-forward
grant is not a native stack rewrite exception: unknown effects or extra members
stop the job, with stage-only work only after an explicit fallback pick. Do not
substitute plain git for required native operations. Grants belong to the actual
visible desk/session named by the picker, not a job label or parent terminal.
Headless handoffs do not inherit them, and `--resume` grants no authority.
See [scoped grants](shep.md#scoped-commit-and-fast-forward-grants).

### Graphite

With `--branch`, a repo that uses Graphite gets `gt track` on the new branch and a line in the agent's handoff comment telling it to use `gt`.

Any `gt` command initializes the repo it runs in, so a stray one must not turn this on. A repo counts as Graphite when `gt` tracks a branch other than trunk. A repo that only has Graphite's config file doesn't count. The spawn prints a note because a real Graphite repo looks the same once its last stack is merged. The check reads `.graphite_metadata.db` with `sqlite3`. Without `sqlite3`, or if the file can't be read, the spawn skips Graphite and warns. Install `sqlite3` or use the override below.

To decide for a repo yourself, add its main checkout to `~/.config/bercail/config.toml`. Linked worktrees follow it.

```toml
[git]
"~/Work/leftlane_app" = "gt"         # a Graphite repo with no stack right now
"~/Work/bercail" = "gh"              # gt once ran here, but you don't use it
```

Tracking can't stop a spawn. Each `gt` call is killed after 30 seconds (`HANDOFF_GT_TIMEOUT`). If `--base` is untracked, bercail tracks it on trunk and retries, then falls back to trunk. On any other failure, such as a locked Graphite database, it changes nothing, so your stack stays as it was. If tracking still fails, or `gt` hangs, the spawn prints a warning with the `gt track` command to run, and the desk still starts.
