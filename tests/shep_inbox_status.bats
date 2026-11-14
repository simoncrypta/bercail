#!/usr/bin/env bats
# Status distinguishes queued/claimed files from actual session-persistence receipts.

setup() {
  load test_helper
  isolate
  mkdir -p "$BATS_TEST_TMPDIR/bin" "$XDG_STATE_HOME/bercail/shep/inbox" "$XDG_STATE_HOME/bercail/shep/delivered"
  export PATH="$BATS_TEST_TMPDIR/bin:/usr/bin:/bin"
  export HERDR_APP_BIN="$BATS_TEST_TMPDIR/no-herdr-app"
  printf '#!/usr/bin/env bash\nprintf '\''{"terminals":[]}\\n'\''\n' >"$BATS_TEST_TMPDIR/bin/hc"
  chmod +x "$BATS_TEST_TMPDIR/bin/hc"
  STATE="$XDG_STATE_HOME/bercail/shep"
}

@test "shep status does not call an interrupted claim or legacy stamp persisted" {
  printf '{"event_id":"queued"}\n' >"$STATE/inbox/queued.json"
  printf '{"event_id":"claimed"}\n' >"$STATE/delivered/claimed.json"
  printf '{"event_id":"old","delivered_at":"yesterday","delivered_session":"old-session"}\n' >"$STATE/delivered/legacy.json"
  printf '{"event_id":"held","delivery_error":"prior session unavailable"}\n' >"$STATE/delivered/held.json"
  printf '{"event_id":"saved","persisted_entry_id":"entry-1","persisted_at":"2026-11-14T00:00:00Z"}\n' >"$STATE/delivered/saved.json"
  printf '{' >"$STATE/delivered/bad.json.invalid"
  run "$ROOT/bin/bercail" shep status
  [ "$status" -eq 0 ]
  [[ "$output" == *"desk notices: 1 queued, 3 awaiting persistence (1 uncertain), 1 persisted to session"* ]]
  [[ "$output" == *"last persisted: saved at 2026-11-14T00:00:00Z"* ]]
  [[ "$output" == *"Persistence is not handled, action-completed, or read by the person."* ]]
}

@test "shep status shows retained malformed records separately" {
  printf '{' >"$STATE/delivered/bad.json"
  printf '{}\n' >"$STATE/delivered/junk.json.invalid"
  run "$ROOT/bin/bercail" shep status
  [ "$status" -eq 0 ]
  [[ "$output" == *"desk notices: 0 queued, 1 awaiting persistence (0 uncertain), 0 persisted to session"* ]]
  [[ "$output" == *"quarantined: 1"* ]]
}
