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
  export AGENTIC_DEV_CONFIG_DIR="$XDG_CONFIG_HOME/agentic-dev"
  export AGENTIC_DEV_USER_CONFIG="$AGENTIC_DEV_CONFIG_DIR/config.toml"
  export AGENTS_SKILLS_DIR="$HOME/.agents/skills"
  export AGENTIC_DEV_SKILL_ID="handoff"
  export AGENTIC_DEV_SKILL_DIR="$AGENTS_SKILLS_DIR/handoff"
  YES=1
  DRY_RUN=0
}

@test "deploy_skills installs canonical skills and links them for pi" {
  rm -rf "$HOME/.agents" "$HOME/.pi"
  deploy_skills >/dev/null
  [[ -f "$AGENTIC_DEV_SKILL_DIR/SKILL.md" ]] || fail "canonical skill missing"
  grep -q '^name: handoff$' "$AGENTIC_DEV_SKILL_DIR/SKILL.md" || fail "skill frontmatter missing"
  [[ -f "$AGENTIC_DEV_SKILL_DIR/resources/handoff.md" ]] || fail "resource handoff.md missing"
  [[ -f "$AGENTIC_DEV_SKILL_DIR/MANIFEST" ]] || fail "MANIFEST missing from deploy_tree"
  [[ -x "$AGENTIC_DEV_SKILL_DIR/scripts/handoff-spawn" ]] || fail "handoff-spawn missing or not executable"
  [[ -f "$AGENTS_SKILLS_DIR/review/SKILL.md" ]] || fail "canonical review skill missing"
  grep -q '^name: review$' "$AGENTS_SKILLS_DIR/review/SKILL.md" || fail "review frontmatter missing"
  [[ -f "$AGENTS_SKILLS_DIR/review/scripts/wait-comments.sh" ]] || fail "wait-comments helper missing"
  [[ -x "$AGENTS_SKILLS_DIR/review/scripts/publish-github.sh" ]] || fail "publish-github helper missing or not executable"
  [[ -L "$HOME/.pi/agent/skills/handoff" ]] || fail "pi skill symlink missing"
  [[ -L "$HOME/.pi/agent/skills/review" ]] || fail "pi review symlink missing"
  [[ -L "$HOME/.pi/agent/skills/bstack" && -L "$HOME/.pi/agent/skills/council" ]] \
    || fail "pi links for bstack and council missing"
  grep -q '^name: unit-testing$' "$AGENTS_SKILLS_DIR/unit-testing/SKILL.md" || fail "canonical unit-testing skill missing"
  [[ -L "$HOME/.pi/agent/skills/unit-testing" ]] || fail "pi link for unit-testing missing"
}

@test "the unit-testing skill links its source" {
  grep -qF 'https://github.com/tekguard/Principles-of-Unit-Testing' "$ROOT/skills/unit-testing/SKILL.md" \
    || fail "unit-testing skill must link F.I.R.S.T.'s source"
}

@test "deploy_skills preserves a foreign path in the pi skills dir" {
  local output
  rm -rf "$HOME/.agents" "$HOME/.pi"
  mkdir -p "$HOME/.pi/agent/skills/handoff"
  printf 'foreign\n' >"$HOME/.pi/agent/skills/handoff/SKILL.md"
  output="$(deploy_skills 2>&1)"
  printf '%s\n' "$output" | grep -q 'preserving pre-existing skill path' \
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
  [[ ! -d "$AGENTIC_DEV_SKILL_DIR" ]] || fail "canonical skill should be removed"
}

@test "review skill waits for user notes and publishes only on request" {
  grep -q 'wait-comments.sh' "$ROOT/skills/review/SKILL.md" \
    || fail "review skill must wait for human tuicr comments"
  grep -q 'publish-github.sh' "$ROOT/skills/review/SKILL.md" \
    || fail "review skill must publish user comments via publish-github.sh"
  grep -q 'tuicr review list' "$ROOT/skills/review/SKILL.md" \
    || fail "review skill must discover the live tuicr session"
  grep -q 'publish-github.sh' "$ROOT/skills/review/MANIFEST" \
    || fail "MANIFEST must list publish-github.sh"
}

@test "handoff skill recipe is the spawn script" {
  grep -q 'scripts/handoff-spawn' "$ROOT/skills/handoff/SKILL.md" \
    || fail "SKILL.md must tell the parent to run handoff-spawn"
  grep -q 'handoff-spawn" --info' "$ROOT/skills/handoff/SKILL.md" \
    || fail "SKILL.md must tell the parent to run --info"
  grep -q 'Do not inspect git, Graphite, the Herdr app, or worktrees yourself' "$ROOT/skills/handoff/SKILL.md" \
    || fail "SKILL.md must not keep the glued multi-tool recipe"
  grep -q -- '--workspace' "$ROOT/skills/handoff/SKILL.md" \
    || fail "SKILL.md must cover socket-attached parents"
  grep -q -- '--issue <id>' "$ROOT/skills/handoff/SKILL.md" \
    || fail "SKILL.md must spawn with --issue so only the beads id reaches argv"
  if grep -q -- '--take-pending\|pending_prompt\|handoff-brief' "$ROOT/skills/handoff/SKILL.md"; then
    fail "SKILL.md must not keep the prompt-file flow"
  fi
  grep -q "Never put the user's ask on the spawn command line" "$ROOT/skills/handoff/SKILL.md" \
    || fail "SKILL.md must forbid prompt-on-argv"
  grep -q 'handoff-spawn' "$ROOT/skills/handoff/MANIFEST" \
    || fail "MANIFEST must list handoff-spawn"
  grep -q 'scripts/git-backend.sh' "$ROOT/skills/handoff/MANIFEST" \
    || fail "MANIFEST must list git-backend.sh"
  if grep -qi 'poteto\|pstack' "$ROOT/skills/handoff/SKILL.md"; then
    fail "SKILL.md must not keep a poteto or pstack mode"
  fi
}

@test "deploy_lib copies git-backend.sh next to the other libs" {
  deploy_lib >/dev/null
  cmp -s "$ROOT/skills/handoff/scripts/git-backend.sh" "$AGENTIC_DEV_SHARE_DIR/lib/git-backend.sh" \
    || fail "installed lib/git-backend.sh must match the skill script"
  cmp -s "$ROOT/skills/handoff/scripts/git-backend.sh" "$ROOT/lib/git-backend.sh" \
    || fail "repo lib/git-backend.sh must be the skill script"
}
