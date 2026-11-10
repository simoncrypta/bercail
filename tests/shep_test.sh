#!/usr/bin/env bash
# shellcheck shell=bash
# bercail shep: the runtime choice (Pi or OpenClaw), OpenClaw setup and its
# failures, the context handoff, and the notify follower's Shep inbox. Stand-ins
# for openclaw, pi and hc; a temp HOME.
set -euo pipefail

unset BASH_ENV HC_TERMINAL_ID
export __MISE_BASH_ENV_LOADED=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

export HOME="$TMP_DIR/home"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_STATE_HOME="$HOME/.local/state"
export HERDR_APP_BIN="$TMP_DIR/no-herdr-app"
export PATH="$TMP_DIR/bin:/usr/bin:/bin"
export OC="$TMP_DIR/oc" LOG="$TMP_DIR/log"
mkdir -p "$TMP_DIR/bin" "$OC" "$HOME/.local/share/bercail/shep/pi" "$HOME/.local/share/bercail/pi" \
  "$HOME/.agents/skills/handoff" "$HOME/.agents/skills/review"
CONFIG="$XDG_CONFIG_HOME/bercail/config.toml"
STATE="$XDG_STATE_HOME/bercail/shep"
SHARE="$HOME/.local/share/bercail/shep"
cp "$ROOT/shep/SHEP.md" "$ROOT/shep/IDENTITY.md" "$SHARE/"
cp "$ROOT/shep/pi/inbox.ts" "$SHARE/pi/"
# bstack's lead, as deploy writes it.
jq -n '["pi","--model","fake/lead:high","-e","npm:pi-claude-bridge@0.11.0","-e","/x/fallback.ts","--append-system-prompt","/x/instructions.md","--skill","/x/bstack"]' \
  >"$HOME/.local/share/bercail/pi/lead.json"

# openclaw: answers from files in $OC, logs every call.
cat >"$TMP_DIR/bin/openclaw" <<'EOF'
#!/usr/bin/env bash
printf 'openclaw %s\n' "$*" >>"$LOG"
case "$1 $2" in
  "gateway status") exit "$(cat "$OC/gateway" 2>/dev/null || echo 0)" ;;
  "agents list") cat "$OC/agents.json" ;;
  "agents add")
    ws=""; while [[ $# -gt 0 ]]; do [[ "$1" == --workspace ]] && ws="$2"; shift; done
    ls "$ws" >"$OC/seeded"
    id="$(sed -n 's/^openclaw agents add \([^ ]*\).*/\1/p' "$LOG" | tail -n 1)"
    jq --arg id "$id" '. + [{id:$id, isDefault:false}]' "$OC/agents.json" >"$OC/a" && mv "$OC/a" "$OC/agents.json"
    printf '{"agentId":"%s"}\n' "$id"
    ;;
  "agents set-identity") ;;
  "sessions --agent") cat "$OC/sessions-$3.json" 2>/dev/null || echo '{"sessions":[]}' ;;
  "tui --session") exit "$(cat "$OC/tui" 2>/dev/null || echo 0)" ;;
  *) exit 9 ;;
esac
EOF
# pi: logs where it ran, what it got, and whether the Anthropic env came through.
cat >"$TMP_DIR/bin/pi" <<'EOF'
#!/usr/bin/env bash
{
  printf 'pi cwd=%s inbox=%s role=%s anthropic=%s\n' "$PWD" "${BERCAIL_SHEP_INBOX:-}" "${BERCAIL_ROLE:-}" "${ANTHROPIC_API_KEY:-unset}"
  printf 'pi-arg %s\n' "$@"
} >>"$LOG"
EOF
cat >"$TMP_DIR/bin/hc" <<'EOF'
#!/usr/bin/env bash
printf 'hc %s\n' "$*" >>"$LOG"
EOF
chmod +x "$TMP_DIR/bin/"*
export ANTHROPIC_API_KEY=sk-ant-test-not-for-shep

reset() {
  rm -rf "$XDG_CONFIG_HOME/bercail" "$STATE" "${OC:?}"/*
  mkdir -p "$XDG_CONFIG_HOME/bercail"
  printf '[{"id":"main","isDefault":false},{"id":"sheep","isDefault":true}]\n' >"$OC/agents.json"
  : >"$LOG"
}
shep() { "$ROOT/bin/bercail" shep "$@"; }
get() { awk -v want="[$1]" -v key="$2" '/^\[/ { s = $0; next } s == want && $1 == key { sub(/^[^=]*=[[:space:]]*/, ""); gsub(/"/, ""); print }' "$CONFIG" 2>/dev/null; }
ran() { grep -c "$1" "$LOG" || true; }

# First start: nothing chosen, so it asks; Pi is the default answer. The choice is
# kept: the next start asks nothing.
reset
out="$(printf '\n' | shep run 2>&1)"
grep -q 'Where should Shep run' <<<"$out" || fail "the first start did not ask: $out"
[[ "$(get shep backend)" == pi ]] || fail "Pi was not remembered: $(cat "$CONFIG")"
[[ "$(ran '^pi cwd=')" == 1 ]] || fail "Pi did not start: $(cat "$LOG")"
: >"$LOG"
out="$(shep run </dev/null 2>&1)"
grep -q 'Where should Shep run' <<<"$out" && fail "a chosen runtime asked again"
[[ "$(ran '^pi cwd=')" == 1 ]] || fail "Pi did not start the second time"
printf 'PASS: the first start asks (Pi by default), remembers it, and the next start just runs\n'

# Pi: its own folder and sessions, bstack's lead model and extensions, Shep's rules
# and inbox, no context files, no Anthropic API key, and an hc label for the view.
grep -qx "pi cwd=$STATE/workspace inbox=$STATE/inbox role=shep anthropic=unset" "$LOG" || fail "Pi env: $(grep '^pi cwd' "$LOG")"
args="$(sed -n 's/^pi-arg //p' "$LOG" | tr '\n' ' ')"
for want in "--model fake/lead:high" "-e npm:pi-claude-bridge@0.11.0" "-e /x/fallback.ts" "-e $SHARE/pi/inbox.ts" \
  "--append-system-prompt $SHARE/SHEP.md" "--no-context-files" "--session-dir $STATE/pi-sessions" "--continue" \
  "--skill $HOME/.agents/skills/handoff" "--skill $HOME/.agents/skills/review"; do
  [[ "$args" == *"$want "* ]] || fail "Pi argv lacks '$want': $args"
done
[[ "$args" != *instructions.md* && "$args" != */x/bstack* && "$args" != *desk-restore* ]] || fail "Pi got the lead's rules or a missing skill: $args"
HC_TERMINAL_ID=t42 shep run </dev/null >/dev/null 2>&1
grep -qx 'hc label t42 bercail.shep_backend=pi' "$LOG" || fail "no hc label: $(grep '^hc' "$LOG")"
[[ -d "$STATE/inbox" && -d "$STATE/delivered" ]] || fail "no inbox"
printf 'PASS: Pi runs in its own folder and sessions on the lead model, with Shep rules and inbox only\n'

# An OpenClaw Shep set up before the choice ([shep] session only) stays on it:
# no question, no agent made or listed, the config untouched.
reset
printf '[shep]\nsession = "agent:sheep:main"\n' >"$CONFIG"
cp "$CONFIG" "$TMP_DIR/before"
out="$(shep run </dev/null 2>&1)"
grep -q 'Where should Shep run' <<<"$out" && fail "an existing OpenClaw Shep was asked: $out"
grep -qx 'openclaw tui --session agent:sheep:main' "$LOG" || fail "tui: $(cat "$LOG")"
[[ "$(ran 'agents add')" == 0 && "$(ran 'agents list')" == 0 && "$(ran '^pi ')" == 0 ]] || fail "unexpected calls: $(cat "$LOG")"
cmp -s "$CONFIG" "$TMP_DIR/before" || fail "config changed: $(cat "$CONFIG")"
[[ "$(shep status)" == *"backend: openclaw"* ]] || fail "status: $(shep status)"
printf 'PASS: an existing [shep] session keeps OpenClaw and its session, with no onboarding\n'

# Change the runtime: Pi keeps the OpenClaw session for coming back, and back
# again verifies it first.
shep use pi >/dev/null
[[ "$(get shep backend)" == pi && "$(get shep session)" == agent:sheep:main ]] || fail "use pi: $(cat "$CONFIG")"
: >"$LOG"
shep use openclaw </dev/null >/dev/null
[[ "$(get shep backend)" == openclaw ]] || fail "use openclaw: $(cat "$CONFIG")"
grep -q '^openclaw gateway status --json --require-rpc' "$LOG" && grep -q '^openclaw agents list' "$LOG" || fail "not verified: $(cat "$LOG")"
printf 'PASS: the runtime changes both ways; the OpenClaw session is kept and checked\n'

# Setup on OpenClaw, an existing agent: the list, then the pick.
reset
out="$(printf '2\n1\n' | shep run 2>&1)"
grep -q '2) sheep (default)' <<<"$out" || fail "agent list: $out"
[[ "$(get shep backend)" == openclaw && "$(get shep session)" == agent:main:main ]] || fail "pick: $(cat "$CONFIG")"
grep -qx 'openclaw tui --session agent:main:main' "$LOG" || fail "tui: $(cat "$LOG")"
[[ "$(ran 'agents add')" == 0 ]] || fail "an agent was made"
grep -q 'bercail notify openclaw --agent main' <<<"$out" || fail "no notify hint: $out"
printf 'PASS: OpenClaw setup connects an existing agent and opens its main session\n'

# Setup on OpenClaw, a new agent: a folder seeded with Shep's rules, then agents add.
reset
out="$(printf '2\nc\n\n' | shep run 2>&1)"
grep -q "^openclaw agents add shep --non-interactive --workspace $STATE/openclaw-shep --json" "$LOG" || fail "add: $(cat "$LOG")"
grep -qx 'AGENTS.md' "$OC/seeded" && grep -qx 'IDENTITY.md' "$OC/seeded" || fail "not seeded: $(cat "$OC/seeded")"
cmp -s "$STATE/openclaw-shep/AGENTS.md" "$ROOT/shep/SHEP.md" || fail "AGENTS.md is not SHEP.md"
[[ "$(get shep session)" == agent:shep:main ]] || fail "session: $(cat "$CONFIG")"
grep -qx 'openclaw tui --session agent:shep:main' "$LOG" || fail "tui: $(cat "$LOG")"
: >"$LOG"
cp "$CONFIG" "$TMP_DIR/before"
shep use openclaw --create </dev/null >/dev/null 2>&1 && fail "a second shep agent was made"
[[ "$(ran 'agents add')" == 0 ]] && cmp -s "$CONFIG" "$TMP_DIR/before" || fail "a refused create changed things"
printf 'PASS: OpenClaw setup creates a dedicated Shep agent, never twice\n'

# OpenClaw missing: install steps, then Pi is offered. Declined: nothing chosen,
# nothing runs.
reset
mv "$TMP_DIR/bin/openclaw" "$TMP_DIR/openclaw"
out="$(printf '2\ny\n' | shep run 2>&1)"
grep -q 'OpenClaw is not installed' <<<"$out" && grep -q 'openclaw onboard' <<<"$out" || fail "no install guide: $out"
[[ "$(get shep backend)" == pi && "$(ran '^pi cwd=')" == 1 ]] || fail "Pi was not taken: $(cat "$CONFIG" 2>/dev/null)"
reset
printf '2\nn\n' | shep run >/dev/null 2>&1
[[ ! -f "$CONFIG" || -z "$(get shep backend)" ]] && [[ "$(ran '^pi ')" == 0 ]] || fail "declined Pi still chose: $(cat "$CONFIG")"
mv "$TMP_DIR/openclaw" "$TMP_DIR/bin/openclaw"
printf 'PASS: no OpenClaw: install steps, Pi offered, and declining leaves nothing chosen\n'

# Gateway down, from a working Pi: it says how to start it and Shep stays on Pi.
reset
printf '[shep]\nbackend = "pi"\n' >"$CONFIG"
echo 1 >"$OC/gateway"
out="$(printf '2\n' | shep run --setup 2>&1)"
grep -q "Gateway does not answer" <<<"$out" && grep -q 'Shep stays on pi' <<<"$out" || fail "gateway down: $out"
[[ "$(get shep backend)" == pi && "$(ran '^pi cwd=')" == 1 && "$(ran 'tui')" == 0 ]] || fail "Pi was abandoned: $(cat "$LOG")"
printf 'PASS: a Gateway that does not answer keeps the working Pi Shep\n'

# Cancelled, and failed checks: the OpenClaw Shep keeps its session.
reset
printf '[shep]\nbackend = "openclaw"\nsession = "agent:sheep:main"\n' >"$CONFIG"
cp "$CONFIG" "$TMP_DIR/before"
out="$(printf '2\nq\n' | shep run --setup 2>&1)"
grep -q 'Cancelled' <<<"$out" || fail "cancel: $out"
cmp -s "$CONFIG" "$TMP_DIR/before" && grep -qx 'openclaw tui --session agent:sheep:main' "$LOG" || fail "cancel changed Shep: $(cat "$CONFIG")"
for args in "--agent ghost" "--agent sheep --session agent:sheep:missing" "--agent sheep --session agent:other:main"; do
  # shellcheck disable=SC2086
  shep use openclaw $args </dev/null >/dev/null 2>&1 && fail "use openclaw $args passed"
  cmp -s "$CONFIG" "$TMP_DIR/before" || fail "use openclaw $args changed the config"
done
printf '{"sessions":[{"key":"agent:sheep:ops"}]}\n' >"$OC/sessions-sheep.json"
shep use openclaw --agent sheep --session agent:sheep:ops </dev/null >/dev/null
[[ "$(get shep session)" == agent:sheep:ops ]] || fail "an existing session was refused"
printf 'PASS: cancel and failed checks change nothing; a session that exists is taken\n'

# The context handoff: written on stdin (0600), read once by the next runtime.
reset
printf '[shep]\nbackend = "openclaw"\nsession = "agent:sheep:main"\n' >"$CONFIG"
printf 'Open: bercail-1: Fix the login (desk t9, blocked)\n' | shep handoff --to openclaw >/dev/null
[[ "$(stat -c %a "$STATE/handoff-openclaw.md")" == 600 ]] || fail "handoff mode"
shep run </dev/null >/dev/null 2>&1
grep -q '^openclaw tui --session agent:sheep:main --message Context handoff.*bercail-1: Fix the login' <(tr '\n' ' ' <"$LOG") || fail "no handoff: $(cat "$LOG")"
: >"$LOG"
shep run </dev/null >/dev/null 2>&1
grep -q -- '--message' "$LOG" && fail "the handoff was read twice"
shep use pi >/dev/null
printf -- '- no dash trouble\n' | shep handoff --to pi >/dev/null
shep run </dev/null >/dev/null 2>&1
sed -n 's/^pi-arg //p' "$LOG" | grep -qx -- '--' || fail "the Pi handoff is not after --"
grep -q '^- no dash trouble' "$LOG" || fail "Pi handoff: $(cat "$LOG")"
printf '' | shep handoff --to pi >/dev/null 2>&1 && fail "an empty handoff was taken"
printf 'PASS: the handoff reaches the other runtime once, as its first message\n'

# The notify follower: with Shep on Pi, a finished desk lands in the inbox once,
# named without the follower's pid. On OpenClaw, nothing does. Each call is its
# own process, like two followers.
reset
printf '[shep]\nbackend = "pi"\n' >"$CONFIG"
cat >"$TMP_DIR/follower.sh" <<EOF
set -euo pipefail
source "$ROOT/lib/common.sh"
source "$ROOT/lib/bstack.sh"
source "$ROOT/lib/shep.sh"
source "$ROOT/lib/notify.sh"
_notify_now() { echo 1793312520; }
"\$@"
EOF
follower() { bash "$TMP_DIR/follower.sh" "$@"; }
[[ "$(follower notify_shep_inbox)" == "$STATE/inbox" ]] || fail "inbox: $(follower notify_shep_inbox)"
follower notify_desk_changed t9 working "done" claude-code sp1 "" "Beads issue"
follower notify_desk_changed t9 working "done" claude-code sp1 "" "Beads issue"
follower notify_desk_changed t9 working "blocked" claude-code sp1 "" "Beads issue"
mkdir -p "$STATE/delivered"
mv "$STATE/inbox/t9_blocked_1793312520.json" "$STATE/delivered/"
follower notify_desk_changed t9 "done" "blocked" claude-code sp1 "" "Beads issue"
names="$(cd "$STATE/inbox" && ls -A)"
[[ "$names" == t9_finished_1793312520.json ]] || fail "inbox: $names"
jq -e '.source == "bercail" and .kind == "finished" and .sink == "shep" and (.event_id | startswith("t9:finished:1793312520:"))
  and .text == "Desk t9 finished."' "$STATE/inbox/$names" >/dev/null || fail "event: $(cat "$STATE/inbox/$names")"
[[ "$(stat -c %a "$STATE/inbox/$names")" == 600 ]] || fail "event mode"
printf '[shep]\nbackend = "openclaw"\nsession = "agent:sheep:main"\n' >"$CONFIG"
[[ -z "$(follower notify_shep_inbox)" ]] || fail "an inbox on OpenClaw"
follower notify_desk_changed t8 working "done" claude-code sp1 "" ""
[[ "$(cd "$STATE/inbox" && ls -A)" == "$names" ]] || fail "OpenClaw got an inbox event"
printf 'PASS: Shep on Pi gets each desk event once in its inbox; on OpenClaw it gets none\n'

# Nothing secret on any command line or in the output.
grep -q 'sk-ant-test' "$LOG" && fail "the Anthropic key reached a command"
grep -Eq -- '--(token|password|url)' "$LOG" && fail "credentials on a command line"
printf 'PASS: no key or Gateway credential on any command line\n'

# Deploy installs Shep's package (rules, identity, Pi extension) into the share dir.
reset
rm -rf "$SHARE"
INSTALL_SRC="$ROOT" bash -c 'set -euo pipefail; for l in common config bstack shep; do source "$1/lib/$l.sh"; done; deploy_shep' _ "$ROOT" >/dev/null
for rel in SHEP.md IDENTITY.md pi/inbox.ts; do
  cmp -s "$ROOT/shep/$rel" "$SHARE/$rel" || fail "deploy did not install shep/$rel"
done
printf 'PASS: deploy installs Shep rules, identity and Pi extension\n'
