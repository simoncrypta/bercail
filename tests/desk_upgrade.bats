#!/usr/bin/env bats
# The first update from v0.14.0 starts as that release's bercail: its bin, its
# loaded libs, and its deploy_configs, which copies the new CLI and lib/ by its
# own lists. The new lib/config.sh then restarts the update on the new CLI, and
# that one runs the source tree's own bercail, as every later update does.
# Install a real old release, then update it from this tree.

setup() {
  load test_helper
  isolate
  # Only plain tools on PATH: no desktop, systemd, Herdr, Pi or network. curl
  # fails, and tuicr is present so nothing tries to install it.
  TOOLS="$BATS_TEST_TMPDIR/tools"
  mkdir -p "$TOOLS"
  local t
  for t in bash sh env cat cp mv rm rmdir ln mkdir chmod cmp diff dirname basename realpath readlink \
    find grep sed awk tr sort uniq head tail wc mktemp date git jq tar touch sha256sum id uname \
    sleep stat cut tee xargs ls cksum gzip timeout; do
    ln -s "$(command -v "$t")" "$TOOLS/$t" || fail "this test needs $t on PATH"
  done
  printf '#!/bin/sh\nexit 1\n' >"$TOOLS/curl"
  printf '#!/bin/sh\nexit 0\n' >"$TOOLS/tuicr"
  chmod +x "$TOOLS/curl" "$TOOLS/tuicr"

  new_version="$(sed -n 's/^BERCAIL_VERSION="\(.*\)"$/\1/p' "$ROOT/lib/common.sh")"
  [[ -n "$new_version" ]] || fail "could not read BERCAIL_VERSION from lib/common.sh"
  mapfile -t new_skills < <(sed -n 's/^BERCAIL_SKILL_IDS=(\(.*\))$/\1/p' "$ROOT/lib/common.sh" | tr ' ' '\n')
  ((${#new_skills[@]} > 1)) || fail "could not read BERCAIL_SKILL_IDS from lib/common.sh"
}

# The newest v* tag: the updater most users run next.
latest_release() {
  git -C "$ROOT" tag -l 'v*' --sort=-v:refname | head -1
}

need_tag() {
  git -C "$ROOT" rev-parse -q --verify "refs/tags/$1" >/dev/null \
    || fail "release tag $1 is missing: git -C $ROOT fetch --tags"
}

# in_home HOME CMD...: run with nothing from this shell's environment.
in_home() {
  local home="$1"
  shift
  env -i HOME="$home" XDG_CONFIG_HOME="$home/.config" XDG_RUNTIME_DIR="$home/run" \
    PATH="$TOOLS" TERM=dumb "$@" </dev/null
}

# What a release of this tree ships, into DIR: tracked and new files that exist on disk.
this_tree() {
  mkdir -p "$1"
  (cd "$ROOT" && git ls-files -co --exclude-standard \
    | while IFS= read -r f; do [[ -e "$f" ]] && printf '%s\0' "$f"; done \
    | tar --null -T - -cf -) | tar -x -C "$1"
}

# Install release TAG (or this tree, as "this") into its own HOME. Sets home and box.
install_release() {
  local tag="$1"
  box="$BATS_TEST_TMPDIR/$tag" home="$BATS_TEST_TMPDIR/$tag/home"
  mkdir -p "$box/src" "$home/run" "$home/.config/hypr"
  # A bindings file to patch, so Omarchy and plain hosts exit the same way.
  : >"$home/.config/hypr/bindings.conf"
  if [[ "$tag" == this ]]; then
    this_tree "$box/src"
  else
    git -C "$ROOT" archive "$tag" | tar -x -C "$box/src"
  fi
  in_home "$home" INSTALL_SRC="$box/src" bash "$box/src/bin/bercail" update >"$box/install.log" 2>&1 \
    || { cat "$box/install.log"; fail "$tag could not install itself"; }
}

restarts() {
  grep -c 'restarting the update on the new bercail' "$1" || true
}

# Install release TAG, then update it from this tree.
update_from() {
  local tag="$1" log rc=0
  install_release "$tag"
  # The old caller must not get as far as its own Omarchy step, which rewrites
  # the input method with an override this tree no longer ships.
  mkdir -p "$home/.local/share/omarchy" "$home/.config/fcitx5/conf"
  printf 'Hint Trigger=Control+Alt+h\nCustom=keep me\n' >"$box/keyboard.conf"
  cp "$box/keyboard.conf" "$home/.config/fcitx5/conf/keyboard.conf"
  # A handoff the old release logged, in the state dir it used.
  mkdir -p "$home/.local/state/agentic-dev"
  printf '{"ok":true,"path":"%s","branch":"","issue":"old-1"}\n' "$home" >"$home/.local/state/agentic-dev/handoffs.jsonl"
  case "${2:-}" in
    off) sed -i 's/^enabled = true$/enabled = false/' "$home/.config/bercail/config.toml" ;;
    no-bstack)
      printf '[layout]\nreview = "tuicr"\n' >"$home/.config/bercail/config.toml"
      rm -rf "$home/.local/share/bercail/pi"
      ;;
  esac
  # Names v1 no longer reads: a [graphite] entry and a sink's workspaces.
  printf '\n[graphite]\n"%s" = true\n' "$box/src" >>"$home/.config/bercail/config.toml"
  mkdir -p "$home/.config/bercail/notify.d"
  printf 'url = "https://example.invalid/hook"\nworkspaces = "old_*"\n' >"$home/.config/bercail/notify.d/old.toml"
  # A clone install: the old CLI updates from its recorded source.
  printf '%s\n' "$ROOT" >"$home/.local/share/bercail/source-path"
  log="$box/update.log"
  in_home "$home" bash "$home/.local/bin/bercail" update >"$log" 2>&1 || rc=$?
  [[ "$rc" -eq 0 ]] || { cat "$log"; fail "$tag's bercail update exited $rc"; }
  cmp -s "$box/keyboard.conf" "$home/.config/fcitx5/conf/keyboard.conf" \
    || fail "$tag's updater changed the input-method config"
  if grep -E 'unbound variable|syntax error|command not found' "$log"; then
    fail "$tag's bercail update hit a shell error"
  fi
}

# The stand-in curl serves $box/new as the new release: each file by name under
# raw.test, which is how v0.14.0's updater fetches, and the whole tree as
# raw.test/archive.tar.gz, which is how this one does. It logs what was asked
# for, and fails on a name the tree does not ship. A link is served as its
# target's path, as raw.githubusercontent.com does.
serve_new_release() {
  this_tree "$box/new"
  cat >"$TOOLS/curl" <<EOF
#!/bin/sh
url= dest=
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o) dest="\$2"; shift ;;
    https://raw.test/*) url="\${1#https://raw.test/}" ;;
  esac
  shift
done
echo "\$url" >>"$box/curl.log"
[ -n "\$url" ] && [ -n "\$dest" ] || exit 22
if [ "\$url" = archive.tar.gz ]; then
  [ ! -e "$box/no-archive" ] || exit 22
  tar -czf "\$dest" -C "$box" new
  exit
fi
[ -f "$box/new/\$url" ] || { echo "\$url" >>"$box/curl-missing"; exit 22; }
if [ -L "$box/new/\$url" ]; then readlink "$box/new/\$url" >"\$dest"; else cp "$box/new/\$url" "\$dest"; fi
EOF
}

# A curl install has no clone to copy from. v0.14.0's updater fetches each file
# it lists, by name, from the new release, then the new bercail takes over.
update_from_curl() {
  local tag="$1" rc=0
  install_release "$tag"
  rm -f "$home/.local/share/bercail/source-path"
  serve_new_release
  in_home "$home" GITHUB_RAW_BASE=https://raw.test BERCAIL_ARCHIVE_URL=https://raw.test/archive.tar.gz \
    bash "$home/.local/bin/bercail" update >"$box/update.log" 2>&1 || rc=$?
  [[ "$rc" -eq 0 ]] || { tail -20 "$box/update.log"; fail "$tag's bercail update exited $rc; not served: $(cat "$box/curl-missing" 2>/dev/null)"; }
  if grep -E 'unbound variable|syntax error|command not found' "$box/update.log"; then
    fail "$tag's bercail update hit a shell error"
  fi
}

assert_this_tree() {
  local tag="$1" skill
  grep -qx "BERCAIL_VERSION=\"$new_version\"" "$home/.local/share/bercail/lib/common.sh" \
    || fail "$tag: the installed libs are not this tree's"
  cmp -s "$ROOT/bin/bercail" "$home/.local/bin/bercail" || fail "$tag: bin/bercail is not this tree's"
  [[ -x "$home/.local/bin/bercail" ]] || fail "$tag: bin/bercail is not executable"
  [[ ! -e "$home/.local/bin/agentic-dev" ]] || fail "$tag: the agentic-dev command is still installed"
  [[ -f "$home/.local/share/bercail/lib/desk.sh" ]] || fail "$tag: lib/desk.sh missing"
  [[ -f "$home/.local/share/bercail/pi-extensions/bercail-desk.ts" ]] \
    || fail "$tag: the Pi desk extension is missing"
  for skill in "${new_skills[@]}"; do
    [[ -f "$home/.agents/skills/$skill/SKILL.md" ]] || fail "$tag: skill $skill not deployed"
    [[ -L "$home/.pi/agent/skills/$skill" ]] || fail "$tag: Pi has no link for skill $skill"
  done
}

# The new CLI updating itself: the copy it runs from is detached too, and an
# update that brings nothing new has nothing to restart on.
assert_updates_itself() {
  local tag="$1"
  in_home "$home" bash "$home/.local/bin/bercail" update >"$box/update-2.log" 2>&1 \
    || { cat "$box/update-2.log"; fail "$tag: a second bercail update failed"; }
  cmp -s "$ROOT/bin/bercail" "$home/.local/bin/bercail" || fail "$tag: the second update broke bin/bercail"
  [[ "$(restarts "$box/update-2.log")" == 0 ]] || fail "$tag: an update with nothing new restarted"
}

# Load lib/config.sh the way an updater's deploy_configs does, as CMD does it,
# with a stand-in for the installed bercail that prints how it was started.
reload_config() {
  mkdir -p "$HOME/.local/bin"
  printf '#!/bin/sh\necho "started: $* restarted=$BERCAIL_UPDATE_RESTARTED ref=$BERCAIL_REF"\n' >"$HOME/.local/bin/bercail"
  # shellcheck disable=SC2016
  ROOT="$ROOT" bash -c '
    source "$ROOT/lib/common.sh"
    deploy_install_file() { :; }
    deploy_configs() { source "$ROOT/lib/config.sh"; echo "went on with the old code"; }
    '"$1"'
    deploy_configs' 2>&1
}

# v0.14.0 is the oldest release that updates straight to this tree (docs/install.md).
@test "bercail v0.14.0 updates to this tree with the new libs, binary, and every Pi skill link" {
  need_tag v0.14.0
  update_from v0.14.0
  assert_this_tree v0.14.0
}

@test "the first update from v0.14.0 moves the handoff log to bercail's state dir" {
  need_tag v0.14.0
  update_from v0.14.0
  [[ "$(jq -r .issue "$home/.local/state/bercail/handoffs.jsonl")" == old-1 ]] \
    || fail "the handoff log did not move: $(ls -la "$home/.local/state")"
  [[ -L "$home/.local/state/agentic-dev" ]] || fail "the old state dir is not a link"
}

@test "the first update from v0.14.0 rewrites [graphite] and a sink's workspaces under their v1 names" {
  need_tag v0.14.0
  update_from v0.14.0
  grep -qxF "\"$box/src\" = \"gt\"" "$home/.config/bercail/config.toml" \
    || fail "the [graphite] entry did not move to [git]: $(cat "$home/.config/bercail/config.toml")"
  grep -qx 'spaces = "old_\*"' "$home/.config/bercail/notify.d/old.toml" \
    || fail "the sink still says workspaces: $(cat "$home/.config/bercail/notify.d/old.toml")"
}

# Offline Pi, with its bridge available; no account is needed to deploy the profile.
upgrade_pi() {
  cat >"$TOOLS/pi" <<'SH'
#!/bin/sh
case "$1" in
  --version) echo 1.5.2 ;;
  --offline) printf '%s\n' 'provider model context max-out thinking images' 'claude-bridge claude-opus-5-5 1M 128K yes yes' ;;
  auth) echo '{"status":"not_ready"}'; exit 1 ;;
  install) exit 0 ;;
esac
SH
  chmod +x "$TOOLS/pi"
}

@test "v0.14.0 with bstack disabled upgrades to the guarded lead and removes the switch" {
  need_tag v0.14.0
  upgrade_pi
  update_from v0.14.0 off
  [[ "$(grep -c 'not plain pi' "$box/update.log")" == 1 ]] || fail "the update did not explain the new lead once: $(cat "$box/update.log")"
  grep -q '^enabled' "$home/.config/bercail/config.toml" && fail "enabled was not removed"
  jq -e '.[0] == "pi" and any(.[]; contains("extensions/guard.ts"))' "$home/.local/share/bercail/pi/lead.json" \
    >/dev/null || fail "the guarded lead was not deployed"
  assert_updates_itself v0.14.0
  if grep -q 'not plain pi' "$box/update-2.log"; then fail "the second update repeated the warning"; fi
}

@test "v0.14.0 without a bstack section upgrades to the guarded lead and warns once" {
  need_tag v0.14.0
  upgrade_pi
  update_from v0.14.0 no-bstack
  [[ "$(grep -c 'not plain pi' "$box/update.log")" == 1 ]] || fail "the update did not explain the new lead once: $(cat "$box/update.log")"
  jq -e '.[0] == "pi" and any(.[]; contains("extensions/guard.ts"))' "$home/.local/share/bercail/pi/lead.json" \
    >/dev/null || fail "the guarded lead was not deployed"
  assert_updates_itself v0.14.0
  if grep -q 'not plain pi' "$box/update-2.log"; then fail "the second update repeated the warning"; fi
}

@test "a curl install of v0.14.0 updates to this tree: every file its updater fetches by name still ships" {
  need_tag v0.14.0
  update_from_curl v0.14.0
  assert_this_tree v0.14.0
  # The new bercail took the rest from the release's archive, not file by file.
  [[ "$(grep -cx archive.tar.gz "$box/curl.log")" == 1 ]] || fail "the archive was not fetched once: $(cat "$box/curl.log")"
  [[ "$(tail -1 "$box/curl.log")" == archive.tar.gz ]] || fail "files were fetched by name after the archive: $(cat "$box/curl.log")"
  cmp -s "$box/new/lib/review.sh" "$home/.local/share/bercail/release/lib/review.sh" \
    || fail "the release was not unpacked under ~/.local/share/bercail/release"
  [[ ! -e "$home/.local/share/bercail/source-path" ]] || fail "the release tree was recorded as a clone"
}

# v0.14.0 copies the new bin and libs by its own list, then the new bercail
# downloads the rest. When that download fails, the libs it left must still run.
@test "a curl install of v0.14.0 whose restarted update cannot download still runs bercail, desk restore, doctor and review-pr" {
  need_tag v0.14.0
  install_release v0.14.0
  rm -f "$home/.local/share/bercail/source-path"
  serve_new_release
  : >"$box/no-archive"
  if in_home "$home" GITHUB_RAW_BASE=https://raw.test BERCAIL_ARCHIVE_URL=https://raw.test/archive.tar.gz \
    bash "$home/.local/bin/bercail" update >"$box/update.log" 2>&1; then
    fail "an update with no download succeeded: $(tail -5 "$box/update.log")"
  fi
  grep -q 'could not download bercail from https://raw.test/archive.tar.gz' "$box/update.log" \
    || fail "the update did not fail on the download: $(tail -5 "$box/update.log")"
  grep -qx "BERCAIL_VERSION=\"$new_version\"" "$home/.local/share/bercail/lib/common.sh" \
    || fail "v0.14.0 did not copy the new libs"
  # No live terminals, as at boot before Herdr starts its desks.
  cat >"$TOOLS/hc" <<'SH'
#!/bin/sh
echo '{"terminals":[]}'
SH
  chmod +x "$TOOLS/hc"
  local cmd want
  for cmd in help "desk restore --dry-run" doctor review-pr; do
    case "$cmd" in
      help) want="bercail v$new_version" ;;
      review-pr) want='Usage: bercail review-pr <command>' ;;
      desk*) want='0 would come back' ;;
      # doctor's bstack check, which reads config.toml.
      doctor) want='  missing  pi (bercail bstack setup)' ;;
    esac
    # shellcheck disable=SC2086 # cmd is a command and its arguments
    in_home "$home" bash "$home/.local/bin/bercail" $cmd >"$box/cmd.log" 2>&1 || true
    grep -qxF "$want" "$box/cmd.log" || fail "bercail $cmd failed on the libs v0.14.0 left: $(tail -3 "$box/cmd.log")"
  done
  rm "$box/no-archive"
  in_home "$home" BERCAIL_ARCHIVE_URL=https://raw.test/archive.tar.gz bash "$home/.local/bin/bercail" update >"$box/update.log" 2>&1 \
    || { tail -20 "$box/update.log"; fail "the next update failed"; }
  assert_this_tree v0.14.0
}

@test "a curl install's update unpacks the next release and runs that tree's bercail; a failed download changes nothing" {
  install_release this
  rm -f "$home/.local/share/bercail/source-path"
  serve_new_release
  # The next release: its update has a step this one's does not, and a new lib file.
  sed -i 's/^  show_summary$/  show_summary; log "a step of the next release"/' "$box/new/bin/bercail"
  : >"$box/new/lib/next.sh"
  : >"$box/no-archive"
  if in_home "$home" BERCAIL_ARCHIVE_URL=https://raw.test/archive.tar.gz bash "$home/.local/bin/bercail" update >"$box/update.log" 2>&1; then
    fail "an update with no download succeeded: $(cat "$box/update.log")"
  fi
  grep -q 'could not download bercail from https://raw.test/archive.tar.gz' "$box/update.log" || fail "no word on the download: $(cat "$box/update.log")"
  cmp -s "$ROOT/bin/bercail" "$home/.local/bin/bercail" || fail "a failed download changed bin/bercail"
  [[ -z "$(find "$home/.local/share/bercail" -maxdepth 1 -name 'release*')" ]] || fail "a failed download left a tree behind"
  rm "$box/no-archive"
  in_home "$home" BERCAIL_ARCHIVE_URL=https://raw.test/archive.tar.gz bash "$home/.local/bin/bercail" update >"$box/update.log" 2>&1 \
    || { cat "$box/update.log"; fail "the update failed"; }
  grep -qx 'a step of the next release' "$box/update.log" \
    || fail "the update finished on the code it replaced: $(tail -5 "$box/update.log")"
  cmp -s "$box/new/bin/bercail" "$home/.local/bin/bercail" || fail "bin/bercail is not the next release's"
  [[ -f "$home/.local/share/bercail/lib/next.sh" ]] || fail "a lib file the next release added was not installed"
  [[ "$(restarts "$box/update.log")" == 0 ]] || fail "restarted $(restarts "$box/update.log") times"
  if grep -vx archive.tar.gz "$box/curl.log"; then fail "fetched more than the archive"; fi
  # Doctor compares against the unpacked release.
  printf 'stale\n' >>"$home/.config/worktrunk/herdr-layout.sh"
  in_home "$home" bash "$home/.local/bin/bercail" doctor >"$box/doctor.log" 2>&1 || true
  grep -q 'stale  herdr-layout.sh' "$box/doctor.log" || fail "doctor did not compare with the release: $(grep herdr-layout "$box/doctor.log")"
}

@test "v0.14.0's updater hands the update to the new bercail once" {
  need_tag v0.14.0
  update_from v0.14.0
  [[ "$(restarts "$box/update.log")" == 1 ]] || fail "restarted $(restarts "$box/update.log") times: $(cat "$box/update.log")"
}

@test "a curl install with HOME behind a symlink records no clone, so its update downloads the next release" {
  box="$BATS_TEST_TMPDIR/link" home="$BATS_TEST_TMPDIR/link/home"
  mkdir -p "$box/real/run" "$box/real/.config/hypr"
  : >"$box/real/.config/hypr/bindings.conf"
  ln -s "$box/real" "$home"
  serve_new_release
  env -i HOME="$home" XDG_CONFIG_HOME="$home/.config" XDG_RUNTIME_DIR="$home/run" PATH="$TOOLS" TERM=dumb \
    BERCAIL_ARCHIVE_URL=https://raw.test/archive.tar.gz bash -s -- --yes <"$box/new/install.sh" >"$box/install.log" 2>&1 \
    || { cat "$box/install.log"; fail "the piped install failed"; }
  [[ ! -e "$home/.local/share/bercail/source-path" ]] \
    || fail "the release was recorded as a clone: $(cat "$home/.local/share/bercail/source-path")"
  sed -i 's/^  show_summary$/  show_summary; log "a step of the next release"/' "$box/new/bin/bercail"
  in_home "$home" BERCAIL_ARCHIVE_URL=https://raw.test/archive.tar.gz bash "$home/.local/bin/bercail" update >"$box/update.log" 2>&1 \
    || { cat "$box/update.log"; fail "the update failed"; }
  grep -qx 'a step of the next release' "$box/update.log" || fail "the update did not run the next release: $(tail -5 "$box/update.log")"
  [[ "$(grep -cx archive.tar.gz "$box/curl.log")" == 2 ]] || fail "the update did not download: $(cat "$box/curl.log")"
}

@test "an update refuses an archive of v0.14.0 or of half a tree, and keeps the release it had" {
  need_tag v0.14.0
  install_release this
  rm -f "$home/.local/share/bercail/source-path"
  serve_new_release
  in_home "$home" BERCAIL_ARCHIVE_URL=https://raw.test/archive.tar.gz bash "$home/.local/bin/bercail" update >"$box/update.log" 2>&1 \
    || { cat "$box/update.log"; fail "the first update failed"; }
  local release="$home/.local/share/bercail/release" bad
  for bad in v0.14.0 half; do
    rm -rf "$box/new" && mkdir -p "$box/new"
    if [[ "$bad" == v0.14.0 ]]; then
      git -C "$ROOT" archive v0.14.0 | tar -x -C "$box/new"
    else
      # Passes a check for the files the update starts with, not a deploy.
      mkdir -p "$box/new/bin" "$box/new/lib"
      cp "$ROOT/install.sh" "$box/new/"; cp "$ROOT/bin/bercail" "$box/new/bin/"; cp "$ROOT/lib/common.sh" "$box/new/lib/"
    fi
    if in_home "$home" BERCAIL_ARCHIVE_URL=https://raw.test/archive.tar.gz bash "$home/.local/bin/bercail" update >"$box/update.log" 2>&1; then
      fail "an update to $bad succeeded: $(tail -5 "$box/update.log")"
    fi
    grep -q 'is not a bercail release that updates from an archive' "$box/update.log" || fail "$bad: no word on why: $(tail -3 "$box/update.log")"
    cmp -s "$ROOT/lib/review.sh" "$release/lib/review.sh" || fail "$bad replaced the release it had"
    cmp -s "$ROOT/bin/bercail" "$home/.local/bin/bercail" || fail "$bad changed the installed CLI"
    [[ ! -e "$home/.local/share/bercail/source-path" ]] || fail "$bad recorded a clone"
    [[ "$(find "$home/.local/share/bercail" -maxdepth 1 -name 'release*' | wc -l)" == 1 ]] || fail "$bad left a tree behind"
  done
}

@test "an update whose source tree's bin/bercail links to the running one runs once" {
  install_release this
  cp -a "$box/src" "$box/linked"
  ln -sf "$home/.local/bin/bercail" "$box/linked/bin/bercail"
  local rc=0
  in_home "$home" INSTALL_SRC="$box/linked" timeout 30 bash "$home/.local/bin/bercail" update >"$box/update.log" 2>&1 || rc=$?
  [[ "$rc" != 124 ]] || fail "the update execs itself over and over"
  [[ "$rc" == 0 ]] || { cat "$box/update.log"; fail "the update exited $rc"; }
}

@test "an update from a clone runs the clone's own bercail, so a step the next release adds runs" {
  install_release this
  printf '%s\n' "$box/src" >"$home/.local/share/bercail/source-path"
  # The next release: its update has a step this one's does not.
  sed -i 's/^  show_summary$/  show_summary; log "a step of the next release"/' "$box/src/bin/bercail"
  grep -q 'a step of the next release' "$box/src/bin/bercail" || fail "cmd_update has no show_summary line to extend"
  in_home "$home" bash "$home/.local/bin/bercail" update >"$box/update.log" 2>&1 \
    || { cat "$box/update.log"; fail "the update failed"; }
  grep -qx 'a step of the next release' "$box/update.log" \
    || fail "the update finished on the code it replaced: $(tail -5 "$box/update.log")"
  [[ "$(restarts "$box/update.log")" == 0 ]] || fail "restarted $(restarts "$box/update.log") times"
}

@test "lib/config.sh loaded by an updater's deploy_configs starts the installed bercail's update" {
  local out
  out="$(reload_config :)"
  grep -qx 'started: update restarted=1 ref=' <<<"$out" || fail "$out"
  if grep -q 'went on' <<<"$out"; then fail "the old code went on: $out"; fi
}

@test "a restarted update keeps --force and the release the first half read" {
  local out
  out="$(reload_config 'FORCE=1 GITHUB_RAW_BASE=https://raw.githubusercontent.com/simoncrypta/bercail/v9.9.0')"
  grep -qx 'started: update --force restarted=1 ref=v9.9.0' <<<"$out" || fail "$out"
}

@test "an update that was restarted does not restart again" {
  local out
  out="$(BERCAIL_UPDATE_RESTARTED=1 reload_config :)"
  grep -qx 'went on with the old code' <<<"$out" || fail "$out"
  if grep -q 'started:' <<<"$out"; then fail "restarted twice: $out"; fi
}

@test "after v0.14.0, the new bercail updates itself and keeps its binary" {
  need_tag v0.14.0
  update_from v0.14.0
  assert_updates_itself v0.14.0
}

@test "the latest release updates to this tree with the new libs, binary, and every Pi skill link" {
  local tag
  tag="$(latest_release)"
  [[ -n "$tag" && "$tag" != v0.14.0 ]] || skip "the latest release is v0.14.0, covered above"
  need_tag "$tag"
  update_from "$tag"
  assert_this_tree "$tag"
}

@test "after the latest release, the new bercail updates itself and keeps its binary" {
  local tag
  tag="$(latest_release)"
  [[ -n "$tag" && "$tag" != v0.14.0 ]] || skip "the latest release is v0.14.0, covered above"
  need_tag "$tag"
  update_from "$tag"
  assert_updates_itself "$tag"
}
