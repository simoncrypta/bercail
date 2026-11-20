#!/usr/bin/env bats
# lib/scratch.sh: each agent run's own TMPDIR, removed when the run ends, and
# never anything bercail did not make. A temp HOME; the runs are real bash.
# shellcheck disable=SC2016 # the bash -c scripts expand in the child

# A sweep reads every process in /proc: one test's holder would keep or stop
# what another test's sweep does, so this file's tests run one at a time.
setup_file() {
  export BATS_NO_PARALLELIZE_WITHIN_FILE=true
}

setup() {
  load test_helper
  isolate
  ROOT_DIR="$XDG_CACHE_HOME/bercail/scratch"
}

scratch() { "$ROOT/bin/bercail" scratch "$@"; }

# Processes a test started to hold something, and a file another uid owns:
# both go even when the test fails.
teardown() {
  local pid
  if [[ -f "$BATS_TEST_TMPDIR/holders" ]]; then
    while read -r pid; do kill "$pid" 2>/dev/null || true; done <"$BATS_TEST_TMPDIR/holders"
  fi
  [[ ! -e "$BATS_TEST_TMPDIR/foreign" ]] || in_userns rm -rf "$(cat "$BATS_TEST_TMPDIR/foreign")"
}

# CMD as root of a user namespace that maps this uid to 0 and a range of
# subordinate ids from 1, with a mount namespace of its own.
in_userns() {
  unshare --user --map-root-user --map-users=auto --map-groups=auto --mount "$@"
}

# Skips a test this machine cannot set up: no user namespaces, or no
# subordinate ids. Such a test only asks the sweep to keep something.
need_userns() {
  in_userns true 2>/dev/null || skip "no user namespace with subordinate ids here"
}

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

# --- the temp dir: BERCAIL_TMP_ROOT, isolate's stand-in for /tmp ---

# Entries in the temp dir, each with everything in it last changed DAYS ago.
aged() {
  local days="$1" path
  shift
  for path in "$@"; do
    find "$path" -depth -exec touch -h -d "$days days ago" {} +
  done
}

# A unix socket at $1: node binds it and exits. Bound from its folder: a
# socket path is at most 107 bytes.
socket_at() {
  (cd "$(dirname "$1")" && node -e 'require("node:net").createServer().listen(process.argv[1], () => process.exit(0))' "./$(basename "$1")")
}

@test "a sweep removes your own temp dir entries nothing changed in 2 days, read-only folders too, and records it" {
  local tmp="$BERCAIL_TMP_ROOT" record="$XDG_STATE_HOME/bercail/tmp-sweep.json" out
  mkdir -p "$tmp/desk-secret-x/bin/op" "$tmp/.pnpm-store/v3" "$tmp/bats-run-old/test" "$tmp/fresh" "$tmp/stirred/deep"
  : >"$tmp/desk-secret-x/bin/op/op" && : >"$tmp/prstate-final.json" && : >"$tmp/stirred/deep/old"
  head -c 2048 /dev/urandom >"$tmp/.pnpm-store/v3/blob"
  chmod a-w "$tmp/desk-secret-x/bin/op" "$tmp/desk-secret-x/bin"
  aged 3 "$tmp/desk-secret-x" "$tmp/.pnpm-store" "$tmp/bats-run-old" "$tmp/prstate-final.json" "$tmp/stirred"
  aged 1 "$tmp/stirred/deep"
  out="$(scratch sweep)"
  for gone in desk-secret-x .pnpm-store bats-run-old prstate-final.json; do
    [[ ! -e "$tmp/$gone" ]] || fail "$gone is past the cut-off and stayed: $out"
    [[ "$out" == *"removed $tmp/$gone"* ]] || fail "the sweep does not name $gone: $out"
  done
  [[ -d "$tmp/fresh" && -f "$tmp/stirred/deep/old" ]] || fail "an entry changed within 2 days went: $(ls -A "$tmp")"
  jq -e --arg root "$tmp" '.root == $root and .days == 2 and .removed == 4 and (.at | fromdate) > 0' "$record" >/dev/null \
    || fail "the record: $(cat "$record")"
}

@test "a sweep keeps sockets, session folders, and what a live process holds, however old" {
  need node
  local tmp="$BERCAIL_TMP_ROOT" kept pid _ held=()
  local -a names=(dbus-abc systemd-private-x .X11-unix .X0-lock tmux-1000 ssh-agent1 hsperfdata_me
    serve open cwd tmp-of dot-tmp-of linked)
  mkdir -p "$tmp/dbus-abc" "$tmp/systemd-private-x" "$tmp/.X11-unix" "$tmp/tmux-1000" "$tmp/ssh-agent1" \
    "$tmp/hsperfdata_me" "$tmp/serve" "$tmp/open" "$tmp/cwd" "$tmp/tmp-of" "$tmp/dot-tmp-of" "$tmp/linked"
  : >"$tmp/.X0-lock" && : >"$tmp/open/log" && : >"$tmp/loose" && : >"$tmp/linked/data"
  # Open through a hard link outside: only its device and inode tie it to the entry.
  ln "$tmp/linked/data" "$BATS_TEST_TMPDIR/data-link"
  socket_at "$tmp/serve/sock"
  socket_at "$tmp/bare.sock"
  (cd "$tmp/cwd" && exec sleep 300) &
  held+=($!)
  sleep 300 3<"$tmp/open/log" &
  held+=($!)
  TMPDIR="$tmp/tmp-of" sleep 300 &
  held+=($!)
  TMPDIR="$tmp/./dot-tmp-of" sleep 300 &
  held+=($!)
  sleep 300 3<"$BATS_TEST_TMPDIR/data-link" &
  held+=($!)
  printf '%s\n' "${held[@]}" >"$BATS_TEST_TMPDIR/holders"
  for kept in "${names[@]}" bare.sock loose; do aged 3 "$tmp/$kept"; done
  # Each holds once it is sleep: its folder, open file and environment are set by then.
  for pid in "${held[@]}"; do
    for _ in $(seq 1 100); do [[ "$(cat "/proc/$pid/comm" 2>/dev/null)" != sleep ]] || break; sleep 0.05; done
    [[ "$(cat "/proc/$pid/comm" 2>/dev/null)" == sleep ]] || fail "holder $pid never started"
  done
  scratch sweep >"$BATS_TEST_TMPDIR/out"
  for kept in "${names[@]}"; do
    [[ -e "$tmp/$kept" ]] || fail "$kept went: $(cat "$BATS_TEST_TMPDIR/out")"
  done
  [[ -S "$tmp/bare.sock" ]] || fail "a socket went"
  [[ ! -e "$tmp/loose" ]] || fail "the sweep did not run: an old file nothing holds stayed"
}

@test "a sweep leaves an entry that is not yours" {
  local tmp="$BERCAIL_TMP_ROOT"
  : >"$tmp/theirs"
  aged 3 "$tmp/theirs"
  # Another uid's view: every entry here belongs to someone else.
  printf '#!/bin/sh\n[ "$1" = -u ] && { echo 4242; exit 0; }\nexec /usr/bin/id "$@"\n' >"$BATS_TEST_TMPDIR/bin/id"
  chmod +x "$BATS_TEST_TMPDIR/bin/id"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" scratch sweep >/dev/null
  [[ -e "$tmp/theirs" ]] || fail "another user's entry went"
  scratch sweep >/dev/null
  [[ ! -e "$tmp/theirs" ]] || fail "as its owner, the sweep keeps it too"
}

@test "--days moves the cut-off, and --dry-run lists what would go and removes and records nothing" {
  local tmp="$BERCAIL_TMP_ROOT" out
  mkdir -p "$tmp/three" "$tmp/one"
  head -c 4096 /dev/urandom >"$tmp/three/f"
  aged 3 "$tmp/three"
  aged 1 "$tmp/one"
  out="$(scratch sweep --dry-run)"
  [[ "$out" == *"would remove $tmp/three ("*")"* && "$out" != *"$tmp/one"* ]] || fail "the default is 2 days: $out"
  [[ "$out" == *"would remove 1 entries from $tmp older than 2 days"* ]] || fail "no total: $out"
  [[ -d "$tmp/three" && ! -e "$XDG_STATE_HOME/bercail/tmp-sweep.json" ]] || fail "a dry run removed or recorded"
  scratch sweep --days 4 >/dev/null
  [[ -d "$tmp/three" ]] || fail "3 days old went with --days 4"
  scratch sweep --days 1 >/dev/null
  [[ ! -e "$tmp/three" && ! -e "$tmp/one" ]] || fail "--days 1 kept: $(ls -A "$tmp")"
  run scratch sweep --days 0
  [[ "$status" -ne 0 && "$output" == *"--days takes a whole number of days, 1 to 3650"* ]] || fail "--days 0: $output"
  : >"$tmp/fresh"
  run scratch sweep --days 1152921504606846976
  [[ "$status" -ne 0 && -e "$tmp/fresh" ]] || fail "a huge --days ran: $output"
}

@test "doctor shows the temp dir's use against its size, and the last sweep" {
  local out
  out="$(doctor)"
  [[ "$out" =~ "  "(ok|high)"  "[0-9.]+[KMGT]?" used of "[0-9.]+[KMGT]?" ("[0-9]+"%)" ]] || fail "use: $out"
  [[ "$out" == *"  none  no sweep yet"* ]] || fail "no sweep yet: $out"
  : >"$BERCAIL_TMP_ROOT/old"
  aged 3 "$BERCAIL_TMP_ROOT/old"
  scratch sweep >/dev/null
  out="$(doctor)"
  [[ "$out" =~ "  ok  last sweep "[0-9T:-]+Z": removed 1 entries older than 2 days" ]] || fail "last sweep: $out"
}

@test "a sweep keeps a held folder with many files, and a program mapped through a hard link outside" {
  local tmp="$BERCAIL_TMP_ROOT" ldso pid cwd_pid _
  ldso="$( { compgen -G '/lib64/ld-linux-*.so.*'; compgen -G '/lib/ld-linux-*.so.*'; } | head -n 1)"
  [[ -n "$ldso" ]] || skip "no dynamic loader to run a program through"
  mkdir -p "$tmp/many" "$tmp/mapped"
  # Enough names that find is still writing when grep finds the held one first.
  (cd "$tmp/many" && seq 1 20000 | xargs touch)
  # bash, which runs as prog-link; a multi-call sleep refuses another name.
  cp "$(command -v bash)" "$tmp/mapped/prog" && ln "$tmp/mapped/prog" "$BATS_TEST_TMPDIR/prog-link"
  mkfifo "$BATS_TEST_TMPDIR/hold.fifo"
  : >"$tmp/loose"
  aged 3 "$tmp/many" "$tmp/mapped" "$tmp/loose"
  (cd "$tmp/many" && exec sleep 300) &
  cwd_pid=$!
  printf '%s\n' "$cwd_pid" >"$BATS_TEST_TMPDIR/holders"
  # Run by the loader, the program is only mapped: no fd, and the loader is the exe.
  # A builtin read on the FIFO waits, so no child outlives the holder's kill.
  "$ldso" "$BATS_TEST_TMPDIR/prog-link" -c 'read -r -t 300 _ <>"$1"' _ "$BATS_TEST_TMPDIR/hold.fifo" &
  pid=$!
  printf '%s\n' "$pid" >>"$BATS_TEST_TMPDIR/holders"
  for _ in $(seq 1 100); do grep -q prog-link "/proc/$pid/maps" 2>/dev/null && break; sleep 0.05; done
  grep -q prog-link "/proc/$pid/maps" || fail "the program was never mapped"
  # Running it read it; old again, only the mapping can keep it.
  aged 3 "$tmp/mapped"
  for _ in $(seq 1 100); do [[ "$(readlink "/proc/$cwd_pid/cwd")" != "$tmp/many" ]] || break; sleep 0.05; done
  [[ "$(readlink "/proc/$cwd_pid/cwd")" == "$tmp/many" ]] || fail "the folder was never held"
  scratch sweep >"$BATS_TEST_TMPDIR/out" || fail "the sweep failed: $(cat "$BATS_TEST_TMPDIR/out")"
  [[ -d "$tmp/many" ]] || fail "a held folder with many files went"
  [[ -f "$tmp/mapped/prog" ]] || fail "a program mapped through a hard link went"
  [[ ! -e "$tmp/loose" ]] || fail "the sweep did not run: an old file nothing holds stayed"
}

@test "a sweep keeps an entry with a newline in its name, open or not, and one with a file read within the cut-off" {
  local tmp="$BERCAIL_TMP_ROOT" pid
  mkdir -p "$tmp/"$'task\noutput' "$tmp/"$'idle\nname' "$tmp/read"
  : >"$tmp/"$'task\noutput/live' && : >"$tmp/"$'idle\nname/x' && : >"$tmp/read/notes" && : >"$tmp/loose"
  aged 3 "$tmp/"$'task\noutput' "$tmp/"$'idle\nname' "$tmp/read" "$tmp/loose"
  touch -a "$tmp/read/notes"
  sleep 300 3<"$tmp/"$'task\noutput/live' &
  pid=$!
  printf '%s\n' "$pid" >"$BATS_TEST_TMPDIR/holders"
  for _ in $(seq 1 100); do [[ "$(cat "/proc/$pid/comm" 2>/dev/null)" != sleep ]] || break; sleep 0.05; done
  scratch sweep >"$BATS_TEST_TMPDIR/out" || fail "the sweep failed: $(cat "$BATS_TEST_TMPDIR/out")"
  [[ -f "$tmp/"$'task\noutput/live' && -f "$tmp/"$'idle\nname/x' ]] || fail "a name with a newline went"
  [[ -f "$tmp/read/notes" ]] || fail "a file read today went"
  [[ ! -e "$tmp/loose" ]] || fail "the sweep did not run: an old file nothing holds stayed"
}

@test "a sweep keeps a folder with another user's file inside, one with a bind mount inside, a space in its name too, and one a mount shows elsewhere" {
  need_userns
  local tmp="$BERCAIL_TMP_ROOT" outside="$BATS_TEST_TMPDIR/outside" elsewhere="$BATS_TEST_TMPDIR/elsewhere" entry
  mkdir -p "$tmp/mine" "$outside" "$tmp/entry space/mnt" "$tmp/plain/mnt" "$tmp/aliased" "$elsewhere"
  : >"$tmp/mine/theirs" && : >"$outside/keep" && : >"$tmp/aliased/keep" && : >"$tmp/loose"
  aged 3 "$tmp/mine" "$tmp/entry space" "$tmp/plain" "$outside" "$tmp/aliased" "$tmp/loose"
  printf '%s' "$tmp/mine/theirs" >"$BATS_TEST_TMPDIR/foreign"
  in_userns chown -h 1:1 "$tmp/mine/theirs"
  [[ "$(stat -c %u "$tmp/mine/theirs")" != "$(id -u)" ]] || fail "the fixture is still this user's"
  # The mounts live in the namespace's mount table; the sweep runs there.
  in_userns bash -c 'mount --bind "$1" "$2/entry space/mnt" && mount --bind "$1" "$2/plain/mnt" \
    && mount --bind "$2/aliased" "$4" && "$3" scratch sweep' \
    _ "$outside" "$tmp" "$ROOT/bin/bercail" "$elsewhere" >"$BATS_TEST_TMPDIR/out" 2>&1 \
    || fail "the sweep failed: $(cat "$BATS_TEST_TMPDIR/out")"
  [[ -f "$tmp/aliased/keep" ]] || fail "a folder a mount shows elsewhere went"
  [[ ! -e "$tmp/loose" ]] || fail "the sweep did not run: an old file nothing holds stayed"
  [[ -f "$outside/keep" ]] || fail "the sweep went through a bind mount: $(cat "$BATS_TEST_TMPDIR/out")"
  for entry in "entry space" plain; do
    [[ -d "$tmp/$entry/mnt" ]] || fail "$entry, which held a mount, went"
  done
  [[ -e "$tmp/mine/theirs" ]] || fail "another user's file went"
}

@test "a sweep keeps a folder a process has as a relative TMPDIR, or through a mount only its namespace has, by a link too" {
  need_userns
  local tmp="$BERCAIL_TMP_ROOT" rel ns linked nl _ lf="$BATS_TEST_TMPDIR/private3"$'\n'
  mkdir -p "$tmp/rel-held" "$tmp/ns-held" "$tmp/link-held" "$tmp/nl-held" "$BATS_TEST_TMPDIR/private" \
    "$BATS_TEST_TMPDIR/private2" "$lf" "${lf%$'\n'}"
  : >"$tmp/ns-held/payload" && : >"$tmp/link-held/payload" && : >"$tmp/nl-held/payload" && : >"$tmp/loose"
  # Here the link names an empty folder; in the holder's namespace, the mount on it.
  ln -s "$BATS_TEST_TMPDIR/private2" "$BATS_TEST_TMPDIR/abs-link"
  # A target that ends in a newline, beside a folder spelled without it.
  ln -s "$lf" "$BATS_TEST_TMPDIR/lf-link"
  aged 3 "$tmp/rel-held" "$tmp/ns-held" "$tmp/link-held" "$tmp/nl-held" "$tmp/loose"
  (cd "${tmp%/*}" && TMPDIR="${tmp##*/}/rel-held" exec sleep 300) &
  rel=$!
  # exec: the pid is the holder itself, so teardown's kill ends it.
  (exec unshare --user --map-root-user --mount bash -c 'mount --bind "$1" "$2" && TMPDIR="$2" exec sleep 300' \
    _ "$tmp/ns-held" "$BATS_TEST_TMPDIR/private") &
  ns=$!
  (exec unshare --user --map-root-user --mount bash -c 'mount --bind "$1" "$2" && TMPDIR="$3" exec sleep 300' \
    _ "$tmp/link-held" "$BATS_TEST_TMPDIR/private2" "$BATS_TEST_TMPDIR/abs-link") &
  linked=$!
  (exec unshare --user --map-root-user --mount bash -c 'mount --bind "$1" "$2" && TMPDIR="$3" exec sleep 300' \
    _ "$tmp/nl-held" "$lf" "$BATS_TEST_TMPDIR/lf-link") &
  nl=$!
  printf '%s\n' "$rel" "$ns" "$linked" "$nl" >"$BATS_TEST_TMPDIR/holders"
  for pid in "$rel" "$ns" "$linked" "$nl"; do
    for _ in $(seq 1 100); do [[ "$(cat "/proc/$pid/comm" 2>/dev/null)" != sleep ]] || break; sleep 0.05; done
    [[ "$(cat "/proc/$pid/comm" 2>/dev/null)" == sleep ]] || fail "holder $pid never started"
  done
  scratch sweep >"$BATS_TEST_TMPDIR/out" || fail "the sweep failed: $(cat "$BATS_TEST_TMPDIR/out")"
  [[ -d "$tmp/rel-held" ]] || fail "a relative TMPDIR's folder went"
  [[ -f "$tmp/ns-held/payload" ]] || fail "a folder another namespace's TMPDIR mounts went"
  [[ -f "$tmp/link-held/payload" ]] || fail "a folder another namespace's TMPDIR reaches by a link went"
  [[ -f "$tmp/nl-held/payload" ]] || fail "a folder reached by a link whose target ends in a newline went"
  [[ ! -e "$tmp/loose" ]] || fail "the sweep did not run: an old file nothing holds stayed"
}

@test "a sweep keeps the folder a chrooted process's relative TMPDIR climbs to from its root" {
  need_userns
  local tmp="$BERCAIL_TMP_ROOT" jail="$BATS_TEST_TMPDIR/jail" pid dir _
  mkdir -p "$tmp/jail-held" "$jail/held" "$jail/usr"
  : >"$tmp/jail-held/payload" && : >"$tmp/loose"
  # Without the chroot, ../held from the jail's root would be $BATS_TEST_TMPDIR/held.
  for dir in bin lib lib64 sbin; do [[ ! -L "/$dir" ]] || ln -s "$(readlink "/$dir")" "$jail/$dir"; done
  aged 3 "$tmp/jail-held" "$tmp/loose"
  (exec unshare --user --map-root-user --mount bash -c 'mount --rbind /usr "$1/usr" && mount --bind "$2" "$1/held" \
    && cd "$1" && TMPDIR=../held exec chroot "$1" /usr/bin/sleep 300' _ "$jail" "$tmp/jail-held") &
  pid=$!
  printf '%s\n' "$pid" >"$BATS_TEST_TMPDIR/holders"
  for _ in $(seq 1 100); do [[ "$(cat "/proc/$pid/comm" 2>/dev/null)" != sleep ]] || break; sleep 0.05; done
  [[ "$(cat "/proc/$pid/comm" 2>/dev/null)" == sleep ]] || skip "chroot did not start here: $(cat "/proc/$pid/comm" 2>/dev/null)"
  scratch sweep >"$BATS_TEST_TMPDIR/out" || fail "the sweep failed: $(cat "$BATS_TEST_TMPDIR/out")"
  [[ -f "$tmp/jail-held/payload" ]] || fail "the folder the chrooted TMPDIR names went"
  [[ ! -e "$tmp/loose" ]] || fail "the sweep did not run: an old entry nothing holds stayed"
}

@test "while a mount shows the whole temp dir elsewhere, a sweep removes nothing" {
  need_userns
  local tmp="$BERCAIL_TMP_ROOT"
  mkdir -p "$BATS_TEST_TMPDIR/whole"
  : >"$tmp/loose"
  aged 3 "$tmp/loose"
  in_userns bash -c 'mount --bind "$1" "$2" && "$3" scratch sweep' _ "$tmp" "$BATS_TEST_TMPDIR/whole" "$ROOT/bin/bercail" \
    >"$BATS_TEST_TMPDIR/out" 2>&1 || fail "the sweep failed: $(cat "$BATS_TEST_TMPDIR/out")"
  [[ -e "$tmp/loose" ]] || fail "an entry the other mount shows went"
  scratch sweep >/dev/null
  [[ ! -e "$tmp/loose" ]] || fail "without the mount, the sweep takes it"
}
