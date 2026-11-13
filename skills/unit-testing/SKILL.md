---
name: unit-testing
description: >-
  Rules for writing and reviewing unit tests, from the F.I.R.S.T. principles
  (Fast, Isolated/Independent, Repeatable, Self-validating, Thorough/Timely)
  turned into steps and checks an agent runs. Each test gets its own temp HOME,
  fakes on PATH, a behavior name, and a run that fails without the change. Use
  when you write, change, or review tests, in any language.
---

# unit-testing

Adapted from [F.I.R.S.T Principles of Unit Testing](https://github.com/tekguard/Principles-of-Unit-Testing)
by Rajesh Kannan. That repo has no license, so this skill paraphrases it and
quotes nothing. Each rule below ends in a check. Run the check instead of
assuming the rule holds.

## Before you write one

- **Timely.** Follow the `bstack` skill's bug fix and feature playbooks: when
  there is a cheap test path, write the failing test first. Run it before the
  change and keep the output. It must fail on its assertion, not on a typo, a
  missing file, or a missing fake. Then make the change and run it again.
- Find the repo's runner and copy a neighboring test's setup, helpers, and
  naming. Don't bring a new framework into one file.

## Fast

- A unit test takes milliseconds. It runs no network, no real model, no real
  `gh`, Pi, Herdr, or `hc`, and no fixed sleeps.
- A live proof (real Pi, real `gh`, a real desk) is its own file or tag, named
  so (`*_live.*`, `@live`), and left out of the default suite or skipped when
  the tool is missing. In your report, say which kind you ran.
- Check: time the file. A unit file that takes seconds is waiting on something.

## Isolated

- Arrange everything the test needs inside the test. Make a temp dir per test
  (or per file when the cases cannot touch each other) and point `HOME`, every
  `XDG_*_HOME`, `XDG_RUNTIME_DIR`, and `TMPDIR` into it before the code under
  test runs. Remove it on exit (`trap`, `afterEach`).
- Nothing may reach the user's `~/.config`, `~/.local/state`, `~/.local/share`,
  or their live tools (`hc`, Herdr, the Shep inbox, `gh`, `bd`). Put fakes for
  them first on `PATH`, inside the temp dir. Unset the variables that lead to
  live sockets and state (`HC_*`, `HERDR_*`, `BERCAIL_*`, `BEADS_*`, `BD_*`,
  `BASH_ENV`).
- Each leak on record was one variable left pointing at real state: the
  handoff log (bercail-4k9), Herdr core templates through `XDG_CONFIG_HOME`
  (bercail-8ut), and review desk events in the real Shep inbox (bercail-7hw).
  Set the variable, then prove it.
- Fake at the process boundary: a script named `gh`, `pi`, or `hc` that logs its
  argv to a file and prints canned output. Don't mock the code's own functions.
- Check: hash the real files the code would write (`sha256sum`) before and after
  the run and compare. Grep the fakes' argv logs to show the code called the fake.

## Independent

- No state shared between cases. Each case builds its own data, and nothing
  relies on what an earlier case left behind. Put shared setup in a helper
  that every case calls, not in leftover files.
- Check: run one case alone (`bats -f`, `vitest -t`, `node --test
  --test-name-pattern`, or call the one bash function), then the file in a
  shuffled order where the runner can. Both must pass.

## Repeatable

- Same result on every run, on every machine. Control the clock, randomness,
  timezone, locale, and the environment: inject them, freeze them, or seed
  them (`TZ=UTC LC_ALL=C`, fake timers, a fixed seed).
- Don't depend on machine load. Never `sleep N` and hope a process is ready.
  Wait for its signal (a file, a log line, an exit) with a deadline that is
  generous and fails loudly. A test that fails under load is a bug in the test.
  The Shep live proof's duplicate check, which passes only when two events land
  in the same clock second, is one to fix, not to rerun until green.
- Don't depend on what the host has installed or configured. Fake it, or skip
  with a message that says what is missing.
- Check: run the file a few times in a row and once under load (the whole suite
  in parallel). All runs must agree.

## Self-validating

- The test decides pass or fail with an assertion and an exit code. Printing
  output and reading it yourself does not check anything.
- Assert the exit code and the exact part of the output or state that the
  behavior is about. Let setup fail loudly (`set -e`, a throw) instead of
  asserting in it.
- Check: break the behavior (revert the fix, or flip the condition) and watch
  the test fail. A test that can't fail doesn't test anything.

## Thorough

- Cover the cases a user hits, not a coverage number. Go through the ones that
  apply: empty and one, boundaries, very large input, bad or hostile input,
  errors and exit codes, permissions or roles, overflow and underflow, and the
  secret that must not appear in argv or output.

## The shape of a test

- Arrange, act, assert, in that order. Nothing runs after the assertions.
- One behavior per test and one reason to fail. Several asserts on the same
  outcome are fine.
- The name states the behavior: `update keeps a foreign skill link`, not
  `test_deploy_2`.
- Test what a caller sees (the CLI, the exported function, the file written),
  not private helpers or the order of internal calls. A refactor that keeps
  behavior must not break the test.

## Never

- Never weaken, skip, retry, or delete a failing test to get green.
- Never change what an existing test asserts unless the issue asks for it. If a
  test looks wrong, say so in your report and leave it.
- Never point a test at real user state "just this once". A one-off manual
  proof against the real tools is a live proof: say so and say what it touched.

## Per ecosystem

- **bash**: `TMP_DIR="$(mktemp -d)"; trap 'rm -rf "$TMP_DIR"' EXIT`, then
  `export HOME="$TMP_DIR/home" XDG_CONFIG_HOME=... XDG_STATE_HOME=...` and
  `PATH="$TMP_DIR/bin:$PATH"` for the fakes. In bats, do it in `setup` with
  `BATS_TEST_TMPDIR`; run one case with `bats -f '<name>'`.
- **Vitest**: `mkdtemp(join(tmpdir(), ...))` in `beforeEach`, `vi.stubEnv` and
  `vi.unstubAllEnvs`, `vi.useFakeTimers()` and `vi.setSystemTime()`, MSW or a
  fake server for HTTP. Run one with `vitest run -t '<name>'`, shuffle with
  `--sequence.shuffle`.
- **node:test**: `t.mock.timers`, `node --test --test-name-pattern '<name>'`.

## Reviewing tests

For the judge, the council, and `/validate`. Report a finding only when a run
shows it, and include the command.

1. **Does it fail without the change?** Export the base to /tmp
   (`git archive <base> | tar -x -C /tmp/<name>`), copy the new tests in, and
   run them there. A pass means the test proves nothing.
2. **Can it reach real state?** Look for `$HOME` or `~` used before the test
   sets them, absolute user paths, an `XDG_*` left unset, live tools missing a
   fake on `PATH`, desk variables passed through. Prove it with a hash of the
   real file before and after the run.
3. **Does it pass alone and shuffled?** Run the one case by name.
4. **Is it repeatable?** Fixed sleeps, tight timeouts, the real clock, random
   values, the network. Run it several times and under load.
5. **Does it assert?** Output that is only printed, an exit code that is never
   checked, a `|| true` that hides a failure.
6. **Did the diff weaken a test?** `git diff -- <test paths>` for removed or
   loosened assertions, new skips, retries, or deleted cases the issue didn't
   ask for.
7. **Does it test behavior?** Mocks of the code's own functions, assertions on
   call order, names that don't say what should happen.
8. **Is a live proof hiding in the unit suite?** Real `gh`, Pi, Herdr, or
   network calls in a file that runs by default.
