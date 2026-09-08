# bercail shell integration (shared)
# Managed by bercail — do not edit; use ~/.config/bercail/config.toml

source "${HOME}/.config/worktrunk/herdr-layout.sh"

worktree-dev() {
  # shellcheck source=/dev/null
  source "${HOME}/.config/worktrunk/herdr-layout.sh"
  wt_herdr_attach "${PWD}"
}

unalias d 2>/dev/null || true
d() {
  # shellcheck source=/dev/null
  source "${HOME}/.config/worktrunk/herdr-layout.sh"
  if _wt_in_herdr; then
    wt_herdr_layout_apply "${PWD}"
    return 0
  fi
  echo "You must be in herdr to use d."
  return 1
}

alias dev='worktree-dev'
alias t='herdr'

_wt_worktree_path_for_branch() {
  local branch="$1"
  wt list --format=json 2>/dev/null \
    | jq -r --arg branch "$branch" 'map(select(.branch == $branch)) | .[0].path'
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
  [[ "$branch" == "$current_branch" ]] || return 1

  repo_root=$(git rev-parse --show-toplevel 2>/dev/null)
  default_branch=$(_wt_default_branch)

  echo "Current worktree is on '$branch'. Moving to '$default_branch' first..."

  existing_worktree=$(git worktree list 2>/dev/null \
    | grep "\[$branch\]" | grep -v "^$repo_root " | awk '{print $1}' | head -1)

  if [[ -n "$existing_worktree" ]]; then
    git switch "$default_branch"
    wt_herdr_attach "$existing_worktree"
    return 0
  fi

  if ! git switch "$default_branch" 2>/dev/null; then
    echo "Cannot switch to '$default_branch'. Commit or stash changes first."
    return 1
  fi

  worktree_dir="${repo_root}.${branch}"
  if git worktree add "$worktree_dir" "$branch" 2>/dev/null; then
    wt_herdr_attach "$worktree_dir"
    return 0
  fi

  echo "Failed to create worktree. It may already exist."
  return 1
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
  local current_dir new_path

  current_dir=$(pwd)

  if [[ -z "$branch" ]]; then
    branch=$(git branch --show-current 2>/dev/null)
    if [[ -z "$branch" ]]; then
      echo "Could not determine current branch. Are you in a git repository?"
      return 1
    fi
  fi

  if _wt_handle_same_branch_worktree "$branch"; then
    cd "$current_dir"
    return 0
  fi

  _wt_switch_or_create "$branch"

  new_path=$(_wt_worktree_path_for_branch "$branch")
  [[ -z "$new_path" || "$new_path" == "null" ]] && new_path=$(pwd)

  wt_herdr_attach "$new_path"
  cd "$current_dir"
}

wts() {
  local branch="$1"

  if [[ -z "$branch" ]]; then
    branch=$(wt list --format=json 2>/dev/null | jq -r '.[].branch' | fzf --header="Select worktree:" --tiebreak=index)
    [[ -z "$branch" ]] && { echo "No worktree selected"; return 1; }
  fi

  local worktree_path
  worktree_path=$(_wt_worktree_path_for_branch "$branch")

  if [[ -z "$worktree_path" || "$worktree_path" == "null" ]]; then
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
  worktree_path=$(_wt_worktree_path_for_branch "$branch")
  if [[ -z "$worktree_path" || "$worktree_path" == "null" ]]; then
    echo "Worktree not found: $branch"
    return 1
  fi

  session_name=$(_wt_generate_session_name "$worktree_path")

  repo_root=$(git rev-parse --show-toplevel 2>/dev/null)
  [[ -n "$repo_root" ]] && cd "$repo_root"

  wt remove "$branch" --force
  wt_herdr_layout_close "$session_name"
}

alias wt.='wts'
