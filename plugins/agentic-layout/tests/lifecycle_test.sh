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
case "$1 $2" in
  "pane get")
    id="${3:-}"
    shell="false"
    [[ "$id" == "pane-sidebar" || "$id" == "pane-review" ]] && shell="true"
    if [[ "$shell" == "true" ]]; then
      printf '{"result":{"pane":{"pane_id":"%s","agent":null}}}\n' "$id"
    else
      printf '{"result":{"pane":{"pane_id":"%s","agent":"live"}}}\n' "$id"
    fi
    ;;
  "workspace list")
    printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","focused":true}]}}'
    ;;
  *)
    printf '%s\n' '{"result":{}}'
    ;;
esac
FAKE_HERDR
chmod +x "$TMP_DIR/herdr"
: >"$HERDR_CALL_LOG"

export HERDR_BIN_PATH="$TMP_DIR/herdr"
export HERDR_CALL_LOG
export HERDR_PLUGIN_ROOT="$PLUGIN_ROOT"
export XDG_STATE_HOME="$TMP_DIR/state-home"
export HOME="$TMP_DIR/home"

# shellcheck disable=SC1090
source "$PLUGIN_ROOT/layout.sh"

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
  "active_center_view": "shell",
  "active_sidebar_view": "files",
  "editors": {}
}
JSON

export HERDR_WORKSPACE_ID=w1
: >"$HERDR_CALL_LOG"
_startup_one w1
grep -q 'pane run pane-review' "$HERDR_CALL_LOG" && fail "startup should not relaunch corpse review pane"
grep -q 'pane run pane-sidebar' "$HERDR_CALL_LOG" || fail "startup should relaunch corpse sidebar pane"
grep -q 'pane run pane-shell' "$HERDR_CALL_LOG" && fail "startup should not relaunch live shell pane"

last="$(jq -r '.last_heal_unix // empty' "$(_state_path w1)")"
[[ -n "$last" && "$last" != "null" ]] || fail "startup heal should persist last_heal_unix"

: >"$HERDR_CALL_LOG"
_startup_one w1
grep -q 'pane run' "$HERDR_CALL_LOG" && fail "startup heal should respect cooldown and not relaunch again"

printf 'PASS: startup recovers corpse sidebar panes once per cooldown and leaves review alone\n'

# Missing Review is healthy: do not re-ensure the whole layout.
jq '.review_pane_id = "" | .review_tab_id = "" | del(.last_heal_unix)' "$(_state_path w1)" >"$TMP_DIR/w1.json"
mv "$TMP_DIR/w1.json" "$(_state_path w1)"
: >"$HERDR_CALL_LOG"
_startup_one w1
grep -q 'tab create' "$HERDR_CALL_LOG" && fail "startup must not create a Review tab when review is absent"
grep -q 'pane run pane-review' "$HERDR_CALL_LOG" && fail "startup must not launch tuicr when review is absent"
printf 'PASS: startup with empty review ids does not re-ensure Review\n'
