#!/usr/bin/env bats
# The first update to a new release runs the previous release's bercail: its
# bin, its loaded libs, and its deploy_configs, which reloads only some of the
# new libs. Install a real old release, then update it from this tree.

setup() {
  load test_helper
  isolate
  # Only plain tools on PATH: no desktop, systemd, Herdr, Pi or network. curl
  # fails, and tuicr is present so nothing tries to install it.
  TOOLS="$BATS_TEST_TMPDIR/tools"
  mkdir -p "$TOOLS"
  local t
  for t in bash sh env cat cp mv rm ln mkdir chmod cmp diff dirname basename realpath readlink \
    find grep sed awk tr sort uniq head tail wc mktemp date git jq tar touch sha256sum id uname \
    sleep stat cut tee xargs ls; do
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

# Install release TAG into its own HOME, then update it from this tree. Sets home and box.
update_from() {
  local tag="$1" log rc=0
  box="$BATS_TEST_TMPDIR/$tag" home="$BATS_TEST_TMPDIR/$tag/home"
  mkdir -p "$box/src" "$home/run" "$home/.config/hypr"
  # A bindings file to patch, so Omarchy and plain hosts exit the same way.
  : >"$home/.config/hypr/bindings.conf"
  git -C "$ROOT" archive "$tag" | tar -x -C "$box/src"
  in_home "$home" INSTALL_SRC="$box/src" bash "$box/src/bin/bercail" update >"$box/install.log" 2>&1 \
    || { cat "$box/install.log"; fail "$tag could not install itself"; }
  # The old caller must pick up the new integration, not rewrite the input
  # method using the override this tree no longer ships (even off an Omarchy host).
  mkdir -p "$home/.local/share/omarchy" "$home/.config/fcitx5/conf"
  printf 'Hint Trigger=Control+Alt+h\nCustom=keep me\n' >"$box/keyboard.conf"
  cp "$box/keyboard.conf" "$home/.config/fcitx5/conf/keyboard.conf"
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

assert_this_tree() {
  local tag="$1" skill
  grep -qF "AGENTIC_DEV_VERSION:-$new_version}" "$home/.local/share/bercail/lib/common.sh" \
    || fail "$tag: the installed libs are not this tree's"
  cmp -s "$ROOT/bin/bercail" "$home/.local/bin/bercail" || fail "$tag: bin/bercail is not this tree's"
  [[ -x "$home/.local/bin/bercail" ]] || fail "$tag: bin/bercail is not executable"
  [[ -f "$home/.local/share/bercail/lib/desk.sh" ]] || fail "$tag: lib/desk.sh missing"
  [[ -f "$home/.local/share/bercail/pi-extensions/bercail-desk.ts" ]] \
    || fail "$tag: the Pi desk extension is missing"
  for skill in "${new_skills[@]}"; do
    [[ -f "$home/.agents/skills/$skill/SKILL.md" ]] || fail "$tag: skill $skill not deployed"
    [[ -L "$home/.pi/agent/skills/$skill" ]] || fail "$tag: Pi has no link for skill $skill"
  done
}

# The new CLI updating itself: the copy it runs from is detached too.
assert_updates_itself() {
  local tag="$1"
  in_home "$home" bash "$home/.local/bin/bercail" update >"$box/update-2.log" 2>&1 \
    || { cat "$box/update-2.log"; fail "$tag: a second bercail update failed"; }
  cmp -s "$ROOT/bin/bercail" "$home/.local/bin/bercail" || fail "$tag: the second update broke bin/bercail"
}

# v0.13.0's skills.sh has no PI_SKILLS_DIR and its deploy_skills unlinks Pi's skills.
@test "bercail v0.13.0 updates to this tree with the new libs, binary, and every Pi skill link" {
  need_tag v0.13.0
  update_from v0.13.0
  assert_this_tree v0.13.0
}

@test "after v0.13.0, the new bercail updates itself and keeps its binary" {
  need_tag v0.13.0
  update_from v0.13.0
  assert_updates_itself v0.13.0
}

@test "the latest release updates to this tree with the new libs, binary, and every Pi skill link" {
  local tag
  tag="$(latest_release)"
  [[ -n "$tag" && "$tag" != v0.13.0 ]] || skip "the latest release is v0.13.0, covered above"
  need_tag "$tag"
  update_from "$tag"
  assert_this_tree "$tag"
}

@test "after the latest release, the new bercail updates itself and keeps its binary" {
  local tag
  tag="$(latest_release)"
  [[ -n "$tag" && "$tag" != v0.13.0 ]] || skip "the latest release is v0.13.0, covered above"
  need_tag "$tag"
  update_from "$tag"
  assert_updates_itself "$tag"
}
