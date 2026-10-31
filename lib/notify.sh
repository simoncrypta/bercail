#!/usr/bin/env bash
# shellcheck shell=bash
# Agent status webhooks: follow the desk agents (hc terminals labelled
# bercail.role=agent) with `hc events` and post their status changes to named
# sinks. Each sink is ~/.config/bercail/notify.d/<name>.toml with its own URL,
# key, and filters.
#
#   bercail notify run         follow desks until hc's event stream ends
#   bercail notify status      sinks, filters, and last delivery (no secrets)
#   bercail notify test NAME   send one kind=test payload to sink NAME
#   bercail notify add NAME    write sink NAME from a pasted url and key, then test it
#
# The desk mod keeps one `run` alive as the hidden hc terminal bercail-notify.

NOTIFY_SCHEMA="bercail.agent_status/v2"

notify_hc() {
  printf '%s' "${HC_BIN:-hc}"
}

notify_sinks_dir() {
  printf '%s' "${BERCAIL_NOTIFY_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/bercail/notify.d}"
}

notify_state_dir() {
  local dir="${XDG_STATE_HOME:-$HOME/.local/state}/bercail/notify"
  mkdir -p "$dir/sinks"
  printf '%s' "$dir"
}

notify_handoffs_file() {
  printf '%s/agentic-dev/handoffs.jsonl' "${XDG_STATE_HOME:-$HOME/.local/state}"
}

_notify_err() {
  printf 'bercail notify: %s\n' "$*" >&2
}

_notify_now() {
  date +%s
}

notify_sink_files() {
  local dir f
  dir="$(notify_sinks_dir)"
  [[ -d "$dir" ]] || return 0
  for f in "$dir"/*.toml; do
    [[ -f "$f" ]] && printf '%s\n' "$f"
  done
}

notify_sink_name() {
  local base
  base="$(basename "$1")"
  printf '%s' "${base%.toml}"
}

# Flat `key = value` reader (same subset as config-reader.sh). Quotes optional.
notify_sink_value() {
  local file="$1" key="$2" default="${3:-}" line val
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    [[ "$line" == \#* ]] && continue
    [[ "$line" =~ ^${key}[[:space:]]*= ]] || continue
    val="${line#*=}"
    val="${val#"${val%%[![:space:]]*}"}"
    if [[ "$val" == \"* ]]; then
      val="${val#\"}"
      val="${val%%\"*}"
    else
      val="${val%%#*}"
      val="${val%"${val##*[![:space:]]}"}"
    fi
    printf '%s' "$val"
    return 0
  done <"$file"
  printf '%s' "$default"
}

_notify_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null || printf '600'
}

# A file holding a key must not be group/other readable.
notify_private_ok() {
  local mode
  mode="$(_notify_mode "$1")"
  [[ "${mode: -2}" == "00" ]]
}

notify_sink_key() {
  local file="$1" key key_file
  key="$(notify_sink_value "$file" key "")"
  if [[ -n "$key" ]]; then
    printf '%s' "$key"
    return 0
  fi
  key_file="$(notify_sink_value "$file" key_file "")"
  key_file="${key_file/#\~/$HOME}"
  [[ -n "$key_file" && -r "$key_file" ]] || return 0
  notify_private_ok "$key_file" || return 2
  tr -d '\r\n' <"$key_file"
}

notify_bool() {
  case "$1" in
    0|false|False|FALSE|no|off) return 1 ;;
    *) return 0 ;;
  esac
}

# Comma-separated list contains WORD (case-insensitive, trimmed).
notify_list_has() {
  local list="$1" want="$2" item
  local IFS=','
  for item in $list; do
    item="${item#"${item%%[![:space:]]*}"}"
    item="${item%"${item##*[![:space:]]}"}"
    [[ "${item,,}" == "${want,,}" ]] && return 0
  done
  return 1
}

# Comma-separated glob list matches VALUE (case-insensitive).
notify_glob_match() {
  local list="$1" value="$2" item
  local IFS=','
  for item in $list; do
    item="${item#"${item%%[![:space:]]*}"}"
    item="${item%"${item##*[![:space:]]}"}"
    [[ -n "$item" ]] || continue
    # shellcheck disable=SC2053
    [[ "${value,,}" == ${item,,} ]] && return 0
  done
  return 1
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

# The desk's space: its id, and its name and folder when the Herdr app answers.
notify_space_info() {
  local id="$1" path="$2" name="" repo="" main linked=false
  if [[ -n "$id" ]]; then
    name="$("${HERDR_APP_BIN:-herdr-app}" ls 2>/dev/null </dev/null \
      | jq -r --arg id "$id" '.spaces[]? | select(.id == $id) | .name' 2>/dev/null | head -n 1)"
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
notify_desk_info() {
  local path="$1" agent="$2" branch="" handoff='{}' result='null' file
  if [[ -n "$path" && -d "$path" ]]; then
    branch="$(git -C "$path" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
    file="$(notify_handoffs_file)"
    if [[ -r "$file" ]]; then
      handoff="$(jq -c --arg p "$path" 'select(.path == $p)' "$file" 2>/dev/null | tail -n 1)"
      [[ -n "$handoff" ]] || handoff='{}'
    fi
    if [[ -r "$path/.bercail/handoff-result.json" ]]; then
      result="$(jq -c '{status, summary:((.summary // "") | .[0:500]), session_id}' \
        "$path/.bercail/handoff-result.json" 2>/dev/null || printf 'null')"
    fi
  fi
  jq -nc --arg branch "$branch" --arg agent "$agent" --argjson h "$handoff" --argjson r "$result" '
    {branch:(if $branch == "" then ($h.branch // null) else $branch end),
     issue:($h.issue // null), stage:($h.stage // null),
     harness:($h.harness // (if $agent == "" then null else $agent end)),
     result:$r}'
}

# Does SINK want this KIND for this space? Empty filters match all.
# `spaces` are space name globs (`workspaces` is the old name for it).
notify_sink_wants() {
  local file="$1" kind="$2" space_json="$3" kinds spaces repos name repo
  notify_bool "$(notify_sink_value "$file" enabled true)" || return 1
  [[ "$kind" == "test" ]] && return 0
  kinds="$(notify_sink_value "$file" notify "finished, blocked")"
  notify_list_has "$kinds" "$kind" || return 1
  spaces="$(notify_sink_value "$file" spaces "")"
  [[ -n "$spaces" ]] || spaces="$(notify_sink_value "$file" workspaces "")"
  repos="$(notify_sink_value "$file" repos "")"
  [[ -z "$spaces" && -z "$repos" ]] && return 0
  name="$(jq -r '.name // empty' <<<"$space_json")"
  repo="$(jq -r '.repo // empty' <<<"$space_json")"
  [[ -n "$spaces" && -n "$name" ]] && notify_glob_match "$spaces" "$name" && return 0
  [[ -n "$repos" && -n "$repo" ]] && notify_glob_match "$repos" "$repo" && return 0
  return 1
}

_notify_sink_state_file() {
  printf '%s/sinks/%s.json' "$(notify_state_dir)" "$1"
}

# Record a delivery. A 401/403 is logged every time and kept as auth_failed,
# which `bercail notify status` and `bercail doctor` show.
notify_record() {
  local name="$1" code="$2" f prev='{}' auth="false" ok="false" now tmp
  f="$(_notify_sink_state_file "$name")"
  # A corrupt or empty state file must not stop recording.
  [[ -r "$f" ]] && prev="$(jq -c 'objects' "$f" 2>/dev/null | head -n 1)"
  [[ -n "$prev" ]] || prev='{}'
  now="$(_notify_now)"
  case "$code" in
    2??) ok="true" ;;
    401|403) auth="true" ;;
  esac
  tmp="$f.$$"
  jq -nc --arg name "$name" --arg code "$code" --argjson now "$now" \
    --argjson ok "$ok" --argjson auth "$auth" \
    --argjson prev "$prev" '
    $prev + {sink:$name, last_code:$code, last_at:$now, auth_failed:$auth}
    + (if $ok then {last_ok_at:$now, failures:0}
       else {last_error_at:$now, failures:(($prev.failures // 0) + 1)} end)' >"$tmp" \
    && mv -f "$tmp" "$f" || rm -f "$tmp"
  if [[ "$auth" == "true" ]]; then
    _notify_err "sink '$name' rejected its key (HTTP $code); fix the key in $(notify_sinks_dir)/$name.toml"
  elif [[ "$ok" != "true" ]]; then
    _notify_err "sink '$name' delivery failed (HTTP $code)"
  fi
}

# POST BODY to the sink. The key goes through a 0600 header file, never argv.
notify_post() {
  local file="$1" body="$2" url key style timeout hdr code rc=0 attempt
  url="$(notify_sink_value "$file" url "")"
  [[ -n "$url" ]] || { printf 'nourl'; return 0; }
  if [[ -n "$(notify_sink_value "$file" key "")" ]] && ! notify_private_ok "$file"; then
    printf 'insecure'
    return 0
  fi
  key="$(notify_sink_key "$file")" || rc=$?
  [[ "$rc" -eq 0 ]] || { printf 'insecure'; return 0; }
  style="$(notify_sink_value "$file" auth both)"
  timeout="$(notify_sink_value "$file" timeout 8)"
  hdr="$(umask 077 && mktemp)"
  {
    printf 'content-type: application/json\n'
    if [[ -n "$key" ]]; then
      case "$style" in
        bearer) printf 'Authorization: Bearer %s\n' "$key" ;;
        x-automation-key) printf 'X-Automation-Key: %s\n' "$key" ;;
        none) ;;
        *) printf 'Authorization: Bearer %s\nX-Automation-Key: %s\n' "$key" "$key" ;;
      esac
    fi
  } >"$hdr"
  for attempt in 1 2; do
    code="$(printf '%s' "$body" | "${NOTIFY_CURL:-curl}" -sS -m "$timeout" -o /dev/null \
      -w '%{http_code}' -X POST -H "@$hdr" --data-binary @- "$url" 2>/dev/null || true)"
    [[ -n "$code" ]] || code="000"
    case "$code" in
      000|5??) [[ "$attempt" -eq 1 ]] && sleep "${NOTIFY_RETRY_SLEEP:-1}" && continue ;;
    esac
    break
  done
  rm -f "$hdr"
  printf '%s' "$code"
}

notify_payload() {
  local kind="$1" sink="$2" agent_json="$3" space_json="$4" desk_json="$5" event_id="$6"
  jq -nc --arg schema "$NOTIFY_SCHEMA" --arg kind "$kind" --arg sink "$sink" \
    --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg event_id "$event_id" \
    --argjson agent "$agent_json" --argjson space "$space_json" --argjson desk "$desk_json" '
    {source:"bercail", schema:$schema, kind:$kind, sink:$sink, at:$at,
     event_id:$event_id, agent:$agent, space:$space, desk:$desk}'
}

notify_deliver_all() {
  local kind="$1" agent_json="$2" space_json="$3" desk_json="$4" event_id="$5" f name body code
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    name="$(notify_sink_name "$f")"
    notify_sink_wants "$f" "$kind" "$space_json" || continue
    body="$(notify_payload "$kind" "$name" "$agent_json" "$space_json" "$desk_json" "$event_id")"
    code="$(notify_post "$f" "$body")"
    case "$code" in
      nourl) _notify_err "sink '$name' has no url; skipped" ;;
      insecure) _notify_err "sink '$name' key file is readable by others; chmod 600 it. Skipped." ;;
      *) notify_record "$name" "$code" ;;
    esac
  done < <(notify_sink_files)
}

# One desk changed status: classify it and deliver.
notify_desk_changed() {
  local address="$1" prev="$2" status="$3" app="$4" space="$5" cwd="$6" title="$7"
  local kind agent_json space_json desk_json
  kind="$(notify_classify "$prev" "$status")"
  [[ "$kind" != "none" ]] || return 0
  agent_json="$(jq -nc --arg address "$address" --arg app "$app" --arg status "$status" \
    --arg prev "$prev" --arg title "$title" '
    def n: if . == "" then null else . end;
    {address:$address, app:($app|n), status:$status, previous_status:($prev|n), title:($title|n)}')"
  space_json="$(notify_space_info "$space" "$cwd")"
  desk_json="$(notify_desk_info "$cwd" "$app")"
  # Same id for every sink and retry, so receivers can dedupe.
  notify_deliver_all "$kind" "$agent_json" "$space_json" "$desk_json" "$address:$kind:$(_notify_now):$$"
}

# The follower's own record, for `bercail doctor`: when it started and the
# last desk finish or block it saw (posted or filtered out).
notify_follower_file() {
  printf '%s/follower.json' "$(notify_state_dir)"
}

notify_restart_file() {
  printf '%s/restarted_at' "$(notify_state_dir)"
}

_notify_follower_write() {
  local f tmp
  f="$(notify_follower_file)"
  tmp="$f.$$"
  jq -nc "$@" >"$tmp" && mv -f "$tmp" "$f" || rm -f "$tmp"
}

# One `hc events` line as records joined by \x1f (\x1f, not tab: read merges
# runs of whitespace separators, so an empty field would shift the ones after it):
#   S                                        a snapshot starts (top level, or under
#                                            params for `missed` and other notifications)
#   T address status app space cwd title     a live desk in that snapshot
#   E type address status app title          an `event` notification: one fact changed
# Heartbeats and anything else give nothing.
_NOTIFY_FOLLOW_JQ='
  def f: tostring | gsub("[\t\n\u001f]"; " ");
  def row: map(f) | join("\u001f");
  def snap: "S", (.terminals[]
    | select(.labels["bercail.role"] == "agent" and .state == "live")
    | ["T", .address, (.status.state // ""), (.status.app // .foreground.name // ""),
       (.labels["bercail.space"] // ""), (.cwd // ""), (.title // "")] | row);
  if (.terminals | type) == "array" then snap
  elif (.params.terminals? | type) == "array" then .params | snap
  elif .method? == "event" and (.params.terminal? | type) == "string" then
    .params as $p | ($p.data | if type == "object" then . else {} end) as $d
    | ($d.status | if type == "object" then . else {} end) as $s
    | ["E", ($p.type // ""), $p.terminal, ($s.state // ""), ($s.app // ""),
       ($d.title // (if $p.type == "title" and ($p.data | type) == "string" then $p.data else "" end))] | row
  else empty end'

# A desk went from $2 to $3: record a finish or block for doctor, and deliver it.
# Called by notify_follow; reads its per-desk maps (bash scoping is dynamic).
_notify_follow_changed() {
  local address="$1" before="$2" now="$3" kind f
  kind="$(notify_classify "$before" "$now")"
  [[ "$kind" != "none" ]] || return 0
  f="$(notify_follower_file)"
  [[ -r "$f" ]] || printf '{}' >"$f"
  _notify_follower_write --argjson at "$(_notify_now)" --arg a "$address" --arg k "$kind" \
    --slurpfile old "$f" '($old[0] // {}) + {last_transition_at:$at, last_transition:{address:$a, kind:$k}}'
  notify_desk_changed "$address" "$before" "$now" "${appof[$address]:-}" "${spaceof[$address]:-}" \
    "${cwdof[$address]:-}" "${titleof[$address]:-}" || true
}

# Read `hc events` lines on stdin; deliver each desk's status changes.
# hc sends one snapshot, then an `event` per changed fact (status, title,
# finished, ...), heartbeats, and a fresh snapshot after `missed`. Reading
# only snapshots saw no change after the first line. Statuses live in memory:
# a desk seen for the first time has no previous status, so a turn already
# running when this starts is not reported.
notify_follow() {
  local line kind a b c d e g snapped address info
  local -A prev=() spaceof=() cwdof=() titleof=() appof=() seen=()
  _notify_follower_write --argjson at "$(_notify_now)" --argjson pid "$$" '{pid:$pid, started_at:$at}'
  while IFS= read -r line; do
    snapped=0
    seen=()
    while IFS=$'\x1f' read -r kind a b c d e g; do
      case "$kind" in
        S) snapped=1 ;;
        T) # address status app space cwd title
          [[ -n "$a" ]] || continue
          seen[$a]=1
          appof[$a]="$c"; spaceof[$a]="$d"; cwdof[$a]="$e"; titleof[$a]="$g"
          if [[ -n "${prev[$a]+x}" && "${prev[$a]}" != "$b" ]]; then
            _notify_follow_changed "$a" "${prev[$a]}" "$b"
          fi
          prev[$a]="$b"
          ;;
        E) # type address status app title
          address="$b"
          [[ -n "$address" ]] || continue
          case "$a" in
            finished|removed|lost)
              # Forget it, so a reused address starts fresh.
              unset "prev[$address]" "spaceof[$address]" "cwdof[$address]" "titleof[$address]" "appof[$address]"
              continue
              ;;
            restarted) unset "prev[$address]" ;;
          esac
          # A desk this follower hasn't met (started after the snapshot), or
          # whose labels changed: ask hc where it is.
          if [[ -z "${spaceof[$address]+x}" || "$a" == labels || "$a" == restarted ]]; then
            info="$("$(notify_hc)" get "$address" --json 2>/dev/null </dev/null | jq -r '
              select(.labels["bercail.role"] == "agent" and .state == "live")
              | [(.labels["bercail.space"] // ""), (.cwd // ""), (.title // ""),
                 (.status.app // .foreground.name // "")]
              | map(tostring | gsub("[\t\n\u001f]"; " ")) | join("\u001f")' 2>/dev/null)" || info=""
            if [[ -z "$info" ]]; then
              unset "prev[$address]" "spaceof[$address]"
              continue
            fi
            IFS=$'\x1f' read -r "spaceof[$address]" "cwdof[$address]" "titleof[$address]" "appof[$address]" <<<"$info"
          fi
          [[ -n "$e" ]] && titleof[$address]="$e"
          [[ "$a" == status ]] || continue
          [[ -n "$d" ]] && appof[$address]="$d"
          if [[ -n "${prev[$address]+x}" && "${prev[$address]}" != "$c" ]]; then
            _notify_follow_changed "$address" "${prev[$address]}" "$c"
          fi
          prev[$address]="$c"
          ;;
      esac
    done < <(jq -r "$_NOTIFY_FOLLOW_JQ" <<<"$line" 2>/dev/null)
    # A snapshot is whole: forget desks it no longer has.
    if [[ "$snapped" -eq 1 ]]; then
      for address in "${!prev[@]}"; do
        [[ -n "${seen[$address]+x}" ]] || unset "prev[$address]"
      done
    fi
  done
}

# Drop keys older sink files carry that nothing reads any more (`panes`:
# agent_status/v2 has no panes). The reader ignores them either way.
notify_drop_stale_keys() {
  local file="$1" tmp mode
  grep -Eq '^[[:space:]]*panes[[:space:]]*=' "$file" 2>/dev/null || return 0
  mode="$(_notify_mode "$file")"
  tmp="$(umask 077 && mktemp "$(dirname "$file")/.$(basename "$file").XXXXXX")" || return 0
  if grep -Ev '^[[:space:]]*panes[[:space:]]*=' "$file" >"$tmp" && chmod "$mode" "$tmp"; then
    mv -f "$tmp" "$file"
  else
    rm -f "$tmp"
  fi
}

# Follow desks while there are sinks. With none, wait for one to appear.
notify_run() {
  local f
  rm -f "$(notify_restart_file)"
  while [[ -z "$(notify_sink_files)" ]]; do
    sleep "${NOTIFY_IDLE_SLEEP:-60}"
  done
  while IFS= read -r f; do
    notify_drop_stale_keys "$f"
  done < <(notify_sink_files)
  "$(notify_hc)" events --json --label bercail.role=agent | notify_follow
}

_notify_follower_live() {
  "$(notify_hc)" get bercail-notify --json 2>/dev/null </dev/null | jq -e '.state == "live"' >/dev/null 2>&1
}

# A live follower keeps running the bercail it started with. After an update,
# end it; the desk mod starts the new one within a minute. The follower is
# --rm, so `hc kill` exits not_found once it's gone: check, don't trust the code.
# Stamp the restart before killing it; the new run clears the stamp on startup.
notify_restart_follower() {
  local f
  _notify_follower_live || return 0
  f="$(notify_restart_file)"
  _notify_now >"$f"
  "$(notify_hc)" kill bercail-notify >/dev/null 2>&1 </dev/null || true
  if _notify_follower_live; then
    rm -f "$f"
    printf 'could not restart the notify follower; run: hc kill bercail-notify\n' >&2
  else
    printf 'restarted the notify follower (hc terminal bercail-notify)\n'
  fi
  return 0
}

notify_status() {
  local f name st found=0
  printf 'sinks: %s\n' "$(notify_sinks_dir)"
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    found=1
    name="$(notify_sink_name "$f")"
    st="$(_notify_sink_state_file "$name")"
    printf -- '- %s enabled=%s url=%s key=%s notify="%s" spaces="%s" repos="%s"\n' \
      "$name" "$(notify_sink_value "$f" enabled true)" \
      "$([[ -n "$(notify_sink_value "$f" url "")" ]] && printf set || printf MISSING)" \
      "$([[ -n "$(notify_sink_key "$f" 2>/dev/null || true)" ]] && printf set || printf none)" \
      "$(notify_sink_value "$f" notify "finished, blocked")" \
      "$(notify_sink_value "$f" spaces "$(notify_sink_value "$f" workspaces "")")" \
      "$(notify_sink_value "$f" repos "")"
    if [[ -r "$st" ]]; then
      jq -r '"    last=\(.last_code) auth_failed=\(.auth_failed) failures=\(.failures // 0) last_ok_at=\(.last_ok_at // "never")"' "$st"
    else
      printf '    no deliveries yet\n'
    fi
  done < <(notify_sink_files)
  [[ "$found" -eq 1 ]] || printf '(no sinks)\n'
}

notify_test() {
  local name="${1:-}" f code agent space desk
  [[ -n "$name" ]] || { _notify_err "usage: bercail notify test SINK"; return 1; }
  f="$(notify_sinks_dir)/$name.toml"
  [[ -f "$f" ]] || { _notify_err "no sink $f"; return 1; }
  agent='{"address":null,"app":null,"status":"test","previous_status":null,"title":null}'
  space='{"id":null,"name":null,"repo":null,"checkout_path":null,"linked":false}'
  desk='{"branch":null,"issue":null,"stage":null,"harness":null,"result":null}'
  code="$(notify_post "$f" "$(notify_payload test "$name" "$agent" "$space" "$desk" "test:$(_notify_now)")")"
  case "$code" in
    nourl|insecure) _notify_err "sink '$name': $code"; return 1 ;;
  esac
  notify_record "$name" "$code"
  printf '%s HTTP %s\n' "$name" "$code"
  [[ "$code" == 2?? ]]
}

# The URL with its path and query cut off; webhook paths often carry a token.
_notify_redact_url() {
  local url="$1" rest
  [[ -n "$url" ]] || { printf 'none'; return 0; }
  if [[ "$url" == *://* ]]; then
    rest="${url#*://}"
    printf '%s://%s/...' "${url%%://*}" "${rest%%/*}"
  else
    printf 'set'
  fi
}

# Repo name for --repos' default: the main worktree's folder, as the payload's
# space.repo names it. Empty outside a checkout.
_notify_current_repo() {
  local main
  main="$(git worktree list --porcelain 2>/dev/null | awk '/^worktree / { print substr($0, 10); exit }')"
  [[ -n "$main" ]] && basename "$main"
  return 0
}

# Read one value for `notify add`: from stdin, with PROMPT on a terminal.
# HIDDEN=1 reads like `read -s`. Trailing CR and surrounding blanks are cut.
_notify_read_value() {
  local prompt="$1" hidden="$2" val=""
  if [[ -t 0 ]]; then
    if [[ "$hidden" == 1 ]]; then
      IFS= read -r -s -p "$prompt" val || true
      printf '\n' >&2
    else
      IFS= read -r -p "$prompt" val || true
    fi
  else
    IFS= read -r val || true
  fi
  val="${val%$'\r'}"
  val="${val#"${val%%[![:space:]]*}"}"
  val="${val%"${val##*[![:space:]]}"}"
  printf '%s' "$val"
}

_notify_add_usage() {
  cat >&2 <<'EOF'
usage: bercail notify add NAME [--auth both|bearer|x-automation-key|none]
                               [--repos LIST | --all-repos] [--spaces GLOBS]
                               [--notify finished,blocked] [--yes]
Prompts for the webhook URL and the key (hidden). Without a terminal it reads
the URL, then the key, one per line from stdin. BERCAIL_NOTIFY_URL and
BERCAIL_NOTIFY_KEY skip their prompt. The key is never taken as an argument.
EOF
}

# Write sink NAME in one step: url and key from prompts, stdin, or the
# environment; filters from flags. The file is written 0600 by rename, so a
# running follower sees it whole on its next delivery. Ends with `notify test`.
notify_add() {
  local name="" auth="both" repos spaces="" kinds="finished, blocked" yes=0 repos_set=0
  local dir f url key kind tmp code reply
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --auth) auth="${2:-}"; shift 2 || { _notify_add_usage; return 1; } ;;
      --auth=*) auth="${1#*=}"; shift ;;
      --repos) repos="${2:-}"; repos_set=1; shift 2 || { _notify_add_usage; return 1; } ;;
      --repos=*) repos="${1#*=}"; repos_set=1; shift ;;
      --all-repos) repos=""; repos_set=1; shift ;;
      --spaces) spaces="${2:-}"; shift 2 || { _notify_add_usage; return 1; } ;;
      --spaces=*) spaces="${1#*=}"; shift ;;
      --notify) kinds="${2:-}"; shift 2 || { _notify_add_usage; return 1; } ;;
      --notify=*) kinds="${1#*=}"; shift ;;
      -y|--yes) yes=1; shift ;;
      -h|--help) _notify_add_usage; return 0 ;;
      --key|--key=*|--url|--url=*)
        _notify_err "pass the url and key by prompt, stdin, or BERCAIL_NOTIFY_URL/BERCAIL_NOTIFY_KEY, never as arguments"
        return 1 ;;
      -*) _notify_err "unknown option '$1'"; _notify_add_usage; return 1 ;;
      *)
        [[ -z "$name" ]] || { _notify_err "one sink name only"; _notify_add_usage; return 1; }
        name="$1"; shift ;;
    esac
  done
  [[ -n "$name" ]] || { _notify_add_usage; return 1; }
  [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
    || { _notify_err "sink name '$name': use letters, digits, dot, dash, underscore"; return 1; }
  case "$auth" in
    both|bearer|x-automation-key|none) ;;
    *) _notify_err "--auth must be both, bearer, x-automation-key, or none"; return 1 ;;
  esac
  local IFS_save="$IFS"
  IFS=','
  for kind in $kinds; do
    kind="${kind//[[:space:]]/}"
    [[ "$kind" == finished || "$kind" == blocked ]] \
      || { IFS="$IFS_save"; _notify_err "--notify takes finished and blocked, not '$kind'"; return 1; }
  done
  IFS="$IFS_save"
  [[ "$repos_set" -eq 1 ]] || repos="$(_notify_current_repo)"
  for kind in "$repos" "$spaces"; do
    [[ "$kind" != *[\"#]* ]] || { _notify_err "--repos and --spaces cannot hold \" or #"; return 1; }
  done

  dir="$(notify_sinks_dir)"
  f="$dir/$name.toml"
  if [[ -e "$f" ]]; then
    printf 'sink %s exists: url=%s key=%s auth=%s repos="%s" spaces="%s" notify="%s" enabled=%s\n' \
      "$name" "$(_notify_redact_url "$(notify_sink_value "$f" url "")")" \
      "$([[ -n "$(notify_sink_key "$f" 2>/dev/null || true)" ]] && printf set || printf none)" \
      "$(notify_sink_value "$f" auth both)" "$(notify_sink_value "$f" repos "")" \
      "$(notify_sink_value "$f" spaces "$(notify_sink_value "$f" workspaces "")")" \
      "$(notify_sink_value "$f" notify "finished, blocked")" "$(notify_sink_value "$f" enabled true)" >&2
    if [[ "$yes" -ne 1 ]]; then
      [[ -t 0 ]] || { _notify_err "sink '$name' exists; pass --yes to replace it"; return 1; }
      read -r -p "Replace it? [y/N] " reply || reply=""
      [[ "$reply" == [yY]* ]] || { printf 'kept %s\n' "$f" >&2; return 1; }
    fi
  fi

  url="${BERCAIL_NOTIFY_URL:-}"
  [[ -n "$url" ]] || url="$(_notify_read_value "Webhook URL: " 0)"
  [[ "$url" =~ ^https?://[^[:space:]\"#]+$ ]] \
    || { _notify_err "the webhook URL must be http(s)://... with no spaces, quotes, or #"; return 1; }
  key=""
  if [[ "$auth" != none ]]; then
    key="${BERCAIL_NOTIFY_KEY:-}"
    [[ -n "$key" ]] || key="$(_notify_read_value "Sender key (hidden): " 1)"
    [[ -n "$key" ]] || { _notify_err "no key given (use --auth none for a webhook without one)"; return 1; }
    [[ "$key" != *[\"#[:space:]]* ]] \
      || { _notify_err "the key holds a quote, #, or blank; check the paste"; return 1; }
  fi

  mkdir -p "$dir" || return 1
  tmp="$(umask 077 && mktemp "$dir/.$name.toml.XXXXXX")" || return 1
  if ! {
    printf '# Written by bercail notify add. Flat key = value; see notify.sink.example.\n'
    printf 'url = "%s"\n' "$url"
    [[ -n "$key" ]] && printf 'key = "%s"\n' "$key"
    printf 'auth = %s\n' "$auth"
    printf 'repos = "%s"\n' "$repos"
    printf 'spaces = "%s"\n' "$spaces"
    printf 'notify = %s\n' "$kinds"
    printf 'enabled = true\n'
  } >"$tmp" || ! chmod 600 "$tmp" || ! mv -f "$tmp" "$f"; then
    rm -f "$tmp"
    _notify_err "could not write $f"
    return 1
  fi
  key=""
  printf 'wrote %s (mode 600)\n' "$f" >&2

  code=0
  notify_test "$name" || code=$?
  if [[ "$code" -ne 0 ]]; then
    case "$(jq -r '.last_code // empty' "$(_notify_sink_state_file "$name")" 2>/dev/null)" in
      401|403) _notify_err "the key or auth mode is wrong; rerun: bercail notify add $name --yes (try --auth bearer or --auth x-automation-key)" ;;
      000) _notify_err "no answer from the webhook URL; check it and rerun: bercail notify add $name --yes" ;;
    esac
    return 1
  fi
}

cmd_notify() {
  case "${1:-status}" in
    run) notify_run ;;
    status) notify_status ;;
    test) notify_test "${2:-}" ;;
    add) shift; notify_add "$@" ;;
    *) _notify_err "unknown command '${1:-}' (run|status|test NAME|add NAME)"; return 1 ;;
  esac
}
