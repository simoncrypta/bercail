#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$TEST_DIR/.." && pwd)"
TMP_DIR="$(mktemp -d)"
HERDR_CALL_LOG="$TMP_DIR/herdr-calls.log"
FILE_PATH="$TMP_DIR/src/main.rs"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

mkdir -p "$TMP_DIR/src" "$TMP_DIR/home" "$TMP_DIR/state-home"
printf 'fn main() {}\n' >"$FILE_PATH"

cat >"$TMP_DIR/herdr" <<'FAKE_HERDR'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$HERDR_CALL_LOG"
case "$1 $2" in
  "tab create")
    printf '%s\n' '{"result":{"tab":{"tab_id":"w1:tE"}}}'
    ;;
  "pane list")
    printf '%s\n' '{"result":{"panes":[{"pane_id":"w1:pE","tab_id":"w1:tE"}]}}'
    ;;
  "pane get")
    id="${3:-}"
    case "$id" in
      pane-agent|pane-sidebar|pane-review) tab="w1:t2" ;;
      pane-shell) tab="w1:t1" ;;
      w1:pOld) tab="w1:tOld" ;;
      *) tab="w1:tE" ;;
    esac
    printf '{"result":{"pane":{"pane_id":"%s","tab_id":"%s"}}}\n' "$id" "$tab"
    ;;
  *)
    printf '%s\n' '{"result":{}}'
    ;;
esac
FAKE_HERDR
chmod +x "$TMP_DIR/herdr"

export HERDR_BIN_PATH="$TMP_DIR/herdr"
export HERDR_CALL_LOG
export HERDR_PLUGIN_ROOT="$PLUGIN_ROOT"
export XDG_STATE_HOME="$TMP_DIR/state-home"
export HOME="$TMP_DIR/home"
export HERDR_WORKSPACE_ID=w1
export EDITOR=nano
unset AGENTIC_OPEN_PATH

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
  "active_center_view": "review",
  "active_sidebar_view": "files",
  "editors": {}
}
JSON

: >"$HERDR_CALL_LOG"
_open_editor "$FILE_PATH"
grep -q 'tab create --workspace w1' "$HERDR_CALL_LOG" || fail "should create a new editor tab"
grep -q -- "--label main.rs" "$HERDR_CALL_LOG" || fail "tab label should be the filename"
grep -q "pane run w1:pE" "$HERDR_CALL_LOG" || fail "should run the editor in the new tab pane"
grep -q "nano" "$HERDR_CALL_LOG" || fail "default editor command should follow EDITOR"
grep -q "$FILE_PATH" "$HERDR_CALL_LOG" || fail "editor command should include the file path"
grep -q "tab focus w1:tE" "$HERDR_CALL_LOG" || fail "should focus the new editor tab"
grep -q "pane move pane-agent" "$HERDR_CALL_LOG" || fail "should dock agent onto the editor tab"
grep -q "pane move pane-sidebar" "$HERDR_CALL_LOG" || fail "should dock sidebar onto the editor tab"
got="$(jq -r --arg p "$FILE_PATH" '.editors[$p].pane_id' "$(_state_path w1)")"
[[ "$got" == "w1:pE" ]] || fail "should record the editor pane, got $got"
got="$(jq -r '.active_center_view' "$(_state_path w1)")"
[[ "$got" == "editor" ]] || fail "should persist active_center_view=editor, got $got"

# Reuse the live editor tab instead of opening a second one.
jq --arg p "$FILE_PATH" '.editors[$p] = {"tab_id":"w1:tOld","pane_id":"w1:pOld"}' \
  "$(_state_path w1)" >"$TMP_DIR/w1.json" && mv "$TMP_DIR/w1.json" "$(_state_path w1)"
: >"$HERDR_CALL_LOG"
_open_editor "$FILE_PATH"
grep -q 'tab create' "$HERDR_CALL_LOG" && fail "should not create a second tab for the same file"
grep -q 'tab focus w1:tOld' "$HERDR_CALL_LOG" || fail "should focus the existing editor tab"
grep -q 'pane move pane-agent' "$HERDR_CALL_LOG" || fail "reused editor tab should dock agent"
grep -q 'pane move pane-sidebar' "$HERDR_CALL_LOG" || fail "reused editor tab should dock sidebar"
grep -q 'pane focus w1:pOld' "$HERDR_CALL_LOG" || fail "should focus the existing editor pane"

# argv is required; env is not enough (herdr invoke strips it).
: >"$HERDR_CALL_LOG"
if AGENTIC_OPEN_PATH="$FILE_PATH" _open_editor ""; then
  :
else
  fail "empty argv should still accept AGENTIC_OPEN_PATH when called in-process"
fi

unset AGENTIC_OPEN_PATH
if _open_editor 2>/dev/null; then
  fail "open-editor without a path should fail"
fi

got="$(_review_launch)"
[[ "$got" == tuicr* && "$got" == *"--no-update-check"* ]] \
  || fail "review should launch tuicr with --no-update-check, got $got"

# Close-tab: dock stickies onto the previous tab, then close. Never pane-close
# the editor center (that 3-column teardown has crashed Herdr).
cat >"$TMP_DIR/herdr" <<'FAKE_HERDR'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$HERDR_CALL_LOG"
case "$1 $2" in
  "tab list")
    printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","label":"Shell"},{"tab_id":"w1:t2","label":"Review"},{"tab_id":"w1:tE","label":"main.rs","focused":true}]}}'
    ;;
  "pane current")
    printf '%s\n' '{"result":{"pane":{"pane_id":"w1:pE","tab_id":"w1:tE"}}}'
    ;;
  "pane get")
    id="${3:-}"
    case "$id" in
      pane-shell) tab="w1:t1" ;;
      pane-review) tab="w1:t2" ;;
      *) tab="w1:tE" ;;
    esac
    printf '{"result":{"pane":{"pane_id":"%s","tab_id":"%s"}}}\n' "$id" "$tab"
    ;;
  "pane list")
    printf '%s\n' '{"result":{"panes":[{"pane_id":"w1:pE","tab_id":"w1:tE"},{"pane_id":"pane-agent","tab_id":"w1:tE"},{"pane_id":"pane-sidebar","tab_id":"w1:tE"},{"pane_id":"pane-review","tab_id":"w1:t2"},{"pane_id":"pane-shell","tab_id":"w1:t1"}]}}'
    ;;
  *)
    printf '%s\n' '{"result":{}}'
    ;;
esac
FAKE_HERDR
chmod +x "$TMP_DIR/herdr"

cat >"$(_state_path w1)" <<JSON
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
  "active_center_view": "editor",
  "active_sidebar_view": "files",
  "editors": {
    "$FILE_PATH": {"tab_id": "w1:tE", "pane_id": "w1:pE"}
  }
}
JSON

got="$(_tab_neighbor w1 w1:tE -1)"
[[ "$got" == "w1:t2" ]] || fail "previous neighbor of the editor tab should be Review, got $got"

: >"$HERDR_CALL_LOG"
_close_current_tab
grep -q 'pane move pane-agent' "$HERDR_CALL_LOG" || fail "close-tab should dock agent onto the previous tab"
grep -q 'pane move pane-sidebar' "$HERDR_CALL_LOG" || fail "close-tab should dock sidebar onto the previous tab"
grep -q 'tab focus w1:t2' "$HERDR_CALL_LOG" || fail "close-tab should focus the previous tab"
grep -q 'tab close w1:tE' "$HERDR_CALL_LOG" || fail "close-tab should close the editor tab"
grep -q 'pane close w1:pE' "$HERDR_CALL_LOG" && fail "close-tab must not pane-close the editor center"
agent_line="$(grep -n 'pane move pane-agent' "$HERDR_CALL_LOG" | head -1 | cut -d: -f1)"
close_line="$(grep -n 'tab close w1:tE' "$HERDR_CALL_LOG" | head -1 | cut -d: -f1)"
[[ "$agent_line" -lt "$close_line" ]] || fail "stickies must dock onto the previous tab before the editor tab closes"
got="$(jq -r --arg p "$FILE_PATH" '.editors[$p] // empty' "$(_state_path w1)")"
[[ -z "$got" ]] || fail "close-tab should drop the editor registry entry, got $got"
got="$(jq -r '.active_center_view' "$(_state_path w1)")"
[[ "$got" == "review" ]] || fail "close-tab should land on the previous Review tab, got $got"

# prefix+x on the editor center is the same as close-tab, not pane close.
jq --arg p "$FILE_PATH" '.editors[$p] = {"tab_id":"w1:tE","pane_id":"w1:pE"} | .active_center_view = "editor"' \
  "$(_state_path w1)" >"$TMP_DIR/w1.json" && mv "$TMP_DIR/w1.json" "$(_state_path w1)"
: >"$HERDR_CALL_LOG"
_close_focused_pane
grep -q 'tab close w1:tE' "$HERDR_CALL_LOG" || fail "close-pane on an editor center should close the tab"
grep -q 'pane close w1:pE' "$HERDR_CALL_LOG" && fail "close-pane on an editor center must not pane-close"

# prefix+x on agent/sidebar/shell/review is a no-op.
for pane in pane-agent pane-sidebar pane-shell pane-review; do
  cat >"$TMP_DIR/herdr" <<FAKE_HERDR
#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "\$*" >> "\$HERDR_CALL_LOG"
case "\$1 \$2" in
  "pane current")
    printf '%s\\n' '{"result":{"pane":{"pane_id":"$pane","tab_id":"w1:tE"}}}'
    ;;
  "tab list")
    printf '%s\\n' '{"result":{"tabs":[{"tab_id":"w1:t1","label":"Shell"},{"tab_id":"w1:t2","label":"Review"},{"tab_id":"w1:tE","label":"main.rs","focused":true}]}}'
    ;;
  *)
    printf '%s\\n' '{"result":{}}'
    ;;
esac
FAKE_HERDR
  chmod +x "$TMP_DIR/herdr"
  : >"$HERDR_CALL_LOG"
  _close_focused_pane
  grep -q 'pane close' "$HERDR_CALL_LOG" && fail "close-pane must not close layout pane $pane"
  grep -q 'tab close' "$HERDR_CALL_LOG" && fail "close-pane must not close a tab when focused on $pane"
done

# Extra user split still pane-closes.
cat >"$TMP_DIR/herdr" <<'FAKE_HERDR'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$HERDR_CALL_LOG"
case "$1 $2" in
  "pane current")
    printf '%s\n' '{"result":{"pane":{"pane_id":"w1:pExtra","tab_id":"w1:t1"}}}'
    ;;
  *)
    printf '%s\n' '{"result":{}}'
    ;;
esac
FAKE_HERDR
chmod +x "$TMP_DIR/herdr"
: >"$HERDR_CALL_LOG"
_close_focused_pane
grep -q 'pane close w1:pExtra' "$HERDR_CALL_LOG" || fail "close-pane should pane-close an extra split"
grep -q 'tab close' "$HERDR_CALL_LOG" && fail "close-pane on an extra split must not close a tab"

# Shell is not closable. Review is ephemeral (close-review / prefix+k).
cat >"$TMP_DIR/herdr" <<'FAKE_HERDR'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$HERDR_CALL_LOG"
case "$1 $2" in
  "tab list")
    printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","label":"Shell","focused":true},{"tab_id":"w1:t2","label":"Review"}]}}'
    ;;
  "pane current")
    printf '%s\n' '{"result":{"pane":{"pane_id":"pane-shell","tab_id":"w1:t1"}}}'
    ;;
  *)
    printf '%s\n' '{"result":{}}'
    ;;
esac
FAKE_HERDR
chmod +x "$TMP_DIR/herdr"
: >"$HERDR_CALL_LOG"
_close_current_tab
grep -q 'tab close' "$HERDR_CALL_LOG" && fail "close-tab must not close the Shell tab"

# pane.exited on an editor docks stickies and closes the leftover tab.
cat >"$TMP_DIR/herdr" <<'FAKE_HERDR'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$HERDR_CALL_LOG"
case "$1 $2" in
  "tab list")
    printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","label":"Shell"},{"tab_id":"w1:t2","label":"Review"},{"tab_id":"w1:tE","label":"main.rs","focused":true}]}}'
    ;;
  "pane get")
    id="${3:-}"
    case "$id" in
      pane-shell) tab="w1:t1" ;;
      pane-review) tab="w1:t2" ;;
      *) tab="w1:tE" ;;
    esac
    printf '{"result":{"pane":{"pane_id":"%s","tab_id":"%s"}}}\n' "$id" "$tab"
    ;;
  *)
    printf '%s\n' '{"result":{}}'
    ;;
esac
FAKE_HERDR
chmod +x "$TMP_DIR/herdr"
jq --arg p "$FILE_PATH" '.editors[$p] = {"tab_id":"w1:tE","pane_id":"w1:pE"} | .active_center_view = "editor"' \
  "$(_state_path w1)" >"$TMP_DIR/w1.json" && mv "$TMP_DIR/w1.json" "$(_state_path w1)"
: >"$HERDR_CALL_LOG"
_on_pane_exited w1:pE
grep -q 'tab close w1:tE' "$HERDR_CALL_LOG" || fail "editor pane.exited should close the leftover tab"
grep -q 'pane move pane-agent' "$HERDR_CALL_LOG" || fail "editor pane.exited should dock agent off the leftover tab"
got="$(jq -r --arg p "$FILE_PATH" '.editors[$p] // empty' "$(_state_path w1)")"
[[ -z "$got" ]] || fail "editor pane.exited should drop the registry entry, got $got"

printf 'PASS: open-editor creates a focused tab running the configured editor\n'
printf 'PASS: open-editor reuses the existing tab for the same file\n'
printf 'PASS: close-tab docks stickies onto the previous tab before closing\n'
printf 'PASS: close-pane on an editor center closes the tab instead of the pane\n'
printf 'PASS: close-pane ignores layout columns and pane-closes extra splits\n'
printf 'PASS: close-tab does not close Shell\n'
printf 'PASS: editor pane.exited recovers by closing the leftover tab\n'
