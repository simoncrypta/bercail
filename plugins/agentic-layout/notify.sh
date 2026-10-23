#!/usr/bin/env bash
# Fan out Herdr agent status changes to named webhook sinks.
#
# One event hook (pane.agent_status_changed) serves every bot. Each sink is a
# file in ~/.config/bercail/notify.d/<name>.toml with its own URL, key, and
# filters. The hook is stateful: it keeps each pane's last live status, so it
# can tell "finished" (working -> done/idle) from "already idle", and report
# "blocked" once per episode. Herdr's own payload has no previous status.
#
#   notify.sh event        Herdr event hook (reads HERDR_PLUGIN_EVENT_JSON)
#   notify.sh pane-exited  forget a pane's saved status (also workspace-closed)
#   notify.sh status       sinks, filters, and last delivery result (no secrets)
#   notify.sh test NAME    send one kind=test payload to sink NAME
# shellcheck disable=SC1091
set -euo pipefail

if [[ -n "${HERDR_BIN_PATH:-}" && ! -x "$HERDR_BIN_PATH" ]]; then
  unset HERDR_BIN_PATH
fi
HERDR="${HERDR_BIN_PATH:-herdr}"
NOTIFY_SCHEMA="bercail.agent_status/v1"

_notify_plugin_root() {
  if [[ -n "${HERDR_PLUGIN_ROOT:-}" ]]; then
    printf '%s' "$HERDR_PLUGIN_ROOT"
  else
    cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
  fi
}

# shellcheck source=state.sh
source "$(_notify_plugin_root)/state.sh"

notify_sinks_dir() {
  printf '%s' "${BERCAIL_NOTIFY_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/bercail/notify.d}"
}

notify_state_dir() {
  local dir
  dir="$(_state_dir)/notify"
  mkdir -p "$dir/panes" "$dir/sinks"
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

# previous live status -> current live status => finished | blocked | none.
# Herdr reports `done` for an unseen idle agent and `idle` once seen, so
# done -> idle (Simon looked at the pane) is not a second finish.
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

_notify_pane_file() {
  local pane="${1//[^A-Za-z0-9_.-]/_}"
  printf '%s/panes/%s.json' "$(notify_state_dir)" "$pane"
}

notify_pane_prev() {
  local f
  f="$(_notify_pane_file "$1")"
  [[ -r "$f" ]] || return 0
  jq -r '.status // empty' "$f" 2>/dev/null || true
}

notify_pane_save() {
  local pane="$1" status="$2" f tmp
  f="$(_notify_pane_file "$pane")"
  tmp="$f.$$"
  jq -nc --arg pane "$pane" --arg status "$status" --argjson at "$(_notify_now)" \
    '{pane_id:$pane,status:$status,at:$at}' >"$tmp" && mv -f "$tmp" "$f"
}

_notify_event_field() {
  printf '%s' "${HERDR_PLUGIN_EVENT_JSON:-{\}}" \
    | jq -r --arg f "$1" '.data[$f] // .[$f] // empty' 2>/dev/null || true
}

_notify_json_or_empty() {
  local v="${1:-}"
  if [[ -n "$v" ]] && jq -e . >/dev/null 2>&1 <<<"$v"; then
    printf '%s' "$v"
  else
    printf '{}'
  fi
}

# Live pane snapshot from herdr, or {} when the pane cannot be read.
notify_live_pane() {
  local out
  out="$("$HERDR" pane get "$1" 2>/dev/null </dev/null)" || { printf '{}'; return 0; }
  jq -c '.result.pane // {}' <<<"$out" 2>/dev/null || printf '{}'
}

notify_workspace_info() {
  local workspace_id="$1" context="$2" label worktree out
  label="$(jq -r '.workspace_label // empty' <<<"$context")"
  worktree="$(jq -c '.worktree // empty' <<<"$context")"
  if [[ -z "$label" || -z "$worktree" ]] && [[ -n "$workspace_id" ]]; then
    out="$("$HERDR" workspace get "$workspace_id" 2>/dev/null </dev/null || true)"
    [[ -n "$label" ]] || label="$(jq -r '.result.workspace.label // empty' <<<"$out" 2>/dev/null || true)"
    [[ -n "$worktree" ]] || worktree="$(jq -c '.result.workspace.worktree // empty' <<<"$out" 2>/dev/null || true)"
  fi
  [[ -n "$worktree" ]] || worktree='{}'
  jq -nc --arg id "$workspace_id" --arg label "$label" \
    --arg cwd "$(jq -r '.workspace_cwd // empty' <<<"$context")" --argjson wt "$worktree" '
    {workspace_id:$id, label:$label,
     repo:($wt.repo_name // null),
     checkout_path:($wt.checkout_path // (if $cwd == "" then null else $cwd end)),
     linked:($wt.is_linked_worktree // false)}'
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

# Does SINK want this KIND for this pane/workspace? Empty filters match all.
notify_sink_wants() {
  local file="$1" kind="$2" pane_json="$3" ws_json="$4"
  local kinds panes workspaces repos label repo agent role
  notify_bool "$(notify_sink_value "$file" enabled true)" || return 1
  if [[ "$kind" != "test" ]]; then
    kinds="$(notify_sink_value "$file" notify "finished, blocked")"
    notify_list_has "$kinds" "$kind" || return 1
  fi
  panes="$(notify_sink_value "$file" panes agent)"
  if [[ "$panes" == "agent" && "$kind" != "test" ]]; then
    agent="$(jq -r '.agent // empty' <<<"$pane_json")"
    role="$(jq -r '.role // empty' <<<"$pane_json")"
    [[ -n "$agent" || "$role" == "agent" ]] || return 1
    [[ -z "$role" || "$role" == "agent" ]] || return 1
  fi
  workspaces="$(notify_sink_value "$file" workspaces "")"
  repos="$(notify_sink_value "$file" repos "")"
  [[ -z "$workspaces" && -z "$repos" ]] && return 0
  [[ "$kind" == "test" ]] && return 0
  label="$(jq -r '.label // empty' <<<"$ws_json")"
  repo="$(jq -r '.repo // empty' <<<"$ws_json")"
  [[ -n "$workspaces" && -n "$label" ]] && notify_glob_match "$workspaces" "$label" && return 0
  [[ -n "$repos" && -n "$repo" ]] && notify_glob_match "$repos" "$repo" && return 0
  return 1
}

_notify_sink_state_file() {
  printf '%s/sinks/%s.json' "$(notify_state_dir)" "$1"
}

# Record a delivery. 401/403 raise one Herdr toast per failure episode and
# always go to stderr (the plugin log), so a dead key is never silent.
notify_record() {
  local name="$1" code="$2" f prev='{}' prev_auth auth="false" ok="false" now tmp
  f="$(_notify_sink_state_file "$name")"
  # A corrupt or empty state file must not stop recording.
  [[ -r "$f" ]] && prev="$(jq -c 'objects' "$f" 2>/dev/null | head -n 1)"
  [[ -n "$prev" ]] || prev='{}'
  prev_auth="$(jq -r '.auth_failed // false' <<<"$prev")"
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
    if [[ "$prev_auth" != "true" ]]; then
      "$HERDR" notification show "bercail notify: $name key rejected" \
        --body "HTTP $code from sink '$name'. Deliveries fail until the key is fixed." \
        --sound request >/dev/null 2>&1 </dev/null || true
    fi
  elif [[ "$ok" != "true" ]]; then
    _notify_err "sink '$name' delivery failed (HTTP $code)"
  elif [[ "$prev_auth" == "true" ]]; then
    "$HERDR" notification show "bercail notify: $name recovered" >/dev/null 2>&1 </dev/null || true
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
  local kind="$1" sink="$2" pane_json="$3" ws_json="$4" desk_json="$5" event_id="$6"
  local event context
  event="$(_notify_json_or_empty "${HERDR_PLUGIN_EVENT_JSON:-}")"
  context="$(_notify_json_or_empty "${HERDR_PLUGIN_CONTEXT_JSON:-}")"
  jq -nc --arg schema "$NOTIFY_SCHEMA" --arg kind "$kind" --arg sink "$sink" \
    --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg event_id "$event_id" \
    --argjson pane "$pane_json" --argjson ws "$ws_json" --argjson desk "$desk_json" \
    --argjson event "$event" --argjson context "$context" '
    {source:"bercail", schema:$schema, kind:$kind, sink:$sink, at:$at,
     event_id:$event_id,
     pane:$pane, workspace:$ws, desk:$desk, event:$event, context:$context}'
}

notify_deliver_all() {
  local kind="$1" pane_json="$2" ws_json="$3" desk_json="$4" event_id="$5" f name body code
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    name="$(notify_sink_name "$f")"
    notify_sink_wants "$f" "$kind" "$pane_json" "$ws_json" || continue
    body="$(notify_payload "$kind" "$name" "$pane_json" "$ws_json" "$desk_json" "$event_id")"
    code="$(notify_post "$f" "$body")"
    case "$code" in
      nourl) _notify_err "sink '$name' has no url; skipped" ;;
      insecure)
        _notify_err "sink '$name' key file is readable by others; chmod 600 it. Skipped."
        "$HERDR" notification show "bercail notify: $name skipped" \
          --body "Key file is group/other readable; chmod 600." >/dev/null 2>&1 </dev/null || true
        ;;
      *) notify_record "$name" "$code" ;;
    esac
  done < <(notify_sink_files)
}

# Herdr event hook. The live read, the previous-status swap, and the
# classification run under a lock so concurrent hooks cannot both see the same
# previous status (that is how duplicate finishes happened). Delivery runs
# after the lock is released: a slow sink must not hold up other panes' hooks,
# or a queued hook reads a later live status and a short turn is lost.
notify_event() {
  [[ -n "$(notify_sink_files)" ]] || return 0
  local pane
  pane="$(_notify_event_field pane_id)"
  [[ -n "$pane" ]] || return 0
  NOTIFY_KIND="none"
  _layout_lock_acquire notify-hook || return 0
  notify_event_classify "$pane" || true
  _layout_lock_release
  [[ "$NOTIFY_KIND" != "none" ]] || return 0
  notify_event_deliver "$pane" || true
}

# Sets NOTIFY_KIND, NOTIFY_LIVE, NOTIFY_STATUS, NOTIFY_PREV, NOTIFY_VERIFIED.
notify_event_classify() {
  local pane="$1"
  NOTIFY_VERIFIED=true
  NOTIFY_LIVE="$(notify_live_pane "$pane")"
  NOTIFY_STATUS="$(jq -r '.agent_status // empty' <<<"$NOTIFY_LIVE")"
  if [[ -z "$NOTIFY_STATUS" ]]; then
    # Pane is gone or herdr is unreachable: fall back to the event's status
    # and mark the payload unverified.
    NOTIFY_STATUS="$(_notify_event_field agent_status)"
    NOTIFY_VERIFIED=false
  fi
  [[ -n "$NOTIFY_STATUS" ]] || return 0
  NOTIFY_PREV="$(notify_pane_prev "$pane")"
  notify_pane_save "$pane" "$NOTIFY_STATUS"
  NOTIFY_KIND="$(notify_classify "$NOTIFY_PREV" "$NOTIFY_STATUS")"
}

notify_event_deliver() {
  local pane="$1" kind="$NOTIFY_KIND" live="$NOTIFY_LIVE" status="$NOTIFY_STATUS"
  local prev="$NOTIFY_PREV" verified="$NOTIFY_VERIFIED"
  local workspace_id agent role pane_json ws_json desk_json context path
  workspace_id="$(jq -r '.workspace_id // empty' <<<"$live")"
  [[ -n "$workspace_id" ]] || workspace_id="$(_notify_event_field workspace_id)"
  agent="$(jq -r '.agent // empty' <<<"$live")"
  [[ -n "$agent" ]] || agent="$(_notify_event_field agent)"
  role="$(jq -r '.tokens.agentic_role // empty' <<<"$live")"
  pane_json="$(jq -nc --arg pane "$pane" --arg ws "$workspace_id" --arg agent "$agent" \
    --arg role "$role" --arg status "$status" --arg prev "$prev" --argjson verified "$verified" \
    --arg title "$(_notify_event_field title)" --arg display "$(_notify_event_field display_agent)" '
    def n: if . == "" then null else . end;
    {pane_id:$pane, workspace_id:$ws, agent:($agent|n), role:($role|n), status:$status,
     previous_status:($prev|n), verified:$verified, title:($title|n), display_agent:($display|n)}')"
  context="$(_notify_json_or_empty "${HERDR_PLUGIN_CONTEXT_JSON:-}")"
  ws_json="$(notify_workspace_info "$workspace_id" "$context")"
  path="$(jq -r '.checkout_path // empty' <<<"$ws_json")"
  desk_json="$(notify_desk_info "$path" "$agent")"
  # Same id for every sink and retry, so receivers can dedupe. The pid keeps
  # two real transitions of one pane in the same second apart.
  notify_deliver_all "$kind" "$pane_json" "$ws_json" "$desk_json" "$pane:$kind:$(_notify_now):$$"
}

# pane.exited / workspace.closed: drop saved statuses so a reused pane id
# (herdr numbers panes per workspace) never inherits a stale `working`.
notify_forget() {
  local what="$1" id dir
  dir="$(_state_dir)/notify/panes"
  [[ -d "$dir" ]] || return 0
  case "$what" in
    pane)
      id="$(_notify_event_field pane_id)"
      [[ -n "$id" ]] && rm -f "$(_notify_pane_file "$id")"
      ;;
    workspace)
      id="$(_notify_event_field workspace_id)"
      id="${id//[^A-Za-z0-9_.-]/_}"
      [[ -n "$id" ]] && rm -f "$dir/${id}_"*.json
      ;;
  esac
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
    printf -- '- %s enabled=%s url=%s key=%s notify="%s" panes=%s workspaces="%s" repos="%s"\n' \
      "$name" "$(notify_sink_value "$f" enabled true)" \
      "$([[ -n "$(notify_sink_value "$f" url "")" ]] && printf set || printf MISSING)" \
      "$([[ -n "$(notify_sink_key "$f" 2>/dev/null || true)" ]] && printf set || printf none)" \
      "$(notify_sink_value "$f" notify "finished, blocked")" \
      "$(notify_sink_value "$f" panes agent)" \
      "$(notify_sink_value "$f" workspaces "")" "$(notify_sink_value "$f" repos "")"
    if [[ -r "$st" ]]; then
      jq -r '"    last=\(.last_code) auth_failed=\(.auth_failed) failures=\(.failures // 0) last_ok_at=\(.last_ok_at // "never")"' "$st"
    else
      printf '    no deliveries yet\n'
    fi
  done < <(notify_sink_files)
  [[ "$found" -eq 1 ]] || printf '(no sinks)\n'
}

notify_test() {
  local name="${1:-}" f code pane ws desk
  [[ -n "$name" ]] || { _notify_err "usage: notify.sh test SINK"; return 1; }
  f="$(notify_sinks_dir)/$name.toml"
  [[ -f "$f" ]] || { _notify_err "no sink $f"; return 1; }
  pane='{"pane_id":null,"status":"test","previous_status":null,"verified":false}'
  ws='{"label":null,"repo":null}'
  desk='{"branch":null,"issue":null,"stage":null,"harness":null,"result":null}'
  code="$(notify_post "$f" "$(notify_payload test "$name" "$pane" "$ws" "$desk" "test:$(_notify_now)")")"
  case "$code" in
    nourl|insecure) _notify_err "sink '$name': $code"; return 1 ;;
  esac
  notify_record "$name" "$code"
  printf '%s HTTP %s\n' "$name" "$code"
  [[ "$code" == 2?? ]]
}

notify_main() {
  case "${1:-event}" in
    event) notify_event ;;
    pane-exited) notify_forget pane ;;
    workspace-closed) notify_forget workspace ;;
    status) notify_status ;;
    test) notify_test "${2:-}" ;;
    *) _notify_err "unknown command '${1:-}' (event|pane-exited|workspace-closed|status|test NAME)"; return 1 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  notify_main "$@"
fi
