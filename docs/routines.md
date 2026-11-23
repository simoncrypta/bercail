# routines

A routine is a query that runs outside Shep's session. It reads something, prints what it found, and only what is new or changed counts. A run that found something new or changed sends Shep one event, and Shep decides what each finding becomes. This page covers the runner, its state and its locks, the event, and [the scheduler](#the-scheduler) that runs each routine when it is due. `bercail routine run` runs one now, and `--dry-run` prints the event a run would send. The plan is bercail-2qig.

## Declare one

Routines are declared only in your own `~/.config/bercail/config.toml`, never in a repo's policy:

```toml
[routine.my-check]
command = ["~/bin/my-check", "--json"]   # your own query; ~/ is your home
every = "1d"                             # or at = "07:30", a local time each day

[routine.cleanup]
run = "cleanup"                          # a built-in, lib/routine/<name>.sh (none ship yet)
at = "07:30"
```

- Each routine has one of `run` (a built-in's name) or `command` (an argv, not a shell line).
- Each has one of `at = "HH:MM"` (a daily local slot) or `every = "<n>h"` or `"<n>d"` (at least `1h`).
- A name is letters, digits, `-` and `_`, at most 64 of them.

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
| `bercail routine show <name>` | Its schedule and state, and its last 10 runs, newest first |
| `bercail routine show <name> --run <id>` | What that run found, each finding marked new, changed or same |
| `bercail routine run <name>` | Run it now. It prints one line: `emitted`, `skipped (quiet)`, `skipped (paused)`, `skipped (overlap)`, `skipped (load)` or `failed`, and a line when an [event](#the-event) waits. It exits 1 when the run failed, or when it could not write its run, its state or its [event](#the-event) |
| `bercail routine run <name> --dry-run` | Run it under the same locks, and print the `bercail.routine/v1` event it would send, or its line when there is none. It writes no state, no run and no inbox file, so the next real run counts the same findings again |
| `bercail routine pause <name>` / `resume <name>` | Stop and restart it. `resume` also clears the failures in a row |
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

- `<name>/state.json`: when it is next due, the failures in a row, whether it is paused, the hash counted per key, the highest slot a run met (`slot`), and the outbox: [events](#the-event) not yet in Shep's inbox.
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

- **Due.** An `at` routine is due at its next `HH:MM`, and one that never ran waits for it. An `every` routine is due that long after its last start, and one that never ran is due now. The tick writes a never-run routine's first due time before it starts it, so a retry is for the same slot.
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

Shep's `inbox.ts` writes the event's line from those fields only, and quarantines a malformed one in `delivered/`, as it does [any other](shep.md#desk-events). SHEP.md says what Shep does next: it reads `show`, handles only the findings marked `new` or `changed`, rechecks each against live state, and turns each that still holds into a card, a todo, a beads issue, a dispatch after the person's pick, or a guarded command. A card that would remove, close or dispatch something never defaults. For a paused routine, Shep says why in one line and resumes it only once the cause is fixed, or when you ask.
