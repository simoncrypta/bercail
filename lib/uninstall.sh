#!/usr/bin/env bash
# shellcheck shell=bash

uninstall_agentic_dev() {
  local keys tmp
  info "uninstalling bercail..."

  remove_marker_block "$(shell_rc_for bash)"
  remove_marker_block "$(shell_rc_for zsh)"

  if [[ -L "$LOCAL_BIN/bercail" && "$(readlink "$LOCAL_BIN/bercail")" != "$AGENTIC_DEV_SHARE_DIR"* ]]; then
    info "keeping $LOCAL_BIN/bercail (link from mise/packslip; remove it with that tool)"
  elif [[ -e "$LOCAL_BIN/bercail" ]]; then
    info "remove: $LOCAL_BIN/bercail"
    run rm -f "$LOCAL_BIN/bercail"
  fi
  if [[ -e "$LOCAL_BIN/agentic-dev" ]]; then
    info "remove: $LOCAL_BIN/agentic-dev"
    run rm -f "$LOCAL_BIN/agentic-dev"
  fi

  if [[ -d "$AGENTIC_DEV_SHARE_DIR" ]]; then
    info "remove: $AGENTIC_DEV_SHARE_DIR"
    run rm -rf "$AGENTIC_DEV_SHARE_DIR"
  fi
  if [[ -d "$LEGACY_AGENTIC_DEV_SHARE_DIR" ]]; then
    info "remove: $LEGACY_AGENTIC_DEV_SHARE_DIR"
    run rm -rf "$LEGACY_AGENTIC_DEV_SHARE_DIR"
  fi

  if confirm "Remove ~/.config/bercail (includes config.toml)?"; then
    if [[ -e "$AGENTIC_DEV_CONFIG_DIR" ]]; then
      info "remove: $AGENTIC_DEV_CONFIG_DIR"
      run rm -rf "$AGENTIC_DEV_CONFIG_DIR"
    fi
    if [[ -e "$LEGACY_AGENTIC_DEV_CONFIG_DIR" ]]; then
      info "remove: $LEGACY_AGENTIC_DEV_CONFIG_DIR"
      run rm -rf "$LEGACY_AGENTIC_DEV_CONFIG_DIR"
    fi
  else
    info "keeping user config: $AGENTIC_DEV_USER_CONFIG"
    run rm -rf "$AGENTIC_DEV_SHELL_DIR"
    run rm -f "$AGENTIC_DEV_CONFIG_DIR/config-reader.sh"
  fi

  if confirm "Remove the bercail Herdr layout, desk mod and keys?"; then
    run rm -f "$HERDR_APP_CONFIG_DIR/$HERDR_APP_LAYOUT"
    run rm -rf "$HERDR_APP_CONFIG_DIR/mods/bercail-desk"
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
    && confirm "Remove bstack's opencode agents, commands, and opencode.jsonc (only files bstack manages)?"; then
    remove_bstack
  fi

  if confirm "Remove managed skills (~/.agents/skills/handoff, review, bstack, council, autopilot, how, why, unslop)?"; then
    remove_managed_skills
  fi

  if confirm "Remove fcitx5 keyboard.conf override?"; then
    run rm -f "${FCITX5_CONFIG_DIR}/conf/keyboard.conf"
  fi

  if confirm "Remove nvim file-tree overlay (~/.config/nvim/lua/plugins/agentic-dev-explorer.lua)?"; then
    run rm -f "${XDG_CONFIG_HOME:-$HOME/.config}/nvim/lua/plugins/agentic-dev-explorer.lua"
  fi

  log "uninstall complete"
}
