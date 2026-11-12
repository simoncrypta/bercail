#!/usr/bin/env bats
# The first update to a new release starts as the previous release's bercail:
# its bin, its loaded libs, and its deploy_configs, which copies the new CLI and
# lib/ by its own lists. The new lib/config.sh then restarts the update on the
# new CLI. Install a real old release, then update it from this tree.

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
    sleep stat cut tee xargs ls cksum; do
    ln -s "$(command -v "$t")" "$TOOLS/$t" || fail "this test needs $t on PATH"
  done
  printf '#!/bin/sh\nexit 1\n' >"$TOOLS/curl"
  printf '#!/bin/sh\nexit 0\n' >"$TOOLS/tuicr"
  chmod +x "$TOOLS/curl" "$TOOLS/tuicr"

  new_version="$(sed -n 's/^AGENTIC_DEV_VERSION="${AGENTIC_DEV_VERSION:-\(.*\)}"$/\1/p' "$ROOT/lib/common.sh")"
  mapfile -t new_skills < <(sed -n 's/^AGENTIC_DEV_SKILL_IDS=(\(.*\))$/\1/p' "$ROOT/lib/common.sh" | tr ' ' '\n')
  ((${#new_skills[@]} > 1)) || fail "could not read AGENTIC_DEV_SKILL_IDS from lib/common.sh"
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

# A curl install has no tree to copy from: the old release's updater fetches
# each file it lists, by name, from the new release. The stand-in curl serves
# this tree's files as that release and fails on a name it does not ship.
update_from_curl() {
  local tag="$1" rc=0
  install_release "$tag"
  rm -f "$home/.local/share/bercail/source-path"
  this_tree "$box/new"
  cat >"$TOOLS/curl" <<EOF
#!/bin/sh
# Stand-in: -o DEST from $box/new for a raw.test URL; anything else fails.
url= dest=
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o) dest="\$2"; shift ;;
    https://raw.test/*) url="\${1#https://raw.test/}" ;;
  esac
  shift
done
[ -n "\$url" ] && [ -n "\$dest" ] && [ -f "$box/new/\$url" ] || { echo "\$url" >>"$box/curl-missing"; exit 22; }
cp "$box/new/\$url" "\$dest"
EOF
  in_home "$home" GITHUB_RAW_BASE=https://raw.test bash "$home/.local/bin/bercail" update >"$box/update.log" 2>&1 || rc=$?
  [[ "$rc" -eq 0 ]] || { tail -20 "$box/update.log"; fail "$tag's bercail update exited $rc; not served: $(cat "$box/curl-missing" 2>/dev/null)"; }
  if grep -E 'unbound variable|syntax error|command not found' "$box/update.log"; then
    fail "$tag's bercail update hit a shell error"
  fi
}

assert_this_tree() {
  local tag="$1" skill
  grep -qF "AGENTIC_DEV_VERSION:-$new_version}" "$home/.local/share/bercail/lib/common.sh" \
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
  printf '#!/bin/sh\necho "started: $* restarted=$BERCAIL_UPDATE_RESTARTED raw=$GITHUB_RAW_BASE"\n' >"$HOME/.local/bin/bercail"
  # shellcheck disable=SC2016
  ROOT="$ROOT" bash -c '
    source "$ROOT/lib/common.sh"
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

@test "a curl install of v0.14.0 updates to this tree: every file its updater fetches by name still ships" {
  need_tag v0.14.0
  update_from_curl v0.14.0
  assert_this_tree v0.14.0
}

@test "v0.14.0's updater hands the update to the new bercail once" {
  need_tag v0.14.0
  update_from v0.14.0
  [[ "$(restarts "$box/update.log")" == 1 ]] || fail "restarted $(restarts "$box/update.log") times: $(cat "$box/update.log")"
}

@test "an update that replaces the bercail running it runs the new one's steps" {
  install_release this
  printf '%s\n' "$box/src" >"$home/.local/share/bercail/source-path"
  # The next release: its update has a step this one's does not.
  sed -i 's/^  show_summary$/  show_summary; log "a step of the next release"/' "$box/src/bin/bercail"
  grep -q 'a step of the next release' "$box/src/bin/bercail" || fail "cmd_update has no show_summary line to extend"
  in_home "$home" bash "$home/.local/bin/bercail" update >"$box/update.log" 2>&1 \
    || { cat "$box/update.log"; fail "the update failed"; }
  grep -qx 'a step of the next release' "$box/update.log" \
    || fail "the update finished on the code it replaced: $(tail -5 "$box/update.log")"
  [[ "$(restarts "$box/update.log")" == 1 ]] || fail "restarted $(restarts "$box/update.log") times"
}

@test "lib/config.sh loaded by an updater's deploy_configs starts the installed bercail's update" {
  local out
  out="$(reload_config :)"
  grep -qx 'started: update restarted=1 raw=' <<<"$out" || fail "$out"
  if grep -q 'went on' <<<"$out"; then fail "the old code went on: $out"; fi
}

@test "a restarted update keeps --force and the release the first half read" {
  local out
  out="$(reload_config 'FORCE=1 GITHUB_RAW_BASE=https://raw.test/v9')"
  grep -qx 'started: update --force restarted=1 raw=https://raw.test/v9' <<<"$out" || fail "$out"
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
