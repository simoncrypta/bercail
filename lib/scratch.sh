#!/usr/bin/env bash
# shellcheck shell=bash
# bercail scratch: each agent run's own TMPDIR, so the copies a judge or builder
# makes go where bercail can remove them. A run's folder is <root>/<pid>, with
# a lease <root>/.<pid> beside it, outside the agent's reach in its TMPDIR: a
# folder without one is not bercail's and stays. A folder is removed once its
# pid is gone and no process still has it as TMPDIR. Nothing outside the
# private root is ever removed.
# A sweep also clears what agents and their tools still leave in /tmp: this
# user's own entries there, once nothing in them changed or was read for a few
# days and no live process holds them (see the temp dir, below).
#
#   bercail scratch run -- CMD [ARGS...]   CMD with its own TMPDIR, removed when it exits
#   bercail scratch dir PID                make PID's folder and print it (the desk agent execs into PID)
#   bercail scratch sweep [--dry-run] [--days N]
#                                          remove the folders whose run has ended, and old /tmp entries

SCRATCH_USAGE='usage: bercail scratch run -- CMD [ARGS...] | dir PID | sweep [--dry-run] [--days N]'

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
# find does not follow links, and rm -rf removes a link, not its target. Neither
# crosses into a file system mounted inside.
_scratch_rm() {
  find "$1" -xdev -type d ! -perm -u+w -exec chmod u+w {} + 2>/dev/null || true
  rm -rf --one-file-system "$1"
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

_scratch_would_remove() {
  log "would remove $1"
}

# --- the temp dir ---
# Agents and their tools still leave files in /tmp, often a tmpfs that holds
# RAM, and systemd-tmpfiles clears it only after 10 days. Each sweep, at every
# recorded desk's start and end, also removes this user's own entries there
# that nothing changed or read for SCRATCH_TMP_DAYS days and that no live
# process holds. When it cannot tell, it keeps the entry. It cannot see into a
# process of this user's that keeps its /proc entries closed (a non-dumpable
# one), and an entry opened between its look and its rm still goes; that
# process keeps its open file. BERCAIL_TMP_ROOT stands in for /tmp in tests.

SCRATCH_TMP_DAYS=2

scratch_tmp_root() {
  printf '%s' "${BERCAIL_TMP_ROOT:-/tmp}"
}

# What the last sweep of the temp dir did, for doctor.
_scratch_tmp_record() {
  printf '%s' "${XDG_STATE_HOME:-$HOME/.local/state}/bercail/tmp-sweep.json"
}

# Names that belong to a session or a service, whatever their age: the
# desktop's sockets and locks, tmux's and ssh's folders, a JVM's perf data.
_scratch_tmp_kept() {
  case "${1##*/}" in
    dbus-* | systemd-* | .X* | tmux-* | ssh-* | hsperfdata_*) return 0 ;;
  esac
  return 1
}

# What live processes of this user hold, one per line: as device:inode, each
# file one has open, works in, runs or has as TMPDIR, and, as an inode alone,
# each file one maps (maps names the device as mountinfo does, which differs
# from stat's on btrfs; a stray match only keeps more). Not paths: a path can be
# spelled many ways, and a hard link or a bind mount gives a file another one.
# Other users' processes cannot be read, so each lookup fails in part.
_scratch_tmp_held_ids() {
  local path
  {
    find -L /proc/[0-9]*/fd -mindepth 1 -maxdepth 1 -printf '%D:%i\n' || true
    find -L /proc/[0-9]*/cwd /proc/[0-9]*/exe -maxdepth 0 -printf '%D:%i\n' || true
    cat /proc/[0-9]*/maps | awk '$5 != 0 { print $5 }' || true
    _scratch_tmp_tmpdirs | while IFS= read -r -d '' path; do
      [[ "$path" != "?" ]] || { printf '?\n'; continue; }
      stat -L -c '%d:%i' -- "$path" || true
    done
  } 2>/dev/null | sort -u
}

# PATH as a process sees it, through ROOT and DIR, its /proc root and cwd: an
# absolute PATH from ROOT, a relative one from DIR. Each symlink is followed in
# that view, an absolute one from ROOT again, not from this process's /. Prints
# the path under ROOT or DIR, then a dot, so a final newline survives $( ).
# A .. stops at the process's root, as its kernel does (a chroot). Fails with 2
# past 40 links, a TMPDIR the process cannot use either, and with 1 when a link
# cannot be read.
_scratch_tmp_resolve() {
  local root="$1" base="$2" path="$3" done="" comp target links=0
  local -a rest more
  [[ "$path" != /* ]] || base="$root"
  mapfile -td / rest < <(printf '%s' "$path")
  while ((${#rest[@]})); do
    comp="${rest[0]}"
    rest=("${rest[@]:1}")
    case "$comp" in
      "" | .) ;;
      # done has no links in it, so dropping its last part is its parent.
      ..) if [[ -n "$done" ]]; then done="${done%/*}"; elif ! [[ "$base" -ef "$root" ]]; then base="$base/.."; fi ;;
      *)
        if [[ -L "$base$done/$comp" ]]; then
          ((++links <= 40)) || return 2
          target="$(readlink -- "$base$done/$comp" && printf .)" || return 1
          target="${target%$'\n.'}"
          mapfile -td / more < <(printf '%s' "$target")
          rest=("${more[@]}" "${rest[@]}")
          [[ "$target" != /* ]] || { base="$root" done=""; }
        else
          done="$done/$comp"
        fi
        ;;
    esac
  done
  printf '%s.' "$base$done"
}

# Each process's TMPDIR as that process sees it (its mounts, its cwd, its
# links), NUL-separated. One whose link it cannot read, of a process still
# there, prints "?": then nothing is swept.
# Only the TMPDIR a process started with is in /proc; one it sets later is not.
_scratch_tmp_tmpdirs() {
  local line env value pid rc
  while IFS= read -r -d '' line; do
    env="${line%%:TMPDIR=*}" value="${line#*:TMPDIR=}"
    pid="${env#/proc/}" pid="${pid%/environ}"
    [[ -n "$value" && "$pid" =~ ^[0-9]+$ ]] || continue
    rc=0
    value="$(_scratch_tmp_resolve "/proc/$pid/root" "/proc/$pid/cwd" "$value")" || rc=$?
    if ((rc == 0)); then
      printf '%s\0' "${value%.}"
    elif ((rc == 1)) && [[ -e "/proc/$pid" ]]; then
      # Not a process that ended mid-lookup: one whose TMPDIR this cannot place.
      printf '?\0'
    fi
  done < <(grep -zH -- '^TMPDIR=' /proc/[0-9]*/environ 2>/dev/null)
}

# The top-level names under ROOT, a resolved path, that a mount shows
# somewhere else: a bind of a folder in there. One per line. A mount that shows
# all of ROOT elsewhere, besides the one it sits in, shows every name: then
# the one line is "/". Only this process's mount namespace is read; a mount in
# another one (a container, a sandbox) counts only through what its processes
# hold.
_scratch_tmp_aliased() {
  local root="$1" dev="" mdev mroot point inside="" best=""
  # The mount the root sits in, the deepest that holds it: its device as
  # mountinfo names it (stat's differs on btrfs), and the root's path in there.
  while read -r _ _ mdev mroot point _; do
    point="$(printf '%b' "$point")"
    if [[ ( "$root" == "$point" || "$root" == "${point%/}"/* ) && ${#point} -ge ${#best} ]]; then
      best="$point" dev="$mdev" inside="$(printf '%b' "$mroot")${root#"$point"}"
    fi
  done </proc/self/mountinfo
  [[ -n "$dev" ]] || return 0
  inside="/${inside#/}"
  inside="${inside%/}"
  while read -r _ _ mdev mroot point _; do
    [[ "$mdev" == "$dev" ]] || continue
    mroot="$(printf '%b' "$mroot")"
    if [[ "$mroot" == "$inside"/?* ]]; then
      mroot="${mroot#"$inside"/}"
      printf '%s\n' "${mroot%%/*}"
    elif [[ "$(printf '%b' "$point")" != "$best" && ( "$mroot" == / || "$inside/" == "${mroot%/}"/* ) ]]; then
      printf '/\n'
    fi
  done </proc/self/mountinfo
}

# 0 when a mount point is ENTRY or inside it. rm --one-file-system goes into a
# bind mount of the same file system, so one there would take what it shows.
# mountinfo writes a space, tab, newline or backslash in a path as \NNN.
_scratch_tmp_mounted() {
  local entry="$1" point
  while read -r _ _ _ _ point _; do
    point="$(printf '%b' "$point")"
    [[ "$point" != "$entry" && "$point" != "$entry"/* ]] || return 0
  done </proc/self/mountinfo
  return 1
}

# 0 when all of ENTRY is old and the user's: nothing in it changed in DAYS
# days, no file in it was read then, it holds no socket, no name in it has a
# newline, and everything in it is UID's. find must read all of it.
_scratch_tmp_old() {
  local entry="$1" days="$2" uid="$3" min found
  min=$((days * 1440))
  found="$(find "$entry" -xdev \( -type s -o -mmin "-$min" -o \( ! -type d -amin "-$min" \) \
    -o ! -user "$uid" -o -name $'*\n*' \) -print -quit 2>/dev/null)" || return 1
  [[ -z "$found" ]]
}

# 0 when a file in ENTRY is one HELD names, by device:inode or inode. grep's
# own status: it stops at a match, and find's SIGPIPE then must not read as none.
_scratch_tmp_holds() {
  local entry="$1" held="$2"
  [[ -n "$held" ]] || return 1
  grep -qxF -f <(printf '%s\n' "$held") < <(find "$entry" -xdev -printf '%D:%i\n%i\n' 2>/dev/null)
}

# Calls FN with each top-level entry in the temp dir that may go: the user's
# own, old all through, holding nothing a live process holds, not a mount and
# with none inside, not shown elsewhere by one, not a kept name, and with no
# newline in its name. Never a socket or another user's.
_scratch_tmp_each_old() {
  local fn="$1" days="$2" root entry name uid ids
  local -A aliased=()
  root="$(scratch_tmp_root)"
  [[ -d "$root" && ! -L "$root" ]] || return 0
  root="$(realpath -e -- "$root")" || return 0
  uid="$(id -u)"
  ids="$(_scratch_tmp_held_ids)"
  # A process's TMPDIR it could not place may be any entry.
  [[ $'\n'"$ids"$'\n' != *$'\n?\n'* ]] || return 0
  while IFS= read -r name; do
    [[ -z "$name" ]] || aliased["$name"]=1
  done < <(_scratch_tmp_aliased "$root")
  [[ -z "${aliased[/]:-}" ]] || return 0
  while IFS= read -r -d '' entry; do
    name="${entry##*/}"
    [[ "$name" != *$'\n'* && -z "${aliased[$name]:-}" ]] && ! _scratch_tmp_kept "$name" || continue
    _scratch_tmp_old "$entry" "$days" "$uid" && ! _scratch_tmp_mounted "$entry" || continue
    ! _scratch_tmp_holds "$entry" "$ids" || continue
    "$fn" "$entry"
  done < <(find "$root" -mindepth 1 -maxdepth 1 -user "$uid" ! -type s -print0 2>/dev/null)
}

_scratch_tmp_would_remove() {
  local kb
  kb="$(du -sk --one-file-system -- "$1" 2>/dev/null | cut -f1)"
  log "would remove $1 ($(_scratch_tmp_size "$kb"))"
  SCRATCH_TMP_COUNT=$((SCRATCH_TMP_COUNT + 1))
}

_scratch_tmp_remove() {
  _scratch_rm "$1"
  [[ ! -e "$1" && ! -L "$1" ]] || return 0
  info "removed $1"
  SCRATCH_TMP_COUNT=$((SCRATCH_TMP_COUNT + 1))
}

# Removes the old entries and records what it did; with DRY 1, only lists them.
# With flock and XDG_RUNTIME_DIR, when several desks end together, one sweeps
# and the others skip.
_scratch_tmp_sweep() {
  local dry="$1" days="$2" record tmp fd
  SCRATCH_TMP_COUNT=0
  if [[ "$dry" -eq 1 ]]; then
    _scratch_tmp_each_old _scratch_tmp_would_remove "$days"
    log "would remove $SCRATCH_TMP_COUNT entries from $(scratch_tmp_root) older than $days days"
    return 0
  fi
  if [[ -n "${XDG_RUNTIME_DIR:-}" ]] && command -v flock >/dev/null 2>&1; then
    exec {fd}>"$XDG_RUNTIME_DIR/bercail-tmp-sweep.lock" || return 0
    flock -n "$fd" || return 0
  fi
  _scratch_tmp_each_old _scratch_tmp_remove "$days"
  [[ "$SCRATCH_TMP_COUNT" -eq 0 ]] || info "removed $SCRATCH_TMP_COUNT entries from $(scratch_tmp_root) older than $days days"
  record="$(_scratch_tmp_record)"
  mkdir -p "${record%/*}" && tmp="$(mktemp "$record.XXXXXX")" || return 0
  jq -n --arg root "$(scratch_tmp_root)" --argjson days "$days" --argjson removed "$SCRATCH_TMP_COUNT" \
    '{at: (now | todate), root: $root, days: $days, removed: $removed}' >"$tmp" \
    && mv "$tmp" "$record" || rm -f "$tmp"
}

scratch_sweep() {
  local dry=0 days="$SCRATCH_TMP_DAYS"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) dry=1; shift ;;
      --days) days="${2:-}"; shift 2 || shift $# ;;
      --days=*) days="${1#*=}"; shift ;;
      *) die "$SCRATCH_USAGE" ;;
    esac
  done
  [[ "$days" =~ ^[1-9][0-9]{0,3}$ && "$days" -le 3650 ]] || die "--days takes a whole number of days, 1 to 3650: $days"
  if [[ "$dry" -eq 1 ]]; then
    _scratch_each_ended _scratch_would_remove
  else
    _scratch_each_ended _scratch_remove
  fi
  _scratch_tmp_sweep "$dry" "$days"
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

_scratch_tmp_size() {
  numfmt --to=iec --from-unit=1024 "${1:-0}"
}

# doctor: the temp dir's use against its size, and the last sweep of it.
doctor_scratch_tmp() {
  local root used size record at removed days
  root="$(scratch_tmp_root)"
  log ""
  log "Temp dir ($root; each recorded desk's start and end sweeps your entries older than $SCRATCH_TMP_DAYS days):"
  if read -r used size < <(df -k --output=used,size "$root" 2>/dev/null | tail -n 1) && [[ "$size" =~ ^[0-9]+$ && "$size" -gt 0 ]]; then
    if ((used * 100 / size >= 80)); then
      log "  high  $(_scratch_tmp_size "$used") used of $(_scratch_tmp_size "$size") ($((used * 100 / size))%); bercail scratch sweep --dry-run --days 1 lists what a sweep would take"
    else
      log "  ok  $(_scratch_tmp_size "$used") used of $(_scratch_tmp_size "$size") ($((used * 100 / size))%)"
    fi
  fi
  record="$(_scratch_tmp_record)"
  if IFS=$'\t' read -r at removed days < <(jq -r '[.at, .removed, .days] | @tsv' "$record" 2>/dev/null); then
    log "  ok  last sweep $at: removed $removed entries older than $days days"
  else
    log "  none  no sweep yet (each desk's start runs one; so does bercail scratch sweep)"
  fi
}

cmd_scratch() {
  local sub="${1:-}"
  shift || true
  case "$sub" in
    run) scratch_run "$@" ;;
    dir) [[ $# -eq 1 ]] || die "$SCRATCH_USAGE"; scratch_dir "$1" ;;
    sweep) scratch_sweep "$@" ;;
    *) die "$SCRATCH_USAGE" ;;
  esac
}
