#!/usr/bin/env bats
# The shell block (config/shell/bercail.inc.sh) with worktrunk and the Herdr
# helper as stand-ins.

setup() {
  load test_helper
  isolate
  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN" "$HOME/.config/worktrunk"
  # Stub: the helper's attach prints the path it was given.
  printf 'wt_herdr_attach() { printf "attach %%s\\n" "$1"; }\n' >"$HOME/.config/worktrunk/herdr-layout.sh"
  # Stub: worktrunk's list, in the shape 0.80.0 and later print.
  cat >"$BIN/wt" <<'WT'
#!/usr/bin/env bash
[[ "$*" == "list --format=json" ]] || exit 1
printf '%s\n' '{"schema":1,"items":[{"branch":"main","worktree":{"path":"/repo"}},{"branch":"feat","worktree":{"path":"/repo.feat"}}]}'
WT
  chmod +x "$BIN/wt"
  PATH="$BIN:$PATH"
  # shellcheck source=/dev/null
  source "$ROOT/config/shell/bercail.inc.sh"
}

@test "wts opens the space of the worktree worktrunk lists for the branch" {
  run wts feat
  [[ "$status" -eq 0 && "$output" == "attach /repo.feat" ]] || fail "wts feat: exit $status: $output"
}

@test "wts says so when worktrunk lists no worktree for the branch" {
  run wts gone
  [[ "$status" -eq 1 && "$output" == "Worktree not found: gone" ]] || fail "wts gone: exit $status: $output"
}

@test "the shell block leaves a person's t and d alone and defines none of its own" {
  local out
  out="$(bash -c 'alias t="echo my t"; d() { echo my d; }
    source "$1"; alias t; d; alias d 2>/dev/null; alias dev' _ "$ROOT/config/shell/bercail.inc.sh" 2>&1)"
  [[ "$out" == "alias t='echo my t'
my d
alias dev='worktree-dev'" ]] || fail "after the block: $out"
}
