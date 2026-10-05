# Handoff spawn (script internals)

The parent recipe is `scripts/handoff-spawn`. This file documents what that
script does so it can be changed without re-teaching the model. Parents should
run `--info` then spawn — not assemble these steps.

## Sequence

1. `--info` prints JSON facts (`herdr`, `main_checkout`, `dirty`, `graphite`,
   `default_copy`, …). Spawn itself still requires `HERDR_ENV=1` and a **main**
   git checkout.
2. `wt switch --create <branch> --no-cd`. Worktrunk `post-start` opens layout
   only (agent pane stays a shell). `WT_HERDR_KEEP_FOCUS` is set before switch
   so create restores the parent workspace.
3. If `--dirty` or `default_copy` is dirty (and not `--clean`): copy
   `git diff HEAD` plus untracked files into the sibling as a **working tree**.
   Never `git add`.
4. If Graphite config exists (`handoff_graphite_config`), `gt track`.
5. Add the intro (worktree; tuicr opens on agent `done`; gt on Graphite) to the
   beads issue as a `bd comment`. The prompt is the issue id, the same for
   every binary. No prompt file and no per-harness mode.
6. `WT_HERDR_AGENT_CMD` is the stage table's binary (not a hardcoded
   cursor-agent) and `WT_HERDR_AGENT_PROMPT` is that one-line prompt.
   `wt_herdr_handoff_agent` forwards both. lifecycle.sh already execs
   `WT_HERDR_AGENT_CMD`. Layout create is not called again. start-agent waits
   up to 30s for Herdr to tag the Agent pane (or a non-shell FG process). A
   timeout does **not** discard the worktree.
7. Print JSON `{label,path,branch,issue,agent_started,dirty_copied,graphite}`
   and append `~/.local/state/agentic-dev/handoffs.jsonl` whenever the sibling
   exists. `agent_started` is false on a wait timeout.

Parents outside a Herdr pane (`HERDR_ENV` unset) spawn by running the
**resolved script directly** with `--workspace`, `--branch`, and `--issue`
(working directory = `--info` `cwd`). Auto-review rejects `python -c`, wrapper
`.sh` files, `herdr pane run … spawn -- <prompt>`, and any argv after `--`. The
ask is in the beads issue, so nothing but the id reaches argv.

`start-agent` launches one quoted `bash -li -c 'exec "$WT_HERDR_AGENT_CMD" -- <prompt>'`
line. The `--branch` pane binary is the stage's binary. `herdr pane run` submits on
newline, so the plugin refuses a multiline `WT_HERDR_AGENT_PROMPT`.

## Stage router

`scripts/handoff-stages.sh` is the table: name, binary, `headless` or `pane`,
model. `handoff-spawn --stage` reads it.

- `cursor`: headless. One `cursor-agent --print --output-format json` in the
  worktree. Resume is `--resume <session_id>` (the flag `cursor-agent --help`
  lists). `--model` is passed only when the table model is set (not `-`).
  `--trust --force` are the non-interactive write flags from that help.
  `--branch` on this stage still opens the sticky pane (not this argv).
- `start`: headless. One `claude --print` in the worktree. No Herdr pane.
  Model spec `opus-5.5` resolves from the claude catalog (full id, never the
  `*-max` slug).
- `codex`: headless. One `codex exec --json` in the worktree. Resume is
  `codex exec --json --sandbox workspace-write resume [-m MODEL] <session_id>`.
  `-m` is passed only when the table model is set (not `-` and not the claude
  `opus-5.5` spec). `--sandbox workspace-write` is required because `codex
  exec` defaults to read-only; `codex exec resume` has no `--sandbox`, so it
  stays before the subcommand. `codex exec` has no `--ask-for-approval`.
`--binary claude|codex|cursor-agent` overrides the table binary on a headless
stage, so `--stage start --binary cursor-agent` picks cursor-agent without
renaming the job. Bercail never picks or skips a harness on its own.
`bercail harness` reports which of claude, codex, and cursor-agent are on PATH,
with a local model hint. It does not choose one.
A missing requested harness writes status `blocked` and exits nonzero. It does
not fall through to another binary.

All three headless stages get the issue id as their whole prompt and write
`<worktree>/.bercail/handoff-result.json`. Before the run, bercail checks bd
and the issue (`bd show <id>`) and adds a `bd comment` with the worktree,
result path, and session id. claude gets `--tools Read,Edit,Write,Bash
--allowedTools "Bash(bd *)"`. When bd's `.beads` is outside the worktree, each
harness gets `--add-dir` for it (codex: before `resume`, which has no
`--add-dir`). bercail fills `session_id` in the result after the run.
Re-handoff is `--resume <session_id>`. For Codex that id is the JSONL
`thread.started` thread id. For cursor-agent it is the print JSON `session_id`.

Intake is the beads issue Shep writes (a Linear issue, a direct ask, or a
note all become one issue). It is not a row and not a file bercail writes.

Arena, implement, and the Composer review pane are not rows. Add a row; a
stage needs no prompt file. Do not special-case the binary in `handoff-spawn`.

## Dirty copy

Default: dirty main → copy; clean main → HEAD only.

`--dirty` / `--clean` override. Copy is **after** `wt switch --create` (the
sibling exists) and **before** start-agent.

Tracked: `git -C main diff HEAD --binary | git -C sibling apply` (no `--index`).
Untracked: `cp -a` each `git ls-files --others --exclude-standard` path.
Result: sibling `git diff --cached` empty; dirty files are unstaged/untracked.

## Do not

The script is the only spawn path. Callers must not `herdr pane run`,
`herdr agent prompt`, paste, send-keys, `plugin action invoke` for create, or
`workspace focus` the child.
