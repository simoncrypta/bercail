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
  # Herdr's Linux keys, whatever the host; the macOS case says Darwin.
  printf '#!/bin/sh\n[ "$1" = -s ] && echo Linux && exit 0\nexec /usr/bin/uname "$@"\n' >"$BATS_TEST_TMPDIR/bin/uname"
  chmod +x "$BATS_TEST_TMPDIR/bin/uname"
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

# The last update shipped two keys bercail has since changed and one it has since
# dropped. The person kept the first, changed the second, removed a key and added
# one. Then an update ran. Sets out.
recorded_keys_update() {
  fresh_install
  jq '.["layout:bercail"] += {"ctrl-shift-r": "old.review", "ctrl-shift-f": "old.files", "ctrl-alt-q": "old.dropped"}' \
    "$ROOT/bercail/keys.json" >"$BERCAIL_SHARE_DIR/herdr-app/keys.json"
  jq '.["layout:bercail"] += {"ctrl-shift-r": "old.review", "ctrl-shift-f": "my.files", "ctrl-alt-q": "old.dropped", "ctrl-shift-x": "mine.cmd"}
      | del(.["layout:bercail"]["ctrl-shift-s"])' "$APP/keys.json" >"$K" && mv "$K" "$APP/keys.json"
  out="$(deploy_herdr_app 2>&1)"
}

# The app rewrote its layout and someone edited the mod, then an update ran.
app_edits_then_update() {
  fresh_install
  jq '.background = "chrome"' "$APP/layouts/bercail.json" >"$BATS_TEST_TMPDIR/l" \
    && mv "$BATS_TEST_TMPDIR/l" "$APP/layouts/bercail.json"
  printf 'local edit\n' >>"$APP/mods/bercail-desk/main.js"
  deploy_herdr_app >/dev/null
}

@test "deploy installs the layout and mod and merges bercail's keys into the person's" {
  fresh_install
  cmp -s "$ROOT/bercail/layouts/bercail.json" "$APP/layouts/bercail.json" || fail "layout not installed"
  cmp -s "$ROOT/bercail/mods/bercail-desk/main.js" "$APP/mods/bercail-desk/main.js" || fail "mod not installed"
  cmp -s "$ROOT/bercail/mods/bercail-agents/main.js" "$APP/mods/bercail-agents/main.js" || fail "agents mod not installed"
  cmp -s "$ROOT/bercail/mods/bercail-review/main.js" "$APP/mods/bercail-review/main.js" || fail "review mod not installed"
  cmp -s "$ROOT/bercail/mods/bercail-shep/main.js" "$APP/mods/bercail-shep/main.js" || fail "Shep mod not installed"
  cmp -s "$ROOT/bercail/mods/bercail-spaces/main.js" "$APP/mods/bercail-spaces/main.js" || fail "spaces mod not installed"
  local f
  for f in main.js mod.json follow.js LICENSE LICENSE-APACHE; do
    cmp -s "$ROOT/bercail/mods/bercail-pane/$f" "$APP/mods/bercail-pane/$f" || fail "pane header mod's $f not installed"
  done
  jq -e '.global["ctrl-shift-t"] == "tab.new"' "$APP/keys.json" >/dev/null || fail "the person's keys must stay"
  jq -e --slurpfile ours "$ROOT/bercail/keys.json" '.["layout:bercail"] == ($ours[0]["layout:bercail"] + {"x":"y"})' \
    "$APP/keys.json" >/dev/null || fail "layout:bercail must get bercail's keys and keep the person's: $(cat "$APP/keys.json")"
}

@test "update follows bercail's key changes only where the person kept bercail's" {
  local before
  recorded_keys_update
  jq -e '.["layout:bercail"] | .["ctrl-shift-r"] == "bercail-desk.review" and .["ctrl-shift-f"] == "my.files"
      and .["ctrl-shift-x"] == "mine.cmd"' "$APP/keys.json" >/dev/null || fail "recorded keys merge: $(section)"
  jq -e '.["layout:bercail"] | (has("ctrl-shift-s") or has("ctrl-alt-q")) | not' "$APP/keys.json" >/dev/null \
    || fail "a key the person removed stays removed, and a key bercail dropped goes: $(section)"
  grep -q 'key ctrl-shift-f: yours is my.files' <<<"$out" || fail "update should warn about the kept key: $out"
  jq -e --slurpfile ours "$ROOT/bercail/keys.json" '.global["ctrl-shift-t"] == "tab.new"
      and .["layout:bercail"] == $ours[0]["layout:bercail"]' "$BERCAIL_SHARE_DIR/herdr-app/keys.json" >/dev/null \
    || fail "update records the shipped keys: $(cat "$BERCAIL_SHARE_DIR/herdr-app/keys.json")"
  before="$(cat "$APP/keys.json")"
  deploy_herdr_app >/dev/null 2>&1
  [[ "$(cat "$APP/keys.json")" == "$before" ]] || fail "a second update must not change keys.json"
}

@test "doctor reports key conflicts" {
  recorded_keys_update
  deploy_herdr_app >/dev/null 2>&1
  jq '.terminal = {"alt-shift-up": "send:x"}' "$APP/keys.json" >"$K" && mv "$K" "$APP/keys.json"
  out="$(doctor_herdr_app 2>&1)"
  grep -q 'conflict  Herdr key ctrl-shift-f: yours is my.files' <<<"$out" || fail "doctor: own key: $out"
  grep -q 'conflict  Herdr key alt-shift-up: the terminal section binds it' <<<"$out" || fail "doctor: terminal key: $out"
  grep -q 'conflict  Herdr key ctrl-shift-s: not in layout:bercail' <<<"$out" || fail "doctor: missing key: $out"
  jq 'del(.terminal) | .["layout:bercail"] = $ours[0]["layout:bercail"]' --slurpfile ours "$ROOT/bercail/keys.json" \
    "$APP/keys.json" >"$K" && mv "$K" "$APP/keys.json"
  out="$(doctor_herdr_app 2>&1)"
  if grep -q conflict <<<"$out"; then
    fail "doctor: no conflicts expected: $out"
  fi
}

@test "doctor names each Pi app key the bercail layout takes before Pi sees it" {
  deploy_herdr_app >/dev/null
  printf '#!/bin/sh\nexit 0\n' >"$BATS_TEST_TMPDIR/bin/pi" && chmod +x "$BATS_TEST_TMPDIR/bin/pi"
  out="$(doctor_herdr_app 2>&1)" || fail "a shadowed Pi key is not a failure: $out"
  grep -q 'shadowed  Pi app.message.dequeue (alt+up): the bercail layout takes alt-up for bercail-desk.space-prev' <<<"$out" \
    || fail "doctor: Pi's default dequeue key: $out"
  grep -q 'shadowed  Pi app.models.reorderDown (alt+down)' <<<"$out" || fail "doctor: every app key: $out"

  # Moved in Pi's keybindings.json, or handed to the program by the terminal
  # section: no longer shadowed. A rebound agent key does not stop the check.
  mkdir -p "$HOME/.pi/agent"
  printf '%s\n' '{"app.message.dequeue": "alt+q", "app.clear": 7, "app.session.new": "ctrl+esc"}' >"$HOME/.pi/agent/keybindings.json"
  jq '.terminal = {"alt-down": "terminal"} | .["layout:bercail"]["ctrl-escape"] = "x.y"
      | .["layout:bercail"]["ctrl-shift-a"] = "mine.agent"' "$APP/keys.json" >"$K" && mv "$K" "$APP/keys.json"
  out="$(doctor_herdr_app 2>&1)" || true
  if grep -q 'app.message.dequeue\|reorderDown' <<<"$out"; then fail "doctor: moved keys are not shadowed: $out"; fi
  grep -q 'shadowed  Pi app.session.new (ctrl+escape): the bercail layout takes ctrl-escape for x.y' <<<"$out" \
    || fail "doctor: the person's own Pi key, after one Pi cannot read: $out"
}

@test "bercail's Pi keys leave no Pi app key shadowed by the shipped layout" {
  deploy_herdr_app >/dev/null
  printf '#!/bin/sh\nexit 0\n' >"$BATS_TEST_TMPDIR/bin/pi" && chmod +x "$BATS_TEST_TMPDIR/bin/pi"
  # shellcheck source=/dev/null
  source "$ROOT/lib/bstack.sh"
  mkdir -p "$HOME/.pi/agent"
  printf '%s\n' "$BSTACK_PI_KEYS" >"$HOME/.pi/agent/keybindings.json"
  out="$(doctor_herdr_app 2>&1)" || fail "doctor: $out"
  if grep -q shadowed <<<"$out"; then fail "doctor: bercail's keys must reach Pi: $out"; fi
}

@test "update keeps the app's layout edits and restores the mod" {
  app_edits_then_update
  jq -e '.background == "chrome"' "$APP/layouts/bercail.json" >/dev/null || fail "an unchanged shipped layout must not replace the app's"
  cmp -s "$ROOT/bercail/mods/bercail-desk/main.js" "$APP/mods/bercail-desk/main.js" || fail "the mod is bercail's: update restores it"
}

@test "a new shipped layout replaces the installed one" {
  app_edits_then_update
  jq '.background = "old"' "$ROOT/bercail/layouts/bercail.json" >"$BERCAIL_SHARE_DIR/herdr-app/layouts/bercail.json"
  deploy_herdr_app >/dev/null
  cmp -s "$ROOT/bercail/layouts/bercail.json" "$APP/layouts/bercail.json" || fail "a new shipped layout must be installed"
}

# ...and keeps the live desks' blocks, the shown one still shown: a running desk mod
# doesn't add a block it added before. The 0.9.x layout had no panel column.
@test "a new shipped layout keeps the live desk blocks" {
  fresh_install
  jq 'walk(if type == "object" and .id == "panel" then .children[0] + {size: {px: 240}} else . end)' \
    "$ROOT/bercail/layouts/bercail.json" >"$BERCAIL_SHARE_DIR/herdr-app/layouts/bercail.json"
  jq '(.. | objects | select(.id == "agent-stack")) |= (.children += [
        {id: "desk-t2x", type: "block", content: {terminal: "t2x"}, padding: [6, 6]},
        {id: "desk-t5p", type: "block", content: {terminal: "t5p"}, padding: [6, 6]}] | .active = "desk-t5p")' \
    "$BERCAIL_SHARE_DIR/herdr-app/layouts/bercail.json" >"$APP/layouts/bercail.json"
  deploy_herdr_app >/dev/null
  jq -e '[.. | objects | select(.id == "agent-stack")][0] | [.children[].id] == ["empty", "desk-t2x", "desk-t5p"]
      and .active == "desk-t5p" and .children[2].content.terminal == "t5p"' "$APP/layouts/bercail.json" >/dev/null \
    || fail "the desk blocks must come back: $(jq -c '.. | objects | select(.id == "agent-stack")' "$APP/layouts/bercail.json")"
  jq -e '.. | objects | select(.id == "panel") | any(.children[]; .id == "panel-body")' "$APP/layouts/bercail.json" >/dev/null \
    || fail "the new layout's panel must be installed"
  [[ "$(_herdr_app_layout_shape "$APP/layouts/bercail.json")" == "$(_herdr_app_layout_shape "$ROOT/bercail/layouts/bercail.json")" ]] \
    || fail "only the desk blocks may differ from the shipped layout"
  cmp -s "$ROOT/bercail/layouts/bercail.json" "$BERCAIL_SHARE_DIR/herdr-app/layouts/bercail.json" \
    || fail "the record is the shipped layout, without the desks"
  deploy_herdr_app >/dev/null
  jq -e '.. | objects | select(.id == "desk-t5p")' "$APP/layouts/bercail.json" >/dev/null || fail "a second update must keep the desks"
}

@test "bercail's layout with only runtime changes is adopted" {
  fresh_install
  # bercail's layout as the app left it (desk and Shep blocks added, the space view
  # shown, columns resized) is adopted.
  rm -f "$BERCAIL_SHARE_DIR/herdr-app/layouts/bercail.json"
  jq '(.. | objects | select(.id == "agent-stack")) |= (.children += [{id: "desk-t9z", type: "block", content: {terminal: "t9z"}}] | .active = "desk-t9z")
    | (.. | objects | select(.id == "shep-stack")) |= (.children += [{id: "shep-t3", type: "block", content: {terminal: "t3"}}] | .active = "shep-t3")
    | (.. | objects | select(.id == "shep") | .hidden) = true | (.. | objects | select(.id == "work") | .hidden) = false
    | (.. | objects | select(.id == "desk") | .size.weight) = 4.2' \
    "$ROOT/bercail/layouts/bercail.json" >"$APP/layouts/bercail.json"
  out="$(deploy_herdr_app)"
  grep -q 'unchanged: .*bercail.json' <<<"$out" || fail "a runtime-only change should count as bercail's: $out"
  jq -e '.. | objects | select(.id == "desk-t9z") | .content.terminal == "t9z"' "$APP/layouts/bercail.json" >/dev/null \
    || fail "adopting must keep the app's values"
  [[ -f "$BERCAIL_SHARE_DIR/herdr-app/layouts/bercail.json" ]] || fail "adopting records the shipped layout"
}

@test "an existing unowned layout is kept unless --force" {
  fresh_install
  rm -f "$BERCAIL_SHARE_DIR/herdr-app/layouts/bercail.json"
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
  grep -q 'stale  Herdr mod file' <<<"$out" || fail "stale mod message: $out"
  deploy_herdr_app >/dev/null
  rm -f "$APP/mods/bercail-pane/follow.js"
  if out="$(doctor_herdr_app)"; then
    fail "doctor should flag the pane header's missing follow.js: $out"
  fi
  grep -qF "missing  Herdr mod file $APP/mods/bercail-pane/follow.js" <<<"$out" || fail "missing follow.js message: $out"
  deploy_herdr_app >/dev/null
  jq 'del(.["layout:bercail"])' "$APP/keys.json" >"$K" && mv "$K" "$APP/keys.json"
  if out="$(doctor_herdr_app)"; then
    fail "doctor should flag missing keys: $out"
  fi
  grep -q 'missing  Herdr keys' <<<"$out" || fail "missing keys message: $out"
}

# Herdr reads a keys.json it did not write as the whole keymap: one bercail starts
# must carry Herdr's own keys too.
@test "a missing keys.json gets Herdr's default keys beside layout:bercail" {
  fresh_install
  rm -f "$APP/keys.json"
  deploy_herdr_app >/dev/null
  jq -e --slurpfile herdr "$ROOT/bercail/herdr-keys/keys.json" --slurpfile ours "$ROOT/bercail/keys.json" '
      keys == ["global", "layout:bercail", "terminal"]
      and .global == $herdr[0].global
      and .global["ctrl-shift-t"] == "tab.new" and .global["ctrl-shift-l"] == "layout.switch"
      and .terminal == ($herdr[0].terminal | del(.["ctrl-shift-f"]))
      and .["layout:bercail"] == $ours[0]["layout:bercail"]' "$APP/keys.json" >/dev/null \
    || fail "new keys.json: $(cat "$APP/keys.json")"
}

@test "on macOS a missing keys.json gets Herdr's macOS default keys" {
  printf '#!/bin/sh\necho Darwin\n' >"$BATS_TEST_TMPDIR/bin/uname" && chmod +x "$BATS_TEST_TMPDIR/bin/uname"
  mkdir -p "$APP"
  deploy_herdr_app >/dev/null
  jq -e --slurpfile herdr "$ROOT/bercail/herdr-keys/keys.macos.json" --slurpfile ours "$ROOT/bercail/keys.json" '
      .global == $herdr[0].global and .global["cmd-t"] == "tab.new"
      and .terminal == $herdr[0].terminal + $ours[0].terminal' "$APP/keys.json" >/dev/null \
    || fail "macOS keys.json: $(cat "$APP/keys.json")"
}

# A keys.json Herdr wrote at 0.1.12 that bercail then merged into: edited, so Herdr
# added none of its later defaults. The person changed one of Herdr's keys and added one.
@test "update adds the Herdr defaults a merged keys.json missed and keeps the person's keys" {
  local before
  fresh_install
  jq --slurpfile ours "$ROOT/bercail/keys.json" '
      del(.global["ctrl-?"]) | .global["ctrl-shift-t"] = "my.tab" | .global["ctrl-shift-y"] = "my.own"
      | .terminal |= del(.["ctrl-shift-f"], .["ctrl-insert"], .["shift-insert"])
      | .["layout:bercail"] = $ours[0]["layout:bercail"]' "$ROOT/bercail/herdr-keys/keys.json" >"$APP/keys.json"
  cp "$ROOT/bercail/keys.json" "$BERCAIL_SHARE_DIR/herdr-app/keys.json"
  deploy_herdr_app >/dev/null 2>&1
  jq -e '.global["ctrl-?"] == "app.help" and .global["ctrl-shift-t"] == "my.tab" and .global["ctrl-shift-y"] == "my.own"
      and .terminal["ctrl-insert"] == "terminal.copy" and .terminal["shift-insert"] == "terminal.paste"
      and (.terminal | has("ctrl-shift-f") | not)' "$APP/keys.json" >/dev/null \
    || fail "Herdr defaults merge: $(cat "$APP/keys.json")"
  before="$(cat "$APP/keys.json")"
  deploy_herdr_app >/dev/null 2>&1
  [[ "$(cat "$APP/keys.json")" == "$before" ]] || fail "a second update must not change keys.json"
}

# A keys.json an earlier bercail started, with only its layout:bercail keys, as on a
# client with no Ctrl+Shift+T. The person bound ctrl-shift-v and one other terminal key.
@test "update adds Herdr's keys to a keys.json bercail started and keeps the person's" {
  local before
  fresh_install
  jq 'del(.terminal)' "$ROOT/bercail/keys.json" >"$BERCAIL_SHARE_DIR/herdr-app/keys.json"
  jq '{"layout:bercail": .["layout:bercail"], terminal: {"ctrl-left": "send:x", "ctrl-shift-v": "my.paste"}}' \
    "$ROOT/bercail/keys.json" >"$APP/keys.json"
  deploy_herdr_app >/dev/null 2>&1
  jq -e --slurpfile herdr "$ROOT/bercail/herdr-keys/keys.json" '
      .terminal == ($herdr[0].terminal | del(.["ctrl-shift-f"]) + {"ctrl-left": "send:x", "ctrl-shift-v": "my.paste"})
      and .global == $herdr[0].global and .global["alt-up"] == "agent.prev"' "$APP/keys.json" >/dev/null \
    || fail "terminal keys merge: $(cat "$APP/keys.json")"
  before="$(cat "$APP/keys.json")"
  deploy_herdr_app >/dev/null 2>&1
  [[ "$(cat "$APP/keys.json")" == "$before" ]] || fail "a second update must not change keys.json"

  # Removed after bercail shipped it: stays removed, and so does a removed section.
  jq 'del(.terminal["ctrl-shift-c"])' "$APP/keys.json" >"$K" && mv "$K" "$APP/keys.json"
  deploy_herdr_app >/dev/null 2>&1
  jq -e '.terminal | has("ctrl-shift-c") | not' "$APP/keys.json" >/dev/null || fail "a removed key came back: $(cat "$APP/keys.json")"
  jq 'del(.terminal)' "$APP/keys.json" >"$K" && mv "$K" "$APP/keys.json"
  deploy_herdr_app >/dev/null 2>&1
  jq -e 'has("terminal") | not' "$APP/keys.json" >/dev/null || fail "a removed section came back: $(cat "$APP/keys.json")"
}

# The terminal section wins over every other one while a terminal has the keyboard,
# so a copy or paste key there would take a chord the person bound elsewhere.
@test "update adds no terminal key the person binds in another section" {
  fresh_install
  jq 'del(.terminal) | .global["ctrl-shift-c"] = "tab.new" | .["layout:bercail"]["ctrl-shift-v"] = "mine.paste"' "$APP/keys.json" >"$K" \
    && mv "$K" "$APP/keys.json"
  jq 'del(.terminal)' "$ROOT/bercail/keys.json" >"$BERCAIL_SHARE_DIR/herdr-app/keys.json"
  deploy_herdr_app >/dev/null 2>&1
  jq -e '(.terminal | has("ctrl-shift-c") or has("ctrl-shift-v") | not) and .terminal["ctrl-insert"] == "terminal.copy"
      and .global["ctrl-shift-c"] == "tab.new" and .["layout:bercail"]["ctrl-shift-v"] == "mine.paste"' "$APP/keys.json" >/dev/null \
    || fail "a key bound elsewhere was shadowed: $(cat "$APP/keys.json")"
}

# Herdr reads modifiers in any order and case, and an upper-case letter as shift.
@test "update adds no Herdr key the person binds under another spelling" {
  mkdir -p "$APP"
  printf '%s\n' '{"global":{" ctrl-T ":"space.new","shift-ctrl-w":"my.close"},"layout:mine":{"SHIFT-INSERT":"tab.new"}}' >"$APP/keys.json"
  deploy_herdr_app >/dev/null 2>&1
  jq -e '.global[" ctrl-T "] == "space.new" and .global["shift-ctrl-w"] == "my.close"
      and (.global | has("ctrl-shift-t") or has("ctrl-shift-w") | not)
      and .global["ctrl-shift-o"] == "pane.split:right"
      and (.terminal | has("shift-insert") | not) and .terminal["ctrl-insert"] == "terminal.copy"' "$APP/keys.json" >/dev/null \
    || fail "a key bound under another spelling was taken: $(cat "$APP/keys.json")"
}

# Herdr's terminal ctrl-insert would run at once and cut off the person's global sequence.
@test "update adds no Herdr key that starts one of the person's key sequences" {
  mkdir -p "$APP"
  printf '%s\n' '{"global":{"ctrl-insert x":"tab.new"}}' >"$APP/keys.json"
  deploy_herdr_app >/dev/null 2>&1
  jq -e '.global["ctrl-insert x"] == "tab.new"
      and (.terminal | has("ctrl-insert") | not) and .terminal["shift-insert"] == "terminal.paste"' "$APP/keys.json" >/dev/null \
    || fail "a key sequence lost its first keystroke: $(cat "$APP/keys.json")"
}

# The person removed the terminal section after an earlier bercail shipped its copy and
# paste there, to give every key to the program: Herdr's other terminal keys stay out too.
@test "update keeps out a section the person removed before it shipped more keys there" {
  fresh_install
  cp "$ROOT/bercail/keys.json" "$BERCAIL_SHARE_DIR/herdr-app/keys.json"
  jq 'del(.terminal)' "$APP/keys.json" >"$K" && mv "$K" "$APP/keys.json"
  deploy_herdr_app >/dev/null 2>&1
  jq -e '(has("terminal") | not) and .global["ctrl-shift-l"] == "layout.switch"' "$APP/keys.json" >/dev/null \
    || fail "a removed section came back: $(cat "$APP/keys.json")"
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
  uninstall_bercail >/dev/null 2>&1
  [[ ! -e "$APP/layouts/bercail.json" && ! -e "$APP/mods/bercail-desk" && ! -e "$APP/mods/bercail-agents" && ! -e "$APP/mods/bercail-review"
    && ! -e "$APP/mods/bercail-shep" && ! -e "$APP/mods/bercail-spaces" && ! -e "$APP/mods/bercail-pane" ]] \
    || fail "uninstall leaves layout or mods"
  jq -e 'has("layout:bercail") | not' "$APP/keys.json" >/dev/null || fail "uninstall leaves layout:bercail keys"
  jq -e '.global["ctrl-shift-t"] == "tab.new"' "$APP/keys.json" >/dev/null || fail "uninstall must keep the person's keys"
}
