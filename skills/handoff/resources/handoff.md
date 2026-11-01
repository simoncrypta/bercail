# Handoff spawn (script internals)

The parent recipe is `scripts/handoff-spawn`. This file documents what that
script does so it can be changed without re-teaching the model. Parents should
run `--info` then spawn — not assemble these steps.

## Sequence

1. `--info` prints JSON facts (`herdr`, `herdr_env`, `main_checkout`, `dirty`,
   `graphite`, `default_copy`, `space`, …). `--branch` itself requires the
   Herdr app to answer (`herdr-app status`) and a **main** git checkout.
2. `wt switch --create <branch> --no-cd`. Worktrunk `post-start` opens a Herdr
   app space on the sibling (no desk agent yet: handoff-spawn sets
   `WT_HERDR_NO_DESK=1` for the hook). `WT_HERDR_KEEP_FOCUS` is set
   first, so the user's shown space comes back after `space.new` selects the
   new one.
3. If `--dirty` or `default_copy` is dirty (and not `--clean`): copy
   `git diff HEAD` plus untracked files into the sibling as a **working tree**.
   Never `git add`.
4. If Graphite config exists (`handoff_graphite_config`, in the shared git
   dir), `gt track` a branch that has no parent yet.
5. Add the intro (worktree; stage, don't commit; Review opens on agent done;
   gt on Graphite) to the beads issue as a `bd comment`. The prompt is one line
   pointing at the issue, the same for every binary. No prompt file and no
   per-harness mode.
6. `WT_HERDR_AGENT_CMD` is the stage table's binary and `WT_HERDR_AGENT_PROMPT`
   that one-line prompt. `wt_herdr_handoff_agent` starts the space's desk:
   `hc run --bg --keep --no-parent` of `bercail-desk-agent --prompt <prompt> <binary>`
   with labels `herdr.space`, `bercail.role=agent` and `bercail.space=<space id>`
   (a tab of its own), replacing a live desk in that space. A failed start does **not** discard the worktree.
7. Print JSON `{ok,label,path,branch,issue,agent_started,dirty_copied,graphite,stage,harness,space,desk}`
   and append `~/.local/state/agentic-dev/handoffs.jsonl` whenever the sibling
   exists.

Callers in no hc terminal (`HC_TERMINAL_ID` unset) run the **resolved script
directly** with `--branch` and `--issue` (working directory = `--info` `cwd`);
`--space` (or `--workspace`) picks the space to keep shown, else the one shown now.
Auto-review rejects `python -c`, wrapper `.sh` files, and any argv after `--`.
The ask is in the beads issue, so nothing but the id reaches argv.

## Stage router

`scripts/handoff-stages.sh` is the table: name, binary, mode (`headless`),
model. `handoff-spawn --stage` reads it.

- `cursor`: headless. One `cursor-agent --print --output-format json` in the
  worktree. Resume is `--resume <session_id>` (the flag `cursor-agent --help`
  lists). `--model` is passed only when the table model is set (not `-`).
  `--trust --force` are the non-interactive write flags from that help.
  `--branch` on this stage still starts a desk agent (not this argv).
- `start`: headless. One `claude --print` in the worktree. Nothing opens in the Herdr app.
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

All three headless stages get that one-line prompt and write
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
sibling exists) and **before** the desk starts.

Tracked: `git -C main diff HEAD --binary | git -C sibling apply` (no `--index`).
Untracked: `cp -a` each `git ls-files --others --exclude-standard` path.
Result: sibling `git diff --cached` empty; dirty files are unstaged/untracked.

## Do not

The script is the only spawn path. Callers must not `hc send` or type into a
desk, start a desk with `hc run` themselves, or switch the user to the child's
space.
