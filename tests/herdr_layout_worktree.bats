#!/usr/bin/env bats
# config/worktrunk/herdr-layout.sh against a fake Herdr app and a fake hc:
# spaces for checkouts, and the desk agent started under each space's Shell.

setup() {
  load test_helper
  isolate
  FAKE_BIN="$BATS_TEST_TMPDIR/bin"
  CALL_LOG="$BATS_TEST_TMPDIR/calls.log"
  mkdir -p "$FAKE_BIN" "$BATS_TEST_TMPDIR/main" "$BATS_TEST_TMPDIR/main.feature"
  unset WT_HERDR_AGENT_PROMPT WT_HERDR_KEEP_FOCUS WT_HERDR_NO_DESK
  export HERDR_APP_BIN="$FAKE_BIN/herdr-app"
  export HC_BIN="$FAKE_BIN/hc"
  mkdir -p "$XDG_CONFIG_HOME/bercail"
  export CALL_LOG FAKE_STATE="$BATS_TEST_TMPDIR/state"
  mkdir -p "$FAKE_STATE"
  printf '[layout]\nreview = "tuicr"\n' >"$XDG_CONFIG_HOME/bercail/config.toml"

  FEATURE="$(cd "$BATS_TEST_TMPDIR/main.feature" && pwd -P)"
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

  # shellcheck source=/dev/null
  source "$ROOT/config/worktrunk/herdr-layout.sh"
}

# The checkout's space (sp-child) is open. The log is cleared so the call under
# test is what remains. A desk may already have started; the fake does not
# record it unless $FAKE_STATE/desk exists.
open_space() {
  wt_herdr_layout_create "Main_Feature" "$BATS_TEST_TMPDIR/main.feature"
  : >"$CALL_LOG"
}

@test "linked path main.feature labels Feature_Main" {
  local got
  got="$(_wt_generate_session_name "$BATS_TEST_TMPDIR/main.feature")"
  [[ "$got" == "Feature_Main" ]] || fail "session name: expected Feature_Main got $got"
}

@test "layout create opens a space for the checkout, keeps the shown space, and starts a desk with no config" {
  : >"$CALL_LOG"
  rm -f "$XDG_CONFIG_HOME/bercail/config.toml"
  wt_herdr_layout_create "Main_Feature" "$BATS_TEST_TMPDIR/main.feature"
  grep -qF "herdr-app do space.new --name Main_Feature --folder $FEATURE --tab Shell" "$CALL_LOG" \
    || fail "expected space.new on the checkout; log=$(cat "$CALL_LOG")"
  [[ "$(cat "$FAKE_STATE/shown")" == sp-parent ]] || fail "create must keep the user's space shown"
  grep -qx "$RUN" "$CALL_LOG" || fail "post-start starts the desk with no config; log=$(cat "$CALL_LOG")"
}

@test "layout create reuses the space open on that folder" {
  open_space
  wt_herdr_layout_create "Main_Feature" "$BATS_TEST_TMPDIR/main.feature"
  if grep -q 'space.new' "$CALL_LOG"; then
    fail "an open space must be reused; log=$(cat "$CALL_LOG")"
  fi
}

@test "post-start starts a desk even when enabled is false, leaves a live desk, and skips when handoff asks not to" {
  open_space
  printf '[bstack]\nenabled = false\n' >"$XDG_CONFIG_HOME/bercail/config.toml"
  wt_herdr_layout_create "Main_Feature" "$BATS_TEST_TMPDIR/main.feature"
  grep -qx "$RUN" "$CALL_LOG" || fail "enabled = false does not stop the desk; log=$(cat "$CALL_LOG")"
  [[ "$(cat "$FAKE_STATE/shown")" == sp-parent ]] || fail "the auto-started desk must keep the user's space shown"
  touch "$FAKE_STATE/desk"
  : >"$CALL_LOG"
  wt_herdr_layout_create "Main_Feature" "$BATS_TEST_TMPDIR/main.feature"
  if grep -q '^hc \(run\|kill\)' "$CALL_LOG"; then
    fail "post-start must leave a live desk alone; log=$(cat "$CALL_LOG")"
  fi
  rm -f "$FAKE_STATE/desk"
  : >"$CALL_LOG"
  WT_HERDR_NO_DESK=1 wt_herdr_layout_create "Main_Feature" "$BATS_TEST_TMPDIR/main.feature"
  if grep -q '^hc run' "$CALL_LOG"; then
    fail "WT_HERDR_NO_DESK (handoff) must skip the desk; log=$(cat "$CALL_LOG")"
  fi
}

@test "handoff starts the desk agent under the Shell, no tab of its own, with its prompt (real TERM)" {
  open_space
  TERM=dumb WT_HERDR_AGENT_PROMPT=bercail-0s1 \
    wt_herdr_handoff_agent "Main_Feature" "$BATS_TEST_TMPDIR/main.feature"
  grep -qx "$RUN --prompt bercail-0s1" "$CALL_LOG" \
    || fail "handoff should start the desk under the space's Shell with no command after it; log=$(cat "$CALL_LOG")"
  grep -qx 'TERM=xterm-256color' "$CALL_LOG" || fail "a headless caller's TERM=dumb must not reach the desk; log=$(cat "$CALL_LOG")"
}

@test "handoff replaces a live desk agent" {
  open_space
  touch "$FAKE_STATE/desk"
  WT_HERDR_AGENT_PROMPT=bercail-0s2 \
    wt_herdr_handoff_agent "Main_Feature" "$BATS_TEST_TMPDIR/main.feature"
  grep -q '^hc kill t5' "$CALL_LOG" || fail "handoff should replace the live desk; log=$(cat "$CALL_LOG")"
  grep -qx "$RUN --prompt bercail-0s2" "$CALL_LOG" || fail "replacement desk; log=$(cat "$CALL_LOG")"
}

@test "handoff requires a prompt" {
  open_space
  if wt_herdr_handoff_agent "Main_Feature" "$BATS_TEST_TMPDIR/main.feature" 2>/dev/null; then
    fail "handoff without WT_HERDR_AGENT_PROMPT must fail"
  fi
}

@test "default agent is bercail-desk-agent with no prompt; issue labels only when set" {
  open_space
  WT_HERDR_AGENT_PROMPT='Your job is beads issue bercail-0s1: Fix login.' \
    WT_HERDR_ISSUE=bercail-0s1 WT_HERDR_ISSUE_TITLE='Fix login' \
    wt_herdr_handoff_agent "Main_Feature" "$BATS_TEST_TMPDIR/main.feature"
  grep -q -- '--label bercail.issue=bercail-0s1' "$CALL_LOG" || fail "issue label missing: $(cat "$CALL_LOG")"
  grep -q -- '--label bercail.issue_title=Fix login' "$CALL_LOG" || fail "title label missing: $(cat "$CALL_LOG")"
  : >"$CALL_LOG"
  WT_HERDR_AGENT_PROMPT=x \
    wt_herdr_handoff_agent "Main_Feature" "$BATS_TEST_TMPDIR/main.feature"
  if grep -q 'bercail.issue' "$CALL_LOG"; then
    fail "no issue env, no issue label: $(cat "$CALL_LOG")"
  fi
  : >"$CALL_LOG"
  WT_HERDR_AGENT_PROMPT=ignored wt_herdr_start_default_agent "Main_Feature" "$BATS_TEST_TMPDIR/main.feature"
  grep -qx "$RUN" "$CALL_LOG" \
    || fail "default agent is bercail-desk-agent's pick, without a prompt; log=$(cat "$CALL_LOG")"
  : >"$CALL_LOG"
  WT_HERDR_ISSUE=bercail-0s1 WT_HERDR_ISSUE_TITLE='Fix login' WT_HERDR_AGENT_PROMPT=ignored \
    wt_herdr_start_default_agent "Main_Feature" "$BATS_TEST_TMPDIR/main.feature"
  if grep -q 'bercail.issue' "$CALL_LOG"; then
    fail "default agent must not inherit issue labels: $(cat "$CALL_LOG")"
  fi
  grep -qx "$RUN" "$CALL_LOG" || fail "default agent argv unchanged: $(cat "$CALL_LOG")"
}

@test "a handoff --model reaches the desk agent and its label; a default start drops it" {
  local model=claude-bridge/fable:high
  open_space
  WT_HERDR_AGENT_PROMPT=bercail-0s1 WT_HERDR_MODEL="$model" \
    wt_herdr_handoff_agent "Main_Feature" "$BATS_TEST_TMPDIR/main.feature"
  grep -qx "hc run --bg --keep --outlive-parent --no-notify --parent t9 --cwd $FEATURE --label bercail.role=agent --label bercail.space=sp-child --label bercail.model=$model $DESK --prompt bercail-0s1 --model $model" "$CALL_LOG" \
    || fail "the desk runs bercail-desk-agent --model, labelled with it; log=$(cat "$CALL_LOG")"
  : >"$CALL_LOG"
  WT_HERDR_MODEL="$model" wt_herdr_start_default_agent "Main_Feature" "$BATS_TEST_TMPDIR/main.feature"
  grep -qx "$RUN" "$CALL_LOG" || fail "a default start runs the lead's model; log=$(cat "$CALL_LOG")"
}

@test "a space with no Shell terminal gets no desk" {
  open_space
  cp "$FAKE_STATE/spaces.json" "$FAKE_STATE/spaces.bak"
  jq 'map(if .id == "sp-child" then .tabs = [] else . end)' "$FAKE_STATE/spaces.bak" >"$FAKE_STATE/spaces.json"
  if wt_herdr_start_default_agent "Main_Feature" "$BATS_TEST_TMPDIR/main.feature" 2>/dev/null; then
    fail "a space with no Shell terminal must not get a desk"
  fi
  if grep -q '^hc run' "$CALL_LOG"; then
    fail "no Shell, no hc run; log=$(cat "$CALL_LOG")"
  fi
}

@test "layout close closes only the named space" {
  open_space
  wt_herdr_layout_close "Main_Feature"
  grep -qF 'herdr-app do space.close --id sp-child --confirmed true' "$CALL_LOG" \
    || fail "close should close the space by name; log=$(cat "$CALL_LOG")"
  : >"$CALL_LOG"
  wt_herdr_layout_close "Nope_Main"
  if grep -q 'space.close' "$CALL_LOG"; then
    fail "close must ignore unknown names"
  fi
}

@test "layout close finds the space by worktree path after the checkout's branch changed" {
  # post-remove expands S from the new branch, so only the path still finds it.
  local wt="$BATS_TEST_TMPDIR/main.renamed" dir id
  git init -q -b branch-a "$wt"
  dir="$(cd "$wt" && pwd -P)"
  wt_herdr_layout_create "Branch-a_Main" "$wt"
  id="$(jq -r --arg f "$dir" '.[] | select(.folder == $f) | .id' "$FAKE_STATE/spaces.json")"
  [[ -n "$id" ]] || fail "expected a space on $dir; spaces=$(cat "$FAKE_STATE/spaces.json")"
  git -C "$wt" checkout -q -b branch-b
  rm -rf "$wt"
  : >"$CALL_LOG"
  wt_herdr_layout_close "Branch-b_Main" "$wt"
  grep -qxF "herdr-app do space.close --id $id --confirmed true" "$CALL_LOG" \
    || fail "close should find the space by the removed worktree's path; log=$(cat "$CALL_LOG")"
  [[ "$(cat "$FAKE_STATE/shown")" == sp-parent ]] || fail "close must keep the user's space shown"
}

@test "a closed app skips the space on post-start and fails a handoff" {
  touch "$FAKE_STATE/down"
  wt_herdr_layout_create "Main_Feature" "$BATS_TEST_TMPDIR/main.feature" 2>/dev/null \
    || fail "post-start must not fail wt when the app is closed"
  if WT_HERDR_AGENT_PROMPT=x wt_herdr_handoff_agent "Main_Feature" "$BATS_TEST_TMPDIR/main.feature" 2>/dev/null; then
    fail "handoff must fail when the app is closed"
  fi
}
