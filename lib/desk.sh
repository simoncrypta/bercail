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
# writes one at its first message), where --session would exit.
desk_resume_command() {
  local record="$1" agent session cwd arg cmd args lead
  agent="$LOCAL_BIN/bercail-desk-agent"
  [[ -x "$agent" ]] || agent="bercail-desk-agent"
  session="$(jq -r .session <<<"$record")"
  cwd="$(jq -r .cwd <<<"$record")"
  args="$(jq -c '.args // []' <<<"$record")"
  # Old plain-Pi records have no managed profile. Resume them on today's lead,
  # but keep a guarded lead or read-only reviewer exactly as it was recorded.
  if ! jq -e 'any(.[]; test("(^|/)(guard|review)\\.ts$"))' <<<"$args" >/dev/null; then
    lead="$BERCAIL_SHARE_DIR/pi/lead.json"
    [[ -r "$lead" ]] || { die "$lead is missing; run bercail update"; return 1; }
    args="$(jq -c --argjson saved "$args" '
      .[1:] | if any($saved[]; . == "--model" or startswith("--model=")) then
        index("--model") as $i | if $i == null then . else .[:$i] + .[$i + 2:] end
      else . end | . + $saved' "$lead")" || return 1
  fi
  printf -v cmd 'cd %q && TERM=xterm-256color COLORTERM=truecolor exec %q pi --session-id %q' \
    "$cwd" "$agent" "$session"
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
# (any hc command would): that happens when the person opens Herdr.
_desk_restore_boot() {
  local rc=0
  [[ -n "${XDG_RUNTIME_DIR:-}" ]] || die "bercail desk restore --boot needs XDG_RUNTIME_DIR"
  _desk_lock_acquire || return 1
  _desk_restore_boot_locked || rc=$?
  _desk_lock_release
  return "$rc"
}

_desk_restore_boot_locked() {
  local marker deadline desks
  marker="$XDG_RUNTIME_DIR/bercail-desk-restore.done"
  [[ ! -e "$marker" ]] || return 0
  until [[ -S "$XDG_RUNTIME_DIR/herdr-core/${HC_SESSION:-default}.sock" ]]; do
    sleep "${DESK_RESTORE_POLL:-5}"
  done
  deadline=$((SECONDS + DESK_RESTORE_RECOVERY_WAIT))
  while :; do
    if _desk_restore; then
      touch "$marker"
      if ((DESK_RESUMED > 0)) && command -v notify-send >/dev/null 2>&1; then
        desks="desks"
        ((DESK_RESUMED > 1)) || desks="desk"
        notify-send "Bercail" "$DESK_RESUMED $desks came back" || true
      fi
      return 0
    fi
    ((SECONDS < deadline)) || return 1
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

# Asks a live Pi desk to switch model through the bercail-desk extension: a
# request file it takes when it is idle, never a chat message. Waits a moment
# for the answer; a busy desk switches when its run ends.
_desk_model() {
  local desk="$1" model="$2" terminal address record pid dir id request reply answer="" i
  [[ "$model" =~ ^[^/[:space:]]+/[^[:space:]]+$ ]] \
    || die "bercail desk model takes PROVIDER/MODEL[:thinking], as pi --list-models names it (claude-bridge/claude-opus-5-5:high), not $model"
  terminal="$(_desk_hc get "$desk" --json 2>/dev/null)" || die "no live terminal $desk (hc ls lists them)"
  jq -e '.state == "live" and .labels["bercail.role"] == "agent"' <<<"$terminal" >/dev/null \
    || die "$desk is not a live desk; only a desk (label bercail.role=agent) switches model"
  address="$(jq -r .address <<<"$terminal")"
  record="$(_desk_sessions_dir)/$address.json"
  pid="$(jq -r 'select(.harness == "pi") | .pid // empty' "$record" 2>/dev/null || true)"
  [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null \
    || die "$desk has no running Pi desk agent ($record); start it with bercail-desk-agent"
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

cmd_desk() {
  local sub="${1:-}" mode=""
  shift || true
  if [[ "$sub" == model ]]; then
    (($# == 2)) || die "usage: bercail desk model DESK PROVIDER/MODEL[:thinking]"
    _desk_model "$1" "$2"
    return
  fi
  [[ "$sub" == restore ]] || die "usage: bercail desk restore [--dry-run] | desk model DESK PROVIDER/MODEL[:thinking]"
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
