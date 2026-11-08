#!/usr/bin/env bash
# Drive this checkout's bercail in a throwaway HOME. See SKILL.md.
# usage: run.sh [evidence-dir]   default: <repo>/.bercail/verify/<timestamp>
set -uo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
evidence="${1:-$repo/.bercail/verify/$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$evidence"
evidence="$(cd "$evidence" && pwd)"
real_opencode="$(mise which opencode 2>/dev/null || command -v opencode || true)"

# --- launch: nothing below can reach the real HOME or a real Herdr core ---
box="$(mktemp -d)"
trap 'rm -rf "$box"' EXIT
unset BASH_ENV HC_TERMINAL_ID HC_SESSION HC_SCOPE HC_TERMINAL_SOCKET OPENCODE_CONFIG_DIR
export __MISE_BASH_ENV_LOADED=1
export HOME="$box/home" XDG_CONFIG_HOME="$box/home/.config" XDG_DATA_HOME="$box/home/.local/share" XDG_CACHE_HOME="$box/home/.cache"
export XDG_STATE_HOME="$box/state" XDG_RUNTIME_DIR="$box/run" INSTALL_SRC="$repo"
export HC_BIN="$box/bin/hc" HC_CALLS="$evidence/hc-calls.log"
export PATH="$box/bin:$PATH"
mkdir -p "$HOME" "$XDG_RUNTIME_DIR" "$box/bin" "$XDG_STATE_HOME/bercail/desk-sessions" "$XDG_CONFIG_HOME/bercail"
: >"$HC_CALLS"
[[ -z "$real_opencode" ]] || ln -s "$real_opencode" "$box/bin/opencode"

# The one stand-in: hc, one live desk at a bare shell. Every call is logged.
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
[agent]
command = "opencode"

[bstack]
enabled = true
claude = "claude-agent/opus#high"
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

oc="$XDG_CONFIG_HOME/opencode"
no_seats() { ! compgen -G "$oc/agents/bstack-council-*.md" >/dev/null; }
out_has() { grep -qF -- "$2" "$evidence/$1.out"; }
absent() { [[ -f "$1" ]] && ! grep -qE -- "$2" "$1"; }

# --- doctor: this HOME has no desk stack, so 1 is expected; a crash is not ---
step reconfigure 0 "$bercail" reconfigure
step doctor 1 "$bercail" doctor
check "doctor reached its bstack section" out_has doctor "bstack subscription"

# --- drive ---
record="$XDG_STATE_HOME/bercail/desk-sessions/t1.json"
# Built at run time: a session id on a command line would read as already open.
jq -n --arg s "ses_verify_$(date +%s%N)" --arg c "$repo" \
  '{address: "t1", session: $s, cwd: $c, harness: "opencode", issue: "verify-1", space: "sp1", args: []}' >"$record"
before="$(sha256sum "$record")"
step desk-restore-dry-run 0 "$bercail" desk restore --dry-run
check "dry run would resume the desk" out_has desk-restore-dry-run "would resume"
check "dry run typed nothing" absent "$HC_CALLS" '^send'
check "dry run left the record alone" test "$before" = "$(sha256sum "$record")"

step handoff-info 0 "$repo/skills/handoff/scripts/handoff-spawn" --info
check "handoff --info is JSON" jq -e 'type == "object"' "$evidence/handoff-info.out"

step bstack-status 0 "$bercail" bstack status
check "bstack status is on" out_has bstack-status "bstack: on"
check "ready.md deployed with no council step" absent "$oc/commands/ready.md" '[Cc]ouncil'
check "council command still deployed" test -f "$oc/commands/council.md"
check "no council seats by default" no_seats

printf 'council = true\n' >>"$XDG_CONFIG_HOME/bercail/config.toml"
step reconfigure-council 0 "$bercail" reconfigure
check "council = true renders a seat" test -f "$oc/agents/bstack-council-claude.md"

cp "$XDG_CONFIG_HOME/bercail/config.toml" "$evidence/config.toml"

# --- result ---
if ((failed)); then
  printf 'verify-bercail FAILED; evidence: %s\n' "$evidence"
  exit 1
fi
printf 'verify-bercail passed; evidence: %s\n' "$evidence"
