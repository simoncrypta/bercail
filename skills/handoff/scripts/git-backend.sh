#!/usr/bin/env bash
# Shared git backend for one repo: gh, gt, or origin.
# Sourced by handoff-spawn (beside this file) and by the bercail CLI (the
# install copies this file to lib/git-backend.sh). Detection never runs gt.
# shellcheck shell=bash

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

# This repo's [git] entry (gh|gt|origin), else its legacy [graphite] bool
# (true → gt, false → gh). Keyed by the main checkout. Status 1 with no entry.
# A value that is not an enum or a bool is ignored. [git] wins when both match.
git_backend_override() {
  local config main key value section git_val="" graphite_val=""
  config="$(_git_backend_config_file)"
  [[ -f "$config" ]] || return 1
  main="$(git_backend_main "$1")" || return 1
  while IFS=$'\t' read -r section key value; do
    [[ "$key" != \~/* ]] || key="$HOME/${key#\~/}"
    [[ "$(_git_backend_realpath "$key")" == "$main" ]] || continue
    case "$section" in
      git)
        [[ -n "$git_val" ]] || git_val="$value"
        ;;
      graphite)
        [[ -n "$graphite_val" ]] || graphite_val="$value"
        ;;
    esac
  done < <(awk '
    /^[[:space:]]*\[/ {
      sec = $0
      sub(/#.*/, "", sec)
      gsub(/[[:space:]"\047]/, "", sec)
      next
    }
    sec != "[git]" && sec != "[graphite]" { next }
    {
      line = $0
      sub(/^[[:space:]]*/, "", line)
      q = substr(line, 1, 1)
      if (q != "\"" && q != "\047") next
      line = substr(line, 2)
      i = index(line, q)
      if (!i) next
      key = substr(line, 1, i - 1)
      value = substr(line, i + 1)
      sub(/^[[:space:]]*=[[:space:]]*/, "", value)
      sub(/[[:space:]]*(#.*)?$/, "", value)
      if (sec == "[graphite]" && (value == "true" || value == "false")) {
        print "graphite\t" key "\t" value
        next
      }
      if (sec == "[git]") {
        v = value
        gsub(/^["\047]|["\047]$/, "", v)
        if (v == "gh" || v == "gt" || v == "origin") print "git\t" key "\t" v
      }
    }' "$config")
  if [[ -n "$git_val" ]]; then
    printf '%s' "$git_val"
    return 0
  fi
  case "$graphite_val" in
    true) printf 'gt'; return 0 ;;
    false) printf 'gh'; return 0 ;;
  esac
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
      printf 'handoff-spawn: cannot read %s (sqlite3 missing, database busy, or unknown schema); skipping Graphite. Set "%s" = true or false under [graphite] in bercail config.toml to override.\n' \
        "$db" "$main" >&2
      return 1
    fi
    [[ -z "$rows" ]] || return 0
  fi
  printf 'handoff-spawn: gt has a config here but tracks no branch, so not using Graphite. If this repo uses it, set "%s" = true under [graphite] in bercail config.toml.\n' \
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

# Kill a command that outlives $1 seconds. Status 124 on timeout. The command
# gets its own process group; only that group is signaled. Not timeout(1):
# macOS has none. Do not kill -INT 0: this file is sourced by the desk, and
# process group 0 is the lead.
_git_backend_bounded() {
  local ticks=$(($1 * 10)) pid rc
  shift
  (
    set -m
    "$@" &
    pid=$!
    set +m
    trap 'kill -KILL -- "-$pid" 2>/dev/null; exit 130' INT
    trap 'kill -KILL -- "-$pid" 2>/dev/null; exit 143' TERM
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

# Print gh, gt, or origin.
# 1. [git] enum, else legacy [graphite] bool.
# 2. Graphite tracking evidence (v0.11). No gt.
# 3. Origin remote whose mirrorStatus is no-mirror or outbound.
#    A matched host with unknown ownership stays gh and warns.
# 4. gh.
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
