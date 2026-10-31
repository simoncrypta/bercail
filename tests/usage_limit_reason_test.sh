#!/usr/bin/env bash
# shellcheck shell=bash
# A stub opencode replays recorded plan-limit errors. No live provider calls.
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

test_chatgpt_limit_sets_reason
test_claude_text_sets_reason
test_rate_limit_has_no_reason
