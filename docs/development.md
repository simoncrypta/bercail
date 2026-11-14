# development

## Hacking on bercail

```bash
bash tests/lint.sh            # shellcheck -S warning on every tracked shell file, vp check, and the mods' lint
herdr-app check bercail/mods/bercail-desk
herdr-app check bercail/mods/bercail-shep
herdr-app check bercail/mods/bercail-spaces
herdr-app check bercail/mods/bercail-agents
herdr-app check bercail/mods/bercail-review
npm ci && bash tests/run.sh   # the unit suite: bats, then vp test; or name files: bash tests/run.sh tests/notify.bats
bash tests/run.sh --live      # the live proofs: real Pi, offline, with a stand-in model
node_modules/.bin/bats -f 'regex' tests/x.bats   # the tests whose names match
npm exec -- vp test -t 'regex'                   # the TypeScript tests whose names match
npm exec -- vp check --fix                       # format, then lint and type-check the TypeScript and JavaScript
./install.sh --help
bin/bercail dry-run   # this checkout's CLI; a bare `bercail` runs the installed copy
npm ci && npm run deploy   # build and deploy bercail.dev (CI does this for a v* tag)
npm run build:site && npx wrangler dev --config site/wrangler.jsonc   # the bercail.dev site locally
```

`bercail-spaces` and `bercail-agents` are copies of Herdr's `spaces` and `agents` mods, and Herdr never updates a copy. Each file's header lists bercail's changes, all of them, and its `mod.json` records the Herdr version and the `main.js` it was copied from (`cloned_from.main_js`, the hash in `~/.config/herdr-app/installed.json`). The copies need the Herdr they were made from, or newer. When `bercail doctor` hints that Herdr's mod has changed, rebase: start from Herdr's file in `~/.config/herdr-app/mods/`, put the listed changes back, update `cloned_from`, then run `herdr-app check` and `tests/agents_mod.bats` or `tests/shep_mod.bats`, and look at the list in Herdr.

The tree has no shellcheck warning and passes `vp check`, and [CI](#ci) keeps it that way. Each test runs under a 5-minute `BATS_TEST_TIMEOUT`, so one hung test fails itself instead of the whole job. With [GNU parallel](https://www.gnu.org/software/parallel/) installed, `tests/run.sh` runs files and tests side by side, two jobs per core (`BATS_JOBS=N` sets the count); without it, one at a time. The live proofs always run one at a time.

`bercail update` is the source tree's own `bin/bercail` deploying itself (`update_from_tree`): the installed copy finds the tree it was installed from, a clone or a package, and runs that tree's `bercail update`. A curl install has no such tree, so it first downloads the release as one archive and unpacks it over `~/.local/share/bercail/release` (`fetch_release_tree`). So the code that deploys a release is always that release's, and a release can add a file or a deploy step without naming it anywhere: every file in `lib/`, `bstack/` and a skill's folder is installed. `BERCAIL_LIBS` in `lib/common.sh` is the one list of the libs every command loads.

An update from v0.14.0 starts as v0.14.0's code, which knows none of this. It copies the new CLI and `lib/` by its own lists, then loads the new `lib/config.sh`, which starts the update again on the new CLI (`restart_update`), and that one goes on as above. So this release must keep shipping every file v0.14.0's updater copies before that point: `bin/agentic-dev`, `config/agentic-dev/`, its `lib/` list, `skills/handoff/scripts/git-backend.sh`. Before it restarts, `restart_update` fetches the libs that list leaves out and the new ones load (`toml.sh`, `pi-log.sh`, `shep-context.sh`), so the CLI still runs when the new one cannot download the release; a lib the new ones load at startup goes in that list too. `tests/desk_upgrade.bats` installs v0.14.0, the oldest release that updates straight to this one ([install](install.md#updating-from-an-older-release)), and the latest `v*` tag into a throwaway HOME and updates each from this tree, as a clone install and as a curl install whose stand-in `curl` serves only what this tree ships, by name and as the archive, so it needs the release tags (`git fetch --tags`; CI checks out with full history).

The tests are [bats-core](https://github.com/bats-core/bats-core) (pinned in `package.json`), one `@test` per case, each runnable alone; `skills/unit-testing` has the rules. A test file's `setup` calls `isolate` (`tests/test_helper.bash`), which gives every test its own `HOME`, with the `XDG_*` dirs and `TMPDIR` under it. `tests/setup_suite.bash` drops the desk's `HC_*`, Herdr, bercail and beads variables, sets `TZ=UTC` and `LC_ALL=C.UTF-8`, and shadows the desktop commands (`omarchy`, `hyprctl`, `fcitx5`, `notify-send`, ...) with stubs; the run fails if a test calls one. `tests/suite.bats` fails if a test file skips `isolate` or a desk variable reaches a test. A test that cannot run without a tool says so with `need node` (or `unavailable "<why>"`): it skips when the tool is missing, except under `CI`, where it fails, so a test never goes unrun there without anyone seeing. `verify-bercail` also checks that the suite leaves the real `handoffs.jsonl` byte-identical.

`tests/handoff_beads.bats` checks that a handoff worktree writes to the main checkout's beads store in two ways. The tests on the real `bd` prove that bd follows the redirect bercail writes. CI installs bd with mise, as `bercail update` does, at the version pinned in `.github/workflows/ci.yml` (`BD_VERSION`). The tests on a fake bd check what bercail hands bd from the worktree and run everywhere.

The TypeScript and JavaScript tooling is [Vite+](https://viteplus.dev) (`vite-plus`, pinned in `package.json`; the config is `vite.config.ts`). `vp check` formats with Oxfmt (TypeScript and JavaScript only; prose, data, and the two copies of Herdr's mods keep their own layout), lints with Oxlint, and type-checks against `tsconfig.json`, Pi extensions included: Pi's own packages are devDependencies for their types, and Pi still loads the `.ts` files as they are. Herdr loads the mods as plain JavaScript, so they stay JavaScript, and `tests/lint.sh` lints them with `bercail/mods/lint.config.ts`, which has no type pass: the `jsconfig.json` that `herdr-app check` writes beside a mod would otherwise make that pass differ between your checkout and CI.

The Pi extensions' unit tests and the Worker's are Vitest (`tests/*.test.ts`, run by `vp test`, which `tests/run.sh` runs after bats when it is given no arguments). `tests/setup.ts` gives each test file the same cut-off as bats: no desk variables, `TZ=UTC`, and a `HOME` and `XDG_*` dirs of its own. Use Node 26. The live proofs (`desk_model_pi`, `desk_session_pi`, `pi_guard`, `pi_fallback`, `review_pi`, `shep_context`, `shep_pi`) are TypeScript files that Node runs as they are (`tests/*_live.ts`). They run the extension in the installed Pi, offline, with a stand-in model, without sending a model prompt or changing your sessions. They are tagged `live`: `tests/run.sh` leaves them out and `tests/run.sh --live` runs only them. `real_pi` fails a test that is not tagged `live`. A proof that drives Pi's TUI gets a terminal from util-linux `script` (`tests/live_term.ts`), so those proofs need Linux.

`site/` is bercail.dev: an Astro site served by the `bercail-site` Worker, which also serves `/install.sh` from the latest release's tag. The proxy is `site/github.ts`.

## ci

`.github/workflows/ci.yml` runs on each push to master, each PR, and each `v*` tag. Two jobs run side by side, and each starts with the setup in `.github/actions/setup` (Node 26, `npm ci`, and the mise tools the job names):

- `lint` runs `tests/lint.sh`: shellcheck, at the version pinned in `SHELLCHECK_VERSION`, then `vp check` and the mods' lint. It takes about 50 seconds, most of it shellcheck.
- `test` runs `tests/run.sh` with GNU parallel: the bats suite, then `vp test`. It takes 2.5 to 3.5 minutes on the free 4-vCPU runner, nearly all of it the bats run. bd comes from mise at the version pinned in `BD_VERSION`, and the checkout has full history for `tests/desk_upgrade.bats`.

`deploy` runs only for a `v*` tag, after both jobs pass, and deploys the site and the Workers when `CLOUDFLARE_API_TOKEN` is set. A newer push to the same branch or PR cancels the older run, on master too, so several merges in a row test only the last one. A tag run is never cancelled.

Every action is pinned by its full commit SHA, with the release tag in a comment beside it (`actions/checkout@<sha> # v7.0.1`), so a moved tag cannot change what runs. To update one, take the new tag's commit SHA and change both.

The caches: setup-node caches npm's download cache, keyed on `package-lock.json`. mise-action caches mise's data dir under a key that holds the job's tool specs, so changing a pin installs fresh, and it saves the cache after the job installs the tools. A hit saves 5 to 10 seconds of setup. Vite+ has no cache in CI. On the runner, `vp check` takes about a second and `vp test` under one, so its task cache, or the Oxlint and Vitest caches, would save at most a second or two on a run that waits about 2 minutes for bats.

### A bigger test runner

The `test` job runs on the label in the repo variable `CI_TEST_RUNNER`, and on `ubuntu-latest` when the variable is unset. `tests/run.sh` runs two jobs per core, so more cores make the suite faster without any other change. Locally, the bats run takes 65 seconds on 4 cores, 38 on 8, and 28 on 16, so 8 cores is about where it stops paying.

GitHub's larger runners need an organization on GitHub Team or Enterprise Cloud. A personal account such as `simoncrypta` cannot have them, and they are billed per minute even on a public repo: Linux 8-core costs $0.022 a minute and 16-core $0.042, and GitHub rounds each job up to the whole minute ([pricing](https://docs.github.com/en/billing/reference/actions-runner-pricing)). To turn one on, create it in the organization's settings (Actions, Runners, New runner), give this repo access to its runner group, then set `CI_TEST_RUNNER` to its name under Settings, Secrets and variables, Actions, Variables. A third-party runner's label works the same way. To go back, delete the variable.

## releasing

master is unreleased trunk: merge to it freely. A `v*` tag is the release.

1. Bump the version in `lib/common.sh`, `manifest.json`, and the README's release link and pin.
2. Tag the commit `v<version>` and push the tag.

The tag runs `release.yml`, which publishes `bercail.tar.gz` and its signed packslip bundle as a GitHub release, and CI, which tests the tag and deploys bercail.dev. Within a minute of the release, bercail.dev serves `/install.sh` from the new tag, pinned to it (`BERCAIL_RELEASE`), so a curl install downloads that tag's archive (`https://github.com/simoncrypta/bercail/archive/<tag>.tar.gz`, not the `bercail.tar.gz` asset, whose marker says mise or packslip owns the command). A curl install's `bercail update` reads the latest release the same way. Neither reads master. If github.com is down, the Worker keeps the last tag it saw, or answers 503; it never falls back to master.

To try unreleased work through the curl path, take `install.sh` and the files from the same ref: `curl -fsSL https://raw.githubusercontent.com/simoncrypta/bercail/master/install.sh | BERCAIL_REF=master bash`. `BERCAIL_REF` takes a tag, branch, or sha, and works for `bercail update` too; `BERCAIL_ARCHIVE_URL` names another archive of the tree, with one top folder.

## dependencies

Installed if missing: the [Herdr app](https://herdr.dev) with herdr-core (`herdr-app`, `hc`, from herdr.dev's installer), git, worktrunk (`wt`) ≥ 0.80.0, [beads](https://beads.gascity.com/) (`bd`), fzf, jq, and the review tool, [tuicr](https://github.com/agavra/tuicr) ≥ 0.26.0. `bercail doctor` checks each one and flags an old worktrunk or tuicr; the installer doesn't upgrade one that is already there.

worktrunk and beads install the same way: skip if present, else mise, else Homebrew (`brew install worktrunk` / `brew install beads`), else upstream (worktrunk's GitHub release; the [beads installer](https://raw.githubusercontent.com/gastownhall/beads/main/scripts/install.sh), which puts `bd` in `/usr/local/bin` when writable, else `~/.local/bin`).

The desk agent: [Pi](https://pi.dev) (mise), 1.5.1+, with `npm:pi-claude-bridge@0.12.0`; the bridge runs `claude` on your Claude plan, so a Claude plan needs `claude` installed and signed in too.

## platforms

**Omarchy.** mise first, `omarchy pkg add`, optional `SUPER+ALT+RETURN` → open or focus the Herdr app, and a post-update hook (`~/.config/omarchy/hooks/post-update.d/bercail.hook`, when `omarchy-hook-install` exists): after `omarchy-update`, it fast-forwards the clone bercail was installed from and runs `bercail update` without prompting (each question takes its default, no). It acts only on a git clone, so curl and mise/packslip installs skip it (update those with `bercail update` or `mise up`). It skips with one line when offline, dirty, off master/main, or diverged. Herdr updates itself; `bercail doctor` says when a downloaded Herdr waits on a window restart. A post-boot hook (`~/.config/omarchy/hooks/post-boot.d/bercail-desk-restore.hook`) brings back [the desks that were running](config.md#desks-after-a-reboot) once Herdr opens.

**Linux with a systemd user manager** (not Omarchy). The `bercail-desk-restore.service` user unit does the same.

**Ubuntu.** mise first, else Homebrew if present, else apt (`git fzf jq curl`); worktrunk, beads, tuicr from upstream.

**macOS.** mise first; Homebrew stays on PATH as fallback (`brew shellenv`, then mise shims prepended).

**Hyprland.** Optional `SUPER+ALT+RETURN` that launches the Herdr app (focus-if-open is Omarchy only).

The `SUPER+ALT+RETURN` patch asks first; `--yes` says yes to it.
