#!/usr/bin/env bash
# shellcheck shell=bash

uninstall_agentic_dev() {
  local managed_plugin_kind="" remove_managed_plugin_files=0
  info "uninstalling bercail..."

  remove_marker_block "$(shell_rc_for bash)"
  remove_marker_block "$(shell_rc_for zsh)"

  if [[ -e "$LOCAL_BIN/bercail" ]]; then
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

  if command -v herdr >/dev/null 2>&1; then
    if ! plugin_inspect "$PLUGIN_ID"; then
      warn "cannot inspect Herdr plugin $PLUGIN_ID; preserving its registration and files"
    elif plugin_is_exact_local "$HERDR_DEV_LAYOUT_LEGACY_DIR"; then
      managed_plugin_kind="local"
      if confirm "Unlink managed Herdr plugin $PLUGIN_ID?"; then
        if _plugin_remove_registration "$PLUGIN_ID" "$managed_plugin_kind"; then
          remove_managed_plugin_files=1
        else
          warn "failed to unlink $PLUGIN_ID; keeping its source directory"
        fi
      fi
    elif [[ "$PLUGIN_STATUS" == "present" \
      && "$PLUGIN_SOURCE_KIND" == "github" \
      && "$PLUGIN_SOURCE_REPO" == "$DEV_LAYOUT_PLUGIN_REPO" ]]; then
      managed_plugin_kind="github"
      if confirm "Uninstall managed Herdr plugin $PLUGIN_ID?"; then
        _plugin_remove_registration "$PLUGIN_ID" "$managed_plugin_kind" || warn "failed to uninstall $PLUGIN_ID"
      fi
    elif [[ "$PLUGIN_STATUS" == "present" ]]; then
      warn "preserving unowned Herdr plugin $PLUGIN_ID: ${PLUGIN_SOURCE_RAW#- }"
    fi
  fi

  if confirm "Also remove managed herdr config and integration files?"; then
    run rm -f "$HERDR_CONFIG_DIR/config.toml"
    if [[ "$remove_managed_plugin_files" -eq 1 ]]; then
      run rm -rf "$HERDR_DEV_LAYOUT_LEGACY_DIR"
    elif [[ -e "$HERDR_DEV_LAYOUT_LEGACY_DIR" ]]; then
      info "keeping Herdr plugin files without confirmed managed ownership: $HERDR_DEV_LAYOUT_LEGACY_DIR"
    fi
    run rm -f "$WORKTRUNK_CONFIG_DIR/herdr-layout.sh"
    [[ ! -e "$WORKTRUNK_CONFIG_DIR/config.toml" ]] \
      || info "keeping third-party worktrunk config: $WORKTRUNK_CONFIG_DIR/config.toml"
  fi

  if confirm "Remove managed skills (~/.agents/skills/handoff, review)?"; then
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
