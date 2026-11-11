# Handoff spawn (script internals)

The parent recipe is `scripts/handoff-spawn`. This file documents what that
script does so it can be changed without re-teaching the model. Parents should
run `--info` then spawn — not assemble these steps.

## Sequence

1. `--info` prints JSON facts (`herdr`, `herdr_env`, `main_checkout`, `dirty`,
   `git` (`gh` | `gt` | `origin`), `graphite` (legacy: `git == "gt"`),
   `default_copy`, `space`, …). `--branch` itself requires the
   Herdr app to answer (`herdr-app status`) and a **main** git checkout.
2. `wt switch --create <branch> --no-cd`. Worktrunk `post-start` opens a Herdr
   app space on the sibling (no desk agent yet: handoff-spawn sets
   `WT_HERDR_NO_DESK=1` for the hook). `WT_HERDR_KEEP_FOCUS` is set
   first, so the user's shown space comes back after `space.new` selects the
   new one.
3. If `--dirty` or `default_copy` is dirty (and not `--clean`): copy
   `git diff HEAD` plus untracked files into the sibling as a **working tree**.
   Never `git add`.
4. Register the sibling with the selected backend: `gt track` for Graphite;
   for `--base` dependents, `gh stack init/add` or `origin stack track --onto`.
   Keep the parent relation in that backend; publishing uses its stack commands.
5. Add the intro (worktree; stage, don't commit; Review opens on agent done;
   selected git backend and stack commands) to the beads issue as a `bd comment`. The prompt is one line
   pointing at the issue (`<id>: <title>`, or the id alone when bd has no title). No prompt file and no
   per-stage mode.
6. `WT_HERDR_AGENT_PROMPT` is that one-line prompt. `WT_HERDR_ISSUE` and
   `WT_HERDR_ISSUE_TITLE` name the issue. `wt_herdr_handoff_agent` starts the
   space's desk: `hc run --bg --keep --outlive-parent --parent <space's first terminal>` of
   `bercail-desk-agent --prompt <prompt>` (Pi's lead) with labels
   `bercail.role=agent`, `bercail.space=<space id>`, and, when set, `bercail.issue`
   and `bercail.issue_title`, replacing a live desk
   in that space. A failed start does **not** discard the worktree.
7. Print JSON `{ok,label,path,branch,issue,issue_title,agent_started,dirty_copied,graphite,stage,harness,space,desk}`
   (`issue_title` omitted when unknown) and append `~/.local/state/agentic-dev/handoffs.jsonl` whenever the sibling
   exists.

Callers in no hc terminal (`HC_TERMINAL_ID` unset) run the **resolved script
directly** with `--branch` and `--issue` (working directory = `--info` `cwd`);
`--space` (or `--workspace`) picks the space to keep shown, else the one shown now.
Auto-review rejects `python -c`, wrapper `.sh` files, and any argv after `--`.
The ask is in the beads issue, so nothing but the id reaches argv.

## Stage router

`scripts/handoff-stages.sh` is the table: name, binary, mode (`headless`),
model. `handoff-spawn --stage` reads it. The only rows are `bstack` and
`autopilot`. Both are headless Pi.

`bstack` and `autopilot` run `pi -p --mode json --session-id <uuid>` on the
lead profile. Pi resume reuses that uuid; `--resume` refuses anything that is
not a uuid. Pi gets no `--add-dir`. With `--branch`, the desk runs the lead from
lead.json, so it needs bstack on. Autopilot sets
`BERCAIL_ROLE=autopilot` and cannot take `--branch`.

A missing `pi`, bd, or issue writes status `blocked` and exits nonzero. It does
not fall through to another stage.

Every headless stage gets that one-line prompt and writes
`<worktree>/.bercail/handoff-result.json`. Before the run, bercail checks bd
and the issue (`bd show <id>`) and adds a `bd comment` with the worktree,
result path, and session id. bercail fills `session_id` in the result after the run.
Re-handoff is `--resume <uuid>`. That id is the uuid bercail passed, or the
session header's id when Pi reports a different one.

Intake is the beads issue Shep writes (a Linear issue, a direct ask, or a
note all become one issue). It is not a row and not a file bercail writes.

Arena, implement, and the Composer review pane are not rows. Add a row; a
stage needs no prompt file. Do not special-case the binary in `handoff-spawn`.

## Dirty copy

Default: dirty main → copy; clean main → HEAD only.

`--dirty` / `--clean` override. Copy is **after** `wt switch --create` (the
sibling exists) and **before** the desk starts.

Tracked: `git -C main diff HEAD --binary | git -C sibling apply` (no `--index`).
Untracked: `cp -a` each `git ls-files --others --exclude-standard` path.
Result: sibling `git diff --cached` empty; dirty files are unstaged/untracked.

## Do not

The script is the only spawn path. Callers must not `hc send` or type into a
desk, start a desk with `hc run` themselves, or switch the user to the child's
space.

## Git backend

`--info` reports one `git` backend for the repo. Linked worktrees use their
main checkout's choice. Detection never invokes `gt`:

1. A `[git]` entry in bercail's config.toml, keyed by main-checkout path,
   chooses `"gh"`, `"gt"`, or `"origin"`.
2. A legacy `[graphite]` entry maps `true` to `gt` and `false` to `gh`.
   `[git]` wins when both are set.
3. Real Graphite tracking (below) selects `gt`.
4. A remote on an exact `origin.cursor.com` or `origin-<environment>.cursor.com`
   host and `/org/repo` or `/git/org/repo` path is an Origin candidate. A bounded
   `origin repo view --json mirrorStatus` selects `origin` only for `no-mirror`
   or `outbound`. Other reported statuses select `gh`. A missing CLI or failed
   lookup warns and falls back to `gh`; use `[git]` to settle an unknown result
   before publishing. GitHub remotes never make this probe.

For example:

```toml
[git]
"~/Work/github-repo" = "gh"
"~/Work/graphite-repo" = "gt"
"~/Work/origin-repo" = "origin"
```

`graphite` stays in `--info` for one release, derived from `git == "gt"`.
Consumers should read `git`, not re-detect. See
[git-workflow.md](git-workflow.md) for publishing and updating each stack.

### Graphite tracking

Any `gt` command auto-initializes the repo it runs in, so the config file in the
shared git dir (`.graphite_repo_config`) proves nothing. After the config
overrides above, tracking evidence decides:

1. No Graphite config file: not Graphite.
2. gt tracks a branch other than trunk: a `refs/branch-metadata/*` ref (older
   gt) or a row with a parent in `.graphite_metadata.db` (current gt, read with
   `sqlite3 -readonly`). Auto-init only writes rows with no parent.
3. A store that can't be read (no sqlite3, busy, unknown schema) skips Graphite,
   with a warning that names the override. Install sqlite3 or set the override.

A config with nothing tracked is off, with a note that names the override: a
real repo looks the same as a stray one once its last stack is merged. An entry
in `[git]` (or legacy `[graphite]`) silences both.

`handoff_track_graphite` runs every `gt` call through `handoff_gt`: its own
process group, no stdin, stdout sent to stderr (stdout is the spawn's JSON), and
killed with its children after `HANDOFF_GT_TIMEOUT` seconds (default 30). It tries the parent
(`--base`, else trunk). Only when `gt branch info` says the parent is untracked
or unknown does it track that parent on trunk and retry, then fall back to trunk.
On any other failure (a tracked parent, a locked store) it changes nothing else:
re-tracking would rewrite a real stack. It never passes `--force`. A failure or a hung gt warns and the desk still
starts; after a hang it runs no more gt.
