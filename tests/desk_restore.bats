#!/usr/bin/env bats
# Desks come back after a reboot: which records get resumed, what gets typed, and
# how it is wired. Nothing here reaches a real hc core or the real home.
# The libraries read YES, DRY_RUN, DESK_* and BERCAIL_PACKAGED, and call the overrides.
# shellcheck disable=SC2034,SC2329

setup() {
  load test_helper
  isolate
  # Pipeline assertions (sort | sed, and the libraries' own pipes) must still fail the test.
  set -o pipefail
  mkdir -p "$BATS_TEST_TMPDIR/bin" "$XDG_RUNTIME_DIR/herdr-core" "$HOME"
  # A mise shim reads $HOME, which the test replaces: take the real node now.
  NODE="$(type -ap node | grep -v '/mise/shims/' | head -1 || true)"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH" HC_BIN="$BATS_TEST_TMPDIR/bin/hc"
  export DESK_RESTORE_POLL=0 INSTALL_SRC="$ROOT"
  YES=1
  DRY_RUN=0
  hash -r

  # shellcheck source=/dev/null
  source "$ROOT/lib/common.sh"
  # shellcheck source=/dev/null
  source "$ROOT/lib/detect.sh"
  # shellcheck source=/dev/null
  source "$ROOT/lib/config.sh"
  # shellcheck source=/dev/null
  source "$ROOT/lib/desk.sh"

  # This machine may really be Omarchy. The test HOME says which one it is.
  is_omarchy() { [[ -d "$HOME/.local/share/omarchy" ]]; }

  # Most cases exercise restore planning, not profile composition.
  mkdir -p "$BERCAIL_SHARE_DIR/pi"
  printf '["pi"]\n' >"$BERCAIL_SHARE_DIR/pi/lead.json"
  RECORDS="$XDG_STATE_HOME/bercail/desk-sessions"
  SENT="$BATS_TEST_TMPDIR/sent"
  TERMS="$BATS_TEST_TMPDIR/terms"
  MARKER="$XDG_RUNTIME_DIR/bercail-desk-restore.done"
  SOCK="$XDG_RUNTIME_DIR/herdr-core/default.sock"
  mkdir -p "$TERMS"
  install_hc
  install_journalctl
  install_notify_send

  SHUTDOWN=1000000
  fresh=$((SHUTDOWN - 60))
  bare='{"state":"live","reason":null,"reported":false,"pid":7,"argv":["/usr/bin/bash"],
    "foreground":{"name":"bash","pid":7},"labels":{"bercail.role":"agent","bercail.space":"sp1"}}'
  running='{"state":"live","reason":null,"reported":true,"pid":9,"argv":["bercail-desk-agent"],
    "foreground":{"name":"pi","pid":9},"labels":{"bercail.role":"agent","bercail.space":"sp1"}}'
  busy="$(jq -c '.foreground = {name: "vim", pid: 11}' <<<"$bare")"
  inner="$(jq -c '.reported = true' <<<"$bare")"
  parked="$(jq -c '.reason = "stopped_by_restart" | .foreground = null | .pid = null' <<<"$bare")"
  starting="$(jq -c '.foreground = null' <<<"$bare")"
  finished="$(jq -c '.state = "finished" | .reason = "exited"' <<<"$bare")"
  plain="$(jq -c '.labels = {}' <<<"$bare")"
  sibling="$(jq -c '.labels = {"bercail.role": "bstack-builder", "bercail.space": "sp1"}' <<<"$bare")"
  working="$(jq -c '.labels = {"bercail.role": "bstack-judge", "bercail.space": "sp1"}
    | .foreground = {name: "pi", pid: 12} | .records = {"0199-judge": {"app": "pi", "state": "working"}}' <<<"$running")"
}

expect() { [[ "$1" == "$2" ]] || fail "$3: got '$1', want '$2'"; }

# Polls a signal. The hook backgrounds its restore; a fixed sleep would race it.
wait_for() {
  local _
  for _ in $(seq 1 100); do
    if eval "$1"; then return 0; fi
    sleep 0.1
  done
  fail "timed out: $1"
}

record() { # session [harness] [space]
  jq -cn --arg s "$1" --arg h "${2:-pi}" --arg sp "${3:-sp1}" \
    '{session: $s, harness: $h, space: $sp, cwd: "/w", issue: "x-1", args: []}'
}

fact() {
  jq -cn --arg a "$1" --argjson r "$2" --argjson m "$3" --argjson t "$4" \
    --argjson c "${5:-true}" --argjson p "${6:-false}" \
    --argjson o "${7:-[]}" \
    '{address: $a, record: $r, mtime: $m, terminal: $t, cwd_exists: $c, in_ps: $p, open_sessions: $o}'
}

verdict() {
  printf '%s\n' "$@" | jq -s . | desk_restore_plan "$SHUTDOWN" | jq -r '.[] | "\(.address) \(.action) \(.why)"'
}

one() { verdict "$(fact t1 "$@")"; }

install_hc() {
  cat >"$BATS_TEST_TMPDIR/bin/hc" <<EOF
#!/usr/bin/env bash
case "\$1" in
  ls)
    [[ ! -f "$BATS_TEST_TMPDIR/hc-down" ]] || exit 1
    if [[ -f "$BATS_TEST_TMPDIR/hc-fails" ]]; then
      n="\$(cat "$BATS_TEST_TMPDIR/hc-fails")"
      if [[ "\$n" != 0 ]]; then
        printf '%s' "\$((n - 1))" >"$BATS_TEST_TMPDIR/hc-fails"
        exit 1
      fi
    fi
    shift
    label=""
    while ((\$#)); do
      if [[ "\$1" == --label ]]; then
        label="\${2:-}"
        shift 2
      elif [[ "\$1" == --label=* ]]; then
        label="\${1#--label=}"
        shift
      else
        shift
      fi
    done
    if [[ -n "\$label" ]]; then
      key="\${label%%=*}"
      val="\${label#*=}"
      jq -cs --arg k "\$key" --arg v "\$val" \
        '{terminals: [.[] | select(.labels[\$k] == \$v) | {address, state}]}' "$TERMS"/*.json
    else
      jq -cs '{terminals: [.[] | {address, state}]}' "$TERMS"/*.json
    fi
    ;;
  get)
    [[ ! -f "$BATS_TEST_TMPDIR/hc-down" ]] || exit 1
    [[ -f "$TERMS/\$2.json" ]] || exit 3
    nfile="$BATS_TEST_TMPDIR/gets-\$2"
    n=0
    [[ -f "\$nfile" ]] && n="\$(cat "\$nfile")"
    printf '%s' "\$((n + 1))" >"\$nfile"
    if [[ -f "$BATS_TEST_TMPDIR/busy-on-refetch" && "\$n" -ge 1 ]]; then
      jq -c '.foreground = {name: "vim", pid: 11}' "$TERMS/\$2.json"
    else
      cat "$TERMS/\$2.json"
    fi
    ;;
  send)
    [[ ! -f "$BATS_TEST_TMPDIR/hc-send-fail" ]] || exit 1
    printf '%s %s\n' "\$2" "\$3" >>"$SENT"
    ;;
esac
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/hc"
}

install_journalctl() {
  cat >"$BATS_TEST_TMPDIR/bin/journalctl" <<EOF
#!/usr/bin/env bash
printf '%s.612821 omarchy systemd[1]: Unmounted.\n' "\$(cat "$BATS_TEST_TMPDIR/shutdown")"
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/journalctl"
}

# Captures boot notifications so a passing restore never calls the real notify-send.
install_notify_send() {
  cat >"$BATS_TEST_TMPDIR/bin/notify-send" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$BATS_TEST_TMPDIR/notified"
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/notify-send"
}

terminal() { # address json
  jq -c --arg a "$1" '. + {address: $a}' <<<"$2" >"$TERMS/$1.json"
}

put_record() { # address session age-before-shutdown [harness]
  mkdir -p "$RECORDS"
  jq -n --arg a "$1" --arg s "$2" --arg cwd "$BATS_TEST_TMPDIR" --arg h "${4:-pi}" \
    '{address: $a, session: $s, harness: $h, cwd: $cwd, issue: "x-1", space: "sp1", args: []}' >"$RECORDS/$1.json"
  touch -d "@$(($(cat "$BATS_TEST_TMPDIR/shutdown") - $3))" "$RECORDS/$1.json"
}

reset_pass() {
  rm -rf "$RECORDS" "$SENT" "$XDG_RUNTIME_DIR/bercail/open-sessions"
  rm -f "$TERMS"/*.json "$BATS_TEST_TMPDIR"/gets-* "$BATS_TEST_TMPDIR/hc-fails" \
    "$BATS_TEST_TMPDIR/busy-on-refetch" "$BATS_TEST_TMPDIR/hc-send-fail"
  date +%s >"$BATS_TEST_TMPDIR/shutdown"
  DESK_TYPED=()
}

# A unix socket file at $1, as the core's would be: node binds it and exits.
BIND_JS='require("node:net").createServer().listen(process.argv[1], () => process.exit(0))'
make_socket() {
  [[ -n "$NODE" ]] || unavailable "node (not a mise shim) not found" || return
  "$NODE" -e "$BIND_JS" "$1"
}

# --boot waits forever without the core socket. Tests that are not about that wait create it.
ensure_core_socket() {
  mkdir -p "$(dirname "$SOCK")"
  [[ -S "$SOCK" ]] || make_socket "$SOCK"
}

claim_file() { # pid ticks session
  mkdir -p "$XDG_RUNTIME_DIR/bercail/open-sessions"
  jq -n --argjson pid "$1" --arg ticks "$2" --arg s "$3" \
    '{pid: $pid, start_ticks: $ticks, sessions: [$s]}' \
    >"$XDG_RUNTIME_DIR/bercail/open-sessions/$1.json"
}

start_ticks() {
  local stat
  stat="$(<"/proc/$1/stat")"
  awk '{ print $20 }' <<<"${stat##*)}"
}

install_systemctl() {
  cat >"$BATS_TEST_TMPDIR/bin/systemctl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$BATS_TEST_TMPDIR/systemctl-calls"
[[ "\$*" != "--user show-environment" ]] || printf 'HOME=%s\n' "\$HOME"
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/systemctl"
  hash -r
}

fake_omarchy() {
  cat >"$BATS_TEST_TMPDIR/bin/omarchy-hook-install" <<'EOF'
#!/bin/bash
set -e
mkdir -p "$HOME/.config/omarchy/hooks/$1.d"
cp -- "$2" "$HOME/.config/omarchy/hooks/$1.d/$(basename -- "$2")"
chmod 755 "$HOME/.config/omarchy/hooks/$1.d/$(basename -- "$2")"
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/omarchy-hook-install"
  hash -r
}

# The five desks the dry-run and the real restore both start from.
arrange_five() {
  reset_pass
  terminal t1 "$bare"; put_record t1 ses_fresh 60
  terminal t2 "$bare"; put_record t2 ses_stale 7200
  terminal t3 "$running"; put_record t3 ses_up 30
  terminal t4 "$bare"
  put_record t5 ses_removed 60
}

@test "only a record written in the ten minutes before the shutdown comes back" {
  expect "$(one "$(record ses_a)" "$fresh" "$bare")" "t1 resume " "written just before the shutdown"
  expect "$(one "$(record ses_a)" $((SHUTDOWN - 600)) "$bare")" "t1 resume " "exactly at the window's edge"
  expect "$(one "$(record ses_a)" $((SHUTDOWN - 601)) "$bare")" "t1 skip closed before the shutdown" "stale by a second"
  expect "$(one "$(record ses_a)" $((SHUTDOWN - 86400)) "$bare")" "t1 skip closed before the shutdown" "stale by a day"
  expect "$(one "$(record ses_a)" $((SHUTDOWN + 5000)) "$bare")" "t1 resume " "this boot, after a core restart"
}

@test "nothing is typed unless the desk sits at a bare shell" {
  expect "$(one "$(record ses_a)" "$fresh" "$running")" "t1 skip already running" "an agent is up"
  expect "$(one "$(record ses_a)" "$fresh" "$busy")" "t1 skip already running" "the shell is running something"
  expect "$(one "$(record ses_a)" "$fresh" "$inner")" "t1 skip already running" "something reports status"
  expect "$(one "$(record ses_a)" "$fresh" "$parked")" "t1 wait hc is recovering it" "parked by a core stop"
  expect "$(one "$(record ses_a)" "$fresh" "$starting")" "t1 wait hc is recovering it" "shell not up yet"
  expect "$(one "$(record ses_a)" "$fresh" null)" "t1 gone terminal ended" "terminal removed"
  expect "$(one "$(record ses_a)" "$fresh" "$finished")" "t1 gone terminal ended" "a quit desk stays quit"
  expect "$(one "$(record ses_a)" "$fresh" "$plain")" "t1 skip not a desk" "unlabelled terminal"
}

@test "a desk without a session, folder or free session stays a shell" {
  local got held
  expect "$(one null 0 "$bare")" "t1 skip no record: see the desk-restore skill" "no record"
  expect "$(one "$(record '')" "$fresh" "$bare")" "t1 skip no session yet" "never reached a turn"
  expect "$(one "$(record ses_a pi sp2)" "$fresh" "$bare")" "t1 skip record is for another space" "wrong space"
  expect "$(one "$(record ses_a other)" $((SHUTDOWN - 86400)) "$bare")" \
    "t1 skip closed before the shutdown" "a pre-Pi record is stale"
  expect "$(one "$(record ses_a)" "$fresh" "$bare" false)" "t1 skip folder is gone: /w" "worktree removed"
  expect "$(one "$(record ses_a)" "$fresh" "$bare" true true)" "t1 skip session is open elsewhere" "a process has it"
  got="$(verdict "$(fact t1 "$(record ses_a)" "$fresh" "$bare")" "$(fact t2 "$(record ses_a)" "$fresh" "$running")")"
  expect "$got" $'t1 skip session is open elsewhere\nt2 skip already running' "another desk runs it"
  got="$(verdict "$(fact t1 "$(record ses_a)" "$fresh" "$bare")" "$(fact t2 "$(record ses_a)" "$fresh" "$bare")")"
  expect "$got" $'t1 resume \nt2 skip session is open elsewhere' "two records, one session: one desk"
  held="$(jq -c '.labels = {} | .records = {"ses_a": {"app": "pi", "state": "idle"}}' <<<"$running")"
  got="$(verdict "$(fact t1 "$(record ses_a)" "$fresh" "$bare")" "$(fact t9 null 0 "$held")")"
  expect "$got" "t1 skip session is open elsewhere" "ordinary terminal records hold the session"
  expect "$(one "$(record ses_a)" "$fresh" "$bare" true false '["ses_a"]')" \
    "t1 skip session is open elsewhere" "a live claim holds the session"
}

@test "a Pi desk resumes" {
  expect "$(one "$(record 0199-pi pi)" "$fresh" "$bare")" "t1 resume " "pi resumes"
}

@test "hc siblings are left alone and do not block their desk" {
  local got
  got="$(verdict "$(fact t1 "$(record 0199-pi pi)" "$fresh" "$bare")" "$(fact t2 null 0 "$sibling")" \
    "$(fact t3 null 0 "$(jq -c '.reason = "stopped_by_restart" | .foreground = null' <<<"$sibling")")" \
    "$(fact t4 null 0 "$working")")"
  expect "$got" "t1 resume " "siblings are not resumed and do not hold the desk back"
}

restore_profile() {
  jq -n '["pi", "--model", "lead/model:high", "-e", "/profile/guard.ts", "-e", "/profile/bridge.ts", "--append-system-prompt", "/profile/instructions.md"]' \
    >"$BERCAIL_SHARE_DIR/pi/lead.json"
  mkdir -p "$LOCAL_BIN"
  ln -s "$ROOT/bin/bercail-desk-agent" "$LOCAL_BIN/bercail-desk-agent"
  printf '#!/bin/bash\njq -nc --args '\''$ARGS.positional'\'' -- "$@"\n' >"$BATS_TEST_TMPDIR/bin/pi"
  chmod +x "$BATS_TEST_TMPDIR/bin/pi"
}

@test "restoring an old plain Pi record loads the current guarded lead and keeps its session" {
  restore_profile
  local rec cmd out
  rec="$(jq -nc --arg cwd "$BATS_TEST_TMPDIR" '{session:"0199-old", cwd:$cwd, args:[]}')"
  cmd="$(desk_resume_command "$rec")"
  out="$(bash -c "$cmd")" || fail "restore: $out"
  [[ "$out" == '["--session-id","0199-old","--model","lead/model:high","-e","/profile/guard.ts","-e","/profile/bridge.ts","--append-system-prompt","/profile/instructions.md"]' ]] \
    || fail "the old plain desk did not resume on the guarded lead: $out"
}

@test "restoring an old plain Pi record keeps its model and tool flags without duplicating the default model" {
  restore_profile
  local args rec cmd out
  for args in '["--model","saved/model:low","--tools","read,grep"]' '["--model=saved/model:low","--tools","read,grep"]'; do
    rec="$(jq -nc --arg cwd "$BATS_TEST_TMPDIR" --argjson args "$args" '{session:"0199-old", cwd:$cwd, args:$args}')"
    cmd="$(desk_resume_command "$rec")"
    out="$(bash -c "$cmd")" || fail "restore: $out"
    jq -e --argjson saved "$args" '.[0:2] == ["--session-id","0199-old"] and .[2:] == (["-e","/profile/guard.ts","-e","/profile/bridge.ts","--append-system-prompt","/profile/instructions.md"] + $saved)' \
      <<<"$out" >/dev/null || fail "restore changed the saved model or flags: $out"
  done
}

@test "restoring a guarded lead or read-only reviewer replays only its recorded profile" {
  restore_profile
  local extension rec cmd out
  for extension in guard review; do
    rec="$(jq -nc --arg cwd "$BATS_TEST_TMPDIR" --arg ext "/saved/$extension.ts" \
      '{session:"0199-managed", cwd:$cwd, args:["-e",$ext,"--tools","read,grep,find,ls"]}')"
    cmd="$(desk_resume_command "$rec")"
    out="$(bash -c "$cmd")" || fail "restore: $out"
    jq -e --arg ext "/saved/$extension.ts" '. == ["--session-id","0199-managed","-e",$ext,"--tools","read,grep,find,ls"]' \
      <<<"$out" >/dev/null || fail "restore mixed the lead into a managed profile: $out"
  done
}

@test "restoring an old plain Pi record without a deployed lead fails with the update command" {
  rm "$BERCAIL_SHARE_DIR/pi/lead.json"
  local out
  if out="$(desk_resume_command "$(record 0199-old)" 2>&1)"; then fail "restored without a profile: $out"; fi
  [[ "$out" == *"lead.json is missing; run bercail update"* ]] || fail "restore: $out"
}

@test "restore sends nothing and fails when an old plain desk has no deployed lead" {
  reset_pass
  terminal t1 "$bare"
  put_record t1 0199-old 60
  rm "$BERCAIL_SHARE_DIR/pi/lead.json"
  local out
  if out="$(_desk_restore_pass 0 2>&1)"; then fail "restore reported success without a profile: $out"; fi
  [[ "$out" == *"lead.json is missing; run bercail update"* ]] || fail "restore: $out"
  [[ ! -e "$SENT" ]] || fail "restore sent an empty command: $(cat "$SENT")"
}

@test "the resume line quotes its parts and leaves the prompt out" {
  local rec cmd nl
  rec="$(jq -cn '{session: "ses_a", harness: "pi", cwd: "/w/a b", args: ["/w/stack dir"], issue: "x-1"}')"
  cmd="$(desk_resume_command "$rec")"
  [[ "$cmd" == "cd /w/a\\ b && TERM=xterm-256color COLORTERM=truecolor exec "* ]] || fail "resume runs in the folder, replacing the shell: $cmd"
  [[ "$cmd" == *"bercail-desk-agent pi --session-id ses_a /w/stack\\ dir" ]] || fail "resume keeps the flags, session first: $cmd"
  [[ "$cmd" != *--prompt* && "$cmd" != *x-1* ]] || fail "the issue prompt is not resent: $cmd"
  cmd="$(desk_resume_command "$(jq -c '.session = "0199-a" | .args = ["--model", "m:high"]' <<<"$rec")")"
  [[ "$cmd" == *"bercail-desk-agent pi --session-id 0199-a --model m:high" ]] \
    || fail "pi resumes with --session-id, which also opens a session never written: $cmd"
  nl="$(printf 'line1\nline2')"
  cmd="$(desk_resume_command "$(jq -cn --arg a "$nl" '{session: "ses_a", harness: "pi", cwd: "/w", args: [$a]}')")"
  [[ "$cmd" == *"\$'line1\\nline2'" ]] || fail "a newline in a flag stays one argument: $cmd"
  [[ "$cmd" != *$'\n'* ]] || fail "a newline in a flag was not quoted: $cmd"
}

@test "--dry-run lists the right desks and changes nothing" {
  local out
  arrange_five
  out="$(cmd_desk restore --dry-run)"
  [[ ! -e "$SENT" ]] || fail "dry-run typed: $(cat "$SENT")"
  [[ -f "$RECORDS/t5.json" ]] || fail "dry-run removed a record"
  [[ "$out" == *"t1     would resume  x-1  ses_fresh  $BATS_TEST_TMPDIR"* ]] || fail "dry-run lists the fresh desk: $out"
  [[ "$out" == *"t2     skip: closed before the shutdown"* ]] || fail "dry-run says why stale: $out"
  [[ "$out" == *"t3     skip: already running"* ]] || fail "dry-run says running: $out"
  [[ "$out" == *"t4     skip: no record"* ]] || fail "dry-run names a desk with no record: $out"
  [[ "$out" == *"1 would come back"* ]] || fail "dry-run counts: $out"
}

@test "restore types into the fresh desk only and drops dead records" {
  local out
  arrange_five
  out="$(cmd_desk restore)"
  expect "$(wc -l <"$SENT" | tr -d ' ')" 1 "only the fresh desk is typed into"
  [[ "$(cat "$SENT")" == "t1 cd "*"pi --session-id ses_fresh" ]] || fail "typed: $(cat "$SENT")"
  [[ ! -e "$RECORDS/t5.json" ]] || fail "a record whose terminal ended is cleaned up"
  [[ -f "$RECORDS/t2.json" ]] || fail "a stale record of a live terminal stays"
  [[ "$out" == *"1 came back"* ]] || fail "restore counts: $out"
}

@test "a fresh Pi desk comes back while a pre-Pi record stays stale" {
  local out
  reset_pass
  terminal t1 "$bare"; put_record t1 0199-pi 60 pi
  terminal t2 "$bare"; put_record t2 ses_old 86400 other
  terminal t3 "$(jq -c '.reason = "stopped_by_restart" | .foreground = null' <<<"$sibling")"
  out="$(cmd_desk restore)"
  expect "$(sed 's/^\(t[0-9]*\) .*exec [^ ]* /\1 /' "$SENT")" $'t1 pi --session-id 0199-pi' \
    "only the Pi desk is typed into"
  [[ "$out" == *"1 came back"* && "$out" == *"t2     skip: closed before the shutdown"* && "$out" != *t3* ]] \
    || fail "the old record stays stale and siblings are not counted: $out"
}

@test "a desk is listed as id: title, resumed or skipped" {
  local out
  reset_pass
  terminal t1 "$bare"
  put_record t1 ses_titled 60
  jq '.issue_title = "Fix login"' "$RECORDS/t1.json" >"$RECORDS/t1.json.new"
  mv "$RECORDS/t1.json.new" "$RECORDS/t1.json"
  out="$(cmd_desk restore --dry-run)"
  [[ "$out" == *"t1     would resume  x-1: Fix login  ses_titled  $BATS_TEST_TMPDIR"* ]] \
    || fail "resume line should name the title: $out"
  terminal t1 "$(jq -c '.foreground = {name: "pi", pid: 99}' <<<"$bare")"
  out="$(cmd_desk restore --dry-run)"
  [[ "$out" == *"t1     skip: already running  (x-1: Fix login)"* ]] \
    || fail "skip line should name the issue: $out"
}

@test "hc down leaves the records alone" {
  local out
  reset_pass
  terminal t1 "$bare"
  put_record t1 ses_titled 60
  touch "$BATS_TEST_TMPDIR/hc-down"
  if out="$(cmd_desk restore 2>&1)"; then fail "hc down should fail: $out"; fi
  [[ -f "$RECORDS/t1.json" ]] || fail "hc down must not read as terminals gone"
}

@test "a session in an ordinary terminal's records is not resumed" {
  local out
  reset_pass
  terminal t1 "$bare"; put_record t1 ses_held 60
  terminal t9 "$(jq -c '.labels = {} | .records = {"ses_held": {"app": "pi", "state": "idle"}}' <<<"$running")"
  out="$(cmd_desk restore)"
  [[ ! -e "$SENT" ]] || fail "resumed a session an ordinary terminal already holds: $(cat "$SENT")"
  [[ "$out" == *"t1     skip: session is open elsewhere"* ]] || fail "records duplicate: $out"
  [[ "$out" != *"t9"* ]] || fail "acted on a non-desk terminal: $out"
}

@test "a live claim blocks restore; a dead pid does not" {
  local out claim_pid
  reset_pass
  terminal t1 "$bare"; put_record t1 ses_claim 60
  sleep 60 &
  claim_pid=$!
  claim_file "$claim_pid" "$(start_ticks "$claim_pid")" ses_claim
  out="$(cmd_desk restore)"
  [[ ! -e "$SENT" ]] || fail "live claim was resumed: $(cat "$SENT")"
  [[ "$out" == *"session is open elsewhere"* ]] || fail "live claim: $out"
  kill "$claim_pid"
  wait "$claim_pid" 2>/dev/null || true
  rm -f "$SENT"
  DESK_TYPED=()
  out="$(cmd_desk restore)"
  [[ -e "$SENT" ]] || fail "a dead pid's claim blocked restore: $out"
}

@test "a claim whose start time does not match is ignored" {
  local out claim_pid
  reset_pass
  terminal t1 "$bare"; put_record t1 ses_stale_claim 60
  sleep 60 &
  claim_pid=$!
  claim_file "$claim_pid" 1 ses_stale_claim
  out="$(cmd_desk restore)"
  kill "$claim_pid"
  wait "$claim_pid" 2>/dev/null || true
  [[ -e "$SENT" ]] || fail "a mismatched start time blocked restore: $out"
}

@test "a terminal that is busy by send time is not typed into" {
  local out
  reset_pass
  terminal t1 "$bare"; put_record t1 ses_flip 60
  touch "$BATS_TEST_TMPDIR/busy-on-refetch"
  out="$(cmd_desk restore)"
  [[ ! -e "$SENT" ]] || fail "typed into a terminal that became busy: $(cat "$SENT")"
  [[ "$out" == *"t1     skip: already running"* ]] || fail "refetch skip: $out"
}

@test "hc send failure fails the restore" {
  local out
  reset_pass
  terminal t1 "$bare"; put_record t1 ses_send 60
  touch "$BATS_TEST_TMPDIR/hc-send-fail"
  if out="$(cmd_desk restore 2>&1)"; then fail "send failure should fail: $out"; fi
  [[ "$out" == *"could not type"* ]] || fail "send failure message: $out"
  [[ ! -e "$SENT" ]] || fail "a failed send was recorded: $(cat "$SENT")"
}

@test "restore waits out hc recovery and types once per desk" {
  local out
  reset_pass
  terminal t1 "$parked"; put_record t1 ses_slow 60
  terminal t2 "$bare"; put_record t2 ses_quick 60
  cat >"$BATS_TEST_TMPDIR/bin/sleep" <<EOF
#!/usr/bin/env bash
cp "$BATS_TEST_TMPDIR/t1-recovered.json" "$TERMS/t1.json"
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/sleep"
  hash -r
  jq -c '. + {address: "t1"}' <<<"$bare" >"$BATS_TEST_TMPDIR/t1-recovered.json"
  out="$(cmd_desk restore)"
  rm -f "$BATS_TEST_TMPDIR/bin/sleep"; hash -r
  expect "$(sort "$SENT" | cut -d' ' -f1 | tr '\n' ' ')" "t1 t2 " "each desk typed into once"
  [[ "$out" == *"2 came back"* ]] || fail "both counted: $out"
}

@test "--boot waits for the core, runs once, notifies with the count" {
  local out
  reset_pass
  terminal t1 "$bare"; put_record t1 ses_boot 60
  # The wait stays in the loop until the core's socket shows up.
  cat >"$BATS_TEST_TMPDIR/bin/sleep" <<EOF
#!/usr/bin/env bash
[[ -S "$SOCK" ]] || "$NODE" -e '$BIND_JS' "$SOCK"
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/sleep"
  hash -r
  (cmd_desk restore --boot) >/dev/null
  rm -f "$BATS_TEST_TMPDIR/bin/sleep"; hash -r
  [[ -S "$SOCK" ]] || fail "boot run should have waited for the core"
  [[ -e "$MARKER" ]] || fail "boot run leaves its marker"
  expect "$(cut -d' ' -f1 "$SENT")" t1 "boot run restores"
  expect "$(cat "$BATS_TEST_TMPDIR/notified")" "Bercail 1 desk came back" "boot run says how many"
  rm -f "$SENT"
  (cmd_desk restore --boot) >/dev/null
  [[ ! -e "$SENT" ]] || fail "second run in one boot typed: $(cat "$SENT")"
}

@test "no notification when nothing came back" {
  reset_pass
  ensure_core_socket
  terminal t1 "$running"; put_record t1 ses_up 60
  (cmd_desk restore --boot) >/dev/null
  [[ ! -e "$BATS_TEST_TMPDIR/notified" ]] || fail "nothing came back, nothing to say"
}

@test "two boots at once type into each desk once" {
  local boot_a boot_b
  # The parent shell must not still hold the restore lock, or both boots inherit it.
  exec 9>&-
  unset DESK_LOCK_HELD || true
  ensure_core_socket
  rm -f "$MARKER" "$SENT" "$BATS_TEST_TMPDIR/notified"
  reset_pass
  terminal t1 "$bare"; put_record t1 ses_once 60
  cmd_desk restore --boot >"$BATS_TEST_TMPDIR/boot-a" 2>&1 &
  boot_a=$!
  cmd_desk restore --boot >"$BATS_TEST_TMPDIR/boot-b" 2>&1 &
  boot_b=$!
  wait "$boot_a" || true
  wait "$boot_b" || true
  [[ -f "$SENT" ]] || fail "concurrent boot typed nothing: $(cat "$BATS_TEST_TMPDIR/boot-a" "$BATS_TEST_TMPDIR/boot-b")"
  expect "$(wc -l <"$SENT" | tr -d ' ')" 1 "concurrent boots type once"
}

@test "a transient hc failure is retried; one that lasts leaves no marker" {
  local out
  ensure_core_socket
  rm -f "$MARKER" "$SENT"
  reset_pass
  terminal t1 "$bare"; put_record t1 ses_retry 60
  printf '2' >"$BATS_TEST_TMPDIR/hc-fails"
  DESK_RESTORE_RECOVERY_WAIT=30
  out="$(cmd_desk restore --boot 2>&1)" || fail "transient hc failure should retry: $out"
  DESK_RESTORE_RECOVERY_WAIT=120
  [[ -e "$MARKER" ]] || fail "a retry that finishes marks done"
  expect "$(cut -d' ' -f1 "$SENT")" t1 "retried boot restores"
  rm -f "$MARKER" "$SENT" "$BATS_TEST_TMPDIR/hc-fails"
  printf '99' >"$BATS_TEST_TMPDIR/hc-fails"
  DESK_RESTORE_RECOVERY_WAIT=0
  if cmd_desk restore --boot >/dev/null 2>&1; then fail "hc still down should fail"; fi
  DESK_RESTORE_RECOVERY_WAIT=120
  [[ ! -e "$MARKER" ]] || fail "a failed boot must not mark done"
}

@test "a recovery timeout does not mark the boot done" {
  ensure_core_socket
  rm -f "$MARKER" "$SENT"
  reset_pass
  terminal t1 "$parked"; put_record t1 ses_wait 60
  DESK_RESTORE_RECOVERY_WAIT=0
  if cmd_desk restore --boot >/dev/null 2>&1; then fail "recovery timeout should fail"; fi
  DESK_RESTORE_RECOVERY_WAIT=120
  [[ ! -e "$MARKER" ]] || fail "a timeout must not mark success"
  [[ ! -e "$SENT" ]] || fail "a timeout typed: $(cat "$SENT")"
}

@test "hc send failure does not mark the boot done" {
  ensure_core_socket
  rm -f "$MARKER" "$SENT"
  reset_pass
  terminal t1 "$bare"; put_record t1 ses_send_boot 60
  touch "$BATS_TEST_TMPDIR/hc-send-fail"
  DESK_RESTORE_RECOVERY_WAIT=0
  if cmd_desk restore --boot >/dev/null 2>&1; then fail "boot send failure should fail"; fi
  DESK_RESTORE_RECOVERY_WAIT=120
  [[ ! -e "$MARKER" ]] || fail "a send failure must not mark done"
}

@test "no journal falls back to a time that leaves old desks alone" {
  local t
  rm -f "$BATS_TEST_TMPDIR/bin/journalctl"
  hash -r
  t="$(_desk_shutdown_time)"
  [[ "$t" =~ ^[0-9]+$ && "$t" -gt 1000000000 ]] || fail "no journal still gives a time: $t"
  printf '#!/usr/bin/env bash\nexit 1\n' >"$BATS_TEST_TMPDIR/bin/journalctl"
  chmod +x "$BATS_TEST_TMPDIR/bin/journalctl"
  hash -r
  t="$(_desk_shutdown_time)"
  [[ "$t" =~ ^[0-9]+$ && "$t" -gt 1000000000 ]] || fail "a journal with no previous boot still gives a time: $t"
}

@test "a systemd user unit off Omarchy, and doctor checks it" {
  local out
  install_systemctl
  deploy_desk_restore_boot >/dev/null
  [[ -f "$DESK_RESTORE_UNIT" ]] || fail "off Omarchy, a systemd user unit is installed"
  grep -q 'enable bercail-desk-restore.service' "$BATS_TEST_TMPDIR/systemctl-calls" || fail "the unit is enabled"
  grep -q 'bercail desk restore --boot' "$DESK_RESTORE_UNIT" || fail "the unit runs the boot restore"
  [[ ! -e "$OMARCHY_POST_BOOT_HOOK" ]] || fail "no Omarchy hook off Omarchy"
  out="$(doctor_desk_restore)"; [[ "$out" == *ok* ]] || fail "doctor: $out"
  rm -f "$DESK_RESTORE_UNIT"
  if out="$(doctor_desk_restore)"; then fail "doctor should flag the missing unit: $out"; fi
}

@test "packaged install runs the release CLI and keeps mise shims on PATH" {
  install_systemctl
  rm -f "$BATS_TEST_TMPDIR/systemctl-calls"
  ln -s "$ROOT" "$BATS_TEST_TMPDIR/package tree"
  (
    BERCAIL_PACKAGED=1
    INSTALL_SRC="$BATS_TEST_TMPDIR/package tree"
    deploy_desk_restore_boot >/dev/null
  )
  grep -qF "ExecStart=\"$BATS_TEST_TMPDIR/package tree/bin/bercail\" desk restore --boot" "$DESK_RESTORE_UNIT" \
    || fail "packaged unit must run the release CLI: $(cat "$DESK_RESTORE_UNIT")"
  if grep -q '%h/.local/bin/bercail' "$DESK_RESTORE_UNIT"; then
    fail "packaged unit still points at the skipped binary: $(cat "$DESK_RESTORE_UNIT")"
  fi
  grep -q '%h/.local/share/mise/shims' "$DESK_RESTORE_UNIT" \
    || fail "unit PATH drops mise shims: $(cat "$DESK_RESTORE_UNIT")"
}

@test "no boot wiring without a user manager" {
  local out
  install_systemctl
  mv "$BATS_TEST_TMPDIR/bin/systemctl" "$BATS_TEST_TMPDIR/systemctl.off"
  hash -r
  deploy_desk_restore_boot >/dev/null
  [[ ! -e "$DESK_RESTORE_UNIT" ]] || fail "no user manager, no unit"
  out="$(doctor_desk_restore)"; [[ -z "$out" ]] || fail "doctor stays quiet without a way in: $out"
}

@test "Omarchy gets the post-boot hook, and keeps one" {
  local out
  mkdir -p "$HOME/.local/share/omarchy"
  fake_omarchy
  deploy_desk_restore_boot >/dev/null
  cmp -s "$ROOT/config/omarchy/bercail-desk-restore.hook" "$OMARCHY_POST_BOOT_HOOK" || fail "Omarchy gets the post-boot hook"
  [[ -x "$OMARCHY_POST_BOOT_HOOK" ]] || fail "hook not executable"
  [[ ! -e "$DESK_RESTORE_UNIT" ]] || fail "one way in per machine"
  out="$(deploy_desk_restore_boot)"
  [[ "$out" == *"unchanged: $OMARCHY_POST_BOOT_HOOK"* ]] || fail "second update leaves the hook: $out"
}

@test "the hook returns at once and runs the boot restore" {
  mkdir -p "$HOME/.local/share/omarchy"
  fake_omarchy
  deploy_desk_restore_boot >/dev/null
  cat >"$BATS_TEST_TMPDIR/bin/bercail" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >"$BATS_TEST_TMPDIR/hook-ran"
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/bercail"
  hash -r
  timeout 5 bash "$OMARCHY_POST_BOOT_HOOK" </dev/null >/dev/null 2>&1 || fail "hook failed or hung"
  # shellcheck disable=SC2016 # eval'd by wait_for, not expanded here
  wait_for '[[ -f "$BATS_TEST_TMPDIR/hook-ran" ]]'
  expect "$(cat "$BATS_TEST_TMPDIR/hook-ran")" "desk restore --boot" "the hook starts the boot run"
  rm -f "$BATS_TEST_TMPDIR/bin/bercail"
  timeout 5 bash "$OMARCHY_POST_BOOT_HOOK" </dev/null >/dev/null 2>&1 || fail "hook without bercail must not fail"
}

@test "uninstall removes the desk restore hook" {
  mkdir -p "$(dirname "$OMARCHY_POST_BOOT_HOOK")"
  touch "$OMARCHY_POST_BOOT_HOOK"
  remove_desk_restore >/dev/null
  [[ ! -e "$OMARCHY_POST_BOOT_HOOK" ]] || fail "uninstall removes the hook"
}
