#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

unset BASH_ENV
export __MISE_BASH_ENV_LOADED=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

export HOME="$TMP_DIR/home"
mkdir -p "$HOME"

# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=lib/detect.sh
source "$ROOT/lib/detect.sh"
# shellcheck source=lib/shell-rc.sh
source "$ROOT/lib/shell-rc.sh"

rc="$HOME/.bashrc"
printf 'alias ll="ls -l"\n' >"$rc"
upsert_marker_block "$rc" bash >/dev/null
first="$(<"$rc")"
upsert_marker_block "$rc" bash >/dev/null
upsert_marker_block "$rc" bash >/dev/null
[[ "$(<"$rc")" == "$first" ]] || fail "amending must not change the file: $(cat -A "$rc")"
[[ "$(grep -c "$AGENTIC_DEV_MARKER_START" "$rc")" == 1 ]] || fail "one marker block"
head -1 "$rc" | grep -qx 'alias ll="ls -l"' || fail "the person's lines stay"
printf 'PASS: re-running the marker block upsert leaves .bashrc unchanged\n'
