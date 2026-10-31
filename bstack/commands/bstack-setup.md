---
# managed by bercail (bstack). `bercail update` rewrites this file; delete this line to keep your own.
description: Check bstack's subscriptions and model roles, and walk through fixing what is missing
---
Help me set up bstack. Here is its current state:

!`bercail bstack status 2>&1`

Explain in a few lines what is connected, which model each role uses, and what is
missing. For each subscription that is not connected, give me the one command to
run in a terminal (logins are interactive, so do not run them yourself):

- Claude plan: `claude auth login`, then `opencode auth login claude-agent`
- ChatGPT plan: `opencode auth login openai` (choose Sign in with ChatGPT)
- X subscription: `opencode auth login xai --method device`

Then tell me to run `bercail bstack setup`, which picks the newest model of each
connected plan by itself and rewrites the bstack agents. To pin a model instead,
set `claude`, `gpt`, or `grok` under `[bstack]` in `~/.config/bercail/config.toml`.
Do not edit bercail or opencode config files yourself.
$ARGUMENTS
