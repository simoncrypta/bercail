# shellcheck shell=bash
# shellcheck disable=SC1010 # "do" is a herdr-app subcommand here, not the keyword
# bercail cleanup <worktree>: retire a finished checkout in one step. It copies
# the ignored .bercail/ evidence to the archive, ends the space's desk and its
# siblings, removes the worktree and closes its Herdr space. The branch stays.
# It refuses work nobody reviewed, and commits on neither trunk nor a remote
# branch, and a terminal it would end that is working or blocked. The guard
# asks the person before it runs. --check makes every refusal and changes
# nothing: the cleanup routine reads it. Exit 1 is a refusal; 2, that it could
# not read the Herdr app, hc or its helpers.

# bercail's Herdr helpers, as the worktrunk hooks use them. False when absent.
_cleanup_herdr_helpers() {
  local helper="${BERCAIL_HERDR_LAYOUT:-$HOME/.config/worktrunk/herdr-layout.sh}"
  declare -F _wt_herdr_hc_on >/dev/null && return 0
  [[ -f "$helper" ]] || return 1
  # shellcheck source=/dev/null
  source "$helper"
}

# Dies unless linked worktree $1 has nothing a removal would lose, nor anything
# git worktree remove refuses: no uncommitted work, no commit that trunk or a
# remote branch does not hold, no lock, no submodule, and evidence it can copy.
# A commit whose patch trunk already holds (git cherry -) landed as another commit.
_cleanup_check() {
  local wt="$1" main="$2" common="$3" gd trunk changed n subs up c out landed=""
  local -a keep=(--remotes) ups=() held=()
  gd="$(git -C "$wt" rev-parse --absolute-git-dir)"
  [[ "$gd" != "$common" ]] || die "refusing to clean up $wt: it is the repo's main checkout"
  [[ ! -f "$gd/locked" ]] || die "refusing to clean up $wt: it is locked (git worktree unlock $wt first)"
  # Untracked files count: a new file nobody committed is work too. No index
  # refresh: --check changes nothing.
  changed="$(GIT_OPTIONAL_LOCKS=0 git -C "$wt" status --porcelain --untracked-files=all)"
  if [[ -n "$changed" ]]; then
    die "refusing to clean up $wt: it holds work nobody reviewed ($(wc -l <<<"$changed") changed files, see git -C $wt status); land it, or move it away, then clean up again"
  fi
  trunk="$(git_backend_trunk "$main")"
  for up in "refs/heads/$trunk" "refs/remotes/origin/$trunk"; do
    ! git -C "$wt" show-ref --verify --quiet "$up" || ups+=("$up")
  done
  [[ "${ups[0]:-}" != "refs/heads/$trunk" ]] || keep+=("refs/heads/$trunk")
  for up in "${ups[@]}"; do
    out="$(git -C "$wt" cherry "$up" HEAD)" || die "refusing to clean up $wt: git cherry $up HEAD failed; nothing was removed"
    landed+=" $(sed -n 's/^- //p' <<<"$out" | tr '\n' ' ')"
  done
  out="$(git -C "$wt" rev-list HEAD --not "${keep[@]}")" \
    || die "refusing to clean up $wt: git cannot list the commits only it holds; nothing was removed"
  [[ -z "$out" ]] || mapfile -t held <<<"$out"
  n=0
  for c in "${held[@]}"; do [[ "$landed " == *" $c "* ]] || n=$((n + 1)); done
  [[ "$n" -eq 0 ]] \
    || die "refusing to clean up $wt: $n commits are on neither $trunk nor the remote (git -C $wt log HEAD --not ${keep[*]}); land or push them, then clean up again"
  [[ "${#held[@]}" -eq 0 ]] \
    || info "${#held[@]} commits are on $trunk as the same patch under another id (git cherry); they count as landed"
  # An uninitialized one (-) has no checkout to lose.
  subs="$(git -C "$wt" submodule status 2>&1)" \
    || die "refusing to clean up $wt: git cannot read its submodules ($subs); remove it by hand"
  [[ -z "$(grep -v '^-' <<<"$subs")" ]] \
    || die "refusing to clean up $wt: git worktree remove refuses a worktree with initialized submodules; remove it by hand"
  [[ ! -L "$wt/.bercail" ]] \
    || die "refusing to clean up $wt: its .bercail is a link, so the archive would hold only the link; copy what it points to by hand"
}

# The archive's folder for repo $1, ~/Work/worktree-archives/<repo>.
_cleanup_archive_root() { printf '%s/Work/worktree-archives/%s' "$HOME" "$1"; }

# Dies unless the archive's folder $2 could be made, outside worktree $1, as
# _cleanup_archive makes it: its nearest folder that exists, by its real path.
_cleanup_archive_check() {
  local wt="$1" dir="$2" up="$2"
  while [[ ! -e "$up" && ! -L "$up" ]]; do up="$(dirname "$up")"; done
  [[ -d "$up" && -w "$up" && -x "$up" ]] || die "could not make the archive dir $dir; nothing was removed"
  [[ "$(cd "$up" && pwd -P)${dir#"$up"}/" != "$wt/"* ]] || die "the archive dir $dir is inside $wt; nothing was removed"
}

# Dies with status 2: what cleanup needs to read did not answer.
_cleanup_unread() {
  printf 'error: %s\n' "$*" >&2
  exit 2
}

# Copies $1/.bercail to a new dir under ~/Work/worktree-archives/<repo>/, links
# as links. Prints the dir.
_cleanup_archive() {
  local wt="$1" repo="$2" name dest
  name="$(basename "$wt")"
  name="${name#"$repo".}"
  dest="$(_cleanup_archive_root "$repo")/$(date -u +%Y%m%dT%H%M%SZ)-$name"
  (umask 077 && mkdir -p "$(dirname "$dest")") \
    || die "could not make the archive dir $(dirname "$dest"); nothing was removed"
  # A link can put the archive inside the worktree, which takes the copy with it.
  [[ "$(cd "$(dirname "$dest")" && pwd -P)/" != "$wt/"* ]] \
    || die "the archive dir $(dirname "$dest") is inside $wt; nothing was removed"
  (umask 077 && mkdir "$dest") || die "could not make the archive dir $dest; nothing was removed"
  cp -a "$wt/.bercail" "$dest/" || {
    rm -rf "$dest"
    die "could not copy $wt/.bercail to $dest; nothing was removed"
  }
  printf '%s' "$dest"
}

# hc ls --json "$@", only when it answers with a list: a failed or blank answer
# is not an empty one. Nothing in these helpers runs under set -e (their callers
# test them), so each step says when it fails.
_cleanup_hc_ls() {
  local out
  out="$("$HC" ls --json "$@")" || return 1
  jq -e '.terminals | type == "array"' <<<"$out" >/dev/null || return 1
  printf '%s' "$out"
}

# The checkout's space on this machine, from the window's list $2 (a space
# another machine shows may sit on the same path), else from hc: the space of a
# kept Shell or a desk there. Status 5 (jq's error) when two match, 1 when hc
# did not answer.
_cleanup_space() {
  local wt="$1" ls="$2" list rows address cwd detail on=""
  if [[ -n "$ls" ]]; then
    jq -er --arg want "$wt" '[.spaces[] | select(.folder == $want and .machine == null) | .id]
      | if length > 1 then error("two spaces") else .[0] // "" end' <<<"$ls"
    return
  fi
  list="$(_cleanup_hc_ls)" || return 1
  rows="$(jq -r '.terminals[] | select(.state == "live" and (.cwd // "") != "") | [.address, .cwd] | @tsv' <<<"$list")" || return 1
  while IFS=$'\t' read -r address cwd; do
    [[ -n "$address" && "$(_wt_realpath "$cwd")" == "$wt" ]] || continue
    detail="$("$HC" get "$address" --json)" || return 1
    jq -e '.labels | type == "object"' <<<"$detail" >/dev/null || return 1
    on+="$detail"$'\n'
  done <<<"$rows"
  jq -ers '[.[] | if .labels["bercail.space_name"] != null then .labels["herdr.space"]
      elif .labels["bercail.role"] == "agent" then .labels["bercail.space"] else empty end | values]
    | unique | if length > 1 then error("two spaces") else .[0] // "" end' <<<"$on"
}

# The terminals cleanup ends in space $1, one a line: its desk first, then its
# siblings (builder, judge), then, with no window here ($2 empty), its kept
# Shell. Ending the parent first keeps a child's exit from waking it.
_cleanup_space_terminals() {
  local space="$1" window="$2" desk out
  desk="$(_wt_herdr_space_desk "$space")" || return 1
  [[ -z "$desk" ]] || printf '%s\n' "$desk"
  out="$(_cleanup_hc_ls --label "bercail.space=$space")" || return 1
  jq -r --arg desk "$desk" '.terminals[] | select(.state == "live" and .address != $desk) | .address' <<<"$out" || return 1
  [[ -z "$window" ]] || return 0
  out="$(_cleanup_hc_ls --label "herdr.space=$space")" || return 1
  jq -r '.terminals[] | select(.state == "live") | .address' <<<"$out" || return 1
}

cmd_cleanup() {
  local usage="usage: bercail cleanup [--check] <worktree>" wt main common repo branch dest="" ls="" space t out keep check=0 state
  local -a ends=() shells=()
  [[ "${1:-}" != --check ]] || { check=1; shift; }
  [[ $# -eq 1 && "$1" != -* ]] || die "$usage"
  [[ -d "$1" ]] || die "$1 is not a directory; $usage"
  wt="$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)" \
    || die "refusing to clean up $1: not a git worktree"
  wt="$(cd "$wt" && pwd -P)"
  [[ "$(cd "$1" && pwd -P)" == "$wt" ]] || die "refusing to clean up $1: it is inside $wt; name the worktree itself"
  main="$(git_backend_main "$wt")"
  repo="$(basename "$main")"
  common="$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir)"
  branch="$(git -C "$wt" symbolic-ref -q --short HEAD || true)"
  _cleanup_check "$wt" "$main" "$common"

  # Every terminal it will end or close is known, and none is this one, before
  # anything changes. What it cannot see, it does not guess at.
  _cleanup_herdr_helpers || _cleanup_unread "no Herdr helpers (herdr-layout.sh); run bercail update; nothing was removed"
  if _wt_herdr_app_running; then
    ls="$("$HERDR_APP" ls)" && jq -e '.spaces | type == "array"' <<<"$ls" >/dev/null 2>&1 \
      || _cleanup_unread "herdr-app could not list its spaces; nothing was removed"
  fi
  space="$(_cleanup_space "$wt" "$ls")" || {
    (($? == 5)) && die "refusing to clean up $wt: two Herdr spaces sit on it; close one, then clean up again"
    _cleanup_unread "could not tell which Herdr space is on $wt: neither the Herdr app nor hc answered in full; nothing was removed"
  }
  if [[ -n "$space" ]]; then
    out="$(_cleanup_space_terminals "$space" "$ls" | awk '!seen[$0]++')" \
      || _cleanup_unread "could not tell which terminals belong to space $space; nothing was removed"
    [[ -z "$out" ]] || mapfile -t ends <<<"$out"
    if [[ -n "$ls" ]]; then
      # Closing the space ends the window's own terminals in it.
      out="$(jq -r --arg id "$space" '.spaces[] | select(.id == $id) | .tabs[]?.terminals[]?.terminal' <<<"$ls")"
      [[ -z "$out" ]] || mapfile -t shells <<<"$out"
    fi
    for t in "${ends[@]}" "${shells[@]}"; do
      [[ "$t" != "${HC_TERMINAL_ID:-}" ]] \
        || die "refusing to clean up $wt from its own space ($t); run it from Shep or another shell"
    done
    # A terminal still at work, or waiting on the person, is not done.
    for t in "${ends[@]}" "${shells[@]}"; do
      state="$("$HC" get "$t" --json | jq -er '.status.state // "none"')" \
        || _cleanup_unread "hc could not read terminal $t; nothing was removed"
      [[ "$state" != working && "$state" != blocked ]] \
        || die "refusing to clean up $wt: terminal $t is $state; let it finish or end it, then clean up again"
    done
  fi

  [[ ! -d "$wt/.bercail" ]] || _cleanup_archive_check "$wt" "$(_cleanup_archive_root "$repo")"
  if ((check)); then
    info "cleanup would retire $wt: $([[ -d "$wt/.bercail" ]] && printf 'archive its .bercail/, ')${ends[*]:+end ${ends[*]}, }remove the worktree${branch:+ (branch $branch stays)}${space:+, close Herdr space $space}"
    return 0
  fi
  if [[ -d "$wt/.bercail" ]]; then
    dest="$(_cleanup_archive "$wt" "$repo")"
    info "archived .bercail/ to $dest/.bercail"
  else
    info "no .bercail/ in $wt to archive"
  fi
  for t in "${ends[@]}"; do
    "$HC" kill "$t" >/dev/null \
      || die "could not end terminal $t; the worktree and its space stay${dest:+, and .bercail/ is archived in $dest}"
    "$HC" rm "$t" >/dev/null 2>&1 || true
    info "ended terminal $t"
  done
  # Off the worktree before it goes; cleanup may run from inside it.
  cd /
  git --git-dir="$common" worktree remove "$wt" \
    || die "could not remove the worktree $wt${ends[*]:+ after ending ${ends[*]}}; its space stays${dest:+, and .bercail/ is archived in $dest}"
  info "removed worktree $wt${branch:+; branch $branch stays}"
  if [[ -z "$space" ]]; then
    info "no Herdr space was open on $wt"
  else
    if [[ -n "$ls" ]]; then
      keep="$(_wt_herdr_focused_space || true)"
      "$HERDR_APP" "do" space.close --id "$space" --confirmed true >/dev/null \
        || die "herdr-app did not close space $space; close it by hand"
      [[ "$keep" == "$space" ]] || _wt_herdr_keep_user_focus "$keep"
    fi
    info "closed Herdr space $space"
  fi
  # What the person sees, not only the space it closed.
  [[ -z "$ls" ]] || "$HERDR_APP" ls 2>/dev/null \
    | jq -r '"Herdr sidebar: \(.spaces | length) open, \(.recent // [] | length) recent"' || true
}
