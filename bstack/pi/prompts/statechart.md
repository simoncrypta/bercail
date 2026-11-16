---
description: Model a stateful change in TLA+, check it with TLC, chart it for the owner, and replay it on the real code.
---
Load the `statechart` skill and follow it. The target: $ARGUMENTS

You have no `statechart` skill when `[bstack] statechart` is off. Then tell the person to set `statechart = true` under `[bstack]` in `~/.config/bercail/config.toml` and run `bercail reconfigure` (it installs TLC, and Java when there is no Java 11 or later), and stop.
