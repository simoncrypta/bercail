#!/usr/bin/env bash
# Drive this checkout's bercail in a throwaway HOME. See SKILL.md.
# usage: run.sh [evidence-dir]   default: <repo>/.bercail/verify/<timestamp>
set -uo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# The whole drive holds one machine-wide test slot (lib/slots.sh); the suite
# it runs is inside it and takes no other.
# shellcheck source=lib/slots.sh
source "$repo/lib/slots.sh"
if ! slot_held; then
  slot_run verify-bercail bash "$repo/.agents/skills/verify-bercail/run.sh" "$@"
  exit
fi
evidence="${1:-$repo/.bercail/verify/$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$evidence"
evidence="$(cd "$evidence" && pwd)"
real_pi="$(mise which pi 2>/dev/null || command -v pi || true)"
# Resolved here: a mise shim on PATH would read the box's HOME.
real_node="$(mise which node 2>/dev/null || command -v node || true)"

# --- tests: tests/run.sh fails a run that wrote the real state ---
box=""
trap 'rm -rf ${box:+"$box"}' EXIT
tests_rc=0
bash "$repo/tests/run.sh" >"$evidence/tests.out" 2>&1 </dev/null || tests_rc=$?

# --- launch: nothing below can reach the real HOME or a real Herdr core ---
box="$(mktemp -d)"
unset BASH_ENV HC_TERMINAL_ID HC_SESSION HC_SCOPE HC_TERMINAL_SOCKET
export __MISE_BASH_ENV_LOADED=1
export HOME="$box/home" XDG_CONFIG_HOME="$box/home/.config" XDG_DATA_HOME="$box/home/.local/share" XDG_CACHE_HOME="$box/home/.cache"
export XDG_STATE_HOME="$box/state" XDG_RUNTIME_DIR="$box/run" INSTALL_SRC="$repo"
export HC_BIN="$box/bin/hc" HC_CALLS="$evidence/hc-calls.log" REAL_PI="$real_pi" REAL_NODE="$real_node"
# A desk's sweep takes this as /tmp: the run never removes anything from the real one.
export BERCAIL_TMP_ROOT="$box/system-tmp"
export PATH="$box/bin:$PATH"
mkdir -p "$HOME" "$XDG_RUNTIME_DIR" "$box/bin" "$BERCAIL_TMP_ROOT" "$XDG_STATE_HOME/bercail/desk-sessions" "$XDG_CONFIG_HOME/bercail"
: >"$HC_CALLS"

# Pi, offline: the real version, a catalog with one Claude model, no login, and
# an install that fetches nothing (the bridge would come from npm).
cat >"$box/bin/pi" <<'PI'
#!/usr/bin/env bash
case "$1" in
  --version) if [[ -n "$REAL_PI" ]]; then "$REAL_PI" --version; else echo 1.5.2; fi ;;
  --offline) printf 'provider model context max-out thinking images\nclaude-bridge claude-opus-5-5 1M 128K yes yes\n' ;;
  install) exit 0 ;;
  auth) printf '{"status":"not_ready"}\n'; exit 1 ;;
  *) exit 1 ;;
esac
PI
chmod +x "$box/bin/pi"

# hc: one live desk at a bare shell. Every call is logged.
cat >"$box/bin/hc" <<'HC'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$HC_CALLS"
case "$1" in
  ls) printf '{"terminals":[{"address":"t1","state":"live"}]}\n' ;;
  get) printf '%s\n' '{"state":"live","reason":null,"reported":false,"pid":7,"argv":["/usr/bin/bash"],"foreground":{"name":"bash","pid":7},"labels":{"bercail.role":"agent","bercail.space":"sp1"},"records":[]}' ;;
  send | run) exit 0 ;;
  *) exit 1 ;;
esac
HC
chmod +x "$box/bin/hc"

cat >"$XDG_CONFIG_HOME/bercail/config.toml" <<'TOML'
[bstack]
claude = "claude-bridge/claude-opus-5-5:high"
TOML

bercail="$repo/bin/bercail"
failed=0
# step NAME MAX_EXIT CMD...: output to NAME.out, exit code to the summary.
step() {
  local name="$1" max="$2" rc=0
  shift 2
  "$@" >"$evidence/$name.out" 2>&1 </dev/null || rc=$?
  printf '%s\t%s\t%s\n' "$name" "$rc" "$*" >>"$evidence/summary.tsv"
  if ((rc > max)); then
    printf 'FAIL %s: exit %s (see %s/%s.out)\n' "$name" "$rc" "$evidence" "$name" >&2
    failed=1
  fi
}
# check NAME COMMAND...: a claim about the state the run left.
check() {
  local name="$1"
  shift
  if "$@" >/dev/null; then
    printf 'ok\t%s\n' "$name" >>"$evidence/checks.tsv"
  else
    printf 'FAIL\t%s\n' "$name" >>"$evidence/checks.tsv"
    printf 'FAIL %s\n' "$name" >&2
    failed=1
  fi
}
: >"$evidence/summary.tsv"
: >"$evidence/checks.tsv"

printf '%s\t%s\t%s\n' tests "$tests_rc" "bash tests/run.sh" >>"$evidence/summary.tsv"
check "tests pass" test "$tests_rc" -eq 0

profile="$HOME/.local/share/bercail/pi"
templates="$XDG_CONFIG_HOME/herdr-core/templates"
out_has() { grep -qF -- "$2" "$evidence/$1.out"; }
absent() { [[ -f "$1" ]] && ! grep -qE -- "$2" "$1"; }

# --- doctor: this HOME has no desk stack, so 1 is expected; a crash is not ---
step reconfigure 0 "$bercail" reconfigure
step doctor 1 "$bercail" doctor
check "doctor reached its bstack section" out_has doctor "bstack login"

# --- drive ---
record="$XDG_STATE_HOME/bercail/desk-sessions/t1.json"
# Built at run time: a session id on a command line would read as already open.
jq -n --arg s "verify-$(date +%s%N)" --arg c "$repo" \
  '{address: "t1", session: $s, cwd: $c, harness: "pi", issue: "verify-1", space: "sp1", args: []}' >"$record"
before="$(sha256sum "$record")"
step desk-restore-dry-run 0 "$bercail" desk restore --dry-run
check "dry run would resume the desk" out_has desk-restore-dry-run "would resume"
check "dry run typed nothing" absent "$HC_CALLS" '^send'
check "dry run left the record alone" test "$before" = "$(sha256sum "$record")"

# A desk session: its harness makes what a toolchain makes (a mktemp file and
# folder, Node's temp dir and compile cache), all in the desk's own TMPDIR,
# nothing under /tmp, and the folder is gone once the desk exits.
mkdir -p "$box/desk"
cat >"$box/desk/pi" <<'PI'
#!/usr/bin/env bash
out="$DESK_OUT"
{
  printf 'tmpdir\t%s\n' "$TMPDIR"
  printf 'mktemp\t%s\n' "$(mktemp -t verify-desk.XXXXXX)" "$(mktemp -d -t verify-desk.XXXXXX)"
  if [[ -x "$REAL_NODE" ]]; then
    "$REAL_NODE" -e 'const m = require("node:module"); m.enableCompileCache(); console.log("node\t" + require("node:os").tmpdir()); console.log("cache\t" + m.getCompileCacheDir())'
  fi
} >"$out"
PI
chmod +x "$box/desk/pi"
before_tmp="$(find /tmp -maxdepth 1 -name 'verify-desk.*' 2>/dev/null | sort)"
step desk-session 0 env HC_TERMINAL_ID=t1 DESK_OUT="$evidence/desk-session.tsv" timeout 30 "$repo/bin/bercail-desk-agent" "$box/desk/pi"
desk_tmp="$(awk -F'\t' '$1 == "tmpdir" { print $2 }' "$evidence/desk-session.tsv" 2>/dev/null)"
inside_desk_tmp() { [[ -n "$desk_tmp" ]] && awk -F'\t' -v d="$desk_tmp/" '$1 != "tmpdir" && index($2, d) != 1 && $2 != substr(d, 1, length(d) - 1) { bad = 1 } END { exit bad }' "$evidence/desk-session.tsv"; }
gone_soon() { local _; for _ in $(seq 1 100); do [[ -e "$1" ]] || return 0; sleep 0.1; done; return 1; }
check "the desk's TMPDIR is its scratch folder" test "${desk_tmp%/*}" = "$XDG_CACHE_HOME/bercail/scratch"
# Two mktemp rows, and Node's two when there is a Node: a missing row is a step that did not run.
desk_rows() { [[ "$(cut -f1 "$evidence/desk-session.tsv" | sort | tr '\n' ' ')" == "${REAL_NODE:+cache }mktemp mktemp ${REAL_NODE:+node }tmpdir " ]]; }
check "the desk's harness made a mktemp file and folder${real_node:+, and Node its temp dir and compile cache}" desk_rows
check "what the desk's tools made is in its TMPDIR" inside_desk_tmp
check "the desk wrote nothing new under /tmp" test "$before_tmp" = "$(find /tmp -maxdepth 1 -name 'verify-desk.*' 2>/dev/null | sort)"
check "the desk's scratch is gone once it exits" gone_soon "$desk_tmp"

step handoff-info 0 "$repo/skills/handoff/scripts/handoff-spawn" --info
check "handoff --info is JSON" jq -e 'type == "object"' "$evidence/handoff-info.out"

step bstack-status 0 "$bercail" bstack status
check "bstack status reports its profile" out_has bstack-status "bstack:"
check "the desk's lead is deployed" jq -e '.[0] == "pi"' "$profile/lead.json"
check "review-pr's reviewer is read-only" jq -e 'index(["--tools", "read,grep,find,ls"]) != null' "$profile/review.json"
check "/validate is deployed, and no /ready" test -f "$profile/prompts/validate.md" -a ! -e "$profile/prompts/ready.md"
check "the describe skill and its standard are deployed" test -f "$HOME/.agents/skills/describe/standard.md"
check "review-pr's reviewer reads the description standard" grep -qF describe/standard.md "$profile/review.json"
check "the builder runs the pinned claude" grep -qF -- '--model claude-bridge/claude-opus-5-5:high ' "$templates/bstack-builder.md"
check "the lead loads the guard" grep -qF extensions/guard.ts "$profile/lead.json"

step describe-template 0 "$bercail" describe template "$repo"
check "bercail has no PR template" out_has describe-template none

step policy-show 0 "$bercail" policy show --json "$repo"
check "the CLI reads this repo's policy" jq -e '.file != "" and .policy.integrate == "direct"' "$evidence/policy-show.out"
check "a fresh HOME does not trust it" jq -e '.trusted == false and .policy.push == "ask"' "$evidence/policy-show.out"

# Shep: a start (the stub pi exits at once) writes its compaction settings and
# its start context with a known repo and a rule.
shep_state="$XDG_STATE_HOME/bercail/shep"
mkdir -p "$shep_state"
printf '%s\n' "$repo" >"$shep_state/repos"
step shep-remember 0 "$bercail" shep remember "verify: a standing rule" --scope verify
step shep-repos 0 "$bercail" shep repos --json
check "shep repos has this checkout's main repo" jq -e --arg m "$(git -C "$repo" worktree list --porcelain | awk '/^worktree /{print substr($0, 10); exit}')" \
  'map(.path) | index($m) != null' "$evidence/shep-repos.out"
step shep-run 0 "$bercail" shep run </dev/null
cp "$shep_state/workspace/.pi/settings.json" "$evidence/shep-settings.json" 2>/dev/null
check "Shep compacts the lead at 250k of its 1M window" \
  jq -e '.compaction.modelOverrides["claude-bridge/claude-opus-5-5"] == {keepRecentTokens: 50000, reserveTokens: 750000}' "$evidence/shep-settings.json"
check "Shep's start context has the rule" grep -qF "[verify] verify: a standing rule" "$shep_state/context.md"

# Routines: a command routine with one finding runs, then is quiet, and a dry
# run prints the finding once it changes.
printf '#!/bin/sh\ncat "$1"\n' >"$box/bin/finds"
chmod +x "$box/bin/finds"
printf '{"key":"verify","title":"one finding"}' >"$box/finding"
printf '\n[routine.verify]\ncommand = ["%s", "%s"]\nevery = "1d"\n' "$box/bin/finds" "$box/finding" \
  >>"$XDG_CONFIG_HOME/bercail/config.toml"
step routine-run 0 "$bercail" routine run verify
check "a routine's new finding is emitted" out_has routine-run "verify: emitted, 1 found (1 new, 0 changed)"
check "the emitted run left one event in Shep's inbox" \
  jq -se 'length == 1 and .[0].schema == "bercail.routine/v1" and .[0].outcome == "emitted"' "$shep_state"/inbox/routine_verify_*.json
step routine-run-again 0 "$bercail" routine run verify
check "the same finding again is quiet" out_has routine-run-again "verify: skipped (quiet)"
printf '{"key":"verify","title":"one finding, changed"}' >"$box/finding"
step routine-dry-run 0 "$bercail" routine run verify --dry-run
check "a dry run prints the changed finding" \
  grep -qx '  changed  verify  one finding, changed' "$evidence/routine-dry-run.out"
step routine-list 0 "$bercail" routine list
check "list shows its last outcome" grep -qE '^verify +every 1d +next .* skipped \(quiet\) +active$' "$evidence/routine-list.out"
# The cleanup built-in, on a HOME with nothing to retire: quiet, and a dry run
# keeps no state of its own. It reads the question ledger with Node, which
# this HOME's PATH finds only by its own folder, and spaces with the Herdr
# helpers, which this HOME has no layout for.
printf '\n[routine.tidy]\nrun = "cleanup"\nat = "07:30"\n' >>"$XDG_CONFIG_HOME/bercail/config.toml"
step routine-cleanup 0 env PATH="${real_node:+$(dirname "$real_node"):}$PATH" \
  BERCAIL_HERDR_LAYOUT="$repo/config/worktrunk/herdr-layout.sh" "$bercail" routine run tidy --dry-run
check "the cleanup routine finds nothing to retire here" out_has routine-cleanup "tidy: skipped (quiet), 0 found"
check "its dry run writes no seen-done.json" test ! -e "$XDG_STATE_HOME/bercail/routines/tidy/seen-done.json"
# The scheduler: a tick starts the routine that never ran, once; the one that
# ran today waits. shep status says the loop is not running here, and start
# asks hc for the bercail-routines terminal.
printf '\n[routine.verify-tick]\ncommand = ["%s", "%s"]\nevery = "1d"\n' "$box/bin/finds" "$box/finding" \
  >>"$XDG_CONFIG_HOME/bercail/config.toml"
step routine-tick 0 env BERCAIL_ROUTINE_BOOT_WAIT=0 "$bercail" routine tick
check "a tick starts the routine that never ran, and only it" \
  grep -qx 'verify-tick: started its .* run' "$evidence/routine-tick.out"
for _ in $(seq 100); do
  [[ -s "$XDG_STATE_HOME/bercail/routines/verify-tick/runs.jsonl" ]] && break
  sleep 0.1
done
check "the started run wrote its line" \
  jq -se 'length == 1 and .[0].outcome == "emitted"' "$XDG_STATE_HOME/bercail/routines/verify-tick/runs.jsonl"
step routine-tick-again 0 env BERCAIL_ROUTINE_BOOT_WAIT=0 "$bercail" routine tick
check "a second tick starts nothing" absent "$evidence/routine-tick-again.out" 'started'
step shep-status 0 "$bercail" shep status
check "shep status says the loop is not running and when it last ticked" \
  grep -qE '^routine loop: not running \(last tick [0-9-]+ [0-9:]+\)' "$evidence/shep-status.out"
step routine-start 0 "$bercail" routine start
check "start asks hc for the hidden bercail-routines terminal" \
  grep -q '^run --bg --no-parent --no-notify --rm --name bercail-routines --label bercail.role=routines ' "$HC_CALLS"

cp "$XDG_CONFIG_HOME/bercail/config.toml" "$evidence/config.toml"

# --- result ---
if ((failed)); then
  printf 'verify-bercail FAILED; evidence: %s\n' "$evidence"
  exit 1
fi
printf 'verify-bercail passed; evidence: %s\n' "$evidence"
