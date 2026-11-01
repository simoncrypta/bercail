#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

FAKE_BIN="$TMP_DIR/bin"
CALL_LOG="$TMP_DIR/calls.log"
mkdir -p "$FAKE_BIN" "$TMP_DIR/main" "$TMP_DIR/main.feature"
unset HC_TERMINAL_ID WT_HERDR_AGENT_CMD WT_HERDR_AGENT_PROMPT WT_HERDR_KEEP_FOCUS WT_HERDR_NO_DESK BERCAIL_DESK_AGENT
export HERDR_APP_BIN="$FAKE_BIN/herdr-app"
export HC_BIN="$FAKE_BIN/hc"
export HOME="$TMP_DIR/home"
export XDG_CONFIG_HOME="$TMP_DIR/xdg-config"
mkdir -p "$HOME" "$XDG_CONFIG_HOME/bercail"
export CALL_LOG FAKE_STATE="$TMP_DIR/state"
mkdir -p "$FAKE_STATE"
printf '[agent]\ncommand = "claude"\n' >"$XDG_CONFIG_HOME/bercail/config.toml"

MAIN="$(cd "$TMP_DIR/main" && pwd -P)"
FEATURE="$(cd "$TMP_DIR/main.feature" && pwd -P)"
export FEATURE
DESK="$HOME/.local/bin/bercail-desk-agent"
# How every desk starts: a sub-agent of sp-child's Shell (t9), no tab of its own
# (no herdr.space), found again by the bercail labels.
RUN="hc run --bg --keep --outlive-parent --no-notify --parent t9 --cwd $FEATURE --label bercail.role=agent --label bercail.space=sp-child $DESK"

# A fake Herdr app: spaces live in $FAKE_STATE/spaces.json, the shown one in $FAKE_STATE/shown.
cat >"$FAKE_BIN/herdr-app" <<'EOF'
#!/usr/bin/env bash
printf 'herdr-app %s\n' "$*" >>"$CALL_LOG"
[[ -f "$FAKE_STATE/down" ]] && exit 1
spaces="$FAKE_STATE/spaces.json"
[[ -f "$spaces" ]] || printf '[{"id":"sp-parent","name":"Main","folder":"/main","tabs":[{"terminals":[{"terminal":"t1"}]}]}]' >"$spaces"
[[ -f "$FAKE_STATE/shown" ]] || printf 'sp-parent' >"$FAKE_STATE/shown"
case "$1 ${2:-}" in
  "status ") printf '{"space":"%s"}\n' "$(cat "$FAKE_STATE/shown")" ;;
  "ls ") jq '{spaces: .}' "$spaces" ;;
  "do space.new")
    name="$4"; folder="$6"
    jq --arg n "$name" --arg f "$folder" \
      '. + [{id:"sp-child",name:$n,folder:$f,tabs:[{terminals:[{terminal:"t9"}]}]}]' "$spaces" >"$spaces.tmp"
    mv "$spaces.tmp" "$spaces"
    printf 'sp-child' >"$FAKE_STATE/shown"
    printf '{"space":"sp-child","tab":"tb1","terminal":"t9"}\n' ;;
  "do space.select") printf '%s' "$4" >"$FAKE_STATE/shown"; echo '{"ok":true}' ;;
  "do space.close")
    jq --arg id "$4" 'map(select(.id != $id))' "$spaces" >"$spaces.tmp"
    mv "$spaces.tmp" "$spaces"; echo '{"ok":true}' ;;
  *) echo '{"ok":true}' ;;
esac
EOF
chmod +x "$FAKE_BIN/herdr-app"

# A fake hc: one live desk (t5) in sp-child when $FAKE_STATE/desk exists.
cat >"$FAKE_BIN/hc" <<'EOF'
#!/usr/bin/env bash
printf 'hc %s\n' "$*" >>"$CALL_LOG"
[[ "$1" != run ]] || printf 'TERM=%s\n' "$TERM" >>"$CALL_LOG"
case "$1" in
  ls)
    if [[ -f "$FAKE_STATE/desk" ]]; then
      echo '{"terminals":[{"address":"t9","state":"live"},{"address":"t5","state":"live"}]}'
    else
      echo '{"terminals":[{"address":"t9","state":"live"}]}'
    fi ;;
  get)
    if [[ "$2" == t5 ]]; then
      echo '{"address":"t5","labels":{"bercail.role":"agent","bercail.space":"sp-child"}}'
    else
      echo '{"address":"'"$2"'","labels":{}}'
    fi ;;
  *) echo '{}' ;;
esac
EOF
chmod +x "$FAKE_BIN/hc"

# shellcheck source=config/worktrunk/herdr-layout.sh
source "$ROOT/config/worktrunk/herdr-layout.sh"

got="$(_wt_generate_session_name "$TMP_DIR/main.feature")"
[[ "$got" == "Feature_Main" ]] || fail "session name: expected Feature_Main got $got"
printf 'PASS: linked path main.feature labels Feature_Main\n'

: >"$CALL_LOG"
wt_herdr_layout_create "Main_Feature" "$TMP_DIR/main.feature"
grep -qF "herdr-app do space.new --name Main_Feature --folder $FEATURE --tab Shell" "$CALL_LOG" \
  || fail "expected space.new on the checkout; log=$(cat "$CALL_LOG")"
[[ "$(cat "$FAKE_STATE/shown")" == sp-parent ]] || fail "create must keep the user's space shown"
grep -q '^hc run' "$CALL_LOG" && fail "post-start create must not start an agent with bstack off"
printf 'PASS: layout create opens a space for the checkout and keeps the shown space\n'

: >"$CALL_LOG"
wt_herdr_layout_create "Main_Feature" "$TMP_DIR/main.feature"
grep -q 'space.new' "$CALL_LOG" && fail "an open space must be reused; log=$(cat "$CALL_LOG")"
printf 'PASS: layout create reuses the space open on that folder\n'

printf '[agent]\ncommand = "claude"\n[bstack]\nenabled = true\n' >"$XDG_CONFIG_HOME/bercail/config.toml"
: >"$CALL_LOG"
wt_herdr_layout_create "Main_Feature" "$TMP_DIR/main.feature"
grep -qx "$RUN" "$CALL_LOG" || fail "with bstack on, post-start starts the desk; log=$(cat "$CALL_LOG")"
[[ "$(cat "$FAKE_STATE/shown")" == sp-parent ]] || fail "the auto-started desk must keep the user's space shown"
touch "$FAKE_STATE/desk"
: >"$CALL_LOG"
wt_herdr_layout_create "Main_Feature" "$TMP_DIR/main.feature"
grep -q '^hc \(run\|kill\)' "$CALL_LOG" && fail "post-start must leave a live desk alone; log=$(cat "$CALL_LOG")"
rm -f "$FAKE_STATE/desk"
: >"$CALL_LOG"
WT_HERDR_NO_DESK=1 wt_herdr_layout_create "Main_Feature" "$TMP_DIR/main.feature"
grep -q '^hc run' "$CALL_LOG" && fail "WT_HERDR_NO_DESK (handoff) must skip the desk; log=$(cat "$CALL_LOG")"
printf '[agent]\ncommand = "claude"\n' >"$XDG_CONFIG_HOME/bercail/config.toml"
printf 'PASS: with bstack on, post-start starts a desk in a space without one, unless handoff asks not to\n'

: >"$CALL_LOG"
TERM=dumb WT_HERDR_AGENT_CMD=codex WT_HERDR_AGENT_PROMPT=bercail-0s1 \
  wt_herdr_handoff_agent "Main_Feature" "$TMP_DIR/main.feature"
grep -qx "$RUN --prompt bercail-0s1 codex" "$CALL_LOG" \
  || fail "handoff should start the desk under the space's Shell with the stage's binary; log=$(cat "$CALL_LOG")"
grep -qx 'TERM=xterm-256color' "$CALL_LOG" || fail "a headless caller's TERM=dumb must not reach the desk; log=$(cat "$CALL_LOG")"
printf 'PASS: handoff starts the desk agent under the Shell, no tab of its own, with its prompt (real TERM)\n'

touch "$FAKE_STATE/desk"
: >"$CALL_LOG"
WT_HERDR_AGENT_CMD=claude WT_HERDR_AGENT_PROMPT=bercail-0s2 \
  wt_herdr_handoff_agent "Main_Feature" "$TMP_DIR/main.feature"
grep -q '^hc kill t5' "$CALL_LOG" || fail "handoff should replace the live desk; log=$(cat "$CALL_LOG")"
grep -qx "$RUN --prompt bercail-0s2 claude" "$CALL_LOG" || fail "replacement desk; log=$(cat "$CALL_LOG")"
printf 'PASS: handoff replaces a live desk agent\n'

rm -f "$FAKE_STATE/desk"
if WT_HERDR_AGENT_CMD=claude wt_herdr_handoff_agent "Main_Feature" "$TMP_DIR/main.feature" 2>/dev/null; then
  fail "handoff without WT_HERDR_AGENT_PROMPT must fail"
fi
printf 'PASS: handoff requires a prompt\n'

: >"$CALL_LOG"
WT_HERDR_AGENT_PROMPT=ignored wt_herdr_start_default_agent "Main_Feature" "$TMP_DIR/main.feature"
grep -qx "$RUN" "$CALL_LOG" \
  || fail "default agent is bercail-desk-agent's pick, without a prompt; log=$(cat "$CALL_LOG")"
printf 'PASS: default agent is bercail-desk-agent with no prompt\n'

cp "$FAKE_STATE/spaces.json" "$FAKE_STATE/spaces.bak"
jq 'map(if .id == "sp-child" then .tabs = [] else . end)' "$FAKE_STATE/spaces.bak" >"$FAKE_STATE/spaces.json"
: >"$CALL_LOG"
if wt_herdr_start_default_agent "Main_Feature" "$TMP_DIR/main.feature" 2>/dev/null; then
  fail "a space with no Shell terminal must not get a desk"
fi
grep -q '^hc run' "$CALL_LOG" && fail "no Shell, no hc run; log=$(cat "$CALL_LOG")"
mv "$FAKE_STATE/spaces.bak" "$FAKE_STATE/spaces.json"
printf 'PASS: a space with no Shell terminal gets no desk\n'

: >"$CALL_LOG"
wt_herdr_layout_close "Main_Feature"
grep -qF 'herdr-app do space.close --id sp-child --confirmed true' "$CALL_LOG" \
  || fail "close should close the space by name; log=$(cat "$CALL_LOG")"
: >"$CALL_LOG"
wt_herdr_layout_close "Nope_Main"
grep -q 'space.close' "$CALL_LOG" && fail "close must ignore unknown names"
printf 'PASS: layout close closes only the named space\n'

touch "$FAKE_STATE/down"
wt_herdr_layout_create "Main_Feature" "$TMP_DIR/main.feature" 2>/dev/null \
  || fail "post-start must not fail wt when the app is closed"
if WT_HERDR_AGENT_CMD=claude WT_HERDR_AGENT_PROMPT=x wt_herdr_handoff_agent "Main_Feature" "$TMP_DIR/main.feature" 2>/dev/null; then
  fail "handoff must fail when the app is closed"
fi
printf 'PASS: a closed app skips the space on post-start and fails a handoff\n'
