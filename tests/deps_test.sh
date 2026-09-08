#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

unset BASH_ENV
export __MISE_BASH_ENV_LOADED=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/detect.sh disable=SC1091
source "$ROOT/lib/detect.sh"
# shellcheck source=lib/deps.sh disable=SC1091
source "$ROOT/lib/deps.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

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

log() { printf '%s\n' "$*"; }
info() { :; }
warn() { printf '%s\n' "$*" >&2; }
has_brew() { return 1; }
has_mise() { return 1; }
run() { "$@"; }
export DRY_RUN=0

test_installed_herdr_short_circuits_install() {
  local case_dir="$tmp/baseline"
  mkdir -p "$case_dir/bin" "$case_dir/home"
  cat >"$case_dir/bin/herdr" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$HERDR_CALL_LOG"
printf 'herdr 0.9.0\n'
EOF
  chmod +x "$case_dir/bin/herdr"
  : >"$case_dir/calls.log"

  HOME="$case_dir/home" \
    PATH="$case_dir/bin:/usr/bin:/bin" \
    HERDR_CALL_LOG="$case_dir/calls.log" \
    install_herdr_binary

  assert_eq "--version" "$(<"$case_dir/calls.log")" \
    "baseline: an installed qualifying Herdr skips install and update"
}

test_old_updater_managed_herdr_handoffs() {
  local case_dir="$tmp/old-updater" rc
  mkdir -p "$case_dir/home/.local/bin"
  printf '0.7.1\n' >"$case_dir/version"
  : >"$case_dir/calls.log"
  cat >"$case_dir/home/.local/bin/herdr" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$HERDR_CALL_LOG"
if [[ "$*" == "--version" ]]; then
  printf 'herdr %s\n' "$(<"$HERDR_VERSION_FILE")"
elif [[ "$*" == "update --handoff" ]]; then
  printf '0.9.0\n' >"$HERDR_VERSION_FILE"
fi
EOF
  chmod +x "$case_dir/home/.local/bin/herdr"

  if HOME="$case_dir/home" \
    PATH="$case_dir/home/.local/bin:/usr/bin:/bin" \
    HERDR_CALL_LOG="$case_dir/calls.log" \
    HERDR_VERSION_FILE="$case_dir/version" \
    install_herdr_binary; then
    rc=0
  else
    rc=$?
  fi

  assert_eq "0" "$rc" "0.7.1 updater-managed Herdr is repaired"
  if [[ "$(<"$case_dir/calls.log")" == *"update --handoff"* ]]; then
    ok "0.7.1 updater-managed Herdr uses update --handoff"
  else
    not_ok "0.7.1 updater-managed Herdr uses update --handoff"
  fi
}

test_malformed_version_fails_closed() {
  local case_dir="$tmp/malformed" rc
  mkdir -p "$case_dir/bin" "$case_dir/home"
  cat >"$case_dir/bin/herdr" <<'EOF'
#!/usr/bin/env bash
printf 'herdr version unknown\n'
EOF
  chmod +x "$case_dir/bin/herdr"

  if HOME="$case_dir/home" \
    PATH="$case_dir/bin:/usr/bin:/bin" \
    install_herdr_binary >/dev/null 2>&1; then
    rc=0
  else
    rc=$?
  fi

  if ((rc != 0)); then
    ok "malformed Herdr version fails closed"
  else
    not_ok "malformed Herdr version fails closed"
  fi
}

test_version_parser_does_not_expand_globs() {
  local case_dir="$tmp/glob-version" rc
  mkdir -p "$case_dir/0.9.0"
  if (cd "$case_dir" && herdr_parse_version '*') >/dev/null 2>&1; then
    rc=0
  else
    rc=$?
  fi
  assert_eq "2" "$rc" "version parser rejects glob-like malformed output"
}

test_version_comparison_matrix() {
  local rc
  if herdr_version_at_least 0.8.2 "$HERDR_MIN_VERSION"; then rc=0; else rc=$?; fi
  assert_eq "1" "$rc" "comparator: 0.8.2 is below 0.9.0"
  if herdr_version_at_least 0.9.0 "$HERDR_MIN_VERSION"; then rc=0; else rc=$?; fi
  assert_eq "0" "$rc" "comparator: 0.9.0 meets 0.9.0"
  if herdr_version_at_least 0.9.1 "$HERDR_MIN_VERSION"; then rc=0; else rc=$?; fi
  assert_eq "0" "$rc" "comparator: 0.9.1 exceeds 0.9.0"
  if herdr_version_at_least garbage "$HERDR_MIN_VERSION"; then rc=0; else rc=$?; fi
  assert_eq "2" "$rc" "comparator: malformed input is rejected"
}

test_newer_herdr_skips_update() {
  local case_dir="$tmp/newer"
  mkdir -p "$case_dir/bin" "$case_dir/home"
  : >"$case_dir/calls.log"
  cat >"$case_dir/bin/herdr" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$HERDR_CALL_LOG"
printf 'herdr 0.9.0\n'
EOF
  chmod +x "$case_dir/bin/herdr"

  HOME="$case_dir/home" PATH="$case_dir/bin:/usr/bin:/bin" \
    HERDR_CALL_LOG="$case_dir/calls.log" install_herdr_binary
  assert_eq "--version" "$(<"$case_dir/calls.log")" \
    "0.9.0 passes without an update"
}

test_package_managed_old_herdr() {
  local manager="$1" command="$2" case_dir="$tmp/package-$1" rc output herdr_dir
  herdr_dir="$case_dir/bin"
  [[ "$manager" == brew ]] && herdr_dir="$case_dir/homebrew/bin"
  [[ "$manager" == nix ]] && herdr_dir="$case_dir/nix/store/herdr/bin"
  [[ "$manager" == mise ]] && herdr_dir="$case_dir/home/.local/share/mise/installs/herdr/0.7.1/bin"
  mkdir -p "$herdr_dir" "$case_dir/home"
  : >"$case_dir/herdr.log"
  : >"$case_dir/curl.log"
  cat >"$herdr_dir/herdr" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$HERDR_CALL_LOG"
printf 'herdr 0.7.1\n'
EOF
  cat >"$case_dir/bin-curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CURL_CALL_LOG"
exit 99
EOF
  chmod +x "$herdr_dir/herdr" "$case_dir/bin-curl"
  ln -s "$case_dir/bin-curl" "$herdr_dir/curl"

  hash -r
  if output="$(HOME="$case_dir/home" PATH="$herdr_dir:/usr/bin:/bin" \
    HERDR_CALL_LOG="$case_dir/herdr.log" CURL_CALL_LOG="$case_dir/curl.log" \
    install_herdr_binary 2>&1)"; then
    rc=0
  else
    rc=$?
  fi

  assert_eq "1" "$rc" "$manager-managed 0.7.1 fails without overlay"
  assert_contains "$output" "run: $command" "$manager failure prints its upgrade command"
  assert_eq "--version" "$(<"$case_dir/herdr.log")" "$manager path never invokes Herdr updater"
  assert_eq "" "$(<"$case_dir/curl.log")" "$manager path never invokes curl installer"
}

test_missing_herdr_uses_upstream_installer() {
  local case_dir="$tmp/missing" rc cmd src
  mkdir -p "$case_dir/bin" "$case_dir/home/.local/bin"
  : >"$case_dir/curl.log"
  : >"$case_dir/herdr.log"
  cat >"$case_dir/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CURL_CALL_LOG"
cat <<'INSTALLER'
cat >"$HOME/.local/bin/herdr" <<'HERDR'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$HERDR_CALL_LOG"
printf 'herdr 0.9.0\n'
HERDR
chmod +x "$HOME/.local/bin/herdr"
INSTALLER
EOF
  chmod +x "$case_dir/bin/curl"
  # Keep host herdr/mise off PATH so this case actually hits the curl installer.
  for cmd in sh bash cat chmod mkdir mktemp sleep kill rm; do
    src="$(command -v "$cmd")" || continue
    [[ -e "$case_dir/bin/$cmd" ]] || ln -s "$src" "$case_dir/bin/$cmd"
  done

  if HOME="$case_dir/home" PATH="$case_dir/home/.local/bin:$case_dir/bin" \
    CURL_CALL_LOG="$case_dir/curl.log" HERDR_CALL_LOG="$case_dir/herdr.log" \
    install_herdr_binary; then
    rc=0
  else
    rc=$?
  fi

  assert_eq "0" "$rc" "missing Herdr retains upstream install behavior"
  assert_contains "$(<"$case_dir/curl.log")" "https://herdr.dev/install.sh" \
    "missing Herdr fetches the documented installer"
  assert_eq "--version" "$(<"$case_dir/herdr.log")" \
    "fresh install is verified against the minimum"
}

test_doctor_version() {
  local version="$1" expected_rc="$2" status="$3" case_dir="$tmp/doctor-$1" rc output cmd
  mkdir -p "$case_dir/bin" "$case_dir/home"
  cat >"$case_dir/bin/herdr" <<EOF
#!/usr/bin/env bash
printf 'herdr $version\\n'
EOF
  chmod +x "$case_dir/bin/herdr"
  for cmd in git wt fzf jq tuicr nvim hunk fresh lazygit; do
    ln -s /bin/true "$case_dir/bin/$cmd"
  done

  if output="$(HOME="$case_dir/home" PATH="$case_dir/bin:/usr/bin:/bin" \
    doctor_dependencies 2>&1)"; then
    rc=0
  else
    rc=$?
  fi
  assert_eq "$expected_rc" "$rc" "doctor exit for Herdr $version"
  assert_contains "$output" "$status  herdr" "doctor reports $status for Herdr $version"
  assert_contains "$output" "found $version, required >=$HERDR_MIN_VERSION" \
    "doctor reports found and required versions for $version"
}

test_hung_version_times_out() {
  local case_dir="$tmp/timeout" rc started elapsed
  mkdir -p "$case_dir/bin" "$case_dir/home"
  cat >"$case_dir/bin/herdr" <<'EOF'
#!/usr/bin/env bash
while :; do :; done
EOF
  chmod +x "$case_dir/bin/herdr"
  started=$SECONDS
  if HOME="$case_dir/home" PATH="$case_dir/bin:/usr/bin:/bin" \
    HERDR_VERSION_TIMEOUT_SECONDS=1 install_herdr_binary >/dev/null 2>&1; then
    rc=0
  else
    rc=$?
  fi
  elapsed=$((SECONDS - started))
  assert_eq "1" "$rc" "hung Herdr version probe fails closed"
  if ((elapsed <= 3)); then
    ok "hung Herdr version probe is bounded"
  else
    not_ok "hung Herdr version probe is bounded (took ${elapsed}s)"
  fi
}

test_term_ignoring_version_probe_is_killed() {
  local case_dir="$tmp/term-ignoring" probe_pid child_pid="" rc="" attempt
  mkdir -p "$case_dir/bin" "$case_dir/home"
  cat >"$case_dir/bin/herdr" <<'EOF'
#!/usr/bin/env bash
trap '' TERM
printf '%s\n' "$$" >"$HERDR_CHILD_PID_FILE"
while :; do :; done
EOF
  cat >"$case_dir/bin/mktemp" <<'EOF'
#!/usr/bin/env bash
: >"$HERDR_OUTPUT_FILE"
printf '%s\n' "$HERDR_OUTPUT_FILE"
EOF
  chmod +x "$case_dir/bin/herdr" "$case_dir/bin/mktemp"

  (
    local probe_rc
    if HOME="$case_dir/home" PATH="$case_dir/bin:/usr/bin:/bin" \
      HERDR_CHILD_PID_FILE="$case_dir/child.pid" HERDR_OUTPUT_FILE="$case_dir/version.output" \
      HERDR_VERSION_TIMEOUT_SECONDS=1 \
      herdr_version_output >"$case_dir/output" 2>&1; then
      probe_rc=0
    else
      probe_rc=$?
    fi
    printf '%s\n' "$probe_rc" >"$case_dir/rc"
  ) &
  probe_pid=$!
  for ((attempt = 0; attempt < 40; attempt++)); do
    kill -0 "$probe_pid" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$probe_pid" 2>/dev/null; then
    [[ ! -f "$case_dir/child.pid" ]] || child_pid="$(<"$case_dir/child.pid")"
    kill -KILL "$probe_pid" 2>/dev/null || true
    [[ -z "$child_pid" ]] || kill -KILL "$child_pid" 2>/dev/null || true
    wait "$probe_pid" 2>/dev/null || true
    not_ok "TERM-ignoring Herdr probe exits within bounded grace period"
    return
  fi
  wait "$probe_pid" 2>/dev/null || true
  [[ ! -f "$case_dir/rc" ]] || rc="$(<"$case_dir/rc")"
  [[ ! -f "$case_dir/child.pid" ]] || child_pid="$(<"$case_dir/child.pid")"
  assert_eq "124" "$rc" "TERM-ignoring Herdr probe reports timeout"
  if [[ ! -e "$case_dir/version.output" ]]; then
    ok "TERM-ignoring Herdr probe removes temporary output"
  else
    not_ok "TERM-ignoring Herdr probe removes temporary output"
  fi
  if [[ -n "$child_pid" ]] && ! kill -0 "$child_pid" 2>/dev/null; then
    ok "TERM-ignoring Herdr process is reaped"
  else
    [[ -z "$child_pid" ]] || kill -KILL "$child_pid" 2>/dev/null || true
    not_ok "TERM-ignoring Herdr process is reaped"
  fi
}

test_misleading_update_success_fails() {
  local case_dir="$tmp/misleading" rc output
  mkdir -p "$case_dir/home/.local/bin"
  : >"$case_dir/calls.log"
  cat >"$case_dir/home/.local/bin/herdr" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$HERDR_CALL_LOG"
if [[ "$*" == "--version" ]]; then printf 'herdr 0.7.1\n'; fi
EOF
  chmod +x "$case_dir/home/.local/bin/herdr"
  if output="$(HOME="$case_dir/home" PATH="$case_dir/home/.local/bin:/usr/bin:/bin" \
    HERDR_CALL_LOG="$case_dir/calls.log" install_herdr_binary 2>&1)"; then
    rc=0
  else
    rc=$?
  fi
  assert_eq "1" "$rc" "misleading updater success fails post-update verification"
  assert_contains "$output" "reported success but found 0.7.1" \
    "misleading updater success explains the stale version"
}

test_dirty_worktree_does_not_block_handoff() {
  local case_dir="$tmp/dirty-worktree" rc
  mkdir -p "$case_dir/home/.local/bin" "$case_dir/worktree/.git"
  printf 'dirty\n' >"$case_dir/worktree/untracked"
  printf '0.7.1\n' >"$case_dir/version"
  : >"$case_dir/calls.log"
  cat >"$case_dir/home/.local/bin/herdr" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$HERDR_CALL_LOG"
if [[ "$*" == "--version" ]]; then
  printf 'herdr %s\n' "$(<"$HERDR_VERSION_FILE")"
else
  printf '0.9.0\n' >"$HERDR_VERSION_FILE"
fi
EOF
  chmod +x "$case_dir/home/.local/bin/herdr"
  if (cd "$case_dir/worktree" && HOME="$case_dir/home" \
    PATH="$case_dir/home/.local/bin:/usr/bin:/bin" \
    HERDR_CALL_LOG="$case_dir/calls.log" HERDR_VERSION_FILE="$case_dir/version" \
    install_herdr_binary); then
    rc=0
  else
    rc=$?
  fi
  assert_eq "0" "$rc" "dirty worktree does not affect updater-managed handoff"
  assert_contains "$(<"$case_dir/calls.log")" "update --handoff" \
    "dirty worktree still uses live handoff"
}

test_subshell_stdout_stderr_contract() {
  local case_dir="$tmp/subshell-channels" rc cmd stdout stderr
  mkdir -p "$case_dir/homebrew/bin" "$case_dir/home"
  cat >"$case_dir/homebrew/bin/herdr" <<'EOF'
#!/usr/bin/env bash
printf 'herdr 0.7.1\n'
EOF
  chmod +x "$case_dir/homebrew/bin/herdr"
  for cmd in git wt fzf jq tuicr nvim hunk fresh lazygit; do
    ln -s /bin/true "$case_dir/homebrew/bin/$cmd"
  done

  if (HOME="$case_dir/home" PATH="$case_dir/homebrew/bin:/usr/bin:/bin" \
    install_herdr_binary >"$case_dir/install.stdout" 2>"$case_dir/install.stderr"); then
    rc=0
  else
    rc=$?
  fi
  stdout="$(<"$case_dir/install.stdout")"
  stderr="$(<"$case_dir/install.stderr")"
  assert_eq "1" "$rc" "subshell install returns nonzero for old package-managed Herdr"
  assert_eq "" "$stdout" "subshell install keeps package-manager failure off stdout"
  assert_contains "$stderr" "run: brew upgrade herdr" \
    "subshell install writes actionable failure to stderr"

  if (HOME="$case_dir/home" PATH="$case_dir/homebrew/bin:/usr/bin:/bin" \
    doctor_dependencies >"$case_dir/doctor.stdout" 2>"$case_dir/doctor.stderr"); then
    rc=0
  else
    rc=$?
  fi
  stdout="$(<"$case_dir/doctor.stdout")"
  stderr="$(<"$case_dir/doctor.stderr")"
  assert_eq "1" "$rc" "subshell doctor returns nonzero below minimum"
  assert_contains "$stdout" "found 0.7.1, required >=$HERDR_MIN_VERSION" \
    "subshell doctor reports version contract on stdout"
  assert_eq "" "$stderr" "subshell doctor emits no unexpected stderr"
}

test_top_level_doctor_fails_for_old_herdr() {
  local case_dir="$tmp/top-level-doctor" rc output cmd
  mkdir -p "$case_dir/bin" "$case_dir/home"
  cat >"$case_dir/bin/herdr" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
  printf 'herdr 0.7.1\n'
  exit 0
fi
exit 1
EOF
  chmod +x "$case_dir/bin/herdr"
  for cmd in git wt fzf jq tuicr nvim hunk fresh lazygit; do
    ln -s /bin/true "$case_dir/bin/$cmd"
  done
  if output="$(HOME="$case_dir/home" SHELL=/bin/bash \
    PATH="$case_dir/bin:/usr/bin:/bin" AGENTIC_DEV_LIB="$ROOT/lib" \
    "$ROOT/bin/agentic-dev" doctor 2>&1)"; then
    rc=0
  else
    rc=$?
  fi
  assert_eq "1" "$rc" "top-level doctor fails for Herdr below minimum"
  assert_contains "$output" "found 0.7.1, required >=$HERDR_MIN_VERSION" \
    "top-level doctor still prints the Herdr version failure"
  assert_contains "$output" "Integration:" \
    "top-level doctor continues through integration checks"
}

test_installed_herdr_short_circuits_install
test_old_updater_managed_herdr_handoffs
test_malformed_version_fails_closed
test_version_parser_does_not_expand_globs
test_version_comparison_matrix
test_newer_herdr_skips_update
test_package_managed_old_herdr brew "brew upgrade herdr"
test_package_managed_old_herdr mise "mise use -g herdr"
test_package_managed_old_herdr nix "nix profile upgrade <index-or-name>"
test_missing_herdr_uses_upstream_installer
test_doctor_version 0.7.1 1 outdated
test_doctor_version 0.8.2 1 outdated
test_doctor_version 0.9.0 0 ok
test_hung_version_times_out
test_term_ignoring_version_probe_is_killed
test_misleading_update_success_fails
test_dirty_worktree_does_not_block_handoff
test_subshell_stdout_stderr_contract
test_top_level_doctor_fails_for_old_herdr

printf '%s passed, %s failed\n' "$pass" "$fail"
((fail == 0))
