#!/usr/bin/env bash
# shellcheck shell=bash
# Desks come back after a reboot: which records get resumed, what gets typed, and
# how it is wired. Nothing here reaches a real hc core or the real home.
set -euo pipefail

unset BASH_ENV HC_TERMINAL_ID HC_SESSION HC_SCOPE HC_TERMINAL_SOCKET
export __MISE_BASH_ENV_LOADED=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
expect() { [[ "$1" == "$2" ]] || fail "$3: got '$1', want '$2'"; }

export HOME="$TMP_DIR/home" XDG_STATE_HOME="$TMP_DIR/state" XDG_RUNTIME_DIR="$TMP_DIR/run" XDG_CONFIG_HOME="$TMP_DIR/home/.config"
mkdir -p "$HOME" "$TMP_DIR/bin" "$XDG_RUNTIME_DIR/herdr-core"
export PATH="$TMP_DIR/bin:$PATH" HC_BIN="$TMP_DIR/bin/hc"
RECORDS="$XDG_STATE_HOME/bercail/desk-sessions"
export DESK_RESTORE_POLL=0

# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=lib/detect.sh
source "$ROOT/lib/detect.sh"
# shellcheck source=lib/config.sh
source "$ROOT/lib/config.sh"
# shellcheck source=lib/desk.sh
source "$ROOT/lib/desk.sh"
export INSTALL_SRC="$ROOT"
YES=1
DRY_RUN=0

# --- the selection, from facts alone ---

SHUTDOWN=1000000
# hc get for a terminal a reboot left at a bare shell, as seen on a real core.
bare='{"state":"live","reason":null,"reported":false,"pid":7,"argv":["/usr/bin/bash"],
  "foreground":{"name":"bash","pid":7},"labels":{"bercail.role":"agent","bercail.space":"sp1"}}'
record() { # session [harness] [space]
  jq -cn --arg s "$1" --arg h "${2:-opencode}" --arg sp "${3:-sp1}" \
    '{session: $s, harness: $h, space: $sp, cwd: "/w", issue: "x-1", args: []}'
}
# fact address record mtime terminal [cwd_exists] [in_ps] [open_sessions]
fact() {
  jq -cn --arg a "$1" --argjson r "$2" --argjson m "$3" --argjson t "$4" \
    --argjson c "${5:-true}" --argjson p "${6:-false}" \
    --argjson o "${7:-[]}" \
    '{address: $a, record: $r, mtime: $m, terminal: $t, cwd_exists: $c, in_ps: $p, open_sessions: $o}'
}
# verdict "<facts...>": "address action why" per desk.
verdict() {
  printf '%s\n' "$@" | jq -s . | desk_restore_plan "$SHUTDOWN" | jq -r '.[] | "\(.address) \(.action) \(.why)"'
}
one() { verdict "$(fact t1 "$@")"; }

fresh=$((SHUTDOWN - 60))
expect "$(one "$(record ses_a)" "$fresh" "$bare")" "t1 resume " "written just before the shutdown"
expect "$(one "$(record ses_a)" $((SHUTDOWN - 600)) "$bare")" "t1 resume " "exactly at the window's edge"
expect "$(one "$(record ses_a)" $((SHUTDOWN - 601)) "$bare")" "t1 skip closed before the shutdown" "stale by a second"
expect "$(one "$(record ses_a)" $((SHUTDOWN - 86400)) "$bare")" "t1 skip closed before the shutdown" "stale by a day"
expect "$(one "$(record ses_a)" $((SHUTDOWN + 5000)) "$bare")" "t1 resume " "this boot, after a core restart"
printf 'PASS: only a record written in the ten minutes before the shutdown comes back\n'

running='{"state":"live","reason":null,"reported":true,"pid":9,"argv":["bercail-desk-agent"],
  "foreground":{"name":"opencode.exe","pid":9},"labels":{"bercail.role":"agent","bercail.space":"sp1"}}'
busy="$(jq -c '.foreground = {name: "vim", pid: 11}' <<<"$bare")"
inner="$(jq -c '.reported = true' <<<"$bare")"
parked="$(jq -c '.reason = "stopped_by_restart" | .foreground = null | .pid = null' <<<"$bare")"
starting="$(jq -c '.foreground = null' <<<"$bare")"
finished="$(jq -c '.state = "finished" | .reason = "exited"' <<<"$bare")"
plain="$(jq -c '.labels = {}' <<<"$bare")"
expect "$(one "$(record ses_a)" "$fresh" "$running")" "t1 skip already running" "an agent is up"
expect "$(one "$(record ses_a)" "$fresh" "$busy")" "t1 skip already running" "the shell is running something"
expect "$(one "$(record ses_a)" "$fresh" "$inner")" "t1 skip already running" "something reports status"
expect "$(one "$(record ses_a)" "$fresh" "$parked")" "t1 wait hc is recovering it" "parked by a core stop"
expect "$(one "$(record ses_a)" "$fresh" "$starting")" "t1 wait hc is recovering it" "shell not up yet"
expect "$(one "$(record ses_a)" "$fresh" null)" "t1 gone terminal ended" "terminal removed"
expect "$(one "$(record ses_a)" "$fresh" "$finished")" "t1 gone terminal ended" "a quit desk stays quit"
expect "$(one "$(record ses_a)" "$fresh" "$plain")" "t1 skip not a desk" "unlabelled terminal"
printf 'PASS: nothing is typed unless the desk sits at a bare shell\n'

expect "$(one null 0 "$bare")" "t1 skip no record: see the desk-restore skill" "no record"
expect "$(one "$(record '')" "$fresh" "$bare")" "t1 skip no session yet" "never reached a turn"
expect "$(one "$(record ses_a opencode sp2)" "$fresh" "$bare")" "t1 skip record is for another space" "wrong space"
expect "$(one "$(record ses_a codex)" "$fresh" "$bare")" "t1 skip cannot resume codex" "harness without a resume"
expect "$(one "$(record ses_a)" "$fresh" "$bare" false)" "t1 skip folder is gone: /w" "worktree removed"
expect "$(one "$(record ses_a)" "$fresh" "$bare" true true)" "t1 skip session is open elsewhere" "a process has it"
got="$(verdict "$(fact t1 "$(record ses_a)" "$fresh" "$bare")" "$(fact t2 "$(record ses_a)" "$fresh" "$running")")"
expect "$got" $'t1 skip session is open elsewhere\nt2 skip already running' "another desk runs it"
got="$(verdict "$(fact t1 "$(record ses_a)" "$fresh" "$bare")" "$(fact t2 "$(record ses_a)" "$fresh" "$bare")")"
expect "$got" $'t1 resume \nt2 skip session is open elsewhere' "two records, one session: one desk"
held="$(jq -c '.labels = {} | .records = {"ses_a": {"app": "opencode", "state": "idle"}}' <<<"$running")"
got="$(verdict "$(fact t1 "$(record ses_a)" "$fresh" "$bare")" "$(fact t9 null 0 "$held")")"
expect "$got" "t1 skip session is open elsewhere" "ordinary terminal records hold the session"
expect "$(one "$(record ses_a)" "$fresh" "$bare" true false '["ses_a"]')" \
  "t1 skip session is open elsewhere" "a live claim holds the session"
printf 'PASS: a desk without a session, folder or free session stays a shell\n'

expect "$(jq -r '.[0].action' <<<"$(fact t1 "$(record ses_a claude)" "$fresh" "$bare" | jq -s . | desk_restore_plan "$SHUTDOWN")")" resume "claude resumes"
printf 'PASS: claude desks resume too\n'

# --- what gets typed ---

rec="$(jq -cn '{session: "ses_a", harness: "opencode", cwd: "/w/a b", args: ["/w/stack dir"], issue: "x-1"}')"
cmd="$(desk_resume_command "$rec")"
[[ "$cmd" == "cd /w/a\\ b && TERM=xterm-256color COLORTERM=truecolor exec "* ]] || fail "resume runs in the folder, replacing the shell: $cmd"
[[ "$cmd" == *"bercail-desk-agent opencode --session ses_a /w/stack\\ dir" ]] || fail "resume keeps the flags, session first: $cmd"
[[ "$cmd" != *--prompt* && "$cmd" != *x-1* ]] || fail "the issue prompt is not resent: $cmd"
cmd="$(desk_resume_command "$(jq -c '.harness = "claude" | .args = ["--verbose"]' <<<"$rec")")"
[[ "$cmd" == *"claude --resume ses_a --verbose" ]] || fail "claude resumes with --resume: $cmd"
nl="$(printf 'line1\nline2')"
cmd="$(desk_resume_command "$(jq -cn --arg a "$nl" '{session: "ses_a", harness: "opencode", cwd: "/w", args: [$a]}')")"
[[ "$cmd" == *"\$'line1\\nline2'" ]] || fail "a newline in a flag stays one argument: $cmd"
[[ "$cmd" != *$'\n'* ]] || fail "a newline in a flag was not quoted: $cmd"
printf 'PASS: the resume line quotes its parts and leaves the prompt out\n'

# --- a whole pass, against a fake hc ---

SENT="$TMP_DIR/sent"
TERMS="$TMP_DIR/terms"
mkdir -p "$TERMS"
cat >"$TMP_DIR/bin/hc" <<EOF
#!/usr/bin/env bash
case "\$1" in
  ls)
    [[ ! -f "$TMP_DIR/hc-down" ]] || exit 1
    if [[ -f "$TMP_DIR/hc-fails" ]]; then
      n="\$(cat "$TMP_DIR/hc-fails")"
      if [[ "\$n" != 0 ]]; then
        printf '%s' "\$((n - 1))" >"$TMP_DIR/hc-fails"
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
    [[ ! -f "$TMP_DIR/hc-down" ]] || exit 1
    [[ -f "$TERMS/\$2.json" ]] || exit 3
    nfile="$TMP_DIR/gets-\$2"
    n=0
    [[ -f "\$nfile" ]] && n="\$(cat "\$nfile")"
    printf '%s' "\$((n + 1))" >"\$nfile"
    if [[ -f "$TMP_DIR/busy-on-refetch" && "\$n" -ge 1 ]]; then
      jq -c '.foreground = {name: "vim", pid: 11}' "$TERMS/\$2.json"
    else
      cat "$TERMS/\$2.json"
    fi
    ;;
  send)
    [[ ! -f "$TMP_DIR/hc-send-fail" ]] || exit 1
    printf '%s %s\n' "\$2" "\$3" >>"$SENT"
    ;;
esac
EOF
chmod +x "$TMP_DIR/bin/hc"
cat >"$TMP_DIR/bin/journalctl" <<EOF
#!/usr/bin/env bash
printf '%s.612821 omarchy systemd[1]: Unmounted.\n' "\$(cat "$TMP_DIR/shutdown")"
EOF
chmod +x "$TMP_DIR/bin/journalctl"

terminal() { # address json
  jq -c --arg a "$1" '. + {address: $a}' <<<"$2" >"$TERMS/$1.json"
}
put_record() { # address session age-before-shutdown
  mkdir -p "$RECORDS"
  jq -n --arg a "$1" --arg s "$2" --arg cwd "$TMP_DIR" \
    '{address: $a, session: $s, harness: "opencode", cwd: $cwd, issue: "x-1", space: "sp1", args: []}' >"$RECORDS/$1.json"
  touch -d "@$(($(cat "$TMP_DIR/shutdown") - $3))" "$RECORDS/$1.json"
}
reset_pass() {
  rm -rf "$RECORDS" "$SENT" "$XDG_RUNTIME_DIR/bercail/open-sessions"
  rm -f "$TERMS"/*.json "$TMP_DIR"/gets-* "$TMP_DIR/hc-fails" "$TMP_DIR/busy-on-refetch" "$TMP_DIR/hc-send-fail"
  date +%s >"$TMP_DIR/shutdown"
  DESK_TYPED=()
}

reset_pass
terminal t1 "$bare"; put_record t1 ses_fresh 60
terminal t2 "$bare"; put_record t2 ses_stale 7200
terminal t3 "$running"; put_record t3 ses_up 30
terminal t4 "$bare"
put_record t5 ses_removed 60

out="$(cmd_desk restore --dry-run)"
[[ ! -e "$SENT" ]] || fail "dry-run typed: $(cat "$SENT")"
[[ -f "$RECORDS/t5.json" ]] || fail "dry-run removed a record"
[[ "$out" == *"t1     would resume  x-1  ses_fresh  $TMP_DIR"* ]] || fail "dry-run lists the fresh desk: $out"
[[ "$out" == *"t2     skip: closed before the shutdown"* ]] || fail "dry-run says why stale: $out"
[[ "$out" == *"t3     skip: already running"* ]] || fail "dry-run says running: $out"
[[ "$out" == *"t4     skip: no record"* ]] || fail "dry-run names a desk with no record: $out"
[[ "$out" == *"1 would come back"* ]] || fail "dry-run counts: $out"
printf 'PASS: --dry-run lists the right desks and changes nothing\n'

out="$(cmd_desk restore)"
expect "$(wc -l <"$SENT" | tr -d ' ')" 1 "only the fresh desk is typed into"
[[ "$(cat "$SENT")" == "t1 cd "*"opencode --session ses_fresh" ]] || fail "typed: $(cat "$SENT")"
[[ ! -e "$RECORDS/t5.json" ]] || fail "a record whose terminal ended is cleaned up"
[[ -f "$RECORDS/t2.json" ]] || fail "a stale record of a live terminal stays"
[[ "$out" == *"1 came back"* ]] || fail "restore counts: $out"
printf 'PASS: restore types into the fresh desk only and drops dead records\n'

touch "$TMP_DIR/hc-down"
if out="$(cmd_desk restore 2>&1)"; then fail "hc down should fail: $out"; fi
[[ -f "$RECORDS/t1.json" ]] || fail "hc down must not read as terminals gone"
rm -f "$TMP_DIR/hc-down"
printf 'PASS: hc down leaves the records alone\n'

# An ordinary terminal, not a desk, whose hc .records names the session. argv
# does not. Restore must not type, and must not act on that terminal.
reset_pass
terminal t1 "$bare"; put_record t1 ses_held 60
terminal t9 "$(jq -c '.labels = {} | .records = {"ses_held": {"app": "opencode", "state": "idle"}}' <<<"$running")"
out="$(cmd_desk restore)"
[[ ! -e "$SENT" ]] || fail "resumed a session an ordinary terminal already holds: $(cat "$SENT")"
[[ "$out" == *"t1     skip: session is open elsewhere"* ]] || fail "records duplicate: $out"
[[ "$out" != *"t9"* ]] || fail "acted on a non-desk terminal: $out"
printf 'PASS: a session in an ordinary terminal'\''s records is not resumed\n'

# The plugin's claim: a live pid whose start time matches suppresses restore.
# A dead pid, or a live pid with the wrong start time, does not.
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
printf 'PASS: a live claim blocks restore; a dead pid does not\n'

reset_pass
terminal t1 "$bare"; put_record t1 ses_stale_claim 60
sleep 60 &
claim_pid=$!
claim_file "$claim_pid" 1 ses_stale_claim
out="$(cmd_desk restore)"
kill "$claim_pid"
wait "$claim_pid" 2>/dev/null || true
[[ -e "$SENT" ]] || fail "a mismatched start time blocked restore: $out"
printf 'PASS: a claim whose start time does not match is ignored\n'

# Planning saw a bare shell. By the time we would type, it is vim.
reset_pass
terminal t1 "$bare"; put_record t1 ses_flip 60
touch "$TMP_DIR/busy-on-refetch"
out="$(cmd_desk restore)"
rm -f "$TMP_DIR/busy-on-refetch"
[[ ! -e "$SENT" ]] || fail "typed into a terminal that became busy: $(cat "$SENT")"
[[ "$out" == *"t1     skip: already running"* ]] || fail "refetch skip: $out"
printf 'PASS: a terminal that is busy by send time is not typed into\n'

reset_pass
terminal t1 "$bare"; put_record t1 ses_send 60
touch "$TMP_DIR/hc-send-fail"
if out="$(cmd_desk restore 2>&1)"; then fail "send failure should fail: $out"; fi
[[ "$out" == *"could not type"* ]] || fail "send failure message: $out"
[[ ! -e "$SENT" ]] || fail "a failed send was recorded: $(cat "$SENT")"
rm -f "$TMP_DIR/hc-send-fail"
printf 'PASS: hc send failure fails the restore\n'

# A parked terminal gets its shell a few seconds later: the pass asks again, and
# does not type twice into a shell that is slow to load.
reset_pass
terminal t1 "$parked"; put_record t1 ses_slow 60
terminal t2 "$bare"; put_record t2 ses_quick 60
cat >"$TMP_DIR/bin/sleep" <<EOF
#!/usr/bin/env bash
cp "$TMP_DIR/t1-recovered.json" "$TERMS/t1.json"
EOF
chmod +x "$TMP_DIR/bin/sleep"
jq -c '. + {address: "t1"}' <<<"$bare" >"$TMP_DIR/t1-recovered.json"
out="$(cmd_desk restore)"
rm -f "$TMP_DIR/bin/sleep"; hash -r
expect "$(sort "$SENT" | cut -d' ' -f1 | tr '\n' ' ')" "t1 t2 " "each desk typed into once"
[[ "$out" == *"2 came back"* ]] || fail "both counted: $out"
printf 'PASS: restore waits out hc recovery and types once per desk\n'

# --- once per boot ---

reset_pass
terminal t1 "$bare"; put_record t1 ses_boot 60
cat >"$TMP_DIR/bin/notify-send" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$TMP_DIR/notified"
EOF
chmod +x "$TMP_DIR/bin/notify-send"
MARKER="$XDG_RUNTIME_DIR/bercail-desk-restore.done"
SOCK="$XDG_RUNTIME_DIR/herdr-core/default.sock"
# The wait stays in the loop until the core's socket shows up.
cat >"$TMP_DIR/bin/sleep" <<EOF
#!/usr/bin/env bash
[[ -S "$SOCK" ]] || /usr/bin/python3 -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$SOCK"
EOF
chmod +x "$TMP_DIR/bin/sleep"
(cmd_desk restore --boot) >/dev/null
rm -f "$TMP_DIR/bin/sleep"; hash -r
[[ -S "$SOCK" ]] || fail "boot run should have waited for the core"
[[ -e "$MARKER" ]] || fail "boot run leaves its marker"
expect "$(cut -d' ' -f1 "$SENT")" t1 "boot run restores"
expect "$(cat "$TMP_DIR/notified")" "Bercail 1 desk came back" "boot run says how many"
rm -f "$SENT"
(cmd_desk restore --boot) >/dev/null
[[ ! -e "$SENT" ]] || fail "second run in one boot typed: $(cat "$SENT")"
printf 'PASS: --boot waits for the core, runs once, notifies with the count\n'

rm -f "$MARKER" "$TMP_DIR/notified"
reset_pass
terminal t1 "$running"; put_record t1 ses_up 60
(cmd_desk restore --boot) >/dev/null
[[ ! -e "$TMP_DIR/notified" ]] || fail "nothing came back, nothing to say"
printf 'PASS: no notification when nothing came back\n'

# The parent shell must not still hold the restore lock, or both boots inherit it.
exec 9>&-
unset DESK_LOCK_HELD || true
[[ -S "$SOCK" ]] || /usr/bin/python3 -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$SOCK"
rm -f "$MARKER" "$SENT" "$TMP_DIR/notified"
reset_pass
terminal t1 "$bare"; put_record t1 ses_once 60
cmd_desk restore --boot >"$TMP_DIR/boot-a" 2>&1 &
boot_a=$!
cmd_desk restore --boot >"$TMP_DIR/boot-b" 2>&1 &
boot_b=$!
wait "$boot_a" || true
wait "$boot_b" || true
[[ -f "$SENT" ]] || fail "concurrent boot typed nothing: $(cat "$TMP_DIR/boot-a" "$TMP_DIR/boot-b")"
expect "$(wc -l <"$SENT" | tr -d ' ')" 1 "concurrent boots type once"
printf 'PASS: two boots at once type into each desk once\n'

rm -f "$MARKER" "$SENT"
reset_pass
terminal t1 "$bare"; put_record t1 ses_retry 60
printf '2' >"$TMP_DIR/hc-fails"
DESK_RESTORE_RECOVERY_WAIT=30
out="$(cmd_desk restore --boot 2>&1)" || fail "transient hc failure should retry: $out"
DESK_RESTORE_RECOVERY_WAIT=120
[[ -e "$MARKER" ]] || fail "a retry that finishes marks done"
expect "$(cut -d' ' -f1 "$SENT")" t1 "retried boot restores"
rm -f "$MARKER" "$SENT" "$TMP_DIR/hc-fails"
printf '99' >"$TMP_DIR/hc-fails"
DESK_RESTORE_RECOVERY_WAIT=0
if cmd_desk restore --boot >/dev/null 2>&1; then fail "hc still down should fail"; fi
DESK_RESTORE_RECOVERY_WAIT=120
[[ ! -e "$MARKER" ]] || fail "a failed boot must not mark done"
rm -f "$TMP_DIR/hc-fails"
printf 'PASS: a transient hc failure is retried; one that lasts leaves no marker\n'

rm -f "$MARKER" "$SENT"
reset_pass
terminal t1 "$parked"; put_record t1 ses_wait 60
DESK_RESTORE_RECOVERY_WAIT=0
if cmd_desk restore --boot >/dev/null 2>&1; then fail "recovery timeout should fail"; fi
DESK_RESTORE_RECOVERY_WAIT=120
[[ ! -e "$MARKER" ]] || fail "a timeout must not mark success"
[[ ! -e "$SENT" ]] || fail "a timeout typed: $(cat "$SENT")"
printf 'PASS: a recovery timeout does not mark the boot done\n'

rm -f "$MARKER" "$SENT"
reset_pass
terminal t1 "$bare"; put_record t1 ses_send_boot 60
touch "$TMP_DIR/hc-send-fail"
DESK_RESTORE_RECOVERY_WAIT=0
if cmd_desk restore --boot >/dev/null 2>&1; then fail "boot send failure should fail"; fi
DESK_RESTORE_RECOVERY_WAIT=120
rm -f "$TMP_DIR/hc-send-fail"
[[ ! -e "$MARKER" ]] || fail "a send failure must not mark done"
printf 'PASS: hc send failure does not mark the boot done\n'

# No previous boot in the journal: only records this boot wrote can pass.
rm -f "$TMP_DIR/bin/journalctl"
t="$(_desk_shutdown_time)"
[[ "$t" =~ ^[0-9]+$ && "$t" -gt 1000000000 ]] || fail "no journal still gives a time: $t"
printf '#!/usr/bin/env bash\nexit 1\n' >"$TMP_DIR/bin/journalctl"
chmod +x "$TMP_DIR/bin/journalctl"
t="$(_desk_shutdown_time)"
[[ "$t" =~ ^[0-9]+$ && "$t" -gt 1000000000 ]] || fail "a journal with no previous boot still gives a time: $t"
printf 'PASS: no journal falls back to a time that leaves old desks alone\n'

# --- wiring ---

# This machine may really be Omarchy, so the test says which one it is.
is_omarchy() { [[ -d "$HOME/.local/share/omarchy" ]]; }
fake_omarchy() {
  cat >"$TMP_DIR/bin/omarchy-hook-install" <<'EOF'
#!/bin/bash
set -e
mkdir -p "$HOME/.config/omarchy/hooks/$1.d"
cp -- "$2" "$HOME/.config/omarchy/hooks/$1.d/$(basename -- "$2")"
chmod 755 "$HOME/.config/omarchy/hooks/$1.d/$(basename -- "$2")"
EOF
  chmod +x "$TMP_DIR/bin/omarchy-hook-install"
}
cat >"$TMP_DIR/bin/systemctl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$TMP_DIR/systemctl-calls"
[[ "\$*" != "--user show-environment" ]] || printf 'HOME=%s\n' "\$HOME"
EOF
chmod +x "$TMP_DIR/bin/systemctl"

deploy_desk_restore_boot >/dev/null
[[ -f "$DESK_RESTORE_UNIT" ]] || fail "off Omarchy, a systemd user unit is installed"
grep -q 'enable bercail-desk-restore.service' "$TMP_DIR/systemctl-calls" || fail "the unit is enabled"
grep -q 'bercail desk restore --boot' "$DESK_RESTORE_UNIT" || fail "the unit runs the boot restore"
[[ ! -e "$OMARCHY_POST_BOOT_HOOK" ]] || fail "no Omarchy hook off Omarchy"
out="$(doctor_desk_restore)"; [[ "$out" == *ok* ]] || fail "doctor: $out"
rm -f "$DESK_RESTORE_UNIT"
if out="$(doctor_desk_restore)"; then fail "doctor should flag the missing unit: $out"; fi
printf 'PASS: a systemd user unit off Omarchy, and doctor checks it\n'

rm -f "$TMP_DIR/systemctl-calls"
ln -s "$ROOT" "$TMP_DIR/package tree"
(
  BERCAIL_PACKAGED=1
  INSTALL_SRC="$TMP_DIR/package tree"
  deploy_desk_restore_boot >/dev/null
)
grep -qF "ExecStart=\"$TMP_DIR/package tree/bin/bercail\" desk restore --boot" "$DESK_RESTORE_UNIT" \
  || fail "packaged unit must run the release CLI: $(cat "$DESK_RESTORE_UNIT")"
if grep -q '%h/.local/bin/bercail' "$DESK_RESTORE_UNIT"; then
  fail "packaged unit still points at the skipped binary: $(cat "$DESK_RESTORE_UNIT")"
fi
grep -q '%h/.local/share/mise/shims' "$DESK_RESTORE_UNIT" \
  || fail "unit PATH drops mise shims: $(cat "$DESK_RESTORE_UNIT")"
rm -f "$DESK_RESTORE_UNIT"
printf 'PASS: packaged install runs the release CLI and keeps harness tools on PATH\n'

mv "$TMP_DIR/bin/systemctl" "$TMP_DIR/systemctl.off"
deploy_desk_restore_boot >/dev/null
[[ ! -e "$DESK_RESTORE_UNIT" ]] || fail "no user manager, no unit"
out="$(doctor_desk_restore)"; [[ -z "$out" ]] || fail "doctor stays quiet without a way in: $out"
mv "$TMP_DIR/systemctl.off" "$TMP_DIR/bin/systemctl"
rm -f "$TMP_DIR/systemctl-calls"
printf 'PASS: no boot wiring without a user manager\n'

mkdir -p "$HOME/.local/share/omarchy"
fake_omarchy
deploy_desk_restore_boot >/dev/null
cmp -s "$ROOT/config/omarchy/bercail-desk-restore.hook" "$OMARCHY_POST_BOOT_HOOK" || fail "Omarchy gets the post-boot hook"
[[ -x "$OMARCHY_POST_BOOT_HOOK" ]] || fail "hook not executable"
[[ ! -e "$DESK_RESTORE_UNIT" ]] || fail "one way in per machine"
out="$(deploy_desk_restore_boot)"
[[ "$out" == *"unchanged: $OMARCHY_POST_BOOT_HOOK"* ]] || fail "second update leaves the hook: $out"
printf 'PASS: Omarchy gets the post-boot hook, and keeps one\n'

# The hook must return at once: omarchy-hook runs its hooks in a row.
cat >"$TMP_DIR/bin/bercail" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >"$TMP_DIR/hook-ran"
EOF
chmod +x "$TMP_DIR/bin/bercail"
timeout 5 bash "$OMARCHY_POST_BOOT_HOOK" </dev/null >/dev/null 2>&1 || fail "hook failed or hung"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [[ ! -f "$TMP_DIR/hook-ran" ]] || break
  sleep 0.2
done
expect "$(cat "$TMP_DIR/hook-ran")" "desk restore --boot" "the hook starts the boot run"
rm -f "$TMP_DIR/bin/bercail"
timeout 5 bash "$OMARCHY_POST_BOOT_HOOK" </dev/null >/dev/null 2>&1 || fail "hook without bercail must not fail"
printf 'PASS: the hook returns at once and runs the boot restore\n'

# Claude's settings: one entry added, the rest untouched, uninstall takes it back.
SETTINGS="$HOME/.claude/settings.json"
deploy_desk_claude_hook >/dev/null
[[ ! -e "$SETTINGS" ]] || fail "no ~/.claude, no settings created"
mkdir -p "$HOME/.claude"
printf '{"model":"x","hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"mine"}]}],"Stop":[{"hooks":[]}]}}\n' >"$SETTINGS"
deploy_desk_claude_hook >/dev/null
deploy_desk_claude_hook >/dev/null
HOOK_CMD="$LOCAL_BIN/bercail-desk-claude-hook"
expect "$(jq -c '[.hooks.SessionStart[].hooks[].command]' "$SETTINGS")" "[\"mine\",\"$HOOK_CMD\"]" "added once, beside the person's own"
expect "$(jq -c --arg c "$HOOK_CMD" '[.hooks.SessionStart[].hooks[] | select(.command == $c) | .args]' "$SETTINGS")" '[[]]' "new hook is the exec form"
expect "$(jq -r .model "$SETTINGS")" x "other settings stay"
touch "$OMARCHY_POST_BOOT_HOOK"
remove_desk_restore >/dev/null
[[ ! -e "$OMARCHY_POST_BOOT_HOOK" ]] || fail "uninstall removes the hook"
expect "$(jq -c .hooks.SessionStart "$SETTINGS")" '[{"hooks":[{"type":"command","command":"mine"}]}]' "uninstall takes only ours"
jq -e '.hooks.Stop' "$SETTINGS" >/dev/null || fail "uninstall leaves other hooks"
printf '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"%s"}]}]}}\n' "$HOOK_CMD" >"$SETTINGS"
remove_desk_restore >/dev/null
expect "$(cat "$SETTINGS")" '{}' "uninstall leaves no empty hooks behind"
printf 'not json' >"$SETTINGS"
out="$(deploy_desk_claude_hook 2>&1)"
[[ "$out" == *"not valid JSON"* ]] || fail "broken settings are reported: $out"
expect "$(cat "$SETTINGS")" 'not json' "broken settings are left alone"
printf 'PASS: the Claude hook is added once, kept apart, and removed cleanly\n'
