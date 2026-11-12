#!/usr/bin/env bats
# deploy_herdr_app installs bercail's layout, mods and keys into the Herdr app's
# home, keeps what the person and the app changed, and doctor and uninstall follow.

# shellcheck disable=SC2034 # YES, DRY_RUN and friends are read by the sourced libs.

setup() {
  load test_helper
  isolate
  mkdir -p "$XDG_CONFIG_HOME" "$BATS_TEST_TMPDIR/bin"
  # A fake herdr-app: check passes unless $BATS_TEST_TMPDIR/check-fails exists.
  cat >"$BATS_TEST_TMPDIR/bin/herdr-app" <<EOF
#!/bin/sh
[ "\$1" = check ] && [ -f "$BATS_TEST_TMPDIR/check-fails" ] && exit 1
exit 0
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/herdr-app"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"

  # shellcheck source=/dev/null
  source "$ROOT/lib/common.sh"
  # shellcheck source=/dev/null
  source "$ROOT/lib/detect.sh"
  # shellcheck source=/dev/null
  source "$ROOT/lib/config.sh"
  # shellcheck source=/dev/null
  source "$ROOT/lib/skills.sh"
  # shellcheck source=/dev/null
  source "$ROOT/lib/doctor.sh"
  # shellcheck source=/dev/null
  source "$ROOT/lib/shell-rc.sh"
  # shellcheck source=/dev/null
  source "$ROOT/lib/uninstall.sh"

  export INSTALL_SRC="$ROOT"
  YES=1
  DRY_RUN=0
  APP="$HERDR_APP_CONFIG_DIR"
  [[ "$APP" == "$HOME/.config/herdr-app" ]] || fail "app home: $APP"
  K="$BATS_TEST_TMPDIR/k"
}

section() { jq -c '.["layout:bercail"]' "$APP/keys.json"; }

# Fresh install over a keys.json the person already has.
fresh_install() {
  mkdir -p "$APP"
  printf '{"global":{"ctrl-shift-t":"tab.new"},"layout:bercail":{"x":"y"}}\n' >"$APP/keys.json"
  deploy_herdr_app >/dev/null
}

# An install from before bercail recorded its keys (0.9.x), with the person's
# own changes in the section, updated. Sets out.
legacy_keys_update() {
  fresh_install
  rm -f "$AGENTIC_DEV_SHARE_DIR/herdr-app/keys.json"
  jq --argjson legacy "$HERDR_APP_KEYS_LEGACY" '.["layout:bercail"] = ($legacy
      + {"ctrl-alt-down": "pane.go:down", "ctrl-shift-x": "mine.cmd"} | del(.["ctrl-shift-s"]))' \
    "$APP/keys.json" >"$K" && mv "$K" "$APP/keys.json"
  out="$(deploy_herdr_app 2>&1)"
}

# Then bercail changes two shipped keys; the person kept one and changed the other.
recorded_keys_update() {
  legacy_keys_update
  jq '.["layout:bercail"]["ctrl-shift-r"] = "old.review" | .["layout:bercail"]["ctrl-shift-f"] = "old.files"' \
    "$ROOT/bercail/keys.json" >"$AGENTIC_DEV_SHARE_DIR/herdr-app/keys.json"
  jq '.["layout:bercail"]["ctrl-shift-r"] = "old.review" | .["layout:bercail"]["ctrl-shift-f"] = "my.files"' \
    "$APP/keys.json" >"$K" && mv "$K" "$APP/keys.json"
  deploy_herdr_app >/dev/null 2>&1
}

# The app rewrote its layout and someone edited the mod, then an update ran.
app_edits_then_update() {
  fresh_install
  jq '.background = "chrome"' "$APP/layouts/bercail.json" >"$BATS_TEST_TMPDIR/l" \
    && mv "$BATS_TEST_TMPDIR/l" "$APP/layouts/bercail.json"
  printf 'local edit\n' >>"$APP/mods/bercail-desk/main.js"
  deploy_herdr_app >/dev/null
}

@test "deploy installs the layout and mod and merges only layout:bercail keys" {
  fresh_install
  cmp -s "$ROOT/bercail/layouts/bercail.json" "$APP/layouts/bercail.json" || fail "layout not installed"
  cmp -s "$ROOT/bercail/mods/bercail-desk/main.js" "$APP/mods/bercail-desk/main.js" || fail "mod not installed"
  cmp -s "$ROOT/bercail/mods/bercail-agents/main.js" "$APP/mods/bercail-agents/main.js" || fail "agents mod not installed"
  cmp -s "$ROOT/bercail/mods/bercail-review/main.js" "$APP/mods/bercail-review/main.js" || fail "review mod not installed"
  cmp -s "$ROOT/bercail/mods/bercail-shep/main.js" "$APP/mods/bercail-shep/main.js" || fail "Shep mod not installed"
  cmp -s "$ROOT/bercail/mods/bercail-spaces/main.js" "$APP/mods/bercail-spaces/main.js" || fail "spaces mod not installed"
  jq -e '.global["ctrl-shift-t"] == "tab.new"' "$APP/keys.json" >/dev/null || fail "the person's keys must stay"
  jq -e --slurpfile ours "$ROOT/bercail/keys.json" '.["layout:bercail"] == ($ours[0]["layout:bercail"] + {"x":"y"})' \
    "$APP/keys.json" >/dev/null || fail "layout:bercail must get bercail's keys and keep the person's: $(cat "$APP/keys.json")"
}

@test "update moves 0.9.x keys to the new ones and keeps the person's changes" {
  legacy_keys_update
  jq -e '.["layout:bercail"] | .["alt-up"] == "bercail-desk.space-prev" and .["alt-shift-down"] == "bercail-desk.agent-next"
      and .["ctrl-alt-up"] == "bercail-desk.subspace-prev"' "$APP/keys.json" >/dev/null || fail "new keys not added: $(section)"
  jq -e '.["layout:bercail"] | .["ctrl-alt-down"] == "pane.go:down" and .["ctrl-shift-x"] == "mine.cmd"
      and (has("ctrl-shift-s") | not)' "$APP/keys.json" >/dev/null || fail "the person's key changes must stay: $(section)"
  jq -e '[.["layout:bercail"][] | select(. == "bercail-desk.go-up" or . == "bercail-desk.go-down")] == []' "$APP/keys.json" >/dev/null \
    || fail "keys bercail dropped must go: $(section)"
  printf '%s' "$out" | grep -q 'key ctrl-alt-down: yours is pane.go:down' || fail "update should warn about the kept key: $out"
  cmp -s "$ROOT/bercail/keys.json" "$AGENTIC_DEV_SHARE_DIR/herdr-app/keys.json" || fail "update records the shipped keys"
}

@test "update follows bercail's key changes only where the person kept bercail's" {
  local before
  recorded_keys_update
  jq -e '.["layout:bercail"] | .["ctrl-shift-r"] == "bercail-desk.review" and .["ctrl-shift-f"] == "my.files"' \
    "$APP/keys.json" >/dev/null || fail "recorded keys merge: $(section)"
  before="$(cat "$APP/keys.json")"
  deploy_herdr_app >/dev/null 2>&1
  [[ "$(cat "$APP/keys.json")" == "$before" ]] || fail "a second update must not change keys.json"
}

@test "doctor reports key conflicts" {
  recorded_keys_update
  deploy_herdr_app >/dev/null 2>&1
  jq '.terminal = {"alt-shift-up": "send:x"}' "$APP/keys.json" >"$K" && mv "$K" "$APP/keys.json"
  out="$(doctor_herdr_app 2>&1)"
  printf '%s' "$out" | grep -q 'conflict  Herdr key ctrl-shift-f: yours is my.files' || fail "doctor: own key: $out"
  printf '%s' "$out" | grep -q 'conflict  Herdr key alt-shift-up: the terminal section binds it' || fail "doctor: terminal key: $out"
  printf '%s' "$out" | grep -q 'conflict  Herdr key ctrl-shift-s: not in layout:bercail' || fail "doctor: missing key: $out"
  jq 'del(.terminal) | .["layout:bercail"] = $ours[0]["layout:bercail"]' --slurpfile ours "$ROOT/bercail/keys.json" \
    "$APP/keys.json" >"$K" && mv "$K" "$APP/keys.json"
  out="$(doctor_herdr_app 2>&1)"
  if printf '%s' "$out" | grep -q conflict; then
    fail "doctor: no conflicts expected: $out"
  fi
}

@test "update keeps the app's layout edits and restores the mod" {
  app_edits_then_update
  jq -e '.background == "chrome"' "$APP/layouts/bercail.json" >/dev/null || fail "an unchanged shipped layout must not replace the app's"
  cmp -s "$ROOT/bercail/mods/bercail-desk/main.js" "$APP/mods/bercail-desk/main.js" || fail "the mod is bercail's: update restores it"
}

@test "a new shipped layout replaces the installed one" {
  app_edits_then_update
  jq '.background = "old"' "$ROOT/bercail/layouts/bercail.json" >"$AGENTIC_DEV_SHARE_DIR/herdr-app/layouts/bercail.json"
  deploy_herdr_app >/dev/null
  cmp -s "$ROOT/bercail/layouts/bercail.json" "$APP/layouts/bercail.json" || fail "a new shipped layout must be installed"
}

# ...and keeps the live desks' blocks, the shown one still shown: a running desk mod
# doesn't add a block it added before. The 0.9.x layout had no panel column.
@test "a new shipped layout keeps the live desk blocks" {
  fresh_install
  jq 'walk(if type == "object" and .id == "panel" then .children[0] + {size: {px: 240}} else . end)' \
    "$ROOT/bercail/layouts/bercail.json" >"$AGENTIC_DEV_SHARE_DIR/herdr-app/layouts/bercail.json"
  jq '(.. | objects | select(.id == "agent-stack")) |= (.children += [
        {id: "desk-t2x", type: "block", content: {terminal: "t2x"}, padding: [6, 6]},
        {id: "desk-t5p", type: "block", content: {terminal: "t5p"}, padding: [6, 6]}] | .active = "desk-t5p")' \
    "$AGENTIC_DEV_SHARE_DIR/herdr-app/layouts/bercail.json" >"$APP/layouts/bercail.json"
  deploy_herdr_app >/dev/null
  jq -e '[.. | objects | select(.id == "agent-stack")][0] | [.children[].id] == ["empty", "desk-t2x", "desk-t5p"]
      and .active == "desk-t5p" and .children[2].content.terminal == "t5p"' "$APP/layouts/bercail.json" >/dev/null \
    || fail "the desk blocks must come back: $(jq -c '.. | objects | select(.id == "agent-stack")' "$APP/layouts/bercail.json")"
  jq -e '.. | objects | select(.id == "panel") | any(.children[]; .id == "panel-body")' "$APP/layouts/bercail.json" >/dev/null \
    || fail "the new layout's panel column must be installed"
  [[ "$(_herdr_app_layout_shape "$APP/layouts/bercail.json")" == "$(_herdr_app_layout_shape "$ROOT/bercail/layouts/bercail.json")" ]] \
    || fail "only the desk blocks may differ from the shipped layout"
  cmp -s "$ROOT/bercail/layouts/bercail.json" "$AGENTIC_DEV_SHARE_DIR/herdr-app/layouts/bercail.json" \
    || fail "the record is the shipped layout, without the desks"
  deploy_herdr_app >/dev/null
  jq -e '.. | objects | select(.id == "desk-t5p")' "$APP/layouts/bercail.json" >/dev/null || fail "a second update must keep the desks"
}

@test "bercail's layout with only runtime changes is adopted" {
  fresh_install
  # bercail's layout as the app left it (desk and Shep blocks added, the space view
  # shown, columns resized) is adopted.
  rm -f "$AGENTIC_DEV_SHARE_DIR/herdr-app/layouts/bercail.json"
  jq '(.. | objects | select(.id == "agent-stack")) |= (.children += [{id: "desk-t9z", type: "block", content: {terminal: "t9z"}}] | .active = "desk-t9z")
    | (.. | objects | select(.id == "shep-stack")) |= (.children += [{id: "shep-t3", type: "block", content: {terminal: "t3"}}] | .active = "shep-t3")
    | (.. | objects | select(.id == "shep") | .hidden) = true | (.. | objects | select(.id == "work") | .hidden) = false
    | (.. | objects | select(.id == "desk") | .size.weight) = 4.2' \
    "$ROOT/bercail/layouts/bercail.json" >"$APP/layouts/bercail.json"
  out="$(deploy_herdr_app)"
  printf '%s' "$out" | grep -q 'unchanged: .*bercail.json' || fail "a runtime-only change should count as bercail's: $out"
  jq -e '.. | objects | select(.id == "desk-t9z") | .content.terminal == "t9z"' "$APP/layouts/bercail.json" >/dev/null \
    || fail "adopting must keep the app's values"
  [[ -f "$AGENTIC_DEV_SHARE_DIR/herdr-app/layouts/bercail.json" ]] || fail "adopting records the shipped layout"
}

@test "an existing unowned layout is kept unless --force" {
  fresh_install
  rm -f "$AGENTIC_DEV_SHARE_DIR/herdr-app/layouts/bercail.json"
  printf '{"id":"mine"}\n' >"$APP/layouts/bercail.json"
  deploy_herdr_app >/dev/null
  jq -e '.id == "mine"' "$APP/layouts/bercail.json" >/dev/null || fail "an unowned bercail layout must be kept"
  FORCE=1 deploy_herdr_app >/dev/null
  cmp -s "$ROOT/bercail/layouts/bercail.json" "$APP/layouts/bercail.json" || fail "--force replaces it"
}

@test "doctor checks the layout, mod and keys" {
  fresh_install
  out="$(doctor_herdr_app)" || fail "doctor should pass: $out"
  printf 'stale\n' >>"$APP/mods/bercail-desk/main.js"
  record_install_source >/dev/null
  if out="$(doctor_herdr_app)"; then
    fail "doctor should flag a stale mod: $out"
  fi
  printf '%s' "$out" | grep -q 'stale  Herdr mod file' || fail "stale mod message: $out"
  deploy_herdr_app >/dev/null
  jq 'del(.["layout:bercail"])' "$APP/keys.json" >"$K" && mv "$K" "$APP/keys.json"
  if out="$(doctor_herdr_app)"; then
    fail "doctor should flag missing keys: $out"
  fi
  printf '%s' "$out" | grep -q 'missing  Herdr keys' || fail "missing keys message: $out"
}

@test "a missing keys.json gets only the layout:bercail section" {
  fresh_install
  rm -f "$APP/keys.json"
  deploy_herdr_app >/dev/null
  jq -e 'keys == ["layout:bercail"]' "$APP/keys.json" >/dev/null || fail "new keys.json: $(cat "$APP/keys.json")"
}

@test "no Herdr app skips the step" {
  fresh_install
  rm -rf "$APP"
  PATH="/usr/bin:/bin" deploy_herdr_app >/dev/null 2>&1 || fail "a missing app must not fail the install"
  [[ ! -e "$APP" ]] || fail "nothing is written without the app"
}

@test "uninstall removes the layout, mod and layout:bercail keys only" {
  fresh_install
  rm -rf "$APP"
  deploy_herdr_app >/dev/null
  jq '.global = {"ctrl-shift-t":"tab.new"}' "$APP/keys.json" >"$K" && mv "$K" "$APP/keys.json"
  uninstall_agentic_dev >/dev/null 2>&1
  [[ ! -e "$APP/layouts/bercail.json" && ! -e "$APP/mods/bercail-desk" && ! -e "$APP/mods/bercail-agents" && ! -e "$APP/mods/bercail-review"
    && ! -e "$APP/mods/bercail-shep" && ! -e "$APP/mods/bercail-spaces" ]] \
    || fail "uninstall leaves layout or mods"
  jq -e 'has("layout:bercail") | not' "$APP/keys.json" >/dev/null || fail "uninstall leaves layout:bercail keys"
  jq -e '.global["ctrl-shift-t"] == "tab.new"' "$APP/keys.json" >/dev/null || fail "uninstall must keep the person's keys"
}
