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

# A dev box has node in /usr/bin and the runner does not: a test that leans on
# that passes here and fails in CI unless it fails here too.
@test "a test runs Node only once it says need node, even with /usr/bin on PATH" {
  local dir="$BATS_TEST_TMPDIR/nested" out
  mkdir -p "$dir"
  cat >"$dir/node.bats" <<FIXTURE
setup() {
  load "$ROOT/tests/test_helper"
  isolate
  export PATH="\$BATS_TEST_TMPDIR/bin:/usr/bin:/bin"
}
@test "undeclared" {
  node -e 0
}
@test "declared" {
  need node
  node -e 0
}
FIXTURE
  out="$("$ROOT/node_modules/.bin/bats" "$dir/node.bats" 2>&1)" && fail "a test ran Node without need node: $out"
  grep -qx 'not ok 1 undeclared' <<<"$out" || fail "the undeclared test did not fail: $out"
  grep -q 'add need node to it' <<<"$out" || fail "the failure does not name the fix: $out"
  grep -qx 'ok 2 declared' <<<"$out" || fail "need node did not give the test Node: $out"
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

# verify-bercail checks that the suite leaves the real handoffs.jsonl alone.
# Another desk spawning during the run is not the suite's doing.
@test "verify's canary: another desk's spawn passes and is kept; a line naming the run's temp root fails" {
  local canary="$ROOT/.agents/skills/verify-bercail/handoffs-canary.sh" dir="$BATS_TEST_TMPDIR/canary"
  local root="$dir/run" log="$dir/handoffs.jsonl" before="$dir/before.jsonl" added="$dir/added.jsonl" out
  mkdir -p "$root"
  printf '{"path":"/home/me/Work/a"}\n' >"$log"
  cp "$log" "$before"
  "$canary" "$log" "$before" "$root" "$added" || fail "an untouched log failed"
  [[ ! -e "$added" ]] || fail "nothing was added, yet $added was written"
  printf '{"path":"/home/me/Work/b"}\n' >>"$log"
  out="$("$canary" "$log" "$before" "$root" "$added" 2>&1)" || fail "another desk's spawn failed: $out"
  grep -qx '{"path":"/home/me/Work/b"}' "$added" || fail "the added line was not kept: $(cat "$added")"
  printf '{"path":"%s/bats-run-1/test/1/wt"}\n' "$root" >>"$log"
  out="$("$canary" "$log" "$before" "$root" "$added" 2>&1)" && fail "a line from the run passed"
  grep -qF 'a test wrote the real handoff log' <<<"$out" || fail "no reason given: $out"
}

@test "verify's canary: a line already in the log that changed fails, even with nothing added" {
  local canary="$ROOT/.agents/skills/verify-bercail/handoffs-canary.sh" dir="$BATS_TEST_TMPDIR/canary" out
  mkdir -p "$dir/run"
  printf '{"path":"/home/me/Work/a"}\n' >"$dir/before.jsonl"
  printf '{"path":"/home/me/Work/x"}\n' >"$dir/handoffs.jsonl"
  out="$("$canary" "$dir/handoffs.jsonl" "$dir/before.jsonl" "$dir/run" "$dir/added.jsonl" 2>&1)" && fail "a changed line passed"
  grep -qF 'lines already in the handoff log changed' <<<"$out" || fail "no reason given: $out"
  rm "$dir/handoffs.jsonl"
  "$canary" "$dir/handoffs.jsonl" "$dir/before.jsonl" "$dir/run" "$dir/added.jsonl" 2>/dev/null && fail "a deleted log passed"
  true
}
