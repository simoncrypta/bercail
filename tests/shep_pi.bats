#!/usr/bin/env bats
# Shep's Pi inbox extension. The unit half runs with node alone. The live half
# runs `bercail shep run` on the installed Pi with a fake model.

setup() {
  load test_helper
  isolate
  need node
}

@test "the inbox extension's unit checks" {
  node --disable-warning=MODULE_TYPELESS_PACKAGE_JSON --experimental-strip-types \
    "$ROOT/tests/shep_pi_test.mjs"
}

# bats test_tags=live
@test "live: bercail shep run on the installed Pi with a fake model" {
  local pi
  pi="$(real_pi)"
  [[ -n "$pi" ]] || skip "Pi not found; live proof not run"
  command -v python3 >/dev/null 2>&1 || fail "python3 is required for the live proof"
  python3 "$ROOT/tests/shep_pi_live.py" "$ROOT" "$pi"
}
