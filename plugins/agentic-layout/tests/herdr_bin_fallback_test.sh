#!/usr/bin/env bash
# A server that predates an in-place Herdr upgrade hands plugins a dead
# HERDR_BIN_PATH ("/usr/bin/herdr (deleted)"); layout.sh must use PATH.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$TEST_DIR/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

mkdir -p "$TMP_DIR/bin"
cat >"$TMP_DIR/bin/herdr" <<'FAKE_HERDR'
#!/usr/bin/env bash
printf 'path-herdr %s\n' "$*"
FAKE_HERDR
chmod +x "$TMP_DIR/bin/herdr"

run_with_bin_path() {
  HERDR_BIN_PATH="$1" HERDR_PLUGIN_ROOT="$PLUGIN_ROOT" HOME="$TMP_DIR/home" \
    XDG_STATE_HOME="$TMP_DIR/state" PATH="$TMP_DIR/bin:$PATH" bash -c '
      source "$HERDR_PLUGIN_ROOT/layout.sh"
      printf "%s|%s|" "$HERDR" "${HERDR_BIN_PATH-unset}"
      _herdr_json tab list
    '
}

out="$(run_with_bin_path "/usr/bin/herdr (deleted)" || true)"
[[ "$out" == "herdr|unset|path-herdr tab list" ]] \
  || fail "dead HERDR_BIN_PATH should fall back to PATH: $out"

out="$(run_with_bin_path "$TMP_DIR/bin/herdr" || true)"
[[ "$out" == "$TMP_DIR/bin/herdr|$TMP_DIR/bin/herdr|path-herdr tab list" ]] \
  || fail "live HERDR_BIN_PATH should be kept: $out"

printf 'ok herdr_bin_fallback\n'
