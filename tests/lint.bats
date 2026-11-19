#!/usr/bin/env bats
# tests/lint.sh's own checks, on fixtures. CI runs lint.sh on the tree.

setup() {
  load test_helper
  isolate
}

# grep -q exits at its first match; under pipefail the writer's SIGPIPE then
# fails the pipeline about once in a thousand runs (ledger key pipefail-grep-q).
# The fixtures have no .sh and no shebang, so lint.sh does not check them.
@test "the grep -q lint fails a printf or echo piped to grep -q or -m, and names the fix" {
  local f="$ROOT/tests/fixtures/grep-q-bad" out line
  out="$("$ROOT/tests/lint_grep_q.sh" "$f" 2>&1)" && fail "the lint passed: $out"
  for line in 2 3 4 5; do
    grep -q "^$f:$line:" <<<"$out" || fail "line $line not reported: $out"
  done
  grep -q 'Use grep -q PATTERN <<<"$var", \[\[ \]\], or case' <<<"$out" || fail "no fix in the message: $out"
}

@test "the grep -q lint passes a here-string, a comment, a quoted mention, and other pipes" {
  local out
  out="$("$ROOT/tests/lint_grep_q.sh" "$ROOT/tests/fixtures/grep-q-good" 2>&1)" || fail "the lint failed: $out"
}

@test "the grep -q lint fails a file it cannot read" {
  local out
  out="$("$ROOT/tests/lint_grep_q.sh" "$ROOT/tests/fixtures/grep-q-good" "$BATS_TEST_TMPDIR/missing" 2>&1)" \
    && fail "a missing file passed: $out"
  grep -q 'missing: No such file' <<<"$out" || fail "the error does not name the file: $out"
}
