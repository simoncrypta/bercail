#!/usr/bin/env bash
# shellcheck shell=bash
# Doctor checks. Source after detect/config/omarchy/skills.

doctor_omarchy_integration() {
  local missing=0
  if [[ "$(detect_os)" != "linux" ]]; then
    return 0
  fi
  if is_omarchy || command -v fcitx5 >/dev/null 2>&1; then
    if [[ -f "${FCITX5_CONFIG_DIR}/conf/keyboard.conf" ]] \
      && grep -q '^Hint Trigger=$' "${FCITX5_CONFIG_DIR}/conf/keyboard.conf" 2>/dev/null; then
      log "  ok  fcitx5 keyboard.conf (hint triggers cleared)"
    else
      log "  missing  fcitx5 keyboard.conf hint trigger override"
      missing=$((missing + 1))
    fi
  fi
  if is_omarchy || has_hyprland; then
    if hypr_has_herdr_binding; then
      log "  ok  hypr bindings include herdr"
    elif omarchy_has_native_herdr; then
      log "  ok  omarchy native Herdr launcher (SUPER+CTRL+RETURN)"
    else
      log "  missing  hypr SUPER+ALT+RETURN herdr binding"
      missing=$((missing + 1))
    fi
  fi
  return "$missing"
}

doctor_adopted_plugin() {
  local id="$1" repo="$2" ref="$3"
  if ! plugin_inspect "$id"; then
    log "  invalid  third-party plugin $id registry/list entry is ambiguous or malformed"
    return 1
  fi
  if plugin_is_exact_github "$repo" "$ref"; then
    log "  ok  third-party plugin $id [github:$repo@$ref]"
    return 0
  fi
  if [[ "$PLUGIN_STATUS" == "missing" ]]; then
    log "  missing  third-party plugin $id"
    return 1
  fi
  log "  warning  third-party plugin $id is pre-existing and preserved [${PLUGIN_SOURCE_RAW#- }]"
  return 0
}

doctor_plugin() {
  local missing=0
  if ! command -v herdr >/dev/null 2>&1; then
    log "  missing  herdr (cannot check plugin)"
    return 1
  fi

  if ! plugin_inspect "$PLUGIN_ID"; then
    log "  invalid  plugin $PLUGIN_ID registry/list entry is ambiguous or malformed"
    missing=$((missing + 1))
  elif plugin_is_exact_local "$HERDR_DEV_LAYOUT_LEGACY_DIR"; then
    if [[ -d "$HERDR_DEV_LAYOUT_LEGACY_DIR" ]]; then
      log "  ok  plugin $PLUGIN_ID [local:$HERDR_DEV_LAYOUT_LEGACY_DIR] (legacy)"
    else
      log "  stale  plugin $PLUGIN_ID source directory is missing: $HERDR_DEV_LAYOUT_LEGACY_DIR"
      missing=$((missing + 1))
    fi
  elif plugin_is_exact_github "$DEV_LAYOUT_PLUGIN_REPO" "$DEV_LAYOUT_PLUGIN_REF"; then
    log "  ok  plugin $PLUGIN_ID [github:$DEV_LAYOUT_PLUGIN_REPO@$DEV_LAYOUT_PLUGIN_REF]"
  elif [[ "$PLUGIN_STATUS" == "missing" ]]; then
    log "  missing  plugin $PLUGIN_ID"
    missing=$((missing + 1))
  else
    log "  mismatched  plugin $PLUGIN_ID preserved [${PLUGIN_SOURCE_RAW#- }]"
    missing=$((missing + 1))
  fi

  doctor_adopted_plugin pickr "$PICKR_PLUGIN_REPO" "$PICKR_PLUGIN_REF" || missing=$((missing + 1))
  doctor_adopted_plugin worktrunk "$WORKTRUNK_PLUGIN_REPO" "$WORKTRUNK_PLUGIN_REF" || missing=$((missing + 1))
  if plugin_inspect "$LEGACY_LAYOUT_PLUGIN_ID" && [[ "$PLUGIN_STATUS" == "present" ]]; then
    log "  warning  legacy layout plugin $LEGACY_LAYOUT_PLUGIN_ID still installed (run update to migrate)"
  fi
  [[ "$missing" -eq 0 ]]
}

doctor_helper() {
  local src
  if [[ ! -f "$WORKTRUNK_CONFIG_DIR/herdr-layout.sh" ]]; then
    log "  missing  herdr-layout.sh"
    return 1
  fi
  if ! src="$(_recorded_install_source)"; then
    log "  unverified  herdr-layout.sh (no recorded install source)"
    return 1
  fi
  if [[ -f "$src/config/worktrunk/herdr-layout.sh" ]] \
    && ! cmp -s "$src/config/worktrunk/herdr-layout.sh" "$WORKTRUNK_CONFIG_DIR/herdr-layout.sh"; then
    log "  stale  herdr-layout.sh (run ./install.sh from $src)"
    return 1
  fi
  log "  ok  herdr-layout.sh"
  return 0
}

_doctor_one_skill() {
  local skill_id="$1" dest src
  dest="$(skill_canonical_dir "$skill_id")"
  if [[ ! -f "${dest}/SKILL.md" ]]; then
    log "  missing  skill $skill_id at $dest"
    return 1
  fi
  if ! src="$(_recorded_install_source)"; then
    log "  unverified  skill $skill_id (no recorded install source)"
    return 1
  fi
  if [[ -f "$src/skills/${skill_id}/SKILL.md" ]] \
    && ! cmp -s "$src/skills/${skill_id}/SKILL.md" "${dest}/SKILL.md"; then
    log "  stale  skill $skill_id (run ./install.sh from $src)"
    return 1
  fi
  log "  ok  skill $skill_id [$dest]"
  return 0
}

doctor_skill() {
  local missing=0 agent_cmd agent_skills_dir link skill_id
  while IFS= read -r skill_id; do
    [[ -n "$skill_id" ]] || continue
    _doctor_one_skill "$skill_id" || missing=$((missing + 1))
  done < <(_skill_ids)

  agent_cmd="$(read_agent_command 2>/dev/null || printf '%s' "cursor-agent")"
  if agent_skills_dir="$(skill_agent_extra_global_dirs "$agent_cmd" 2>/dev/null)"; then
    while IFS= read -r skill_id; do
      [[ -n "$skill_id" ]] || continue
      link="${agent_skills_dir}/${skill_id}"
      if [[ -L "$link" ]] && _skill_link_is_ours "$link" "$skill_id"; then
        log "  ok  skill link for agent '$agent_cmd' [$link]"
      elif [[ -e "$link" ]]; then
        log "  warning  skill path exists but is not our symlink [$link]"
      else
        log "  missing  skill link for agent '$agent_cmd' [$link]"
        missing=$((missing + 1))
      fi
    done < <(_skill_ids)
  else
    log "  ok  agent '$agent_cmd' uses ~/.agents/skills (no extra link)"
  fi
  [[ "$missing" -eq 0 ]]
}

doctor_pstack() {
  if pstack_plugin_present; then
    log "  ok  pstack (cursor plugin, /poteto-mode)"
    return 0
  fi
  log "  missing  pstack (in Cursor: /add-plugin pstack — required for handoff children)"
  return 1
}
