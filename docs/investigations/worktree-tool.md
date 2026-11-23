# Worktree tool

**Research**, for bercail-ym32. Checked on 2026-11-22 against
[`077a6c4`](https://github.com/simoncrypta/bercail/commit/077a6c478ec30ed8d39f75f781de5ac272325fba),
with worktrunk 0.82.0 installed (0.83.0 is the latest release), Herdr app
0.1.16, hc 0.1.21, Entire 0.13.4 and gh stack 0.2.1.

Simon picked the explicit spawn on 2026-11-22 (Q380), with project `pre-start`
hooks run for desks and slash branches named `Feat-x`. Changes 1 to 5 below
were then built on the same branch. The exclude is `.beads/*` and `.bercail/*`,
not the folders: before worktrunk 0.81 a folder holding tracked files is not
excluded, and LeftLane's mise pins wt 0.67.0. The spawn also takes back what the
copy adds under them, whatever the config says. bercail-wc1 was found done in b85fab8. Not
built: `wtc`'s raw `git worktree add`, `_shep_handoff_path`'s guess, and the
LeftLane stack parent.

Recommendation: keep worktrunk, and change how bercail calls it. None of the
recent worktree-layer bugs was worktrunk's fault. They come from bercail
rebuilding what worktrunk already decided (the checkout's path, the space's
name), from a background hook and the spawn both making a space, and from a
shipped copy hook that copies state stores along with `node_modules`. A desk's
spawn should call `wt switch --create --no-hooks` and then run the steps it
wants itself, in order, where it sees their errors. A person's `wt switch`
keeps the hooks. Plain `git worktree` for spawns is the next step only if
`wt switch` itself breaks bercail again.

## What bercail uses worktrunk for

| Use | Where | What it relies on |
| --- | --- | --- |
| Make a desk's worktree | `skills/handoff/scripts/handoff-spawn:672-678` | `wt switch --create <branch> [--base X] --no-cd`. worktrunk picks the path from its `worktree-path` template, per project if set. The live config nests Lesentiel (`~/Work/lesentiel/<branch>`). Everything else is the sibling `<main>.<branch \| sanitize>`. |
| A PR's branch | `handoff-spawn:299` | `wt switch <branch> --no-cd` on a branch that already exists. |
| Find the new path | `handoff-spawn:321-335` | Not from worktrunk: `git worktree list`, else a hand-built `${main}.${branch}`. |
| Copy ignored files | `config/worktrunk/config.toml:1-2` | User `pre-start` hook `wt step copy-ignored`, blocking. With no `.worktreeinclude` it copies every ignored file except worktrunk's built-in excludes (`.entire/`, VCS dirs, nested worktrees). |
| Open the Herdr space | `config/worktrunk/config.toml:4-17` | User `post-start` hook, which worktrunk runs in the background and logs under `.git/wt/logs/`. It names the space `{{ branch \| capitalize }}_{{ repo \| capitalize }}` and calls `wt_herdr_layout_create`. |
| Close the space | `config/worktrunk/config.toml:19-24` | User `post-remove` hook, for a person's `wt remove`. |
| Shell helpers | `config/shell/bercail.inc.sh:18-46,117-126,213` | `wt list --format=json` (both schemas), `wt switch`, `wt remove --force` for `wtc`, `wts` and `wtd`. |
| Shell integration | `config/bash/bercail.sh:8`, `config/zsh/bercail.zsh:7` | `wt config shell init`, so `wt switch` can `cd`. |
| Install and doctor | `lib/deps.sh:232-292,564-566`, `lib/deps.json` (min 0.80.0) | mise, then brew, then GitHub's `releases/latest`. The config is deployed once and kept after that (`lib/config.sh:756-760`), with one in-place migration (`lib/config.sh:489`). |

What bercail already does itself, without worktrunk:

- The space and its desk. `handoff-spawn` makes the main checkout's space
  (`:656`), then starts the desk through `wt_herdr_handoff_agent` (`:759`),
  which finds or makes the space by folder under a per-checkout `flock`
  (`config/worktrunk/herdr-layout.sh:46,180-205`). `WT_HERDR_NO_DESK=1` only
  stops the hook from starting a second desk. The hook still makes the space.
- The space's name, in `_wt_generate_session_name` (`herdr-layout.sh:62`). It
  parses the folder name, separately from the hook's template.
- The dirty copy (`handoff-spawn:99-117`), the beads redirect that undoes the
  copied Dolt store (`skills/handoff/scripts/handoff-stages.sh:76-99`), and stack
  tracking for gt, gh and origin (`handoff-spawn:156-279`).
- Removal. `bercail cleanup` runs `git worktree remove` itself
  (`lib/cleanup.sh:179`) after archiving `.bercail/` (`:166`), and SHEP.md
  forbids `wt remove` (`shep/SHEP.md:383`). The reason was lesentiel-n8u:
  Shep's `wt remove` of 12 worktrees deleted their ignored evidence.
- Every later lookup goes through `git worktree list`: `git_backend_main`,
  `mainOf` in `lib/shep-task.ts:215`, and the Herdr worktree mod.
- Client installs (`lib/deps.sh:520`) do not install worktrunk. Worktrees are
  made on the backend machine, so the choice here does not touch a laptop.

## The issues on record, and whose they are

| Issue | What happened | Whose | Evidence |
| --- | --- | --- | --- |
| bercail-3rjp (landed, 077a6c4) | Lesentiel trail:83 ended "partial visible creation". A bare Pi then came up in the space. | bercail and Herdr | worktrunk's switch finished, and its post-start hook logged `Herdr space 'Foldkit-ui_Lesentiel' ready` at 15:26:00Z. That echo prints whatever happened (`config/worktrunk/config.toml:13-15`). The spawn's line followed at 15:26:02Z with no desk. A plausible cause: the bercail-desk mod starts a desk in any shown space with none (`bercail/mods/bercail-desk/main.js:560-575`), outside the spawn's lock, and the spawn's create-only start refuses a space that has one (`herdr-layout.sh:221`). Not proven. 077a6c4 fixed the recovery, not the creation. |
| bercail-2krl | Dispatch refuses a task whose earlier desk was cleaned up. | bercail | `records()` marks a record unresolved when its path is gone (`lib/shep-task.ts:236`). Cleanup does not write down that it retired the checkout. Any worktree tool would hit this. |
| bercail-qsvn | `--base <sha>` or `--base origin/master` made a local branch named after it. | bercail (gh stack glue) | `handoff_track_gh` passes the base to `gh stack init` as a branch name (`handoff-spawn:256`). Real `wt switch --create z --base <sha>` in a scratch repo made only `z`. |
| bercail-wc1 | A stray `gt` call auto-initialized Graphite, and `gt track` hung the spawn. | bercail (gt glue) | Fixed in b85fab8 (detection and bounded `gt`), but the issue is still open. |
| bercail-aywz | Cleanup refuses a commit that landed replayed with different context lines. | bercail | `git cherry` in `lib/cleanup.sh:39` compares patch ids, and the context lines changed them. |
| Sibling-path naming | Four places rebuild worktrunk's path or name. | bercail | `handoff-spawn:331` and `_shep_handoff_path` (`lib/shep-context.sh:243`) assume `<main>.<branch>`. `wtc` makes `${repo_root}.${branch}` with raw `git worktree add` (`bercail.inc.sh:109`), which skips the template, the copy and the hooks. In a scratch repo, `feat/x` lives at `r.feat-x` while the fallback looks for `r.feat/x`. Its space is `Feat/x_Bercail` from the hook but `Feat-x_Bercail` from `_wt_generate_session_name`. `v0.18-fix` gives `V0.18-fix_Bercail.v0`. |
| 14c7633, and this worktree | Every new worktree carries a copy of the main checkout's ignored state. | bercail's shipped config | This worktree got 1.1 GB of ignored files. That is 884 MB of `node_modules` (wanted), 190 MB of `.beads` Dolt store and backups (bd then wrote there until the redirect), and main's `.bercail/verify/` from 2026-11-11, which `bercail cleanup` would archive as this worktree's evidence. btrfs reflinks keep the disk cost near zero. The cost is wrong state, not space. |
| lesentiel-n8u | `wt remove` deleted ignored evidence. | worktrunk, working as designed | `wt remove` deletes the folder, ignored files included. bercail answered with `bercail cleanup`. |
| bb43739, acded55 | Shell helpers broke on `wt list --format=json`'s schema change. It took two fixes. | worktrunk churn | 0.80.0 changed the shape. bercail now reads both. |
| 2b4b038 | The install fallback asked for release assets that no longer existed. | worktrunk churn | Fixed for the current asset names. |
| (no issue) | LeftLane's project `pre-start` runs `gt track --parent main` before `handoff_track_graphite`, which leaves a branch alone once `gt parent` succeeds. So a `--base` stack there may end up on trunk. | worktrunk hooks and bercail glue | `~/Work/leftlane_app/.config/wt.toml`, `handoff-spawn:156-180`. Inferred, not run, since this desk does not run `gt`. One `--base` spawn in leftlane_app, then `gt parent` there, would settle it. |

`bercail shep mistake list` has no other worktree-tool entries. The rest are
about the process, tests and scratch paths.

What worktrunk costs bercail: it ships about weekly, and 0.80, 0.81 and 0.82
each list breaking CLI changes. bercail installs whatever is latest, and its
contract (switch, list, three hook templates) has no test against a real `wt`.

## Options

**Keep worktrunk and fix the glue.** Fixes the naming, the guessed paths and
the copied state. Costs a few small changes. Risk: worktrunk keeps shipping
breaking changes, and the background hook still races the spawn.

**Keep worktrunk, with an explicit spawn.** The spawn runs
`wt switch --create --no-hooks --no-cd`, so worktrunk still picks the path,
Lesentiel's nested layout included. Then it runs, in order, what the hooks
did: `wt step copy-ignored` with bercail's excludes, the project's own
`pre-start` hooks if the repo has them, then the space and the desk. It reads
the path back from `git worktree list`.

- Fixes: one space creator per spawn, errors on the spawn's stderr instead of
  `.git/wt/logs/`, and less of worktrunk's hook behaviour can change under
  bercail.
- Costs: one small change to `handoff-spawn` and the hook, and the tests that
  pin the hook path.
- Risk: it narrows the bercail-3rjp race but does not close it. The desk mod
  can still start a desk in a new space that is shown for a moment
  (`herdr-layout.sh:192-197`, `bercail-desk/main.js:560-575`).

**Plain `git worktree` for spawns only.** People keep `wt`, its helpers and
hooks. The spawn runs `git worktree add` itself, and can call
`wt step copy-ignored` at first.

- Fixes: everything the explicit spawn fixes, and `wt switch` changes stop
  reaching spawns at all.
- Costs: bercail must compute each repo's path itself, so Lesentiel's nested
  layout needs a second setting beside worktrunk's. The project's setup hooks
  stop running for desks unless bercail runs them, and LeftLane's are the
  team's.
- Risk: a person's `wt switch --create` and a desk's spawn make checkouts that
  differ in path or setup.

None of the issues above is fixed by this, beyond what the explicit spawn
already fixes. It is the next step if `wt switch --create` or its path
template breaks bercail again.

**Herdr's worktree mod.** Herdr 0.1.16 ships one (`~/.config/herdr-app/mods/worktree`).
It is a dialog in the window: new, open and remove over plain `git worktree`,
under `~/.herdr/worktrees/<repo>/<slug>`, with no hooks, no copy and no
command a script can call. Its remove uses `--force` on a dirty checkout,
which bercail cleanup exists to refuse. It confirms Herdr's model (a worktree is
a folder, and a space follows the folder), and bercail already matches spaces by
folder. It cannot replace the spawn.

**Entire.** `entire trail checkout <trail> --worktree` checks out a trail's
branch into a worktree under `.entire/worktrees` in the main checkout. It
copies ignored files that match `.worktreeinclude`, and prints only the path
when stdout is not a terminal. It works only for a branch a trail already
has, it needs entire.io and the keyring, and its path differs from every
other desk's. It could serve adopting an existing trail branch in an Entire
repo. It does not replace the spawn for beads or gh jobs.

**Graphite, gh stack, origin.** None makes worktrees. Graphite's docs say gt
"fully supports multiple Git worktrees" and since 1.8.4 leaves branches checked
out elsewhere alone. `gh stack checkout` switches the current checkout, and
finds a worktree that already holds the branch. `origin` has no worktree
command.

**Other tools.** jj workspaces are not git worktrees: jj's docs list
git-worktree as unsupported and say the staging area is ignored. bercail's review
is the staged tree, and `bercail land` pins `git write-tree`, so jj is out.
git-town (v24.2.0) and git-branchless (v0.11.1, May 2026) manage branches,
not checkouts. git-town has open issues about running inside worktrees.
Neither fits.

## Recommended changes

In order of value. Each is its own small job with a failing test first.

1. **An explicit spawn.** `wt switch --create --no-hooks --no-cd`, then the
   copy, the project's `pre-start` hooks, the space and the desk, as above.
   The post-start hook stays for a person's `wt switch --create`. Before
   calling 3rjp's cause fixed, check in a real window that the desk mod cannot
   claim the new space during a spawn.
2. **Look the path up, never guess it.** After either switch, use
   `handoff_worktree_of` (`handoff-spawn:182-189`), which reuse and adoption
   already use, and drop the `${main}.${branch}` fallback. `wtc`'s raw
   `git worktree add` goes through `wt switch`. `_shep_handoff_path`
   (`lib/shep-context.sh:243-249`) uses the record's `repo` when it has one.
3. **One name function.** The post-start hook and the spawn both call
   `_wt_generate_session_name`, and it takes the branch from git and the repo
   from the main checkout in every layout. Post-remove keeps closing by folder.
   Git cannot name a checkout that is already gone, so its fallback label keeps
   using the hook's own variables.
4. **Copy what a desk needs, not the state.** Add `[step.copy-ignored] exclude`
   for `.bercail/`, `.wrangler/` and the beads store to the shipped config,
   with a migration, since installs keep their own copy. Keep the beads
   redirect until a test shows bd finds the main store without it.
5. **Pin the contract.** A live bats test against a real `wt`, at the
   supported floor (0.80.0) and the latest: `switch --create --no-hooks`,
   `--base <sha>`, switching to an existing branch, list JSON, and the hook
   variables bercail reads. Run it when the deps tracker opens a worktrunk
   issue.

The bugs that are not worktrunk's (2krl, qsvn, aywz, and the LeftLane stack
parent) stay on their own issues. bercail-wc1 looks done in b85fab8 and could
be closed.

## Open questions

Settled since: desks run the project's `pre-start` hooks, and spaces are
`Feat-x`, both Simon's picks. A bare `project:` filter runs only the project's
hooks, and bd 1.3.1 in a linked worktree with no copied store reads the main
store. Both were observed on the real tools.

- LeftLane's hook still tracks the branch on trunk first, so a `--base` stack
  there needs `handoff_track_graphite` to set the parent even when
  `gt parent` already answers. Not checked, since this desk does not run `gt`.
- What made the trail:83 desk start fail is inferred, not reproduced.

## Private source records

Raw output for this page (versions, the scratch probes, the trail:83 hook log
and handoff lines, the ignored-file sizes, the config diff) is in this
worktree's ignored `.bercail/worktree-tool/evidence.txt`. `bercail cleanup`
moves it to `~/Work/worktree-archives/bercail/` when the worktree is retired.
