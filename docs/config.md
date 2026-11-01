# config

`~/.config/bercail/config.toml`:

```toml
[agent]
command = "opencode"                 # --no-bstack installs: cursor-agent, and no [bstack]

[layout]
review = "tuicr"                     # or "hunk"
auto_review = true

[bstack]
enabled = true
claude = ""
gpt = ""
grok = ""
effort = "high"
lead = "claude"
build = "grok"
judge = "claude"
```

After you edit it, `bercail reconfigure` re-reads it, refreshes the skills and bstack, and installs the desk agent and review tool if they are missing. What the `[bstack]` keys do (pins, `effort`, roles) is in [Make it yours](bstack/08-make-it-yours.md#models-and-roles); `review` and `auto_review` in [review](review.md).

## Files bercail manages

- `~/.config/herdr-app/layouts/bercail.json`, `mods/bercail-desk/` and `mods/bercail-agents/` (the app rewrites the layout as you use it, so `bercail update` replaces it only when bercail ships a new one), and the `layout:bercail` section of `keys.json` (see [keys](keys.md)).
- `~/.config/bercail/` (`config.toml`, `shell/`, `config-reader.sh`, `config.toml.example`, `notify.d/`), and the marker block in your `~/.bashrc` or `~/.zshrc` that sources the shell helpers.
- worktrunk hooks (`~/.config/worktrunk/config.toml`, `herdr-layout.sh`).
- `~/.local/bin/{bercail,agentic-dev,bercail-desk-agent}` (a mise or packslip install keeps its own `bercail`), and `~/.local/share/bercail/`.
- `~/.agents/skills/{handoff,review,bstack,council,autopilot,how,why,unslop}`.
- bstack's files in `~/.config/opencode` (see [Make it yours](bstack/08-make-it-yours.md#your-own-files)).
- `diff_watch_interval_ms` in `~/.config/tuicr/config.toml`, unless you set it already.
- On Linux and Omarchy, the extras in [platforms](development.md#platforms).
