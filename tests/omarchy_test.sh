#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

unset BASH_ENV
export __MISE_BASH_ENV_LOADED=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Isolated HOME so the host Omarchy tree does not leak into detection.
export HOME="$tmp/home"
export OMARCHY_PATH=""
mkdir -p "$HOME"

# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=lib/detect.sh
source "$ROOT/lib/detect.sh"
# shellcheck source=lib/omarchy.sh
source "$ROOT/lib/omarchy.sh"
# shellcheck source=lib/doctor.sh
source "$ROOT/lib/doctor.sh"

YES=1
DRY_RUN=0

pass=0
fail=0

ok() {
  printf 'ok - %s\n' "$1"
  pass=$((pass + 1))
}

not_ok() {
  printf 'not ok - %s\n' "$1" >&2
  fail=$((fail + 1))
}

assert_eq() {
  local expected="$1" actual="$2" label="$3"
  if [[ "$actual" == "$expected" ]]; then
    ok "$label"
  else
    not_ok "$label (expected '$expected', got '$actual')"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    ok "$label"
  else
    not_ok "$label (missing '$needle')"
  fi
}

assert_rc() {
  local expected="$1" actual="$2" label="$3"
  if [[ "$actual" -eq "$expected" ]]; then
    ok "$label"
  else
    not_ok "$label (expected rc $expected, got $actual)"
  fi
}

test_is_omarchy_isolated_home() {
  local rc expect=1
  export OMARCHY_PATH=""
  command -v omarchy >/dev/null 2>&1 && expect=0
  [[ -x /usr/share/omarchy/bin/omarchy ]] && expect=0
  if is_omarchy; then rc=0; else rc=$?; fi
  assert_rc "$expect" "$rc" "isolated HOME detects Omarchy only via CLI/share path"
}

test_is_omarchy_user_share() {
  local rc
  mkdir -p "$HOME/.local/share/omarchy"
  if is_omarchy; then rc=0; else rc=$?; fi
  assert_rc 0 "$rc" "HOME/.local/share/omarchy detects Omarchy"
  rmdir "$HOME/.local/share/omarchy"
}

test_is_omarchy_omarchy_path() {
  local rc root="$tmp/custom-omarchy"
  mkdir -p "$root"
  export OMARCHY_PATH="$root"
  if is_omarchy; then rc=0; else rc=$?; fi
  assert_rc 0 "$rc" "OMARCHY_PATH detects Omarchy"
  export OMARCHY_PATH=""
}

test_is_omarchy_config_dir_is_not_enough() {
  local rc
  if command -v omarchy >/dev/null 2>&1 || [[ -x /usr/share/omarchy/bin/omarchy ]]; then
    ok "skip config-dir-only (host already has omarchy CLI)"
    return
  fi
  mkdir -p "$HOME/.config/omarchy"
  if is_omarchy; then rc=0; else rc=$?; fi
  assert_rc 1 "$rc" "HOME/.config/omarchy alone is not Omarchy"
  rm -rf "$HOME/.config/omarchy"
}

test_has_hyprland_lua() {
  local rc
  mkdir -p "$HOME/.config/hypr"
  : >"$HOME/.config/hypr/bindings.lua"
  if has_hyprland; then rc=0; else rc=$?; fi
  assert_rc 0 "$rc" "bindings.lua counts as Hyprland"
  rm -rf "$HOME/.config/hypr"
}

test_hypr_bindings_prefers_lua() {
  mkdir -p "$HOME/.config/hypr"
  : >"$HOME/.config/hypr/bindings.conf"
  : >"$HOME/.config/hypr/bindings.lua"
  assert_eq "$HOME/.config/hypr/bindings.lua" "$(hypr_bindings_file)" \
    "Quattro prefers bindings.lua over leftover bindings.conf"
  rm -rf "$HOME/.config/hypr"
}

test_lua_binding_omarchy() {
  mkdir -p "$HOME/.local/share/omarchy"
  local block
  block="$(herdr_hypr_binding_lua)"
  assert_contains "$block" 'hl.unbind("SUPER + ALT + RETURN")' \
    "Omarchy lua unbinds SUPER+ALT+RETURN"
  assert_contains "$block" '{ launch = "herdr-app", focus = "^herdr-app$" }' \
    "Omarchy lua launches or focuses the Herdr app"
  rmdir "$HOME/.local/share/omarchy"
}

test_lua_binding_generic() {
  local block
  block="$(
    is_omarchy() { return 1; }
    herdr_hypr_binding_lua
  )"
  assert_contains "$block" 'hl.dsp.exec_cmd("herdr-app")' \
    "generic Hyprland lua launches the Herdr app"
}

test_patch_lua_bindings() {
  mkdir -p "$HOME/.local/share/omarchy" "$HOME/.config/hypr"
  printf '%s\n' '-- user overrides' >"$HOME/.config/hypr/bindings.lua"
  patch_hypr_herdr_binding
  grep -q 'launch = "herdr-app"' "$HOME/.config/hypr/bindings.lua" \
    && ok "patch writes Omarchy lua Herdr binding" \
    || not_ok "patch writes Omarchy lua Herdr binding"
  if hypr_has_herdr_binding; then
    ok "hypr_has_herdr_binding sees lua herdr"
  else
    not_ok "hypr_has_herdr_binding sees lua herdr"
  fi
  local before
  before="$(<"$HOME/.config/hypr/bindings.lua")"
  patch_hypr_herdr_binding
  assert_eq "$before" "$(<"$HOME/.config/hypr/bindings.lua")" \
    "second patch is a no-op when herdr is already bound"
  rm -rf "$HOME/.local/share/omarchy" "$HOME/.config/hypr"
}

test_doctor_herdr_app_binding() {
  mkdir -p "$HOME/.local/share/omarchy" "$HOME/.config/fcitx5/conf" "$HOME/.config/hypr"
  printf '%s\n' 'Hint Trigger=' >"$HOME/.config/fcitx5/conf/keyboard.conf"
  printf '%s\n' 'bindd = SUPER ALT, RETURN, Herdr, exec, xdg-terminal-exec herdr' >"$HOME/.config/hypr/bindings.conf"
  local output rc
  if output="$(doctor_omarchy_integration 2>&1)"; then rc=0; else rc=$?; fi
  assert_rc 1 "$rc" "doctor flags a binding that still opens terminal herdr"
  assert_contains "$output" "missing  hypr SUPER+ALT+RETURN Herdr app binding" \
    "doctor names the missing Herdr app binding"
  YES=1 patch_hypr_herdr_binding
  assert_eq 'bindd = SUPER ALT, RETURN, Herdr, exec, omarchy-launch-or-focus "^herdr-app$" herdr-app' \
    "$(<"$HOME/.config/hypr/bindings.conf")" "patch replaces the terminal herdr binding in bindings.conf"
  if output="$(doctor_omarchy_integration 2>&1)"; then rc=0; else rc=$?; fi
  assert_rc 0 "$rc" "doctor accepts the Herdr app binding"
  rm -rf "$HOME/.local/share/omarchy" "$HOME/.config/fcitx5" "$HOME/.config/hypr"
}

test_sync_omarchy_default_agent() {
  mkdir -p "$HOME/.local/share/omarchy" "$HOME/.config/agentic-dev"
  cat >"$HOME/.config/agentic-dev/config.toml" <<'EOF'
[agent]
command = "grok"
EOF
  read_agent_command() { printf 'grok'; }
  RECONFIGURE=1
  sync_omarchy_default_agent
  assert_eq "grok" "$(tr -d '\n' <"$HOME/.config/omarchy/defaults/agent")" \
    "reconfigure writes omarchy default agent grok"
  unset -f read_agent_command
  rm -rf "$HOME/.local/share/omarchy" "$HOME/.config/omarchy" "$HOME/.config/agentic-dev"
}

test_is_omarchy_isolated_home
test_is_omarchy_user_share
test_is_omarchy_omarchy_path
test_is_omarchy_config_dir_is_not_enough
test_has_hyprland_lua
test_hypr_bindings_prefers_lua
test_lua_binding_omarchy
test_lua_binding_generic
test_patch_lua_bindings
test_doctor_herdr_app_binding
test_sync_omarchy_default_agent

printf '%s passed, %s failed\n' "$pass" "$fail"
((fail == 0))
