#!/usr/bin/env bash
# notify.sh: classification, filters, enrichment, delivery, auth alerts.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$TEST_DIR/.." && pwd)"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

export HERDR_CALL_LOG="$TMP_DIR/herdr-calls.log"
export PANES_DIR="$TMP_DIR/panes"
export CURL_DIR="$TMP_DIR/curl-log"
mkdir -p "$PANES_DIR" "$CURL_DIR"

# Fake herdr: `pane get ID` prints $PANES_DIR/ID.json (missing => error).
cat >"$TMP_DIR/herdr" <<'FAKE_HERDR'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$HERDR_CALL_LOG"
case "$1 $2" in
  "pane get")
    [[ -f "$PANES_DIR/$3.json" ]] || { echo '{"error":{"code":"pane_not_found"}}'; exit 1; }
    printf '{"result":{"pane":%s}}\n' "$(cat "$PANES_DIR/$3.json")"
    ;;
  "workspace get")
    printf '%s\n' '{"result":{"workspace":{"workspace_id":"w9","label":"Fallback","worktree":{"repo_name":"other"}}}}'
    ;;
  *) printf '%s\n' '{"result":{}}' ;;
esac
FAKE_HERDR
chmod +x "$TMP_DIR/herdr"

# Fake curl: log argv, header file contents, body; reply with $CURL_DIR/code.
cat >"$TMP_DIR/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
n=$(( $(cat "$CURL_DIR/count" 2>/dev/null || echo 0) + 1 ))
echo "$n" >"$CURL_DIR/count"
printf '%s\n' "$*" >>"$CURL_DIR/argv.log"
url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -H) [[ "$2" == @* ]] && cat "${2#@}" >"$CURL_DIR/headers.$n"; shift 2 ;;
    -m|-o|-w|-X|--data-binary) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
cat >"$CURL_DIR/body.$n"
printf '%s\n' "$url" >"$CURL_DIR/url.$n"
code="$(cat "$CURL_DIR/code" 2>/dev/null || echo 200)"
printf '%s' "$code"
FAKE_CURL
chmod +x "$TMP_DIR/curl"

export HERDR_BIN_PATH="$TMP_DIR/herdr"
export NOTIFY_CURL="$TMP_DIR/curl"
export NOTIFY_RETRY_SLEEP=0
export HERDR_PLUGIN_ROOT="$PLUGIN_ROOT"
export HOME="$TMP_DIR/home"
export XDG_STATE_HOME="$TMP_DIR/state-home"
export XDG_CONFIG_HOME="$TMP_DIR/config"
export HERDR_PLUGIN_STATE_DIR="$TMP_DIR/plugin-state"
SINKS="$XDG_CONFIG_HOME/bercail/notify.d"
mkdir -p "$HOME" "$SINKS"

# shellcheck disable=SC1091
source "$PLUGIN_ROOT/notify.sh"

# --- classification ------------------------------------------------------
[[ "$(notify_classify working "done")" == finished ]] || fail "working->done"
[[ "$(notify_classify working idle)" == finished ]] || fail "working->idle"
[[ "$(notify_classify blocked idle)" == finished ]] || fail "blocked->idle"
[[ "$(notify_classify "done" idle)" == none ]] || fail "done->idle is a seen-flip"
[[ "$(notify_classify '' idle)" == none ]] || fail "unknown prev idle"
[[ "$(notify_classify '' "done")" == none ]] || fail "first sight done"
[[ "$(notify_classify working blocked)" == blocked ]] || fail "working->blocked"
[[ "$(notify_classify blocked blocked)" == none ]] || fail "blocked twice"
[[ "$(notify_classify idle working)" == none ]] || fail "working"
[[ "$(notify_classify "done" "done")" == none ]] || fail "duplicate done"

notify_glob_match "Work, *_Leftlane_app" "Render-preview_leftlane_APP" || fail "glob ci"
! notify_glob_match "Work" "Workbench" || fail "glob must anchor"
notify_list_has "finished, blocked" Blocked || fail "list_has"

# --- fixtures ------------------------------------------------------------
DESK="$TMP_DIR/desk"
git init -q -b feat/render "$DESK"
mkdir -p "$DESK/.bercail" "$XDG_STATE_HOME/agentic-dev"
printf '%s\n' '{"status":"ready","summary":"Rendered preview","session_id":"s1"}' >"$DESK/.bercail/handoff-result.json"
printf '%s\n' \
  "{\"ok\":true,\"path\":\"$DESK\",\"branch\":\"old\",\"issue\":\"lef-old\"}" \
  "{\"ok\":true,\"path\":\"$DESK\",\"branch\":\"feat/render\",\"issue\":\"lef2745-2vs\",\"stage\":\"start\",\"harness\":\"claude\"}" \
  >"$XDG_STATE_HOME/agentic-dev/handoffs.jsonl"

set_pane() { # id status agent role ws
  local agent='null' tokens='{}'
  [[ -n "$3" ]] && agent="\"$3\""
  [[ -n "$4" ]] && tokens="{\"agentic_role\":\"$4\"}"
  printf '{"pane_id":"%s","workspace_id":"%s","agent_status":"%s","agent":%s,"tokens":%s}\n' \
    "$1" "${5:-w6N}" "$2" "$agent" "$tokens" >"$PANES_DIR/$1.json"
}

fire() { # pane event_status [label repo]
  export HERDR_PLUGIN_EVENT_JSON="{\"event\":\"pane.agent_status_changed\",\"data\":{\"pane_id\":\"$1\",\"workspace_id\":\"w6N\",\"agent_status\":\"$2\",\"agent\":\"claude\",\"title\":\"t\"}}"
  export HERDR_PLUGIN_CONTEXT_JSON="{\"workspace_id\":\"w6N\",\"workspace_label\":\"${3:-Render-preview_Leftlane_app}\",\"workspace_cwd\":\"$DESK\",\"worktree\":{\"repo_name\":\"${4:-leftlane_app}\",\"checkout_path\":\"$DESK\",\"is_linked_worktree\":true}}"
  bash "$PLUGIN_ROOT/notify.sh" event 2>>"$TMP_DIR/stderr.log"
}

posts() { cat "$CURL_DIR/count" 2>/dev/null || echo 0; }
last_body() { cat "$CURL_DIR/body.$(posts)"; }

# --- no sinks: no herdr calls at all ---------------------------------------
set_pane p2 working claude agent
fire p2 working
[[ ! -s "$HERDR_CALL_LOG" ]] || fail "no sinks must not call herdr"

# --- sinks -----------------------------------------------------------------
SECRET="sekret-$$-value"
cat >"$SINKS/work-shep.toml" <<TOML
# work Shep
url = "https://example.invalid/hook/work"
key = "$SECRET"
repos = leftlane_app
panes = agent
notify = finished, blocked
TOML
chmod 600 "$SINKS/work-shep.toml"
printf '%s\n' "$SECRET-perso" >"$TMP_DIR/perso.key"
chmod 600 "$TMP_DIR/perso.key"
cat >"$SINKS/perso.toml" <<TOML
url = https://example.invalid/hook/perso
key_file = $TMP_DIR/perso.key
workspaces = Personal*
auth = bearer
TOML
printf 'url = https://example.invalid/off\nenabled = false\n' >"$SINKS/off.toml"

set_pane p2 working claude agent
fire p2 working
[[ "$(posts)" == 0 ]] || fail "working must not post"

set_pane p2 "done" claude agent
fire p2 "done"
[[ "$(posts)" == 1 ]] || fail "working->done should post once to work-shep only, got $(posts)"
grep -q 'hook/work' "$CURL_DIR/url.1" || fail "wrong sink url"
body="$(last_body)"
jq -e '.kind == "finished" and .schema == "bercail.agent_status/v1" and .sink == "work-shep"' <<<"$body" >/dev/null || fail "envelope: $body"
jq -e '.pane.status == "done" and .pane.previous_status == "working" and .pane.verified == true and .pane.role == "agent"' <<<"$body" >/dev/null || fail "pane: $body"
jq -e '.workspace.repo == "leftlane_app" and .workspace.linked == true' <<<"$body" >/dev/null || fail "workspace: $body"
jq -e '.desk.branch == "feat/render" and .desk.issue == "lef2745-2vs" and .desk.stage == "start" and .desk.harness == "claude" and .desk.result.status == "ready"' <<<"$body" >/dev/null || fail "desk: $body"
jq -e '.event.event == "pane.agent_status_changed" and (.event_id | startswith("p2:finished:"))' <<<"$body" >/dev/null || fail "raw event: $body"

# key only in the 0600 header file, never argv or body
! grep -q "$SECRET" "$CURL_DIR/argv.log" || fail "key leaked into curl argv"
! grep -q "$SECRET" "$CURL_DIR/body.1" || fail "key leaked into body"
grep -q "Authorization: Bearer $SECRET" "$CURL_DIR/headers.1" || fail "bearer header"
grep -q "X-Automation-Key: $SECRET" "$CURL_DIR/headers.1" || fail "x-automation-key header"
leftover="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -newer "$SINKS/work-shep.toml" -type f -name 'tmp.*' -exec grep -l "$SECRET" {} + 2>/dev/null || true)"
[[ -z "$leftover" ]] || fail "header temp file left behind"

# duplicate / presentation-only / seen-flip events
fire p2 "done"
set_pane p2 idle claude agent
fire p2 idle
[[ "$(posts)" == 1 ]] || fail "dup done and done->idle must not post, got $(posts)"

# stale event: herdr says working although the event says done
set_pane p2 working claude agent
fire p2 "done"
[[ "$(posts)" == 1 ]] || fail "stale done must be verified live, got $(posts)"

# blocked once, then finished
set_pane p2 blocked claude agent
fire p2 blocked
fire p2 blocked
[[ "$(posts)" == 2 ]] || fail "blocked should post exactly once, got $(posts)"
jq -e '.kind == "blocked"' <<<"$(last_body)" >/dev/null || fail "blocked kind"
set_pane p2 idle claude agent
fire p2 idle
[[ "$(posts)" == 3 ]] || fail "blocked->idle should finish"

# shell pane flaps never post (no agent / non-agent role)
set_pane p1 working "" center_shell
fire p1 working
set_pane p1 "done" "" center_shell
fire p1 "done"
set_pane p3 working claude review
fire p3 working
set_pane p3 "done" claude review
fire p3 "done"
[[ "$(posts)" == 3 ]] || fail "shell/review panes must not post, got $(posts)"

# workspace filters route to the right sink
set_pane p7 working codex agent
fire p7 working "Personal-notes" "notes"
set_pane p7 "done" codex agent
fire p7 "done" "Personal-notes" "notes"
[[ "$(posts)" == 4 ]] || fail "perso sink should get it, got $(posts)"
grep -q 'hook/perso' "$CURL_DIR/url.4" || fail "routed to wrong sink"
grep -q "Authorization: Bearer $SECRET-perso" "$CURL_DIR/headers.4" || fail "key_file bearer"
! grep -q "X-Automation-Key" "$CURL_DIR/headers.4" || fail "auth=bearer must send one header"

# pane gone: fall back to event status, unverified
set_pane p8 working claude agent
fire p8 working
rm -f "$PANES_DIR/p8.json"
fire p8 "done"
[[ "$(posts)" == 5 ]] || fail "unverified finish should still post"
jq -e '.pane.verified == false and .pane.status == "done"' <<<"$(last_body)" >/dev/null || fail "verified=false"

# --- auth failure: stderr every time, one toast per episode, clears on 2xx --
: >"$HERDR_CALL_LOG"
echo 401 >"$CURL_DIR/code"
for s in working "done" working "done"; do
  set_pane p2 "$s" claude agent
  fire p2 "$s"
done
[[ "$(grep -c 'notification show bercail notify: work-shep key rejected' "$HERDR_CALL_LOG")" == 1 ]] \
  || fail "one toast per auth episode: $(cat "$HERDR_CALL_LOG")"
[[ "$(grep -c "rejected its key (HTTP 401)" "$TMP_DIR/stderr.log")" == 2 ]] || fail "stderr each 401"
! grep -q "$SECRET\|example.invalid" "$TMP_DIR/stderr.log" || fail "secret or url in stderr"
jq -e '.auth_failed == true and .failures == 2' "$HERDR_PLUGIN_STATE_DIR/notify/sinks/work-shep.json" >/dev/null || fail "sink state"
echo 200 >"$CURL_DIR/code"
set_pane p2 working claude agent; fire p2 working
set_pane p2 "done" claude agent; fire p2 "done"
grep -q 'work-shep recovered' "$HERDR_CALL_LOG" || fail "recovery toast"
jq -e '.auth_failed == false and .failures == 0' "$HERDR_PLUGIN_STATE_DIR/notify/sinks/work-shep.json" >/dev/null || fail "recovered state"

# --- 5xx retries once ---------------------------------------------------------
before="$(posts)"
echo 503 >"$CURL_DIR/code"
set_pane p2 working claude agent; fire p2 working
set_pane p2 "done" claude agent; fire p2 "done"
[[ "$(( $(posts) - before ))" == 2 ]] || fail "5xx should retry once"
echo 200 >"$CURL_DIR/code"

# --- insecure sink files are refused -----------------------------------------
chmod 644 "$SINKS/work-shep.toml"
before="$(posts)"
set_pane p2 working claude agent; fire p2 working
set_pane p2 "done" claude agent; fire p2 "done"
[[ "$(posts)" == "$before" ]] || fail "world-readable key sink must not post"
grep -q "work-shep' key file is readable by others" "$TMP_DIR/stderr.log" || fail "insecure warning"
chmod 600 "$SINKS/work-shep.toml"

# --- status / test never print secrets ----------------------------------------
out="$(bash "$PLUGIN_ROOT/notify.sh" status)"
grep -q -- '- work-shep enabled=true url=set key=set' <<<"$out" || fail "status: $out"
grep -q -- '- off enabled=false' <<<"$out" || fail "status off: $out"
! grep -q "$SECRET\|example.invalid" <<<"$out" || fail "status leaked secrets"
out="$(bash "$PLUGIN_ROOT/notify.sh" test work-shep)"
[[ "$out" == "work-shep HTTP 200" ]] || fail "test: $out"
jq -e '.kind == "test"' <<<"$(last_body)" >/dev/null || fail "test payload"

echo "notify_test: ok"
