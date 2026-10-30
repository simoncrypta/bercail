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




test_version_parser_does_not_expand_globs() {
  local case_dir="$tmp/glob-version" rc
  mkdir -p "$case_dir/0.9.0"
  if (cd "$case_dir" && parse_version '*') >/dev/null 2>&1; then
    rc=0
  else
    rc=$?
  fi
  assert_eq "2" "$rc" "version parser rejects glob-like malformed output"
}

test_version_comparison_matrix() {
  local rc
  if version_at_least 0.19.9 0.20.0; then rc=0; else rc=$?; fi
  assert_eq "1" "$rc" "comparator: 0.19.9 is below 0.20.0"
  if version_at_least 0.20.0 0.20.0; then rc=0; else rc=$?; fi
  assert_eq "0" "$rc" "comparator: 0.20.0 meets 0.20.0"
  if version_at_least 0.100.0 0.20.0; then rc=0; else rc=$?; fi
  assert_eq "0" "$rc" "comparator: 0.100.0 exceeds 0.20.0"
  if version_at_least garbage 0.20.0; then rc=0; else rc=$?; fi
  assert_eq "2" "$rc" "comparator: malformed input is rejected"
}

# check_herdr_app reports; install_herdr_app (below) installs.
test_check_herdr_app() {
  local case_dir="$tmp/herdr-app" rc output
  mkdir -p "$case_dir/bin"
  ln -s /bin/true "$case_dir/bin/herdr"
  output="$(PATH="$case_dir/bin:/usr/bin:/bin" check_herdr_app 2>&1)" || true
  assert_contains "$output" "found herdr, the Herdr terminal: bercail needs the Herdr app" \
    "check_herdr_app tells the herdr terminal from the app"
  rm "$case_dir/bin/herdr"
  ln -s /bin/true "$case_dir/bin/herdr-app"
  if output="$(PATH="$case_dir/bin:/usr/bin:/bin" check_herdr_app 2>&1)"; then rc=0; else rc=$?; fi
  assert_eq "1" "$rc" "check_herdr_app fails without hc"
  assert_contains "$output" "missing hc: install the Herdr app from https://herdr.dev" \
    "check_herdr_app says where the app comes from"
  ln -s /bin/true "$case_dir/bin/hc"
  if PATH="$case_dir/bin:/usr/bin:/bin" check_herdr_app >/dev/null 2>&1; then rc=0; else rc=$?; fi
  assert_eq "0" "$rc" "check_herdr_app passes with herdr-app and hc"
}

# install_herdr_app runs herdr.dev's installers only for what is missing.
test_install_herdr_app() {
  local case_dir="$tmp/install-herdr-app" mode out
  for mode in none app both; do
    out="$case_dir/$mode"
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
    ) >"$out/output" 2>&1 && echo 0 >"$out/rc" || echo 1 >"$out/rc"
  done
  assert_eq "0" "$(cat "$case_dir/none/rc")" "install_herdr_app installs the app when nothing is there"
  assert_contains "$(cat "$case_dir/none/curl.log")" "https://releases.herdr.dev/app/install.sh" \
    "a missing app runs the app installer"
  assert_eq "1" "$(wc -l <"$case_dir/none/curl.log" | tr -d ' ')" "the app installer brings hc; no second installer"
  assert_eq "0" "$(cat "$case_dir/app/rc")" "install_herdr_app adds hc next to an installed app"
  assert_eq "https://releases.herdr.dev/core/install.sh" "$(cat "$case_dir/app/curl.log")" \
    "an app without hc runs only the core installer"
  assert_eq "0" "$(cat "$case_dir/both/rc")" "install_herdr_app passes when both are there"
  assert_eq "" "$(cat "$case_dir/both/curl.log" 2>/dev/null)" "a present app and hc download nothing"
}

test_top_level_doctor_reports_missing_app() {
  local case_dir="$tmp/top-level-doctor" rc output cmd
  mkdir -p "$case_dir/bin" "$case_dir/home"
  for cmd in herdr git wt bd fzf jq tuicr; do
    ln -s /bin/true "$case_dir/bin/$cmd"
  done
  if output="$(HOME="$case_dir/home" SHELL=/bin/bash \
    PATH="$case_dir/bin:/usr/bin:/bin" AGENTIC_DEV_LIB="$ROOT/lib" \
    "$ROOT/bin/agentic-dev" doctor 2>&1)"; then
    rc=0
  else
    rc=$?
  fi
  assert_eq "1" "$rc" "top-level doctor fails without the Herdr app"
  assert_contains "$output" "missing  herdr-app" "top-level doctor names herdr-app"
  assert_contains "$output" "missing  hc" "top-level doctor names hc"
  assert_contains "$output" "wrong  herdr is the Herdr terminal" \
    "top-level doctor tells the herdr terminal from the app"
  assert_contains "$output" "Integration:" \
    "top-level doctor continues through integration checks"
  assert_contains "$output" "missing  Herdr layout" "top-level doctor checks the bercail layout"
}











# worktrunk's last fallback downloads its GitHub release. Upstream ships
# .tar.xz archives (musl on Linux) with wt inside worktrunk-<target>/.
test_worktrunk_release_fallback() {
  local out="$tmp/wt-fallback" archive url_log
  mkdir -p "$out/bin" "$out/build/worktrunk-x86_64-unknown-linux-musl"
  printf '#!/bin/sh\necho wt-stub\n' >"$out/build/worktrunk-x86_64-unknown-linux-musl/wt"
  chmod +x "$out/build/worktrunk-x86_64-unknown-linux-musl/wt"
  archive="$out/release.tar.xz"
  tar -cJf "$archive" -C "$out/build" worktrunk-x86_64-unknown-linux-musl
  url_log="$out/urls"
  (
    LOCAL_BIN="$out/bin" DRY_RUN=0
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
  assert_eq "https://github.com/max-sixty/worktrunk/releases/latest/download/worktrunk-x86_64-unknown-linux-musl.tar.xz" \
    "$(head -n1 "$url_log" 2>/dev/null)" "worktrunk fallback asks for the musl .tar.xz asset"
  assert_eq "wt-stub" "$("$out/bin/wt" 2>/dev/null)" "worktrunk fallback installs wt from worktrunk-<target>/"
}


# tuicr's installer prompts on /dev/tty unless TUICR_INSTALL_YES is set.
# bercail --yes must answer it so an unattended install does not stall.
test_tuicr_installer_answers_under_yes() {
  local out="$tmp/tuicr-yes" mode
  mkdir -p "$out"
  for mode in 1 0; do
    (
      DRY_RUN=0 YES="$mode"
      dep_present() { [[ "$1" == curl ]]; }
      maybe_mise_install() { return 1; }
      has_brew() { return 1; }
      ensure_mise_shims() { :; }
      # Stub: the "installer" records whether the prompt would be skipped.
      curl() { printf 'printf "%%s" "${TUICR_INSTALL_YES:-prompt}" >"%s/seen-%s"\n' "$out" "$mode"; }
      install_tuicr_binary
    ) >/dev/null 2>&1 || true   # tuicr stays "missing": the stub installs nothing
  done
  assert_eq "1" "$(cat "$out/seen-1" 2>/dev/null)" "tuicr installer skips its prompt under --yes"
  assert_eq "prompt" "$(cat "$out/seen-0" 2>/dev/null)" "tuicr installer still asks without --yes"
}


test_version_parser_does_not_expand_globs
test_version_comparison_matrix
test_check_herdr_app
test_install_herdr_app
test_top_level_doctor_reports_missing_app
test_worktrunk_release_fallback
test_tuicr_installer_answers_under_yes

printf '%s passed, %s failed\n' "$pass" "$fail"
((fail == 0))
