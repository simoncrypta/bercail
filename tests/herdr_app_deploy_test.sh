#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

unset BASH_ENV
export __MISE_BASH_ENV_LOADED=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

export HOME="$TMP_DIR/home"
export XDG_CONFIG_HOME="$HOME/.config"
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$TMP_DIR/bin"
unset HERDR_APP_CONFIG_DIR

# A fake herdr-app: check passes unless $TMP_DIR/check-fails exists.
cat >"$TMP_DIR/bin/herdr-app" <<EOF
#!/bin/sh
[ "\$1" = check ] && [ -f "$TMP_DIR/check-fails" ] && exit 1
exit 0
EOF
chmod +x "$TMP_DIR/bin/herdr-app"
export PATH="$TMP_DIR/bin:$PATH"

# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=lib/detect.sh
source "$ROOT/lib/detect.sh"
# shellcheck source=lib/config.sh
source "$ROOT/lib/config.sh"
# shellcheck source=lib/skills.sh
source "$ROOT/lib/skills.sh"
# shellcheck source=lib/doctor.sh
source "$ROOT/lib/doctor.sh"
# shellcheck source=lib/shell-rc.sh
source "$ROOT/lib/shell-rc.sh"
# shellcheck source=lib/uninstall.sh
source "$ROOT/lib/uninstall.sh"

export INSTALL_SRC="$ROOT"
YES=1
DRY_RUN=0
APP="$HERDR_APP_CONFIG_DIR"
[[ "$APP" == "$HOME/.config/herdr-app" ]] || fail "app home: $APP"

# Fresh install: layout, mod and keys land; the person's keys stay.
mkdir -p "$APP"
printf '{"global":{"ctrl-shift-t":"tab.new"},"layout:bercail":{"x":"y"}}\n' >"$APP/keys.json"
deploy_herdr_app >/dev/null
cmp -s "$ROOT/bercail/layouts/bercail.json" "$APP/layouts/bercail.json" || fail "layout not installed"
cmp -s "$ROOT/bercail/mods/bercail-desk/main.js" "$APP/mods/bercail-desk/main.js" || fail "mod not installed"
jq -e '.global["ctrl-shift-t"] == "tab.new"' "$APP/keys.json" >/dev/null || fail "the person's keys must stay"
jq -e --slurpfile ours "$ROOT/bercail/keys.json" '.["layout:bercail"] == ($ours[0]["layout:bercail"] + {"x":"y"})' \
  "$APP/keys.json" >/dev/null || fail "layout:bercail must get bercail's keys and keep the person's: $(cat "$APP/keys.json")"
printf 'PASS: deploy installs the layout and mod and merges only layout:bercail keys\n'

# Keys: an install from before bercail recorded its keys (0.9.x) moves to the new
# ones, and keeps what the person changed in the section since.
section() { jq -c '.["layout:bercail"]' "$APP/keys.json"; }
rm -f "$AGENTIC_DEV_SHARE_DIR/herdr-app/keys.json"
jq --argjson legacy "$HERDR_APP_KEYS_LEGACY" '.["layout:bercail"] = ($legacy
    + {"ctrl-alt-down": "pane.go:down", "ctrl-shift-x": "mine.cmd"} | del(.["ctrl-shift-s"]))' \
  "$APP/keys.json" >"$TMP_DIR/k" && mv "$TMP_DIR/k" "$APP/keys.json"
out="$(deploy_herdr_app 2>&1)"
jq -e '.["layout:bercail"] | .["alt-up"] == "bercail-desk.space-prev" and .["alt-shift-down"] == "bercail-desk.agent-next"
    and .["ctrl-alt-up"] == "bercail-desk.subspace-prev"' "$APP/keys.json" >/dev/null || fail "new keys not added: $(section)"
jq -e '.["layout:bercail"] | .["ctrl-alt-down"] == "pane.go:down" and .["ctrl-shift-x"] == "mine.cmd"
    and (has("ctrl-shift-s") | not)' "$APP/keys.json" >/dev/null || fail "the person's key changes must stay: $(section)"
jq -e '[.["layout:bercail"][] | select(. == "bercail-desk.go-up" or . == "bercail-desk.go-down")] == []' "$APP/keys.json" >/dev/null \
  || fail "keys bercail dropped must go: $(section)"
printf '%s' "$out" | grep -q 'key ctrl-alt-down: yours is pane.go:down' || fail "update should warn about the kept key: $out"
cmp -s "$ROOT/bercail/keys.json" "$AGENTIC_DEV_SHARE_DIR/herdr-app/keys.json" || fail "update records the shipped keys"
printf 'PASS: update moves 0.9.x keys to the new ones and keeps the person'"'"'s changes\n'

# With the shipped keys recorded: a value bercail changes follows it unless the person changed it.
jq '.["layout:bercail"]["ctrl-shift-r"] = "old.review" | .["layout:bercail"]["ctrl-shift-f"] = "old.files"' \
  "$ROOT/bercail/keys.json" >"$AGENTIC_DEV_SHARE_DIR/herdr-app/keys.json"
jq '.["layout:bercail"]["ctrl-shift-r"] = "old.review" | .["layout:bercail"]["ctrl-shift-f"] = "my.files"' \
  "$APP/keys.json" >"$TMP_DIR/k" && mv "$TMP_DIR/k" "$APP/keys.json"
deploy_herdr_app >/dev/null 2>&1
jq -e '.["layout:bercail"] | .["ctrl-shift-r"] == "bercail-desk.review" and .["ctrl-shift-f"] == "my.files"' \
  "$APP/keys.json" >/dev/null || fail "recorded keys merge: $(section)"
before="$(cat "$APP/keys.json")"
deploy_herdr_app >/dev/null 2>&1
[[ "$(cat "$APP/keys.json")" == "$before" ]] || fail "a second update must not change keys.json"
printf 'PASS: update follows bercail'"'"'s key changes only where the person kept bercail'"'"'s\n'

# Doctor reports keys that don't do bercail's thing: the person's own, and terminal ones.
jq '.terminal = {"alt-shift-up": "send:x"}' "$APP/keys.json" >"$TMP_DIR/k" && mv "$TMP_DIR/k" "$APP/keys.json"
out="$(doctor_herdr_app 2>&1)"
printf '%s' "$out" | grep -q 'conflict  Herdr key ctrl-shift-f: yours is my.files' || fail "doctor: own key: $out"
printf '%s' "$out" | grep -q 'conflict  Herdr key alt-shift-up: the terminal section binds it' || fail "doctor: terminal key: $out"
printf '%s' "$out" | grep -q 'conflict  Herdr key ctrl-shift-s: not in layout:bercail' || fail "doctor: missing key: $out"
jq 'del(.terminal) | .["layout:bercail"] = $ours[0]["layout:bercail"]' --slurpfile ours "$ROOT/bercail/keys.json" \
  "$APP/keys.json" >"$TMP_DIR/k" && mv "$TMP_DIR/k" "$APP/keys.json"
out="$(doctor_herdr_app 2>&1)"
printf '%s' "$out" | grep -q conflict && fail "doctor: no conflicts expected: $out"
printf 'PASS: doctor reports key conflicts\n'

# The app rewrites its layout (the desk mod adds desk blocks): keep that.
jq '.background = "chrome"' "$APP/layouts/bercail.json" >"$TMP_DIR/l" && mv "$TMP_DIR/l" "$APP/layouts/bercail.json"
printf 'local edit\n' >>"$APP/mods/bercail-desk/main.js"
deploy_herdr_app >/dev/null
jq -e '.background == "chrome"' "$APP/layouts/bercail.json" >/dev/null || fail "an unchanged shipped layout must not replace the app's"
cmp -s "$ROOT/bercail/mods/bercail-desk/main.js" "$APP/mods/bercail-desk/main.js" || fail "the mod is bercail's: update restores it"
printf 'PASS: update keeps the app'"'"'s layout edits and restores the mod\n'

# A new shipped layout replaces the app's copy.
jq '.background = "old"' "$ROOT/bercail/layouts/bercail.json" >"$AGENTIC_DEV_SHARE_DIR/herdr-app/layouts/bercail.json"
deploy_herdr_app >/dev/null
cmp -s "$ROOT/bercail/layouts/bercail.json" "$APP/layouts/bercail.json" || fail "a new shipped layout must be installed"
printf 'PASS: a new shipped layout replaces the installed one\n'

# ...and keeps the live desks' blocks, the shown one still shown: a running desk mod
# doesn't add a block it added before. The 0.9.x layout had no panel column.
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
printf 'PASS: a new shipped layout keeps the live desk blocks\n'

# bercail's layout as the app left it (desk blocks added, columns resized) is adopted.
rm -f "$AGENTIC_DEV_SHARE_DIR/herdr-app/layouts/bercail.json"
jq '(.. | objects | select(.id == "agent-stack")) |= (.children += [{id: "desk-t9z", type: "block", content: {terminal: "t9z"}}] | .active = "desk-t9z")
  | (.. | objects | select(.id == "desk") | .size.weight) = 4.2' \
  "$ROOT/bercail/layouts/bercail.json" >"$APP/layouts/bercail.json"
out="$(deploy_herdr_app)"
printf '%s' "$out" | grep -q 'unchanged: .*bercail.json' || fail "a runtime-only change should count as bercail's: $out"
jq -e '.. | objects | select(.id == "desk-t9z") | .content.terminal == "t9z"' "$APP/layouts/bercail.json" >/dev/null \
  || fail "adopting must keep the app's values"
[[ -f "$AGENTIC_DEV_SHARE_DIR/herdr-app/layouts/bercail.json" ]] || fail "adopting records the shipped layout"
printf 'PASS: bercail'"'"'s layout with only runtime changes is adopted\n'

# A bercail.json from before bercail shipped one is kept unless --force.
rm -f "$AGENTIC_DEV_SHARE_DIR/herdr-app/layouts/bercail.json"
printf '{"id":"mine"}\n' >"$APP/layouts/bercail.json"
deploy_herdr_app >/dev/null
jq -e '.id == "mine"' "$APP/layouts/bercail.json" >/dev/null || fail "an unowned bercail layout must be kept"
FORCE=1 deploy_herdr_app >/dev/null
cmp -s "$ROOT/bercail/layouts/bercail.json" "$APP/layouts/bercail.json" || fail "--force replaces it"
printf 'PASS: an existing unowned layout is kept unless --force\n'

# Doctor.
out="$(doctor_herdr_app)" || fail "doctor should pass: $out"
printf 'stale\n' >>"$APP/mods/bercail-desk/main.js"
record_install_source >/dev/null
out="$(doctor_herdr_app)" && fail "doctor should flag a stale mod: $out"
printf '%s' "$out" | grep -q 'stale  Herdr mod file' || fail "stale mod message: $out"
deploy_herdr_app >/dev/null
jq 'del(.["layout:bercail"])' "$APP/keys.json" >"$TMP_DIR/k" && mv "$TMP_DIR/k" "$APP/keys.json"
out="$(doctor_herdr_app)" && fail "doctor should flag missing keys: $out"
printf '%s' "$out" | grep -q 'missing  Herdr keys' || fail "missing keys message: $out"
deploy_herdr_app >/dev/null
printf 'PASS: doctor checks the layout, mod and keys\n'

# No keys.json yet: one is made with only bercail's section.
rm -f "$APP/keys.json"
deploy_herdr_app >/dev/null
jq -e 'keys == ["layout:bercail"]' "$APP/keys.json" >/dev/null || fail "new keys.json: $(cat "$APP/keys.json")"
printf 'PASS: a missing keys.json gets only the layout:bercail section\n'

# No app: nothing written, install goes on.
rm -rf "$APP"
PATH="/usr/bin:/bin" deploy_herdr_app >/dev/null 2>&1 || fail "a missing app must not fail the install"
[[ ! -e "$APP" ]] || fail "nothing is written without the app"
printf 'PASS: no Herdr app skips the step\n'

# Uninstall removes bercail's files and keys, nothing else.
deploy_herdr_app >/dev/null
jq '.global = {"ctrl-shift-t":"tab.new"}' "$APP/keys.json" >"$TMP_DIR/k" && mv "$TMP_DIR/k" "$APP/keys.json"
uninstall_agentic_dev >/dev/null 2>&1
[[ ! -e "$APP/layouts/bercail.json" && ! -e "$APP/mods/bercail-desk" ]] || fail "uninstall leaves layout or mod"
jq -e 'has("layout:bercail") | not' "$APP/keys.json" >/dev/null || fail "uninstall leaves layout:bercail keys"
jq -e '.global["ctrl-shift-t"] == "tab.new"' "$APP/keys.json" >/dev/null || fail "uninstall must keep the person's keys"
printf 'PASS: uninstall removes the layout, mod and layout:bercail keys only\n'
