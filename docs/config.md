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

[graphite]                           # optional, one line per repo; see below
"~/Work/some-repo" = false
```

After you edit it, `bercail reconfigure` re-reads it, refreshes the skills and bstack, and installs the desk agent and review tool if they are missing. What the `[bstack]` keys do (pins, `effort`, roles) is in [Make it yours](bstack/08-make-it-yours.md#models-and-roles); `review` and `auto_review` in [review](review.md); `[graphite]` in [handoff](handoff.md#graphite).

## Files bercail manages

- `~/.config/herdr-app/layouts/bercail.json`, `mods/bercail-desk/`, `mods/bercail-agents/` and `mods/bercail-review/` (the app rewrites the layout as you use it, so `bercail update` replaces it only when bercail ships a new one), and the `layout:bercail` section of `keys.json` (see [keys](keys.md)).
- `~/.config/bercail/` (`config.toml`, `shell/`, `config-reader.sh`, `config.toml.example`, `notify.d/`), and the marker block in your `~/.bashrc` or `~/.zshrc` that sources the shell helpers.
- worktrunk hooks (`~/.config/worktrunk/config.toml`, `herdr-layout.sh`).
- `~/.local/bin/{bercail,agentic-dev,bercail-desk-agent,bercail-desk-claude-hook}` (a mise or packslip install keeps its own `bercail`), and `~/.local/share/bercail/`.
- `~/.agents/skills/{handoff,review,bstack,council,autopilot,how,why,unslop,desk-restore}`.
- bstack's files in `~/.config/opencode` (see [Make it yours](bstack/08-make-it-yours.md#your-own-files)).
- The local TUI plugin `~/.config/opencode/plugins/bercail-desk/tui.ts`, including when bstack is off.
- `diff_watch_interval_ms` in `~/.config/tuicr/config.toml`, unless you set it already.
- On Linux and Omarchy, the extras in [platforms](development.md#platforms).
- One `SessionStart` entry in `~/.claude/settings.json`, when `~/.claude` exists (`bercail uninstall` takes it back).

## Desks after a reboot

Herdr brings back spaces, tabs, and each desk's terminal, but as a bare shell: it never reruns a program. So `bercail-desk-agent` writes down what ran there, and the desk comes back on the same session in the same space, with no prompt sent again.

- **The record.** `~/.local/state/bercail/desk-sessions/<address>.json` holds `session`, `cwd`, `harness`, `issue`, `space`, `args` (resume-safe flags) and `pid`, keyed by the terminal's address. A local opencode TUI plugin records the selected session, even while idle and with bstack off. A watcher touches the file every minute while the desk lives. Claude's session comes from a `SessionStart` hook. Headless runs get no record.
- **What comes back.** A record fresh within ten minutes of shutdown (the last journal line of the previous boot), on a desk at a bare shell, in a folder that still exists, whose session is not already open. Records written since shutdown also qualify for a manual restore after a core stop/start. A desk you quit has finished, so it stays quit. Older records stay shells.
- **Duplicate checks.** Restore checks process arguments, all live Herdr terminals' status records, and the opencode plugin's runtime claims in `$XDG_RUNTIME_DIR/bercail/open-sessions/`. Claims include idle sessions and tabs, and count only while their original process is alive. TUIs started before the plugin was installed may have no claim: check those manually before restoring.
- **When.** Once per boot, through Omarchy's post-boot hook or else a systemd user unit: it waits until you open Herdr, then a notification says how many came back. Omarchy logs to `~/.local/state/bercail/desk-restore.log`; systemd logs to `journalctl --user -u bercail-desk-restore`. After a core restart, or to run it yourself, use `bercail desk restore`; `--dry-run` lists each desk and why.
- **What does not.** An opencode home screen with no selected session has nothing to resume. Codex and cursor-agent desks are not recorded with a session. No boot hook runs on macOS or without Omarchy/systemd; manual restore is still available. For these, and for desks from before records existed, the `desk-restore` skill finds the session by folder and content. Install/update wires the hooks for future sessions, not agents already running.
