#!/usr/bin/env bash
# shellcheck shell=bash
# bercail.dev's Worker: the latest release's tag, its install.sh pin, and its fallback.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if ! command -v node >/dev/null 2>&1; then
  printf 'SKIP: node not found; Worker release test not run\n'
  exit 0
fi
node --disable-warning=MODULE_TYPELESS_PACKAGE_JSON "$ROOT/tests/worker_release_test.mjs"
