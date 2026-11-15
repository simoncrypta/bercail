# shellcheck shell=bash
# Loaded by every .bats file. `isolate` in setup gives the @test its own HOME,
# with every XDG dir and TMPDIR under it, so nothing it runs reaches real state.

ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
export ROOT

isolate() {
  # need node looks for the real node with these: a mise shim reads HOME.
  TEST_REAL_HOME="$HOME" TEST_REAL_PATH="$PATH"
  export HOME="$BATS_TEST_TMPDIR/home"
  export XDG_STATE_HOME="$HOME/.local/state" XDG_CONFIG_HOME="$HOME/.config"
  export XDG_DATA_HOME="$HOME/.local/share" XDG_CACHE_HOME="$HOME/.cache"
  export XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/run" TMPDIR="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$HOME" "$TMPDIR"
  mkdir -m 700 "$XDG_RUNTIME_DIR"
  export DESKTOP_TEST="${BATS_TEST_FILENAME##*/}: $BATS_TEST_DESCRIPTION"
  # bats keeps its BATS_TEST_TIMEOUT watchdog's pid in a local, gone by the time
  # a failed test's exit trap reads it: the watchdog outlives the test, and under
  # set -u (lib/common.sh) the trap dies before it prints the failure.
  [[ -z "${BATS_killer_pid:-}" ]] || declare -g BATS_killer_pid="$BATS_killer_pid"
  # A dev box has node in /usr/bin and the runner does not, so a test that puts
  # its stand-ins before /usr/bin:/bin finds Node here and fails in CI. This
  # stand-in fails it here too, until the test says need node.
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\necho "node: this test did not ask for Node; add need node to it (tests/test_helper.bash)" >&2\nexit 127\n' \
    >"$BATS_TEST_TMPDIR/bin/node"
  chmod +x "$BATS_TEST_TMPDIR/bin/node"
}

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  return 1
}

# A repo at DIR with one commit.
git_init() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" config user.email test@example.com
  git -C "$dir" config user.name test
  printf 'base\n' >"$dir/file.txt"
  git -C "$dir" add file.txt
  git -C "$dir" commit -qm base
}

# The tools a test cannot run without. CI installs them all, so there a missing
# one fails the test; anywhere else the test skips and says which.
need() {
  local tool
  for tool in "$@"; do
    if [[ "$tool" == node ]]; then
      need_node || return
    else
      command -v "$tool" >/dev/null 2>&1 || unavailable "$tool not found"
    fi
  done
}

# Swap isolate's node stand-in for one that runs the real node. A wrapper, not
# a symlink: a test that later writes its own bin/node must not write through.
need_node() {
  local node
  node="$(HOME="$TEST_REAL_HOME" PATH="$TEST_REAL_PATH" mise which node 2>/dev/null ||
    PATH="$TEST_REAL_PATH" command -v node || true)"
  [[ -n "$node" ]] || unavailable "node not found" || return
  printf '#!/bin/sh\nexec %q "$@"\n' "$node" >"$BATS_TEST_TMPDIR/bin/node"
}

# The same rule for a need that is not one command on PATH.
unavailable() {
  [[ -z "${CI:-}" ]] || fail "$1; CI must provide it (.github/workflows/ci.yml)" || return
  skip "$1"
}

# The installed Pi for a live proof, or nothing. Never a mise shim: one
# reinstalls Pi once HOME has moved. Only a test tagged live may run it, so the
# unit run (tests/run.sh) never does.
real_pi() {
  local pi=""
  [[ " ${BATS_TEST_TAGS[*]} " == *" live "* ]] || fail "real Pi in a test not tagged live: $BATS_TEST_DESCRIPTION" || return
  if command -v mise >/dev/null 2>&1; then
    pi="$(mise which pi 2>/dev/null || true)"
  fi
  if [[ -z "$pi" || ! -x "$pi" || "$pi" == */mise/shims/* ]]; then
    pi="$(command -v pi 2>/dev/null || true)"
    [[ -n "$pi" && "$pi" != */mise/shims/* && -x "$pi" ]] || pi=""
  fi
  printf '%s' "$pi"
}

# Whether Pi version $1 is at least major.minor $2.
pi_at_least() {
  node -e 'const [a, b] = process.argv[1].split(".").map(Number); const [x, y] = process.argv[2].split(".").map(Number);
    process.exit(a > x || (a === x && b >= y) ? 0 : 1)' "$1" "$2"
}
