#!/usr/bin/env bats
# Review's remote reads and transfers are bounded, against a fake gh only.

setup() {
  load test_helper
  isolate
  bats_require_minimum_version 1.5.0
  need timeout
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  export GH_LOG="$BATS_TEST_TMPDIR/gh.log" GH_PID="$BATS_TEST_TMPDIR/gh.pid"
  export REVIEW_RESULT="$BATS_TEST_TMPDIR/result"
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_LOG"
if [[ "${GH_HANG:-}" == 1 ]]; then
  printf '%s\n' "$$" >"$GH_PID"
  sleep 60 &
  wait
fi
printf 'stdout\n'
printf 'stderr\n' >&2
exit "${GH_EXIT:-0}"
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

# The outer deadline makes a regression fail instead of hanging the suite. A
# result file distinguishes the inner deadline from that emergency timeout.
review_call() {
  timeout 8 bash -c '
    source "$1/lib/review.sh"
    STACK_GH_TIMEOUT=1 STACK_GH_TRANSFER_TIMEOUT=1
    shift
    "$@"
    rc=$?
    printf "%s\n" "$rc" >"$REVIEW_RESULT"
    exit "$rc"
  ' _ "$ROOT" "$@"
}

@test "a hung review PR read fails at its own deadline and kills gh" {
  export GH_HANG=1
  run review_call _review_pr_view 7 github.com/acme/repo
  [[ "$status" == 124 ]] || fail "review PR read: $status $output"
  [[ "$(cat "$REVIEW_RESULT")" == 124 ]] || fail "only the emergency timeout ended the read"
  grep -qx 'pr view 7 -R github.com/acme/repo --json .*' "$GH_LOG" || fail "the fake gh was not called"
  if kill -0 "$(cat "$GH_PID")" 2>/dev/null; then fail "gh survived its deadline"; fi
}

@test "a hung stack list or clone returns 124 before the emergency timeout" {
  export GH_HANG=1
  local call
  for call in list clone; do
    rm -f "$REVIEW_RESULT"
    if [[ "$call" == list ]]; then
      run review_call _stack_gh_list github.com/acme/repo head feature
    else
      run review_call _stack_gh repo clone github.com/acme/repo "$BATS_TEST_TMPDIR/clone" -- --quiet
    fi
    [[ "$status" == 124 ]] || fail "$call: $status $output"
    [[ "$(cat "$REVIEW_RESULT")" == 124 ]] || fail "only the emergency timeout ended $call"
    if kill -0 "$(cat "$GH_PID")" 2>/dev/null; then fail "gh survived $call's deadline"; fi
  done
}

@test "bounded review gh keeps stdout, stderr, and a nonzero command status" {
  export GH_EXIT=17
  run --separate-stderr review_call _stack_gh pr view 7
  [[ "$status" == 17 && "$output" == stdout && "$stderr" == stderr ]] \
    || fail "bounded gh changed its result: $status / $output / $stderr"
  [[ "$(cat "$REVIEW_RESULT")" == 17 ]] || fail "the command did not finish normally"
}
