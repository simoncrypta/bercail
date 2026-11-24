#!/usr/bin/env bats
# tests/run.sh without GNU parallel: one bats run per file, side by side.

load test_helper

setup() {
  isolate
  # A copy of the runner in a tree of its own, with the real bats and a vp that
  # passes, so the files it runs are the ones each test writes.
  tree="$BATS_TEST_TMPDIR/tree"
  mkdir -p "$tree/tests" "$tree/lib" "$tree/node_modules/.bin"
  cp "$ROOT/tests/run.sh" "$ROOT/tests/test_helper.bash" "$tree/tests/"
  cp "$ROOT/lib/slots.sh" "$ROOT/lib/toml.sh" "$tree/lib/"
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

# The processes a test below leaves, so they do not outlive it.
teardown() {
  local pids
  [[ ! -s "$MEET/pid" ]] || mapfile -t pids <"$MEET/pid"
  [[ -z "${pids[*]:-}" ]] || kill "${pids[@]}" 2>/dev/null || true
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
  run env BATS_JOBS=8 PATH="$BATS_TEST_TMPDIR/path" bash "$tree/tests/run.sh"
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
  run env BATS_JOBS=8 PATH="$BATS_TEST_TMPDIR/path" bash "$tree/tests/run.sh"
  [[ "$status" -eq 0 ]] || fail "status $status: $output"
  grep -qx '4 tests, 0 failures, 0 skipped' <<<"$output" || fail "no total: $output"
}

@test "run.sh fails the run and shows the failure when one file fails" {
  meet_file a b
  meet_file b a
  printf 'load test_helper\nsetup() { isolate; }\n@test "c fails" {\n  echo the reason\n  false\n}\n' >"$tree/tests/c.bats"
  run env BATS_JOBS=8 PATH="$BATS_TEST_TMPDIR/path" bash "$tree/tests/run.sh"
  [[ "$status" -ne 0 ]] || fail "a failing file passed the run: $output"
  grep -qx 'not ok tests/c.bats' <<<"$output" || fail "no line for c.bats: $output"
  grep -qF 'the reason' <<<"$output" || fail "the failure's output is missing: $output"
  grep -qx '3 tests, 1 failures, 0 skipped' <<<"$output" || fail "no total: $output"
}

@test "run.sh counts a failed teardown_suite as a failed run, not a test" {
  meet_file a b
  meet_file b a
  printf 'setup_suite() { :; }\nteardown_suite() { return 1; }\n' >"$tree/tests/setup_suite.bash"
  run env BATS_JOBS=8 PATH="$BATS_TEST_TMPDIR/path" bash "$tree/tests/run.sh"
  [[ "$status" -ne 0 ]] || fail "a failed teardown_suite passed the run: $output"
  grep -qx '2 tests, 0 failures, 0 skipped' <<<"$output" || fail "wrong total: $output"
}

# bats reads each test file before setup_suite runs, so a GIT_DIR from the
# shell, or a repo above the temp dir, would reach a file's top-level code and
# the git it runs (bercail-m94t).
@test "run.sh starts bats with no GIT_* variable and no repo above it, before any setup runs" {
  local repo="$BATS_TEST_TMPDIR/real"
  git init -q "$repo"
  mkdir "$repo/tmp"
  printf '%s\n' 'load test_helper' 'compgen -e | grep -E "^GIT_" | grep -vx GIT_CEILING_DIRECTORIES >>"$MEET/seen" || true' \
    'git -C "$BATS_RUN_TMPDIR" rev-parse --show-toplevel >>"$MEET/seen" 2>/dev/null || true' \
    'setup() { isolate; }' '@test "top level" { :; }' >"$tree/tests/top.bats"
  run env PATH="$BATS_TEST_TMPDIR/path" TMPDIR="$repo/tmp" GIT_DIR="$repo/.git" GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig" \
    bash "$tree/tests/run.sh" tests/top.bats
  [[ "$status" -eq 0 ]] || fail "status $status: $output"
  [[ ! -s "$MEET/seen" ]] || fail "the test file saw: $(cat "$MEET/seen")"
}

# Tests once wrote the person's handoff log, herdr-core templates and Shep's
# inbox (bercail-fss). Here the runner's HOME stands for the person's: a test
# reaches it through TEST_REAL_HOME, past its own isolated one.
@test "run.sh fails the run when a test writes the person's state, and names the file" {
  printf '%s\n' 'load test_helper' 'setup() { isolate; }' '@test "leaks" {' \
    '  mkdir -p "$TEST_REAL_HOME/.local/state/bercail/shep/inbox"' \
    '  printf "{\"cwd\":\"%s\"}\n" "$HOME" >"$TEST_REAL_HOME/.local/state/bercail/shep/inbox/leak.json"' '}' \
    >"$tree/tests/leak.bats"
  run env PATH="$BATS_TEST_TMPDIR/path" bash "$tree/tests/run.sh" tests/leak.bats
  [[ "$status" -ne 0 ]] || fail "a write to the person's state passed the run: $output"
  grep -qF "$HOME/.local/state/bercail/shep/inbox/leak.json" <<<"$output" || fail "the file is not named: $output"
}

# Shep and other desks write the same folders while the suite runs.
@test "run.sh passes a run while something else writes the person's state" {
  printf '%s\n' 'load test_helper' 'setup() { isolate; }' '@test "another desk" {' \
    '  mkdir -p "$TEST_REAL_HOME/.config/herdr-app"' \
    '  printf "{\"cwd\":\"/home/me/Work/a\"}\n" >"$TEST_REAL_HOME/.config/herdr-app/view.json"' '}' \
    >"$tree/tests/other.bats"
  run env PATH="$BATS_TEST_TMPDIR/path" bash "$tree/tests/run.sh" tests/other.bats
  [[ "$status" -eq 0 ]] || fail "status $status: $output"
}

# Another desk's spawn appends to the handoff log during the run; nothing else
# may change it.
@test "run.sh fails the run when a line already in the handoff log changes or the log goes" {
  local log="$HOME/.local/state/bercail/handoffs.jsonl" change
  for change in 'printf "{\"path\":\"/x\"}\n" >"$log"' 'rm "$log"'; do
    mkdir -p "${log%/*}"
    printf '{"path":"/home/me/Work/a"}\n' >"$log"
    printf '%s\n' 'load test_helper' 'setup() { isolate; }' '@test "rewrites" {' \
      '  log="$TEST_REAL_HOME/.local/state/bercail/handoffs.jsonl"' "  $change" '}' >"$tree/tests/log.bats"
    run env PATH="$BATS_TEST_TMPDIR/path" bash "$tree/tests/run.sh" tests/log.bats
    [[ "$status" -ne 0 ]] || fail "[$change] passed the run: $output"
    grep -qF "$log: lines it had changed or went" <<<"$output" || fail "[$change] the log is not named: $output"
  done
  printf '{"path":"/home/me/Work/a"}\n' >"$log"
  printf '%s\n' 'load test_helper' 'setup() { isolate; }' '@test "another spawn" {' \
    '  echo "{\"path\":\"/home/me/Work/b\"}" >>"$TEST_REAL_HOME/.local/state/bercail/handoffs.jsonl"' '}' >"$tree/tests/log.bats"
  run env PATH="$BATS_TEST_TMPDIR/path" bash "$tree/tests/run.sh" tests/log.bats
  [[ "$status" -eq 0 ]] || fail "an appended spawn failed the run: $output"
}

# A proof once overwrote them with its own deploy, which need not name its run.
@test "run.sh fails the run when a herdr-core template changes, whatever it says" {
  mkdir -p "$HOME/.config/herdr-core/templates"
  printf 'old\n' >"$HOME/.config/herdr-core/templates/bstack-judge.md"
  printf '%s\n' 'load test_helper' 'setup() { isolate; }' '@test "deploys" {' \
    '  echo new >"$TEST_REAL_HOME/.config/herdr-core/templates/bstack-judge.md"' '}' >"$tree/tests/deploy.bats"
  run env PATH="$BATS_TEST_TMPDIR/path" bash "$tree/tests/run.sh" tests/deploy.bats
  [[ "$status" -ne 0 ]] || fail "an overwritten template passed the run: $output"
  grep -qF "$HOME/.config/herdr-core/templates/bstack-judge.md: changed" <<<"$output" || fail "the template is not named: $output"
}

# A stub a test starts in the background outlives it (trail 111 left 82), and
# one started with no environment still has its working dir in the run.
@test "run.sh fails the run when a test leaves a process running, and names it" {
  printf '%s\n' 'load test_helper' 'setup() { isolate; }' '@test "leaves two" {' \
    '  sleep 301 </dev/null >/dev/null 2>&1 3>&- &' '  echo "$!" >>"$MEET/pid"' \
    '  (cd "${BATS_RUN_TMPDIR%/*}" && exec env -i sleep 302 </dev/null >/dev/null 2>&1 3>&-) &' '  echo "$!" >>"$MEET/pid"' '}' \
    >"$tree/tests/stray.bats"
  run env PATH="$BATS_TEST_TMPDIR/path" bash "$tree/tests/run.sh" tests/stray.bats
  local pid pids=()
  mapfile -t pids <"$MEET/pid"
  [[ ${#pids[@]} -eq 2 ]] || fail "the test did not start both: ${pids[*]}"
  [[ "$status" -ne 0 ]] || fail "processes left running passed the run: $output"
  for pid in "${pids[@]}"; do
    grep -qE "^ *$pid sleep$" <<<"$output" || fail "pid $pid is not named: $output"
  done
}
