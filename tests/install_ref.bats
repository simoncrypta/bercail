#!/usr/bin/env bats
# A piped install.sh and a curl install's `bercail update` take every file from
# one tagged commit, as one archive: the latest release, never master unless
# BERCAIL_REF says so. curl is a stand-in that serves this checkout as that
# archive and logs each URL.

setup() {
  load test_helper
  isolate
  set -o pipefail
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  hash -r
  unset BERCAIL_REF BERCAIL_ARCHIVE_URL INSTALL_SRC
  ARCHIVE="https://github.com/simoncrypta/bercail/archive"
  RELEASE="$HOME/.local/share/bercail/release"
  LOG="$BATS_TEST_TMPDIR/curl.log"
  OUT="$BATS_TEST_TMPDIR/out"
  # The tree under one top folder, as GitHub packs it.
  (cd "$ROOT" && git ls-files -co --exclude-standard \
    | while IFS= read -r f; do [[ -e "$f" ]] && printf '%s\0' "$f"; done \
    | tar --null -T - --transform 's,^,bercail-9.9.0/,S' -czf "$BATS_TEST_TMPDIR/tree.tar.gz")
  # LATEST_TAG: where github.com redirects /releases/latest; empty fails the lookup.
  # BROKEN_ARCHIVE: the download ends early.
  cat >"$BATS_TEST_TMPDIR/bin/curl" <<EOF
#!/usr/bin/env bash
url="" out="" fmt=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -o) out="\$2"; shift ;;
    -w) fmt="\$2"; shift ;;
    http*) url="\$1" ;;
  esac
  shift
done
printf '%s\n' "\$url" >>"$LOG"
case "\$url" in
  https://github.com/simoncrypta/bercail/releases/latest)
    [[ -n "\${LATEST_TAG:-}" && "\$fmt" == '%{redirect_url}' ]] || exit 22
    printf 'https://github.com/simoncrypta/bercail/releases/tag/%s' "\$LATEST_TAG" ;;
  $ARCHIVE/*.tar.gz|https://mirror.test/bercail.tar.gz)
    if [[ -n "\${BROKEN_ARCHIVE:-}" ]]; then head -c 2000 "$BATS_TEST_TMPDIR/tree.tar.gz" >"\$out"; exit 18; fi
    cp "$BATS_TEST_TMPDIR/tree.tar.gz" "\$out" ;;
  *) exit 7 ;;
esac
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/curl"
}

# Pipe install.sh (or $1) to bash the way the one-liner does, with --help so it
# stops once every lib is loaded.
piped_install() {
  : >"$LOG"
  rm -rf "$RELEASE"
  bash -s -- --help <"${1:-$ROOT/install.sh}" >"$OUT" 2>&1
}

# The one archive fetched is $1, and it is unpacked as the release tree.
expect_tree_from() {
  local url="$1" label="$2"
  [[ "$(grep -v 'releases/latest' "$LOG")" == "$url" ]] || fail "$label: fetched $(cat "$LOG"), not only $url"
  cmp -s "$ROOT/lib/shep.sh" "$RELEASE/lib/shep.sh" || fail "$label: the archive is not unpacked in $RELEASE"
  [[ "$(ls -A "$HOME/.local/share/bercail")" == release ]] \
    || fail "$label: more than the release tree is left: $(ls -A "$HOME/.local/share/bercail")"
}

# install.sh with the line the Worker pins, so a test does not depend on another.
pinned_install() {
  sed 's/^BERCAIL_RELEASE=""$/BERCAIL_RELEASE="v9.8.0"/' "$ROOT/install.sh" >"$BATS_TEST_TMPDIR/pinned.sh"
  grep -q '^BERCAIL_RELEASE="v9.8.0"$' "$BATS_TEST_TMPDIR/pinned.sh" \
    || fail "install.sh has no BERCAIL_RELEASE=\"\" line for the Worker to pin"
}

# The download half of `bercail update` on a curl install, from the installed lib.
remote_update() {
  : >"$LOG"
  # shellcheck disable=SC2016
  bash -c 'source "$1/lib/common.sh"; fetch_release_tree' _ "$ROOT" >"$OUT" 2>&1
}

@test "piped install.sh unpacks the latest release's archive and loads its libs from it" {
  LATEST_TAG=v9.9.0 piped_install || fail "unpinned install: $(cat "$OUT")"
  grep -q '^Install (curl' "$OUT" || fail "install.sh did not load its libs: $(cat "$OUT")"
  grep -qxF "bercail: installing from $ARCHIVE/v9.9.0.tar.gz" "$OUT" || fail "no source line: $(cat "$OUT")"
  expect_tree_from "$ARCHIVE/v9.9.0.tar.gz" "unpinned"
}

@test "install.sh pinned by bercail.dev reads only its own tag" {
  pinned_install
  LATEST_TAG=v9.9.0 piped_install "$BATS_TEST_TMPDIR/pinned.sh" || fail "pinned install: $(cat "$OUT")"
  expect_tree_from "$ARCHIVE/v9.8.0.tar.gz" "pinned"
  if grep -q 'releases/latest' "$LOG"; then
    fail "a pinned install.sh looked the release up again: $(cat "$LOG")"
  fi
}

@test "BERCAIL_REF and BERCAIL_ARCHIVE_URL override the release for development" {
  pinned_install
  LATEST_TAG=v9.9.0 BERCAIL_REF=master piped_install "$BATS_TEST_TMPDIR/pinned.sh" \
    || fail "BERCAIL_REF: $(cat "$OUT")"
  expect_tree_from "$ARCHIVE/master.tar.gz" "BERCAIL_REF=master"
  BERCAIL_ARCHIVE_URL=https://mirror.test/bercail.tar.gz piped_install || fail "BERCAIL_ARCHIVE_URL: $(cat "$OUT")"
  expect_tree_from "https://mirror.test/bercail.tar.gz" "BERCAIL_ARCHIVE_URL"
}

@test "no release found stops the install instead of reading master" {
  if LATEST_TAG="" piped_install; then fail "install went on without a release: $(cat "$OUT")"; fi
  grep -q 'BERCAIL_REF=<tag>' "$OUT" || fail "the error should name the override: $(cat "$OUT")"
  if grep -qF "$ARCHIVE/" "$LOG"; then fail "fetched an archive without a release: $(cat "$LOG")"; fi
}

@test "a download that ends early stops the install and leaves no tree" {
  if LATEST_TAG=v9.9.0 BROKEN_ARCHIVE=1 piped_install; then fail "install went on: $(cat "$OUT")"; fi
  grep -q "could not download bercail from $ARCHIVE/v9.9.0.tar.gz" "$OUT" || fail "no word on the download: $(cat "$OUT")"
  [[ -z "$(ls -A "$HOME/.local/share/bercail")" ]] || fail "left behind: $(ls -A "$HOME/.local/share/bercail")"
}

@test "install.sh refuses v0.14.0's archive, which it cannot install, and names that tag's own install.sh" {
  git -C "$ROOT" rev-parse -q --verify refs/tags/v0.14.0 >/dev/null || fail "release tag v0.14.0 is missing: git -C $ROOT fetch --tags"
  git -C "$ROOT" archive --prefix=bercail-0.14.0/ -o "$BATS_TEST_TMPDIR/tree.tar.gz" v0.14.0
  if BERCAIL_REF=v0.14.0 piped_install; then fail "install went on with v0.14.0: $(cat "$OUT")"; fi
  grep -qF 'raw.githubusercontent.com/simoncrypta/bercail/<tag>/install.sh' "$OUT" || fail "no way out named: $(cat "$OUT")"
  [[ -z "$(ls -A "$HOME/.local/share/bercail")" ]] || fail "left behind: $(ls -A "$HOME/.local/share/bercail")"
}

@test "bercail update on a curl install unpacks the latest release over the last one" {
  mkdir -p "$RELEASE/lib"
  : >"$RELEASE/lib/gone-in-this-release.sh"
  LATEST_TAG=v9.9.0 remote_update || fail "update: $(cat "$OUT")"
  expect_tree_from "$ARCHIVE/v9.9.0.tar.gz" "update"
  [[ "$(grep -c 'releases/latest' "$LOG")" == 1 ]] || fail "update should look the release up once: $(cat "$LOG")"
  [[ ! -e "$RELEASE/lib/gone-in-this-release.sh" ]] || fail "a file the release dropped stays in the tree"
  LATEST_TAG=v9.9.0 BERCAIL_REF=master remote_update || fail "update BERCAIL_REF: $(cat "$OUT")"
  expect_tree_from "$ARCHIVE/master.tar.gz" "update BERCAIL_REF=master"
}

@test "no release found, or a download that ends early, stops bercail update and keeps the tree it had" {
  mkdir -p "$RELEASE"
  : >"$RELEASE/the-last-release"
  if LATEST_TAG="" remote_update; then fail "update went on without a release: $(cat "$OUT")"; fi
  grep -q 'BERCAIL_REF=<tag>' "$OUT" || fail "update error should name the override: $(cat "$OUT")"
  if grep -qF "$ARCHIVE/" "$LOG"; then fail "update fetched an archive without a release: $(cat "$LOG")"; fi
  if LATEST_TAG=v9.9.0 BROKEN_ARCHIVE=1 remote_update; then fail "update went on with half an archive: $(cat "$OUT")"; fi
  grep -q 'could not download bercail' "$OUT" || fail "no word on the download: $(cat "$OUT")"
  [[ "$(ls -A "$RELEASE")" == the-last-release ]] || fail "the tree it had is gone: $(ls -A "$RELEASE")"
  [[ "$(ls -A "$HOME/.local/share/bercail")" == release ]] || fail "left behind: $(ls -A "$HOME/.local/share/bercail")"
}
