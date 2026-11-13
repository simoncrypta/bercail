#!/usr/bin/env bash
# shellcheck shell=bash
# Runs the unit suite, or the .bats files named. Each @test gets its own HOME
# (test_helper.bash); setup_suite.bash cuts the run off from the desk it ran in.
# With no arguments, the TypeScript unit tests (tests/*.test.ts) run after them
# with vp test. The live proofs (real Pi, tagged `live`) run only with --live.
# With GNU parallel installed, the unit run spreads files and tests over two
# jobs per core, since most tests spend their time waiting on a child
# (BATS_JOBS overrides the count). Without it, they run one at a time.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
bats=node_modules/.bin/bats vp=node_modules/.bin/vp
for tool in "$bats" "$vp"; do
  [[ -x "$tool" ]] || { printf 'tests/run.sh: %s is missing; run npm ci\n' "${tool##*/}" >&2; exit 1; }
done
vitest=$(($# == 0))
tags='!live'
jobs=()
if [[ "${1:-}" == --live ]]; then
  tags=live
  shift
elif command -v parallel >/dev/null 2>&1; then
  cores="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)"
  jobs=(--jobs "${BATS_JOBS:-$((cores * 2))}")
fi
# A hung test fails itself, not the whole run.
export BATS_TEST_TIMEOUT="${BATS_TEST_TIMEOUT:-300}"
# Options pass through to bats; with no file or folder named, run them all.
named=0
for arg in "$@"; do
  [[ ! -e "$arg" ]] || named=1
done
((named)) || set -- "$@" tests
if ((${#jobs[@]})); then
  # GNU parallel keeps a cache in ~/.parallel; this run's goes in a temp dir.
  PARALLEL_HOME="$(mktemp -d)"
  export PARALLEL_HOME
  trap 'rm -rf "$PARALLEL_HOME"' EXIT
fi
rc=0
"$bats" ${jobs[@]+"${jobs[@]}"} --filter-tags "$tags" "$@" || rc=$?
if ((vitest)); then
  "$vp" test || rc=$?
fi
exit "$rc"
