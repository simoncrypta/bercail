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

# A wt whose config check reads FILE as valid, or as failing to parse when it
# holds $1 (worktrunk's own TOML parser stands behind this in the live test).
fake_wt_parses() {
  printf '#!/bin/sh\n[ -z "%s" ] || ! grep -qF -- "%s" "$2" || { echo "User config @ $2 failed to parse, skipping" >&2; exit 1; }\n' "$1" "$1" \
    >"$BATS_TEST_TMPDIR/bin/wt"
  chmod +x "$BATS_TEST_TMPDIR/bin/wt"
}

@test "update names spaces with sanitize and keeps state out of the copy, in a kept bercail config only" {
  fake_wt_parses ""
  mkdir -p "$WORKTRUNK_CONFIG_DIR"
  cat >"$WORKTRUNK_CONFIG_DIR/config.toml" <<'TOML'
[pre-start]
copy-ignored = "wt step copy-ignored"

[post-start]
herdr = """
S="{{ branch | capitalize }}_{{ repo | capitalize }}"
source "$HOME/.config/worktrunk/herdr-layout.sh"
"""
TOML

  deploy_configs >"$deploy_log"
  local cfg="$WORKTRUNK_CONFIG_DIR/config.toml" once
  # shellcheck disable=SC2016 # the hook's own "$S"
  grep -Fxq 'S="{{ branch | sanitize | capitalize }}_{{ repo | capitalize }}"' "$cfg" \
    || fail "the space name should sanitize the branch: $(cat "$cfg")"
  grep -Fxq '[step.copy-ignored]' "$cfg" && grep -Fxq 'exclude = [".beads/*", ".bercail/*"]' "$cfg" \
    || fail "the copy should leave out the beads store and .bercail: $(cat "$cfg")"
  grep -q "worktrunk" "$deploy_log" || fail "update did not report it: $(cat "$deploy_log")"
  once="$(checksum "$cfg")"
  deploy_configs >"$deploy_log"
  assert_eq "$once" "$(checksum "$cfg")" "a second update must change nothing"
}

@test "update leaves a kept bercail config alone when it already mentions copy-ignored, however written" {
  local form cfg="$WORKTRUNK_CONFIG_DIR/config.toml"
  mkdir -p "$WORKTRUNK_CONFIG_DIR"
  for form in '[step.copy-ignored]  # mine
exclude = [".cache/"]' '[ step . "copy-ignored" ]
exclude = [".cache/"]' "[step.'copy-ignored']
exclude = [\".cache/\"]" '# copy-ignored.exclude is set in dotfiles' 'step.copy-ignored.exclude = [".cache/"]' '[step]
copy-ignored = { exclude = [".cache/"] }'; do
    printf '%s\n\n[post-start]\nherdr = """\nsource "$HOME/.config/worktrunk/herdr-layout.sh"\n"""\n' "$form" >"$cfg"
    deploy_configs >"$deploy_log"
    [[ "$(grep -c 'copy-ignored' "$cfg")" -eq 1 ]] || fail "a second copy-ignored setting makes the file invalid: $(cat "$cfg")"
    grep -q 'add ".beads/\*" and ".bercail/\*"' "$deploy_log" || fail "say what to add: $(cat "$deploy_log")"
  done
}

@test "update leaves a kept bercail config alone when wt could not read it with the new table" {
  local cfg="$WORKTRUNK_CONFIG_DIR/config.toml" before
  fake_wt_parses "[step.copy-ignored]"
  mkdir -p "$WORKTRUNK_CONFIG_DIR"
  printf 'step = {}\n\n[pre-start]\ncopy-ignored = "wt step copy-ignored"\n\n[post-start]\nherdr = """\nsource "$HOME/.config/worktrunk/herdr-layout.sh"\n"""\n' >"$cfg"
  before="$(checksum "$cfg")"
  deploy_configs >"$deploy_log"
  assert_eq "$before" "$(checksum "$cfg")" "a table wt cannot read must not be appended"
  grep -q 'could not check that wt reads' "$deploy_log" || fail "say why: $(cat "$deploy_log")"
}
