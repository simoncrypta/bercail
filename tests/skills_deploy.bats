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
  deploy_skills >/dev/null
  [[ -f "$AGENTS_SKILLS_DIR/handoff/SKILL.md" ]] || fail "canonical skill missing"
  grep -q '^name: handoff$' "$AGENTS_SKILLS_DIR/handoff/SKILL.md" || fail "skill frontmatter missing"
  [[ -f "$AGENTS_SKILLS_DIR/handoff/resources/git-workflow.md" ]] || fail "resource git-workflow.md missing"
  [[ -f "$AGENTS_SKILLS_DIR/handoff/MANIFEST" ]] || fail "MANIFEST missing from deploy_tree"
  [[ -x "$AGENTS_SKILLS_DIR/handoff/scripts/handoff-spawn" ]] || fail "handoff-spawn missing or not executable"
  [[ -f "$AGENTS_SKILLS_DIR/review/SKILL.md" ]] || fail "canonical review skill missing"
  grep -q '^name: review$' "$AGENTS_SKILLS_DIR/review/SKILL.md" || fail "review frontmatter missing"
  [[ -f "$AGENTS_SKILLS_DIR/review/scripts/wait-comments.sh" ]] || fail "wait-comments helper missing"
  [[ -x "$AGENTS_SKILLS_DIR/review/scripts/publish-github.sh" ]] || fail "publish-github helper missing or not executable"
  [[ -f "$AGENTS_SKILLS_DIR/review/scripts/is-agent.jq" ]] || fail "the jq both review scripts include is missing"
  grep -qx 'scripts/is-agent.jq' "$ROOT/skills/review/MANIFEST" || fail "a curl install would not fetch is-agent.jq"
  [[ -L "$HOME/.pi/agent/skills/handoff" ]] || fail "pi skill symlink missing"
  [[ -L "$HOME/.pi/agent/skills/review" ]] || fail "pi review symlink missing"
  [[ -L "$HOME/.pi/agent/skills/bstack" && -L "$HOME/.pi/agent/skills/council" ]] \
    || fail "pi links for bstack and council missing"
  grep -q '^name: unit-testing$' "$AGENTS_SKILLS_DIR/unit-testing/SKILL.md" || fail "canonical unit-testing skill missing"
  [[ -L "$HOME/.pi/agent/skills/unit-testing" ]] || fail "pi link for unit-testing missing"
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
