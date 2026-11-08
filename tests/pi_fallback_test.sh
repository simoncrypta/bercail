#!/usr/bin/env bash
# shellcheck shell=bash
# Real Pi with offline providers: no subscriptions or API requests.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if ! command -v node >/dev/null 2>&1; then
  printf 'SKIP: node not found; Pi fallback proof not run\n'
  exit 0
fi
pi="${PI_FALLBACK_BIN:-}"
# Resolve mise before the test isolates HOME; its shim may otherwise reinstall.
if [[ -z "$pi" ]] && command -v mise >/dev/null 2>&1; then
  pi="$(mise which pi 2>/dev/null || true)"
fi
if [[ -z "$pi" || ! -x "$pi" || "$pi" == */mise/shims/* ]]; then
  pi="$(command -v pi 2>/dev/null || true)"
  [[ -n "$pi" && "$pi" != */mise/shims/* && -x "$pi" ]] || pi=""
fi
if [[ -z "$pi" ]]; then
  printf 'SKIP: Pi not found; fallback live proof not run\n'
  exit 0
fi
version="$("$pi" --version)"
if ! node -e 'const [a,b] = process.argv[1].split(".").map(Number); process.exit(a > 1 || (a === 1 && b >= 5) ? 0 : 1)' "$version"; then
  printf 'SKIP: Pi %s is older than 1.5; fallback live proof not run\n' "$version"
  exit 0
fi
PI_FALLBACK_BIN="$pi" node "$ROOT/tests/pi_fallback_test.mjs"
