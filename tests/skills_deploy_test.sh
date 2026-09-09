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

write_agent_config() {
  local cmd="$1"
  mkdir -p "$AGENTIC_DEV_CONFIG_DIR"
  cat >"$AGENTIC_DEV_USER_CONFIG" <<EOF
[agent]
command = "$cmd"

[layout]
editor = "nvim"
EOF
}

test_deploy_agents_path_for_cursor() {
  write_agent_config cursor-agent
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
  [[ ! -e "$HOME/.cursor/skills/handoff" ]] || fail "cursor should use ~/.agents/skills only"
  printf 'PASS: deploy_skills installs ~/.agents/handoff and review for cursor-agent\n'
}

test_reconfigure_scrubs_orphan_extra_link() {
  write_agent_config codex
  deploy_skills >/dev/null
  [[ -L "$HOME/.codex/skills/handoff" ]] || fail "codex skill symlink missing"
  write_agent_config cursor-agent
  deploy_skills >/dev/null
  [[ ! -e "$HOME/.codex/skills/handoff" ]] || fail "codex orphan link should be scrubbed on reconfigure to cursor-agent"
  [[ -f "$AGENTIC_DEV_SKILL_DIR/SKILL.md" ]] || fail "canonical skill missing after scrub"
  printf 'PASS: deploy_skills scrubs orphan extra links on agent switch\n'
}

test_preserve_foreign_skill_path() {
  write_agent_config opencode
  mkdir -p "$HOME/.config/opencode/skills/handoff"
  printf 'foreign\n' >"$HOME/.config/opencode/skills/handoff/SKILL.md"
  local output
  output="$(deploy_skills 2>&1)"
  printf '%s\n' "$output" | grep -q 'preserving pre-existing skill path' \
    || fail "expected preserve warning for foreign skill dir"
  grep -qx 'foreign' "$HOME/.config/opencode/skills/handoff/SKILL.md" \
    || fail "foreign skill contents changed"
  printf 'PASS: deploy_skills preserves foreign agent skill paths\n'
}

test_custom_agent_canonical_only() {
  rm -rf "$HOME/.agents" "$HOME/.cursor" "$HOME/.codex" "$HOME/.config/opencode" "$HOME/.claude"
  write_agent_config my-custom-agent
  deploy_skills >/dev/null
  [[ -f "$AGENTIC_DEV_SKILL_DIR/SKILL.md" ]] || fail "canonical skill missing for custom agent"
  [[ ! -e "$HOME/.codex/skills/handoff" ]] || fail "custom agent should not create codex link"
  printf 'PASS: custom agent installs canonical skill only\n'
}

test_grok_gets_extra_skill_link() {
  rm -rf "$HOME/.agents" "$HOME/.grok" "$HOME/.codex" "$HOME/.claude"
  write_agent_config grok
  deploy_skills >/dev/null
  [[ -f "$AGENTIC_DEV_SKILL_DIR/SKILL.md" ]] || fail "canonical skill missing for grok"
  [[ -L "$HOME/.grok/skills/handoff" ]] || fail "grok skill symlink missing"
  [[ -L "$HOME/.grok/skills/review" ]] || fail "grok review symlink missing"
  [[ ! -e "$HOME/.codex/skills/handoff" ]] || fail "grok should not create a codex link"
  write_agent_config cursor-agent
  deploy_skills >/dev/null
  [[ ! -e "$HOME/.grok/skills/handoff" ]] || fail "grok orphan link should be scrubbed on reconfigure"
  [[ ! -e "$HOME/.grok/skills/review" ]] || fail "grok review orphan link should be scrubbed on reconfigure"
  printf 'PASS: deploy_skills links ~/.grok/skills/handoff for grok\n'
}

test_pi_gets_extra_skill_link() {
  rm -rf "$HOME/.agents" "$HOME/.pi" "$HOME/.codex"
  write_agent_config pi
  deploy_skills >/dev/null
  [[ -f "$AGENTIC_DEV_SKILL_DIR/SKILL.md" ]] || fail "canonical skill missing for pi"
  [[ -L "$HOME/.pi/agent/skills/handoff" ]] || fail "pi skill symlink missing"
  [[ -L "$HOME/.pi/agent/skills/review" ]] || fail "pi review symlink missing"
  write_agent_config cursor-agent
  deploy_skills >/dev/null
  [[ ! -e "$HOME/.pi/agent/skills/handoff" ]] || fail "pi orphan link should be scrubbed on reconfigure"
  printf 'PASS: deploy_skills links ~/.pi/agent/skills/handoff for pi\n'
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
  grep -q 'Do not inspect git, Graphite, Herdr, or worktrees yourself' "$ROOT/skills/handoff/SKILL.md" \
    || fail "SKILL.md must not keep the glued multi-tool recipe"
  grep -q -- '--workspace' "$ROOT/skills/handoff/SKILL.md" \
    || fail "SKILL.md must cover socket-attached parents"
  grep -q -- '--take-pending' "$ROOT/skills/handoff/SKILL.md" \
    || fail "SKILL.md must use --take-pending so Auto-review does not bind a prompt argv"
  grep -q 'do not put the original user prompt on the spawn command line' "$ROOT/skills/handoff/SKILL.md" \
    || grep -q 'Never put the original user prompt on the spawn command line' "$ROOT/skills/handoff/SKILL.md" \
    || fail "SKILL.md must forbid prompt-on-argv"
  grep -q 'handoff-spawn' "$ROOT/skills/handoff/MANIFEST" \
    || fail "MANIFEST must list handoff-spawn"
  grep -q 'pstack' "$ROOT/skills/handoff/SKILL.md" \
    || fail "SKILL.md must mention pstack"
  printf 'PASS: handoff skill recipe is the spawn script\n'
}

test_deploy_agents_path_for_cursor
test_reconfigure_scrubs_orphan_extra_link
test_preserve_foreign_skill_path
test_custom_agent_canonical_only
test_grok_gets_extra_skill_link
test_pi_gets_extra_skill_link
test_handoff_spawn_is_the_recipe
test_review_skill_recipe
