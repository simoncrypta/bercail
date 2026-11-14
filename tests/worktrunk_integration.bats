#!/usr/bin/env bats
# deploy_configs keeps a person's worktrunk config as it is.

setup() {
  load test_helper
  isolate
  mkdir -p "$BATS_TEST_TMPDIR/bin" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  # deploy_configs also deploys bstack and the desk restore hook, which call
  # these; the real pi would npm-install its bridge (~470 MB) into HOME, and on
  # Omarchy the real omarchy-hook-install acts on the desktop. These tests are
  # about worktrunk.
  local tool
  for tool in pi claude opencode herdr-app omarchy-hook-install; do
    printf '#!/bin/sh
exit 0
' >"$BATS_TEST_TMPDIR/bin/$tool"
    chmod +x "$BATS_TEST_TMPDIR/bin/$tool"
  done
  export INSTALL_SRC="$ROOT"

  # Every lib deploy_configs calls into, as bin/bercail loads them.
  local lib
  for lib in common detect deps config skills omarchy notify bstack desk shep; do
    # shellcheck source=/dev/null
    source "$ROOT/lib/$lib.sh"
  done

  export HERDR_APP_CONFIG_DIR="$XDG_CONFIG_HOME/herdr-app"
  export BERCAIL_CONFIG_DIR="$XDG_CONFIG_HOME/bercail"
  export BERCAIL_SHELL_DIR="$BERCAIL_CONFIG_DIR/shell"
  export BERCAIL_USER_CONFIG="$BERCAIL_CONFIG_DIR/config.toml"
  export WORKTRUNK_CONFIG_DIR="$XDG_CONFIG_HOME/worktrunk"
  export LOCAL_BIN="$HOME/.local/bin"
  export YES=1
  export DRY_RUN=0
  export FORCE=0
  deploy_log="$BATS_TEST_TMPDIR/deploy.output"
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

seed_existing_worktrunk_config() {
  mkdir -p "$WORKTRUNK_CONFIG_DIR"
  cat >"$WORKTRUNK_CONFIG_DIR/config.toml" <<'EOF'
# user-customized worktrunk config - must survive install/update
[pre-start]
custom = "echo custom-user-hook"
EOF
}

@test "existing worktrunk config checksum is unchanged across install and update" {
  local before
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
}

@test "update migrates a label-only post-remove close to pass the worktree path" {
  mkdir -p "$WORKTRUNK_CONFIG_DIR"
  cat >"$WORKTRUNK_CONFIG_DIR/config.toml" <<'TOML'
[post-remove]
herdr = """
S="{{ branch | capitalize }}_{{ repo | capitalize }}"
source "$HOME/.config/worktrunk/herdr-layout.sh"
wt_herdr_layout_close "$S"
"""
TOML

  deploy_configs >"$deploy_log"
  # shellcheck disable=SC2016 # the hook's own "$S"
  grep -Fxq 'wt_herdr_layout_close "$S" "{{ worktree_path }}"' "$WORKTRUNK_CONFIG_DIR/config.toml" \
    || fail "post-remove should pass the worktree path: $(cat "$WORKTRUNK_CONFIG_DIR/config.toml")"
  # shellcheck disable=SC2016
  if grep -Fxq 'wt_herdr_layout_close "$S"' "$WORKTRUNK_CONFIG_DIR/config.toml"; then
    fail "the label-only close is still there"
  fi
  grep -q "migrated worktrunk post-remove to close by worktree path" "$deploy_log" \
    || fail "update did not report the migration: $(cat "$deploy_log")"
}
