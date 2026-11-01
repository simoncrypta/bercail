# Make it yours

bstack is opinions in files. Change the ones that don't fit.

## Models and roles

Everything lives under `[bstack]` in `~/.config/bercail/config.toml`:

```toml
[bstack]
enabled = true
# Empty: auto, the newest model of that plan. An opencode id pins one.
claude = ""
gpt = ""
grok = "xai/grok-4.7"
# Reasoning effort of auto models: low, medium, high (default), xhigh, max, none.
effort = "xhigh"
# A plan (claude, gpt, grok) or a full model id.
lead = "claude"
build = "gpt"
judge = "claude"
```

Then `bercail bstack setup` or `bercail update`. `bercail bstack status` shows
each model as `auto` or `pinned`. A pin stays until you clear it, gets a council
seat even when its plan isn't connected, and skips every new release; auto
picks again on every update.

Roles fall back to the next connected plan, so you can set them once and
connect plans later ([the order](./02-the-bstack-agent.md#the-roles)). Higher
effort reasons longer and spends more of each plan; a model without the level
you ask for gets the next one down.

## What bstack turns on in opencode

- **`bstack` as the default agent**, on the lead's model, with bercail's
  instructions.
- **Asks before** `git commit`, `git push`, and `gh pr merge`, so agents stage
  and stop.
- **Policies** that block force-push and `--no-verify` for every agent, headless
  runs included. A permission or an "Allow always" can't lift them.
- **Web search** on `random`: Exa and TinyFish work without a key, and a rate
  limit moves the search to another provider. Add a key with `/connect` for
  higher limits.
- **The todo tool**, which the playbooks use for their steps.
- **Background compaction**, so long runs don't stop while the summary is written.

Formatters stay off: a formatter that runs on every edit reformats whole files in
repos that don't use it. Turn it on per project with `"formatter": true` in that
repo's `opencode.jsonc`.

## Your own files

`opencode.jsonc`, `agents/bstack*.md`, and bstack's eight `commands/*.md`
under `~/.config/opencode` each carry a `managed by bercail (bstack)` line.
Delete that line and bercail never touches the file again; `bercail doctor`
lists it as yours. `bstack/instructions.md` has no line: it belongs to bercail,
and every update rewrites it.

Your own opencode settings go in `~/.config/opencode/opencode.json`. opencode
loads it under bstack's `.jsonc`, so yours survive every update.

## Skills

bstack's skills are in `~/.agents/skills` ([the list](../cli.md#skills)).
opencode and cursor-agent read them directly. When Claude Code or Codex is your
`[agent] command`, bercail links them into `~/.claude/skills` or
`~/.codex/skills`. Outside opencode there are no `bstack-*` subagents, so
the skill does the role's work in the session and says so.

Add your own skill next to them. Write one when you have corrected the same
mistake twice, not before. Better still, when a lint, a test, or a type can
catch the mistake, add that, so nothing depends on an agent reading a rule.

## Turn it off

```bash
bercail bstack off
```

It removes bstack's files (the marked ones, the `bstack/` folder, and its
model cache in `~/.local/share/bercail`) and leaves opencode, your plans, and
your own config alone. `[agent] command` stays as it is, so after `bstack on`
moved it to opencode, the desk now runs plain opencode; set it back in
[config](../config.md) if you want another agent.

Next: [Recipes and pitfalls](./09-recipes-and-pitfalls.md).
