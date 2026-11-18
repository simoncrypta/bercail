# shellcheck shell=bash
# bercail shell integration (shared)
# Managed by bercail — do not edit; use ~/.config/bercail/config.toml

source "${HOME}/.config/worktrunk/herdr-layout.sh"

# The Herdr app space for $PWD (made if missing) with its desk agent, shown.
worktree-dev() {
  # shellcheck source=/dev/null
  source "${HOME}/.config/worktrunk/herdr-layout.sh"
  wt_herdr_attach "${PWD}"
}

alias dev='worktree-dev'

# Normalize only the fields we use. Schema 1 is a bare array; schema 2 nests
# paths under worktree: https://worktrunk.dev/list/#json-output.
_wt_list_rows() {
  local json rows
  json=$(wt list --format=json) || {
    echo "worktrunk list failed; run wt list --format=json to inspect the error" >&2
    return 1
  }
  rows=$(jq -e -s '
    if length != 1 then error("expected one JSON document")
    else .[0] end
    | if type == "array" then {schema: 1, items: .}
      elif type == "object" and (.schema | type) == "number" and .schema == 2
           and (.items | type) == "array" then {schema: 2, items: .items}
      else error("unknown worktrunk list schema") end
    | .schema as $schema
    | [.items[]
        | if type != "object" then error("row is not an object")
          elif (has("branch") | not) then error("row has no branch field") else . end
        | if $schema == 1 then {branch, path}
          elif .worktree == null then {branch, path: null}
          elif (.worktree | type) == "object" and (.worktree.path | type) == "string"
            then {branch, path: .worktree.path}
          else error("invalid worktree path") end
        | if (.branch != null and (.branch | type) != "string")
             or (.path != null and (.path | type) != "string") or .path == ""
          then error("branch or path has the wrong type") else . end]
  ' <<<"$json" 2>/dev/null) || {
    echo "Could not read worktrunk's list (expected a schema 1 array or a schema 2 envelope)" >&2
    return 1
  }
  printf '%s\n' "$rows"
}

_wt_worktree_path_for_branch() {
  local branch="$1" rows path
  rows=$(_wt_list_rows) || return
  path=$(jq -r --arg branch "$branch" '
    map(select(.branch == $branch and .path != null))
    | if length == 0 then "" else .[0].path end
  ' <<<"$rows") || return
  printf '%s' "$path"
}

_wt_worktree_branches() {
  local rows
  rows=$(_wt_list_rows) || return
  jq -r '.[] | select(.branch != null and .path != null) | .branch' <<<"$rows"
}

_wt_branch_exists() {
  local branch="$1"
  git show-ref --verify --quiet "refs/heads/$branch" 2>/dev/null && return 0
  git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1
}

_wt_default_branch() {
  local default_branch
  default_branch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|^refs/remotes/origin/||')
  [[ -z "$default_branch" ]] && default_branch="main"
  printf '%s' "$default_branch"
}

_wt_handle_same_branch_worktree() {
  local branch="$1"
  local current_branch repo_root default_branch existing_worktree worktree_dir

  current_branch=$(git branch --show-current 2>/dev/null)
  # 1 is not this case, so wtc may switch. Any other nonzero is a failure of this case.
  [[ "$branch" == "$current_branch" ]] || return 1

  repo_root=$(git rev-parse --show-toplevel 2>/dev/null)
  default_branch=$(_wt_default_branch)

  echo "Current worktree is on '$branch'. Moving to '$default_branch' first..."

  existing_worktree=$(git worktree list 2>/dev/null \
    | grep "\[$branch\]" | grep -v "^$repo_root " | awk '{print $1}' | head -1)

  if [[ -n "$existing_worktree" ]]; then
    if ! git switch "$default_branch"; then
      echo "Cannot switch to '$default_branch'. Commit or stash changes first."
      return 2
    fi
    wt_herdr_attach "$existing_worktree" || return 2
    return 0
  fi

  if ! git switch "$default_branch" 2>/dev/null; then
    echo "Cannot switch to '$default_branch'. Commit or stash changes first."
    return 2
  fi

  worktree_dir="${repo_root}.${branch}"
  if git worktree add "$worktree_dir" "$branch" 2>/dev/null; then
    wt_herdr_attach "$worktree_dir" || return 2
    return 0
  fi

  echo "Failed to create worktree. It may already exist."
  return 2
}

_wt_switch_or_create() {
  local branch="$1"
  if _wt_branch_exists "$branch"; then
    wt switch "$branch"
  else
    wt switch --create "$branch" --base=@
  fi
}

wtc() {
  local branch="$1"
  local current_dir new_path status=0 same=0

  current_dir=$(pwd)

  if [[ -z "$branch" ]]; then
    branch=$(git branch --show-current 2>/dev/null)
    if [[ -z "$branch" ]]; then
      echo "Could not determine current branch. Are you in a git repository?"
      return 1
    fi
  fi

  _wt_handle_same_branch_worktree "$branch" || same=$?
  if [[ "$same" -eq 0 ]]; then
    cd "$current_dir" || return
    return 0
  fi
  if [[ "$same" -ne 1 ]]; then
    cd "$current_dir" || return
    return "$same"
  fi

  _wt_switch_or_create "$branch" || return

  new_path=$(_wt_worktree_path_for_branch "$branch") || {
    cd "$current_dir" || return
    return 1
  }
  if [[ -z "$new_path" ]]; then
    echo "Worktree not found: $branch"
    cd "$current_dir" || return
    return 1
  fi

  wt_herdr_attach "$new_path" || status=$?
  cd "$current_dir" || return
  return "$status"
}

wts() {
  local branch="$1"

  if [[ -z "$branch" ]]; then
    local branches
    branches=$(_wt_worktree_branches) || return
    [[ -n "$branches" ]] || { echo "No worktree selected"; return 1; }
    branch=$(printf '%s\n' "$branches" | fzf --header="Select worktree:" --tiebreak=index) || {
      echo "No worktree selected"
      return 1
    }
    [[ -n "$branch" ]] || { echo "No worktree selected"; return 1; }
  fi

  local worktree_path
  worktree_path=$(_wt_worktree_path_for_branch "$branch") || return
  if [[ -z "$worktree_path" ]]; then
    echo "Worktree not found: $branch"
    return 1
  fi

  wt_herdr_attach "$worktree_path"
}

wtd() {
  local branch="$1"

  if [[ -z "$branch" ]]; then
    branch=$(git branch --show-current 2>/dev/null)
    [[ -z "$branch" ]] && { echo "Usage: wtd <branch-name>"; return 1; }
  fi

  local worktree_path session_name repo_root
  worktree_path=$(_wt_worktree_path_for_branch "$branch") || return
  if [[ -z "$worktree_path" ]]; then
    echo "Worktree not found: $branch"
    return 1
  fi

  session_name=$(_wt_generate_session_name "$worktree_path")

  repo_root=$(git rev-parse --show-toplevel 2>/dev/null)
  [[ -z "$repo_root" ]] || cd "$repo_root" || return

  wt remove "$branch" --force || return
  wt_herdr_layout_close "$session_name" "$worktree_path"
}

alias wt.='wts'
