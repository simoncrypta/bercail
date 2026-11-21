# Script languages: bash, dash, QuickJS, Node

**Proposal**, not implementation ([the job](#sources)). Measured on 2026-11-20
against [`eb2ac33`](https://github.com/simoncrypta/bercail/commit/eb2ac33fb02396600a27eebfbf18124358bff0ed)
(v0.18.0), on the person's Omarchy desktop: AMD Ryzen 7 9700X (16 threads),
kernel 7.2.15, bash 5.3.20, Node 26.13.1, jq 1.8.2, with other desks running.

Each claim carries one of three marks. **Measured**: timed, counted or tried on
this machine for this page ([method](#method)). **Benchmark**: from
[rivet-dev/code-mode-language-benchmark](https://github.com/rivet-dev/code-mode-language-benchmark)
at `258b364`, on its own host, or from the studies its report cites.
**Inferred**: reasoned from those facts, not tested.

## Conclusions

Keep bash for process glue. Use the Node and TypeScript that bercail already
runs for new logic that parses JSON or keeps state, and move existing bash
plus jq to it one unit at a time, starting with a pilot. Adopt neither dash
nor QuickJS, nor Bun or Deno.

- No surveyed bercail entry point has a measured speed case for another
  language. The
  costs measured are about 2 to 55 ms a call, and Pi takes 230 ms just to
  print its version (measured).
- Most of a bash start on this machine is the person's `~/.bash_env`, not bash
  itself: 6.1 ms as installed, 1.1 ms without it (measured).
- dash would save about 0.5 ms a process over bash, and QuickJS about 15 ms
  over Node (measured). Neither matters at these rates, and each costs a
  rewrite or a second runtime (inferred).
- TypeScript's case is maintenance, not speed. It is a hypothesis this page
  could not measure, and the pilot is the way to test it.

## What the benchmark measures, and how far it applies

The benchmark is for *code mode*. A model answers by writing a short script,
a host runs each script in a fresh, isolated interpreter, and that runtime's
cost per instance decides how many sessions one host can hold. It measures
memory per idle instance, time to first response (`1 + 1`), one JSON
tool-call round trip, and parsing and aggregating 3 MB of JSON. Its rows for
these candidates (benchmark, on Debian, a 24-core, 48-thread EPYC, load 7 to
12):

| Runtime | Memory each | First response | Tool call |
| --- | ---: | ---: | ---: |
| dash | 242 KiB | 2.39 ms | 55.2 µs |
| bash | 419 KiB | 3.02 ms | 76.5 µs |
| QuickJS-ng, embedded in Rust | 164 KiB | 70.3 µs | 0.75 µs |
| Bun | 7.51 MiB | 19.2 ms | 59.4 µs |
| Node | 7.75 MiB | 32 ms | 37.1 µs |
| Deno | 14.4 MiB | 38.9 ms | 65.8 µs |

**What carries over.** Little of the headline. bercail runs its own code, not
model-written scripts, and it embeds no interpreter. Memory per instance does
not decide anything here. bercail's 39 long-running processes (desk watchers,
`hc events`, notify followers) held 96 MiB of summed RSS, against 4.3 GiB for
the 29 Pi processes they serve (measured, with shared pages counted in each). The
QuickJS row is the engine embedded in Rust, which bercail would not do. The
process start times are what carries over, and the order matches this machine:
dash, then bash, Bun, Node and Deno. The benchmark times spawn to first output
from a Node host, and this page times spawn to exit from Python, so the absolute
numbers differ.

**Agents writing and reading the code.** The issue cares about this more than
speed, and the benchmark has little on it. Its own fluency run had one model
write ten tool-calling tasks in each of Python, JavaScript, Lua and bash. All
40 passed, so the run cannot rank the languages, and it did not test reading
or changing existing code (benchmark). Its report sorts languages into tiers
by other people's studies: JavaScript and TypeScript in tier 1, bash in tier
2, jq in tier 3. On jqBench the best model scored 76%, and 81% with execution
feedback. Execution feedback helped weaker languages more than documentation
did (benchmark, citing those studies). Nothing compares how well agents read
bash and jq against TypeScript, in general or in this repo.

So the case for TypeScript is a hypothesis about maintenance. It goes like this
(inferred, unmeasured). In `pr-state.sh` the PR snapshot and the next step come
from one 40-line `jq` program over three JSON strings, and a reader rebuilds
their shape from the filters. In TypeScript the same data is a named type, built
by a function a test can call directly. Shep's mistake ledger (97 entries) shows
failures that bash invites. `pipefail-grep-q` happened twice, then 69 lines
changed and a lint rule was added. A pipe through `jq` hid a command's output,
and a trail was created twice. In a test, `BASH_ENV` put the mise shims back
ahead of a stand-in. `secret-pipe-no-pipefail` happened twice, in ad hoc scripts
outside bercail (measured). The TypeScript side has four entries where Vitest
picked up a scratch `*.test.ts` (measured). The ledger mixes languages, tools
and how much code each has (about 15,100 lines in the 40 shell files surveyed
against 1,465 in `lib/*.ts`), so it motivates a pilot but ranks nothing.

## bercail's scripts by area

Sizes are measured at `eb2ac33`. "Start" is spawn to exit, median, as
installed (with `BASH_ENV`) / without `BASH_ENV`. It is marked *proxy* when
it times a stand-in for the real path. "How often" is measured only where it
says so.

| Area | What | Size | How often | Start |
| --- | --- | ---: | --- | ---: |
| `bin/bercail` | bash; `help`, `doctor`, `desk`, `shep` and most others source `common.sh` and 13 libs, which source others; `job` none; `scratch` two | 328 lines | started in about 230 agent tool calls a day (measured); its callers in mods and extensions not counted | `help`: 26 / 19 ms; sourcing the default lib set alone: 21 / 14 ms |
| `lib/*.sh` | bash and jq | 28 files, 11,565 lines; `lib/todo/` 168 | inside `bercail` | (above) |
| `lib/*.ts` | TypeScript, `node` per call: `jobs.ts`, `shep-task.ts`, `runtime.ts` | 3 files, 1,465 lines | `bercail job`, `shep task`, Shep's board in an Entire repo; `runtime.ts` from `doctor` and `shep runtime`; not counted | `node` on `jobs.ts` or `shep-task.ts`, ending in a usage error: 55 ms; `runtime.ts` not timed |
| desk start | `bin/bercail-desk-agent`, bash; `exec`s the harness | 226 lines | each desk start; within about 90 Pi sessions a day (measured) | unlabelled path: 10 / 3.3 ms; labelled path (`hc get`, `jq`, record, watcher, `scratch dir`) not timed |
| scratch wrapper | `bercail scratch run`: `scratch.sh` and `common.sh` | 454 + 170 lines | each role agent start; not counted | 25 / 17 ms; `scratch dir`: 15 / 8.4 ms |
| hooks | Omarchy post-update and post-boot; worktrunk post-start and post-remove through `herdr-layout.sh` | 42 + 360 lines | per update, boot, worktree | proxy, sourcing `herdr-layout.sh`: 8.2 / 1.6 ms; the hooks themselves not timed |
| shell rc | `bercail.inc.sh` and the bash and zsh stubs | 234 lines | each interactive shell, which does not read `BASH_ENV` | proxy, sourced in `bash -c`: 8.4 / 1.8 ms |
| Pi extensions | TypeScript loaded into Pi: bstack's and the desk's (4,283 lines), Shep's (2,693) | 6,976 lines | the guard's handler on every tool call, in Pi's process; some handlers start `hc` or `git` on events | no new interpreter |
| Herdr mods | JavaScript in the Herdr app | 5 files, 4,233 lines | in Herdr's process; some handlers start `gh`, `hc` or `bash -lc` | no new interpreter |
| skill scripts | handoff (bash, 1,934 lines), `pr-state.sh` (bash, 187), statechart (TypeScript, 4,004) | | per handoff, per autopilot run (`--wait` polls inside one run), per `/statechart`; not counted | not timed |
| `install.sh` | bash, runs before Node exists | 117 lines | once | not timed |
| tests | 64 bats files, 938 `@test`; 18 Vitest files, 295 static `test`/`it` declarations | 21,873 + 7,653 lines | `tests/run.sh`, CI | see [method](#method) |

**How often, measured.** From the Pi session files written between 2026-11-14
00:00 and 21:16 on 2026-11-20 (EST), about 6.9 days. There were 634 session
files, about 90 a day, counting desks, role agents and headless runs. There were
24,280 bash tool calls, about 3,500 a day, and Pi runs each as `/bin/bash -c`
(one call checked from inside). In a second pass a few minutes later, 1,565 of
24,469 bash tool calls started `bercail` or `bin/bercail` at least once, about
230 a day (a text match at a command position). A session file is counted by
its modification time, so it is not always a fresh start. All 29 Pi processes
and 4 notify followers running had `BASH_ENV` set. As an illustration
(inferred), 5 ms of `~/.bash_env` on 3,500 calls is about 18 s a day across all
desks. If each session file were a fresh Pi start, 230 ms on 90 of them would
be about 21 s.

## The candidates

Interpreter start, spawn to exit, median of 60 to 300 runs at load 4 to 7
(measured). The `/usr/bin/true` floor is 0.24 ms.

| Runtime | Start | A small `.ts` | Packaging |
| --- | ---: | ---: | --- |
| bash, `BASH_ENV` as installed | 6.6 ms | — | Arch `base`; Homebrew `bash` 5.3; macOS ships 3.2 |
| bash, no `BASH_ENV` | 1.1 ms; 0.8 with an empty env | — | |
| dash 0.5.13 | 0.5 ms | — | Arch `core`, 163 KiB; no Homebrew formula; not installed on this desktop |
| QuickJS-ng 0.17 (`qjs`) | 0.7 ms | cannot run | Arch `extra`, 1.34 MiB; Homebrew `quickjs-ng`; not installed here |
| Node 26 | 15.8 ms | 34.8 ms; 16.0 ms with a warm `NODE_COMPILE_CACHE` | comes with Pi on a full install |
| Bun 1.4.5 | 6.8 ms | 6.5 ms | Homebrew `bun`; here only inside vite-plus |
| Deno 2.9.8 | 18.9 ms | 17.6 ms | Arch `extra`, 107 MiB; Homebrew `deno`; not installed here |
| jq 1.8.2, one call | 1.25 ms | — | required already |

**Bash as is.** Its start is fine without `BASH_ENV`. Correctness is where it
costs. In bash's default mode, `set -e` is off inside conditions, and inside
`$(…)` unless `inherit_errexit` is set, which bercail never sets. Pipefail turns
`printf | grep -q` into a rare SIGPIPE failure, and an unquoted expansion in a
command's arguments splits and globs. bercail holds the line with shellcheck,
`tests/lint_grep_q.sh` and bats, whose tests drive the real CLI with a HOME and
stand-ins of their own. bercail needs bash 4.4 or later: `local -A`, `mapfile`
(with `-d`) and `${x,,}` appear 25 times. macOS's `/bin/bash` 3.2 is too old,
and no CI job is declared for macOS (measured). So it is unverified that every
macOS install path puts a newer bash first. Migration cost: none.

**dash.** It saves about 0.5 ms per process against bash without `BASH_ENV`,
which is the whole speed case (measured). dash 0.5.13 has `set -o pipefail` and
`local`. It has no arrays, `[[`, `<(…)`, `<<<`, `mapfile`, `printf %q` or
`${x,,}` (measured). bercail uses arrays to pass argv and paths without
re-splitting them, so a port would trade them for `set --` and rewrites
(inferred). `dash -n` rejects 31 of the 40 shell files surveyed, among them the
hot paths the issue names: the desk agent, `scratch.sh` and `herdr-layout.sh`. 8
of the 9 it parses use `[[` (measured). Files sourced into the person's shell
must stay bash and zsh. A port could go one file at a time, but none of the
files has a speed reason to move. No dash fluency evidence was found. Migration
cost: rewrites, for under a millisecond per process.

**QuickJS (quickjs-ng).** The fastest JavaScript start here (0.7 ms). It has
no Node APIs: `import("node:fs")` fails, and there is no `process` and no
`fetch`. Its `qjs:os` module starts programs from an argv array, and it ran
`git rev-parse` without a shell (measured). The existing `lib/*.ts` import
`node:child_process`, `node:crypto` and `node:fs`, so none of it runs there.
QuickJS cannot run TypeScript ("SyntaxError: missing initializer" on
`const x: number = 1`, measured). That leaves a build step, which the CLI has
none of, or plain JavaScript. A pure JavaScript core could still be tested in
Vitest, with only the `qjs:*` I/O tested from outside (inferred). How well
agents know `qjs:std` and `qjs:os` was not measured. The benchmark considers
QuickJS for many embedded sessions per host, which bercail does not have.
Migration cost: a second JS runtime to package and pin, plus the build or
untyped-JS question.

**Node and TypeScript, as is.** A full install needs Pi, which runs on Node, and
`lib/*.ts`, the Pi extensions and the tests already use it. But bercail installs
`pi`, not Node, and checks no `node` on PATH. A client install (the Herdr half
only) checks `herdr-app`, `hc` and `jq`. `lib/deps.json` pins Node 26 for CI and
development only. The statechart wrapper already sets the floor for running
`.ts` directly: Node 22.18 on the 22 line or 23.6 and later, then Bun 1.1.5 or
Deno 2.0 as fallbacks (`skills/statechart/scripts/statechart`). Its start is the
slowest of the candidates except Deno's eval. A small `.ts` took 34.8 ms against
15.8 ms for the same file as `.js`. A warm compile cache brought it to 16.0 ms,
and the first, cold run was not timed. For bercail's real files, warm repeated
runs that end in a usage error took 55 ms for `jobs.ts` and `shep-task.ts`, and
30 and 24 ms with the cache (measured). That suits an occasional command, and
not anything that runs per shell or per tool call (inferred).

Speed does not favor a port either, on one synthetic probe. Five `jq` calls from
bash on a desk-record fixture took 14 ms without `BASH_ENV` and 25 ms as
installed. The same reads in one Node process took 25 ms, and in `qjs` 1 ms
(measured at load 170). A separate run showed all three give the same output.
The gain would be correctness and testing: an exception instead of `set -e`, one
`JSON.parse` instead of the substitutions, arguments as arrays. Suite averages,
from unmatched suites under load: Vitest ran 282 cases in 2.4 s (3.1 s wall),
about 9 to 11 ms a case. Two bats files averaged 88 ms and 1.5 s a case
(measured). It is not automatic, though. A child's exit status still has to be
checked and external JSON validated, because types are erased at run time.
Migration cost: per unit, and only where it pays.

**Bun and Deno.** Bun ran the small `.ts` in 6.5 ms with no cache, the one
real speed option for TypeScript (measured). Deno was slower than Node on
`eval` but faster on the uncached `.ts`. Neither is a bercail dependency.
The statechart skill already falls back to them, with its own minimums and,
for Deno, permission flags. Homebrew packages both, and Deno takes 107 MiB on
Arch. Making either bercail's runtime would mean a third one to pin, checking
each `node:` API bercail uses, and keeping Vitest or moving to their test
runners (inferred). Start time is not
bercail's bottleneck, so none of that pays.

## Where a change pays off, and where it does not

**Pays off, by hypothesis: bash that is mostly JSON and state.** Ranked by
`jq` word matches (measured): `review.sh` (1,697 lines, 116),
`shep-context.sh` (1,136, 93), `todo.sh` and `stack.sh` (47 each),
`describe.sh` (44), `desk.sh` (42), and the handoff scripts (52). A port to
TypeScript under `lib/`, run by `node`, adds no runtime where a `node` is on
PATH, and the bats tests
that drive the CLI keep pinning the behavior. Move one unit at a time when a
behavior change touches it, never all at once, and only if the pilot bears
out the hypothesis.

**Does not pay off:** glue that must start fast or before Node, or that runs
in the person's shell. That is `install.sh`, `bin/bercail`'s dispatch,
`bercail-desk-agent`, `bercail scratch`, the Omarchy and worktrunk hooks,
`herdr-layout.sh` and the shell rc files. A bare Node start is 15.8 ms
against 1.1 ms for bash, so moving them to Node would likely make them slower
(inferred). Porting them to
dash, QuickJS, Bun or Deno does not pay off either.

**Proposed rule for new code:** bash for process glue, the environment and
`exec`. TypeScript in `lib/` once a function parses JSON in several places,
keeps state, or needs more than a few `jq` calls.

## Recommendation and first step

**First step: a pilot port of `skills/autopilot/scripts/pr-state.sh`.** It is
187 lines with 9 `jq` calls, and its snapshot and next-step logic is the one
`jq` program at lines 101 to 144, a bounded JSON transform. Its 18 bats cases in
`tests/autopilot_state.bats` drive it from outside with fixtures, `--wait`
included.

1. Write the snapshot and next-step logic as a typed function with Vitest
   cases, and keep the 18 bats behavior cases passing.
2. Keep one file. If the path changes from `pr-state.sh`, update
   `skills/autopilot/SKILL.md`, `docs/bstack/06-autopilot.md` and the test
   setup with it, rather than keep a shell wrapper only for the experiment.
3. Set and check the Node floor it needs on an installed skill: a Node that
   strips types by default.
4. Compare the two versions on the same fixtures: output and exit codes, lines,
   test time, and a reading task. An agent explains the next-step and error
   contract, then makes a small follow-up change, on each version.

The result decides whether `review.sh` and `shep-context.sh` follow.

**Not yet: a default `NODE_COMPILE_CACHE`.** It would touch every place
bercail starts `node` on a `.ts`, including the high-stakes `bin/bercail`. It
saved 25 to 31 ms on warm repeated usage-error runs, which shows nothing about
how hot those commands are. Do it once a frequently used
command shows a real end-to-end gain. Check cold and warm runs, concurrent
desks, a bercail update, an opt-out, and where the cache is kept and for how
long.

**For the person, outside bercail.** Exporting `__MISE_BASH_ENV_LOADED` from
`~/.bash_env` as it stands would be unsafe. A shell whose PATH was stripped of
mise, as the file does for `omarchy-agent-account-exec`, would inherit the flag
and never get the shims back (measured). The safe form keys the guard on the
PATH the file produced. A child bash skips the setup only while its PATH is
still that one. A child with its PATH unchanged started in about 2 ms, against
about 7 ms for a fresh shell that runs the setup (measured). A Pi tool shell
still runs the setup, because Pi puts `~/.pi/agent/bin` at the front of its
PATH. A bash started under it skips the setup only if its PATH is unchanged.

## Open questions

- Do agents read and change TypeScript in this repo more reliably than bash
  and jq? The pilot's reading task is the first measurement.
- On macOS, does every install path put bash 4.4 or later ahead of
  `/bin/bash`? No CI job is declared there.
- How much of a bats case's time is bercail's isolation (a HOME and stand-ins
  per test) rather than bash? Moving logic to Vitest speeds up only the cases
  that move.
- Is a default Node compile cache safe across concurrent desks and updates?
  Not tested.

## Method

Timing used a small Python harness (`subprocess.run`, stdio on `/dev/null`,
3 to 15 warm-ups, then 60 to 300 runs, 10 for `pi --version`). It reports the
median, p90, minimum and the last exit code, and discards output, so outputs
were checked separately. It is not a rigorous benchmark. Other desks ran
throughout. Interpreter and bercail starts were taken at a 1-minute load of
4.3 to 6.8. Test times and the five-`jq` comparison were taken at 50 and 170.
The test times are `tests/toml.bats` (9 cases, 0.8 s), `tests/scratch.bats`
(22 cases, 33 s) and `tests/pi_guard.test.ts` (282 cases, 2.4 s). bercail
commands ran from this checkout with a throwaway `HOME`, `XDG_CACHE_HOME` and
`XDG_STATE_HOME`, and `HC_TERMINAL_ID` unset. dash 0.5.13.4, quickjs-ng
0.17.0 and Deno 2.9.8 came from the Omarchy Arch mirror. Their signatures
were checked with `pacman-key --verify`, and they were unpacked into scratch,
not installed. Bun was vite-plus's copy, run directly. Homebrew formulae come
from the formulae.brew.sh API, which shows a listing, not that an install
works. Counts come from the session files' `toolCall` entries (commands
only), `ps`, `/proc/<pid>/environ` and Shep's ledger. The raw results, the
probes and these counts stayed in the worktree's git-ignored
`.bercail/script-languages/`, which is not published.

## Sources

- The job: beads issue bercail-vlxw, "Proposal: better script languages for
  bercail (dash, QuickJS) vs bash".
- [code-mode-language-benchmark](https://github.com/rivet-dev/code-mode-language-benchmark)
  at `258b364` (2026-11-19): `README.md`, `docs/report.md` and
  `benches/fluency/results.json`.
