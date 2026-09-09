# Herdr dev layout helpers for worktrunk and shell integration.
# Safe to source repeatedly — worktrunk hooks and shell reload pick up updates.

HERDR="${HERDR_BIN_PATH:-herdr}"
PLUGIN_ID="agentic-dev.layout"

_wt_herdr_server_running() {
  "$HERDR" status server 2>/dev/null | grep -q '^status: running'
}

_wt_herdr_ensure_server() {
  _wt_herdr_server_running && return 0
  "$HERDR" status >/dev/null 2>&1 || true
  _wt_herdr_server_running
}

_wt_realpath() {
  local path="$1"
  (cd "$path" 2>/dev/null && pwd -P) || printf '%s' "$path"
}

_wt_git_main_worktree() {
  local workdir="$1"
  git -C "$workdir" worktree list --porcelain 2>/dev/null \
    | awk '/^worktree / { print substr($0, 10); exit }'
}

_wt_herdr_workspace_id_by_label() {
  local label="$1"
  "$HERDR" workspace list 2>/dev/null \
    | jq -r --arg label "$label" '.result.workspaces[] | select(.label == $label) | .workspace_id' \
    | head -1
}

_wt_herdr_workspace_id_by_cwd() {
  local cwd="$1"
  local want ws_id pane_cwd
  want="$(_wt_realpath "$cwd")"
  while IFS= read -r ws_id; do
    [[ -n "$ws_id" ]] || continue
    pane_cwd="$("$HERDR" pane list --workspace "$ws_id" 2>/dev/null \
      | jq -r '.result.panes[0].cwd // empty' | head -1)"
    [[ -n "$pane_cwd" ]] || continue
    if [[ "$(_wt_realpath "$pane_cwd")" == "$want" ]]; then
      printf '%s' "$ws_id"
      return 0
    fi
  done < <("$HERDR" workspace list 2>/dev/null | jq -r '.result.workspaces[].workspace_id')
  return 1
}

_wt_in_herdr() {
  [[ -n "${HERDR_ENV:-}" || -n "${HERDR_PANE_ID:-}" ]]
}

_wt_generate_session_name() {
  local worktree_path="$1"
  local worktree_name repo_name branch

  worktree_name=$(basename "$worktree_path")

  if [[ "$worktree_name" == *.* ]]; then
    repo_name=$(echo "$worktree_name" | sed 's/\.[a-zA-Z0-9_-]*$//' | awk '{print toupper(substr($0,1,1)) tolower(substr($0,2))}')
    branch=$(echo "$worktree_name" | sed 's/^[^.]*\.//' | awk '{print toupper(substr($0,1,1)) tolower(substr($0,2))}')
  else
    repo_name=$(echo "$worktree_name" | awk '{print toupper(substr($0,1,1)) tolower(substr($0,2))}')
    branch=$(cd "$worktree_path" && git branch --show-current 2>/dev/null | awk '{print toupper(substr($0,1,1)) tolower(substr($0,2))}')
  fi

  echo "${branch}_${repo_name}"
}

_wt_herdr_focused_workspace_id() {
  "$HERDR" workspace list 2>/dev/null \
    | jq -r '.result.workspaces[] | select(.focused == true) | .workspace_id' \
    | head -1
}

# Keep whatever workspace the user is viewing. Never focus the child, and never
# restore to this helper's own pane (HERDR_WORKSPACE_ID) if the user is elsewhere.
_wt_herdr_keep_user_focus() {
  local want="$1"
  local now
  [[ -n "$want" ]] || return 0
  now="$(_wt_herdr_focused_workspace_id)"
  [[ "$now" != "$want" ]] || return 0
  "$HERDR" workspace focus "$want" >/dev/null 2>&1 || true
}

_wt_herdr_focus_workspace() {
  local label="$1"
  local workdir="${2:-}"
  local workspace_id

  _wt_herdr_ensure_server || return 1
  workspace_id="$(_wt_herdr_workspace_id_by_label "$label")"
  if [[ -z "$workspace_id" && -n "$workdir" ]]; then
    workspace_id="$(_wt_herdr_workspace_id_by_cwd "$workdir" 2>/dev/null || true)"
  fi
  if [[ -n "$workspace_id" ]]; then
    "$HERDR" workspace focus "$workspace_id" >/dev/null
    return 0
  fi
  return 1
}

_wt_is_linked_worktree() {
  local workdir="$1" main_path
  [[ -d "$workdir" ]] || return 1
  main_path="$(_wt_git_main_worktree "$workdir")"
  [[ -n "$main_path" ]] || return 1
  [[ "$(_wt_realpath "$workdir")" != "$(_wt_realpath "$main_path")" ]]
}

_wt_herdr_workspace_id_from_worktree_path() {
  local workdir="$1"
  local want
  want="$(_wt_realpath "$workdir")"
  "$HERDR" worktree list --cwd "$workdir" 2>/dev/null \
    | jq -r --arg want "$want" '
        .result.worktrees[]?
        | select((.path // "") != "")
        | select(.path == $want or (.path | sub("/$"; "")) == $want)
        | .open_workspace_id // empty
      ' \
    | head -1
}

# Linked checkouts: worktree open/create only — never flat workspace create.
# `worktree open --path` still uses the focused workspace as the source unless
# --cwd/--workspace is set; a non-git focused workspace returns not_git_worktree.
_wt_herdr_json_workspace_id() {
  printf '%s' "$1" | jq -r '.result.workspace.workspace_id // empty' 2>/dev/null || true
}

_wt_herdr_json_error() {
  printf '%s' "$1" | jq -r '.error.message // empty' 2>/dev/null || true
}

_wt_herdr_resolve_linked_workspace() {
  local label="$1"
  local workdir="$2"
  local main_root branch workspace_id out err

  workspace_id="$(_wt_herdr_workspace_id_from_worktree_path "$workdir")"
  if [[ -n "$workspace_id" ]]; then
    printf '%s' "$workspace_id"
    return 0
  fi

  main_root="$(_wt_git_main_worktree "$workdir")"
  branch="$(git -C "$workdir" branch --show-current 2>/dev/null || true)"
  if [[ -z "$main_root" ]]; then
    echo "Cannot resolve main repo for linked worktree: $workdir" >&2
    return 1
  fi

  out="$("$HERDR" worktree open --cwd "$main_root" --path "$workdir" --label "$label" --no-focus)" || true
  workspace_id="$(_wt_herdr_json_workspace_id "$out")"
  if [[ -n "$workspace_id" ]]; then
    printf '%s' "$workspace_id"
    return 0
  fi
  err="$(_wt_herdr_json_error "$out")"
  [[ -z "$err" ]] || echo "herdr worktree open: $err" >&2

  if [[ -z "$branch" ]]; then
    echo "Cannot resolve branch for linked worktree: $workdir" >&2
    return 1
  fi

  out="$("$HERDR" worktree create \
    --cwd "$main_root" \
    --branch "$branch" \
    --path "$workdir" \
    --label "$label" \
    --no-focus)" || true
  workspace_id="$(_wt_herdr_json_workspace_id "$out")"
  if [[ -n "$workspace_id" ]]; then
    printf '%s' "$workspace_id"
    return 0
  fi
  err="$(_wt_herdr_json_error "$out")"
  [[ -z "$err" ]] || echo "herdr worktree create: $err" >&2

  echo "Failed to open/create Herdr worktree subspace for: $workdir" >&2
  return 1
}

_wt_herdr_resolve_workspace() {
  local label="$1"
  local workdir="$2"
  local workspace_id

  workspace_id="$(_wt_herdr_workspace_id_by_label "$label")"
  if [[ -z "$workspace_id" ]]; then
    workspace_id="$(_wt_herdr_workspace_id_by_cwd "$workdir" 2>/dev/null || true)"
  fi

  if [[ -z "$workspace_id" ]]; then
    if _wt_is_linked_worktree "$workdir"; then
      workspace_id="$(_wt_herdr_resolve_linked_workspace "$label" "$workdir")" || return 1
    else
      workspace_id="$("$HERDR" workspace create --cwd "$workdir" --label "$label" --no-focus \
        | jq -r '.result.workspace.workspace_id // empty')"
    fi
  fi

  [[ -n "$workspace_id" ]] || {
    echo "Failed to resolve Herdr workspace '$label' for $workdir" >&2
    return 1
  }

  "$HERDR" workspace rename "$workspace_id" "$label" >/dev/null 2>&1 || true
  printf '%s' "$workspace_id"
}

# `herdr plugin action invoke` replaces the plugin env with the focused workspace.
# Run the plugin script directly so the child id/label/path and prompt survive.
_wt_herdr_plugin_root() {
  local registry root id
  if [[ -n "${WT_HERDR_PLUGIN_ROOT:-}" ]]; then
    if [[ -f "${WT_HERDR_PLUGIN_ROOT}/layout.sh" ]]; then
      printf '%s' "$WT_HERDR_PLUGIN_ROOT"
      return 0
    fi
  fi
  registry="${XDG_CONFIG_HOME:-$HOME/.config}/herdr/plugins.json"
  [[ -f "$registry" ]] || return 1
  id="$PLUGIN_ID"
  root="$(jq -r --arg id "$id" \
    '.[] | select(.plugin_id == $id) | .plugin_root // .source.managed_path // empty' \
    "$registry" | head -1)"
  if [[ -n "$root" && -f "$root/layout.sh" ]]; then
    printf '%s' "$root"
    return 0
  fi
  # Leftover agentic-dev.dev-layout registrations that actually point at this
  # plugin (a tree with layout.sh) still count.
  root="$(jq -r \
    '.[] | select(.plugin_id == "agentic-dev.dev-layout") | .plugin_root // .source.managed_path // empty' \
    "$registry" | head -1)"
  if [[ -n "$root" && -f "$root/layout.sh" ]]; then
    printf '%s' "$root"
    return 0
  fi
  return 1
}

_wt_herdr_invoke_plugin() {
  local action="$1"
  local workspace_id="$2"
  local label="$3"
  local workdir="$4"
  local root
  root="$(_wt_herdr_plugin_root)" || {
    echo "Cannot find $PLUGIN_ID plugin root; cannot $action layout for workspace ${workspace_id:-unknown}" >&2
    return 1
  }
  WT_HERDR_LABEL="$label" \
    WT_HERDR_WORKDIR="$workdir" \
    WT_HERDR_NO_ATTACH="${WT_HERDR_NO_ATTACH:-}" \
    WT_HERDR_AGENT_CMD="${WT_HERDR_AGENT_CMD:-}" \
    WT_HERDR_AGENT_PROMPT_FILE="${WT_HERDR_AGENT_PROMPT_FILE:-}" \
    HERDR_WORKSPACE_ID="$workspace_id" \
    HERDR_PLUGIN_ROOT="$root" \
    HERDR_BIN_PATH="${HERDR_BIN_PATH:-$HERDR}" \
    bash "$root/layout.sh" "$action"
}

wt_herdr_layout_create() {
  local label="$1"
  local workdir="$2"
  local workspace_id keep_focus rc=0

  _wt_herdr_ensure_server || {
    echo "Herdr server is not running. Start it with: herdr" >&2
    return 1
  }

  # Prefer the caller's workspace (handoff-spawn sets WT_HERDR_KEEP_FOCUS to
  # the parent pane's HERDR_WORKSPACE_ID). "currently focused" is already the
  # child if wt/post-start stole focus.
  keep_focus="${WT_HERDR_KEEP_FOCUS:-$(_wt_herdr_focused_workspace_id)}"
  workspace_id="$(_wt_herdr_resolve_workspace "$label" "$workdir")" || {
    _wt_herdr_keep_user_focus "$keep_focus"
    return 1
  }
  if ! WT_HERDR_NO_ATTACH=1 _wt_herdr_invoke_plugin create "$workspace_id" "$label" "$workdir"; then
    echo "Failed to create $PLUGIN_ID layout for workspace $workspace_id" >&2
    rc=1
  fi
  _wt_herdr_keep_user_focus "$keep_focus"
  return "$rc"
}

# Clear session of the configured agent (d / dev / apply). Ignores any
# inherited handoff prompt file.
wt_herdr_start_default_agent() {
  local label="$1"
  local workdir="$2"
  local workspace_id keep_focus rc=0

  _wt_herdr_ensure_server || {
    echo "Herdr server is not running. Start it with: herdr" >&2
    return 1
  }

  keep_focus="${WT_HERDR_KEEP_FOCUS:-$(_wt_herdr_focused_workspace_id)}"
  workspace_id="$(_wt_herdr_resolve_workspace "$label" "$workdir")" || {
    _wt_herdr_keep_user_focus "$keep_focus"
    return 1
  }
  if ! WT_HERDR_NO_ATTACH=1 WT_HERDR_AGENT_PROMPT_FILE= \
    _wt_herdr_invoke_plugin start-agent "$workspace_id" "$label" "$workdir"; then
    echo "Failed to start agent in workspace $workspace_id" >&2
    rc=1
  fi
  _wt_herdr_keep_user_focus "$keep_focus"
  return "$rc"
}

# Orchestrator / handoff-spawn: start or replace the agent with WT_HERDR_AGENT_PROMPT_FILE.
wt_herdr_handoff_agent() {
  local label="$1"
  local workdir="$2"
  local workspace_id keep_focus rc=0

  _wt_herdr_ensure_server || {
    echo "Herdr server is not running. Start it with: herdr" >&2
    return 1
  }
  if [[ -z "${WT_HERDR_AGENT_PROMPT_FILE:-}" ]]; then
    echo "wt_herdr_handoff_agent requires WT_HERDR_AGENT_PROMPT_FILE" >&2
    return 1
  fi

  keep_focus="${WT_HERDR_KEEP_FOCUS:-$(_wt_herdr_focused_workspace_id)}"
  workspace_id="$(_wt_herdr_resolve_workspace "$label" "$workdir")" || {
    _wt_herdr_keep_user_focus "$keep_focus"
    return 1
  }
  if ! WT_HERDR_NO_ATTACH=1 _wt_herdr_invoke_plugin handoff-agent "$workspace_id" "$label" "$workdir"; then
    echo "Failed to hand off agent in workspace $workspace_id" >&2
    rc=1
  fi
  _wt_herdr_keep_user_focus "$keep_focus"
  return "$rc"
}

# Backward-compatible alias: prompted start when a prompt file is set, else clear.
wt_herdr_start_agent() {
  if [[ -n "${WT_HERDR_AGENT_PROMPT_FILE:-}" ]]; then
    wt_herdr_handoff_agent "$@"
  else
    wt_herdr_start_default_agent "$@"
  fi
}

wt_herdr_layout_apply() {
  local workdir="${1:-$PWD}"
  local label="${2:-}"
  local workspace_id

  _wt_herdr_ensure_server || return 1

  if _wt_in_herdr && [[ -n "${HERDR_WORKSPACE_ID:-}" ]]; then
    workspace_id="$HERDR_WORKSPACE_ID"
    label="$("$HERDR" workspace get "$workspace_id" 2>/dev/null \
      | jq -r '.result.workspace.label // empty')"
  fi

  if [[ -z "$label" ]]; then
    label="$(_wt_generate_session_name "$workdir" 2>/dev/null || basename "$workdir")"
  fi

  workspace_id="${workspace_id:-$(_wt_herdr_workspace_id_by_label "$label")}"
  [[ -n "$workspace_id" ]] || workspace_id="$(_wt_herdr_workspace_id_by_cwd "$workdir" 2>/dev/null || true)"

  if ! _wt_herdr_invoke_plugin apply "${workspace_id:-}" "$label" "$workdir"; then
    echo "Failed to apply $PLUGIN_ID layout for workspace ${workspace_id:-unknown}" >&2
    return 1
  fi
}

wt_herdr_layout_close() {
  local label="$1"
  local workspace_id

  _wt_herdr_ensure_server || return 0
  workspace_id="$(_wt_herdr_workspace_id_by_label "$label")"
  [[ -n "$workspace_id" ]] || return 0

  # Close this worktree workspace only. Herdr 0.9 refuses to close a primary
  # while linked children are open unless `--group` is passed; wtd/remove
  # always target the child, so a bare close is correct.
  "$HERDR" workspace close "$workspace_id" >/dev/null 2>&1 || true
}

wt_herdr_attach() {
  local worktree_path="$1"
  local session_name

  session_name="$(_wt_generate_session_name "$worktree_path")"
  wt_herdr_layout_create "$session_name" "$worktree_path"
  wt_herdr_start_default_agent "$session_name" "$worktree_path" || true
  _wt_herdr_focus_workspace "$session_name" "$worktree_path" || true

  if [[ -n "${HERDR_ENV:-}" || -n "${HERDR_PANE_ID:-}" ]]; then
    return 0
  fi

  if [[ -z "${WT_HERDR_NO_ATTACH:-}" ]]; then
    "$HERDR"
  fi
}
