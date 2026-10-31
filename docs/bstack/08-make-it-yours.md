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
each model as `auto` or `pinned`. A pin stays until you clear it; auto picks
again on every update.

A role whose plan isn't connected takes the next one that is, so you can set
roles once and connect plans later. Higher effort reasons longer and spends more
of each plan; a model without the level you ask for gets the next one down.

## What bstack turns on in opencode

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

Every file bstack writes carries a `managed by bercail (bstack)` line:
`opencode.jsonc`, `agents/bstack*.md`, `commands/*.md`, and
`bstack/instructions.md` under `~/.config/opencode`. Delete that line and
bercail never touches the file again. It warns on update instead.

Your own opencode settings go in `~/.config/opencode/opencode.json`. opencode
loads it under bstack's `.jsonc`, so yours survive every update.

## Skills

bstack's skills are in `~/.agents/skills`: `bstack`, `how`, `why`, `unslop`,
`council`, `autopilot`. opencode reads them directly, and so do Claude Code,
Codex, and cursor-agent. Outside opencode there are no `bstack-*` subagents, so
the skill does the role's work in the session and says so.

Add your own skill next to them. Write one when you have corrected the same
mistake twice, not before. Better still, when a lint, a test, or a type can
catch the mistake, add that, so nothing depends on an agent reading a rule.

## Turn it off

```bash
bercail bstack off
```

It removes bstack's files (only the ones that still carry the marker) and leaves
opencode, your plans, and your own config alone.

Next: [Recipes and pitfalls](./09-recipes-and-pitfalls.md).
