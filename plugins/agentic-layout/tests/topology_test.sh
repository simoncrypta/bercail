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

cat >"$TMP_DIR/herdr" <<'FAKE_HERDR'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$HERDR_CALL_LOG"
printf '%s\n' '{"result":{}}'
FAKE_HERDR
chmod +x "$TMP_DIR/herdr"

export HERDR_BIN_PATH="$TMP_DIR/herdr"
export HERDR_CALL_LOG
export HERDR_PLUGIN_ROOT="$PLUGIN_ROOT"
export XDG_STATE_HOME="$TMP_DIR/state-home"
export HOME="$TMP_DIR/home"

# shellcheck disable=SC1090
source "$PLUGIN_ROOT/layout.sh"

empty_state='{"shell_tab_id":"","review_tab_id":"","editors":{}}'

# Adopt first tab even when it is labeled Review (recovery: rename later).
tabs=$'w1:t1\tReview\nw1:t2\tnotes'
got="$(printf '%s' "$(_adopt_tabs_json "$empty_state" "$tabs")" | jq -r '.shell_tab_id // empty')"
[[ "$got" == "w1:t1" ]] || fail "Review-first workspace should still adopt tab[0] as shell, got $got"

# Live shell_tab_id wins when still present.
state='{"shell_tab_id":"w1:t2","review_tab_id":"w1:t1","editors":{}}'
tabs=$'w1:t1\tReview\nw1:t2\tShell'
got="$(printf '%s' "$(_adopt_tabs_json "$state" "$tabs")" | jq -r '.shell_tab_id // empty')"
[[ "$got" == "w1:t2" ]] || fail "live shell_tab_id should win, got $got"

# Review is the other layout tab, never the shell tab.
got="$(printf '%s' "$(_adopt_tabs_json "$empty_state" "$tabs" "w1:t2")" | jq -r '.review_tab_id // empty')"
[[ "$got" == "w1:t1" ]] || fail "review should be the Review-labeled tab, got $got"

# Extra Shell/Review plus Herdr placeholders (main, "1") are closed; user tabs are not.
tabs=$'w1:t1\tShell\nw1:t2\tReview\nw1:t3\tmain\nw1:t4\teditor'
got="$(printf '%s' "$(_adopt_tabs_json "$empty_state" "$tabs")" | jq -r '.extra_tab_ids[]?')"
[[ "$got" == "w1:t3" ]] || fail "extra main placeholder should be collected, got '$got'"

tabs=$'w1:t0\t1\nw1:t1\tShell\nw1:t2\tReview'
got="$(printf '%s' "$(_adopt_tabs_json "$empty_state" "$tabs")" | jq -r '.extra_tab_ids[]?')"
[[ "$got" == "w1:t0" ]] || fail "leading numeric placeholder should be collected, got '$got'"

# Editor tabs are never adopted as Shell.
state='{"shell_tab_id":"","review_tab_id":"","editors":{"/tmp/a.rs":{"tab_id":"w1:t1","pane_id":"p1"}}}'
tabs=$'w1:t1\ta.rs\nw1:t2\tmain'
got="$(printf '%s' "$(_adopt_tabs_json "$state" "$tabs")" | jq -r '.shell_tab_id // empty')"
[[ "$got" == "w1:t2" ]] || fail "should skip editor tab and adopt main, got $got"

# Alt+1 / _select_tab_number docks shared panes onto the chosen tab.
cat >"$TMP_DIR/herdr" <<'FAKE_HERDR'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$HERDR_CALL_LOG"
case "$1" in
  tab)
    if [[ "${2:-}" == list ]]; then
      printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","label":"Shell","focused":true},{"tab_id":"w1:t2","label":"Review"}]}}'
    else
      printf '%s\n' '{"result":{}}'
    fi
    ;;
  pane)
    if [[ "${2:-}" == get ]]; then
      id="${3:-}"
      tab="w1:t2"
      [[ "$id" == pane-shell ]] && tab="w1:t1"
      printf '{"result":{"pane":{"pane_id":"%s","tab_id":"%s"}}}\n' "$id" "$tab"
    else
      printf '%s\n' '{"result":{}}'
    fi
    ;;
  *)
    printf '%s\n' '{"result":{}}'
    ;;
esac
FAKE_HERDR
chmod +x "$TMP_DIR/herdr"
: >"$HERDR_CALL_LOG"

mkdir -p "$(_state_dir)"
cat >"$(_state_path w1)" <<'JSON'
{
  "version": 4,
  "workspace_id": "w1",
  "workdir": "/tmp/worktree",
  "label": "w1",
  "shell_tab_id": "w1:t1",
  "review_tab_id": "w1:t2",
  "agent_pane_id": "pane-agent",
  "review_pane_id": "pane-review",
  "shell_pane_id": "pane-shell",
  "sidebar_pane_id": "pane-sidebar",
  "active_center_view": "review",
  "active_sidebar_view": "files",
  "editors": {}
}
JSON

export HERDR_WORKSPACE_ID=w1
_select_tab_number 1
grep -q 'tab focus w1:t1' "$HERDR_CALL_LOG" || fail "select-tab 1 should focus shell tab"
grep -q 'pane move pane-agent' "$HERDR_CALL_LOG" || fail "select-tab 1 should dock agent"
grep -q 'pane move pane-sidebar' "$HERDR_CALL_LOG" || fail "select-tab 1 should dock sidebar"
agent_line="$(grep -n 'pane move pane-agent' "$HERDR_CALL_LOG" | head -1 | cut -d: -f1)"
sidebar_line="$(grep -n 'pane move pane-sidebar' "$HERDR_CALL_LOG" | head -1 | cut -d: -f1)"
[[ "$agent_line" -lt "$sidebar_line" ]] || fail "agent should dock before sidebar so it keeps its final width"
grep -q -- '--ratio 0.416667' "$HERDR_CALL_LOG" || fail "agent move left-keep should be 5/12 (then swap into that slot)"
grep -q -- '--ratio 0.714285' "$HERDR_CALL_LOG" || fail "sidebar move left-keep should keep equal center share of remaining"
focus_line="$(grep -n 'tab focus w1:t1' "$HERDR_CALL_LOG" | head -1 | cut -d: -f1)"
[[ "$sidebar_line" -lt "$focus_line" ]] || fail "dock onto the hidden tab before focusing it"
got="$(jq -r '.active_center_view' "$(_state_path w1)")"
[[ "$got" == "shell" ]] || fail "select-tab should persist active_center_view before tab focus returns, got $got"

export HERDR_PLUGIN_EVENT_JSON='{"event":"tab_focused","data":{"type":"tab_focused","tab_id":"w1:t1","workspace_id":"w1"}}'
[[ "$(_event_id tab_id)" == "w1:t1" ]] || fail "event JSON should read data.tab_id, got $(_event_id tab_id)"
[[ "$(_event_id workspace_id)" == "w1" ]] || fail "event JSON should read data.workspace_id, got $(_event_id workspace_id)"
[[ "$(printf '%s' "$HERDR_PLUGIN_EVENT_JSON" | jq -r '.tab_id // .tab.tab_id // empty')" == "" ]] \
  || fail "legacy top-level tab_id parse should miss nested payloads"

: >"$HERDR_CALL_LOG"
unset HERDR_WORKSPACE_ID
_on_tab_focused "$(_event_id tab_id)"
[[ "$HERDR_WORKSPACE_ID" == "w1" ]] || fail "tab.focused should export data.workspace_id, got ${HERDR_WORKSPACE_ID:-}"
grep -q 'pane move pane-agent' "$HERDR_CALL_LOG" || fail "tab.focused should dock agent"
grep -q 'pane move pane-sidebar' "$HERDR_CALL_LOG" || fail "tab.focused should dock sidebar"
grep -q 'tab focus w1:t1' "$HERDR_CALL_LOG" && fail "tab.focused must not re-issue tab focus"

: >"$HERDR_CALL_LOG"
export HERDR_PLUGIN_EVENT_JSON='{"event":"tab_focused","data":{"type":"tab_focused","tab_id":"w1:t2","workspace_id":"w1"}}'
_on_tab_focused "$(_event_id tab_id)"
grep -q 'pane move' "$HERDR_CALL_LOG" && fail "tab.focused must not dock when stickies already live on the event tab"
grep -q 'tab focus' "$HERDR_CALL_LOG" && fail "redundant tab.focused must not focus a tab"

cat >"$TMP_DIR/herdr" <<'FAKE_HERDR'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$HERDR_CALL_LOG"
case "$1" in
  tab)
    if [[ "${2:-}" == list ]]; then
      printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","label":"Shell","focused":true},{"tab_id":"w1:t2","label":"Review"}]}}'
    else
      printf '%s\n' '{"result":{}}'
    fi
    ;;
  pane)
    if [[ "${2:-}" == get ]]; then
      id="${3:-}"
      tab="w1:t1"
      [[ "$id" == pane-review ]] && tab="w1:t2"
      printf '{"result":{"pane":{"pane_id":"%s","tab_id":"%s"}}}\n' "$id" "$tab"
    else
      printf '%s\n' '{"result":{}}'
    fi
    ;;
  *)
    printf '%s\n' '{"result":{}}'
    ;;
esac
FAKE_HERDR
chmod +x "$TMP_DIR/herdr"
: >"$HERDR_CALL_LOG"
export HERDR_PLUGIN_EVENT_JSON='{"event":"tab_focused","data":{"type":"tab_focused","tab_id":"w1:t1","workspace_id":"w1"}}'
_on_tab_focused "$(_event_id tab_id)"
grep -q 'pane move' "$HERDR_CALL_LOG" && fail "tab.focused must no-op when stickies already live on the tab"
grep -q 'pane resize' "$HERDR_CALL_LOG" && fail "tab.focused must not enforce ratios when nothing moved"

# Source-tab echo while stickies are docking onto another tab must not ping-pong.
jq '. + {dock_target_tab: "w1:t1"}' "$(_state_path w1)" >"$TMP_DIR/w1.json"
mv "$TMP_DIR/w1.json" "$(_state_path w1)"
: >"$HERDR_CALL_LOG"
export HERDR_PLUGIN_EVENT_JSON='{"event":"tab_focused","data":{"type":"tab_focused","tab_id":"w1:t2","workspace_id":"w1"}}'
_on_tab_focused "$(_event_id tab_id)"
grep -q 'pane move' "$HERDR_CALL_LOG" && fail "source-tab tab.focused echo must not re-dock stickies"

: >"$HERDR_CALL_LOG"
_select_tab_relative 1
grep -q 'tab focus w1:t2' "$HERDR_CALL_LOG" || fail "select-next-tab should focus the neighbor tab"

# Same-tab dock cannot pane-move; enforce must grow a leftover 0.25 inner split.
cat >"$TMP_DIR/herdr" <<'FAKE_HERDR'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$HERDR_CALL_LOG"
case "$1 $2" in
  "pane layout")
    printf '%s\n' '{"result":{"layout":{"splits":[{"id":"split_0_root","direction":"right","ratio":0.333333,"rect":{"width":300}},{"id":"split_1_1","direction":"right","ratio":0.25,"rect":{"width":200}}],"panes":[]}}}'
    ;;
  "pane get")
    printf '{"result":{"pane":{"pane_id":"%s","tab_id":"w1:t1"}}}\n' "${3:-}"
    ;;
  *)
    printf '%s\n' '{"result":{}}'
    ;;
esac
FAKE_HERDR
chmod +x "$TMP_DIR/herdr"
: >"$HERDR_CALL_LOG"
state="$(cat "$(_state_path w1)")"
_dock_shared_panes w1:t1 pane-shell "$state" >/dev/null
grep -q 'pane move' "$HERDR_CALL_LOG" && fail "same-tab dock should not pane-move"
grep -q 'pane resize --pane pane-shell --direction right --amount 0.464285' "$HERDR_CALL_LOG" \
  || fail "enforce should grow inner split from 0.25 to 0.714285, log: $(cat "$HERDR_CALL_LOG")"

# Shrink a too-wide center via the sidebar's left edge (negative amount is ignored).
cat >"$TMP_DIR/herdr" <<'FAKE_HERDR'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$HERDR_CALL_LOG"
case "$1 $2" in
  "pane layout")
    printf '%s\n' '{"result":{"layout":{"splits":[{"id":"split_0_root","direction":"right","ratio":0.183,"rect":{"width":300}},{"id":"split_1_1","direction":"right","ratio":0.9,"rect":{"width":245}}],"panes":[]}}}'
    ;;
  "pane get")
    printf '{"result":{"pane":{"pane_id":"%s","tab_id":"w1:t1"}}}\n' "${3:-}"
    ;;
  *)
    printf '%s\n' '{"result":{}}'
    ;;
esac
FAKE_HERDR
chmod +x "$TMP_DIR/herdr"
: >"$HERDR_CALL_LOG"
state="$(cat "$(_state_path w1)")"
_dock_shared_panes w1:t1 pane-shell "$state" >/dev/null
grep -q 'pane resize --pane pane-sidebar --direction left --amount 0.185715' "$HERDR_CALL_LOG" \
  || fail "enforce should shrink inner split from 0.9 to 0.714285 via sidebar, log: $(cat "$HERDR_CALL_LOG")"
grep -q 'pane resize --pane pane-agent --direction right --amount 0.233667' "$HERDR_CALL_LOG" \
  || fail "enforce should grow agent split from 0.183 to 0.416667, log: $(cat "$HERDR_CALL_LOG")"

printf 'PASS: tab identity chooses Shell first and does not destroy editors\n'
printf 'PASS: select-tab docks agent+sidebar onto the hidden tab before focusing it\n'
printf 'PASS: tab.focused nested payload docks without re-focusing the tab\n'
printf 'PASS: tab.focused no-ops when stickies already live on the tab\n'
printf 'PASS: source-tab tab.focused echo does not ping-pong stickies\n'
printf 'PASS: select-next-tab focuses the neighbor tab\n'
printf 'PASS: same-tab dock enforces equal agent/shell column ratios\n'
