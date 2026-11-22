#!/usr/bin/env bats
# install.sh --client MACHINE puts only the Herdr app half of bercail on a laptop
# whose bercail runs on MACHINE: the CLI, the layout, the mods, the keys and
# [herdr] backend. Later updates stay that way, and doctor checks the backend.

setup() {
  load test_helper
  isolate
  B="$BATS_TEST_TMPDIR/bin"
  LOG="$BATS_TEST_TMPDIR/calls.log"
  : >"$LOG"
  # herdr-app: check passes. hc exec --on box: what $BATS_TEST_TMPDIR/backend says,
  # the first line of `bercail help` there, or hc's error for an unknown machine.
  cat >"$B/herdr-app" <<'EOF'
#!/bin/sh
exit 0
EOF
  cat >"$B/hc" <<EOF
#!/bin/sh
printf 'hc %s\n' "\$*" >>"$LOG"
[ "\$1 \$2" = "exec --on" ] || exit 0
if [ "\$3" != box ]; then
  printf '{"error":{"code":"machine_unknown","message":"no machine named %s"}}\n' "\$3" >&2
  exit 1
fi
cat "$BATS_TEST_TMPDIR/backend" 2>/dev/null || exit 127
EOF
  # Nothing a full install would reach for: no network, no package manager.
  for cmd in mise curl sudo pi tuicr; do
    printf '#!/bin/sh\nprintf "%s %%s\\n" "$*" >>"%s"\nexit 1\n' "$cmd" "$LOG" >"$B/$cmd"
  done
  chmod +x "$B"/*
  export PATH="$B:/usr/bin:/bin"
  unset INSTALL_SRC BERCAIL_PACKAGED BERCAIL_LIB
  CONFIG="$HOME/.config/bercail/config.toml"
  APP="$HOME/.config/herdr-app"
  printf 'bercail v%s\n\nInstall ...\n' "$(sed -n 's/^BERCAIL_VERSION="\(.*\)"$/\1/p' "$ROOT/lib/common.sh")" >"$BATS_TEST_TMPDIR/backend"
}

client_install() {
  out="$(bash "$ROOT/install.sh" --yes --client box 2>&1)" || fail "install --client: $out"
}

# Only the Herdr app half and the CLI are here.
expect_client_only() {
  local what
  for what in layouts/bercail.json mods/bercail-desk/main.js mods/bercail-shep/main.js \
    mods/bercail-spaces/main.js mods/bercail-agents/main.js mods/bercail-review/main.js; do
    [[ -f "$APP/$what" ]] || fail "$1: no $what"
  done
  jq -e '.["layout:bercail"]["ctrl-shift-a"] == "bercail-desk.agent"' "$APP/keys.json" >/dev/null \
    || fail "$1: no layout:bercail keys"
  jq -e '.terminal["ctrl-shift-c"] == "terminal.copy" and .terminal["ctrl-shift-v"] == "terminal.paste"' \
    "$APP/keys.json" >/dev/null || fail "$1: no copy and paste keys: $(cat "$APP/keys.json")"
  [[ -x "$HOME/.local/bin/bercail" ]] || fail "$1: no bercail CLI"
  for what in .agents .pi .config/worktrunk .config/bercail/shell .config/herdr-core \
    .local/bin/bercail-desk-agent .local/share/bercail/pi .local/share/bercail/pi-extensions .bashrc .zshrc; do
    [[ ! -e "$HOME/$what" ]] || fail "$1 deployed ~/$what"
  done
  ! grep -qE '^(mise|curl|sudo|pi|tuicr) ' "$LOG" || fail "$1 reached for: $(cat "$LOG")"
}

@test "install --client deploys the CLI, layout, mods, keys and backend only" {
  client_install
  expect_client_only "install --client"
  [[ "$(cat "$CONFIG")" == $'[herdr]\nbackend = "box"' ]] || fail "config.toml: $(cat "$CONFIG")"
  [[ "$(cat "$HOME/.local/share/bercail/install-mode")" == client ]] || fail "mode not recorded"
}

@test "bercail update on a client stays client-only and keeps its backend" {
  client_install
  out="$("$HOME/.local/bin/bercail" update 2>&1)" || fail "update: $out"
  grep -q 'bercail client installed' <<<"$out" || fail "not the client update: $out"
  expect_client_only "update"
  grep -qx 'backend = "box"' "$CONFIG" || fail "backend lost: $(cat "$CONFIG")"
}

@test "bercail update gives a client's keys.json from an earlier bercail its copy and paste keys" {
  client_install
  jq 'del(.terminal)' "$APP/keys.json" >"$BATS_TEST_TMPDIR/k" && mv "$BATS_TEST_TMPDIR/k" "$APP/keys.json"
  jq 'del(.terminal)' "$ROOT/bercail/keys.json" >"$HOME/.local/share/bercail/herdr-app/keys.json"
  out="$("$HOME/.local/bin/bercail" update 2>&1)" || fail "update: $out"
  expect_client_only "update"
}

@test "a plain install over a client stays client-only" {
  client_install
  out="$(bash "$ROOT/install.sh" --yes 2>&1)" || fail "install: $out"
  expect_client_only "a plain install"
}

@test "dry-run on a client plans the client half only" {
  client_install
  out="$("$HOME/.local/bin/bercail" dry-run 2>&1)" || fail "dry-run: $out"
  grep -q 'would record a client install' <<<"$out" || fail "no client plan: $out"
  ! grep -qE '\.agents/skills|worktrunk|bercail-desk-agent' <<<"$out" || fail "dry-run plans the full install: $out"
}

@test "install --client sets the backend in an existing config and keeps the rest" {
  mkdir -p "${CONFIG%/*}"
  printf '[layout]\nreview = "tuicr"\n\n[herdr]\n# where bercail runs\nbackend = "old"\nother = 1\n' >"$CONFIG"
  client_install
  [[ "$(cat "$CONFIG")" == $'[layout]\nreview = "tuicr"\n\n[herdr]\nbackend = "box"\n# where bercail runs\nother = 1' ]] \
    || fail "config.toml: $(cat "$CONFIG")"
}

@test "install --client leaves a config it cannot follow as it is, and stops" {
  mkdir -p "${CONFIG%/*}"
  printf '[policy."~/r"]\nrules = """\n[herdr]\n"""\n' >"$CONFIG"
  cp "$CONFIG" "$BATS_TEST_TMPDIR/before"
  run bash "$ROOT/install.sh" --yes --client box
  [[ "$status" -ne 0 ]] || fail "went on: $output"
  grep -q 'set backend = "box" under \[herdr\] by hand' <<<"$output" || fail "no way out: $output"
  cmp -s "$CONFIG" "$BATS_TEST_TMPDIR/before" || fail "config.toml changed: $(cat "$CONFIG")"
  [[ ! -e "$HOME/.local/share/bercail/install-mode" ]] || fail "recorded a client"
}

@test "install --client refuses a name that is no machine name, and writes nothing" {
  run bash "$ROOT/install.sh" --yes --client 'box"; rm -rf ~'
  [[ "$status" -ne 0 ]] || fail "accepted: $output"
  grep -q 'not a machine name' <<<"$output" || fail "no reason: $output"
  [[ ! -e "$HOME/.config" && ! -e "$HOME/.local" ]] || fail "wrote files: $(find "$HOME" -mindepth 1)"
}

@test "doctor on a client checks the Herdr app half and the backend, and nothing else" {
  client_install
  out="$("$HOME/.local/bin/bercail" doctor 2>&1)" || fail "doctor: $out"
  grep -q 'ok  backend box runs bercail v' <<<"$out" || fail "no backend check: $out"
  grep -q 'ok  Herdr layout bercail' <<<"$out" || fail "no layout check: $out"
  [[ "$(grep -E '^[A-Z][a-z ]+:$' <<<"$out")" == $'Dependencies:\nHerdr app:\nBackend:' ]] \
    || fail "checks more than the client half: $out"
  ! grep -qE '^  [a-z]+  (pi|wt|bd|fzf|git|tuicr) ' <<<"$out" || fail "checks the backend's tools: $out"
}

@test "doctor on a client reads the version past what a login shell prints" {
  client_install
  { printf 'Welcome to box\nbercail v9 is not a version line\n'; cat "$BATS_TEST_TMPDIR/backend"; } >"$BATS_TEST_TMPDIR/b2"
  mv "$BATS_TEST_TMPDIR/b2" "$BATS_TEST_TMPDIR/backend"
  out="$("$HOME/.local/bin/bercail" doctor 2>&1)" || fail "doctor: $out"
  grep -q 'ok  backend box runs bercail v' <<<"$out" || fail "no backend check: $out"
}

@test "doctor on a client fails on a backend with another bercail version" {
  client_install
  printf 'bercail v0.1.0\n' >"$BATS_TEST_TMPDIR/backend"
  run "$HOME/.local/bin/bercail" doctor
  [[ "$status" -ne 0 ]] || fail "passed: $output"
  grep -q 'outdated  bercail on box is v0.1.0' <<<"$output" || fail "no mismatch: $output"
}

@test "doctor on a client names hc's error for a backend it cannot reach" {
  client_install
  sed -i 's/^backend = .*/backend = "gone"/' "$CONFIG"
  run "$HOME/.local/bin/bercail" doctor
  [[ "$status" -ne 0 ]] || fail "passed: $output"
  grep -q 'unreachable  backend gone: no machine named gone' <<<"$output" || fail "no reason: $output"
}

@test "doctor on a client says when the backend has no bercail" {
  client_install
  rm "$BATS_TEST_TMPDIR/backend"
  run "$HOME/.local/bin/bercail" doctor
  [[ "$status" -ne 0 ]] || fail "passed: $output"
  grep -q 'missing  bercail on box (exit 127' <<<"$output" || fail "no reason: $output"
}

@test "reconfigure on a client refuses and names the backend's" {
  client_install
  run "$HOME/.local/bin/bercail" reconfigure
  [[ "$status" -ne 0 ]] || fail "reconfigured: $output"
  grep -q 'run bercail reconfigure there' <<<"$output" || fail "no reason: $output"
  [[ ! -e "$HOME/.agents" ]] || fail "deployed skills"
}

@test "bercail install --client from a mise/packslip release keeps that tool's bercail link" {
  local stage="$BATS_TEST_TMPDIR/stage"
  mkdir -p "$stage" "$HOME/.local/bin"
  (cd "$ROOT" && git ls-files -co --exclude-standard \
    | while IFS= read -r f; do [[ -e "$f" ]] && printf '%s\0' "$f"; done \
    | tar --null -T - -cf -) | tar -x -C "$stage"
  : >"$stage/.bercail-package"
  ln -s "$stage/bin/bercail" "$HOME/.local/bin/bercail"
  out="$("$HOME/.local/bin/bercail" install --yes --client box 2>&1)" || fail "install --client: $out"
  [[ "$(readlink "$HOME/.local/bin/bercail")" == "$stage/bin/bercail" ]] || fail "replaced the link: $out"
  grep -q 'keeping bercail from mise/packslip' <<<"$out" || fail "did not say so: $out"
  [[ "$(cat "$HOME/.local/share/bercail/install-mode")" == client ]] || fail "mode not recorded"
}
