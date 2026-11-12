#!/usr/bin/env bats
# bercail.dev's Worker: the latest release's tag, its install.sh pin, and its fallback.

setup() {
  load test_helper
  isolate
  command -v node >/dev/null 2>&1 || skip "node not found; Worker release test not run"
}

@test "the Worker serves the latest release's tag, pins install.sh to it, and keeps the last tag" {
  node --disable-warning=MODULE_TYPELESS_PACKAGE_JSON "$ROOT/tests/worker_release_test.mjs"
}
