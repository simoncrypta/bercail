#!/usr/bin/env bats
# bercail desk model: Shep, for the person, switches a live desk's model through
# the desk's Pi extension, never through chat. Stand-ins for hc and pi; the live
# proof runs the installed Pi with a fake provider.

setup() {
  load test_helper
  isolate
  need jq node
  mkdir -p "$BATS_TEST_TMPDIR/bin" "$BATS_TEST_TMPDIR/terms"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH" HC_BIN="$BATS_TEST_TMPDIR/bin/hc"
  export HC_LOG="$BATS_TEST_TMPDIR/hc.log" PI_LOG="$BATS_TEST_TMPDIR/pi.log" TERMS="$BATS_TEST_TMPDIR/terms"
  export BERCAIL_DESK_MODEL_WAIT=0
  RECORDS="$XDG_STATE_HOME/bercail/desk-sessions"
  COMMANDS="$XDG_STATE_HOME/bercail/desk-commands"
  mkdir -p "$RECORDS" "$HOME/.local/share/bercail/pi"
  jq -n '["pi", "--model", "fake/opus:high", "-e", "npm:bridge", "-e", "/x/guard.ts"]' >"$HOME/.local/share/bercail/pi/lead.json"

  # hc: `get NAME` prints terms/NAME.json (exit 3 when there is none); every call is logged.
  cat >"$BATS_TEST_TMPDIR/bin/hc" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$HC_LOG"
[[ "$1" == get ]] || exit 0
[[ -f "$TERMS/$2.json" ]] || exit 3
cat "$TERMS/$2.json"
SH
  # pi: lists fake/opus and fake/fable; logs its argv.
  cat >"$BATS_TEST_TMPDIR/bin/pi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$PI_LOG"
[[ " $* " == *" --list-models "* ]] || exit 2
printf 'provider  model  context  max-out  thinking  images\n'
printf 'fake      opus   1M       128K     yes       yes\n'
printf 'fake      fable  1M       128K     yes       yes\n'
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/hc" "$BATS_TEST_TMPDIR/bin/pi"

  # The desk agent: a live process its record names.
  sleep 300 >/dev/null 2>&1 3>&- &
  DESK_PID=$!
  desk t9 agent
  jq -n --argjson pid "$DESK_PID" '{address: "t9", session: "s1", cwd: "/w", harness: "pi", space: "sp1",
    args: ["--model", "fake/opus:high"], pid: $pid}' >"$RECORDS/t9.json"
}

teardown() {
  kill "$DESK_PID" 2>/dev/null || true
}

desk() { # address role [name]
  jq -n --arg a "$1" --arg r "$2" '{address: $a, state: "live", labels: {"bercail.role": $r, "bercail.space": "sp1"}}' \
    >"$TERMS/${3:-$1}.json"
}

# Answers the next request the way the desk extension does.
answer() { # status field=value...
  (
    for _ in $(seq 1 100); do
      if [[ -f "$COMMANDS/t9.json" ]]; then
        jq -c --arg s "$1" --arg extra "$2" '{id, status: $s} + ($extra | split("=") | {(.[0]): .[1]})' \
          "$COMMANDS/t9.json" >"$COMMANDS/t9.done.json"
        rm -f "$COMMANDS/t9.json"
        exit 0
      fi
      sleep 0.05
    done
  ) >/dev/null 2>&1 3>&- &
}

@test "a desk by name gets a request for its own Pi, and says what it switched to" {
  desk t9 agent my-desk
  export BERCAIL_DESK_MODEL_WAIT=5
  answer switched model=fake/fable:medium
  run "$ROOT/bin/bercail" desk model my-desk fake/fable:medium
  [[ "$status" -eq 0 && "$output" == *"t9 switched to fake/fable:medium"* ]] || fail "switch: $status $output"
  grep -qx -- '--offline --list-models -e npm:bridge -e /x/guard.ts' "$PI_LOG" || fail "listed with the lead's extensions: $(cat "$PI_LOG")"
}

@test "a busy desk keeps the request for its next idle moment" {
  run "$ROOT/bin/bercail" desk model t9 fake/fable
  [[ "$status" -eq 0 && "$output" == *"t9 is busy: it switches to fake/fable when its current run ends"* ]] || fail "$output"
  jq -e --argjson pid "$DESK_PID" '.pid == $pid and .model == "fake/fable" and (.id | length > 0)' "$COMMANDS/t9.json" >/dev/null \
    || fail "request: $(cat "$COMMANDS/t9.json")"
  [[ "$(stat -c %a "$COMMANDS/t9.json")" == 600 ]] || fail "the request is private"
  ! grep -q '^send' "$HC_LOG" || fail "nothing is typed into the desk: $(cat "$HC_LOG")"
}

@test "a model Pi does not list is refused before any request" {
  run "$ROOT/bin/bercail" desk model t9 fake/nope:high
  [[ "$status" -eq 1 && "$output" == *"Pi has no model fake/nope"* ]] || fail "$status $output"
  [[ ! -e "$COMMANDS/t9.json" ]] || fail "no request for an unknown model"
  run "$ROOT/bin/bercail" desk model t9 fable
  [[ "$status" -eq 1 && "$output" == *"PROVIDER/MODEL[:thinking]"* ]] || fail "a bare id: $output"
}

@test "the desk's own refusal fails the command with its reason" {
  export BERCAIL_DESK_MODEL_WAIT=5
  answer refused "reason=no login for fake/fable"
  run "$ROOT/bin/bercail" desk model t9 fake/fable
  [[ "$status" -eq 1 && "$output" == *"t9 refused fake/fable: no login for fake/fable"* ]] || fail "$status $output"
}

@test "only a running Pi desk takes a model" {
  desk t8 bstack-builder
  run "$ROOT/bin/bercail" desk model t8 fake/fable
  [[ "$status" -eq 1 && "$output" == *"t8 is not a live desk"* ]] || fail "a sibling: $output"
  run "$ROOT/bin/bercail" desk model t7 fake/fable
  [[ "$status" -eq 1 && "$output" == *"no live terminal t7"* ]] || fail "gone: $output"
  kill "$DESK_PID"
  wait "$DESK_PID" 2>/dev/null || true
  run "$ROOT/bin/bercail" desk model t9 fake/fable
  [[ "$status" -eq 1 && "$output" == *"t9 has no running Pi desk agent"* ]] || fail "dead desk: $output"
  [[ ! -e "$COMMANDS/t9.json" ]] || fail "no request without a desk agent"
}

# bats test_tags=live
@test "live: the installed Pi switches a desk's model from the CLI and back, and chat text does not" {
  local pi version
  rm "$BATS_TEST_TMPDIR/bin/pi"
  hash -r
  pi="$(real_pi)"
  [[ -n "$pi" ]] || skip "Pi not found; live proof not run"
  version="$("$pi" --version 2>/dev/null || true)"
  pi_at_least "$version" 1.2 || skip "Pi $version is older than 1.2.0; live proof not run"
  need script
  node "$ROOT/tests/desk_model_pi_live.ts" "$ROOT" "$pi"
}
