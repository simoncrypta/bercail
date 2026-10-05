#!/usr/bin/env bash
# shellcheck shell=bash
# mise (packslip: backend) and packslip install unpack the release archive and
# put a symlink to bin/bercail on PATH. bercail must follow that link to its
# lib/, and the installer must not copy a second bercail over it.
set -euo pipefail

unset BASH_ENV
export __MISE_BASH_ENV_LOADED=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

STAGE="$TMP_DIR/stage"
mkdir -p "$STAGE"
# Tracked and new files that exist on disk (a deleted tracked file is skipped).
(cd "$ROOT" && git ls-files -co --exclude-standard \
  | while IFS= read -r f; do [[ -e "$f" ]] && printf '%s\0' "$f"; done \
  | tar --null -T - -cf -) | tar -x -C "$STAGE"

run_bercail() {
  local home="$1"
  shift
  HOME="$home" PATH="$home/.local/bin:/usr/bin:/bin" \
    BERCAIL_LIB="" AGENTIC_DEV_LIB="" BERCAIL_PACKAGED="" \
    bercail "$@"
}

test_symlinked_bercail_finds_its_lib() {
  local home="$TMP_DIR/home-link" out
  mkdir -p "$home/.local/bin"
  : >"$STAGE/.bercail-package"
  ln -s "$STAGE/bin/bercail" "$home/.local/bin/bercail"
  out="$(run_bercail "$home" harness)"
  printf '%s' "$out" | jq -e '.ok == true' >/dev/null || fail "harness via symlink: $out"
  printf 'PASS: bercail behind a PATH symlink loads lib/ from the release tree\n'
}

test_packaged_dry_run_keeps_the_managed_command() {
  local home="$TMP_DIR/home-pkg" out
  mkdir -p "$home/.local/bin"
  : >"$STAGE/.bercail-package"
  ln -s "$STAGE/bin/bercail" "$home/.local/bin/bercail"
  # dry-run may exit nonzero on host-only warnings (Hyprland); read its plan.
  out="$(run_bercail "$home" dry-run 2>&1 || true)"
  printf '%s' "$out" | grep -q 'keeping bercail from mise/packslip' \
    || fail "packaged dry-run should keep the managed command: $out"
  printf '%s' "$out" | grep -qF "cp $STAGE/bin/bercail -> " \
    && fail "packaged dry-run must not copy bin/bercail: $out"
  [[ -L "$home/.local/bin/bercail" ]] || fail "dry-run replaced the link"
  printf 'PASS: packaged install does not copy bercail over the mise/packslip link\n'
}

test_unpackaged_tree_still_copies_bercail() {
  local home="$TMP_DIR/home-clone" out
  mkdir -p "$home/.local/bin"
  rm -f "$STAGE/.bercail-package"
  out="$(HOME="$home" PATH="/usr/bin:/bin" BERCAIL_LIB="" AGENTIC_DEV_LIB="" BERCAIL_PACKAGED="" \
    "$STAGE/bin/bercail" dry-run 2>&1 || true)"
  printf '%s' "$out" | grep -qF "cp $STAGE/bin/bercail -> $home/.local/bin/bercail" \
    || fail "a clone or curl install should still copy bercail: $out"
  printf 'PASS: clone and curl installs still copy bercail into ~/.local/bin\n'
}

test_install_command_needs_install_sh() {
  local home="$TMP_DIR/home-bare" bare="$TMP_DIR/bare" rc=0 err
  mkdir -p "$bare/bin" "$home"
  cp -R "$STAGE/lib" "$bare/lib"
  cp "$STAGE/bin/bercail" "$bare/bin/bercail"
  err="$(HOME="$home" PATH="/usr/bin:/bin" "$bare/bin/bercail" install 2>&1)" || rc=$?
  [[ "$rc" -eq 1 ]] || fail "install without install.sh should exit 1, got $rc"
  printf '%s' "$err" | grep -q 'setup.simoncrypta.dev/install.sh' \
    || fail "install without install.sh should point at curl: $err"
  printf 'PASS: bercail install without a release tree points at the curl installer\n'
}

test_symlinked_bercail_finds_its_lib
test_packaged_dry_run_keeps_the_managed_command
test_unpackaged_tree_still_copies_bercail
test_install_command_needs_install_sh
