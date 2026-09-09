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

write_tuicr() {
  cat >"$TUICR_BIN" <<FAKE
#!/usr/bin/env bash
set -euo pipefail
list_file="$TMP_DIR/tuicr-list"
comments_file="$TMP_DIR/tuicr-comments"
case "\$1 \$2" in
  "review list")
    if [[ ! -f "\$list_file" ]]; then
      printf '%s\n' '[]'
      exit 0
    fi
    cat "\$list_file"
    ;;
  "review comments")
    if [[ ! -f "\$comments_file" ]]; then
      echo "no session" >&2
      exit 1
    fi
    cat "\$comments_file"
    ;;
  *)
    echo "unexpected: \$*" >&2
    exit 1
    ;;
esac
FAKE
  chmod +x "$TUICR_BIN"
}

write_tuicr

# No session → 2
printf '%s\n' '[]' >"$TMP_DIR/tuicr-list"
set +e
"$SCRIPT" --repo . --timeout 1 >/dev/null
rc=$?
set -e
[[ "$rc" -eq 2 ]] || fail "missing session should exit 2, got $rc"
printf 'PASS: wait-comments exits 2 when no session exists\n'

# Baseline then new comment → 0
printf '%s\n' '[{"slug":"local/worktree","kind":"local","active":true}]' >"$TMP_DIR/tuicr-list"
printf '%s\n' '[{"id":"user:1","author":"user","content":"old"}]' >"$TMP_DIR/tuicr-comments"
(
  sleep 0.05
  printf '%s\n' '[{"id":"user:1","author":"user","content":"old"},{"id":"user:2","author":"user","content":"new note"}]' \
    >"$TMP_DIR/tuicr-comments"
) &
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
printf '%s\n' '[{"id":"user:1","author":"user","content":"old"}]' >"$TMP_DIR/tuicr-comments"
(
  sleep 0.05
  printf '%s\n' '[{"id":"user:1","author":"user","content":"old"},{"id":"agent:1","author":"cursor-agent","content":"ai note"}]' \
    >"$TMP_DIR/tuicr-comments"
) &
set +e
"$SCRIPT" --repo . --timeout 1 >/dev/null
rc=$?
set -e
[[ "$rc" -eq 124 ]] || fail "agent-only new comments should timeout, got $rc"
printf 'PASS: wait-comments ignores agent-authored comments\n'

# Session disappears after baseline → 2
printf '%s\n' '[{"id":"user:1","author":"user","content":"old"}]' >"$TMP_DIR/tuicr-comments"
(
  sleep 0.05
  printf '%s\n' '[]' >"$TMP_DIR/tuicr-list"
) &
set +e
"$SCRIPT" --repo . --timeout 5 >/dev/null
rc=$?
set -e
[[ "$rc" -eq 2 ]] || fail "session gone should exit 2, got $rc"
printf 'PASS: wait-comments exits 2 when the session disappears\n'

# Timeout with no new comments → 124
printf '%s\n' '[{"slug":"local/worktree","kind":"local","active":true}]' >"$TMP_DIR/tuicr-list"
printf '%s\n' '[]' >"$TMP_DIR/tuicr-comments"
set +e
"$SCRIPT" --repo . --timeout 1 >/dev/null
rc=$?
set -e
[[ "$rc" -eq 124 ]] || fail "timeout should exit 124, got $rc"
printf 'PASS: wait-comments exits 124 on timeout\n'
