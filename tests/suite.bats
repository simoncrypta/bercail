#!/usr/bin/env bats
# The suite's own rules.

setup() {
  load test_helper
  isolate
}

@test "every .bats file isolates each test in its setup" {
  local f missing=()
  for f in "$ROOT"/tests/*.bats; do
    grep -Eq '^[[:space:]]+isolate([[:space:]]|$)' "$f" || missing+=("${f##*/}")
  done
  [[ ${#missing[@]} -eq 0 ]] || fail "no isolate in setup: ${missing[*]}"
}

@test "a test cannot see the desk it was started from" {
  [[ "$HOME" == "$BATS_TEST_TMPDIR/home" ]] || fail "HOME is $HOME"
  [[ "$XDG_STATE_HOME" == "$HOME/.local/state" ]] || fail "XDG_STATE_HOME is $XDG_STATE_HOME"
  [[ "$TMPDIR" == "$BATS_TEST_TMPDIR/"* ]] || fail "TMPDIR is $TMPDIR"
  [[ "$BERCAIL_TMP_ROOT" == "$BATS_TEST_TMPDIR/"* ]] || fail "a sweep would take $BERCAIL_TMP_ROOT for /tmp"
  local leaked
  leaked="$(compgen -e | grep -E '^(HC|HERDR|BERCAIL|BEADS|BD|HANDOFF)_' | grep -vx BERCAIL_TMP_ROOT || true)"
  [[ -z "$leaked" ]] || fail "desk variables reached the test: $leaked"
}

@test "a test that needs a missing tool skips, and fails under CI" {
  local dir="$BATS_TEST_TMPDIR/nested" out
  mkdir -p "$dir"
  cat >"$dir/needs.bats" <<FIXTURE
setup() {
  load "$ROOT/tests/test_helper"
  isolate
}
@test "needs a tool" {
  need bash no-such-tool-here
}
FIXTURE
  out="$(CI='' "$ROOT/node_modules/.bin/bats" "$dir/needs.bats" 2>&1)" || fail "outside CI the test failed: $out"
  grep -qx 'ok 1 needs a tool # skip no-such-tool-here not found' <<<"$out" || fail "no skip reported: $out"
  out="$(CI=true "$ROOT/node_modules/.bin/bats" "$dir/needs.bats" 2>&1)" && fail "under CI the test passed: $out"
  grep -q 'no-such-tool-here not found; CI must provide it' <<<"$out" || fail "the failure does not name the tool: $out"
}

# A dev box has node in /usr/bin and the runner does not: a test that leans on
# that passes here and fails in CI unless it fails here too.
@test "a test runs Node only once it says need node, even with /usr/bin on PATH" {
  local dir="$BATS_TEST_TMPDIR/nested" out
  mkdir -p "$dir"
  cat >"$dir/node.bats" <<FIXTURE
setup() {
  load "$ROOT/tests/test_helper"
  isolate
  export PATH="\$BATS_TEST_TMPDIR/bin:/usr/bin:/bin"
}
@test "undeclared" {
  node -e 0
}
@test "declared" {
  need node
  node -e 0
}
FIXTURE
  out="$("$ROOT/node_modules/.bin/bats" "$dir/node.bats" 2>&1)" && fail "a test ran Node without need node: $out"
  grep -qx 'not ok 1 undeclared' <<<"$out" || fail "the undeclared test did not fail: $out"
  grep -q 'add need node to it' <<<"$out" || fail "the failure does not name the fix: $out"
  grep -qx 'ok 2 declared' <<<"$out" || fail "need node did not give the test Node: $out"
}

# bats loses the watchdog's pid before a failed test's exit trap reads it;
# isolate keeps it. Without that, under set -u (lib/common.sh) the failure
# prints nothing, and a serial run waits out the whole BATS_TEST_TIMEOUT.
@test "a failed test under set -u and a timeout still reports, and does not wait it out" {
  local dir="$BATS_TEST_TMPDIR/nested" out mode start
  mkdir -p "$dir"
  cat >"$dir/fails.bats" <<FIXTURE
setup() {
  load "$ROOT/tests/test_helper"
  isolate
  set -u
}
@test "fails" {
  false
}
FIXTURE
  # Serial, then tests side by side (no GNU parallel needed within a file).
  for mode in "" "--jobs 2 --no-parallelize-across-files"; do
    start=$SECONDS
    # shellcheck disable=SC2086 # mode is the flags, split on purpose
    out="$(BATS_TEST_TIMEOUT=20 "$ROOT/node_modules/.bin/bats" $mode "$dir/fails.bats" 2>&1)" \
      && fail "[$mode]: the failing test passed: $out"
    grep -qx 'not ok 1 fails' <<<"$out" || fail "[$mode]: no failure reported: $out"
    [[ $((SECONDS - start)) -lt 15 ]] || fail "[$mode]: waited out the timeout ($((SECONDS - start))s)"
  done
}

# verify-bercail checks that the suite leaves the real handoffs.jsonl alone.
# Another desk spawning during the run is not the suite's doing.
@test "verify's canary: another desk's spawn passes and is kept; a line naming the run's temp root fails" {
  local canary="$ROOT/.agents/skills/verify-bercail/handoffs-canary.sh" dir="$BATS_TEST_TMPDIR/canary"
  local root="$dir/run" log="$dir/handoffs.jsonl" before="$dir/before.jsonl" added="$dir/added.jsonl" out
  mkdir -p "$root"
  printf '{"path":"/home/me/Work/a"}\n' >"$log"
  cp "$log" "$before"
  "$canary" "$log" "$before" "$root" "$added" || fail "an untouched log failed"
  [[ ! -e "$added" ]] || fail "nothing was added, yet $added was written"
  printf '{"path":"/home/me/Work/b"}\n' >>"$log"
  out="$("$canary" "$log" "$before" "$root" "$added" 2>&1)" || fail "another desk's spawn failed: $out"
  grep -qx '{"path":"/home/me/Work/b"}' "$added" || fail "the added line was not kept: $(cat "$added")"
  printf '{"path":"%s/bats-run-1/test/1/wt"}\n' "$root" >>"$log"
  out="$("$canary" "$log" "$before" "$root" "$added" 2>&1)" && fail "a line from the run passed"
  grep -qF 'a test wrote the real handoff log' <<<"$out" || fail "no reason given: $out"
}

@test "verify's canary: a line already in the log that changed fails, even with nothing added" {
  local canary="$ROOT/.agents/skills/verify-bercail/handoffs-canary.sh" dir="$BATS_TEST_TMPDIR/canary" out
  mkdir -p "$dir/run"
  printf '{"path":"/home/me/Work/a"}\n' >"$dir/before.jsonl"
  printf '{"path":"/home/me/Work/x"}\n' >"$dir/handoffs.jsonl"
  out="$("$canary" "$dir/handoffs.jsonl" "$dir/before.jsonl" "$dir/run" "$dir/added.jsonl" 2>&1)" && fail "a changed line passed"
  grep -qF 'lines already in the handoff log changed' <<<"$out" || fail "no reason given: $out"
  rm "$dir/handoffs.jsonl"
  "$canary" "$dir/handoffs.jsonl" "$dir/before.jsonl" "$dir/run" "$dir/added.jsonl" 2>/dev/null && fail "a deleted log passed"
  true
}

# A leak once ran the real gh past a stand-in: BASH_ENV put the mise shims back
# ahead of it (bercail-fss). isolate fails a test whose PATH or BASH_ENV can.
@test "a test fails when its PATH or BASH_ENV reaches the real mise shims" {
  local dir="$BATS_TEST_TMPDIR/nested" out
  mkdir -p "$dir"
  cat >"$dir/escape.bats" <<FIXTURE
setup() {
  load "$ROOT/tests/test_helper"
  case "\$BATS_TEST_DESCRIPTION" in
    shims) export PATH="/home/me/.local/share/mise/shims/:\$PATH" ;;
    wrappers) export PATH="\$PATH:/home/me/.local/share/mise/command-wrappers/bin" ;;
    bash_env) export BASH_ENV=/home/me/.bash_env ;;
  esac
  isolate
}
@test "shims" { :; }
@test "wrappers" { :; }
@test "bash_env" { :; }
@test "clean" { :; }
FIXTURE
  out="$("$ROOT/node_modules/.bin/bats" "$dir/escape.bats" 2>&1)" && fail "every escape passed: $out"
  grep -qx 'not ok 1 shims' <<<"$out" || fail "the shims on PATH passed: $out"
  grep -q 'PATH reaches mise through /home/me/.local/share/mise/shims/; drop it' <<<"$out" || fail "the failure does not name the shims: $out"
  grep -qx 'not ok 2 wrappers' <<<"$out" || fail "the command wrappers on PATH passed: $out"
  grep -qx 'not ok 3 bash_env' <<<"$out" || fail "a BASH_ENV passed: $out"
  grep -q 'BASH_ENV is set (/home/me/.bash_env)' <<<"$out" || fail "the failure does not name BASH_ENV: $out"
  grep -qx 'ok 4 clean' <<<"$out" || fail "the suite's own PATH failed the check: $out"
}

# A judge once ran the suite with GIT_DIR at a desk's worktree: fixtures moved
# its branch, set user.name=test in its config and left 34 branches (bercail-m94t).
# A repo outside the run, with one commit, and a fingerprint of its .git.
real_repo() {
  REAL="$BATS_TEST_TMPDIR/real"
  git init -q -b main "$REAL"
  git -C "$REAL" -c user.name=me -c user.email=me@example.com commit -q --allow-empty -m start
}
real_git_state() {
  (cd "$REAL/.git" && find . -type f -print0 | sort -z | xargs -0 sha256sum)
}

# Fixture work a test does in its own temp dir, the kind that leaked: it fails
# unless its config write and commit land in its own repo, and a folder outside
# any repo stays outside one.
fixture_git='set -e
git init -q "$1/repo"
git -C "$1/repo" config user.name fixture
[ "$(git config -f "$1/repo/.git/config" user.name)" = fixture ]
git -C "$1/repo" -c user.email=test@example.com commit -q --allow-empty -m fixture
git -C "$1/repo" branch fixture
mkdir "$1/plain"
if git -C "$1/plain" rev-parse --git-dir >/dev/null 2>&1; then exit 1; fi'

bats_fixture() {
  local dir="$BATS_TEST_TMPDIR/nested"
  mkdir -p "$dir"
  printf '%s\n' "$fixture_git" >"$dir/fixture.sh"
  cat >"$dir/fixture.bats" <<FIXTURE
setup_file() {
  mkdir -p "\$BATS_FILE_TMPDIR/seed"
  bash "$dir/fixture.sh" "\$BATS_FILE_TMPDIR/seed"
}
setup() {
  load "$ROOT/tests/test_helper"
  isolate
}
@test "fixture" {
  bash "$dir/fixture.sh" "\$BATS_TEST_TMPDIR"
}
FIXTURE
  printf '%s' "$dir/fixture.bats"
}

@test "a bats run started with GIT_* naming a repo leaves that repo alone" {
  local fixture before out rc=0
  real_repo
  fixture="$(bats_fixture)"
  before="$(real_git_state)"
  out="$(GIT_DIR="$REAL/.git" GIT_WORK_TREE="$REAL" GIT_INDEX_FILE="$REAL/.git/index" \
    GIT_OBJECT_DIRECTORY="$REAL/.git/objects" GIT_COMMON_DIR="$REAL/.git" GIT_CONFIG="$REAL/.git/config" \
    "$ROOT/node_modules/.bin/bats" --setup-suite-file "$ROOT/tests/setup_suite.bash" "$fixture" 2>&1)" || rc=$?
  [[ "$(real_git_state)" == "$before" ]] || fail "the run wrote to the repo GIT_DIR named: $(git -C "$REAL" branch -a) $(git -C "$REAL" config --list --local)"
  [[ "$rc" -eq 0 ]] && grep -qx 'ok 1 fixture' <<<"$out" || fail "the fixture's git did not work in its own repo: $out"
}

@test "a bats run whose temp root is inside a repo never finds that repo" {
  local fixture before out rc=0
  real_repo
  fixture="$(bats_fixture)"
  mkdir "$REAL/tmp"
  before="$(real_git_state)"
  out="$(TMPDIR="$REAL/tmp" "$ROOT/node_modules/.bin/bats" --setup-suite-file "$ROOT/tests/setup_suite.bash" "$fixture" 2>&1)" || rc=$?
  [[ "$(real_git_state)" == "$before" ]] || fail "the run wrote to the repo above its temp root: $(git -C "$REAL" config --list --local)"
  [[ "$rc" -eq 0 ]] && grep -qx 'ok 1 fixture' <<<"$out" || fail "a fixture found the repo above its temp root: $out"
}

@test "a test fails when a GIT_* variable reaches it before isolate" {
  local dir="$BATS_TEST_TMPDIR/nested" out
  mkdir -p "$dir"
  cat >"$dir/escape.bats" <<FIXTURE
setup() {
  load "$ROOT/tests/test_helper"
  [[ "\$BATS_TEST_DESCRIPTION" != git_dir ]] || export GIT_DIR="$BATS_TEST_TMPDIR/real/.git"
  isolate
}
@test "git_dir" { :; }
@test "clean" { :; }
FIXTURE
  out="$("$ROOT/node_modules/.bin/bats" "$dir/escape.bats" 2>&1)" && fail "every escape passed: $out"
  grep -qx 'not ok 1 git_dir' <<<"$out" || fail "a GIT_DIR passed: $out"
  grep -q 'GIT_DIR set before isolate' <<<"$out" || fail "the failure does not name GIT_DIR: $out"
  grep -qx 'ok 2 clean' <<<"$out" || fail "the suite's own git setup failed the check: $out"
}

# The same fixture work from a Vitest file, under tests/setup.ts.
vitest_fixture() {
  local dir="$BATS_TEST_TMPDIR/vitest"
  mkdir -p "$dir"
  printf '%s\n' "$fixture_git" >"$dir/fixture.sh"
  printf 'export default { test: { include: ["*.test.ts"], setupFiles: [%s], globals: true } };\n' \
    "\"$ROOT/tests/setup.ts\"" >"$dir/vitest.config.mjs"
  cat >"$dir/fixture.test.ts" <<FIXTURE
import { execFileSync } from "node:child_process";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
test("fixture", () => {
  execFileSync("bash", ["$dir/fixture.sh", mkdtempSync(join(tmpdir(), "fixture-"))], { stdio: "pipe" });
});
FIXTURE
  printf '%s' "$dir"
}

@test "a Vitest run started with GIT_DIR at a repo, or from inside one, leaves it alone" {
  need node
  local dir before out rc=0
  real_repo
  dir="$(vitest_fixture)"
  mkdir "$REAL/tmp"
  before="$(real_git_state)"
  out="$(cd "$ROOT" && GIT_DIR="$REAL/.git" GIT_WORK_TREE="$REAL" TMPDIR="$REAL/tmp" \
    node_modules/.bin/vp test --run --root "$dir" --config "$dir/vitest.config.mjs" 2>&1)" || rc=$?
  [[ "$(real_git_state)" == "$before" ]] || fail "the run wrote to the real repo: $(git -C "$REAL" branch -a) $(git -C "$REAL" config --list --local)"
  [[ "$rc" -eq 0 ]] && grep -q '1 passed' <<<"$out" || fail "the fixture's git did not work in its own repo: $out"
}
