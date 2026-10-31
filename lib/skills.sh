#!/usr/bin/env bash
# shellcheck shell=bash

# Agent-specific skill dirs (scrubbed on reconfigure/uninstall).
skill_extra_global_dirs_all() {
  printf '%s\n' \
    "${HOME}/.codex/skills" \
    "${HOME}/.config/opencode/skills" \
    "${HOME}/.claude/skills" \
    "${HOME}/.pi/agent/skills" \
    "${HOME}/.grok/skills"
}

# Extra link only when the agent does not discover ~/.agents/skills.
# Grok scans ~/.grok/skills (and ~/.claude/skills), not ~/.agents/skills.
# opencode v2 reads ~/.agents/skills itself; old links in its dir are scrubbed.
skill_agent_extra_global_dirs() {
  local cmd="${1:-}"
  case "$cmd" in
    agent|cursor|cursor-agent|opencode) return 1 ;;
    grok) printf '%s' "${HOME}/.grok/skills" ;;
    pi) printf '%s' "${HOME}/.pi/agent/skills" ;;
    codex) printf '%s' "${HOME}/.codex/skills" ;;
    claude|claude-code) printf '%s' "${HOME}/.claude/skills" ;;
    *) return 1 ;;
  esac
}

_skill_ids() {
  if ((${#AGENTIC_DEV_SKILL_IDS[@]})); then
    printf '%s\n' "${AGENTIC_DEV_SKILL_IDS[@]}"
    return 0
  fi
  printf '%s\n' "${AGENTIC_DEV_SKILL_ID:-handoff}"
}

_skill_link_is_ours() {
  local link="$1" skill_id="$2"
  [[ -L "$link" ]] || return 1
  local resolved canonical
  resolved="$(realpath "$link" 2>/dev/null || true)"
  canonical="$(realpath "$(skill_canonical_dir "$skill_id")" 2>/dev/null || true)"
  [[ -n "$resolved" && -n "$canonical" && "$resolved" == "$canonical" ]]
}

ensure_skill_symlink() {
  local dest_parent="$1" skill_id="$2"
  local dest link
  dest="$(skill_canonical_dir "$skill_id")"
  link="${dest_parent}/${skill_id}"

  [[ "$dest_parent" == "$AGENTS_SKILLS_DIR" ]] && return 0
  ensure_dir "$dest_parent"

  if [[ -L "$link" ]]; then
    if _skill_link_is_ours "$link" "$skill_id"; then
      info "unchanged: skill link $link"
      return 0
    fi
    warn "preserving pre-existing skill link $link -> $(readlink "$link")"
    return 0
  fi
  if [[ -e "$link" ]]; then
    warn "preserving pre-existing skill path $link (not a symlink to $dest)"
    return 0
  fi

  info "link skill: $link -> $dest"
  run ln -s "$dest" "$link"
}

remove_managed_skill_symlink() {
  local dest_parent="$1" skill_id="$2"
  local link="${dest_parent}/${skill_id}"
  [[ -L "$link" ]] || return 0
  _skill_link_is_ours "$link" "$skill_id" || return 0
  info "remove: $link"
  run rm -f "$link"
}

scrub_managed_skill_extra_links() {
  local dir skill_id
  while IFS= read -r dir; do
    [[ -n "$dir" ]] || continue
    while IFS= read -r skill_id; do
      [[ -n "$skill_id" ]] || continue
      remove_managed_skill_symlink "$dir" "$skill_id"
    done < <(_skill_ids)
  done < <(skill_extra_global_dirs_all)
}

deploy_skill_tree() {
  local skill_id="$1"
  local src dest_root src_root manifest line
  dest_root="$(skill_canonical_dir "$skill_id")"
  ensure_dir "$dest_root"

  src="$(install_src_dir)"
  if [[ -d "$src" ]]; then
    src_root="$src/skills/${skill_id}"
    [[ -d "$src_root" ]] || {
      warn "skill source missing: $src_root"
      return 1
    }
    deploy_tree "$src_root" "$dest_root"
    if [[ -d "$dest_root/scripts" ]]; then
      run find "$dest_root/scripts" -type f -exec chmod +x {} +
    fi
    return 0
  fi

  deploy_install_file "skills/${skill_id}/MANIFEST" "${dest_root}/MANIFEST"
  [[ -f "${dest_root}/MANIFEST" ]] || {
    warn "skill MANIFEST missing after fetch"
    return 1
  }
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" && "$line" != \#* ]] || continue
    deploy_install_file "skills/${skill_id}/$line" "${dest_root}/$line"
  done <"${dest_root}/MANIFEST"
  if [[ -d "$dest_root/scripts" ]]; then
    run find "$dest_root/scripts" -type f -exec chmod +x {} +
  fi
}

deploy_skills() {
  local agent_cmd agent_skills_dir skill_id
  ensure_dir "$AGENTS_SKILLS_DIR"
  while IFS= read -r skill_id; do
    [[ -n "$skill_id" ]] || continue
    deploy_skill_tree "$skill_id"
  done < <(_skill_ids)
  scrub_managed_skill_extra_links

  agent_cmd="$(read_agent_command 2>/dev/null || printf '%s' "cursor-agent")"
  if agent_skills_dir="$(skill_agent_extra_global_dirs "$agent_cmd")"; then
    while IFS= read -r skill_id; do
      [[ -n "$skill_id" ]] || continue
      ensure_skill_symlink "$agent_skills_dir" "$skill_id"
    done < <(_skill_ids)
  else
    info "skills at $AGENTS_SKILLS_DIR (no extra link for '$agent_cmd')"
  fi
}

remove_managed_handoff_skill() {
  remove_managed_skills
}

remove_managed_skills() {
  local skill_id dest
  scrub_managed_skill_extra_links
  while IFS= read -r skill_id; do
    [[ -n "$skill_id" ]] || continue
    dest="$(skill_canonical_dir "$skill_id")"
    if [[ -d "$dest" ]]; then
      info "remove: $dest"
      run rm -rf "$dest"
    fi
  done < <(_skill_ids)
}
