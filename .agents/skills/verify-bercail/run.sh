#!/usr/bin/env bash
# Drive this checkout's bercail in a throwaway HOME. See SKILL.md.
# usage: run.sh [evidence-dir]   default: <repo>/.bercail/verify/<timestamp>
set -uo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
evidence="${1:-$repo/.bercail/verify/$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$evidence"
evidence="$(cd "$evidence" && pwd)"
real_pi="$(mise which pi 2>/dev/null || command -v pi || true)"

# --- tests: the suite must leave the real handoff log byte-identical ---
real_handoffs="${XDG_STATE_HOME:-$HOME/.local/state}/bercail/handoffs.jsonl"
handoffs_lines() { [[ -f "$real_handoffs" ]] && wc -l <"$real_handoffs" || echo 0; }
handoffs_sum() { [[ -f "$real_handoffs" ]] && sha256sum <"$real_handoffs" || echo absent; }
handoffs_before="$(handoffs_sum)"
handoffs_count="$(handoffs_lines)"
tests_rc=0
bash "$repo/tests/run.sh" >"$evidence/tests.out" 2>&1 </dev/null || tests_rc=$?
handoffs_after="$(handoffs_sum)"
# Another desk may spawn during the run: keep what was added so a reader can tell.
[[ "$handoffs_before" == "$handoffs_after" ]] \
  || tail -n "+$((handoffs_count + 1))" "$real_handoffs" >"$evidence/handoffs-added.jsonl"

# --- launch: nothing below can reach the real HOME or a real Herdr core ---
box="$(mktemp -d)"
trap 'rm -rf "$box"' EXIT
unset BASH_ENV HC_TERMINAL_ID HC_SESSION HC_SCOPE HC_TERMINAL_SOCKET
export __MISE_BASH_ENV_LOADED=1
export HOME="$box/home" XDG_CONFIG_HOME="$box/home/.config" XDG_DATA_HOME="$box/home/.local/share" XDG_CACHE_HOME="$box/home/.cache"
export XDG_STATE_HOME="$box/state" XDG_RUNTIME_DIR="$box/run" INSTALL_SRC="$repo"
export HC_BIN="$box/bin/hc" HC_CALLS="$evidence/hc-calls.log" REAL_PI="$real_pi"
export PATH="$box/bin:$PATH"
mkdir -p "$HOME" "$XDG_RUNTIME_DIR" "$box/bin" "$XDG_STATE_HOME/bercail/desk-sessions" "$XDG_CONFIG_HOME/bercail"
: >"$HC_CALLS"

# Pi, offline: the real version, a catalog with one Claude model, no login, and
# an install that fetches nothing (the bridge would come from npm).
cat >"$box/bin/pi" <<'PI'
#!/usr/bin/env bash
case "$1" in
  --version) if [[ -n "$REAL_PI" ]]; then "$REAL_PI" --version; else echo 1.5.0; fi ;;
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
  send) exit 0 ;;
  *) exit 1 ;;
esac
HC
chmod +x "$box/bin/hc"

cat >"$XDG_CONFIG_HOME/bercail/config.toml" <<'TOML'
[bstack]
claude = "claude-bridge/claude-opus-5-5#high"
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
check "tests left the real handoffs.jsonl byte-identical" test "$handoffs_before" = "$handoffs_after"

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

step handoff-info 0 "$repo/skills/handoff/scripts/handoff-spawn" --info
check "handoff --info is JSON" jq -e 'type == "object"' "$evidence/handoff-info.out"

step bstack-status 0 "$bercail" bstack status
check "bstack status reports its profile" out_has bstack-status "bstack:"
check "the desk's lead is deployed" jq -e '.[0] == "pi"' "$profile/lead.json"
check "review-pr's reviewer is read-only" jq -e 'index(["--tools", "read,grep,find,ls"]) != null' "$profile/review.json"
check "/council is deployed" test -f "$profile/prompts/council.md"
check "the pinned claude has a council seat" test -f "$templates/bstack-council-claude.md"
check "no seat for a provider without a model" test ! -e "$templates/bstack-council-gpt.md"
check "the lead loads the guard" grep -qF extensions/guard.ts "$profile/lead.json"

step policy-show 0 "$bercail" policy show --json "$repo"
check "the CLI reads this repo's policy" jq -e '.file != "" and .policy.integrate == "direct"' "$evidence/policy-show.out"
check "a fresh HOME does not trust it" jq -e '.trusted == false and .policy.commit == "ask"' "$evidence/policy-show.out"

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

cp "$XDG_CONFIG_HOME/bercail/config.toml" "$evidence/config.toml"

# --- result ---
if ((failed)); then
  printf 'verify-bercail FAILED; evidence: %s\n' "$evidence"
  exit 1
fi
printf 'verify-bercail passed; evidence: %s\n' "$evidence"
