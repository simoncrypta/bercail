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
  # Pi's agent dir follows HOME only when this is unset; set, it is the real one.
  unset PI_CODING_AGENT_DIR
  # What a sweep takes as /tmp: never the real one.
  export BERCAIL_TMP_ROOT="$BATS_TEST_TMPDIR/system-tmp"
  # The live Pi processes lib/pi-code.sh reads: none but a test's fake_proc ones.
  export BERCAIL_PROC_DIR="$BATS_TEST_TMPDIR/proc"
  mkdir -p "$HOME" "$TMPDIR" "$BERCAIL_TMP_ROOT"
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
  # Last, once the watchdog's pid is kept: a failure here must not wait it out.
  escaped_to_mise && escaped_to_git || return
  # Nor may git look above the run for a repo (tests/setup_suite.bash).
  export GIT_CEILING_DIRECTORIES="${BATS_RUN_TMPDIR%/*}"
}

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  return 1
}

# A mise shim or command wrapper on PATH runs the real mise, which then reads
# the test's HOME or reaches past a stand-in, and a BASH_ENV can put them back
# in every bash child (bercail-fss). setup_suite drops all three; this fails a
# test whose suite or file setup brought one back.
escaped_to_mise() {
  local dir dirs
  [[ -z "${BASH_ENV:-}" ]] ||
    fail "BASH_ENV is set ($BASH_ENV): a bash child sources it and can put the real mise shims back on PATH; unset it (tests/setup_suite.bash)" || return
  IFS=: read -ra dirs <<<"$PATH"
  for dir in "${dirs[@]}"; do
    case "${dir%/}" in
      */mise/shims | */mise/command-wrappers/bin)
        fail "PATH reaches mise through $dir; drop it (tests/setup_suite.bash), or name the tool's own bin dir" || return
        ;;
    esac
  done
}

# tests/run.sh and setup_suite drop every GIT_* variable; this fails a test
# whose suite or file setup brought one back. A test sets its own
# (GIT_CONFIG_GLOBAL, ...) after isolate.
escaped_to_git() {
  local vars
  vars="$(compgen -e | grep -E '^GIT_' | grep -vx GIT_CEILING_DIRECTORIES | paste -sd ' ' || true)"
  [[ -z "$vars" ]] ||
    fail "$vars set before isolate: git in a fixture would write to the repo or config it names; unset it (tests/setup_suite.bash)" || return
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

# A process in a fake /proc booted at 1000, for lib/pi-code.sh:
# fake_proc PID PPID STARTED COMM TERMINAL ARGV..., STARTED in epoch seconds.
fake_proc() {
  local pid="$1" ppid="$2" started="$3" comm="$4" terminal="$5" dir
  shift 5
  dir="$BERCAIL_PROC_DIR/$pid"
  mkdir -p "$dir"
  printf 'cpu 0\nbtime 1000\n' >"$BERCAIL_PROC_DIR/stat"
  printf '%s\n' "$comm" >"$dir/comm"
  printf '%s\0' "$@" >"$dir/cmdline"
  printf 'HOME=%s\0HC_TERMINAL_ID=%s\0' "$HOME" "$terminal" >"$dir/environ"
  printf '%s (%s) S %s %s%s\n' "$pid" "$comm" "$ppid" "$(printf '0 %.0s' {1..17})" \
    "$(((started - 1000) * $(getconf CLK_TCK)))" >"$dir/stat"
}
