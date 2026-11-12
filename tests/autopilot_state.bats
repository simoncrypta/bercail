#!/usr/bin/env bats

setup() {
  load test_helper
  isolate
  SCRIPT="$ROOT/skills/autopilot/scripts/pr-state.sh"
  export GH_BIN="$BATS_TEST_TMPDIR/gh"
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
  cat "$BATS_TEST_TMPDIR/checks.json"
  if [[ -f "$BATS_TEST_TMPDIR/checks-after.json" ]]; then
    mv "$BATS_TEST_TMPDIR/checks-after.json" "$BATS_TEST_TMPDIR/checks.json"
  fi
  exit 8
fi
if [[ "\$1" == "api" && "\$2" == "graphql" ]]; then
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

@test "--wait returns when a pending check finishes" {
  pr
  threads
  printf '[%s]\n' "$(check test pending)" >"$BATS_TEST_TMPDIR/checks.json"
  printf '[%s]\n' "$(check test pass)" >"$BATS_TEST_TMPDIR/checks-after.json"
  local out
  out="$(state --wait 30)"
  jq -e '.next == "green"' <<<"$out" >/dev/null || fail "wait should return the new state: $out"
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
