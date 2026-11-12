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

# Omarchy's default agent starts as pi, the desk's agent. A choice already
# there stays unless bercail reconfigure runs.
sync_omarchy_default_agent() {
  local dest current
  is_omarchy || return 0
  dest="$OMARCHY_DEFAULT_AGENT_FILE"
  if [[ -f "$dest" && "$RECONFIGURE" -ne 1 ]]; then
    current="$(tr -d '\n' <"$dest")"
    info "keeping omarchy default agent: $current"
    return 0
  fi
  info "syncing omarchy default agent: pi"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "[dry-run] would write $dest"
    return 0
  fi
  ensure_dir "$(dirname "$dest")"
  printf '%s\n' pi >"$dest"
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

# omarchy-update runs this hook after every update: it fast-forwards the
# recorded clone and runs bercail update. Installed the supported way, under
# one fixed name, so each update replaces it rather than adding another.
deploy_omarchy_post_update_hook() {
  local staged="${BERCAIL_SHARE_DIR}/omarchy/bercail.hook"
  is_omarchy || return 0
  deploy_install_file "config/omarchy/bercail.hook" "$staged"
  if [[ -f "$OMARCHY_POST_UPDATE_HOOK" ]] && cmp -s "$staged" "$OMARCHY_POST_UPDATE_HOOK"; then
    info "unchanged: $OMARCHY_POST_UPDATE_HOOK"
    return 0
  fi
  if ! command -v omarchy-hook-install >/dev/null 2>&1; then
    info "skipping omarchy post-update hook (omarchy-hook-install not found)"
    return 0
  fi
  run omarchy-hook-install post-update "$staged"
}

deploy_omarchy_integration() {
  if is_omarchy || has_hyprland; then
    patch_hypr_herdr_binding
  fi
  deploy_omarchy_post_update_hook
}
