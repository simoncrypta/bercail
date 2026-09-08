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
5. Wrap intro (worktree only; hunk opens on agent `done`) around the original
   prompt, prefix `/poteto-mode`, write a prompt file.
6. `WT_HERDR_AGENT_CMD=cursor-agent WT_HERDR_AGENT_PROMPT_FILE=… wt_herdr_start_agent`.
   Layout create is not called again. start-agent waits up to 30s for Herdr to
   tag the Agent pane (or a non-shell FG process). A timeout does **not**
   discard the worktree.
7. Print JSON `{label,path,branch,task,agent_started,dirty_copied,graphite}`
   and append `~/.local/state/agentic-dev/handoffs.jsonl` whenever the sibling
   exists. `agent_started` is false on a wait timeout.

Parents outside a Herdr pane (`HERDR_ENV` unset) spawn by running the
**resolved script directly** with `--workspace`, `--branch`, and
`--take-pending` (working directory = `--info` `cwd`). Auto-review rejects
`python -c`, wrapper `.sh` files, `herdr pane run … spawn -- <prompt>`, and
any argv after `--`. Write `pending_prompt` as plain text, then take-pending.

`start-agent` launches one quoted `bash -li -c '… cat file … exec cursor-agent -- "$p"'`
line. `herdr pane run a b c` types unquoted words, so a multiline prompt cannot
be argv.

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
