#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

SCRIPT="$ROOT/skills/autopilot/scripts/pr-state.sh"
export GH_BIN="$TMP_DIR/gh"
export AUTOPILOT_POLL_SECONDS=0

# pr.json, checks.json, threads.json drive the fake; checks-after.json replaces
# checks.json after the first `pr checks` call (a check finishing mid-wait).
cat >"$GH_BIN" <<FAKE
#!/usr/bin/env bash
set -euo pipefail
if [[ "\$1" == "pr" && "\$2" == "view" ]]; then
  [[ -f "$TMP_DIR/pr.json" ]] || { echo "no pull requests found" >&2; exit 1; }
  cat "$TMP_DIR/pr.json"
  exit 0
fi
if [[ "\$1" == "pr" && "\$2" == "checks" ]]; then
  cat "$TMP_DIR/checks.json"
  if [[ -f "$TMP_DIR/checks-after.json" ]]; then
    mv "$TMP_DIR/checks-after.json" "$TMP_DIR/checks.json"
  fi
  exit 8
fi
if [[ "\$1" == "api" && "\$2" == "graphql" ]]; then
  cat "$TMP_DIR/threads.json"
  exit 0
fi
echo "unexpected gh: \$*" >&2
exit 1
FAKE
chmod +x "$GH_BIN"

pr() {
  printf '{"number":7,"url":"https://github.com/o/r/pull/7","state":"%s","isDraft":false,"headRefName":"fix","headRefOid":"abc","baseRefName":"master","mergeable":"%s","mergeStateStatus":"CLEAN","reviewDecision":""}\n' \
    "${1:-OPEN}" "${2:-MERGEABLE}" >"$TMP_DIR/pr.json"
}
threads() {
  printf '{"data":{"viewer":{"login":"me"},"repository":{"pullRequest":{"reviewThreads":{"nodes":%s}}}}}\n' \
    "${1:-[]}" >"$TMP_DIR/threads.json"
}
check() { printf '{"name":"%s","bucket":"%s","state":"x","workflow":"ci","link":"https://github.com/o/r/actions/runs/%s/job/1"}' "$1" "$2" "${3:-1}"; }

state() { "$SCRIPT" --repo "$TMP_DIR" "$@"; }

test_no_pr() {
  rm -f "$TMP_DIR/pr.json"
  local rc=0
  state >/dev/null 2>&1 || rc=$?
  [[ "$rc" -eq 2 ]] || fail "no PR should exit 2, got $rc"
  printf 'PASS: no PR exits 2\n'
}

test_failing_check_comes_first() {
  pr; threads '[{"id":"T1","isResolved":false,"isOutdated":false,"path":"a.sh","line":3,"comments":{"nodes":[{"author":{"login":"rev","__typename":"User"},"body":"bug","url":"u"}]}}]'
  printf '[%s,%s]\n' "$(check lint fail 42)" "$(check test pass)" >"$TMP_DIR/checks.json"
  local out
  out="$(state)"
  jq -e '.next == "fix-ci" and .checks.fail == 1 and .checks.pass == 1' <<<"$out" >/dev/null || fail "fix-ci: $out"
  jq -e '.failing[0].run == "42" and .failing[0].name == "lint"' <<<"$out" >/dev/null || fail "run id: $out"
  jq -e '.threads | length == 1' <<<"$out" >/dev/null || fail "threads listed: $out"
  printf 'PASS: a failing check comes first and carries its run id\n'
}

test_threads_filter() {
  pr
  printf '[%s]\n' "$(check test pass)" >"$TMP_DIR/checks.json"
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
  printf 'PASS: resolved threads and threads we answered last are skipped\n'
}

test_conflicts_and_terminal() {
  pr OPEN CONFLICTING; threads
  printf '[%s]\n' "$(check test fail)" >"$TMP_DIR/checks.json"
  jq -e '.next == "conflicts"' <<<"$(state)" >/dev/null || fail "conflicts before CI"
  pr MERGED
  jq -e '.next == "merged"' <<<"$(state)" >/dev/null || fail "merged"
  pr; printf '[%s]\n' "$(check test pass)" >"$TMP_DIR/checks.json"
  jq -e '.next == "green"' <<<"$(state)" >/dev/null || fail "green"
  printf 'PASS: conflicts, merged, and green\n'
}

test_wait_returns_on_change() {
  pr; threads
  printf '[%s]\n' "$(check test pending)" >"$TMP_DIR/checks.json"
  printf '[%s]\n' "$(check test pass)" >"$TMP_DIR/checks-after.json"
  local out
  out="$(state --wait 30)"
  jq -e '.next == "green"' <<<"$out" >/dev/null || fail "wait should return the new state: $out"
  printf 'PASS: --wait returns when a pending check finishes\n'
}

test_wait_times_out() {
  pr; threads
  printf '[%s]\n' "$(check test pending)" >"$TMP_DIR/checks.json"
  local rc=0 out
  out="$(state --wait 1)" || rc=$?
  [[ "$rc" -eq 124 ]] || fail "wait timeout should exit 124, got $rc"
  jq -e '.next == "wait-ci"' <<<"$out" >/dev/null || fail "timeout prints the snapshot: $out"
  printf 'PASS: --wait times out with exit 124\n'
}

test_no_pr
test_failing_check_comes_first
test_threads_filter
test_conflicts_and_terminal
test_wait_returns_on_change
test_wait_times_out
