#!/usr/bin/env bats
# The statechart skill: [bstack] statechart installs TLC and Java and deploys the
# skill only when on, and its wrapper never installs, reads statechart.env as
# data, bounds each run, and writes the post for Pi's chat. Each @test is its
# own HOME; mise, java and upstream's command are stand-ins.

# shellcheck disable=SC2016 # single-quoted text is stand-in code.
# shellcheck disable=SC2034 # DRY_RUN and friends are read by the sourced libs.
# shellcheck disable=SC2329 # stubs replace lib functions the libs call.

setup() {
  load test_helper
  isolate
  BIN="$BATS_TEST_TMPDIR/bin"
  CONFIG="$HOME/.config/bercail/config.toml"
  ENV_FILE="$HOME/.local/share/bercail/statechart.env"
  mkdir -p "${CONFIG%/*}" "${ENV_FILE%/*}"
  # The only commands the functions under test may find: no system java.
  SYS="$BATS_TEST_TMPDIR/sys"
  mkdir -p "$SYS"
  for cmd in bash sh sed head dirname mkdir awk jq rm cat readlink tail chmod; do
    ln -s "$(command -v "$cmd")" "$SYS/$cmd"
  done
  # mise: logs each call; install makes what where and which find.
  cat >"$BIN/mise" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$BATS_TEST_TMPDIR/mise.log"
root="$BATS_TEST_TMPDIR/mise-installs"
case "$1" in
  install)
    shift
    quiet=0
    if [ "$1" = --quiet ]; then quiet=1; shift; fi
    for spec in "$@"; do
      if [ "$spec" = "${MISE_FAIL_SPEC:-}" ]; then
        echo "mise ERROR $spec download failed" >&2
        exit 1
      fi
      case "$spec" in
        http:tla2tools*) mkdir -p "$root/tla" && : >"$root/tla/tla2tools.jar" ;;
        java@temurin-25) mkdir -p "$root/temurin/bin" && printf '#!/bin/sh\n' >"$root/temurin/bin/java" && chmod +x "$root/temurin/bin/java" ;;
      esac
      if [ "$quiet" -eq 0 ]; then
        echo "mise WARN $spec installed but not activated — it is not in any config file." >&2
      fi
    done ;;
  where) [ -d "$root/tla" ] && echo "$root/tla" ;;
  which) [ -x "$root/temurin/bin/java" ] && echo "$root/temurin/bin/java" ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$BIN/mise"
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

# A java on PATH that says it is VERSION.
java_on_path() {
  printf '#!/bin/sh\necho "openjdk version \\"%s\\" 2026-01-01" >&2\n' "$1" >"$BIN/java"
  chmod +x "$BIN/java"
}

@test "with statechart off, nothing is installed and statechart.env goes" {
  libs
  printf 'TLA2TOOLS=/old.jar\n' >"$ENV_FILE"
  PATH="$BIN:$SYS" ensure_statechart_tools
  [[ ! -e "$BATS_TEST_TMPDIR/mise.log" ]] || fail "mise ran: $(cat "$BATS_TEST_TMPDIR/mise.log")"
  [[ ! -e "$ENV_FILE" ]] || fail "statechart.env is still there"
}

@test "with statechart on and java 11 or later on PATH, mise installs only TLC, pinned by its sha256" {
  libs
  statechart_on
  java_on_path 21.0.2
  local output
  output="$(PATH="$BIN:$SYS" ensure_statechart_tools 2>&1)"
  [[ "$output" != *"mise WARN"* ]] || fail "activation warning: $output"
  grep -qxF "install --quiet $STATECHART_TLC_SPEC" "$BATS_TEST_TMPDIR/mise.log" || fail "no TLC install: $(cat "$BATS_TEST_TMPDIR/mise.log")"
  ! grep -q '^use' "$BATS_TEST_TMPDIR/mise.log" || fail "mise use changed the global tools"
  [[ "$STATECHART_TLC_SPEC" == *checksum=sha256:936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88* ]] \
    || fail "the TLC spec has no sha256"
  ! grep -q temurin "$BATS_TEST_TMPDIR/mise.log" || fail "mise installed a JDK beside java 21"
  [[ "$(cat "$ENV_FILE")" == "TLA2TOOLS=$BATS_TEST_TMPDIR/mise-installs/tla/tla2tools.jar"$'\n'"JAVA=$BIN/java" ]] \
    || fail "statechart.env: $(cat "$ENV_FILE")"
}

@test "with statechart on and only java 8 on PATH, mise installs temurin 25 without making it the global java" {
  libs
  statechart_on
  printf '#!/bin/sh\necho "java version \\"1.8.0_391\\"" >&2\n' >"$BIN/java"
  chmod +x "$BIN/java"
  local output
  output="$(PATH="$BIN:$SYS" ensure_statechart_tools 2>&1)"
  [[ "$output" != *"mise WARN"* ]] || fail "activation warning: $output"
  grep -qx 'install --quiet java@temurin-25' "$BATS_TEST_TMPDIR/mise.log" || fail "no temurin install: $(cat "$BATS_TEST_TMPDIR/mise.log")"
  ! grep -q '^use' "$BATS_TEST_TMPDIR/mise.log" || fail "mise use changed the global tools"
  grep -qx "JAVA=$BATS_TEST_TMPDIR/mise-installs/temurin/bin/java" "$ENV_FILE" || fail "statechart.env: $(cat "$ENV_FILE")"
}

@test "a failed TLC install keeps mise's error visible and does not write statechart.env" {
  statechart_on
  java_on_path 21.0.2
  run env PATH="$BIN:$SYS" \
    bash -c 'for l in common detect deps config; do source "$1/lib/$l.sh"; done; export MISE_FAIL_SPEC="$STATECHART_TLC_SPEC"; ensure_statechart_tools' _ "$ROOT"
  [[ "$status" -eq 1 ]] || fail "exit $status: $output"
  [[ "$output" == *"mise ERROR http:tla2tools"*"download failed"* ]] || fail "no install error: $output"
  [[ ! -e "$ENV_FILE" ]] || fail "statechart.env was written"
  ! grep -q '^use' "$BATS_TEST_TMPDIR/mise.log" || fail "mise use changed the global tools"
}

@test "a failed Java install keeps mise's error visible and does not write statechart.env" {
  statechart_on
  run env PATH="$BIN:$SYS" MISE_FAIL_SPEC=java@temurin-25 \
    bash -c 'for l in common detect deps config; do source "$1/lib/$l.sh"; done; ensure_statechart_tools' _ "$ROOT"
  [[ "$status" -eq 1 ]] || fail "exit $status: $output"
  [[ "$output" == *"mise ERROR java@temurin-25 download failed"* ]] || fail "no install error: $output"
  [[ ! -e "$ENV_FILE" ]] || fail "statechart.env was written"
  ! grep -q '^use' "$BATS_TEST_TMPDIR/mise.log" || fail "mise use changed the global tools"
}

@test "with statechart on and no mise, the warning says what to install and statechart.env is not written" {
  statechart_on
  java_on_path 21.0.2
  rm "$BIN/mise"
  run env PATH="$BIN:$SYS" bash -c 'for l in common detect deps config; do source "$1/lib/$l.sh"; done; ensure_statechart_tools' _ "$ROOT"
  [[ "$status" -eq 1 ]] || fail "exit $status: $output"
  [[ "$output" == *"install mise"*"bercail reconfigure"* ]] || fail "no fix in: $output"
  [[ ! -e "$ENV_FILE" ]] || fail "statechart.env was written"
}

@test "deploy_skills deploys statechart for Pi only while statechart is on" {
  libs
  statechart_on
  deploy_skills >/dev/null
  [[ -x "$AGENTS_SKILLS_DIR/statechart/scripts/statechart-bstack" ]] || fail "the wrapper is missing or not executable"
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

@test "doctor names statechart's missing TLC or java only while statechart is on" {
  libs
  local out rc=0
  out="$(_doctor_statechart)" || rc=$?
  [[ "$rc" -eq 0 && -z "$out" ]] || fail "off: exit $rc, $out"
  statechart_on
  rc=0
  out="$(_doctor_statechart)" || rc=$?
  [[ "$rc" -eq 1 && "$out" == *"missing  statechart"*"bercail reconfigure"* ]] || fail "on: exit $rc, $out"
}

@test "doctor counts [bstack] statechart as a key bercail reads" {
  libs
  statechart_on
  local out
  out="$(doctor_config)"
  [[ "$out" != *unknown* ]] || fail "$out"
}

# --- the wrapper -------------------------------------------------------------

# This checkout's wrapper and pi-chart beside a stand-in for upstream's command,
# which records its environment and, given --out, writes CHART there as chart.mmd.
wrapper() {
  W="$BATS_TEST_TMPDIR/skill"
  mkdir -p "$W"
  cp "$ROOT/skills/statechart/scripts/statechart-bstack" "$ROOT/skills/statechart/scripts/pi-chart.mjs" "$W/"
  cat >"$W/statechart" <<'SH'
#!/bin/sh
printf 'TLA2TOOLS=%s JAVA=%s\n' "$TLA2TOOLS" "$JAVA" >"$BATS_TEST_TMPDIR/upstream.env"
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

tools() {
  : >"$BATS_TEST_TMPDIR/tla2tools.jar"
  printf '#!/bin/sh\n' >"$BIN/java"
  chmod +x "$BIN/java"
}

@test "statechart-bstack without TLC and java exits 2 with the fix, and installs nothing" {
  wrapper
  run env -u TLA2TOOLS -u JAVA PATH="$BIN:$PATH" "$W/statechart-bstack" Spec.tla
  [[ "$status" -eq 2 ]] || fail "exit $status"
  [[ "$output" == *"never installs"*"statechart = true"*"bercail reconfigure"* ]] || fail "$output"
  [[ ! -e "$BATS_TEST_TMPDIR/mise.log" && ! -e "$BATS_TEST_TMPDIR/upstream.env" ]] || fail "it ran mise or upstream"
}

@test "statechart-bstack reads statechart.env as data and hands both paths to upstream" {
  wrapper
  tools
  printf 'TLA2TOOLS=%s\nJAVA=%s\n$(touch %s)\n' "$BATS_TEST_TMPDIR/tla2tools.jar" "$BIN/java" "$BATS_TEST_TMPDIR/ran" >"$ENV_FILE"
  run env -u TLA2TOOLS -u JAVA "$W/statechart-bstack" Spec.tla
  [[ "$status" -eq 0 ]] || fail "exit $status: $output"
  [[ "$(cat "$BATS_TEST_TMPDIR/upstream.env")" == "TLA2TOOLS=$BATS_TEST_TMPDIR/tla2tools.jar JAVA=$BIN/java" ]] \
    || fail "upstream saw $(cat "$BATS_TEST_TMPDIR/upstream.env")"
  [[ ! -e "$BATS_TEST_TMPDIR/ran" ]] || fail "a line of statechart.env ran"
}

@test "TLA2TOOLS and JAVA in the environment win over statechart.env" {
  wrapper
  tools
  printf 'TLA2TOOLS=/missing.jar\nJAVA=/missing-java\n' >"$ENV_FILE"
  run env TLA2TOOLS="$BATS_TEST_TMPDIR/tla2tools.jar" JAVA="$BIN/java" "$W/statechart-bstack" Spec.tla
  [[ "$status" -eq 0 ]] || fail "exit $status: $output"
}

@test "statechart-bstack without timeout from coreutils exits 2 with the fix" {
  wrapper
  tools
  mkdir -p "$BATS_TEST_TMPDIR/no-timeout"
  for cmd in sh sed tail dirname readlink cat; do ln -s "$(command -v "$cmd")" "$BATS_TEST_TMPDIR/no-timeout/$cmd"; done
  run env PATH="$BATS_TEST_TMPDIR/no-timeout" TLA2TOOLS="$BATS_TEST_TMPDIR/tla2tools.jar" JAVA="$BIN/java" \
    "$BATS_TEST_TMPDIR/no-timeout/sh" "$W/statechart-bstack" Spec.tla
  [[ "$status" -eq 2 && "$output" == *"install coreutils"* ]] || fail "exit $status: $output"
  [[ ! -e "$BATS_TEST_TMPDIR/upstream.env" ]] || fail "upstream ran with no bound"
}

@test "a statechart-bstack run past STATECHART_TIMEOUT stops and exits 2" {
  need timeout
  wrapper
  tools
  SECONDS=0
  run env TLA2TOOLS="$BATS_TEST_TMPDIR/tla2tools.jar" JAVA="$BIN/java" STATECHART_TIMEOUT=1 UPSTREAM_SLEEP=30 \
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
  run env TLA2TOOLS="$BATS_TEST_TMPDIR/tla2tools.jar" JAVA="$BIN/java" CHART="$BATS_TEST_TMPDIR/chart.mmd" UPSTREAM_EXIT=1 \
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
  run env TLA2TOOLS="$BATS_TEST_TMPDIR/tla2tools.jar" JAVA="$BIN/java" CHART="$BATS_TEST_TMPDIR/chart.mmd" \
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
  run env TLA2TOOLS="$BATS_TEST_TMPDIR/tla2tools.jar" JAVA="$BIN/java" CHART="$BATS_TEST_TMPDIR/chart.mmd" \
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

# --- the Shep inbox spec, with the real TLC ------------------------------------

# bats test_tags=live
@test "check.sh: TLC's verdicts hold for the Shep inbox, and the committed chart and graph are current" {
  local env="$TEST_REAL_HOME/.local/share/bercail/statechart.env" tree="$BATS_TEST_TMPDIR/tree"
  export TLA2TOOLS="${TLA2TOOLS:-$(sed -n 's/^TLA2TOOLS=//p' "$env" 2>/dev/null)}"
  export JAVA="${JAVA:-$(sed -n 's/^JAVA=//p' "$env" 2>/dev/null)}"
  [[ -r "$TLA2TOOLS" && -x "$JAVA" ]] || skip "no TLC: set [bstack] statechart = true, or TLA2TOOLS and JAVA"
  need node
  mkdir -p "$tree/tests/statechart" "$tree/skills"
  cp -R "$ROOT/tests/statechart/shep-inbox" "$tree/tests/statechart/"
  cp -R "$ROOT/skills/statechart" "$tree/skills/"
  PATH="$BIN:$PATH" run "$tree/tests/statechart/shep-inbox/check.sh"
  [[ "$status" -eq 0 ]] || fail "$output"
  diff -r "$ROOT/tests/statechart/shep-inbox" "$tree/tests/statechart/shep-inbox" || fail "check.sh changed what the repo keeps: rerun it"
}
