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

  mkdir -p "$BERCAIL_CONFIG_DIR" "$WORKTRUNK_CONFIG_DIR" "$AGENTS_SKILLS_DIR/handoff" \
    "$AGENTS_SKILLS_DIR/review" "$BERCAIL_SHARE_DIR"
  cat >"$BERCAIL_USER_CONFIG" <<'EOF'
[layout]
review = "tuicr"
EOF

  cp "$ROOT/config/worktrunk/herdr-layout.sh" "$WORKTRUNK_CONFIG_DIR/herdr-layout.sh"
  cp "$ROOT/skills/handoff/SKILL.md" "$AGENTS_SKILLS_DIR/handoff/SKILL.md"
  cp "$ROOT/skills/review/SKILL.md" "$AGENTS_SKILLS_DIR/review/SKILL.md"
  local id
  for id in bstack council autopilot how why unslop desk-restore unit-testing; do
    mkdir -p "$AGENTS_SKILLS_DIR/$id"
    cp "$ROOT/skills/$id/SKILL.md" "$AGENTS_SKILLS_DIR/$id/SKILL.md"
  done
  mkdir -p "$HOME/.pi/agent/skills"
  for id in "${BERCAIL_SKILL_IDS[@]}"; do
    ln -s "$AGENTS_SKILLS_DIR/$id" "$HOME/.pi/agent/skills/$id"
  done

  record_install_source
}

@test "record_install_source writes the clone's path to source-path" {
  local assert_src
  [[ -f "$BERCAIL_SOURCE_PATH_FILE" ]] || fail "source-path was not recorded"
  assert_src="$(<"$BERCAIL_SOURCE_PATH_FILE")"
  [[ "$assert_src" == "$ROOT" ]] || fail "source-path: expected $ROOT got $assert_src"
}

@test "doctor reports ok when helper and skill match the clone" {
  local helper_out skill_out
  helper_out="$(doctor_helper)"
  grep -q 'ok  herdr-layout.sh' <<<"$helper_out" \
    || fail "matching helper should be ok: $helper_out"
  skill_out="$(doctor_skill)"
  grep -q "ok  skill handoff" <<<"$skill_out" \
    || fail "matching skill should be ok: $skill_out"
}

@test "doctor reports stale skill vs clone" {
  local skill_out
  printf 'stale-skill\n' >"$AGENTS_SKILLS_DIR/handoff/SKILL.md"
  skill_out="$(doctor_skill)" || true
  grep -q "stale  skill handoff" <<<"$skill_out" \
    || fail "mismatched skill should be stale: $skill_out"
  grep -q "run ./install.sh from $ROOT" <<<"$skill_out" \
    || fail "stale skill should name the clone: $skill_out"
}

@test "doctor reports stale helper vs clone" {
  local helper_out
  printf 'stale-helper\n' >"$WORKTRUNK_CONFIG_DIR/herdr-layout.sh"
  helper_out="$(doctor_helper)" || true
  grep -q "stale  herdr-layout.sh" <<<"$helper_out" \
    || fail "mismatched helper should be stale: $helper_out"
  grep -q "run ./install.sh from $ROOT" <<<"$helper_out" \
    || fail "stale helper should name the clone: $helper_out"
}

@test "doctor checks installed files without requiring a recorded source" {
  local helper_out skill_out
  rm -f "$BERCAIL_SOURCE_PATH_FILE"
  helper_out="$(doctor_helper)"
  [[ "$helper_out" == *'ok  herdr-layout.sh (not compared: installed from a release)'* ]] \
    || fail "release helper: $helper_out"
  skill_out="$(doctor_skill)"
  [[ "$skill_out" == *'ok  skill handoff (not compared: installed from a release)'* ]] \
    || fail "release skill: $skill_out"
}

@test "doctor exits zero on a complete deployed install with no recorded source" {
  local tools="$BATS_TEST_TMPDIR/bin" tool output rc=0
  mkdir -p "$tools" "$HOME/.config/hypr"
  # No host desktop, package manager, core socket, or network on this PATH.
  for tool in bash sh env cat cp mv rm ln mkdir chmod cmp dirname basename realpath readlink \
    find grep sed awk tr sort uniq head tail wc mktemp date git jq touch uname sleep stat cut; do
    ln -s "$(command -v "$tool")" "$tools/$tool"
  done
  for tool in herdr-app hc wt bd fzf tuicr; do
    printf '#!/bin/sh\n[ "$1" != --version ] || echo 99.0.0\nexit 0\n' >"$tools/$tool"
    chmod +x "$tools/$tool"
  done
  # Pi with the Claude bridge installed, and Claude Code signed in on a plan.
  cat >"$tools/pi" <<'SH'
#!/bin/sh
case "$1" in
  --version) echo 99.0.0 ;;
  --offline) printf '%s\n' 'provider model context max-out thinking images' 'claude-bridge claude-opus-5-5 1M 128K yes yes' ;;
esac
SH
  printf '%s\n' '#!/bin/sh' "echo '{\"loggedIn\":true,\"authMethod\":\"claude.ai\"}'" >"$tools/claude"
  printf '#!/bin/sh\nexit 1\n' >"$tools/curl"
  chmod +x "$tools/pi" "$tools/claude" "$tools/curl"
  : >"$HOME/.config/hypr/bindings.conf"
  output="$(env -i HOME="$HOME" PATH="$tools" SHELL=/bin/bash INSTALL_SRC="$ROOT" \
    BERCAIL_NO_PROMPT=1 "$ROOT/bin/bercail" update 2>&1)" || fail "deploy: $output"
  rm "$BERCAIL_SOURCE_PATH_FILE"
  output="$(env -i HOME="$HOME" PATH="$tools" SHELL=/bin/bash "$HOME/.local/bin/bercail" doctor 2>&1)" || rc=$?
  [[ "$rc" -eq 0 ]] || fail "doctor: $output"
  [[ "$output" == *'not compared: installed from a release'* ]] || fail "$output"
  [[ "$output" == *'ok  bstack (lead=claude-bridge/claude-opus-5-5:high)'* ]] || fail "bstack is part of the install: $output"
}

@test "doctor still fails missing files without a recorded source" {
  rm -f "$BERCAIL_SOURCE_PATH_FILE" "$WORKTRUNK_CONFIG_DIR/herdr-layout.sh" \
    "$AGENTS_SKILLS_DIR/handoff/SKILL.md"
  local output rc=0
  output="$(doctor_helper)" || rc=$?
  [[ "$rc" -eq 1 && "$output" == *'missing  herdr-layout.sh'* ]] || fail "$output"
  rc=0
  output="$(doctor_skill)" || rc=$?
  [[ "$rc" -eq 1 && "$output" == *'missing  skill handoff'* ]] || fail "$output"
}
