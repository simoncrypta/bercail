# development

## Hacking on bercail

```bash
bash tests/lint.sh            # shellcheck -S warning on every tracked shell file, node --check on each mod
herdr-app check bercail/mods/bercail-desk
herdr-app check bercail/mods/bercail-shep
herdr-app check bercail/mods/bercail-spaces
herdr-app check bercail/mods/bercail-agents
herdr-app check bercail/mods/bercail-review
npm ci && bash tests/run.sh   # the unit suite; or name files: bash tests/run.sh tests/notify.bats
bash tests/run.sh --live      # the live proofs: real Pi, offline, with a stand-in model
node_modules/.bin/bats -f 'regex' tests/x.bats   # the tests whose names match
./install.sh --help
bin/bercail dry-run   # this checkout's CLI; a bare `bercail` runs the installed copy
npm ci && npm run deploy   # build and deploy bercail.dev (CI does this for a v* tag)
npm run build:site && npx wrangler dev --config site/wrangler.jsonc   # the bercail.dev site locally
```

`bercail-spaces` and `bercail-agents` are copies of Herdr's `spaces` and `agents` mods, and Herdr never updates a copy. Each file's header lists bercail's changes, all of them, and its `mod.json` records the Herdr version and the `main.js` it was copied from (`cloned_from.main_js`, the hash in `~/.config/herdr-app/installed.json`). The copies need the Herdr they were made from, or newer. When `bercail doctor` hints that Herdr's mod has changed, rebase: start from Herdr's file in `~/.config/herdr-app/mods/`, put the listed changes back, update `cloned_from`, then run `herdr-app check` and `tests/agents_mod.bats` or `tests/shep_mod.bats`, and look at the list in Herdr.

CI runs `tests/lint.sh` and `tests/run.sh` on each push and PR. The tree has no shellcheck warning, and CI keeps it that way with shellcheck at the version pinned in `.github/workflows/ci.yml` (`SHELLCHECK_VERSION`). Each test runs under a 5-minute `BATS_TEST_TIMEOUT`, so one hung test fails itself instead of the whole job. With [GNU parallel](https://www.gnu.org/software/parallel/) installed, `tests/run.sh` runs files and tests side by side, two jobs per core (`BATS_JOBS=N` sets the count); without it, one at a time. The live proofs always run one at a time. It deploys the site and the Workers only for a `v*` tag, when `CLOUDFLARE_API_TOKEN` is set.

`bercail update` is the source tree's own `bin/bercail` deploying itself (`update_from_tree`): the installed copy finds the tree it was installed from, a clone or a package, and runs that tree's `bercail update`. A curl install has no such tree, so it first downloads the release as one archive and unpacks it over `~/.local/share/bercail/release` (`fetch_release_tree`). So the code that deploys a release is always that release's, and a release can add a file or a deploy step without naming it anywhere: every file in `lib/`, `bstack/` and a skill's folder is installed. `BERCAIL_LIBS` in `lib/common.sh` is the one list of the libs every command loads.

An update from v0.14.0 starts as v0.14.0's code, which knows none of this. It copies the new CLI and `lib/` by its own lists, then loads the new `lib/config.sh`, which starts the update again on the new CLI (`restart_update`), and that one goes on as above. So this release must keep shipping every file v0.14.0's updater copies before that point: `bin/agentic-dev`, `config/agentic-dev/`, its `lib/` list, `skills/handoff/scripts/git-backend.sh`. Before it restarts, `restart_update` fetches the libs that list leaves out and the new ones load (`toml.sh`, `pi-log.sh`, `shep-context.sh`), so the CLI still runs when the new one cannot download the release; a lib the new ones load at startup goes in that list too. `tests/desk_upgrade.bats` installs v0.14.0, the oldest release that updates straight to this one ([install](install.md#updating-from-an-older-release)), and the latest `v*` tag into a throwaway HOME and updates each from this tree, as a clone install and as a curl install whose stand-in `curl` serves only what this tree ships, by name and as the archive, so it needs the release tags (`git fetch --tags`; CI checks out with full history).

The tests are [bats-core](https://github.com/bats-core/bats-core) (pinned in `package.json`), one `@test` per case, each runnable alone; `skills/unit-testing` has the rules. A test file's `setup` calls `isolate` (`tests/test_helper.bash`), which gives every test its own `HOME`, with the `XDG_*` dirs and `TMPDIR` under it. `tests/setup_suite.bash` drops the desk's `HC_*`, Herdr, bercail and beads variables, sets `TZ=UTC` and `LC_ALL=C.UTF-8`, and shadows the desktop commands (`omarchy`, `hyprctl`, `fcitx5`, `notify-send`, ...) with stubs; the run fails if a test calls one. `tests/suite.bats` fails if a test file skips `isolate` or a desk variable reaches a test. A test that cannot run without a tool says so with `need node` (or `unavailable "<why>"`): it skips when the tool is missing, except under `CI`, where it fails, so a test never goes unrun there without anyone seeing. `verify-bercail` also checks that the suite leaves the real `handoffs.jsonl` byte-identical.

`tests/handoff_beads.bats` checks that a handoff worktree writes to the main checkout's beads store in two ways. The tests on the real `bd` prove that bd follows the redirect bercail writes. CI installs bd with mise, as `bercail update` does, at the version pinned in `.github/workflows/ci.yml` (`BD_VERSION`). The tests on a fake bd check what bercail hands bd from the worktree and run everywhere.

Use Node 26 for the Pi extension unit tests. The live proofs (`desk_session_pi`, `pi_guard`, `pi_fallback`, `review_pi`, `shep_pi`) run the extension in the installed Pi, offline, with a stand-in model, without sending a model prompt or changing your sessions. They are tagged `live`: `tests/run.sh` leaves them out and `tests/run.sh --live` runs only them. `real_pi` fails a test that is not tagged `live`.

`site/` is bercail.dev: an Astro site served by the `bercail-site` Worker, which also serves `/install.sh` from the latest release's tag. The proxy is `site/github.js`.

## releasing

master is unreleased trunk: merge to it freely. A `v*` tag is the release.

1. Bump the version in `lib/common.sh`, `manifest.json`, and the README's release link and pin.
2. Tag the commit `v<version>` and push the tag.

The tag runs `release.yml`, which publishes `bercail.tar.gz` and its signed packslip bundle as a GitHub release, and CI, which tests the tag and deploys bercail.dev. Within a minute of the release, bercail.dev serves `/install.sh` from the new tag, pinned to it (`BERCAIL_RELEASE`), so a curl install downloads that tag's archive (`https://github.com/simoncrypta/bercail/archive/<tag>.tar.gz`, not the `bercail.tar.gz` asset, whose marker says mise or packslip owns the command). A curl install's `bercail update` reads the latest release the same way. Neither reads master. If github.com is down, the Worker keeps the last tag it saw, or answers 503; it never falls back to master.

To try unreleased work through the curl path, take `install.sh` and the files from the same ref: `curl -fsSL https://raw.githubusercontent.com/simoncrypta/bercail/master/install.sh | BERCAIL_REF=master bash`. `BERCAIL_REF` takes a tag, branch, or sha, and works for `bercail update` too; `BERCAIL_ARCHIVE_URL` names another archive of the tree, with one top folder.

## dependencies

Installed if missing: the [Herdr app](https://herdr.dev) with herdr-core (`herdr-app`, `hc`, from herdr.dev's installer), git, worktrunk (`wt`) ≥ 0.80.0, [beads](https://beads.gascity.com/) (`bd`), fzf, jq, and the review tool, [tuicr](https://github.com/agavra/tuicr) ≥ 0.20.0. `bercail doctor` checks each one and flags an old worktrunk or tuicr; the installer doesn't upgrade one that is already there.

worktrunk and beads install the same way: skip if present, else mise, else Homebrew (`brew install worktrunk` / `brew install beads`), else upstream (worktrunk's GitHub release; the [beads installer](https://raw.githubusercontent.com/gastownhall/beads/main/scripts/install.sh), which puts `bd` in `/usr/local/bin` when writable, else `~/.local/bin`).

The desk agent: [Pi](https://pi.dev) (mise), 1.2.0+, with `npm:pi-claude-bridge@0.11.0`; the bridge runs `claude` on your Claude plan, so a Claude plan needs `claude` installed and signed in too.

## platforms

**Omarchy.** mise first, `omarchy pkg add`, optional `SUPER+ALT+RETURN` → open or focus the Herdr app, and a post-update hook (`~/.config/omarchy/hooks/post-update.d/bercail.hook`, when `omarchy-hook-install` exists): after `omarchy-update`, it fast-forwards the clone bercail was installed from and runs `bercail update` without prompting (each question takes its default, no). It acts only on a git clone, so curl and mise/packslip installs skip it (update those with `bercail update` or `mise up`). It skips with one line when offline, dirty, off master/main, or diverged. Herdr updates itself; `bercail doctor` says when a downloaded Herdr waits on a window restart. A post-boot hook (`~/.config/omarchy/hooks/post-boot.d/bercail-desk-restore.hook`) brings back [the desks that were running](config.md#desks-after-a-reboot) once Herdr opens.

**Linux with a systemd user manager** (not Omarchy). The `bercail-desk-restore.service` user unit does the same.

**Ubuntu.** mise first, else Homebrew if present, else apt (`git fzf jq curl`); worktrunk, beads, tuicr from upstream.

**macOS.** mise first; Homebrew stays on PATH as fallback (`brew shellenv`, then mise shims prepended).

**Hyprland.** Optional `SUPER+ALT+RETURN` that launches the Herdr app (focus-if-open is Omarchy only).

The `SUPER+ALT+RETURN` patch asks first; `--yes` says yes to it.
