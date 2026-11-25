#!/usr/bin/env bats
# The routines' scheduler (lib/routine.sh): bercail routine tick and loop, the
# bercail-routines terminal that runs the loop, and what says whether it is
# alive. Each @test is its own HOME; the clock is a stand-in date that reads
# $CLOCK, and hc is a stand-in that logs what it was asked.

setup() {
  load test_helper
  isolate
  need flock jq sha256sum
  REAL_DATE="$(command -v date)"
  export PATH="$BATS_TEST_TMPDIR/bin:/usr/bin:/bin"
  export MEET="$BATS_TEST_TMPDIR/meet" Q="$BATS_TEST_TMPDIR/q" CLOCK="$BATS_TEST_TMPDIR/clock"
  export BERCAIL_ROUTINE_BOOT_WAIT=0 HC_BIN="$BATS_TEST_TMPDIR/bin/hc" HC_LOG="$BATS_TEST_TMPDIR/hc.log"
  mkdir -p "$MEET" "$Q" "$XDG_CONFIG_HOME/bercail" "$XDG_STATE_HOME/bercail/shep/inbox"
  CONFIG="$XDG_CONFIG_HOME/bercail/config.toml"
  STATE="$XDG_STATE_HOME/bercail/routines"
  INBOX="$XDG_STATE_HOME/bercail/shep/inbox"
  : >"$CONFIG"
  # date +%s reads $CLOCK when there is one, and $CLOCK.then is what it reads
  # after that once; anything else is the real date.
  printf '#!/bin/sh\nif [ "$1" = "+%%s" ] && [ -f "$CLOCK" ]; then cat "$CLOCK"; [ ! -f "$CLOCK.then" ] || mv "$CLOCK.then" "$CLOCK"; else exec %s "$@"; fi\n' \
    "$REAL_DATE" >"$BATS_TEST_TMPDIR/bin/date"
  chmod +x "$BATS_TEST_TMPDIR/bin/date"
  # A query that logs it ran and prints $Q/<name>.out. $Q/<name>.hold makes it
  # say it started and wait for $MEET/release.<name>.
  cat >"$Q/query" <<'EOF'
#!/usr/bin/env bash
name="$1"
echo ran >>"$MEET/ran.$name"
if [[ -e "$Q/$name.hold" ]]; then
  touch "$MEET/started.$name"
  for _ in $(seq 100); do [[ -e "$MEET/release.$name" ]] && break; sleep 0.1; done
fi
[[ ! -e "$Q/$name.out" ]] || cat "$Q/$name.out"
EOF
  chmod +x "$Q/query"
  # hc: ls lists $HC_TERMS (a JSON array of {address, name, state}); run and
  # kill log their argv to $HC_LOG; kill takes the terminal at its address out.
  HC_TERMS="$BATS_TEST_TMPDIR/terms.json"
  echo '[]' >"$HC_TERMS"
  cat >"$HC_BIN" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$HC_LOG"
case "\$1" in
  ls) jq -c '{terminals: .}' "$HC_TERMS" ;;
  run) ;;
  kill) jq -c --arg a "\$2" 'map(select(.address != \$a))' "$HC_TERMS" >"$HC_TERMS.new" && mv "$HC_TERMS.new" "$HC_TERMS" ;;
  *) exit 2 ;;
esac
EOF
  chmod +x "$HC_BIN"
}

teardown() {
  [[ -z "${LOOP:-}" ]] || kill -- -"$LOOP" 2>/dev/null || true
  touch "$MEET"/release.a "$MEET"/release.b "$MEET"/release.c 2>/dev/null || true
}

bercail() { "$ROOT/bin/bercail" "$@"; }
tick() { "$ROOT/bin/bercail" routine tick 3>&-; }
# slot_run NAME SLOT: the run a tick starts for SLOT, in the foreground.
slot_run() {
  bash -c 'source "$ROOT/lib/common.sh"; for n in "${BERCAIL_LIBS[@]}"; do source "$ROOT/lib/$n.sh"; done
    source "$ROOT/lib/routine.sh"; routine_run "$1" 0 "$2"' _ "$1" "$2"
}
# due NAME EPOCH: NAME's state.json says it is next due then.
due() { mkdir -p "$STATE/$1"; printf '{"next_due":%s}\n' "$2" >"$STATE/$1/state.json"; }

# declare NAME [SCHEDULE]: a command routine running the stand-in query.
declare_routine() {
  printf '[routine.%s]\ncommand = ["%s", "%s"]\n%s\n\n' "$1" "$Q/query" "$1" "${2:-every = \"1h\"}" >>"$CONFIG"
}

at() { printf '%s' "$1" >"$CLOCK"; }
# at_then A B: the clock reads A once (the tick's), then B (its run's).
at_then() { at "$1"; printf '%s' "$2" >"$CLOCK.then"; }
ran() { [[ -e "$MEET/ran.$1" ]] && wc -l <"$MEET/ran.$1" | tr -d ' ' || echo 0; }
runs() { [[ -e "$STATE/$1/runs.jsonl" ]] && wc -l <"$STATE/$1/runs.jsonl" | tr -d ' ' || echo 0; }
state() { jq -c "$2" "$STATE/$1/state.json"; }

# Waits up to 10 s for COMMAND to succeed.
await() {
  local _
  for _ in $(seq 100); do
    eval "$1" && return 0
    sleep 0.1
  done
  fail "timed out: $1"
}

# Waits for NAME's Nth run line, then for its run to let go of its lock.
await_run() {
  await "[[ \$(runs $1) -ge $2 ]]"
  await "flock -n '$STATE/$1/lock' true"
}

# A Monday at 07:30 local time, in epoch seconds.
monday() { "$REAL_DATE" -d '2026-11-23 07:30:00' +%s; }

@test "a due routine runs once: a second tick at the same time starts nothing" {
  declare_routine a
  at 1800000000
  out="$(tick)" || fail "$out"
  [[ "$out" == *"a: started"* ]] || fail "first tick: $out"
  await_run a 1
  out="$(tick)" || fail "$out"
  [[ "$out" != *started* ]] || fail "second tick: $out"
  [[ "$(ran a)" == 1 ]] || fail "ran $(ran a) times"
  [[ "$(state a .next_due)" == $((1800000000 + 3600)) ]] || fail "next due: $(state a .next_due)"
}

@test "an every routine runs again that long after its last start, by the wall clock" {
  declare_routine a
  at 1800000000
  tick >/dev/null
  await_run a 1
  at $((1800000000 + 3599))
  tick >/dev/null
  [[ "$(ran a)" == 1 ]] || fail "ran before its hour"
  at $((1800000000 + 3600))
  out="$(tick)"
  await_run a 2
  [[ "$(ran a)" == 2 ]] || fail "ran $(ran a) times: $out"
  [[ "$(jq -r .due "$STATE/a/runs.jsonl" | tail -n 1)" == "$(TZ=UTC "$REAL_DATE" -d @$((1800000000 + 3600)) +%Y-%m-%dT%H:%M:%SZ)" ]] \
    || fail "the run is for its slot: $(tail -n 1 "$STATE/a/runs.jsonl")"
}

@test "an overdue routine runs once after a clock jump, however many slots it missed, for its first missed slot" {
  declare_routine a
  at 1800000000
  tick >/dev/null
  await_run a 1
  # Asleep for 5 hours and a bit: four slots missed.
  at $((1800000000 + 5 * 3600 + 120))
  tick >/dev/null
  await_run a 2
  tick >/dev/null
  [[ "$(ran a)" == 2 ]] || fail "ran $(ran a) times"
  [[ "$(state a .next_due)" == $((1800000000 + 6 * 3600 + 120)) ]] || fail "next due: $(state a .next_due)"
  [[ "$(state a .slot)" == $((1800000000 + 3600)) ]] || fail "slot: $(state a .slot)"
}

@test "an at routine waits for its next slot, and after days away runs once" {
  declare_routine a 'at = "07:30"'
  mon="$(monday)"
  at $((mon - 600))
  tick >/dev/null
  [[ "$(ran a)" == 0 ]] || fail "ran before 07:30"
  [[ "$(state a .next_due)" == "$mon" ]] || fail "next due: $(state a .next_due)"
  at $((mon + 3 * 86400 + 5400))
  tick >/dev/null
  await_run a 1
  tick >/dev/null
  [[ "$(ran a)" == 1 ]] || fail "ran $(ran a) times"
  [[ "$(state a .next_due)" == "$("$REAL_DATE" -d '2026-11-27 07:30:00' +%s)" ]] || fail "next due: $(state a .next_due)"
}

@test "a routine still running is skipped quietly: no second run and no run line" {
  declare_routine a
  at 1800000000
  touch "$Q/a.hold"
  tick >/dev/null
  await "[[ -e '$MEET/started.a' ]]"
  at $((1800000000 + 2 * 3600))
  out="$(tick)" || fail "$out"
  [[ "$out" != *started* ]] || fail "started a running one: $out"
  touch "$MEET/release.a"
  await_run a 1
  [[ "$(ran a)" == 1 && "$(runs a)" == 1 ]] || fail "ran $(ran a), $(runs a) run lines"
}

@test "with 2 routines running, a third due one waits for a free slot without a run line" {
  declare_routine a
  declare_routine b
  declare_routine c
  at 1800000000
  touch "$Q/a.hold" "$Q/b.hold"
  out="$(tick)"
  [[ "$out" == *"a: started"* && "$out" == *"b: started"* && "$out" != *"c: started"* ]] || fail "$out"
  await "[[ -e '$MEET/started.a' && -e '$MEET/started.b' ]]"
  tick >/dev/null
  [[ "$(runs c)" == 0 ]] || fail "c: $(cat "$STATE/c/runs.jsonl")"
  touch "$MEET/release.a"
  await_run a 1
  out="$(tick)"
  [[ "$out" == *"c: started"* ]] || fail "$out"
  await_run c 1
  touch "$MEET/release.b"
  await_run b 1
}

@test "a paused routine is not run, and its waiting event goes to Shep's inbox once there is one" {
  declare_routine a
  at 1800000000
  rm -rf "$INBOX"
  mkdir -p "$STATE/a"
  # Paused by its third failure before Shep's first start: its event waits.
  printf '{"next_due":1700000000,"failures":3,"paused":true,"sent":{},"outbox":[%s]}\n' \
    '{"source":"bercail","schema":"bercail.routine/v1","kind":"routine","sink":"shep","event_id":"routine:a:20261123T073000Z","routine":"a","outcome":"paused"}' \
    >"$STATE/a/state.json"
  tick >/dev/null
  [[ "$(ran a)" == 0 && "$(runs a)" == 0 ]] || fail "a paused routine ran"
  [[ "$(state a '.outbox | length')" == 1 ]] || fail "sent with no inbox"
  mkdir -p "$INBOX"
  tick >/dev/null
  [[ -f "$INBOX/routine_a_20261123T073000Z.json" ]] || fail "not sent: $(ls "$INBOX")"
  [[ "$(state a '.outbox | length')" == 0 ]] || fail "still in the outbox"
  bercail routine resume a >/dev/null
  tick >/dev/null
  await_run a 1
  [[ "$(ran a)" == 1 ]] || fail "resumed and overdue, it runs once"
}

@test "a run that could not write its state is not retried every tick, only after 15 minutes, for the same slot" {
  declare_routine a
  at 1800000000
  due a 1799999000
  # mktemp fails for state.json, so its write does, and nothing else.
  printf '#!/bin/sh\ncase "$*" in *state.json.*) [ -e "$Q/nostate" ] && exit 1 ;; esac\nexec %s "$@"\n' \
    "$(command -v mktemp)" >"$BATS_TEST_TMPDIR/bin/mktemp"
  chmod +x "$BATS_TEST_TMPDIR/bin/mktemp"
  touch "$Q/nostate"
  tick >/dev/null
  await "[[ \$(ran a) -ge 1 ]]"
  await "flock -n '$STATE/a/lock' true"
  at $((1800000000 + 60))
  out="$(tick)"
  [[ "$out" != *started* ]] || fail "retried a minute later: $out"
  at $((1800000000 + 899))
  tick >/dev/null
  [[ "$(ran a)" == 1 ]] || fail "retried before 15 minutes"
  [[ "$(runs a)" == 1 && "$(state a .next_due)" == 1799999000 ]] || fail "its run line, and its state as it was"
  rm "$Q/nostate"
  at $((1800000000 + 900))
  out="$(tick)"
  [[ "$out" == *"a: started"* ]] || fail "not retried after 15 minutes: $out"
  await_run a 2
  [[ "$(state a .next_due)" == $((1800000000 + 900 + 3600)) ]] || fail "next due: $(state a .next_due)"
  [[ "$(jq -rs 'map(.due) | unique | length' "$STATE/a/runs.jsonl")" == 1 ]] || fail "two slots: $(cat "$STATE/a/runs.jsonl")"
  [[ "$(state a .slot)" == 1799999000 ]] || fail "slot: $(state a .slot)"
}

@test "two runs a tick started for one slot: when the first cannot write its state, the second waits and keeps its stamp" {
  declare_routine a
  at 1800000001
  due a 1800000000
  printf '#!/bin/sh\ncase "$*" in *state.json.*) [ -e "$Q/nostate" ] && exit 1 ;; esac\nexec %s "$@"\n' \
    "$(command -v mktemp)" >"$BATS_TEST_TMPDIR/bin/mktemp"
  chmod +x "$BATS_TEST_TMPDIR/bin/mktemp"
  touch "$Q/nostate"
  # Both were started before either took the lock, so the tick saw no try.
  slot_run a 1800000000 >/dev/null 2>&1 && fail "its state was written"
  [[ "$(jq -c . "$STATE/a/tried.json")" == '{"due":1800000000,"at":1800000001}' ]] || fail "$(cat "$STATE/a/tried.json")"
  # The second started a second earlier; under the lock, the clock says 08:00:01.
  at_then 1800000000 1800000001
  out="$(slot_run a 1800000000)" || fail "$out"
  [[ "$out" == "a: skipped (tried): "* ]] || fail "$out"
  [[ "$(ran a)" == 1 && "$(jq -c . "$STATE/a/tried.json")" == '{"due":1800000000,"at":1800000001}' ]] || fail "ran $(ran a): $(cat "$STATE/a/tried.json")"
  rm "$Q/nostate"
  at $((1800000001 + 900))
  out="$(tick)"
  [[ "$out" == *"a: started"* ]] || fail "$out"
  await_run a 3
  [[ "$(ran a)" == 2 && "$(state a .slot)" == 1800000000 ]] || fail "ran $(ran a): $(cat "$STATE/a/state.json")"
}

@test "an every routine that never ran has its first due written before its run starts" {
  declare_routine a
  at 1800000000
  touch "$Q/a.hold"
  tick >/dev/null
  await "[[ -e '$MEET/started.a' ]]"
  [[ "$(state a .next_due)" == 1800000000 ]] || fail "first due: $(cat "$STATE/a/state.json")"
  touch "$MEET/release.a"
  await_run a 1
  [[ "$(state a '.slot, .next_due')" == $'1800000000\n1800003600' ]] || fail "$(cat "$STATE/a/state.json")"
}

@test "a run by hand meets the slot that was due, so a stale scheduled run for it is skipped as done" {
  declare_routine a
  at 1800000000
  due a 1799999900
  bercail routine run a >/dev/null
  [[ "$(state a '.slot, .next_due')" == $'1799999900\n1800003600' ]] || fail "$(cat "$STATE/a/state.json")"
  out="$(slot_run a 1799999900)" || fail "$out"
  [[ "$out" == "a: skipped (done): "* ]] || fail "$out"
  [[ "$(ran a)" == 1 ]] || fail "ran $(ran a) times"
}

@test "a clock that went back behind the last slot met strands nothing: next_due comes after that slot" {
  declare_routine a
  at 1800000000
  due a 1800000000
  tick >/dev/null
  await_run a 1
  [[ "$(state a '.slot, .next_due')" == $'1800000000\n1800003600' ]] || fail "$(cat "$STATE/a/state.json")"
  # Two hours back, a run by hand: next_due stays after the slot it met.
  at $((1800000000 - 7200))
  bercail routine run a >/dev/null
  [[ "$(state a '.slot, .next_due')" == $'1800000000\n1800003600' ]] || fail "$(cat "$STATE/a/state.json")"
  at 1800003600
  tick >/dev/null
  await_run a 3
  [[ "$(ran a)" == 3 && "$(state a .slot)" == 1800003600 ]] || fail "ran $(ran a) times: $(cat "$STATE/a/state.json")"
}

@test "a slot the run's own clock says is ahead is skipped as early and stays due, for a run in its window" {
  declare_routine a 'at = "07:30"'
  mon="$(monday)"
  due a "$mon"
  # The tick chose 07:30 at 07:30; then the clock went back to 05:30.
  at_then "$mon" $((mon - 7200))
  tick >/dev/null
  await_run a 1
  [[ "$(jq -r .reason "$STATE/a/runs.jsonl")" == early ]] || fail "$(cat "$STATE/a/runs.jsonl")"
  [[ "$(ran a)" == 0 && "$(state a .next_due)" == "$mon" ]] || fail "ran $(ran a), next due $(state a .next_due)"
  # A pause, a run by hand it skips, and a resume, all at 05:30, change nothing.
  bercail routine pause a >/dev/null
  bercail routine run a >/dev/null
  bercail routine resume a >/dev/null
  # At the slot, it runs: the early run's query never ran, so nothing waits.
  at "$mon"
  printf '{"key":"k","title":"found at 07:30"}\n' >"$Q/a.out"
  out="$(tick)"
  [[ "$out" == *"a: started"* ]] || fail "$out"
  await_run a 3
  [[ "$(ran a)" == 1 && "$(tail -n 1 "$STATE/a/runs.jsonl" | jq -r .outcome)" == emitted ]] || fail "$(cat "$STATE/a/runs.jsonl")"
}

@test "a query that ran but could not write its run line waits 15 minutes too, after an early skip" {
  declare_routine a
  due a 1800000000
  at $((1800000000 - 7200))
  slot_run a 1800000000 >/dev/null
  at 1800000000
  printf '{"key":"k","title":"K"}\n' >"$Q/a.out"
  # A file where its outputs/ folder goes: the run stops before its line.
  : >"$STATE/a/outputs"
  tick >/dev/null
  await "[[ \$(ran a) -ge 1 ]]"
  await "flock -n '$STATE/a/lock' true"
  [[ "$(runs a)" == 1 && "$(state a .next_due)" == 1800000000 ]] || fail "$(cat "$STATE/a/state.json")"
  at 1800000060
  out="$(tick)"
  [[ "$out" != *started* ]] || fail "ran its query again a minute later: $out"
  rm "$STATE/a/outputs"
  at 1800000900
  out="$(tick)"
  [[ "$out" == *"a: started"* ]] || fail "$out"
  await_run a 2
  [[ "$(ran a)" == 2 ]] || fail "ran $(ran a) times"
}

@test "a run goes by the clock once it holds its locks: back to before its slot, it is early" {
  declare_routine a 'at = "07:30"'
  mon="$(monday)"
  due a "$mon"
  # 07:30 when the run started, 05:30 once it held its locks.
  at_then "$mon" $((mon - 7200))
  out="$(slot_run a "$mon")" || fail "$out"
  [[ "$out" == "a: skipped (early): "* ]] || fail "$out"
  [[ "$(ran a)" == 0 && "$(state a .next_due)" == "$mon" && ! -e "$STATE/a/tried.json" ]] || fail "ran $(ran a): $(cat "$STATE/a/state.json")"
}

@test "a run goes by the clock once it holds its locks: three hours on, it is due an hour after that" {
  declare_routine a
  due a 1800000000
  # 08:00 when the run started, 11:00 once it held its locks.
  at_then 1800000000 $((1800000000 + 3 * 3600))
  slot_run a 1800000000 >/dev/null || fail "the run"
  [[ "$(state a .next_due)" == $((1800000000 + 4 * 3600)) ]] || fail "$(cat "$STATE/a/state.json")"
  [[ "$(jq -r .at "$STATE/a/tried.json")" == $((1800000000 + 3 * 3600)) ]] || fail "$(cat "$STATE/a/tried.json")"
  out="$(tick)"
  [[ "$out" != *started* && "$(ran a)" == 1 ]] || fail "ran $(ran a): $out"
}

@test "a try stamped after now, from before the clock went back, does not hold a run back" {
  declare_routine a
  due a 1799500000
  printf '{"due":1799500000,"at":1800000000}\n' >"$STATE/a/tried.json"
  at 1799700000
  out="$(tick)"
  [[ "$out" == *"a: started"* ]] || fail "$out"
  await_run a 1
}

@test "the first tick after a boot waits 5 minutes" {
  declare_routine a
  at 1800000000
  out="$(BERCAIL_ROUTINE_BOOT_WAIT=999999999 tick)" || fail "$out"
  [[ "$out" == *"booted"* ]] || fail "says why it waits: $out"
  [[ "$(ran a)" == 0 && ! -e "$STATE/a/runs.jsonl" ]] || fail "ran right after a boot"
  out="$(tick)"
  [[ "$out" == *"a: started"* ]] || fail "$out"
  await_run a 1
}

@test "an invalid routine is left out of the tick, and the others still run" {
  printf '[routine.bad]\ncommand = ["true"]\n\n' >"$CONFIG"
  declare_routine a
  at 1800000000
  out="$(tick 2>&1)" || fail "$out"
  [[ "$out" == *"a: started"* && "$out" != *"bad: started"* ]] || fail "$out"
  await_run a 1
}

@test "one loop per machine: a second loop refuses while the first runs, and shep status says when it ticked" {
  declare_routine a
  at 1800000000
  loop_line() { bercail shep status | grep '^routine loop: '; }
  [[ "$(loop_line)" == "routine loop: not running (never ticked); "* ]] || fail "$(loop_line)"
  # Its own process group, for teardown to stop its sleep too (bercail-oniw).
  set -m
  "$ROOT/bin/bercail" routine loop >"$MEET/loop.out" 2>&1 3>&- &
  LOOP=$!
  set +m
  await "[[ -f '$STATE/tick.json' ]]"
  await_run a 1
  out="$(bercail routine loop 2>&1)" && fail "a second loop ran: $out"
  [[ "$out" == *"already running"* ]] || fail "$out"
  [[ "$(loop_line)" == "routine loop: running, last tick $("$REAL_DATE" -d @1800000000 '+%Y-%m-%d %H:%M')" ]] || fail "$(loop_line)"
  # The loop alone: its sleep lives on, and must not hold the lock.
  kill "$LOOP"
  wait "$LOOP" 2>/dev/null || true
  await "flock -n '$STATE/.loop.lock' true"
  [[ "$(loop_line)" == "routine loop: not running (last tick "*"); "* ]] || fail "$(loop_line)"
}

@test "doctor fails without a loop when routines are declared" {
  declare_routine a
  # shellcheck source=/dev/null
  source "$ROOT/lib/common.sh"
  # shellcheck source=/dev/null
  source "$ROOT/lib/routine.sh"
  out="$(doctor_routines)" && fail "doctor passed without a loop: $out"
  grep -q '^  missing  routine loop: not running' <<<"$out" || fail "$out"
  mkdir -p "$STATE"
  exec {held}>>"$STATE/.loop.lock"
  flock -n "$held"
  out="$(doctor_routines)" || fail "doctor failed with a loop: $out"
  grep -q '^  ok  routine loop: running' <<<"$out" || fail "$out"
  exec {held}>&-
}

@test "the board gets one line, only when a routine failed or is paused" {
  declare_routine a
  declare_routine b
  declare_routine c
  # shellcheck source=/dev/null
  source "$ROOT/lib/common.sh"
  # shellcheck source=/dev/null
  source "$ROOT/lib/routine.sh"
  [[ -z "$(routine_board_line)" ]] || fail "nothing wrong, but: $(routine_board_line)"
  mkdir -p "$STATE/a" "$STATE/b"
  printf '{"failures":1,"paused":false}\n' >"$STATE/b/state.json"
  [[ "$(routine_board_line)" == "Routines: b failed 1 time in a row (bercail routine show b)" ]] || fail "$(routine_board_line)"
  printf '{"failures":3,"paused":true}\n' >"$STATE/a/state.json"
  printf '{"failures":1,"paused":false}\n' >"$STATE/b/state.json"
  out="$(routine_board_line)"
  [[ "$out" == "Routines: a is paused after 3 failures in a row (bercail routine resume a once it is fixed); b failed 1 time in a row (bercail routine show b)" ]] \
    || fail "$out"
}

@test "the loop starts as the hidden terminal bercail-routines once, on the backend when there is one" {
  # shellcheck source=/dev/null
  source "$ROOT/lib/common.sh"
  # shellcheck source=/dev/null
  source "$ROOT/lib/routine.sh"
  routine_start_loop
  routine_start_loop_called="$(grep -c '^run ' "$HC_LOG")"
  [[ "$routine_start_loop_called" == 1 ]] || fail "$(cat "$HC_LOG")"
  grep -q -- '^run --bg --no-parent --no-notify --rm --name bercail-routines --label bercail.role=routines bash -lc .*exec bercail routine loop$' "$HC_LOG" \
    || fail "$(cat "$HC_LOG")"
  echo '[{"address":"t9","name":"bercail-routines","state":"live"}]' >"$HC_TERMS"
  : >"$HC_LOG"
  routine_start_loop
  ! grep -q '^run ' "$HC_LOG" || fail "started a second: $(cat "$HC_LOG")"
  # A client: the backend's loop is the one, and one here does not count.
  printf '[herdr]\nbackend = "box"\n' >"$CONFIG"
  routine_start_loop
  grep -q -- '^run --bg --no-parent --no-notify --rm --on box --name bercail-routines ' "$HC_LOG" || fail "$(cat "$HC_LOG")"
  echo '[{"address":"box/t9","name":"bercail-routines","state":"live"}]' >"$HC_TERMS"
  : >"$HC_LOG"
  routine_start_loop
  ! grep -q '^run ' "$HC_LOG" || fail "box's loop is live: $(cat "$HC_LOG")"
}

@test "an update restarts a live loop, and starts none where there was none" {
  # shellcheck source=/dev/null
  source "$ROOT/lib/common.sh"
  # shellcheck source=/dev/null
  source "$ROOT/lib/routine.sh"
  out="$(routine_restart_loop 2>&1)" || fail "$out"
  ! grep -q '^run \|^kill ' "$HC_LOG" || fail "$(cat "$HC_LOG")"
  echo '[{"address":"t9","name":"bercail-routines","state":"live"}]' >"$HC_TERMS"
  out="$(routine_restart_loop 2>&1)" || fail "$out"
  [[ "$(grep -E '^(kill|run) ' "$HC_LOG" | cut -d' ' -f1-2 | xargs)" == "kill t9 run --bg" ]] || fail "$(cat "$HC_LOG")"
  [[ "$out" == "restarted the routine loop (hc terminal bercail-routines)" ]] || fail "$out"
}
