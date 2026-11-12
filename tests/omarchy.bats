#!/usr/bin/env bats

# shellcheck disable=SC2034 # YES, DRY_RUN and friends are read by the sourced libs.
# shellcheck disable=SC2329 # stubs replace lib functions the libs call.

setup() {
  load test_helper
  isolate
  # The host Omarchy tree must not leak into detection.
  export OMARCHY_PATH=""
  # shellcheck source=/dev/null
  source "$ROOT/lib/common.sh"
  # shellcheck source=/dev/null
  source "$ROOT/lib/detect.sh"
  # shellcheck source=/dev/null
  source "$ROOT/lib/omarchy.sh"
  # shellcheck source=/dev/null
  source "$ROOT/lib/doctor.sh"
  YES=1
  DRY_RUN=0
}

assert_eq() {
  local expected="$1" actual="$2" label="$3"
  [[ "$actual" == "$expected" ]] || fail "$label (expected '$expected', got '$actual')"
}

assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  [[ "$haystack" == *"$needle"* ]] || fail "$label (missing '$needle')"
}

assert_rc() {
  local expected="$1" actual="$2" label="$3"
  [[ "$actual" -eq "$expected" ]] || fail "$label (expected rc $expected, got $actual)"
}

host_has_omarchy_cli() {
  command -v omarchy >/dev/null 2>&1 || [[ -x /usr/share/omarchy/bin/omarchy ]]
}

# Omarchy, with a lua bindings file of the person's own, patched once.
patch_lua() {
  mkdir -p "$HOME/.local/share/omarchy" "$HOME/.config/hypr"
  printf '%s\n' '-- user overrides' >"$HOME/.config/hypr/bindings.lua"
  patch_hypr_herdr_binding
}

# Omarchy, with a bindings.conf whose SUPER+ALT+RETURN opens the herdr terminal.
terminal_herdr_binding() {
  mkdir -p "$HOME/.local/share/omarchy" "$HOME/.config/fcitx5/conf" "$HOME/.config/hypr"
  printf '%s\n' 'Hint Trigger=' >"$HOME/.config/fcitx5/conf/keyboard.conf"
  printf '%s\n' 'bindd = SUPER ALT, RETURN, Herdr, exec, xdg-terminal-exec herdr' >"$HOME/.config/hypr/bindings.conf"
}

@test "isolated HOME detects Omarchy only via CLI/share path" {
  local rc expect=1
  host_has_omarchy_cli && expect=0
  if is_omarchy; then rc=0; else rc=$?; fi
  assert_rc "$expect" "$rc" "isolated HOME detects Omarchy only via CLI/share path"
}

@test "HOME/.local/share/omarchy detects Omarchy" {
  local rc
  mkdir -p "$HOME/.local/share/omarchy"
  if is_omarchy; then rc=0; else rc=$?; fi
  assert_rc 0 "$rc" "HOME/.local/share/omarchy detects Omarchy"
}

@test "OMARCHY_PATH detects Omarchy" {
  local rc omarchy_root="$BATS_TEST_TMPDIR/custom-omarchy"
  mkdir -p "$omarchy_root"
  export OMARCHY_PATH="$omarchy_root"
  if is_omarchy; then rc=0; else rc=$?; fi
  assert_rc 0 "$rc" "OMARCHY_PATH detects Omarchy"
}

@test "HOME/.config/omarchy alone is not Omarchy" {
  local rc
  if host_has_omarchy_cli; then
    skip "config-dir-only (host already has omarchy CLI)"
  fi
  mkdir -p "$HOME/.config/omarchy"
  if is_omarchy; then rc=0; else rc=$?; fi
  assert_rc 1 "$rc" "HOME/.config/omarchy alone is not Omarchy"
}

@test "bindings.lua counts as Hyprland" {
  local rc
  mkdir -p "$HOME/.config/hypr"
  : >"$HOME/.config/hypr/bindings.lua"
  if has_hyprland; then rc=0; else rc=$?; fi
  assert_rc 0 "$rc" "bindings.lua counts as Hyprland"
}

@test "Quattro prefers bindings.lua over leftover bindings.conf" {
  mkdir -p "$HOME/.config/hypr"
  : >"$HOME/.config/hypr/bindings.conf"
  : >"$HOME/.config/hypr/bindings.lua"
  assert_eq "$HOME/.config/hypr/bindings.lua" "$(hypr_bindings_file)" \
    "Quattro prefers bindings.lua over leftover bindings.conf"
}

@test "Omarchy lua unbinds SUPER+ALT+RETURN and launches or focuses the Herdr app" {
  local block
  mkdir -p "$HOME/.local/share/omarchy"
  block="$(herdr_hypr_binding_lua)"
  assert_contains "$block" 'hl.unbind("SUPER + ALT + RETURN")' \
    "Omarchy lua unbinds SUPER+ALT+RETURN"
  assert_contains "$block" '{ launch = "herdr-app", focus = "^herdr-app$" }' \
    "Omarchy lua launches or focuses the Herdr app"
}

@test "generic Hyprland lua launches the Herdr app" {
  local block
  block="$(
    is_omarchy() { return 1; }
    herdr_hypr_binding_lua
  )"
  assert_contains "$block" 'hl.dsp.exec_cmd("herdr-app")' \
    "generic Hyprland lua launches the Herdr app"
}

@test "patch writes Omarchy lua Herdr binding" {
  patch_lua
  grep -q 'launch = "herdr-app"' "$HOME/.config/hypr/bindings.lua" \
    || fail "patch writes Omarchy lua Herdr binding"
}

@test "hypr_has_herdr_binding sees lua herdr" {
  patch_lua
  hypr_has_herdr_binding || fail "hypr_has_herdr_binding sees lua herdr"
}

@test "second patch is a no-op when herdr is already bound" {
  local before
  patch_lua
  before="$(<"$HOME/.config/hypr/bindings.lua")"
  patch_hypr_herdr_binding
  assert_eq "$before" "$(<"$HOME/.config/hypr/bindings.lua")" \
    "second patch is a no-op when herdr is already bound"
}

@test "doctor flags a binding that still opens terminal herdr" {
  local output rc
  terminal_herdr_binding
  if output="$(doctor_omarchy_integration 2>&1)"; then rc=0; else rc=$?; fi
  assert_rc 1 "$rc" "doctor flags a binding that still opens terminal herdr"
  assert_contains "$output" "missing  hypr SUPER+ALT+RETURN Herdr app binding" \
    "doctor names the missing Herdr app binding"
}

@test "patch replaces the terminal herdr binding in bindings.conf" {
  terminal_herdr_binding
  YES=1 patch_hypr_herdr_binding
  assert_eq 'bindd = SUPER ALT, RETURN, Herdr, exec, omarchy-launch-or-focus "^herdr-app$" herdr-app' \
    "$(<"$HOME/.config/hypr/bindings.conf")" "patch replaces the terminal herdr binding in bindings.conf"
}

@test "doctor accepts the Herdr app binding" {
  local output rc
  terminal_herdr_binding
  YES=1 patch_hypr_herdr_binding
  if output="$(doctor_omarchy_integration 2>&1)"; then rc=0; else rc=$?; fi
  assert_rc 0 "$rc" "doctor accepts the Herdr app binding"
}

@test "reconfigure writes omarchy default agent pi; a choice already there stays" {
  mkdir -p "$HOME/.local/share/omarchy"
  RECONFIGURE=1
  sync_omarchy_default_agent
  assert_eq "pi" "$(tr -d '\n' <"$HOME/.config/omarchy/defaults/agent")" \
    "reconfigure writes omarchy default agent pi"
  RECONFIGURE=0
  printf 'custom\n' >"$HOME/.config/omarchy/defaults/agent"
  sync_omarchy_default_agent
  assert_eq "custom" "$(tr -d '\n' <"$HOME/.config/omarchy/defaults/agent")" \
    "a choice already there stays"
  rm -f "$HOME/.config/omarchy/defaults/agent"
  sync_omarchy_default_agent
  assert_eq "pi" "$(tr -d '\n' <"$HOME/.config/omarchy/defaults/agent")" \
    "a missing file is written as pi"
}
