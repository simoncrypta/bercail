#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

unset BASH_ENV
export __MISE_BASH_ENV_LOADED=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() {
  local expected="$1" actual="$2" msg="${3:-}"
  [[ "$expected" == "$actual" ]] || fail "${msg}: expected '$expected' got '$actual'"
}
assert_contains() {
  local haystack="$1" needle="$2" msg="${3:-}"
  [[ "$haystack" == *"$needle"* ]] || fail "${msg}: missing '$needle' in '$haystack'"
}

export HOME="$TMP_DIR/home"
export XDG_CONFIG_HOME="$HOME/.config"
mkdir -p "$HOME" "$XDG_CONFIG_HOME"

# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=lib/detect.sh
source "$ROOT/lib/detect.sh"
# shellcheck source=lib/deps.sh
source "$ROOT/lib/deps.sh"
# shellcheck source=lib/config.sh
source "$ROOT/lib/config.sh"

export INSTALL_SRC="$ROOT"
export AGENTIC_DEV_CONFIG_DIR="$XDG_CONFIG_HOME/agentic-dev"
export AGENTIC_DEV_USER_CONFIG="$AGENTIC_DEV_CONFIG_DIR/config.toml"
unset EDITOR
YES=1
DRY_RUN=0

info() { :; }
warn() { printf '%s\n' "$*" >&2; }

saved_shell="${SHELL:-}"
SHELL=/bin/zsh
assert_eq "zsh" "$(detect_shell_name)" "detect_shell_name follows zsh \$SHELL"
assert_eq "${HOME}/.zshrc" "$(shell_rc_for zsh)" "zsh rc is ~/.zshrc"
SHELL=/bin/bash
assert_eq "bash" "$(detect_shell_name)" "detect_shell_name follows bash \$SHELL"
assert_eq "${HOME}/.bashrc" "$(shell_rc_for bash)" "bash rc is ~/.bashrc"
SHELL="$saved_shell"

assert_contains "$(default_user_config)" 'command = "cursor-agent"' \
  "default config uses cursor-agent"
grep -q 'Choice \[1-7\]' "$ROOT/lib/config.sh" \
  && fail "install must not prompt for an agent picker"

YES=1
prompt_user_config
assert_eq "cursor-agent" "$(read_agent_command)" "prompt_user_config writes cursor-agent with no picker"
YES=0

declare -F pstack_plugin_present >/dev/null \
  && fail "pstack detection is gone; Shep owns the workflow, not a cursor plugin"
assert_contains "$(default_user_config)" 'review = "tuicr"' \
  "default config includes review"
assert_contains "$(default_user_config)" 'auto_review = true' \
  "default config enables auto_review"
[[ "$(default_user_config)" != *'editor = "fresh"'* ]] \
  || fail "default config must not pin fresh as the editor"

mkdir -p "$AGENTIC_DEV_CONFIG_DIR"
cp "$ROOT/config/agentic-dev/config-reader.sh" "$AGENTIC_DEV_CONFIG_DIR/config-reader.sh"

assert_eq "cursor-agent" "$(read_agent_command)" "agent defaults to cursor-agent"
assert_eq "tuicr" "$(read_layout_review)" "review defaults to tuicr"

write_user_config grok
assert_eq "grok" "$(read_agent_command)" "write_user_config stores agent"
assert_eq "tuicr" "$(read_layout_review)" "write_user_config stores review"
grep -q 'auto_review = true' "$AGENTIC_DEV_USER_CONFIG" \
  || fail "write_user_config should enable auto_review"
grep -q 'editor =' "$AGENTIC_DEV_USER_CONFIG" \
  && fail "write_user_config has no editor setting"

write_user_config agent
migrate_cursor_cli_command
assert_eq "cursor-agent" "$(read_agent_command)" "migrates agent command to cursor-agent"

case_dir="$TMP_DIR/doctor-hunk"
mkdir -p "$case_dir/bin" "$case_dir/home/.config/agentic-dev"
cat >"$case_dir/home/.config/agentic-dev/config.toml" <<'EOF'
[agent]
command = "agent"

[layout]
review = "hunk"
EOF
cp "$ROOT/config/agentic-dev/config-reader.sh" \
  "$case_dir/home/.config/agentic-dev/config-reader.sh"
for cmd in herdr-app hc git wt bd fzf jq hunk; do
  ln -s /bin/true "$case_dir/bin/$cmd"
done

output="$(
  HOME="$case_dir/home" \
    XDG_CONFIG_HOME="$case_dir/home/.config" \
    AGENTIC_DEV_CONFIG_DIR="$case_dir/home/.config/agentic-dev" \
    AGENTIC_DEV_USER_CONFIG="$case_dir/home/.config/agentic-dev/config.toml" \
    PATH="$case_dir/bin:/usr/bin:/bin" \
    doctor_dependencies 2>&1
)" || rc=$?
rc="${rc:-0}"
assert_eq "0" "$rc" "doctor exits 0 for hunk review"
assert_contains "$output" "ok  hunk" "doctor accepts configured hunk"
assert_contains "$output" "ok  herdr-app" "doctor checks the Herdr app"
assert_contains "$output" "ok  hc" "doctor checks herdr-core"
[[ "$output" != *"missing  tuicr"* ]] || fail "doctor should not require tuicr when review is hunk"
[[ "$output" != *"lazygit"* ]] || fail "doctor no longer needs lazygit"

cat >"$AGENTIC_DEV_USER_CONFIG" <<'EOF'
[layout]
review = "hunk diff"
auto_review = false
EOF
migrate_hunk_review_to_tuicr
assert_eq "tuicr" "$(read_layout_review)" "migrate_hunk_review_to_tuicr rewrites hunk diff"
grep -q 'review = "tuicr"' "$AGENTIC_DEV_USER_CONFIG" \
  || fail "migrate_hunk_review_to_tuicr writes review = tuicr"

mkdir -p "$XDG_CONFIG_HOME/tuicr"
printf 'theme = "dark"\n' >"$XDG_CONFIG_HOME/tuicr/config.toml"
ensure_tuicr_watch_config
grep -q 'theme = "dark"' "$XDG_CONFIG_HOME/tuicr/config.toml" \
  || fail "ensure_tuicr_watch_config must keep an existing theme"
grep -q 'diff_watch_interval_ms = 1000' "$XDG_CONFIG_HOME/tuicr/config.toml" \
  || fail "ensure_tuicr_watch_config should add diff watch to an existing config"

printf 'PASS: layout config, write, migration, and doctor follow the review command\n'
