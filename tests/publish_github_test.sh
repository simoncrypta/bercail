#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

SCRIPT="$ROOT/skills/review/scripts/publish-github.sh"
export TUICR_BIN="$TMP_DIR/tuicr"
export GH_BIN="$TMP_DIR/gh"

cat >"$TUICR_BIN" <<FAKE
#!/usr/bin/env bash
set -euo pipefail
action="\$*"
if [[ "\$1" == "review" && "\$2" == "list" ]]; then
  cat "$TMP_DIR/tuicr-list"
  exit 0
fi
if [[ "\$1" == "review" && "\$2" == "comments" ]]; then
  cat "$TMP_DIR/tuicr-comments"
  exit 0
fi
echo "unexpected tuicr: \$action" >&2
exit 1
FAKE
chmod +x "$TUICR_BIN"

cat >"$GH_BIN" <<FAKE
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >> "$TMP_DIR/gh-calls.log"
if [[ "\$1" == "pr" && "\$2" == "view" ]]; then
  if [[ -f "$TMP_DIR/no-pr" ]]; then
    echo "no pull requests found" >&2
    exit 1
  fi
  printf '%s\n' '{"number":7,"url":"https://github.com/o/r/pull/7","headRefOid":"abc123"}'
  exit 0
fi
if [[ "\$1" == "api" ]]; then
  cat >"$TMP_DIR/posted.json"
  printf '%s\n' '{"html_url":"https://github.com/o/r/pull/7#pullrequestreview-1"}'
  exit 0
fi
echo "unexpected gh: \$*" >&2
exit 1
FAKE
chmod +x "$GH_BIN"

printf '%s\n' '[{"slug":"local/worktree","kind":"local","active":true}]' >"$TMP_DIR/tuicr-list"
printf '%s\n' '[{"id":"user:1","author":"user","path":"src/a.rs","start_line":12,"side":"new","content":"rename this"}]' \
  >"$TMP_DIR/tuicr-comments"

out="$("$SCRIPT" --repo "$TMP_DIR" --dry-run)"
printf '%s' "$out" | jq -e '.event == "COMMENT"' >/dev/null || fail "dry-run event: $out"
printf '%s' "$out" | jq -e '.comments | length == 1' >/dev/null || fail "dry-run comments: $out"
printf '%s' "$out" | jq -e '.comments[0].path == "src/a.rs"' >/dev/null || fail "path: $out"
printf '%s' "$out" | jq -e '.comments[0].line == 12' >/dev/null || fail "line: $out"
printf '%s' "$out" | jq -e '.comments[0].side == "RIGHT"' >/dev/null || fail "side: $out"
printf 'PASS: publish-github dry-run maps user notes\n'

out="$("$SCRIPT" --repo "$TMP_DIR")"
printf '%s' "$out" | grep -q 'published 1 user comment' || fail "post summary: $out"
jq -e '.event == "COMMENT"' "$TMP_DIR/posted.json" >/dev/null || fail "posted event"
jq -e '.comments[0].body == "rename this"' "$TMP_DIR/posted.json" >/dev/null \
  || fail "posted body $(cat "$TMP_DIR/posted.json")"
printf 'PASS: publish-github posts a COMMENT review\n'

printf '%s\n' '[{"id":"agent:1","author":"cursor-agent","path":"src/a.rs","start_line":12,"content":"ai note"}]' \
  >"$TMP_DIR/tuicr-comments"
set +e
"$SCRIPT" --repo "$TMP_DIR" >/dev/null 2>"$TMP_DIR/err"
rc=$?
set -e
[[ "$rc" -eq 2 ]] || fail "agent-only comments should exit 2, got $rc"
grep -q 'no user comments' "$TMP_DIR/err" || fail "empty comments error: $(cat "$TMP_DIR/err")"
printf 'PASS: publish-github refuses agent-only comments\n'

printf '%s\n' '[]' >"$TMP_DIR/tuicr-comments"
set +e
"$SCRIPT" --repo "$TMP_DIR" >/dev/null 2>"$TMP_DIR/err"
rc=$?
set -e
[[ "$rc" -eq 2 ]] || fail "empty user comments should exit 2, got $rc"
printf 'PASS: publish-github refuses an empty user-comment list\n'

printf '%s\n' '[{"id":"user:1","author":"user","path":"src/a.rs","start_line":12,"side":"new","content":"rename this"}]' \
  >"$TMP_DIR/tuicr-comments"
touch "$TMP_DIR/no-pr"
set +e
"$SCRIPT" --repo "$TMP_DIR" >/dev/null 2>"$TMP_DIR/err"
rc=$?
set -e
[[ "$rc" -eq 2 ]] || fail "no PR should exit 2, got $rc"
grep -q 'no pull request' "$TMP_DIR/err" || fail "no PR error: $(cat "$TMP_DIR/err")"
printf 'PASS: publish-github requires an open PR\n'
