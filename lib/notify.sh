#!/usr/bin/env bash
# shellcheck shell=bash
# The desk follower: watch the desk agents (hc terminals labelled
# bercail.role=agent) with `hc events` and write each finish or block to Shep's
# inbox, with a current source projection beside it.
#
#   bercail notify run         follow desks until hc's event stream ends
#
# The desk mod keeps one `run` alive as the hidden hc terminal bercail-notify.

NOTIFY_SCHEMA="bercail.agent_status/v2"

notify_hc() {
  printf '%s' "${HC_BIN:-hc}"
}

notify_handoffs_file() {
  printf '%s/bercail/handoffs.jsonl' "${XDG_STATE_HOME:-$HOME/.local/state}"
}

_notify_err() {
  printf 'bercail notify: %s\n' "$*" >&2
}

_notify_now() {
  date +%s
}

# previous status -> current status => finished | blocked | none.
# hc reports `done` for an agent that finished unseen and `idle` once seen, so
# done -> idle (Simon looked at it) is not a second finish.
notify_classify() {
  local prev="$1" cur="$2"
  [[ "$prev" == "$cur" ]] && { printf 'none'; return 0; }
  case "$cur" in
    blocked) printf 'blocked' ;;
    done|idle)
      case "$prev" in
        working|blocked) printf 'finished' ;;
        *) printf 'none' ;;
      esac
      ;;
    *) printf 'none' ;;
  esac
}

# The desk's space: its id, its name, and its folder. The name is the Herdr
# app's, else (no window here) the one bercail gave a space it made through hc.
notify_space_info() {
  local id="$1" path="$2" name="" repo="" main linked=false shell
  if [[ -n "$id" ]]; then
    name="$("${HERDR_APP_BIN:-herdr-app}" ls 2>/dev/null </dev/null \
      | jq -r --arg id "$id" '.spaces[]? | select(.id == $id) | .name' 2>/dev/null | head -n 1)"
  fi
  if [[ -n "$id" && -z "$name" ]]; then
    shell="$("$(notify_hc)" ls --json --label "herdr.space=$id" 2>/dev/null </dev/null \
      | jq -r '.terminals[0].address // empty' 2>/dev/null)"
    [[ -z "$shell" ]] || name="$("$(notify_hc)" get "$shell" --json 2>/dev/null </dev/null \
      | jq -r '.labels["bercail.space_name"] // empty' 2>/dev/null)"
  fi
  if [[ -n "$path" && -d "$path" ]]; then
    main="$(git -C "$path" worktree list --porcelain 2>/dev/null | awk '/^worktree / { print substr($0, 10); exit }')"
    [[ -n "$main" ]] && repo="$(basename "$main")"
    [[ -n "$main" && "$main" != "$path" ]] && linked=true
  fi
  jq -nc --arg id "$id" --arg name "$name" --arg repo "$repo" --arg path "$path" --argjson linked "$linked" '
    def n: if . == "" then null else . end;
    {id:($id|n), name:($name|n), repo:($repo|n), checkout_path:($path|n), linked:$linked}'
}

# Branch, beads issue, stage, harness, and headless result for a checkout.
# The terminal's bercail.issue labels name its job: a handoff record or result
# for another issue in the same folder (a background Shep in a main checkout)
# is not this desk's.
notify_desk_info() {
  local path="$1" agent="$2" issue="${3:-}" issue_title="${4:-}" branch="" handoff='{}' result='null' file
  if [[ -n "$path" && -d "$path" ]]; then
    branch="$(git -C "$path" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
    file="$(notify_handoffs_file)"
    if [[ -r "$file" ]]; then
      handoff="$(jq -c --arg p "$path" 'select(.path == $p)' "$file" 2>/dev/null | tail -n 1)"
      [[ -n "$handoff" ]] || handoff='{}'
    fi
    if [[ -r "$path/.bercail/handoff-result.json" ]]; then
      result="$(jq -c '{status, summary:((.summary // "") | .[0:500]), session_id, issue}
        + (if .provider_error then {provider_error, reason, completion, prior_result} else {} end)' \
        "$path/.bercail/handoff-result.json" 2>/dev/null || printf 'null')"
    fi
  fi
  jq -nc --arg branch "$branch" --arg agent "$agent" --arg li "$issue" --arg lt "$issue_title" \
    --argjson h "$handoff" --argjson r "$result" '
    def mine: $li == "" or (.issue // "") == $li;
    (if $h | mine then $h else {} end) as $h
    | (if $r != null and ($r | mine) then $r | del(.issue) else null end) as $r
    | {branch:(if $branch == "" then ($h.branch // null) else $branch end),
     issue:(if $li == "" then ($h.issue // null) else $li end),
     issue_title:(if $lt == "" then ($h.issue_title // null) else $lt end), stage:($h.stage // null),
     harness:($h.harness // (if $agent == "" then null else $agent end)),
     result:$r}'
}

# The event Shep reads. `sink` is always "shep", kept so the schema is unchanged.
notify_payload() {
  local kind="$1" agent_json="$2" space_json="$3" desk_json="$4" event_id="$5"
  jq -nc --arg schema "$NOTIFY_SCHEMA" --arg kind "$kind" \
    --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg event_id "$event_id" \
    --argjson agent "$agent_json" --argjson space "$space_json" --argjson desk "$desk_json" '
    def titled: if type == "string" and endswith(".") then .[:-1] else . end;
    def where:
      (if $agent.role == "shep-bg" then "Background Shep " else "Desk " end) + ($agent.address // "")
      + (if ($space.name // "") == "" then "" else " (" + $space.name + ")" end);
    def line:
      (($desk.issue_title // "") | titled) as $title
      | (if ($desk.issue // "") == "" then ""
         elif $title == "" then $desk.issue + ". "
         else $desk.issue + ": " + $title + (if $title | endswith("…") then " " else ". " end) end)
        + where
        + (if $kind == "blocked" then " is blocked." else " finished." end);
    {source:"bercail", schema:$schema, kind:$kind, sink:"shep", at:$at,
     event_id:$event_id, agent:$agent, space:$space, desk:$desk, text:line}'
}

# The prompt a blocked desk shows now, as <session>.<screen hash>: the Pi session
# its desk record names for this pid, else the pid. Nothing when hc gives no
# screen or pid to tell prompts apart; fails when hc no longer says blocked.
# The prompt names the event, so a prompt that comes back is one file.
notify_blocked_prompt() {
  local address="$1" screen pid session
  screen="$("$(notify_hc)" read "$address" --json 2>/dev/null </dev/null | jq -r '.text // empty' 2>/dev/null)"
  pid="$("$(notify_hc)" get "$address" --json 2>/dev/null </dev/null \
    | jq -r 'select(.status.state == "blocked") | .foreground.pid // .pid // "none"' 2>/dev/null)"
  [[ -n "$pid" ]] || return 1
  [[ -n "$screen" && "$pid" =~ ^[0-9]+$ ]] || return 0
  session="$(jq -r --argjson pid "$pid" 'select(.pid == $pid) | .session // empty' \
    "${XDG_STATE_HOME:-$HOME/.local/state}/bercail/desk-sessions/$address.json" 2>/dev/null)" || session=""
  printf '%s.%s' "${session:-$pid}" "$(printf '%s' "$screen" | sha256sum | cut -c1-16)"
}

# One desk changed status: classify it and queue it for Shep. ISSUE,
# ISSUE_TITLE and SHEP are its bercail.issue, bercail.issue_title and
# bercail.shep labels. PROMPT names a block (notify_blocked_prompt), or is
# `stale` when hc no longer shows it: then only a provider error's episode goes.
notify_desk_changed() {
  local address="$1" prev="$2" status="$3" app="$4" space="$5" cwd="$6" title="$7"
  local issue="${8:-}" issue_title="${9:-}" shep="${10:-}" seq="${11:-}" prompt="${12:-}"
  local kind agent_json space_json desk_json
  kind="$(notify_classify "$prev" "$status")"
  [[ "$kind" != "none" ]] || return 0
  agent_json="$(jq -nc --arg address "$address" --arg app "$app" --arg status "$status" \
    --arg prev "$prev" --arg title "$title" --arg shep "$shep" '
    def n: if . == "" then null else . end;
    {address:$address, app:($app|n), status:$status, previous_status:($prev|n), title:($title|n),
     role:(if $shep == "bg" then "shep-bg" else "desk" end)}')"
  space_json="$(notify_space_info "$space" "$cwd")"
  desk_json="$(notify_desk_info "$cwd" "$app" "$issue" "$issue_title")"
  # Keep distinct stream events apart even when queued in the same second.
  local event_id
  event_id="$address:$kind:$(_notify_now)${seq:+.$seq}:$$"
  local episode
  if jq -e '.result.provider_error.completion == "incomplete"' <<<"$desk_json" >/dev/null; then
    kind=blocked
    episode="$(jq -r '.result.provider_error.episode_id // empty' <<<"$desk_json")"
    [[ -z "$episode" ]] || event_id="provider-error:$episode:blocked"
  elif [[ "$prompt" == stale ]]; then
    return 0
  elif [[ "$kind" == blocked && -n "$prompt" ]]; then
    event_id="$address:blocked:$prompt:$$"
  fi
  notify_shep_enqueue "$kind" "$agent_json" "$space_json" "$desk_json" "$event_id"
}

# Where Shep on Pi reads desk events (lib/shep.sh), or nothing.
notify_shep_inbox() {
  shep_inbox_dir
}

# Shep on Pi gets desk events as files: its extension hands them to
# the running session, and they wait there while Shep is not running. The name
# leaves out the follower's pid, so two followers that see the same change in
# the same second write one file. Written whole (tmp, then mv), never read half done.
notify_shep_enqueue() {
  local kind="$1" agent_json="$2" space_json="$3" desk_json="$4" event_id="$5" inbox name tmp
  inbox="$(notify_shep_inbox)"
  [[ -n "$inbox" ]] || return 0
  name="$(printf '%s' "${event_id%:*}" | tr -c 'A-Za-z0-9._-' '_').json"
  [[ -e "$inbox/$name" || -e "$inbox/../delivered/$name" ]] && return 0
  mkdir -p "$inbox"
  tmp="$(umask 077 && mktemp "$inbox/.event.XXXXXX")" || return 0
  if notify_payload "$kind" "$agent_json" "$space_json" "$desk_json" "$event_id" >"$tmp"; then
    mv -f "$tmp" "$inbox/$name"
  else
    rm -f "$tmp"
    _notify_err "could not queue the desk event for Shep in $inbox"
  fi
}

# Current source observations are not events: no historical id or desk-authored
# prose. These helpers read notify_follow's maps and keep one bounded projection.
# TURN is hc's turn in the one lookup STATUS came from, when it did.
_notify_follow_source() {
  local address="$1" status="$2" turn="${3:-0}" space desk
  [[ -n "$(notify_shep_inbox)" ]] || return 0
  # Pi starts idle: a desk that has not worked yet has no finish to reconstruct.
  if [[ "$status" == idle && -z "${workedof[$address]+x}" && "$turn" == 0 ]]; then
    unset "sourceof[$address]"
    return 0
  fi
  space="$(notify_space_info "${spaceof[$address]:-}" "${cwdof[$address]:-}")"
  desk="$(notify_desk_info "${cwdof[$address]:-}" "${appof[$address]:-}" "${issueof[$address]:-}")"
  sourceof[$address]="$(jq -nc --arg at "$observed_at" --arg a "$address" --arg s "$status" \
    --arg app "${appof[$address]:-}" --arg shep "${shepof[$address]:-}" \
    --argjson space "$space" --argjson desk "$desk" '
    {observed_at:$at, agent:{address:$a, app:(if $app == "" then null else $app end),
      status:$s, role:(if $shep == "bg" then "shep-bg" else "desk" end)},
     space:$space, desk:($desk | {branch,issue,stage,harness})}')"
}

_notify_follow_source_write() {
  local inbox tmp
  inbox="$(notify_shep_inbox)"
  [[ -n "$inbox" ]] || return 0
  tmp="$(umask 077 && mktemp "$inbox/../.source-state.XXXXXX")" || return 0
  if printf '%s\n' "${sourceof[@]}" | jq -sc --arg at "$observed_at" '
    {source:"bercail",schema:"bercail.source_state/v1",kind:"reconciliation",
     observed_at:$at,history_gap:true,possibly_stale:true,desks:(sort_by(.agent.address))}' >"$tmp" \
    && mv -f "$tmp" "$inbox/../source-state.json"; then
    return 0
  fi
  rm -f "$tmp"
  _notify_err "could not write the source observation for Shep in $inbox/.."
}

# One `hc events` line as records joined by \x1f (\x1f, not tab: read merges
# runs of whitespace separators, so an empty field would shift the ones after it):
#   S                                        a snapshot starts (top level, or under
#                                            params for `missed` and other notifications)
#   T address status app space cwd title issue issue_title shep turn
#                                            a live desk in that snapshot, with its
#                                            bercail.issue, .issue_title and .shep labels
#                                            and hc's turn count
#   E type address status app title seq      an `event` notification: one fact changed
# Heartbeats and anything else give nothing.
_NOTIFY_FOLLOW_JQ='
  def f: tostring | gsub("[\t\n\u001f]"; " ");
  def row: map(f) | join("\u001f");
  def optional_string: . == null or type == "string";
  def valid_status: . == null or (type == "object" and (.state | optional_string) and (.app | optional_string));
  def valid_terminal:
    type == "object" and (.address | type == "string" and length > 0)
    and (.state | type == "string") and ((.labels // {}) | type == "object")
    and ((.labels // {}) | all(.[]; optional_string)) and (.cwd | optional_string)
    and (.status | valid_status);
  def snap: if all(.terminals[]; valid_terminal) then "S", (.terminals[]
    | select(.labels["bercail.role"] == "agent" and .state == "live")
    | ["T", .address, (.status.state // ""), (.status.app // .foreground.name // ""),
       (.labels["bercail.space"] // ""), (.cwd // ""), (.title // ""),
       (.labels["bercail.issue"] // ""), (.labels["bercail.issue_title"] // ""),
       (.labels["bercail.shep"] // ""), (.turn // 0)] | row) else empty end;
  if (.terminals | type) == "array" then snap
  elif (.params.terminals? | type) == "array" then .params | snap
  elif .method? == "event" and (.params.terminal? | type) == "string" then
    .params as $p | ($p.data | if type == "object" then . else {} end) as $d
    | ($d.status | if type == "object" then . else {} end) as $s
    | if $p.type == "status" and (($d.status | valid_status) | not) then empty
      else ["E", ($p.type // ""), $p.terminal, ($s.state // ""), ($s.app // ""),
       ($d.title // (if $p.type == "title" and ($p.data | type) == "string" then $p.data else "" end)),
       ($p.seq | numbers // "")] | row end
  else empty end'

# A desk went from $2 to $3: queue a finish or block for Shep, with the prompt
# _notify_follow_takes found.
# Called by notify_follow; reads its per-desk maps (bash scoping is dynamic).
_notify_follow_changed() {
  local address="$1" before="$2" now="$3" seq="${4:-}"
  notify_desk_changed "$address" "$before" "$now" "${appof[$address]:-}" "${spaceof[$address]:-}" \
    "${cwdof[$address]:-}" "${titleof[$address]:-}" "${issueof[$address]:-}" \
    "${issuetitleof[$address]:-}" "${shepof[$address]:-}" "$seq" "$prompt" || true
}

# Whether the follower takes STATUS for a desk: a new block only while hc still
# shows it, read once here and kept in `prompt` for its event. Else the desk
# keeps its status, whether it has worked, and its source row: a stale block
# there would come back to Shep as a reconstructed notice.
_notify_follow_takes() {
  local address="$1" status="$2"
  prompt=""
  [[ "$status" != blocked || "${prev[$address]-}" == blocked ]] && return 0
  prompt="$(notify_blocked_prompt "$address")" && return 0
  prompt=stale
  return 1
}

# hc just said a desk is not blocked: a row of a desk met by a lookup alone that
# says blocked is gone. A row from the stream is kept as it was.
_notify_follow_unblock() {
  local address="$1"
  [[ -z "${prev[$address]+x}" ]] || return 0
  jq -e '.agent.status == "blocked"' <<<"${sourceof[$address]:-null}" >/dev/null 2>&1 || return 0
  unset "sourceof[$address]"
}

# Read `hc events` lines on stdin; queue each desk's status changes for Shep.
# hc sends one snapshot, then an `event` per changed fact (status, title,
# finished, ...), heartbeats, and a fresh snapshot after `missed`. Reading
# only snapshots saw no change after the first line. Statuses live in memory:
# a desk seen for the first time has no previous status, so no historical
# transition is invented. Shep also gets a separate current-source projection.
notify_follow() {
  local line kind a b c d e g h i j k turn prompt snapped address info changed observed_at last_status_seq=0
  local -A prev=() spaceof=() cwdof=() titleof=() appof=() issueof=() issuetitleof=() shepof=() seen=() sourceof=() workedof=()
  while IFS= read -r line; do
    snapped=0
    changed=0
    observed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    seen=()
    while IFS=$'\x1f' read -r kind a b c d e g h i j turn; do
      case "$kind" in
        S) snapped=1 ;;
        T) # address status app space cwd title issue issue_title shep turn
          [[ -n "$a" ]] || continue
          seen[$a]=1
          appof[$a]="$c"; spaceof[$a]="$d"; cwdof[$a]="$e"; titleof[$a]="$g"
          issueof[$a]="$h"; issuetitleof[$a]="$i"; shepof[$a]="$j"
          if ! _notify_follow_takes "$a" "$b"; then
            [[ -z "${prev[$a]+x}" ]] || _notify_follow_changed "$a" "${prev[$a]}" "$b"
            _notify_follow_unblock "$a"
            continue
          fi
          [[ "$b" != working && "${turn:-0}" == 0 ]] || workedof[$a]=1
          if [[ -n "${prev[$a]+x}" && "${prev[$a]}" != "$b" ]]; then
            _notify_follow_changed "$a" "${prev[$a]}" "$b"
          fi
          prev[$a]="$b"
          _notify_follow_source "$a" "$b"
          ;;
        E) # type address status app title seq
          address="$b"
          [[ -n "$address" ]] || continue
          # Sequence numbers belong to this ordered stream, not to a later hc
          # get. Ignore replayed statuses before they can change prev or deliver.
          if [[ "$a" == status && "$g" =~ ^[1-9][0-9]{0,15}$ ]]; then
            (( g > last_status_seq )) || continue
            last_status_seq="$g"
          else
            g=""
          fi
          case "$a" in
            finished|removed|lost)
              # Forget it, so a reused address starts fresh.
              unset "prev[$address]" "spaceof[$address]" "cwdof[$address]" "titleof[$address]" "appof[$address]" \
                "issueof[$address]" "issuetitleof[$address]" "shepof[$address]" "sourceof[$address]" "workedof[$address]"
              changed=1
              continue
              ;;
            restarted) unset "prev[$address]" "workedof[$address]" ;;
          esac
          # A desk this follower hasn't met (started after the snapshot), or
          # whose labels changed: ask hc where it is.
          if [[ -z "${spaceof[$address]+x}" || "$a" == labels || "$a" == restarted ]]; then
            info="$("$(notify_hc)" get "$address" --json 2>/dev/null </dev/null | jq -r '
              select(.labels["bercail.role"] == "agent" and .state == "live")
              | [(.labels["bercail.space"] // ""), (.cwd // ""), (.title // ""),
                 (.status.app // .foreground.name // ""), (.labels["bercail.issue"] // ""),
                 (.labels["bercail.issue_title"] // ""), (.labels["bercail.shep"] // ""), (.status.state // ""), (.turn // 0)]
              | map(tostring | gsub("[\t\n\u001f]"; " ")) | join("\u001f")' 2>/dev/null)" || info=""
            if [[ -z "$info" ]]; then
              unset "prev[$address]" "spaceof[$address]" "cwdof[$address]" "titleof[$address]" "appof[$address]" \
                "issueof[$address]" "issuetitleof[$address]" "shepof[$address]" "sourceof[$address]" "workedof[$address]"
              changed=1
              continue
            fi
            IFS=$'\x1f' read -r "spaceof[$address]" "cwdof[$address]" "titleof[$address]" "appof[$address]" \
              "issueof[$address]" "issuetitleof[$address]" "shepof[$address]" k turn <<<"$info"
            # hc get can be ahead of the stream: a desk this follower knows keeps
            # its status until the status event comes, so the source never says
            # done before the finish is queued (Shep would read a gap notice too).
            # A status event's own status is projected below, once it is taken. A
            # desk not met yet is projected from this lookup alone, its turn too.
            if [[ "$a" != status && -n "${prev[$address]+x}" ]]; then
              _notify_follow_source "$address" "${prev[$address]}"
            elif [[ "$a" != status ]]; then
              _notify_follow_source "$address" "$k" "${turn:-0}"
            fi
            changed=1
          fi
          [[ -n "$e" ]] && titleof[$address]="$e"
          [[ "$a" == status ]] || continue
          [[ -n "$d" ]] && appof[$address]="$d"
          if ! _notify_follow_takes "$address" "$c"; then
            [[ -z "${prev[$address]+x}" ]] || _notify_follow_changed "$address" "${prev[$address]}" "$c" "$g"
            _notify_follow_unblock "$address"
            changed=1
            continue
          fi
          [[ "$c" != working ]] || workedof[$address]=1
          if [[ -n "${prev[$address]+x}" && "${prev[$address]}" != "$c" ]]; then
            _notify_follow_changed "$address" "${prev[$address]}" "$c" "$g"
          fi
          prev[$address]="$c"
          _notify_follow_source "$address" "$c"
          changed=1
          ;;
      esac
    done < <(jq -r "$_NOTIFY_FOLLOW_JQ" <<<"$line" 2>/dev/null)
    # A snapshot is whole: forget desks it no longer has.
    if [[ "$snapped" -eq 1 ]]; then
      for address in "${!spaceof[@]}"; do
        [[ -n "${seen[$address]+x}" ]] || \
          unset "prev[$address]" "spaceof[$address]" "cwdof[$address]" "titleof[$address]" "appof[$address]" \
            "issueof[$address]" "issuetitleof[$address]" "shepof[$address]" "sourceof[$address]" "workedof[$address]"
      done
    fi
    if [[ "$snapped" -eq 1 || "$changed" -eq 1 ]]; then
      _notify_follow_source_write
    fi
  done
}

# Follow desks once Shep has made its inbox. Before that, wait.
notify_run() {
  while [[ -z "$(notify_shep_inbox)" ]]; do
    sleep "${NOTIFY_IDLE_SLEEP:-60}"
  done
  "$(notify_hc)" events --json --label bercail.role=agent | notify_follow
}

_notify_follower_live() {
  "$(notify_hc)" get bercail-notify --json 2>/dev/null </dev/null | jq -e '.state == "live"' >/dev/null 2>&1
}

# A live follower keeps running the bercail it started with. After an update,
# end it; the desk mod starts the new one within a minute. The follower is
# --rm, so `hc kill` exits not_found once it's gone: check, don't trust the code.
notify_restart_follower() {
  _notify_follower_live || return 0
  "$(notify_hc)" kill bercail-notify >/dev/null 2>&1 </dev/null || true
  if _notify_follower_live; then
    printf 'could not restart the notify follower; run: hc kill bercail-notify\n' >&2
  else
    printf 'restarted the notify follower (hc terminal bercail-notify)\n'
  fi
  return 0
}

# `run` is the only command: the webhook sinks and their commands were removed in v0.18.
cmd_notify() {
  case "${1:-}" in
    run) notify_run ;;
    *) _notify_err "unknown command '${1:-}': only run is left, the follower the desk mod starts (the webhook sinks were removed)"; return 1 ;;
  esac
}
