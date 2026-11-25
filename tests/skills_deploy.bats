#!/usr/bin/env bats
# deploy_skills, the skill recipes, and deploy_lib. Each @test is its own HOME.

# shellcheck disable=SC2034 # YES, DRY_RUN and friends are read by the sourced libs.

setup() {
  load test_helper
  isolate
  mkdir -p "$XDG_CONFIG_HOME"
  # shellcheck disable=SC1091
  source "$ROOT/lib/common.sh"
  # shellcheck disable=SC1091
  source "$ROOT/lib/config.sh"
  # shellcheck disable=SC1091
  source "$ROOT/lib/skills.sh"

  export INSTALL_SRC="$ROOT"
  export BERCAIL_CONFIG_DIR="$XDG_CONFIG_HOME/bercail"
  export BERCAIL_USER_CONFIG="$BERCAIL_CONFIG_DIR/config.toml"
  export AGENTS_SKILLS_DIR="$HOME/.agents/skills"
  YES=1
  DRY_RUN=0
}

@test "deploy_skills installs canonical skills and links them for pi" {
  rm -rf "$HOME/.agents" "$HOME/.pi"
  # The file list an older release's curl install left in each skill.
  mkdir -p "$AGENTS_SKILLS_DIR/handoff"
  : >"$AGENTS_SKILLS_DIR/handoff/MANIFEST"
  deploy_skills >/dev/null
  local id
  for id in "${BERCAIL_SKILL_IDS[@]}"; do
    diff -r "$ROOT/skills/$id" "$AGENTS_SKILLS_DIR/$id" || fail "skill $id is not its source"
    [[ -L "$HOME/.pi/agent/skills/$id" ]] || fail "pi link for $id missing"
  done
  [[ -z "$(find "$AGENTS_SKILLS_DIR" -path '*/scripts/*' -type f ! -perm -u+x)" ]] || fail "a skill script is not executable"
  [[ ! -e "$AGENTS_SKILLS_DIR/handoff/MANIFEST" ]] || fail "an older release's MANIFEST stays"
}

@test "deploy_skills removes the handoff resources an older release installed" {
  mkdir -p "$AGENTS_SKILLS_DIR/handoff/resources"
  printf 'old\n' >"$AGENTS_SKILLS_DIR/handoff/resources/handoff.md"
  printf 'old\n' >"$AGENTS_SKILLS_DIR/handoff/resources/keys.md"
  printf 'mine\n' >"$AGENTS_SKILLS_DIR/handoff/resources/notes.md"
  deploy_skills >/dev/null
  [[ ! -e "$AGENTS_SKILLS_DIR/handoff/resources/handoff.md" && ! -e "$AGENTS_SKILLS_DIR/handoff/resources/keys.md" ]] \
    || fail "the folded resources are still installed"
  [[ -f "$AGENTS_SKILLS_DIR/handoff/resources/notes.md" ]] || fail "a file bercail does not own was removed"
  local link
  while IFS= read -r link; do
    [[ -e "$AGENTS_SKILLS_DIR/handoff/$link" ]] || fail "the skill links a file that is not installed: $link"
  done < <(grep -oE 'resources/[a-z-]+\.md' "$AGENTS_SKILLS_DIR/handoff/SKILL.md" | sort -u)
}

# A council skill as an older release installed it, with its Pi link; its
# SKILL.md counts as shipped (the digest is of the text below).
old_council_skill() {
  mkdir -p "$AGENTS_SKILLS_DIR/council" "$HOME/.pi/agent/skills"
  printf -- '---\nname: council\n---\n\nLaunch every `bstack-council-*` subagent.\n' >"$AGENTS_SKILLS_DIR/council/SKILL.md"
  printf 'SKILL.md\nMANIFEST\n' >"$AGENTS_SKILLS_DIR/council/MANIFEST"
  ln -s "$AGENTS_SKILLS_DIR/council" "$HOME/.pi/agent/skills/council"
  BERCAIL_RETIRED_SKILL_FILES=(
    "council/SKILL.md e96b7755055330174617ea71f5b56f9410f0ad3c4abd73de8ed18e86704c1ba3"
    "council/MANIFEST acdcb3c48ccf4ce67b0a88f86261ab8a4f28ca34ab7d342f272391975ca8fb7f"
  )
}

@test "deploy_skills removes the council skill an older release installed, and its pi link" {
  old_council_skill
  deploy_skills >/dev/null
  [[ ! -e "$AGENTS_SKILLS_DIR/council" ]] || fail "an update keeps the retired council skill"
  [[ ! -L "$HOME/.pi/agent/skills/council" ]] || fail "an update keeps the council skill's pi link"
}

@test "deploy_skills keeps the files someone added to the old council skill, their own MANIFEST too" {
  old_council_skill
  printf 'mine\n' >"$AGENTS_SKILLS_DIR/council/my-notes.md"
  printf 'my manifest\n' >"$AGENTS_SKILLS_DIR/council/MANIFEST"
  deploy_skills >/dev/null 2>&1
  [[ ! -e "$AGENTS_SKILLS_DIR/council/SKILL.md" ]] || fail "an update keeps the retired SKILL.md"
  grep -qx mine "$AGENTS_SKILLS_DIR/council/my-notes.md" || fail "an update removed a file bercail did not install"
  grep -qx 'my manifest' "$AGENTS_SKILLS_DIR/council/MANIFEST" || fail "an update removed a MANIFEST bercail did not ship"
}

@test "deploy_skills keeps a council skill folder that is a link, and the files behind it" {
  old_council_skill
  mv "$AGENTS_SKILLS_DIR/council" "$BATS_TEST_TMPDIR/my-council"
  ln -s "$BATS_TEST_TMPDIR/my-council" "$AGENTS_SKILLS_DIR/council"
  deploy_skills >/dev/null
  [[ -f "$BATS_TEST_TMPDIR/my-council/SKILL.md" && -f "$BATS_TEST_TMPDIR/my-council/MANIFEST" ]] \
    || fail "an update removed files through a linked skill folder"
  [[ -L "$HOME/.pi/agent/skills/council" ]] || fail "an update removed the pi link to a linked skill folder"
}

@test "deploy_skills keeps a council skill that is not bercail's, even one that names a seat" {
  old_council_skill
  printf -- '---\nname: council\n---\n\nNot the bstack-council-gpt seat.\n' >"$AGENTS_SKILLS_DIR/council/SKILL.md"
  deploy_skills >/dev/null
  grep -q 'Not the bstack-council-gpt seat' "$AGENTS_SKILLS_DIR/council/SKILL.md" \
    || fail "an update removed someone else's council skill"
  [[ -L "$HOME/.pi/agent/skills/council" ]] || fail "an update removed the link to someone else's council skill"
}

@test "uninstall removes the council skill an older release installed" {
  old_council_skill
  remove_managed_skills >/dev/null
  [[ ! -e "$AGENTS_SKILLS_DIR/council" && ! -L "$HOME/.pi/agent/skills/council" ]] \
    || fail "uninstall keeps the retired council skill"
}

# The review skill as RELEASE installed it, with its Pi link.
old_review_skill() {
  need_tag "${1:-v0.17.4}"
  mkdir -p "$AGENTS_SKILLS_DIR/review" "$HOME/.pi/agent/skills"
  git -C "$ROOT" archive "${1:-v0.17.4}" skills/review | tar -x --strip-components=2 -C "$AGENTS_SKILLS_DIR/review"
  ln -s "$AGENTS_SKILLS_DIR/review" "$HOME/.pi/agent/skills/review"
}

need_tag() {
  git -C "$ROOT" rev-parse -q --verify "refs/tags/$1" >/dev/null \
    || fail "release tag $1 is missing: git -C $ROOT fetch --tags"
}

# The releases that shipped the review skill, oldest tag name first.
review_releases() {
  local tag
  git -C "$ROOT" tag -l 'v*' | while IFS= read -r tag; do
    git -C "$ROOT" cat-file -e "$tag:skills/review/SKILL.md" 2>/dev/null && printf '%s\n' "$tag"
  done
}

# Every fourth of them from the Kth: four tests, so their deploys run side by side.
removes_review_skills() {
  local k="$1" tag n=0
  need_tag v0.17.4
  while IFS= read -r tag; do
    old_review_skill "$tag"
    deploy_skills >/dev/null
    [[ ! -e "$AGENTS_SKILLS_DIR/review" ]] || fail "an update keeps $tag's review skill: $(find "$AGENTS_SKILLS_DIR/review")"
    [[ ! -L "$HOME/.pi/agent/skills/review" ]] || fail "an update keeps the pi link to $tag's review skill"
    n=$((n + 1))
  done < <(review_releases | awk -v k="$k" 'NR % 4 == k')
  ((n > 0)) || fail "no release in this fourth shipped the review skill"
}

@test "over 30 releases shipped the review skill that deploy_skills removes" {
  local n
  need_tag v0.17.4
  n="$(review_releases | wc -l)"
  ((n > 30)) || fail "only $n releases shipped the review skill"
}

@test "deploy_skills removes the review skill the 1st, 5th, ... release installed, and its pi link" {
  removes_review_skills 1
}

@test "deploy_skills removes the review skill the 2nd, 6th, ... release installed, and its pi link" {
  removes_review_skills 2
}

@test "deploy_skills removes the review skill the 3rd, 7th, ... release installed, and its pi link" {
  removes_review_skills 3
}

@test "deploy_skills removes the review skill the 4th, 8th, ... release installed, and its pi link" {
  removes_review_skills 0
}

@test "deploy_skills keeps a review script someone edited and a file they added, and removes the rest" {
  old_review_skill
  printf '# mine\n' >>"$AGENTS_SKILLS_DIR/review/scripts/publish-github.sh"
  printf 'mine\n' >"$AGENTS_SKILLS_DIR/review/notes.md"
  deploy_skills >/dev/null 2>&1
  [[ ! -e "$AGENTS_SKILLS_DIR/review/SKILL.md" && ! -e "$AGENTS_SKILLS_DIR/review/scripts/wait-comments.sh" ]] \
    || fail "an update keeps the review files bercail shipped"
  grep -qx '# mine' "$AGENTS_SKILLS_DIR/review/scripts/publish-github.sh" || fail "an update removed an edited script"
  grep -qx mine "$AGENTS_SKILLS_DIR/review/notes.md" || fail "an update removed a file bercail did not install"
}

@test "deploy_skills keeps a review skill whose scripts folder is a link, and the files behind it" {
  old_review_skill
  mv "$AGENTS_SKILLS_DIR/review/scripts" "$BATS_TEST_TMPDIR/my-scripts"
  ln -s "$BATS_TEST_TMPDIR/my-scripts" "$AGENTS_SKILLS_DIR/review/scripts"
  deploy_skills >/dev/null 2>&1
  [[ -f "$BATS_TEST_TMPDIR/my-scripts/wait-comments.sh" && -f "$BATS_TEST_TMPDIR/my-scripts/publish-github.sh" ]] \
    || fail "an update removed files through a linked scripts folder"
  [[ -L "$AGENTS_SKILLS_DIR/review/scripts" ]] || fail "an update removed the linked scripts folder"
}

@test "a dry run names each review file it would remove once, and removes none" {
  local out
  old_review_skill
  out="$(DRY_RUN=1 deploy_skills 2>&1)"
  [[ "$(grep -c "remove: $AGENTS_SKILLS_DIR/review/SKILL.md$" <<<"$out")" == 1 ]] || fail "SKILL.md named more than once: $out"
  [[ -f "$AGENTS_SKILLS_DIR/review/SKILL.md" && -L "$HOME/.pi/agent/skills/review" ]] || fail "a dry run removed the skill"
}

@test "deploy_skills keeps a folder of the old council skill that bercail never shipped there" {
  old_council_skill
  mkdir "$AGENTS_SKILLS_DIR/council/scripts"
  deploy_skills >/dev/null 2>&1
  [[ -d "$AGENTS_SKILLS_DIR/council/scripts" ]] || fail "an update removed a council/scripts folder bercail never shipped"
}

@test "uninstall removes the review skill an older release installed" {
  old_review_skill
  remove_managed_skills >/dev/null
  [[ ! -e "$AGENTS_SKILLS_DIR/review" && ! -L "$HOME/.pi/agent/skills/review" ]] \
    || fail "uninstall keeps the retired review skill"
}

@test "deploy_skills preserves a foreign path in the pi skills dir" {
  local output
  rm -rf "$HOME/.agents" "$HOME/.pi"
  mkdir -p "$HOME/.pi/agent/skills/handoff"
  printf 'foreign\n' >"$HOME/.pi/agent/skills/handoff/SKILL.md"
  output="$(deploy_skills 2>&1)"
  grep -q 'preserving pre-existing skill path' <<<"$output" \
    || fail "expected preserve warning for foreign skill dir: $output"
  grep -qx 'foreign' "$HOME/.pi/agent/skills/handoff/SKILL.md" \
    || fail "foreign skill contents changed"
}

@test "uninstall scrubs the pi skill links" {
  rm -rf "$HOME/.agents" "$HOME/.pi"
  deploy_skills >/dev/null
  [[ -L "$HOME/.pi/agent/skills/handoff" ]] || fail "pi link missing before scrub"
  remove_managed_skills >/dev/null
  [[ ! -e "$HOME/.pi/agent/skills/handoff" ]] || fail "pi link should be scrubbed on uninstall"
  [[ ! -d "$AGENTS_SKILLS_DIR/handoff" ]] || fail "canonical skill should be removed"
}

@test "deploy_lib copies git-backend.sh next to the other libs" {
  deploy_lib >/dev/null
  cmp -s "$ROOT/skills/handoff/scripts/git-backend.sh" "$BERCAIL_SHARE_DIR/lib/git-backend.sh" \
    || fail "installed lib/git-backend.sh must match the skill script"
  cmp -s "$ROOT/skills/handoff/scripts/git-backend.sh" "$ROOT/lib/git-backend.sh" \
    || fail "repo lib/git-backend.sh must be the skill script"
}

@test "deploy_lib copies pi-log.sh next to the other libs" {
  deploy_lib >/dev/null
  cmp -s "$ROOT/skills/handoff/scripts/pi-log.sh" "$BERCAIL_SHARE_DIR/lib/pi-log.sh" \
    || fail "installed lib/pi-log.sh must match the skill script"
  cmp -s "$ROOT/skills/handoff/scripts/pi-log.sh" "$ROOT/lib/pi-log.sh" \
    || fail "repo lib/pi-log.sh must be the skill script"
  [[ ! -L "$BERCAIL_SHARE_DIR/lib/pi-log.sh" ]] || fail "installed pi-log.sh must be a file, not a skills-tree symlink"
}

@test "deploy_lib copies toml.sh next to the other libs" {
  deploy_lib >/dev/null
  cmp -s "$ROOT/skills/handoff/scripts/toml.sh" "$BERCAIL_SHARE_DIR/lib/toml.sh" \
    || fail "installed lib/toml.sh must match the skill script"
  cmp -s "$ROOT/skills/handoff/scripts/toml.sh" "$ROOT/lib/toml.sh" \
    || fail "repo lib/toml.sh must be the skill script"
  [[ ! -L "$BERCAIL_SHARE_DIR/lib/toml.sh" ]] || fail "installed toml.sh must be a file, not a skills-tree symlink"
}
