#!/usr/bin/env bash
# shellcheck shell=bash
# A Pi stub replays recorded plan-limit errors. No live provider calls.
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

profile="$TMP_DIR/pi-profile"
mkdir -p "$profile/extensions" "$profile/agents"
guard="$profile/extensions/guard.ts"
printf '// guard\n' >"$guard"
jq -n --arg guard "$guard" --arg model "claude-bridge/lead-model:high" \
  '["pi","--model",$model,"-e","npm:pi-claude-bridge@0.11.0","-e",$guard]' >"$profile/lead.json"
export HANDOFF_PI_PROFILE="$profile"
export HANDOFF_PI_BIN="$TMP_DIR/bin/pi"
export HANDOFF_ARGV_LOG="$TMP_DIR/argv.log"
export HANDOFF_RUNS="$TMP_DIR/runs"
export HANDOFF_STUB_PAYLOAD="$TMP_DIR/payload"

# Prints $HANDOFF_STUB_PAYLOAD and exits 0. Pi exits 0 when the provider failed.
# Counts invocations so a limit cannot start a second command.
cat >"$HANDOFF_PI_BIN" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "role=${BERCAIL_ROLE:-} $*" >>"${HANDOFF_ARGV_LOG:?}"
printf '1\n' >>"${HANDOFF_RUNS:?}"
cat "${HANDOFF_STUB_PAYLOAD:?}"
exit 0
STUB
chmod +x "$HANDOFF_PI_BIN"

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

pi_log() {
  local id="$1" msg="$2"
  jq -nc --arg id "$id" --arg msg "$msg" \
    '{type:"session",version:3,id:$id},{type:"message_end",message:{role:"assistant",stopReason:"error",errorMessage:$msg}}'
}

test_pi_limit_sets_reason() {
  local header wt
  header=11111111-2222-4333-8444-555555555555
  pi_log "$header" "You've hit your 5-hour limit · resets 9pm" >"$HANDOFF_STUB_PAYLOAD"
  wt="$(run_stage bstack five-hour)"
  assert_limit "$wt" "five-hour"
  jq -e --arg id "$header" '.session_id == $id' "$wt/.bercail/handoff-result.json" >/dev/null \
    || fail "five-hour session: $(cat "$wt/.bercail/handoff-result.json")"

  header=22222222-3333-4444-8555-666666666666
  pi_log "$header" "Claude quota exceeded — rate limit (five_hour) — resets 9pm" >"$HANDOFF_STUB_PAYLOAD"
  wt="$(run_stage bstack quota)"
  assert_limit "$wt" "quota"

  header=aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee
  pi_log "$header" "You have hit your ChatGPT usage limit. Try again later." >"$HANDOFF_STUB_PAYLOAD"
  wt="$(run_stage bstack chatgpt)"
  assert_limit "$wt" "chatgpt"
  jq -e --arg id "$header" '.session_id == $id' "$wt/.bercail/handoff-result.json" >/dev/null \
    || fail "chatgpt session: $(cat "$wt/.bercail/handoff-result.json")"

  header=cccccccc-dddd-4eee-8fff-000000000000
  pi_log "$header" "You've reached your ChatGPT workspace's usage limit" >"$HANDOFF_STUB_PAYLOAD"
  wt="$(run_stage autopilot workspace)"
  assert_limit "$wt" "autopilot"
  grep -q '^role=autopilot ' "$HANDOFF_ARGV_LOG" \
    || fail "autopilot must set BERCAIL_ROLE: $(cat "$HANDOFF_ARGV_LOG")"
  printf 'PASS: Pi plan-limit message_end yields failed with reason usage-limit\n'
}

test_plain_429_has_no_reason() {
  local header wt
  header=bbbbbbbb-cccc-4ddd-8eee-ffffffffffff
  pi_log "$header" "429 Too many requests: weekly limit unverified" >"$HANDOFF_STUB_PAYLOAD"
  wt="$(run_stage bstack rate)"
  jq -e --arg id "$header" '.status == "failed" and .session_id == $id and (has("reason") | not)' \
    "$wt/.bercail/handoff-result.json" >/dev/null \
    || fail "a plain 429 must not set reason: $(cat "$wt/.bercail/handoff-result.json")"
  handoff_result_ok "$wt/.bercail/handoff-result.json" \
    || fail "rate-limit result should still pass handoff_result_ok"

  # A mention in other JSON, or a phrase beside a clean stop, is not a limit.
  printf '%s\n' '{"type":"text","text":"subscription_sharing_usage_limit_exceeded"}' >"$TMP_DIR/mention.log"
  [[ -z "$(handoff_usage_limit_reason "$TMP_DIR/mention.log")" ]] \
    || fail "a mention of the code is not a usage limit"
  printf '%s\n' \
    '{"type":"session","id":"cccccccc-dddd-4eee-8fff-000000000003"}' \
    '{"type":"message_end","message":{"role":"assistant","stopReason":"stop"}}' \
    "You've hit your 5-hour limit" >"$TMP_DIR/pi-stop.log"
  [[ -z "$(handoff_usage_limit_reason "$TMP_DIR/pi-stop.log")" ]] \
    || fail "a Pi stop must not pick up a phrase on another line"
  printf '%s\n' \
    '{"type":"session","id":"cccccccc-dddd-4eee-8fff-000000000001"}' \
    '{"type":"message_end","message":{"role":"assistant","stopReason":"error","errorMessage":"You'\''re out of extra usage · resets 6:30pm"}}' \
    >"$TMP_DIR/pi-extra.log"
  [[ "$(handoff_usage_limit_reason "$TMP_DIR/pi-extra.log")" == usage-limit ]] \
    || fail "out of extra usage should be a Pi plan limit"
  printf '%s\n' "You've hit your 5-hour limit" >"$TMP_DIR/stderr-only.log"
  [[ -z "$(handoff_usage_limit_reason "$TMP_DIR/stderr-only.log")" ]] \
    || fail "plain text is not a Pi plan limit"
  printf 'PASS: a plain 429 yields no usage-limit reason\n'
}

test_pi_limit_sets_reason
test_plain_429_has_no_reason
