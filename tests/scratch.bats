#!/usr/bin/env bats
# lib/scratch.sh: each agent run's own TMPDIR, removed when the run ends, and
# never anything bercail did not make. A temp HOME; the runs are real bash.
# shellcheck disable=SC2016 # the bash -c scripts expand in the child

setup() {
  load test_helper
  isolate
  ROOT_DIR="$XDG_CACHE_HOME/bercail/scratch"
}

scratch() { "$ROOT/bin/bercail" scratch "$@"; }

# A pid that has ended: the sleep is the process, gone once waited for.
dead_pid() {
  sleep 0 &
  DEAD=$!
  wait "$DEAD"
}

# Folders as bercail makes them: each with its lease beside it.
made() {
  local dir
  for dir in "$@"; do
    mkdir -p "$dir"
    : >"${dir%/*}/.${dir##*/}"
  done
}

# Waits until PID has ended, a zombie included; fails after 10s.
until_gone() {
  local _
  for _ in $(seq 1 100); do
    [[ "$(ps -o stat= -p "$1" 2>/dev/null)" == Z* || -z "$(ps -o pid= -p "$1" 2>/dev/null)" ]] && return 0
    sleep 0.1
  done
  fail "pid $1 is still running"
}

@test "a copy made in scratch run goes under the cache, not the temp dir, and is gone when the command exits" {
  local rc=0 seen copy
  scratch run -- bash -c '
    printf "%s" "$TMPDIR" >"$0/seen"
    copy="$(mktemp -d)" && printf "%s" "$copy" >"$0/copy"
    cp -r "$1/lib" "$copy/" && chmod -R a-w "$copy/lib"
    exit 3' "$BATS_TEST_TMPDIR" "$ROOT" || rc=$?
  [[ "$rc" -eq 3 ]] || fail "the command's status is the run's: got $rc"
  seen="$(cat "$BATS_TEST_TMPDIR/seen")" copy="$(cat "$BATS_TEST_TMPDIR/copy")"
  [[ "$seen" =~ ^"$ROOT_DIR"/[0-9]+$ ]] || fail "TMPDIR is <root>/<pid>: $seen"
  [[ "$copy" == "$seen"/* ]] || fail "mktemp -d made the copy outside the run's folder: $copy"
  [[ -z "$(ls -A "$TMPDIR")" ]] || fail "the run wrote to the temp dir it was given: $(ls -A "$TMPDIR")"
  [[ ! -e "$seen" ]] || fail "the folder outlived its run: $(ls -lR "$seen")"
  [[ ! -e "${seen%/*}/.${seen##*/}" ]] || fail "its lease outlived the run"
}

@test "a signal ends scratch run only after the command, then removes the folder" {
  local rc=0 seen
  scratch run -- bash -c '
    printf "%s" "$TMPDIR" >"$0/seen"
    kill -TERM "$PPID"
    sleep 0.2
    [[ -d "$TMPDIR" ]] && touch "$0/still-there"' "$BATS_TEST_TMPDIR" || rc=$?
  [[ "$rc" -eq 143 ]] || fail "TERM ends the run as TERM: got $rc"
  [[ -e "$BATS_TEST_TMPDIR/still-there" ]] || fail "the folder went before the command ended"
  seen="$(cat "$BATS_TEST_TMPDIR/seen")"
  [[ "$seen" == "$ROOT_DIR"/* && ! -e "$seen" ]] || fail "the folder outlived a signalled run: $seen"
}

@test "sweep removes the folders whose run has ended, and nothing else" {
  local outside="$BATS_TEST_TMPDIR/outside" gone link unleased
  dead_pid; gone=$DEAD
  dead_pid; link=$DEAD
  dead_pid; unleased=$DEAD
  made "$ROOT_DIR/$gone/copy" "$ROOT_DIR/$$"
  : >"$ROOT_DIR/.$gone"
  mkdir -p "$ROOT_DIR/notes" "$ROOT_DIR/$unleased" "$outside/keep" "$TMPDIR/5wm832-judge.$gone"
  chmod a-w "$ROOT_DIR/$gone/copy"
  ln -s "$outside" "$ROOT_DIR/$link"
  : >"$ROOT_DIR/.$link"
  scratch sweep >"$BATS_TEST_TMPDIR/out"
  [[ ! -e "$ROOT_DIR/$gone" && ! -e "$ROOT_DIR/.$gone" ]] || fail "a dead run's folder or its lease stayed"
  grep -qxF "→ removed $ROOT_DIR/$gone" "$BATS_TEST_TMPDIR/out" || fail "sweep says what it removed: $(cat "$BATS_TEST_TMPDIR/out")"
  [[ -d "$ROOT_DIR/$$" ]] || fail "a live run's folder went"
  [[ -d "$ROOT_DIR/notes" ]] || fail "a folder not named for a pid went"
  [[ -d "$ROOT_DIR/$unleased" ]] || fail "a folder with no lease went: bercail did not make it"
  [[ -d "$outside/keep" && -L "$ROOT_DIR/$link" ]] || fail "a link, or what it points at, went"
  [[ -d "$TMPDIR/5wm832-judge.$gone" ]] || fail "a folder outside the scratch root went"
}

@test "a folder stays while its command lives on after the wrapper was killed alone, a newline in its path too" {
  local wrapper child
  export XDG_CACHE_HOME="$BATS_TEST_TMPDIR/c"$'\n'"d"
  ROOT_DIR="$XDG_CACHE_HOME/bercail/scratch"
  "$ROOT/bin/bercail" scratch run -- bash -c 'printf "%s" "$$" >"$0/child"; exec sleep 30' "$BATS_TEST_TMPDIR" &
  wrapper=$!
  for _ in $(seq 1 100); do [[ -s "$BATS_TEST_TMPDIR/child" ]] && break; sleep 0.1; done
  child="$(cat "$BATS_TEST_TMPDIR/child")" || fail "the command never started"
  kill -KILL "$wrapper"
  wait "$wrapper" 2>/dev/null || true
  scratch sweep >/dev/null
  [[ -d "$ROOT_DIR/$wrapper" ]] || { kill "$child"; fail "a sweep took the folder of a command still running"; }
  kill "$child"
  until_gone "$child"
  scratch sweep >/dev/null
  [[ ! -e "$ROOT_DIR/$wrapper" ]] || fail "the folder stayed once its command ended"
}

@test "a folder a detached command still holds outlives its run, and a sweep takes it once that ends" {
  local seen child
  scratch run -- bash -c 'printf "%s" "$TMPDIR" >"$0/seen"; sleep 30 >/dev/null 2>&1 & printf "%s" "$!" >"$0/child"' "$BATS_TEST_TMPDIR"
  seen="$(cat "$BATS_TEST_TMPDIR/seen")" child="$(cat "$BATS_TEST_TMPDIR/child")"
  [[ -d "$seen" ]] || { kill "$child"; fail "the run took a folder a live command holds"; }
  kill "$child"
  until_gone "$child"
  scratch sweep >/dev/null
  [[ ! -e "$seen" ]] || fail "the folder stayed once nothing held it"
}

@test "a run that swaps the root for a link does not make its end remove what the link points at" {
  local outside="$BATS_TEST_TMPDIR/outside"
  mkdir -p "$outside"
  scratch run -- bash -c '
    root="${TMPDIR%/*}" name="${TMPDIR##*/}"
    mkdir "$0/$name" && : >"$0/$name/keep" && : >"$0/.$name"
    mv "$root" "$root.real" && ln -s "$0" "$root"' "$outside"
  [[ -e "$outside/$(ls "$outside")/keep" ]] || fail "the run's end removed a folder behind the link"
  compgen -G "$outside/.[0-9]*" >/dev/null || fail "the run's end removed a lease behind the link"
}

@test "scratch dir reuses a folder already there, and keeps what is in it" {
  mkdir -p "$ROOT_DIR/$$"
  : >"$ROOT_DIR/$$/work"
  [[ "$(scratch dir "$$")" == "$ROOT_DIR/$$" ]] || fail "it prints the folder"
  [[ -e "$ROOT_DIR/$$/work" ]] || fail "it emptied a folder that may be in use"
}

@test "a sweep never reaches outside the root: not a hard link's file, not a path cut at a newline" {
  local cache="$BATS_TEST_TMPDIR/c"$'\n'"d" outside="$BATS_TEST_TMPDIR/outside"
  dead_pid
  made "$cache/bercail/scratch/$DEAD"
  mkdir -p "$cache/bercail/scratch/$DEAD/ro" "$BATS_TEST_TMPDIR/c" "$outside"
  : >"$outside/file"
  chmod 0444 "$outside/file"
  ln "$outside/file" "$cache/bercail/scratch/$DEAD/ro/file"
  chmod a-w "$cache/bercail/scratch/$DEAD/ro"
  XDG_CACHE_HOME="$cache" scratch sweep >/dev/null
  [[ ! -e "$cache/bercail/scratch/$DEAD" ]] || fail "the dead run's folder stayed"
  [[ -d "$BATS_TEST_TMPDIR/c" ]] || fail "a path cut at the newline was removed"
  [[ "$(stat -c %a "$outside/file")" == 444 ]] || fail "the hard-linked file outside changed mode: $(stat -c %a "$outside/file")"
}

# bercail doctor on the test HOME. Only system tools on PATH, so no hc or Pi
# is reached; doctor exits 1 there, for the parts a temp HOME lacks.
doctor() {
  PATH="$BATS_TEST_TMPDIR/bin:/usr/bin:/bin" "$ROOT/bin/bercail" doctor 2>&1 || true
}

@test "doctor names each leftover scratch folder with its size, and no live one" {
  local out size
  out="$(doctor)"
  [[ "$out" == *"  ok  no leftover scratch in $ROOT_DIR"* ]] || fail "none left: $out"
  dead_pid
  made "$ROOT_DIR/$DEAD" "$ROOT_DIR/$$"
  head -c 2097152 /dev/urandom >"$ROOT_DIR/$DEAD/copy"
  read -r size _ < <(du -sh "$ROOT_DIR/$DEAD")
  out="$(doctor)"
  [[ "$out" == *"  leftover  $ROOT_DIR/$DEAD ($size; bercail scratch sweep removes it)"* ]] || fail "names it with its size: $out"
  [[ "$out" != *"$ROOT_DIR/$$"* && "$out" != *"ok  no leftover"* ]] || fail "only the leftover: $out"
}

@test "a scratch root others can write to is not used, swept, or called ok" {
  dead_pid
  made "$ROOT_DIR/$DEAD"
  chmod 0777 "$ROOT_DIR"
  scratch run -- true 2>"$BATS_TEST_TMPDIR/err"
  grep -q "no scratch folder under $ROOT_DIR" "$BATS_TEST_TMPDIR/err" || fail "it says why: $(cat "$BATS_TEST_TMPDIR/err")"
  scratch sweep >/dev/null
  [[ -d "$ROOT_DIR/$DEAD" ]] || fail "a sweep ran in a root others can write to"
  [[ "$(doctor)" == *"  invalid  $ROOT_DIR is a link or not yours alone"* ]] || fail "doctor: $(doctor)"
}

@test "a scratch root that is a link is not used, swept, or called ok" {
  local elsewhere="$BATS_TEST_TMPDIR/elsewhere" seen
  dead_pid
  made "$elsewhere/$DEAD"
  mkdir -p "${ROOT_DIR%/*}"
  ln -s "$elsewhere" "$ROOT_DIR"
  scratch run -- bash -c 'printf "%s" "$TMPDIR" >"$0/seen"' "$BATS_TEST_TMPDIR" 2>"$BATS_TEST_TMPDIR/err"
  seen="$(cat "$BATS_TEST_TMPDIR/seen")"
  [[ "$seen" == "$TMPDIR" ]] || fail "the command runs on the TMPDIR it was given: $seen"
  grep -q "no scratch folder under $ROOT_DIR" "$BATS_TEST_TMPDIR/err" || fail "it says why: $(cat "$BATS_TEST_TMPDIR/err")"
  scratch sweep >/dev/null
  [[ -d "$elsewhere/$DEAD" ]] || fail "a sweep went through the link"
  [[ "$(doctor)" == *"  invalid  $ROOT_DIR is a link or not yours alone"* ]] || fail "doctor: $(doctor)"
}
