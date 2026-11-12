#!/usr/bin/env bash
# shellcheck shell=bash
# Runs the unit suite, or the .bats files named. Each @test gets its own HOME
# (test_helper.bash); setup_suite.bash cuts the run off from the desk it ran in.
# The live proofs (real Pi, tagged `live`) run only with --live.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
bats=node_modules/.bin/bats
[[ -x "$bats" ]] || { printf 'tests/run.sh: bats is missing; run npm ci\n' >&2; exit 1; }
tags='!live'
if [[ "${1:-}" == --live ]]; then
  tags=live
  shift
fi
# A hung test fails itself, not the whole run.
export BATS_TEST_TIMEOUT="${BATS_TEST_TIMEOUT:-300}"
# Options pass through to bats; with no file or folder named, run them all.
named=0
for arg in "$@"; do
  [[ ! -e "$arg" ]] || named=1
done
((named)) || set -- "$@" tests
exec "$bats" --filter-tags "$tags" "$@"
