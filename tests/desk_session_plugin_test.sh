#!/usr/bin/env bash
# shellcheck shell=bash
# The desk's OpenCode plugin: which session is selected, without waiting for a turn.
# The unit half runs with node alone. The live half needs the installed opencode.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

if ! command -v node >/dev/null 2>&1; then
  printf 'SKIP: node not found\n'
  exit 0
fi

node --disable-warning=MODULE_TYPELESS_PACKAGE_JSON --experimental-strip-types \
  "$ROOT/tests/desk_session_plugin_test.mjs"

# mise's shim reinstalls when HOME changes. The aube shim execs the binary.
oc=""
if command -v mise >/dev/null 2>&1; then
  oc="$(mise which opencode 2>/dev/null || true)"
fi
if [[ -z "$oc" || ! -x "$oc" || "$oc" == */mise/shims/* ]]; then
  oc="$(command -v opencode 2>/dev/null || true)"
  [[ -n "$oc" && "$oc" != */mise/shims/* && -x "$oc" ]] || oc=""
fi
if [[ -z "$oc" ]]; then
  printf 'SKIP: opencode not found; live proof not run\n'
  exit 0
fi
command -v python3 >/dev/null 2>&1 || fail "python3 is required for the live proof"

python3 "$ROOT/tests/desk_session_plugin_live.py" "$ROOT" "$oc"
