#!/usr/bin/env bash
# shellcheck shell=bash
# doctor hints when Herdr has downloaded a newer version than the one running.
set -euo pipefail

unset BASH_ENV
export __MISE_BASH_ENV_LOADED=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

export HOME="$TMP_DIR/home"
export HERDR_APP_CONFIG_DIR="$TMP_DIR/herdr-app"
mkdir -p "$HOME" "$HERDR_APP_CONFIG_DIR" "$TMP_DIR/bin"
cat >"$TMP_DIR/bin/herdr-app" <<EOF
#!/bin/sh
[ "\$1" = --version ] && echo "herdr-app \$(cat "$TMP_DIR/version")"
EOF
chmod +x "$TMP_DIR/bin/herdr-app"
export PATH="$TMP_DIR/bin:$PATH"

# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=lib/doctor.sh
source "$ROOT/lib/doctor.sh"

state() {
  printf '%s\n' "$1" >"$TMP_DIR/version"
  printf '{"last_run": "%s", "presented": []}\n' "$2" >"$HERDR_APP_CONFIG_DIR/update-notes.json"
  printf '# Herdr changelog\n\n## [%s] - 2026-10-31\n\n### Fixed\n- a\n\n## [0.1.9] - 2026-10-30\n' "$3" \
    >"$HERDR_APP_CONFIG_DIR/update-notes-cache.md"
}

state 0.1.9 0.1.9 0.1.11
out="$(doctor_herdr_app_update)"
[[ "$out" == "  hint  Herdr 0.1.11 is downloaded (running 0.1.9); restart the Herdr window to apply it" ]] \
  || fail "newer cached version should hint: $out"
printf 'PASS: doctor hints when the cached version is newer\n'

state 0.1.11 0.1.9 0.1.11
out="$(doctor_herdr_app_update)"
[[ "$out" == *"Herdr 0.1.11 is downloaded (running 0.1.9)"* ]] \
  || fail "a replaced binary the window has not run yet should hint: $out"
printf 'PASS: doctor hints when the new binary is on disk but not running\n'

state 0.1.11 0.1.11 0.1.11
out="$(doctor_herdr_app_update)"
[[ -z "$out" ]] || fail "equal versions should be silent: $out"
state 0.1.10 0.1.10 0.1.9
out="$(doctor_herdr_app_update)"
[[ -z "$out" ]] || fail "an older changelog should be silent: $out"
printf 'PASS: doctor stays silent when the versions are equal\n'

rm -f "$HERDR_APP_CONFIG_DIR/update-notes-cache.md" "$HERDR_APP_CONFIG_DIR/update-notes.json"
out="$(doctor_herdr_app_update)"
[[ -z "$out" ]] || fail "missing files should be silent: $out"
state 0.1.9 0.1.9 0.1.11
rm -f "$HERDR_APP_CONFIG_DIR/update-notes.json"
: >"$TMP_DIR/version"
out="$(doctor_herdr_app_update)"
[[ -z "$out" ]] || fail "no running version known should be silent: $out"
printf 'PASS: doctor stays silent when the files are missing\n'
