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
