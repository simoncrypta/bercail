#!/usr/bin/env bats

# shellcheck disable=SC2016 # single-quoted text is literal stub and installer code.
# shellcheck disable=SC2030,SC2031 # env set in a subshell stays there on purpose; helpers set out and rc.
# shellcheck disable=SC2034 # YES, DRY_RUN and friends are read by the sourced libs.
# shellcheck disable=SC2329 # stubs replace lib functions the libs call.

setup() {
  load test_helper
  isolate
  # shellcheck source=lib/detect.sh disable=SC1091
  source "$ROOT/lib/detect.sh"
  # shellcheck source=lib/deps.sh disable=SC1091
  source "$ROOT/lib/deps.sh"

  log() { printf '%s\n' "$*"; }
  info() { :; }
  warn() { printf '%s\n' "$*" >&2; }
  has_brew() { return 1; }
  has_mise() { return 1; }
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

# check_herdr_app with only the named commands on PATH (plus the system). Sets out and rc.
check_herdr_app_with() {
  local bin="$BATS_TEST_TMPDIR/herdr-app-bin" cmd
  mkdir -p "$bin"
  for cmd in "$@"; do ln -s /bin/true "$bin/$cmd"; done
  if out="$(PATH="$bin:/usr/bin:/bin" check_herdr_app 2>&1)"; then rc=0; else rc=$?; fi
}

# install_herdr_app with none, the app, or both the app and hc already in
# ~/.local/bin. The curl stub logs each URL to $out/curl.log. Sets out and rc.
install_herdr_app_with() {
  local mode="$1" cmd
  out="$BATS_TEST_TMPDIR/install-herdr-app/$mode"
  mkdir -p "$out/home/.local/bin" "$out/sys"
  ln -s "$(command -v bash)" "$out/sys/bash"
  for cmd in sh mkdir touch chmod cat; do ln -sf "$(command -v "$cmd")" "$out/sys/$cmd"; done
  [[ "$mode" == none ]] || ln -s /bin/true "$out/home/.local/bin/herdr-app"
  [[ "$mode" != both ]] || ln -s /bin/true "$out/home/.local/bin/hc"
  (
    export HOME="$out/home" PATH="$out/sys" DRY_RUN=0
    dep_present() { command -v "$1" >/dev/null 2>&1 || [[ "$1" == curl ]]; }
    # Stub: log the URL and print an "installer" that makes what it would.
    curl() {
      local url="${*: -1}"
      printf '%s\n' "$url" >>"$out/curl.log"
      case "$url" in
        */app/install.sh) printf 'touch "$HOME/.local/bin/herdr-app" "$HOME/.local/bin/hc"; chmod +x "$HOME/.local/bin/"*\n' ;;
        */core/install.sh) printf 'touch "$HC_INSTALL_DIR/hc"; chmod +x "$HC_INSTALL_DIR/hc"\n' ;;
      esac
    }
    install_herdr_app
  ) >"$out/output" 2>&1 && rc=0 || rc=1
}

# The top-level doctor on a host with herdr (the terminal) but no Herdr app. Sets out and rc.
top_level_doctor() {
  local case_dir="$BATS_TEST_TMPDIR/top-level-doctor" cmd
  mkdir -p "$case_dir/bin" "$case_dir/home"
  for cmd in herdr git wt bd fzf jq tuicr; do
    ln -s /bin/true "$case_dir/bin/$cmd"
  done
  if out="$(HOME="$case_dir/home" SHELL=/bin/bash \
    PATH="$case_dir/bin:/usr/bin:/bin" AGENTIC_DEV_LIB="$ROOT/lib" \
    "$ROOT/bin/agentic-dev" doctor 2>&1)"; then
    rc=0
  else
    rc=$?
  fi
}

# worktrunk's last fallback downloads its GitHub release. Upstream ships
# .tar.xz archives (musl on Linux) with wt inside worktrunk-<target>/.
worktrunk_release_fallback() {
  local archive
  wt_out="$BATS_TEST_TMPDIR/wt-fallback"
  mkdir -p "$wt_out/bin" "$wt_out/build/worktrunk-x86_64-unknown-linux-musl"
  printf '#!/bin/sh\necho wt-stub\n' >"$wt_out/build/worktrunk-x86_64-unknown-linux-musl/wt"
  chmod +x "$wt_out/build/worktrunk-x86_64-unknown-linux-musl/wt"
  archive="$wt_out/release.tar.xz"
  tar -cJf "$archive" -C "$wt_out/build" worktrunk-x86_64-unknown-linux-musl
  url_log="$wt_out/urls"
  (
    LOCAL_BIN="$wt_out/bin" DRY_RUN=0
    dep_present() { [[ "$1" == curl ]]; }
    maybe_mise_install() { return 1; }
    has_brew() { return 1; }
    detect_os() { printf linux; }
    detect_arch() { printf x86_64; }
    ensure_dir() { mkdir -p "$1"; }
    # Stub for: curl -fsSL URL -o FILE
    curl() {
      printf '%s\n' "$2" >>"$url_log"
      [[ "$3" == -o ]] && cp "$archive" "$4"
    }
    install_worktrunk_binary
  ) 2>/dev/null
}

# tuicr's installer prompts on /dev/tty unless TUICR_INSTALL_YES is set.
# bercail --yes must answer it so an unattended install does not stall.
# $1: YES. The stub installer writes what it saw to $tuicr_out/seen-$1.
tuicr_installer_under_yes() {
  local mode="$1"
  tuicr_out="$BATS_TEST_TMPDIR/tuicr-yes"
  mkdir -p "$tuicr_out"
  (
    DRY_RUN=0 YES="$mode"
    dep_present() { [[ "$1" == curl ]]; }
    maybe_mise_install() { return 1; }
    has_brew() { return 1; }
    ensure_mise_shims() { :; }
    # Stub: the "installer" records whether the prompt would be skipped.
    curl() { printf 'printf "%%s" "${TUICR_INSTALL_YES:-prompt}" >"%s/seen-%s"\n' "$tuicr_out" "$mode"; }
    install_tuicr_binary
  ) >/dev/null 2>&1 || true   # tuicr stays "missing": the stub installs nothing
}

@test "version parser rejects glob-like malformed output" {
  local case_dir="$BATS_TEST_TMPDIR/glob-version" rc
  mkdir -p "$case_dir/0.9.0"
  if (cd "$case_dir" && parse_version '*') >/dev/null 2>&1; then
    rc=0
  else
    rc=$?
  fi
  assert_eq "2" "$rc" "version parser rejects glob-like malformed output"
}

@test "comparator: 0.19.9 is below 0.20.0" {
  local rc
  if version_at_least 0.19.9 0.20.0; then rc=0; else rc=$?; fi
  assert_eq "1" "$rc" "comparator: 0.19.9 is below 0.20.0"
}

@test "comparator: 0.20.0 meets 0.20.0" {
  local rc
  if version_at_least 0.20.0 0.20.0; then rc=0; else rc=$?; fi
  assert_eq "0" "$rc" "comparator: 0.20.0 meets 0.20.0"
}

@test "comparator: 0.100.0 exceeds 0.20.0" {
  local rc
  if version_at_least 0.100.0 0.20.0; then rc=0; else rc=$?; fi
  assert_eq "0" "$rc" "comparator: 0.100.0 exceeds 0.20.0"
}

@test "comparator: malformed input is rejected" {
  local rc
  if version_at_least garbage 0.20.0; then rc=0; else rc=$?; fi
  assert_eq "2" "$rc" "comparator: malformed input is rejected"
}

@test "check_herdr_app tells the herdr terminal from the app" {
  check_herdr_app_with herdr
  assert_contains "$out" "found herdr, the Herdr terminal: bercail needs the Herdr app" \
    "check_herdr_app tells the herdr terminal from the app"
}

@test "check_herdr_app fails without hc and says where the app comes from" {
  check_herdr_app_with herdr-app
  assert_eq "1" "$rc" "check_herdr_app fails without hc"
  assert_contains "$out" "missing hc: install the Herdr app from https://herdr.dev" \
    "check_herdr_app says where the app comes from"
}

@test "check_herdr_app passes with herdr-app and hc" {
  check_herdr_app_with herdr-app hc
  assert_eq "0" "$rc" "check_herdr_app passes with herdr-app and hc"
}

@test "install_herdr_app installs the app when nothing is there, with one installer" {
  install_herdr_app_with none
  assert_eq "0" "$rc" "install_herdr_app installs the app when nothing is there"
  assert_contains "$(cat "$out/curl.log")" "https://releases.herdr.dev/app/install.sh" \
    "a missing app runs the app installer"
  assert_eq "1" "$(wc -l <"$out/curl.log" | tr -d ' ')" "the app installer brings hc; no second installer"
}

@test "install_herdr_app adds hc next to an installed app with only the core installer" {
  install_herdr_app_with app
  assert_eq "0" "$rc" "install_herdr_app adds hc next to an installed app"
  assert_eq "https://releases.herdr.dev/core/install.sh" "$(cat "$out/curl.log")" \
    "an app without hc runs only the core installer"
}

@test "install_herdr_app passes and downloads nothing when the app and hc are there" {
  install_herdr_app_with both
  assert_eq "0" "$rc" "install_herdr_app passes when both are there"
  assert_eq "" "$(cat "$out/curl.log" 2>/dev/null)" "a present app and hc download nothing"
}

@test "top-level doctor fails and names herdr-app and hc without the Herdr app" {
  top_level_doctor
  assert_eq "1" "$rc" "top-level doctor fails without the Herdr app"
  assert_contains "$out" "missing  herdr-app" "top-level doctor names herdr-app"
  assert_contains "$out" "missing  hc" "top-level doctor names hc"
}

@test "top-level doctor tells the herdr terminal from the app" {
  top_level_doctor
  assert_contains "$out" "wrong  herdr is the Herdr terminal" \
    "top-level doctor tells the herdr terminal from the app"
}

@test "top-level doctor continues through integration checks to the bercail layout" {
  top_level_doctor
  assert_contains "$out" "Integration:" \
    "top-level doctor continues through integration checks"
  assert_contains "$out" "missing  Herdr layout" "top-level doctor checks the bercail layout"
}

@test "worktrunk fallback asks for the musl .tar.xz asset" {
  worktrunk_release_fallback
  assert_eq "https://github.com/max-sixty/worktrunk/releases/latest/download/worktrunk-x86_64-unknown-linux-musl.tar.xz" \
    "$(head -n1 "$url_log" 2>/dev/null)" "worktrunk fallback asks for the musl .tar.xz asset"
}

@test "worktrunk fallback installs wt from worktrunk-<target>/" {
  worktrunk_release_fallback
  assert_eq "wt-stub" "$("$wt_out/bin/wt" 2>/dev/null)" "worktrunk fallback installs wt from worktrunk-<target>/"
}

@test "tuicr installer skips its prompt under --yes" {
  tuicr_installer_under_yes 1
  assert_eq "1" "$(cat "$tuicr_out/seen-1" 2>/dev/null)" "tuicr installer skips its prompt under --yes"
}

@test "tuicr installer still asks without --yes" {
  tuicr_installer_under_yes 0
  assert_eq "prompt" "$(cat "$tuicr_out/seen-0" 2>/dev/null)" "tuicr installer still asks without --yes"
}
