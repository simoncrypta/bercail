#!/usr/bin/env bash
# shellcheck shell=bash

# Pi does not discover ~/.agents/skills: each skill gets a link in Pi's dir.
PI_SKILLS_DIR="${HOME}/.pi/agent/skills"
# Every file of a retired skill bercail shipped, as "<skill>/<path> <sha256>"
# (git log -- skills/<skill>). Any other bytes are someone's own copy.
BERCAIL_RETIRED_SKILL_FILES=(
  "council/SKILL.md e78b96c78a486158c6cd47f916819363c95af408d69624312d5924d7eddfa1f9"
  "council/SKILL.md 871aa33841db78ddcc44fa6d0c2be729008fa37c54cc32536f8609312d8c9a9f"
  "council/SKILL.md 3324536081f78318252427c7b443a27feb42ab15828fdea99a412996cd4ea85f"
  "council/SKILL.md 7dbf6febe53276956af7beadac3fec2dad8b8416a7deff9535a5278776c21baf"
  "council/SKILL.md c883401fa02c7aaeca145a079d334b0cea2d95b04008c6df7769cd62a0295932"
  "council/SKILL.md 6533b37e41edcca6f8a7bb44f35d3ba83aa9132d2a838b05846898d6147c719c"
  "council/MANIFEST acdcb3c48ccf4ce67b0a88f86261ab8a4f28ca34ab7d342f272391975ca8fb7f"
  "review/SKILL.md 03547f0c4fc0a74dd6aefbff56842278f57f0e1ec04ce1b961e80d833f834ae7"
  "review/SKILL.md 217a4e34bbfa61adb8b2a1461e4502fe9a703130b8a03e604be29d79837fdbc0"
  "review/SKILL.md 24e17471ad35fe92fe0b7d30070c471640f4b7fae3d3cfececb9f09212f69a92"
  "review/SKILL.md 472c5da804f9d95b03302911fc683d393980f2767cc726c43799c1ac17b15c25"
  "review/SKILL.md 6153b011dd71d8b174d190542c4163bd9d70e758a19b1a7fb29566d59096f11a"
  "review/MANIFEST caac8452c0cc084797f7fcc414bb0fe1a8a09615f9fcc961b5519c128840f418"
  "review/MANIFEST d749414bf512319d46e711c1e60a4fa266d6cba698a4436a4d7deead67d756a3"
  "review/MANIFEST eb9d3f60331c201c0fed957321e0d364984d0a7e10f0b15ac4bc48f67947a737"
  "review/scripts/wait-comments.sh 0cddbb570fe549886526b2db88954fb519372e42cdc0c9af8ad179ccad3bace1"
  "review/scripts/wait-comments.sh 88fcd2a6c47a9fbaa4fac421d940ca3a75e47691eef96f86ef88ddbccd5edb8b"
  "review/scripts/wait-comments.sh 98f73b9707b30e92546b2e3d48fbc8a7ebd7b4a2dd4d4472da4730b2a5d6c57f"
  "review/scripts/wait-comments.sh d0a4d2a5e7e6a3fafbb39aee392830bf65995838d7c03154a99ac37c8a099102"
  "review/scripts/publish-github.sh 39f7e73bd80c4d5ccb840c7a8ad0407356c4350cb87e3166e72a0ee5475778fe"
  "review/scripts/publish-github.sh 5406c0d8ef63119a1879badb3b891459cb70ece6abc9d81051eaffb461f189ae"
  "review/scripts/publish-github.sh 6427619da42e7fa944a3ce36590b305a193e14daf9e012a225fc1220276abeca"
  "review/scripts/publish-github.sh 6c0a86750dfc4d3ed68ecb90a3c59157ce6c18d2e65fbed0ef01ab281a081e25"
  "review/scripts/is-agent.jq 3b3fa5730d1785dc8e21cc41894d94db962a23f4f057199d239e86f3d54c08b9"
)

# The skills to deploy and give bstack's agents. statechart only when [bstack]
# statechart = true, which also installs its tla-ts.
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
  remove_retired_skills
}

# sha256 of a file, hex. macOS has shasum, not sha256sum.
_skill_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# A skill an older release installed and this one no longer ships: the files it
# shipped, byte for byte, and its Pi link. Its SKILL.md must be one bercail
# shipped. bercail copies skills, so a linked folder or file is someone's, and a
# file someone added or edited keeps the folder.
remove_retired_skill() {
  local id="$1" dest entry path file seen=" " dir dirs=" "
  dest="$(skill_canonical_dir "$id")"
  [[ ! -L "$dest" && ! -L "$dest/SKILL.md" && -f "$dest/SKILL.md" ]] || return 0
  _retired_skill_file_shipped "$id" SKILL.md || return 0
  remove_managed_skill_symlink "$PI_SKILLS_DIR" "$id"
  # Each path once: the list holds a line per shipped version.
  for entry in "${BERCAIL_RETIRED_SKILL_FILES[@]}"; do
    [[ "$entry" == "$id/"* ]] || continue
    path="${entry%% *}" && path="${path#"$id/"}"
    [[ "$seen" != *" $path "* ]] || continue
    seen+="$path "
    [[ "$path" != */* || "$dirs" == *" ${path%/*} "* ]] || dirs+="${path%/*} "
    file="$dest/$path"
    [[ -f "$file" && ! -L "$file" && ! -L "${file%/*}" ]] || continue
    _retired_skill_file_shipped "$id" "$path" || continue
    info "remove: $file"
    run rm -f "$file"
  done
  for dir in $dirs; do
    [[ ! -d "$dest/$dir" || -L "$dest/$dir" ]] || run rmdir "$dest/$dir" 2>/dev/null || true
  done
  run rmdir "$dest" 2>/dev/null || warn "kept $dest: it holds files bercail did not install"
}

# Whether skill ID's PATH, as installed, is a file bercail shipped.
_retired_skill_file_shipped() {
  local entry sum
  sum="$(_skill_sha256 "$(skill_canonical_dir "$1")/$2")" || return 1
  for entry in "${BERCAIL_RETIRED_SKILL_FILES[@]}"; do
    [[ "$entry" != "$1/$2 $sum" ]] || return 0
  done
  return 1
}

# The skills v0.18 removed.
remove_retired_skills() {
  remove_retired_skill council
  remove_retired_skill review
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
  remove_retired_skills
}
