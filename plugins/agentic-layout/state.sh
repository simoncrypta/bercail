# Durable per-workspace layout state. Sourced from layout.sh.
# Schema v4: shell + review tabs, four panes, no main_tab_id.

STATE_VERSION=4

_state_dir() {
  if [[ -n "${HERDR_PLUGIN_STATE_DIR:-}" ]]; then
    printf '%s' "$HERDR_PLUGIN_STATE_DIR"
    return 0
  fi
  printf '%s' "${XDG_STATE_HOME:-${HOME}/.local/state}/herdr/plugins/agentic-dev.layout"
}

_state_path() {
  local workspace_id="$1"
  mkdir -p "$(_state_dir)"
  printf '%s/%s.json' "$(_state_dir)" "$workspace_id"
}

_has_flock() {
  command -v flock >/dev/null 2>&1
}

_layout_lock_acquire() {
  local workspace_id="$1"
  local lockfile lockdir waited pid
  if [[ "${LAYOUT_LOCK_WORKSPACE:-}" == "$workspace_id" ]]; then
    LAYOUT_LOCK_DEPTH=$((LAYOUT_LOCK_DEPTH + 1))
    return 0
  fi
  mkdir -p "$(_state_dir)"
  if _has_flock; then
    lockfile="$(_state_dir)/${workspace_id}.lock"
    exec 9>"$lockfile"
    flock 9
    LAYOUT_LOCK_KIND="flock"
  else
    lockdir="$(_state_dir)/${workspace_id}.lock.d"
    waited=0
    while ! mkdir "$lockdir" 2>/dev/null; do
      pid="$(cat "$lockdir/pid" 2>/dev/null || true)"
      if [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null; then
        stale="${lockdir}.stale.$$"
        if mv "$lockdir" "$stale" 2>/dev/null; then
          if [[ "$(cat "$stale/pid" 2>/dev/null || true)" == "$pid" ]]; then
            rm -rf "$stale"
          else
            mv "$stale" "$lockdir" 2>/dev/null || true
          fi
        fi
        continue
      fi
      sleep 0.05
      waited=$((waited + 1))
      if (( waited > 200 )); then
        echo "agentic-layout: timed out waiting for layout lock" >&2
        return 1
      fi
    done
    LAYOUT_LOCKDIR="$lockdir"
    LAYOUT_LOCK_KIND="mkdir"
    printf '%s\n' "$$" >"$LAYOUT_LOCKDIR/pid"
  fi
  LAYOUT_LOCK_WORKSPACE="$workspace_id"
  LAYOUT_LOCK_DEPTH=1
}

_layout_lock_release() {
  local depth="${LAYOUT_LOCK_DEPTH:-0}"
  if (( depth > 1 )); then
    LAYOUT_LOCK_DEPTH=$((depth - 1))
    return 0
  fi
  case "${LAYOUT_LOCK_KIND:-}" in
    flock)
      flock -u 9 2>/dev/null || true
      # Do not write `exec 9>&- 2>/dev/null`: exec would redirect the
      # shell's stderr to /dev/null for the rest of the process.
      exec 9>&- || true
      ;;
    mkdir)
      [[ -n "${LAYOUT_LOCKDIR:-}" ]] || return 0
      if [[ "$(cat "$LAYOUT_LOCKDIR/pid" 2>/dev/null || true)" == "$$" ]]; then
        rm -rf "$LAYOUT_LOCKDIR"
      fi
      LAYOUT_LOCKDIR=""
      ;;
  esac
  LAYOUT_LOCK_KIND=""
  LAYOUT_LOCK_WORKSPACE=""
  LAYOUT_LOCK_DEPTH=0
}

# Hold the workspace lock for the duration of "$@".
_with_layout_lock() {
  local workspace_id="$1" rc
  shift
  _layout_lock_acquire "$workspace_id" || return 1
  "$@"
  rc=$?
  _layout_lock_release
  return "$rc"
}

# Reload-merge-save under the lock so writers cannot clobber post-dock pane ids.
_state_update() {
  local workspace_id="$1"
  shift
  _with_layout_lock "$workspace_id" _state_update_locked "$workspace_id" "$@"
}

_state_update_locked() {
  local workspace_id="$1" state
  shift
  state="$(_state_load "$workspace_id" 2>/dev/null || true)"
  [[ -n "$state" ]] || return 0
  state="$(printf '%s' "$state" | jq "$@")" || return 1
  _state_save "$workspace_id" "$state"
}

_state_schema_ok() {
  local path="$1" workspace_id="$2"
  jq -e \
    --arg workspace_id "$workspace_id" \
    --argjson version "$STATE_VERSION" \
    'type == "object"
      and (.version | type == "number")
      and .version == $version
      and (.workspace_id | type == "string")
      and .workspace_id == $workspace_id
      and (.workdir | type == "string")
      and (.shell_tab_id | type == "string")
      and (.review_tab_id | type == "string")
      and (.agent_pane_id | type == "string")
      and (.review_pane_id | type == "string")
      and (.shell_pane_id | type == "string")
      and (.sidebar_pane_id | type == "string")
      and (.editors | type == "object")
      and (has("main_tab_id") | not)' \
    "$path" >/dev/null 2>&1
}

_state_quarantine() {
  local workspace_id="$1" path="$2"
  local quarantine_dir target
  quarantine_dir="$(_state_dir)/quarantine"
  mkdir -p "$quarantine_dir"
  target="$(mktemp "$quarantine_dir/$workspace_id.json.XXXXXX")"
  if ! mv "$path" "$target"; then
    rm -f "$target"
    return 1
  fi
  printf 'agentic-layout: quarantined invalid state: %s\n' "$target" >&2
}

# Predicate only: no stdout, never quarantines.
_state_probe() {
  local workspace_id="$1" path
  path="$(_state_path "$workspace_id")"
  [[ -f "$path" ]] || return 1
  _state_schema_ok "$path" "$workspace_id"
}

_state_init() {
  local workspace_id="$1" workdir="$2"
  jq -n \
    --arg workspace_id "$workspace_id" \
    --arg workdir "$workdir" \
    --argjson version "$STATE_VERSION" \
    '{
      version: $version,
      workspace_id: $workspace_id,
      workdir: $workdir,
      label: "",
      shell_tab_id: "",
      review_tab_id: "",
      agent_pane_id: "",
      review_pane_id: "",
      shell_pane_id: "",
      sidebar_pane_id: "",
      active_center_view: "shell",
      active_sidebar_view: "files",
      editors: {}
    }'
}

_state_save() {
  local workspace_id="$1" json="$2"
  local path tmp
  path="$(_state_path "$workspace_id")"
  tmp="$(mktemp "${path}.XXXXXX")"
  if ! printf '%s' "$json" | jq -c 'del(.main_tab_id)' >"$tmp" 2>/dev/null; then
    rm -f "$tmp"
    echo "agentic-layout: refused to save invalid state for $workspace_id" >&2
    return 1
  fi
  mv "$tmp" "$path"
}

_state_delete() {
  rm -f "$(_state_path "$1")"
}

_state_migrate() {
  local workspace_id="$1" raw="$2"
  printf '%s' "$raw" | _layout_core --migrate-state "$workspace_id"
}

_state_migrate_locked() {
  local workspace_id="$1" path raw migrated
  path="$(_state_path "$workspace_id")"
  [[ -f "$path" ]] || return 1
  if _state_probe "$workspace_id"; then
    cat "$path"
    return 0
  fi
  raw="$(cat "$path")"
  if [[ "$(printf '%s' "$raw" | jq -s 'length' 2>/dev/null)" == "2" ]]; then
    raw="$(printf '%s' "$raw" | jq -s '.[0]')"
  fi
  if ! printf '%s' "$raw" | jq -e 'type == "object"' >/dev/null 2>&1; then
    _state_quarantine "$workspace_id" "$path" || rm -f "$path"
    return 1
  fi
  migrated="$(_state_migrate "$workspace_id" "$raw")" || return 1
  _state_save "$workspace_id" "$migrated"
  if ! _state_probe "$workspace_id"; then
    _state_quarantine "$workspace_id" "$path" || rm -f "$path"
    return 1
  fi
  printf '%s' "$migrated"
}

_state_load() {
  local workspace_id="$1" path
  path="$(_state_path "$workspace_id")"
  [[ -f "$path" ]] || return 1
  if _state_probe "$workspace_id"; then
    cat "$path"
    return 0
  fi
  _with_layout_lock "$workspace_id" _state_migrate_locked "$workspace_id"
}

_clear_missing_pane() {
  local state="$1" field="$2" pane
  pane="$(printf '%s' "$state" | jq -r --arg field "$field" '.[$field] // empty')"
  if [[ -n "$pane" ]] && ! _pane_exists "$pane"; then
    printf '%s' "$state" | jq --arg field "$field" '.[$field] = ""'
  else
    printf '%s' "$state"
  fi
}

_reconcile_live_state() {
  local state="$1"
  state="$(_clear_missing_pane "$state" agent_pane_id)"
  state="$(_clear_missing_pane "$state" review_pane_id)"
  state="$(_clear_missing_pane "$state" shell_pane_id)"
  state="$(_clear_missing_pane "$state" sidebar_pane_id)"
  printf '%s' "$state"
}
