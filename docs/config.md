# config

`~/.config/bercail/config.toml`:

```toml
[layout]
review = "tuicr"                     # or "hunk"
auto_review = true

[bstack]                             # --no-bstack installs: none, and the desk runs plain Pi
enabled = true
fallback = ["claude", "gpt", "grok"] # Pi rate-limit candidates, no duplicates
claude = ""
gpt = ""
grok = ""
effort = "high"
lead = "claude"
build = "grok"
judge = "claude"

[git]                                # optional, one line per main checkout
"~/Work/some-repo" = "gh"              # gh | gt | origin
```

After you edit it, `bercail reconfigure` re-reads it, refreshes the skills and bstack, and installs Pi and the review tool if they are missing. The desk always runs Pi: bstack's lead when bstack is on, else plain `pi`. What the `[bstack]` keys do (pins, `effort`, roles) is in [Make it yours](bstack/08-make-it-yours.md#models-and-roles); `review` and `auto_review` in [review](review.md); `[git]` in [handoff](handoff.md#git-backend). Legacy `[graphite]` booleans still work (`true` → `gt`, `false` → `gh`), but `[git]` takes precedence.

## Files bercail manages

- `~/.config/herdr-app/layouts/bercail.json`, `mods/bercail-desk/`, `mods/bercail-shep/`, `mods/bercail-spaces/`, `mods/bercail-agents/` and `mods/bercail-review/` (the app rewrites the layout as you use it, so `bercail update` replaces it only when bercail ships a new one), and the `layout:bercail` section of `keys.json` (see [keys](keys.md)).
- `~/.config/bercail/` (`config.toml`, `shell/`, `config-reader.sh`, `config.toml.example`, `notify.d/`), and the marker block in your `~/.bashrc` or `~/.zshrc` that sources the shell helpers.
- worktrunk hooks (`~/.config/worktrunk/config.toml`, `herdr-layout.sh`).
- `~/.local/bin/{bercail,agentic-dev,bercail-desk-agent}` (a mise or packslip install keeps its own `bercail`), and `~/.local/share/bercail/`.
- `~/.agents/skills/{handoff,review,bstack,council,autopilot,how,why,unslop,desk-restore}`, with a link to each in `~/.pi/agent/skills`.
- bstack's Pi profile in `~/.local/share/bercail/pi/` and role templates in `~/.config/herdr-core/templates/` (see [Make it yours](bstack/08-make-it-yours.md#your-own-files)). bstack installs `npm:pi-claude-bridge@0.11.0` into Pi's package settings.
- The Pi extension `~/.local/share/bercail/pi-extensions/bercail-desk.ts` that every Pi desk loads with `-e`, including when bstack is off.
- `diff_watch_interval_ms` in `~/.config/tuicr/config.toml`, unless you set it already.
- On Linux and Omarchy, the extras in [platforms](development.md#platforms).

## Desks after a reboot

Herdr brings back spaces, tabs, and each desk's terminal, but as a bare shell: it never reruns a program. So `bercail-desk-agent` writes down what ran there, and the desk comes back on the same session in the same space, with no prompt sent again.

- **The record.** `~/.local/state/bercail/desk-sessions/<address>.json` holds `session`, `cwd`, `harness`, `issue`, `issue_title` (empty when unknown), `space`, `args` (resume-safe flags) and `pid`, keyed by the terminal's address. The `bercail-desk` Pi extension records the session Pi has open, even while idle and with bstack off. A watcher touches the file every minute while the desk lives. Headless runs get no record.
- **What comes back.** A record fresh within ten minutes of shutdown (the last journal line of the previous boot), on a desk at a bare shell, in a folder that still exists, whose session is not already open. Records written since shutdown also qualify for a manual restore after a core stop/start. A desk you quit has finished, so it stays quit. Older records stay shells.
- **Duplicate checks.** Restore checks process arguments, all live Herdr terminals' status records, and the Pi extension's runtime claims in `$XDG_RUNTIME_DIR/bercail/open-sessions/`. Claims include idle sessions, and count only while their original process is alive. A Pi started before the extension was installed may have no claim: check those manually before restoring.
- **When.** Once per boot, through Omarchy's post-boot hook or else a systemd user unit: it waits until you open Herdr, then a notification says how many came back. Omarchy logs to `~/.local/state/bercail/desk-restore.log`; systemd logs to `journalctl --user -u bercail-desk-restore`. After a core restart, or to run it yourself, use `bercail desk restore`; `--dry-run` lists each desk and why.
- **What does not.** A Pi with no session saved (`--no-session`) has nothing to resume. The lead's `hc` siblings (builder, judge, council) are not desks and stay shells. No boot hook runs on macOS or without Omarchy/systemd; manual restore is still available. For these, and for desks from before records existed, the `desk-restore` skill finds the session by folder and content. Install/update wires the hooks for future sessions, not agents already running.
