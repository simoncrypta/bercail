#!/usr/bin/env bats
# review-pr's Pi reviewer extension. The unit half runs with node alone. The
# live half runs the installed Pi with a fake model, headless and as the desk.

setup() {
  load test_helper
  isolate
  need node
}

@test "the reviewer extension's unit checks" {
  node --disable-warning=MODULE_TYPELESS_PACKAGE_JSON --experimental-strip-types \
    "$ROOT/tests/review_pi_test.mjs"
}

# bats test_tags=live
@test "live: the reviewer on the installed Pi with a fake model, headless and as the desk" {
  local pi
  pi="$(real_pi)"
  [[ -n "$pi" ]] || skip "Pi not found; live proof not run"
  command -v python3 >/dev/null 2>&1 || fail "python3 is required for the live proof"
  python3 "$ROOT/tests/review_pi_live.py" "$ROOT" "$pi"
}
