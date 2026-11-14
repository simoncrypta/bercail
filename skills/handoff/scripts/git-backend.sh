#!/usr/bin/env bash
# Shared git backend for one repo: gh, gt, origin, or entire.
# Sourced by handoff-spawn (beside this file) and by the bercail CLI (the
# install copies this file to lib/git-backend.sh). Detection never runs gt.
# shellcheck shell=bash

# shellcheck source=skills/handoff/scripts/toml.sh
source "$(dirname "${BASH_SOURCE[0]}")/toml.sh"

# Primary worktree of ROOT, canonicalized. Empty output and status 1 when ROOT
# is not a git checkout. Config keys use this path.
git_backend_main() {
  local path
  path="$(git -C "$1" worktree list --porcelain 2>/dev/null \
    | awk '/^worktree / { print substr($0, 10); exit }')" || true
  [[ -n "$path" && -d "$path" ]] || return 1
  (cd "$path" && pwd -P)
}

# Absolute .graphite_repo_config in the shared git dir, or status 1.
# A linked worktree's own git dir never holds it; --git-path would miss it.
git_backend_graphite_config() {
  local cfg
  cfg="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  [[ -n "$cfg" ]] || return 1
  cfg="$cfg/.graphite_repo_config"
  [[ -f "$cfg" ]] || return 1
  printf '%s' "$cfg"
}

_git_backend_config_file() {
  printf '%s' "${BERCAIL_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/bercail/config.toml}"
}

_git_backend_realpath() {
  local path="$1"
  if [[ -d "$path" ]]; then
    (cd "$path" && pwd -P)
  else
    printf '%s' "$path"
  fi
}

# This repo's [git] entry (gh|gt|origin|entire), keyed by the main checkout.
# Status 1 with no entry. A value that is not one of the four is ignored.
git_backend_override() {
  local config main key value
  config="$(_git_backend_config_file)"
  [[ -f "$config" ]] || return 1
  main="$(git_backend_main "$1")" || return 1
  while IFS=$'\t' read -r value key; do
    [[ "$key" != \~/* ]] || key="$HOME/${key#\~/}"
    [[ "$(_git_backend_realpath "$key")" == "$main" ]] || continue
    printf '%s' "$value"
    return 0
  done < <(toml_records "$config" \
    | jq -r 'select(.section == ["git"]) | (.value // .raw) as $v | select($v | IN("gh", "gt", "origin", "entire")) | $v + "\t" + .key')
  return 1
}

# v0.11: a config file alone is not Graphite. A non-trunk refs/branch-metadata
# ref, or a parented row in .graphite_metadata.db, is. No gt command.
# Warns when the file is there but nothing is tracked, or the store cannot be read.
git_backend_graphite_tracks() {
  local root="$1" cfg trunks refs db rows main
  cfg="$(git_backend_graphite_config "$root")" || return 1
  main="$(git_backend_main "$root" 2>/dev/null || true)"
  trunks="$(jq -r '[.trunk, .trunks[]?.name] | map(select(. != null)) | .[]' "$cfg" 2>/dev/null || true)"
  refs="$(git -C "$root" for-each-ref --format='%(refname:lstrip=2)' refs/branch-metadata/ 2>/dev/null || true)"
  if [[ -n "$refs" ]] && grep -qvxF -e "$trunks" <<<"$refs"; then
    return 0
  fi
  db="$(dirname "$cfg")/.graphite_metadata.db"
  if [[ -f "$db" ]]; then
    if ! rows="$("${HANDOFF_SQLITE3_BIN:-sqlite3}" -readonly "$db" \
      "select 1 from branch_metadata where coalesce(parent_branch_name, '') <> '' limit 1" 2>/dev/null)"; then
      printf 'handoff-spawn: cannot read %s (sqlite3 missing, database busy, or unknown schema); skipping Graphite. Set "%s" = "gt" or "gh" under [git] in bercail config.toml to override.\n' \
        "$db" "$main" >&2
      return 1
    fi
    [[ -z "$rows" ]] || return 0
  fi
  printf 'handoff-spawn: gt has a config here but tracks no branch, so not using Graphite. If this repo uses it, set "%s" = "gt" under [git] in bercail config.toml.\n' \
    "$main" >&2
  return 1
}

# Offline: origin remote URL is an Origin git host. Not an ownership decision.
# Host is origin.cursor.com or origin-<alnum>.cursor.com. Path is /org/repo or
# /git/org/repo (https or scp). A GitHub remote is not a candidate.
git_backend_origin_remote() {
  local url host path
  url="$(git -C "$1" remote get-url origin 2>/dev/null)" || return 1
  url="${url%"${url##*[![:space:]]}"}"
  url="${url#"${url%%[![:space:]]*}"}"
  url="${url%.git}"
  url="${url%/}"
  host=""
  path=""
  if [[ "$url" != *://* && "$url" =~ ^([^@:/]+@)?([^:/]+):(.+)$ ]]; then
    host="${BASH_REMATCH[2]}"
    path="${BASH_REMATCH[3]}"
  elif [[ "$url" =~ ^[a-zA-Z][a-zA-Z0-9+.-]*://([^/@]+@)?([^/:]+)(:[0-9]+)?(/.*)?$ ]]; then
    host="${BASH_REMATCH[2]}"
    path="${BASH_REMATCH[4]}"
  else
    return 1
  fi
  host="${host,,}"
  [[ "$host" =~ ^origin(-[a-z0-9]+)?\.cursor\.com$ ]] || return 1
  path="${path#/}"
  path="${path%.git}"
  path="${path%/}"
  [[ -n "$path" ]] || return 1
  local -a segs=()
  local seg
  IFS=/ read -r -a segs <<<"$path"
  local -a kept=()
  for seg in "${segs[@]}"; do
    [[ -n "$seg" ]] && kept+=("$seg")
  done
  if [[ ${#kept[@]} -eq 3 && "${kept[0],,}" == git ]]; then
    return 0
  fi
  [[ ${#kept[@]} -eq 2 && "${kept[0],,}" != git ]]
}

# Offline: origin is a repo hosted on Entire, entire://<host>/et/<project>/<repo>.
# A mirror (entire://<host>/gh/<owner>/<repo>) is not: GitHub owns it and its
# PRs, so it stays gh.
git_backend_entire_remote() {
  local url
  url="$(git -C "$1" remote get-url origin 2>/dev/null)" || return 1
  [[ "$url" =~ ^entire://[^/]+/et/[^/]+/[^/]+$ ]]
}

# Entire captures agent sessions in the checkout at ROOT: .entire/settings.json
# that does not say enabled: false, where settings.local.json, when it says
# either, has the last word. policy_json hands it to the guard.
git_backend_entire_capture() {
  local dir="$1/.entire" enabled=""
  [[ -f "$dir/settings.json" ]] || return 1
  [[ ! -f "$dir/settings.local.json" ]] \
    || enabled="$(jq -r '.enabled | select(type == "boolean")' "$dir/settings.local.json" 2>/dev/null)" || true
  [[ -n "$enabled" ]] || enabled="$(jq -r '.enabled != false' "$dir/settings.json" 2>/dev/null)" || return 1
  [[ "$enabled" == true ]]
}

# Status 124 on timeout. Kill leftover children even after a successful command:
# otherwise they can hold the caller's pipes open.
# Signal only the worker group, never the desk or its sibling terminals.
_git_backend_bounded() {
  local ticks=$(($1 * 10)) pid rc
  shift
  (
    # Job notices go to this shell's stderr: /dev/null. The command gets the caller's.
    exec 3>&2 2>/dev/null
    set -m
    "$@" 2>&3 3>&- &
    pid=$!
    set +m
    # Signal death stops a foreground caller too; plain exit 130 can carry on.
    trap 'kill -KILL -- "-$pid" 2>/dev/null || true; trap - INT; kill -INT "$BASHPID"' INT
    trap 'kill -KILL -- "-$pid" 2>/dev/null || true; exit 143' TERM
    while kill -0 "$pid" 2>/dev/null; do
      if [[ "$ticks" -le 0 ]]; then
        kill -TERM -- "-$pid" 2>/dev/null || true
        sleep 1
        kill -KILL -- "-$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        exit 124
      fi
      ticks=$((ticks - 1))
      sleep 0.1
    done
    rc=0
    wait "$pid" || rc=$?
    kill -KILL -- "-$pid" 2>/dev/null || true
    exit "$rc"
  )
}

_git_backend_origin_unknown() {
  printf 'handoff-spawn: could not tell whether Origin owns this repo (%s); using gh. Set "%s" = "origin" or "gh" under [git] in bercail config.toml.\n' \
    "$1" "$2" >&2
}

# Ownership, only after git_backend_origin_remote. no-mirror or outbound → 0.
# A reported other mirrorStatus → 1 (GitHub owns it; the probe succeeded).
# No CLI, a failed lookup, a timeout, or no mirrorStatus → 1, with a warning
# that names the [git] override. A matched host is not ownership.
# Never called for a non-Origin remote, so --info does not probe GitHub repos.
git_backend_origin_owns() {
  local root="$1" raw status rc=0 main
  main="$(git_backend_main "$root" 2>/dev/null || printf '%s' "$root")"
  if ! command -v origin >/dev/null 2>&1; then
    _git_backend_origin_unknown "origin is not on PATH" "$main"
    return 1
  fi
  raw="$(
    cd "$root" || exit 1
    _git_backend_bounded 10 origin repo view --json mirrorStatus </dev/null
  )" || rc=$?
  # Interrupted: do not invent gh. The caller exits 130.
  [[ "$rc" -ne 130 ]] || return 130
  if [[ "$rc" -eq 124 ]]; then
    _git_backend_origin_unknown "origin repo view timed out" "$main"
    return 1
  fi
  if [[ "$rc" -ne 0 ]]; then
    _git_backend_origin_unknown "origin repo view failed" "$main"
    return 1
  fi
  status="$(jq -r '.mirrorStatus // empty' <<<"$raw" 2>/dev/null || true)"
  case "$status" in
    no-mirror|outbound) return 0 ;;
    "")
      _git_backend_origin_unknown "mirrorStatus missing" "$main"
      return 1
      ;;
    *) return 1 ;;
  esac
}

# Print gh, gt, origin, or entire.
# 1. The repo's [git] entry.
# 2. Graphite tracking evidence (v0.11). No gt.
# 3. An origin hosted on Entire (et/). A GitHub mirror on Entire stays gh.
# 4. Origin remote whose mirrorStatus is no-mirror or outbound.
#    A matched host with unknown ownership stays gh and warns.
# 5. gh.
git_backend() {
  local override
  if override="$(git_backend_override "$1")"; then
    printf '%s' "$override"
    return 0
  fi
  if git_backend_graphite_tracks "$1"; then
    printf 'gt'
    return 0
  fi
  if git_backend_entire_remote "$1"; then
    printf 'entire'
    return 0
  fi
  if git_backend_origin_remote "$1"; then
    local owns=0
    git_backend_origin_owns "$1" || owns=$?
    if [[ "$owns" -eq 0 ]]; then
      printf 'origin'
      return 0
    fi
    # Ctrl-C during the probe must not become a backend guess.
    [[ "$owns" -ne 130 ]] || return 130
  fi
  printf 'gh'
}
