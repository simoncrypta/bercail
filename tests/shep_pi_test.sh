#!/usr/bin/env bash
# shellcheck shell=bash
# Shep's Pi inbox extension. The unit half runs with node alone. The live half
# runs `bercail shep run` on the installed Pi with a fake model.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

if ! command -v node >/dev/null 2>&1; then
  printf 'SKIP: node not found\n'
  exit 0
fi

node --disable-warning=MODULE_TYPELESS_PACKAGE_JSON --experimental-strip-types \
  "$ROOT/tests/shep_pi_test.mjs"

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
command -v python3 >/dev/null 2>&1 || fail "python3 is required for the live proof"

python3 "$ROOT/tests/shep_pi_live.py" "$ROOT" "$pi"
