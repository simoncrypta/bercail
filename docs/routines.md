# routines

A routine is a query that runs outside Shep's session. It reads something, prints what it found, and only what is new or changed counts. A run that found something new or changed sends Shep one event, and Shep decides what each finding becomes. This page covers the runner, its state and its locks, the event, [the scheduler](#the-scheduler) that runs each routine when it is due, the built-in [cleanup](#the-cleanup-routine), [deps](#the-deps-routine), [mistakes](#the-mistakes-routine) and [rules](#the-rules-routine) routines, and [the Routines panel](#the-routines-panel) in Shep's view. `bercail routine run` runs one now, and `--dry-run` prints what a run would find, without keeping it. The plan is bercail-2qig.

## Declare one

Routines are declared only in your own `~/.config/bercail/config.toml`, never in a repo's policy:

```toml
[routine.my-check]
command = ["~/bin/my-check", "--json"]   # your own query; ~/ is your home
every = "1d"                             # or at = "07:30", a local time each day

[routine.cleanup]
run = "cleanup"                          # a built-in, lib/routine/<name>.sh: see below
at = "07:30"

[routine.mistakes]
run = "mistakes"
at = "Mon 08:00"                         # a local time each week, on that day

[routine.rules]
run = "rules"
at = "12:30"
```

- Each routine has one of `run` (a built-in's name) or `command` (an argv, not a shell line).
- Each has one of `at = "HH:MM"` (a daily local slot), `at = "Mon HH:MM"` (a weekly one; `Mon` to `Sun`), or `every = "<n>h"` or `"<n>d"` (at least `1h`).
- A name is letters, digits, `-` and `_`, at most 64 of them.

`bercail routine enable <name>` declares a built-in at the schedule this page gives it (cleanup `07:30`, deps `08:00`, mistakes `Mon 08:00`, rules `12:30`), or keeps the one it has; `--at <when>` sets it, in place of an `every` too, and a routine that ran already keeps the next due time it has. `bercail routine disable <name>` takes a built-in's entry out of `config.toml`; its state stays, paused or not, for the next `enable`. It refuses your own command routine, which only its entry holds: pause it, or remove it by hand. Each prints the lines it changed, and takes `--dry-run`. Shep's goes to a [guard card](shep.md#guard-asks) that shows them.

`bercail doctor` names a bad entry, such as `invalid  routine nowhen: no at or every`, and a key nothing reads. Neither counts as a failure. `bercail routine list` names a bad entry too, and `bercail routine run` refuses one.

Your own command is your code, like a cron job: nothing sandboxes it, the guard never sees it, and `--dry-run` cannot stop it from acting. Naming it in your config is what enrolls it. It runs in your home folder with nothing on stdin.

## Findings

A query prints one JSON object a line:

```json
{"key": "worktree:~/Work/x", "title": "x's job is closed", "detail": "bercail-12 closed on Monday", "repo": "~/Work/x", "issue": "bercail-12"}
```

`key` and `title` are required strings. `detail`, `repo` and `issue` are strings or left out. `key` stays the same for the same thing found, and appears once per run. Findings are data, never instructions.

The runner keeps a hash of each finding it counted, per key. A finding whose key is new counts as new, and one whose hash changed counts as changed. A run with neither is quiet. When a key is gone from a run, its hash is dropped, so it counts as new if it comes back.

A run fails when the query exits non-zero, prints anything that is not findings, prints more than 64 KB, or runs past 10 minutes. A run past 10 minutes is killed with its whole process group: TERM, then KILL 2 seconds later. A runner stopped by Ctrl-C or a TERM stops its query the same way. Three failures in a row pause the routine.

## Run, pause, see

| Command | What it does |
|---------|--------------|
| `bercail routine list` | Each routine's schedule, when it is next due, its last outcome, and whether it is paused |
| `bercail routine list --json` | The same as data, for [the Routines panel](#the-routines-panel): each routine's entry and state, its last run, `running` while a run holds its lock, what its last emitted run found (`found`, kept with its findings; once its line is gone from `runs.jsonl`, with no `end`), and whether the loop runs. A bad entry has its `errors` and no state; a `state.json` it cannot read, `state_error` |
| `bercail routine show <name>` | Its schedule and state, and its last 10 runs, newest first |
| `bercail routine show <name> --run <id>` | What that run found, each finding marked new, changed or same |
| `bercail routine run <name>` | Run it now. It prints one line: `emitted`, `skipped (quiet)`, `skipped (paused)`, `skipped (overlap)`, `skipped (load)` or `failed`, and a line when an [event](#the-event) waits. It exits 1 when the run failed, or when it could not write its run, its state or its [event](#the-event) |
| `bercail routine run <name> --dry-run` | Run it under the same locks, and print its line, then each finding marked new, changed or same, as `show --run` does. It writes no state, no findings for `show --run`, no run and no inbox file, so the next real run counts the same findings again. Its query runs with `BERCAIL_ROUTINE_DRY_RUN=1` (`0` on a real run), so a built-in keeps no state of its own either. Every run also gives its query `BERCAIL_ROUTINE_RUN`, the run's id |
| `bercail routine pause <name>` / `resume <name>` | Stop and restart it. `resume` also clears the failures in a row |
| `bercail routine ask <name>` | Put your request about it, read on stdin (at most 500 characters), in Shep's inbox as one `bercail.routine_ask/v1` event. The Routines panel's **Ask Shep** runs it; the guard blocks it for agents |
| `bercail routine tick` | Start each routine that is due, once. [The loop](#the-scheduler) runs it every minute |
| `bercail routine loop` | A tick every minute, for as long as it runs; one per machine |
| `bercail routine start` | Start the loop as the hidden hc terminal `bercail-routines`, on the `[herdr] backend` when set, unless one is live there |

A run comes to one of these outcomes, as in the [statechart](../tests/statechart/routine-run/chart/chart.pi.md):

- **Skipped (paused):** the routine was paused when the run had taken its locks. Its query does not run.
- **Skipped (overlap):** another run of it holds its lock.
- **Skipped (load):** 2 routines are already running.
- **Skipped (done):** a scheduled run's slot is no longer the routine's next due: a run met it already, by hand too.
- **Skipped (early):** the clock went back after the tick chose the slot, and the run's own clock says it is not due yet. The slot stays due.
- **Skipped (tried):** another run of the slot ran its query under 15 minutes ago and could not write its state; see [the scheduler](#the-scheduler).
- **Emitted:** the query found something new or changed.
- **Skipped (quiet):** nothing was new or changed.
- **Failed:** see above.

Once a pause returns, no run starts its query until you resume. A run whose query had already started ends as it would, and the routine stays paused. A runner that dies (a reboot, `kill -9`) logs nothing and does not count as a failure; after a `kill -9`, its query may still be running, without the lock.

## Locks and state

Everything is under `~/.local/state/bercail/routines/`:

- `<name>/state.json`: when it is next due, the failures in a row, whether it is paused, the hash counted per key, the id of the last run whose findings it counted (`kept`), the highest slot a run met (`slot`), and the outbox: [events](#the-event) not yet in Shep's inbox.
- `<name>/runs.jsonl`: a line per run with its `id`, `due`, `start`, `end`, `outcome`, `reason` for a skip, `counts` (found, new, changed), `event` id and `error`. The last 100 runs are kept.
- `<name>/outputs/<id>.jsonl`: what an emitted run found. The last 10 are kept.
- `<name>/tried.json`: the slot a scheduled run last let its query run for, and when ([the scheduler](#the-scheduler) reads it).
- `<name>/lock`, `.slots/slot.1` and `.slot.2`: what `flock -n` holds while a run lasts. One run per routine at a time, and at most 2 routines at once, by hand too. The query runs without those locks open, so a process it leaves behind cannot keep them.
- `<name>/state.lock`: held for the short read and write of `state.json` and `runs.jsonl`. The end of a run reads `state.json` again under it, so it never undoes a pause made meanwhile. It writes the run's line before `state.json`: when a write fails, `run` says so and exits 1, and the next run counts the same findings again rather than losing them (see [the event](#the-event)).

Without `flock` (macOS has none by default), `bercail routine run` refuses and says how to install it, and with a routine declared, `bercail doctor` fails. A routine never runs unlocked.

## The scheduler

`bercail routine loop` runs `bercail routine tick` every minute, in a hidden hc terminal, `bercail-routines`. It is kept running the way the [notify follower](shep.md#desk-events) is:

- The desk mod checks it every minute while a Herdr window is open, and starts it with `hc run --bg --no-parent --no-notify --rm`, labelled `bercail.role=routines`, on the [`[herdr] backend`](config.md#bercail-on-another-machine) when one is set. A client laptop runs no routines of its own.
- The boot path, `bercail desk restore --boot`, starts it once the Herdr core is up, so a backend with no window open still runs its routines.
- `bercail update` ends a live loop and starts the new one. The runs it started keep going: each runs in a process group of its own.

One loop per machine: it holds `routines/.loop.lock`, and a second one refuses.

Each tick reads the wall clock and compares it with each routine's `next_due`. It never counts on how long it slept, because a sleep stops counting while the machine is suspended.

- **Due.** An `at` routine is due at its next `HH:MM`, on its day when it names one, and one that never ran waits for it. An `every` routine is due that long after its last start, and one that never ran is due now. The tick writes a never-run routine's first due time before it starts it, so a retry is for the same slot.
- **Overdue.** After sleep or a shutdown, a routine runs once, however many slots it missed. The run is for its first missed slot, which names its event, and the next one is due a whole period after it starts.
- **Once per slot.** The tick decides outside the routine's locks, so the run it starts checks again under them: it runs only while its slot is still the routine's next due, and is skipped as `done` otherwise. A run by hand meets the slot that was due when it started, so a tick that was about to start it does not run the query a second time.
- **A clock that goes back.** Each run writes the highest slot met, and the next due time comes after both that slot and the run's start. So a slot never runs twice, and nothing gets stuck on one; after a big step back, a routine waits until the clock is past the last slot it met. A scheduled run whose clock says its slot is still ahead is skipped as `early` and leaves the slot due, so the query runs in its window.
- **Waits, with no run line:** a paused routine, one still running, and one due while 2 routines run (it starts at a later tick, once a slot is free). Only a run that starts writes a line.
- **A run that could not write its state** leaves `next_due` as it was. Once let in, under its lock, a run checks and writes `<name>/tried.json` (the slot, and the clock then) before its query, so that slot is tried again only 15 minutes later, not every minute; a second run of the slot in between is skipped as `tried`. A run skipped before its query writes none, so it holds nothing back, and a try stamped after the clock (from before it went back) is over.
- **After a boot,** no routine starts until the machine has been up 5 minutes, so routines do not pile onto the desk restore. `BERCAIL_ROUTINE_BOOT_WAIT` sets it in seconds.
- **A waiting event** of a routine goes to Shep's inbox at the next tick once there is one, a paused routine's too.

A tick writes `routines/tick.json`: when it last ticked. What the runs print goes to `routines/loop.log`, cut back to its last 1000 lines once it passes 2000.

`bercail shep status` says whether the loop is running and when it last ticked. With a routine declared, `bercail doctor` fails when the loop is not running, or when there is no `flock`. Shep's board gets one line when a routine failed or is paused, such as `Routines: cleanup is paused after 3 failures in a row (bercail routine resume cleanup once it is fixed)`, and none otherwise.

## The event

A run sends Shep one `bercail.routine/v1` event when it emitted, and when its failure was the third in a row and paused the routine. Any other run sends nothing. Its file goes into Shep's inbox, `~/.local/state/bercail/shep/inbox/`, mode 600, named after its id:

```json
{"source":"bercail","schema":"bercail.routine/v1","kind":"routine","sink":"shep","at":"2026-11-23T07:30:04Z",
 "event_id":"routine:cleanup:20261123T073000Z-4127","routine":"cleanup","run":"20261123T073000Z-4127",
 "outcome":"emitted","counts":{"found":5,"new":2,"changed":1},
 "show":"bercail routine show cleanup --run 20261123T073000Z-4127"}
```

- `outcome` is `emitted`, with its `counts`, or `paused`, with `counts: null`.
- `event_id` is `routine:<name>:<run id>` for a run by hand. A run [the scheduler](#the-scheduler) starts is for a due slot, and its id is `routine:<name>:<slot>`, such as `routine:cleanup:20261123T073000Z`.
- `show` is the command that shows what the run found, or why it failed.
- No finding text and no error text: those are the query's words. Shep reads them with `show`, as data.

**When a run stops partway.** A run writes what it found, its run line, then `state.json`. That one rename counts the findings as sent, records the slot it met and its next due time, and puts the event in the routine's outbox, a list in `state.json`. Then the run writes each event in the outbox into Shep's inbox and takes it out of the outbox.

- A run that stops before the rename has counted nothing: the next run queries again and sends what it finds then, and a retried slot runs again.
- A run that stops after it leaves the event in the outbox, and the next run of that routine sends it, skipped or not. A retried slot is skipped as `done`, whatever its query would find then.
- An id already in the inbox or in its `delivered/` folder is not written again. `delivered/` keeps a file 30 days after Shep's session saved it. So an event that reached the inbox, but stopped before it was taken out of the outbox, may be sent again when its next flush comes after that.
- A `state.json` that cannot be read stops the run, and nothing writes over it.

These hold when a process dies or a write fails, not across a power loss.

**Before Shep's first start** there is no inbox. The run counts its findings and pauses on a third failure as always, its event waits in the outbox, and it says so: `its event waits: no Shep inbox … yet; start Shep once (bercail shep)`. The next run or tick after Shep's first start sends what waited. When the inbox is there but the write fails, the event waits the same way, and `run` exits 1.

**What Shep reads.** `show --run` shows what a run found while it is among the last 10 emitted runs, and its line while it is among the last 100 runs. A quiet run keeps no findings. An event Shep reads after that finds them gone, and [SHEP.md](../shep/SHEP.md#routine-events) has it tell you the run expired.

Shep's `inbox.ts` writes the event's line from those fields only, and quarantines a malformed one in `delivered/`, as it does [any other](shep.md#desk-events). SHEP.md says what Shep does next: it reads `show`, handles only the findings marked `new` or `changed`, rechecks each against live state, and turns each that still holds into a card, a todo, a beads issue, a dispatch after the person's pick, or a guarded command. A card Shep asks that would remove, close or dispatch something never defaults; a guard card follows the guard's rules. For a paused routine, Shep says why in one line and resumes it only once the cause is fixed, or when you ask.

## The cleanup routine

`run = "cleanup"` finds what should be retired or asked about, on the schedule you give it, such as `at = "07:30"`. It only reads: the handoff records, the desks and Discuss terminals in `hc`, bd or Entire for each job, the Herdr window's spaces, `bercail cleanup --check`, and the question ledger. Each finding's key says what it is, and [SHEP.md](../shep/SHEP.md#routine-events) says what Shep does with it, after your pick where one is needed:

| Key | Found when |
|-----|------------|
| `cleanup:<worktree>` | The latest handoff on the worktree names a closed job (a closed issue, or a trail closed or merged), the worktree is still on that handoff's branch, every desk in it or in the space cleanup finds on it is done on that job, nothing is staged, and `bercail cleanup --check` passes. Shep runs `bercail cleanup`, which goes through the guard as any cleanup does |
| `staged-closed:<worktree>` | The same, but changes are staged there, and no desk there is working, as the review queue counts it |
| `done-desk:<desk>` | A desk is done or idle on an open job with nothing staged, in two runs on different days at least 20 hours apart. Shep asks: send it back, close the job, or leave it |
| `bg-done:<terminal>` | A background Shep is done or idle and still live. A blocked one waits |
| `space:<id>` | A space on this machine that a handoff opened on its worktree is still open, and that folder is gone while its parent is there. With no Herdr window on the machine, no space is read |
| `card:<Qn@rev>` | A pending card asked over 3 days ago whose check is stale or unavailable, or a default nobody said OK to or reversed in 3 days |
| `discuss:<terminal>` | A Discuss terminal is open on a card the ledger has as answered, superseded or withdrawn |
| `thread:<topic>` | Shep's selected thread topic has no card waiting |

A job bd or Entire cannot read is not closed, and gives no finding. Each bd call gets 10 seconds, and a lookup killed or out of time fails the run instead, since that job may be closed. A worktree whose `.git` is gone by the time its index is read, because a cleanup removed it meanwhile or is removing it, is skipped, not a failed source. A source that does not answer (`hc`, the window's list once it runs, the ledger, a card's live check, or what `cleanup --check` reads) fails the run: a run that left its findings out would drop their hashes, and the next one would send them again as new. Titles hold no state or time, so a finding stays `same` while it holds. A space found while the window was open is new again after a run with no window.

`routines/<name>/seen-done.json` keeps when each desk was first seen done, and drops one seen working, gone, staged, or on another job, so its clock starts over. A dry run reads it and writes nothing.

## The deps routine

`run = "deps"` reads the open issues the [dependency tracker](development.md#dependency-tracker) keeps on bercail's GitHub repo, for whoever works on bercail. The tracker runs at 07:17 UTC, so schedule the routine after it, such as `at = "08:00"`. It only reads: `gh issue list --repo simoncrypta/bercail --label deps --state open`, and `bd list` in your bercail checkout: the one of [Shep's repos](shep.md#known-repos) whose `origin` is that GitHub repo, over https or ssh. It never opens, closes or comments on an issue, and keeps no state of its own.

Each open issue with a `deps:<name>` label is a finding keyed `deps:<name>`; when two have the label, the newest counts. Its title is the issue's (`deps: tuicr 0.30.0`), its `repo` is your bercail checkout, and its detail gives the issue's URL, the version (the title's last word: a release, a date, or a vendored copy's commit), and the beads issues there that link it, an open one first: `https://github.com/simoncrypta/bercail/issues/71; version 0.30.0; linked by bercail-12 (open)`, or `no beads issue links it`. A beads issue links it when its external ref is `gh-71` or the URL, or its title or description holds the URL; a bare `#71` or `tuicr 0.30.0` does not, since any issue that mentions the version reads so. The first one that links it is the finding's `issue`. A new version retitles the tracker's issue, so the finding counts as changed; a beads issue that links it, or one that closes, changes it too. `deps:tracker` is the tracker's own `deps: tracker failing` issue, with no version. [SHEP.md](../shep/SHEP.md#routine-events) says what Shep does with each.

The run fails when no bercail checkout is among Shep's repos (add its path to `~/.local/state/bercail/shep/repos`), when there are two (each has its own beads, so a finding could not say which links it), when that checkout has no beads, or when `gh` or `bd` does not answer.

## The mistakes routine

`run = "mistakes"` finds the groups of [Shep's mistakes ledger](shep.md#mistakes) that need a fix in the system, on the schedule you give it, such as `at = "Mon 08:00"`. It only reads: `bercail shep mistake list --json`, every issue of each known repo with beads (one `bd list` a repo), and the trails the entries name. A group is found, with the key `mistake:<group>`, when its count grew since the last run, none of its entries names an open issue or trail, and either:

| Title | Found when |
|-------|------------|
| `G7 Test isolation has happened 7 times, counts against a tool, and has no open issue` | It has happened twice or more, and no issue is labelled `mistake:G7` |
| `… has happened 9 times, counts against a tool: 2 times since its fix bercail-12 closed on 2026-11-20` | Every issue labelled `mistake:G7` is closed, and it happened again after the last one closed: the fix did not hold. The finding's `repo` and `issue` name that fix |

Its `detail` lists the group's keys and their counts. An entry's beads issue with no repo is looked up in every repo; one in a repo without beads, or that bd does not have, is not open. A trail with no repo may be open, so it holds its group back. Keys in no group are left out. [SHEP.md](../shep/SHEP.md#routine-events) has Shep file the issue the group counts against, in the repo that owns the fix, labelled `mistake:<group>` and `routine`, so the issues routine can offer it.

`routines/<name>/counts.json` keeps each group's count and the run that saw it, so a group that did not grow is not found again, even once the issue that held it back has closed. A run counts from the last run the runner kept (`kept` in its `state.json`): when the runner could not write its state, the next run finds the same groups again. A source that fails fails the run, as in the cleanup routine: a bd list, or a trail Entire could not show, which may be open. A dry run reads `counts.json` and writes nothing.

## The rules routine

`run = "rules"` finds the [standing rules](shep.md#standing-rules) that may no longer apply, on the schedule you give it, such as `at = "12:30"`: after noon, last night's rules are past. It only reads: `~/.local/state/bercail/shep/preferences.md`, the terminals `hc ls` lists, and the question ledger. Each rule it finds is one finding, keyed `rules:<hash>` from the rule's line, titled with every reason that holds, and with the rule's line as `bercail shep list` prints it (`2026-11-22 [repo] Night of 2026-11-22: …`) as its detail:

| Reason | Found when |
|--------|------------|
| `for the night of 2026-11-22, now past` | The rule names its night (`Night of 2026-11-22`, `2026-11-21 night`) or, with no date, says `tonight`, `going to sleep`, `during the night` or `for the night`, which is the night of the day it was added. A night is past at noon the next day |
| `for 2026-11-14, now past` | The rule names its day (`On 2026-11-14`, or it starts `2026-11-24:`) or, with no date, says `for today`, `today only` or `just today`, the day it was added. A day is past the next day |
| `for desk t1d7, which hc no longer has` | Its scope is a desk, or it says `desk` and names desks (`on desks t2wp and t2wr`), and `hc ls` lists none of them. A rule that names a desk on another machine (`vps/t1aa`) is not read as for gone desks: that one may be live |
| `names Q71@1, a once-only permission used on 2026-11-16` | It allows something once (`once`, `one-time`, `a single`; not `once Q71@1 is answered`) and names a card whose push, guard Allow or land chain was claimed |
| `may be covered by a later rule of the same or wider scope: <that rule>` | A later rule, scoped the same or `all`, says the same or shares most of its words, and is not found itself |

These are word patterns, not a reading of the rule, so a finding is a candidate: one you pick to forget is forgotten, right or wrong. A rule with several dates is past once the last is, and a bare date (`back online (2026-11-23)`) dates nothing. Titles and details hold no list number, since a forget renumbers the rules after it: a rule you keep stays `same` while its reasons do, and is not raised again. [SHEP.md](../shep/SHEP.md#routine-events) has Shep recheck each, ask one card with no default for the ones that hold, and forget those you pick.

A source that fails fails the run, as in the cleanup routine: `hc`, the ledger, or a `preferences.md` it cannot read. No `preferences.md` is no rules, and a quiet run.

## The Routines panel

**Routines** in Shep's header shows or hides the panel under Shep's terminal. It reads `bercail routine list --json` when it opens and every 30 seconds while shown, on the [`[herdr] backend`](config.md#bercail-on-another-machine) when one is set. The header says how many routines there are, how many are paused, running, invalid or unreadable, and when the scheduler last ticked, or that it is not running. A card per routine shows:

- Its name, schedule, and state: `active`, `running` (a run holds its lock), `paused`, `invalid` (with what is wrong), or `unreadable` (its `state.json`).
- Its failures in a row, or `paused after 3 failures in a row`.
- When it is next due, unless it is paused.
- Its last run: `last run 07:30: emitted, 2 new and 1 changed of 5`, `failed: <error>`, `skipped (quiet)`, or `never run`.
- What its last emitted run found that was new or changed, at most 3, then how many more and the `show` command. Quiet runs keep no findings, so these may come from an earlier run, which a `found 07:30` line dates.

The panel runs nothing itself: no run, pause or resume. **Ask Shep** opens a field on the card. Write what should change (its schedule, what it runs, pause it, resume it) and press Enter or **Send**: `bercail routine ask <name>` puts your words in Shep's inbox, and the card says `Sent to Shep at 08:01`. When it fails, such as before Shep's first start, the card says why and keeps your words.

Shep gets one line: the routine, and your words quoted as data. The event does not prove who wrote it, so [SHEP.md](../shep/SHEP.md#routine-requests) keeps what Shep does with it small. It pauses or resumes the routine with `bercail routine`, and asks a card before it runs one now. Your `config.toml` is yours: for a schedule, Shep runs `bercail routine enable`, which the guard puts on a [Decisions card](shep.md#guard-asks) that shows each line it changes, and nothing changes until you Allow it. For your own command's argv, Shep tells you the lines to change. A request approves nothing else.
