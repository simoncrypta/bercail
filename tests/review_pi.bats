#!/usr/bin/env bats
# review-pr's Pi reviewer extension. The unit half is tests/review_pi.test.ts (vp test). The
# live half runs the installed Pi with a fake model, headless and as the desk.

setup() {
  load test_helper
  isolate
  need node
}

# bats test_tags=live
@test "live: the reviewer on the installed Pi with a fake model, headless and as the desk" {
  local pi
  pi="$(real_pi)"
  [[ -n "$pi" ]] || skip "Pi not found; live proof not run"
  command -v script >/dev/null 2>&1 || fail "script (util-linux) is required for the live proof"
  node "$ROOT/tests/review_pi_live.ts" "$ROOT" "$pi"
}
