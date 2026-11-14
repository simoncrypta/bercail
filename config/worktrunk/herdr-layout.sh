# shellcheck shell=bash
# shellcheck disable=SC1010 # "do" is a herdr-app subcommand here, not the keyword
# Herdr app helpers for worktrunk and shell integration.
# Safe to source repeatedly — worktrunk hooks and shell reload pick up updates.
#
# One checkout is one Herdr app space. Its desk agent is an hc terminal started
# as a sub-agent of the space's first terminal, labelled bercail.role=agent and
# bercail.space=<space id>; the bercail layout's desk column shows it.
# bercail-desk-agent picks what it runs.

HERDR_APP="${HERDR_APP_BIN:-herdr-app}"
HC="${HC_BIN:-hc}"
DESK_AGENT="${BERCAIL_DESK_AGENT:-$HOME/.local/bin/bercail-desk-agent}"

# A removed checkout (post-remove) resolves through its parent.
_wt_realpath() {
  local path="$1" parent
  (cd "$path" 2>/dev/null && pwd -P) && return
  parent="$(cd "$(dirname "$path")" 2>/dev/null && pwd -P)" \
    && printf '%s/%s' "$parent" "$(basename "$path")" && return
  printf '%s' "$path"
}

_wt_git_main_worktree() {
  local workdir="$1"
  git -C "$workdir" worktree list --porcelain 2>/dev/null \
    | awk '/^worktree / { print substr($0, 10); exit }'
}

_wt_herdr_app_running() {
  "$HERDR_APP" status >/dev/null 2>&1
}

# <Branch>_<Repo>, as worktrunk's post-start names the space. A sibling
# <main>.<branch> folder names both (a review worktree there is detached).
# Any other folder, a nested <repo>/<branch> layout among them, takes the repo
# from its main checkout's folder, as notify's space.repo does, and the branch from git.
_wt_generate_session_name() {
  local worktree_path="$1"
  local worktree_name main repo_name branch

  worktree_name=$(basename "$worktree_path")
  main="$(_wt_git_main_worktree "$worktree_path")"
  [[ -z "$main" ]] || main="$(basename "$main")"

  if [[ "$worktree_name" == *.* && ( -z "$main" || "$worktree_name" == "$main".* ) ]]; then
    repo_name=$(echo "$worktree_name" | sed 's/\.[a-zA-Z0-9_-]*$//' | awk '{print toupper(substr($0,1,1)) tolower(substr($0,2))}')
    branch=$(echo "$worktree_name" | sed 's/^[^.]*\.//' | awk '{print toupper(substr($0,1,1)) tolower(substr($0,2))}')
  else
    repo_name=$(echo "${main:-$worktree_name}" | awk '{print toupper(substr($0,1,1)) tolower(substr($0,2))}')
    branch=$(git -C "$worktree_path" branch --show-current 2>/dev/null | awk '{print toupper(substr($0,1,1)) tolower(substr($0,2))}')
  fi

  echo "${branch}_${repo_name}"
}

_wt_herdr_focused_space() {
  "$HERDR_APP" status 2>/dev/null | jq -r '.space // empty'
}

# Keep whatever space the user is viewing: space.new selects the new one.
_wt_herdr_keep_user_focus() {
  local want="$1"
  [[ -n "$want" ]] || return 0
  [[ "$(_wt_herdr_focused_space)" != "$want" ]] || return 0
  "$HERDR_APP" do space.select --id "$want" >/dev/null 2>&1 || true
}

_wt_herdr_space_by_folder() {
  local want
  want="$(_wt_realpath "$1")"
  "$HERDR_APP" ls 2>/dev/null \
    | jq -r --arg want "$want" '.spaces[] | select(.folder == $want) | .id' \
    | head -1
}

_wt_herdr_space_by_name() {
  "$HERDR_APP" ls 2>/dev/null \
    | jq -r --arg name "$1" '.spaces[] | select(.name == $name) | .id' \
    | head -1
}

# The space's first terminal: the desk agent's parent.
_wt_herdr_space_shell() {
  "$HERDR_APP" ls 2>/dev/null \
    | jq -r --arg id "$1" '.spaces[] | select(.id == $id) | .tabs[0].terminals[0].terminal // empty'
}

_wt_herdr_space_desk() {
  "$HC" ls --json 2>/dev/null \
    | jq -r '.terminals[] | select(.state == "live") | .address' \
    | while IFS= read -r address; do
        if "$HC" get "$address" --json 2>/dev/null \
          | jq -e --arg id "$1" '.labels["bercail.role"] == "agent" and .labels["bercail.space"] == $id' >/dev/null; then
          printf '%s' "$address"
          break
        fi
      done
}

# Space for this checkout: the one open on its folder, else a new one named label.
# Prints the space id; does not change the space the user is viewing.
_wt_herdr_resolve_space() {
  local label="$1" workdir="$2" space keep out
  workdir="$(_wt_realpath "$workdir")"
  space="$(_wt_herdr_space_by_folder "$workdir")"
  if [[ -z "$space" ]]; then
    keep="${WT_HERDR_KEEP_FOCUS:-$(_wt_herdr_focused_space)}"
    out="$("$HERDR_APP" do space.new --name "$label" --folder "$workdir" --tab Shell 2>&1)" || {
      echo "herdr-app space.new: $out" >&2
      return 1
    }
    space="$(printf '%s' "$out" | jq -r '.space // empty')"
    _wt_herdr_keep_user_focus "$keep"
  fi
  [[ -n "$space" ]] || {
    echo "Failed to resolve a Herdr space '$label' for $workdir" >&2
    return 1
  }
  printf '%s' "$space"
}

# Start the space's desk agent, replacing a live one. $3: its first message
# (optional). bercail-desk-agent runs bstack's Pi lead.
_wt_herdr_start_desk() {
  local space="$1" workdir="$2" prompt="${3:-}" shell old
  local -a argv=("$DESK_AGENT")
  shell="$(_wt_herdr_space_shell "$space")"
  [[ -n "$shell" ]] || {
    echo "Space $space has no terminal to start the desk agent from" >&2
    return 1
  }
  old="$(_wt_herdr_space_desk "$space")"
  if [[ -n "$old" ]]; then
    "$HC" kill "$old" >/dev/null 2>&1 || true
    "$HC" rm "$old" >/dev/null 2>&1 || true
  fi
  [[ -z "$prompt" ]] || argv+=(--prompt "$prompt")
  # Handoff names the issue and any model on the desk. A default start clears those vars.
  local -a labels=()
  if [[ -n "${WT_HERDR_ISSUE:-}" ]]; then
    labels+=(--label "bercail.issue=${WT_HERDR_ISSUE}")
    if [[ -n "${WT_HERDR_ISSUE_TITLE:-}" ]]; then
      labels+=(--label "bercail.issue_title=${WT_HERDR_ISSUE_TITLE}")
    fi
  fi
  if [[ -n "${WT_HERDR_MODEL:-}" ]]; then
    argv+=(--model "$WT_HERDR_MODEL")
    labels+=(--label "bercail.model=${WT_HERDR_MODEL}")
  fi
  # hc passes on the caller's environment; a headless caller (Shep) has
  # TERM=dumb, which leaves the desk without colors or key handling.
  TERM=xterm-256color COLORTERM=truecolor "$HC" run --bg --keep --outlive-parent --no-notify \
    --parent "$shell" --cwd "$(_wt_realpath "$workdir")" \
    --label bercail.role=agent --label "bercail.space=$space" \
    "${labels[@]}" \
    "${argv[@]}" >/dev/null
}

# The checkout's space, and its desk agent unless it has one.
# WT_HERDR_NO_DESK=1 (handoff-spawn, which starts its own desk): the space only.
wt_herdr_layout_create() {
  local label="$1" workdir="$2" space
  _wt_herdr_app_running || {
    echo "Herdr app is not running; open it and run: wt switch $(basename "$workdir")" >&2
    return 0
  }
  space="$(_wt_herdr_resolve_space "$label" "$workdir")" || return 1
  [[ "${WT_HERDR_NO_DESK:-}" != 1 ]] || return 0
  [[ -n "$(_wt_herdr_space_desk "$space")" ]] || _wt_herdr_start_desk "$space" "$workdir" || true
}

# A space sits on folder $1: it was made there (on any machine), or its first
# terminal is there now, as the bercail-spaces mod places a space. Only local
# terminals are in hc.
_wt_herdr_space_on() {
  local want ls terminal
  want="$(_wt_realpath "$1")"
  ls="$("$HERDR_APP" ls 2>/dev/null)" || return 1
  jq -e --arg want "$want" 'any(.spaces[]; .folder == $want)' <<<"$ls" >/dev/null && return 0
  while IFS= read -r terminal; do
    [[ "$(_wt_realpath "$("$HC" get "$terminal" --json 2>/dev/null | jq -r '.cwd // empty')")" != "$want" ]] \
      || return 0
  done < <(jq -r '.spaces[] | select(.machine == null) | .tabs[0].terminals[0].terminal // empty' <<<"$ls")
  return 1
}

# handoff-spawn: a space on the repo's main checkout, a plain shell, when none
# sits there, so the bercail-spaces mod nests the new desk's space under it.
wt_herdr_main_space() {
  local main="$1"
  _wt_herdr_app_running || return 0
  ! _wt_herdr_space_on "$main" || return 0
  WT_HERDR_NO_DESK=1 wt_herdr_layout_create "$(_wt_generate_session_name "$main")" "$main"
}

# Clear session of the desk agent (d / dev / apply). Ignores any
# inherited handoff prompt, issue labels, or model.
wt_herdr_start_default_agent() {
  local label="$1" workdir="$2" space
  _wt_herdr_app_running || { echo "Herdr app is not running" >&2; return 1; }
  space="$(_wt_herdr_resolve_space "$label" "$workdir")" || return 1
  WT_HERDR_ISSUE='' WT_HERDR_ISSUE_TITLE='' WT_HERDR_MODEL='' _wt_herdr_start_desk "$space" "$workdir"
}

# Orchestrator / handoff-spawn: start or replace the desk agent with
# WT_HERDR_AGENT_PROMPT (one line pointing at the beads issue).
wt_herdr_handoff_agent() {
  local label="$1" workdir="$2" space
  _wt_herdr_app_running || { echo "Herdr app is not running" >&2; return 1; }
  if [[ -z "${WT_HERDR_AGENT_PROMPT:-}" ]]; then
    echo "wt_herdr_handoff_agent requires WT_HERDR_AGENT_PROMPT (one line pointing at the beads issue)" >&2
    return 1
  fi
  space="$(_wt_herdr_resolve_space "$label" "$workdir")" || return 1
  _wt_herdr_start_desk "$space" "$workdir" "$WT_HERDR_AGENT_PROMPT"
}

# The checkout's space: the one open on its folder (the branch, and so the
# label, may have changed since it opened), else the one named label.
wt_herdr_layout_close() {
  local label="$1" workdir="${2:-}" space=
  _wt_herdr_app_running || return 0
  [[ -z "$workdir" ]] || space="$(_wt_herdr_space_by_folder "$workdir")"
  [[ -n "$space" ]] || space="$(_wt_herdr_space_by_name "$label")"
  [[ -n "$space" ]] || return 0
  "$HERDR_APP" do space.close --id "$space" --confirmed true >/dev/null 2>&1 || true
}

wt_herdr_attach() {
  local worktree_path="$1" session_name space
  session_name="$(_wt_generate_session_name "$worktree_path")"
  if ! _wt_herdr_app_running; then
    (nohup "$HERDR_APP" >/dev/null 2>&1 &)
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      _wt_herdr_app_running && break
      sleep 0.5
    done
  fi
  space="$(_wt_herdr_resolve_space "$session_name" "$worktree_path")" || return 1
  [[ -n "$(_wt_herdr_space_desk "$space")" ]] \
    || wt_herdr_start_default_agent "$session_name" "$worktree_path" || true
  "$HERDR_APP" do space.select --id "$space" >/dev/null 2>&1 || true
}
