#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

SCRIPT="$ROOT/skills/review/scripts/wait-comments.sh"
export WAIT_COMMENTS_POLL_SECONDS=0
export TUICR_BIN="$TMP_DIR/tuicr"

# The fake tuicr answers its first call of each kind from <kind>.before and
# every later call from <kind>.after (falling back to .before). The script
# takes its baseline on the first call, so each scenario changes state right
# after the baseline without racing a background writer.
cat >"$TUICR_BIN" <<FAKE
#!/usr/bin/env bash
set -euo pipefail
serve() {
  local kind="\$1" count_file="$TMP_DIR/\$1.count" n=0
  [[ -f "\$count_file" ]] && n="\$(cat "\$count_file")"
  n=\$((n + 1))
  printf '%s' "\$n" >"\$count_file"
  if (( n > 1 )) && [[ -f "$TMP_DIR/\$kind.after" ]]; then
    cat "$TMP_DIR/\$kind.after"
  elif [[ -f "$TMP_DIR/\$kind.before" ]]; then
    cat "$TMP_DIR/\$kind.before"
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

# scenario <list.before> <list.after|-> <comments.before|-> <comments.after|->
scenario() {
  rm -f "$TMP_DIR"/list.* "$TMP_DIR"/comments.*
  printf '%s\n' "$1" >"$TMP_DIR/list.before"
  [[ "$2" == "-" ]] || printf '%s\n' "$2" >"$TMP_DIR/list.after"
  [[ "$3" == "-" ]] || printf '%s\n' "$3" >"$TMP_DIR/comments.before"
  [[ "$4" == "-" ]] || printf '%s\n' "$4" >"$TMP_DIR/comments.after"
}

OLD='[{"id":"user:1","author":"user","content":"old"}]'

# No session → 2
scenario '[]' - - -
set +e
"$SCRIPT" --repo . --timeout 1 >/dev/null
rc=$?
set -e
[[ "$rc" -eq 2 ]] || fail "missing session should exit 2, got $rc"
printf 'PASS: wait-comments exits 2 when no session exists\n'

# Baseline then new comment → 0
scenario "$SESSION" - "$OLD" \
  '[{"id":"user:1","author":"user","content":"old"},{"id":"user:2","author":"user","content":"new note"}]'
set +e
out="$("$SCRIPT" --repo . --timeout 5)"
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "new comment should exit 0, got $rc"
printf '%s' "$out" | jq -e '.comments | length == 1' >/dev/null \
  || fail "should emit only new comments: $out"
printf '%s' "$out" | jq -e '.comments[0].id == "user:2"' >/dev/null \
  || fail "should emit user:2, got $out"
printf 'PASS: wait-comments prints new user comments and exits 0\n'

# Agent comments must not count as human notes
scenario "$SESSION" - "$OLD" \
  '[{"id":"user:1","author":"user","content":"old"},{"id":"agent:1","author":"cursor-agent","content":"ai note"}]'
set +e
"$SCRIPT" --repo . --timeout 1 >/dev/null
rc=$?
set -e
[[ "$rc" -eq 124 ]] || fail "agent-only new comments should timeout, got $rc"
printf 'PASS: wait-comments ignores agent-authored comments\n'

# Session disappears after baseline → 2
scenario "$SESSION" '[]' "$OLD" -
set +e
"$SCRIPT" --repo . --timeout 5 >/dev/null
rc=$?
set -e
[[ "$rc" -eq 2 ]] || fail "session gone should exit 2, got $rc"
printf 'PASS: wait-comments exits 2 when the session disappears\n'

# Timeout with no new comments → 124
scenario "$SESSION" - '[]' -
set +e
"$SCRIPT" --repo . --timeout 1 >/dev/null
rc=$?
set -e
[[ "$rc" -eq 124 ]] || fail "timeout should exit 124, got $rc"
printf 'PASS: wait-comments exits 124 on timeout\n'
