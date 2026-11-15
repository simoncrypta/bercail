#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  load test_helper
  isolate
  local name
  while IFS= read -r name; do unset "$name"; done < <(compgen -v | grep -E '^(HC_|HERDR_|BERCAIL_|BEADS_|BD_)')
  unset BASH_ENV
  source "$ROOT/skills/handoff/scripts/handoff-stages.sh"
  export HANDOFF_PI_PROFILE="$BATS_TEST_TMPDIR/profile"
  mkdir -p "$HANDOFF_PI_PROFILE/extensions" "$BATS_TEST_TMPDIR/bin"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  export HANDOFF_BD_BIN="$BATS_TEST_TMPDIR/bin/bd"
  printf '#!/bin/sh\ncase "$1" in show) echo '\''[{"title":"Offline review"}]'\'';; comment) cat >/dev/null;; context) echo '\''{"beads_dir":"/nonexistent"}'\'';; esac\n' >"$HANDOFF_BD_BIN"
  chmod +x "$HANDOFF_BD_BIN"
  if [[ -f "$ROOT/bstack/pi/extensions/provider-error.ts" ]]; then
    cp "$ROOT/bstack/pi/extensions/provider-error.ts" "$HANDOFF_PI_PROFILE/extensions/"
  fi
}

@test "a partial Pi profile blocks before execution and tells the person to update" {
  printf '// guard\n' >"$HANDOFF_PI_PROFILE/extensions/guard.ts"
  jq -nc --arg guard "$HANDOFF_PI_PROFILE/extensions/guard.ts" '["pi","-e",$guard]' >"$HANDOFF_PI_PROFILE/lead.json"
  rm "$HANDOFF_PI_PROFILE/extensions/provider-error.ts"
  run handoff_pi_prepare
  [[ "$status" -ne 0 ]]
  if handoff_pi_prepare; then fail "partial profile must block"; fi
  [[ "$HANDOFF_PI_BLOCK" == 'Pi provider-error helper is missing. Run bercail update.' ]]
}

@test "an unavailable TypeScript runtime blocks before making any provider request" {
  local wt="$BATS_TEST_TMPDIR/runtime" rc=0
  mkdir -p "$wt"
  printf '// guard\n' >"$HANDOFF_PI_PROFILE/extensions/guard.ts"
  jq -nc --arg guard "$HANDOFF_PI_PROFILE/extensions/guard.ts" '["pi","-e",$guard]' >"$HANDOFF_PI_PROFILE/lead.json"
  printf '#!/bin/sh\nexit 1\n' >"$BATS_TEST_TMPDIR/bin/node"
  printf '#!/bin/sh\necho request >>"%s"\n' "$BATS_TEST_TMPDIR/provider-calls" >"$BATS_TEST_TMPDIR/bin/pi"
  chmod +x "$BATS_TEST_TMPDIR/bin/node" "$BATS_TEST_TMPDIR/bin/pi"
  export HANDOFF_PI_BIN="$BATS_TEST_TMPDIR/bin/pi"
  handoff_run_headless bstack "$wt" example-237 '' 0 >"$BATS_TEST_TMPDIR/out" 2>"$BATS_TEST_TMPDIR/err" || rc=$?
  [[ "$rc" -ne 0 ]]
  [[ ! -e "$BATS_TEST_TMPDIR/provider-calls" ]]
  jq -e '.status == "blocked" and (.summary | contains("Node.js with built-in TypeScript support"))' "$wt/.bercail/handoff-result.json"
}

preflight_evidence_fixture() {
  local mode="$1" wt="$BATS_TEST_TMPDIR/preflight"
  mkdir -p "$wt/.bercail"
  printf '// guard\n' >"$HANDOFF_PI_PROFILE/extensions/guard.ts"
  jq -nc --arg guard "$HANDOFF_PI_PROFILE/extensions/guard.ts" '["pi","-e",$guard]' >"$HANDOFF_PI_PROFILE/lead.json"
  if [[ "$mode" == helper ]]; then
    rm "$HANDOFF_PI_PROFILE/extensions/provider-error.ts"
  else
    printf '#!/bin/sh\nexit 1\n' >"$BATS_TEST_TMPDIR/bin/node"
    chmod +x "$BATS_TEST_TMPDIR/bin/node"
  fi
  printf '#!/bin/sh\necho request >>"%s"\n' "$BATS_TEST_TMPDIR/provider-calls" >"$BATS_TEST_TMPDIR/bin/pi"
  chmod +x "$BATS_TEST_TMPDIR/bin/pi"
  export HANDOFF_PI_BIN="$BATS_TEST_TMPDIR/bin/pi"
  printf '%s\n' '{"status":"ready","summary":"earlier candidate evidence","candidate":"old-tree","verification":[{"kind":"test","command":"offline","exit_code":0,"evidence":"start.log","candidate":"old-tree"}],"provider_error":{"evidence":{"source":"start.log","event_index":1}}}' >"$wt/.bercail/handoff-result.json"
  printf 'earlier candidate log\n' >"$wt/.bercail/start.log"
  cp "$wt/.bercail/handoff-result.json" "$BATS_TEST_TMPDIR/original.json"
  cp "$wt/.bercail/start.log" "$BATS_TEST_TMPDIR/original.log"
}

assert_preflight_evidence_preserved() {
  local result="$BATS_TEST_TMPDIR/preflight/.bercail/handoff-result.json" prior source
  jq -e '.status == "blocked" and (has("verification") | not) and (.prior_result | type == "string")' "$result"
  prior="$(jq -r .prior_result "$result")"
  cmp "$prior" "$BATS_TEST_TMPDIR/original.json"
  source="$(jq -r .provider_error.evidence.source "$prior")"
  cmp "$(dirname "$prior")/$source" "$BATS_TEST_TMPDIR/original.log"
  [[ ! -e "$BATS_TEST_TMPDIR/provider-calls" ]]
}

@test "a resumed missing-helper preflight preserves the prior result and its adjacent log" {
  preflight_evidence_fixture helper
  run handoff_run_headless bstack "$BATS_TEST_TMPDIR/preflight" example-237 11111111-2222-4333-8444-555555555555 0
  [[ "$status" -ne 0 ]]
  assert_preflight_evidence_preserved
}

@test "a resumed incompatible-runtime preflight preserves the prior result and its adjacent log" {
  preflight_evidence_fixture runtime
  run handoff_run_headless bstack "$BATS_TEST_TMPDIR/preflight" example-237 11111111-2222-4333-8444-555555555555 0
  [[ "$status" -ne 0 ]]
  assert_preflight_evidence_preserved
}

@test "a blocked preflight dry-run leaves the prior result and log untouched without history writes" {
  preflight_evidence_fixture runtime
  run handoff_run_headless bstack "$BATS_TEST_TMPDIR/preflight" example-237 11111111-2222-4333-8444-555555555555 1
  [[ "$status" -ne 0 ]]
  cmp "$BATS_TEST_TMPDIR/preflight/.bercail/handoff-result.json" "$BATS_TEST_TMPDIR/original.json"
  cmp "$BATS_TEST_TMPDIR/preflight/.bercail/start.log" "$BATS_TEST_TMPDIR/original.log"
  [[ ! -d "$BATS_TEST_TMPDIR/preflight/.bercail/handoff-history" ]]
  [[ ! -e "$BATS_TEST_TMPDIR/provider-calls" ]]
}

@test "safety takes precedence over plan limits in final assistant selection" {
  local log="$BATS_TEST_TMPDIR/pi.log"
  printf '%s\n' '{"type":"message_end","message":{"role":"assistant","stopReason":"error","errorMessage":"content was flagged for possible cybersecurity risk; You have hit your ChatGPT usage limit; 429"}}' >"$log"
  [[ -z "$(handoff_pi_usage_limit_reason "$log")" ]]
}

@test "headless safety leaves a prewritten ready review incomplete and preserves candidate evidence" {
  local wt="$BATS_TEST_TMPDIR/review" rc=0 result
  mkdir -p "$wt/.bercail"
  printf '// guard\n' >"$HANDOFF_PI_PROFILE/extensions/guard.ts"
  jq -nc --arg guard "$HANDOFF_PI_PROFILE/extensions/guard.ts" '["pi","-e",$guard]' >"$HANDOFF_PI_PROFILE/lead.json"
  export HANDOFF_PI_BIN="$BATS_TEST_TMPDIR/bin/pi" HANDOFF_BD_BIN="$BATS_TEST_TMPDIR/bin/bd"
  printf '#!/bin/sh\ncase "$1" in show) echo '\''[{"title":"Offline review"}]'\'';; comment) cat >/dev/null;; context) echo '\''{"beads_dir":"/nonexistent"}'\'';; esac\n' >"$HANDOFF_BD_BIN"
  cat >"$HANDOFF_PI_BIN" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' '{"status":"ready","summary":"earlier review approved","candidate":"old-tree","verification":[{"kind":"test","command":"offline test","exit_code":0,"evidence":"proof-old-tree.txt","candidate":"old-tree"}]}' >"$BERCAIL_RESULT_PATH"
printf '%s\n' '{"type":"message_end","message":{"role":"assistant","provider":"offline","model":"test","stopReason":"error","errorMessage":"content was flagged for possible cybersecurity risk; 429; Authorization: Bearer secret-canary-237"}}'
# This is a native retry success, not permission to erase the block.
printf '%s\n' '{"type":"message_end","message":{"role":"assistant","stopReason":"stop","content":[{"type":"text","text":"approved"}]}}'
STUB
  chmod +x "$HANDOFF_PI_BIN" "$HANDOFF_BD_BIN"
  printf 'completed evidence for old-tree\n' >"$wt/proof-old-tree.txt"
  BERCAIL_ROLE=judge BERCAIL_PHASE=final-review BERCAIL_CANDIDATE=new-tree handoff_run_headless bstack "$wt" example-237 '' 0 >/dev/null 2>"$BATS_TEST_TMPDIR/err" || rc=$?
  [[ "$rc" -ne 0 ]]
  result="$wt/.bercail/handoff-result.json"
  jq -e '.status == "blocked" and .reason == "provider_safety_block" and .completion == "incomplete"
    and .provider_error.reason == "provider_safety_block" and .provider_error.phase == "final-review" and .provider_error.candidate == "new-tree"
    and .candidate == "old-tree" and .verification[0].candidate == "old-tree" and .verification[0].exit_code == 0
    and (.summary | contains("incomplete")) and (.summary | contains("approved") | not)' "$result"
  [[ "$(<"$wt/proof-old-tree.txt")" == 'completed evidence for old-tree' ]]
  ! grep -q 'secret-canary-237\|Do this part yourself' "$result" "$BATS_TEST_TMPDIR/err"
}

@test "resumed safety with no new result keeps earlier candidate evidence as a non-authoritative snapshot" {
  local wt="$BATS_TEST_TMPDIR/resume" rc=0 result prior sid=11111111-2222-4333-8444-555555555555
  mkdir -p "$wt/.bercail"
  printf '// guard\n' >"$HANDOFF_PI_PROFILE/extensions/guard.ts"
  jq -nc --arg guard "$HANDOFF_PI_PROFILE/extensions/guard.ts" '["pi","-e",$guard]' >"$HANDOFF_PI_PROFILE/lead.json"
  export HANDOFF_PI_BIN="$BATS_TEST_TMPDIR/bin/pi" HANDOFF_BD_BIN="$BATS_TEST_TMPDIR/bin/bd"
  printf '#!/bin/sh\ncase "$1" in show) echo '\''[{"title":"Offline review"}]'\'';; comment) cat >/dev/null;; context) echo '\''{"beads_dir":"/nonexistent"}'\'';; esac\n' >"$HANDOFF_BD_BIN"
  printf '#!/bin/sh\nprintf '\''%%s\\n'\'' '\''{"type":"message_end","message":{"role":"assistant","stopReason":"error","errorMessage":"content was flagged for possible cybersecurity risk"}}'\''\n' >"$HANDOFF_PI_BIN"
  chmod +x "$HANDOFF_PI_BIN" "$HANDOFF_BD_BIN"
  result="$wt/.bercail/handoff-result.json"
  printf '%s\n' '{"status":"ready","summary":"old candidate review","candidate":"old-tree","verification":[{"kind":"test","command":"offline test","exit_code":0,"evidence":"proof.txt","candidate":"old-tree"}]}' >"$result"
  cp "$result" "$BATS_TEST_TMPDIR/original.json"
  printf 'prior session log\n' >"$wt/.bercail/start.log"
  handoff_run_headless bstack "$wt" example-237 "$sid" 0 >/dev/null 2>"$BATS_TEST_TMPDIR/err" || rc=$?
  [[ "$rc" -ne 0 ]]
  jq -e '.status == "blocked" and .completion == "incomplete" and .reason == "provider_safety_block" and (has("verification") | not)' "$result"
  prior="$(jq -r .prior_result "$result")"
  cmp "$prior" "$BATS_TEST_TMPDIR/original.json"
  [[ "$(<"$(dirname "$prior")/start.log")" == 'prior session log' ]]
}

@test "notify projects typed incomplete review fields without changing their candidate labels" {
  source "$ROOT/lib/notify.sh"
  local wt="$BATS_TEST_TMPDIR/desk" result
  mkdir -p "$wt/.bercail"
  printf '%s\n' '{"status":"blocked","summary":"review incomplete","session_id":"s1","issue":"example-237","reason":"provider_safety_block","completion":"incomplete","provider_error":{"reason":"provider_safety_block","candidate":"new-tree","phase":"final-review","role":"judge"},"verification":[{"candidate":"old-tree"}]}' >"$wt/.bercail/handoff-result.json"
  result="$(notify_desk_info "$wt" pi example-237 'Offline review')"
  jq -e '.result.reason == "provider_safety_block" and .result.completion == "incomplete" and .result.provider_error.candidate == "new-tree" and .result.provider_error.phase == "final-review"' <<<"$result"
}
