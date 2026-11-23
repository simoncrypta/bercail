# routines

A routine is a query that runs outside Shep's session. It reads something, prints what it found, and only what is new or changed counts. This page covers the runner, its state and its locks. Nothing schedules a routine yet, and no run writes to Shep's inbox: `bercail routine run` runs one now, and `--dry-run` prints the event a run will send. The plan is bercail-2qig.

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
- A name is letters, digits, `-` and `_`.

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
| `bercail routine run <name>` | Run it now. It prints one line: `emitted`, `skipped (quiet)`, `skipped (paused)`, `skipped (overlap)`, `skipped (load)` or `failed`. It exits 1 only when the run failed |
| `bercail routine run <name> --dry-run` | Run it under the same locks, and print the `bercail.routine/v1` event it would send, or its line when there is none. It writes no state, no run and no inbox file, so the next real run counts the same findings again |
| `bercail routine pause <name>` / `resume <name>` | Stop and restart it. `resume` also clears the failures in a row |

A run comes to one of these outcomes, as in the [statechart](../tests/statechart/routine-run/chart/chart.pi.md):

- **Skipped (paused):** the routine was paused when the run had taken its locks. Its query does not run.
- **Skipped (overlap):** another run of it holds its lock.
- **Skipped (load):** 2 routines are already running.
- **Emitted:** the query found something new or changed.
- **Skipped (quiet):** nothing was new or changed.
- **Failed:** see above.

Once a pause returns, no run starts its query until you resume. A run whose query had already started ends as it would, and the routine stays paused. A runner that dies (a reboot, `kill -9`) logs nothing and does not count as a failure; after a `kill -9`, its query may still be running, without the lock.

## Locks and state

Everything is under `~/.local/state/bercail/routines/`:

- `<name>/state.json`: when it is next due, the failures in a row, whether it is paused, and the hash counted per key.
- `<name>/runs.jsonl`: a line per run with its `id`, `due`, `start`, `end`, `outcome`, `reason` for a skip, `counts` (found, new, changed), `event` id and `error`. The last 100 runs are kept.
- `<name>/outputs/<id>.jsonl`: what a run found. The last 10 are kept.
- `<name>/lock`, `.slots/slot.1` and `.slot.2`: what `flock -n` holds while a run lasts. One run per routine at a time, and at most 2 routines at once, by hand too. The query runs without those locks open, so a process it leaves behind cannot keep them.
- `<name>/state.lock`: held for the short read and write of `state.json` and `runs.jsonl`. The end of a run reads `state.json` again under it, so it never undoes a pause made meanwhile. It writes the run's line before `state.json`: when a write fails, `run` says so and exits 1, and the next run counts the same findings again rather than losing them.

Without `flock` (macOS has none by default), `bercail routine run` refuses and says how to install it, and with a routine declared, `bercail doctor` fails. A routine never runs unlocked.

The event id is `routine:<name>:<due slot>`. For a run by hand, the due slot is its start.

`tests/statechart/routine-run/` models a run and its locks in TLA+. Its `check.sh` checks every config with TLC, including four planted bugs, and `tests/routine.bats` has a case for each of the model's steps on the code; it does not walk TLC's graph. `BERCAIL_ROUTINE_TIMEOUT` (seconds) replaces the 10 minutes, for tests.
