#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$TEST_DIR/.." && pwd)"
TMP_DIR="$(mktemp -d)"
HERDR_CALL_LOG="$TMP_DIR/herdr-calls.log"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

write_herdr_shell() {
  cat >"$TMP_DIR/herdr" <<'FAKE_HERDR'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$HERDR_CALL_LOG"
printf '%s\n' '{"result":{"pane":{"pane_id":"pane-agent","agent":null}}}'
FAKE_HERDR
  chmod +x "$TMP_DIR/herdr"
}

export HERDR_BIN_PATH="$TMP_DIR/herdr"
export HERDR_CALL_LOG
export HERDR_PLUGIN_ROOT="$PLUGIN_ROOT"
export XDG_STATE_HOME="$TMP_DIR/state-home"
export HOME="$TMP_DIR/home"
write_herdr_shell

# shellcheck disable=SC1090
source "$PLUGIN_ROOT/layout.sh"

mkdir -p "$(_state_dir)"
cat >"$(_state_path w-child)" <<'JSON'
{
  "version": 4,
  "workspace_id": "w-child",
  "workdir": "/tmp/x",
  "label": "w-child",
  "shell_tab_id": "w-child:t1",
  "review_tab_id": "",
  "agent_pane_id": "pane-agent",
  "review_pane_id": "",
  "shell_pane_id": "pane-shell",
  "sidebar_pane_id": "pane-sidebar",
  "active_center_view": "shell",
  "active_sidebar_view": "files",
  "editors": {}
}
JSON
export HERDR_WORKSPACE_ID=w-child

prompt_file="$TMP_DIR/prompt.txt"
printf '/poteto-mode\n\nintro\n\nfix auth' >"$prompt_file"
export WT_HERDR_AGENT_CMD=cursor-agent
export WT_HERDR_AGENT_PROMPT_FILE="$prompt_file"
: >"$HERDR_CALL_LOG"
_launch_agent_on_pane pane-agent || fail "prompted launch should succeed"
run_line="$(grep '^pane run pane-agent ' "$HERDR_CALL_LOG" | head -1)"
[[ "$run_line" == pane\ run\ pane-agent\ * ]] \
  || fail "handoff should pane-run the agent launch; log=$(cat "$HERDR_CALL_LOG")"
[[ "$run_line" != *$'\n'* ]] || fail "pane run command must not contain newlines"
printf '%s' "$run_line" | grep -q -- '-li -c' \
  || fail "must pass one quoted login-shell -c line; log=$run_line"
printf '%s' "$run_line" | grep -q 'cursor-agent' \
  || fail "one-liner should exec cursor-agent; log=$run_line"
printf '%s' "$run_line" | grep -q 'cat' \
  || fail "one-liner should cat the prompt file; log=$run_line"
grep -q 'agent prompt' "$HERDR_CALL_LOG" \
  && fail "must not TUI-inject herdr agent prompt; log=$(cat "$HERDR_CALL_LOG")"
printf 'PASS: start-agent launches cursor-agent from a prompt file\n'

unset WT_HERDR_AGENT_PROMPT_FILE
unset WT_HERDR_AGENT_CMD
: >"$HERDR_CALL_LOG"
_launch_agent_on_pane pane-agent || true
grep -qE '^pane run pane-agent cursor-agent$' "$HERDR_CALL_LOG" \
  || fail "unprompted start should run the configured agent; log=$(cat "$HERDR_CALL_LOG")"
grep -q '/poteto-mode' "$HERDR_CALL_LOG" \
  && fail "no prompt file means no poteto-mode argv; log=$(cat "$HERDR_CALL_LOG")"
printf 'PASS: unprompted start-agent runs the configured agent\n'

# Default start ignores an inherited handoff prompt file.
export WT_HERDR_AGENT_CMD=cursor-agent
export WT_HERDR_AGENT_PROMPT_FILE="$prompt_file"
export WT_HERDR_AGENT_READY_TIMEOUT_MS=0
: >"$HERDR_CALL_LOG"
_start_default_agent || true
unset WT_HERDR_AGENT_READY_TIMEOUT_MS
grep -qE '^pane run pane-agent cursor-agent$' "$HERDR_CALL_LOG" \
  || fail "default start should run a clear agent session; log=$(cat "$HERDR_CALL_LOG")"
grep -q 'cat' "$HERDR_CALL_LOG" \
  && fail "default start must not cat a prompt file; log=$(cat "$HERDR_CALL_LOG")"
printf 'PASS: start-default-agent ignores an inherited prompt file\n'

# Handoff-agent without a prompt file fails.
unset WT_HERDR_AGENT_PROMPT_FILE
unset WT_HERDR_AGENT_CMD
: >"$HERDR_CALL_LOG"
if _start_handoff_agent 2>"$TMP_DIR/handoff-err"; then
  fail "handoff-agent without a prompt file should fail"
fi
grep -q 'WT_HERDR_AGENT_PROMPT_FILE' "$TMP_DIR/handoff-err" \
  || fail "handoff-agent should require the prompt file; err=$(cat "$TMP_DIR/handoff-err")"
grep -q 'pane run' "$HERDR_CALL_LOG" \
  && fail "handoff-agent without a prompt must not launch; log=$(cat "$HERDR_CALL_LOG")"
printf 'PASS: handoff-agent requires WT_HERDR_AGENT_PROMPT_FILE\n'

unset WT_HERDR_AGENT_PROMPT_FILE
unset WT_HERDR_AGENT_CMD

# Live agent + no prompt file: no-op (do not replace).
cat >"$TMP_DIR/herdr" <<'FAKE_HERDR'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$HERDR_CALL_LOG"
case "$1 $2" in
  "pane get")
    printf '%s\n' '{"result":{"pane":{"pane_id":"pane-agent","agent":"cursor"}}}'
    ;;
  *)
    printf '%s\n' '{"result":{}}'
    ;;
esac
FAKE_HERDR
chmod +x "$TMP_DIR/herdr"
: >"$HERDR_CALL_LOG"
_start_agent || true
grep -q 'pane run' "$HERDR_CALL_LOG" \
  && fail "must not restart a live agent when there is no prompt file; log=$(cat "$HERDR_CALL_LOG")"
printf 'PASS: unprompted start-agent does not replace a live agent\n'

# Prompt file + live agent: reset then launch.
RESET_FLAG="$TMP_DIR/reset-requested"
STARTED_FLAG="$TMP_DIR/started"
cat >"$TMP_DIR/herdr" <<FAKE_HERDR
#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "\$*" >> "$HERDR_CALL_LOG"
case "\$1 \$2" in
  "pane get")
    if [[ -f "$STARTED_FLAG" ]]; then
      printf '%s\\n' '{"result":{"pane":{"pane_id":"pane-agent","agent":"cursor"}}}'
    elif [[ -f "$RESET_FLAG" ]]; then
      printf '%s\\n' '{"result":{"pane":{"pane_id":"pane-agent","agent":null}}}'
    else
      printf '%s\\n' '{"result":{"pane":{"pane_id":"pane-agent","agent":"cursor"}}}'
    fi
    ;;
  "pane process-info")
    touch "$RESET_FLAG"
    printf '%s\\n' '{"result":{"process_info":{"foreground_process_group_id":0,"shell_pid":1,"foreground_processes":[]}}}'
    ;;
  "pane run")
    touch "$STARTED_FLAG"
    printf '%s\\n' '{"result":{}}'
    ;;
  *)
    printf '%s\\n' '{"result":{}}'
    ;;
esac
FAKE_HERDR
chmod +x "$TMP_DIR/herdr"
export WT_HERDR_AGENT_CMD=cursor-agent
export WT_HERDR_AGENT_PROMPT_FILE="$prompt_file"
: >"$HERDR_CALL_LOG"
rm -f "$RESET_FLAG" "$STARTED_FLAG"
_start_agent || fail "prompted start should replace the live agent"
grep -q 'pane process-info' "$HERDR_CALL_LOG" \
  || fail "should inspect the live agent before replacing it; log=$(cat "$HERDR_CALL_LOG")"
grep -qE 'pane run pane-agent .*-li -c ' "$HERDR_CALL_LOG" \
  || fail "after reset, should start via quoted login-shell -c; log=$(cat "$HERDR_CALL_LOG")"
grep -q 'cursor-agent' "$HERDR_CALL_LOG" \
  || fail "replacement launch should exec cursor-agent; log=$(cat "$HERDR_CALL_LOG")"
printf 'PASS: prompted start-agent replaces a live agent\n'

# create never starts the agent.
write_herdr_shell
unset WT_HERDR_AGENT_PROMPT_FILE
unset WT_HERDR_AGENT_CMD
: >"$HERDR_CALL_LOG"
# _layout_ensure needs more herdr surface; just assert create action does not
# launch via _launch_agent_on_pane by checking _ensure_agent_pane does not pane-run.
state="$(cat "$(_state_path w-child)")"
got="$(_ensure_agent_pane /tmp/x "$state" pane-shell)"
[[ "$got" == pane-agent ]] || fail "existing agent pane should be reused, got $got"
grep -q 'pane run' "$HERDR_CALL_LOG" \
  && fail "layout ensure must not start the agent; log=$(cat "$HERDR_CALL_LOG")"
printf 'PASS: layout create/ensure leaves the agent pane as a shell\n'

# Wait succeeds from a non-shell FG process even when the agent field lags.
cat >"$TMP_DIR/herdr" <<'FAKE_HERDR'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$HERDR_CALL_LOG"
case "$1 $2" in
  "pane get")
    printf '%s\n' '{"result":{"pane":{"pane_id":"pane-agent","agent":null}}}'
    ;;
  "pane process-info")
    printf '%s\n' '{"result":{"process_info":{"foreground_process_group_id":4242,"shell_pid":100,"foreground_processes":[{"pid":4242}]}}}'
    ;;
  *)
    printf '%s\n' '{"result":{}}'
    ;;
esac
FAKE_HERDR
chmod +x "$TMP_DIR/herdr"
: >"$HERDR_CALL_LOG"
_wait_agent_running pane-agent || fail "non-shell FG process should count as started"
printf 'PASS: wait treats a non-shell FG process as agent started\n'

# Timeout is bounded (do not wait the production 30s in tests).
cat >"$TMP_DIR/herdr" <<'FAKE_HERDR'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$HERDR_CALL_LOG"
printf '%s\n' '{"result":{"pane":{"pane_id":"pane-agent","agent":null},"process_info":{"foreground_process_group_id":1,"shell_pid":1}}}'
FAKE_HERDR
chmod +x "$TMP_DIR/herdr"
export WT_HERDR_AGENT_READY_TIMEOUT_MS=0
: >"$HERDR_CALL_LOG"
if _wait_agent_running pane-agent; then
  fail "timeout 0 with a shell pane must fail"
fi
unset WT_HERDR_AGENT_READY_TIMEOUT_MS
printf 'PASS: wait timeout is configurable and can fail immediately\n'
