#!/usr/bin/env bats
# tests/run.sh without GNU parallel: one bats run per file, side by side.

load test_helper

setup() {
  isolate
  # A copy of the runner in a tree of its own, with the real bats and a vp that
  # passes, so the files it runs are the ones each test writes.
  tree="$BATS_TEST_TMPDIR/tree"
  mkdir -p "$tree/tests" "$tree/node_modules/.bin"
  cp "$ROOT/tests/run.sh" "$ROOT/tests/test_helper.bash" "$tree/tests/"
  ln -s "$ROOT/node_modules/bats/bin/bats" "$tree/node_modules/.bin/bats"
  printf '#!/bin/sh\nexit 0\n' >"$tree/node_modules/.bin/vp"
  chmod +x "$tree/node_modules/.bin/vp"
  # Every command on PATH but GNU parallel, which the CI runner has.
  local dir
  mkdir -p "$BATS_TEST_TMPDIR/path"
  while IFS= read -r -d: dir; do
    [[ -d "$dir" ]] && ln -s "$dir"/* "$BATS_TEST_TMPDIR/path/" 2>/dev/null || true
  done <<<"$PATH:"
  rm -f "$BATS_TEST_TMPDIR/path/parallel"
  export MEET="$BATS_TEST_TMPDIR/meet"
  mkdir -p "$MEET"
}

# A file whose one test passes only when the file named OTHER runs alongside it.
# printf, not a heredoc: bats rewrites any line here that starts with @test.
meet_file() {
  local name="$1" other="$2"
  # shellcheck disable=SC2016 # expands when the test runs
  printf '%s\n' 'load test_helper' 'setup() { isolate; }' "@test \"$name meets $other\" {" \
    "  touch \"\$MEET/$name\"" '  for _ in $(seq 300); do' \
    "    [[ -e \"\$MEET/$other\" ]] && return 0" '    sleep 0.1' '  done' '  return 1' '}' \
    >"$tree/tests/$name.bats"
}

@test "run.sh runs the files side by side without GNU parallel" {
  meet_file a b
  meet_file b a
  run env -u BATS_JOBS PATH="$BATS_TEST_TMPDIR/path" bash "$tree/tests/run.sh"
  [[ "$status" -eq 0 ]] || fail "status $status: $output"
  grep -qx 'ok tests/a.bats' <<<"$output" || fail "no line for a.bats: $output"
  grep -qx '2 tests, 0 failures, 0 skipped' <<<"$output" || fail "no total: $output"
}

@test "run.sh runs a file's tests side by side without GNU parallel" {
  meet_file a b
  meet_file b a
  cat "$tree/tests/b.bats" >>"$tree/tests/a.bats"
  rm "$tree/tests/b.bats"
  meet_file c d
  meet_file d c
  run env -u BATS_JOBS PATH="$BATS_TEST_TMPDIR/path" bash "$tree/tests/run.sh"
  [[ "$status" -eq 0 ]] || fail "status $status: $output"
  grep -qx '4 tests, 0 failures, 0 skipped' <<<"$output" || fail "no total: $output"
}

@test "run.sh fails the run and shows the failure when one file fails" {
  meet_file a b
  meet_file b a
  printf 'load test_helper\nsetup() { isolate; }\n@test "c fails" {\n  echo the reason\n  false\n}\n' >"$tree/tests/c.bats"
  run env -u BATS_JOBS PATH="$BATS_TEST_TMPDIR/path" bash "$tree/tests/run.sh"
  [[ "$status" -ne 0 ]] || fail "a failing file passed the run: $output"
  grep -qx 'not ok tests/c.bats' <<<"$output" || fail "no line for c.bats: $output"
  grep -qF 'the reason' <<<"$output" || fail "the failure's output is missing: $output"
  grep -qx '3 tests, 1 failures, 0 skipped' <<<"$output" || fail "no total: $output"
}

@test "run.sh counts a failed teardown_suite as a failed run, not a test" {
  meet_file a b
  meet_file b a
  printf 'setup_suite() { :; }\nteardown_suite() { return 1; }\n' >"$tree/tests/setup_suite.bash"
  run env -u BATS_JOBS PATH="$BATS_TEST_TMPDIR/path" bash "$tree/tests/run.sh"
  [[ "$status" -ne 0 ]] || fail "a failed teardown_suite passed the run: $output"
  grep -qx '2 tests, 0 failures, 0 skipped' <<<"$output" || fail "wrong total: $output"
}
