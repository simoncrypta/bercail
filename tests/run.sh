#!/usr/bin/env bash
# shellcheck shell=bash
# Runs the unit suite, or the .bats files named. Each @test gets its own HOME
# (test_helper.bash); setup_suite.bash cuts the run off from the desk it ran in.
# With no arguments, the TypeScript unit tests (tests/*.test.ts) run after them
# with vp test. The live proofs (real Pi, tagged `live`) run only with --live.
# --shard I/N, --affected BASE and --vitest run what tests/plan.sh lists for
# them instead: CI's shards, and the tests a branch's change needs.
# Either run fails when a test wrote the person's bercail or Herdr state or
# left a process running (canary, below).
# Each run first takes one of the machine's test slots (lib/slots.sh), and
# waits for one while [tests] slots others run. It gets its share of the cores:
# two bats jobs per core, since most tests spend their time waiting on a child
# (BATS_JOBS overrides the count), and one Vitest worker per core. With GNU
# parallel, bats spreads files and tests over them. Without it, a quarter that
# many files run side by side, each in its own bats run (xargs -P) with its
# tests 4 at a time, and a file's output shows once it is done.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
# A GIT_DIR or GIT_CONFIG from the shell that started the run would send
# fixtures' writes to the repo it names, and git must not look above the temp
# dir bats runs in for one. setup_suite does both too, but bats reads each test
# file before it runs (bercail-m94t).
unset "${!GIT_@}"
# A BASH_ENV (mise activate) runs in bats and every bash child, and can put the
# real mise shims back on PATH ahead of a test's stand-ins (bercail-fss).
unset BASH_ENV
export GIT_CEILING_DIRECTORIES="${TMPDIR:-/tmp}"
bats=node_modules/.bin/bats vp=node_modules/.bin/vp
for tool in "$bats" "$vp"; do
  [[ -x "$tool" ]] || { printf 'tests/run.sh: %s is missing; run npm ci\n' "${tool##*/}" >&2; exit 1; }
done
# shellcheck source=lib/slots.sh
source lib/slots.sh
if ! slot_held; then
  slot_run tests/run.sh bash "$PWD/tests/run.sh" "$@"
  exit
fi
vitest=$(($# == 0)) bats_run=1 weights=0
if [[ "${1:-}" =~ ^--(shard|affected|vitest)$ ]]; then
  items="$(bash tests/plan.sh "$@")"
  mapfile -t files < <(grep '\.bats$' <<<"$items" || true)
  vitest=0 also=""
  ! grep -qx vitest <<<"$items" || vitest=1 also=" and vitest"
  printf 'tests/run.sh: %s runs %d .bats files%s\n' "$*" "${#files[@]}" "$also"
  # Each test's time, to see what makes a shard long, and each file's below.
  set -- --timing ${files[@]+"${files[@]}"}
  weights=1
  ((${#files[@]})) || bats_run=0
fi
tags='!live'
jobs=() per_file=0
cores="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)"
slots="$(slot_count)"
share=$((cores / slots))
((share >= 1)) || share=1
count="${BATS_JOBS:-$((share * 2))}"
if [[ "${1:-}" == --live ]]; then
  tags=live
  shift
elif command -v parallel >/dev/null 2>&1; then
  jobs=(--jobs "$count")
else
  per_file=1
fi
# A hung test fails itself, not the whole run.
export BATS_TEST_TIMEOUT="${BATS_TEST_TIMEOUT:-300}"
# Options pass through to bats; with no file or folder named, run them all.
named=0
for arg in "$@"; do
  [[ ! -e "$arg" ]] || named=1
done
((named)) || set -- "$@" tests
tmp="$(cd "$(mktemp -d)" && pwd -P)"
# A test may leave a read-only folder in it; that goes too.
trap 'chmod -R u+w "$tmp" 2>/dev/null; rm -rf "$tmp"' EXIT
# GNU parallel keeps a cache in ~/.parallel; this run's goes in the temp dir.
# So does every test's: its HOME, TMPDIR and worktrees all name $tmp.
export PARALLEL_HOME="$tmp" TMPDIR="$tmp"
# Tests start Node on bercail's TypeScript thousands of times: Node compiles
# each module once for the run instead of once a process.
export NODE_COMPILE_CACHE="$tmp/node-compile-cache"

# The person's bercail and Herdr state, which no test may write (bercail-fss).
# Shep and other desks write most of it during the run, so there a file counts
# against the run only when it changed since the run began and names $tmp. Pi
# transcripts are left out: they record what an agent read, maybe this run's
# output. Two parts have a stricter rule: the handoff log is append-only, and
# a file added, removed or changed (size or mtime) under herdr-core counts,
# whoever wrote it: only the person and bercail update should.
state="${XDG_STATE_HOME:-$HOME/.local/state}/bercail" config="${XDG_CONFIG_HOME:-$HOME/.config}"
templates() { find "$config/herdr-core" -type f -printf '%P\t%s\t%T@\n' 2>/dev/null | sort || true; }
touch "$tmp/start"
cat "$state/handoffs.jsonl" >"$tmp/handoffs" 2>/dev/null || true
templates >"$tmp/herdr-core"

# One line per file a test wrote, with why it counts.
state_written() {
  local dir dirs=() size
  for dir in "$state" "$config/bercail" "$config/herdr-core" "$config/herdr-app"; do
    [[ ! -d "$dir" ]] || dirs+=("$dir")
  done
  ((${#dirs[@]} == 0)) || find "${dirs[@]}" \( -path "$state/shep/pi-sessions" -o -path "$state/shep/discuss" \) -prune \
    -o -type f -cnewer "$tmp/start" -print0 2>/dev/null | xargs -0r grep -lF -- "$tmp" 2>/dev/null |
    sed "s/\$/: names the run's temp dir/" || true
  size="$(wc -c <"$tmp/handoffs")"
  ((size == 0)) || cmp -s -n "$size" "$tmp/handoffs" "$state/handoffs.jsonl" 2>/dev/null ||
    printf '%s: lines it had changed or went; it is append-only\n' "$state/handoffs.jsonl"
  { templates | diff "$tmp/herdr-core" - || true; } | awk -F'\t' -v dir="$config/herdr-core/" '/^[<>] / {
    print dir substr($1, 3) ": changed; if you or a bercail update changed it during the run, run again" }' | sort -u
}

# The processes the run left: any whose environment names $tmp (a test's
# TMPDIR) or whose working dir is in it, but this shell and what it runs now.
# A stub or daemon a test starts in the background outlives it.
leftovers() {
  local file pid
  [[ -d /proc/self ]] || return 0
  for file in $(grep -lzF -- "$tmp" /proc/[0-9]*/environ 2>/dev/null) \
    $(find /proc/[0-9]*/cwd -maxdepth 0 \( -lname "$tmp" -o -lname "$tmp/*" \) 2>/dev/null); do
    pid="${file#/proc/}" pid="${pid%%/*}"
    ours "$pid" || printf '%s\n' "$pid"
  done | sort -un
}

# Whether pid $1 is this shell or under it, by its parents in /proc.
ours() {
  local pid="$1" stat
  while ((pid > 1)); do
    ((pid != $$)) || return 0
    read -r stat 2>/dev/null <"/proc/$pid/stat" || return 0
    read -r _ pid _ <<<"${stat##*) }"
  done
  return 1
}

# Fails the run when a test wrote the person's state or left a process. Only
# reads; what it finds is for the person to look at and stop.
canary() {
  local written left n pid comm name
  written="$(state_written)"
  if [[ -n "$written" ]]; then
    printf '\ntests/run.sh: a test wrote the real state; give it its own HOME and XDG dirs (isolate) and stand-ins for hc and Herdr:\n%s\n' \
      "$written" >&2
    rc=1
  fi
  for n in 1 2 3 4 5 6 7 8 9 10; do
    left="$(leftovers)"
    [[ -n "$left" ]] || return 0
    ((n == 10)) || sleep 0.3
  done
  printf '\ntests/run.sh: the run left these processes running, and a test must stop what it starts:\n' >&2
  # With the test that started it, from the name isolate puts in its environment.
  ps -o pid=,comm= -p "$(paste -sd, <<<"$left")" | while read -r pid comm; do
    name="$(tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null | sed -n 's/^DESKTOP_TEST=//p')"
    printf '%7s %s%s\n' "$pid" "$comm" "${name:+ ($name)}"
  done >&2 || true
  rc=1
}

# One file's bats run, for xargs: its output goes to a log, and a line says how
# it went. A failed file's log is kept as .failed for run_files to show.
# shellcheck disable=SC2016 # expands in the worker
worker='logs="$1" bats="$2"; shift 2
file="${!#}"
log="$logs/${file//\//%}"
"$bats" "$@" >"$log" 2>&1 && { printf "ok %s\n" "$file"; exit 0; }
mv "$log" "$log.failed"
printf "not ok %s\n" "$file"
exit 1'

# Without GNU parallel: each file in its own bats run, COUNT / 4 at a time, and
# its tests 4 at a time (fewer when COUNT is) (bats needs parallel only to spread files). One test
# at a time, review_pr.bats alone takes about 2 minutes and sets the run's length.
# Options go to every run; a folder stands for the .bats files in it, as with
# bats. One file runs as it is, so its output shows as it goes.
run_files() {
  local arg opts=() files=() logs="$tmp/logs" log rc=0 per=$((count < 4 ? count : 4))
  for arg; do
    if [[ -d "$arg" ]]; then
      files+=("$arg"/*.bats)
    elif [[ -e "$arg" ]]; then
      files+=("$arg")
    else
      opts+=("$arg")
    fi
  done
  if ((${#files[@]} < 2)); then
    "$bats" ${opts[@]+"${opts[@]}"} --filter-tags "$tags" ${files[@]+"${files[@]}"}
    return
  fi
  mkdir "$logs"
  printf '%s\0' "${files[@]}" |
    xargs -0 -n 1 -P "$((count / per))" bash -c "$worker" worker "$logs" "$bats" \
      --jobs "$per" --no-parallelize-across-files ${opts[@]+"${opts[@]}"} --filter-tags "$tags" || rc=1
  for log in "$logs"/*.failed; do
    [[ -e "$log" ]] || continue
    printf '\n--- %s\n' "$(basename "${log%.failed}" | tr % /)"
    cat "$log"
  done
  # A failed setup_suite or teardown_suite is a not ok line, not a test.
  cat "$logs"/* | awk '
    / (setup|teardown)_suite$/ { next }
    /^(not )?ok [0-9]/ { tests++ }
    /^not ok [0-9]/ { failures++ }
    /^ok [0-9]+ .*# skip/ { skipped++ }
    END { printf "\n%d tests, %d failures, %d skipped\n", tests, failures, skipped }'
  return "$rc"
}

rc=0
if ((!bats_run)); then
  :
elif ((per_file)); then
  run_files "$@" || rc=$?
else
  ((!weights)) || jobs+=(--report-formatter junit --output "$tmp")
  "$bats" ${jobs[@]+"${jobs[@]}"} --filter-tags "$tags" "$@" || rc=$?
fi
# Each file's summed test time, the line tests/weights.tsv takes
# (docs/development.md#ci).
if [[ -f "$tmp/report.xml" ]]; then
  sed -nE 's|^<testsuite name="([^"]*)".* time="([^"]*)".*|weight tests/\1\t\2|p' "$tmp/report.xml"
fi
if ((vitest)); then
  "$vp" test --maxWorkers "$share" || rc=$?
fi
canary
exit "$rc"
