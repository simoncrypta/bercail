#!/usr/bin/env bash
# shellcheck shell=bash

uninstall_agentic_dev() {
  local keys tmp mod keyboard
  info "uninstalling bercail..."

  remove_marker_block "$(shell_rc_for bash)"
  remove_marker_block "$(shell_rc_for zsh)"

  if [[ -L "$LOCAL_BIN/bercail" && "$(readlink "$LOCAL_BIN/bercail")" != "$AGENTIC_DEV_SHARE_DIR"* ]]; then
    info "keeping $LOCAL_BIN/bercail (link from mise/packslip; remove it with that tool)"
  elif [[ -e "$LOCAL_BIN/bercail" ]]; then
    info "remove: $LOCAL_BIN/bercail"
    run rm -f "$LOCAL_BIN/bercail"
  fi
  if declare -F remove_desk_restore >/dev/null; then
    remove_desk_restore
  fi
  if [[ -e "$LOCAL_BIN/bercail-desk-agent" ]]; then
    info "remove: $LOCAL_BIN/bercail-desk-agent"
    run rm -f "$LOCAL_BIN/bercail-desk-agent"
  fi

  if [[ -e "$OMARCHY_POST_UPDATE_HOOK" ]]; then
    info "remove: $OMARCHY_POST_UPDATE_HOOK"
    run rm -f "$OMARCHY_POST_UPDATE_HOOK"
  fi
  if [[ -d "$AGENTIC_DEV_SHARE_DIR" ]]; then
    info "remove: $AGENTIC_DEV_SHARE_DIR"
    run rm -rf "$AGENTIC_DEV_SHARE_DIR"
  fi

  if confirm "Remove ~/.config/bercail (includes config.toml)?"; then
    if [[ -e "$AGENTIC_DEV_CONFIG_DIR" ]]; then
      info "remove: $AGENTIC_DEV_CONFIG_DIR"
      run rm -rf "$AGENTIC_DEV_CONFIG_DIR"
    fi
  else
    info "keeping user config: $AGENTIC_DEV_USER_CONFIG"
    run rm -rf "$AGENTIC_DEV_SHELL_DIR"
    run rm -f "$AGENTIC_DEV_CONFIG_DIR/config-reader.sh"
  fi

  if confirm "Remove the bercail Herdr layout, mods and keys?"; then
    run rm -f "$HERDR_APP_CONFIG_DIR/$HERDR_APP_LAYOUT"
    for mod in "${HERDR_APP_MODS[@]}"; do run rm -rf "$HERDR_APP_CONFIG_DIR/mods/$mod"; done
    keys="$HERDR_APP_CONFIG_DIR/keys.json"
    if [[ -f "$keys" ]] && jq -e --arg s "$HERDR_APP_KEYS_SECTION" 'has($s)' "$keys" >/dev/null 2>&1; then
      info "remove: $HERDR_APP_KEYS_SECTION from $keys"
      if [[ "$DRY_RUN" -ne 1 ]]; then
        tmp="$(mktemp)"
        jq --arg s "$HERDR_APP_KEYS_SECTION" 'del(.[$s])' "$keys" >"$tmp" && mv "$tmp" "$keys"
      fi
    fi
    run rm -f "$WORKTRUNK_CONFIG_DIR/herdr-layout.sh"
    [[ ! -e "$WORKTRUNK_CONFIG_DIR/config.toml" ]] \
      || info "keeping third-party worktrunk config: $WORKTRUNK_CONFIG_DIR/config.toml"
  fi

  if declare -F remove_bstack >/dev/null \
    && confirm "Remove bstack's Pi profile and agent templates (only files bstack manages)?"; then
    remove_bstack
  fi

  if confirm "Remove managed skills (~/.agents/skills/handoff, review, bstack, council, autopilot, how, why, unslop, desk-restore, unit-testing)?"; then
    remove_managed_skills
  fi

  # Older installs wrote this whole file. A customized input-method config is not ours.
  keyboard="$HOME/.config/fcitx5/conf/keyboard.conf"
  if [[ -f "$keyboard" ]] && cmp -s "$keyboard" - <<'EOF'
# Clear spell/hint completion toggles (Ctrl+Alt+H/J) so those chords stay free.
# See: https://github.com/basecamp/omarchy/discussions/1578
Hint Trigger=
One Time Hint Trigger=
EOF
  then
    if confirm "Remove fcitx5 keyboard.conf override?"; then
      run rm -f "$keyboard"
    fi
  fi

  log "uninstall complete"
}
