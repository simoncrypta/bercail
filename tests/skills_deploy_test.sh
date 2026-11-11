#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

unset BASH_ENV
export __MISE_BASH_ENV_LOADED=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() {
  local expected="$1" actual="$2" msg="${3:-}"
  [[ "$expected" == "$actual" ]] || fail "${msg}: expected '$expected' got '$actual'"
}

export HOME="$TMP_DIR/home"
export XDG_CONFIG_HOME="$HOME/.config"
mkdir -p "$HOME" "$XDG_CONFIG_HOME"

# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=lib/config.sh
source "$ROOT/lib/config.sh"
# shellcheck source=lib/skills.sh
source "$ROOT/lib/skills.sh"

export INSTALL_SRC="$ROOT"
export AGENTIC_DEV_CONFIG_DIR="$XDG_CONFIG_HOME/agentic-dev"
export AGENTIC_DEV_USER_CONFIG="$AGENTIC_DEV_CONFIG_DIR/config.toml"
export AGENTS_SKILLS_DIR="$HOME/.agents/skills"
export AGENTIC_DEV_SKILL_ID="handoff"
export AGENTIC_DEV_SKILL_DIR="$AGENTS_SKILLS_DIR/handoff"
YES=1
DRY_RUN=0

test_deploy_installs_canonical_skills_and_pi_links() {
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
  printf 'PASS: deploy_skills installs canonical skills and links them for pi\n'
}

test_unit_testing_skill_credits_its_source() {
  grep -qF 'https://github.com/tekguard/Principles-of-Unit-Testing' "$ROOT/skills/unit-testing/SKILL.md" \
    || fail "unit-testing skill must link F.I.R.S.T.'s source"
  printf 'PASS: the unit-testing skill links its source\n'
}

test_pi_link_preserves_a_foreign_path() {
  rm -rf "$HOME/.agents" "$HOME/.pi"
  mkdir -p "$HOME/.pi/agent/skills/handoff"
  printf 'foreign\n' >"$HOME/.pi/agent/skills/handoff/SKILL.md"
  local output
  output="$(deploy_skills 2>&1)"
  printf '%s\n' "$output" | grep -q 'preserving pre-existing skill path' \
    || fail "expected preserve warning for foreign skill dir: $output"
  grep -qx 'foreign' "$HOME/.pi/agent/skills/handoff/SKILL.md" \
    || fail "foreign skill contents changed"
  printf 'PASS: deploy_skills preserves a foreign path in the pi skills dir\n'
}

test_uninstall_scrubs_pi_links() {
  rm -rf "$HOME/.agents" "$HOME/.pi"
  deploy_skills >/dev/null
  [[ -L "$HOME/.pi/agent/skills/handoff" ]] || fail "pi link missing before scrub"
  remove_managed_skills >/dev/null
  [[ ! -e "$HOME/.pi/agent/skills/handoff" ]] || fail "pi link should be scrubbed on uninstall"
  [[ ! -d "$AGENTIC_DEV_SKILL_DIR" ]] || fail "canonical skill should be removed"
  printf 'PASS: uninstall scrubs the pi skill links\n'
}

test_review_skill_recipe() {
  grep -q 'wait-comments.sh' "$ROOT/skills/review/SKILL.md" \
    || fail "review skill must wait for human tuicr comments"
  grep -q 'publish-github.sh' "$ROOT/skills/review/SKILL.md" \
    || fail "review skill must publish user comments via publish-github.sh"
  grep -q 'tuicr review list' "$ROOT/skills/review/SKILL.md" \
    || fail "review skill must discover the live tuicr session"
  grep -q 'publish-github.sh' "$ROOT/skills/review/MANIFEST" \
    || fail "MANIFEST must list publish-github.sh"
  printf 'PASS: review skill waits for user notes and publishes only on request\n'
}

test_handoff_spawn_is_the_recipe() {
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
  grep -q -- '--take-pending\|pending_prompt\|handoff-brief' "$ROOT/skills/handoff/SKILL.md" \
    && fail "SKILL.md must not keep the prompt-file flow"
  grep -q "Never put the user's ask on the spawn command line" "$ROOT/skills/handoff/SKILL.md" \
    || fail "SKILL.md must forbid prompt-on-argv"
  grep -q 'handoff-spawn' "$ROOT/skills/handoff/MANIFEST" \
    || fail "MANIFEST must list handoff-spawn"
  grep -q 'scripts/git-backend.sh' "$ROOT/skills/handoff/MANIFEST" \
    || fail "MANIFEST must list git-backend.sh"
  grep -qi 'poteto\|pstack' "$ROOT/skills/handoff/SKILL.md" \
    && fail "SKILL.md must not keep a poteto or pstack mode"
  printf 'PASS: handoff skill recipe is the spawn script\n'
}

test_deploy_installs_canonical_skills_and_pi_links
test_pi_link_preserves_a_foreign_path
test_uninstall_scrubs_pi_links
test_deploy_lib_copies_git_backend() {
  deploy_lib >/dev/null
  cmp -s "$ROOT/skills/handoff/scripts/git-backend.sh" "$AGENTIC_DEV_SHARE_DIR/lib/git-backend.sh" \
    || fail "installed lib/git-backend.sh must match the skill script"
  cmp -s "$ROOT/skills/handoff/scripts/git-backend.sh" "$ROOT/lib/git-backend.sh" \
    || fail "repo lib/git-backend.sh must be the skill script"
  printf 'PASS: deploy_lib copies git-backend.sh next to the other libs\n'
}

test_handoff_spawn_is_the_recipe
test_review_skill_recipe
test_unit_testing_skill_credits_its_source
test_deploy_lib_copies_git_backend
