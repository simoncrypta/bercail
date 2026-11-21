#!/usr/bin/env bash
# shellcheck shell=bash
# Machine-wide slots for heavy local checks: tests/run.sh and the verify-bercail
# run. At most [tests] slots of them (2) run at once, so desks running suites
# side by side do not starve each other into failing timing tests. Desks, reads
# and model calls are never limited; only these runs wait.
#
# A slot is a file in the state dir that flock(1) holds while its run lasts,
# with a line naming the run. flock -o keeps the lock in its own process and
# out of the run's children, so a background process a test leaves cannot keep
# it, and the kernel drops it once the run ends, killed or not. Holder and
# waiter lines are for people; they are not part of the lock.

# shellcheck source=lib/toml.sh
source "$(dirname "${BASH_SOURCE[0]}")/toml.sh"

slot_dir() {
  printf '%s/bercail/test-slots' "${XDG_STATE_HOME:-$HOME/.local/state}"
}

# [tests] slots, 2 when unset.
slot_count() {
  local n
  n="$(toml_value "${BERCAIL_USER_CONFIG:-$HOME/.config/bercail/config.toml}" tests slots 2)"
  [[ "$n" =~ ^[1-9][0-9]*$ ]] && { printf '%s' "$n"; return 0; }
  printf 'bercail: [tests] slots must be a whole number above 0, not %s (~/.config/bercail/config.toml)\n' "$n" >&2
  return 1
}

# flock's status when someone else holds the file.
SLOT_BUSY=75

# True inside a slot: this run's own, or an outer run's (verify-bercail runs
# the suite inside its slot), or none to take, without flock.
slot_held() {
  local rc=0
  [[ -n "${BERCAIL_TEST_SLOT:-}" ]] || return 1
  [[ "$BERCAIL_TEST_SLOT" != none ]] || return 0
  flock -n -s -E "$SLOT_BUSY" "$BERCAIL_TEST_SLOT" true 2>/dev/null || rc=$?
  ((rc == SLOT_BUSY))
}

# The line of each run that holds a slot now. A file nobody locks is free,
# whatever it says.
slot_holders() {
  local file rc
  for file in "$(slot_dir)"/slot.*; do
    [[ -f "$file" ]] || continue
    rc=0
    flock -n -s -E "$SLOT_BUSY" "$file" true 2>/dev/null || rc=$?
    ((rc != SLOT_BUSY)) || cat "$file"
  done
}

# The line of each run waiting for one; a dead waiter's file goes.
slot_waiters() {
  local file pid
  for file in "$(slot_dir)"/wait.*; do
    [[ -f "$file" ]] || continue
    pid="${file##*.}"
    if kill -0 "$pid" 2>/dev/null; then cat "$file"; else rm -f "$file"; fi
  done
}

# slot_run WHAT CMD...: run CMD in a free slot and return its status. CMD gets
# BERCAIL_TEST_SLOT, so slot_held is true in it, and the slot's line names its
# pid. Waits up to BERCAIL_TEST_SLOT_WAIT seconds (1800) and says once that it
# waits, for whom.
slot_run() {
  local what="$1" dir count limit deadline said=0 n file who wait rc
  shift
  if ! command -v flock >/dev/null 2>&1; then
    BERCAIL_TEST_SLOT=none "$@"
    return
  fi
  count="$(slot_count)" || return 1
  limit="${BERCAIL_TEST_SLOT_WAIT:-1800}"
  [[ "$limit" =~ ^[0-9]+$ ]] || { printf '%s: BERCAIL_TEST_SLOT_WAIT must be whole seconds, not %s\n' "$what" "$limit" >&2; return 1; }
  limit=$((10#$limit))
  deadline=$((SECONDS + limit))
  dir="$(slot_dir)"
  who="$what in $PWD${HC_TERMINAL_ID:+, desk $HC_TERMINAL_ID}"
  # The waiter's line, until the slot's wrapper removes it as CMD starts.
  wait="$dir/wait.$$"
  mkdir -p "$dir" && printf '%s, pid %s, waiting since %(%H:%M:%S)T\n' "$who" "$$" -1 >"$wait" || return 1
  while :; do
    for ((n = 1; n <= count; n++)); do
      file="$dir/slot.$n"
      rc=0
      # shellcheck disable=SC2016 # expands in the wrapper
      BERCAIL_TEST_SLOT="$file" flock -n -E "$SLOT_BUSY" -o "$file" bash -c \
        'rm "$2" && printf "%s, pid %s, since %(%H:%M:%S)T\n" "$1" "$$" -1 >"$BERCAIL_TEST_SLOT" || exit 70
        shift 2
        exec "$@"' slot "$who" "$wait" "$@" || rc=$?
      # Gone, CMD ran and rc is its own. Still there, it never started.
      [[ -e "$wait" ]] || return "$rc"
      if ((rc != SLOT_BUSY)); then
        rm -f "$wait"
        printf '%s: could not take test slot %s (flock exit %s); check that folder\n' "$what" "$file" "$rc" >&2
        return 1
      fi
    done
    if ((!said)); then
      said=1
      printf '%s: waiting for a test slot; all %s ([tests] slots) are taken by:\n' "$what" "$count" >&2
      slot_holders | sed 's/^/  /' >&2
    fi
    if ((SECONDS >= deadline)); then
      rm -f "$wait"
      printf '%s: gave up after %ss waiting for a test slot. Run it again once one of those ends, or raise [tests] slots in ~/.config/bercail/config.toml\n' \
        "$what" "$limit" >&2
      return 1
    fi
    sleep 1
  done
}

# doctor: who holds a slot and who waits for one, once a test run here made
# the folder; a machine that never runs bercail's suite has nothing to show.
doctor_test_slots() {
  local count holders waiters line
  [[ -d "$(slot_dir)" ]] || return 0
  log ""
  if ! count="$(slot_count 2>/dev/null)"; then
    log "Test slots:"
    log "  invalid  [tests] slots = $(toml_value "$BERCAIL_USER_CONFIG" tests slots) (a whole number above 0)"
    return 0
  fi
  log "Test slots (tests/run.sh and the verify-bercail run each take one; [tests] slots = $count):"
  if ! command -v flock >/dev/null 2>&1; then
    log "  off  no flock here, so test runs do not wait for one another"
    return 0
  fi
  holders="$(slot_holders)" waiters="$(slot_waiters)"
  [[ -n "$holders$waiters" ]] || { log "  ok  all free"; return 0; }
  [[ -z "$holders" ]] || while IFS= read -r line; do log "  held  $line"; done <<<"$holders"
  [[ -z "$waiters" ]] || while IFS= read -r line; do log "  waiting  $line"; done <<<"$waiters"
}
