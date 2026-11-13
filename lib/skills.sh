#!/usr/bin/env bash
# shellcheck shell=bash

# Pi does not discover ~/.agents/skills: each skill gets a link in Pi's dir.
PI_SKILLS_DIR="${HOME}/.pi/agent/skills"

_skill_ids() {
  printf '%s\n' "${BERCAIL_SKILL_IDS[@]}"
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
  local skill_id
  while IFS= read -r skill_id; do
    [[ -n "$skill_id" ]] || continue
    remove_managed_skill_symlink "$PI_SKILLS_DIR" "$skill_id"
  done < <(_skill_ids)
}

deploy_skill_tree() {
  local skill_id="$1"
  local dest_root src_root
  dest_root="$(skill_canonical_dir "$skill_id")"
  ensure_dir "$dest_root"

  src_root="$(install_src_dir)/skills/${skill_id}"
  [[ -d "$src_root" ]] || {
    warn "skill source missing: $src_root"
    return 1
  }
  deploy_tree "$src_root" "$dest_root"
  # Older releases shipped a file list for the curl install.
  run rm -f "$dest_root/MANIFEST"
  if [[ -d "$dest_root/scripts" ]]; then
    run find "$dest_root/scripts" -type f -exec chmod +x {} +
  fi
}

deploy_skills() {
  local skill_id
  ensure_dir "$AGENTS_SKILLS_DIR"
  # Folded into the handoff skill; a copy left behind would be read as current.
  run rm -f "$(skill_canonical_dir handoff)/resources/handoff.md" "$(skill_canonical_dir handoff)/resources/keys.md"
  while IFS= read -r skill_id; do
    [[ -n "$skill_id" ]] || continue
    deploy_skill_tree "$skill_id"
    ensure_skill_symlink "$PI_SKILLS_DIR" "$skill_id"
  done < <(_skill_ids)
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
