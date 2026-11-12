#!/usr/bin/env bats
# mise (packslip: backend) and packslip install unpack the release archive and
# put a symlink to bin/bercail on PATH. bercail must follow that link to its
# lib/, and the installer must not copy a second bercail over it.

setup() {
  load test_helper
  isolate
  STAGE="$BATS_TEST_TMPDIR/stage"
  mkdir -p "$STAGE"
  # Tracked and new files that exist on disk (a deleted tracked file is skipped).
  (cd "$ROOT" && git ls-files -co --exclude-standard \
    | while IFS= read -r f; do [[ -e "$f" ]] && printf '%s\0' "$f"; done \
    | tar --null -T - -cf -) | tar -x -C "$STAGE"
}

run_bercail() {
  local home="$1"
  shift
  HOME="$home" PATH="$home/.local/bin:/usr/bin:/bin" \
    BERCAIL_LIB="" AGENTIC_DEV_LIB="" BERCAIL_PACKAGED="" \
    bercail "$@"
}

# install.sh sources lib/ from its tree, and a curl install fetches its list
# from GitHub first. Each lib it names must ship.
@test "install.sh sources and fetches only libs that ship" {
  local lib out
  out="$(HOME="$BATS_TEST_TMPDIR/home-help" PATH="/usr/bin:/bin" bash "$STAGE/install.sh" --help 2>&1)" \
    || fail "install.sh --help from a release tree: $out"
  for lib in $(sed -n 's/^  for lib in \(.*\); do$/\1/p' "$STAGE/install.sh"); do
    [[ -f "$STAGE/lib/$lib.sh" ]] || fail "install.sh fetches lib/$lib.sh, which does not ship"
  done
}

@test "bercail behind a PATH symlink loads lib/ from the release tree" {
  local home="$BATS_TEST_TMPDIR/home-link" out
  mkdir -p "$home/.local/bin"
  : >"$STAGE/.bercail-package"
  ln -s "$STAGE/bin/bercail" "$home/.local/bin/bercail"
  out="$(run_bercail "$home" doctor 2>&1 || true)"
  printf '%s' "$out" | grep -q 'bercail doctor' || fail "doctor via symlink did not load lib: $out"
  if printf '%s' "$out" | grep -q 'cannot find bercail lib'; then fail "symlink did not find lib: $out"; fi
}

@test "packaged install does not copy bercail over the mise/packslip link" {
  local home="$BATS_TEST_TMPDIR/home-pkg" out
  mkdir -p "$home/.local/bin"
  : >"$STAGE/.bercail-package"
  ln -s "$STAGE/bin/bercail" "$home/.local/bin/bercail"
  # dry-run may exit nonzero on host-only warnings (Hyprland); read its plan.
  out="$(run_bercail "$home" dry-run 2>&1 || true)"
  grep -q 'keeping bercail from mise/packslip' <<<"$out" \
    || fail "packaged dry-run should keep the managed command: $out"
  if grep -qF "cp $STAGE/bin/bercail -> " <<<"$out"; then
    fail "packaged dry-run must not copy bin/bercail: $out"
  fi
  [[ -L "$home/.local/bin/bercail" ]] || fail "dry-run replaced the link"
}

@test "clone and curl installs still copy bercail into ~/.local/bin" {
  local home="$BATS_TEST_TMPDIR/home-clone" out
  mkdir -p "$home/.local/bin"
  rm -f "$STAGE/.bercail-package"
  out="$(HOME="$home" PATH="/usr/bin:/bin" BERCAIL_LIB="" AGENTIC_DEV_LIB="" BERCAIL_PACKAGED="" \
    "$STAGE/bin/bercail" dry-run 2>&1 || true)"
  grep -qF "cp $STAGE/bin/bercail -> $home/.local/bin/bercail" <<<"$out" \
    || fail "a clone or curl install should still copy bercail: $out"
}

@test "bercail install without a release tree points at the curl installer" {
  local home="$BATS_TEST_TMPDIR/home-bare" bare="$BATS_TEST_TMPDIR/bare" rc=0 err
  mkdir -p "$bare/bin" "$home"
  cp -R "$STAGE/lib" "$bare/lib"
  cp "$STAGE/bin/bercail" "$bare/bin/bercail"
  err="$(HOME="$home" PATH="/usr/bin:/bin" "$bare/bin/bercail" install 2>&1)" || rc=$?
  [[ "$rc" -eq 1 ]] || fail "install without install.sh should exit 1, got $rc"
  grep -q 'https://bercail.dev/install.sh' <<<"$err" \
    || fail "install without install.sh should point at curl: $err"
}
