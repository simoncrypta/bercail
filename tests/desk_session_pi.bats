#!/usr/bin/env bats
# The desk's Pi extension: which session is running, so a reboot can resume it.
# The unit half is tests/desk_session_pi.test.ts (vp test). The live half needs the installed Pi.

setup() {
  load test_helper
  isolate
  need node
}

# bats test_tags=live
@test "live: the desk extension records the session in the installed Pi" {
  local pi version
  pi="$(real_pi)"
  [[ -n "$pi" ]] || skip "Pi not found; live proof not run"
  version="$("$pi" --version 2>/dev/null || true)"
  pi_at_least "$version" 1.2 || skip "Pi $version is older than 1.2.0; live proof not run"
  command -v script >/dev/null 2>&1 || fail "script (util-linux) is required for the live proof"
  node "$ROOT/tests/desk_session_pi_live.ts" "$ROOT" "$pi"
}
