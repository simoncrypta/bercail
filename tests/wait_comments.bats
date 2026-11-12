#!/usr/bin/env bats
# wait-comments.sh against a fake tuicr: exit codes and which comments it prints.

setup() {
  load test_helper
  isolate
  SCRIPT="$ROOT/skills/review/scripts/wait-comments.sh"
  export WAIT_COMMENTS_POLL_SECONDS=0
  export TUICR_BIN="$BATS_TEST_TMPDIR/tuicr"

  # The fake tuicr answers its first call of each kind from <kind>.before and
  # every later call from <kind>.after (falling back to .before). The script
  # takes its baseline on the first call, so each scenario changes state right
  # after the baseline without racing a background writer.
  cat >"$TUICR_BIN" <<FAKE
#!/usr/bin/env bash
set -euo pipefail
serve() {
  local kind="\$1" count_file="$BATS_TEST_TMPDIR/\$1.count" n=0
  [[ -f "\$count_file" ]] && n="\$(cat "\$count_file")"
  n=\$((n + 1))
  printf '%s' "\$n" >"\$count_file"
  if (( n > 1 )) && [[ -f "$BATS_TEST_TMPDIR/\$kind.after" ]]; then
    cat "$BATS_TEST_TMPDIR/\$kind.after"
  elif [[ -f "$BATS_TEST_TMPDIR/\$kind.before" ]]; then
    cat "$BATS_TEST_TMPDIR/\$kind.before"
  else
    return 1
  fi
}
case "\$1 \$2" in
  "review list") serve list || printf '%s\n' '[]' ;;
  "review comments") serve comments || { echo "no session" >&2; exit 1; } ;;
  *) echo "unexpected: \$*" >&2; exit 1 ;;
esac
FAKE
  chmod +x "$TUICR_BIN"

  SESSION='[{"slug":"local/worktree","kind":"local","active":true}]'
  OLD='[{"id":"user:1","author":"user","content":"old"}]'
}

# scenario <list.before> <list.after|-> <comments.before|-> <comments.after|->
scenario() {
  printf '%s\n' "$1" >"$BATS_TEST_TMPDIR/list.before"
  [[ "$2" == "-" ]] || printf '%s\n' "$2" >"$BATS_TEST_TMPDIR/list.after"
  [[ "$3" == "-" ]] || printf '%s\n' "$3" >"$BATS_TEST_TMPDIR/comments.before"
  [[ "$4" == "-" ]] || printf '%s\n' "$4" >"$BATS_TEST_TMPDIR/comments.after"
}

@test "wait-comments exits 2 when no session exists" {
  local rc=0
  scenario '[]' - - -
  "$SCRIPT" --repo . --timeout 1 >/dev/null || rc=$?
  [[ "$rc" -eq 2 ]] || fail "missing session should exit 2, got $rc"
}

@test "wait-comments prints new user comments and exits 0" {
  local out rc=0
  scenario "$SESSION" - "$OLD" \
    '[{"id":"user:1","author":"user","content":"old"},{"id":"user:2","author":"user","content":"new note"}]'
  out="$("$SCRIPT" --repo . --timeout 5)" || rc=$?
  [[ "$rc" -eq 0 ]] || fail "new comment should exit 0, got $rc"
  printf '%s' "$out" | jq -e '.comments | length == 1' >/dev/null \
    || fail "should emit only new comments: $out"
  printf '%s' "$out" | jq -e '.comments[0].id == "user:2"' >/dev/null \
    || fail "should emit user:2, got $out"
}

@test "wait-comments ignores agent-authored comments" {
  local rc=0
  scenario "$SESSION" - "$OLD" \
    '[{"id":"user:1","author":"user","content":"old"},{"id":"agent:1","author":"pi","content":"ai note"}]'
  "$SCRIPT" --repo . --timeout 1 >/dev/null || rc=$?
  [[ "$rc" -eq 124 ]] || fail "agent-only new comments should timeout, got $rc"
}

@test "wait-comments exits 2 when the session disappears" {
  local rc=0
  scenario "$SESSION" '[]' "$OLD" -
  "$SCRIPT" --repo . --timeout 5 >/dev/null || rc=$?
  [[ "$rc" -eq 2 ]] || fail "session gone should exit 2, got $rc"
}

@test "wait-comments exits 124 on timeout" {
  local rc=0
  scenario "$SESSION" - '[]' -
  "$SCRIPT" --repo . --timeout 1 >/dev/null || rc=$?
  [[ "$rc" -eq 124 ]] || fail "timeout should exit 124, got $rc"
}
