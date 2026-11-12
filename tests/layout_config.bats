#!/usr/bin/env bats
# Layout config: defaults, write, migration, and doctor follow the review command.

# shellcheck disable=SC2034 # YES, DRY_RUN and friends are read by the sourced libs.
# shellcheck disable=SC2329 # stubs replace lib functions the libs call.

setup() {
  load test_helper
  isolate
  mkdir -p "$XDG_CONFIG_HOME"
  # shellcheck source=/dev/null
  source "$ROOT/lib/common.sh"
  # shellcheck source=/dev/null
  source "$ROOT/lib/detect.sh"
  # shellcheck source=/dev/null
  source "$ROOT/lib/deps.sh"
  # shellcheck source=/dev/null
  source "$ROOT/lib/config.sh"

  export INSTALL_SRC="$ROOT"
  export AGENTIC_DEV_CONFIG_DIR="$XDG_CONFIG_HOME/agentic-dev"
  export AGENTIC_DEV_USER_CONFIG="$AGENTIC_DEV_CONFIG_DIR/config.toml"
  unset EDITOR
  YES=1
  DRY_RUN=0

  info() { :; }
  warn() { printf '%s\n' "$*" >&2; }
}

assert_eq() {
  local expected="$1" actual="$2" msg="${3:-}"
  [[ "$expected" == "$actual" ]] || fail "${msg}: expected '$expected' got '$actual'"
}

assert_contains() {
  local haystack="$1" needle="$2" msg="${3:-}"
  [[ "$haystack" == *"$needle"* ]] || fail "${msg}: missing '$needle' in '$haystack'"
}

install_config_reader() {
  mkdir -p "$AGENTIC_DEV_CONFIG_DIR"
  cp "$ROOT/config/agentic-dev/config-reader.sh" "$AGENTIC_DEV_CONFIG_DIR/config-reader.sh"
}

# doctor_dependencies on a host with every tool but tuicr, and review = "hunk".
# Sets out and rc.
doctor_with_hunk_review() {
  local case_dir="$BATS_TEST_TMPDIR/doctor-hunk" cmd
  mkdir -p "$case_dir/bin" "$case_dir/home/.config/agentic-dev"
  cat >"$case_dir/home/.config/agentic-dev/config.toml" <<'EOF'
[layout]
review = "hunk"
EOF
  cp "$ROOT/config/agentic-dev/config-reader.sh" \
    "$case_dir/home/.config/agentic-dev/config-reader.sh"
  for cmd in herdr-app hc git wt bd fzf jq hunk pi; do
    ln -s /bin/true "$case_dir/bin/$cmd"
  done
  rc=0
  out="$(
    HOME="$case_dir/home" \
      XDG_CONFIG_HOME="$case_dir/home/.config" \
      AGENTIC_DEV_CONFIG_DIR="$case_dir/home/.config/agentic-dev" \
      AGENTIC_DEV_USER_CONFIG="$case_dir/home/.config/agentic-dev/config.toml" \
      PATH="$case_dir/bin:/usr/bin:/bin" \
      doctor_dependencies 2>&1
  )" || rc=$?
}

@test "detect_shell_name and shell_rc_for follow the SHELL variable" {
  SHELL=/bin/zsh
  assert_eq "zsh" "$(detect_shell_name)" "detect_shell_name follows zsh \$SHELL"
  assert_eq "${HOME}/.zshrc" "$(shell_rc_for zsh)" "zsh rc is ~/.zshrc"
  SHELL=/bin/bash
  assert_eq "bash" "$(detect_shell_name)" "detect_shell_name follows bash \$SHELL"
  assert_eq "${HOME}/.bashrc" "$(shell_rc_for bash)" "bash rc is ~/.bashrc"
}

@test "a new install turns bstack on with the claude lead; --no-bstack writes no [bstack] and no agent command" {
  local cfg
  assert_contains "$(default_user_config)" 'enabled = true' \
    "a new install turns bstack on"
  assert_contains "$(default_user_config)" 'lead = "claude"' \
    "a new install names the claude family for the lead"
  cfg="$(BSTACK_NEW_INSTALL=0 default_user_config)"
  [[ "$cfg" != *'[bstack]'* ]] || fail "--no-bstack leaves plain Pi, no [bstack]"
  [[ "$cfg" != *'command = '* ]] || fail "config has no agent command"
}

@test "install has no agent picker: prompt_user_config writes the default review and turns bstack on" {
  if grep -q 'Choice \[1-7\]' "$ROOT/lib/config.sh"; then
    fail "install must not prompt for an agent picker"
  fi
  YES=1
  prompt_user_config
  assert_eq "tuicr" "$(read_layout_review)" "prompt_user_config writes the default review"
  grep -q 'enabled = true' "$AGENTIC_DEV_USER_CONFIG" \
    || fail "prompt_user_config turns bstack on"
}

@test "pstack plugin detection is gone" {
  if declare -F pstack_plugin_present >/dev/null; then
    fail "pstack detection is gone; Shep owns the workflow"
  fi
}

@test "default config turns on tuicr review with auto_review and pins no editor" {
  assert_contains "$(default_user_config)" 'review = "tuicr"' \
    "default config includes review"
  assert_contains "$(default_user_config)" 'auto_review = true' \
    "default config enables auto_review"
  [[ "$(default_user_config)" != *'editor = "fresh"'* ]] \
    || fail "default config must not pin fresh as the editor"
}

@test "the config reader returns tuicr review for a new install" {
  YES=1
  prompt_user_config
  install_config_reader
  assert_eq "tuicr" "$(read_layout_review)" "review defaults to tuicr"
}

@test "doctor accepts hunk review without requiring tuicr or lazygit" {
  doctor_with_hunk_review
  assert_eq "0" "$rc" "doctor exits 0 for hunk review"
  assert_contains "$out" "ok  hunk" "doctor accepts configured hunk"
  [[ "$out" != *"missing  tuicr"* ]] || fail "doctor should not require tuicr when review is hunk"
  [[ "$out" != *"lazygit"* ]] || fail "doctor no longer needs lazygit"
}

@test "doctor checks the Herdr app and herdr-core" {
  doctor_with_hunk_review
  assert_contains "$out" "ok  herdr-app" "doctor checks the Herdr app"
  assert_contains "$out" "ok  hc" "doctor checks herdr-core"
}

@test "migrate_hunk_review_to_tuicr rewrites hunk diff to tuicr" {
  install_config_reader
  cat >"$AGENTIC_DEV_USER_CONFIG" <<'EOF'
[layout]
review = "hunk diff"
auto_review = false
EOF
  migrate_hunk_review_to_tuicr
  assert_eq "tuicr" "$(read_layout_review)" "migrate_hunk_review_to_tuicr rewrites hunk diff"
  grep -q 'review = "tuicr"' "$AGENTIC_DEV_USER_CONFIG" \
    || fail "migrate_hunk_review_to_tuicr writes review = tuicr"
}

@test "ensure_tuicr_watch_config adds diff watch and keeps an existing theme" {
  mkdir -p "$XDG_CONFIG_HOME/tuicr"
  printf 'theme = "dark"\n' >"$XDG_CONFIG_HOME/tuicr/config.toml"
  ensure_tuicr_watch_config
  grep -q 'theme = "dark"' "$XDG_CONFIG_HOME/tuicr/config.toml" \
    || fail "ensure_tuicr_watch_config must keep an existing theme"
  grep -q 'diff_watch_interval_ms = 1000' "$XDG_CONFIG_HOME/tuicr/config.toml" \
    || fail "ensure_tuicr_watch_config should add diff watch to an existing config"
}
