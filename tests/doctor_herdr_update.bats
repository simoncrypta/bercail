#!/usr/bin/env bats
# doctor hints when Herdr has downloaded a newer version than the one running.

setup() {
  load test_helper
  isolate
  export HERDR_APP_CONFIG_DIR="$BATS_TEST_TMPDIR/herdr-app"
  mkdir -p "$HERDR_APP_CONFIG_DIR" "$BATS_TEST_TMPDIR/bin"
  cat >"$BATS_TEST_TMPDIR/bin/herdr-app" <<EOF
#!/bin/sh
[ "\$1" = --version ] && echo "herdr-app \$(cat "$BATS_TEST_TMPDIR/version")"
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/herdr-app"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  # shellcheck source=/dev/null
  source "$ROOT/lib/common.sh"
  # shellcheck source=/dev/null
  source "$ROOT/lib/doctor.sh"
}

# $1 running binary, $2 version Herdr last ran, $3 newest in the cached changelog.
state() {
  printf '%s\n' "$1" >"$BATS_TEST_TMPDIR/version"
  printf '{"last_run": "%s", "presented": []}\n' "$2" >"$HERDR_APP_CONFIG_DIR/update-notes.json"
  printf '# Herdr changelog\n\n## [%s] - 2026-10-31\n\n### Fixed\n- a\n\n## [0.1.9] - 2026-10-30\n' "$3" \
    >"$HERDR_APP_CONFIG_DIR/update-notes-cache.md"
}

@test "doctor hints when the cached version is newer" {
  local out
  state 0.1.9 0.1.9 0.1.11
  out="$(doctor_herdr_app_update)"
  [[ "$out" == "  hint  Herdr 0.1.11 is downloaded (running 0.1.9); restart the Herdr window to apply it" ]] \
    || fail "newer cached version should hint: $out"
}

@test "doctor hints when the new binary is on disk but not running" {
  local out
  state 0.1.11 0.1.9 0.1.11
  out="$(doctor_herdr_app_update)"
  [[ "$out" == *"Herdr 0.1.11 is downloaded (running 0.1.9)"* ]] \
    || fail "a replaced binary the window has not run yet should hint: $out"
}

@test "doctor hints when Herdr's mod is no longer the one bercail's copy was made from" {
  local out mod
  printf '0.1.16\n' >"$BATS_TEST_TMPDIR/version"
  for mod in bercail-spaces bercail-agents; do
    mkdir -p "$HERDR_APP_CONFIG_DIR/mods/$mod"
    cp "$ROOT/bercail/mods/$mod/mod.json" "$HERDR_APP_CONFIG_DIR/mods/$mod/"
  done
  jq -n --slurpfile s "$ROOT/bercail/mods/bercail-spaces/mod.json" --slurpfile a "$ROOT/bercail/mods/bercail-agents/mod.json" \
    '{spaces: {"main.js": $s[0].cloned_from.main_js}, agents: {"main.js": $a[0].cloned_from.main_js}}' \
    >"$HERDR_APP_CONFIG_DIR/installed.json"
  out="$(doctor_mod_copies)"
  [[ -z "$out" ]] || fail "the mods bercail copied are the installed ones: $out"

  jq '.agents["main.js"] = "0000000000000000"' "$HERDR_APP_CONFIG_DIR/installed.json" >"$BATS_TEST_TMPDIR/installed.json"
  mv "$BATS_TEST_TMPDIR/installed.json" "$HERDR_APP_CONFIG_DIR/installed.json"
  out="$(doctor_mod_copies)"
  [[ "$out" == "  hint  Herdr's agents mod changed after 0.1.15; bercail-agents is bercail's copy of that one and lacks the change until bercail updates it" ]] \
    || fail "a newer agents mod should hint, and only it: $out"

  printf '0.1.14\n' >"$BATS_TEST_TMPDIR/version"
  out="$(doctor_mod_copies)"
  [[ "$out" == "  hint  bercail-agents is bercail's copy of Herdr 0.1.15's agents mod and this Herdr is 0.1.14; update Herdr" ]] \
    || fail "an older Herdr is the one to update: $out"

  rm "$HERDR_APP_CONFIG_DIR/installed.json"
  out="$(doctor_mod_copies)"
  [[ -z "$out" ]] || fail "no installed.json is nothing to compare: $out"
}

@test "doctor stays silent when the versions are equal" {
  local out
  state 0.1.11 0.1.11 0.1.11
  out="$(doctor_herdr_app_update)"
  [[ -z "$out" ]] || fail "equal versions should be silent: $out"
  state 0.1.10 0.1.10 0.1.9
  out="$(doctor_herdr_app_update)"
  [[ -z "$out" ]] || fail "an older changelog should be silent: $out"
}

@test "doctor stays silent when the files are missing" {
  local out
  state 0.1.10 0.1.10 0.1.9
  rm -f "$HERDR_APP_CONFIG_DIR/update-notes-cache.md" "$HERDR_APP_CONFIG_DIR/update-notes.json"
  out="$(doctor_herdr_app_update)"
  [[ -z "$out" ]] || fail "missing files should be silent: $out"
  state 0.1.9 0.1.9 0.1.11
  rm -f "$HERDR_APP_CONFIG_DIR/update-notes.json"
  : >"$BATS_TEST_TMPDIR/version"
  out="$(doctor_herdr_app_update)"
  [[ -z "$out" ]] || fail "no running version known should be silent: $out"
}
