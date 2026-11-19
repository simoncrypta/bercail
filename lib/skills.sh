#!/usr/bin/env bash
# shellcheck shell=bash

# Pi does not discover ~/.agents/skills: each skill gets a link in Pi's dir.
PI_SKILLS_DIR="${HOME}/.pi/agent/skills"
# The sha256 of every council SKILL.md bercail shipped before v0.18 removed it
# (git log -- skills/council/SKILL.md). Any other bytes are someone's own copy.
BERCAIL_COUNCIL_SKILL_SHA256=(
  e78b96c78a486158c6cd47f916819363c95af408d69624312d5924d7eddfa1f9
  871aa33841db78ddcc44fa6d0c2be729008fa37c54cc32536f8609312d8c9a9f
  3324536081f78318252427c7b443a27feb42ab15828fdea99a412996cd4ea85f
  7dbf6febe53276956af7beadac3fec2dad8b8416a7deff9535a5278776c21baf
  c883401fa02c7aaeca145a079d334b0cea2d95b04008c6df7769cd62a0295932
  6533b37e41edcca6f8a7bb44f35d3ba83aa9132d2a838b05846898d6147c719c
)

# The skills to deploy and give bstack's agents. statechart only when [bstack]
# statechart = true, which also installs its TLC and Java.
_skill_ids() {
  printf '%s\n' "${BERCAIL_SKILL_IDS[@]}"
  if statechart_enabled; then
    printf 'statechart\n'
  fi
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
  done < <(printf '%s\n' "${BERCAIL_SKILL_IDS[@]}")
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
    if [[ "$skill_id" == statechart ]] && ! _statechart_skill_ours; then
      warn "keeping $(skill_canonical_dir statechart): another statechart skill is there; move it to use bercail's"
      continue
    fi
    deploy_skill_tree "$skill_id"
    ensure_skill_symlink "$PI_SKILLS_DIR" "$skill_id"
  done < <(_skill_ids)
  statechart_enabled || remove_statechart_skill
  remove_council_skill
}

# sha256 of a file, hex. macOS has shasum, not sha256sum.
_skill_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# The council skill an older release installed: the files it shipped, byte for
# byte, and its Pi link. bercail copies skills, so a linked folder or file is
# someone's, and a file someone added keeps the folder.
remove_council_skill() {
  local dest sum
  dest="$(skill_canonical_dir council)"
  [[ ! -L "$dest" && ! -L "$dest/SKILL.md" && -f "$dest/SKILL.md" ]] || return 0
  sum="$(_skill_sha256 "$dest/SKILL.md")" || return 0
  [[ " ${BERCAIL_COUNCIL_SKILL_SHA256[*]} " == *" $sum "* ]] || return 0
  remove_managed_skill_symlink "$PI_SKILLS_DIR" council
  info "remove: $dest/SKILL.md"
  run rm -f "$dest/SKILL.md"
  # The file list older releases' curl install wrote.
  if [[ -f "$dest/MANIFEST" && ! -L "$dest/MANIFEST" ]] && cmp -s "$dest/MANIFEST" <(printf 'SKILL.md\nMANIFEST\n'); then
    run rm -f "$dest/MANIFEST"
  fi
  run rmdir "$dest" 2>/dev/null || warn "kept $dest: it holds files bercail did not install"
}

# No statechart skill yet, or bercail's, found by bstack's wrapper in it.
# Another one in the same place (pstack's own) is never written over or removed.
_statechart_skill_ours() {
  local dest
  dest="$(skill_canonical_dir statechart)"
  [[ ! -e "$dest" || -f "$dest/scripts/statechart-bstack" ]]
}

# bercail's statechart skill and its link.
remove_statechart_skill() {
  local dest
  dest="$(skill_canonical_dir statechart)"
  [[ -e "$dest" ]] && _statechart_skill_ours || return 0
  remove_managed_skill_symlink "$PI_SKILLS_DIR" statechart
  info "remove: $dest"
  run rm -rf "$dest"
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
  done < <(printf '%s\n' "${BERCAIL_SKILL_IDS[@]}")
  remove_statechart_skill
  remove_council_skill
}
