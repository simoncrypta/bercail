#!/usr/bin/env bats
# Machine-wide test slots (lib/slots.sh): tests/run.sh waits for one, sizes
# itself to its share, and doctor lists who holds and who waits.

load test_helper

setup() {
  isolate
  need flock jq
  # A copy of the runner in a tree of its own, with a bats and a vp that log
  # their arguments. bats notes its run's pid and whether slot 1 is locked. It
  # holds the folder busy, so two at once leave overlap behind, and ends once
  # release exists.
  tree="$BATS_TEST_TMPDIR/tree"
  mkdir -p "$tree/tests" "$tree/lib" "$tree/node_modules/.bin"
  cp "$ROOT/tests/run.sh" "$tree/tests/"
  cp "$ROOT/lib/slots.sh" "$ROOT/lib/toml.sh" "$tree/lib/"
  export MEET="$BATS_TEST_TMPDIR/meet"
  mkdir -p "$MEET"
  cat >"$tree/node_modules/.bin/bats" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$MEET/bats.$RUN"
echo "$PPID" >"$MEET/pid.$RUN"
flock -n -s -E 75 "$XDG_STATE_HOME/bercail/test-slots/slot.1" true; echo "$?" >"$MEET/locked.$RUN"
mkdir "$MEET/busy" 2>/dev/null || touch "$MEET/overlap"
touch "$MEET/started.$RUN"
for _ in $(seq 300); do [[ -e "$MEET/release" ]] && break; sleep 0.1; done
rmdir "$MEET/busy" 2>/dev/null || true
EOF
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"$MEET/vp.$RUN"\n' >"$tree/node_modules/.bin/vp"
  # GNU parallel present, so the count goes to bats as --jobs, and CORES cores.
  printf '#!/bin/sh\nexit 0\n' >"$BATS_TEST_TMPDIR/bin/parallel"
  printf '#!/bin/sh\necho "${CORES:-16}"\n' >"$BATS_TEST_TMPDIR/bin/nproc"
  chmod +x "$tree/node_modules/.bin/"{bats,vp} "$BATS_TEST_TMPDIR/bin/"{parallel,nproc}
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  unset BATS_JOBS BERCAIL_TEST_SLOT BERCAIL_TEST_SLOT_WAIT
  slots 1
}

slots() {
  mkdir -p "$HOME/.config/bercail"
  printf '[tests]\nslots = %s\n' "$1" >"$HOME/.config/bercail/config.toml"
}

# Starts tests/run.sh as run NAME in the background, its output in NAME.out;
# $! is its pid.
start() {
  RUN="$1" bash "$tree/tests/run.sh" >"$MEET/$1.out" 2>&1 3>&- &
}

# Waits up to 10 s for a file.
await() {
  local _
  for _ in $(seq 100); do
    [[ -e "$1" ]] && return 0
    sleep 0.1
  done
  fail "no $1"
}

# Waits up to 10 s for slot 1 to be free.
await_free() {
  local _ rc
  for _ in $(seq 100); do
    rc=0
    flock -n -E 75 "$XDG_STATE_HOME/bercail/test-slots/slot.1" true || rc=$?
    ((rc != 75)) && return 0
    sleep 0.1
  done
  fail "slot 1 is still held"
}

@test "with one slot, a second run waits for the first, then runs, and says for whom" {
  start a
  pid_a=$!
  await "$MEET/started.a"
  start b
  pid_b=$!
  for _ in $(seq 100); do
    grep -q 'waiting for a test slot' "$MEET/b.out" && break
    sleep 0.1
  done
  [[ ! -e "$MEET/started.b" ]] || fail "b started while a held the only slot"
  touch "$MEET/release"
  wait "$pid_a" || fail "a: $(cat "$MEET/a.out")"
  wait "$pid_b" || fail "b: $(cat "$MEET/b.out")"
  [[ ! -e "$MEET/overlap" ]] || fail "the two runs overlapped"
  [[ -e "$MEET/started.b" ]] || fail "b never ran: $(cat "$MEET/b.out")"
  grep -qF "tests/run.sh: waiting for a test slot; all 1 ([tests] slots) are taken by:" "$MEET/b.out" || fail "$(cat "$MEET/b.out")"
  grep -qE "^  tests/run.sh in $tree, pid $(cat "$MEET/pid.a"), since [0-9:]{8}$" "$MEET/b.out" || fail "holder not named: $(cat "$MEET/b.out")"
}

@test "a run inside one that holds the only slot does not wait for it" {
  touch "$MEET/release"
  export BERCAIL_TEST_SLOT_WAIT=2
  RUN=nested run bash -c 'source "$1/lib/slots.sh"; slot_run outer bash "$1/tests/run.sh"' _ "$tree"
  [[ "$status" -eq 0 ]] || fail "status $status: $output"
  [[ "$output" != *"waiting for a test slot"* ]] || fail "the nested run waited: $output"
  [[ -e "$MEET/started.nested" ]] || fail "the nested run did not run: $output"
  [[ "$(cat "$MEET/locked.nested")" == 75 ]] || fail "the outer run did not hold the slot"
}

@test "a run sizes bats and Vitest to its share of the cores, and BATS_JOBS still wins" {
  touch "$MEET/release"
  slots 2
  RUN=two bash "$tree/tests/run.sh"
  grep -qx -- "--jobs 16 --filter-tags !live tests" "$MEET/bats.two" || fail "$(cat "$MEET/bats.two")"
  grep -qx -- "test --maxWorkers 8" "$MEET/vp.two" || fail "$(cat "$MEET/vp.two")"
  slots 4
  RUN=four bash "$tree/tests/run.sh"
  grep -qx -- "--jobs 8 --filter-tags !live tests" "$MEET/bats.four" || fail "$(cat "$MEET/bats.four")"
  grep -qx -- "test --maxWorkers 4" "$MEET/vp.four" || fail "$(cat "$MEET/vp.four")"
  CORES=1 RUN=one bash "$tree/tests/run.sh"
  grep -qx -- "--jobs 2 --filter-tags !live tests" "$MEET/bats.one" || fail "$(cat "$MEET/bats.one")"
  BATS_JOBS=3 RUN=set bash "$tree/tests/run.sh"
  grep -qx -- "--jobs 3 --filter-tags !live tests" "$MEET/bats.set" || fail "$(cat "$MEET/bats.set")"
}

@test "without GNU parallel, the files at once times their 4 jobs each is the run's count" {
  touch "$MEET/release"
  slots 2
  touch "$tree/tests/one.bats" "$tree/tests/two.bats"
  # Every command on PATH but GNU parallel, and an xargs that logs its arguments.
  local dir path="$BATS_TEST_TMPDIR/path"
  mkdir -p "$path"
  while IFS= read -r -d: dir; do
    [[ -d "$dir" ]] && ln -s "$dir"/* "$path/" 2>/dev/null || true
  done <<<"$PATH:"
  rm -f "$path/parallel" "$path/xargs"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"$MEET/xargs.$RUN"\nexec %s "$@"\n' "$(command -v xargs)" >"$path/xargs"
  chmod +x "$path/xargs"
  RUN=files PATH="$path" bash "$tree/tests/run.sh"
  grep -q -- "^-0 -n 1 -P 4 bash" "$MEET/xargs.files" || fail "$(cat "$MEET/xargs.files")"
  grep -q -- "^--jobs 4 --no-parallelize-across-files" "$MEET/bats.files" || fail "$(cat "$MEET/bats.files")"
  BATS_JOBS=2 RUN=small PATH="$path" bash "$tree/tests/run.sh"
  grep -q -- "^-0 -n 1 -P 1 bash" "$MEET/xargs.small" || fail "$(cat "$MEET/xargs.small")"
  grep -q -- "^--jobs 2 --no-parallelize-across-files" "$MEET/bats.small" || fail "$(cat "$MEET/bats.small")"
}

@test "killing the pid a slot's line names frees the slot, whatever its file still says" {
  start a
  pid_a=$!
  await "$MEET/started.a"
  grep -q "tests/run.sh in $tree, pid $(cat "$MEET/pid.a")," "$XDG_STATE_HOME/bercail/test-slots/slot.1" || fail "no line for run a"
  kill -9 "$(cat "$MEET/pid.a")"
  await_free
  grep -q "pid $(cat "$MEET/pid.a")," "$XDG_STATE_HOME/bercail/test-slots/slot.1" || fail "the killed run's line is gone"
  touch "$MEET/release"
  wait "$pid_a" || true
  rmdir "$MEET/busy" 2>/dev/null || true
  BERCAIL_TEST_SLOT_WAIT=1 RUN=b run bash "$tree/tests/run.sh"
  [[ "$status" -eq 0 ]] || fail "status $status: $output"
  [[ "$output" != *"waiting for a test slot"* ]] || fail "b waited for a dead run: $output"
}

@test "a run gives up after its bounded wait and says so" {
  start a
  pid_a=$!
  await "$MEET/started.a"
  BERCAIL_TEST_SLOT_WAIT=1 RUN=b run bash "$tree/tests/run.sh"
  touch "$MEET/release"
  wait "$pid_a"
  [[ "$status" -eq 1 ]] || fail "status $status: $output"
  [[ ! -e "$MEET/started.b" ]] || fail "b ran without a slot"
  [[ "$output" == *"tests/run.sh: gave up after 1s waiting for a test slot"*"raise [tests] slots"* ]] || fail "$output"
  ! compgen -G "$XDG_STATE_HOME/bercail/test-slots/wait.*" >/dev/null || fail "b left its wait file"
  BERCAIL_TEST_SLOT_WAIT=08 RUN=c run bash "$tree/tests/run.sh"
  [[ "$status" -eq 0 ]] || fail "a wait of 08 seconds: $output"
  BERCAIL_TEST_SLOT_WAIT=0.5 run bash "$tree/tests/run.sh"
  [[ "$status" -eq 1 && "$output" == *"BERCAIL_TEST_SLOT_WAIT must be whole seconds, not 0.5"* ]] || fail "$output"
}

@test "a slot file flock cannot open fails the run at once, not as a wait" {
  mkdir -p "$XDG_STATE_HOME/bercail/test-slots"
  ln -s "$BATS_TEST_TMPDIR/nowhere/slot" "$XDG_STATE_HOME/bercail/test-slots/slot.1"
  BERCAIL_TEST_SLOT_WAIT=30 run bash "$tree/tests/run.sh"
  [[ "$status" -eq 1 ]] || fail "status $status: $output"
  [[ "$output" == *"tests/run.sh: could not take test slot $XDG_STATE_HOME/bercail/test-slots/slot.1"* ]] || fail "$output"
  [[ "$output" != *"waiting for a test slot"* && ! -e "$MEET/started." ]] || fail "$output"
}

@test "doctor lists who holds a slot and who waits for one" {
  doctor() {
    bash -c 'source "$1/lib/common.sh"; source "$1/lib/slots.sh"; doctor_test_slots' _ "$ROOT"
  }
  run doctor
  [[ -z "$output" ]] || fail "slots shown before any test run here: $output"
  mkdir -p "$XDG_STATE_HOME/bercail/test-slots"
  run doctor
  [[ "$output" == *"[tests] slots = 1):"*"  ok  all free"* ]] || fail "$output"
  start a
  pid_a=$!
  await "$MEET/started.a"
  start b
  pid_b=$!
  await "$XDG_STATE_HOME/bercail/test-slots/wait.$pid_b"
  run doctor
  touch "$MEET/release"
  wait "$pid_a" "$pid_b"
  grep -qE "^  held  tests/run.sh in $tree, pid $(cat "$MEET/pid.a"), since [0-9:]{8}$" <<<"$output" || fail "$output"
  grep -qE "^  waiting  tests/run.sh in $tree, pid $pid_b, waiting since [0-9:]{8}$" <<<"$output" || fail "$output"
  printf '[tests]\nslots = none\n' >"$HOME/.config/bercail/config.toml"
  run doctor
  [[ "$output" == *"invalid  [tests] slots = none (a whole number above 0)"* ]] || fail "$output"
}
