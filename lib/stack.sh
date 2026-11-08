#!/usr/bin/env bash
# shellcheck shell=bash
# Stack discovery for bercail review-pr.
#
# Backend: shared handoff detection chooses gh, gt, or origin. A Graphite
# config alone is not evidence: only tracked branches (or an override) select gt.
# Local `gt log` is not the source of truth (it can omit a remote stack). Sync
# with `gt get` only in a private clone (its own git dir, never a linked
# worktree of the source). Never run gt against the source: even
# `gt get --no-checkout` rewrites branches. After get, the private clone is
# switched onto the PR branch so `gt log short --stack` (current branch, no
# JSON) can list it. Order is that drawing plus each branch's Parent from
# `gt branch info --branch`. The log is taken from the stack root, with a
# second `gt get` in the private clone only when the named branch is not the
# root, so a sibling below the entry is not missed. gt 1.8.6 leaves Children:
# empty, so it is not used.
#
# Otherwise: walk baseRefName down to trunk and `gh pr list --base` up from the
# root, not from the PR that was named. A fork or two open PRs on one head
# reviews that PR alone (its own run dir), never a partial root stack. A cycle
# or a truncated list is still an error. Trunk is
# origin/HEAD, or the repo's default branch when there is no checkout. Down
# does not ask `--head <trunk>`. A cross-repo head is not a parent and is not
# walked up from; a single cross-repo child of a same-repo branch can still be
# in the stack.
#
# No local checkout: the caller clones a normal repo to $HOME/Work/<repo>
# (or $HOME/Work/<owner>-<repo> when the first path exists and is a different
# repo; never overwrite) and adds the review worktree beside it. A fresh clone
# has no .graphite_repo_config, so that path uses the GitHub walk.

_stack_strip_ansi() {
  local s="$1"
  printf '%s' "$s" | sed $'s/\x1b\\[[0-9;]*[A-Za-z]//g'
}

# Source tree: symlink to the skill script. Installed CLI: a standalone copy.
# shellcheck source=lib/git-backend.sh
source "$(dirname "${BASH_SOURCE[0]}")/git-backend.sh"


_stack_trunk_name() {
  jq -r '.trunk // .trunks[0].name // "main"' "$1"
}

_stack_trunk_names() {
  jq -r '[.trunk, (.trunks[]?.name)] | map(select(. != null and . != "")) | unique[]' "$1"
}

# Tip-first branch names from `gt log short --stack`, one per line.
# Exit 2 when the drawing is a fork (┴ ┬ ┘ ┐): do not pick a side.
_stack_parse_log() {
  local line rest name
  local -a names=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="$(_stack_strip_ansi "$line")"
    [[ "$line" == *◯* || "$line" == *◉* ]] || continue
    if [[ "$line" == *┴* || "$line" == *┬* || "$line" == *┘* || "$line" == *┐* || "$line" == *┌* || "$line" == *└* ]]; then
      printf 'branched stack in gt log short; refusing to pick a side\n' >&2
      return 2
    fi
    rest="$(printf '%s' "$line" | sed -E 's/.*[◯◉][[:space:]]*//')"
    name="$(printf '%s' "$rest" | awk '{ print $1 }')"
    [[ -n "$name" ]] || continue
    names+=("$name")
  done
  [[ ${#names[@]} -gt 0 ]] || {
    printf 'gt log short --stack listed no branches\n' >&2
    return 1
  }
  printf '%s\n' "${names[@]}"
}

# JSON: {parent, pr} from `gt branch info` text. No JSON flag on gt 1.8.6.
# Children: is empty even when the branch has a child (gt 1.8.6), so it is not read.
_stack_parse_info() {
  local line parent="" pr=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="$(_stack_strip_ansi "$line")"
    if [[ "$line" == Parent:* ]]; then
      parent="${line#Parent:}"
      parent="${parent#"${parent%%[![:space:]]*}"}"
      parent="${parent%"${parent##*[![:space:]]}"}"
      continue
    fi
    if [[ "$line" =~ ^PR\ \#([0-9]+) ]]; then
      pr="${BASH_REMATCH[1]}"
    fi
  done
  jq -nc --arg parent "$parent" --arg pr "$pr" \
    '{parent: $parent, pr: (if $pr == "" then null else ($pr | tonumber) end)}'
}

_stack_gt_info() {
  local cwd="$1" branch="$2" out err
  err="$(mktemp)"
  out="$(gt branch info --branch "$branch" --no-interactive --cwd "$cwd" 2>"$err")" || {
    printf 'gt branch info %s failed: %s\n' "$branch" "$(<"$err")" >&2
    rm -f "$err"
    return 1
  }
  rm -f "$err"
  _stack_parse_info <<<"$out"
}

_stack_seen_add() {
  local -n _seen="$1"
  local key="$2"
  [[ -z "${_seen[$key]:-}" ]] || {
    printf 'cycle in stack at %s\n' "$key" >&2
    return 1
  }
  _seen["$key"]=1
}

# Private clone: own git dir, origin copied from source, graphite config copied in.
# gt get rewrites branches here and nowhere else.
_stack_private_clone() {
  local source="$1" dest="$2" origin a b cfg destcfg
  origin="$(git -C "$source" remote get-url origin)" || return 1
  if [[ ! -d "$dest/.git" && ! -f "$dest/.git" ]]; then
    mkdir -p "$(dirname "$dest")"
    git clone --quiet "$source" "$dest" >&2 || return 1
  fi
  a="$(git -C "$source" rev-parse --path-format=absolute --git-common-dir)"
  b="$(git -C "$dest" rev-parse --path-format=absolute --git-common-dir)"
  [[ "$a" != "$b" ]] || {
    printf 'private Graphite clone shares a git dir with the source; refusing to sync\n' >&2
    return 1
  }
  git -C "$dest" remote set-url origin "$origin" || return 1
  cfg="$a/.graphite_repo_config"
  destcfg="$b/.graphite_repo_config"
  cp "$cfg" "$destcfg"
}

_stack_gt_get() {
  local sync="$1" branch="$2" err
  err="$(mktemp)"
  gt get "$branch" --remote-upstack --no-checkout --no-restack --no-interactive --cwd "$sync" >"$err" 2>&1 || {
    printf 'gt get %s failed in the private clone: %s\n' "$branch" "$(<"$err")" >&2
    rm -f "$err"
    return 1
  }
  rm -f "$err"
}

# Checkout only in the private clone, then `gt log short --stack` (current branch).
_stack_gt_log() {
  local sync="$1" branch="$2" err log
  err="$(mktemp)"
  git -C "$sync" checkout --quiet --force "$branch" >&2 || {
    printf 'private clone has no branch %s after gt get\n' "$branch" >&2
    rm -f "$err"
    return 1
  }
  log="$(gt log short --stack --no-interactive --cwd "$sync" 2>"$err")" || {
    printf 'gt log short --stack failed: %s\n' "$(<"$err")" >&2
    rm -f "$err"
    return 1
  }
  rm -f "$err"
  printf '%s\n' "$log"
}

# origin/HEAD when a checkout exists, else the repo's default branch.
# Never `gh pr list --head <trunk>`: that lists fork PRs whose head is named trunk.
_stack_trunk() {
  local source="$1" slug="$2" ref name
  if [[ -n "$source" ]]; then
    ref="$(git -C "$source" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null || true)"
    if [[ "$ref" == refs/remotes/origin/* ]]; then
      printf '%s' "${ref#refs/remotes/origin/}"
      return 0
    fi
  fi
  name="$(gh repo view "$slug" --json defaultBranchRef | jq -r '.defaultBranchRef.name // empty')" || return 1
  [[ -n "$name" && "$name" != null ]] || return 1
  printf '%s' "$name"
}

_stack_log_reaches_trunk() {
  local cfg="$1" trunk="$2" last="$3" line hit=0
  while IFS= read -r line; do
    [[ "$last" == "$line" ]] && hit=1
  done < <(_stack_trunk_names "$cfg")
  [[ "$hit" -eq 1 ]] || {
    printf 'gt log short --stack did not reach trunk %s (ended at %s)\n' "$trunk" "$last" >&2
    return 1
  }
}

# Prints root-first PR numbers, one per line. Trunk is not a PR.
_stack_graphite() {
  local source="$1" branch="$2" sync="$3" cfg trunk
  local -a branches=()
  local line parent pr log info
  command -v gt >/dev/null 2>&1 || {
    printf 'review-pr needs gt on PATH (this repo is Graphite-initialized)\n' >&2
    return 1
  }
  _stack_private_clone "$source" "$sync" || return 1
  cfg="$(git -C "$sync" rev-parse --path-format=absolute --git-common-dir)/.graphite_repo_config"
  trunk="$(_stack_trunk_name "$cfg")"
  # --no-checkout: get must not switch. The checkout below is only in this clone.
  _stack_gt_get "$sync" "$branch" || return 1
  log="$(_stack_gt_log "$sync" "$branch")" || return 1
  local parsed root_branch found=0
  parsed="$(_stack_parse_log <<<"$log")" || return $?
  while IFS= read -r line; do
    [[ -n "$line" ]] && branches+=("$line")
  done <<<"$parsed"
  _stack_log_reaches_trunk "$cfg" "$trunk" "${branches[${#branches[@]} - 1]}" || return 1
  # A log from a non-root branch omits siblings below it. Re-log from the root.
  if [[ ${#branches[@]} -ge 2 ]]; then
    root_branch="${branches[${#branches[@]} - 2]}"
    if [[ "$branch" != "$root_branch" ]]; then
      _stack_gt_get "$sync" "$root_branch" || return 1
      log="$(_stack_gt_log "$sync" "$root_branch")" || return 1
      parsed="$(_stack_parse_log <<<"$log")" || return $?
      branches=()
      while IFS= read -r line; do
        [[ -n "$line" ]] && branches+=("$line")
      done <<<"$parsed"
      _stack_log_reaches_trunk "$cfg" "$trunk" "${branches[${#branches[@]} - 1]}" || return 1
    fi
  fi
  # shellcheck disable=SC2034 # nameref target of _stack_seen_add
  local -A seen=()
  local i name next
  for name in "${branches[@]}"; do
    _stack_seen_add seen "$name" || return 1
    [[ "$name" == "$branch" ]] && found=1
  done
  [[ "$found" -eq 1 ]] || {
    printf 'branch %s is not in the root stack; refusing to guess\n' "$branch" >&2
    return 1
  }
  local -a prs=()
  for ((i = 0; i < ${#branches[@]} - 1; i++)); do
    name="${branches[$i]}"
    info="$(_stack_gt_info "$sync" "$name")" || return 1
    parent="$(jq -r '.parent' <<<"$info")"
    pr="$(jq -r '.pr // empty' <<<"$info")"
    next="${branches[$((i + 1))]}"
    # Linearity is the log drawing (a fork character fails the parse) plus this
    # parent. gt 1.8.6 prints Children: with no names, so that list is not used.
    [[ "$parent" == "$next" ]] || {
      printf 'gt branch info parent of %s is %s, but gt log short --stack says %s; refusing to guess\n' \
        "$name" "${parent:-"(none)"}" "$next" >&2
      return 1
    }
    [[ -n "$pr" ]] || {
      printf 'branch %s has no PR in gt branch info\n' "$name" >&2
      return 1
    }
    prs+=("$pr")
  done
  [[ ${#prs[@]} -gt 0 ]] || {
    printf 'gt log short --stack of %s has no PRs above trunk\n' "$branch" >&2
    return 1
  }
  # Log is tip-first. The stack is root-first.
  for ((i = ${#prs[@]} - 1; i >= 0; i--)); do
    printf '%s\n' "${prs[$i]}"
  done
}

_stack_gh_list() {
  local slug="$1" flag="$2" value="$3"
  gh pr list --"$flag" "$value" --state open --limit 50 -R "$slug" \
    --json number,baseRefName,headRefName,isCrossRepository,url
}

# Drop fork PRs whose head is only a same-named branch in another repo.
_stack_same_repo() {
  jq -c '[.[] | select(.isCrossRepository != true)]'
}

# Root-first PR numbers. ENTRY is the requested PR's view JSON. TRUNK is not a PR head.
_stack_github() {
  local slug="$1" entry="$2" trunk="$3"
  local n base head count kid listed cur owned="" cross
  # shellcheck disable=SC2034 # nameref target of _stack_seen_add
  local -A down_seen=()
  n="$(jq -r '.number' "$entry")"
  cur="$entry"
  while true; do
    _stack_seen_add down_seen "$n" || return 1
    base="$(jq -r '.baseRefName' "$cur")"
    # Trunk is this repo's default branch, not a parent PR. Do not --head it.
    [[ "$base" == "$trunk" ]] && break
    listed="$(_stack_gh_list "$slug" head "$base")" || return 1
    listed="$(_stack_same_repo <<<"$listed")"
    count="$(jq 'length' <<<"$listed")"
    if [[ "$count" -gt 1 ]]; then
      return 2
    fi
    [[ "$count" -eq 1 ]] || break
    n="$(jq -r '.[0].number' <<<"$listed")"
    [[ -n "$owned" ]] && rm -f "$cur"
    cur="$(mktemp)"
    owned=1
    gh pr view "$n" -R "$slug" --json number,baseRefName,headRefName,isCrossRepository >"$cur" || return 1
  done
  # cur is the root. Walk up from here with a fresh seen set so the entry is not a false cycle.
  n="$(jq -r '.number' "$cur")"
  head="$(jq -r '.headRefName' "$cur")"
  cross="$(jq -r '.isCrossRepository // false' "$cur")"
  [[ -n "$owned" ]] && rm -f "$cur"
  owned=""
  # shellcheck disable=SC2034
  local -A up_seen=()
  local -a stack=()
  _stack_seen_add up_seen "$n" || return 1
  stack+=("$n")
  # A cross-repo head is not a branch in this repo. Do not list PRs based on it.
  if [[ "$cross" != true ]]; then
    while true; do
      listed="$(_stack_gh_list "$slug" base "$head")" || return 1
      count="$(jq 'length' <<<"$listed")"
      if [[ "$count" -ge 50 ]]; then
        printf 'branched or truncated stack: 50 open PRs are based on %s; refusing to guess\n' "$head" >&2
        return 1
      fi
      if [[ "$count" -gt 1 ]]; then
        return 2
      fi
      [[ "$count" -eq 1 ]] || break
      kid="$(jq -r '.[0].number' <<<"$listed")"
      _stack_seen_add up_seen "$kid" || return 1
      stack+=("$kid")
      cross="$(jq -r '.[0].isCrossRepository // false' <<<"$listed")"
      [[ "$cross" == true ]] && break
      head="$(jq -r '.[0].headRefName' <<<"$listed")"
    done
  fi
  printf '%s\n' "${stack[@]}"
}

# Prints one JSON object: {via, trunk, numbers:[root..tip]}.
# source may be empty (GitHub walk only). sync is the private clone path.
# A fork is not fatal: review the named PR alone, in its own run dir.
_stack_alone() {
  local entry="$1" via="${2:-github}" n
  n="$(jq -r '.number' "$entry")"
  printf 'branched stack; reviewing PR #%s alone\n' "$n" >&2
  jq -nc --argjson n "$n" --arg via "$via" --arg trunk "$(jq -r '.baseRefName' "$entry")" \
    '{via: $via, trunk: $trunk, numbers: [$n]}'
}

# Validate a native backend's parent graph before emitting a linear PR order.
_stack_native_order() {
  local payload="$1" parent count row branch n total used=0
  # shellcheck disable=SC2034 # nameref targets of _stack_seen_add
  local -A seen=() pr_seen=()
  parent="$(jq -r '.trunk | sub("^refs/heads/"; "")' <<<"$payload")"
  total="$(jq '.members | length' <<<"$payload")"
  [[ "$total" -gt 0 && -n "$parent" && "$parent" != null ]] || return 1
  _stack_seen_add seen "$parent" || return 1
  while [[ "$used" -lt "$total" ]]; do
    row="$(jq -c --arg parent "$parent" '[.members[] | select((.parent | sub("^refs/heads/"; "")) == $parent)]' <<<"$payload")" || return 1
    count="$(jq length <<<"$row")"
    [[ "$count" -le 1 ]] || return 2
    [[ "$count" -eq 1 ]] || { printf 'disconnected or cyclic native stack\n' >&2; return 1; }
    branch="$(jq -r '.[0].branch | sub("^refs/heads/"; "")' <<<"$row")"
    n="$(jq -r '.[0].number // empty' <<<"$row")"
    [[ "$n" =~ ^[1-9][0-9]*$ ]] || { printf 'stack branch %s has no PR\n' "$branch" >&2; return 1; }
    _stack_seen_add seen "$branch" || return 1
    _stack_seen_add pr_seen "$n" || return 1
    printf '%s\n' "$n"
    parent="$branch"
    used=$((used + 1))
  done
}

# Select by requested PR/head, not whichever stack happens to be checked out.
_stack_gh_stack() {
  local source="$1" entry="$2" sync="$3" slug="$4" catalog selected=null branch remote payload common name err rc=0 remote_stack=0
  common="$(git -C "$source" rev-parse --path-format=absolute --git-common-dir)" || return 1
  catalog="$common/gh-stack"
  if [[ -f "$catalog" ]]; then
    selected="$(jq -c --argjson n "$(jq '.number' "$entry")" --arg head "$(jq -r .headRefName "$entry")" \
      '[.stacks[] | select(any(.branches[]; .pullRequest.number == $n or .branch == $head))] |
       if length == 0 then null elif length == 1 then .[0] else error("ambiguous stack membership") end' "$catalog")" || return 1
  fi
  err="$(mktemp)"
  payload="$(gh api --hostname "${slug%%/*}" "repos/${slug#*/}/stacks?pull_request=$(jq '.number' "$entry")" 2>"$err")" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    if grep -q 'HTTP 404' "$err"; then
      payload='[]'
    else
      printf 'GitHub stack discovery failed: %s\n' "$(<"$err")" >&2
      rm -f "$err"
      return 1
    fi
  fi
  rm -f "$err"
  jq -e 'type == "array"' <<<"$payload" >/dev/null || return 1
  case "$(jq length <<<"$payload")" in
    0) [[ "$selected" != null ]] || return 3 ;;
    1) remote_stack=1 ;;
    *) return 1 ;;
  esac
  remote="$(git -C "$source" remote get-url origin)" || return 1
  if [[ ! -d "$sync/.git" ]]; then
    git clone --quiet "$source" "$sync" >&2 || return 1
  fi
  [[ "$(git -C "$sync" rev-parse --path-format=absolute --git-common-dir)" != "$common" ]] || return 1
  git -C "$sync" remote set-url origin "$remote" || return 1
  # This clone is disposable. Detach before moving its branch refs so a repeat
  # gather cannot leave its index/worktree at an older branch tip.
  git -C "$sync" checkout --quiet --detach --force >&2 || return 1
  if [[ "$remote_stack" -eq 1 ]]; then
    # checkout prefers local membership. Discard only this private catalog so
    # a previous review cannot hide newly added remote stack members.
    rm -f "$sync/.git/gh-stack"
    (cd "$sync" && gh stack checkout "$(jq -r '.url' "$entry")" </dev/null >&2) || return 1
  else
    cp "$catalog" "$sync/.git/gh-stack" || return 1
    git -C "$sync" fetch --quiet origin >&2 || return 1
    while IFS= read -r name; do
      if git -C "$sync" rev-parse --verify "refs/remotes/origin/$name" >/dev/null 2>&1; then
        git -C "$sync" update-ref "refs/heads/$name" "refs/remotes/origin/$name" || return 1
      fi
    done < <(jq -r '.branches[].branch' <<<"$selected")
    branch="$(jq -r '.headRefName' "$entry")"
    git -C "$sync" checkout --quiet -B "$branch" "$(jq -r '.headRefOid' "$entry")" >&2 || return 1
  fi
  payload="$(cd "$sync" && gh stack view --json </dev/null)" || return 1
  jq -c '. as $s | {trunk, members: [.branches | to_entries[] |
    {branch: .value.name, parent: (if .key == 0 then $s.trunk else $s.branches[.key - 1].name end), number: .value.pr.number}]}' <<<"$payload"
}

_stack_origin_stack() {
  local slug="$2" n="$3" neutral rc=0
  # Even view can reconcile/write records inside a checkout. Query remotely
  # outside any repository so stale local records cannot hide remote members.
  neutral="$(mktemp -d)" || return 1
  (cd "$neutral" && origin stack view "$n" -R "${slug#*/}" --json source,trunk,members </dev/null) || rc=$?
  rmdir "$neutral"
  return "$rc"
}

stack_discover() {
  local slug="$1" entry="$2" source="$3" sync="$4" via trunk text line rc=0 n backend="${5:-}" payload
  local -a numbers=()
  n="$(jq -r '.number' "$entry")"
  if [[ -z "$backend" ]]; then
    backend=gh
    [[ -z "$source" ]] || backend="$(git_backend "$source")"
  fi
  if [[ "$backend" == origin ]]; then
    via=origin
    payload="$(_stack_origin_stack "$source" "$slug" "$n")" || return 1
    trunk="$(jq -r '.trunk | sub("^refs/heads/"; "")' <<<"$payload")"
    text="$(_stack_native_order "$payload")" || rc=$?
  elif [[ "$backend" == gt && -n "$source" ]] \
    && jq -e '.isCrossRepository != true' "$entry" >/dev/null; then
    via=graphite
    trunk="$(_stack_trunk_name "$(git -C "$source" rev-parse --path-format=absolute --git-common-dir)/.graphite_repo_config")"
    text="$(_stack_graphite "$source" "$(jq -r '.headRefName' "$entry")" "$sync")" || rc=$?
  else
    via=github
    trunk="$(_stack_trunk "$source" "$slug")" || {
      printf 'could not tell the trunk branch for %s\n' "$slug" >&2
      return 1
    }
    if [[ -n "$source" ]] && jq -e '.isCrossRepository != true' "$entry" >/dev/null; then
      payload="$(_stack_gh_stack "$source" "$entry" "$sync" "$slug")" || rc=$?
    else
      rc=3
    fi
    if [[ "$rc" -eq 3 ]]; then
      rc=0
      text="$(_stack_github "$slug" "$entry" "$trunk")" || rc=$?
    elif [[ "$rc" -eq 0 ]]; then
      via=gh-stack
      trunk="$(jq -r .trunk <<<"$payload")"
      text="$(_stack_native_order "$payload")" || rc=$?
    fi
  fi
  if [[ "$rc" -eq 2 ]]; then
    if [[ "$backend" == origin ]]; then _stack_alone "$entry" origin; else _stack_alone "$entry"; fi
    return 0
  fi
  [[ "$rc" -eq 0 ]] || return "$rc"
  while IFS= read -r line; do
    [[ -n "$line" ]] && numbers+=("$line")
  done <<<"$text"
  # Always the root PR's base, even when that is not the default branch.
  if [[ "$via" == github ]]; then
    if [[ "${numbers[0]}" == "$n" ]]; then
      trunk="$(jq -r '.baseRefName' "$entry")"
    else
      trunk="$(gh pr view "${numbers[0]}" -R "$slug" --json baseRefName | jq -r .baseRefName)" || return 1
    fi
  fi
  [[ ${#numbers[@]} -gt 0 ]] || return 1
  printf '%s\n' "${numbers[@]}" | grep -qxF "$n" || {
    printf 'native stack omitted requested PR #%s\n' "$n" >&2
    return 1
  }
  jq -nc --arg via "$via" --arg trunk "$trunk" --args \
    '{via: $via, trunk: $trunk, numbers: ($ARGS.positional | map(tonumber))}' -- "${numbers[@]}"
}
