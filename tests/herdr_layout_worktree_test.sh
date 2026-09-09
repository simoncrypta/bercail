#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

FAKE_BIN="$TMP_DIR/bin"
HERDR_CALL_LOG="$TMP_DIR/herdr-calls.log"
mkdir -p "$FAKE_BIN" "$TMP_DIR/main" "$TMP_DIR/main.feature"
unset HERDR_ENV HERDR_PANE_ID
export HERDR_BIN_PATH="$FAKE_BIN/herdr"
export PATH="$FAKE_BIN:$PATH"
export HOME="$TMP_DIR/home"
mkdir -p "$HOME"
export XDG_CONFIG_HOME="$TMP_DIR/xdg-config"
mkdir -p "$XDG_CONFIG_HOME"
export XDG_STATE_HOME="$TMP_DIR/xdg-state"
mkdir -p "$XDG_STATE_HOME"
export HERDR_CALL_LOG
export HERDR_WORKSPACE_ID="w-parent"

PLUGIN_ROOT="$TMP_DIR/plugin"
mkdir -p "$PLUGIN_ROOT"
cat >"$PLUGIN_ROOT/layout.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'plugin %s workspace=%s label=%s no_attach=%s prompt_file=%s agent_cmd=%s\n' \
  "${1:-}" "${HERDR_WORKSPACE_ID:-}" "${WT_HERDR_LABEL:-}" \
  "${WT_HERDR_NO_ATTACH:-}" "${WT_HERDR_AGENT_PROMPT_FILE:+set}" \
  "${WT_HERDR_AGENT_CMD:-}" >>"${HERDR_CALL_LOG}"
EOF
chmod +x "$PLUGIN_ROOT/layout.sh"
export WT_HERDR_PLUGIN_ROOT="$PLUGIN_ROOT"

cat >"$FAKE_BIN/git" <<EOF
#!/usr/bin/env bash
set -euo pipefail
MAIN="$TMP_DIR/main"
LINKED="$TMP_DIR/main.feature"
if [[ "\${1:-}" == "-C" ]]; then
  dir="\$2"
  shift 2
else
  dir="\$PWD"
fi
case "\$*" in
  "worktree list --porcelain")
    printf 'worktree %s\\n' "\$MAIN"
    printf 'HEAD abc\\nbranch refs/heads/master\\n\\n'
    printf 'worktree %s\\n' "\$LINKED"
    printf 'HEAD def\\nbranch refs/heads/feature\\n\\n'
    ;;
  "branch --show-current")
    if [[ "\$dir" == "\$LINKED" ]]; then
      printf 'feature\\n'
    else
      printf 'master\\n'
    fi
    ;;
  *)
    exit 0
    ;;
esac
EOF
chmod +x "$FAKE_BIN/git"

write_fake_herdr() {
  local mode="$1"
  cat >"$FAKE_BIN/herdr" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "\$*" >>"\${HERDR_CALL_LOG}"
mode="$mode"
case "\$*" in
  "status server")
    printf 'status: running\\n'
    ;;
  workspace\\ list*)
    if [[ "\$mode" == "steal-focus" ]]; then
      fid=w-user
      [[ -f "$TMP_DIR/focused-id" ]] && fid="\$(cat "$TMP_DIR/focused-id")"
      if [[ "\$fid" == "w-child" ]]; then
        printf '{"result":{"workspaces":[{"workspace_id":"w-user","label":"user","focused":false},{"workspace_id":"w-child","label":"child","focused":true}]}}\\n'
      else
        printf '{"result":{"workspaces":[{"workspace_id":"w-user","label":"user","focused":true}]}}\\n'
      fi
    elif [[ "\$mode" == "labeled-child" ]]; then
      printf '{"result":{"workspaces":[{"workspace_id":"w-parent","label":"parent","focused":true},{"workspace_id":"w-child","label":"Feature_Main","focused":false}]}}\\n'
    else
      printf '{"result":{"workspaces":[{"workspace_id":"w-parent","label":"parent","focused":true}]}}\\n'
    fi
    ;;
  worktree\\ list*)
    printf '{"result":{"worktrees":[]}}\\n'
    ;;
  worktree\\ open*)
    if [[ "\$mode" == "open-fail" || "\$mode" == "all-fail" ]]; then
      printf '{"error":{"code":"not_git_worktree","message":"Herdr worktree actions require a workspace inside a Git work tree"}}\\n'
      exit 1
    fi
    if [[ "\$mode" == "open-requires-cwd" && "\$*" != *"--cwd "* ]]; then
      printf '{"error":{"code":"not_git_worktree","message":"Herdr worktree actions require a workspace inside a Git work tree"}}\\n'
      exit 1
    fi
    if [[ "\$mode" == "steal-focus" ]]; then
      printf 'w-child\\n' >"$TMP_DIR/focused-id"
    fi
    printf '{"result":{"workspace":{"workspace_id":"w-child"}}}\\n'
    ;;
  worktree\\ create*)
    if [[ "\$mode" == "all-fail" ]]; then
      exit 1
    fi
    printf '{"result":{"workspace":{"workspace_id":"w-created"}}}\\n'
    ;;
  workspace\\ create*)
    printf '{"result":{"workspace":{"workspace_id":"w-flat"}}}\\n'
    ;;
  workspace\\ focus*)
    if [[ "\$mode" == "steal-focus" ]]; then
      printf '%s\\n' "\$3" >"$TMP_DIR/focused-id"
    fi
    printf '{}\\n'
    ;;
  workspace\\ rename*|pane\\ list*)
    printf '{"result":{"panes":[]}}\\n'
    ;;
  *)
    printf '{}\\n'
    ;;
esac
EOF
  chmod +x "$FAKE_BIN/herdr"
}

# shellcheck source=config/worktrunk/herdr-layout.sh
source "$ROOT/config/worktrunk/herdr-layout.sh"
[[ "$HERDR" == "$FAKE_BIN/herdr" ]] || fail "HERDR bound to live binary: $HERDR"

got="$(_wt_generate_session_name "$TMP_DIR/main.feature")"
[[ "$got" == "Feature_Main" ]] || fail "session name: expected Feature_Main got $got"
printf 'PASS: linked path main.feature labels Feature_Main\n'

write_fake_herdr open-ok
: >"$HERDR_CALL_LOG"
wt_herdr_layout_create "Main_Feature" "$TMP_DIR/main.feature" >/dev/null
grep -qE '^worktree open --cwd .*main --path .*main\.feature' "$HERDR_CALL_LOG" \
  || fail "expected herdr worktree open --cwd main --path linked; log=$(cat "$HERDR_CALL_LOG")"
grep -qE '^workspace create ' "$HERDR_CALL_LOG" \
  && fail "should not fall back to workspace create when worktree open succeeds"
grep -qE '^plugin create workspace=w-child label=Main_Feature no_attach=1 prompt_file=' "$HERDR_CALL_LOG" \
  || fail "expected direct plugin create for child workspace; log=$(cat "$HERDR_CALL_LOG")"
grep -q 'plugin action invoke' "$HERDR_CALL_LOG" \
  && fail "create must not use plugin action invoke; log=$(cat "$HERDR_CALL_LOG")"
grep -qE '^workspace focus ' "$HERDR_CALL_LOG" \
  && fail "create must not steal workspace focus; log=$(cat "$HERDR_CALL_LOG")"
grep -qE '^agent prompt ' "$HERDR_CALL_LOG" \
  && fail "helper must not agent prompt; plugin create owns that; log=$(cat "$HERDR_CALL_LOG")"
printf 'PASS: linked worktree uses herdr worktree open without stealing focus\n'

write_fake_herdr steal-focus
printf 'w-user\n' >"$TMP_DIR/focused-id"
: >"$HERDR_CALL_LOG"
wt_herdr_layout_create "Main_Feature" "$TMP_DIR/main.feature" >/dev/null
grep -qE '^workspace focus w-user$' "$HERDR_CALL_LOG" \
  || fail "create must restore the user's workspace if focus moved; log=$(cat "$HERDR_CALL_LOG")"
grep -qE '^workspace focus w-child$' "$HERDR_CALL_LOG" \
  && fail "create must not focus the child; log=$(cat "$HERDR_CALL_LOG")"
grep -qE '^workspace focus w-parent$' "$HERDR_CALL_LOG" \
  && fail "create must not restore the helper pane; log=$(cat "$HERDR_CALL_LOG")"
[[ "$(cat "$TMP_DIR/focused-id")" == "w-user" ]] \
  || fail "user focus should remain w-user; got $(cat "$TMP_DIR/focused-id")"
printf 'PASS: create restores the user workspace, not the helper pane\n'

write_fake_herdr open-requires-cwd
: >"$HERDR_CALL_LOG"
wt_herdr_layout_create "Main_Feature" "$TMP_DIR/main.feature" >/dev/null
grep -qE '^worktree open --cwd .*main --path .*main\.feature' "$HERDR_CALL_LOG" \
  || fail "open from a non-git focused workspace must pass --cwd; log=$(cat "$HERDR_CALL_LOG")"
grep -qE '^plugin create workspace=w-child ' "$HERDR_CALL_LOG" \
  || fail "expected layout create after --cwd open; log=$(cat "$HERDR_CALL_LOG")"
grep -q 'plugin action invoke' "$HERDR_CALL_LOG" \
  && fail "create must not use plugin action invoke; log=$(cat "$HERDR_CALL_LOG")"
printf 'PASS: linked open passes --cwd so it does not depend on focused workspace\n'

write_fake_herdr open-ok
: >"$HERDR_CALL_LOG"
WT_HERDR_AGENT_CMD=cursor-agent
WT_HERDR_AGENT_PROMPT_FILE="$TMP_DIR/prompt.txt"
printf 'task\n' >"$TMP_DIR/prompt.txt"
wt_herdr_handoff_agent "Main_Feature" "$TMP_DIR/main.feature" >/dev/null
grep -qE '^plugin handoff-agent workspace=w-child label=Main_Feature no_attach=1 prompt_file=set agent_cmd=cursor-agent$' "$HERDR_CALL_LOG" \
  || fail "handoff-agent must forward prompt file and agent cmd; log=$(cat "$HERDR_CALL_LOG")"
grep -q 'plugin action invoke' "$HERDR_CALL_LOG" \
  && fail "handoff-agent must not use plugin action invoke; log=$(cat "$HERDR_CALL_LOG")"
grep -qE '^agent prompt ' "$HERDR_CALL_LOG" \
  && fail "helper must not agent prompt; handoff-agent owns launch; log=$(cat "$HERDR_CALL_LOG")"
unset WT_HERDR_AGENT_CMD WT_HERDR_AGENT_PROMPT_FILE
printf 'PASS: handoff-agent forwards prompt file and agent cmd to the plugin\n'

write_fake_herdr open-ok
: >"$HERDR_CALL_LOG"
WT_HERDR_AGENT_CMD=cursor-agent
WT_HERDR_AGENT_PROMPT_FILE="$TMP_DIR/prompt.txt"
wt_herdr_start_default_agent "Main_Feature" "$TMP_DIR/main.feature" >/dev/null
grep -qE '^plugin start-agent workspace=w-child label=Main_Feature no_attach=1 prompt_file= agent_cmd=cursor-agent$' "$HERDR_CALL_LOG" \
  || fail "default start must clear the prompt file; log=$(cat "$HERDR_CALL_LOG")"
unset WT_HERDR_AGENT_CMD WT_HERDR_AGENT_PROMPT_FILE
printf 'PASS: start-default-agent starts a clear agent session\n'

write_fake_herdr open-ok
: >"$HERDR_CALL_LOG"
wt_herdr_layout_create "Main_Master" "$TMP_DIR/main" >/dev/null
grep -qE '^workspace create --cwd .*main ' "$HERDR_CALL_LOG" \
  || fail "main checkout should use workspace create; log=$(cat "$HERDR_CALL_LOG")"
grep -qE '^worktree open ' "$HERDR_CALL_LOG" \
  && fail "main checkout should not use worktree open"
printf 'PASS: main checkout uses workspace create\n'

write_fake_herdr all-fail
: >"$HERDR_CALL_LOG"
if wt_herdr_layout_create "Main_Feature" "$TMP_DIR/main.feature" >/dev/null 2>&1; then
  fail "linked worktree should fail loud when open/create fail"
fi
grep -qE '^workspace create ' "$HERDR_CALL_LOG" \
  && fail "linked failure must not fall through to flat workspace create; log=$(cat "$HERDR_CALL_LOG")"
printf 'PASS: linked worktree fails without flat fallback\n'

write_fake_herdr labeled-child
: >"$HERDR_CALL_LOG"
wt_herdr_layout_close "Feature_Main"
grep -qE '^workspace close w-child$' "$HERDR_CALL_LOG" \
  || fail "worktree close should target the child workspace; log=$(cat "$HERDR_CALL_LOG")"
grep -qE 'workspace close --group' "$HERDR_CALL_LOG" \
  && fail "worktree close must not pass --group; log=$(cat "$HERDR_CALL_LOG")"
printf 'PASS: worktree close targets the child workspace without --group\n'

unset WT_HERDR_PLUGIN_ROOT
mkdir -p "$XDG_CONFIG_HOME/herdr"
printf '%s\n' "[{\"plugin_id\":\"agentic-dev.layout\",\"plugin_root\":\"$PLUGIN_ROOT\"}]" \
  >"$XDG_CONFIG_HOME/herdr/plugins.json"
got="$(_wt_herdr_plugin_root)"
[[ "$got" == "$PLUGIN_ROOT" ]] || fail "plugin root from plugins.json: expected $PLUGIN_ROOT got $got"
printf 'PASS: plugin root resolves from herdr plugins.json\n'

printf '%s\n' "[{\"plugin_id\":\"agentic-dev.layout\",\"source\":{\"managed_path\":\"$PLUGIN_ROOT\"}}]" \
  >"$XDG_CONFIG_HOME/herdr/plugins.json"
got="$(_wt_herdr_plugin_root)"
[[ "$got" == "$PLUGIN_ROOT" ]] || fail "plugin root from managed_path: expected $PLUGIN_ROOT got $got"
printf 'PASS: plugin root resolves from source.managed_path\n'

rm -f "$XDG_CONFIG_HOME/herdr/plugins.json"
write_fake_herdr open-ok
: >"$HERDR_CALL_LOG"
if wt_herdr_layout_create "Main_Feature" "$TMP_DIR/main.feature" >/dev/null 2>&1; then
  fail "create should fail loud when plugin root is missing"
fi
grep -qE '^plugin create ' "$HERDR_CALL_LOG" \
  && fail "missing plugin root must not run create; log=$(cat "$HERDR_CALL_LOG")"
grep -q 'plugin action invoke' "$HERDR_CALL_LOG" \
  && fail "missing plugin root must not fall back to invoke; log=$(cat "$HERDR_CALL_LOG")"
export WT_HERDR_PLUGIN_ROOT="$PLUGIN_ROOT"
printf 'PASS: missing plugin root fails without invoke fallback\n'
