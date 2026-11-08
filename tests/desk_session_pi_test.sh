#!/usr/bin/env bash
# shellcheck shell=bash
# The desk's Pi extension: which session is running, so a reboot can resume it.
# The unit half runs with node alone. The live half needs the installed Pi.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

if ! command -v node >/dev/null 2>&1; then
  printf 'SKIP: node not found\n'
  exit 0
fi

node --disable-warning=MODULE_TYPELESS_PACKAGE_JSON --experimental-strip-types \
  "$ROOT/tests/desk_session_pi_test.mjs"

# mise's shim reinstalls when HOME changes. Resolve the binary first.
pi=""
if command -v mise >/dev/null 2>&1; then
  pi="$(mise which pi 2>/dev/null || true)"
fi
if [[ -z "$pi" || ! -x "$pi" || "$pi" == */mise/shims/* ]]; then
  pi="$(command -v pi 2>/dev/null || true)"
  [[ -n "$pi" && "$pi" != */mise/shims/* && -x "$pi" ]] || pi=""
fi
if [[ -z "$pi" ]]; then
  printf 'SKIP: Pi not found; live proof not run\n'
  exit 0
fi
version="$("$pi" --version 2>/dev/null || true)"
if ! node -e 'const [a,b] = process.argv[1].split(".").map(Number); process.exit(a > 1 || (a === 1 && b >= 2) ? 0 : 1)' "$version"; then
  printf 'SKIP: Pi %s is older than 1.2.0; live proof not run\n' "$version"
  exit 0
fi
command -v python3 >/dev/null 2>&1 || fail "python3 is required for the live proof"

python3 "$ROOT/tests/desk_session_pi_live.py" "$ROOT" "$pi"
