# Make it yours

bstack is opinions in files. Change the ones that don't fit.

## Models and roles

Everything lives under `[bstack]` in `~/.config/bercail/config.toml`:

```toml
[bstack]
enabled = true
# Empty: auto, the newest model of that plan. A Pi model id pins one.
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
seat even when you are not signed in to its plan, and skips every new release;
auto picks again on every update.

Roles fall back to the next plan you are signed in to, so you can set them once
and sign in later ([the order](./02-the-bstack-agent.md#the-roles)). Higher
effort reasons longer and spends more of each plan; a model without the level
you ask for gets the next one down.

### Rate-limit fallback

`fallback = ["claude", "gpt", "grok"]` sets runtime candidates after Pi
exhausts rate-limit retries. Each switch scans from the start, skipping the
current model, models already tried, models still limited, and providers that
are dead for the session (402, out of credits, no subscription). For example,
`fallback = ["gpt", "grok"]` tries GPT before Grok. An entry is a family name or
a Pi model id without an effort: `["claude-bridge/claude-sonnet-5-5", "claude",
"gpt"]` tries Sonnet before Opus. That helps only when the limit belongs to one
model (`seven_day_opus`); the five-hour and weekly windows cover the whole plan,
and the fallback skips every Claude model then. Duplicates are rejected, and
`[]` disables fallback. This does not change the initial role model picks above.

When the desk's own model's limit lifts, the next user message or turn goes back
to it. Every switch keeps the desk's thinking level, so a `:high` desk stays high.

Claude IDs use `claude-bridge/`, for example
`claude-bridge/claude-opus-5-5:high`, as `pi --list-models` and
`handoff-spawn --model` write it. The bridge uses `claude auth login`, not
Pi's Anthropic login. Status and doctor count a subscription only when
`claude auth status` reports `authMethod` `claude.ai` or `oauth_token`.
Run `bercail update` after changing fallback or model pins. `bercail bstack status`
shows the order, and `bercail doctor` flags stale profile data and lists the
providers the fallback found dead in the last day. See
[How it runs](../bstack.md#how-it-runs) for installation and role launches.

## What bstack sets up in Pi

- **The lead on the desk**, on the lead's model, with bercail's instructions
  (`pi/instructions.md`), its prompt templates (`/ready`, `/council`, ...), and
  bercail's skills.
- **The roles as `hc` templates** in `~/.config/herdr-core/templates/`, each with
  its own model and brief.
- **A guard** that blocks force-push, `--no-verify`, and `gh pr merge` for every
  role, and autopilot's push to `main` or `master`. Other commits, pushes, and
  tags follow the repo's trusted [git policy](../config.md#git-policy-per-repo):
  what it allows goes through and is logged; the rest asks on a desk and is
  blocked in a headless run. Each agent gets that policy in its prompt.
- **The rate-limit fallback** above.
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
