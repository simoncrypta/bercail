# shellcheck shell=bash
# shellcheck disable=SC1010 # "do" is a herdr-app subcommand here, not the keyword
# Herdr app helpers for worktrunk and shell integration.
# Safe to source repeatedly — worktrunk hooks and shell reload pick up updates.
#
# One checkout is one Herdr app space. Its desk agent is an hc terminal started
# as a sub-agent of the space's first terminal, labelled bercail.role=agent and
# bercail.space=<space id>; the bercail layout's desk column shows it.
# bercail-desk-agent picks what it runs.
#
# With no window on this machine (a laptop's window shows its spaces), a space is
# a kept Shell that hc labels herdr.space/herdr.tab: any window connected now or
# later adopts it. bercail.space_name on it carries the name bercail-spaces gives it.

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

# A window here, else hc's core: either can make a space.
_wt_herdr_reachable() {
  _wt_herdr_app_running || "$HC" ls --json >/dev/null 2>&1
}

# Runs "$@" holding checkout $1's lock, so two hooks or spawns cannot both make
# its space or desk. Callers check _wt_herdr_reachable first: a core that an hc
# call started in here would inherit fd 9, and the lock with it.
_wt_herdr_locked() {
  local key lock
  key="$(_wt_realpath "$1" | cksum | cut -d' ' -f1)"
  shift
  command -v flock >/dev/null 2>&1 || { "$@"; return; }
  lock="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/bercail-space-$key.lock"
  (
    flock -w 30 9 || { echo "another bercail hook has held $lock for 30s; try again" >&2; exit 1; }
    "$@"
  ) 9>"$lock"
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
  local snapshot address detail found=""
  snapshot="$("$HC" ls --json 2>/dev/null)" || return 1
  jq -e '.terminals | type == "array"' <<<"$snapshot" >/dev/null || return 1
  while IFS= read -r address; do
    detail="$("$HC" get "$address" --json 2>/dev/null)" || return 1
    jq -e '.labels | type == "object"' <<<"$detail" >/dev/null || return 1
    if jq -e --arg id "$1" '.labels["bercail.role"] == "agent" and .labels["bercail.space"] == $id' <<<"$detail" >/dev/null; then
      [[ -z "$found" ]] || { echo "Space $1 has ambiguous desks" >&2; return 1; }
      found="$address"
    fi
  done < <(jq -r '.terminals[] | select(.state == "live") | .address' <<<"$snapshot")
  printf '%s' "$found"
}

# No window here: each live terminal on folder $1, as hc get prints it, one a line.
_wt_herdr_hc_on() {
  local want address cwd
  want="$(_wt_realpath "$1")"
  "$HC" ls --json 2>/dev/null \
    | jq -r '.terminals[]? | select(.state == "live" and (.cwd // "") != "") | [.address, .cwd] | @tsv' \
    | while IFS=$'\t' read -r address cwd; do
        [[ "$(_wt_realpath "$cwd")" == "$want" ]] || continue
        "$HC" get "$address" --json 2>/dev/null | jq -c . 2>/dev/null || true
      done
}

# No window here: the space on folder $1, from the Shell bercail made for it, else
# a desk there. Every window terminal carries herdr.space too, but only its live
# folder: a Shell someone cd'd here belongs to another space.
_wt_herdr_hc_space_by_folder() {
  _wt_herdr_hc_on "$1" | jq -rs 'first(
    (.[] | select(.labels["bercail.space_name"] != null) | .labels["herdr.space"] // empty),
    (.[] | select(.labels["bercail.role"] == "agent") | .labels["bercail.space"] // empty)) // empty'
}

# No window here: the first live terminal of space $1, its Shell.
_wt_herdr_hc_space_shell() {
  "$HC" ls --json --label "herdr.space=$1" 2>/dev/null \
    | jq -r '[.terminals[]? | select(.state == "live") | .address][0] // empty'
}

# The checkout's open space: the window's on folder $1, else (no window here) hc's.
_wt_herdr_find_space() {
  if _wt_herdr_app_running; then
    _wt_herdr_space_by_folder "$1"
  else
    _wt_herdr_hc_space_by_folder "$1"
  fi
}

# No window here: a new space on folder $2 named $1, as a kept Shell that any
# window adopts without showing it. Ids look like the app's. Prints the space id.
_wt_herdr_hc_space_new() {
  local label="$1" workdir="$2" space tab
  space="sp$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
  tab="tb$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
  TERM=xterm-256color COLORTERM=truecolor "$HC" run --bg --keep --no-parent --no-notify --cwd "$workdir" \
    --label "herdr.space=$space" --label "herdr.tab=$tab" --label "bercail.space_name=$label" >/dev/null || {
    echo "hc run could not start a Shell for a space on $workdir" >&2
    return 1
  }
  printf '%s' "$space"
}

# Space for this checkout: the one open on its folder, else a new one named label.
# Prints the space id; does not change the space the user is viewing.
_wt_herdr_resolve_space() {
  local label="$1" workdir="$2" space keep out
  workdir="$(_wt_realpath "$workdir")"
  if ! _wt_herdr_app_running; then
    space="$(_wt_herdr_hc_space_by_folder "$workdir")"
    [[ -n "$space" ]] || space="$(_wt_herdr_hc_space_new "$label" "$workdir")" || return 1
    printf '%s' "$space"
    return 0
  fi
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
  local space="$1" workdir="$2" prompt="${3:-}" shell old created
  local -a argv=("$DESK_AGENT")
  if _wt_herdr_app_running; then
    shell="$(_wt_herdr_space_shell "$space")"
  else
    shell="$(_wt_herdr_hc_space_shell "$space")"
  fi
  [[ -n "$shell" ]] || {
    echo "Space $space has no terminal to start the desk agent from" >&2
    return 1
  }
  old="$(_wt_herdr_space_desk "$space")" || { echo "Desk ownership UNKNOWN in $space; no agent started" >&2; return 1; }
  if [[ -n "$old" && "${WT_HERDR_CREATE_ONLY:-0}" == 1 ]]; then
    echo "Space $space already has desk $old; continue its original session with bercail shep task dispatch" >&2
    return 1
  fi
  if [[ -n "$old" ]]; then
    "$HC" kill "$old" >/dev/null 2>&1 || true
    "$HC" rm "$old" >/dev/null 2>&1 || true
  fi
  [[ -z "${WT_HERDR_SESSION_ID:-}" ]] || argv=(env "WT_HERDR_SESSION_ID=$WT_HERDR_SESSION_ID" "${argv[@]}")
  [[ -z "$prompt" ]] || argv+=(--prompt "$prompt")
  [[ -z "${WT_HERDR_ROLE:-}" ]] || argv+=(--role "$WT_HERDR_ROLE")
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
  created="$(TERM=xterm-256color COLORTERM=truecolor "$HC" run --bg --json --keep --outlive-parent --no-notify \
    --parent "$shell" --cwd "$(_wt_realpath "$workdir")" \
    --label bercail.role=agent --label "bercail.space=$space" \
    "${labels[@]}" \
    "${argv[@]}")" || return 1
  if [[ "${WT_HERDR_CREATE_ONLY:-0}" == 1 ]]; then
    jq -ce --arg space "$space" 'select(.address) | {space:$space,desk:.address}' <<<"$created"
  fi
}

# The checkout's space, and its desk agent unless it has one.
# WT_HERDR_NO_DESK=1 (handoff-spawn, which starts its own desk): the space only.
wt_herdr_layout_create() {
  _wt_herdr_reachable || {
    echo "Neither the Herdr app nor hc answers; start one and run: wt switch $(basename "$2")" >&2
    return 0
  }
  _wt_herdr_locked "$2" _wt_herdr_layout_create_locked "$@"
}

_wt_herdr_layout_create_locked() {
  local label="$1" workdir="$2" space
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
  ls="$("$HERDR_APP" ls 2>/dev/null)" || {
    _wt_herdr_hc_space_on "$want"
    return
  }
  jq -e --arg want "$want" 'any(.spaces[]; .folder == $want)' <<<"$ls" >/dev/null && return 0
  while IFS= read -r terminal; do
    [[ "$(_wt_realpath "$("$HC" get "$terminal" --json 2>/dev/null | jq -r '.cwd // empty')")" != "$want" ]] \
      || return 0
  done < <(jq -r '.spaces[] | select(.machine == null) | .tabs[0].terminals[0].terminal // empty' <<<"$ls")
  return 1
}

# No window here: a terminal of some space (herdr.space, which every window
# terminal carries) or a desk sits on folder $1.
_wt_herdr_hc_space_on() {
  _wt_herdr_hc_on "$1" | jq -e -s 'any(.[]; .labels["herdr.space"] != null or .labels["bercail.role"] == "agent")' >/dev/null
}

# handoff-spawn: a space on the repo's main checkout, a plain shell, when none
# sits there, so the bercail-spaces mod nests the new desk's space under it.
wt_herdr_main_space() {
  _wt_herdr_reachable || return 0
  _wt_herdr_locked "$1" _wt_herdr_main_space_locked "$1"
}

_wt_herdr_main_space_locked() {
  ! _wt_herdr_space_on "$1" || return 0
  WT_HERDR_NO_DESK=1 _wt_herdr_layout_create_locked "$(_wt_generate_session_name "$1")" "$1"
}

# The checkout's space and a desk in it, replacing a live one; $3: its prompt.
_wt_herdr_desk_locked() {
  local space
  space="$(_wt_herdr_resolve_space "$1" "$2")" || return 1
  _wt_herdr_start_desk "$space" "$2" "${3:-}"
}

# Clear session of the desk agent (d / dev / apply). Ignores any
# inherited handoff prompt, issue labels, model, or role.
wt_herdr_start_default_agent() {
  _wt_herdr_reachable || { echo "Neither the Herdr app nor hc answers" >&2; return 1; }
  WT_HERDR_ISSUE='' WT_HERDR_ISSUE_TITLE='' WT_HERDR_MODEL='' WT_HERDR_SESSION_ID='' WT_HERDR_ROLE='' _wt_herdr_locked "$2" _wt_herdr_desk_locked "$1" "$2"
}

# Orchestrator / handoff-spawn: create only, never replace a desk agent, with
# WT_HERDR_AGENT_PROMPT (one line pointing at the beads issue).
wt_herdr_handoff_agent() {
  local WT_HERDR_CREATE_ONLY=1
  _wt_herdr_reachable || { echo "Neither the Herdr app nor hc answers" >&2; return 1; }
  if [[ -z "${WT_HERDR_AGENT_PROMPT:-}" ]]; then
    echo "wt_herdr_handoff_agent requires WT_HERDR_AGENT_PROMPT (one line pointing at the beads issue)" >&2
    return 1
  fi
  _wt_herdr_locked "$2" _wt_herdr_desk_locked "$1" "$2" "$WT_HERDR_AGENT_PROMPT"
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
