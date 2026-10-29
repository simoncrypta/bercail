#!/usr/bin/env bash
# shellcheck shell=bash

HYPR_BINDINGS_LUA="${HOME}/.config/hypr/bindings.lua"
HYPR_BINDINGS_CONF="${HOME}/.config/hypr/bindings.conf"
OMARCHY_DEFAULT_AGENT_FILE="${HOME}/.config/omarchy/defaults/agent"

hypr_bindings_file() {
  if [[ -f "$HYPR_BINDINGS_LUA" ]]; then
    printf '%s' "$HYPR_BINDINGS_LUA"
    return 0
  fi
  if [[ -f "$HYPR_BINDINGS_CONF" ]]; then
    printf '%s' "$HYPR_BINDINGS_CONF"
    return 0
  fi
  return 1
}

# SUPER+ALT+RETURN launches the Herdr app, or focuses its window.
herdr_hypr_binding_line() {
  if is_omarchy; then
    printf '%s' 'bindd = SUPER ALT, RETURN, Herdr, exec, omarchy-launch-or-focus "^herdr-app$" herdr-app'
  else
    printf '%s' 'bind = SUPER ALT, RETURN, exec, herdr-app'
  fi
}

herdr_hypr_binding_lua() {
  if is_omarchy; then
    cat <<'EOF'
-- SUPER+ALT+RETURN was Tmux; launch the Herdr app (or focus its window) instead.
hl.unbind("SUPER + ALT + RETURN")
o.bind("SUPER + ALT + RETURN", "Herdr", { launch = "herdr-app", focus = "^herdr-app$" })
EOF
  else
    cat <<'EOF'
-- SUPER+ALT+RETURN → Herdr app
hl.unbind("SUPER + ALT + RETURN")
hl.bind("SUPER + ALT + RETURN", hl.dsp.exec_cmd("herdr-app"), { description = "Herdr" })
EOF
  fi
}

hypr_has_herdr_binding() {
  local file
  file="$(hypr_bindings_file)" || return 1
  grep -q 'herdr-app' "$file" 2>/dev/null
}

omarchy_restart_fcitx5() {
  if command -v omarchy >/dev/null 2>&1; then
    info "restarting fcitx5 via omarchy restart xcompose"
    omarchy restart xcompose 2>/dev/null && return 0
    omarchy restart app fcitx5 --disable notificationitem 2>/dev/null && return 0
  fi
  if command -v omarchy-restart-app >/dev/null 2>&1; then
    info "restarting fcitx5 via omarchy-restart-app"
    omarchy-restart-app fcitx5 --disable notificationitem 2>/dev/null && return 0
  fi
  return 1
}

deploy_fcitx5_keyboard_conf() {
  [[ "$(detect_os)" == "linux" ]] || return 0
  if ! is_omarchy && ! command -v fcitx5 >/dev/null 2>&1; then
    info "skipping fcitx5 (not installed)"
    return 0
  fi

  deploy_install_file "config/fcitx5/conf/keyboard.conf" "${FCITX5_CONFIG_DIR}/conf/keyboard.conf"
  restart_fcitx5
}

restart_fcitx5() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "[dry-run] restart fcitx5"
    return 0
  fi
  if omarchy_restart_fcitx5; then
    return 0
  fi
  if command -v fcitx5 >/dev/null 2>&1; then
    info "restarting fcitx5"
    pkill -x fcitx5 2>/dev/null || true
    if command -v uwsm-app >/dev/null 2>&1; then
      uwsm-app -- fcitx5 --disable notificationitem &
    elif command -v systemctl >/dev/null 2>&1 \
      && systemctl --user is-active fcitx5.service >/dev/null 2>&1; then
      systemctl --user restart fcitx5.service
    else
      fcitx5 --disable notificationitem &
    fi
  fi
}

omarchy_known_agent() {
  case "$1" in
    grok|claude|codex|opencode|gemini|copilot|crush|pi|omp) return 0 ;;
    *) return 1 ;;
  esac
}

sync_omarchy_default_agent() {
  local cmd dest
  is_omarchy || return 0
  cmd="$(read_agent_command 2>/dev/null || true)"
  omarchy_known_agent "$cmd" || return 0
  dest="$OMARCHY_DEFAULT_AGENT_FILE"
  if [[ -f "$dest" && "$RECONFIGURE" -ne 1 ]]; then
    info "keeping omarchy default agent: $(tr -d '\n' <"$dest")"
    return 0
  fi
  info "syncing omarchy default agent: $cmd"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "[dry-run] would write $dest"
    return 0
  fi
  ensure_dir "$(dirname "$dest")"
  printf '%s\n' "$cmd" >"$dest"
}

reload_hyprland_if_possible() {
  [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]] || return 0
  command -v hyprctl >/dev/null 2>&1 || return 0
  hyprctl reload >/dev/null 2>&1 || true
  if errors="$(hyprctl configerrors 2>/dev/null)" && [[ -n "$errors" && "$errors" != "ok" ]]; then
    warn "hyprctl configerrors: $errors"
  fi
}

patch_hypr_conf_herdr_binding() {
  local file="$1"
  local tmp replaced=0 binding
  binding="$(herdr_hypr_binding_line)"
  tmp="$(mktemp)"
  while IFS= read -r line; do
    if [[ "$line" =~ SUPER[[:space:]]+ALT,[[:space:]]+RETURN ]] \
      && [[ "$line" =~ tmux|Tmux|herdr ]]; then
      printf '%s\n' "$binding"
      replaced=1
    else
      printf '%s\n' "$line"
    fi
  done <"$file" >"$tmp"

  if [[ "$replaced" -eq 0 ]]; then
    printf '\n%s\n' "$binding" >>"$tmp"
  fi
  mv "$tmp" "$file"
}

patch_hypr_lua_herdr_binding() {
  local file="$1"
  printf '\n%s\n' "$(herdr_hypr_binding_lua)" >>"$file"
}

patch_hypr_herdr_binding() {
  local file
  file="$(hypr_bindings_file)" || {
    warn "hypr bindings not found: $HYPR_BINDINGS_LUA or $HYPR_BINDINGS_CONF"
    return 1
  }

  if hypr_has_herdr_binding; then
    info "hypr already launches the Herdr app — skipping"
    return 0
  fi

  if ! confirm "Patch ${file/#$HOME/~} to launch the Herdr app on SUPER+ALT+RETURN?"; then
    info "skipping hypr binding patch"
    return 0
  fi

  info "patching hypr bindings for the Herdr app"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "[dry-run] would update $file"
    return 0
  fi

  if [[ "$file" == *.lua ]]; then
    patch_hypr_lua_herdr_binding "$file"
  else
    patch_hypr_conf_herdr_binding "$file"
  fi

  info "hypr bindings updated"
  reload_hyprland_if_possible
}

deploy_omarchy_integration() {
  deploy_fcitx5_keyboard_conf

  if is_omarchy || has_hyprland; then
    patch_hypr_herdr_binding
  fi
}
