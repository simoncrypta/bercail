# development

## Hacking on bercail

```bash
shellcheck install.sh lib/*.sh bin/bercail bin/bercail-desk-agent config/shell/bercail.inc.sh config/worktrunk/herdr-layout.sh
herdr-app check bercail/mods/bercail-desk
herdr-app check bercail/mods/bercail-shep
herdr-app check bercail/mods/bercail-spaces
herdr-app check bercail/mods/bercail-agents
herdr-app check bercail/mods/bercail-review
for t in tests/*_test.sh; do bash "$t" || break; done
./install.sh --help
bin/bercail dry-run   # this checkout's CLI; a bare `bercail` runs the installed copy
npm ci && npm run deploy   # deploy the setup.simoncrypta.dev Worker and the site (CI does this for a v* tag)
npm run build:site && npx wrangler dev --config site/wrangler.jsonc   # the bercail.dev site locally
```

CI runs every `tests/*.sh` on each push and PR, each under a 5-minute `timeout`, so one hung test fails its file instead of the whole job. It deploys the site and the Workers only for a `v*` tag, when `CLOUDFLARE_API_TOKEN` is set.

Use Node 26 for the Pi extension unit tests. When Pi is installed, `tests/desk_session_pi_test.sh`, `tests/review_pi_test.sh`, and the other `*_pi_test.sh` also run the extension in a real Pi, offline, with a stand-in model, without sending a model prompt or changing your sessions.

`site/` is bercail.dev: an Astro site served by the `bercail-site` Worker, which also serves `/install.sh` from the latest release's tag. `workers/setup-domain` keeps the legacy setup.simoncrypta.dev host alive for older installs. Both share `workers/setup-domain/src/github.js`.

## releasing

master is unreleased trunk: merge to it freely. A `v*` tag is the release.

1. Bump the version in `lib/common.sh`, `manifest.json`, and the README's release link and pin.
2. Tag the commit `v<version>` and push the tag.

The tag runs `release.yml`, which publishes `bercail.tar.gz` and its signed packslip bundle as a GitHub release, and CI, which tests the tag and deploys bercail.dev. Within a minute of the release, bercail.dev serves `/install.sh` from the new tag, pinned to it (`BERCAIL_RELEASE`), so a curl install reads every file from that tag. A curl install's `bercail update` reads the latest release the same way. Neither reads master. If github.com is down, the Worker keeps the last tag it saw, or answers 503; it never falls back to master.

To try unreleased work through the curl path, take `install.sh` and the files from the same ref: `curl -fsSL https://raw.githubusercontent.com/simoncrypta/bercail/master/install.sh | BERCAIL_REF=master bash`. `BERCAIL_REF` takes a tag, branch, or sha, and works for `bercail update` too; `GITHUB_RAW_BASE` overrides the whole raw URL.

## dependencies

Installed if missing: the [Herdr app](https://herdr.dev) with herdr-core (`herdr-app`, `hc`, from herdr.dev's installer), git, worktrunk (`wt`), [beads](https://beads.gascity.com/) (`bd`), fzf, jq, and the review tool: [tuicr](https://github.com/agavra/tuicr) ≥ 0.20.0, or hunk ≥ 0.20.1 with `review = "hunk"`. `bercail doctor` checks each one and flags an old tuicr; the installer doesn't upgrade one that is already there.

worktrunk and beads install the same way: skip if present, else mise, else Homebrew (`brew install worktrunk` / `brew install beads`), else upstream (worktrunk's GitHub release; the [beads installer](https://raw.githubusercontent.com/gastownhall/beads/main/scripts/install.sh), which puts `bd` in `/usr/local/bin` when writable, else `~/.local/bin`).

The desk agent: [Pi](https://pi.dev) (mise). With bstack on, Pi 1.2.0+ and `npm:pi-claude-bridge@0.11.0`; the bridge runs `claude` on your Claude plan, so a Claude plan needs `claude` installed and signed in too.

## platforms

**Omarchy.** mise first, `omarchy pkg add`, optional `SUPER+ALT+RETURN` → open or focus the Herdr app, and a post-update hook (`~/.config/omarchy/hooks/post-update.d/bercail.hook`, when `omarchy-hook-install` exists): after `omarchy-update`, it fast-forwards the clone bercail was installed from and runs `bercail update` without prompting (each question takes its default, no). It acts only on a git clone, so curl and mise/packslip installs skip it (update those with `bercail update` or `mise up`). It skips with one line when offline, dirty, off master/main, or diverged. Herdr updates itself; `bercail doctor` says when a downloaded Herdr waits on a window restart. A post-boot hook (`~/.config/omarchy/hooks/post-boot.d/bercail-desk-restore.hook`) brings back [the desks that were running](config.md#desks-after-a-reboot) once Herdr opens.

**Linux with a systemd user manager** (not Omarchy). The `bercail-desk-restore.service` user unit does the same.

**Linux with fcitx5** (Omarchy included). fcitx5 `Ctrl+Alt+H/J` hint keys cleared.

**Ubuntu.** mise first, else Homebrew if present, else apt (`git fzf jq curl`); worktrunk, beads, tuicr from upstream.

**macOS.** mise first; Homebrew stays on PATH as fallback (`brew shellenv`, then mise shims prepended).

**Hyprland.** Optional `SUPER+ALT+RETURN` that launches the Herdr app (focus-if-open is Omarchy only).

The `SUPER+ALT+RETURN` patch asks first; `--yes` says yes to it.
