#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

unset BASH_ENV
export __MISE_BASH_ENV_LOADED=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

export HOME="$TMP_DIR/home"
export XDG_CONFIG_HOME="$HOME/.config"
mkdir -p "$HOME" "$XDG_CONFIG_HOME"

# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=lib/detect.sh
source "$ROOT/lib/detect.sh"
# shellcheck source=lib/config.sh
source "$ROOT/lib/config.sh"
# shellcheck source=lib/skills.sh
source "$ROOT/lib/skills.sh"
# shellcheck source=lib/doctor.sh
source "$ROOT/lib/doctor.sh"

export INSTALL_SRC="$ROOT"
YES=1
DRY_RUN=0

mkdir -p "$AGENTIC_DEV_CONFIG_DIR" "$WORKTRUNK_CONFIG_DIR" "$AGENTIC_DEV_SKILL_DIR" \
  "$AGENTS_SKILLS_DIR/review" "$AGENTIC_DEV_SHARE_DIR"
cat >"$AGENTIC_DEV_USER_CONFIG" <<'EOF'
[agent]
command = "agent"

[layout]
editor = "nvim"
EOF

cp "$ROOT/config/worktrunk/herdr-layout.sh" "$WORKTRUNK_CONFIG_DIR/herdr-layout.sh"
cp "$ROOT/skills/handoff/SKILL.md" "$AGENTIC_DEV_SKILL_DIR/SKILL.md"
cp "$ROOT/skills/review/SKILL.md" "$AGENTS_SKILLS_DIR/review/SKILL.md"
for id in bstack council autopilot how why unslop; do
  mkdir -p "$AGENTS_SKILLS_DIR/$id"
  cp "$ROOT/skills/$id/SKILL.md" "$AGENTS_SKILLS_DIR/$id/SKILL.md"
done

record_install_source
[[ -f "$AGENTIC_DEV_SOURCE_PATH_FILE" ]] || fail "source-path was not recorded"
assert_src="$(<"$AGENTIC_DEV_SOURCE_PATH_FILE")"
[[ "$assert_src" == "$ROOT" ]] || fail "source-path: expected $ROOT got $assert_src"

helper_out="$(doctor_helper)"
printf '%s\n' "$helper_out" | grep -q 'ok  herdr-layout.sh' \
  || fail "matching helper should be ok: $helper_out"
skill_out="$(doctor_skill)"
printf '%s\n' "$skill_out" | grep -q "ok  skill handoff" \
  || fail "matching skill should be ok: $skill_out"
printf 'PASS: doctor reports ok when helper and skill match the clone\n'

printf 'stale-skill\n' >"$AGENTIC_DEV_SKILL_DIR/SKILL.md"
skill_out="$(doctor_skill)" || true
printf '%s\n' "$skill_out" | grep -q "stale  skill handoff" \
  || fail "mismatched skill should be stale: $skill_out"
printf '%s\n' "$skill_out" | grep -q "run ./install.sh from $ROOT" \
  || fail "stale skill should name the clone: $skill_out"
printf 'PASS: doctor reports stale skill vs clone\n'

printf 'stale-helper\n' >"$WORKTRUNK_CONFIG_DIR/herdr-layout.sh"
helper_out="$(doctor_helper)" || true
printf '%s\n' "$helper_out" | grep -q "stale  herdr-layout.sh" \
  || fail "mismatched helper should be stale: $helper_out"
printf '%s\n' "$helper_out" | grep -q "run ./install.sh from $ROOT" \
  || fail "stale helper should name the clone: $helper_out"
printf 'PASS: doctor reports stale helper vs clone\n'

rm -f "$AGENTIC_DEV_SOURCE_PATH_FILE"
helper_out="$(doctor_helper)" || true
printf '%s\n' "$helper_out" | grep -q 'unverified  herdr-layout.sh' \
  || fail "missing source-path should be unverified: $helper_out"
skill_out="$(doctor_skill)" || true
printf '%s\n' "$skill_out" | grep -q 'unverified  skill handoff' \
  || fail "missing source-path should unverified skill: $skill_out"
printf 'PASS: doctor reports unverified when install source is missing\n'
