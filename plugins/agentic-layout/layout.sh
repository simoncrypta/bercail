#!/usr/bin/env bash
# Agentic three-column Herdr layout: agent | review/shell | sidebar.
# shellcheck disable=SC1091
set -euo pipefail

HERDR="${HERDR_BIN_PATH:-herdr}"
METADATA_SOURCE="agentic-dev.layout"

_plugin_root() {
  if [[ -n "${HERDR_PLUGIN_ROOT:-}" ]]; then
    printf '%s' "$HERDR_PLUGIN_ROOT"
  else
    cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
  fi
}

PLUGIN_ROOT="$(_plugin_root)"

_layout_core() {
  local bin="${PLUGIN_ROOT}/target/release/herdr-layout"
  [[ -x "$bin" ]] || bin="${PLUGIN_ROOT}/target/debug/herdr-layout"
  if [[ ! -x "$bin" ]]; then
    printf 'agentic-layout: herdr-layout binary missing (cargo build --release -p herdr-sidebar)\n' >&2
    return 127
  fi
  "$bin" "$@"
}

_herdr_json() {
  "$HERDR" "$@" 2>/dev/null
}

_jq() {
  jq -r "$@"
}

# shellcheck source=config-reader.sh
source "$PLUGIN_ROOT/config-reader.sh"
# shellcheck source=state.sh
source "$PLUGIN_ROOT/state.sh"

_agent_cmd() {
  if declare -F agentic_dev_agent_command >/dev/null 2>&1; then
    agentic_dev_agent_command
  else
    printf '%s' "cursor-agent"
  fi
}

_file_editor() {
  if declare -F agentic_dev_layout_file_editor >/dev/null 2>&1; then
    agentic_dev_layout_file_editor
  elif declare -F agentic_dev_default_file_editor >/dev/null 2>&1; then
    agentic_dev_default_file_editor
  else
    printf '%s' "${EDITOR:-${VISUAL:-vi}}"
  fi
}

# Column shares of the full tab: agent 5/12, center 5/12, sidebar 1/6.
_agent_ratio() {
  if declare -F agentic_dev_layout_agent_ratio >/dev/null 2>&1; then
    agentic_dev_layout_agent_ratio
  else
    printf '%s' "0.416667"
  fi
}

_sidebar_ratio() {
  if declare -F agentic_dev_layout_sidebar_ratio >/dev/null 2>&1; then
    agentic_dev_layout_sidebar_ratio
  else
    printf '%s' "0.166667"
  fi
}

_layout_geometry() {
  jq -n --argjson agent "$(_agent_ratio)" --argjson sidebar "$(_sidebar_ratio)" \
    '{agent_ratio:$agent, sidebar_ratio:$sidebar}' | _layout_core --split-ratios
}

_agent_split_ratio() {
  _layout_geometry | jq -r '.agent_split'
}

_sidebar_split_ratio() {
  _layout_geometry | jq -r '.sidebar_split'
}

_agent_move_ratio() {
  _layout_geometry | jq -r '.agent_move'
}

_id_after_move() {
  local json="$1" fallback="$2" id
  id="$(printf '%s' "${json:-{}}" | _jq '.result.move_result.pane.pane_id // .result.pane.pane_id // empty' 2>/dev/null || true)"
  if [[ -n "$id" && "$id" != "null" ]]; then
    printf '%s' "$id"
  else
    printf '%s' "$fallback"
  fi
}

# Herdr plugin events wrap the payload in `.data` (0.8+). Older builds used a
# top-level field; keep that one fallback.
_event_id() {
  local field="$1"
  printf '%s' "${HERDR_PLUGIN_EVENT_JSON:-{}}" | jq -r --arg f "$field" \
    '.data[$f] // .[$f] // empty' \
    2>/dev/null || true
}

_review_cmd() {
  if declare -F agentic_dev_layout_review >/dev/null 2>&1; then
    agentic_dev_layout_review
  else
    printf '%s' "hunk diff"
  fi
}

# Upstream/main used to detect "this branch has commits to review".
# Skip refs that are the current branch (do not diff main against main).
_review_merge_base() {
  local workdir="$1" head short ref
  [[ -n "$workdir" ]] || return 1
  head="$(git -C "$workdir" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  for ref in origin/main origin/master main master; do
    git -C "$workdir" rev-parse --verify --quiet "$ref^{commit}" >/dev/null 2>&1 || continue
    short="${ref#origin/}"
    [[ "$head" == "$short" ]] && continue
    printf '%s' "$ref"
    return 0
  done
  return 1
}

# Open Review when there is a PR-shaped diff: untracked/uncommitted files,
# or the working tree differs from origin/main / main.
_review_should_open() {
  local workdir="$1" base
  if ! git -C "$workdir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    return 0
  fi
  [[ -n "$(git -C "$workdir" status --porcelain 2>/dev/null)" ]] && return 0
  base="$(_review_merge_base "$workdir")" || return 1
  ! git -C "$workdir" diff --quiet "$base" -- 2>/dev/null
}

_review_auto_enabled() {
  if declare -F agentic_dev_layout_auto_review >/dev/null 2>&1; then
    [[ "$(agentic_dev_layout_auto_review)" == "true" ]]
  else
    return 0
  fi
}

_review_workdir() {
  local state workdir
  if [[ -n "${1:-}" ]]; then
    printf '%s' "$1"
    return 0
  fi
  if [[ -n "${HERDR_WORKSPACE_ID:-}" ]]; then
    state="$(_state_load "$HERDR_WORKSPACE_ID" 2>/dev/null || true)"
    workdir="$(printf '%s' "${state:-}" | _jq '.workdir // empty')"
    [[ -n "$workdir" ]] && { printf '%s' "$workdir"; return 0; }
  fi
  printf '%s' "$PWD"
}

# Feature branch: working tree vs origin/main / main (committed + uncommitted).
# On main with no PR base: working tree only, including untracked.
_review_hunk_cmd() {
  local workdir="$1" base
  base="$(_review_merge_base "$workdir" || true)"
  if [[ -n "$base" ]]; then
    printf '%s' "hunk diff ${base} --watch --agent-notes"
    return 0
  fi
  printf '%s' "hunk diff --watch --agent-notes"
}

# On-demand Review is a hunk session. Always watch so comments stream.
# --agent-notes keeps AI vs human comments visible in the TUI.
_review_launch() {
  local cmd workdir
  cmd="$(_review_cmd)"
  workdir="$(_review_workdir "${1:-}")"
  case "$cmd" in
    hunk|"hunk diff")
      _review_hunk_cmd "$workdir"
      ;;
    hunk\ diff*)
      [[ "$cmd" == *"--watch"* ]] || cmd="$cmd --watch"
      if [[ "$cmd" != *"--agent-notes"* && "$cmd" != *"--no-agent-notes"* ]]; then
        cmd="$cmd --agent-notes"
      fi
      printf '%s' "$cmd"
      ;;
    *)
      printf '%s' "$cmd"
      ;;
  esac
}

_sidebar_bin() {
  local root="$PLUGIN_ROOT" candidate
  for candidate in "$root/target/release/herdr-sidebar" "$root/bin/herdr-sidebar"; do
    if [[ -x "$candidate" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  printf '%s' "$root/target/release/herdr-sidebar"
}

_login_shell() {
  local shell="${SHELL:-}" resolved
  if [[ -n "$shell" && -x "$shell" ]]; then
    printf '%s' "$shell"
    return 0
  fi
  if [[ -n "$shell" ]]; then
    resolved="$(command -v "$shell" 2>/dev/null || true)"
    if [[ -n "$resolved" && -x "$resolved" ]]; then
      printf '%s' "$resolved"
      return 0
    fi
  fi
  if [[ "$(uname -s)" == Darwin && -x /bin/zsh ]]; then
    printf '%s' "/bin/zsh"
    return 0
  fi
  printf '%s' "bash"
}

# shellcheck source=lifecycle.sh
source "$PLUGIN_ROOT/lifecycle.sh"
# shellcheck source=topology.sh
source "$PLUGIN_ROOT/topology.sh"

_dev_workspace_id() {
  if [[ -n "${HERDR_WORKSPACE_ID:-}" ]]; then
    printf '%s' "$HERDR_WORKSPACE_ID"
    return 0
  fi
  _focused_workspace_id
}

_dev_state() {
  local workspace_id
  workspace_id="$(_dev_workspace_id)"
  [[ -n "$workspace_id" ]] || return 1
  _state_load "$workspace_id"
}

_select_center() {
  local view="$1" state
  state="$(_dev_state)" || state="$(_layout_ensure)"
  if [[ -z "$state" ]]; then
    return 0
  fi
  if [[ "$view" == review ]]; then
    _open_review || return 1
  fi
  _activate_center_view "$view"
}

_focus_agent() {
  local state agent_pane view
  state="$(_dev_state)" || state="$(_layout_ensure)"
  [[ -n "$state" ]] || return 0
  view="$(printf '%s' "$state" | _jq '.active_center_view // "shell"')"
  _activate_center_view "$view"
  agent_pane="$(printf '%s' "$state" | _jq '.agent_pane_id // empty')"
  if ! _pane_exists "$agent_pane"; then
    state="$(_layout_ensure)"
    agent_pane="$(printf '%s' "$state" | _jq '.agent_pane_id // empty')"
  fi
  if _pane_exists "$agent_pane" && _pane_is_shell "$agent_pane"; then
    _launch_agent_on_pane "$agent_pane" || true
  fi
  if _pane_exists "$agent_pane"; then
    _herdr_json agent focus "$agent_pane" >/dev/null 2>&1 \
      || _herdr_json pane focus "$agent_pane" >/dev/null 2>&1 \
      || true
  fi
}

_refresh_review() {
  local state review
  _select_center review
  state="$(_dev_state)" || return 0
  review="$(printf '%s' "$state" | _jq '.review_pane_id // empty')"
  [[ -n "$review" ]] && _pane_exists "$review" || return 0
  _restart_pane_cmd "$review" "$(_review_launch)"
}

_toggle_sidebar() {
  local state sidebar
  state="$(_dev_state)" || return 0
  sidebar="$(printf '%s' "$state" | _jq '.sidebar_pane_id // empty')"
  [[ -n "$sidebar" ]] || return 0
  _activate_center_view "$(printf '%s' "$state" | _jq '.active_center_view // "shell"')"
  _herdr_json pane zoom "$sidebar" --toggle >/dev/null 2>&1 || true
}

_sidebar_send_key() {
  local key="$1" state sidebar
  state="$(_dev_state)" || return 0
  sidebar="$(printf '%s' "$state" | _jq '.sidebar_pane_id // empty')"
  [[ -n "$sidebar" ]] || return 0
  _activate_center_view "$(printf '%s' "$state" | _jq '.active_center_view // "shell"')"
  _herdr_json pane send-keys "$sidebar" "$key" >/dev/null 2>&1 || true
}

_select_sidebar_view() {
  local view="$1" key="$2" workspace_id
  _sidebar_send_key "$key"
  workspace_id="$(_dev_workspace_id)"
  [[ -n "$workspace_id" ]] || return 0
  _state_update "$workspace_id" --arg view "$view" '.active_sidebar_view = $view'
}

_select_files() {
  _select_sidebar_view files 1
}

_select_source_control() {
  _select_sidebar_view source_control 2
}

_abs_path() {
  local path="$1"
  if [[ "$path" != /* ]]; then
    path="$(cd "$(dirname "$path")" 2>/dev/null && pwd)/$(basename "$path")"
  fi
  printf '%s' "$path"
}

_editor_launch_cmd() {
  local path="$1"
  printf '%s %s' "$(_file_editor)" "$(printf '%q' "$path")"
}

_open_editor() {
  local path="${1:-${AGENTIC_OPEN_PATH:-}}"
  local state workspace_id pane tab_id tab_label existing cwd
  [[ -n "$path" ]] || { echo "agentic-layout: open-editor requires a path" >&2; return 1; }
  path="$(_abs_path "$path")"
  [[ -e "$path" ]] || { echo "agentic-layout: open-editor path not found: $path" >&2; return 1; }
  state="$(_dev_state)" || state="$(_layout_ensure)"
  workspace_id="$(printf '%s' "$state" | _jq '.workspace_id')"
  existing="$(printf '%s' "$state" | jq -r --arg path "$path" '.editors[$path].pane_id // empty')"
  if [[ -n "$existing" ]] && _pane_exists "$existing"; then
    tab_id="$(printf '%s' "$state" | jq -r --arg path "$path" '.editors[$path].tab_id // empty')"
    [[ -n "$tab_id" ]] && _activate_tab "$tab_id"
    return 0
  fi
  cwd="$(dirname "$path")"
  tab_label="$(basename "$path")"
  tab_id="$(_herdr_json tab create --workspace "$workspace_id" --label "$tab_label" --cwd "$cwd" --no-focus \
    | _jq '.result.tab.tab_id')"
  [[ -n "$tab_id" && "$tab_id" != "null" ]] || {
    echo "agentic-layout: failed to create editor tab for $path" >&2
    return 1
  }
  pane="$(_pane_on_tab "$workspace_id" "$tab_id")"
  [[ -n "$pane" ]] || {
    echo "agentic-layout: editor tab $tab_id has no pane" >&2
    return 1
  }
  _pane_run_login "$pane" "$(_editor_launch_cmd "$path")"
  _stamp_metadata "$pane" editor "agentic_path=$(basename "$path")"
  _rename_pane "$pane" editor
  _state_update "$workspace_id" --arg path "$path" --arg tab "$tab_id" --arg pane "$pane" \
    '.editors[$path] = {tab_id: $tab, pane_id: $pane}'
  _activate_tab "$tab_id"
}

_on_pane_exited() {
  local pane_id="${1:-}" path workspace_id close_tab close_ws
  [[ -n "$pane_id" ]] || return 0
  close_tab=""
  close_ws=""
  shopt -s nullglob
  for path in "$(_state_dir)"/*.json; do
    [[ -f "$path" ]] || continue
    workspace_id="${path##*/}"
    workspace_id="${workspace_id%.json}"
    if [[ -z "$close_tab" ]]; then
      close_tab="$(jq -r --arg pane "$pane_id" '
        [(.editors // {})[] | select(.pane_id == $pane) | .tab_id][0] //
        (if .review_pane_id == $pane then .review_tab_id else empty end)
      ' "$path" 2>/dev/null || true)"
      if [[ -n "$close_tab" ]]; then
        close_ws="$workspace_id"
      fi
    fi
    _state_update "$workspace_id" --arg pane "$pane_id" '
      if .agent_pane_id == $pane then .agent_pane_id = "" else . end
      | if .review_pane_id == $pane then .review_pane_id = "" else . end
      | if .shell_pane_id == $pane then .shell_pane_id = "" else . end
      | if .sidebar_pane_id == $pane then .sidebar_pane_id = "" else . end
      | .editors = ((.editors // {}) | to_entries | map(select(.value.pane_id != $pane)) | from_entries)'
  done
  shopt -u nullglob
  if [[ -n "$close_tab" && -n "$close_ws" ]]; then
    export HERDR_WORKSPACE_ID="$close_ws"
    _close_tab_id "$close_tab"
  fi
}

_on_workspace_closed() {
  local workspace_id="${1:-}"
  [[ -n "$workspace_id" ]] || return 0
  _state_delete "$workspace_id"
}

_on_tab_focused() {
  local tab_id="${1:-}" workspace_id
  [[ -n "$tab_id" ]] || return 0
  workspace_id="$(_event_id workspace_id)"
  [[ -n "$workspace_id" ]] && export HERDR_WORKSPACE_ID="$workspace_id"
  _activate_tab "$tab_id" 1
}

# Open hunk when the layout agent pane finishes a turn (`done`). Idle is too
# noisy (includes never-started). Skip empty trees (unless the working tree
# differs from origin/main / main) and debounce. auto_review=false disables this.
_on_agent_status_changed() {
  local status pane workspace_id state agent workdir now last focused
  status="$(_event_id agent_status)"
  pane="$(_event_id pane_id)"
  workspace_id="$(_event_id workspace_id)"
  [[ "$status" == "done" ]] || return 0
  _review_auto_enabled || return 0
  [[ -n "$pane" && -n "$workspace_id" ]] || return 0
  export HERDR_WORKSPACE_ID="$workspace_id"
  state="$(_state_load "$workspace_id" 2>/dev/null || true)"
  [[ -n "$state" ]] || return 0
  agent="$(printf '%s' "$state" | _jq '.agent_pane_id // empty')"
  [[ "$pane" == "$agent" ]] || return 0
  now="$(_unix_now)"
  last="$(printf '%s' "$state" | _jq '.last_auto_review_unix // 0')"
  if [[ "$last" =~ ^[0-9]+$ ]] && (( now - last < 15 && last > 0 )); then
    return 0
  fi
  workdir="$(printf '%s' "$state" | _jq '.workdir // empty')"
  workdir="${workdir:-$PWD}"
  _review_should_open "$workdir" || return 0
  _state_update "$workspace_id" --argjson now "$now" '.last_auto_review_unix = $now' || true
  _open_review || return 0
  focused="$(_focused_workspace_id)"
  if [[ "$focused" == "$workspace_id" ]]; then
    _activate_center_view review
  fi
}

_resolve_context() {
  local focused
  if [[ -n "${WT_HERDR_LABEL:-}" && -n "${WT_HERDR_WORKDIR:-}" ]]; then
    return 0
  fi
  if [[ -n "${HERDR_WORKSPACE_ID:-}" ]]; then
    return 0
  fi
  focused="$(_focused_workspace_id)"
  [[ -n "$focused" ]] && export HERDR_WORKSPACE_ID="$focused"
}

main() {
  local cmd="${1:-}"
  [[ -n "$cmd" ]] || cmd="${HERDR_PLUGIN_ACTION_ID:-}"
  [[ -n "$cmd" ]] || cmd="${HERDR_PLUGIN_EVENT:-}"

  case "$cmd" in
    create)
      _resolve_context
      _layout_ensure
      if [[ -z "${WT_HERDR_NO_ATTACH:-}" ]]; then
        _select_center shell
      fi
      ;;
    apply)
      _resolve_context
      state="$(_layout_ensure)"
      pane="$(printf '%s' "$state" | _jq '.sidebar_pane_id // empty')"
      _restart_sidebar_pane "$pane"
      if [[ -z "${WT_HERDR_NO_ATTACH:-}" ]]; then
        _select_center shell
      fi
      ;;
    start-agent|start_agent)
      _resolve_context
      _start_agent
      ;;
    startup) _on_startup ;;
    focus-agent|focus_agent)
      _resolve_context
      _focus_agent
      ;;
    select-review|select_review)
      _resolve_context
      _select_center review
      ;;
    close-review|close_review)
      _resolve_context
      _close_review
      ;;
    refresh-review|refresh_review)
      _resolve_context
      _refresh_review
      ;;
    select-shell|select_terminal)
      _resolve_context
      _select_center shell
      ;;
    toggle-sidebar)
      _resolve_context
      _toggle_sidebar
      ;;
    select-files|select_files|select-explorer|select_explorer)
      _resolve_context
      _select_files
      ;;
    select-source-control)
      _resolve_context
      _select_source_control
      ;;
    open-editor)
      _resolve_context
      _open_editor "${2:-}"
      ;;
    close-tab|close_tab)
      _resolve_context
      _close_current_tab
      ;;
    close-pane|close_pane)
      _resolve_context
      _close_focused_pane
      ;;
    select-tab|select_tab)
      _resolve_context
      _select_tab_number "${2:-1}"
      ;;
    select-tab-*|select_tab_*)
      _resolve_context
      _select_tab_number "${cmd##*[-_]}"
      ;;
    select-prev-tab|select_prev_tab)
      _resolve_context
      _select_tab_relative -1
      ;;
    select-next-tab|select_next_tab)
      _resolve_context
      _select_tab_relative 1
      ;;
    event-pane-exited|event_pane_exited|pane.exited)
      _on_pane_exited "$(_event_id pane_id)"
      ;;
    event-workspace-closed|event_workspace_closed|workspace.closed)
      _on_workspace_closed "$(_event_id workspace_id)"
      ;;
    event-tab-focused|event_tab_focused|tab.focused)
      _on_tab_focused "$(_event_id tab_id)"
      ;;
    event-agent-status|event_agent_status|pane.agent_status_changed)
      _on_agent_status_changed
      ;;
    *)
      echo "agentic-layout: unknown command '$cmd'" >&2
      exit 1
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
