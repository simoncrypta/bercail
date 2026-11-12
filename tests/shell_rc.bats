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
  [[ "$(grep -c "$AGENTIC_DEV_MARKER_START" "$rc")" == 1 ]] || fail "one marker block"
  head -1 "$rc" | grep -qx 'alias ll="ls -l"' || fail "the person's lines stay"
}
