#!/usr/bin/env bats

# shellcheck disable=SC2034 # YES, DRY_RUN and friends are read by the sourced libs.

setup() {
  load test_helper
  isolate
  mkdir -p "$XDG_CONFIG_HOME"
  # shellcheck source=/dev/null
  source "$ROOT/lib/common.sh"
  # shellcheck source=/dev/null
  source "$ROOT/lib/detect.sh"
  # shellcheck source=/dev/null
  source "$ROOT/lib/config.sh"
  # shellcheck source=/dev/null
  source "$ROOT/lib/skills.sh"
  # shellcheck source=/dev/null
  source "$ROOT/lib/doctor.sh"

  export INSTALL_SRC="$ROOT"
  YES=1
  DRY_RUN=0

  mkdir -p "$AGENTIC_DEV_CONFIG_DIR" "$WORKTRUNK_CONFIG_DIR" "$AGENTIC_DEV_SKILL_DIR" \
    "$AGENTS_SKILLS_DIR/review" "$AGENTIC_DEV_SHARE_DIR"
  cat >"$AGENTIC_DEV_USER_CONFIG" <<'EOF'
[layout]
review = "tuicr"
EOF

  cp "$ROOT/config/worktrunk/herdr-layout.sh" "$WORKTRUNK_CONFIG_DIR/herdr-layout.sh"
  cp "$ROOT/skills/handoff/SKILL.md" "$AGENTIC_DEV_SKILL_DIR/SKILL.md"
  cp "$ROOT/skills/review/SKILL.md" "$AGENTS_SKILLS_DIR/review/SKILL.md"
  local id
  for id in bstack council autopilot how why unslop desk-restore unit-testing; do
    mkdir -p "$AGENTS_SKILLS_DIR/$id"
    cp "$ROOT/skills/$id/SKILL.md" "$AGENTS_SKILLS_DIR/$id/SKILL.md"
  done
  mkdir -p "$HOME/.pi/agent/skills"
  for id in "${AGENTIC_DEV_SKILL_IDS[@]}"; do
    ln -s "$AGENTS_SKILLS_DIR/$id" "$HOME/.pi/agent/skills/$id"
  done

  record_install_source
}

@test "record_install_source writes the clone's path to source-path" {
  local assert_src
  [[ -f "$AGENTIC_DEV_SOURCE_PATH_FILE" ]] || fail "source-path was not recorded"
  assert_src="$(<"$AGENTIC_DEV_SOURCE_PATH_FILE")"
  [[ "$assert_src" == "$ROOT" ]] || fail "source-path: expected $ROOT got $assert_src"
}

@test "doctor reports ok when helper and skill match the clone" {
  local helper_out skill_out
  helper_out="$(doctor_helper)"
  printf '%s\n' "$helper_out" | grep -q 'ok  herdr-layout.sh' \
    || fail "matching helper should be ok: $helper_out"
  skill_out="$(doctor_skill)"
  printf '%s\n' "$skill_out" | grep -q "ok  skill handoff" \
    || fail "matching skill should be ok: $skill_out"
}

@test "doctor reports stale skill vs clone" {
  local skill_out
  printf 'stale-skill\n' >"$AGENTIC_DEV_SKILL_DIR/SKILL.md"
  skill_out="$(doctor_skill)" || true
  printf '%s\n' "$skill_out" | grep -q "stale  skill handoff" \
    || fail "mismatched skill should be stale: $skill_out"
  printf '%s\n' "$skill_out" | grep -q "run ./install.sh from $ROOT" \
    || fail "stale skill should name the clone: $skill_out"
}

@test "doctor reports stale helper vs clone" {
  local helper_out
  printf 'stale-helper\n' >"$WORKTRUNK_CONFIG_DIR/herdr-layout.sh"
  helper_out="$(doctor_helper)" || true
  printf '%s\n' "$helper_out" | grep -q "stale  herdr-layout.sh" \
    || fail "mismatched helper should be stale: $helper_out"
  printf '%s\n' "$helper_out" | grep -q "run ./install.sh from $ROOT" \
    || fail "stale helper should name the clone: $helper_out"
}

@test "doctor reports unverified when install source is missing" {
  local helper_out skill_out
  rm -f "$AGENTIC_DEV_SOURCE_PATH_FILE"
  helper_out="$(doctor_helper)" || true
  printf '%s\n' "$helper_out" | grep -q 'unverified  herdr-layout.sh' \
    || fail "missing source-path should be unverified: $helper_out"
  skill_out="$(doctor_skill)" || true
  printf '%s\n' "$skill_out" | grep -q 'unverified  skill handoff' \
    || fail "missing source-path should unverified skill: $skill_out"
}
