#!/usr/bin/env bats
# bercail routine (lib/routine.sh): a routine's run, its locks and its state, a
# case for each step of tests/statechart/routine-run/RoutineRun.tla. Each @test
# is its own HOME; the queries are stand-in scripts, and nothing schedules.

setup() {
  load test_helper
  isolate
  need flock jq sha256sum
  export PATH="$BATS_TEST_TMPDIR/bin:/usr/bin:/bin"
  export MEET="$BATS_TEST_TMPDIR/meet" Q="$BATS_TEST_TMPDIR/q"
  mkdir -p "$MEET" "$Q" "$XDG_CONFIG_HOME/bercail"
  CONFIG="$XDG_CONFIG_HOME/bercail/config.toml"
  STATE="$XDG_STATE_HOME/bercail/routines"
  : >"$CONFIG"
  # A query that prints $Q/<name>.out as its findings and logs that it ran.
  # $Q/<name>.exit exits with that status, after the line in $Q/<name>.err on
  # stderr. $Q/<name>.hold makes it say it started and wait for $MEET/release.
  cat >"$Q/query" <<'EOF'
#!/usr/bin/env bash
name="$1"
echo ran >>"$MEET/ran.$name"
echo "$$" >"$MEET/pid.$name"
if [[ -e "$Q/$name.hold" ]]; then
  touch "$MEET/started.$name"
  for _ in $(seq 100); do [[ -e "$MEET/release" ]] && break; sleep 0.1; done
fi
[[ ! -e "$Q/$name.err" ]] || cat "$Q/$name.err" >&2
[[ ! -e "$Q/$name.out" ]] || cat "$Q/$name.out"
exit "$(cat "$Q/$name.exit" 2>/dev/null || echo 0)"
EOF
  chmod +x "$Q/query"
}

routine() { "$ROOT/bin/bercail" routine "$@"; }

# declare NAME [SCHEDULE]: a command routine running the stand-in query.
declare_routine() {
  printf '[routine.%s]\ncommand = ["%s", "%s"]\n%s\n\n' "$1" "$Q/query" "$1" "${2:-every = \"4h\"}" >>"$CONFIG"
}

# findings NAME JSON...: what NAME's query prints next.
findings() {
  local name="$1"
  shift
  printf '%s\n' "$@" >"$Q/$name.out"
}

runs() { cat "$STATE/$1/runs.jsonl"; }
last_run() { tail -n 1 "$STATE/$1/runs.jsonl"; }
state() { jq -c "$2" "$STATE/$1/state.json"; }
ran() { [[ -e "$MEET/ran.$1" ]] && wc -l <"$MEET/ran.$1" | tr -d ' ' || echo 0; }

# Waits up to 10 s for a file.
await() {
  local _
  for _ in $(seq 100); do
    [[ -e "$1" ]] && return 0
    sleep 0.1
  done
  fail "no $1"
}

# hold NAME: starts a run of NAME in the background that waits in its query
# until release; $! is its pid, and its output goes to $MEET/NAME.bg.
hold() {
  touch "$Q/$1.hold"
  "$ROOT/bin/bercail" routine run "$1" >"$MEET/$1.bg" 2>&1 3>&- &
  await "$MEET/started.$1"
  rm "$Q/$1.hold"
}

@test "a command routine's new findings are emitted: the run is logged with its counts, and the hashes kept" {
  declare_routine check
  findings check '{"key":"a","title":"A is stale"}' '{"key":"b","title":"B","detail":"why","repo":"~/Work/x","issue":"x-1"}'
  out="$(routine run check)" || fail "run: $out"
  [[ "$out" == "check: emitted, 2 found (2 new, 0 changed); run "* ]] || fail "summary: $out"
  line="$(last_run check)"
  jq -e '.outcome == "emitted" and .counts == {found: 2, new: 2, changed: 0}
    and (.event | startswith("routine:check:")) and .error == null and .start <= .end' <<<"$line" >/dev/null \
    || fail "run line: $line"
  [[ "$(state check '.sent | keys')" == '["a","b"]' ]] || fail "sent: $(cat "$STATE/check/state.json")"
  [[ "$(state check '.failures, .paused')" == $'0\nfalse' ]] || fail "state: $(cat "$STATE/check/state.json")"
}

@test "a command's ~/ is your home, and it runs there" {
  mkdir -p "$HOME/bin"
  printf '#!/bin/sh\nprintf "{\\"key\\":\\"cwd\\",\\"title\\":\\"%%s\\"}\\n" "$PWD"\n' >"$HOME/bin/where"
  chmod +x "$HOME/bin/where"
  printf '[routine.where]\ncommand = ["~/bin/where"]\nevery = "1h"\n' >"$CONFIG"
  out="$(cd "$BATS_TEST_TMPDIR" && routine run where)" || fail "$out"
  id="$(last_run where | jq -r .id)"
  [[ "$(jq -r .title "$STATE/where/outputs/$id.jsonl")" == "$HOME" ]] || fail "$(cat "$STATE/where/outputs/$id.jsonl")"
}

@test "each command entry is one argument, newlines and all" {
  printf '#!/bin/sh\nprintf "{\\"key\\":\\"argc\\",\\"title\\":\\"%%s\\"}\\n" "$#"\n' >"$Q/argc"
  chmod +x "$Q/argc"
  printf '[routine.argc]\ncommand = ["%s", "first\\nsecond", "third"]\nevery = "1h"\n' "$Q/argc" >"$CONFIG"
  routine run argc >/dev/null
  id="$(last_run argc | jq -r .id)"
  [[ "$(jq -r .title "$STATE/argc/outputs/$id.jsonl")" == 2 ]] || fail "$(cat "$STATE/argc/outputs/$id.jsonl")"
}

@test "a second run with the same findings is quiet: skipped, nothing new, no event" {
  declare_routine check
  findings check '{"key":"a","title":"A"}'
  routine run check >/dev/null
  out="$(routine run check)" || fail "second run: $out"
  [[ "$out" == "check: skipped (quiet), 1 found, nothing new or changed; run "* ]] || fail "summary: $out"
  jq -e '.outcome == "skipped" and .reason == "quiet" and .event == null and .counts.found == 1' <<<"$(last_run check)" >/dev/null \
    || fail "run line: $(last_run check)"
  [[ "$(ran check)" == 2 ]]
}

@test "a changed finding counts as changed, and a key that went away is new when it comes back" {
  declare_routine check
  findings check '{"key":"a","title":"A"}' '{"key":"b","title":"B"}'
  routine run check >/dev/null
  findings check '{"key":"a","title":"A, now worse"}'
  routine run check >/dev/null
  jq -e '.outcome == "emitted" and .counts == {found: 1, new: 0, changed: 1}' <<<"$(last_run check)" >/dev/null \
    || fail "changed: $(last_run check)"
  findings check '{"key":"a","title":"A, now worse"}' '{"key":"b","title":"B"}'
  routine run check >/dev/null
  jq -e '.outcome == "emitted" and .counts == {found: 2, new: 1, changed: 0}' <<<"$(last_run check)" >/dev/null \
    || fail "back: $(last_run check)"
}

@test "run --dry-run prints the event and writes no state, no run and no inbox file" {
  declare_routine check
  findings check '{"key":"a","title":"A"}'
  out="$(routine run check --dry-run)" || fail "dry run: $out"
  jq -e '.source == "bercail" and .schema == "bercail.routine/v1" and .kind == "routine" and .sink == "shep"
    and .routine == "check" and .outcome == "emitted" and .counts == {found: 1, new: 1, changed: 0}
    and (.event_id | test("^routine:check:[0-9]{8}T[0-9]{6}Z$")) and (.run | type == "string")
    and (.text | contains("bercail routine show check --run"))' <<<"$out" >/dev/null || fail "event: $out"
  [[ ! -e "$STATE/check/state.json" && ! -e "$STATE/check/runs.jsonl" ]] || fail "dry run wrote: $(ls -R "$STATE")"
  [[ -z "$(find "$XDG_STATE_HOME" -path '*inbox*')" ]]
  out="$(routine run check)"
  [[ "$out" == "check: emitted, "* ]] || fail "the real run after it: $out"
}

@test "a query that exits non-zero fails with its last stderr line, and counts one failure" {
  declare_routine check
  echo 2 >"$Q/check.exit"
  printf 'starting\nno such repo: ~/Work/gone\n' >"$Q/check.err"
  run routine run check
  [[ "$status" -eq 1 ]] || fail "status $status: $output"
  [[ "$output" == "check: failed: exit 2: no such repo: ~/Work/gone; run "* ]] || fail "summary: $output"
  jq -e '.outcome == "failed" and .error == "exit 2: no such repo: ~/Work/gone" and .counts == null' <<<"$(last_run check)" >/dev/null \
    || fail "run line: $(last_run check)"
  [[ "$(state check '.failures, .paused')" == $'1\nfalse' ]]
}

@test "output that is not findings fails the run and names the line; nothing is kept as sent" {
  declare_routine check
  for bad in 'not json' '{"title":"no key"}' '["a"]' '{"key":"a","title":"A"}
{"key":"a","title":"twice"}'; do
    printf '%s\n' "$bad" >"$Q/check.out"
    run routine run check
    [[ "$status" -eq 1 && "$output" == "check: failed: "* ]] || fail "accepted $bad: $output"
    routine resume check >/dev/null
  done
  jq -e '.error | test("line 1")' <<<"$(sed -n 1p "$STATE/check/runs.jsonl")" >/dev/null || fail "$(runs check)"
  jq -e '.error | test("key a.*twice")' <<<"$(last_run check)" >/dev/null || fail "$(last_run check)"
  [[ "$(state check '.sent')" == '{}' ]]
}

@test "64 KB of small findings is read whole, hashes and all" {
  declare_routine check
  jq -nc '[range(2300) | {key: "k\(.)", title: ""}] | .[]' >"$Q/check.out"
  (($(wc -c <"$Q/check.out") > 55000)) || fail "only $(wc -c <"$Q/check.out") bytes"
  out="$(routine run check)" || fail "$out"
  [[ "$out" == "check: emitted, 2300 found (2300 new, 0 changed); run "* ]] || fail "$out"
  [[ "$(state check '.sent | length')" == 2300 ]]
  out="$(routine run check)"
  [[ "$out" == "check: skipped (quiet), 2300 found, "* ]] || fail "$out"
}

@test "a run whose line cannot be written says so and counts nothing, so the next run finds the same again" {
  declare_routine check
  findings check '{"key":"a","title":"A"}'
  mkdir -p "$STATE/check"
  : >"$STATE/check/runs.jsonl"
  chmod 444 "$STATE/check/runs.jsonl"
  run routine run check
  chmod 644 "$STATE/check/runs.jsonl"
  [[ "$status" -eq 1 && "$output" == *"could not write its run"* && "$output" != *emitted* ]] || fail "$output"
  out="$(routine run check)"
  [[ "$out" == "check: emitted, 1 found (1 new, 0 changed); run "* ]] || fail "$out"
}

@test "an at routine is next due at its local time, also across a clock change" {
  [[ -e /usr/share/zoneinfo/America/Toronto && -e /usr/share/zoneinfo/Australia/Lord_Howe ]] || unavailable "no tz database"
  # shellcheck source=/dev/null
  source "$ROOT/lib/common.sh"
  # shellcheck source=/dev/null
  source "$ROOT/lib/routine.sh"
  export TZ=America/Toronto
  # Saturday 2026-10-31 12:00 EDT; the clocks go back that night.
  next="$(_routine_next_due '{"at":"07:30","every":null}' 1793462400)"
  [[ "$(printf '%(%F %H:%M)T' "$next")" == "2026-11-01 07:30" ]] || fail "$(printf '%(%F %H:%M %Z)T' "$next")"
  next="$(_routine_next_due '{"at":"07:30","every":null}' 1793430000)"
  [[ "$(printf '%(%F %H:%M)T' "$next")" == "2026-10-31 07:30" ]] || fail "before the slot: $(printf '%(%F %H:%M)T' "$next")"
  # Lord Howe Island moves its clocks by half an hour, on 2026-10-04.
  export TZ=Australia/Lord_Howe
  next="$(_routine_next_due '{"at":"07:30","every":null}' "$(TZ=Australia/Lord_Howe date -d '2026-10-03 12:00' +%s)")"
  [[ "$(printf '%(%F %H:%M)T' "$next")" == "2026-10-04 07:30" ]] || fail "Lord Howe: $(printf '%(%F %H:%M %Z)T' "$next")"
  [[ "$(_routine_next_due '{"at":null,"every":"2h"}' 1000)" == 8200 ]]
}

@test "output over 64 KB fails the run" {
  declare_routine check
  jq -nc '[range(700) | {key: "k\(.)", title: ("x" * 100)}] | .[]' >"$Q/check.out"
  run routine run check
  [[ "$status" -eq 1 && "$output" == "check: failed: output over 64 KB; run "* ]] || fail "$output"
}

@test "a run past its time is killed with its process group and fails" {
  printf '[routine.slow]\ncommand = ["bash", "-c", "sleep 30 & echo $! >%s; wait"]\nevery = "1h"\n' "$MEET/child" >"$CONFIG"
  start=$SECONDS
  BERCAIL_ROUTINE_TIMEOUT=1 run routine run slow
  [[ "$status" -eq 1 && "$output" == "slow: failed: timed out after 1s; run "* ]] || fail "$output"
  ((SECONDS - start < 10)) || fail "took $((SECONDS - start))s"
  kill -0 "$(cat "$MEET/child")" 2>/dev/null && fail "the query's child outlived the kill"
  jq -e '.outcome == "failed" and .error == "timed out after 1s"' <<<"$(last_run slow)" >/dev/null
}

@test "3 failures in a row pause the routine; a good run in between starts the count again" {
  declare_routine check
  echo 1 >"$Q/check.exit"
  routine run check >/dev/null || true
  routine run check >/dev/null || true
  rm "$Q/check.exit"
  routine run check >/dev/null
  [[ "$(state check '.failures')" == 0 ]]
  echo 1 >"$Q/check.exit"
  for _ in 1 2; do routine run check >/dev/null || true; done
  [[ "$(state check '.failures, .paused')" == $'2\nfalse' ]] || fail "$(cat "$STATE/check/state.json"; runs check)"
  run routine run check
  [[ "$output" == *"failed 3 times in a row and is paused; bercail routine resume check" ]] || fail "$output"
  [[ "$(state check '.failures, .paused')" == $'3\ntrue' ]]
}

@test "a paused routine's run is skipped without running its query, and resume runs it again with no failures" {
  declare_routine check
  echo 1 >"$Q/check.exit"
  routine run check >/dev/null || true
  out="$(routine pause check)"
  [[ "$out" == "check: paused" ]] || fail "pause: $out"
  out="$(routine run check)" || fail "paused run: $out"
  [[ "$out" == "check: skipped (paused); bercail routine resume check" ]] || fail "$out"
  [[ "$(ran check)" == 1 ]] || fail "the query ran while paused"
  jq -e '.outcome == "skipped" and .reason == "paused"' <<<"$(last_run check)" >/dev/null
  out="$(routine resume check)"
  [[ "$out" == "check: resumed" ]] || fail "resume: $out"
  [[ "$(state check '.failures, .paused')" == $'0\nfalse' ]]
  rm "$Q/check.exit"
  routine run check >/dev/null
  [[ "$(ran check)" == 2 ]]
}

@test "a run while one of the same routine holds its lock is skipped as overlap, by hand too" {
  declare_routine check
  hold check
  pid=$!
  out="$(routine run check)" || fail "$out"
  [[ "$out" == "check: skipped (overlap): a run of it is still going" ]] || fail "$out"
  [[ "$(ran check)" == 1 ]]
  touch "$MEET/release"
  wait "$pid"
  jq -sc 'map(.outcome + "/" + (.reason // ""))' "$STATE/check/runs.jsonl" | grep -qx '\["skipped/overlap","skipped/quiet"\]' \
    || fail "$(runs check)"
}

@test "with 2 routines running, a third is skipped as load; once one ends it runs" {
  declare_routine one
  declare_routine two
  declare_routine three
  hold one
  a=$!
  hold two
  b=$!
  out="$(routine run three)" || fail "$out"
  [[ "$out" == "three: skipped (load): 2 routines are running" ]] || fail "$out"
  [[ "$(ran three)" == 0 ]]
  touch "$MEET/release"
  wait "$a" "$b"
  out="$(routine run three)"
  [[ "$out" == "three: skipped (quiet), "* ]] || fail "$out"
}

@test "a pause that returns while a run waits for its locks stops that run" {
  declare_routine check
  # flock, whose first flock -n (the routine's lock) waits for $MEET/open.
  real="$(command -v flock)"
  cat >"$BATS_TEST_TMPDIR/bin/flock" <<GATE
#!/usr/bin/env bash
if [[ "\$1" == -n && ! -e "\$MEET/gated" ]]; then
  touch "\$MEET/gated"
  for _ in \$(seq 100); do [[ -e "\$MEET/open" ]] && break; sleep 0.1; done
fi
exec "$real" "\$@"
GATE
  chmod +x "$BATS_TEST_TMPDIR/bin/flock"
  "$ROOT/bin/bercail" routine run check >"$MEET/check.bg" 2>&1 3>&- &
  pid=$!
  await "$MEET/gated"
  routine pause check >/dev/null
  touch "$MEET/open"
  wait "$pid"
  [[ "$(cat "$MEET/check.bg")" == "check: skipped (paused); bercail routine resume check" ]] || fail "$(cat "$MEET/check.bg")"
  [[ "$(ran check)" == 0 ]]
}

@test "a pause while a run is going holds after the run ends" {
  declare_routine check
  findings check '{"key":"a","title":"A"}'
  hold check
  pid=$!
  routine pause check >/dev/null
  touch "$MEET/release"
  wait "$pid"
  [[ "$(cat "$MEET/check.bg")" == "check: emitted, "* ]] || fail "$(cat "$MEET/check.bg")"
  [[ "$(state check '.paused, (.sent | keys)')" == $'true\n["a"]' ]] || fail "$(cat "$STATE/check/state.json")"
}

@test "a runner stopped by a signal stops its query, and the next run takes the lock" {
  declare_routine check
  hold check
  pid=$!
  kill -TERM "$pid"
  wait "$pid" || true
  for _ in $(seq 50); do kill -0 "$(cat "$MEET/pid.check")" 2>/dev/null || break; sleep 0.1; done
  kill -0 "$(cat "$MEET/pid.check")" 2>/dev/null && fail "the query outlived its runner"
  out="$(routine run check)"
  [[ "$out" == "check: skipped (quiet), "* ]] || fail "$out"
}

@test "a query that ignores TERM is killed when its runner is stopped" {
  printf '[routine.stubborn]\ncommand = ["bash", "-c", "trap \\"\\" TERM; echo $$ >%s; sleep 30"]\nevery = "1h"\n' "$MEET/pid.stubborn" >"$CONFIG"
  "$ROOT/bin/bercail" routine run stubborn >/dev/null 2>&1 3>&- &
  pid=$!
  await "$MEET/pid.stubborn"
  kill -TERM "$pid"
  wait "$pid" || true
  kill -0 "$(cat "$MEET/pid.stubborn")" 2>/dev/null && fail "the query outlived its runner"
  true
}

@test "a child the query leaves behind does not keep the routine's lock" {
  printf '[routine.leaves]\ncommand = ["bash", "-c", "sleep 30 >/dev/null 2>&1 & echo $! >%s"]\nevery = "1h"\n' "$MEET/child" >"$CONFIG"
  routine run leaves >/dev/null
  child="$(cat "$MEET/child")"
  out="$(routine run leaves)"
  kill "$child" 2>/dev/null || true
  [[ "$out" == "leaves: skipped (quiet), "* ]] || fail "second run: $out"
}

@test "without flock, a run refuses with the fix and never runs its query" {
  declare_routine check
  # PATH as it is, less flock.
  local dir nofl="$BATS_TEST_TMPDIR/no-flock" path="" dirs
  IFS=: read -ra dirs <<<"$PATH"
  for dir in "${dirs[@]}"; do
    if [[ -x "$dir/flock" ]]; then
      mkdir -p "$nofl"
      ln -sf "$dir"/* "$nofl"/
      rm -f "$nofl/flock"
      dir="$nofl"
    fi
    path="${path:+$path:}$dir"
  done
  PATH="$path" run routine run check
  [[ "$status" -eq 1 ]] || fail "status $status: $output"
  [[ "$output" == *"no flock"*"never runs unlocked"* ]] || fail "$output"
  [[ "$(ran check)" == 0 ]]
}

@test "list shows each routine's schedule, next due, last outcome and pause, and names a bad entry" {
  declare_routine daily 'at = "07:30"'
  declare_routine often 'every = "1d"'
  printf '[routine.broken]\nevery = "30m"\n' >>"$CONFIG"
  findings often '{"key":"a","title":"A"}'
  routine run often >/dev/null
  routine pause daily >/dev/null
  out="$(routine list)"
  grep -qE '^daily +at 07:30 +next [0-9-]+ 07:30 +never run +paused$' <<<"$out" || fail "daily: $out"
  grep -qE '^often +every 1d +next [0-9-]+ [0-9:]+ +emitted +active$' <<<"$out" || fail "often: $out"
  grep -qx 'broken  invalid: no run or command; every must be <n>h or <n>d, at least 1h, not 30m' <<<"$out" || fail "broken: $out"
}

@test "show lists the last runs, and --run shows what that run found, new or changed" {
  declare_routine check
  findings check '{"key":"a","title":"A"}'
  routine run check >/dev/null
  findings check '{"key":"a","title":"A"}' '{"key":"b","title":"B","detail":"why","repo":"~/Work/x","issue":"x-1"}'
  routine run check >/dev/null
  id="$(last_run check | jq -r .id)"
  out="$(routine show check)"
  [[ "$(grep -c '^  [0-9]\{8\}T' <<<"$out")" == 2 ]] || fail "runs: $out"
  grep -q "^  $id  emitted, 2 found (1 new, 0 changed)" <<<"$out" || fail "last run: $out"
  out="$(routine show check --run "$id")"
  grep -qx "run $id: emitted, 2 found (1 new, 0 changed)" <<<"$out" || fail "header: $out"
  grep -qx '  same     a  A' <<<"$out" || fail "a: $out"
  grep -qx '  new      b  B' <<<"$out" || fail "b: $out"
  grep -qx '           why (~/Work/x, x-1)' <<<"$out" || fail "b's detail: $out"
  run routine show check --run 20000101T000000Z-1
  [[ "$status" -eq 1 && "$output" == *"no run 20000101T000000Z-1"* ]] || fail "$output"
}

@test "the last 100 runs and the last 10 outputs are kept, in a state folder with a space" {
  export XDG_STATE_HOME="$BATS_TEST_TMPDIR/state space"
  STATE="$XDG_STATE_HOME/bercail/routines"
  declare_routine check
  mkdir -p "$STATE/check/outputs"
  for i in $(seq 1 100); do
    printf '{"id":"20200101T000%03dZ-1","outcome":"skipped","reason":"quiet"}\n' "$i" >>"$STATE/check/runs.jsonl"
  done
  for i in $(seq -w 1 10); do : >"$STATE/check/outputs/20200101T0000${i}Z-1.jsonl"; done
  routine run check >/dev/null
  [[ "$(wc -l <"$STATE/check/runs.jsonl")" -eq 100 ]] || fail "$(wc -l <"$STATE/check/runs.jsonl") runs"
  [[ "$(sed -n 1p "$STATE/check/runs.jsonl" | jq -r .id)" == 20200101T000002Z-1 ]] || fail "$(sed -n 1p "$STATE/check/runs.jsonl")"
  [[ "$(find "$STATE/check/outputs" -type f | wc -l)" -eq 10 ]] || fail "$(ls "$STATE/check/outputs")"
  [[ ! -e "$STATE/check/outputs/20200101T000001Z-1.jsonl" ]]
}

@test "a routine that is not declared, or not valid, is refused with the fix; pause and resume too" {
  printf '[routine.broken]\ncommand = ["x"]\nrun = "cleanup"\nat = "25:00"\n' >"$CONFIG"
  for cmd in "run nope" "pause nope" "resume nope" "show nope"; do
    # shellcheck disable=SC2086 # two words on purpose
    run routine $cmd
    [[ "$status" -eq 1 && "$output" == *"no routine nope in $CONFIG"* ]] || fail "$cmd: $output"
  done
  run routine run broken
  [[ "$status" -eq 1 ]] || fail "$output"
  [[ "$output" == *"routine broken: run and command are both set; at must be HH:MM, not 25:00"* ]] || fail "$output"
}

@test "doctor names each bad routine and does not call their keys unknown" {
  cat >>"$CONFIG" <<'EOF'
[routine.good]
command = ["true"]
every = "2h"

[routine.both]
run = "cleanup"
command = ["true"]
every = "1h"

[routine.nowhen]
command = ["true"]

[routine.toosoon]
command = ["true"]
every = "0h"

[routine.typo]
command = ["true"]
every = "1d"
evry = "1d"

[routine."has.dot"]
command = ["true"]
every = "1d"
EOF
  # shellcheck source=/dev/null
  source "$ROOT/lib/common.sh"
  # shellcheck source=/dev/null
  source "$ROOT/lib/config.sh"
  # shellcheck source=/dev/null
  source "$ROOT/lib/routine.sh"
  out="$(doctor_config; doctor_routines)" || fail "a bad routine is not a failure: $out"
  grep -qx '  invalid  routine both: run and command are both set' <<<"$out" || fail "$out"
  grep -qx '  invalid  routine nowhen: no at or every' <<<"$out" || fail "$out"
  grep -qx '  invalid  routine toosoon: every must be <n>h or <n>d, at least 1h, not 0h' <<<"$out" || fail "$out"
  grep -qx '  invalid  routine "has.dot": a name is letters, digits, - and _' <<<"$out" || fail "$out"
  grep -qx '  ok  routine good: every 2h' <<<"$out" || fail "$out"
  grep -q 'unknown  \[routine.typo\] evry (nothing reads it)' <<<"$out" || fail "$out"
  ! grep -q 'unknown  \[routine.good\]' <<<"$out" || fail "$out"
}

@test "the statechart was last checked on the spec, configs and view as they are" {
  cd "$ROOT/tests/statechart/routine-run"
  sha256sum --quiet -c sha256sums || fail "stale: run tests/statechart/routine-run/check.sh"
}
