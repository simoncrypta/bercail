# shellcheck shell=bash
# shellcheck disable=SC1010 # "do" is a herdr-app subcommand here, not the keyword
# bercail cleanup <worktree>: retire a finished checkout in one step. It copies
# the ignored .bercail/ evidence to the archive, ends the space's desk, its
# siblings and what they started, parents first, removes the worktree and
# closes its Herdr space. The branch stays. It refuses work nobody reviewed,
# and commits on neither trunk nor a remote branch, and a terminal it would end
# that is working or blocked, and stops partway when one changes. The guard
# asks the person before it runs. --check makes every refusal and changes
# nothing: the cleanup routine reads it. Exit 1 is a refusal; 2, that it could
# not read the Herdr app, hc or its helpers. Once the worktree is gone it adds a
# line to retired.jsonl, which tells dispatch the job's desk went on purpose, so
# the job may get a new one; --gone records one removed some other way.

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

# hc ls --json, only when it answers with a list: a failed or blank answer is
# not an empty one. Nothing in these helpers runs under set -e (their callers
# test them), so each step says when it fails.
_cleanup_hc_ls() {
  local out
  out="$("$HC" ls --json)" || return 1
  jq -e '.terminals | type == "array"' <<<"$out" >/dev/null || return 1
  printf '%s' "$out"
}

# The checkout's space on this machine, from the window's list $2 (a space
# another machine shows may sit on the same path), else from hc: the space of a
# kept Shell or a desk there. Status 5 (jq's error) when two match; 1, with
# the read that failed, when hc did not answer.
_cleanup_space() {
  local wt="$1" ls="$2" list rows address cwd detail on=""
  if [[ -n "$ls" ]]; then
    jq -er --arg want "$wt" '[.spaces[] | select(.folder == $want and .machine == null) | .id]
      | if length > 1 then error("two spaces") else .[0] // "" end' <<<"$ls"
    return
  fi
  list="$(_cleanup_hc_ls)" || return 1
  rows="$(jq -r '.terminals[] | if (.address | type) == "string" and (.state | type) == "string" then . else error("row") end
    | select(.state == "live" and (.cwd // "") != "") | [.address, .cwd] | @tsv' <<<"$list" 2>/dev/null)" || return 1
  while IFS=$'\t' read -r address cwd; do
    [[ -n "$address" && "$(_wt_realpath "$cwd")" == "$wt" ]] || continue
    detail="$("$HC" get "$address" --json)" || { (($? == 3)) && continue; printf 'hc could not read terminal %s' "$address"; return 1; }
    jq -e '.labels | type == "object"' <<<"$detail" >/dev/null || { printf 'hc could not read terminal %s' "$address"; return 1; }
    on+="$detail"$'\n'
  done <<<"$rows"
  jq -ers '[.[] | if .labels["bercail.space_name"] != null then .labels["herdr.space"]
      elif .labels["bercail.role"] == "agent" then .labels["bercail.space"] else empty end | values]
    | unique | if length > 1 then error("two spaces") else .[0] // "" end' <<<"$on"
}

# Every live terminal on this machine, those named in $@, and the finished
# ancestors of both, as hc get prints them, cut to what cleanup checks. A
# terminal hc no longer knows (exit 3) has ended. When hc did not answer, or
# answered without an address or a state, it prints what failed, and status 1.
_cleanup_snapshot() {
  local list address detail rc out="" more
  list="$(_cleanup_hc_ls)" || { printf 'hc did not list its terminals'; return 1; }
  list="$(jq -r '.terminals[] | if (.address | type) == "string" and (.state | type) == "string" then . else error("row") end
    | select(.state == "live" and (.address | contains("/") | not)) | .address' <<<"$list" 2>/dev/null)" \
    || { printf 'hc listed a terminal without its address or state'; return 1; }
  more="$(printf '%s\n' "$list" "$@" | awk 'NF && !seen[$0]++')"
  while [[ -n "$more" ]]; do
    while IFS= read -r address; do
      rc=0
      detail="$("$HC" get "$address" --json)" || rc=$?
      if ((rc == 3)); then
        detail="$(jq -nc --arg a "$address" '{address: $a, state: "gone", labels: {}}')"
      elif ((rc != 0)) || ! jq -e --arg a "$address" '.address == $a and (.labels | type == "object")
          and (.state | IN("live", "finished"))' <<<"$detail" >/dev/null 2>&1; then
        printf 'hc could not read terminal %s' "$address"
        return 1
      fi
      out+="$detail"$'\n'
    done <<<"$more"
    # A finished parent still links what it started to the tree.
    more="$(jq -rs 'map(.address) as $have | [.[].parent | strings | select((IN($have[]) | not) and (contains("/") | not))]
      | unique | .[]' <<<"$out")"
  done
  jq -sc 'map({address, parent, live: (.state == "live"), dies: (.die_with_parent == true), pid, start: .created_ms,
    status: (if .status == null then "none" elif (.status.state | type) == "string" then .status.state else "unknown" end),
    role: .labels["bercail.role"], bs: .labels["bercail.space"], hs: .labels["herdr.space"]})' <<<"$out"
}

# The owner tree of space $2 in snapshot $1, as {end, close, problems}. end is
# what cleanup ends: the space's desk, its siblings, with no window ($3 true)
# its kept Shell, and every terminal they started, each parent before what it
# started, so no child's end wakes a terminal still to end. Ended members of
# the earlier tree $5, and ended terminals the space labels, still link what
# they started. close is what closing
# the space ends: the window's terminals $4 and what dies with them. A
# terminal labelled for another space is never taken: problems names one it
# would end, a member with another space's label, and two desks.
_cleanup_tree() {
  jq -c --arg space "$2" --argjson nowin "$3" --argjson w "$4" --argjson was "$5" '
    . as $all | (map({(.address): .}) | add // {}) as $by
    | def keep: reduce .[] as $a ([]; if IN(.[]; $a) then . else . + [$a] end);
      def mine: [.bs, .hs] | map(select(. != null)) | all(. == $space);
      def grow($any): . as $s | [$all[] | select((.parent | IN($s[])) and (.address | IN($s[]) | not)
          and mine and ($any or .dies or (.live | not))) | .address] as $n
        | if $n == [] then $s else $s + $n | grow($any) end;
      def live: map(select($by[.].live));
      def depth($set): ($by[.].parent // null) as $p | if $p != null and ($p | IN($set[])) then ($p | depth($set)) + 1 else 0 end;
    [$all[] | select(.live and .role == "agent" and .bs == $space) | .address] as $desk
    | ($desk + [$all[] | select(.live and .bs == $space) | .address] + [$all[] | select(.live and $nowin and .hs == $space) | .address]
      | keep) as $roots
    | ($roots + [$all[] | select((.live | not) and (.bs == $space or ($nowin and .hs == $space))) | .address]
      + ($was.end | map(select($by[.].live | not))) | keep | grow(true)) as $e
    | ($w | keep | grow(false)) as $c
    | ($e | live) as $end
    | {end: ($end | to_entries | sort_by((.value | depth($end)), .key) | map(.value)),
      close: ($c | live | map(select(IN($end[]) | not))),
      problems: ((if ($desk | length) > 1 then ["two desks claim space \($space): \($desk | join(", "))"] else [] end)
        + [($roots + ($w | live))[] | $by[.] | select(mine | not)
          | "terminal \(.address) is labelled for another space (bercail.space \(.bs // "none"), herdr.space \(.hs // "none"))"]
        + [$all[] | select(.live and .dies and (mine | not) and (.parent | IN($e[], $c[])))
          | "terminal \(.address) of space \(.bs // .hs) would end with \(.parent)"])}' <<<"$1"
}

# What changed for worktree $1 and its space $2 (the window's list $3, empty
# with none) since snapshot $4 of owner tree $5. Prints {ended, problems}: the
# worktree is still on that space (with no window, the space is known from
# the terminals cleanup ends, so none is fine); a member hc has as finished or no longer
# knows has ended; one still live must be the process checked, with the same
# parent, labels and place in the tree, still reporting a status if it did,
# and neither working nor blocked; and the tree, read again, holds nothing new. When hc or the
# window did not answer, it prints what failed, and status 1.
_cleanup_recheck() {
  local wt="$1" space="$2" window="$3" snap="$4" tree="$5" shells='[]' now next nowin=true on rc=0
  local -a named=()
  if [[ -n "$window" ]]; then
    nowin=false
    window="$("$HERDR_APP" ls)" && jq -e '.spaces | type == "array"' <<<"$window" >/dev/null 2>&1 \
      || { printf 'herdr-app could not list its spaces'; return 1; }
    shells="$(jq -c --arg id "$space" '[.spaces[] | select(.id == $id) | .tabs[]?.terminals[]?.terminal]' <<<"$window")"
  fi
  on="$(_cleanup_space "$wt" "$window")" || rc=$?
  ((rc == 0 || rc == 5)) || { printf 'could not tell which Herdr space is on %s: %s' "$wt" "${on:-hc did not answer}"; return 1; }
  ((rc == 0)) || on="two spaces"
  if [[ -z "$space" ]]; then
    jq -nc --arg on "$on" '{ended: [], problems: (if $on == "" then [] else ["Herdr space \($on) is on the worktree now"] end)}'
    return
  fi
  mapfile -t named < <(jq -r '.[]' <<<"$shells"; jq -r '.end[], .close[]' <<<"$tree")
  now="$(_cleanup_snapshot "${named[@]}")" || { printf '%s' "$now"; return 1; }
  next="$(_cleanup_tree "$now" "$space" "$nowin" "$shells" "$tree")"
  jq -nc --arg space "$space" --arg on "$on" --argjson nowin "$nowin" --argjson was "$snap" --argjson now "$now" --argjson tree "$tree" --argjson next "$next" '
    ($was | map({(.address): .}) | add // {}) as $w | ($now | map({(.address): .}) | add // {}) as $n
    | ($tree.end + $tree.close) as $m
    | {ended: [$m[] | select($n[.].live | not)],
      problems: ((if $on == $space or ($nowin and $on == "") then [] else ["the Herdr space on the worktree is \(if $on == "" then "none" else $on end) now, not \($space)"] end)
        + [$m[] | . as $a | $n[$a] | select(.live) | $w[$a] as $o
          | (if [.pid, .start] != [$o.pid, $o.start]
              then "terminal \($a) is not the process cleanup checked (pid \($o.pid) from \($o.start), now pid \(.pid) from \(.start))" else empty end),
            (if [.parent, .bs, .hs] != [$o.parent, $o.bs, $o.hs]
              then "terminal \($a) has another parent or space now (parent \(.parent // "none"), space \(.bs // .hs // "none"))"
            elif ($a | IN($tree.end[])) != ($a | IN($next.end[])) or ($a | IN($tree.close[])) != ($a | IN($next.close[]))
              then "terminal \($a) is no longer where cleanup found it in space \($space)" else empty end),
            (if .status | IN("working", "blocked", "unknown") then "terminal \($a) is \(.status) now"
            elif .status == "none" and $o.status != "none" then "terminal \($a) no longer reports its status" else empty end)]
        + [($next.end + $next.close)[] | select(IN($m[]) | not)
          | "terminal \(.) joined the space after cleanup checked it\(if $n[.].status | IN("working", "blocked", "unknown") then ", and is \($n[.].status)" else "" end)"]
        + $next.problems)}'
}

# What a cleanup that stops partway leaves: the terminals it ended ($2...),
# the worktree and space that stay, and the archive $1.
_cleanup_left() {
  local dest="$1"
  shift
  printf '%sthe worktree and its space stay%s' "${*:+it ended $*; }" "${dest:+, and .bercail/ is archived in $dest}"
}

# Appends that checkout $1 of repo $2 (branch $3) is retired; $4 is true when
# it was gone already. Dispatch reads it: a handoff there before it names a
# desk that went on purpose, not an unknown one.
_cleanup_retired() {
  local dir="${XDG_STATE_HOME:-$HOME/.local/state}/bercail"
  mkdir -p "$dir" && jq -nc --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg p "$1" --arg r "$2" --arg b "$3" --argjson gone "$4" \
    '{v: 1, at: $at, path: $p, repo: $r, branch: $b} + (if $gone then {gone: true} else {} end)' >>"$dir/retired.jsonl"
}

# cleanup --gone <path>: a checkout a handoff started, removed without cleanup
# (by hand, or wt remove). The person says nothing was lost; this records it.
_cleanup_gone() {
  local path="$1" handoffs line="" repo branch
  handoffs="${XDG_STATE_HOME:-$HOME/.local/state}/bercail/handoffs.jsonl"
  [[ ! -e "$path" ]] || die "$path is still there; bercail cleanup $path retires it"
  [[ ! -f "$handoffs" ]] || line="$(jq -c --arg p "$path" 'select(.path == $p)' "$handoffs" | tail -1)"
  [[ -n "$line" ]] || die "no handoff names $path, so no job waits on it; nothing to record"
  repo="$(jq -r '.repo // empty' <<<"$line")"
  branch="$(jq -r '.branch // empty' <<<"$line")"
  if [[ -n "$repo" ]] && git -C "$repo" worktree list --porcelain | grep -qxF "worktree $path"; then
    die "git still lists $path as a worktree; run git -C $repo worktree prune, then retry"
  fi
  _cleanup_retired "$path" "$repo" "$branch" true || die "could not record $path in retired.jsonl"
  info "recorded $path as retired${branch:+; a dispatch of its job starts a new desk on $branch or a new branch}"
}

cmd_cleanup() {
  local usage="usage: bercail cleanup [--check] <worktree> | bercail cleanup --gone <path>" wt main common repo branch dest="" ls="" space t out keep check=0
  local snap="" tree='{"end": [], "close": []}' shells='[]' got
  local -a ends=() named=() ended=() killed=()
  [[ "${1:-}" != --check ]] || { check=1; shift; }
  if [[ "${1:-}" == --gone && "$check" -eq 0 ]]; then
    [[ $# -eq 2 && "$2" == /* ]] || die "--gone takes the checkout's absolute path, as its handoff names it; $usage"
    _cleanup_gone "$2"
    return
  fi
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
    _cleanup_unread "could not tell which Herdr space is on $wt: ${space:-neither the Herdr app nor hc answered in full}; nothing was removed"
  }
  if [[ -n "$space" ]]; then
    # Closing the space ends the window's own terminals in it.
    [[ -z "$ls" ]] || shells="$(jq -c --arg id "$space" '[.spaces[] | select(.id == $id) | .tabs[]?.terminals[]?.terminal]' <<<"$ls")"
    mapfile -t named < <(jq -r '.[]' <<<"$shells")
    snap="$(_cleanup_snapshot "${named[@]}")" || _cleanup_unread "$snap; nothing was removed"
    tree="$(_cleanup_tree "$snap" "$space" "$([[ -n "$ls" ]] && echo false || echo true)" "$shells" "$tree")"
    mapfile -t ends < <(jq -r '.end[]' <<<"$tree")
    while IFS= read -r t; do
      [[ "$t" != "${HC_TERMINAL_ID:-}" ]] \
        || die "refusing to clean up $wt from its own space ($t); run it from Shep or another shell"
    done < <(jq -r '.end[], .close[]' <<<"$tree")
    # A terminal still at work, waiting on the person, or not saying, is not
    # done; one another space owns is not cleanup's to end.
    out="$(jq -r --argjson tree "$tree" '[.[] | select((.address | IN($tree.end[], $tree.close[]))
      and (.status | IN("working", "blocked", "unknown"))) | "terminal \(.address) is \(.status)"] + $tree.problems | join("; ")' <<<"$snap")"
    [[ -z "$out" ]] || die "refusing to clean up $wt: $out; nothing was removed"
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
  # Each kill, the removal and the close wait on a fresh look at the whole
  # tree: an end wakes a parent outside it, hc brings one back, an agent
  # starts another. A member that ended with its parent is not ended again.
  for t in "${ends[@]}" ""; do
    [[ -z "$t" || " ${ended[*]} " != *" $t "* ]] || continue
    got="$(_cleanup_recheck "$wt" "$space" "$ls" "$snap" "$tree")" \
      || _cleanup_unread "cleanup stopped: $got; $(_cleanup_left "$dest" "${killed[@]}")"
    out="$(jq -r '.problems | join("; ")' <<<"$got")"
    [[ -z "$out" ]] || die "cleanup stopped: $out; $(_cleanup_left "$dest" "${killed[@]}")"
    while IFS= read -r out; do
      [[ " ${ended[*]} " != *" $out "* ]] || continue
      ended+=("$out")
      info "terminal $out had ended already"
    done < <(jq -r '.ended[]' <<<"$got")
    [[ -n "$t" && " ${ended[*]} " != *" $t "* ]] || continue
    "$HC" kill "$t" >/dev/null \
      || die "could not end terminal $t; $(_cleanup_left "$dest" "${killed[@]}")"
    ended+=("$t")
    killed+=("$t")
    "$HC" rm "$t" >/dev/null 2>&1 || true
    info "ended terminal $t"
  done
  # Off the worktree before it goes; cleanup may run from inside it.
  cd /
  git --git-dir="$common" worktree remove "$wt" \
    || die "could not remove the worktree $wt${ends[*]:+ after ending ${ends[*]}}; its space stays${dest:+, and .bercail/ is archived in $dest}"
  info "removed worktree $wt${branch:+; branch $branch stays}"
  # It is retired either way; unrecorded, its job's next dispatch asks for --gone.
  _cleanup_retired "$wt" "$main" "$branch" false \
    || warn "could not record $wt in retired.jsonl; a dispatch of its job will ask you to run bercail cleanup --gone $wt"
  if [[ -z "$space" ]]; then
    info "no Herdr space was open on $wt"
  else
    if [[ -n "$ls" ]]; then
      keep="$(_wt_herdr_focused_space || true)"
      got="$(_cleanup_recheck "$wt" "$space" "$ls" "$snap" "$tree")" \
        || _cleanup_unread "removed worktree $wt, but did not close Herdr space $space: $got; close it by hand"
      out="$(jq -r '.problems | join("; ")' <<<"$got")"
      [[ -z "$out" ]] || die "removed worktree $wt, but left Herdr space $space open: $out; close it by hand once that is done"
      "$HERDR_APP" "do" space.close --id "$space" --confirmed true >/dev/null \
        || die "herdr-app did not close space $space; close it by hand"
      [[ "$keep" == "$space" ]] || _wt_herdr_keep_user_focus "$keep"
    fi
    info "closed Herdr space $space"
  fi
  # The records of those that ended with their parent, once nothing else waits.
  for t in "${ended[@]}"; do
    [[ " ${killed[*]} " == *" $t "* ]] || "$HC" rm "$t" >/dev/null 2>&1 || true
  done
  # What the person sees, not only the space it closed.
  [[ -z "$ls" ]] || "$HERDR_APP" ls 2>/dev/null \
    | jq -r '"Herdr sidebar: \(.spaces | length) open, \(.recent // [] | length) recent"' || true
}
