#!/usr/bin/env bats
# Real Pi with offline providers: no subscriptions or API requests.
# bats file_tags=live

setup() {
  load test_helper
  isolate
  command -v node >/dev/null 2>&1 || skip "node not found; Pi fallback proof not run"
  pi="${PI_FALLBACK_BIN:-}"
  [[ -n "$pi" ]] || pi="$(real_pi)"
  [[ -n "$pi" ]] || skip "Pi not found; fallback live proof not run"
  version="$("$pi" --version)"
  pi_at_least "$version" 1.5 || skip "Pi $version is older than 1.5; fallback live proof not run"
}

@test "live: Pi fallback runs offline against real Pi >= 1.5" {
  PI_FALLBACK_BIN="$pi" node "$ROOT/tests/pi_fallback_test.mjs"
}
