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
      log "  ok  hypr SUPER+ALT+RETURN launches the Herdr app"
    else
      log "  missing  hypr SUPER+ALT+RETURN Herdr app binding"
      missing=$((missing + 1))
    fi
  fi
  return "$missing"
}

# The bercail layout, its desk mod and its keys in the Herdr app's home.
doctor_herdr_app() {
  local missing=0 src rel dest ours
  src="$(_recorded_install_source 2>/dev/null || true)"
  if [[ -f "$HERDR_APP_CONFIG_DIR/$HERDR_APP_LAYOUT" ]]; then
    log "  ok  Herdr layout bercail"
  else
    log "  missing  Herdr layout $HERDR_APP_CONFIG_DIR/$HERDR_APP_LAYOUT"
    missing=$((missing + 1))
  fi
  for rel in "${HERDR_APP_MOD_FILES[@]}"; do
    dest="$HERDR_APP_CONFIG_DIR/$rel"
    if [[ ! -f "$dest" ]]; then
      log "  missing  Herdr mod file $dest"
      missing=$((missing + 1))
    elif [[ -n "$src" && -f "$src/bercail/$rel" ]] && ! cmp -s "$src/bercail/$rel" "$dest"; then
      log "  stale  Herdr mod file $dest (run: bercail update)"
      missing=$((missing + 1))
    fi
  done
  if [[ "$missing" -eq 0 ]]; then
    log "  ok  Herdr mod bercail-desk"
  fi
  if jq -e --arg s "$HERDR_APP_KEYS_SECTION" '.[$s]["ctrl-shift-a"] == "bercail-desk.agent"' \
    "$HERDR_APP_CONFIG_DIR/keys.json" >/dev/null 2>&1; then
    log "  ok  Herdr keys $HERDR_APP_KEYS_SECTION"
    # The person's choices: reported, not a failure.
    ours="$(_herdr_app_shipped_keys)"
    [[ -z "$src" || ! -f "$src/bercail/keys.json" ]] || ours="$src/bercail/keys.json"
    _herdr_app_keys_conflicts "$HERDR_APP_CONFIG_DIR/keys.json" "$ours" \
      | while IFS= read -r line; do log "  conflict  Herdr $line"; done
  else
    log "  missing  Herdr keys $HERDR_APP_KEYS_SECTION in $HERDR_APP_CONFIG_DIR/keys.json (run: bercail update)"
    missing=$((missing + 1))
  fi
  [[ "$missing" -eq 0 ]]
}

# Did the live follower miss a desk finishing or blocking? Prints what it
# missed and fails. A desk now done or blocked since after the follower
# started, later than the last transition the follower recorded, is one it
# didn't see. A follower without a record runs a bercail older than this check.
doctor_notify_missed() {
  local f started last address ms
  f="$(notify_follower_file)"
  started="$(jq -r '.started_at // empty' "$f" 2>/dev/null)"
  if [[ ! "$started" =~ ^[0-9]+$ ]]; then
    printf 'runs an older bercail'
    return 1
  fi
  last="$(jq -r '.last_transition_at // 0' "$f" 2>/dev/null)"
  [[ "$last" =~ ^[0-9]+$ ]] || last=0
  while IFS= read -r address; do
    [[ -n "$address" ]] || continue
    ms="$("$(notify_hc)" get "$address" --json 2>/dev/null </dev/null \
      | jq -r 'select(.status.state == "done" or .status.state == "blocked") | .status_ms // empty' 2>/dev/null)"
    [[ "$ms" =~ ^[0-9]+$ ]] || continue
    # Slack: the follower records a transition a moment after hc stamps it.
    if (( ms / 1000 > started + 5 && ms / 1000 > last + 60 )); then
      printf 'missed desk %s finishing or blocking' "$address"
      return 1
    fi
  done < <("$(notify_hc)" ls --json --label bercail.role=agent 2>/dev/null </dev/null \
    | jq -r '.terminals[]? | select(.state == "live") | .address' 2>/dev/null)
  return 0
}

# How long after `bercail update` kills the follower doctor calls it restarting
# rather than missing: the desk mod checks every 60s, plus slack to start.
DOCTOR_NOTIFY_RESTART_WINDOW=90

# Webhook sinks: their last delivery, and the follower that sends to them.
doctor_notify() {
  local f name st at last=0 missing=0 missed restarted now
  [[ -n "$(notify_sink_files)" ]] || return 0
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    name="$(notify_sink_name "$f")"
    st="$(_notify_sink_state_file "$name")"
    if [[ -r "$st" ]] && jq -e '.auth_failed == true' "$st" >/dev/null 2>&1; then
      log "  failing  notify sink $name (key rejected; see bercail notify status)"
      missing=$((missing + 1))
    else
      log "  ok  notify sink $name"
    fi
    at="$(jq -r '.last_ok_at // 0 | floor' "$st" 2>/dev/null || true)"
    if [[ "$at" =~ ^[0-9]+$ ]] && (( at > last )); then
      last="$at"
    fi
  done < <(notify_sink_files)
  # A live follower can still be silent; the last post time makes that visible.
  if [[ "$last" -gt 0 ]]; then
    at="$(date -d "@$last" '+%Y-%m-%d %H:%M' 2>/dev/null || date -r "$last" '+%Y-%m-%d %H:%M')"
  else
    at="never"
  fi
  restarted="$(cat "$(notify_restart_file)" 2>/dev/null || true)"
  [[ "$restarted" =~ ^[0-9]+$ ]] || restarted=0
  now="$(_notify_now)"
  if "$(notify_hc)" get bercail-notify --json 2>/dev/null | jq -e '.state == "live"' >/dev/null 2>&1; then
    if missed="$(doctor_notify_missed)"; then
      log "  ok  notify follower (hc terminal bercail-notify; last post $at)"
    else
      log "  deaf  notify follower is live but $missed (restart it: hc kill bercail-notify; the bercail layout starts it again)"
      missing=$((missing + 1))
    fi
  elif (( restarted > 0 && now >= restarted && now - restarted <= DOCTOR_NOTIFY_RESTART_WINDOW )); then
    # bercail update killed it; the desk mod's 60s check starts the new one.
    log "  restarting  notify follower (bercail update restarted it $((now - restarted))s ago; the desk mod starts it within a minute)"
  else
    log "  missing  notify follower (the bercail layout starts it; or: hc run --bg --no-parent --name bercail-notify bercail notify run)"
    missing=$((missing + 1))
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
