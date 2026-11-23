#!/usr/bin/env bats
# The statechart skill: [bstack] statechart installs tla-ts from bercail's
# lockfile and deploys the skill only when on, and its wrapper never installs,
# reads statechart.env as data, runs upstream's command on tla-ts through a java
# shim (or on TLC when TLA2TOOLS and JAVA are both set), bounds each run, and
# writes the post for Pi's chat. Each @test is its own HOME; npm, node and
# upstream's command are stand-ins.

# shellcheck disable=SC2016 # single-quoted text is stand-in code.
# shellcheck disable=SC2034 # DRY_RUN and friends are read by the sourced libs.
# shellcheck disable=SC2329 # stubs replace lib functions the libs call.

setup() {
  load test_helper
  isolate
  BIN="$BATS_TEST_TMPDIR/bin"
  CONFIG="$HOME/.config/bercail/config.toml"
  ENV_FILE="$HOME/.local/share/bercail/statechart.env"
  STATECHART_DIR="$HOME/.local/share/bercail/statechart"
  CLI="$STATECHART_DIR/node_modules/tla-ts/dist/cli.js"
  mkdir -p "${CONFIG%/*}" "${ENV_FILE%/*}"
  # The only commands the functions under test may find: no system npm.
  SYS="$BATS_TEST_TMPDIR/sys"
  mkdir -p "$SYS"
  for cmd in bash sh sed head dirname mkdir awk jq rm cat cp cmp mv readlink tail chmod; do
    ln -s "$(command -v "$cmd")" "$SYS/$cmd"
  done
  # npm: logs each call; ci makes the CLI the lockfile would install.
  cat >"$BIN/npm" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$BATS_TEST_TMPDIR/npm.log"
[ "$1" = ci ] || exit 1
if [ -n "${NPM_FAIL:-}" ]; then
  echo "npm error code E404 tla-ts not found" >&2
  exit 1
fi
prefix=""
while [ $# -gt 0 ]; do
  [ "$1" = --prefix ] && prefix=$2
  shift
done
mkdir -p "$prefix/node_modules/tla-ts/dist" && : >"$prefix/node_modules/tla-ts/dist/cli.js"
printf '{"version": "0.0.10"}\n' >"$prefix/node_modules/tla-ts/package.json"
if [ -n "${NPM_FAIL_AFTER:-}" ]; then
  echo "npm error code EINTEGRITY fflate" >&2
  exit 1
fi
SH
  chmod +x "$BIN/npm"
}

# bercail's libs, for the tests of its functions. lib/common.sh's run() replaces
# bats' run, so those tests capture output themselves.
libs() {
  local lib
  for lib in common detect deps config skills; do
    # shellcheck disable=SC1090
    source "$ROOT/lib/$lib.sh"
  done
  info() { :; }
  export INSTALL_SRC="$ROOT"
  DRY_RUN=0
}

statechart_on() {
  printf '[bstack]\nstatechart = true\n' >"$CONFIG"
}

@test "with statechart off, nothing is installed and statechart.env goes" {
  libs
  printf 'TLA_TS=/old/cli.js\n' >"$ENV_FILE"
  PATH="$BIN:$SYS" ensure_statechart_tools
  [[ ! -e "$BATS_TEST_TMPDIR/npm.log" ]] || fail "npm ran: $(cat "$BATS_TEST_TMPDIR/npm.log")"
  [[ ! -e "$ENV_FILE" ]] || fail "statechart.env is still there"
}

@test "turning statechart off removes the tla-ts bercail installed" {
  libs
  statechart_on
  PATH="$BIN:$SYS" ensure_statechart_tools
  printf '[bstack]\nstatechart = false\n' >"$CONFIG"
  PATH="$BIN:$SYS" ensure_statechart_tools
  [[ ! -e "$STATECHART_DIR" && ! -e "$ENV_FILE" ]] || fail "left: $(ls -A "$STATECHART_DIR" 2>/dev/null) $(cat "$ENV_FILE" 2>/dev/null)"
}

@test "with statechart on, npm ci installs tla-ts from bercail's lockfile with no scripts, and statechart.env names its CLI" {
  libs
  statechart_on
  PATH="$BIN:$SYS" ensure_statechart_tools
  grep -qxF "ci --prefix $STATECHART_DIR.new --ignore-scripts --omit=dev --no-audit --no-fund --no-update-notifier" "$BATS_TEST_TMPDIR/npm.log" \
    || fail "npm: $(cat "$BATS_TEST_TMPDIR/npm.log")"
  cmp -s "$ROOT/lib/statechart/package-lock.json" "$STATECHART_DIR/package-lock.json" || fail "npm ci ran on another lockfile"
  [[ "$(cat "$ENV_FILE")" == "TLA_TS=$CLI" ]] || fail "statechart.env: $(cat "$ENV_FILE")"
}

@test "with tla-ts already installed from this lockfile, reconfigure runs no npm" {
  libs
  statechart_on
  PATH="$BIN:$SYS" ensure_statechart_tools
  rm "$BATS_TEST_TMPDIR/npm.log"
  PATH="$BIN:$SYS" ensure_statechart_tools
  [[ ! -e "$BATS_TEST_TMPDIR/npm.log" ]] || fail "npm ran again: $(cat "$BATS_TEST_TMPDIR/npm.log")"
  [[ "$(cat "$ENV_FILE")" == "TLA_TS=$CLI" ]] || fail "statechart.env: $(cat "$ENV_FILE")"
}

@test "a tla-ts installed from an older lockfile is installed again" {
  libs
  statechart_on
  mkdir -p "${CLI%/*}"
  : >"$CLI"
  printf '{"lockfileVersion": 3}\n' >"$STATECHART_DIR/package-lock.json"
  PATH="$BIN:$SYS" ensure_statechart_tools
  grep -q '^ci ' "$BATS_TEST_TMPDIR/npm.log" || fail "no npm ci"
  cmp -s "$ROOT/lib/statechart/package-lock.json" "$STATECHART_DIR/package-lock.json" || fail "the old lockfile stayed"
}

@test "a statechart.env from TLC and java is rewritten to name tla-ts" {
  libs
  statechart_on
  printf 'TLA2TOOLS=/old/tla2tools.jar\nJAVA=/usr/bin/java\n' >"$ENV_FILE"
  PATH="$BIN:$SYS" ensure_statechart_tools
  [[ "$(cat "$ENV_FILE")" == "TLA_TS=$CLI" ]] || fail "statechart.env: $(cat "$ENV_FILE")"
}

@test "a dry run installs nothing and writes no statechart.env" {
  libs
  statechart_on
  DRY_RUN=1
  PATH="$BIN:$SYS" ensure_statechart_tools
  [[ ! -e "$BATS_TEST_TMPDIR/npm.log" ]] || fail "npm ran: $(cat "$BATS_TEST_TMPDIR/npm.log")"
  [[ ! -e "$ENV_FILE" && ! -e "$STATECHART_DIR" ]] || fail "it wrote under $HOME/.local/share/bercail"
}

@test "a failed npm ci keeps npm's error visible and does not write statechart.env" {
  statechart_on
  run env PATH="$BIN:$SYS" NPM_FAIL=1 \
    bash -c 'for l in common detect deps config; do source "$1/lib/$l.sh"; done; INSTALL_SRC="$1" ensure_statechart_tools' _ "$ROOT"
  [[ "$status" -eq 1 ]] || fail "exit $status: $output"
  [[ "$output" == *"npm error code E404"* && "$output" == *"bercail reconfigure"* ]] || fail "no install error and fix: $output"
  [[ ! -e "$ENV_FILE" ]] || fail "statechart.env was written"
}

@test "an npm ci that fails part way leaves nothing that looks installed, so the next reconfigure tries again" {
  libs
  statechart_on
  local rc=0
  NPM_FAIL_AFTER=1 PATH="$BIN:$SYS" ensure_statechart_tools 2>/dev/null || rc=$?
  [[ "$rc" -eq 1 ]] || fail "the failed install returned $rc"
  [[ ! -e "$ENV_FILE" && ! -e "$STATECHART_DIR" && ! -e "$STATECHART_DIR.new" ]] || fail "a partial install stayed"
  PATH="$BIN:$SYS" ensure_statechart_tools
  [[ "$(grep -c '^ci ' "$BATS_TEST_TMPDIR/npm.log")" -eq 2 ]] || fail "npm ran $(grep -c '^ci ' "$BATS_TEST_TMPDIR/npm.log") times"
  [[ "$(cat "$ENV_FILE")" == "TLA_TS=$CLI" ]] || fail "statechart.env: $(cat "$ENV_FILE")"
}

@test "with statechart on and no npm, the warning says to install Node.js and statechart.env is not written" {
  statechart_on
  rm "$BIN/npm"
  run env PATH="$BIN:$SYS" bash -c 'for l in common detect deps config; do source "$1/lib/$l.sh"; done; INSTALL_SRC="$1" ensure_statechart_tools' _ "$ROOT"
  [[ "$status" -eq 1 ]] || fail "exit $status: $output"
  [[ "$output" == *"install Node.js"*"bercail reconfigure"* ]] || fail "no fix in: $output"
  [[ ! -e "$ENV_FILE" ]] || fail "statechart.env was written"
}

@test "bercail's statechart lockfile pins the tla-ts lib/deps.json knows, each package by its sha512" {
  local known dir="$ROOT/lib/statechart"
  known="$(jq -r '.[] | select(.name == "tla-ts") | .known' "$ROOT/lib/deps.json")"
  [[ "$known" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "lib/deps.json knows no tla-ts: $known"
  [[ "$(jq -r '.dependencies["tla-ts"]' "$dir/package.json")" == "$known" ]] || fail "package.json pins another tla-ts"
  [[ "$(jq -r '.packages["node_modules/tla-ts"].version' "$dir/package-lock.json")" == "$known" ]] || fail "the lockfile has another tla-ts"
  jq -e '[.packages | to_entries[] | select(.key != "") | .value.integrity | test("^sha512-")] | length > 0 and all' \
    "$dir/package-lock.json" >/dev/null || fail "a locked package has no sha512"
}

@test "deploy_skills deploys statechart for Pi only while statechart is on" {
  libs
  statechart_on
  deploy_skills >/dev/null
  [[ -x "$AGENTS_SKILLS_DIR/statechart/scripts/statechart-bstack" ]] || fail "the wrapper is missing or not executable"
  [[ -x "$AGENTS_SKILLS_DIR/statechart/scripts/tla-ts-java" ]] || fail "the java shim is missing or not executable"
  [[ -L "$HOME/.pi/agent/skills/statechart" ]] || fail "no Pi link"
  printf '[bstack]\nstatechart = false\n' >"$CONFIG"
  deploy_skills >/dev/null
  [[ ! -e "$AGENTS_SKILLS_DIR/statechart" && ! -L "$HOME/.pi/agent/skills/statechart" ]] || fail "the skill stayed after statechart went off"
}

@test "with statechart off, a statechart skill that is not bercail's stays" {
  libs
  mkdir -p "$AGENTS_SKILLS_DIR/statechart/scripts"
  printf -- '---\nname: statechart\n---\n' >"$AGENTS_SKILLS_DIR/statechart/SKILL.md"
  deploy_skills >/dev/null
  [[ -f "$AGENTS_SKILLS_DIR/statechart/SKILL.md" ]] || fail "pstack's own copy was removed"
}

@test "with statechart on, a statechart skill that is not bercail's is kept, with a warning" {
  libs
  statechart_on
  mkdir -p "$AGENTS_SKILLS_DIR/statechart/scripts/test"
  printf -- '---\nname: statechart\n---\n' >"$AGENTS_SKILLS_DIR/statechart/SKILL.md"
  local err
  err="$(deploy_skills 2>&1 >/dev/null)"
  [[ "$err" == *"keeping $AGENTS_SKILLS_DIR/statechart"* ]] || fail "no warning: $err"
  [[ ! -e "$AGENTS_SKILLS_DIR/statechart/scripts/statechart-bstack" ]] || fail "bercail's copy went over it"
  printf '[bstack]\nstatechart = false\n' >"$CONFIG"
  deploy_skills >/dev/null
  [[ -d "$AGENTS_SKILLS_DIR/statechart/scripts/test" ]] || fail "turning it off removed it"
}

@test "the bstack lead loads the statechart skill only while statechart is on" {
  libs
  # shellcheck disable=SC1091
  source "$ROOT/lib/bstack.sh"
  _bstack_pi_argv model
  [[ " ${BSTACK_PI_ARGV[*]} " != *"/skills/statechart "* ]] || fail "off, yet: ${BSTACK_PI_ARGV[*]}"
  statechart_on
  _bstack_pi_argv model
  [[ " ${BSTACK_PI_ARGV[*]} " == *" --skill $AGENTS_SKILLS_DIR/statechart "* ]] || fail "on, yet: ${BSTACK_PI_ARGV[*]}"
}

@test "doctor names statechart's missing tla-ts or node only while statechart is on" {
  libs
  local out rc=0
  out="$(_doctor_statechart)" || rc=$?
  [[ "$rc" -eq 0 && -z "$out" ]] || fail "off: exit $rc, $out"
  statechart_on
  rc=0
  out="$(_doctor_statechart)" || rc=$?
  [[ "$rc" -eq 1 && "$out" == *"missing  statechart"*"bercail reconfigure"* ]] || fail "on, no tla-ts: exit $rc, $out"
  mkdir -p "${CLI%/*}" && : >"$CLI"
  printf 'TLA_TS=%s\n' "$CLI" >"$ENV_FILE"
  rc=0
  out="$(PATH="$SYS" _doctor_statechart)" || rc=$?
  [[ "$rc" -eq 1 && "$out" == *"missing  node"* ]] || fail "on, no node: exit $rc, $out"
  ln -s "$BIN/npm" "$SYS/node"
  rc=0
  out="$(PATH="$SYS" _doctor_statechart)" || rc=$?
  [[ "$rc" -eq 0 && "$out" == *"ok  statechart (tla-ts $CLI)"* ]] || fail "on: exit $rc, $out"
}

@test "doctor counts [bstack] statechart as a key bercail reads" {
  libs
  statechart_on
  local out
  out="$(doctor_config)"
  [[ "$out" != *unknown* ]] || fail "$out"
}

# --- the wrapper -------------------------------------------------------------

# This checkout's wrapper, java shim and pi-chart beside a stand-in for upstream's
# command, which records its environment and, given --out, writes CHART there as chart.mmd.
wrapper() {
  W="$BATS_TEST_TMPDIR/skill"
  mkdir -p "$W"
  cp "$ROOT/skills/statechart/scripts/statechart-bstack" "$ROOT/skills/statechart/scripts/tla-ts-java" \
    "$ROOT/skills/statechart/scripts/pi-chart.mjs" "$W/"
  cat >"$W/statechart" <<'SH'
#!/bin/sh
printf 'TLA2TOOLS=%s JAVA=%s TLA_TS=%s\n' "$TLA2TOOLS" "$JAVA" "${TLA_TS:-}" >"$BATS_TEST_TMPDIR/upstream.env"
[ -z "${UPSTREAM_SLEEP:-}" ] || sleep "$UPSTREAM_SLEEP"
out=""
while [ $# -gt 0 ]; do
  case "$1" in --out) out=$2 ;; --out=*) out=${1#--out=} ;; esac
  shift
done
if [ -n "$out" ] && [ -n "${CHART:-}" ]; then mkdir -p "$out" && cp "$CHART" "$out/chart.mmd"; fi
exit "${UPSTREAM_EXIT:-0}"
SH
  chmod +x "$W/statechart"
}

# A tla-ts CLI (cli.js), and a TLC jar and java for the reference runs.
tools() {
  TLA_TS="$BATS_TEST_TMPDIR/cli.js"
  : >"$TLA_TS"
  : >"$BATS_TEST_TMPDIR/tla2tools.jar"
  printf '#!/bin/sh\n' >"$BIN/java"
  chmod +x "$BIN/java"
}

@test "statechart-bstack without tla-ts exits 2 with the fix, and installs nothing" {
  wrapper
  run env -u TLA2TOOLS -u JAVA -u TLA_TS PATH="$BIN:$PATH" "$W/statechart-bstack" Spec.tla
  [[ "$status" -eq 2 ]] || fail "exit $status"
  [[ "$output" == *"never installs"*"statechart = true"*"bercail reconfigure"* ]] || fail "$output"
  [[ ! -e "$BATS_TEST_TMPDIR/npm.log" && ! -e "$BATS_TEST_TMPDIR/upstream.env" ]] || fail "it ran npm or upstream"
}

@test "statechart-bstack reads statechart.env as data and runs upstream on tla-ts through the java shim" {
  wrapper
  tools
  printf 'TLA_TS=%s\n$(touch %s)\n' "$TLA_TS" "$BATS_TEST_TMPDIR/ran" >"$ENV_FILE"
  run env -u TLA2TOOLS -u JAVA -u TLA_TS "$W/statechart-bstack" Spec.tla
  [[ "$status" -eq 0 ]] || fail "exit $status: $output"
  [[ "$(cat "$BATS_TEST_TMPDIR/upstream.env")" == "TLA2TOOLS=$TLA_TS JAVA=$W/tla-ts-java TLA_TS=$TLA_TS" ]] \
    || fail "upstream saw $(cat "$BATS_TEST_TMPDIR/upstream.env")"
  [[ ! -e "$BATS_TEST_TMPDIR/ran" ]] || fail "a line of statechart.env ran"
}

@test "an old statechart.env with only TLC and java exits 2 and says to reconfigure" {
  wrapper
  tools
  printf 'TLA2TOOLS=%s\nJAVA=%s\n' "$BATS_TEST_TMPDIR/tla2tools.jar" "$BIN/java" >"$ENV_FILE"
  run env -u TLA2TOOLS -u JAVA -u TLA_TS "$W/statechart-bstack" Spec.tla
  [[ "$status" -eq 2 && "$output" == *"bercail reconfigure"* ]] || fail "exit $status: $output"
  [[ ! -e "$BATS_TEST_TMPDIR/upstream.env" ]] || fail "upstream ran"
}

@test "a relative TLA_TS reaches upstream as an absolute path" {
  wrapper
  tools
  cd "$BATS_TEST_TMPDIR"
  run env -u TLA2TOOLS -u JAVA TLA_TS=cli.js "$W/statechart-bstack" Spec.tla
  [[ "$status" -eq 0 ]] || fail "exit $status: $output"
  [[ "$(cat "$BATS_TEST_TMPDIR/upstream.env")" == "TLA2TOOLS=$TLA_TS JAVA=$W/tla-ts-java TLA_TS=$TLA_TS" ]] \
    || fail "upstream saw $(cat "$BATS_TEST_TMPDIR/upstream.env")"
}

@test "TLA_TS in the environment wins over statechart.env" {
  wrapper
  tools
  printf 'TLA_TS=/missing/cli.js\n' >"$ENV_FILE"
  run env -u TLA2TOOLS -u JAVA TLA_TS="$TLA_TS" "$W/statechart-bstack" Spec.tla
  [[ "$status" -eq 0 ]] || fail "exit $status: $output"
}

@test "TLA2TOOLS and JAVA set together run upstream on TLC, over TLA_TS, as absolute paths" {
  wrapper
  tools
  cd "$BATS_TEST_TMPDIR"
  run env TLA_TS="$TLA_TS" TLA2TOOLS=tla2tools.jar JAVA=bin/java "$W/statechart-bstack" Spec.tla
  [[ "$status" -eq 0 ]] || fail "exit $status: $output"
  [[ "$(cat "$BATS_TEST_TMPDIR/upstream.env")" == "TLA2TOOLS=$BATS_TEST_TMPDIR/tla2tools.jar JAVA=$BIN/java TLA_TS=$TLA_TS" ]] \
    || fail "upstream saw $(cat "$BATS_TEST_TMPDIR/upstream.env")"
}

@test "only one of TLA2TOOLS and JAVA set exits 2 rather than mix TLC and tla-ts" {
  wrapper
  tools
  printf 'TLA_TS=%s\n' "$TLA_TS" >"$ENV_FILE"
  run env -u TLA2TOOLS JAVA="$BIN/java" "$W/statechart-bstack" Spec.tla
  [[ "$status" -eq 2 && "$output" == *"both"* ]] || fail "JAVA alone: exit $status: $output"
  run env -u JAVA TLA2TOOLS="$BATS_TEST_TMPDIR/tla2tools.jar" "$W/statechart-bstack" Spec.tla
  [[ "$status" -eq 2 && "$output" == *"both"* ]] || fail "TLA2TOOLS alone: exit $status: $output"
  [[ ! -e "$BATS_TEST_TMPDIR/upstream.env" ]] || fail "upstream ran"
}

@test "the java shim runs tla-ts as TLC 1.7.4 with upstream's java arguments" {
  wrapper
  tools
  printf '#!/bin/sh\nprintf "%%s\\n" "$@" >"$BATS_TEST_TMPDIR/node.args"\n' >"$BIN/node"
  chmod +x "$BIN/node"
  run env PATH="$BIN:$PATH" TLA_TS="$TLA_TS" "$W/tla-ts-java" -Djava.io.tmpdir=/t -cp "$TLA_TS" tlc2.TLC -tool Spec
  [[ "$status" -eq 0 ]] || fail "exit $status: $output"
  [[ "$(cat "$BATS_TEST_TMPDIR/node.args")" == "$TLA_TS"$'\n-Dtla-ts.tlc=1.7.4\n-Djava.io.tmpdir=/t\n-cp\n'"$TLA_TS"$'\ntlc2.TLC\n-tool\nSpec' ]] \
    || fail "node ran with: $(cat "$BATS_TEST_TMPDIR/node.args")"
}

@test "statechart-bstack without timeout from coreutils exits 2 with the fix" {
  wrapper
  tools
  mkdir -p "$BATS_TEST_TMPDIR/no-timeout"
  for cmd in sh sed tail dirname readlink cat; do ln -s "$(command -v "$cmd")" "$BATS_TEST_TMPDIR/no-timeout/$cmd"; done
  run env PATH="$BATS_TEST_TMPDIR/no-timeout" TLA_TS="$TLA_TS" \
    "$BATS_TEST_TMPDIR/no-timeout/sh" "$W/statechart-bstack" Spec.tla
  [[ "$status" -eq 2 && "$output" == *"install coreutils"* ]] || fail "exit $status: $output"
  [[ ! -e "$BATS_TEST_TMPDIR/upstream.env" ]] || fail "upstream ran with no bound"
}

@test "a statechart-bstack run past STATECHART_TIMEOUT stops and exits 2" {
  need timeout
  wrapper
  tools
  SECONDS=0
  run env TLA_TS="$TLA_TS" STATECHART_TIMEOUT=1 UPSTREAM_SLEEP=30 \
    "$W/statechart-bstack" Spec.tla
  [[ "$status" -eq 2 && "$output" == *"stopped after 1s (STATECHART_TIMEOUT)"* ]] || fail "exit $status: $output"
  ((SECONDS < 15)) || fail "it ran ${SECONDS}s"
}

# A chart.mmd as upstream writes it, with N states in a row, the first two on the
# path to the Rule bug and the last one breaking it.
chart_of() {
  local n="$1" i
  {
    printf 'stateDiagram-v2\n  direction LR\n  state "Legend" as legend {\n    lg0: Breaks Rule\n    lg1: Path to the Rule bug\n  }\n'
    printf '  class lg0 breaks\n  class lg1 bugPath\n'
    for ((i = 0; i < n; i++)); do printf '  s%d: state #34;%d#34;\n' "$i" "$i"; done
    printf '  [*] --> s0\n'
    for ((i = 1; i < n; i++)); do printf '  s%d --> s%d: step %d\n' "$((i - 1))" "$i" "$i"; done
    printf '  classDef breaks fill:#ffecee\n  class s%d breaks\n  class s1 bugPath\n  class s0 bugPath\n' "$((n - 1))"
  } >"$BATS_TEST_TMPDIR/chart.mmd"
}

@test "chart.pi.md has a chart of 20 states with no Legend or classes, the breaking state in words, and every arrow" {
  need node
  wrapper
  tools
  chart_of 20
  run env TLA_TS="$TLA_TS" CHART="$BATS_TEST_TMPDIR/chart.mmd" UPSTREAM_EXIT=1 \
    "$W/statechart-bstack" Spec.tla --out "$BATS_TEST_TMPDIR/out"
  [[ "$status" -eq 1 ]] || fail "exit $status: $output"
  post="$(cat "$BATS_TEST_TMPDIR/out/chart.pi.md")"
  [[ "$post" == '```mermaid'*'direction TB'*'```'* ]] || fail "no chart, top to bottom: $post"
  [[ "$post" != *Legend* && "$post" != *"class s"* && "$post" != *classDef* ]] || fail "Pi draws neither: $post"
  [[ "$post" == *$'\nBreaks Rule: state "19".\n'* ]] || fail "the breaking state is not named: $post"
  [[ "$post" == *$'\nStates on the path to the Rule bug (report.md has the order): state "0"; state "1".\n'* ]] \
    || fail "the bug path's states, or that their order is in report.md: $post"
  [[ "$post" == *$'- start -> state "0"\n'* && "$post" == *'- state "18" -> state "19": step 19'* ]] || fail "arrows: $post"
}

@test "chart.pi.md says a [*] inside a parent starts that parent, not the chart" {
  need node
  wrapper
  tools
  # Upstream draws a parent's only way in as an arrow to the parent and a [*] inside it.
  printf '%s\n' 'stateDiagram-v2' '  s0: Signed out' '  state "Trying to sign in" as s1 {' '    s2: Checking' \
    '    [*] --> s2' '  }' '  [*] --> s0' '  s0 --> s1: Submit' >"$BATS_TEST_TMPDIR/chart.mmd"
  run env TLA_TS="$TLA_TS" CHART="$BATS_TEST_TMPDIR/chart.mmd" \
    "$W/statechart-bstack" Spec.tla --out "$BATS_TEST_TMPDIR/out"
  [[ "$status" -eq 0 ]] || fail "exit $status: $output"
  post="$(cat "$BATS_TEST_TMPDIR/out/chart.pi.md")"
  [[ "$post" == *$'\n- start of Trying to sign in -> Trying to sign in › Checking\n'* ]] || fail "the parent's start: $post"
  [[ "$post" == *$'\n- start -> Signed out\n'* && "$post" == *$'\n- Signed out -> Trying to sign in: Submit'* ]] || fail "arrows: $post"
}

@test "over 20 states, chart.pi.md has no chart and sends the reader to report.md's path" {
  need node
  wrapper
  tools
  chart_of 21
  run env TLA_TS="$TLA_TS" CHART="$BATS_TEST_TMPDIR/chart.mmd" \
    "$W/statechart-bstack" Spec.tla --out="$BATS_TEST_TMPDIR/out"
  [[ "$status" -eq 0 ]] || fail "exit $status: $output"
  post="$(cat "$BATS_TEST_TMPDIR/out/chart.pi.md")"
  [[ "$post" != *'```'* && "$post" == *"21 states"*"report.md"* ]] || fail "$post"
}

@test "the statechart skill's UPSTREAM.md records the commit lib/deps.json knows" {
  local known record="$ROOT/skills/statechart/UPSTREAM.md"
  known="$(jq -r '.[] | select(.name == "pstack-statechart") | .known' "$ROOT/lib/deps.json")"
  [[ "$known" =~ ^[0-9a-f]{40}$ ]] || fail "lib/deps.json knows no pstack-statechart commit: $known"
  grep -q "^- Commit: $known " "$record" || fail "UPSTREAM.md names another commit than lib/deps.json ($known)"
}

# --- the TLC cross-check -------------------------------------------------------

# A copy of the repo's layout with this checkout's cross-check.sh and lockfile,
# a stand-in statechart-bstack that writes what REPORT_ and GRAPH_TLA_TS or _TLC
# say, exits EXIT_TLA_TS or EXIT_TLC, skips report.md when NO_REPORT_<engine> is
# set or its folder holds SKIP_IN, and logs the tla-ts it was given; a spec with two configs; and a
# sha256sum that gives tla2tools.jar 1.7.4's sum for GOOD_JAR alone.
cross() {
  REPO="$BATS_TEST_TMPDIR/repo"
  SPEC="$BATS_TEST_TMPDIR/specs/door"
  mkdir -p "$REPO/tests/statechart" "$REPO/skills/statechart/scripts" "$REPO/lib" "$SPEC"
  cp "$ROOT/tests/statechart/cross-check.sh" "$REPO/tests/statechart/"
  cp -R "$ROOT/lib/statechart" "$REPO/lib/"
  : >"$SPEC/Door.tla"
  : >"$SPEC/view.mjs"
  : >"$SPEC/full.cfg"
  : >"$SPEC/replay.cfg"
  cat >"$REPO/skills/statechart/scripts/statechart-bstack" <<'SH'
#!/bin/sh
if [ -n "${JAVA:-}" ]; then engine=TLC; else engine=TLA_TS; fi
printf '%s %s\n' "$engine" "${TLA_TS:-}" >>"$BATS_TEST_TMPDIR/engines.log"
eval "report=\${REPORT_$engine:-same} code=\${EXIT_$engine:-0} graph=\${GRAPH_$engine:-same} skip=\${NO_REPORT_$engine:-}"
if [ "$1" = graph ]; then printf '%s\n' "$graph" >"$4"; exit 0; fi
out=""
while [ $# -gt 0 ]; do [ "$1" = --out ] && out=$2; shift; done
mkdir -p "$out"
case "$PWD" in *"${SKIP_IN:-//}"*) skip=1 ;; esac
[ -n "$skip" ] || printf '%s\n' "$report" >"$out/report.md"
exit "$code"
SH
  printf '#!/bin/sh\n[ "$1" = "$GOOD_JAR" ] && s=936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88 || s=0000\necho "$s  $1"\n' \
    >"$BIN/sha256sum"
  chmod +x "$REPO/skills/statechart/scripts/statechart-bstack" "$BIN/sha256sum"
  : >"$BATS_TEST_TMPDIR/tla2tools.jar"
  printf '#!/bin/sh\n' >"$BIN/java"
  chmod +x "$BIN/java"
  export GOOD_JAR="$BATS_TEST_TMPDIR/tla2tools.jar"
}

cross_check() {
  run env PATH="$BIN:$PATH" TLA2TOOLS="$BATS_TEST_TMPDIR/tla2tools.jar" JAVA="$BIN/java" \
    "$REPO/tests/statechart/cross-check.sh" "$SPEC"
}

@test "cross-check passes when tla-ts and TLC write the same verdicts, reports and graph" {
  cross
  cross_check
  [[ "$status" -eq 0 ]] || fail "exit $status: $output"
  [[ "$output" == *"door/full"*"same (exit 0)"* && "$output" == *"door/replay"*"same (exit 0)"* ]] || fail "$output"
}

@test "cross-check runs the tla-ts the lockfile pins, installed fresh, not the one in TLA_TS" {
  cross
  TLA_TS=/old/tla-ts/dist/cli.js cross_check
  [[ "$status" -eq 0 ]] || fail "exit $status: $output"
  grep -q '^ci --prefix ' "$BATS_TEST_TMPDIR/npm.log" || fail "no npm ci: $(cat "$BATS_TEST_TMPDIR/npm.log" 2>/dev/null)"
  [[ "$output" == *"tla-ts 0.0.10 against TLC 1.7.4"* ]] || fail "no version line: $output"
  ! grep -q /old/ "$BATS_TEST_TMPDIR/engines.log" || fail "it ran the old tla-ts: $(cat "$BATS_TEST_TMPDIR/engines.log")"
  grep -q '^TLA_TS /.*/node_modules/tla-ts/dist/cli.js$' "$BATS_TEST_TMPDIR/engines.log" || fail "$(cat "$BATS_TEST_TMPDIR/engines.log")"
}

@test "cross-check names the config and the file where TLC and tla-ts differ, and goes on to the next" {
  cross
  REPORT_TLC="Rule breaks" cross_check
  [[ "$status" -eq 1 ]] || fail "exit $status: $output"
  [[ "$output" == *"door/full"*"differs: report.md"* ]] || fail "$output"
  [[ "$output" == *"door/replay"*"differs: report.md"* ]] || fail "it stopped after the first: $output"
  EXIT_TLC=1 cross_check
  [[ "$status" -eq 1 && "$output" == *"door/full"*"exit 0/1"* ]] || fail "exit codes: $status: $output"
}

@test "cross-check fails on a replay graph that differs between the engines" {
  cross
  GRAPH_TLC="other" cross_check
  [[ "$status" -eq 1 && "$output" == *"door/replay"*"graph"* ]] || fail "$status: $output"
  [[ "$output" == *"door/full"*same* ]] || fail "a config with no graph: $output"
}

@test "cross-check takes only holds or breaks as verdicts, and needs a report from each engine" {
  cross
  EXIT_TLC=2 EXIT_TLA_TS=2 cross_check
  [[ "$status" -eq 1 && "$output" == *"door/full"*"exit 2 on tla-ts"* ]] || fail "both 2: $status: $output"
  EXIT_TLC=126 EXIT_TLA_TS=126 cross_check
  [[ "$status" -eq 1 && "$output" == *"door/full"*"exit 126 on tla-ts"* ]] || fail "both 126: $status: $output"
  NO_REPORT_TLC=1 NO_REPORT_TLA_TS=1 cross_check
  [[ "$status" -eq 1 && "$output" == *"door/full"*"no report.md on tla-ts"* ]] || fail "no reports: $status: $output"
}

@test "cross-check keeps each spec's outputs apart when two spec folders share a name" {
  cross
  mkdir -p "$BATS_TEST_TMPDIR/right"
  cp -R "$SPEC" "$BATS_TEST_TMPDIR/right/"
  SKIP_IN=/right/ run env PATH="$BIN:$PATH" TLA2TOOLS="$BATS_TEST_TMPDIR/tla2tools.jar" JAVA="$BIN/java" \
    "$REPO/tests/statechart/cross-check.sh" "$SPEC" "$BATS_TEST_TMPDIR/right/door"
  [[ "$status" -eq 1 && "$output" == *"door/full"*"no report.md on tla-ts"* ]] || fail "$status: $output"
}

@test "cross-check refuses a tla2tools.jar that is not 1.7.4's, by its sha256, and needs JAVA" {
  cross
  : >"$BATS_TEST_TMPDIR/other.jar"
  run env PATH="$BIN:$PATH" TLA2TOOLS="$BATS_TEST_TMPDIR/other.jar" JAVA="$BIN/java" \
    "$REPO/tests/statechart/cross-check.sh" "$SPEC"
  [[ "$status" -eq 2 && "$output" == *"not tla2tools.jar 1.7.4"*"releases/download/v1.7.4/tla2tools.jar"* ]] || fail "$status: $output"
  run env -u JAVA PATH="$BIN:$PATH" TLA2TOOLS="$BATS_TEST_TMPDIR/tla2tools.jar" "$REPO/tests/statechart/cross-check.sh" "$SPEC"
  [[ "$status" -eq 2 && "$output" == *"JAVA"* ]] || fail "no java: $status: $output"
  [[ ! -e "$BATS_TEST_TMPDIR/engines.log" ]] || fail "it ran a check"
}

@test "cross-check hands TLC absolute paths when TLA2TOOLS and JAVA are relative" {
  cross
  cd "$BATS_TEST_TMPDIR"
  run env PATH="$BIN:$PATH" TLA2TOOLS=./tla2tools.jar JAVA=bin/java \
    "$REPO/tests/statechart/cross-check.sh" "$SPEC"
  [[ "$status" -eq 0 ]] || fail "exit $status: $output"
  [[ "$output" == *"against TLC 1.7.4 ($BIN/java)"* ]] || fail "$output"
}

# --- the Shep inbox spec, on the real tla-ts -----------------------------------

@test "check.sh on tla-ts: the Shep inbox's verdicts hold, and it writes the chart and graph the repo keeps" {
  local env="$TEST_REAL_HOME/.local/share/bercail/statechart.env" tree="$BATS_TEST_TMPDIR/tree"
  export TLA_TS="${TLA_TS:-$(sed -n 's/^TLA_TS=//p' "$env" 2>/dev/null)}"
  [[ -r "$TLA_TS" ]] || unavailable "no tla-ts: set [bstack] statechart = true, or TLA_TS (CI installs it from lib/statechart)"
  need node
  unset TLA2TOOLS JAVA
  mkdir -p "$tree/tests/statechart" "$tree/skills"
  cp -R "$ROOT/tests/statechart/shep-inbox" "$tree/tests/statechart/"
  cp -R "$ROOT/skills/statechart" "$tree/skills/"
  PATH="$BIN:$PATH" run "$tree/tests/statechart/shep-inbox/check.sh"
  [[ "$status" -eq 0 ]] || fail "$output"
  diff -r "$ROOT/tests/statechart/shep-inbox" "$tree/tests/statechart/shep-inbox" || fail "check.sh changed what the repo keeps: rerun it"
}
