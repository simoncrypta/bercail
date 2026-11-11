#!/usr/bin/env bash
# shellcheck shell=bash
# A piped install.sh and a curl install's `bercail update` read every file from
# one tagged commit, the latest release, never master unless BERCAIL_REF says so.
# curl is a stand-in that serves this checkout and logs each URL.
set -euo pipefail

unset BASH_ENV
export __MISE_BASH_ENV_LOADED=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
RAW="https://raw.githubusercontent.com/simoncrypta/bercail"
LOG="$TMP_DIR/curl.log"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/home"
# LATEST_TAG: where github.com redirects /releases/latest; empty fails the lookup.
cat >"$TMP_DIR/bin/curl" <<EOF
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
chmod +x "$TMP_DIR/bin/curl"
export PATH="$TMP_DIR/bin:$PATH" HOME="$TMP_DIR/home"
unset BERCAIL_REF GITHUB_RAW_BASE INSTALL_SRC

# Pipe install.sh (or $2) to bash the way the one-liner does, with --help so it
# stops once every lib is loaded.
piped_install() {
  : >"$LOG"
  bash -s -- --help <"${1:-$ROOT/install.sh}" >"$TMP_DIR/out" 2>&1
}

# Every lib URL is under $1; nothing came from master.
expect_libs_from() {
  local base="$1" label="$2" url
  grep -qxF "$base/lib/shep.sh" "$LOG" || fail "$label: no lib/shep.sh from $base: $(cat "$LOG")"
  while IFS= read -r url; do
    [[ "$url" == "$base/"* ]] || fail "$label: fetched $url, not from $base"
  done < <(grep -F "$RAW/" "$LOG")
  grep -q '/master/' "$LOG" && [[ "$base" != */master ]] && fail "$label: read master: $(cat "$LOG")"
  return 0
}

LATEST_TAG=v9.9.0 piped_install || fail "unpinned install: $(cat "$TMP_DIR/out")"
grep -q '^Install (curl' "$TMP_DIR/out" || fail "install.sh did not load its libs: $(cat "$TMP_DIR/out")"
grep -qxF 'bercail: installing from '"$RAW/v9.9.0" "$TMP_DIR/out" || fail "no source line: $(cat "$TMP_DIR/out")"
expect_libs_from "$RAW/v9.9.0" "unpinned"
printf 'PASS: piped install.sh loads every lib from the latest release tag\n'

sed 's/^BERCAIL_RELEASE=""$/BERCAIL_RELEASE="v9.8.0"/' "$ROOT/install.sh" >"$TMP_DIR/pinned.sh"
grep -q '^BERCAIL_RELEASE="v9.8.0"$' "$TMP_DIR/pinned.sh" || fail "install.sh has no BERCAIL_RELEASE=\"\" line for the Worker to pin"
LATEST_TAG=v9.9.0 piped_install "$TMP_DIR/pinned.sh" || fail "pinned install: $(cat "$TMP_DIR/out")"
expect_libs_from "$RAW/v9.8.0" "pinned"
grep -q 'releases/latest' "$LOG" && fail "a pinned install.sh looked the release up again: $(cat "$LOG")"
printf 'PASS: install.sh pinned by bercail.dev reads only its own tag\n'

LATEST_TAG=v9.9.0 BERCAIL_REF=master piped_install "$TMP_DIR/pinned.sh" || fail "BERCAIL_REF: $(cat "$TMP_DIR/out")"
expect_libs_from "$RAW/master" "BERCAIL_REF=master"
GITHUB_RAW_BASE="$RAW/abc1234/" piped_install || fail "GITHUB_RAW_BASE: $(cat "$TMP_DIR/out")"
expect_libs_from "$RAW/abc1234" "GITHUB_RAW_BASE"
printf 'PASS: BERCAIL_REF and GITHUB_RAW_BASE override the release for development\n'

if LATEST_TAG="" piped_install; then fail "install went on without a release: $(cat "$TMP_DIR/out")"; fi
grep -q 'BERCAIL_REF=<tag>' "$TMP_DIR/out" || fail "the error should name the override: $(cat "$TMP_DIR/out")"
grep -qF "$RAW/" "$LOG" && fail "fetched files without a release: $(cat "$LOG")"
printf 'PASS: no release found stops the install instead of reading master\n'

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
  ' _ "$ROOT" >"$TMP_DIR/out" 2>&1
}

LATEST_TAG=v9.9.0 remote_update || fail "update: $(cat "$TMP_DIR/out")"
grep -qF 'source: https://bercail.dev (GitHub v9.9.0)' "$TMP_DIR/out" || fail "update source line: $(cat "$TMP_DIR/out")"
grep -qxF "$RAW/v9.9.0/bin/bercail" "$LOG" || fail "update did not fetch from the tag: $(cat "$LOG")"
[[ "$(grep -c 'releases/latest' "$LOG")" == 1 ]] || fail "update should look the release up once: $(cat "$LOG")"
grep -q '/master/' "$LOG" && fail "update read master: $(cat "$LOG")"
cmp -s "$ROOT/bin/bercail" "$HOME/a/bercail" || fail "update did not write the fetched file"
LATEST_TAG=v9.9.0 BERCAIL_REF=master remote_update || fail "update BERCAIL_REF: $(cat "$TMP_DIR/out")"
grep -qxF "$RAW/master/bin/bercail" "$LOG" || fail "update ignored BERCAIL_REF: $(cat "$LOG")"
printf 'PASS: bercail update on a curl install reads the latest release tag\n'

if LATEST_TAG="" remote_update; then fail "update went on without a release: $(cat "$TMP_DIR/out")"; fi
grep -q 'BERCAIL_REF=<tag>' "$TMP_DIR/out" || fail "update error should name the override: $(cat "$TMP_DIR/out")"
grep -qF "$RAW/" "$LOG" && fail "update fetched files without a release: $(cat "$LOG")"
printf 'PASS: no release found stops bercail update instead of reading master\n'
