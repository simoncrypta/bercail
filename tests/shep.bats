#!/usr/bin/env bats
# bercail shep: Shep on Pi (its argv, env and folders), status, configs that still
# carry the old runtime keys, and the notify follower's Shep inbox. A stand-in for
# pi; a temp HOME.

setup() {
  load test_helper
  isolate
  # A failure anywhere in a pipeline fails the check it feeds.
  set -o pipefail
  export HERDR_APP_BIN="$BATS_TEST_TMPDIR/no-herdr-app"
  export ANTHROPIC_API_KEY=sk-ant-test-not-for-shep
  export LOG="$BATS_TEST_TMPDIR/log"
  # Only the stand-ins, then the system bins: a real pi or hc later on PATH would run instead.
  export PATH="$BATS_TEST_TMPDIR/bin:/usr/bin:/bin"
  mkdir -p "$BATS_TEST_TMPDIR/bin" "$HOME/.local/share/bercail/shep/pi" "$HOME/.local/share/bercail/pi" \
    "$HOME/.agents/skills/handoff" "$HOME/.agents/skills/review"
  CONFIG="$XDG_CONFIG_HOME/bercail/config.toml"
  STATE="$XDG_STATE_HOME/bercail/shep"
  SHARE="$HOME/.local/share/bercail/shep"
  cp "$ROOT/shep/SHEP.md" "$ROOT/shep/BACKGROUND.md" "$SHARE/"
  cp "$ROOT/shep/pi/inbox.ts" "$ROOT/shep/pi/compaction.ts" "$SHARE/pi/"
  # bstack's lead, as deploy writes it.
  jq -n '["pi","--model","fake/lead:high","-e","npm:pi-claude-bridge@0.11.0","-e","/x/fallback.ts","--append-system-prompt","/x/instructions.md","--skill","/x/bstack"]' \
    >"$HOME/.local/share/bercail/pi/lead.json"

  # pi: logs where it ran, what it got, and whether the Anthropic env came through.
  # --list-models (Shep's window lookup) lists the lead with a 1M window.
  cat >"$BATS_TEST_TMPDIR/bin/pi" <<'EOF'
#!/usr/bin/env bash
if [[ " $* " == *" --list-models "* ]]; then
  printf 'pi-list %s\n' "$*" >>"$LOG"
  printf 'provider  model  context\nfake      lead   1M\n'
  exit 0
fi
{
  printf 'pi cwd=%s inbox=%s role=%s anthropic=%s\n' "$PWD" "${BERCAIL_SHEP_INBOX:-}" "${BERCAIL_ROLE:-}" "${ANTHROPIC_API_KEY:-unset}"
  printf 'pi-arg %s\n' "$@"
} >>"$LOG"
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/"*
  : >"$LOG"
}

reset() {
  rm -rf "$XDG_CONFIG_HOME/bercail" "$STATE"
  mkdir -p "$XDG_CONFIG_HOME/bercail"
  : >"$LOG"
}

shep() { "$ROOT/bin/bercail" shep "$@"; }

ran() { grep -c "$1" "$LOG" || true; }

# One start. Later checks read this run's log, not a neighbour's.
start_pi() {
  reset
  shep run </dev/null >/dev/null 2>&1
}

# The notify follower, its own process, clock frozen. Each inbox case installs it.
install_follower() {
  cat >"$BATS_TEST_TMPDIR/follower.sh" <<EOF
set -euo pipefail
source "$ROOT/lib/common.sh"
source "$ROOT/lib/bstack.sh"
source "$ROOT/lib/shep.sh"
source "$ROOT/lib/notify.sh"
_notify_now() { echo 1793312520; }
"\$@"
EOF
}

follower() { bash "$BATS_TEST_TMPDIR/follower.sh" "$@"; }

# bd knows bc-1 only in $REPO. hc logs run's argv one per line and answers get/ls from the env.
bg_standins() {
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO"
  cat >"$BATS_TEST_TMPDIR/bin/bd" <<EOF
#!/usr/bin/env bash
[[ "\$PWD" == "$REPO" && "\$1 \$2" == "show bc-1" ]] || exit 1
printf '%s\n' '[{"id":"bc-1","title":"Wait for CI on PR 12,\nthen merge it."}]'
EOF
  cat >"$BATS_TEST_TMPDIR/bin/hc" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  get) [[ "$2" == "${HC_LIVE:-}" ]] || { printf '{"error":{"kind":"not_found"}}\n'; exit 5; }
       printf '{"state":"live"}\n' ;;
  ls) printf '%s\n' "${HC_LS:-"{\"terminals\":[]}"}" ;;
  run) printf '%s\n' "$@" >"$HC_RUN_LOG"
       printf '{"address":"t20","agent":"env","cwd":"/x","name":"shep-bg-bc-1","state":"live","turn":0}\n' ;;
esac
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/bd" "$BATS_TEST_TMPDIR/bin/hc"
  export HC_RUN_LOG="$BATS_TEST_TMPDIR/hc-run"
}

@test "a start runs Pi with no question and no config" {
  local out
  reset
  out="$(shep run </dev/null 2>&1)"
  [[ -z "$out" ]] || fail "the start printed: $out"
  [[ "$(ran '^pi cwd=')" == 1 && ! -f "$CONFIG" ]] || fail "Pi did not just start: $(cat "$LOG")"
}

@test "Pi runs in its own folder and sessions on the lead model, with Shep rules and inbox only" {
  local args want
  start_pi
  grep -qx "pi cwd=$STATE/workspace inbox=$STATE/inbox role=shep anthropic=unset" "$LOG" || fail "Pi env: $(grep '^pi cwd' "$LOG")"
  args="$(sed -n 's/^pi-arg //p' "$LOG" | tr '\n' ' ')"
  for want in "--model fake/lead:high" "-e npm:pi-claude-bridge@0.11.0" "-e /x/fallback.ts" "-e $SHARE/pi/inbox.ts" \
    "-e $SHARE/pi/compaction.ts" "--append-system-prompt $SHARE/SHEP.md" "--append-system-prompt $STATE/context.md" \
    "--no-context-files" "--approve" "--session-dir $STATE/pi-sessions" "--continue" \
    "--skill $HOME/.agents/skills/handoff" "--skill $HOME/.agents/skills/review"; do
    [[ "$args" == *"$want "* ]] || fail "Pi argv lacks '$want': $args"
  done
  [[ "$args" != *instructions.md* && "$args" != */x/bstack* && "$args" != *desk-restore* ]] || fail "Pi got the lead's rules or a missing skill: $args"
  [[ -d "$STATE/inbox" && -d "$STATE/delivered" ]] || fail "no inbox"
}

@test "the old [shep] backend and session keys are ignored; run and status work" {
  local old out
  for old in 'backend = "pi"\nsession = "agent:sheep:main"' 'session = "agent:sheep:main"' 'backend = "nope"'; do
    reset
    printf "[shep]\n$old\n" >"$CONFIG"
    cp "$CONFIG" "$BATS_TEST_TMPDIR/before"
    out="$(shep run </dev/null 2>&1)" || fail "run failed with: $(cat "$CONFIG")"
    [[ -z "$out" && "$(ran '^pi cwd=')" == 1 ]] || fail "old keys: $out $(cat "$LOG")"
    out="$(shep status 2>&1)" || fail "status failed with: $(cat "$CONFIG")"
    [[ "$out" == "pi sessions: $STATE/pi-sessions"$'\n'"desk events: 0 waiting, 0 delivered"$'\n'"background Sheps: none" ]] || fail "status: $out"
    cmp -s "$CONFIG" "$BATS_TEST_TMPDIR/before" || fail "config changed: $(cat "$CONFIG")"
  done
}

@test "no Pi: it says how to install it" {
  local out
  reset
  mv "$BATS_TEST_TMPDIR/bin/pi" "$BATS_TEST_TMPDIR/pi"
  out="$(shep run </dev/null 2>&1)"
  mv "$BATS_TEST_TMPDIR/pi" "$BATS_TEST_TMPDIR/bin/pi"
  grep -q 'Pi is not installed; install it with: mise use -g pi' <<<"$out" && grep -q 'Press Enter to close' <<<"$out" || fail "no Pi: $out"
}

@test "shep setup, use and handoff are gone; the usage names every subcommand" {
  local sub out
  for sub in setup "use pi" "handoff --to pi"; do
    # shellcheck disable=SC2086
    out="$(shep $sub </dev/null 2>&1)" && fail "shep $sub passed"
    [[ "$out" == 'bercail shep: usage: bercail shep run | status | bg --issue ID [--cwd DIR] | repos [--json] | brief ISSUE [--repo DIR] [--budget CHARS] | board | remember "RULE" [--scope SCOPE] | forget N | list' ]] \
      || fail "shep $sub: $out"
  done
}

@test "shep bg runs the lead Pi with the background brief and a one-line prompt in a labelled background terminal" {
  local out
  local -a argv want
  bg_standins
  reset
  out="$(cd "$BATS_TEST_TMPDIR" && shep bg --issue bc-1 --cwd "$REPO" 2>&1)" || fail "shep bg: $out"
  jq -e '. == {address:"t20", name:"shep-bg-bc-1", cwd:"/x", issue:"bc-1", issue_title:"Wait for CI on PR 12, then merge it"}' \
    <<<"$out" >/dev/null || fail "shep bg JSON: $out"
  mapfile -t argv <"$HC_RUN_LOG"
  want=(run --bg --json --name shep-bg-bc-1 --cwd "$REPO" --outlive-parent --no-notify --rm
    --label bercail.role=agent --label bercail.shep=bg --label bercail.issue=bc-1
    --label "bercail.issue_title=Wait for CI on PR 12, then merge it" --
    env -u ANTHROPIC_API_KEY -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN -u BERCAIL_SHEP_INBOX
    BERCAIL_ROLE=shep-bg TERM=xterm-256color COLORTERM=truecolor bercail-desk-agent
    --prompt 'Your job is beads issue bc-1: Wait for CI on PR 12, then merge it. Run `bd show bc-1` (read its comments too) and do exactly what it describes, then stop.'
    pi --model fake/lead:high -e npm:pi-claude-bridge@0.11.0 -e /x/fallback.ts
    --append-system-prompt /x/instructions.md --skill /x/bstack --append-system-prompt "$SHARE/BACKGROUND.md")
  [[ "$(printf '%s\n' "${argv[@]}")" == "$(printf '%s\n' "${want[@]}")" ]] \
    || fail "hc run argv: $(diff <(printf '%s\n' "${want[@]}") <(printf '%s\n' "${argv[@]}"))"
}

@test "shep bg refuses a live duplicate, an issue bd does not know there, and no issue" {
  local out
  bg_standins
  reset
  rm -f "$HC_RUN_LOG"
  out="$(HC_LIVE=shep-bg-bc-1 shep bg --issue bc-1 --cwd "$REPO" 2>&1)" && fail "a second bc-1 started"
  [[ "$out" == *"shep-bg-bc-1 is already running"*"hc kill shep-bg-bc-1"* ]] || fail "live name: $out"
  out="$(cd "$BATS_TEST_TMPDIR" && shep bg --issue bc-1 2>&1)" && fail "bg outside the repo started"
  [[ "$out" == *"bd does not know bc-1 in $BATS_TEST_TMPDIR"*"--cwd"* ]] || fail "unknown issue: $out"
  out="$(shep bg 2>&1)" && fail "bg without an issue started"
  [[ "$out" == *"usage: bercail shep bg --issue ID"* ]] || fail "no issue: $out"
  [[ ! -e "$HC_RUN_LOG" ]] || fail "hc run ran: $(cat "$HC_RUN_LOG")"
}

@test "shep status lists live background Sheps" {
  local out
  bg_standins
  out="$(HC_LS='{"terminals":[{"address":"t20","name":"shep-bg-bc-1","state":"live","status":{"state":"working"},
    "labels":{"bercail.issue":"bc-1","bercail.issue_title":"Wait for CI"}}]}' shep status 2>&1)"
  [[ "$out" == *$'background Sheps:\n- shep-bg-bc-1 (t20) working: bc-1 Wait for CI' ]] || fail "status: $out"
}

@test "Shep gets each desk event once in its inbox, and none before it first starts" {
  local names
  reset
  install_follower
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
}

@test "a background Shep finishing is queued for Shep like a desk event, with its own issue" {
  local main bg desk
  reset
  install_follower
  mkdir -p "$STATE/inbox" "$STATE/delivered"
  main="$BATS_TEST_TMPDIR/main"
  git init -q "$main"
  git -C "$main" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
  mkdir -p "$main/.bercail" "$XDG_STATE_HOME/agentic-dev"
  jq -nc --arg p "$main" '{path:$p, issue:"old-1", issue_title:"Old job", stage:"bstack", harness:"pi"}' \
    >"$XDG_STATE_HOME/agentic-dev/handoffs.jsonl"
  printf '{"status":"ready","summary":"old","session_id":"s","issue":"old-1"}\n' >"$main/.bercail/handoff-result.json"
  snapshot() {
    jq -nc --arg s "$1" --arg main "$main" '{seq:1, terminals:[
      {address:"t9", state:"live", status:{state:$s, app:"pi"}, cwd:$main, title:"desk",
       labels:{"bercail.role":"agent", "bercail.space":"sp1"}},
      {address:"t20", name:"shep-bg-bc-1", state:"live", status:{state:$s, app:"pi"}, cwd:$main, title:"bg",
       labels:{"bercail.role":"agent", "bercail.shep":"bg", "bercail.issue":"bc-1", "bercail.issue_title":"Wait for CI"}}]}'
  }
  { snapshot working; snapshot "done"; } | follower notify_follow
  bg="$STATE/inbox/t20_finished_1793312520.json"
  desk="$STATE/inbox/t9_finished_1793312520.json"
  [[ -f "$bg" && -f "$desk" ]] || fail "inbox: $(ls -A "$STATE/inbox")"
  jq -e --arg main "$main" '.source == "bercail" and .sink == "shep" and .kind == "finished"
    and .agent.address == "t20" and .agent.role == "shep-bg" and .space.id == null and .space.checkout_path == $main
    and .desk.issue == "bc-1" and .desk.issue_title == "Wait for CI" and .desk.stage == null and .desk.result == null
    and .text == "bc-1: Wait for CI. Background Shep t20 finished."' "$bg" >/dev/null || fail "bg event: $(cat "$bg")"
  jq -e '.agent.role == "desk" and .desk.issue == "old-1" and .desk.result.status == "ready" and (.desk.result | has("issue") | not)
    and .text == "old-1: Old job. Desk t9 finished."' "$desk" >/dev/null || fail "desk event: $(cat "$desk")"
  shape() { jq -c '{top:keys, agent:(.agent|keys), space:(.space|keys), desk:(.desk|keys)}' "$1"; }
  [[ "$(shape "$bg")" == "$(shape "$desk")" ]] || fail "shapes differ: $(shape "$bg") vs $(shape "$desk")"
}

# The shell case greps a log the previous case had just reset, so it never saw a
# command. Run Shep first: the key check has to look at a command that ran.
@test "no key on any command line" {
  start_pi
  grep -q '^pi cwd=' "$LOG" || fail "Shep did not run: $(cat "$LOG")"
  if grep -q 'sk-ant-test' "$LOG"; then fail "the Anthropic key reached a command"; fi
}

@test "deploy installs Shep rules, the background brief and Pi extensions" {
  local rel
  reset
  rm -rf "$SHARE"
  INSTALL_SRC="$ROOT" bash -c 'set -euo pipefail; for l in common config bstack shep; do source "$1/lib/$l.sh"; done; deploy_shep' _ "$ROOT" >/dev/null
  for rel in SHEP.md BACKGROUND.md pi/inbox.ts pi/compaction.ts; do
    cmp -s "$ROOT/shep/$rel" "$SHARE/$rel" || fail "deploy did not install shep/$rel"
  done
}
