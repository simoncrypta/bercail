#!/usr/bin/env bats
# What the guard blocks, on a live Pi. The decision table is tests/pi_guard.test.ts (vp test).

setup() {
  load test_helper
  isolate
  need node
}

# bats test_tags=live
@test "live: real Pi >= 1.5 blocks what the guard blocks" {
  local pi version
  pi="${PI_GUARD_BIN:-}"
  [[ -n "$pi" ]] || pi="$(real_pi)"
  [[ -n "$pi" ]] || skip "Pi not found; guard live proof not run"
  version="$("$pi" --version)"
  pi_at_least "$version" 1.5 || skip "Pi $version is older than 1.5; guard live proof not run"
  PI_GUARD_BIN="$pi" node "$ROOT/tests/pi_guard_live.ts"
}

# bats test_tags=live
@test "live: a real Pi Shep hands a push to a guard card and answers while it waits" {
  local pi
  pi="${PI_GUARD_BIN:-}"
  [[ -n "$pi" ]] || pi="$(real_pi)"
  [[ -n "$pi" ]] || skip "Pi not found; guard-ask live proof not run"
  need git jq flock
  node "$ROOT/tests/pi_guard_ask_live.ts" "$ROOT" "$pi"
}

# bats test_tags=live
@test "live: a real Pi whose guard changed on disk refuses the next call, reloads it and goes on" {
  local pi
  pi="${PI_GUARD_BIN:-}"
  [[ -n "$pi" ]] || pi="$(real_pi)"
  [[ -n "$pi" ]] || skip "Pi not found; guard reload live proof not run"
  need script
  node "$ROOT/tests/pi_guard_reload_live.ts" "$ROOT" "$pi"
}
