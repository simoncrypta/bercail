---
name: verify-bercail
description: >-
  Runs the unit test suite, then drives this checkout's bercail CLI the way a
  user does, in a throwaway HOME: deploy, doctor, desk restore --dry-run,
  handoff-spawn --info, bstack status, a routine run, and Shep's repos, rules and start.
  Leaves evidence under .bercail/verify/. Use at /validate, or to prove a change to
  the CLI, the deploy, handoff, desk restore, or bstack.
---

# verify-bercail

One command runs the whole proof, in about three minutes:

```bash
.agents/skills/verify-bercail/run.sh
```

It exits 0 when every step and check passed, and prints the evidence folder.
It holds one of the machine's test slots for the whole drive, the same ones
`tests/run.sh` takes (`[tests] slots`, [development](../../../docs/development.md#test-slots)),
so with every slot taken it says `waiting for a test slot` and who holds them,
then starts when one frees.

## Tests

First, `tests/run.sh` (the unit suite, every test in its own throwaway HOME),
with `TMPDIR` set to a temp root of its own. Then `handoffs-canary.sh` checks
the real `${XDG_STATE_HOME:-~/.local/state}/bercail/handoffs.jsonl`: the lines
it had must be unchanged, and a line added since that names the temp root came
from a test and fails the check. A line naming any other path is another desk's
spawn during the run and passes. Every added line goes to `handoffs-added.jsonl`.
The live proofs (`tests/run.sh --live`) are not part of it.

## Launch

`run.sh` makes a temp directory and points `HOME`, the `XDG_*` dirs and
`INSTALL_SRC` at it, with this checkout as the source. It clears the desk's
`HC_*` variables, writes a `config.toml` with one pinned model,
and runs `bercail reconfigure` to deploy into that HOME.

Two stand-ins. `hc` answers for one live desk at a bare shell, accepts `run`, and logs every
call; the real `hc` would start or reach a Herdr core. `pi` reports the real
Pi's version, a catalog with one Claude model and no login, and installs
nothing, so the deploy fetches no bridge from npm.

## Doctor

`bercail doctor` on that HOME. Exit 1 is expected, because the temp HOME has no
Herdr layout or shell block. Pass means it reached its bstack section. Exit 2 or
higher is a crash.

## Drive

| Step | Proves |
|------|--------|
| `bercail desk restore --dry-run` on a seeded record | says `would resume`, sends no `hc send`, leaves the record unchanged |
| a desk session (`bercail-desk-agent` on a stand-in `pi`) | its `TMPDIR` is its scratch folder; the stand-in's `mktemp` file and folder, and Node's temp dir and compile cache when there is a Node, all land in it; no `verify-desk.*` appears in `/tmp` (only that name is looked for); and the folder is gone once the desk exits. The run's sweeps take `$box/system-tmp` as `/tmp` (`BERCAIL_TMP_ROOT`), so it removes nothing from the real one |
| `handoff-spawn --info` | prints JSON |
| `bercail bstack status` | reports the profile, models and logins |
| deployed files | the lead's `lead.json` loads the guard, review-pr's `review.json` has only read tools and the description standard, `/validate` is there and `/ready` is not, the `describe` skill is installed |
| `bercail describe template` on this checkout | the command loads and finds no PR template here |
| `bercail policy show --json` on this checkout | reads `.bercail/policy.toml`, and a fresh HOME has not trusted it, so push stays `ask` |
| the pinned Claude model | the `bstack-builder` template runs it |
| `bercail routine run`, `run --dry-run`, `list` on a `[routine.verify]` command routine | its one finding is emitted as one event in Shep's inbox, the same finding again is quiet, a dry run prints the changed finding, and `list` shows the last outcome |
| `bercail routine run --dry-run` on a `[routine.tidy]` of the cleanup built-in | it runs from this checkout, finds nothing on a fresh HOME, and writes no `seen-done.json` |
| `bercail routine tick` twice, `shep status`, `routine start` | the tick starts the routine that never ran and not the one that ran today, its run writes its line, a second tick starts nothing, `shep status` says the loop is not running and when it last ticked, and `start` asks the stand-in `hc` for the hidden `bercail-routines` terminal |
| `bercail shep remember`, `repos --json`, `run` | `repos` finds this checkout's main repo from Shep's extras file; a start writes `.pi/settings.json` with the lead at 250k of its 1M window and a start context with the rule |

## Evidence

`.bercail/verify/<timestamp>/` (gitignored):

- `summary.tsv`: step, exit code, command.
- `tests.out`: the suite's output.
- `handoffs-added.jsonl`: the lines added to the real handoff log during the suite, when there were any.
- `checks.tsv`: `ok` or `FAIL` for each claim about the state the run left.
- `<step>.out`: each step's output.
- `hc-calls.log`: every call to the stand-in.
- `config.toml`: the config the run ended with.

Quote `summary.tsv`'s exit codes and the folder path in the `/validate` report.

## Cleanup

The script's trap removes the temp directory, on failure too. It starts no
daemons, and evidence stays. Prune old `.bercail/verify/` folders by hand.

## Not proven here

A real Herdr core, a real resume typed into a desk, and connected plans. For
those, run `bercail desk restore --dry-run` and `bercail doctor` on the real HOME.
