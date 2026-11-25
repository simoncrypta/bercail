#!/usr/bin/env bats
# bercail desk prompt / desk answer: Shep, for the person, reads the confirm a
# desk's guard is waiting on and answers it through a file the guard reads,
# never by typing into the desk. Stand-ins for hc, bd and entire; a background
# subshell plays the guard.

setup() {
  bats_require_minimum_version 1.5.0
  load test_helper
  isolate
  need jq git
  mkdir -p "$BATS_TEST_TMPDIR/bin" "$BATS_TEST_TMPDIR/terms"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH" HC_BIN="$BATS_TEST_TMPDIR/bin/hc"
  export HC_LOG="$BATS_TEST_TMPDIR/hc.log" BD_LOG="$BATS_TEST_TMPDIR/bd.log" TERMS="$BATS_TEST_TMPDIR/terms"
  export BERCAIL_DESK_ANSWER_WAIT=5
  RECORDS="$XDG_STATE_HOME/bercail/desk-sessions"
  PROMPTS="$XDG_STATE_HOME/bercail/desk-prompts"
  mkdir -p "$RECORDS"
  ( umask 077 && mkdir -p "$PROMPTS" )

  # hc: `get NAME` prints terms/NAME.json (exit 3 when there is none); every call is logged.
  cat >"$BATS_TEST_TMPDIR/bin/hc" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$HC_LOG"
[[ "$1" == get ]] || exit 0
[[ -f "$TERMS/$2.json" ]] || exit 3
cat "$TERMS/$2.json"
SH
  # bd: logs its cwd and argv, one line each.
  cat >"$BATS_TEST_TMPDIR/bin/bd" <<'SH'
#!/usr/bin/env bash
{ printf 'cwd %s\n' "$PWD"; printf 'argv'; printf ' [%s]' "$@"; printf '\n'; } >>"$BD_LOG"
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/hc" "$BATS_TEST_TMPDIR/bin/bd"

  # The desk's checkout: a worktree of a main checkout, where the comment goes.
  MAIN="$BATS_TEST_TMPDIR/app"
  git_init "$MAIN"
  git -C "$MAIN" worktree add -q -b work "$BATS_TEST_TMPDIR/app.work"
  MAIN="$(cd "$MAIN" && pwd -P)"

  # The desk agent: a live process its record names.
  sleep 300 >/dev/null 2>&1 3>&- &
  DESK_PID=$!
  desk t9 agent
  jq -n --argjson pid "$DESK_PID" --arg cwd "$BATS_TEST_TMPDIR/app.work" '{address: "t9", session: "s1", cwd: $cwd,
    harness: "pi", issue: "app-12", issue_title: "Ship the export", space: "sp1", args: [], pid: $pid}' >"$RECORDS/t9.json"
}

teardown() {
  kill "$DESK_PID" 2>/dev/null || true
}

desk() { # address role [name]
  jq -n --arg a "$1" --arg r "$2" '{address: $a, state: "live", labels: {"bercail.role": $r, "bercail.space": "sp1"}}' \
    >"$TERMS/${3:-$1}.json"
}

# The guard's pending prompt for t9: pid and command can be overridden.
pending() { # [pid] [command]
  jq -n --argjson pid "${1:-$DESK_PID}" --arg command "${2:-git push origin main}" '{v: 1, id: "p-1", address: "t9", pid: $pid,
    session: "s1", cwd: "/w", tool: "bash", command: $command,
    reason: "Allow this push to origin: main? No keeps it local for the person.", at: "2026-11-25T10:00:00Z"}' \
    >"$PROMPTS/t9.json"
}

# Plays the guard: waits for the answer file, keeps a copy, then acts.
#   taken|refused  takes it and writes done with that status
#   swallow        takes it and writes no done
guard() { # mode
  (
    for _ in $(seq 1 200); do
      if [[ -f "$PROMPTS/t9.answer.json" ]]; then
        mv "$PROMPTS/t9.answer.json" "$BATS_TEST_TMPDIR/taken.json"
        case "$1" in
          taken) jq -c '{id, nonce, status: "taken", answer, at: "2026-11-25T10:00:01Z"}' "$BATS_TEST_TMPDIR/taken.json" >"$PROMPTS/t9.done-$(jq -r .nonce "$BATS_TEST_TMPDIR/taken.json").json" ;;
          refused) jq -c '{id, nonce, status: "refused", why: "the prompt closed", at: "x"}' "$BATS_TEST_TMPDIR/taken.json" >"$PROMPTS/t9.done-$(jq -r .nonce "$BATS_TEST_TMPDIR/taken.json").json" ;;
        esac
        exit 0
      fi
      sleep 0.05
    done
  ) >/dev/null 2>&1 3>&- &
}

@test "desk prompt prints the waiting prompt with the desk's issue" {
  pending
  run --separate-stderr "$ROOT/bin/bercail" desk prompt t9
  [[ "$status" -eq 0 ]] || fail "$status $output $stderr"
  jq -e --argjson pid "$DESK_PID" '.id == "p-1" and .address == "t9" and .pid == $pid and .tool == "bash"
    and .command == "git push origin main" and .issue == "app-12" and .issue_title == "Ship the export"' <<<"$output" >/dev/null \
    || fail "record: $output"
}

@test "desk prompt fails when no prompt waits, or it belongs to another Pi" {
  run "$ROOT/bin/bercail" desk prompt t9
  [[ "$status" -eq 1 && "$output" == *"t9 has no guard prompt waiting"* ]] || fail "none: $status $output"
  pending 1
  run "$ROOT/bin/bercail" desk prompt t9
  [[ "$status" -eq 1 && "$output" == *"t9 has no guard prompt waiting"* ]] || fail "other pid: $status $output"
  printf '{"id": ' >"$PROMPTS/t9.json"
  run "$ROOT/bin/bercail" desk prompt t9
  [[ "$status" -eq 1 && "$output" == *"t9 has no guard prompt waiting"* ]] || fail "broken: $status $output"
  pending
  kill "$DESK_PID"
  wait "$DESK_PID" 2>/dev/null || true
  run "$ROOT/bin/bercail" desk prompt t9
  [[ "$status" -eq 1 && "$output" == *"t9 has no running Pi desk agent"* ]] || fail "dead desk: $status $output"
}

@test "desk answer with a prompt id that is not the waiting one writes nothing" {
  pending
  run "$ROOT/bin/bercail" desk answer t9 yes --prompt p-0
  [[ "$status" -eq 1 && "$output" == *"the prompt you read is gone; bercail desk prompt t9 shows the one waiting now"* ]] \
    || fail "$status $output"
  [[ ! -e "$PROMPTS/t9.answer.json" ]] || fail "an answer was written"
  [[ ! -e "$BD_LOG" ]] || fail "bd ran: $(cat "$BD_LOG")"
}

@test "desk answer no needs a reason" {
  pending
  run "$ROOT/bin/bercail" desk answer t9 no --prompt p-1
  [[ "$status" -eq 1 && "$output" == *"--reason"* ]] || fail "$status $output"
  [[ ! -e "$PROMPTS/t9.answer.json" ]] || fail "an answer was written"
}

@test "desk answer no delivers the answer, waits for the guard to take it, and logs it on the issue once" {
  pending
  guard taken
  run --separate-stderr "$ROOT/bin/bercail" desk answer t9 no --prompt p-1 --reason "the person pushes it"
  [[ "$status" -eq 0 && "$output" == "t9 answered No: git push origin main" ]] || fail "$status $output $stderr"
  jq -e '. == {id: "p-1", answer: "no", reason: "the person pushes it", nonce: .nonce} and (.nonce | test("^[0-9a-f]{32}$"))' \
    "$BATS_TEST_TMPDIR/taken.json" >/dev/null || fail "answer: $(cat "$BATS_TEST_TMPDIR/taken.json")"
  [[ -z "$(find "$PROMPTS" -mindepth 1 ! -name t9.json ! -name t9.answer.lock)" ]] || fail "files left: $(ls -a "$PROMPTS")"
  [[ "$(grep -c '^argv' "$BD_LOG")" -eq 1 ]] || fail "one comment: $(cat "$BD_LOG")"
  grep -qxF "cwd $MAIN" "$BD_LOG" || fail "in the main checkout: $(cat "$BD_LOG")"
  grep -qxF "argv [comment] [app-12] [bercail desk answer: answered No to desk t9's guard prompt \"Allow this push to origin: main? No keeps it local for the person.\" (its bash: git push origin main): the person pushes it]" "$BD_LOG" \
    || fail "comment: $(cat "$BD_LOG")"
}

@test "the answer file is private" {
  pending
  (
    for _ in $(seq 1 200); do
      [[ -f "$PROMPTS/t9.answer.json" ]] && { stat -c %a "$PROMPTS/t9.answer.json" >"$BATS_TEST_TMPDIR/mode"; exit 0; }
      sleep 0.05
    done
  ) >/dev/null 2>&1 3>&- &
  BERCAIL_DESK_ANSWER_WAIT=1 run "$ROOT/bin/bercail" desk answer t9 yes --prompt p-1
  [[ "$(cat "$BATS_TEST_TMPDIR/mode")" == 600 ]] || fail "mode: $(cat "$BATS_TEST_TMPDIR/mode" 2>&1)"
  [[ "$(stat -c %a "$PROMPTS")" == 700 ]] || fail "dir mode"
}

@test "desk answer --dry-run prints the card text and writes nothing" {
  pending
  run --separate-stderr "$ROOT/bin/bercail" desk answer t9 no --prompt p-1 --reason "the person pushes it" --dry-run
  [[ "$status" -eq 0 ]] || fail "$status $output $stderr"
  [[ "$output" == "Answer No to desk t9's guard prompt (app-12: Ship the export): Allow this push to origin: main? No keeps it local for the person."$'\n'"Its bash: git push origin main"$'\n'"Why: the person pushes it" ]] \
    || fail "card: $output"
  run --separate-stderr "$ROOT/bin/bercail" desk answer t9 yes --prompt p-1 --dry-run
  [[ "$output" == "Answer Yes to desk t9's guard prompt (app-12: Ship the export): Allow this push to origin: main? No keeps it local for the person."$'\n'"Its bash: git push origin main" ]] \
    || fail "yes card: $output"
  [[ -z "$(find "$PROMPTS" -mindepth 1 ! -name t9.json ! -name t9.answer.lock)" ]] || fail "files: $(ls -a "$PROMPTS")"
  [[ ! -e "$BD_LOG" ]] || fail "bd ran"
}

@test "an answer the guard never takes is withdrawn and nothing is answered" {
  pending
  BERCAIL_DESK_ANSWER_WAIT=0 run "$ROOT/bin/bercail" desk answer t9 yes --prompt p-1
  [[ "$status" -eq 1 && "$output" == *"desk t9 did not take the answer: its prompt may have closed. Nothing was answered."* ]] \
    || fail "$status $output"
  [[ -z "$(find "$PROMPTS" -mindepth 1 ! -name t9.json ! -name t9.answer.lock)" ]] || fail "files: $(ls -a "$PROMPTS")"
  [[ ! -e "$BD_LOG" ]] || fail "bd ran: $(cat "$BD_LOG")"
}

@test "an answer the guard took without saying what became of it is reported as unknown" {
  pending
  guard swallow
  BERCAIL_DESK_ANSWER_WAIT=1 run "$ROOT/bin/bercail" desk answer t9 yes --prompt p-1
  [[ "$status" -eq 1 && "$output" == *"desk t9 took the answer but did not say what became of it; the outcome is unknown: hc read t9 shows it."* ]] \
    || fail "$status $output"
  [[ -f "$BATS_TEST_TMPDIR/taken.json" ]] || fail "the guard did not take it"
  [[ ! -e "$BD_LOG" ]] || fail "bd ran: $(cat "$BD_LOG")"
}

@test "an answer the guard refuses fails with its why and logs nothing" {
  pending
  guard refused
  run "$ROOT/bin/bercail" desk answer t9 yes --prompt p-1
  [[ "$status" -eq 1 && "$output" == *"desk t9 refused the answer: the prompt closed"* ]] || fail "$status $output"
  [[ ! -e "$BD_LOG" ]] || fail "bd ran: $(cat "$BD_LOG")"
}

@test "a credential in the command, its question or the reason never reaches the output or the issue" {
  local cmd="git push https://simon:s3cr3t-tok@github.com/o/r main"
  pending "$DESK_PID" "$cmd"
  jq '.reason = "Allow this push to https://simon:s3cr3t-tok@github.com/o/r: main?"' "$PROMPTS/t9.json" >"$PROMPTS/t9.json.new" \
    && mv "$PROMPTS/t9.json.new" "$PROMPTS/t9.json"
  run "$ROOT/bin/bercail" desk prompt t9
  [[ "$status" -eq 0 && "$output" == *'https://***@github.com/o/r main'* && "$output" != *s3cr3t* ]] || fail "prompt: $output"
  run "$ROOT/bin/bercail" desk answer t9 no --prompt p-1 --reason "see https://simon:s3cr3t-tok@github.com/o/r" --dry-run
  [[ "$status" -eq 0 && "$output" == *'Why: see https://***@github.com/o/r'* && "$output" != *s3cr3t* ]] || fail "no dry run: $output"
  run "$ROOT/bin/bercail" desk answer t9 yes --prompt p-1 --dry-run
  [[ "$status" -eq 0 && "$output" == *'Its bash: git push https://***@github.com/o/r main'* && "$output" != *s3cr3t* ]] || fail "dry run: $output"
  guard taken
  run "$ROOT/bin/bercail" desk answer t9 no --prompt p-1 --reason "fine, see https://simon:s3cr3t-tok@github.com/o/r"
  [[ "$status" -eq 0 ]] || fail "no: $status $output"
  ! grep -q s3cr3t "$BATS_TEST_TMPDIR/taken.json" || fail "the desk got the secret: $(cat "$BATS_TEST_TMPDIR/taken.json")"
  guard taken
  run "$ROOT/bin/bercail" desk answer t9 yes --prompt p-1 --reason "fine"
  [[ "$status" -eq 0 && "$output" == *'t9 answered Yes: git push https://***@github.com/o/r main'* && "$output" != *s3cr3t* ]] || fail "answer: $output"
  grep -qF 'https://***@github.com/o/r main): fine]' "$BD_LOG" || fail "comment: $(cat "$BD_LOG")"
  grep -qF 'push to https://***@github.com/o/r: main?' "$BD_LOG" || fail "question: $(cat "$BD_LOG")"
  ! grep -q s3cr3t "$BD_LOG" || fail "the secret reached bd: $(cat "$BD_LOG")"
}

@test "a card shows the whole command, and the issue gets it cut to 500 characters" {
  local long
  long="echo $(printf 'a%.0s' $(seq 1 600))"
  pending "$DESK_PID" "$long"
  run "$ROOT/bin/bercail" desk answer t9 yes --prompt p-1 --dry-run
  [[ "$(sed -n 2p <<<"$output")" == "Its bash: $long" ]] || fail "$output"
  guard taken
  run "$ROOT/bin/bercail" desk answer t9 yes --prompt p-1
  [[ "$status" -eq 0 ]] || fail "$status $output"
  grep -qF "(its bash: ${long:0:500}…)]" "$BD_LOG" || fail "comment: $(cat "$BD_LOG")"
}

@test "desk answer takes its words only in the one order the guard reads" {
  pending
  for args in "--reason no t9 yes --prompt p-1" "t9 yes --reason x --prompt p-1" "t9 no --prompt p-1 --dry-run --reason x" \
    "t9 yes --prompt p-1 --reason" "t9 yes --prompt p-1 --dry-run extra" "--dry-run yes --prompt p-1"; do
    # shellcheck disable=SC2086
    run "$ROOT/bin/bercail" desk answer $args
    [[ "$status" -eq 1 && "$output" == *"usage: bercail desk prompt DESK | desk answer DESK yes|no --prompt ID"* ]] \
      || fail "$args: $status $output"
  done
  [[ -z "$(find "$PROMPTS" -mindepth 1 ! -name t9.json ! -name t9.answer.lock)" ]] || fail "files: $(ls -a "$PROMPTS")"
  [[ ! -e "$BD_LOG" ]] || fail "bd ran"
}

@test "an answer while another writer waits on the same desk writes nothing" {
  local holder
  need flock
  pending
  # Another bercail desk answer to t9, mid-wait: it holds the desk's answer lock.
  (
    exec 9>>"$PROMPTS/t9.answer.lock"
    flock 9
    touch "$BATS_TEST_TMPDIR/held"
    # exec: the holder's pid is the sleep, which keeps fd 9 and the lock, so kill ends both.
    exec sleep 30
  ) >/dev/null 2>&1 3>&- &
  holder=$!
  for _ in $(seq 1 100); do [[ -e "$BATS_TEST_TMPDIR/held" ]] && break; sleep 0.05; done
  run "$ROOT/bin/bercail" desk answer t9 yes --prompt p-1
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  [[ "$status" -eq 1 && "$output" == *"another answer to desk t9 waits for its guard"* ]] || fail "$status $output"
  [[ ! -e "$PROMPTS/t9.answer.json" ]] || fail "an answer was written"
  [[ ! -e "$BD_LOG" ]] || fail "bd ran"
}

@test "another writer's receipt for the same prompt is not this answer's" {
  pending
  printf '{"id":"p-1","nonce":"%032d","status":"taken","answer":"no"}\n' 0 >"$PROMPTS/t9.done-$(printf '%032d' 0).json"
  BERCAIL_DESK_ANSWER_WAIT=0 run "$ROOT/bin/bercail" desk answer t9 yes --prompt p-1
  [[ "$status" -eq 1 && "$output" == *"did not take the answer"* ]] || fail "$status $output"
  [[ -f "$PROMPTS/t9.done-$(printf '%032d' 0).json" ]] || fail "the other receipt was removed"
  [[ ! -e "$BD_LOG" ]] || fail "bd ran: $(cat "$BD_LOG")"
}

@test "a desk on a trail logs the answer in the trail's comments, not bd" {
  local file
  need node
  git -C "$MAIN" remote add origin entire://entire.example/et/proj/app
  cat >"$BATS_TEST_TMPDIR/bin/entire" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "repo view") echo '{"id":"R1"}' ;;
  "trail show") [[ "$3" == 3 ]] || exit 1; echo '{"number":3,"title":"Ship","status":"open","repoIds":["R1"],"changes":[]}' ;;
  *) exit 2 ;;
esac
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/entire"
  jq '.issue = "trail:3"' "$RECORDS/t9.json" >"$RECORDS/t9.json.new" && mv "$RECORDS/t9.json.new" "$RECORDS/t9.json"
  pending
  guard taken
  run "$ROOT/bin/bercail" desk answer t9 yes --prompt p-1
  [[ "$status" -eq 0 ]] || fail "$status $output"
  file="$(find "$XDG_STATE_HOME/bercail/jobs" -name 3.comments.jsonl)"
  jq -e '.text == "bercail desk answer: answered Yes to desk t9'"'"'s guard prompt \"Allow this push to origin: main? No keeps it local for the person.\" (its bash: git push origin main)"' "$file" >/dev/null \
    || fail "comment: $(cat "$file")"
  [[ ! -e "$BD_LOG" ]] || fail "bd ran: $(cat "$BD_LOG")"
}

@test "a desk with no issue is answered with a note and no comment" {
  jq '.issue = ""' "$RECORDS/t9.json" >"$RECORDS/t9.json.new" && mv "$RECORDS/t9.json.new" "$RECORDS/t9.json"
  pending
  guard taken
  run --separate-stderr "$ROOT/bin/bercail" desk answer t9 yes --prompt p-1
  [[ "$status" -eq 0 && "$output" == "t9 answered Yes: git push origin main" && "$stderr" == *"no issue"* ]] || fail "$status $output $stderr"
  [[ ! -e "$BD_LOG" ]] || fail "bd ran: $(cat "$BD_LOG")"
}

@test "a failed comment says the answer went through and how to log it by hand" {
  printf '#!/bin/sh\nexit 1\n' >"$BATS_TEST_TMPDIR/bin/bd"
  pending
  guard taken
  run --separate-stderr "$ROOT/bin/bercail" desk answer t9 yes --prompt p-1
  [[ "$status" -eq 1 && "$output" == "t9 answered Yes: git push origin main" && "$stderr" == *"bd comment app-12 "* ]] \
    || fail "$status $output $stderr"
}

@test "only a live desk takes an answer" {
  desk t8 bstack-builder
  run "$ROOT/bin/bercail" desk answer t8 yes --prompt p-1
  [[ "$status" -eq 1 && "$output" == *"t8 is not a live desk"* ]] || fail "a sibling: $output"
  run "$ROOT/bin/bercail" desk prompt t7
  [[ "$status" -eq 1 && "$output" == *"no live terminal t7"* ]] || fail "gone: $output"
}

# bats test_tags=live
@test "live: a real Pi desk pushes its own branch unasked, and takes a No then a Yes from desk answer" {
  local pi
  pi="${PI_GUARD_BIN:-}"
  [[ -n "$pi" ]] || pi="$(real_pi)"
  [[ -n "$pi" ]] || skip "Pi not found; desk-answer live proof not run"
  need node
  node "$ROOT/tests/pi_desk_answer_live.ts" "$ROOT" "$pi"
}
