#!/usr/bin/env bats
# A piped install.sh and a curl install's `bercail update` read every file from
# one tagged commit, the latest release, never master unless BERCAIL_REF says so.
# curl is a stand-in that serves this checkout and logs each URL.

setup() {
  load test_helper
  isolate
  set -o pipefail
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  hash -r
  unset BERCAIL_REF GITHUB_RAW_BASE INSTALL_SRC
  RAW="https://raw.githubusercontent.com/simoncrypta/bercail"
  LOG="$BATS_TEST_TMPDIR/curl.log"
  OUT="$BATS_TEST_TMPDIR/out"
  # LATEST_TAG: where github.com redirects /releases/latest; empty fails the lookup.
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
  $RAW/*)
    rel="\${url#$RAW/}"; rel="\${rel#*/}"
    [[ -f "$ROOT/\$rel" ]] || exit 22
    cp "$ROOT/\$rel" "\$out" ;;
  *) exit 7 ;;
esac
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/curl"
}

# Pipe install.sh (or $1) to bash the way the one-liner does, with --help so it
# stops once every lib is loaded.
piped_install() {
  : >"$LOG"
  bash -s -- --help <"${1:-$ROOT/install.sh}" >"$OUT" 2>&1
}

# Every lib URL is under $1; nothing came from master.
expect_libs_from() {
  local base="$1" label="$2" url
  grep -qxF "$base/lib/shep.sh" "$LOG" || fail "$label: no lib/shep.sh from $base: $(cat "$LOG")"
  while IFS= read -r url; do
    [[ "$url" == "$base/"* ]] || fail "$label: fetched $url, not from $base"
  done < <(grep -F "$RAW/" "$LOG")
  if grep -q '/master/' "$LOG" && [[ "$base" != */master ]]; then
    fail "$label: read master: $(cat "$LOG")"
  fi
}

# install.sh with the line the Worker pins, so a test does not depend on another.
pinned_install() {
  sed 's/^BERCAIL_RELEASE=""$/BERCAIL_RELEASE="v9.8.0"/' "$ROOT/install.sh" >"$BATS_TEST_TMPDIR/pinned.sh"
  grep -q '^BERCAIL_RELEASE="v9.8.0"$' "$BATS_TEST_TMPDIR/pinned.sh" \
    || fail "install.sh has no BERCAIL_RELEASE=\"\" line for the Worker to pin"
}

# `bercail update` on a curl install: the installed libs fetch from GitHub raw.
remote_update() {
  : >"$LOG"
  # shellcheck disable=SC2016
  INSTALL_SRC=https://bercail.dev bash -c '
    set -euo pipefail
    for l in common detect config; do source "$1/lib/$l.sh"; done
    describe_install_source
    fetch_file config/agentic-dev/config-reader.sh "$HOME/a/config-reader.sh"
    fetch_file bin/bercail "$HOME/a/bercail"
  ' _ "$ROOT" >"$OUT" 2>&1
}

@test "piped install.sh loads every lib from the latest release tag" {
  LATEST_TAG=v9.9.0 piped_install || fail "unpinned install: $(cat "$OUT")"
  grep -q '^Install (curl' "$OUT" || fail "install.sh did not load its libs: $(cat "$OUT")"
  grep -qxF 'bercail: installing from '"$RAW/v9.9.0" "$OUT" || fail "no source line: $(cat "$OUT")"
  expect_libs_from "$RAW/v9.9.0" "unpinned"
}

@test "install.sh pinned by bercail.dev reads only its own tag" {
  pinned_install
  LATEST_TAG=v9.9.0 piped_install "$BATS_TEST_TMPDIR/pinned.sh" || fail "pinned install: $(cat "$OUT")"
  expect_libs_from "$RAW/v9.8.0" "pinned"
  if grep -q 'releases/latest' "$LOG"; then
    fail "a pinned install.sh looked the release up again: $(cat "$LOG")"
  fi
}

@test "BERCAIL_REF and GITHUB_RAW_BASE override the release for development" {
  pinned_install
  LATEST_TAG=v9.9.0 BERCAIL_REF=master piped_install "$BATS_TEST_TMPDIR/pinned.sh" \
    || fail "BERCAIL_REF: $(cat "$OUT")"
  expect_libs_from "$RAW/master" "BERCAIL_REF=master"
  GITHUB_RAW_BASE="$RAW/abc1234/" piped_install || fail "GITHUB_RAW_BASE: $(cat "$OUT")"
  expect_libs_from "$RAW/abc1234" "GITHUB_RAW_BASE"
}

@test "no release found stops the install instead of reading master" {
  if LATEST_TAG="" piped_install; then fail "install went on without a release: $(cat "$OUT")"; fi
  grep -q 'BERCAIL_REF=<tag>' "$OUT" || fail "the error should name the override: $(cat "$OUT")"
  if grep -qF "$RAW/" "$LOG"; then fail "fetched files without a release: $(cat "$LOG")"; fi
}

@test "bercail update on a curl install reads the latest release tag" {
  LATEST_TAG=v9.9.0 remote_update || fail "update: $(cat "$OUT")"
  grep -qF 'source: https://bercail.dev (GitHub v9.9.0)' "$OUT" || fail "update source line: $(cat "$OUT")"
  grep -qxF "$RAW/v9.9.0/bin/bercail" "$LOG" || fail "update did not fetch from the tag: $(cat "$LOG")"
  [[ "$(grep -c 'releases/latest' "$LOG")" == 1 ]] || fail "update should look the release up once: $(cat "$LOG")"
  if grep -q '/master/' "$LOG"; then fail "update read master: $(cat "$LOG")"; fi
  cmp -s "$ROOT/bin/bercail" "$HOME/a/bercail" || fail "update did not write the fetched file"
  LATEST_TAG=v9.9.0 BERCAIL_REF=master remote_update || fail "update BERCAIL_REF: $(cat "$OUT")"
  grep -qxF "$RAW/master/bin/bercail" "$LOG" || fail "update ignored BERCAIL_REF: $(cat "$LOG")"
}

@test "no release found stops bercail update instead of reading master" {
  if LATEST_TAG="" remote_update; then fail "update went on without a release: $(cat "$OUT")"; fi
  grep -q 'BERCAIL_REF=<tag>' "$OUT" || fail "update error should name the override: $(cat "$OUT")"
  if grep -qF "$RAW/" "$LOG"; then fail "update fetched files without a release: $(cat "$LOG")"; fi
}
