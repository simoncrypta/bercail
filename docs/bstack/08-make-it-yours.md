# Make it yours

bstack is opinions in files. Change the ones that don't fit.

## Models and roles

Everything lives under `[bstack]` in `~/.config/bercail/config.toml`:

```toml
[bstack]
# Empty: auto, the newest model of that plan. A Pi model id pins one.
claude = ""
gpt = "openai/gpt-6.2-sol"
# Reasoning effort of auto models: low, medium, high (default), xhigh, max, none.
effort = "xhigh"
# A plan (claude, gpt) or a full model id.
lead = "claude"
build = "claude"
judge = "gpt"
```

Then `bercail bstack setup` or `bercail update`. `bercail bstack status` shows
each model as `auto` or `pinned`. A pin stays until you clear it, gets a council
seat even when you are not signed in to its plan, and skips every new release;
auto picks again on every update.

The judge on `gpt` runs on Claude until you sign in to ChatGPT, so you can set
it once and sign in later ([the roles](./02-the-bstack-agent.md#the-roles)).
Every other role takes only Claude. Higher
effort reasons longer and spends more of each plan; a model without the level
you ask for gets the next one down.

### Rate limits

There is no fallback model. When a role hits a limit after Pi's own retries, it
pauses until the limit resets and then goes on with the same request, on the
same model. The desk shows the reset time and reports itself blocked; Esc stops
waiting. The judge is the one exception: while GPT is limited, Claude stands in,
so `/validate` still finishes, and the judge goes back to GPT once its limit
lifts. If Claude is limited too, the judge pauses. [How it runs](../bstack.md#how-it-runs)
has the details. A `fallback` key from an older release is ignored with a
warning.

Claude IDs use `claude-bridge/`, for example
`claude-bridge/claude-opus-5-5:high`, as `pi --list-models` and
`handoff-spawn --model` write it. The bridge uses `claude auth login`, not
Pi's Anthropic login. Status and doctor count a subscription only when
`claude auth status` reports `authMethod` `claude.ai` or `oauth_token`.
Run `bercail update` after changing model pins. `bercail doctor` flags stale
profile data and lists the providers found dead in the last day. See
[How it runs](../bstack.md#how-it-runs) for installation and role launches.

## What bstack sets up in Pi

- **The lead on the desk**, on the lead's model, with bercail's instructions
  (`pi/instructions.md`), its prompt templates (`/validate`, `/council`, ...), and
  bercail's skills.
- **The roles as `hc` templates** in `~/.config/herdr-core/templates/`, each with
  its own model and brief.
- **A guard** that blocks force-push, `--no-verify`, and `gh pr merge` for every
  role, and autopilot's push to `main` or `master`. Other commits, pushes, and
  tags follow the repo's trusted [git policy](../config.md#git-policy-per-repo):
  what it allows goes through and is logged; the rest asks on a desk and is
  blocked in a headless run. Each agent gets that policy in its prompt.
- **The rate-limit pause** above, and the judge's stand-in.
- **review-pr's reviewer** (`pi/review.json`): the lead's model with only Pi's
  read tools, kept inside the review's stack dir.

Pi's own settings and logins stay yours: bstack passes everything with flags
and adds only the bridge package to Pi's settings, plus a 40k compaction
reserve for each `claude-bridge` model so Pi compacts before Claude Code
refuses the prompt ([why](../bstack.md#how-it-runs)). A larger reserve you set
stays.

## Your own files

The templates in `~/.config/herdr-core/templates/bstack-*.md` each carry a
`managed by bercail (bstack)` line. Delete that line and bercail never touches
the file again; `bercail doctor` lists it as yours. `~/.local/share/bercail/pi/`
has no line: it belongs to bercail, and every update rewrites it.

## Skills

bstack's skills are in `~/.agents/skills` ([the list](../cli.md#skills)), with
a link in `~/.pi/agent/skills` for each. Every bstack role also loads them with
`--skill`, so Pi's settings cannot filter them out.

Add your own skill next to them. Write one when you have corrected the same
mistake twice, not before. Better still, when a lint, a test, or a type can
catch the mistake, add that, so nothing depends on an agent reading a rule.

Next: [Recipes and pitfalls](./09-recipes-and-pitfalls.md).
