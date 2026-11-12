#!/usr/bin/env bats
# The suite's own rules.

setup() {
  load test_helper
  isolate
}

@test "every .bats file isolates each test in its setup" {
  local f missing=()
  for f in "$ROOT"/tests/*.bats; do
    grep -Eq '^[[:space:]]+isolate([[:space:]]|$)' "$f" || missing+=("${f##*/}")
  done
  [[ ${#missing[@]} -eq 0 ]] || fail "no isolate in setup: ${missing[*]}"
}

@test "a test cannot see the desk it was started from" {
  [[ "$HOME" == "$BATS_TEST_TMPDIR/home" ]] || fail "HOME is $HOME"
  [[ "$XDG_STATE_HOME" == "$HOME/.local/state" ]] || fail "XDG_STATE_HOME is $XDG_STATE_HOME"
  [[ "$TMPDIR" == "$BATS_TEST_TMPDIR/"* ]] || fail "TMPDIR is $TMPDIR"
  local leaked
  leaked="$(compgen -e | grep -E '^(HC|HERDR|BERCAIL|BEADS|BD|HANDOFF)_' || true)"
  [[ -z "$leaked" ]] || fail "desk variables reached the test: $leaked"
}

@test "a test that needs a missing tool skips, and fails under CI" {
  local dir="$BATS_TEST_TMPDIR/nested" out
  mkdir -p "$dir"
  cat >"$dir/needs.bats" <<FIXTURE
setup() {
  load "$ROOT/tests/test_helper"
  isolate
}
@test "needs a tool" {
  need bash no-such-tool-here
}
FIXTURE
  out="$(CI='' "$ROOT/node_modules/.bin/bats" "$dir/needs.bats" 2>&1)" || fail "outside CI the test failed: $out"
  grep -qx 'ok 1 needs a tool # skip no-such-tool-here not found' <<<"$out" || fail "no skip reported: $out"
  out="$(CI=true "$ROOT/node_modules/.bin/bats" "$dir/needs.bats" 2>&1)" && fail "under CI the test passed: $out"
  grep -q 'no-such-tool-here not found; CI must provide it' <<<"$out" || fail "the failure does not name the tool: $out"
}

# bats loses the watchdog's pid before a failed test's exit trap reads it;
# isolate keeps it. Without that, under set -u (lib/common.sh) the failure
# prints nothing, and a serial run waits out the whole BATS_TEST_TIMEOUT.
@test "a failed test under set -u and a timeout still reports, and does not wait it out" {
  local dir="$BATS_TEST_TMPDIR/nested" out mode start
  mkdir -p "$dir"
  cat >"$dir/fails.bats" <<FIXTURE
setup() {
  load "$ROOT/tests/test_helper"
  isolate
  set -u
}
@test "fails" {
  false
}
FIXTURE
  # Serial, then tests side by side (no GNU parallel needed within a file).
  for mode in "" "--jobs 2 --no-parallelize-across-files"; do
    start=$SECONDS
    # shellcheck disable=SC2086 # mode is the flags, split on purpose
    out="$(BATS_TEST_TIMEOUT=20 "$ROOT/node_modules/.bin/bats" $mode "$dir/fails.bats" 2>&1)" \
      && fail "[$mode]: the failing test passed: $out"
    grep -qx 'not ok 1 fails' <<<"$out" || fail "[$mode]: no failure reported: $out"
    [[ $((SECONDS - start)) -lt 15 ]] || fail "[$mode]: waited out the timeout ($((SECONDS - start))s)"
  done
}
