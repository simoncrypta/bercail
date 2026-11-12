---
name: verify-bercail
description: >-
  Runs the unit test suite, then drives this checkout's bercail CLI the way a
  user does, in a throwaway HOME: deploy, doctor, desk restore --dry-run,
  handoff-spawn --info, bstack status, and Shep's repos, rules and start.
  Leaves evidence under .bercail/verify/. Use at /ready, or to prove a change to
  the CLI, the deploy, handoff, desk restore, or bstack.
---

# verify-bercail

One command runs the whole proof, in about three minutes:

```bash
.agents/skills/verify-bercail/run.sh
```

It exits 0 when every step and check passed, and prints the evidence folder.

## Tests

First, `tests/run.sh` (the unit suite, every test in its own throwaway HOME)
with the real `${XDG_STATE_HOME:-~/.local/state}/bercail/handoffs.jsonl`
hashed before and after. A changed hash fails the check, and the added lines go
to `handoffs-added.jsonl`: a real path there is another desk's spawn, so rerun.
The live proofs (`tests/run.sh --live`) are not part of it.

## Launch

`run.sh` makes a temp directory and points `HOME`, the `XDG_*` dirs and
`INSTALL_SRC` at it, with this checkout as the source. It clears the desk's
`HC_*` variables, writes a `config.toml` with one pinned model,
and runs `bercail reconfigure` to deploy into that HOME.

Two stand-ins. `hc` answers for one live desk at a bare shell and logs every
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
| `handoff-spawn --info` | prints JSON |
| `bercail bstack status` | reports the profile, models and logins |
| deployed files | the lead's `lead.json` loads the guard, review-pr's `review.json` has only read tools, `/council` is there |
| `bercail policy show --json` on this checkout | reads `.bercail/policy.toml`, and a fresh HOME has not trusted it, so commit stays `ask` |
| the pinned Claude model | a `bstack-council-claude` seat, and none for a provider with no model |
| `bercail shep remember`, `repos --json`, `run` | `repos` finds this checkout's main repo from Shep's extras file; a start writes `.pi/settings.json` with the lead at 250k of its 1M window and a start context with the rule |

## Evidence

`.bercail/verify/<timestamp>/` (gitignored):

- `summary.tsv`: step, exit code, command.
- `tests.out`: the suite's output.
- `checks.tsv`: `ok` or `FAIL` for each claim about the state the run left.
- `<step>.out`: each step's output.
- `hc-calls.log`: every call to the stand-in.
- `config.toml`: the config the run ended with.

Quote `summary.tsv`'s exit codes and the folder path in the `/ready` report.

## Cleanup

The script's trap removes the temp directory, on failure too. It starts no
daemons, and evidence stays. Prune old `.bercail/verify/` folders by hand.

## Not proven here

A real Herdr core, a real resume typed into a desk, and connected plans. For
those, run `bercail desk restore --dry-run` and `bercail doctor` on the real HOME.
