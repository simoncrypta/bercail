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

# The Herdr app and hc come from herdr.dev: bercail checks, never installs.
test_check_herdr_app() {
  local case_dir="$tmp/herdr-app" rc output
  mkdir -p "$case_dir/bin"
  ln -s /bin/true "$case_dir/bin/herdr-app"
  if output="$(PATH="$case_dir/bin:/usr/bin:/bin" check_herdr_app 2>&1)"; then rc=0; else rc=$?; fi
  assert_eq "1" "$rc" "check_herdr_app fails without hc"
  assert_contains "$output" "missing hc: install the Herdr app from https://herdr.dev" \
    "check_herdr_app says where the app comes from"
  ln -s /bin/true "$case_dir/bin/hc"
  if PATH="$case_dir/bin:/usr/bin:/bin" check_herdr_app >/dev/null 2>&1; then rc=0; else rc=$?; fi
  assert_eq "0" "$rc" "check_herdr_app passes with herdr-app and hc"
}

test_top_level_doctor_reports_missing_app() {
  local case_dir="$tmp/top-level-doctor" rc output cmd
  mkdir -p "$case_dir/bin" "$case_dir/home"
  for cmd in git wt bd fzf jq tuicr; do
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
test_top_level_doctor_reports_missing_app
test_worktrunk_release_fallback
test_tuicr_installer_answers_under_yes

printf '%s passed, %s failed\n' "$pass" "$fail"
((fail == 0))
