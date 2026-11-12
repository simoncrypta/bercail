#!/usr/bin/env bats
# publish-github.sh against fake tuicr and gh: maps user notes to a GitHub review.

setup() {
  load test_helper
  isolate
  SCRIPT="$ROOT/skills/review/scripts/publish-github.sh"
  export TUICR_BIN="$BATS_TEST_TMPDIR/tuicr"
  export GH_BIN="$BATS_TEST_TMPDIR/gh"

  cat >"$TUICR_BIN" <<FAKE
#!/usr/bin/env bash
set -euo pipefail
action="\$*"
if [[ "\$1" == "review" && "\$2" == "list" ]]; then
  cat "$BATS_TEST_TMPDIR/tuicr-list"
  exit 0
fi
if [[ "\$1" == "review" && "\$2" == "comments" ]]; then
  cat "$BATS_TEST_TMPDIR/tuicr-comments"
  exit 0
fi
echo "unexpected tuicr: \$action" >&2
exit 1
FAKE
  chmod +x "$TUICR_BIN"

  cat >"$GH_BIN" <<FAKE
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >> "$BATS_TEST_TMPDIR/gh-calls.log"
if [[ "\$1" == "pr" && "\$2" == "view" ]]; then
  if [[ -f "$BATS_TEST_TMPDIR/no-pr" ]]; then
    echo "no pull requests found" >&2
    exit 1
  fi
  printf '%s\n' '{"number":7,"url":"https://github.com/o/r/pull/7","headRefOid":"abc123"}'
  exit 0
fi
if [[ "\$1" == "api" ]]; then
  cat >"$BATS_TEST_TMPDIR/posted.json"
  printf '%s\n' '{"html_url":"https://github.com/o/r/pull/7#pullrequestreview-1"}'
  exit 0
fi
echo "unexpected gh: \$*" >&2
exit 1
FAKE
  chmod +x "$GH_BIN"

  printf '%s\n' '[{"slug":"local/worktree","kind":"local","active":true}]' >"$BATS_TEST_TMPDIR/tuicr-list"
  printf '%s\n' '[{"id":"user:1","author":"user","path":"src/a.rs","start_line":12,"side":"new","content":"rename this"}]' \
    >"$BATS_TEST_TMPDIR/tuicr-comments"
}

@test "publish-github dry-run maps user notes" {
  local out
  out="$("$SCRIPT" --repo "$BATS_TEST_TMPDIR" --dry-run)"
  printf '%s' "$out" | jq -e '.event == "COMMENT"' >/dev/null || fail "dry-run event: $out"
  printf '%s' "$out" | jq -e '.comments | length == 1' >/dev/null || fail "dry-run comments: $out"
  printf '%s' "$out" | jq -e '.comments[0].path == "src/a.rs"' >/dev/null || fail "path: $out"
  printf '%s' "$out" | jq -e '.comments[0].line == 12' >/dev/null || fail "line: $out"
  printf '%s' "$out" | jq -e '.comments[0].side == "RIGHT"' >/dev/null || fail "side: $out"
}

@test "publish-github posts a COMMENT review" {
  local out
  out="$("$SCRIPT" --repo "$BATS_TEST_TMPDIR")"
  grep -q 'published 1 user comment' <<<"$out" || fail "post summary: $out"
  jq -e '.event == "COMMENT"' "$BATS_TEST_TMPDIR/posted.json" >/dev/null || fail "posted event"
  jq -e '.comments[0].body == "rename this"' "$BATS_TEST_TMPDIR/posted.json" >/dev/null \
    || fail "posted body $(cat "$BATS_TEST_TMPDIR/posted.json")"
}

@test "publish-github refuses agent-only comments" {
  local rc=0
  printf '%s\n' '[{"id":"agent:1","author":"pi","path":"src/a.rs","start_line":12,"content":"ai note"}]' \
    >"$BATS_TEST_TMPDIR/tuicr-comments"
  "$SCRIPT" --repo "$BATS_TEST_TMPDIR" >/dev/null 2>"$BATS_TEST_TMPDIR/err" || rc=$?
  [[ "$rc" -eq 2 ]] || fail "agent-only comments should exit 2, got $rc"
  grep -q 'no user comments' "$BATS_TEST_TMPDIR/err" || fail "empty comments error: $(cat "$BATS_TEST_TMPDIR/err")"
}

@test "publish-github refuses an empty user-comment list" {
  local rc=0
  printf '%s\n' '[]' >"$BATS_TEST_TMPDIR/tuicr-comments"
  "$SCRIPT" --repo "$BATS_TEST_TMPDIR" >/dev/null 2>"$BATS_TEST_TMPDIR/err" || rc=$?
  [[ "$rc" -eq 2 ]] || fail "empty user comments should exit 2, got $rc"
}

@test "publish-github requires an open PR" {
  local rc=0
  touch "$BATS_TEST_TMPDIR/no-pr"
  "$SCRIPT" --repo "$BATS_TEST_TMPDIR" >/dev/null 2>"$BATS_TEST_TMPDIR/err" || rc=$?
  [[ "$rc" -eq 2 ]] || fail "no PR should exit 2, got $rc"
  grep -q 'no pull request' "$BATS_TEST_TMPDIR/err" || fail "no PR error: $(cat "$BATS_TEST_TMPDIR/err")"
}
