#!/usr/bin/env bash
# Isolated mise / omarchy-pkg install tests. Never invoke a real herdr or mise.
# shellcheck shell=bash
set -euo pipefail

# ~/.bashrc exports BASH_ENV=~/.bash_env, which runs `mise activate`. A mock
# `mise` with a bash shebang then recurses until fork fails and Herdr dies.
unset BASH_ENV
export __MISE_BASH_ENV_LOADED=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp/home"
export OMARCHY_PATH=""
mkdir -p "$HOME"

# shellcheck source=lib/detect.sh
source "$ROOT/lib/detect.sh"
# shellcheck source=lib/deps.sh
source "$ROOT/lib/deps.sh"

info() { :; }
warn() { printf '%s\n' "$*" >&2; }
has_brew() { return 1; }
run() { "$@"; }
export DRY_RUN=0

pass=0
fail=0

ok() { printf 'ok - %s\n' "$1"; pass=$((pass + 1)); }
not_ok() { printf 'not ok - %s\n' "$1" >&2; fail=$((fail + 1)); }

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
    unset BASH_ENV
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

test_mise_allowlist() {
  local rc
  (
    has_mise() { return 0; }
    mise_can_install herdr
  ) && rc=0 || rc=$?
  assert_eq "0" "$rc" "mise_can_install allows herdr"
  (
    has_mise() { return 0; }
    mise_can_install jq
  ) && rc=0 || rc=$?
  assert_eq "0" "$rc" "mise_can_install allows jq"
  (
    has_mise() { return 0; }
    mise_can_install "npm:@xai-official/grok"
  ) && rc=0 || rc=$?
  assert_eq "0" "$rc" "mise_can_install allows grok npm spec"
  (
    has_mise() { return 0; }
    mise_can_install pi
  ) && rc=0 || rc=$?
  assert_eq "0" "$rc" "mise_can_install allows pi"
  (
    has_mise() { return 0; }
    mise_can_install hunk
  ) && rc=0 || rc=$?
  assert_eq "0" "$rc" "mise_can_install allows hunk"
  (
    has_mise() { return 0; }
    mise_can_install github:agavra/tuicr
  ) && rc=0 || rc=$?
  assert_eq "0" "$rc" "mise_can_install allows tuicr github spec"
  (
    has_mise() { return 0; }
    mise_can_install git
  ) && rc=0 || rc=$?
  assert_eq "1" "$rc" "mise_can_install skips git (no registry probe)"
}

test_maybe_mise_install_jq() {
  local case_dir="$tmp/dep-mise" rc
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
  assert_eq "0" "$rc" "install_dep installs jq via mise"
  assert_contains "$(<"$case_dir/mise.log")" "use -g jq" "install_dep calls mise use -g jq"
  assert_eq "" "$(<"$case_dir/omarchy.log")" "mise-first install_dep skips omarchy pkg"
}

test_omarchy_pkg_add_when_mise_cannot() {
  local case_dir="$tmp/omarchy-pkg" rc
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

test_install_grok_via_mise() {
  local case_dir="$tmp/grok-mise" rc
  mkdir -p "$case_dir/bin" "$case_dir/home/.local/bin"
  isolated_sys "$case_dir/sys"
  : >"$case_dir/mise.log"
  cat >"$case_dir/bin/mise" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$MISE_CALL_LOG"
if [ "$1" = "use" ] && [ "$2" = "-g" ] && [ "$3" = "npm:@xai-official/grok" ]; then
  printf '%s\n' '#!/bin/sh' 'exit 0' >"$HOME/.local/bin/grok"
  chmod +x "$HOME/.local/bin/grok"
  exit 0
fi
exit 1
EOF
  chmod +x "$case_dir/bin/mise"

  if with_isolated_path "$case_dir" install_grok_binary; then rc=0; else rc=$?; fi
  assert_eq "0" "$rc" "grok installs via mise npm spec"
  assert_contains "$(<"$case_dir/mise.log")" "use -g npm:@xai-official/grok" \
    "grok uses Omarchy's npm:@xai-official/grok mise package"
}

test_maybe_mise_install_herdr_binary_only() {
  local case_dir="$tmp/mise-herdr" rc
  mkdir -p "$case_dir/bin" "$case_dir/home/.local/bin"
  isolated_sys "$case_dir/sys"
  : >"$case_dir/mise.log"
  cat >"$case_dir/bin/mise" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$MISE_CALL_LOG"
if [ "$1" = "use" ] && [ "$2" = "-g" ] && [ "$3" = "herdr" ]; then
  printf '%s\n' '#!/bin/sh' 'exit 0' >"$HOME/.local/bin/herdr"
  chmod +x "$HOME/.local/bin/herdr"
  exit 0
fi
exit 1
EOF
  chmod +x "$case_dir/bin/mise"

  if with_isolated_path "$case_dir" maybe_mise_install herdr herdr; then rc=0; else rc=$?; fi
  assert_eq "0" "$rc" "maybe_mise_install herdr uses mise use -g"
  assert_contains "$(<"$case_dir/mise.log")" "use -g herdr" \
    "maybe_mise_install calls mise use -g herdr"
}

test_herdr_integration_mapping() {
  assert_eq "cursor" "$(herdr_integration_for_agent agent)" "agent maps to cursor integration"
  assert_eq "cursor" "$(herdr_integration_for_agent cursor-agent)" "cursor-agent maps to cursor"
  assert_eq "grok" "$(herdr_integration_for_agent grok)" "grok maps to grok integration"
  assert_eq "pi" "$(herdr_integration_for_agent pi)" "pi maps to pi integration"
  if herdr_integration_for_agent custom-bot >/dev/null; then
    not_ok "unknown agent should not map to an integration"
  else
    ok "unknown agent does not map to an integration"
  fi
}

test_ensure_herdr_agent_integration_installs_cursor() {
  local case_dir="$tmp/herdr-integration" rc
  mkdir -p "$case_dir/bin" "$case_dir/home"
  : >"$case_dir/herdr.log"
  cat >"$case_dir/bin/herdr" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$HERDR_CALL_LOG"
exit 0
EOF
  chmod +x "$case_dir/bin/herdr"
  read_agent_command() { printf 'agent'; }

  if HOME="$case_dir/home" PATH="$case_dir/bin:/usr/bin:/bin" \
    HERDR_CALL_LOG="$case_dir/herdr.log" ensure_herdr_agent_integration; then
    rc=0
  else
    rc=$?
  fi
  unset -f read_agent_command
  assert_eq "0" "$rc" "ensure_herdr_agent_integration installs for agent"
  assert_contains "$(<"$case_dir/herdr.log")" "integration install cursor" \
    "ensure_herdr_agent_integration installs cursor for agent command"
  [[ -d "$case_dir/home/.cursor" ]] \
    || { not_ok "ensure_herdr_agent_integration creates ~/.cursor"; return; }
  ok "ensure_herdr_agent_integration creates ~/.cursor"
}

test_outdated_brew_herdr_upgrades_via_mise() {
  local case_dir="$tmp/brew-to-mise" rc
  mkdir -p "$case_dir/homebrew/bin" "$case_dir/bin" \
    "$case_dir/home/.local/share/mise/shims" "$case_dir/home/.local/bin"
  isolated_sys "$case_dir/sys"
  : >"$case_dir/mise.log"
  cat >"$case_dir/homebrew/bin/herdr" <<'EOF'
#!/usr/bin/env bash
printf 'herdr 0.7.1\n'
EOF
  cat >"$case_dir/bin/mise" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$MISE_CALL_LOG"
if [ "$1" = "use" ] && [ "$2" = "-g" ] && [ "$3" = "herdr" ]; then
  printf '%s\n' '#!/bin/sh' 'printf "herdr 0.9.0\n"' \
    >"$HOME/.local/share/mise/shims/herdr"
  chmod +x "$HOME/.local/share/mise/shims/herdr"
  exit 0
fi
exit 1
EOF
  chmod +x "$case_dir/homebrew/bin/herdr" "$case_dir/bin/mise"

  if (
    unset BASH_ENV
    export HOME="$case_dir/home"
    export PATH="$case_dir/homebrew/bin:$case_dir/bin:$case_dir/sys"
    export MISE_CALL_LOG="$case_dir/mise.log"
    case "$(command -v mise)" in
      "$case_dir"/bin/mise) ;;
      *)
        printf 'refusing to run: mise resolved to %s\n' "$(command -v mise)" >&2
        exit 90
        ;;
    esac
    install_herdr_binary
  ); then
    rc=0
  else
    rc=$?
  fi
  assert_eq "0" "$rc" "outdated brew Herdr is upgraded via mise"
  assert_contains "$(<"$case_dir/mise.log")" "use -g herdr" \
    "outdated brew Herdr calls mise use -g herdr"
}

test_ensure_mise_shims_beats_brew() {
  local case_dir="$tmp/shim-order" got
  mkdir -p "$case_dir/home/.local/share/mise/shims" \
    "$case_dir/home/.local/bin" "$case_dir/homebrew/bin"
  got="$(
    HOME="$case_dir/home" PATH="$case_dir/homebrew/bin:/usr/bin"
    ensure_mise_shims
    printf '%s' "$PATH"
  )"
  case "$got" in
    "$case_dir/home/.local/share/mise/shims":*)
      ok "ensure_mise_shims puts mise shims ahead of brew"
      ;;
    *)
      not_ok "ensure_mise_shims puts mise shims ahead of brew (got $got)"
      ;;
  esac
}

test_maybe_mise_install_dry_run_without_binary() {
  local case_dir="$tmp/mise-dry" rc
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
    unset BASH_ENV
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

test_marker_block_prefers_mise_path() {
  local content brew_pos mise_pos
  # shellcheck source=lib/common.sh
  source "$ROOT/lib/common.sh"
  # shellcheck source=lib/shell-rc.sh
  source "$ROOT/lib/shell-rc.sh"
  brew_shellenv_snippet() { printf '%s\n' 'eval "$(/opt/homebrew/bin/brew shellenv)"'; }
  content="$(marker_block_content bash)"
  assert_contains "$content" '.local/share/mise/shims' \
    "shell marker puts mise shims on PATH"
  assert_contains "$content" 'brew shellenv' \
    "shell marker keeps brew shellenv as a fallback"
  brew_pos="${content%%brew shellenv*}"
  mise_pos="${content%%mise/shims*}"
  if ((${#brew_pos} < ${#mise_pos})); then
    ok "shell marker evals brew shellenv before prepending mise shims"
  else
    not_ok "shell marker evals brew shellenv before prepending mise shims"
  fi
}

test_mise_allowlist
test_maybe_mise_install_jq
test_omarchy_pkg_add_when_mise_cannot
test_install_grok_via_mise
test_maybe_mise_install_herdr_binary_only
test_herdr_integration_mapping
test_ensure_herdr_agent_integration_installs_cursor
test_outdated_brew_herdr_upgrades_via_mise
test_ensure_mise_shims_beats_brew
test_maybe_mise_install_dry_run_without_binary
test_marker_block_prefers_mise_path

printf '%s passed, %s failed\n' "$pass" "$fail"
((fail == 0))
