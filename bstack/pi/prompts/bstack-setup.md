---
description: Check bstack's Pi logins and model roles, and walk through fixing what is missing
---
Help me set up bstack on Pi. Start by running `bercail bstack status 2>&1`.

Explain in a few lines which logins are ready, which model each role uses, and what is missing. For each provider that is not logged in, give me the one line to type in this Pi session (logins are interactive, so do not try to run them yourself):

- Claude: `/login anthropic` (Pi's own Anthropic login, billed per token as extra usage)
- ChatGPT: `/login openai` (choose Sign in with ChatGPT)
- Grok: `/login xai`

Then tell me to run `bercail update`, which picks the newest model of each logged-in provider and rewrites the bstack profile. To pin a model instead, set `claude`, `gpt`, or `grok` under `[bstack]` in `~/.config/bercail/config.toml`, as a Pi id such as `anthropic/claude-opus-5-5#high`. Do not edit bercail or Pi config files yourself.
$ARGUMENTS
