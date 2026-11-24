#!/usr/bin/env bats
# install.sh --client MACHINE puts only the Herdr app half of bercail on a laptop
# whose bercail runs on MACHINE: the CLI, the layout, the mods, the keys and
# [herdr] backend. Later updates stay that way, and doctor checks the backend.

# This checkout's files, committed and tagged as this version's release: the
# upstream each test clones. Built once; tests clone it, never change it.
setup_file() {
  load test_helper
  local seed="$BATS_FILE_TMPDIR/seed" version
  version="$(sed -n 's/^BERCAIL_VERSION="\(.*\)"$/\1/p' "$ROOT/lib/common.sh")"
  mkdir -p "$seed"
  (cd "$ROOT" && git ls-files -co --exclude-standard \
    | while IFS= read -r f; do [[ -e "$f" ]] && printf '%s\0' "$f"; done \
    | tar --null -T - -cf -) | tar -x -C "$seed"
  git -C "$seed" init -q -b master
  git -C "$seed" add -A
  git -C "$seed" -c user.email=test@example.com -c user.name=test commit -qm "release: v$version"
  git -C "$seed" tag "v$version"
  git clone -q --bare "$seed" "$BATS_FILE_TMPDIR/seed.git"
}

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

# A client installed from a clone at $CLONE (~/Work/bercail), on the tag github.com names
# as the latest release. $UP answers for github.com/simoncrypta/bercail, so the
# clone's origin and the upstream update checks are the same repo until a test
# says otherwise.
clone_install() {
  UP="$BATS_TEST_TMPDIR/upstream.git" CLONE="${CLONE:-$HOME/Work/bercail}"
  VERSION="$(sed -n 's/^BERCAIL_VERSION="\(.*\)"$/\1/p' "$ROOT/lib/common.sh")"
  git clone -q --bare "$BATS_FILE_TMPDIR/seed.git" "$UP"
  export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
  git config --global url."$UP".insteadOf https://github.com/simoncrypta/bercail
  git config --global user.email test@example.com
  git config --global user.name test
  git clone -q https://github.com/simoncrypta/bercail "$CLONE"
  git -C "$CLONE" switch -q --detach "v$VERSION"
  printf 'v%s\n' "$VERSION" >"$BATS_TEST_TMPDIR/latest"
  # github.com's /releases/latest redirect, to the tag in $BATS_TEST_TMPDIR/latest.
  cat >"$B/curl" <<EOF
#!/bin/sh
case "\$*" in
  *simoncrypta/bercail/releases/latest*)
    [ -f "$BATS_TEST_TMPDIR/latest" ] || exit 22
    printf 'https://github.com/simoncrypta/bercail/releases/tag/%s' "\$(cat "$BATS_TEST_TMPDIR/latest")" ;;
  *) printf 'curl %s\n' "\$*" >>"$LOG"; exit 1 ;;
esac
EOF
  chmod +x "$B/curl"
  out="$(bash "$CLONE/install.sh" --yes --client box 2>&1)" || fail "install --client: $out"
  # A line no deploy writes: still here after an update means nothing was redeployed.
  printf '# not redeployed\n' >>"$HOME/.local/share/bercail/lib/common.sh"
}

# Upstream cuts release $1, a commit past the one the clone sits on.
upstream_release() {
  local work="$BATS_TEST_TMPDIR/up-work"
  git clone -q "$UP" "$work"
  git -C "$work" commit -q --allow-empty -m "release: $1"
  git -C "$work" tag "$1"
  git -C "$work" push -q origin HEAD:master "$1"
  printf '%s\n' "$1" >"$BATS_TEST_TMPDIR/latest"
}

redeployed() {
  ! grep -q '^# not redeployed$' "$HOME/.local/share/bercail/lib/common.sh"
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
  jq -e '.terminal["ctrl-shift-c"] == "terminal.copy" and .terminal["ctrl-shift-v"] == "terminal.paste"
      and ([.global[]] | index("tab.new") and index("layout.switch"))' \
    "$APP/keys.json" >/dev/null || fail "$1: no Herdr default keys: $(cat "$APP/keys.json")"
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
  clone_install
  out="$("$HOME/.local/bin/bercail" update 2>&1)" || fail "update: $out"
  grep -q "bercail client updated (v$VERSION)" <<<"$out" || fail "not the client update: $out"
  redeployed || fail "did not redeploy: $out"
  expect_client_only "update"
  grep -qx 'backend = "box"' "$CONFIG" || fail "backend lost: $(cat "$CONFIG")"
}

@test "bercail update gives a client's keys.json from an earlier bercail Herdr's default keys" {
  clone_install
  jq 'del(.terminal, .global)' "$APP/keys.json" >"$BATS_TEST_TMPDIR/k" && mv "$BATS_TEST_TMPDIR/k" "$APP/keys.json"
  jq 'del(.terminal)' "$ROOT/bercail/keys.json" >"$HOME/.local/share/bercail/herdr-app/keys.json"
  out="$("$HOME/.local/bin/bercail" update 2>&1)" || fail "update: $out"
  expect_client_only "update"
}

@test "update on a client refuses a clone behind the latest release, and names the checkout" {
  clone_install
  upstream_release v99.0.0
  run "$HOME/.local/bin/bercail" update
  [[ "$status" -ne 0 ]] || fail "updated a stale clone: $output"
  ! redeployed || fail "redeployed the stale clone: $output"
  grep -q "$CLONE is at v$VERSION, not bercail v99.0.0" <<<"$output" || fail "no reason: $output"
  grep -qF "git -C $CLONE fetch --no-tags https://github.com/simoncrypta/bercail refs/tags/v99.0.0 && git -C $CLONE switch --detach FETCH_HEAD" <<<"$output" \
    || fail "no checkout command: $output"
}

@test "update on a client deploys once the checkout it printed has run, from a path with a space" {
  CLONE="$HOME/Work/my bercail"
  clone_install
  upstream_release v99.0.0
  run "$HOME/.local/bin/bercail" update
  [[ "$status" -ne 0 ]] || fail "updated a stale clone: $output"
  checkout="$(sed -n 's/^  \(git -C .*\)$/\1/p' <<<"$output")"
  [[ -n "$checkout" ]] || fail "no checkout command: $output"
  eval "$checkout" || fail "the printed command failed: $checkout"
  out="$("$HOME/.local/bin/bercail" update 2>&1)" || fail "update: $out"
  redeployed || fail "did not redeploy: $out"
}

@test "update on a client checks the clone against upstream's tag, not a local one" {
  clone_install
  upstream_release v99.0.0
  git -C "$CLONE" commit -q --allow-empty -m "not the release"
  git -C "$CLONE" tag v99.0.0
  run "$HOME/.local/bin/bercail" update
  [[ "$status" -ne 0 ]] || fail "took the local tag: $output"
  ! redeployed || fail "redeployed: $output"
}

@test "update on a client refuses a clone on the release with changes in it" {
  clone_install
  git -C "$CLONE" config status.showUntrackedFiles no
  printf 'local\n' >"$CLONE/untracked.txt"
  run "$HOME/.local/bin/bercail" update
  [[ "$status" -ne 0 ]] || fail "updated a changed clone: $output"
  ! redeployed || fail "redeployed: $output"
  grep -q "$CLONE is on v$VERSION but has changes" <<<"$output" || fail "no reason: $output"
}

@test "update on a client that cannot find the latest release says so, and deploys nothing" {
  clone_install
  rm "$BATS_TEST_TMPDIR/latest"
  run "$HOME/.local/bin/bercail" update
  [[ "$status" -ne 0 ]] || fail "updated unchecked: $output"
  ! redeployed || fail "redeployed: $output"
  grep -q 'cannot find the latest bercail release on github.com' <<<"$output" || fail "no reason: $output"
  grep -q 'BERCAIL_REF=HEAD' <<<"$output" || fail "no way through: $output"
}

@test "update on a client refuses a BERCAIL_REF that is no tag upstream, even a branch the clone sits on" {
  clone_install
  run env BERCAIL_REF=master "$HOME/.local/bin/bercail" update
  [[ "$status" -ne 0 ]] || fail "updated: $output"
  ! redeployed || fail "redeployed: $output"
  grep -q 'cannot fetch the tag master from https://github.com/simoncrypta/bercail' <<<"$output" || fail "no reason: $output"
}

@test "BERCAIL_REF pins a client's clone to a release other than the latest" {
  clone_install
  upstream_release v99.0.0
  out="$(BERCAIL_REF="v$VERSION" "$HOME/.local/bin/bercail" update 2>&1)" || fail "update: $out"
  redeployed || fail "did not redeploy: $out"
}

@test "BERCAIL_REF=HEAD deploys a client's clone as it sits, as a dev build" {
  clone_install
  upstream_release v99.0.0
  printf 'local\n' >"$CLONE/untracked.txt"
  out="$(BERCAIL_REF=HEAD "$HOME/.local/bin/bercail" update 2>&1)" || fail "update: $out"
  redeployed || fail "did not redeploy: $out"
  grep -q "deploying $CLONE as it sits (v$VERSION, with changes): a dev build" <<<"$out" || fail "no warning: $out"
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
  grep -q 'outdated  bercail on box is v0.1.0, this computer.s is v.* (run bercail update on box)' <<<"$output" \
    || fail "no mismatch: $output"
}

@test "doctor on a client names no older side for a version it cannot order" {
  client_install
  printf 'bercail v%s-rc.1\n' "$(sed -n 's/^BERCAIL_VERSION="\(.*\)"$/\1/p' "$ROOT/lib/common.sh")" >"$BATS_TEST_TMPDIR/backend"
  run "$HOME/.local/bin/bercail" doctor
  [[ "$status" -ne 0 ]] || fail "passed: $output"
  grep -q '(run bercail update on the older one)' <<<"$output" || fail "guessed a side: $output"
}

@test "doctor on a client behind its backend says to update here, and what update checks a clone against" {
  clone_install
  printf 'bercail v99.0.0\n' >"$BATS_TEST_TMPDIR/backend"
  run "$HOME/.local/bin/bercail" doctor
  [[ "$status" -ne 0 ]] || fail "passed: $output"
  grep -qF "(run bercail update here: it checks $CLONE against the latest release and names the checkout)" <<<"$output" \
    || fail "no advice: $output"
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
