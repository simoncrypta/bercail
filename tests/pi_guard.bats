#!/usr/bin/env bats
# The guard's decision table, plus a live Pi block when Pi is installed.

setup() {
  load test_helper
  isolate
  command -v node >/dev/null 2>&1 || skip "node not found; Pi guard proof not run"
}

@test "the guard's decision table" {
  node "$ROOT/tests/pi_guard_test.mjs"
}

# bats test_tags=live
@test "live: real Pi >= 1.5 blocks what the guard blocks" {
  local pi version
  pi="${PI_GUARD_BIN:-}"
  [[ -n "$pi" ]] || pi="$(real_pi)"
  [[ -n "$pi" ]] || skip "Pi not found; guard live proof not run"
  version="$("$pi" --version)"
  pi_at_least "$version" 1.5 || skip "Pi $version is older than 1.5; guard live proof not run"
  PI_GUARD_BIN="$pi" node "$ROOT/tests/pi_guard_live.mjs"
}
