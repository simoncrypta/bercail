#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$TEST_DIR/.." && pwd)"
TMP_DIR="$(mktemp -d)"
FAKE_BIN="$TMP_DIR/bin"

cleanup() {
  rm -rf "$TMP_DIR"
  printf 'CLEANUP PASS: removed isolated HOME/XDG fixture: %s\n' "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  local expected="$1" actual="$2" message="$3"
  [[ "$actual" == "$expected" ]] || fail "$message (expected=$expected actual=$actual)"
}

checksum() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d ' ' -f 1
  else
    shasum -a 256 "$1" | cut -d ' ' -f 1
  fi
}

reset_fixture() {
  rm -rf "$HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME"
  mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME"
}

mkdir -p "$FAKE_BIN"

export HOME="$TMP_DIR/home"
export XDG_CONFIG_HOME="$TMP_DIR/xdg-config"
export XDG_STATE_HOME="$TMP_DIR/xdg-state"
export PATH="$FAKE_BIN:$PATH"
export INSTALL_SRC="$ROOT"

# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=lib/deps.sh
source "$ROOT/lib/deps.sh"
# shellcheck source=lib/config.sh
source "$ROOT/lib/config.sh"
# shellcheck source=lib/skills.sh
source "$ROOT/lib/skills.sh"

export HERDR_APP_CONFIG_DIR="$XDG_CONFIG_HOME/herdr-app"
export AGENTIC_DEV_CONFIG_DIR="$XDG_CONFIG_HOME/agentic-dev"
export AGENTIC_DEV_SHELL_DIR="$AGENTIC_DEV_CONFIG_DIR/shell"
export AGENTIC_DEV_USER_CONFIG="$AGENTIC_DEV_CONFIG_DIR/config.toml"
export WORKTRUNK_CONFIG_DIR="$XDG_CONFIG_HOME/worktrunk"
export FCITX5_CONFIG_DIR="$XDG_CONFIG_HOME/fcitx5"
export LOCAL_BIN="$HOME/.local/bin"
export YES=1
export DRY_RUN=0
export FORCE=0

seed_existing_worktrunk_config() {
  mkdir -p "$WORKTRUNK_CONFIG_DIR"
  cat >"$WORKTRUNK_CONFIG_DIR/config.toml" <<'EOF'
# user-customized worktrunk config - must survive install/update
[pre-start]
custom = "echo custom-user-hook"
EOF
}

test_existing_worktrunk_config_preserved_across_install_and_update() {
  local before deploy_log="$TMP_DIR/deploy.output"
  reset_fixture
  seed_existing_worktrunk_config
  before="$(checksum "$WORKTRUNK_CONFIG_DIR/config.toml")"

  deploy_configs >"$deploy_log"
  assert_eq "$before" "$(checksum "$WORKTRUNK_CONFIG_DIR/config.toml")" \
    "install changed the existing worktrunk config"
  grep -q "keeping existing worktrunk config: $WORKTRUNK_CONFIG_DIR/config.toml" "$deploy_log" \
    || fail "install did not report keeping the existing worktrunk config"
  [[ -x "$WORKTRUNK_CONFIG_DIR/herdr-layout.sh" ]] \
    || fail "worktrunk herdr-layout.sh hook helper was not deployed executable"

  : >"$deploy_log"
  deploy_configs >"$deploy_log"
  assert_eq "$before" "$(checksum "$WORKTRUNK_CONFIG_DIR/config.toml")" \
    "update changed the existing worktrunk config"
  grep -q "keeping existing worktrunk config: $WORKTRUNK_CONFIG_DIR/config.toml" "$deploy_log" \
    || fail "update did not report keeping the existing worktrunk config"
  printf 'PASS: existing worktrunk config checksum is unchanged across install and update\n'
}

test_worktrunk_session_label_migrated_on_update() {
  local deploy_log="$TMP_DIR/deploy-migrate.output"
  reset_fixture
  mkdir -p "$WORKTRUNK_CONFIG_DIR"
  cat >"$WORKTRUNK_CONFIG_DIR/config.toml" <<'EOF'
# user-customized worktrunk config - must survive install/update
[post-start]
herdr = """
S="{{ repo | capitalize }}_{{ branch | capitalize }}"
W="{{ worktree_path }}"
custom = "echo keep-me"
"""

[post-remove]
herdr = """
S="{{ repo | capitalize }}_{{ branch | capitalize }}"
"""
EOF

  deploy_configs >"$deploy_log"
  grep -Fq 'S="{{ branch | capitalize }}_{{ repo | capitalize }}"' "$WORKTRUNK_CONFIG_DIR/config.toml" \
    || fail "did not migrate session labels to Branch_Repo"
  grep -Fq 'S="{{ repo | capitalize }}_{{ branch | capitalize }}"' "$WORKTRUNK_CONFIG_DIR/config.toml" \
    && fail "old Repo_Branch session labels still present"
  grep -q 'custom = "echo keep-me"' "$WORKTRUNK_CONFIG_DIR/config.toml" \
    || fail "migrated config lost user customizations"
  grep -q "migrated worktrunk session labels to Branch_Repo" "$deploy_log" \
    || fail "did not report session label migration"
  grep -q "keeping existing worktrunk config: $WORKTRUNK_CONFIG_DIR/config.toml" "$deploy_log" \
    || fail "update did not report keeping the existing worktrunk config"
  printf 'PASS: existing worktrunk S= templates migrate Repo_Branch to Branch_Repo\n'
}

test_worktrunk_post_start_unsets_handoff_prompt() {
  local deploy_log="$TMP_DIR/deploy-unset-prompt.output"
  reset_fixture
  mkdir -p "$WORKTRUNK_CONFIG_DIR"
  cat >"$WORKTRUNK_CONFIG_DIR/config.toml" <<'EOF'
[post-start]
herdr = """
S="{{ branch | capitalize }}_{{ repo | capitalize }}"
W="{{ worktree_path }}"
source "$HOME/.config/worktrunk/herdr-layout.sh"
wt_herdr_layout_create "$S" "$W"
"""
EOF

  deploy_configs >"$deploy_log"
  grep -q 'unset WT_HERDR_AGENT_PROMPT' "$WORKTRUNK_CONFIG_DIR/config.toml" \
    || fail "did not migrate unset WT_HERDR_AGENT_PROMPT into post-start"
  grep -q "migrated worktrunk post-start to unset WT_HERDR_AGENT_PROMPT" "$deploy_log" \
    || fail "did not report handoff prompt isolation migration"
  printf 'PASS: existing worktrunk post-start unsets WT_HERDR_AGENT_PROMPT\n'
}

test_worktrunk_layout_echo_migrated_on_update() {
  local deploy_log="$TMP_DIR/deploy-layout-echo.output"
  reset_fixture
  mkdir -p "$WORKTRUNK_CONFIG_DIR"
  cat >"$WORKTRUNK_CONFIG_DIR/config.toml" <<'EOF'
[post-start]
herdr = """
S="{{ branch | capitalize }}_{{ repo | capitalize }}"
source "$HOME/.config/worktrunk/herdr-layout.sh"
unset WT_HERDR_AGENT_PROMPT
wt_herdr_layout_create "$S" "$W"
echo "  Layout: agent pane (left, sticky) | tabs: review, explorer, terminal"
echo "  Switch tabs: Alt+1..3 (review/explorer/terminal), prefix+1 focuses agent, prefix+2..4 same tabs"
"""
EOF

  deploy_configs >"$deploy_log"
  grep -Eq 'tabs: review, explorer, terminal|prefix\+' "$WORKTRUNK_CONFIG_DIR/config.toml" \
    && fail "old layout echo still present"
  grep -Fq 'Desk: Ctrl+Shift+A agent' "$WORKTRUNK_CONFIG_DIR/config.toml" \
    || fail "did not migrate post-start layout echo"
  [[ "$(grep -c '^echo' "$WORKTRUNK_CONFIG_DIR/config.toml")" == 2 ]] \
    || fail "the new echo is written once: $(cat "$WORKTRUNK_CONFIG_DIR/config.toml")"
  grep -q "migrated worktrunk post-start echo" "$deploy_log" \
    || fail "did not report layout echo migration"
  printf 'PASS: existing worktrunk post-start echo migrates to the Herdr app keys\n'
}

test_existing_worktrunk_config_preserved_across_install_and_update
test_worktrunk_session_label_migrated_on_update
test_worktrunk_post_start_unsets_handoff_prompt
test_worktrunk_layout_echo_migrated_on_update
printf 'ALL PASS: worktrunk integration fixture matrix\n'
