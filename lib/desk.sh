#!/usr/bin/env bash
# shellcheck shell=bash
# Desks come back after a reboot. A lost hc terminal keeps its address and labels
# but gets a bare shell; bercail-desk-agent leaves a record per terminal saying
# which session ran there, and this resumes it in place.
#
# Record: desk-sessions/<address>.json {address, session, cwd, harness, issue,
# space, args, pid}. Its mtime is a heartbeat while the agent lives.
# A live Pi also writes $XDG_RUNTIME_DIR/bercail/open-sessions/<pid>.json
# {pid, start_ticks, sessions} so an idle agent (hc records {}) is not started twice.

# shellcheck source=lib/git-backend.sh
source "$(dirname "${BASH_SOURCE[0]}")/git-backend.sh"

# A record this close to the shutdown was still running then.
DESK_RESTORE_WINDOW=600
# How long a pass waits for hc to finish giving lost terminals their shells.
DESK_RESTORE_RECOVERY_WAIT=120

# Closes the lock's fd: an hc that starts the core must not leave it holding the lock.
_desk_hc() { "${HC_BIN:-hc}" "$@" 9>&-; }

_desk_sessions_dir() {
  printf '%s/bercail/desk-sessions' "${XDG_STATE_HOME:-$HOME/.local/state}"
}

# When the machine last went down: the previous boot's last journal line. With
# no journal, this boot's start, then now. Both are later than the shutdown, so
# they err toward leaving a desk alone.
_desk_shutdown_time() {
  local t
  t="$(journalctl -b -1 -n 1 -o short-unix --no-pager -q 2>/dev/null | cut -d. -f1)" || true
  if [[ "$t" =~ ^[0-9]+$ ]]; then
    printf '%s' "$t"
    return 0
  fi
  t="$(awk '/^btime/ { print $2 }' /proc/stat 2>/dev/null)" || true
  printf '%s' "${t:-$(date +%s)}"
}

# The selection, from facts alone. stdin: JSON array of
#   {address, record (null when none), mtime, terminal (hc get; null when gone),
#    cwd_exists, in_ps (a process names this session),
#    open_sessions (session ids a live claim names)}
# A fact with no record and no desk label is only there so its .records count.
# It is not acted on. Prints {address, action, why, record}, where action is:
#   resume  type the resume command
#   wait    hc is still recovering this terminal; ask again shortly
#   gone    the terminal ended, so the record is garbage
#   skip    leave it alone, why says why
desk_restore_plan() {
  local shutdown="$1"
  jq --argjson shutdown "$shutdown" --argjson window "$DESK_RESTORE_WINDOW" '
    # At its prompt: the terminal runs a shell and nothing has started from it.
    def bare:
      (.foreground.name // "" | IN("bash", "zsh", "fish", "sh", "dash", "ksh"))
      and .foreground.pid == .pid and (.reported | not);
    def recovering: .reason != null or .foreground == null;
    # Running something, so its .records are a session that is open now. A bare
    # or recovering terminal still carries the session from before the reboot;
    # those keys are stale and must not block the resume. Idle counts when hc
    # has kept the keys (it usually reports {}).
    def hosting:
      . != null and .state == "live" and (recovering | not) and (bare | not);
    def actionable:
      .record != null or (.terminal.labels["bercail.role"] == "agent");
    def decide($d; $open; $taken):
      $d.terminal as $t | $d.record as $r
      | if $t == null or $t.state != "live" then ["gone", "terminal ended"]
        elif $t.labels["bercail.role"] != "agent" then ["skip", "not a desk"]
        elif ($t | recovering) then ["wait", "hc is recovering it"]
        elif ($t | bare | not) then ["skip", "already running"]
        elif $r == null then ["skip", "no record: see the desk-restore skill"]
        elif $r.space != $t.labels["bercail.space"] then ["skip", "record is for another space"]
        elif ($r.session // "") == "" then ["skip", "no session yet"]
        elif $d.mtime < ($shutdown - $window) then ["skip", "closed before the shutdown"]
        elif ($d.cwd_exists | not) then ["skip", "folder is gone: \($r.cwd)"]
        elif $d.in_ps or ($open | index($r.session)) or ($taken | index($r.session)) then ["skip", "session is open elsewhere"]
        else ["resume", ""] end;
    . as $all
    | ([$all[] | select(.record.session and (.terminal | hosting)) | .record.session]
       + [$all[] | select(.terminal | hosting) | .terminal.records // {} | keys[]]
       + [$all[] | .open_sessions // [] | .[]]) as $open
    | reduce ($all[] | select(actionable)) as $d ({taken: [], out: []};
        decide($d; $open; .taken) as [$action, $why]
        | .out += [{address: $d.address, action: $action, why: $why, record: $d.record}]
        | if $action == "resume" then .taken += [$d.record.session] else . end)
    | .out'
}

# The line typed into the bare shell. exec: quitting the agent then finishes the
# terminal as a quit desk does, instead of leaving a live labelled shell.
# Same terminal settings as a desk's spawn; no prompt, the session has it.
# Pi takes --session-id: it creates the session when it was never written (Pi
# writes one at its first message), where --session would exit. PI: the Pi to
# run, when the shell's own PATH may find another.
desk_resume_command() {
  local record="$1" pi="${2:-pi}" agent session cwd arg cmd args lead bridge
  agent="$LOCAL_BIN/bercail-desk-agent"
  [[ -x "$agent" ]] || agent="bercail-desk-agent"
  session="$(jq -r .session <<<"$record")"
  cwd="$(jq -r .cwd <<<"$record")"
  args="$(jq -c '.args // []' <<<"$record")"
  lead="$BERCAIL_SHARE_DIR/pi/lead.json"
  # Old plain-Pi records have no managed profile. Resume them on today's lead,
  # but keep a guarded lead or read-only reviewer as it was recorded, bar the bridge.
  if ! jq -e 'any(.[]; test("(^|/)(guard|review)\\.ts$"))' <<<"$args" >/dev/null; then
    [[ -r "$lead" ]] || { die "$lead is missing; run bercail update"; return 1; }
    args="$(jq -c --argjson saved "$args" '
      .[1:] | if any($saved[]; . == "--model" or startswith("--model=")) then
        index("--model") as $i | if $i == null then . else .[:$i] + .[$i + 2:] end
      else . end | . + $saved' "$lead")" || return 1
  fi
  # The bridge the desk started on may be an older pin. Desks resumed together on
  # two pins reinstall it over each other in Pi's one npm prefix, and a Pi that
  # loads mid-install mixes the versions' files. Take today's.
  bridge="$(jq -r 'first(.[] | select(startswith("npm:pi-claude-bridge@"))) // empty' "$lead" 2>/dev/null)" || true
  if [[ -n "$bridge" ]]; then
    args="$(jq -c --arg bridge "$bridge" '. as $a | [range(length) as $i | $a[$i]
      | if $i > 0 and ($a[$i - 1] | IN("-e", "--extension")) and startswith("npm:pi-claude-bridge@")
        then $bridge else . end]' <<<"$args")" || return 1
  fi
  printf -v cmd 'cd %q && TERM=xterm-256color COLORTERM=truecolor exec %q %q --session-id %q' \
    "$cwd" "$agent" "$pi" "$session"
  # NUL, not lines: a recorded flag may contain a newline, and a line split would
  # turn one argument into two.
  while IFS= read -r -d '' arg; do
    printf -v cmd '%s %q' "$cmd" "$arg"
  done < <(jq -j '.[] | ., "\u0000"' <<<"$args")
  printf '%s' "$cmd"
}

# Field 22 of /proc/pid/stat: start time in clock ticks. comm is in parentheses
# and may contain spaces, so count from the last ')'.
_desk_start_ticks() {
  local stat pid="$1"
  [[ "$pid" =~ ^[0-9]+$ && -r "/proc/$pid/stat" ]] || return 1
  stat="$(<"/proc/$pid/stat")" || return 1
  awk '{ print $20 }' <<<"${stat##*)}"
}

# Sessions a live TUI has claimed. Stale when the pid is gone or reused
# (start_ticks no longer matches). A TUI that started before the plugin has no
# claim: only a live claim, hc .records, or a process argument names a session.
# Treating every uninstrumented TUI as holding it would block restore on a
# machine that already has one open.
_desk_claim_sessions() {
  local dir="${XDG_RUNTIME_DIR:-}/bercail/open-sessions" file pid ticks live
  [[ -n "${XDG_RUNTIME_DIR:-}" && -d "$dir" ]] || { printf '[]'; return 0; }
  for file in "$dir"/*.json; do
    [[ -f "$file" ]] || continue
    pid="$(jq -r '.pid // empty' "$file" 2>/dev/null)" || continue
    ticks="$(jq -r '.start_ticks // empty' "$file" 2>/dev/null)" || continue
    [[ -n "$pid" && -n "$ticks" ]] || continue
    live="$(_desk_start_ticks "$pid" 2>/dev/null)" || continue
    [[ "$live" == "$ticks" ]] || continue
    jq -r '.sessions[]? | select(type == "string" and . != "")' "$file" 2>/dev/null || true
  done | jq -R . | jq -s 'unique'
}

# Every live terminal hc knows, plus every record: facts for desk_restore_plan.
# A terminal that is not a desk is not resumed or cleaned up; its .records still
# count, including an idle agent when hc has kept the keys. Claims are read on
# every pass. Fails when hc cannot answer, so an outage never reads as "gone".
_desk_gather() {
  local dir list address terminal rc record mtime cwd_exists in_ps ps_args file session claims
  local -A addresses=()
  dir="$(_desk_sessions_dir)"
  list="$(_desk_hc ls --json)" || return 1
  while IFS= read -r address; do
    [[ -z "$address" ]] || addresses["$address"]=1
  done < <(jq -r '.terminals[]? | select(.state == "live") | .address' <<<"$list")
  for file in "$dir"/*.json; do
    [[ -f "$file" ]] || continue
    address="$(basename "$file" .json)"
    addresses["$address"]=1
  done
  ps_args="$(ps -eo args= 2>/dev/null || true)"
  claims="$(_desk_claim_sessions)"
  for address in "${!addresses[@]}"; do
    rc=0
    terminal="$(_desk_hc get "$address" --json 2>/dev/null)" || rc=$?
    case "$rc" in
      0) terminal="$(jq -c '{state, reason, reported, pid, foreground, labels, records}' <<<"$terminal")" ;;
      3) terminal=null ;;
      *) return 1 ;;
    esac
    record=null mtime=0 cwd_exists=false in_ps=false
    file="$dir/$address.json"
    if [[ -f "$file" ]] && jq -e . "$file" >/dev/null 2>&1; then
      record="$(<"$file")"
      mtime="$(stat -c %Y "$file" 2>/dev/null || stat -f %m "$file")"
      [[ ! -d "$(jq -r '.cwd // ""' "$file")" ]] || cwd_exists=true
      session="$(jq -r '.session // ""' "$file")"
      [[ -z "$session" ]] || ! grep -qF -- "$session" <<<"$ps_args" || in_ps=true
    fi
    jq -cn --arg address "$address" --argjson record "$record" --argjson mtime "$mtime" \
      --argjson terminal "$terminal" --argjson cwd_exists "$cwd_exists" --argjson in_ps "$in_ps" \
      --argjson open_sessions "$claims" \
      '{address: $address, record: $record, mtime: $mtime, terminal: $terminal,
        cwd_exists: $cwd_exists, in_ps: $in_ps, open_sessions: $open_sessions}'
  done | jq -s 'sort_by(.address)'
}

# Same plan, on a fresh hc get. The gather can take seconds; if the shell is
# busy or no longer this desk, do not type. A start in the gap after this check
# can still land a line; that race stays. Prints {action, why}. Fails when hc
# does not answer.
_desk_confirm_resume() {
  local address="$1" shutdown="$2" facts="$3" terminal rc=0 fact
  fact="$(jq -c --arg a "$address" '.[] | select(.address == $a)' <<<"$facts")"
  [[ -n "$fact" ]] || { warn "hc did not answer: desks left alone"; return 1; }
  terminal="$(_desk_hc get "$address" --json 2>/dev/null)" || rc=$?
  case "$rc" in
    0) ;;
    3) terminal=null ;;
    *) warn "hc did not answer: desks left alone"; return 1 ;;
  esac
  jq -c --argjson t "$terminal" '.terminal = $t' <<<"$fact" | jq -s . \
    | desk_restore_plan "$shutdown" | jq -c '.[0] | {action, why}'
}

# One pass. Prints a line per desk. Sets DESK_RESUMED and DESK_WAITING. A terminal
# typed into is not typed into again: its shell may still be loading its rc files
# on the next pass, and a second line would land in the agent's input.
declare -gA DESK_TYPED=()
_desk_restore_pass() {
  local dry="$1" facts plan shutdown row address action why record what confirm named tag command
  DESK_RESUMED=0 DESK_WAITING=0
  facts="$(_desk_gather)" || { warn "hc did not answer: desks left alone"; return 1; }
  shutdown="$(_desk_shutdown_time)"
  plan="$(desk_restore_plan "$shutdown" <<<"$facts")"
  while IFS= read -r row; do
    address="$(jq -r .address <<<"$row")"
    [[ -z "${DESK_TYPED[$address]:-}" ]] || continue
    action="$(jq -r .action <<<"$row")"
    why="$(jq -r .why <<<"$row")"
    record="$(jq -c .record <<<"$row")"
    # The desk's issue as "id: title", or the bare id, so an address reads as a job.
    named="$(jq -r '(.issue // "") as $i | (.issue_title // "") as $t
      | if $i != "" and $t != "" then "\($i): \($t)" else $i end' <<<"$record")"
    tag="${named:+  ($named)}"
    case "$action" in
      resume)
        what="$(jq -r --arg named "$named" '[$named, .session, .cwd] | map(select(. != "")) | join("  ")' <<<"$record")"
        if [[ "$dry" -eq 1 ]]; then
          printf '%-6s would resume  %s\n' "$address" "$what"
          DESK_RESUMED=$((DESK_RESUMED + 1))
        else
          confirm="$(_desk_confirm_resume "$address" "$shutdown" "$facts")" || return 1
          action="$(jq -r .action <<<"$confirm")"
          if [[ "$action" != resume ]]; then
            why="$(jq -r .why <<<"$confirm")"
            if [[ "$action" == wait ]]; then
              DESK_WAITING=$((DESK_WAITING + 1))
              printf '%-6s waiting: %s%s\n' "$address" "$why" "$tag"
            else
              printf '%-6s skip: %s%s\n' "$address" "$why" "$tag"
            fi
          elif ! command="$(desk_resume_command "$record")"; then
            return 1
          elif _desk_hc send "$address" "$command" >/dev/null; then
            DESK_TYPED["$address"]=1
            printf '%-6s resumed  %s\n' "$address" "$what"
            DESK_RESUMED=$((DESK_RESUMED + 1))
          else
            printf '%-6s could not type into it\n' "$address"
            return 1
          fi
        fi
        ;;
      wait)
        DESK_WAITING=$((DESK_WAITING + 1))
        printf '%-6s waiting: %s%s\n' "$address" "$why" "$tag"
        ;;
      gone)
        [[ "$dry" -eq 1 ]] || rm -f "$(_desk_sessions_dir)/$address.json"
        ;;
      *) printf '%-6s skip: %s%s\n' "$address" "$why" "$tag" ;;
    esac
  done < <(jq -c '.[]' <<<"$plan")
}

# fd 9, closed in the hc child by _desk_hc so a core hc starts does not keep it.
# Non-blocking: the same process already holding it (boot calling restore) must
# not flock again and deadlock.
_desk_lock_acquire() {
  [[ -z "${DESK_LOCK_HELD:-}" ]] || return 0
  command -v flock >/dev/null 2>&1 || return 0
  exec 9>"${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/bercail-desk-restore.lock"
  flock -n 9 || { exec 9>&-; warn "another desk restore is running"; return 1; }
  DESK_LOCK_HELD=1
}

_desk_lock_release() {
  [[ -n "${DESK_LOCK_HELD:-}" ]] || return 0
  exec 9>&-
  unset DESK_LOCK_HELD
}

# Pass until hc has recovered every terminal, or the wait runs out. Still waiting
# at the deadline, or a send that did not land, is a failure. One at a time: the
# boot run and a manual run must not both type into a shell.
_desk_restore() {
  local owned=0 rc=0 deadline total=0
  if [[ -z "${DESK_LOCK_HELD:-}" ]]; then
    _desk_lock_acquire || return 1
    owned=1
  fi
  deadline=$((SECONDS + DESK_RESTORE_RECOVERY_WAIT))
  while :; do
    _desk_restore_pass 0 || rc=1
    if [[ "$rc" -ne 0 ]]; then
      break
    fi
    total=$((total + DESK_RESUMED))
    if ((DESK_WAITING == 0)); then
      break
    fi
    if ((SECONDS >= deadline)); then
      warn "hc is still recovering desks"
      rc=1
      break
    fi
    sleep "${DESK_RESTORE_POLL:-5}"
  done
  if [[ "$rc" -eq 0 ]]; then
    DESK_RESUMED="$total"
  fi
  if [[ "$owned" -eq 1 ]]; then
    _desk_lock_release
  fi
  return "$rc"
}

# Once per boot, from the login hook: $XDG_RUNTIME_DIR is empty at each boot, so
# the marker means "done since this boot". The lock is taken before the marker
# check, and the marker is written only after a completed pass. A failure leaves
# it unset so a later attempt can retry. Waits for the core rather than start it
# (any hc command would): that happens when the person opens Herdr. Then it
# starts the routine loop, so routines run with no window open; the marker
# waits for that too. A later attempt types only into desks still at a bare shell.
_desk_restore_boot() {
  local rc=0
  [[ -n "${XDG_RUNTIME_DIR:-}" ]] || die "bercail desk restore --boot needs XDG_RUNTIME_DIR"
  _desk_lock_acquire || return 1
  _desk_restore_boot_locked || rc=$?
  _desk_lock_release
  return "$rc"
}

_desk_restore_boot_locked() {
  local marker deadline desks restored=0 started=0
  marker="$XDG_RUNTIME_DIR/bercail-desk-restore.done"
  [[ ! -e "$marker" ]] || return 0
  until [[ -S "$XDG_RUNTIME_DIR/herdr-core/${HC_SESSION:-default}.sock" ]]; do
    sleep "${DESK_RESTORE_POLL:-5}"
  done
  # shellcheck source=lib/routine.sh
  declare -F routine_start_loop >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/routine.sh"
  # Two duties, each tried until it is done: a stuck desk does not keep the
  # routines from running, nor the loop the desks from coming back.
  deadline=$((SECONDS + DESK_RESTORE_RECOVERY_WAIT))
  while :; do
    if ((!restored)) && _desk_restore; then
      restored=1
      if ((DESK_RESUMED > 0)) && command -v notify-send >/dev/null 2>&1; then
        desks="desks"
        ((DESK_RESUMED > 1)) || desks="desk"
        notify-send "Bercail" "$DESK_RESUMED $desks came back" || true
      fi
    fi
    ((started)) || ! routine_start_loop 9>&- || started=1
    if ((restored && started)); then
      touch "$marker"
      return 0
    fi
    if ((SECONDS >= deadline)); then
      ((started)) || warn "could not start the routine loop; bercail routine start starts it"
      return 1
    fi
    sleep "${DESK_RESTORE_POLL:-5}"
  done
}

# --- model ---

# How long `desk model` waits for an idle desk to answer, in seconds.
DESK_MODEL_WAIT="${BERCAIL_DESK_MODEL_WAIT:-5}"

_desk_commands_dir() {
  printf '%s/bercail/desk-commands' "${XDG_STATE_HOME:-$HOME/.local/state}"
}

# Dies unless Pi lists MODEL's provider/id, with the lead's extensions loaded:
# a provider can come from one (claude-bridge).
_desk_model_check() {
  local model="$1" id ext list lead="$BERCAIL_SHARE_DIR/pi/lead.json"
  local -a argv=(pi --offline --list-models)
  id="$(sed -E 's/:(off|minimal|low|medium|high|xhigh|max)$//' <<<"$model")"
  while IFS= read -r ext; do
    [[ -z "$ext" ]] || argv+=(-e "$ext")
  done < <(jq -r '. as $a | range(0; length) | select($a[.] == "-e") | $a[. + 1]' "$lead" 2>/dev/null || true)
  list="$(env -u ANTHROPIC_API_KEY -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN "${argv[@]}" </dev/null 2>/dev/null)" \
    || die "pi --list-models failed, so $model cannot be checked. Run ${argv[*]} to see why."
  awk -v want="$id" 'NR > 1 && $1 "/" $2 == want { found = 1 } END { exit !found }' <<<"$list" \
    || die "Pi has no model $id. pi --list-models lists the ones you can use."
}

# Sets DESK_ADDRESS, DESK_RECORD and DESK_PID for DESK, a live Pi desk, or dies.
# WHAT finishes "only a desk ..." in the error.
_desk_live() {
  local desk="$1" what="$2" terminal
  terminal="$(_desk_hc get "$desk" --json 2>/dev/null)" || die "no live terminal $desk (hc ls lists them)"
  jq -e '.state == "live" and .labels["bercail.role"] == "agent"' <<<"$terminal" >/dev/null \
    || die "$desk is not a live desk; only a desk (label bercail.role=agent) $what"
  DESK_ADDRESS="$(jq -r .address <<<"$terminal")"
  DESK_RECORD="$(_desk_sessions_dir)/$DESK_ADDRESS.json"
  DESK_PID="$(jq -r 'select(.harness == "pi") | .pid // empty' "$DESK_RECORD" 2>/dev/null || true)"
  [[ "$DESK_PID" =~ ^[0-9]+$ ]] && kill -0 "$DESK_PID" 2>/dev/null \
    || die "$desk has no running Pi desk agent ($DESK_RECORD); start it with bercail-desk-agent"
}

# Asks a live Pi desk to switch model through the bercail-desk extension: a
# request file it takes when it is idle, never a chat message. Waits a moment
# for the answer; a busy desk switches when its run ends.
_desk_model() {
  local desk="$1" model="$2" address pid dir id request reply answer="" i
  [[ "$model" =~ ^[^/[:space:]]+/[^[:space:]]+$ ]] \
    || die "bercail desk model takes PROVIDER/MODEL[:thinking], as pi --list-models names it (claude-bridge/claude-opus-5-5:high), not $model"
  _desk_live "$desk" "switches model"
  address="$DESK_ADDRESS" pid="$DESK_PID"
  _desk_model_check "$model"
  dir="$(_desk_commands_dir)"
  ( umask 077 && mkdir -p "$dir" ) || die "cannot create $dir"
  id="$(date +%s)-$$-$RANDOM"
  reply="$dir/$address.done.json"
  rm -f "$reply"
  request="$(umask 077 && mktemp "$dir/.$address.json.XXXXXX")" || die "cannot write to $dir"
  jq -n --arg id "$id" --argjson pid "$pid" --arg model "$model" '{id: $id, pid: $pid, model: $model}' >"$request" \
    && mv "$request" "$dir/$address.json" || { rm -f "$request"; die "cannot write to $dir"; }
  for ((i = 0; i < DESK_MODEL_WAIT * 5; i++)); do
    answer="$(jq -c --arg id "$id" 'select(.id == $id)' "$reply" 2>/dev/null || true)"
    [[ -z "$answer" ]] || break
    sleep 0.2
  done
  if [[ -z "$answer" ]]; then
    log "$address is busy: it switches to $model when its current run ends"
  elif [[ "$(jq -r .status <<<"$answer")" == switched ]]; then
    log "$address switched to $(jq -r .model <<<"$answer") (was $(jq -r .from <<<"$answer"))"
  else
    die "$address refused $model: $(jq -r .reason <<<"$answer")"
  fi
}

# --- restart ---

# How long `desk restart` waits for hc to give the desk its shell, then for the new Pi, in seconds.
DESK_RESTART_WAIT="${BERCAIL_DESK_RESTART_WAIT:-60}"
# How long one hc get may take: a core that stops answering must not hold up bercail update.
DESK_RESTART_HC_WAIT="${BERCAIL_DESK_RESTART_HC_WAIT:-10}"

_desk_restart_get() { _git_backend_bounded "$DESK_RESTART_HC_WAIT" _desk_hc get "$1" --json 2>/dev/null </dev/null; }

# Why the desk in TERMINAL (hc get) may not be restarted now, or nothing: it must
# be idle and run the Pi its record names (by start time too, when the record
# has it), with no follow-up or model switch waiting for that Pi, and, where its
# desk extension says so (runtime/PID.json), no unsent text or queued messages
# in its last second. An older extension says nothing.
_desk_restart_refusal() {
  local terminal="$1" state address pid ticks record queued=0 model runtime
  local -a ups
  state="$(dirname "$(_desk_sessions_dir)")"
  address="$(jq -r .address <<<"$terminal")"
  pid="$(jq -r .pid <<<"$terminal")"
  ticks="$(_desk_start_ticks "$pid" 2>/dev/null)" || ticks=""
  record="$(jq -c 'objects' "$(_desk_sessions_dir)/$address.json" 2>/dev/null)" || record=""
  ups=("$state/desk-follow-ups/$address"/*.json)
  [[ ! -e "${ups[0]}" ]] || queued="$(jq -s 'map(select(.delivery == "queued")) | length' "${ups[@]}" 2>/dev/null)" || queued=-1
  [[ ! -d "$state/desk-follow-ups/$address" || (-r "$state/desk-follow-ups/$address" && -x "$state/desk-follow-ups/$address") ]] \
    || queued=-1
  model="$(jq -c 'objects' "$state/desk-commands/$address.json" 2>/dev/null)" || model=""
  runtime="$(jq -c --arg pid "$pid" --arg ticks "$ticks" 'select((.pid | tostring) == $pid and .start_ticks == $ticks)' \
    "$state/runtime/$pid.json" 2>/dev/null)" || runtime=""
  jq -r --argjson r "${record:-null}" --argjson q "$queued" --argjson m "${model:-null}" --argjson rt "${runtime:-null}" \
    --arg ticks "$ticks" '
    (.status.state // "unknown") as $s | "bercail desk restart \(.address) once it is idle" as $later
    | if .state != "live" or .labels["bercail.role"] != "agent" then "it is not a live desk (label bercail.role=agent)"
      elif .labels["bercail.shep"] == "bg" then "it is a background Shep: let it report, then start a new one with bercail shep bg"
      elif .keep != true then "hc does not keep it, so ending its Pi would end the desk"
      elif ($s | IN("idle", "done") | not) then "it is \($s); \($later)"
      elif $r.harness != "pi" or $r.pid != .pid or ($r.session // "") == "" or $r.space != .labels["bercail.space"]
        or $ticks == "" or (($r.start_ticks // "") != "" and $r.start_ticks != $ticks) then
        "its desk record does not name the Pi running there"
      elif any($r.args[]?; . == "--api-key" or startswith("--api-key=")) then
        "its flags hold an API key, which the resume line would pass to hc; restart it by hand"
      elif $q < 0 then "its follow-ups cannot be read"
      elif $q > 0 then "a follow-up waits for its Pi; \($later)"
      elif $m.pid == .pid then "a model switch waits for its Pi; \($later)"
      elif $rt.draft == true then "its editor holds text not sent yet"
      elif $rt.pending == true or $rt.idle == false then "Pi has messages queued; \($later)"
      else empty end' <<<"$terminal"
}

# Ends an idle desk's Pi and starts Pi again on its session in the same
# terminal, so it loads the code bercail update installed. SIGKILL, not TERM: Pi takes TERM as a quit and exits 0, which
# finishes the terminal; a death by signal makes hc give a kept terminal a shell
# in place, its labels kept, and that shell gets the restore's resume line. Done
# only once the new Pi's desk extension wrote the record for that session file;
# the restore's lock is held till then.
_desk_restart() {
  local desk="$1" file terminal address name pid why record path pi command written now i
  local shell='.state == "live" and .reason == null and .pid != null and .foreground.pid == .pid
    and (.foreground.name // "" | IN("bash", "zsh", "fish", "sh", "dash", "ksh"))'
  terminal="$(_desk_restart_get "$desk")" || die "no live terminal $desk (hc ls lists them)"
  address="$(jq -r .address <<<"$terminal")"
  name="$(jq -r '.labels as $l | "desk \(.address)" + if ($l["bercail.issue"] // "") == "" then ""
    else " (\($l["bercail.issue"])\($l["bercail.issue_title"] // "" | if . != "" then ": " + . else "" end))" end' <<<"$terminal")"
  why="$(_desk_restart_refusal "$terminal")"
  [[ -z "$why" ]] || die "$name is not restarted: $why"
  pid="$(jq -r .pid <<<"$terminal")"
  file="$(_desk_sessions_dir)/$address.json"
  record="$(jq -c . "$file")" || die "$name is not restarted: cannot read $file"
  [[ -d "$(jq -r .cwd <<<"$record")" ]] || die "$name is not restarted: its folder $(jq -r .cwd <<<"$record") is gone"
  # The pi this desk's PATH found when it started: the new shell's rc files may put another first.
  path="$(tr '\0' '\n' 2>/dev/null <"${BERCAIL_PROC_DIR:-/proc}/$pid/environ" | sed -n 's/^PATH=//p' | head -n 1)" || path=""
  pi="$(PATH="$path" command -v pi)" || die "$name is not restarted: no pi on the PATH its Pi started with"
  command="$(desk_resume_command "$record" "$pi")" || return 1
  # The restore types into bare desk shells too: one at a time.
  _desk_lock_acquire 2>/dev/null || die "$name is not restarted: a desk restore is running; try again when it ends"
  # Again, just before the kill: the same Pi on the same session, still idle.
  terminal="$(_desk_restart_get "$address")" || die "hc did not answer; $name is left alone"
  why="$(_desk_restart_refusal "$terminal")"
  [[ -n "$why" || ("$(jq -r .pid <<<"$terminal")" == "$pid" && "$(jq -c . "$file" 2>/dev/null)" == "$record") ]] \
    || why="its Pi or session changed since bercail first looked"
  [[ -z "$why" ]] || die "$name is not restarted: $why"
  kill -KILL "$pid" 2>/dev/null || die "could not end $name's Pi (pid $pid)"
  for ((i = 0; i < DESK_RESTART_WAIT * 5; i++)); do
    if terminal="$(_desk_restart_get "$address")"; then
      jq -e ".state != \"live\" or ($shell)" <<<"$terminal" >/dev/null && break
    fi
    sleep 0.2
  done
  jq -e "$shell" <<<"$terminal" >/dev/null \
    || die "$name's Pi ended, but hc gave it no shell; start it again: Ctrl+Shift+A in its space, then /resume session $(jq -r .session <<<"$record")"
  _git_backend_bounded "$DESK_RESTART_WAIT" _desk_hc send "$address" "$command" >/dev/null </dev/null \
    || die "$name is at a shell, but bercail could not type its resume line; start it again: /resume session $(jq -r .session <<<"$record")"
  # A session Pi never wrote (no message yet) has nothing to reopen, so another file for it is fine.
  written=false
  [[ ! -f "$(jq -r '.session_file // ""' <<<"$record")" ]] || written=true
  for ((i = 0; i < DESK_RESTART_WAIT * 5; i++)); do
    now="$(jq -c . "$file" 2>/dev/null)" && terminal="$(_desk_restart_get "$address")" \
      && jq -en --argjson n "$now" --argjson t "$terminal" --argjson old "$record" --argjson written "$written" '
        $n.pid == $t.pid and $n.pid != $old.pid and $t.state == "live" and $t.foreground.pid == $t.pid
        and ($n.start_ticks // "") != "" and $n.session == $old.session
        and (($written | not) or $n.session_file == $old.session_file)' >/dev/null && break
    now=""
    sleep 0.2
  done
  [[ -n "$now" ]] || die "$name got its resume line, but no new Pi opened its session; hc read $address shows why"
  _desk_lock_release
  log "$name restarted on session $(jq -r .session <<<"$record")"
}

# --- guard prompts ---

# How long `desk answer` waits for the desk's guard to take an answer, in seconds.
DESK_ANSWER_WAIT="${BERCAIL_DESK_ANSWER_WAIT:-5}"
DESK_ANSWER_USAGE="usage: bercail desk prompt DESK | desk answer DESK yes|no --prompt ID [--reason TEXT] [--dry-run]"

_desk_prompts_dir() {
  printf '%s/bercail/desk-prompts' "${XDG_STATE_HOME:-$HOME/.local/state}"
}

# Text from a prompt as it may be shown: no credential in a URL
# (scheme://user:pass@ becomes scheme://***@). With "cut", at most 500 characters,
# for what is logged; a card shows all of it.
_desk_shown() {
  jq -rn --arg s "$1" --arg cut "${2:-}" '$s | gsub("(?<s>[A-Za-z][A-Za-z0-9+.-]*://)[^/@\\s]+@"; "\(.s)***@")
    | if $cut != "" and length > 500 then .[:500] + "…" else . end'
}

# The prompt the guard of the desk in DESK_ADDRESS/DESK_PID waits on, or status 1:
# only one written by that desk's own Pi counts.
_desk_pending() {
  jq -ce --arg a "$DESK_ADDRESS" --argjson pid "$DESK_PID" \
    'select(type == "object" and .address == $a and .pid == $pid and (.id | type) == "string")' \
    "$(_desk_prompts_dir)/$DESK_ADDRESS.json" 2>/dev/null
}

# Prints the guard prompt a desk waits on, with its issue, command and question redacted.
_desk_prompt() {
  local desk="$1" pending
  _desk_live "$desk" "has a guard prompt"
  pending="$(_desk_pending)" || die "$desk has no guard prompt waiting"
  jq -c --arg command "$(_desk_shown "$(jq -r '.command // ""' <<<"$pending")")" \
    --arg reason "$(_desk_shown "$(jq -r '.reason // ""' <<<"$pending")")" --slurpfile record "$DESK_RECORD" \
    '.command = $command | .reason = $reason | .issue = ($record[0].issue // "") | .issue_title = ($record[0].issue_title // "")' \
    <<<"$pending"
}

# The guard's receipt for this writer's answer, or nothing yet.
_desk_receipt() {
  jq -c --arg id "$1" --arg n "$2" 'select(.id == $id and .nonce == $n)' "$3" 2>/dev/null || true
}

# Answers the guard prompt a desk waits on through a file its guard reads, never
# by typing into it: ID must be the prompt read with desk prompt. One grammar, in
# this order, the one the guard reads too. One writer per desk at a time, under
# flock; the answer carries a nonce and the guard's receipt names it, so only the
# answer the guard took is logged on the desk's issue.
_desk_answer() {
  local desk="${1:-}" answer="${2:-}" id="" reason="" dry=0 pending word tool command line dir file reply tmp nonce lock got="" issue cwd title main i
  [[ "${3:-}" == --prompt && -n "${4:-}" ]] || die "$DESK_ANSWER_USAGE"
  id="$4"
  shift 4
  if [[ "${1:-}" == --reason ]] && (($# >= 2)); then reason="$2" && shift 2; fi
  if [[ "${1:-}" == --dry-run ]]; then dry=1 && shift; fi
  [[ "$desk" =~ ^[A-Za-z0-9_.][A-Za-z0-9_.-]*$ && "$answer" =~ ^(yes|no)$ ]] && (($# == 0)) || die "$DESK_ANSWER_USAGE"
  [[ "$answer" == yes || -n "${reason//[[:space:]]/}" ]] || die "a no needs --reason: the desk shows it to its agent"
  reason="$(_desk_shown "$reason")"
  _desk_live "$desk" "has a guard prompt"
  pending="$(_desk_pending)" && [[ "$(jq -r .id <<<"$pending")" == "$id" ]] \
    || die "the prompt you read is gone; bercail desk prompt $desk shows the one waiting now"
  word="${answer^}"
  tool="$(jq -r '.tool // ""' <<<"$pending")"
  issue="$(jq -r '.issue // ""' "$DESK_RECORD")"
  if ((dry)); then
    title="$(jq -r '.issue_title // ""' "$DESK_RECORD")"
    printf "Answer %s to desk %s's guard prompt%s: %s\n" "$word" "$DESK_ADDRESS" \
      "${issue:+ ($issue${title:+: $title})}" "$(_desk_shown "$(jq -r '.reason // ""' <<<"$pending")")"
    printf 'Its %s: %s\n' "$tool" "$(_desk_shown "$(jq -r '.command // ""' <<<"$pending")")"
    [[ "$answer" == yes ]] || printf 'Why: %s\n' "$reason"
    return 0
  fi
  command -v flock >/dev/null 2>&1 \
    || die "bercail desk answer needs flock, so two answers to one desk never cross (util-linux on Linux, brew install flock on macOS)"
  dir="$(_desk_prompts_dir)"
  exec {lock}>>"$dir/$DESK_ADDRESS.answer.lock" || die "cannot write to $dir"
  flock -n "$lock" || die "another answer to desk $DESK_ADDRESS waits for its guard; bercail desk prompt $desk shows what waits now"
  file="$dir/$DESK_ADDRESS.answer.json"
  nonce="$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')"
  reply="$dir/$DESK_ADDRESS.done-$nonce.json"
  tmp="$(umask 077 && mktemp "$dir/.$DESK_ADDRESS.answer.XXXXXX")" || die "cannot write to $dir"
  jq -cn --arg id "$id" --arg a "$answer" --arg r "$reason" --arg n "$nonce" '{id: $id, answer: $a, reason: $r, nonce: $n}' >"$tmp" \
    && mv "$tmp" "$file" || { rm -f "$tmp"; die "cannot write to $dir"; }
  for ((i = 0; i < DESK_ANSWER_WAIT * 5; i++)); do
    got="$(_desk_receipt "$id" "$nonce" "$reply")"
    [[ -z "$got" ]] || break
    sleep 0.2
  done
  if [[ -z "$got" ]]; then
    # Withdraw it: no other writer holds the lock, so a rename that works takes back
    # our own answer, which the guard never had.
    tmp="$dir/.$DESK_ADDRESS.withdrawn.$nonce"
    if mv "$file" "$tmp" 2>/dev/null; then
      rm -f "$tmp"
      die "desk $DESK_ADDRESS did not take the answer: its prompt may have closed. Nothing was answered."
    fi
    for ((i = 0; i < 5; i++)); do
      got="$(_desk_receipt "$id" "$nonce" "$reply")"
      [[ -z "$got" ]] || break
      sleep 0.2
    done
    [[ -n "$got" ]] \
      || die "desk $DESK_ADDRESS took the answer but did not say what became of it; the outcome is unknown: hc read $DESK_ADDRESS shows it."
  fi
  rm -f "$reply"
  [[ "$(jq -r .status <<<"$got")" == taken ]] \
    || die "desk $DESK_ADDRESS refused the answer: $(jq -r '.why // "no reason given"' <<<"$got")"
  command="$(_desk_shown "$(jq -r '.command // ""' <<<"$pending")" cut)"
  log "$DESK_ADDRESS answered $word: $command"
  if [[ -z "$issue" ]]; then
    warn "desk $DESK_ADDRESS has no issue in its record, so the answer is logged nowhere"
    return 0
  fi
  line="bercail desk answer: answered $word to desk $DESK_ADDRESS's guard prompt \"$(_desk_shown "$(jq -r '.reason // ""' <<<"$pending")" cut)\" (its $tool: $command)${reason:+: $(_desk_shown "$reason" cut)}"
  cwd="$(jq -r '.cwd // ""' "$DESK_RECORD")"
  main="$(git_backend_main "$cwd")" \
    || die "answered, but $cwd is no git checkout, so nothing went on $issue; log it there by hand: $line"
  if [[ "$issue" == trail:* ]]; then
    printf '%s' "$line" | node "$(dirname "${BASH_SOURCE[0]}")/jobs.ts" comment "$issue" --repo "$main" >/dev/null 2>&1 \
      || die "answered, but bercail could not comment on $issue in $main; log it by hand: printf '%s' $(printf '%q' "$line") | bercail job comment $issue --repo $main"
  else
    (cd "$main" && bd comment "$issue" "$line" </dev/null >/dev/null 2>&1) \
      || die "answered, but bd could not comment on $issue in $main; log it by hand: (cd $main && bd comment $issue $(printf '%q' "$line"))"
  fi
}

cmd_desk() {
  local sub="${1:-}" mode=""
  shift || true
  case "$sub" in
    model)
      (($# == 2)) || die "usage: bercail desk model DESK PROVIDER/MODEL[:thinking]"
      _desk_model "$1" "$2"
      return
      ;;
    prompt)
      (($# == 1)) || die "$DESK_ANSWER_USAGE"
      _desk_prompt "$1"
      return
      ;;
    answer)
      _desk_answer "$@"
      return
      ;;
    restart)
      (($# == 1)) || die "usage: bercail desk restart DESK"
      _desk_restart "$1"
      return
      ;;
  esac
  [[ "$sub" == restore ]] || die "usage: bercail desk restore [--dry-run] | desk restart DESK | desk model DESK PROVIDER/MODEL[:thinking] | desk prompt DESK | desk answer DESK yes|no --prompt ID [--reason TEXT] [--dry-run]"
  while (($#)); do
    case "$1" in
      --dry-run | --boot) mode="$1" ;;
      *) die "unknown option: $1" ;;
    esac
    shift
  done
  case "$mode" in
    --boot) _desk_restore_boot ;;
    --dry-run)
      _desk_restore_pass 1 || return 1
      log "$DESK_RESUMED would come back"
      ;;
    *)
      _desk_restore || return 1
      log "$DESK_RESUMED came back"
      ;;
  esac
}

# --- install ---

DESK_RESTORE_UNIT="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/bercail-desk-restore.service"

# A systemd user manager for this HOME: the one a unit under it would reach.
_desk_user_systemd() {
  [[ "$(detect_os)" == linux ]] || return 1
  [[ "$(systemctl --user show-environment 2>/dev/null | sed -n 's/^HOME=//p')" == "$HOME" ]]
}

_desk_omarchy_hook() {
  is_omarchy && command -v omarchy-hook-install >/dev/null 2>&1
}

# mise/packslip own the bercail command and do not copy it to ~/.local/bin.
# The unit must run the release's bin/bercail. PATH in the unit keeps mise shims.
_desk_point_restore_unit() {
  local cli tmp
  [[ "${BERCAIL_PACKAGED:-0}" == 1 ]] || return 0
  cli="$(install_src_dir)/bin/bercail"
  [[ -x "$cli" ]] || { warn "packaged bercail not found at $cli"; return 1; }
  [[ "$DRY_RUN" -eq 1 || ! -f "$DESK_RESTORE_UNIT" ]] && return 0
  tmp="$(mktemp)"
  awk -v cli="$cli" '
    /^ExecStart=/ { print "ExecStart=\"" cli "\" desk restore --boot"; next }
    { print }
  ' "$DESK_RESTORE_UNIT" >"$tmp" && mv "$tmp" "$DESK_RESTORE_UNIT"
}

# One way in per machine: Omarchy's post-boot hook, else a systemd user unit.
deploy_desk_restore_boot() {
  local staged="${BERCAIL_SHARE_DIR}/omarchy/bercail-desk-restore.hook"
  if _desk_omarchy_hook; then
    deploy_install_file "config/omarchy/bercail-desk-restore.hook" "$staged"
    if [[ -f "$OMARCHY_POST_BOOT_HOOK" ]] && cmp -s "$staged" "$OMARCHY_POST_BOOT_HOOK"; then
      info "unchanged: $OMARCHY_POST_BOOT_HOOK"
    else
      run omarchy-hook-install post-boot "$staged"
    fi
  elif _desk_user_systemd; then
    deploy_install_file "config/systemd/bercail-desk-restore.service" "$DESK_RESTORE_UNIT"
    _desk_point_restore_unit || return 1
    run systemctl --user daemon-reload
    run systemctl --user enable bercail-desk-restore.service
  fi
}

deploy_desk_restore() {
  deploy_desk_restore_boot || warn "could not set up the desk restore at boot"
}

remove_desk_restore() {
  if [[ -e "$OMARCHY_POST_BOOT_HOOK" ]]; then
    info "remove: $OMARCHY_POST_BOOT_HOOK"
    run rm -f "$OMARCHY_POST_BOOT_HOOK"
  fi
  if [[ -e "$DESK_RESTORE_UNIT" ]]; then
    info "remove: $DESK_RESTORE_UNIT"
    run systemctl --user disable bercail-desk-restore.service || true
    run rm -f "$DESK_RESTORE_UNIT"
  fi
}

doctor_desk_restore() {
  local way=""
  if _desk_omarchy_hook; then
    way="$OMARCHY_POST_BOOT_HOOK"
  elif _desk_user_systemd; then
    way="$DESK_RESTORE_UNIT"
  fi
  [[ -n "$way" ]] || return 0
  if [[ -f "$way" ]]; then
    log "  ok  desks come back after a reboot ($way)"
  else
    log "  missing  $way (run bercail update)"
    return 1
  fi
}
