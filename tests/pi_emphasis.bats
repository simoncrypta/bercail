#!/usr/bin/env bats
# pi-emphasis, vendored at a commit (bstack/pi/extensions/pi-emphasis/UPSTREAM.md).
# The unit half checks the copy against its record. The live half installs bercail
# into a throwaway HOME, fresh and as an update from v0.17.4 (the last release
# without it), runs the deployed lead on the installed Pi in a terminal
# (tests/pi_emphasis_live.ts), and uninstalls. Deploy, doctor and each role's argv
# are in tests/bstack.bats.

setup() {
  load test_helper
  isolate
  VENDOR="$ROOT/bstack/pi/extensions/pi-emphasis"
}

@test "the vendored pi-emphasis is the commit lib/deps.json and UPSTREAM.md record, byte for byte" {
  local known sum
  known="$(jq -r '.[] | select(.name == "pi-emphasis") | .known' "$ROOT/lib/deps.json")"
  [[ "$known" =~ ^[0-9a-f]{40}$ ]] || fail "lib/deps.json knows no pi-emphasis commit: $known"
  grep -q "^- Commit: $known " "$VENDOR/UPSTREAM.md" || fail "UPSTREAM.md names another commit than lib/deps.json ($known)"
  sum="$(sed -n 's/^- index.ts sha256: //p' "$VENDOR/UPSTREAM.md")"
  [[ "$(sha256sum "$VENDOR/index.ts" | cut -d' ' -f1)" == "$sum" ]] \
    || fail "index.ts is not the copy UPSTREAM.md records (sha256 $sum); copy upstream's in whole"
  grep -q '^MIT License$' "$VENDOR/LICENSE" && grep -q 'Copyright (c) 2026 John Lindquist' "$VENDOR/LICENSE" \
    || fail "the license must ship with the copy"
}

@test "the vendored pi-emphasis imports only Pi's types, fetches nothing and binds no key" {
  local imports
  imports="$(grep -E '^[[:space:]]*import\b' "$VENDOR/index.ts")"
  [[ "$imports" == 'import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";' ]] \
    || fail "a new commit imports more than Pi's types; read it before shipping: $imports"
  if grep -nE '\bfetch\(|require\(|import\(|registerShortcut|registerCommand|registerTool' "$VENDOR/index.ts"; then
    fail "a new commit fetches, loads code, or adds a key, command or tool: check it against bercail's extensions"
  fi
}

# in_home HOME CMD...: run with only plain tools, the stand-in pi, and nothing from this shell.
in_home() {
  local home="$1"
  shift
  env -i HOME="$home" XDG_CONFIG_HOME="$home/.config" XDG_RUNTIME_DIR="$home/run" \
    PATH="$TOOLS" TERM=dumb REAL_PI_VERSION="$PI_VERSION" "$@" </dev/null
}

# What a release of this tree ships, into DIR: tracked and new files that exist on disk.
this_tree() {
  mkdir -p "$1"
  (cd "$ROOT" && git ls-files -co --exclude-standard \
    | while IFS= read -r f; do [[ -e "$f" ]] && printf '%s\0' "$f"; done \
    | tar --null -T - -cf -) | tar -x -C "$1"
}

# bats test_tags=live
@test "live: a fresh install and an update from v0.17.4 both load pi-emphasis on the installed Pi" {
  # The last release before pi-emphasis: the update leg proves an install without it gets it.
  local pi tag=v0.17.4 home src log
  pi="$(real_pi)"
  [[ -n "$pi" ]] || skip "Pi not found; live proof not run"
  need node
  command -v script >/dev/null 2>&1 || fail "script (util-linux) is required for the live proof"
  PI_VERSION="$("$pi" --version)"
  pi_at_least "$PI_VERSION" 1.5 || skip "Pi $PI_VERSION is older than 1.5; live proof not run"
  git -C "$ROOT" rev-parse -q --verify "refs/tags/$tag" >/dev/null || fail "release tag $tag is missing: git -C $ROOT fetch --tags"

  # The install's own tools. curl fails, so nothing is fetched; tuicr is there so
  # nothing installs it. pi stands in for the deploy only: the real version, a
  # catalog with the bridge, no login, and an install that fetches nothing.
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
  cat >"$TOOLS/pi" <<'SH'
#!/usr/bin/env bash
case "$1" in
  --version) echo "$REAL_PI_VERSION" ;;
  --offline) printf 'provider model context max-out thinking images\nclaude-bridge claude-opus-5-5 1M 128K yes yes\n' ;;
  install) exit 0 ;;
  auth) printf '{"status":"not_ready"}\n'; exit 1 ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$TOOLS/curl" "$TOOLS/tuicr" "$TOOLS/pi"
  src="$BATS_TEST_TMPDIR/this"
  this_tree "$src"

  # A fresh install: this tree's installer into an empty HOME.
  home="$BATS_TEST_TMPDIR/fresh"
  mkdir -p "$home/run" "$home/.config/hypr"
  : >"$home/.config/hypr/bindings.conf"
  log="$BATS_TEST_TMPDIR/fresh.log"
  in_home "$home" bash "$src/install.sh" --yes >"$log" 2>&1 || { cat "$log"; fail "fresh install"; }
  node "$ROOT/tests/pi_emphasis_live.ts" "$ROOT" "$pi" "$home" || fail "fresh install: pi-emphasis did not load"

  # An update: the last release installs itself, then its bercail updates from this tree.
  home="$BATS_TEST_TMPDIR/update"
  mkdir -p "$home/run" "$home/.config/hypr" "$BATS_TEST_TMPDIR/old"
  : >"$home/.config/hypr/bindings.conf"
  git -C "$ROOT" archive "$tag" | tar -x -C "$BATS_TEST_TMPDIR/old"
  log="$BATS_TEST_TMPDIR/old.log"
  in_home "$home" INSTALL_SRC="$BATS_TEST_TMPDIR/old" bash "$BATS_TEST_TMPDIR/old/bin/bercail" update >"$log" 2>&1 \
    || { cat "$log"; fail "$tag could not install itself"; }
  [[ -f "$home/.local/share/bercail/pi/lead.json" ]] || { cat "$log"; fail "$tag deployed no lead"; }
  if grep -q pi-emphasis "$home/.local/share/bercail/pi/lead.json"; then
    fail "$tag already loads pi-emphasis: this is no update proof"
  fi
  printf '%s\n' "$src" >"$home/.local/share/bercail/source-path"
  log="$BATS_TEST_TMPDIR/update.log"
  in_home "$home" bash "$home/.local/bin/bercail" update >"$log" 2>&1 || { cat "$log"; fail "update from $tag"; }
  node "$ROOT/tests/pi_emphasis_live.ts" "$ROOT" "$pi" "$home" || fail "update from $tag: pi-emphasis did not load"

  # Uninstall, answering yes to each question, takes it with bstack's profile and
  # templates. setsid: no controlling terminal, so the answers come from stdin.
  log="$BATS_TEST_TMPDIR/uninstall.log"
  yes y | setsid -w env -i HOME="$home" XDG_CONFIG_HOME="$home/.config" XDG_RUNTIME_DIR="$home/run" PATH="$TOOLS" TERM=dumb \
    bash "$home/.local/bin/bercail" uninstall >"$log" 2>&1 || { cat "$log"; fail "uninstall"; }
  [[ ! -e "$home/.local/share/bercail/pi/extensions/pi-emphasis" ]] || fail "uninstall left pi-emphasis"
  if grep -rqs pi-emphasis "$home/.config/herdr-core/templates"; then
    fail "uninstall left a role template that loads pi-emphasis"
  fi
}
