#!/usr/bin/env bash
# shellcheck shell=bash
# bercail shep: Shep on Pi (its argv, env and folders), status, configs that still
# carry the old runtime keys, and the notify follower's Shep inbox. A stand-in for
# pi; a temp HOME.
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
export LOG="$TMP_DIR/log"
mkdir -p "$TMP_DIR/bin" "$HOME/.local/share/bercail/shep/pi" "$HOME/.local/share/bercail/pi" \
  "$HOME/.agents/skills/handoff" "$HOME/.agents/skills/review"
CONFIG="$XDG_CONFIG_HOME/bercail/config.toml"
STATE="$XDG_STATE_HOME/bercail/shep"
SHARE="$HOME/.local/share/bercail/shep"
cp "$ROOT/shep/SHEP.md" "$SHARE/"
cp "$ROOT/shep/pi/inbox.ts" "$SHARE/pi/"
# bstack's lead, as deploy writes it.
jq -n '["pi","--model","fake/lead:high","-e","npm:pi-claude-bridge@0.11.0","-e","/x/fallback.ts","--append-system-prompt","/x/instructions.md","--skill","/x/bstack"]' \
  >"$HOME/.local/share/bercail/pi/lead.json"

# pi: logs where it ran, what it got, and whether the Anthropic env came through.
cat >"$TMP_DIR/bin/pi" <<'EOF'
#!/usr/bin/env bash
{
  printf 'pi cwd=%s inbox=%s role=%s anthropic=%s\n' "$PWD" "${BERCAIL_SHEP_INBOX:-}" "${BERCAIL_ROLE:-}" "${ANTHROPIC_API_KEY:-unset}"
  printf 'pi-arg %s\n' "$@"
} >>"$LOG"
EOF
chmod +x "$TMP_DIR/bin/"*
export ANTHROPIC_API_KEY=sk-ant-test-not-for-shep

reset() {
  rm -rf "$XDG_CONFIG_HOME/bercail" "$STATE"
  mkdir -p "$XDG_CONFIG_HOME/bercail"
  : >"$LOG"
}
shep() { "$ROOT/bin/bercail" shep "$@"; }
ran() { grep -c "$1" "$LOG" || true; }

# Every start runs Pi, asking nothing and writing no config.
reset
out="$(shep run </dev/null 2>&1)"
[[ -z "$out" ]] || fail "the start printed: $out"
[[ "$(ran '^pi cwd=')" == 1 && ! -f "$CONFIG" ]] || fail "Pi did not just start: $(cat "$LOG")"
printf 'PASS: a start runs Pi with no question and no config\n'

# Pi: its own folder and sessions, bstack's lead model and extensions, Shep's rules
# and inbox, no context files, no Anthropic API key.
grep -qx "pi cwd=$STATE/workspace inbox=$STATE/inbox role=shep anthropic=unset" "$LOG" || fail "Pi env: $(grep '^pi cwd' "$LOG")"
args="$(sed -n 's/^pi-arg //p' "$LOG" | tr '\n' ' ')"
for want in "--model fake/lead:high" "-e npm:pi-claude-bridge@0.11.0" "-e /x/fallback.ts" "-e $SHARE/pi/inbox.ts" \
  "--append-system-prompt $SHARE/SHEP.md" "--no-context-files" "--session-dir $STATE/pi-sessions" "--continue" \
  "--skill $HOME/.agents/skills/handoff" "--skill $HOME/.agents/skills/review"; do
  [[ "$args" == *"$want "* ]] || fail "Pi argv lacks '$want': $args"
done
[[ "$args" != *instructions.md* && "$args" != */x/bstack* && "$args" != *desk-restore* ]] || fail "Pi got the lead's rules or a missing skill: $args"
[[ -d "$STATE/inbox" && -d "$STATE/delivered" ]] || fail "no inbox"
printf 'PASS: Pi runs in its own folder and sessions on the lead model, with Shep rules and inbox only\n'

# A config from before Pi was the only runtime: [shep] backend and session are
# ignored. Pi runs, status works, nothing errors, and the config stays as it was.
for old in 'backend = "pi"\nsession = "agent:sheep:main"' 'session = "agent:sheep:main"' 'backend = "nope"'; do
  reset
  printf "[shep]\n$old\n" >"$CONFIG"
  cp "$CONFIG" "$TMP_DIR/before"
  out="$(shep run </dev/null 2>&1)" || fail "run failed with: $(cat "$CONFIG")"
  [[ -z "$out" && "$(ran '^pi cwd=')" == 1 ]] || fail "old keys: $out $(cat "$LOG")"
  out="$(shep status 2>&1)" || fail "status failed with: $(cat "$CONFIG")"
  [[ "$out" == "pi sessions: $STATE/pi-sessions"$'\n'"desk events: 0 waiting, 0 delivered" ]] || fail "status: $out"
  cmp -s "$CONFIG" "$TMP_DIR/before" || fail "config changed: $(cat "$CONFIG")"
done
printf 'PASS: the old [shep] backend and session keys are ignored; run and status work\n'

# Pi missing: the install step, kept on screen until Enter.
reset
mv "$TMP_DIR/bin/pi" "$TMP_DIR/pi"
out="$(shep run </dev/null 2>&1)"
mv "$TMP_DIR/pi" "$TMP_DIR/bin/pi"
grep -q 'Pi is not installed; install it with: mise use -g pi' <<<"$out" && grep -q 'Press Enter to close' <<<"$out" || fail "no Pi: $out"
printf 'PASS: no Pi: it says how to install it\n'

# Only run and status are left; the runtime commands are gone.
for sub in setup "use pi" "handoff --to pi"; do
  # shellcheck disable=SC2086
  out="$(shep $sub </dev/null 2>&1)" && fail "shep $sub passed"
  [[ "$out" == "bercail shep: usage: bercail shep run | status" ]] || fail "shep $sub: $out"
done
printf 'PASS: shep setup, use and handoff are gone; the usage names run and status\n'

# The notify follower: before Shep's first start, nothing is queued. After it, a
# finished desk lands in the inbox once, named without the follower's pid. Each
# call is its own process, like two followers.
reset
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
[[ -z "$(follower notify_shep_inbox)" ]] || fail "an inbox before Shep started"
follower notify_desk_changed t8 working "done" claude-code sp1 "" ""
[[ ! -e "$STATE/inbox" ]] || fail "an event queued before Shep started: $(ls -A "$STATE/inbox")"
shep run </dev/null >/dev/null 2>&1
[[ "$(follower notify_shep_inbox)" == "$STATE/inbox" ]] || fail "inbox: $(follower notify_shep_inbox)"
follower notify_desk_changed t9 working "done" claude-code sp1 "" "Beads issue"
follower notify_desk_changed t9 working "done" claude-code sp1 "" "Beads issue"
follower notify_desk_changed t9 working "blocked" claude-code sp1 "" "Beads issue"
mv "$STATE/inbox/t9_blocked_1793312520.json" "$STATE/delivered/"
follower notify_desk_changed t9 "done" "blocked" claude-code sp1 "" "Beads issue"
names="$(cd "$STATE/inbox" && ls -A)"
[[ "$names" == t9_finished_1793312520.json ]] || fail "inbox: $names"
jq -e '.source == "bercail" and .kind == "finished" and .sink == "shep" and (.event_id | startswith("t9:finished:1793312520:"))
  and .text == "Desk t9 finished."' "$STATE/inbox/$names" >/dev/null || fail "event: $(cat "$STATE/inbox/$names")"
[[ "$(stat -c %a "$STATE/inbox/$names")" == 600 ]] || fail "event mode"
printf 'PASS: Shep gets each desk event once in its inbox, and none before it first starts\n'

# Nothing secret on any command line.
grep -q 'sk-ant-test' "$LOG" && fail "the Anthropic key reached a command"
printf 'PASS: no key on any command line\n'

# Deploy installs Shep's package (rules, Pi extension) into the share dir.
reset
rm -rf "$SHARE"
INSTALL_SRC="$ROOT" bash -c 'set -euo pipefail; for l in common config bstack shep; do source "$1/lib/$l.sh"; done; deploy_shep' _ "$ROOT" >/dev/null
for rel in SHEP.md pi/inbox.ts; do
  cmp -s "$ROOT/shep/$rel" "$SHARE/$rel" || fail "deploy did not install shep/$rel"
done
printf 'PASS: deploy installs Shep rules and Pi extension\n'
