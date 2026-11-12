#!/usr/bin/env bats
# Isolated mise / omarchy-pkg install tests. Never invoke a real herdr or mise.

# shellcheck disable=SC2016 # single-quoted text is literal stub and installer code.
# shellcheck disable=SC2030,SC2031 # env set in a subshell stays there on purpose; helpers set out and rc.
# shellcheck disable=SC2329 # stubs replace lib functions the libs call.

setup() {
  load test_helper
  isolate
  export OMARCHY_PATH=""
  # shellcheck source=/dev/null
  source "$ROOT/lib/detect.sh"
  # shellcheck source=/dev/null
  source "$ROOT/lib/deps.sh"

  info() { :; }
  warn() { printf '%s\n' "$*" >&2; }
  has_brew() { return 1; }
  run() { "$@"; }
  export DRY_RUN=0
}

assert_eq() {
  local expected="$1" actual="$2" label="$3"
  [[ "$actual" == "$expected" ]] || fail "$label (expected '$expected', got '$actual')"
}

assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  [[ "$haystack" == *"$needle"* ]] || fail "$label (missing '$needle')"
}

isolated_sys() {
  local dest="$1" cmd
  mkdir -p "$dest"
  for cmd in bash cat chmod mkdir mktemp rm mv cp ln true false env sleep kill; do
    if [[ -x "/usr/bin/$cmd" ]]; then
      ln -s "/usr/bin/$cmd" "$dest/$cmd"
    elif [[ -x "/bin/$cmd" ]]; then
      ln -s "/bin/$cmd" "$dest/$cmd"
    fi
  done
}

with_isolated_path() {
  local case_dir="$1"
  shift
  (
    export HOME="$case_dir/home"
    export PATH="$case_dir/home/.local/bin:$case_dir/bin:$case_dir/sys"
    export MISE_CALL_LOG="$case_dir/mise.log"
    export OMARCHY_CALL_LOG="${case_dir}/omarchy.log"
    case "$(command -v mise)" in
      "$case_dir"/bin/mise) ;;
      *)
        printf 'refusing to run: mise resolved to %s\n' "$(command -v mise)" >&2
        exit 90
        ;;
    esac
    if command -v herdr >/dev/null 2>&1; then
      printf 'refusing to run: herdr is visible on isolated PATH\n' >&2
      exit 91
    fi
    "$@"
  )
}

# mise_can_install's exit status for $1 with mise present.
mise_can_install_rc() {
  local rc
  (
    has_mise() { return 0; }
    mise_can_install "$1"
  ) && rc=0 || rc=$?
  printf '%s' "$rc"
}

# install_dep jq with a mise that installs jq and an omarchy that must not run.
# Sets case_dir and rc.
install_jq_via_mise() {
  case_dir="$BATS_TEST_TMPDIR/dep-mise"
  mkdir -p "$case_dir/bin" "$case_dir/home/.local/bin"
  isolated_sys "$case_dir/sys"
  : >"$case_dir/mise.log"
  : >"$case_dir/omarchy.log"
  cat >"$case_dir/bin/mise" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$MISE_CALL_LOG"
if [ "$1" = "use" ] && [ "$2" = "-g" ] && [ "$3" = "jq" ]; then
  printf '%s\n' '#!/bin/sh' 'exit 0' >"$HOME/.local/bin/jq"
  chmod +x "$HOME/.local/bin/jq"
  exit 0
fi
exit 1
EOF
  cat >"$case_dir/bin/omarchy" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$OMARCHY_CALL_LOG"
exit 99
EOF
  chmod +x "$case_dir/bin/mise" "$case_dir/bin/omarchy"

  if with_isolated_path "$case_dir" install_dep jq; then rc=0; else rc=$?; fi
}

# The bash marker block, with a brew shellenv line available.
marker_block() {
  # shellcheck source=/dev/null
  source "$ROOT/lib/common.sh"
  # shellcheck source=/dev/null
  source "$ROOT/lib/shell-rc.sh"
  brew_shellenv_snippet() { printf '%s\n' 'eval "$(/opt/homebrew/bin/brew shellenv)"'; }
  content="$(marker_block_content bash)"
}

@test "mise_can_install skips herdr (the Herdr app comes from herdr.dev)" {
  assert_eq "1" "$(mise_can_install_rc herdr)" "mise_can_install skips herdr (the Herdr app comes from herdr.dev)"
}

@test "mise_can_install allows jq" {
  assert_eq "0" "$(mise_can_install_rc jq)" "mise_can_install allows jq"
}

@test "mise_can_install allows grok npm spec" {
  assert_eq "0" "$(mise_can_install_rc "npm:@xai-official/grok")" "mise_can_install allows grok npm spec"
}

@test "mise_can_install allows pi" {
  assert_eq "0" "$(mise_can_install_rc pi)" "mise_can_install allows pi"
}

@test "mise_can_install allows tuicr github spec" {
  assert_eq "0" "$(mise_can_install_rc github:agavra/tuicr)" "mise_can_install allows tuicr github spec"
}

@test "mise_can_install skips git (no registry probe)" {
  assert_eq "1" "$(mise_can_install_rc git)" "mise_can_install skips git (no registry probe)"
}

@test "install_dep installs jq via mise use -g jq" {
  install_jq_via_mise
  assert_eq "0" "$rc" "install_dep installs jq via mise"
  assert_contains "$(<"$case_dir/mise.log")" "use -g jq" "install_dep calls mise use -g jq"
}

@test "mise-first install_dep skips omarchy pkg" {
  install_jq_via_mise
  assert_eq "" "$(<"$case_dir/omarchy.log")" "mise-first install_dep skips omarchy pkg"
}

@test "Omarchy installs git via omarchy pkg add when mise cannot" {
  local case_dir="$BATS_TEST_TMPDIR/omarchy-pkg" rc
  mkdir -p "$case_dir/bin" "$case_dir/home/.local/share/omarchy" "$case_dir/home/.local/bin"
  isolated_sys "$case_dir/sys"
  : >"$case_dir/mise.log"
  : >"$case_dir/omarchy.log"
  cat >"$case_dir/bin/mise" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$MISE_CALL_LOG"
exit 1
EOF
  cat >"$case_dir/bin/omarchy" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$OMARCHY_CALL_LOG"
if [ "$1" = "pkg" ] && [ "$2" = "add" ] && [ "$3" = "git" ]; then
  printf '%s\n' '#!/bin/sh' 'exit 0' >"$HOME/.local/bin/git"
  chmod +x "$HOME/.local/bin/git"
  exit 0
fi
exit 1
EOF
  chmod +x "$case_dir/bin/mise" "$case_dir/bin/omarchy"

  if with_isolated_path "$case_dir" install_dep git; then rc=0; else rc=$?; fi
  assert_eq "0" "$rc" "Omarchy installs git via omarchy pkg add"
  assert_contains "$(<"$case_dir/omarchy.log")" "pkg add git" \
    "Omarchy path calls omarchy pkg add git"
}

@test "ensure_pi installs pi via mise use -g pi" {
  local case_dir="$BATS_TEST_TMPDIR/pi-mise" rc
  mkdir -p "$case_dir/bin" "$case_dir/home/.local/bin"
  isolated_sys "$case_dir/sys"
  : >"$case_dir/mise.log"
  cat >"$case_dir/bin/mise" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$MISE_CALL_LOG"
if [ "$1" = "use" ] && [ "$2" = "-g" ] && [ "$3" = "pi" ]; then
  printf '%s\n' '#!/bin/sh' 'exit 0' >"$HOME/.local/bin/pi"
  chmod +x "$HOME/.local/bin/pi"
  exit 0
fi
exit 1
EOF
  chmod +x "$case_dir/bin/mise"

  if with_isolated_path "$case_dir" ensure_pi; then rc=0; else rc=$?; fi
  assert_eq "0" "$rc" "ensure_pi installs pi via mise"
  assert_contains "$(<"$case_dir/mise.log")" "use -g pi" \
    "ensure_pi calls mise use -g pi"
}

@test "ensure_mise_shims puts mise shims ahead of brew" {
  local case_dir="$BATS_TEST_TMPDIR/shim-order" got
  mkdir -p "$case_dir/home/.local/share/mise/shims" \
    "$case_dir/home/.local/bin" "$case_dir/homebrew/bin"
  got="$(
    HOME="$case_dir/home" PATH="$case_dir/homebrew/bin:/usr/bin"
    ensure_mise_shims
    printf '%s' "$PATH"
  )"
  case "$got" in
    "$case_dir/home/.local/share/mise/shims":*) ;;
    *) fail "ensure_mise_shims puts mise shims ahead of brew (got $got)" ;;
  esac
}

@test "dry-run maybe_mise_install succeeds without invoking mise when the binary is missing" {
  local case_dir="$BATS_TEST_TMPDIR/mise-dry" rc
  mkdir -p "$case_dir/bin" "$case_dir/home/.local/bin"
  isolated_sys "$case_dir/sys"
  : >"$case_dir/mise.log"
  cat >"$case_dir/bin/mise" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$MISE_CALL_LOG"
exit 0
EOF
  chmod +x "$case_dir/bin/mise"

  if (
    export HOME="$case_dir/home"
    export PATH="$case_dir/bin:$case_dir/sys"
    export MISE_CALL_LOG="$case_dir/mise.log"
    export DRY_RUN=1
    maybe_mise_install jq jq
  ); then
    rc=0
  else
    rc=$?
  fi
  assert_eq "0" "$rc" "dry-run maybe_mise_install succeeds when the binary is missing"
  assert_eq "" "$(<"$case_dir/mise.log")" \
    "dry-run maybe_mise_install does not invoke mise"
}

@test "shell marker puts mise shims on PATH" {
  marker_block
  assert_contains "$content" '.local/share/mise/shims' \
    "shell marker puts mise shims on PATH"
}

@test "shell marker keeps brew shellenv as a fallback, evaluated before prepending mise shims" {
  local brew_pos mise_pos
  marker_block
  assert_contains "$content" 'brew shellenv' \
    "shell marker keeps brew shellenv as a fallback"
  brew_pos="${content%%brew shellenv*}"
  mise_pos="${content%%mise/shims*}"
  ((${#brew_pos} < ${#mise_pos})) \
    || fail "shell marker evals brew shellenv before prepending mise shims"
}
