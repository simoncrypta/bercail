#!/usr/bin/env bats

setup() {
  load test_helper
  bats_require_minimum_version 1.5.0
  isolate
  SCRIPT="$ROOT/skills/autopilot/scripts/pr-state.sh"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  export GH_BIN="$BATS_TEST_TMPDIR/bin/gh"
  export AUTOPILOT_POLL_SECONDS=0

  # pr.json, checks.json, threads.json drive the fake; checks-after.json replaces
  # checks.json after the first `pr checks` call (a check finishing mid-wait).
  cat >"$GH_BIN" <<FAKE
#!/usr/bin/env bash
set -euo pipefail
if [[ "\$1" == "pr" && "\$2" == "view" ]]; then
  [[ -f "$BATS_TEST_TMPDIR/pr.json" ]] || { echo "no pull requests found" >&2; exit 1; }
  cat "$BATS_TEST_TMPDIR/pr.json"
  exit 0
fi
if [[ "\$1" == "pr" && "\$2" == "checks" ]]; then
  echo checks >>"$BATS_TEST_TMPDIR/calls"
  if [[ -f "$BATS_TEST_TMPDIR/checks-error" ]]; then
    cat "$BATS_TEST_TMPDIR/checks-error" >&2
    [[ ! -f "$BATS_TEST_TMPDIR/recover" ]] || rm "$BATS_TEST_TMPDIR/checks-error"
    exit 1
  fi
  cat "$BATS_TEST_TMPDIR/checks.json"
  if [[ -f "$BATS_TEST_TMPDIR/checks-after.json" ]]; then
    mv "$BATS_TEST_TMPDIR/checks-after.json" "$BATS_TEST_TMPDIR/checks.json"
  fi
  if [[ -f "$BATS_TEST_TMPDIR/checks-after-error" ]]; then
    mv "$BATS_TEST_TMPDIR/checks-after-error" "$BATS_TEST_TMPDIR/checks-error"
  fi
  exit "\$(cat "$BATS_TEST_TMPDIR/checks-exit" 2>/dev/null || echo 8)"
fi
if [[ "\$1" == "api" && "\$2" == "graphql" ]]; then
  if [[ -f "$BATS_TEST_TMPDIR/threads-error" ]]; then
    cat "$BATS_TEST_TMPDIR/threads-error" >&2
    exit 1
  fi
  cat "$BATS_TEST_TMPDIR/threads.json"
  exit 0
fi
echo "unexpected gh: \$*" >&2
exit 1
FAKE
  chmod +x "$GH_BIN"
}

pr() {
  printf '{"number":7,"url":"https://github.com/o/r/pull/7","state":"%s","isDraft":false,"headRefName":"fix","headRefOid":"abc","baseRefName":"master","mergeable":"%s","mergeStateStatus":"CLEAN","reviewDecision":""}\n' \
    "${1:-OPEN}" "${2:-MERGEABLE}" >"$BATS_TEST_TMPDIR/pr.json"
}
threads() {
  printf '{"data":{"viewer":{"login":"me"},"repository":{"pullRequest":{"reviewThreads":{"nodes":%s}}}}}\n' \
    "${1:-[]}" >"$BATS_TEST_TMPDIR/threads.json"
}
check() { printf '{"name":"%s","bucket":"%s","state":"x","workflow":"ci","link":"https://github.com/o/r/actions/runs/%s/job/1"}' "$1" "$2" "${3:-1}"; }

state() { "$SCRIPT" --repo "$BATS_TEST_TMPDIR" "$@"; }

@test "no PR exits 2" {
  rm -f "$BATS_TEST_TMPDIR/pr.json"
  local rc=0
  state >/dev/null 2>&1 || rc=$?
  [[ "$rc" -eq 2 ]] || fail "no PR should exit 2, got $rc"
}

@test "a failing check comes first and carries its run id" {
  pr
  threads '[{"id":"T1","isResolved":false,"isOutdated":false,"path":"a.sh","line":3,"comments":{"nodes":[{"author":{"login":"rev","__typename":"User"},"body":"bug","url":"u"}]}}]'
  printf '[%s,%s]\n' "$(check lint fail 42)" "$(check test pass)" >"$BATS_TEST_TMPDIR/checks.json"
  local out
  out="$(state)"
  jq -e '.next == "fix-ci" and .checks.fail == 1 and .checks.pass == 1' <<<"$out" >/dev/null || fail "fix-ci: $out"
  jq -e '.failing[0].run == "42" and .failing[0].name == "lint"' <<<"$out" >/dev/null || fail "run id: $out"
  jq -e '.threads | length == 1' <<<"$out" >/dev/null || fail "threads listed: $out"
}

@test "resolved threads and threads we answered last are skipped" {
  pr
  printf '[%s]\n' "$(check test pass)" >"$BATS_TEST_TMPDIR/checks.json"
  threads '[
    {"id":"open","isResolved":false,"isOutdated":false,"path":"a.sh","line":1,"comments":{"nodes":[{"author":{"login":"coderabbitai[bot]","__typename":"Bot"},"body":"nit","url":"u1"}]}},
    {"id":"resolved","isResolved":true,"isOutdated":false,"path":"a.sh","line":2,"comments":{"nodes":[{"author":{"login":"rev","__typename":"User"},"body":"x","url":"u2"}]}},
    {"id":"answered","isResolved":false,"isOutdated":false,"path":"a.sh","line":3,"comments":{"nodes":[{"author":{"login":"rev","__typename":"User"},"body":"why?","url":"u3"},{"author":{"login":"me","__typename":"User"},"body":"because","url":"u4"}]}}
  ]'
  local out
  out="$(state)"
  jq -e '.next == "answer-threads"' <<<"$out" >/dev/null || fail "answer-threads: $out"
  jq -e '[.threads[].id] == ["open"] and .threads[0].bot == true' <<<"$out" >/dev/null \
    || fail "only the unanswered thread, flagged bot: $out"
}

# Split from "conflicts, merged, and green": three inputs, three next-states.
# merged and green each arrange the files the old case left over from the line above.

@test "conflicts come before a failing check" {
  pr OPEN CONFLICTING
  threads
  printf '[%s]\n' "$(check test fail)" >"$BATS_TEST_TMPDIR/checks.json"
  jq -e '.next == "conflicts"' <<<"$(state)" >/dev/null || fail "conflicts before CI"
}

@test "a merged PR is next merged" {
  pr MERGED
  threads
  printf '[%s]\n' "$(check test fail)" >"$BATS_TEST_TMPDIR/checks.json"
  jq -e '.next == "merged"' <<<"$(state)" >/dev/null || fail "merged"
}

@test "passing checks and no threads are green" {
  pr
  threads
  printf '[%s]\n' "$(check test pass)" >"$BATS_TEST_TMPDIR/checks.json"
  jq -e '.next == "green"' <<<"$(state)" >/dev/null || fail "green"
}

@test "unreadable checks exit 3 without a snapshot and preserve gh diagnostics" {
  pr
  threads
  printf 'HTTP 502: checks unavailable\n' >"$BATS_TEST_TMPDIR/checks-error"
  run --separate-stderr state
  [[ "$status" -eq 3 ]] || fail "expected read failure, got $status: $output"
  [[ -z "$output" ]] || fail "read failure printed a snapshot: $output"
  [[ "$stderr" == *'HTTP 502: checks unavailable'* ]] || fail "missing gh diagnostic: $stderr"
}

@test "unreadable threads exit 3 without a snapshot and preserve gh diagnostics" {
  pr
  threads
  printf '[]\n' >"$BATS_TEST_TMPDIR/checks.json"
  printf 'GraphQL: rate limit exceeded\n' >"$BATS_TEST_TMPDIR/threads-error"
  run --separate-stderr state
  [[ "$status" -eq 3 && -z "$output" ]] || fail "expected no snapshot and exit 3, got $status: $output"
  [[ "$stderr" == *'GraphQL: rate limit exceeded'* ]] || fail "missing gh diagnostic: $stderr"
}

@test "malformed checks and incomplete GraphQL responses are unreadable" {
  pr
  threads
  printf 'not JSON\n' >"$BATS_TEST_TMPDIR/checks.json"
  run --separate-stderr state
  [[ "$status" -eq 3 && -z "$output" && -n "$stderr" ]] || fail "malformed checks: $status $output $stderr"

  printf '[]\n' >"$BATS_TEST_TMPDIR/checks.json"
  printf '{"data":{}}\n' >"$BATS_TEST_TMPDIR/threads.json"
  run --separate-stderr state
  [[ "$status" -eq 3 && -z "$output" && -n "$stderr" ]] || fail "incomplete threads: $status $output $stderr"
}

@test "GraphQL errors with partial data are unreadable" {
  pr
  threads
  printf '[]\n' >"$BATS_TEST_TMPDIR/checks.json"
  jq '. + {errors:[{message:"thread access denied"}]}' "$BATS_TEST_TMPDIR/threads.json" >"$BATS_TEST_TMPDIR/partial.json"
  mv "$BATS_TEST_TMPDIR/partial.json" "$BATS_TEST_TMPDIR/threads.json"
  run --separate-stderr state
  [[ "$status" -eq 3 && -z "$output" && -n "$stderr" ]] || fail "partial GraphQL: $status $output $stderr"
}

@test "a PR with no checks is green" {
  pr
  threads
  printf "no checks reported on the 'fix' branch\n" >"$BATS_TEST_TMPDIR/checks-error"
  run --separate-stderr state
  [[ "$status" -eq 0 ]] || fail "no checks is readable: $status $stderr"
  jq -e '.next == "green" and .checks == {pass:0,fail:0,pending:0,skipping:0}' <<<"$output" >/dev/null
}

@test "valid failing check JSON is readable when gh exits 1" {
  pr
  threads
  printf '[%s]\n' "$(check test fail)" >"$BATS_TEST_TMPDIR/checks.json"
  printf '1\n' >"$BATS_TEST_TMPDIR/checks-exit"
  jq -e '.next == "fix-ci" and .checks.fail == 1' <<<"$(state)" >/dev/null
}

@test "--wait retries an initial read failure and recovers" {
  pr
  threads
  printf '[%s]\n' "$(check test pass)" >"$BATS_TEST_TMPDIR/checks.json"
  printf 'HTTP 502\n' >"$BATS_TEST_TMPDIR/checks-error"
  touch "$BATS_TEST_TMPDIR/recover"
  run --separate-stderr state --wait 1
  [[ "$status" -eq 0 ]] || fail "recovery: $status $output $stderr"
  jq -e '.next == "green"' <<<"$output" >/dev/null
  [[ "$(wc -l <"$BATS_TEST_TMPDIR/calls")" -ge 2 ]] || fail "failed read was not retried"
}

@test "--wait exits 3 without stdout when reads keep failing" {
  pr
  threads
  printf 'HTTP 502\n' >"$BATS_TEST_TMPDIR/checks-error"
  run --separate-stderr state --wait 1
  [[ "$status" -eq 3 && -z "$output" ]] || fail "unreadable timeout: $status $output"
  [[ "$stderr" == *'HTTP 502'* ]] || fail "missing diagnostic: $stderr"
  [[ "$(wc -l <"$BATS_TEST_TMPDIR/calls")" -ge 2 ]] || fail "failed read was not retried"
}

@test "--wait does not print a stale pending snapshot after the latest read fails" {
  pr
  threads
  printf '[%s]\n' "$(check test pending)" >"$BATS_TEST_TMPDIR/checks.json"
  printf 'HTTP 502\n' >"$BATS_TEST_TMPDIR/checks-after-error"
  run --separate-stderr state --wait 1
  [[ "$status" -eq 3 && -z "$output" ]] || fail "stale timeout: $status $output"
  [[ "$stderr" == *'HTTP 502'* ]] || fail "missing diagnostic: $stderr"
}

@test "--wait returns when a pending check finishes" {
  pr
  threads
  printf '[%s]\n' "$(check test pending)" >"$BATS_TEST_TMPDIR/checks.json"
  printf '[%s]\n' "$(check test pass)" >"$BATS_TEST_TMPDIR/checks-after.json"
  local out
  out="$(state --wait 30)"
  jq -e '.next == "green"' <<<"$out" >/dev/null || fail "wait should return the new state: $out"
}

@test "--wait caps the poll sleep at its remaining deadline" {
  pr
  threads
  printf '[%s]\n' "$(check test pending)" >"$BATS_TEST_TMPDIR/checks.json"
  export AUTOPILOT_POLL_SECONDS=30
  cat >"$BATS_TEST_TMPDIR/bin/sleep" <<FAKE
#!/usr/bin/env bash
printf '%s\\n' "\$@" >>"$BATS_TEST_TMPDIR/sleeps"
FAKE
  chmod +x "$BATS_TEST_TMPDIR/bin/sleep"
  run --separate-stderr state --wait 1
  [[ "$status" -eq 124 ]] || fail "pending timeout: $status $output $stderr"
  [[ -s "$BATS_TEST_TMPDIR/sleeps" ]] || fail "poll did not sleep"
  awk '$1 > 1 || $1 <= 0 {exit 1}' "$BATS_TEST_TMPDIR/sleeps" || fail "sleep exceeded deadline"
}

@test "--wait times out with exit 124" {
  pr
  threads
  printf '[%s]\n' "$(check test pending)" >"$BATS_TEST_TMPDIR/checks.json"
  local rc=0 out
  out="$(state --wait 1)" || rc=$?
  [[ "$rc" -eq 124 ]] || fail "wait timeout should exit 124, got $rc"
  jq -e '.next == "wait-ci"' <<<"$out" >/dev/null || fail "timeout prints the snapshot: $out"
}
