# development

## Hacking on bercail

```bash
shellcheck install.sh lib/*.sh bin/bercail config/shell/bercail.inc.sh config/worktrunk/herdr-layout.sh
herdr-app check bercail/mods/bercail-desk
herdr-app check bercail/mods/bercail-agents
for t in tests/*_test.sh; do bash "$t" || break; done
./install.sh --help
bin/bercail dry-run   # this checkout's CLI; a bare `bercail` runs the installed copy
npm ci && npm run deploy   # sync public/, deploy Pages + the setup.simoncrypta.dev Worker
```

CI runs every `tests/*.sh` on each push and PR, and deploys from master when `CLOUDFLARE_API_TOKEN` is set.

## dependencies

Installed if missing: the [Herdr app](https://herdr.dev) with herdr-core (`herdr-app`, `hc`, from herdr.dev's installer), git, worktrunk (`wt`), [beads](https://beads.gascity.com/) (`bd`), fzf, jq, and the review tool: [tuicr](https://github.com/agavra/tuicr) ≥ 0.20.0, or hunk ≥ 0.20.1 with `review = "hunk"`. `bercail doctor` checks each one and flags an old tuicr; the installer doesn't upgrade one that is already there.

worktrunk and beads install the same way: skip if present, else mise, else Homebrew (`brew install worktrunk` / `brew install beads`), else upstream (worktrunk's GitHub release; the [beads installer](https://raw.githubusercontent.com/gastownhall/beads/main/scripts/install.sh), which puts `bd` in `/usr/local/bin` when writable, else `~/.local/bin`).

With bstack on: [opencode](https://github.com/anomalyco/opencode) 2.2.3+ (mise, else `brew install anomalyco/tap/opencode-v2`). Its Claude Agent sign-in runs [Claude Code](https://docs.anthropic.com/en/docs/claude-code), so a Claude plan needs `claude` too.

[Claude Code](https://docs.anthropic.com/en/docs/claude-code), [Codex CLI](https://github.com/openai/codex), and cursor-agent are optional. Install the ones you want Shep to use; `bercail harness` reports which are on PATH.

## platforms

**Omarchy.** mise first, `omarchy pkg add`, optional `SUPER+ALT+RETURN` → open or focus the Herdr app, and a post-update hook (`~/.config/omarchy/hooks/post-update.d/bercail.hook`, when `omarchy-hook-install` exists): after `omarchy-update`, it fast-forwards the clone bercail was installed from and runs `bercail update` without prompting (each question takes its default, no). It acts only on a git clone, so curl and mise/packslip installs skip it (update those with `bercail update` or `mise up`). It skips with one line when offline, dirty, off master/main, or diverged. Herdr updates itself; `bercail doctor` says when a downloaded Herdr waits on a window restart.

**Linux with fcitx5** (Omarchy included). fcitx5 `Ctrl+Alt+H/J` hint keys cleared.

**Ubuntu.** mise first, else Homebrew if present, else apt (`git fzf jq curl`); worktrunk, beads, tuicr from upstream.

**macOS.** mise first; Homebrew stays on PATH as fallback (`brew shellenv`, then mise shims prepended).

**Hyprland.** Optional `SUPER+ALT+RETURN` that launches the Herdr app (focus-if-open is Omarchy only).

The `SUPER+ALT+RETURN` patch asks first; `--yes` says yes to it.
