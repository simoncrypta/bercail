# shellcheck shell=bash
# Once per bats run: drop what ties the process to the desk it started from.
# Each @test then gets its own HOME (test_helper.bash).
setup_suite() {
  # mise shims stop resolving once HOME moves: use the tools' own bin dirs, and
  # drop the shims so a tool mise does not manage here falls through to the system.
  if command -v mise >/dev/null 2>&1; then
    local bins
    bins="$(mise bin-paths 2>/dev/null | paste -sd:)"
    PATH="${bins:+$bins:}$(tr : '\n' <<<"$PATH" | grep -v '/mise/shims$' | paste -sd:)"
  fi
  unset BASH_ENV OPENCODE_CONFIG_DIR HYPRLAND_INSTANCE_SIGNATURE
  # The same clock zone and collation on every machine.
  export TZ=UTC LC_ALL=C.UTF-8
  local var
  while IFS= read -r var; do
    unset "$var"
  done < <(compgen -e | grep -E '^(HC|HERDR|BERCAIL|BEADS|BD|HANDOFF)_')

  # These act on the live desktop whatever HOME is (omarchy restart xcompose
  # restarts the running fcitx5). Shadow the ones installed here with a stub
  # that logs the call, so detection is unchanged; teardown_suite fails on any.
  # A test that needs one puts its own stub first on PATH.
  export DESKTOP_CALLS="$BATS_RUN_TMPDIR/desktop-calls"
  local tool desk="$BATS_RUN_TMPDIR/desktop-bin"
  mkdir -p "$desk"
  for tool in omarchy omarchy-restart-app omarchy-hook-install hyprctl fcitx5 uwsm-app notify-send; do
    command -v "$tool" >/dev/null 2>&1 || continue
    # shellcheck disable=SC2016 # expands when the stub runs
    printf '#!/bin/sh\nprintf "%%s: %s %%s\\n" "$DESKTOP_TEST" "$*" >>"$DESKTOP_CALLS"\n' "$tool" >"$desk/$tool"
    chmod +x "$desk/$tool"
  done
  export PATH="$desk:$PATH" __MISE_BASH_ENV_LOADED=1
}

teardown_suite() {
  [[ -s "$DESKTOP_CALLS" ]] || return 0
  printf 'FAIL: tests reached the live desktop:\n' >&2
  cat "$DESKTOP_CALLS" >&2
  return 1
}
