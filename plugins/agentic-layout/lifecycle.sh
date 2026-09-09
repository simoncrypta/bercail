# Pane lifecycle. Sourced from layout.sh before topology.sh.

HEAL_COOLDOWN_SECONDS=15

_unix_now() {
  date +%s
}

_pane_exists() {
  local pane_id="$1"
  [[ -n "$pane_id" ]] || return 1
  _herdr_json pane get "$pane_id" >/dev/null 2>&1
}

_pane_is_shell() {
  local pane="$1" json agent
  json="$(_herdr_json pane get "$pane")" || return 1
  agent="$(printf '%s' "$json" | _jq '.result.pane.agent // .result.agent // empty')"
  [[ -z "$agent" || "$agent" == "null" ]]
}

_pane_has_sidebar_token() {
  local pane="$1" sidebar_bin panes
  [[ -n "$pane" ]] || return 1
  sidebar_bin="$(_sidebar_bin)"
  [[ -x "$sidebar_bin" ]] || return 1
  panes="$(_herdr_json pane list)" || return 1
  [[ "$("$sidebar_bin" --pane-has-token "$pane" <<<"$panes")" == "yes" ]]
}

_pane_run_login() {
  local pane="$1" cmd="$2" sh
  sh="$(_login_shell)"
  _herdr_json pane run "$pane" "$(printf '%q' "$sh") -li -c $(printf '%q' "$cmd")" >/dev/null
}

_pane_run_sidebar() {
  local pane="$1" sidebar_bin="$2"
  local -a run_cmd=(env AGENTIC_LAYOUT_EMBEDDED=1 AGENTIC_LAYOUT_PLUGIN_ID=agentic-dev.layout)
  run_cmd+=(HERDR_SIDEBAR_FONT_PROMPT=off)
  run_cmd+=(HERDR_PLUGIN_STATE_DIR="$(_state_dir)")
  run_cmd+=(HERDR_PLUGIN_ROOT="$PLUGIN_ROOT")
  [[ -n "${HERDR_WORKSPACE_ID:-}" ]] && run_cmd+=(HERDR_WORKSPACE_ID="$HERDR_WORKSPACE_ID")
  [[ -n "${HERDR_BIN_PATH:-}" ]] && run_cmd+=(HERDR_BIN_PATH="${HERDR_BIN_PATH}")
  run_cmd+=("$sidebar_bin" --embedded)
  _stamp_metadata "$pane" sidebar
  _herdr_json pane run "$pane" "${run_cmd[@]}" >/dev/null 2>&1 || true
  _rename_pane "$pane" sidebar
}

_restart_sidebar_pane() {
  local pane="$1" sidebar_bin
  [[ -n "$pane" ]] || return 0
  _pane_exists "$pane" || return 0
  _pane_is_shell "$pane" || return 0
  sidebar_bin="$(_sidebar_bin)"
  [[ -x "$sidebar_bin" ]] || return 0
  _pane_run_sidebar "$pane" "$sidebar_bin"
}

_shell_launch() {
  local sh
  sh="$(printf '%q' "$(_login_shell)")"
  printf '%s' "clear; exec ${sh} -li"
}

_restart_pane_cmd() {
  local pane="$1" cmd="$2"
  [[ -n "$pane" && -n "$cmd" ]] || return 0
  if _pane_is_shell "$pane"; then
    _pane_run_login "$pane" "$cmd" || true
  else
    _herdr_json pane run "$pane" "$cmd" >/dev/null 2>&1 || _pane_run_login "$pane" "$cmd" || true
  fi
}

_ensure_pane_process() {
  local pane="$1" cmd="$2"
  [[ -n "$pane" && -n "$cmd" ]] || return 0
  if _pane_is_shell "$pane"; then
    _pane_run_login "$pane" "$cmd" || true
  fi
}

_stamp_metadata() {
  local pane="$1" role="$2" extra="${3:-}"
  [[ -n "$pane" ]] || return 0
  if [[ -n "$extra" ]]; then
    _herdr_json pane report-metadata "$pane" --source "$METADATA_SOURCE" \
      --token "agentic_role=$role" --token "$extra" >/dev/null 2>&1 || true
  else
    _herdr_json pane report-metadata "$pane" --source "$METADATA_SOURCE" \
      --token "agentic_role=$role" >/dev/null 2>&1 || true
  fi
}

_pane_label() {
  local role="$1"
  case "$role" in
    agent) printf '%s' "Agent" ;;
    center_review) printf '%s' "Review" ;;
    center_shell) printf '%s' "Shell" ;;
    sidebar) printf '%s' "Files" ;;
    editor) printf '%s' "Editor" ;;
    *) printf '%s' "$role" ;;
  esac
}

_rename_pane() {
  local pane="$1" role="$2"
  [[ -n "$pane" ]] || return 0
  _herdr_json pane rename "$pane" "$(_pane_label "$role")" >/dev/null 2>&1 || true
}

_reset_agent_pane_to_shell() {
  local pane="$1" json pgid shell_pid pid waited=0
  [[ -n "$pane" ]] || return 1
  json="$(_herdr_json pane process-info --pane "$pane")" || true
  pgid="$(printf '%s' "${json:-}" | _jq '.result.process_info.foreground_process_group_id // empty' 2>/dev/null || true)"
  shell_pid="$(printf '%s' "${json:-}" | _jq '.result.process_info.shell_pid // empty' 2>/dev/null || true)"
  if [[ "$pgid" =~ ^[1-9][0-9]*$ ]] && (( pgid > 1 )) && [[ "$pgid" != "$shell_pid" ]]; then
    kill -- -"$pgid" 2>/dev/null || kill "$pgid" 2>/dev/null || true
  fi
  while IFS= read -r pid; do
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || continue
    [[ "$pid" == "$shell_pid" ]] && continue
    (( pid > 1 )) || continue
    kill "$pid" 2>/dev/null || true
  done < <(printf '%s' "${json:-}" | jq -r '.result.process_info.foreground_processes[]?.pid // empty' 2>/dev/null || true)
  while ! _pane_is_shell "$pane"; do
    if (( waited >= 50 )); then
      echo "agentic-layout: timed out waiting for agent pane $pane to return to a shell" >&2
      return 1
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
}

# herdr pane run types the command + Enter. A multiline prompt would submit
# early, so handoff writes the prompt to a file and we exec one argv.
_launch_agent_on_pane() {
  local pane="$1" agent file cmd
  [[ -n "$pane" ]] || return 1
  agent="${WT_HERDR_AGENT_CMD:-$(_agent_cmd)}"
  file="${WT_HERDR_AGENT_PROMPT_FILE:-}"
  if [[ -n "$file" ]]; then
    [[ -f "$file" ]] || {
      echo "agentic-layout: prompt file not found: $file" >&2
      return 1
    }
    cmd="$(printf 'p=$(cat -- %q) && rm -f %q && exec %q -- "$p"' "$file" "$file" "$agent")"
    _pane_run_login "$pane" "$cmd"
    return
  fi
  _herdr_json pane run "$pane" "$agent" >/dev/null
}

# True when Herdr already tagged the pane, or a non-shell process is in the
# foreground (the agent field can lag after pane run / a heavy worktree copy).
_pane_agent_started() {
  local pane="$1" json pgid shell_pid
  [[ -n "$pane" ]] || return 1
  if ! _pane_is_shell "$pane"; then
    return 0
  fi
  json="$(_herdr_json pane process-info --pane "$pane")" || return 1
  pgid="$(printf '%s' "${json:-}" | _jq '.result.process_info.foreground_process_group_id // empty' 2>/dev/null || true)"
  shell_pid="$(printf '%s' "${json:-}" | _jq '.result.process_info.shell_pid // empty' 2>/dev/null || true)"
  [[ "$pgid" =~ ^[1-9][0-9]*$ ]] && (( pgid > 1 )) && [[ "$pgid" != "$shell_pid" ]]
}

_wait_agent_running() {
  local pane="$1" timeout_ms waited=0
  [[ -n "$pane" ]] || return 1
  timeout_ms="${WT_HERDR_AGENT_READY_TIMEOUT_MS:-30000}"
  [[ "$timeout_ms" =~ ^[0-9]+$ ]] || timeout_ms=30000
  while true; do
    if _pane_agent_started "$pane"; then
      return 0
    fi
    if (( waited >= timeout_ms )); then
      break
    fi
    sleep 0.2
    waited=$((waited + 200))
  done
  echo "agentic-layout: agent did not start on pane $pane within ${timeout_ms}ms" >&2
  return 1
}

# Clear session: configured agent, no prompt. Used by apply / d / dev.
# Never inherit a handoff prompt from the parent environment.
_start_default_agent() {
  unset WT_HERDR_AGENT_PROMPT_FILE
  _start_agent
}

# Orchestrator / handoff-spawn: start or replace the agent with the prompt file.
_start_handoff_agent() {
  local file="${WT_HERDR_AGENT_PROMPT_FILE:-}"
  if [[ -z "$file" ]]; then
    echo "agentic-layout: handoff-agent requires WT_HERDR_AGENT_PROMPT_FILE" >&2
    return 1
  fi
  if [[ ! -f "$file" ]]; then
    echo "agentic-layout: prompt file not found: $file" >&2
    return 1
  fi
  _start_agent
}

# start-agent action: replace a live agent only when a prompt file is set
# (re-handoff). Unprompted start is a no-op if the pane is already an agent.
_start_agent() {
  local state pane
  state="$(_dev_state)" || state="$(_layout_ensure)"
  [[ -n "$state" ]] || return 1
  pane="$(printf '%s' "$state" | _jq '.agent_pane_id // empty')"
  if ! _pane_exists "$pane"; then
    state="$(_layout_ensure)"
    pane="$(printf '%s' "$state" | _jq '.agent_pane_id // empty')"
  fi
  [[ -n "$pane" ]] || return 1
  if ! _pane_is_shell "$pane"; then
    if [[ -n "${WT_HERDR_AGENT_PROMPT_FILE:-}" ]]; then
      _reset_agent_pane_to_shell "$pane" || return 1
    else
      return 0
    fi
  fi
  _launch_agent_on_pane "$pane" || return 1
  _wait_agent_running "$pane"
}

_ensure_pane_live() {
  local workspace_id="$1" pane="$2" role="$3"
  local sidebar_bin
  [[ -n "$pane" ]] || return 1
  _pane_exists "$pane" || return 1
  _pane_is_shell "$pane" || return 1
  [[ -n "$workspace_id" ]] && export HERDR_WORKSPACE_ID="$workspace_id"
  case "$role" in
    center_shell)
      _ensure_pane_process "$pane" "$(_shell_launch)"
      ;;
    center_review)
      if _pane_agent_started "$pane"; then
        return 1
      fi
      _restart_pane_cmd "$pane" "$(_review_launch)"
      ;;
    sidebar)
      if _pane_has_sidebar_token "$pane"; then
        return 1
      fi
      sidebar_bin="$(_sidebar_bin)"
      [[ -x "$sidebar_bin" ]] || return 1
      _pane_run_sidebar "$pane" "$sidebar_bin"
      return 0
      ;;
    *)
      return 1
      ;;
  esac
  _stamp_metadata "$pane" "$role"
  _rename_pane "$pane" "$role"
  return 0
}

_refresh_pane_identity() {
  local pane="$1" role="$2"
  [[ -n "$pane" ]] || return 0
  _stamp_metadata "$pane" "$role"
  _rename_pane "$pane" "$role"
}

_recover_workspace_panes() {
  local workspace_id="$1" state="$2"
  local now last healed=0
  local shell_pane sidebar_pane
  [[ -n "$workspace_id" && -n "$state" ]] || {
    printf '%s' "${state:-{}}"
    return 0
  }
  now="$(_unix_now)"
  last="$(printf '%s' "$state" | _jq '.last_heal_unix // 0')"
  if [[ "$last" =~ ^[0-9]+$ ]] && (( now - last < HEAL_COOLDOWN_SECONDS && last > 0 )); then
    printf '%s' "$state"
    return 0
  fi
  shell_pane="$(printf '%s' "$state" | _jq '.shell_pane_id // empty')"
  sidebar_pane="$(printf '%s' "$state" | _jq '.sidebar_pane_id // empty')"
  if _ensure_pane_live "$workspace_id" "$shell_pane" center_shell; then
    healed=1
  fi
  if _ensure_pane_live "$workspace_id" "$sidebar_pane" sidebar; then
    healed=1
  fi
  if (( healed )); then
    state="$(printf '%s' "$state" | jq --argjson now "$now" '.last_heal_unix = $now')"
  fi
  printf '%s' "$state"
}

_workspace_is_live() {
  local workspace_id="$1" found
  found="$(_herdr_json workspace list | _jq --arg id "$workspace_id" \
    '.result.workspaces[]? | select(.workspace_id == $id) | .workspace_id' | head -1)" || return 2
  [[ -n "$found" ]]
}

_startup_one() {
  local workspace_id="$1" state reconciled live_status
  state="$(_state_load "$workspace_id" 2>/dev/null || true)"
  [[ -n "$state" ]] || return 0
  live_status=0
  _workspace_is_live "$workspace_id" || live_status=$?
  if [[ "$live_status" -eq 1 ]]; then
    _state_delete "$workspace_id"
    return 0
  fi
  [[ "$live_status" -eq 0 ]] || return 0
  reconciled="$(_reconcile_live_state "$state")"
  reconciled="$(_recover_workspace_panes "$workspace_id" "$reconciled")"
  if [[ -z "$(printf '%s' "$reconciled" | _jq '.sidebar_pane_id // empty')" ]]; then
    export HERDR_WORKSPACE_ID="$workspace_id"
    WT_HERDR_NO_ATTACH=1 _layout_ensure >/dev/null 2>&1 || true
  fi
  if [[ "$reconciled" != "$state" ]]; then
    _state_save "$workspace_id" "$reconciled"
  fi
}

_on_startup() {
  local state_dir path workspace_id
  state_dir="$(_state_dir)"
  [[ -d "$state_dir" ]] || return 0
  shopt -s nullglob
  for path in "$state_dir"/*.json; do
    [[ -f "$path" ]] || continue
    workspace_id="${path##*/}"
    workspace_id="${workspace_id%.json}"
    _with_layout_lock "$workspace_id" _startup_one "$workspace_id"
  done
  shopt -u nullglob
}
