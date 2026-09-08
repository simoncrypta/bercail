# Tab/pane topology. Sourced from layout.sh after herdr helpers.
# Invariant: Shell tab always, Review tab on demand, plus editor tabs.
# Agent + sidebar follow the active center.

_tab_list_tsv() {
  local workspace_id="$1"
  _herdr_json tab list --workspace "$workspace_id" \
    | jq -r '.result.tabs[]? | [.tab_id, (.label // "")] | @tsv'
}

_tab_exists() {
  local workspace_id="$1" tab_id="$2"
  [[ -n "$workspace_id" && -n "$tab_id" ]] || return 1
  _tab_list_tsv "$workspace_id" | awk -F '\t' -v id="$tab_id" '$1 == id { found=1 } END { exit found ? 0 : 1 }'
}

_pane_tab_id() {
  local pane="$1"
  _herdr_json pane get "$pane" | _jq '.result.pane.tab_id // empty' 2>/dev/null || true
}

_pane_on_tab() {
  local workspace_id="$1" tab_id="$2"
  _herdr_json pane list --workspace "$workspace_id" \
    | jq -r --arg tab "$tab_id" '.result.panes[]? | select(.tab_id == $tab) | .pane_id' \
    | head -1
}

# Center is the pane on the tab that is not agent or sidebar.
_center_pane_on_tab() {
  local workspace_id="$1" tab_id="$2" state="$3"
  _herdr_json pane list --workspace "$workspace_id" \
    | jq -r --arg tab "$tab_id" --argjson state "$state" '
        ($state.agent_pane_id // "") as $agent
        | ($state.sidebar_pane_id // "") as $sidebar
        | .result.panes[]?
        | select(.tab_id == $tab and .pane_id != $agent and .pane_id != $sidebar)
        | .pane_id' \
    | head -1
}

_split_pane() {
  local parent="$1" direction="$2" ratio="$3" cwd="${4:-}"
  local json args=(pane split "$parent" --direction "$direction" --ratio "$ratio" --no-focus)
  [[ -n "$cwd" ]] && args+=(--cwd "$cwd")
  json="$(_herdr_json "${args[@]}")"
  printf '%s' "$json" | _jq '.result.pane.pane_id // empty'
}

_tabs_json_from_tsv() {
  jq -Rn '[inputs | select(length > 0) | split("\t") | {tab_id: .[0], label: (.[1] // ""), focused: false}]'
}

_adopt_tabs_json() {
  local state="$1" tabs_tsv="$2" shell_id="${3:-}"
  jq -n \
    --argjson state "$state" \
    --argjson tabs "$(printf '%s\n' "$tabs_tsv" | _tabs_json_from_tsv)" \
    --arg shell_tab_id "$shell_id" \
    '{state: $state, tabs: $tabs} + if $shell_tab_id == "" then {} else {shell_tab_id: $shell_tab_id} end' \
    | _layout_core --adopt-tabs
}

# Adopt the first non-editor tab as Shell. Review-first workspaces are renamed.
# Review is optional: adopt a live Review tab if one exists, never create it here.
_ensure_shell_and_review_tabs() {
  local workspace_id="$1" workdir="$2" state="$3"
  local tabs_tsv adopted shell_id review_id extra
  tabs_tsv="$(_tab_list_tsv "$workspace_id")"
  adopted="$(_adopt_tabs_json "$state" "$tabs_tsv")"
  shell_id="$(printf '%s' "$adopted" | jq -r '.shell_tab_id // empty')"
  if [[ -z "$shell_id" ]]; then
    shell_id="$(_create_tab "$workspace_id" "$workdir" Shell)"
  else
    _herdr_json tab rename "$shell_id" Shell >/dev/null 2>&1 || true
  fi
  tabs_tsv="$(_tab_list_tsv "$workspace_id")"
  adopted="$(_adopt_tabs_json "$state" "$tabs_tsv" "$shell_id")"
  review_id="$(printf '%s' "$adopted" | jq -r '.review_tab_id // empty')"
  if [[ -n "$review_id" ]]; then
    _herdr_json tab rename "$review_id" Review >/dev/null 2>&1 || true
  fi
  tabs_tsv="$(_tab_list_tsv "$workspace_id")"
  adopted="$(_adopt_tabs_json "$state" "$tabs_tsv" "$shell_id")"
  while IFS= read -r extra; do
    [[ -n "$extra" ]] || continue
    _herdr_json tab close "$extra" >/dev/null 2>&1 || true
  done < <(printf '%s' "$adopted" | jq -r '.extra_tab_ids[]?')
  printf '%s\t%s' "$shell_id" "$review_id"
}

_create_tab() {
  local workspace_id="$1" workdir="$2" label="$3"
  _herdr_json tab create --workspace "$workspace_id" --cwd "$workdir" --label "$label" --no-focus \
    | _jq '.result.tab.tab_id'
}

_pane_needs_dock() {
  local pane="$1" tab="$2"
  [[ -n "$pane" ]] && _pane_exists "$pane" && [[ "$(_pane_tab_id "$pane")" != "$tab" ]]
}

_stickies_on_tab() {
  local state="$1" tab_id="$2"
  local agent sidebar
  agent="$(printf '%s' "$state" | _jq '.agent_pane_id // empty')"
  sidebar="$(printf '%s' "$state" | _jq '.sidebar_pane_id // empty')"
  ! _pane_needs_dock "$agent" "$tab_id" && ! _pane_needs_dock "$sidebar" "$tab_id"
}

# pane move emits tab.focused on the source tab while a programmatic dock is
# in flight; ignore those echoes plus redundant same-tab events.
_tab_focus_should_skip() {
  local state="$1" tab_id="$2" workspace_id="$3"
  local focused target
  if _stickies_on_tab "$state" "$tab_id"; then
    return 0
  fi
  focused="$(_focused_tab_id "$workspace_id")"
  if [[ -n "$focused" && "$focused" != "$tab_id" ]]; then
    return 0
  fi
  target="$(printf '%s' "$state" | _jq '.dock_target_tab // empty')"
  if [[ -n "$target" && "$target" != "$tab_id" ]] && _stickies_on_tab "$state" "$target"; then
    return 0
  fi
  return 1
}

_focused_tab_id() {
  local workspace_id="${1:-}"
  [[ -n "$workspace_id" ]] || return 0
  _herdr_json tab list --workspace "$workspace_id" \
    | jq -r '.result.tabs[]? | select(.focused == true) | .tab_id' \
    | head -1
}

_dock_shared_panes() {
  local target_tab="$1" center_pane="$2" state="$3"
  local agent sidebar json plan role split ratio swap pane_id docked=0
  [[ -n "$target_tab" && -n "$center_pane" ]] || {
    printf '%s' "$state"
    return 0
  }
  agent="$(printf '%s' "$state" | _jq '.agent_pane_id // empty')"
  sidebar="$(printf '%s' "$state" | _jq '.sidebar_pane_id // empty')"
  plan="$(jq -n --argjson state "$state" --arg tab_id "$target_tab" \
    --argjson agent "$(_agent_ratio)" --argjson sidebar "$(_sidebar_ratio)" \
    '{state:$state, tab_id:$tab_id, agent_ratio:$agent, sidebar_ratio:$sidebar}' \
    | _layout_core --dock-plan 2>/dev/null || true)"
  [[ -n "$plan" ]] || {
    if _stickies_on_tab "$state" "$target_tab"; then
      _enforce_column_ratios "$center_pane" "$agent" "$sidebar"
    fi
    printf '%s' "$state"
    return 0
  }
  # Agent first, at final width, then swap onto the left. Same-width swap
  # is how the sidebar avoids a respawn: the PTY never changes size mid-dock.
  while IFS=$'\t' read -r role split ratio swap; do
    [[ -n "$role" ]] || continue
    case "$role" in
      agent) pane_id="$agent" ;;
      sidebar) pane_id="$sidebar" ;;
      *) continue ;;
    esac
    ratio="$(awk -v n="$ratio" 'BEGIN { printf "%.6f", n }')"
    if _pane_needs_dock "$pane_id" "$target_tab"; then
      json="$(_herdr_json pane move "$pane_id" --tab "$target_tab" --split "$split" --target-pane "$center_pane" \
        --ratio "$ratio" --no-focus 2>/dev/null || true)"
      pane_id="$(_id_after_move "$json" "$pane_id")"
      if [[ "$swap" == "1" ]]; then
        _herdr_json pane swap --source-pane "$pane_id" --target-pane "$center_pane" >/dev/null 2>&1 || true
      fi
      docked=1
      case "$role" in
        agent) agent="$pane_id" ;;
        sidebar) sidebar="$pane_id" ;;
      esac
    fi
  done < <(printf '%s' "$plan" | jq -r '.steps[]? | [.pane_role, .split, (.ratio|tostring), (if .swap then "1" else "0" end)] | @tsv')
  state="$(printf '%s' "$state" | jq --arg agent "$agent" --arg sidebar "$sidebar" \
    '.agent_pane_id = $agent | .sidebar_pane_id = $sidebar')"
  if (( docked )) || _stickies_on_tab "$state" "$target_tab"; then
    _enforce_column_ratios "$center_pane" "$agent" "$sidebar"
  fi
  printf '%s' "$state"
}

# Signed (want - current). Empty if the split is already close enough.
_ratio_delta() {
  awk -v want="$1" -v cur="$2" 'BEGIN {
    d = want - cur
    if (d < 0.01 && d > -0.01) exit 1
    printf "%.6f", d
  }'
}

# pane move/split --ratio is left-keep. Same-tab dock is a no-op, so push
# existing 3-column tabs to agent 5/12 | center 5/12 | sidebar 1/6.
# herdr pane resize ignores a negative --amount; grow and shrink use
# opposite pane edges instead.
_enforce_column_ratios() {
  local center_pane="$1" agent_pane="${2:-}" sidebar_pane="${3:-}"
  local layout n current want delta abs
  [[ -n "$center_pane" ]] && _pane_exists "$center_pane" || return 0
  layout="$(_herdr_json pane layout --pane "$center_pane")"
  n="$(printf '%s' "${layout:-}" | jq -r \
    '[.result.layout.splits[]? | select(.direction == "right")] | length' 2>/dev/null || true)"
  [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 2 )) || return 0

  current="$(printf '%s' "${layout:-}" | jq -r '
    [.result.layout.splits[]? | select(.direction == "right" and .rect.width != null)]
    | sort_by(.rect.width)
    | .[0].ratio // empty
  ' 2>/dev/null || true)"
  want="$(_sidebar_split_ratio)"
  if delta="$(_ratio_delta "$want" "$current")"; then
    if awk -v d="$delta" 'BEGIN { exit !(d > 0) }'; then
      _herdr_json pane resize --pane "$center_pane" --direction right --amount "$delta" >/dev/null 2>&1 || true
    elif [[ -n "$sidebar_pane" ]] && _pane_exists "$sidebar_pane"; then
      abs="$(awk -v d="$delta" 'BEGIN { printf "%.6f", -d }')"
      _herdr_json pane resize --pane "$sidebar_pane" --direction left --amount "$abs" >/dev/null 2>&1 || true
    fi
  fi

  current="$(printf '%s' "${layout:-}" | jq -r '
    [.result.layout.splits[]? | select(.direction == "right" and .rect.width != null)]
    | sort_by(.rect.width)
    | .[-1].ratio // empty
  ' 2>/dev/null || true)"
  want="$(_agent_move_ratio)"
  if delta="$(_ratio_delta "$want" "$current")"; then
    if awk -v d="$delta" 'BEGIN { exit !(d > 0) }' && [[ -n "$agent_pane" ]] && _pane_exists "$agent_pane"; then
      _herdr_json pane resize --pane "$agent_pane" --direction right --amount "$delta" >/dev/null 2>&1 || true
    elif awk -v d="$delta" 'BEGIN { exit !(d < 0) }'; then
      abs="$(awk -v d="$delta" 'BEGIN { printf "%.6f", -d }')"
      _herdr_json pane resize --pane "$center_pane" --direction left --amount "$abs" >/dev/null 2>&1 || true
    fi
  fi
}

# One activation path for Alt+N, prefix role keys, and tab.focused.
# Pass skip_tab_focus=1 from tab.focused so we do not re-enter the event.
# Persist post-dock ids and drop the lock before `tab focus`: that RPC can
# synchronously dispatch tab.focused in another process.
_activate_tab() {
  local tab_id="$1"
  local skip_tab_focus="${2:-0}"
  local state workspace_id shell_tab review_tab center_pane view
  [[ -n "$tab_id" ]] || return 0
  workspace_id="${HERDR_WORKSPACE_ID:-${tab_id%%:*}}"
  export HERDR_WORKSPACE_ID="$workspace_id"
  _layout_lock_acquire "$workspace_id" || return 0
  state="$(_state_load "$workspace_id" 2>/dev/null || true)"
  if [[ -z "$state" ]]; then
    _layout_lock_release
    return 0
  fi
  if [[ "$skip_tab_focus" == 1 ]] && _tab_focus_should_skip "$state" "$tab_id" "$workspace_id"; then
    _layout_lock_release
    return 0
  fi
  shell_tab="$(printf '%s' "$state" | _jq '.shell_tab_id // empty')"
  review_tab="$(printf '%s' "$state" | _jq '.review_tab_id // empty')"
  if [[ "$tab_id" == "$shell_tab" ]]; then
    view=shell
    center_pane="$(printf '%s' "$state" | _jq '.shell_pane_id // empty')"
  elif [[ "$tab_id" == "$review_tab" ]]; then
    view=review
    center_pane="$(printf '%s' "$state" | _jq '.review_pane_id // empty')"
  else
    center_pane="$(printf '%s' "$state" | jq -r --arg tab "$tab_id" \
      '[(.editors // {})[] | select(.tab_id == $tab and (.pane_id // "") != "") | .pane_id][0] // empty')"
    if [[ -z "$center_pane" ]] || ! _pane_exists "$center_pane"; then
      _layout_lock_release
      if [[ "$skip_tab_focus" != 1 ]]; then
        _herdr_json tab focus "$tab_id" >/dev/null 2>&1 || true
      fi
      return 0
    fi
    view=editor
  fi
  if [[ "$skip_tab_focus" != 1 ]]; then
    state="$(printf '%s' "$state" | jq --arg tab "$tab_id" '.dock_target_tab = $tab')"
    _state_save "$workspace_id" "$state"
  fi
  state="$(_dock_shared_panes "$tab_id" "$center_pane" "$state")"
  state="$(printf '%s' "$state" | jq --arg view "$view" '.active_center_view = $view | del(.dock_target_tab)')"
  _state_save "$workspace_id" "$state"
  _layout_lock_release
  if [[ "$skip_tab_focus" != 1 ]]; then
    _herdr_json tab focus "$tab_id" >/dev/null 2>&1 || true
    _herdr_json pane focus "$center_pane" >/dev/null 2>&1 || true
  fi
}

_select_tab_number() {
  local number="$1" workspace_id tab_id
  [[ "$number" =~ ^[0-9]+$ ]] || return 0
  workspace_id="$(_dev_workspace_id)"
  [[ -n "$workspace_id" ]] || return 0
  tab_id="$(_herdr_json tab list --workspace "$workspace_id" | _layout_core --tab-index "$number")" || return 0
  [[ -n "$tab_id" ]] || return 0
  _activate_tab "$tab_id"
}

# Dock onto the neighbor, then focus — so the destination is never painted as a
# full-width center with stickies arriving a frame later.
_select_tab_relative() {
  local delta="$1" workspace_id tab_id
  workspace_id="$(_dev_workspace_id)"
  [[ -n "$workspace_id" ]] || return 0
  tab_id="$(_herdr_json tab list --workspace "$workspace_id" | _layout_core --tab-relative "$delta")" || return 0
  [[ -n "$tab_id" && "$tab_id" != "null" ]] || return 0
  _activate_tab "$tab_id"
}

# Neighbor of a specific tab. Empty if it is missing or is the only tab.
_tab_neighbor() {
  local workspace_id="$1" tab_id="$2" delta="${3:--1}"
  [[ -n "$workspace_id" && -n "$tab_id" ]] || return 0
  _herdr_json tab list --workspace "$workspace_id" \
    | jq -r --arg id "$tab_id" --argjson d "$delta" '
      .result.tabs as $tabs
      | ($tabs | map(.tab_id) | index($id)) as $i
      | ($tabs | length) as $n
      | if $i == null or $n < 2 then empty
        else $tabs[($i + ($d % $n) + $n) % $n].tab_id
        end'
}

_drop_editors_on_tab() {
  local workspace_id="$1" tab_id="$2"
  _state_update "$workspace_id" --arg tab "$tab_id" \
    '.editors = ((.editors // {}) | to_entries | map(select(.value.tab_id != $tab)) | from_entries)'
}

_focused_pane_id() {
  _herdr_json pane current | _jq '.result.pane.pane_id // empty' 2>/dev/null || true
}

_current_tab_id() {
  local workspace_id="${1:-}" tab_id
  tab_id="$(_herdr_json pane current | _jq '.result.pane.tab_id // empty' 2>/dev/null || true)"
  if [[ -n "$tab_id" ]]; then
    printf '%s' "$tab_id"
    return 0
  fi
  _focused_tab_id "$workspace_id"
}

_clear_review_state() {
  local workspace_id="$1"
  _state_update "$workspace_id" \
    '.review_tab_id = "" | .review_pane_id = "" | if .active_center_view == "review" then .active_center_view = "shell" else . end'
}

# Dock stickies onto the previous tab, then close. Native pane-close of the
# editor center has crashed Herdr; native tab-close would kill the stickies.
# Review is ephemeral (like an editor tab) and docks back to Shell.
_close_tab_id() {
  local tab_id="$1"
  local workspace_id state shell_tab review_tab dest closing_review=0
  [[ -n "$tab_id" ]] || return 0
  workspace_id="${HERDR_WORKSPACE_ID:-${tab_id%%:*}}"
  export HERDR_WORKSPACE_ID="$workspace_id"
  state="$(_state_load "$workspace_id" 2>/dev/null || true)"
  [[ -n "$state" ]] || return 0
  shell_tab="$(printf '%s' "$state" | _jq '.shell_tab_id // empty')"
  review_tab="$(printf '%s' "$state" | _jq '.review_tab_id // empty')"
  if [[ "$tab_id" == "$shell_tab" ]]; then
    return 0
  fi
  if [[ -n "$review_tab" && "$tab_id" == "$review_tab" ]]; then
    closing_review=1
  fi
  if ! _tab_exists "$workspace_id" "$tab_id"; then
    if (( closing_review )); then
      _clear_review_state "$workspace_id"
    fi
    return 0
  fi
  if (( closing_review )); then
    dest="$shell_tab"
  else
    dest="$(_tab_neighbor "$workspace_id" "$tab_id" -1)"
    if [[ -z "$dest" || "$dest" == "$tab_id" ]]; then
      dest="$shell_tab"
    fi
    if [[ -z "$dest" || "$dest" == "$tab_id" ]]; then
      dest="$review_tab"
    fi
  fi
  if [[ -z "$dest" || "$dest" == "$tab_id" ]]; then
    return 0
  fi
  _drop_editors_on_tab "$workspace_id" "$tab_id"
  _activate_tab "$dest"
  _herdr_json tab close "$tab_id" >/dev/null 2>&1 || true
  if (( closing_review )); then
    _clear_review_state "$workspace_id"
  fi
}

_close_current_tab() {
  local workspace_id tab_id
  workspace_id="$(_dev_workspace_id)"
  [[ -n "$workspace_id" ]] || return 0
  export HERDR_WORKSPACE_ID="$workspace_id"
  tab_id="$(_current_tab_id "$workspace_id")"
  _close_tab_id "$tab_id"
}

_pane_is_layout_owned() {
  local pane="$1" state="$2"
  printf '%s' "$state" | jq -e --arg pane "$pane" '
    .agent_pane_id == $pane or .sidebar_pane_id == $pane
    or .shell_pane_id == $pane or .review_pane_id == $pane' >/dev/null
}

# prefix+x on an editor center closes the tab; layout columns are left alone.
_close_focused_pane() {
  local workspace_id pane state tab_id
  workspace_id="$(_dev_workspace_id)"
  [[ -n "$workspace_id" ]] || return 0
  export HERDR_WORKSPACE_ID="$workspace_id"
  pane="$(_focused_pane_id)"
  [[ -n "$pane" ]] || return 0
  state="$(_state_load "$workspace_id" 2>/dev/null || true)"
  [[ -n "$state" ]] || return 0
  if _pane_is_layout_owned "$pane" "$state"; then
    return 0
  fi
  tab_id="$(printf '%s' "$state" | jq -r --arg pane "$pane" \
    '[(.editors // {})[] | select(.pane_id == $pane) | .tab_id][0] // empty')"
  if [[ -n "$tab_id" ]]; then
    _close_tab_id "$tab_id"
    return 0
  fi
  _herdr_json pane close "$pane" >/dev/null 2>&1 || true
}

_open_review() {
  local workspace_id workdir state review_tab review_pane
  workspace_id="$(_dev_workspace_id)"
  [[ -n "$workspace_id" ]] || return 1
  export HERDR_WORKSPACE_ID="$workspace_id"
  state="$(_state_load "$workspace_id" 2>/dev/null || true)"
  [[ -n "$state" ]] || return 1
  review_tab="$(printf '%s' "$state" | _jq '.review_tab_id // empty')"
  review_pane="$(printf '%s' "$state" | _jq '.review_pane_id // empty')"
  if [[ -n "$review_tab" ]] && _tab_exists "$workspace_id" "$review_tab" \
    && [[ -n "$review_pane" ]] && _pane_exists "$review_pane"; then
    if _pane_is_shell "$review_pane"; then
      _restart_pane_cmd "$review_pane" "$(_review_launch)"
    fi
    return 0
  fi
  workdir="$(printf '%s' "$state" | _jq '.workdir // empty')"
  workdir="${workdir:-$PWD}"
  _layout_lock_acquire "$workspace_id" || return 1
  trap '_layout_lock_release' RETURN
  state="$(_state_load "$workspace_id" 2>/dev/null || true)"
  [[ -n "$state" ]] || return 1
  review_tab="$(printf '%s' "$state" | _jq '.review_tab_id // empty')"
  if [[ -z "$review_tab" ]] || ! _tab_exists "$workspace_id" "$review_tab"; then
    review_tab="$(_create_tab "$workspace_id" "$workdir" Review)"
    [[ -n "$review_tab" ]] || return 1
  fi
  state="$(printf '%s' "$state" | jq --arg tab "$review_tab" '.review_tab_id = $tab')"
  review_pane="$(_ensure_center_pane "$workspace_id" "$workdir" "$review_tab" \
    review_pane_id center_review "$(_review_launch)" "$state")" || true
  [[ -n "$review_pane" ]] || return 1
  state="$(printf '%s' "$state" | jq --arg tab "$review_tab" --arg pane "$review_pane" \
    '.review_tab_id = $tab | .review_pane_id = $pane')"
  _state_save "$workspace_id" "$state"
  _layout_lock_release
  trap - RETURN
  return 0
}

_close_review() {
  local workspace_id state review_tab
  workspace_id="$(_dev_workspace_id)"
  [[ -n "$workspace_id" ]] || return 0
  export HERDR_WORKSPACE_ID="$workspace_id"
  state="$(_state_load "$workspace_id" 2>/dev/null || true)"
  [[ -n "$state" ]] || return 0
  review_tab="$(printf '%s' "$state" | _jq '.review_tab_id // empty')"
  [[ -n "$review_tab" ]] || return 0
  _close_tab_id "$review_tab"
}

_activate_center_view() {
  local view="$1" state tab_id
  state="$(_dev_state)" || return 0
  case "$view" in
    shell) tab_id="$(printf '%s' "$state" | _jq '.shell_tab_id // empty')" ;;
    review) tab_id="$(printf '%s' "$state" | _jq '.review_tab_id // empty')" ;;
    *) return 0 ;;
  esac
  [[ -n "$tab_id" ]] || return 0
  _activate_tab "$tab_id"
}

_pane_role() {
  local pane="$1"
  _herdr_json pane get "$pane" | _jq '.result.pane.tokens.agentic_role // empty' 2>/dev/null || true
}

_ensure_center_pane() {
  local workspace_id="$1" workdir="$2" tab_id="$3" field="$4" role="$5" launch="$6" state="$7"
  local pane
  pane="$(printf '%s' "$state" | jq -r --arg field "$field" '.[$field] // empty')"
  if ! _pane_exists "$pane" || [[ "$(_pane_tab_id "$pane")" != "$tab_id" ]]; then
    pane="$(_center_pane_on_tab "$workspace_id" "$tab_id" "$state")"
    [[ -n "$pane" ]] || return 1
    _ensure_pane_process "$pane" "$launch"
    _stamp_metadata "$pane" "$role"
    _rename_pane "$pane" "$role"
    printf '%s' "$pane"
    return 0
  fi
  if ! _ensure_pane_live "${HERDR_WORKSPACE_ID:-$workspace_id}" "$pane" "$role"; then
    _refresh_pane_identity "$pane" "$role"
  fi
  printf '%s' "$pane"
}

_ensure_agent_pane() {
  local workdir="$1" state="$2" center_pane="$3"
  local pane
  pane="$(printf '%s' "$state" | _jq '.agent_pane_id // empty')"
  if _pane_exists "$pane"; then
    printf '%s' "$pane"
    return 0
  fi
  pane="$(_split_pane "$center_pane" right "$(_agent_split_ratio)" "$workdir")"
  _herdr_json pane swap --source-pane "$pane" --target-pane "$center_pane" >/dev/null 2>&1 || true
  _stamp_metadata "$pane" agent
  _rename_pane "$pane" agent
  printf '%s' "$pane"
}

_ensure_sidebar_pane() {
  local workdir="$1" state="$2" center_pane="$3"
  local pane sidebar_bin workspace_id
  workspace_id="${HERDR_WORKSPACE_ID:-$(printf '%s' "$state" | _jq '.workspace_id // empty')}"
  pane="$(printf '%s' "$state" | _jq '.sidebar_pane_id // empty')"
  sidebar_bin="$(_sidebar_bin)"
  if _pane_exists "$pane"; then
    if ! _ensure_pane_live "$workspace_id" "$pane" sidebar; then
      _refresh_pane_identity "$pane" sidebar
    fi
    printf '%s' "$pane"
    return 0
  fi
  pane="$(_split_pane "$center_pane" right "$(_sidebar_split_ratio)" "$workdir")"
  if [[ -x "$sidebar_bin" ]]; then
    _pane_run_sidebar "$pane" "$sidebar_bin"
  else
    _pane_run_login "$pane" "echo 'sidebar binary missing: build with cargo build --release'; exec $(_login_shell) -li" || true
    _stamp_metadata "$pane" sidebar
    _rename_pane "$pane" sidebar
  fi
  printf '%s' "$pane"
}

_focused_workspace_id() {
  _herdr_json workspace list \
    | _jq '.result.workspaces[] | select(.focused == true) | .workspace_id' \
    | head -1
}

_workspace_id_by_label() {
  local label="$1"
  _herdr_json workspace list \
    | _jq --arg label "$label" '.result.workspaces[] | select(.label == $label) | .workspace_id' \
    | head -1
}

_workspace_id_by_cwd() {
  local cwd="$1" ws_id pane_cwd
  while IFS= read -r ws_id; do
    [[ -n "$ws_id" ]] || continue
    pane_cwd="$(_herdr_json pane list --workspace "$ws_id" \
      | _jq '.result.panes[0].cwd // empty' | head -1)"
    if [[ "$pane_cwd" == "$cwd" ]]; then
      printf '%s' "$ws_id"
      return 0
    fi
  done < <(_herdr_json workspace list | _jq '.result.workspaces[].workspace_id')
  return 1
}

_ensure_workspace() {
  local label="$1" workdir="$2" workspace_id
  workspace_id="$(_workspace_id_by_label "$label")"
  if [[ -z "$workspace_id" ]]; then
    workspace_id="$(_workspace_id_by_cwd "$workdir" 2>/dev/null || true)"
  fi
  if [[ -n "$workspace_id" ]]; then
    _herdr_json workspace rename "$workspace_id" "$label" >/dev/null 2>&1 || true
    printf '%s' "$workspace_id"
    return 0
  fi
  _herdr_json workspace create --cwd "$workdir" --label "$label" --no-focus \
    | _jq '.result.workspace.workspace_id'
}

_layout_ensure() {
  local label="${WT_HERDR_LABEL:-}" workdir="${WT_HERDR_WORKDIR:-}"
  local workspace_id state tabs shell_tab_id review_tab_id
  local review_pane shell_pane agent_pane sidebar_pane active_view

  if [[ -z "$label" || -z "$workdir" ]]; then
    workspace_id="${HERDR_WORKSPACE_ID:-$(_focused_workspace_id)}"
    [[ -n "$workspace_id" ]] || { echo "agentic-layout: no workspace context" >&2; exit 1; }
    state="$(_state_load "$workspace_id" 2>/dev/null || true)"
    if [[ -n "$state" ]]; then
      label="$(printf '%s' "$state" | _jq '.label // empty')"
      workdir="$(printf '%s' "$state" | _jq '.workdir')"
    else
      label="$(_herdr_json workspace get "$workspace_id" | _jq '.result.workspace.label // empty')"
      workdir="$(_herdr_json pane list --workspace "$workspace_id" \
        | _jq '.result.panes[0].cwd // empty' | head -1)"
      workdir="${workdir:-$PWD}"
      label="${label:-$workdir}"
    fi
  fi

  workspace_id="$(_ensure_workspace "$label" "$workdir")"
  export HERDR_WORKSPACE_ID="$workspace_id"
  _layout_lock_acquire "$workspace_id" || return 1
  trap '_layout_lock_release' RETURN

  state="$(_state_load "$workspace_id" 2>/dev/null || _state_init "$workspace_id" "$workdir")"
  state="$(printf '%s' "$state" | jq \
    --arg wid "$workspace_id" --arg label "$label" --arg workdir "$workdir" \
    '.workspace_id = $wid | .workdir = $workdir | .label = $label')"

  tabs="$(_ensure_shell_and_review_tabs "$workspace_id" "$workdir" "$state")"
  shell_tab_id="${tabs%%$'\t'*}"
  review_tab_id="${tabs#*$'\t'}"
  state="$(printf '%s' "$state" | jq \
    --arg shell_tab "$shell_tab_id" --arg review_tab "$review_tab_id" \
    '.shell_tab_id = $shell_tab | .review_tab_id = $review_tab')"

  shell_pane="$(_ensure_center_pane "$workspace_id" "$workdir" "$shell_tab_id" \
    shell_pane_id center_shell "$(_shell_launch)" "$state")"
  state="$(printf '%s' "$state" | jq --arg pane "$shell_pane" '.shell_pane_id = $pane')"
  agent_pane="$(_ensure_agent_pane "$workdir" "$state" "$shell_pane")"
  state="$(printf '%s' "$state" | jq --arg pane "$agent_pane" '.agent_pane_id = $pane')"
  sidebar_pane="$(_ensure_sidebar_pane "$workdir" "$state" "$shell_pane")"
  review_pane=""
  if [[ -n "$review_tab_id" ]]; then
    review_pane="$(_ensure_center_pane "$workspace_id" "$workdir" "$review_tab_id" \
      review_pane_id center_review "$(_review_launch)" "$state")" || true
  fi

  active_view="$(printf '%s' "$state" | _jq '.active_center_view // "shell"')"
  if [[ "$active_view" == "review" && -n "$review_tab_id" && -n "$review_pane" ]]; then
    :
  else
    active_view="shell"
  fi

  state="$(printf '%s' "$state" | jq \
    --arg review_tab "$review_tab_id" \
    --arg shell_tab "$shell_tab_id" \
    --arg agent "$agent_pane" \
    --arg review "$review_pane" \
    --arg shell "$shell_pane" \
    --arg sidebar "$sidebar_pane" \
    --arg view "$active_view" \
    '.review_tab_id = $review_tab
     | .shell_tab_id = $shell_tab
     | .agent_pane_id = $agent
     | .review_pane_id = $review
     | .shell_pane_id = $shell
     | .sidebar_pane_id = $sidebar
     | .active_center_view = $view')"
  _state_save "$workspace_id" "$state"
  _layout_lock_release
  trap - RETURN
  _activate_center_view "$active_view"
  printf '%s' "$state"
}
