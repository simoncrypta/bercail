#!/usr/bin/env bats
# bercail desk restart: an idle desk's Pi ends and Pi starts again on its
# session in the same terminal. A stand-in hc: while the desk's process lives,
# `get` prints the desk; once it is gone, the shell hc gives a kept terminal.
# `send` logs what was typed and plays the new Pi: it runs in that shell's
# process, and its desk extension writes the record for the same session.

setup() {
  load test_helper
  isolate
  need jq
  mkdir -p "$BATS_TEST_TMPDIR/bin" "$BATS_TEST_TMPDIR/terms" "$BATS_TEST_TMPDIR/pathbin"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH" HC_BIN="$BATS_TEST_TMPDIR/bin/hc"
  export HC_LOG="$BATS_TEST_TMPDIR/hc.log" TERMS="$BATS_TEST_TMPDIR/terms" BERCAIL_DESK_RESTART_WAIT=2 BERCAIL_DESK_RESTART_HC_WAIT=1
  export RECORDS="$XDG_STATE_HOME/bercail/desk-sessions"
  mkdir -p "$RECORDS" "$HOME/.local/share/bercail/pi"
  jq -n '["pi", "--model", "fake/opus:high"]' >"$HOME/.local/share/bercail/pi/lead.json"
  # The pi the desk's own PATH finds, which the shell's may not.
  printf '#!/bin/sh\n' >"$BATS_TEST_TMPDIR/pathbin/pi"
  chmod +x "$BATS_TEST_TMPDIR/pathbin/pi"

  cat >"$BATS_TEST_TMPDIR/bin/hc" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$HC_LOG"
t="$TERMS/$2.json"
case "$1" in
  get)
    [[ -f "$t" ]] || exit 3
    # A core that answers once, then stops.
    [[ -z "${HC_HANG:-}" ]] || ! grep -q "^get $2" "$HC_LOG.seen" 2>/dev/null || exec sleep 30
    # A get after the first: what changed meanwhile, in the desk or its record.
    if grep -q "^get $2" "$HC_LOG.seen" 2>/dev/null; then
      [[ ! -f "$TERMS/next" ]] || { jq -c --slurpfile n "$TERMS/next" '. * $n[0]' "$t" >"$t.tmp" && mv "$t.tmp" "$t" && rm "$TERMS/next"; }
      [[ ! -f "$TERMS/next-record" ]] || { jq -c --slurpfile n "$TERMS/next-record" '. * $n[0]' "$RECORDS/$2.json" >"$t.tmp" \
        && mv "$t.tmp" "$RECORDS/$2.json" && rm "$TERMS/next-record"; }
    fi
    printf '%s\n' "$*" >>"$HC_LOG.seen"
    if kill -0 "$(jq -r .pid "$t")" 2>/dev/null || [[ "$(jq -r .pid "$t")" == 7777 ]]; then cat "$t"
    elif [[ -f "$TERMS/finished" ]]; then jq -c '.state = "finished" | .reason = "exited"' "$t"
    else jq -c '.pid = 7777 | .status = null | .foreground = {name: "bash", pid: 7777}' "$t" | tee "$t.tmp" && mv "$t.tmp" "$t"; fi
    ;;
  send)
    printf '%s\n' "$3" >>"$TERMS/sent"
    # The wrapper writes the record first; only a Pi that opened the session adds start_ticks.
    jq -c --arg ticks "${PI_TICKS-55}" --arg file "${PI_FILE:-}" '.pid = 7777 | del(.start_ticks)
      | if $ticks != "" then .start_ticks = $ticks else . end | if $file != "" then .session_file = $file else . end' \
      "$RECORDS/$2.json" >"$RECORDS/$2.tmp" && mv "$RECORDS/$2.tmp" "$RECORDS/$2.json"
    jq -c '.foreground = {name: "pi", pid: 7777} | .status = {app: "pi", state: "idle"}' "$t" >"$t.tmp" && mv "$t.tmp" "$t"
    ;;
esac
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/hc"

  # The desk's Pi: a live process, its PATH in its environ as /proc shows it.
  sleep 300 >/dev/null 2>&1 3>&- &
  DESK_PID=$!
  mkdir -p "$BERCAIL_PROC_DIR/$DESK_PID"
  printf 'HOME=%s\0PATH=%s\0' "$HOME" "$BATS_TEST_TMPDIR/pathbin:/usr/bin:/bin" >"$BERCAIL_PROC_DIR/$DESK_PID/environ"
  desk idle
  WORK="$BATS_TEST_TMPDIR/w"
  mkdir -p "$WORK"
  : >"$WORK/s1.jsonl"
  # Field 22 of /proc/PID/stat, as the desk extension records it.
  TICKS="$(awk '{ print $22 }' "/proc/$DESK_PID/stat")"
  jq -n --argjson pid "$DESK_PID" --arg cwd "$WORK" --arg ticks "$TICKS" '{address: "t9", session: "s1", cwd: $cwd, harness: "pi",
    space: "sp1", issue: "app-1", args: ["--model", "fake/opus:high"], pid: $pid, start_ticks: $ticks, session_file: "\($cwd)/s1.jsonl"}' \
    >"$RECORDS/t9.json"
}

teardown() {
  kill "$DESK_PID" 2>/dev/null || true
}

desk() { # state [jq filter]
  jq -n --argjson pid "$DESK_PID" --arg s "$1" '{address: "t9", state: "live", reason: null, keep: true, pid: $pid,
    status: {app: "pi", state: $s}, foreground: {name: "pi", pid: $pid},
    labels: {"bercail.role": "agent", "bercail.space": "sp1", "bercail.issue": "app-1", "bercail.issue_title": "Fix it"}} | '"${2:-.}" \
    >"$TERMS/t9.json"
}

alive() { kill -0 "$DESK_PID" 2>/dev/null; }

@test "an idle desk's Pi ends, its shell gets the resume line on the pi its own PATH found, and the new Pi opens the session" {
  local out
  out="$("$ROOT/bin/bercail" desk restart t9)" || fail "restart: $out"
  [[ "$out" == "desk t9 (app-1: Fix it) restarted on session s1" ]] || fail "output: $out"
  ! alive || fail "the old Pi still runs"
  [[ "$(cat "$TERMS/sent")" == "cd $WORK && TERM=xterm-256color COLORTERM=truecolor exec bercail-desk-agent $BATS_TEST_TMPDIR/pathbin/pi --session-id s1 --model fake/opus:high" ]] \
    || fail "typed: $(cat "$TERMS/sent")"
  [[ "$(jq -c '[.pid, .session, .session_file]' "$RECORDS/t9.json")" == "[7777,\"s1\",\"$WORK/s1.jsonl\"]" ]] || fail "record: $(cat "$RECORDS/t9.json")"
}

@test "a Pi that never opens the session after the resume line fails the restart" {
  local out
  out="$(PI_TICKS="" "$ROOT/bin/bercail" desk restart t9 2>&1)" && fail "restarted: $out"
  [[ "$out" == "error: desk t9 (app-1: Fix it) got its resume line, but no new Pi opened its session; hc read t9 shows why" ]] || fail "output: $out"
}

@test "a Pi that opens another file for a session already written fails the restart" {
  local out
  out="$(PI_FILE=/s/other.jsonl "$ROOT/bin/bercail" desk restart t9 2>&1)" && fail "restarted: $out"
  [[ "$out" == *"got its resume line, but no new Pi opened its session"* ]] || fail "output: $out"
}

@test "a working, blocked or unknown desk is refused, and nothing is ended or typed" {
  local state out
  for state in working blocked unknown; do
    desk "$state"
    if out="$("$ROOT/bin/bercail" desk restart t9 2>&1)"; then fail "$state: restarted: $out"; fi
    [[ "$out" == "error: desk t9 (app-1: Fix it) is not restarted: it is $state; bercail desk restart t9 once it is idle" ]] || fail "$state: $out"
  done
  alive || fail "a refused desk's Pi was ended"
  [[ ! -f "$TERMS/sent" ]] || fail "typed: $(cat "$TERMS/sent")"
}

@test "a background Shep, a terminal hc does not keep, and a record of another process are refused" {
  local out
  desk idle '.labels["bercail.shep"] = "bg"'
  out="$("$ROOT/bin/bercail" desk restart t9 2>&1)" && fail "bg: $out"
  [[ "$out" == *"it is a background Shep"* ]] || fail "bg: $out"
  desk idle '.keep = false'
  out="$("$ROOT/bin/bercail" desk restart t9 2>&1)" && fail "no keep: $out"
  [[ "$out" == *"hc does not keep it"* ]] || fail "no keep: $out"
  desk idle
  cp "$RECORDS/t9.json" "$BATS_TEST_TMPDIR/record"
  jq '.pid = 1' "$BATS_TEST_TMPDIR/record" >"$RECORDS/t9.json"
  out="$("$ROOT/bin/bercail" desk restart t9 2>&1)" && fail "other pid: $out"
  [[ "$out" == *"its desk record does not name the Pi running there" ]] || fail "other pid: $out"
  # The same pid, started at another time: a process that took over a dead one's pid.
  jq '.start_ticks = "1"' "$BATS_TEST_TMPDIR/record" >"$RECORDS/t9.json"
  out="$("$ROOT/bin/bercail" desk restart t9 2>&1)" && fail "other start: $out"
  [[ "$out" == *"its desk record does not name the Pi running there" ]] || fail "other start: $out"
  alive || fail "a refused desk's Pi was ended"
}

@test "a desk that started a turn or switched session after the first look is left alone" {
  local out
  printf '{"status": {"state": "working"}}' >"$TERMS/next"
  out="$("$ROOT/bin/bercail" desk restart t9 2>&1)" && fail "restarted: $out"
  [[ "$out" == "error: desk t9 (app-1: Fix it) is not restarted: it is working; bercail desk restart t9 once it is idle" ]] || fail "turn: $out"
  desk idle
  : >"$HC_LOG.seen"
  printf '{"session": "s2", "session_file": "/s/s2.jsonl"}' >"$TERMS/next-record"
  out="$("$ROOT/bin/bercail" desk restart t9 2>&1)" && fail "restarted: $out"
  [[ "$out" == *"is not restarted: its Pi or session changed since bercail first looked" ]] || fail "session: $out"
  alive || fail "the desk's Pi was ended"
  [[ ! -f "$TERMS/sent" ]] || fail "typed: $(cat "$TERMS/sent")"
}

@test "a desk with a follow-up or model switch waiting, text not sent yet, or messages queued in Pi is left alone" {
  local out runtime="$XDG_STATE_HOME/bercail/runtime/$DESK_PID.json" ups="$XDG_STATE_HOME/bercail/desk-follow-ups/t9"
  mkdir -p "$ups" "$XDG_STATE_HOME/bercail/runtime" "$XDG_STATE_HOME/bercail/desk-commands"
  printf '{"delivery": "queued"}' >"$ups/1.json"
  out="$("$ROOT/bin/bercail" desk restart t9 2>&1)" && fail "follow-up: $out"
  [[ "$out" == *"is not restarted: a follow-up waits for its Pi; bercail desk restart t9 once it is idle" ]] || fail "follow-up: $out"
  printf 'not json' >"$ups/0.json"
  out="$("$ROOT/bin/bercail" desk restart t9 2>&1)" && fail "unreadable: $out"
  [[ "$out" == *"is not restarted: its follow-ups cannot be read" ]] || fail "unreadable: $out"
  rm "$ups/0.json"
  chmod 000 "$ups"
  out="$("$ROOT/bin/bercail" desk restart t9 2>&1)" && { chmod 755 "$ups"; fail "unlistable: $out"; }
  chmod 755 "$ups"
  [[ "$out" == *"is not restarted: its follow-ups cannot be read" ]] || fail "unlistable: $out"
  printf '{"delivery": "submitted"}' >"$ups/1.json"
  jq -n --argjson pid "$DESK_PID" '{id: "m1", pid: $pid, model: "fake/fable"}' >"$XDG_STATE_HOME/bercail/desk-commands/t9.json"
  out="$("$ROOT/bin/bercail" desk restart t9 2>&1)" && fail "model: $out"
  [[ "$out" == *"is not restarted: a model switch waits for its Pi; bercail desk restart t9 once it is idle" ]] || fail "model: $out"
  rm "$XDG_STATE_HOME/bercail/desk-commands/t9.json"
  jq -n --argjson pid "$DESK_PID" --arg t "$TICKS" '{pid: $pid, start_ticks: $t, idle: true, pending: false, draft: true}' >"$runtime"
  out="$("$ROOT/bin/bercail" desk restart t9 2>&1)" && fail "draft: $out"
  [[ "$out" == *"is not restarted: its editor holds text not sent yet" ]] || fail "draft: $out"
  jq -n --argjson pid "$DESK_PID" --arg t "$TICKS" '{pid: $pid, start_ticks: $t, idle: true, pending: true, draft: false}' >"$runtime"
  out="$("$ROOT/bin/bercail" desk restart t9 2>&1)" && fail "pending: $out"
  [[ "$out" == *"is not restarted: Pi has messages queued; bercail desk restart t9 once it is idle" ]] || fail "pending: $out"
  alive || fail "the desk's Pi was ended"
  [[ ! -f "$TERMS/sent" ]] || fail "typed: $(cat "$TERMS/sent")"
}

@test "a core that stops answering after the first look leaves the desk alone, and does not hang" {
  local out start="$SECONDS"
  out="$(HC_HANG=1 "$ROOT/bin/bercail" desk restart t9 2>&1)" && fail "restarted: $out"
  [[ "$out" == "error: hc did not answer; desk t9 (app-1: Fix it) is left alone" ]] || fail "output: $out"
  ((SECONDS - start < 10)) || fail "waited $((SECONDS - start))s on hc"
  alive || fail "the desk's Pi was ended"
}

@test "a desk whose flags hold an API key is left alone, and the key is never sent or shown" {
  local out flag
  for flag in '"--api-key", "sk-test-sentinel"' '"--api-key=sk-test-sentinel"'; do
    jq --argjson a "[$flag]" '.args += $a' "$RECORDS/t9.json" >"$RECORDS/x" && cp "$RECORDS/x" "$RECORDS/t9.json"
    out="$("$ROOT/bin/bercail" desk restart t9 2>&1)" && fail "restarted: $out"
    [[ "$out" == *"is not restarted: its flags hold an API key, which the resume line would pass to hc; restart it by hand" ]] || fail "$flag: $out"
    [[ "$out" != *sk-test-sentinel* ]] || fail "key shown: $out"
    jq '.args = ["--model", "fake/opus:high"]' "$RECORDS/x" >"$RECORDS/t9.json"
  done
  alive || fail "the desk's Pi was ended"
  [[ ! -f "$TERMS/sent" ]] || fail "typed: $(cat "$TERMS/sent")"
}

@test "a terminal that finished instead of getting a shell fails with the steps to start it again" {
  local out
  : >"$TERMS/finished"
  out="$("$ROOT/bin/bercail" desk restart t9 2>&1)" && fail "restarted: $out"
  [[ "$out" == *"hc gave it no shell"*"/resume session s1" ]] || fail "output: $out"
  [[ ! -f "$TERMS/sent" ]] || fail "typed: $(cat "$TERMS/sent")"
}
