#!/usr/bin/env bash
# shellcheck shell=bash
# Stub harnesses replay recorded plan-limit errors. No live provider calls.
# Existing cases pin harness = opencode so they do not follow the Pi default.
set -euo pipefail

unset BASH_ENV
export __MISE_BASH_ENV_LOADED=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# shellcheck disable=SC1090
source "$ROOT/skills/handoff/scripts/handoff-spawn"

ISSUE=bercail-0s1

mkdir -p "$TMP_DIR/bin"
cat >"$TMP_DIR/bin/bd" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  show)
    [[ "$2" == "${BD_KNOWN:?}" ]] || { echo "no issue $2" >&2; exit 1; }
    printf '[{"id":"%s"}]\n' "$2"
    ;;
  comment)
    [[ "${3:-}" == --stdin ]] || exit 3
    cat >/dev/null
    ;;
  context)
    printf '{"beads_dir":"%s"}\n' "$PWD/.beads"
    ;;
  *) exit 2 ;;
esac
STUB
chmod +x "$TMP_DIR/bin/bd"
export HANDOFF_BD_BIN="$TMP_DIR/bin/bd"
export BD_KNOWN="$ISSUE"

# Prints $HANDOFF_STUB_PAYLOAD and exits 1. Counts invocations so a limit cannot
# start a second command.
cat >"$TMP_DIR/bin/opencode" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${HANDOFF_ARGV_LOG:?}"
printf '1\n' >>"${HANDOFF_RUNS:?}"
cat "${HANDOFF_STUB_PAYLOAD:?}"
exit 1
STUB
chmod +x "$TMP_DIR/bin/opencode"
export HANDOFF_OPENCODE_BIN="$TMP_DIR/bin/opencode"
export HANDOFF_ARGV_LOG="$TMP_DIR/argv.log"
export HANDOFF_RUNS="$TMP_DIR/runs"
export HANDOFF_STUB_PAYLOAD="$TMP_DIR/payload"
printf '[bstack]\nharness = "opencode"\nlead = "openai/gpt-6.1-sol"\n' >"$TMP_DIR/opencode.toml"
export BERCAIL_CONFIG="$TMP_DIR/opencode.toml"
export BERCAIL_BSTACK_MODELS="$TMP_DIR/no-bstack-models"
: >"$BERCAIL_BSTACK_MODELS"

run_stage() {
  local stage="$1" name="$2" rc=0
  local wt="$TMP_DIR/$name"
  mkdir -p "$wt"
  : >"$HANDOFF_ARGV_LOG"
  : >"$HANDOFF_RUNS"
  (cd "$wt" && "$ROOT/skills/handoff/scripts/handoff-spawn" \
    --stage "$stage" --issue "$ISSUE" --worktree "$wt" >/dev/null 2>&1) || rc=$?
  [[ "$rc" -ne 0 ]] || fail "$name should exit nonzero"
  [[ "$(wc -l <"$HANDOFF_RUNS")" -eq 1 ]] || fail "$name started more than once: $(cat "$HANDOFF_RUNS")"
  printf '%s' "$wt"
}

assert_limit() {
  local wt="$1" label="$2"
  jq -e '.status == "failed"
    and .reason == "usage-limit"
    and (.summary | type == "string" and length > 0)
    and (.session_id | type == "string" and length > 0)' \
    "$wt/.bercail/handoff-result.json" >/dev/null \
    || fail "$label: $(cat "$wt/.bercail/handoff-result.json")"
  handoff_result_ok "$wt/.bercail/handoff-result.json" \
    || fail "$label result should still pass handoff_result_ok"
}

test_chatgpt_limit_sets_reason() {
  # Recorded ChatGPT session error: type provider.chatgpt-limit, code in the body.
  # Live capture was HTTP 200, not a 429.
  jq -nc \
    --arg body '{"error":{"code":"subscription_sharing_usage_limit_exceeded","message":"Limit"}}' \
    '{type:"error", sessionID:"ses_gptlimit", error:{
      type:"provider.chatgpt-limit",
      message:"ChatGPT usage limit reached. Check ChatGPT Settings → Usage for details.",
      status:200,
      response:{body:$body}
    }}' >"$HANDOFF_STUB_PAYLOAD"
  local wt
  wt="$(run_stage bstack chatgpt)"
  assert_limit "$wt" "chatgpt"
  jq -e '.session_id == "ses_gptlimit"' "$wt/.bercail/handoff-result.json" >/dev/null \
    || fail "chatgpt session: $(cat "$wt/.bercail/handoff-result.json")"
  wt="$(run_stage autopilot chatgpt-autopilot)"
  assert_limit "$wt" "autopilot"
  printf 'PASS: ChatGPT usage-limit error yields failed with reason usage-limit\n'
}

test_claude_text_sets_reason() {
  # The sentence Claude Code 2.1.316 composes, as opencode's plain error, and as
  # stderr when the process exits before a JSON error event.
  jq -nc '{type:"error", sessionID:"ses_claude", error:{
    type:"provider.unknown",
    message:"You'\''ve hit your 5-hour limit · resets 6:10pm"
  }}' >"$HANDOFF_STUB_PAYLOAD"
  local wt
  wt="$(run_stage bstack claude-json)"
  assert_limit "$wt" "claude json"
  printf '%s\n' "You've hit your 5-hour limit" >"$HANDOFF_STUB_PAYLOAD"
  wt="$(run_stage bstack claude-text)"
  assert_limit "$wt" "claude text"
  printf 'PASS: Claude 5-hour limit text yields failed with reason usage-limit\n'
}

test_rate_limit_has_no_reason() {
  # A transient 429. Status alone is not a plan limit (xAI's weekly body is unverified).
  jq -nc \
    --arg body '{"error":{"type":"rate_limit_error","message":"Too many requests"}}' \
    '{type:"error", sessionID:"ses_rate", error:{
      type:"provider.rate-limit",
      message:"Too many requests",
      status:429,
      response:{body:$body}
    }}' >"$HANDOFF_STUB_PAYLOAD"
  local wt
  wt="$(run_stage bstack rate)"
  jq -e '.status == "failed"
    and (.summary | type == "string" and length > 0)
    and .session_id == "ses_rate"
    and (has("reason") | not)' \
    "$wt/.bercail/handoff-result.json" >/dev/null \
    || fail "rate limit must not set reason: $(cat "$wt/.bercail/handoff-result.json")"
  handoff_result_ok "$wt/.bercail/handoff-result.json" \
    || fail "rate-limit result should still pass handoff_result_ok"

  # A mention in other JSON, or a bare 429 with no code, is not a limit.
  printf '%s\n' '{"type":"text","text":"subscription_sharing_usage_limit_exceeded"}' >"$TMP_DIR/mention.log"
  [[ -z "$(handoff_usage_limit_reason "$TMP_DIR/mention.log")" ]] \
    || fail "a mention of the code is not a usage limit"
  printf '%s\n' '{"type":"text","text":"You'"'"'ve hit your 5-hour limit"}' >"$TMP_DIR/quote.log"
  [[ -z "$(handoff_usage_limit_reason "$TMP_DIR/quote.log")" ]] \
    || fail "a quoted phrase in other JSON is not a usage limit"
  printf '%s\n' ' {"type":"text","text":"You'"'"'ve hit your 5-hour limit"}' >"$TMP_DIR/indented.log"
  [[ -z "$(handoff_usage_limit_reason "$TMP_DIR/indented.log")" ]] \
    || fail "indented JSON is not stderr"
  jq -nc '{type:"error", error:{type:"provider.unknown", message:"You'\''re out of usage credits"}}' >"$TMP_DIR/credits.log"
  [[ "$(handoff_usage_limit_reason "$TMP_DIR/credits.log")" == usage-limit ]] \
    || fail "out of usage credits should be a plan limit"
  jq -nc '{type:"error", error:{type:"provider.unknown", message:"HTTP 429", status:429}}' >"$TMP_DIR/bare429.log"
  [[ -z "$(handoff_usage_limit_reason "$TMP_DIR/bare429.log")" ]] \
    || fail "status 429 alone is not a usage limit"
  # The error event decides. A phrase on another line does not override a 429.
  printf '%s\n' \
    '{"type":"error","error":{"type":"provider.rate-limit","message":"Too many requests","status":429}}' \
    "You've hit your 5-hour limit" >"$TMP_DIR/mixed.log"
  [[ -z "$(handoff_usage_limit_reason "$TMP_DIR/mixed.log")" ]] \
    || fail "a rate-limit event must not pick up a phrase elsewhere"
  printf 'PASS: a plain 429 yields no usage-limit reason\n'
}

test_pi_limit_sets_reason() {
  local profile="$TMP_DIR/pi-profile" guard header wt
  mkdir -p "$profile/extensions" "$profile/agents"
  guard="$profile/extensions/guard.ts"
  printf '// guard\n' >"$guard"
  jq -n --arg guard "$guard" --arg model "claude-bridge/lead-model:high" \
    '["pi","--model",$model,"-e","npm:pi-claude-bridge@0.11.0","-e",$guard]' >"$profile/lead.json"
  printf 'claude=claude-bridge/family-claude#high\ngpt=openai/family-gpt#high\n' >"$profile/models"
  printf '[bstack]\nharness = "pi"\nenabled = true\n' >"$TMP_DIR/pi.toml"
  export BERCAIL_CONFIG="$TMP_DIR/pi.toml"
  export HANDOFF_PI_PROFILE="$profile"
  export HANDOFF_PI_BIN="$TMP_DIR/bin/pi"
  cat >"$HANDOFF_PI_BIN" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${HANDOFF_ARGV_LOG:?}"
printf '1\n' >>"${HANDOFF_RUNS:?}"
cat "${HANDOFF_STUB_PAYLOAD:?}"
exit 0
STUB
  chmod +x "$HANDOFF_PI_BIN"

  header=11111111-2222-4333-8444-555555555555
  jq -nc --arg id "$header" --arg msg "Claude quota exceeded — rate limit (five_hour) — resets 9:00:00 PM: You've hit your 5-hour limit · resets 9pm" \
    '{type:"session",version:3,id:$id},{type:"message_end",message:{role:"assistant",stopReason:"error",errorMessage:$msg}}' \
    >"$HANDOFF_STUB_PAYLOAD"
  wt="$(run_stage bstack pi-claude)"
  assert_limit "$wt" "pi claude"
  jq -e --arg id "$header" '.session_id == $id' "$wt/.bercail/handoff-result.json" >/dev/null \
    || fail "pi claude session: $(cat "$wt/.bercail/handoff-result.json")"

  header=aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee
  jq -nc --arg id "$header" --arg msg "You have hit your ChatGPT usage limit. Try again later." \
    '{type:"session",version:3,id:$id},{type:"message_end",message:{role:"assistant",stopReason:"error",errorMessage:$msg}}' \
    >"$HANDOFF_STUB_PAYLOAD"
  wt="$(run_stage bstack pi-chatgpt)"
  assert_limit "$wt" "pi chatgpt"
  jq -e --arg id "$header" '.session_id == $id' "$wt/.bercail/handoff-result.json" >/dev/null \
    || fail "pi chatgpt session: $(cat "$wt/.bercail/handoff-result.json")"

  header=bbbbbbbb-cccc-4ddd-8eee-ffffffffffff
  jq -nc --arg id "$header" --arg msg "429 Too many requests: xAI weekly limit unverified" \
    '{type:"session",version:3,id:$id},{type:"message_end",message:{role:"assistant",stopReason:"error",errorMessage:$msg}}' \
    >"$HANDOFF_STUB_PAYLOAD"
  wt="$(run_stage bstack pi-xai)"
  jq -e --arg id "$header" '.status == "failed" and .session_id == $id and (has("reason") | not)' \
    "$wt/.bercail/handoff-result.json" >/dev/null \
    || fail "xAI 429 must not set reason: $(cat "$wt/.bercail/handoff-result.json")"

  printf '%s\n' \
    '{"type":"session","id":"cccccccc-dddd-4eee-8fff-000000000001"}' \
    '{"type":"message_end","message":{"role":"assistant","stopReason":"error","errorMessage":"You'\''re out of extra usage · resets 6:30pm"}}' \
    >"$TMP_DIR/pi-extra.log"
  [[ "$(handoff_usage_limit_reason "$TMP_DIR/pi-extra.log")" == usage-limit ]] \
    || fail "out of extra usage should be a Pi plan limit"
  printf '%s\n' \
    '{"type":"session","id":"cccccccc-dddd-4eee-8fff-000000000002"}' \
    '{"type":"message_end","message":{"role":"assistant","stopReason":"error","errorMessage":"You'\''ve reached your ChatGPT workspace'\''s usage limit"}}' \
    >"$TMP_DIR/pi-workspace.log"
  [[ "$(handoff_usage_limit_reason "$TMP_DIR/pi-workspace.log")" == usage-limit ]] \
    || fail "workspace usage limit should be a Pi plan limit"
  printf '%s\n' \
    '{"type":"session","id":"cccccccc-dddd-4eee-8fff-000000000003"}' \
    '{"type":"message_end","message":{"role":"assistant","stopReason":"stop"}}' \
    "You've hit your 5-hour limit" >"$TMP_DIR/pi-stop.log"
  [[ -z "$(handoff_usage_limit_reason "$TMP_DIR/pi-stop.log")" ]] \
    || fail "a Pi stop must not pick up a phrase on another line"
  printf 'PASS: Pi error message_end yields usage-limit, and a plain xAI 429 does not\n'
}

test_chatgpt_limit_sets_reason
test_claude_text_sets_reason
test_rate_limit_has_no_reason
test_pi_limit_sets_reason
