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

write_herdr() {
  cat >"$TMP_DIR/herdr" <<'FAKE_HERDR'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$HERDR_CALL_LOG"
case "$1 $2" in
  "tab list")
    printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","label":"Shell","focused":true}]}}'
    ;;
  "tab create")
    printf '%s\n' '{"result":{"tab":{"tab_id":"w1:t2"}}}'
    ;;
  "pane list")
    printf '%s\n' '{"result":{"panes":[{"pane_id":"pane-shell","tab_id":"w1:t1"},{"pane_id":"pane-agent","tab_id":"w1:t1"},{"pane_id":"pane-sidebar","tab_id":"w1:t1"},{"pane_id":"pane-review","tab_id":"w1:t2"}]}}'
    ;;
  "pane get")
    id="${3:-}"
    tab="w1:t1"
    [[ "$id" == pane-review ]] && tab="w1:t2"
    agent="null"
    [[ "$id" == pane-agent ]] && agent='"live"'
    printf '{"result":{"pane":{"pane_id":"%s","tab_id":"%s","agent":%s}}}\n' "$id" "$tab" "$agent"
    ;;
  "pane current")
    printf '%s\n' '{"result":{"pane":{"pane_id":"pane-review","tab_id":"w1:t2"}}}'
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
}

export HERDR_BIN_PATH="$TMP_DIR/herdr"
export HERDR_CALL_LOG
export HERDR_PLUGIN_ROOT="$PLUGIN_ROOT"
export XDG_STATE_HOME="$TMP_DIR/state-home"
export HOME="$TMP_DIR/home"
write_herdr
: >"$HERDR_CALL_LOG"

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

export HERDR_WORKSPACE_ID=w1
state="$(cat "$(_state_path w1)")"
tabs="$(_ensure_shell_and_review_tabs w1 /tmp/worktree "$state")"
review_id="${tabs#*$'\t'}"
[[ -z "$review_id" ]] || fail "ensure should not create a Review tab, got '$review_id'"
grep -q 'tab create' "$HERDR_CALL_LOG" && fail "ensure must not tab-create Review"
printf 'PASS: layout ensure does not create a Review tab\n'

: >"$HERDR_CALL_LOG"
_open_review || fail "open-review should succeed"
got="$(jq -r '.review_tab_id' "$(_state_path w1)")"
[[ "$got" == "w1:t2" ]] || fail "open-review should persist review_tab_id, got $got"
got="$(jq -r '.review_pane_id' "$(_state_path w1)")"
[[ "$got" == "pane-review" ]] || fail "open-review should persist review_pane_id, got $got"
grep -q 'tab create' "$HERDR_CALL_LOG" || fail "open-review should create the Review tab"
grep -qE 'tuicr(\\ | ).*-w' "$HERDR_CALL_LOG" \
  || fail "open-review should launch tuicr -w; log=$(cat "$HERDR_CALL_LOG")"
grep -q -- '--no-update-check' "$HERDR_CALL_LOG" \
  || fail "open-review should pass --no-update-check; log=$(cat "$HERDR_CALL_LOG")"
printf 'PASS: select-review / open-review creates Review and launches tuicr -w\n'

# After open, fake herdr must report the Review tab as live so close can find it.
cat >"$TMP_DIR/herdr" <<'FAKE_HERDR'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$HERDR_CALL_LOG"
case "$1 $2" in
  "tab list")
    printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","label":"Shell","focused":false},{"tab_id":"w1:t2","label":"Review","focused":true}]}}'
    ;;
  "pane list")
    printf '%s\n' '{"result":{"panes":[{"pane_id":"pane-shell","tab_id":"w1:t1"},{"pane_id":"pane-agent","tab_id":"w1:t2"},{"pane_id":"pane-sidebar","tab_id":"w1:t2"},{"pane_id":"pane-review","tab_id":"w1:t2"}]}}'
    ;;
  "pane get")
    id="${3:-}"
    tab="w1:t2"
    [[ "$id" == pane-shell ]] && tab="w1:t1"
    printf '{"result":{"pane":{"pane_id":"%s","tab_id":"%s"}}}\n' "$id" "$tab"
    ;;
  "pane layout")
    printf '%s\n' '{"result":{"layout":{"splits":[],"panes":[]}}}'
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
_close_review
got="$(jq -r '.review_tab_id' "$(_state_path w1)")"
[[ "$got" == "" ]] || fail "close-review should clear review_tab_id, got $got"
got="$(jq -r '.review_pane_id' "$(_state_path w1)")"
[[ "$got" == "" ]] || fail "close-review should clear review_pane_id, got $got"
got="$(jq -r '.active_center_view' "$(_state_path w1)")"
[[ "$got" == "shell" ]] || fail "close-review should land on shell, got $got"
grep -q 'tab close w1:t2' "$HERDR_CALL_LOG" || fail "close-review should close the Review tab"
printf 'PASS: close-review docks to Shell and clears review ids\n'

# pane.exited on the review center closes the Review tab.
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
_on_pane_exited pane-review
got="$(jq -r '.review_tab_id' "$(_state_path w1)")"
[[ "$got" == "" ]] || fail "review pane exit should clear review_tab_id, got $got"
grep -q 'tab close w1:t2' "$HERDR_CALL_LOG" || fail "review pane exit should close the Review tab"
printf 'PASS: review pane exit closes the Review tab\n'

git_dir="$TMP_DIR/worktree"
mkdir -p "$git_dir"
git -C "$git_dir" init -q
git -C "$git_dir" config user.email t@example.com
git -C "$git_dir" config user.name t
printf 'base\n' >"$git_dir/file.txt"
git -C "$git_dir" add file.txt
git -C "$git_dir" commit -qm base
printf 'dirty\n' >"$git_dir/file.txt"

cat >"$(_state_path w1)" <<JSON
{
  "version": 4,
  "workspace_id": "w1",
  "workdir": "$git_dir",
  "label": "w1",
  "shell_tab_id": "w1:t1",
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

cat >"$TMP_DIR/herdr" <<'FAKE_HERDR'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$HERDR_CALL_LOG"
case "$1 $2" in
  "tab create")
    printf '%s\n' '{"result":{"tab":{"tab_id":"w1:t2"}}}'
    ;;
  "tab list")
    printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","label":"Shell"},{"tab_id":"w1:t2","label":"Review"}]}}'
    ;;
  "pane list")
    printf '%s\n' '{"result":{"panes":[{"pane_id":"pane-shell","tab_id":"w1:t1"},{"pane_id":"pane-agent","tab_id":"w1:t1"},{"pane_id":"pane-sidebar","tab_id":"w1:t1"},{"pane_id":"pane-review","tab_id":"w1:t2"}]}}'
    ;;
  "pane get")
    id="${3:-}"
    tab="w1:t1"
    [[ "$id" == pane-review ]] && tab="w1:t2"
    printf '{"result":{"pane":{"pane_id":"%s","tab_id":"%s"}}}\n' "$id" "$tab"
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

export HERDR_PLUGIN_EVENT_JSON='{"data":{"agent_status":"idle","pane_id":"pane-agent","workspace_id":"w1"}}'
: >"$HERDR_CALL_LOG"
_on_agent_status_changed
grep -q 'tab create' "$HERDR_CALL_LOG" && fail "idle must not open Review"
got="$(jq -r '.review_tab_id' "$(_state_path w1)")"
[[ "$got" == "" ]] || fail "idle must not persist review_tab_id"

export HERDR_PLUGIN_EVENT_JSON='{"data":{"agent_status":"done","pane_id":"pane-shell","workspace_id":"w1"}}'
: >"$HERDR_CALL_LOG"
_on_agent_status_changed
grep -q 'tab create' "$HERDR_CALL_LOG" && fail "non-agent done must not open Review"

export HERDR_PLUGIN_EVENT_JSON='{"data":{"agent_status":"done","pane_id":"pane-agent","workspace_id":"w1"}}'
: >"$HERDR_CALL_LOG"
_on_agent_status_changed
grep -q 'tab create' "$HERDR_CALL_LOG" || fail "agent done should open Review; log=$(cat "$HERDR_CALL_LOG")"
grep -qE 'tuicr(\\ | ).*-w' "$HERDR_CALL_LOG" \
  || fail "agent done should launch tuicr; log=$(cat "$HERDR_CALL_LOG")"
got="$(jq -r '.review_tab_id' "$(_state_path w1)")"
[[ "$got" == "w1:t2" ]] || fail "agent done should persist review_tab_id, got $got"
grep -q -- '--no-update-check' "$HERDR_CALL_LOG" \
  || fail "agent done should launch tuicr with --no-update-check; log=$(cat "$HERDR_CALL_LOG")"
printf 'PASS: agent done opens tuicr; idle and other panes do not\n'

reset_review_state() {
  cat >"$(_state_path w1)" <<JSON
{
  "version": 4,
  "workspace_id": "w1",
  "workdir": "$git_dir",
  "label": "w1",
  "shell_tab_id": "w1:t1",
  "review_tab_id": "",
  "review_pane_id": "",
  "agent_pane_id": "pane-agent",
  "shell_pane_id": "pane-shell",
  "sidebar_pane_id": "pane-sidebar",
  "active_center_view": "shell",
  "active_sidebar_view": "files",
  "editors": {},
  "last_auto_review_unix": 0
}
JSON
}

# Clean tree on the default branch: nothing to review.
base_branch="$(git -C "$git_dir" rev-parse --abbrev-ref HEAD)"
git -C "$git_dir" checkout -- file.txt
git -C "$git_dir" status --porcelain | grep -q . && fail "expected a clean worktree"
reset_review_state
: >"$HERDR_CALL_LOG"
_on_agent_status_changed
grep -q 'tab create' "$HERDR_CALL_LOG" && fail "clean $base_branch must not open Review"
printf 'PASS: clean default branch does not auto-open Review\n'

# Feature branch vs main/master: always tuicr -r <base> -w, not working-tree-only.
git -C "$git_dir" checkout -q -b feat
printf 'feat\n' >"$git_dir/file.txt"
git -C "$git_dir" add file.txt
git -C "$git_dir" commit -qm feat
reset_review_state
: >"$HERDR_CALL_LOG"
_on_agent_status_changed
grep -q 'tab create' "$HERDR_CALL_LOG" || fail "branch-ahead should open Review; log=$(cat "$HERDR_CALL_LOG")"
grep -Fq -- "-r\\ ${base_branch}\\ -w" "$HERDR_CALL_LOG" \
  || fail "clean feature should launch tuicr -r ${base_branch} -w; log=$(cat "$HERDR_CALL_LOG")"
grep -q "${base_branch}...HEAD" "$HERDR_CALL_LOG" \
  && fail "should not use three-dot range; log=$(cat "$HERDR_CALL_LOG")"
printf 'PASS: committed feature branch opens tuicr -r %s -w\n' "$base_branch"

printf 'wip\n' >"$git_dir/file.txt"
reset_review_state
: >"$HERDR_CALL_LOG"
_on_agent_status_changed
grep -Fq -- "-r\\ ${base_branch}\\ -w" "$HERDR_CALL_LOG" \
  || fail "dirty feature should still launch tuicr -r ${base_branch} -w; log=$(cat "$HERDR_CALL_LOG")"
grep -E 'tuicr(\\ | )-w(\\ | )--no-update-check' "$HERDR_CALL_LOG" \
  && fail "dirty feature must not drop the PR base; log=$(cat "$HERDR_CALL_LOG")"
printf 'PASS: dirty feature branch still opens tuicr -r %s -w\n' "$base_branch"

# auto_review = false skips even a dirty tree.
git -C "$git_dir" checkout -q -f "$base_branch"
printf 'dirty-again\n' >"$git_dir/file.txt"
mkdir -p "$HOME/.config/agentic-dev"
cat >"$HOME/.config/agentic-dev/config.toml" <<'EOF'
[layout]
review = "tuicr"
auto_review = false
EOF
reset_review_state
: >"$HERDR_CALL_LOG"
_on_agent_status_changed
grep -q 'tab create' "$HERDR_CALL_LOG" && fail "auto_review=false must not open Review"
printf 'PASS: auto_review=false disables the agent-done hook\n'

got="$(_review_launch "$git_dir")"
[[ "$got" == tuicr* && "$got" == *"--no-update-check"* ]] \
  || fail "review launch should be tuicr with --no-update-check, got $got"
printf 'PASS: review launch is tuicr --no-update-check\n'

# Someone else's PR on this checkout → tuicr pr N, not local -w.
export GH_BIN="$TMP_DIR/gh"
cat >"$GH_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "pr" && "${2:-}" == "view" ]]; then
  printf '%s\n' '{"number":42,"author":{"login":"other-dev"}}'
  exit 0
fi
if [[ "${1:-}" == "api" && "${2:-}" == "user" ]]; then
  printf '%s\n' 'me'
  exit 0
fi
exit 1
EOF
chmod +x "$GH_BIN"
got="$(_review_launch "$git_dir")"
[[ "$got" == "tuicr pr 42 --no-update-check" ]] \
  || fail "foreign PR should launch tuicr pr 42, got $got"
printf 'PASS: someone else'\''s PR launches tuicr pr\n'

cat >"$GH_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "pr" && "${2:-}" == "view" ]]; then
  printf '%s\n' '{"number":7,"author":{"login":"me"}}'
  exit 0
fi
if [[ "${1:-}" == "api" && "${2:-}" == "user" ]]; then
  printf '%s\n' 'me'
  exit 0
fi
exit 1
EOF
got="$(_review_launch "$git_dir")"
[[ "$got" == tuicr*" -w"* ]] \
  || fail "own PR should keep local watch, got $got"
[[ "$got" != *"tuicr pr "* ]] \
  || fail "own PR must not use tuicr pr (no diff watch), got $got"
printf 'PASS: own PR keeps local tuicr -w watch\n'

export AGENTIC_REVIEW_SCOPE=worktree
got="$(_review_launch "$git_dir")"
unset AGENTIC_REVIEW_SCOPE
[[ "$got" == "tuicr -w --no-update-check" ]] \
  || fail "worktree scope should launch tuicr -w only, got $got"
printf 'PASS: AGENTIC_REVIEW_SCOPE=worktree launches tuicr -w\n'
