# development

## Hacking on bercail

```bash
bash tests/lint.sh            # shellcheck -S warning and the printf | grep -q check on every tracked shell file, vp check, and the mods' lint
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

The tree has no shellcheck warning and passes `vp check`, and [CI](#ci) keeps it that way. Each test runs under a 5-minute `BATS_TEST_TIMEOUT`, so one hung test fails itself instead of the whole job. `tests/run.sh` runs files and tests side by side, two jobs per core of its [slot's](#test-slots) share (`BATS_JOBS=N` sets the count). With [GNU parallel](https://www.gnu.org/software/parallel/) installed, bats spreads the tests over them. Without it, a quarter that many files run at once, each in its own bats run (`xargs -P`) with its tests 4 at a time (fewer when the count is under 4), and a file's output shows once it is done, the full log only when it failed. That run takes under 2 minutes on 16 cores. The live proofs always run one at a time.

### Test slots

Several desks running the suite at once gain nothing and fail timing tests: three full runs on 16 cores pushed the load average to about 300. So `tests/run.sh` and the [verify-bercail](../.agents/skills/verify-bercail/SKILL.md) run each take one of the machine's test slots first, `[tests] slots` in `~/.config/bercail/config.toml` (2), and a run started while all of them are taken waits for one:

```
tests/run.sh: waiting for a test slot; all 2 ([tests] slots) are taken by:
  tests/run.sh in /home/you/Work/bercail.fix, desk t3, pid 4120, since 21:30:05
  verify-bercail in /home/you/Work/bercail.docs, desk t7, pid 4388, since 21:31:40
```

It starts once one frees, in no set order, and gives up after 30 minutes (`BERCAIL_TEST_SLOT_WAIT`, in whole seconds) with a line that says so. Only these runs wait: desks start, read and call their models as before. A run inside one that holds a slot, such as the verify run's suite, takes none. A slot is a file in `bercail/test-slots/` under `XDG_STATE_HOME` (`~/.local/state`) that `flock` holds for the run, outside the run's children, so a process a test leaves behind cannot keep it. The pid in a holder's line is the run's: when it ends, killed or not, its slot frees at once. Ctrl-C in its terminal stops the whole run. `bercail doctor` lists who holds a slot and who waits, on a machine where a test run made that folder. Each run sizes itself to its share of the cores, the cores divided by the slots: two bats jobs per core of it (`BATS_JOBS` overrides that) and one Vitest worker per core of it. Without flock (macOS) nothing waits, and the share still applies. CI runs one suite on its machine, so it sets `slots = 1` unless the runner has a bercail config of its own.

`bercail update` is the source tree's own `bin/bercail` deploying itself (`update_from_tree`): the installed copy finds the tree it was installed from, a clone or a package, and runs that tree's `bercail update`. A curl install has no such tree, so it first downloads the release as one archive and unpacks it over `~/.local/share/bercail/release` (`fetch_release_tree`). So the code that deploys a release is always that release's, and a release can add a file or a deploy step without naming it anywhere: every file in `lib/`, `bstack/` and a skill's folder is installed. `BERCAIL_LIBS` in `lib/common.sh` is the one list of the libs every command loads.

v0.15.0 is the first release whose update works this way, and the oldest that updates straight to this one. v0.14.0 and older copied the new files by their own lists and stop on one this release no longer ships, so they reinstall ([install](install.md#updating-from-an-older-release)). `tests/desk_upgrade.bats` installs v0.15.0 and the latest `v*` tag into a throwaway HOME and updates each from this tree as a clone install, and v0.15.0 also as a curl install whose stand-in `curl` serves this tree as the archive. It also reinstalls this tree over v0.14.0. It needs the release tags (`git fetch --tags`; CI checks out with full history).

The tests are [bats-core](https://github.com/bats-core/bats-core) (pinned in `package.json`), one `@test` per case, each runnable alone; `skills/unit-testing` has the rules. A test file's `setup` calls `isolate` (`tests/test_helper.bash`), which gives every test its own `HOME`, with the `XDG_*` dirs and `TMPDIR` under it. `tests/run.sh` drops every inherited `GIT_*` variable (an inherited `GIT_DIR` sends fixtures' commits, branches and config to the repo it names) and sets `GIT_CEILING_DIRECTORIES` to the temp dir bats runs in, so no fixture finds a repo above it; it does this first, since bats reads each test file before any setup runs. `tests/setup_suite.bash` drops them again for a bare `bats` run, with the desk's `HC_*`, Herdr, bercail and beads variables, sets `TZ=UTC` and `LC_ALL=C.UTF-8`, takes mise's shims and command wrappers off `PATH` and unsets `BASH_ENV` (each runs the real mise, which reads the test's `HOME` or reaches past a stand-in), and shadows the desktop commands (`omarchy`, `hyprctl`, `fcitx5`, `notify-send`, ...) with stubs; the run fails if a test calls one. `tests/suite.bats` fails if a test file skips `isolate` or a desk variable reaches a test, and `isolate` fails a test whose `PATH` has a mise shim or wrapper dir again, whose `BASH_ENV` is set, or that a `GIT_*` variable reaches before it sets its own. `setup_suite` and `isolate` set the same ceiling from the run's temp root, for a bare `bats` run and a nested one. `tests/setup.ts` drops `GIT_*` for Vitest and sets the ceiling to the temp dir. To run the suite on a copy of a checkout, use a `git clone --no-local` of it with the diff applied: a `cp -a` of a worktree copies its `.git` pointer to the real repo. A test that cannot run without a tool says so with `need node` (or `unavailable "<why>"`): it skips when the tool is missing, except under `CI`, where it fails, so a test never goes unrun there without anyone seeing. `isolate` also puts a `node` stand-in in `$BATS_TEST_TMPDIR/bin` that fails until the test says `need node`: a dev box has Node in `/usr/bin` and the CI runner does not, so a test whose PATH is its stand-ins and `/usr/bin:/bin` would otherwise pass locally and fail in CI. `tests/run.sh` (unit and `--live`) puts every test's temp files under one temp dir of its own and, once the run ends, fails it when a test wrote your real state or left a process running. Shep and other desks write most of that state during a run, so a file under `~/.local/state/bercail` (Shep's inbox with it), `~/.config/bercail` or `~/.config/herdr-app` counts only when it changed during the run and names that dir; Shep's and desks' Pi transcripts are left out, since they may quote the run's output. `handoffs.jsonl` is append-only: a line it had that changed or went fails the run. A file added, removed or changed (size or mtime) under `~/.config/herdr-core` fails it whoever wrote it: if you edited a template or ran `bercail update` during the run, run again. A process left running counts when its environment or working dir names the run's dir, such as a stub left in the background or the Herdr core an `hc` call with no stand-in starts; the run names it with its pid and command. It only reads your state and signals nothing. A write that names no path of the run, outside those two, and a process with neither, go unseen; an unrelated process that names the run's dir would be listed.

`tests/handoff_beads.bats` checks that a handoff worktree writes to the main checkout's beads store in two ways. The tests on the real `bd` prove that bd follows the redirect bercail writes. CI installs bd with mise, as `bercail update` does, at the version pinned in `.github/workflows/ci.yml` (`BD_VERSION`). The tests on a fake bd check what bercail hands bd from the worktree and run everywhere.

The TypeScript and JavaScript tooling is [Vite+](https://viteplus.dev) (`vite-plus`, pinned in `package.json`; the config is `vite.config.ts`). `vp check` formats with Oxfmt (TypeScript and JavaScript only; prose, data, and the two copies of Herdr's mods keep their own layout), lints with Oxlint, and type-checks against `tsconfig.json`, Pi extensions included: Pi's own packages are devDependencies for their types, and Pi still loads the `.ts` files as they are. Herdr loads the mods as plain JavaScript, so they stay JavaScript, and `tests/lint.sh` lints them with `bercail/mods/lint.config.ts`, which has no type pass: the `jsconfig.json` that `herdr-app check` writes beside a mod would otherwise make that pass differ between your checkout and CI.

The Pi extensions' unit tests and the Worker's are Vitest (`tests/*.test.ts`, run by `vp test`, which `tests/run.sh` runs after bats when it is given no arguments). `tests/setup.ts` gives each test file the same cut-off as bats: no desk variables, `TZ=UTC`, and a `HOME` and `XDG_*` dirs of its own. Use Node 26. The live proofs (`desk_model_pi`, `desk_session_pi`, `pi_guard`, `pi_fallback`, `review_pi`, `shep_context`, `shep_pi`) are TypeScript files that Node runs as they are (`tests/*_live.ts`). They run the extension in the installed Pi, offline, with a stand-in model, without sending a model prompt or changing your sessions. They are tagged `live`: `tests/run.sh` leaves them out and `tests/run.sh --live` runs only them. `real_pi` fails a test that is not tagged `live`. A proof that drives Pi's TUI gets a terminal from util-linux `script` (`tests/live_term.ts`), so those proofs need Linux.

`site/` is bercail.dev: an Astro site served by the `bercail-site` Worker, which also serves `/install.sh` from the latest release's tag. The proxy is `site/github.ts`.

## ci

`.github/workflows/ci.yml` runs on each push to master or any other branch, each PR, and each `v*` tag. A branch's run is the one [`bercail land`](cli.md#install--cli) waits for before Shep pushes the branch to master. Two jobs run side by side, and each starts with the setup in `.github/actions/setup` (Node 26, `npm ci`, and the mise tools the job names):

- `lint` runs `tests/lint.sh`: shellcheck, at the version pinned in `SHELLCHECK_VERSION`, then `tests/lint_grep_q.sh` (`printf … | grep -q`), then `vp check` and the mods' lint. It takes about 50 seconds, most of it shellcheck. It then warns, without failing, when the [dependency tracker](#dependency-tracker) has not succeeded in 3 days.
- `test` runs `tests/run.sh` with GNU parallel: the bats suite, then `vp test`. It takes 2.5 to 3.5 minutes on the free 4-vCPU runner, nearly all of it the bats run. bd comes from mise at the version pinned in `BD_VERSION`, and the checkout has full history for `tests/desk_upgrade.bats`.

`deploy` runs only for a `v*` tag, after both jobs pass, and deploys the site and the Workers when `CLOUDFLARE_API_TOKEN` is set. A newer push to the same branch or PR cancels the older run, on master too, so several merges in a row test only the last one. A tag run is never cancelled.

Every action is pinned by its full commit SHA, with the release tag in a comment beside it (`actions/checkout@<sha> # v7.0.1`), so a moved tag cannot change what runs. To update one, take the new tag's commit SHA and change both; the dependency tracker's issue for it names the SHA.

The caches: setup-node caches npm's download cache, keyed on `package-lock.json`. mise-action caches mise's data dir under a key that holds the job's tool specs, so changing a pin installs fresh, and it saves the cache after the job installs the tools. A hit saves 5 to 10 seconds of setup. Vite+ has no cache in CI. On the runner, `vp check` takes about a second and `vp test` under one, so its task cache, or the Oxlint and Vitest caches, would save at most a second or two on a run that waits about 2 minutes for bats.

### A bigger test runner

The `test` job runs on the label in the repo variable `CI_TEST_RUNNER`, and on `ubuntu-latest` when the variable is unset. `tests/run.sh` runs two jobs per core (CI sets `[tests] slots = 1`, so its one run gets them all), so more cores make the suite faster without any other change. Locally, the bats run takes 65 seconds on 4 cores, 38 on 8, and 28 on 16, so 8 cores is about where it stops paying.

GitHub's larger runners need an organization on GitHub Team or Enterprise Cloud. A personal account such as `simoncrypta` cannot have them, and they are billed per minute even on a public repo: Linux 8-core costs $0.022 a minute and 16-core $0.042, and GitHub rounds each job up to the whole minute ([pricing](https://docs.github.com/en/billing/reference/actions-runner-pricing)). To turn one on, create it in the organization's settings (Actions, Runners, New runner), give this repo access to its runner group, then set `CI_TEST_RUNNER` to its name under Settings, Secrets and variables, Actions, Variables. A third-party runner's label works the same way. To go back, delete the variable.

## releasing

master is unreleased trunk: merge to it freely. A `v*` tag is the release.

1. Bump the version in `lib/common.sh`, `manifest.json`, and the README's release link and pin.
2. Tag the commit `v<version>` and push the tag.

The tag runs `release.yml`, which publishes `bercail.tar.gz` and its signed packslip bundle as a GitHub release, and CI, which tests the tag and deploys bercail.dev. Within a minute of the release, bercail.dev serves `/install.sh` from the new tag, pinned to it (`BERCAIL_RELEASE`), so a curl install downloads that tag's archive (`https://github.com/simoncrypta/bercail/archive/<tag>.tar.gz`, not the `bercail.tar.gz` asset, whose marker says mise or packslip owns the command). A curl install's `bercail update` reads the latest release the same way. Neither reads master. If github.com is down, the Worker keeps the last tag it saw, or answers 503; it never falls back to master.

To try unreleased work through the curl path, take `install.sh` and the files from the same ref: `curl -fsSL https://raw.githubusercontent.com/simoncrypta/bercail/master/install.sh | BERCAIL_REF=master bash`. `BERCAIL_REF` takes a tag, branch, or sha, and works for `bercail update` too; `BERCAIL_ARCHIVE_URL` names another archive of the tree, with one top folder.

## dependencies

Installed if missing: the [Herdr app](https://herdr.dev) with herdr-core (`herdr-app`, `hc`, from herdr.dev's installer), git, worktrunk (`wt`) ≥ 0.80.0, [beads](https://beads.gascity.com/) (`bd`), fzf, jq, and the review tool, [tuicr](https://github.com/agavra/tuicr) ≥ 0.29.0. `bercail doctor` checks each one and flags an old worktrunk or tuicr; the installer doesn't upgrade one that is already there.

worktrunk and beads install the same way: skip if present, else mise, else Homebrew (`brew install worktrunk` / `brew install beads`), else upstream (worktrunk's GitHub release; the [beads installer](https://raw.githubusercontent.com/gastownhall/beads/main/scripts/install.sh), which puts `bd` in `/usr/local/bin` when writable, else `~/.local/bin`).

The desk agent: [Pi](https://pi.dev) (mise), 1.5.1+, with `npm:pi-claude-bridge@0.13.0`; the bridge runs `claude` on your Claude plan, so a Claude plan needs `claude` installed and signed in too.

Only with `[bstack] statechart = true`: tla-ts, with `npm ci` from `lib/statechart/package-lock.json` into `~/.local/share/bercail/statechart/`. See [statecharts](bstack.md#statecharts).

### Dependency tracker

`lib/deps.json` lists each tool bercail installs or pins, plus jq and fzf, the CI tools, the npm devDependencies and the actions. Each entry has:

- `name`, which names the tool's issue and its label.
- `source`, where its releases are read: `github:<owner>/<repo>` (releases/latest, which skips prereleases and drafts), `action:<owner>/<repo>` (the same, plus the tag's commit), `npm:<package>`, `herdr:app` or `herdr:core` (`releases.herdr.dev/<app|core>/latest.json`), `node:<major>` (`nodejs.org/dist/index.json`), `git:<owner>/<repo>` (commits on the default branch of `github.com/<owner>/<repo>`, for a vendored copy), or `workerd:<lockfile>` (the Workers compatibility date wrangler gives as the latest: the date in the version of the workerd that lockfile locks, read with no network). Every entry has a feed: a source that cannot be read fails its row.
- `paths`, on a `git:` entry only: the git pathspecs bercail copies, `:!` for one it leaves out. A commit that touches none of them opens nothing. Without `paths`, the whole repo counts.
- `min` and `why`: the oldest version bercail works with, and the reason. `bercail doctor` and bstack read it from here (`dep_min` in `lib/deps.sh`), so a minimum changes in this file only. The docs and `lib/help.sh` name some minimums in prose; change those with it.
- `known`: the version bercail was last checked against. For a `git:` entry, the full commit the copy is at.
- `pinned_in`: the files that pin it. An entry `path:KEY` says the version is written on each line of `path` that holds `KEY` (`.github/workflows/ci.yml:BD_VERSION`, `.github/workflows/ci.yml:actions/checkout`), and each must equal `known`. A bare path is a pointer for the issue body.
- `notes`, for whoever takes the issue: a one-way migration, a version to wait for.

`.github/workflows/deps.yml` runs `.github/scripts/deps-track.sh check` daily at 07:17 UTC, or by hand from the Actions tab. It uses the workflow's own token, with `issues: write`. For each tool, as soon as a stable release newer than `known` is out, it keeps one open issue titled `deps: <tool> <version>` and labelled `deps` and `deps:<tool>`. The issue gives the change from `known`, a link to the release notes, `pinned_in`, the minimum, the notes, and a checklist (new features, workarounds, breaking changes, the minimum). An action's issue also names the commit to pin. A newer release retitles the open issue and comments on it. Setting `known` to the issue's version closes it on the next run. An issue closed by hand while `known` is behind comes back the next day: to hold a version (a one-way migration, say), leave its issue open. A release opens its issue on the first run that sees it, with no wait, and mise's hold does not apply to the tools bercail installs ([install](install.md#mise--packslip-recommended-for-a-manual-install)). A Herdr release's date comes from its `latest.json`'s Last-Modified.

A `git:` entry gets a blobless clone of upstream's default branch, with no checkout; none of its code runs. The target is the newest first-parent commit past `known` that touches `paths`. With none, the copy is current, even when `known` is past the last commit to touch them. With one, the run keeps one open issue titled `vendor: <name> <full commit>` and labelled `deps`, `deps:<name>` and `vendor`. It gives `git log --oneline` and `git diff --stat` of `paths` from `known` to the target, a compare link, `pinned_in` and the notes. The steps for a move are in the copy's `UPSTREAM.md`. A newer target retitles the issue and comments on it. Once `known` is the issue's commit or past it, the next run closes it. The lookup fails when `known`, or an open issue's commit, is not on the default branch: upstream rewrote its history, or `known` is wrong.

A lookup that fails does not stop the others. The run then opens or updates one `deps: tracker failing` issue (label `deps:tracker`), naming each source and its error, and exits 1. The next run where every lookup works closes that issue.

The [deps routine](routines.md#the-deps-routine) brings these issues to Shep: declare a routine with `run = "deps"` at a time after the tracker runs, such as `at = "08:00"`, and Shep is told to open a beads issue for a desk on each version no job covers yet.

`deps-track.sh pins` checks, offline, that each entry has every field (a `git:` entry's `known` a full commit) and that every `path:KEY` pin agrees with `known`. `tests/deps_track.bats` runs it on this tree, so CI fails when, say, `BD_VERSION` moves without `known`. `check` prints the same warnings. `check --dry-run` does the lookups and prints the issue writes instead of making them; with `GH_REPO=simoncrypta/bercail` and your gh login, it shows what the next run would do. To take a new version, read its notes, make the change it needs, then set `known` (and the pin, for a `path:KEY`) in the same commit.

`bstack/pi/extensions/pi-emphasis/` is [pi-emphasis](https://github.com/johnlindquist/pi-emphasis), vendored like the statechart skill below: `index.ts` and `LICENSE` are upstream's, byte for byte, at the commit in its `UPSTREAM.md` and in `lib/deps.json` (a `git:` entry on `index.ts` and `LICENSE`: upstream has no releases or tags). `tests/pi_emphasis.bats` checks that the copy, the record and the manifest agree, and that the copy imports only Pi's types and adds no fetch, key, command or tool. Its live test installs bercail fresh and as an update from v0.17.4, the last release without it, and checks that the deployed lead draws a pill on the installed Pi. Formatting and lint leave it alone (`vite.config.ts`).

## statecharts

`skills/statechart/` is pstack's statechart skill, vendored at the commit in its `UPSTREAM.md`, which also says how to compare the copy with upstream and how to move it. Every file under `scripts/` and `references/` is upstream's, byte for byte, except bercail's `statechart-bstack`, `tla-ts-java`, `pi-chart.mjs` and `graph.ts`. Formatting and lint leave the upstream files alone (`vite.config.ts`). The `pstack-statechart` entry in `lib/deps.json` follows upstream's `pstack/skills/statechart`, less `scripts/test/`, and `pstack/LICENSE`, and `tests/statechart.bats` checks that it and `UPSTREAM.md` name the same commit.

`tests/statechart/shep-inbox/` is the model of Shep's inbox (`shep/pi/inbox.ts` and the follower in `lib/notify.sh`). After a change to the spec, a config or the view, or to the inbox code it models, run its `check.sh` (it needs tla-ts, so `[bstack] statechart = true` or `TLA_TS`, about 30 seconds). It checks every config: the ones for the real code hold every rule, and each planted bug (`bug-*.cfg`) breaks the rule it targets. Then it rewrites `chart/` (what Simon checks), `graph.json` and `sha256sums`. A test in `tests/statechart.bats` runs it in a copy on tla-ts, in CI on every push (the `tla-ts` step installs it from the same lockfile), and fails when the copy differs from the repo. `tests/shep_inbox_statechart.test.ts` runs on every `vp test`, with no model checker. It replays every step of `graph.json` (`replay.cfg`: one Shep, two sessions, a notice) on the real `inbox.ts`, and after each one compares what `inbox.ts` decides with the model: where each event is, its delivery attempt and receipt, what it queues in Pi, and whether it runs or pauses. Two Sheps and the consumer lock are checked in the model only. It also fails when `sha256sums` no longer matches the spec, the configs or the view. A replay that fails after a change to `inbox.ts` means the code and the model disagree: fix the one that is wrong, then rerun `check.sh`.

To bump tla-ts: change its version in `lib/statechart/package.json`, run `npm install --package-lock-only --ignore-scripts` in `lib/statechart/`, set `known` in `lib/deps.json`, and run `tests/statechart/cross-check.sh` with `TLA2TOOLS` (tla2tools.jar 1.7.4) and `JAVA` on bercail's specs and any others you keep. It installs the tla-ts the new lockfile pins and prints its version, so it tests the bump, not the tla-ts you have. Take the bump only when every config is the same on both.

## platforms

**Omarchy.** mise first, `omarchy pkg add`, optional `SUPER+ALT+RETURN` → open or focus the Herdr app, and a post-update hook (`~/.config/omarchy/hooks/post-update.d/bercail.hook`, when `omarchy-hook-install` exists): after `omarchy-update`, it fast-forwards the clone bercail was installed from and runs `bercail update` without prompting (each question takes its default, no). It acts only on a git clone, so curl and mise/packslip installs skip it (update those with `bercail update` or `mise up`). It skips with one line when offline, dirty, off master/main, or diverged. Herdr updates itself; `bercail doctor` says when a downloaded Herdr waits on a window restart. A post-boot hook (`~/.config/omarchy/hooks/post-boot.d/bercail-desk-restore.hook`) brings back [the desks that were running](config.md#desks-after-a-reboot) once Herdr opens.

**Linux with a systemd user manager** (not Omarchy). The `bercail-desk-restore.service` user unit does the same.

**Ubuntu.** mise first, else Homebrew if present, else apt (`git fzf jq curl`); worktrunk, beads, tuicr from upstream.

**macOS.** mise first; Homebrew stays on PATH as fallback (`brew shellenv`, then mise shims prepended).

**Hyprland.** Optional `SUPER+ALT+RETURN` that launches the Herdr app (focus-if-open is Omarchy only).

The `SUPER+ALT+RETURN` patch asks first; `--yes` says yes to it.
