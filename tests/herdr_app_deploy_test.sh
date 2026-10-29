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
jq -e --slurpfile ours "$ROOT/bercail/keys.json" '.["layout:bercail"] == $ours[0]["layout:bercail"]' \
  "$APP/keys.json" >/dev/null || fail "layout:bercail must be replaced by bercail's"
printf 'PASS: deploy installs the layout and mod and merges only layout:bercail keys\n'

# The app rewrites its layout (the desk mod repoints the agent block): keep that.
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

# bercail's layout as the app left it (desk repointed, columns resized) is adopted.
rm -f "$AGENTIC_DEV_SHARE_DIR/herdr-app/layouts/bercail.json"
jq '(.. | objects | select(.id == "agent") | .content) = {terminal: "t9z"}
  | (.. | objects | select(.id == "agent-stack") | .active) = "agent"
  | (.. | objects | select(.id == "desk") | .size.weight) = 4.2' \
  "$ROOT/bercail/layouts/bercail.json" >"$APP/layouts/bercail.json"
out="$(deploy_herdr_app)"
printf '%s' "$out" | grep -q 'unchanged: .*bercail.json' || fail "a runtime-only change should count as bercail's: $out"
jq -e '.. | objects | select(.id == "agent") | .content.terminal == "t9z"' "$APP/layouts/bercail.json" >/dev/null \
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
