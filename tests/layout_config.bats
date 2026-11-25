#!/usr/bin/env bats
# Layout config: defaults, write, and doctor follow the review command.

# shellcheck disable=SC2034 # YES, DRY_RUN and friends are read by the sourced libs.
# shellcheck disable=SC2329 # stubs replace lib functions the libs call.

setup() {
  load test_helper
  isolate
  mkdir -p "$XDG_CONFIG_HOME"
  # shellcheck source=/dev/null
  source "$ROOT/lib/common.sh"
  # shellcheck source=/dev/null
  source "$ROOT/lib/detect.sh"
  # shellcheck source=/dev/null
  source "$ROOT/lib/deps.sh"
  # shellcheck source=/dev/null
  source "$ROOT/lib/config.sh"

  export INSTALL_SRC="$ROOT"
  export BERCAIL_CONFIG_DIR="$XDG_CONFIG_HOME/bercail"
  export BERCAIL_USER_CONFIG="$BERCAIL_CONFIG_DIR/config.toml"
  unset EDITOR
  YES=1
  DRY_RUN=0

  info() { :; }
  warn() { printf '%s\n' "$*" >&2; }
}

assert_eq() {
  local expected="$1" actual="$2" msg="${3:-}"
  [[ "$expected" == "$actual" ]] || fail "${msg}: expected '$expected' got '$actual'"
}

assert_contains() {
  local haystack="$1" needle="$2" msg="${3:-}"
  [[ "$haystack" == *"$needle"* ]] || fail "${msg}: missing '$needle' in '$haystack'"
}

# doctor_dependencies on a host with every tool but tuicr, and review = "hunk",
# a tool bercail once installed and held to 0.20.1. Sets out and rc.
doctor_with_hunk_review() {
  local case_dir="$BATS_TEST_TMPDIR/doctor-hunk" cmd
  mkdir -p "$case_dir/bin" "$case_dir/home/.config/bercail"
  cat >"$case_dir/home/.config/bercail/config.toml" <<'EOF'
[layout]
review = "hunk"
EOF
  for cmd in herdr-app hc git wt bd fzf pi; do
    ln -s /bin/true "$case_dir/bin/$cmd"
  done
  # The config reader runs jq, so this one is real.
  ln -s "$(command -v jq)" "$case_dir/bin/jq"
  printf '#!/bin/sh\necho hunk 0.1.0\n' >"$case_dir/bin/hunk"
  chmod +x "$case_dir/bin/hunk"
  rc=0
  out="$(
    HOME="$case_dir/home" \
      XDG_CONFIG_HOME="$case_dir/home/.config" \
      BERCAIL_CONFIG_DIR="$case_dir/home/.config/bercail" \
      BERCAIL_USER_CONFIG="$case_dir/home/.config/bercail/config.toml" \
      PATH="$case_dir/bin:/usr/bin:/bin" \
      doctor_dependencies 2>&1
  )" || rc=$?
}

@test "detect_shell_name and shell_rc_for follow the SHELL variable" {
  SHELL=/bin/zsh
  assert_eq "zsh" "$(detect_shell_name)" "detect_shell_name follows zsh \$SHELL"
  assert_eq "${HOME}/.zshrc" "$(shell_rc_for zsh)" "zsh rc is ~/.zshrc"
  SHELL=/bin/bash
  assert_eq "bash" "$(detect_shell_name)" "detect_shell_name follows bash \$SHELL"
  assert_eq "${HOME}/.bashrc" "$(shell_rc_for bash)" "bash rc is ~/.bashrc"
}

@test "a new install writes [bstack] with the claude lead and no switch or agent command" {
  local cfg
  cfg="$(default_user_config)"
  assert_contains "$cfg" '[bstack]' \
    "a new install writes [bstack]"
  assert_contains "$cfg" 'lead = "claude"' \
    "a new install names the claude family for the lead"
  [[ "$cfg" != *'enabled'* ]] || fail "a new install has no bstack switch"
  [[ "$cfg" != *'command = '* ]] || fail "config has no agent command"
  # BSTACK_NEW_INSTALL was the --no-bstack switch. Nothing reads it.
  cfg="$(BSTACK_NEW_INSTALL=0 default_user_config)"
  assert_contains "$cfg" '[bstack]' \
    "the old switch variable does not drop [bstack]"
  assert_contains "$cfg" 'lead = "claude"' \
    "the lead stays when the old switch variable is set"
  [[ "$cfg" != *'enabled'* ]] || fail "the old switch variable does not write enabled"
}

@test "prompt_user_config writes the default review and [bstack] with no switch" {
  YES=1
  prompt_user_config
  assert_eq "tuicr" "$(read_layout_review)" "prompt_user_config writes the default review"
  grep -q 'lead = "claude"' "$BERCAIL_USER_CONFIG" \
    || fail "prompt_user_config writes the lead"
  if grep -q 'enabled' "$BERCAIL_USER_CONFIG"; then
    fail "prompt_user_config writes no bstack switch"
  fi
}

@test "default config turns on tuicr review with auto_review and pins no editor" {
  assert_contains "$(default_user_config)" 'review = "tuicr"' \
    "default config includes review"
  assert_contains "$(default_user_config)" 'auto_review = true' \
    "default config enables auto_review"
  [[ "$(default_user_config)" != *'editor = "fresh"'* ]] \
    || fail "default config must not pin fresh as the editor"
}

@test "read_layout_review is tuicr with no config, hunk diff for hunk, and any other command as written" {
  assert_eq "tuicr" "$(read_layout_review)" "no config"
  mkdir -p "$BERCAIL_CONFIG_DIR"
  printf '[bstack]\nreview = "not this one"\n[layout]\nreview = "hunk"\n' >"$BERCAIL_USER_CONFIG"
  assert_eq "hunk diff" "$(read_layout_review)" "hunk, and only the [layout] key"
  printf '[layout]\nreview = "lazygit --diff"\n' >"$BERCAIL_USER_CONFIG"
  assert_eq "lazygit --diff" "$(read_layout_review)" "another command"
}

@test "doctor takes the configured review command as it is: no tuicr, no minimum version" {
  doctor_with_hunk_review
  assert_eq "0" "$rc" "doctor exits 0 for a review command on PATH: $out"
  assert_contains "$out" "ok  hunk" "doctor accepts the configured command"
  [[ "$out" != *"missing  tuicr"* ]] || fail "doctor should not require tuicr when review names another command"
  [[ "$out" != *"required >="* ]] || fail "doctor holds a command bercail does not install to a version: $out"
}

@test "doctor names the config keys nothing reads, a [git] value that is no backend, and a line it cannot read" {
  local out
  mkdir -p "$BERCAIL_CONFIG_DIR"
  cat >"$BERCAIL_USER_CONFIG" <<'EOF'
[layout]
review = "tuicr"
reveiw = "hunk"
[bstack]
harness = "pi"
lead = "claude"
[agent]
command = "pi"
[shep]
session = "agent:sheep:main"
backend = "pi"
rollover = true
oops
[git]
"~/Work/a.b" = "gh"
"~/Work/c" = "github"
[policy."~/Work/a.b"]
commit = "allow"
merge = "yes"
[policy]
commit = "allow"
[desk_secrets."~/Work/a.b"]
op_service_account = "~/.config/bercail/secrets/a.op"
token = "ops_x"
EOF
  out="$(doctor_config)" || fail "an unread key is not a failure: $out"
  assert_eq '  unknown  [layout] reveiw (nothing reads it)
  unknown  [bstack] harness (nothing reads it)
  unknown  [agent] command (nothing reads it)
  unknown  [shep] session (nothing reads it)
  unknown  [shep] backend (nothing reads it)
  unread  config.toml line 13: not a key = value line
  unknown  [git] "~/Work/c" = github (use gh, gt, origin, or entire)
  unknown  [policy."~/Work/a.b"] commit (nothing reads it)
  unknown  [policy."~/Work/a.b"] merge (nothing reads it)
  unknown  [policy] commit (nothing reads it)
  unknown  [desk_secrets."~/Work/a.b"] token (nothing reads it)' "$out" "doctor notes"
}

@test "doctor has nothing to say about the config docs/config.md shows, the example, or a new install's" {
  local out
  mkdir -p "$BERCAIL_CONFIG_DIR"
  awk '/^```toml$/ { on = 1; next } /^```$/ { exit } on' "$ROOT/docs/config.md" >"$BERCAIL_USER_CONFIG"
  grep -q '^\[shep\]' "$BERCAIL_USER_CONFIG" || fail "did not find the documented config"
  out="$(doctor_config)"
  assert_eq "" "$out" "docs/config.md"
  cp "$ROOT/config/bercail/config.toml.example" "$BERCAIL_USER_CONFIG"
  out="$(doctor_config)"
  assert_eq "" "$out" "config.toml.example"
  default_user_config >"$BERCAIL_USER_CONFIG"
  out="$(doctor_config)"
  assert_eq "" "$out" "a new install"
}

@test "bercail config get prints a value as bercail reads it, and exits 1 for a key that is not set" {
  local out rc=0
  mkdir -p "$BERCAIL_CONFIG_DIR"
  cp "$ROOT/tests/fixtures/config-hard.toml" "$BERCAIL_USER_CONFIG"
  assert_eq hunk "$(bash "$ROOT/bin/bercail" config get layout review)" "a string, comment dropped"
  assert_eq false "$(bash "$ROOT/bin/bercail" config get layout auto_review)" "a bool"
  assert_eq '["claude","gpt","grok"]' "$(bash "$ROOT/bin/bercail" config get bstack fallback)" "an array"
  assert_eq allow "$(bash "$ROOT/bin/bercail" config get 'policy."~/Work/a.b"' commit)" "a quoted table name"
  out="$(bash "$ROOT/bin/bercail" config get layout no_such 2>&1)" || rc=$?
  [[ "$rc" -eq 1 && -z "$out" ]] || fail "a missing key: rc=$rc out=$out"
  rc=0
  out="$(bash "$ROOT/bin/bercail" config set layout review 2>&1)" || rc=$?
  [[ "$rc" -eq 1 && "$out" == *"usage: bercail config get <section> <key>"* ]] || fail "usage: rc=$rc out=$out"
}

@test "bercail config set changes its key's line alone, comment kept, or adds the key or its table; each unset puts the file back" {
  local out cfg="$BERCAIL_USER_CONFIG" real="$BATS_TEST_TMPDIR/dotfiles/config.toml"
  mkdir -p "$BERCAIL_CONFIG_DIR" "${real%/*}"
  sed 's/^compact_at = 250000$/&#no space/' "$ROOT/tests/fixtures/config-hard.toml" >"$real"
  cp "$real" "$BATS_TEST_TMPDIR/before"
  chmod 600 "$real"
  ln -s "$real" "$cfg"
  out="$(bash "$ROOT/bin/bercail" config set layout review tuicr)"
  [[ "$out" == "--- $cfg -> $real"$'\n'* ]] || fail "the diff names the link and its file: $out"
  [[ "$out" == *$'\n-review = "hunk" # comment after\n+review = "tuicr" # comment after\n'* ]] || fail "the diff: $out"
  bash "$ROOT/bin/bercail" config set bstack claude 'x"y#z' >/dev/null
  assert_eq 'claude = "x\"y#z"   # keeps the variant' "$(grep '^claude' "$cfg")" "a quote and a # in the value, the comment after it kept"
  bash "$ROOT/bin/bercail" config set shep compact_at 1 >/dev/null
  assert_eq 'compact_at = 1#no space' "$(grep '^compact_at' "$cfg")" "a comment right after its value"
  bash "$ROOT/bin/bercail" config set shep compact_at 250000 >/dev/null
  bash "$ROOT/bin/bercail" config set shep rollover true >/dev/null
  bash "$ROOT/bin/bercail" config set git '/Work/x y' entire >/dev/null
  bash "$ROOT/bin/bercail" config set routine.deps at 08:00 >/dev/null
  assert_eq true "$(bash "$ROOT/bin/bercail" config get shep rollover)" "a bool, bare"
  assert_eq entire "$(bash "$ROOT/bin/bercail" config get git '/Work/x y')" "a quoted key"
  assert_eq $'[routine.deps]\nat = "08:00"' "$(tail -n 2 "$cfg")" "a new table at the end"
  # A dry run prints the same diff, and writes nothing.
  out="$(bash "$ROOT/bin/bercail" config set --dry-run shep compact_at 1)"
  [[ "$out" == *$'\n-compact_at = 250000#no space\n+compact_at = 1#no space\n'* ]] || fail "dry run: $out"
  assert_eq 250000 "$(bash "$ROOT/bin/bercail" config get shep compact_at)" "the dry run wrote nothing"
  bash "$ROOT/bin/bercail" config unset routine.deps at >/dev/null
  bash "$ROOT/bin/bercail" config unset git '/Work/x y' >/dev/null
  bash "$ROOT/bin/bercail" config unset shep rollover >/dev/null
  bash "$ROOT/bin/bercail" config set bstack claude 'claude-bridge/claude-opus-5-5#high' >/dev/null
  bash "$ROOT/bin/bercail" config set layout review hunk >/dev/null
  diff "$BATS_TEST_TMPDIR/before" "$cfg" || fail "the file is not as it was"
  [[ -L "$cfg" && "$(stat -c %a "$real")" == 600 ]] || fail "the link or its mode changed"
  assert_eq "unchanged: $cfg -> $real" "$(bash "$ROOT/bin/bercail" config unset shep rollover)" "an unset key"
}

@test "bercail config set --expect writes only the edit its card showed, to the file it showed, and never over a change made since" {
  local out rc=0 links="$BATS_TEST_TMPDIR/links"
  # The hash a card's worker passes: of the lines a dry run adds and removes.
  card() { printf '%s' "$(bash "$ROOT/bin/bercail" config set shep rollover true --dry-run | grep '^[-+]')" | sha256sum | cut -c1-64; }
  apply() { rc=0; out="$(bash "$ROOT/bin/bercail" config set shep rollover true --expect "$1" 2>&1)" || rc=$?; }
  mkdir -p "$BERCAIL_CONFIG_DIR" "$links/a" "$links/b"
  printf '[shep]\nrollover = false\n' >"$links/a/config.toml"
  cp "$links/a/config.toml" "$links/b/config.toml"
  ln -s "$links/a" "$links/profile"
  ln -s "$links/profile/config.toml" "$BERCAIL_USER_CONFIG"
  hash="$(card)"
  # The person edits it, or switches the profile the link goes through: the card is stale.
  printf '[shep]\nrollover = false # the person\n' >"$links/a/config.toml"
  apply "$hash"
  [[ "$rc" -eq 1 && "$out" == *"changed since its card"*"nothing written"* ]] || fail "an edit: rc=$rc out=$out"
  hash="$(card)"
  ln -sfn "$links/b" "$links/profile"
  apply "$hash"
  [[ "$rc" -eq 1 && "$out" == *"changed since its card"* ]] || fail "a switched profile: rc=$rc out=$out"
  assert_eq $'[shep]\nrollover = false' "$(cat "$links/b/config.toml")" "a stale card wrote"
  apply "$(card)"
  [[ "$rc" -eq 0 && "$(cat "$links/b/config.toml")" == $'[shep]\nrollover = true' && -L "$BERCAIL_USER_CONFIG" ]] ||
    fail "the card's edit: rc=$rc out=$out"
  # --expect is the worker's, last; anywhere else it is no flag bercail takes.
  for args in "config --expect $hash set shep rollover true" "config set shep rollover true --expect $hash --dry-run" \
    "config set shep rollover true --expect nothex"; do
    rc=0
    read -r -a words <<<"$args"
    out="$(bash "$ROOT/bin/bercail" "${words[@]}" 2>&1)" || rc=$?
    [[ "$rc" -eq 1 && "$out" == *usage* ]] || fail "$args: rc=$rc out=$out"
  done
}

@test "bercail config set refuses a key bercail does not read, a table it cannot name, a multi-line value, an array or a key written twice" {
  local out rc
  mkdir -p "$BERCAIL_CONFIG_DIR"
  cp "$ROOT/tests/fixtures/config-hard.toml" "$BERCAIL_USER_CONFIG"
  printf '[tests]\nslots = 1\nslots = 2\n\n[routine.mine]\ncommand = ["x"]\n' >>"$BERCAIL_USER_CONFIG"
  cp "$BERCAIL_USER_CONFIG" "$BATS_TEST_TMPDIR/before"
  for args in "shep session 1|bercail reads no [shep] session" "a..b x 1|a..b is not a table name" \
    "policy push main|bercail reads no [policy] push" "routine.mine command x|[routine.mine] command is an array" \
    'policy."~/Work/a.b" rules x|[policy."~/Work/a.b"] rules is a multi-line value' "tests slots 3|appears twice"; do
    IFS=' ' read -r -a words <<<"${args%%|*}"
    rc=0
    out="$(bash "$ROOT/bin/bercail" config set "${words[@]}" 2>&1)" || rc=$?
    [[ "$rc" -eq 1 && "$out" == *"${args#*|}"* ]] || fail "${args%%|*}: rc=$rc out=$out"
  done
  diff "$BATS_TEST_TMPDIR/before" "$BERCAIL_USER_CONFIG" || fail "a refusal changed the file"
}

@test "a command bercail does not know prints the commands as bercail help lists them, each dispatched command among them" {
  local out help rc=0 cmd line
  out="$(bash "$ROOT/bin/bercail" nope 2>&1 >/dev/null)" || rc=$?
  [[ "$rc" -eq 1 ]] || fail "an unknown command exits 1, got $rc"
  help="$(bash "$ROOT/bin/bercail" help)"
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == Run* ]] || grep -qxF -- "$line" <<<"$help" || fail "not in bercail help: $line"
  done <<<"$out"
  while IFS= read -r cmd; do
    grep -q "^  $cmd " <<<"$out" || fail "bercail dispatches $cmd but the list leaves it out: $out"
  done < <(sed -n '/^main() {/,/^}/s/^    \([a-z-]*\))$/\1/p' "$ROOT/bin/bercail")
  [[ "$(grep -c . <<<"$out")" -gt 15 ]] || fail "the list is short: $out"
}

@test "doctor checks the Herdr app and herdr-core" {
  doctor_with_hunk_review
  assert_contains "$out" "ok  herdr-app" "doctor checks the Herdr app"
  assert_contains "$out" "ok  hc" "doctor checks herdr-core"
}

@test "ensure_tuicr_watch_config adds diff watch and keeps an existing theme" {
  mkdir -p "$XDG_CONFIG_HOME/tuicr"
  printf 'theme = "dark"\n' >"$XDG_CONFIG_HOME/tuicr/config.toml"
  ensure_tuicr_watch_config
  grep -q 'theme = "dark"' "$XDG_CONFIG_HOME/tuicr/config.toml" \
    || fail "ensure_tuicr_watch_config must keep an existing theme"
  grep -q 'diff_watch_interval_ms = 1000' "$XDG_CONFIG_HOME/tuicr/config.toml" \
    || fail "ensure_tuicr_watch_config should add diff watch to an existing config"
}
