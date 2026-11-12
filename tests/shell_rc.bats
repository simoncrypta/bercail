#!/usr/bin/env bats

setup() {
  load test_helper
  isolate
  # shellcheck source=/dev/null
  source "$ROOT/lib/common.sh"
  # shellcheck source=/dev/null
  source "$ROOT/lib/detect.sh"
  # shellcheck source=/dev/null
  source "$ROOT/lib/shell-rc.sh"
}

@test "re-running the marker block upsert leaves .bashrc unchanged" {
  local rc="$HOME/.bashrc" first
  printf 'alias ll="ls -l"\n' >"$rc"
  upsert_marker_block "$rc" bash >/dev/null
  first="$(<"$rc")"
  upsert_marker_block "$rc" bash >/dev/null
  upsert_marker_block "$rc" bash >/dev/null
  [[ "$(<"$rc")" == "$first" ]] || fail "amending must not change the file: $(cat -A "$rc")"
  [[ "$(grep -c "$BERCAIL_MARKER_START" "$rc")" == 1 ]] || fail "one marker block"
  head -1 "$rc" | grep -qx 'alias ll="ls -l"' || fail "the person's lines stay"
}

@test "shell integration keeps a person's worktree-dev and still installs the marker" {
  local rc="$HOME/.bashrc" rc_code=0
  export SHELL=/bin/bash
  printf '%s\n' 'worktree-dev() { echo mine; }' >"$rc"
  if install_shell_integration >/dev/null; then rc_code=0; else rc_code=$?; fi
  [[ "$rc_code" -eq 0 ]] || fail "shell integration skipped a person's worktree-dev (rc=$rc_code)"
  grep -qx 'worktree-dev() { echo mine; }' "$rc" || fail "the person's worktree-dev was changed: $(<"$rc")"
  grep -qF "$BERCAIL_MARKER_START" "$rc" || fail "the marker was not installed"
}
