#!/usr/bin/env bash
# shellcheck shell=bash
# bercail scratch: each agent run's own TMPDIR, so the copies a judge or builder
# makes go where bercail can remove them. A run's folder is <root>/<pid>, with
# a lease <root>/.<pid> beside it, outside the agent's reach in its TMPDIR: a
# folder without one is not bercail's and stays. A folder is removed once its
# pid is gone and no process still has it as TMPDIR. Nothing outside the
# private root is ever removed.
#
#   bercail scratch run -- CMD [ARGS...]   CMD with its own TMPDIR, removed when it exits
#   bercail scratch dir PID                make PID's folder and print it (the desk agent execs into PID)
#   bercail scratch sweep                  remove the folders whose run has ended

SCRATCH_USAGE='usage: bercail scratch run -- CMD [ARGS...] | dir PID | sweep'

# On disk, not in /tmp: /tmp is often a tmpfs that shares RAM, and a copy left
# there holds memory until reboot.
scratch_root() {
  printf '%s' "${XDG_CACHE_HOME:-$HOME/.cache}/bercail/scratch"
}

# Everything in the root is bercail's only while nobody else can write there: a
# folder of this user's, not a link, with no group or other write.
_scratch_root_ok() {
  [[ -d "$1" && ! -L "$1" && -O "$1" && -z "$(find "$1" -maxdepth 0 -perm /022)" ]]
}

# PID's folder, printed. One already there is reused, never emptied: it may
# still be in use.
scratch_dir() {
  local pid="$1" root dir
  [[ "$pid" =~ ^[0-9]+$ ]] || die "$SCRATCH_USAGE"
  root="$(scratch_root)"
  if [[ ! -e "$root" && ! -L "$root" ]]; then
    mkdir -p "${root%/*}" || return 1
    mkdir -m 0700 "$root" 2>/dev/null || true
  fi
  _scratch_root_ok "$root" || return 1
  dir="$root/$pid"
  mkdir -m 0700 "$dir" 2>/dev/null || [[ -d "$dir" && ! -L "$dir" ]] || return 1
  : >"$root/.$pid" || return 1
  printf '%s' "$dir"
}

# rm -rf needs write access to each folder, and tests leave read-only ones.
# Only folders: chmod on a file would change a hard-linked file outside too.
# find does not follow links, and rm -rf removes a link, not its target.
_scratch_rm() {
  find "$1" -type d ! -perm -u+w -exec chmod u+w {} + 2>/dev/null || true
  rm -rf "$1"
}

# 0 when a process of this user, other than this one, has DIR as TMPDIR: the
# agent of a wrapper killed alone, or a server an agent left running. This one
# is skipped: a desk's watcher sweeps with the desk's TMPDIR. Without /proc,
# never.
# One grep finds the environments that name the folder's pid, then each entry
# is compared whole: grep would split a path with a newline into two patterns.
_scratch_held() {
  local dir="$1" env var
  local -a envs=()
  mapfile -d '' envs < <(grep -lZzF -e "${dir##*/}" /proc/[0-9]*/environ 2>/dev/null)
  for env in "${envs[@]}"; do
    [[ -O "$env" && "$env" != "/proc/$$/environ" ]] || continue
    while IFS= read -r -d '' var; do
      [[ "$var" != "TMPDIR=$dir" ]] || return 0
    done 2>/dev/null <"$env"
  done
  return 1
}

# 0 when DIR's run has ended: its pid is gone (ps sees a process kill -0 may
# not signal), and nothing holds it.
_scratch_ended() {
  ! ps -p "${1##*/}" >/dev/null 2>&1 && ! _scratch_held "$1"
}

# Removes DIR and its lease, once the root is checked again: the run could have
# swapped it for a link. A lease whose folder is gone goes too.
_scratch_drop() {
  local dir="$1" root="${1%/*}"
  _scratch_root_ok "$root" && [[ -f "$root/.${dir##*/}" ]] || return 1
  if [[ -d "$dir" && ! -L "$dir" ]]; then
    _scratch_rm "$dir"
  elif [[ -e "$dir" || -L "$dir" ]]; then
    return 1
  fi
  rm -f "$root/.${dir##*/}"
}

# A run's own end: its folder goes unless something still holds it, which the
# next sweep then removes once it has ended.
_scratch_release() {
  _scratch_held "$1" || _scratch_drop "$1" || true
}

# Calls FN with each leased folder whose run has ended.
_scratch_each_ended() {
  local fn="$1" root lease pid
  root="$(scratch_root)"
  _scratch_root_ok "$root" || return 0
  for lease in "$root"/.[0-9]*; do
    pid="${lease##*/.}"
    [[ -f "$lease" && ! -L "$lease" && "$pid" =~ ^[0-9]+$ ]] || continue
    _scratch_ended "$root/$pid" && "$fn" "$root/$pid"
  done
  return 0
}

_scratch_remove() {
  _scratch_drop "$1" && info "removed $1"
  return 0
}

scratch_sweep() {
  _scratch_each_ended _scratch_remove
}

# Runs in the foreground, so a TUI keeps the terminal. A signal's trap waits for
# CMD to end, so the folder outlives CMD's last write. Without a folder CMD
# still runs, on the TMPDIR it was given.
scratch_run() {
  local dir="" rc=0
  [[ "${1:-}" != -- ]] || shift
  [[ $# -gt 0 ]] || die "$SCRATCH_USAGE"
  if dir="$(scratch_dir "$$")"; then
    export TMPDIR="$dir"
    # shellcheck disable=SC2064 # dir is fixed now
    trap "_scratch_release $(printf '%q' "$dir")" EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
  else
    warn "no scratch folder under $(scratch_root); $1 runs on TMPDIR=${TMPDIR:-/tmp}"
  fi
  "$@" || rc=$?
  exit "$rc"
}

_scratch_name_leftover() {
  local size
  [[ -d "$1" && ! -L "$1" ]] || return 0
  size="$(du -sh "$1" 2>/dev/null | cut -f1)"
  log "  leftover  $1 (${size:-?}; bercail scratch sweep removes it)"
  SCRATCH_LEFTOVER=1
}

# doctor: name each folder a run left behind, with its size.
doctor_scratch() {
  local root
  root="$(scratch_root)"
  SCRATCH_LEFTOVER=0
  log ""
  log "Scratch (each agent's TMPDIR):"
  if [[ -e "$root" || -L "$root" ]] && ! _scratch_root_ok "$root"; then
    log "  invalid  $root is a link or not yours alone, so agents run without scratch (remove it; the next agent makes it)"
    return 0
  fi
  _scratch_each_ended _scratch_name_leftover
  [[ "$SCRATCH_LEFTOVER" -eq 1 ]] || log "  ok  no leftover scratch in $(scratch_root)"
}

cmd_scratch() {
  local sub="${1:-}"
  shift || true
  case "$sub" in
    run) scratch_run "$@" ;;
    dir) [[ $# -eq 1 ]] || die "$SCRATCH_USAGE"; scratch_dir "$1" ;;
    sweep) [[ $# -eq 0 ]] || die "$SCRATCH_USAGE"; scratch_sweep ;;
    *) die "$SCRATCH_USAGE" ;;
  esac
}
