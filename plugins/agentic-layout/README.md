# Agentic Layout

Herdr plugin for the agentic-dev three-column workspace:

```text
Herdr dock | agent (5/12) | review or shell (5/12) | files/git sidebar (1/6)
```

Install the full stack (Herdr, Worktrunk, agents, keybindings) via [agentic-dev-setup](https://github.com/simoncrypta/agentic-dev-setup).

## Plugin only

```bash
herdr plugin install simoncrypta/agentic-dev-setup/plugins/agentic-layout --ref v0.5.1 --yes
```

Local development:

```bash
cargo build --release -p herdr-sidebar
herdr plugin link ~/path/to/agentic-dev-setup/plugins/agentic-layout
```

## Actions

| Action | Description |
|--------|-------------|
| `create` | Create layout (agent pane stays a shell; used by worktrunk/handoff) |
| `apply` | Repair plugin-owned panes and start a clear session of the configured agent (`d` / `prefix+d`) |
| `start-agent` | Start the configured agent if the pane is a shell (no prompt; does not replace a live agent) |
| `handoff-agent` | Start or replace the agent with `WT_HERDR_AGENT_PROMPT_FILE` (orchestrator / handoff-spawn) |
| `focus-agent` | Focus the persistent agent pane; start it if the pane is a shell |
| `select-review` | Open or focus review (`tuicr -r origin/main -w` on a feature branch, `tuicr pr N` for someone else's PR; creates the tab if needed) |
| `close-review` | Close the Review tab and return to Shell |
| `refresh-review` | Focus review and restart tuicr (`-r <base> -w` or `tuicr pr`) |
| `select-review-worktree` | Open Review with uncommitted changes (`tuicr -w`) |
| `select-shell` | Show live shell pane (no respawn) |
| `toggle-sidebar` | Toggle files pane zoom |
| `select-files` | Files view |
| `select-source-control` | Source control view |
| `open-editor` | Open a path in a new tab (`layout.sh open-editor <path>`) |
| `close-tab` | Close the current file tab and land on the previous one |
| `close-pane` | Close an extra split; an editor center closes the tab instead |

Sidebar keys in embedded mode: `v` opens tuicr. Source Control lists changes (click a file to edit); **Review** opens tuicr on uncommitted work (`tuicr -w`).

## Config

Reads `~/.config/bercail/config.toml` when present:

```toml
[layout]
review = "tuicr"
auto_review = true   # open tuicr when the agent pane goes done
# editor = "nvim"   # optional; default is $EDITOR / $VISUAL
agent_ratio = 0.416667
sidebar_ratio = 0.166667
```

## Sidebar fork

Files/git sidebar is our fork of [alexarthurs/herdr-sidebar](https://github.com/alexarthurs/herdr-sidebar) (MIT). See `THIRD_PARTY_NOTICES.md`.

## License

MIT
