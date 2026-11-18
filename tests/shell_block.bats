#!/usr/bin/env bats
# The shell block (config/shell/bercail.inc.sh) with worktrunk, git, fzf, and
# the Herdr helper as stand-ins. Schema 1 is a bare array of {branch, path}
# (wt v0.81.0 `wt list --help`, https://worktrunk.dev/list/#json-output).
# Schema 2 is {"schema":2,"items":[{branch, worktree:{path}}]}.

setup() {
  load test_helper
  isolate
  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN" "$HOME/.config/worktrunk"
  export WT_LIST_FILE="$BATS_TEST_TMPDIR/wt-list.json" WT_LOG="$BATS_TEST_TMPDIR/wt.log"
  export GIT_LOG="$BATS_TEST_TMPDIR/git.log" HERDR_LOG="$BATS_TEST_TMPDIR/herdr.log"
  export FZF_INPUT="$BATS_TEST_TMPDIR/fzf-in" FZF_SELECT="" FZF_STATUS=0 WT_LIST_STATUS=0
  export WT_SWITCH_STATUS=0 WT_REMOVE_STATUS=0 ATTACH_STATUS=0 GIT_BRANCH=other
  export GIT_ROOT="" GIT_WORKTREE_LIST="" GIT_SWITCH_STATUS=0 GIT_WORKTREE_ADD_STATUS=0
  : >"$WT_LOG"
  : >"$GIT_LOG"
  : >"$HERDR_LOG"
  # Schema 1, the bare array current wt prints with [list] json-schema = 1.
  printf '%s\n' '[{"branch":"main","path":"/repo"},{"branch":"feat","path":"/repo.feat"}]' >"$WT_LIST_FILE"
  cat >"$HOME/.config/worktrunk/herdr-layout.sh" <<'EOF'
wt_herdr_attach() {
  printf 'attach %s\n' "$1" >>"$HERDR_LOG"
  printf 'attach %s\n' "$1"
  return "${ATTACH_STATUS:-0}"
}
wt_herdr_layout_close() { printf 'close %s %s\n' "$1" "$2" >>"$HERDR_LOG"; }
_wt_generate_session_name() { basename "$1"; }
EOF
  cat >"$BIN/wt" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$WT_LOG"
case "$1" in
  list)
    [[ "$*" == "list --format=json" ]] || exit 1
    cat "$WT_LIST_FILE"
    exit "$WT_LIST_STATUS"
    ;;
  switch) exit "$WT_SWITCH_STATUS" ;;
  remove) exit "$WT_REMOVE_STATUS" ;;
  *) exit 1 ;;
esac
EOF
  cat >"$BIN/git" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GIT_LOG"
case "$1" in
  branch) printf '%s\n' "${GIT_BRANCH:-other}" ;;
  rev-parse) [[ -z "${GIT_ROOT:-}" ]] || printf '%s\n' "$GIT_ROOT" ;;
  show-ref) exit 0 ;;
  ls-remote) exit 1 ;;
  symbolic-ref) printf '%s\n' 'refs/remotes/origin/main' ;;
  switch) exit "${GIT_SWITCH_STATUS:-0}" ;;
  worktree)
    if [[ "$2" == list ]]; then
      [[ -z "${GIT_WORKTREE_LIST:-}" ]] || printf '%s\n' "$GIT_WORKTREE_LIST"
      exit 0
    fi
    exit "${GIT_WORKTREE_ADD_STATUS:-0}"
    ;;
  *) exit 1 ;;
esac
EOF
  # A choice only if it is one of the lines offered. Empty input selects nothing.
  cat >"$BIN/fzf" <<'EOF'
#!/usr/bin/env bash
cat >"$FZF_INPUT"
[[ -s "$FZF_INPUT" && -n "${FZF_SELECT:-}" ]] || exit 1
grep -Fxq "$FZF_SELECT" "$FZF_INPUT" || exit 1
printf '%s\n' "$FZF_SELECT"
exit "$FZF_STATUS"
EOF
  chmod +x "$BIN/wt" "$BIN/git" "$BIN/fzf"
  PATH="$BIN:$PATH"
  # shellcheck source=/dev/null
  source "$ROOT/config/shell/bercail.inc.sh"
}

set_list() {
  printf '%s\n' "$1" >"$WT_LIST_FILE"
  WT_LIST_STATUS="${2:-0}"
}

@test "wts opens the space of the worktree worktrunk lists for the branch" {
  run wts feat
  [[ "$status" -eq 0 && "$output" == "attach /repo.feat" ]] || fail "wts feat: exit $status: $output"
}

@test "wts opens the space when worktrunk prints a schema 2 envelope" {
  set_list '{"schema":2,"items":[{"branch":"feat","worktree":{"path":"/repo.feat"}},{"branch":null,"worktree":{"path":"/det"}}]}'
  run wts feat
  [[ "$status" -eq 0 && "$output" == "attach /repo.feat" ]] || fail "schema 2: exit $status: $output"
}

@test "wts says so when worktrunk lists no worktree for the branch" {
  run wts gone
  [[ "$status" -eq 1 && "$output" == "Worktree not found: gone" ]] || fail "schema 1 missing: exit $status: $output"
  set_list '{"schema":2,"items":[{"branch":"main","worktree":{"path":"/repo"}},{"branch":"only"},{"branch":null,"worktree":{"path":"/det"}}]}'
  run wts gone
  [[ "$status" -eq 1 && "$output" == "Worktree not found: gone" ]] || fail "schema 2 missing: exit $status: $output"
  run wts only
  [[ "$status" -eq 1 && "$output" == "Worktree not found: only" ]] || fail "branch-only: exit $status: $output"
}

@test "an empty worktree list is a missing branch, not an unreadable list" {
  set_list '[]'
  run wts gone
  [[ "$status" -eq 1 && "$output" == "Worktree not found: gone" ]] || fail "schema 1 empty: exit $status: $output"
  set_list '{"schema":2,"items":[]}'
  run wts gone
  [[ "$status" -eq 1 && "$output" == "Worktree not found: gone" ]] || fail "schema 2 empty: exit $status: $output"
}

@test "wts keeps spaces and shell characters in the worktree path" {
  local path=' /repo/my feat;$(echo pwned)'
  set_list "[{\"branch\":\"feat/name\",\"path\":\"${path}\"}]"
  run wts 'feat/name'
  [[ "$status" -eq 0 && "$output" == "attach ${path}" ]] || fail "schema 1 path: exit $status: $output"
  set_list "{\"schema\":2,\"items\":[{\"branch\":\"feat/name\",\"worktree\":{\"path\":\"${path}\"}}]}"
  run wts 'feat/name'
  [[ "$status" -eq 0 && "$output" == "attach ${path}" ]] || fail "schema 2 path: exit $status: $output"
}

@test "wts reports an unreadable list instead of a missing worktree" {
  local bad
  local -a cases=(
    ''
    '['
    '[{"branch":"feat","path":"/repo.feat"}][{"branch":"feat","path":"/other"}]'
    '{"schema":1,"items":[{"branch":"feat","worktree":{"path":"/repo.feat"}}]}'
    '{"schema":3,"items":[]}'
    '{"items":[{"branch":"feat","worktree":{"path":"/p"}}]}'
    '"feat"'
    'null'
    '{"schema":2,"items":{}}'
    '["feat"]'
    '[{}]'
    '[{"path":"/repo.feat"}]'
    '{"schema":2,"items":[{}]}'
    '{"schema":2,"items":[{"worktree":{"path":"/repo.feat"}}]}'
    '[{"branch":"feat","path":1}]'
    '[{"branch":1,"path":"/p"}]'
    '{"schema":2,"items":[{"branch":"feat","worktree":{"path":1}}]}'
    '{"schema":2,"items":[{"branch":"feat","worktree":{"path":false}}]}'
    '{"schema":2,"items":[{"branch":"feat","worktree":{}}]}'
    '{"schema":2,"items":[{"branch":"feat","worktree":{"path":null}}]}'
    '{"schema":2,"items":[{"branch":"feat","worktree":{"path":""}}]}'
    '[{"branch":"feat","path":""}]'
    '{"schema":2,"items":[{"branch":"feat","worktree":false}]}'
  )
  for bad in "${cases[@]}"; do
    : >"$WT_LOG"
    : >"$HERDR_LOG"
    printf '%s' "$bad" >"$WT_LIST_FILE"
    run wts feat
    [[ "$status" -ne 0 ]] || fail "unreadable list succeeded: ${bad:-<empty>}"
    [[ "$output" != *"Worktree not found"* ]] || fail "unreadable looked missing: $output"
    [[ "$output" != *"attach "* ]] || fail "unreadable attached: $output"
    [[ "$output" == *"Could not read worktrunk's list"* ]] || fail "no read error for ${bad:-<empty>}: $output"
    [[ "$output" != *"Cannot index array"* ]] || fail "jq leak: $output"
    if grep -q '^remove' "$WT_LOG" || grep -q attach "$HERDR_LOG"; then
      fail "side effect on unreadable list: ${bad:-<empty>}"
    fi
  done
}

@test "wts does not trust list output when worktrunk exits nonzero" {
  set_list '{"schema":2,"items":[{"branch":"feat","worktree":{"path":"/repo.feat"}}]}' 1
  run wts feat
  [[ "$status" -ne 0 && "$output" == *"worktrunk list failed"* ]] || fail "list status: exit $status: $output"
  [[ "$output" != *"Worktree not found"* && "$output" != *"attach "* ]] || fail "trusted stdout: $output"
  if grep -q attach "$HERDR_LOG"; then fail "attached after a failed list"; fi
}

@test "wts picker reads both list schemas and skips null and branch-only rows" {
  local json
  for json in \
    '[{"branch":"main","path":"/repo"},{"branch":"my feat","path":"/repo/my feat"},{"branch":null,"path":"/det"},{"branch":"only"}]' \
    '{"schema":2,"items":[{"branch":"main","worktree":{"path":"/repo"}},{"branch":"my feat","worktree":{"path":"/repo/my feat"}},{"branch":null,"worktree":{"path":"/det"}},{"branch":"only","worktree":null}]}'
  do
    set_list "$json"
    : >"$HERDR_LOG"
    FZF_SELECT='my feat' run wts
    [[ "$status" -eq 0 && "$output" == "attach /repo/my feat" ]] || fail "picker: exit $status: $output"
    [[ "$(cat "$FZF_INPUT")" == $'main\nmy feat' ]] || fail "offered $(cat "$FZF_INPUT")"
  done
}

@test "wts does not attach when fzf selects nothing" {
  run wts
  [[ "$status" -eq 1 && "$output" == "No worktree selected" ]] || fail "cancel: exit $status: $output"
  if grep -q attach "$HERDR_LOG"; then fail "attached on cancel"; fi
}

@test "wts does not attach when fzf fails even if it prints a branch" {
  FZF_SELECT=feat FZF_STATUS=2 run wts
  [[ "$status" -ne 0 ]] || fail "picker failure succeeded: $output"
  [[ ! -s "$HERDR_LOG" ]] || fail "attached after picker failed: $(cat "$HERDR_LOG")"
}

@test "wts returns nonzero when attach fails" {
  ATTACH_STATUS=1 run wts feat
  [[ "$status" -eq 1 && "$output" == "attach /repo.feat" ]] || fail "attach failure: exit $status: $output"
}

@test "wtc opens the schema 1 worktree after switch and skips attach when switch or the list fails" {
  run wtc feat
  [[ "$status" -eq 0 && "$output" == "attach /repo.feat" ]] || fail "wtc schema 1: exit $status: $output"
  grep -qx 'switch feat' "$WT_LOG" || fail "did not switch: $(cat "$WT_LOG")"

  : >"$WT_LOG"
  : >"$HERDR_LOG"
  WT_SWITCH_STATUS=1 run wtc feat
  [[ "$status" -ne 0 && "$output" != *"attach "* ]] || fail "switch failure attached: exit $status: $output"
  if grep -q attach "$HERDR_LOG"; then fail "herdr attach after switch failure"; fi

  : >"$HERDR_LOG"
  WT_SWITCH_STATUS=0 set_list '{'
  run wtc feat
  [[ "$status" -ne 0 && "$output" == *"Could not read worktrunk's list"* && "$output" != *"attach "* ]] \
    || fail "bad list attached: exit $status: $output"
}

@test "wtc says the branch has no worktree when the list is valid and does not attach" {
  set_list '[{"branch":"main","path":"/repo"}]'
  run wtc feat
  [[ "$status" -eq 1 && "$output" == "Worktree not found: feat" ]] || fail "schema 1: exit $status: $output"
  grep -qx 'switch feat' "$WT_LOG" || fail "did not switch: $(cat "$WT_LOG")"
  if grep -q attach "$HERDR_LOG"; then fail "attached cwd for a missing branch"; fi

  : >"$WT_LOG"
  : >"$HERDR_LOG"
  set_list '{"schema":2,"items":[{"branch":"main","worktree":{"path":"/repo"}},{"branch":"feat"}]}'
  run wtc feat
  [[ "$status" -eq 1 && "$output" == "Worktree not found: feat" ]] || fail "branch-only: exit $status: $output"
  if grep -q attach "$HERDR_LOG"; then fail "attached a branch-only row"; fi
}

@test "wtc same-branch failure does not create another worktree or hide the error" {
  local other="$BATS_TEST_TMPDIR/other"
  GIT_ROOT="$BATS_TEST_TMPDIR/repo"
  GIT_BRANCH=feat
  GIT_WORKTREE_LIST="$other [feat]"
  GIT_SWITCH_STATUS=1
  run wtc feat
  [[ "$status" -ne 0 && "$output" == *"Cannot switch to 'main'"* ]] || fail "git switch: exit $status: $output"
  if grep -q attach "$HERDR_LOG" || grep -q '^switch' "$WT_LOG" || grep -q 'worktree add' "$GIT_LOG"; then
    fail "side effect after git switch failed: wt=$(cat "$WT_LOG") git=$(cat "$GIT_LOG")"
  fi

  : >"$WT_LOG"
  : >"$GIT_LOG"
  : >"$HERDR_LOG"
  GIT_SWITCH_STATUS=0
  ATTACH_STATUS=1
  run wtc feat
  [[ "$status" -ne 0 ]] || fail "attach failure succeeded: $output"
  grep -q attach "$HERDR_LOG" || fail "did not try to attach"
  if grep -q '^switch' "$WT_LOG" || grep -q 'worktree add' "$GIT_LOG"; then
    fail "fell through after attach failed"
  fi

  : >"$WT_LOG"
  : >"$GIT_LOG"
  : >"$HERDR_LOG"
  GIT_WORKTREE_LIST=""
  GIT_SWITCH_STATUS=1
  ATTACH_STATUS=0
  run wtc feat
  [[ "$status" -ne 0 && "$output" == *"Cannot switch to 'main'"* ]] || fail "no worktree: exit $status: $output"
  if grep -q 'worktree add' "$GIT_LOG" || grep -q '^switch' "$WT_LOG" || grep -q attach "$HERDR_LOG"; then
    fail "created after switch failed: $(cat "$GIT_LOG")"
  fi

  : >"$WT_LOG"
  : >"$GIT_LOG"
  : >"$HERDR_LOG"
  GIT_SWITCH_STATUS=0
  GIT_WORKTREE_ADD_STATUS=1
  run wtc feat
  [[ "$status" -ne 0 && "$output" == *"Failed to create worktree"* ]] || fail "add: exit $status: $output"
  if grep -q attach "$HERDR_LOG" || grep -q '^switch' "$WT_LOG"; then fail "hid the add failure"; fi
}

@test "wtc returns the attach failure" {
  ATTACH_STATUS=1 run wtc feat
  [[ "$status" -eq 1 && "$output" == "attach /repo.feat" ]] || fail "wtc attach: exit $status: $output"
}

@test "wtd removes a schema 1 worktree and closes its space" {
  run wtd feat
  [[ "$status" -eq 0 ]] || fail "wtd: exit $status: $output"
  grep -qx 'remove feat --force' "$WT_LOG" || fail "did not remove: $(cat "$WT_LOG")"
  grep -qx 'close repo.feat /repo.feat' "$HERDR_LOG" || fail "did not close: $(cat "$HERDR_LOG")"
}

@test "wtd does not remove or close when the branch is missing or the list is unreadable" {
  run wtd gone
  [[ "$status" -eq 1 && "$output" == "Worktree not found: gone" ]] || fail "missing: exit $status: $output"
  if grep -q '^remove' "$WT_LOG" || grep -q '^close' "$HERDR_LOG"; then fail "removed a missing branch"; fi

  : >"$WT_LOG"
  : >"$HERDR_LOG"
  local bad
  for bad in '{' '[{}]' '{"schema":2,"items":[{"worktree":{"path":"/repo.feat"}}]}'; do
    set_list "$bad"
    run wtd feat
    [[ "$status" -ne 0 && "$output" == *"Could not read worktrunk's list"* ]] || fail "unreadable: exit $status: $output"
    [[ "$output" != *"Worktree not found"* ]] || fail "unreadable looked missing: $output"
    if grep -q '^remove' "$WT_LOG" || grep -q '^close' "$HERDR_LOG"; then fail "removed on a bad list"; fi
  done
}

@test "wtd does not remove or close when worktrunk list exits nonzero" {
  set_list '{"schema":2,"items":[{"branch":"feat","worktree":{"path":"/repo.feat"}}]}' 1
  run wtd feat
  [[ "$status" -ne 0 && "$output" == *"worktrunk list failed"* ]] || fail "list status: exit $status: $output"
  [[ "$output" != *"Worktree not found"* ]] || fail "failed list looked missing: $output"
  if grep -q '^remove' "$WT_LOG" || grep -q '^close' "$HERDR_LOG"; then
    fail "removed after a failed list: wt=$(cat "$WT_LOG") herdr=$(cat "$HERDR_LOG")"
  fi
}

@test "wtd does not close the space when remove fails" {
  set_list '{"schema":2,"items":[{"branch":"feat","worktree":{"path":"/repo.feat"}}]}'
  WT_REMOVE_STATUS=1 run wtd feat
  [[ "$status" -ne 0 ]] || fail "remove failure succeeded: $output"
  grep -qx 'remove feat --force' "$WT_LOG" || fail "did not try to remove: $(cat "$WT_LOG")"
  if grep -q '^close' "$HERDR_LOG"; then fail "closed after remove failed: $(cat "$HERDR_LOG")"; fi
}

@test "the shell block leaves a person's t and d alone and defines none of its own" {
  local out
  out="$(bash -c 'alias t="echo my t"; d() { echo my d; }
    source "$1"; alias t; d; alias d 2>/dev/null; alias dev' _ "$ROOT/config/shell/bercail.inc.sh" 2>&1)"
  [[ "$out" == "alias t='echo my t'
my d
alias dev='worktree-dev'" ]] || fail "after the block: $out"
}
