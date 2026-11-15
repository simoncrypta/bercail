#!/usr/bin/env bats
# Shep's Pi inbox extension. The unit half is tests/shep_pi.test.ts (vp test). The live half
# runs `bercail shep run` on the installed Pi with a fake model, and Discuss on a branch.

setup() {
  load test_helper
  isolate
  need node
}

# bats test_tags=live
@test "live: bercail shep run on the installed Pi with a fake model" {
  local pi
  pi="$(real_pi)"
  [[ -n "$pi" ]] || skip "Pi not found; live proof not run"
  command -v script >/dev/null 2>&1 || fail "script (util-linux) is required for the live proof"
  node "$ROOT/tests/shep_pi_live.ts" "$ROOT" "$pi"
}

# bats test_tags=live
@test "live: Shep inbox survives SIGKILL at real Pi delivery boundaries offline" {
  local pi
  pi="$(real_pi)"
  [[ -n "$pi" ]] || skip "Pi not found; live proof not run"
  need flock
  node "$ROOT/tests/shep_inbox_live.ts" "$ROOT" "$pi"
}

# bats test_tags=live
@test "live: Discuss runs the installed Pi on a read-only branch at the question" {
  local pi
  pi="$(real_pi)"
  [[ -n "$pi" ]] || skip "Pi not found; live proof not run"
  node "$ROOT/tests/shep_discuss_live.ts" "$ROOT" "$pi"
}
