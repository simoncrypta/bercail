#!/usr/bin/env bash
# shellcheck shell=bash
# Runs the unit suite, or the .bats files named. Each @test gets its own HOME
# (test_helper.bash); setup_suite.bash cuts the run off from the desk it ran in.
# With no arguments, the TypeScript unit tests (tests/*.test.ts) run after them
# with vp test. The live proofs (real Pi, tagged `live`) run only with --live.
# The unit run uses two jobs per core, since most tests spend their time
# waiting on a child (BATS_JOBS overrides the count). With GNU parallel, bats
# spreads files and tests over them. Without it, that many files run side by
# side, each in its own bats run (xargs -P) with its tests 4 at a time, and a
# file's output shows once it is done.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
bats=node_modules/.bin/bats vp=node_modules/.bin/vp
for tool in "$bats" "$vp"; do
  [[ -x "$tool" ]] || { printf 'tests/run.sh: %s is missing; run npm ci\n' "${tool##*/}" >&2; exit 1; }
done
vitest=$(($# == 0))
tags='!live'
jobs=() per_file=0
cores="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)"
count="${BATS_JOBS:-$((cores * 2))}"
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
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# GNU parallel keeps a cache in ~/.parallel; this run's goes in the temp dir.
export PARALLEL_HOME="$tmp"

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

# Without GNU parallel: each file in its own bats run, COUNT at a time, and
# its tests 4 at a time (bats needs parallel only to spread files). One test
# at a time, review_pr.bats alone takes about 2 minutes and sets the run's length.
# Options go to every run; a folder stands for the .bats files in it, as with
# bats. One file runs as it is, so its output shows as it goes.
run_files() {
  local arg opts=() files=() logs="$tmp/logs" log rc=0
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
    xargs -0 -n 1 -P "$count" bash -c "$worker" worker "$logs" "$bats" \
      --jobs 4 --no-parallelize-across-files ${opts[@]+"${opts[@]}"} --filter-tags "$tags" || rc=1
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
if ((per_file)); then
  run_files "$@" || rc=$?
else
  "$bats" ${jobs[@]+"${jobs[@]}"} --filter-tags "$tags" "$@" || rc=$?
fi
if ((vitest)); then
  "$vp" test || rc=$?
fi
exit "$rc"
