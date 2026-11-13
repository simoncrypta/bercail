#!/usr/bin/env bats
# The subset TOML reader. Each case is its own HOME. The shared fixture is the
# hard file later callers, including the desk mod, read too.

setup() {
  load test_helper
  isolate
  # shellcheck source=/dev/null
  source "$ROOT/lib/toml.sh"
  FIXTURE="$ROOT/tests/fixtures/config-hard.toml"
}

@test "the shared fixture keeps quotes, comments, paths, arrays, and ints" {
  local rec
  rec="$(toml_records "$FIXTURE")"
  printf '%s\n' "$rec" | jq -se '
    (map(select(.section == ["layout"] and .key == "review")) | last.value) == "hunk"
    and (map(select(.section == ["layout"] and .key == "auto_review")) | last.value) == false
    and (map(select(.section == ["bstack"] and .key == "claude")) | last.value) == "claude-bridge/claude-opus-5-5#high"
    and (map(select(.section == ["bstack"] and .key == "gpt")) | last.value) == "openai/gpt-6.1-sol:high"
    and (map(select(.section == ["bstack"] and .key == "fallback")) | last.value) == ["claude","gpt","grok"]
    and (map(select(.section == ["shep"] and .key == "compact_at")) | last.value) == 250000
    and (map(select(.section == ["git"] and .key == "~/Work/a.b")) | last.value) == "gh"
    and (map(select(.section == ["git"] and .key == "esc\tape")) | last.value) == "gt"
    and (map(select(.section == ["policy","~/Work/a.b"] and .key == "commit")) | last.value) == "allow"
    and (map(select(.section == ["policy","~/Work/a.b"] and .key == "rules")) | last.value) == "Use gh, never gt.\nSimon merges."
    and (map(select(.section == ["policy","hash#path"] and .key == "push")) | last.value) == "main"
  ' >/dev/null || fail "fixture records: $rec"
  [[ "$(toml_get "$FIXTURE" layout review)" == '"hunk"' ]] || fail "layout get"
  [[ "$(toml_get "$FIXTURE" 'policy."~/Work/a.b"' rules)" == '"Use gh, never gt.\nSimon merges."' ]] \
    || fail "policy path get"
  [[ "$(toml_get "$FIXTURE" bstack claude)" == '"claude-bridge/claude-opus-5-5#high"' ]] \
    || fail "#high must not be rewritten"
}

@test "a quoted table is the same section as a bare one" {
  local bare="$BATS_TEST_TMPDIR/bare.toml" quoted="$BATS_TEST_TMPDIR/quoted.toml" got_bare got_quoted
  printf '[bstack]\nlead = "claude"\n' >"$bare"
  printf '["bstack"]\nlead = "claude"\n' >"$quoted"
  got_bare="$(toml_records "$bare")"
  got_quoted="$(toml_records "$quoted")"
  jq -se '.[0].section == ["bstack"] and .[1].section == ["bstack"]' <<<"$got_bare"$'\n'"$got_quoted" >/dev/null \
    || fail "sections: $got_bare vs $got_quoted"
}

@test "policy multiline closing matches the current policy file" {
  local f="$BATS_TEST_TMPDIR/policy.toml" rec
  cat >"$f" <<'EOF'
# team policy
commit = "allow"   # no prompt
push = 'main'
integrate = "direct"
pr_draft = true
release = "Bump \"VERSION\", then tag v*."
agent_may_release = false
rules = """
Use gh, never gt.
Simon merges."""
EOF
  rec="$(toml_records "$f")"
  printf '%s\n' "$rec" | jq -se '
    (map(select(.section == [] and .key == "commit")) | last.value) == "allow"
    and (map(select(.section == [] and .key == "push")) | last.value) == "main"
    and (map(select(.section == [] and .key == "release")) | last.value) == "Bump \"VERSION\", then tag v*."
    and (map(select(.section == [] and .key == "pr_draft")) | last.value) == true
    and (map(select(.section == [] and .key == "agent_may_release")) | last.value) == false
    and (map(select(.section == [] and .key == "rules")) | last.value) == "Use gh, never gt.\nSimon merges."
  ' >/dev/null || fail "policy file: $rec"
}

@test "an escaped path key stays one component, and [policy] is not a path" {
  local f="$BATS_TEST_TMPDIR/scope.toml" rec
  printf '%s\n' '[policy]' 'commit = "ask"' '[policy."~/Work/a.b"]' 'commit = "allow"' \
    '[git]' '"esc\tape\"q" = "origin"' >"$f"
  rec="$(toml_records "$f")"
  printf '%s\n' "$rec" | jq -se --arg key $'esc\tape"q' '
    (map(select(.section == ["policy"] and .key == "commit")) | last.value) == "ask"
    and (map(select(.section == ["policy","~/Work/a.b"] and .key == "commit")) | last.value) == "allow"
    and (map(select(.section == ["git"] and .key == $key)) | last.value) == "origin"
  ' >/dev/null || fail "scope: $rec"
  [[ "$(toml_get "$f" policy commit)" == '"ask"' ]] || fail "bare policy section"
  [[ "$(toml_get "$f" 'policy."~/Work/a.b"' commit)" == '"allow"' ]] || fail "path section"
}

@test "a missing file or key exits 1" {
  local rc=0
  toml_records "$BATS_TEST_TMPDIR/missing.toml" >/dev/null 2>"$BATS_TEST_TMPDIR/miss.err" || rc=$?
  [[ "$rc" -eq 1 ]] || fail "missing file records should exit 1, got $rc"
  grep -q 'no such file' "$BATS_TEST_TMPDIR/miss.err" || fail "missing file message: $(cat "$BATS_TEST_TMPDIR/miss.err")"
  rc=0
  toml_get "$FIXTURE" layout no_such >/dev/null 2>&1 || rc=$?
  [[ "$rc" -eq 1 ]] || fail "missing key should exit 1, got $rc"
  rc=0
  toml_get "$BATS_TEST_TMPDIR/missing.toml" layout review >/dev/null 2>&1 || rc=$?
  [[ "$rc" -eq 1 ]] || fail "missing file get should exit 1, got $rc"
}

@test "a line it cannot read is an error record with its line, and the rest of the file still reads" {
  local f="$BATS_TEST_TMPDIR/bad.toml" rec err
  cat >"$f" <<'EOF'
commit = "root"
[policy."unterminated
commit = "allow"
[layout]
review = "tuicr"
not a line
rollover = false
EOF
  err="$(toml_records "$f" 2>&1 >"$BATS_TEST_TMPDIR/bad.out")" || fail "a bad line must not fail the file: $err"
  [[ -z "$err" ]] || fail "the reader leaves the wording to its caller, so stderr stays empty: $err"
  rec="$(cat "$BATS_TEST_TMPDIR/bad.out")"
  printf '%s\n' "$rec" | jq -se '
    (map(select(.section == [] and .key == "commit")) | last.value) == "root"
    and (map(select(.value == "allow")) | length) == 0
    and (map(select(.section == ["layout"] and .key == "review")) | last.value) == "tuicr"
    and (map(select(.section == ["layout"] and .key == "rollover")) | last.value) == false
    and (map(select(has("error")) | [.section, .line, .error])
      == [[null, 2, "malformed table"], [["layout"], 6, "not a key = value line"]])
  ' >/dev/null || fail "errors: $rec"
}

@test "a value outside the subset is a raw record, exit 2 from toml_get, and the text as written from toml_value" {
  local f="$BATS_TEST_TMPDIR/raw.toml" rec out rc=0
  printf '%s\n' 'notify = finished, blocked  # two' '[shep]' 'compact_at = lots' 'keep_recent = 1.5' \
    '[bstack]' 'fallback = ["gpt",]' 'lead = "claude' >"$f"
  rec="$(toml_records "$f")"
  printf '%s\n' "$rec" | jq -se '
    map(select(has("raw")) | [.section, .key, .raw, .line]) == [
      [[], "notify", "finished, blocked", 1],
      [["shep"], "compact_at", "lots", 3],
      [["shep"], "keep_recent", "1.5", 4],
      [["bstack"], "fallback", "[\"gpt\",]", 6],
      [["bstack"], "lead", "\"claude", 7]]
    and (map(select(has("value") or has("error"))) | length) == 0
  ' >/dev/null || fail "raw records: $rec"
  out="$(toml_get "$f" shep compact_at)" || rc=$?
  [[ "$rc" -eq 2 && "$out" == lots ]] || fail "toml_get on a raw value: rc=$rc out=$out"
  [[ "$(toml_value "$f" '' notify default)" == "finished, blocked" ]] || fail "toml_value passes the text on"
  [[ "$(toml_value "$f" bstack fallback)" == '["gpt",]' ]] || fail "a bad array as written"
}

@test "a control character in a value, CRLF line ends, and a BOM do not lose the rest of the file" {
  local f="$BATS_TEST_TMPDIR/bytes.toml" rec
  printf '\357\273\277[policy."~/Work/app"]\r\nrules = """\r\nred: \033[31m\r\n"""\r\n[git]\r\n"~/Work/app" = "gt"\r\n' >"$f"
  rec="$(toml_records "$f")"
  printf '%s\n' "$rec" | jq -se '
    (map(select(.section == ["policy","~/Work/app"] and .key == "rules")) | last.value) == "red: \u001b[31m\n"
    and (map(select(.section == ["git"] and .key == "~/Work/app")) | last.value) == "gt"
    and (map(select(has("error") or has("raw"))) | length) == 0
  ' >/dev/null || fail "bytes: $rec"
}

@test "toml_value returns a raw bool, a compact array, and a default when missing" {
  local rc=0 got
  [[ "$(toml_value "$FIXTURE" layout auto_review)" == false ]] || fail "bool"
  [[ "$(toml_value "$FIXTURE" shep compact_at)" == 250000 ]] || fail "int"
  [[ "$(toml_value "$FIXTURE" 'policy."~/Work/a.b"' rules)" == $'Use gh, never gt.\nSimon merges.' ]] || fail "multi-line string"
  [[ "$(toml_value "$FIXTURE" bstack fallback)" == '["claude","gpt","grok"]' ]] || fail "array"
  got="$(toml_value "$FIXTURE" bstack no_such fallback-default)" || rc=$?
  [[ "$rc" -eq 0 && "$got" == fallback-default ]] || fail "missing key default: rc=$rc got=$got"
  rc=0
  got="$(toml_value "$BATS_TEST_TMPDIR/missing.toml" layout review)" || rc=$?
  [[ "$rc" -eq 0 && -z "$got" ]] || fail "missing file default: rc=$rc got=$got"
}
