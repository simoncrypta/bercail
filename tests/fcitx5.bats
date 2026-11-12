#!/usr/bin/env bats
# Install/update must leave the input method alone. Uninstall may remove only
# the exact override bercail used to ship. All desktop commands are stand-ins.

setup() {
  load test_helper
  isolate
  TOOLS="$BATS_TEST_TMPDIR/bin"
  CALLS="$BATS_TEST_TMPDIR/desktop.log"
  KEYBOARD="$HOME/.config/fcitx5/conf/keyboard.conf"
  mkdir -p "$TOOLS" "${KEYBOARD%/*}" "$HOME/.config/bercail" "$HOME/.config/hypr"
  local tool
  for tool in bash sh env cat cp mv rm ln mkdir chmod cmp dirname basename realpath readlink \
    find grep sed awk tr sort uniq head tail wc mktemp date git jq touch uname sleep stat cut; do
    ln -s "$(command -v "$tool")" "$TOOLS/$tool"
  done
  for tool in herdr-app hc wt bd fzf pi tuicr; do
    printf '#!/bin/sh\n[ "$1" != --version ] || echo 99.0.0\nexit 0\n' >"$TOOLS/$tool"
    chmod +x "$TOOLS/$tool"
  done
  for tool in omarchy fcitx5 pkill uwsm-app; do
    printf '#!/bin/sh\nprintf "%%s %%s\\n" "%s" "$*" >>"$CALLS"\n' "$tool" >"$TOOLS/$tool"
    chmod +x "$TOOLS/$tool"
  done
  printf '#!/bin/sh\nexit 1\n' >"$TOOLS/curl"
  chmod +x "$TOOLS/curl"
  printf '[bstack]\nenabled = false\n' >"$HOME/.config/bercail/config.toml"
  printf 'bind = SUPER ALT, RETURN, exec, herdr-app\n' >"$HOME/.config/hypr/bindings.conf"
  : >"$CALLS"
}

bercail() {
  env -i HOME="$HOME" PATH="$TOOLS" SHELL=/bin/bash INSTALL_SRC="$ROOT" \
    CALLS="$CALLS" BERCAIL_NO_PROMPT=1 "$ROOT/bin/bercail" "$@" </dev/null
}

uninstall_yes() {
  env -i HOME="$HOME" PATH="$TOOLS" SHELL=/bin/bash ROOT="$ROOT" \
    bash -c 'source "$ROOT/lib/common.sh"; source "$ROOT/lib/detect.sh";
      source "$ROOT/lib/config.sh"; source "$ROOT/lib/shell-rc.sh";
      source "$ROOT/lib/skills.sh"; source "$ROOT/lib/uninstall.sh";
      YES=1; uninstall_agentic_dev'
}

@test "update preserves the keyboard config and never restarts the input method" {
  printf '[Keyboard]\nHint Trigger=Control+Alt+h\nCustom=keep me\n' >"$KEYBOARD"
  local before output
  before="$(<"$KEYBOARD")"
  output="$(bercail update 2>&1)" || fail "update: $output"
  [[ "$(<"$KEYBOARD")" == "$before" ]] || fail "keyboard config changed"
  [[ ! -s "$CALLS" ]] || fail "update called the desktop: $(<"$CALLS")"
}

@test "uninstall keeps a customized keyboard config" {
  printf 'Hint Trigger=Control+Alt+h\nCustom=keep me\n' >"$KEYBOARD"
  local before output
  before="$(<"$KEYBOARD")"
  output="$(uninstall_yes 2>&1)" || fail "uninstall: $output"
  [[ -f "$KEYBOARD" && "$(<"$KEYBOARD")" == "$before" ]] || fail "custom keyboard config removed"
}

@test "uninstall removes the unchanged keyboard override when the person agrees" {
  cat >"$KEYBOARD" <<'EOF'
# Clear spell/hint completion toggles (Ctrl+Alt+H/J) so those chords stay free.
# See: https://github.com/basecamp/omarchy/discussions/1578
Hint Trigger=
One Time Hint Trigger=
EOF
  uninstall_yes >"$BATS_TEST_TMPDIR/uninstall.log" 2>&1 \
    || fail "uninstall: $(<"$BATS_TEST_TMPDIR/uninstall.log")"
  [[ ! -e "$KEYBOARD" ]] || fail "shipped keyboard override remains"
}
