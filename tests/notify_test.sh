#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

unset BASH_ENV
export __MISE_BASH_ENV_LOADED=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

export HOME="$TMP_DIR/home"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_STATE_HOME="$HOME/.local/state"
export HERDR_APP_BIN="$TMP_DIR/no-herdr-app"
export NOTIFY_RETRY_SLEEP=0
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
mkdir -p "$XDG_CONFIG_HOME/bercail/notify.d" "$TMP_DIR/bin"

# A fake curl: records the body and headers it was given, answers $CURL_CODE.
cat >"$TMP_DIR/bin/curl" <<EOF
#!/usr/bin/env bash
hdr=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -H) hdr="\${2#@}"; shift 2 ;;
    *) shift ;;
  esac
done
cat >>"$TMP_DIR/bodies.jsonl"
printf '\n' >>"$TMP_DIR/bodies.jsonl"
cat "\$hdr" >>"$TMP_DIR/headers.txt"
printf '%s' "\${CURL_CODE:-200}"
EOF
chmod +x "$TMP_DIR/bin/curl"
export NOTIFY_CURL="$TMP_DIR/bin/curl"

# shellcheck source=lib/notify.sh
source "$ROOT/lib/notify.sh"

sink="$XDG_CONFIG_HOME/bercail/notify.d/work-shep.toml"
cat >"$sink" <<'EOF'
url = "https://example.invalid/hook"
key = "secret-key"
auth = both
repos = myapp
notify = finished, blocked
EOF
chmod 600 "$sink"

# A checkout whose main worktree is named myapp, with a handoff record.
git init -q "$TMP_DIR/myapp"
git -C "$TMP_DIR/myapp" commit -q --allow-empty -m init
git -C "$TMP_DIR/myapp" worktree add -q -b feat "$TMP_DIR/myapp.feat"
desk="$TMP_DIR/myapp.feat"
mkdir -p "$XDG_STATE_HOME/agentic-dev"
jq -nc --arg p "$desk" '{path:$p, branch:"feat", issue:"myapp-1", stage:"start", harness:"claude"}' \
  >"$XDG_STATE_HOME/agentic-dev/handoffs.jsonl"

# One `hc events` line: every terminal, the desk with STATUS.
event() {
  jq -nc --arg s "$1" --arg cwd "$desk" '{seq:1, terminals:[
    {address:"t5", state:"live", status:{state:"working", app:"claude-code"}, labels:{"herdr.space":"sp1"}, cwd:"/"},
    {address:"t9", state:"live", status:(if $s == "" then null else {state:$s, app:"claude-code"} end),
     labels:{"bercail.role":"agent","bercail.space":"sp1"}, cwd:$cwd, title:"Beads\tissue myapp-1"}]}'
}

: >"$TMP_DIR/bodies.jsonl"
{ event done; event working; event working; event done; event idle; event working; event blocked; event blocked; event done; } \
  | notify_follow
kinds="$(jq -sc '[.[] | select(. != null) | .kind]' "$TMP_DIR/bodies.jsonl" 2>/dev/null)"
[[ "$kinds" == '["finished","blocked","finished"]' ]] || fail "kinds: $kinds"
printf 'PASS: a desk seen done first is not reported; working->done, blocked once, blocked->done are\n'

first="$(head -n 1 "$TMP_DIR/bodies.jsonl")"
jq -e --arg p "$desk" '
  .schema == "bercail.agent_status/v2" and .sink == "work-shep"
  and .agent.address == "t9" and .agent.status == "done" and .agent.previous_status == "working"
  and .agent.app == "claude-code" and .agent.title == "Beads issue myapp-1"
  and .space.id == "sp1" and .space.repo == "myapp" and .space.checkout_path == $p and .space.linked == true
  and .desk.issue == "myapp-1" and .desk.stage == "start" and .desk.branch == "feat"' <<<"$first" >/dev/null \
  || fail "payload: $first"
grep -q 'Authorization: Bearer secret-key' "$TMP_DIR/headers.txt" || fail "bearer header"
grep -q 'X-Automation-Key: secret-key' "$TMP_DIR/headers.txt" || fail "automation key header"
grep -q secret-key "$TMP_DIR/bodies.jsonl" && fail "the key must not be in the body"
printf 'PASS: the payload names the desk, its space and handoff; the key goes in headers only\n'

# An agent that reports no app: the empty field must not shift the others.
: >"$TMP_DIR/bodies.jsonl"
{ event working; event working | jq -c '.terminals[1].status = {state:"done"}'; } | notify_follow
jq -e --arg p "$desk" '.agent.app == null and .space.id == "sp1" and .space.checkout_path == $p' \
  "$TMP_DIR/bodies.jsonl" >/dev/null || fail "empty app shifted fields: $(cat "$TMP_DIR/bodies.jsonl")"
printf 'PASS: an empty field keeps the others in place\n'

# hc sends heartbeats between snapshots; they carry no terminals and must not
# make the follower forget the desk's previous status.
heartbeat() {
  printf '{"jsonrpc":"2.0","method":"heartbeat","params":{"seq":%s}}\n' "$1"
}
: >"$TMP_DIR/bodies.jsonl"
{ event working; heartbeat 3706; event done; } | notify_follow
kinds="$(jq -sc '[.[] | select(. != null) | .kind]' "$TMP_DIR/bodies.jsonl" 2>/dev/null)"
[[ "$kinds" == '["finished"]' ]] || fail "heartbeat between working and done: $kinds"
jq -e '.sink == "work-shep" and .space.repo == "myapp" and .space.linked == true' \
  "$TMP_DIR/bodies.jsonl" >/dev/null || fail "heartbeat finished payload: $(cat "$TMP_DIR/bodies.jsonl")"
: >"$TMP_DIR/bodies.jsonl"
{ event working; heartbeat 1; printf 'not json\n'; heartbeat 2; event blocked; } | notify_follow
kinds="$(jq -sc '[.[] | select(. != null) | .kind]' "$TMP_DIR/bodies.jsonl" 2>/dev/null)"
[[ "$kinds" == '["blocked"]' ]] || fail "heartbeat between working and blocked: $kinds"
printf 'PASS: heartbeats and other non-snapshot lines keep desk statuses; finished and blocked post\n'

# A snapshot sent as a JSON-RPC notification (terminals under params) counts.
: >"$TMP_DIR/bodies.jsonl"
{ event working; event done | jq -c '{jsonrpc:"2.0", method:"snapshot", params:.}'; } | notify_follow
kinds="$(jq -sc '[.[] | select(. != null) | .kind]' "$TMP_DIR/bodies.jsonl" 2>/dev/null)"
[[ "$kinds" == '["finished"]' ]] || fail "params snapshot: $kinds"
printf 'PASS: a snapshot under params is read like a top-level one\n'

# What hc actually sends: one snapshot, then an `event` per changed fact.
# (The 10:43 miss: the follower read the snapshot and nothing after it.)
status_event() {
  jq -nc --arg t "${2:-t9}" --arg s "$1" '{jsonrpc:"2.0", method:"event", params:{seq:9, terminal:$t,
    type:"status", data:{records:{}, reported:true,
      status:(if $s == "" then null else {app:"claude-code", state:$s, msg:"Reading"} end)}}}'
}
: >"$TMP_DIR/bodies.jsonl"
{ event working; heartbeat 4054
  printf '{"jsonrpc":"2.0","method":"event","params":{"seq":4055,"terminal":"t9","type":"size","data":{"cols":200,"rows":120}}}\n'
  status_event working; status_event working; status_event done; status_event idle
  status_event working; status_event blocked; status_event working; status_event done; } | notify_follow
kinds="$(jq -sc '[.[] | select(. != null) | .kind]' "$TMP_DIR/bodies.jsonl" 2>/dev/null)"
[[ "$kinds" == '["finished","blocked","finished"]' ]] || fail "event deltas: $kinds"
jq -se --arg p "$desk" '.[0] | .agent.address == "t9" and .agent.status == "done"
  and .agent.previous_status == "working" and .space.id == "sp1" and .space.repo == "myapp"
  and .space.checkout_path == $p and .desk.issue == "myapp-1"' "$TMP_DIR/bodies.jsonl" >/dev/null \
  || fail "event delta payload: $(head -n 1 "$TMP_DIR/bodies.jsonl")"
jq -e '.last_transition.address == "t9" and .last_transition.kind == "finished" and .last_transition_at > 0' \
  "$(notify_follower_file)" >/dev/null || fail "follower record: $(cat "$(notify_follower_file)")"
printf 'PASS: status events after the snapshot post finished and blocked, and the follower records them\n'

# A desk started after the snapshot: the follower asks hc where it is.
cat >"$TMP_DIR/bin/hc-get" <<EOF
#!/usr/bin/env bash
[[ "\$1 \$2" == "get t12" ]] || exit 1
jq -nc --arg cwd "$desk" '{address:"t12", state:"live", cwd:\$cwd, title:"New desk",
  labels:{"bercail.role":"agent","bercail.space":"sp2"}, status:{app:"codex", state:"idle"}}'
EOF
chmod +x "$TMP_DIR/bin/hc-get"
: >"$TMP_DIR/bodies.jsonl"
{ event working; status_event working t12; status_event done t12;
  printf '{"jsonrpc":"2.0","method":"event","params":{"seq":5,"terminal":"t9","type":"finished","data":{}}}\n'
  status_event done; } | HC_BIN="$TMP_DIR/bin/hc-get" notify_follow
jq -se 'length == 1 and .[0].agent.address == "t12" and .[0].space.id == "sp2" and .[0].agent.title == "New desk"' \
  "$TMP_DIR/bodies.jsonl" >/dev/null || fail "new desk / finished desk: $(cat "$TMP_DIR/bodies.jsonl")"
printf 'PASS: a desk started later is looked up; a finished terminal is forgotten\n'

# Filters: another repo is not sent.
sed -i 's/^repos = myapp/repos = other/' "$sink"
: >"$TMP_DIR/bodies.jsonl"
{ event working; event done; } | notify_follow
[[ ! -s "$TMP_DIR/bodies.jsonl" ]] || fail "a sink for another repo got: $(cat "$TMP_DIR/bodies.jsonl")"
sed -i 's/^repos = other/repos = myapp/' "$sink"
printf 'PASS: repos filter skips other repos\n'

# A readable key is refused.
chmod 644 "$sink"
: >"$TMP_DIR/bodies.jsonl"
{ event working; event done; } | notify_follow 2>"$TMP_DIR/err"
[[ ! -s "$TMP_DIR/bodies.jsonl" ]] || fail "insecure sink must not post"
grep -q 'chmod 600' "$TMP_DIR/err" || fail "insecure message: $(cat "$TMP_DIR/err")"
chmod 600 "$sink"
printf 'PASS: a group/other-readable key is not sent\n'

# A rejected key is recorded, and status shows it without secrets.
{ event working; event done; } | CURL_CODE=401 notify_follow 2>/dev/null
out="$(notify_status)"
printf '%s' "$out" | grep -q 'auth_failed=true' || fail "status: $out"
printf '%s' "$out" | grep -q 'secret-key\|example.invalid' && fail "status leaks: $out"
printf 'PASS: a rejected key is recorded and status prints no url or key\n'

out="$(notify_test work-shep)" || fail "test send: $out"
[[ "$out" == "work-shep HTTP 200" ]] || fail "test output: $out"
jq -e 'select(.kind == "test")' "$TMP_DIR/bodies.jsonl" >/dev/null || fail "test payload"
printf 'PASS: notify test sends a kind=test payload\n'

# doctor shows when the live follower last posted, without the url or key.
# shellcheck source=lib/doctor.sh
source "$ROOT/lib/doctor.sh"
log() { printf '%s\n' "$*"; }
cat >"$TMP_DIR/bin/hc" <<'EOF'
#!/usr/bin/env bash
printf '{"state":"live"}\n'
EOF
chmod +x "$TMP_DIR/bin/hc"
st="$(_notify_sink_state_file work-shep)"
jq -c '.last_ok_at = 1793314928 | .auth_failed = false' "$st" >"$st.new" && mv "$st.new" "$st"
out="$(HC_BIN="$TMP_DIR/bin/hc" doctor_notify)" || fail "doctor_notify: $out"
want="last post $(date -d @1793314928 '+%Y-%m-%d %H:%M' 2>/dev/null || date -r 1793314928 '+%Y-%m-%d %H:%M')"
printf '%s' "$out" | grep -q "ok  notify follower (hc terminal bercail-notify; $want)" || fail "doctor: $out"
printf '%s' "$out" | grep -q 'secret-key\|example.invalid' && fail "doctor leaks: $out"
rm -f "$st"
out="$(HC_BIN="$TMP_DIR/bin/hc" doctor_notify)" || fail "doctor_notify without state: $out"
printf '%s' "$out" | grep -q 'last post never' || fail "doctor never: $out"
printf 'PASS: doctor notes the last post next to a live follower\n'

# A live follower that didn't see a desk finish is flagged; one that saw it is fine.
now="$(date +%s)"
cat >"$TMP_DIR/bin/hc-desk" <<EOF
#!/usr/bin/env bash
case "\$1" in
  ls) printf '{"terminals":[{"address":"t3s","state":"live"}]}\n' ;;
  get) [[ "\$2" == t3s ]] && printf '{"address":"t3s","state":"live","status":{"state":"done"},"status_ms":%s}\n' "$(( (now - 30) * 1000 ))" \
    || printf '{"state":"live"}\n' ;;
esac
EOF
chmod +x "$TMP_DIR/bin/hc-desk"
printf '{"pid":1,"started_at":%s}\n' "$((now - 600))" >"$(notify_follower_file)"
out="$(HC_BIN="$TMP_DIR/bin/hc-desk" doctor_notify)" && fail "a deaf follower passed doctor: $out"
printf '%s' "$out" | grep -q 'deaf  notify follower is live but missed desk t3s' || fail "deaf: $out"
printf '{"pid":1,"started_at":%s,"last_transition_at":%s}\n' "$((now - 600))" "$((now - 29))" >"$(notify_follower_file)"
out="$(HC_BIN="$TMP_DIR/bin/hc-desk" doctor_notify)" || fail "a follower that saw it: $out"
printf '{"pid":1,"started_at":%s}\n' "$((now - 10))" >"$(notify_follower_file)"
out="$(HC_BIN="$TMP_DIR/bin/hc-desk" doctor_notify)" || fail "a finish before the follower started: $out"
rm -f "$(notify_follower_file)"
out="$(HC_BIN="$TMP_DIR/bin/hc-desk" doctor_notify)" && fail "an old follower passed doctor"
printf '%s' "$out" | grep -q 'runs an older bercail' || fail "old follower: $out"
printf 'PASS: doctor flags a live follower that missed a desk finishing, or runs older code\n'

# bercail update restarts a live follower so it runs the new code.
# Like hc: killing a --rm terminal removes it, and kill then answers not_found (exit 3).
cat >"$TMP_DIR/bin/hc-kill" <<EOF
#!/usr/bin/env bash
case "\$1" in
  kill) printf '%s\n' "\$2" >>"$TMP_DIR/killed"; exit 3 ;;
  get) [[ -s "$TMP_DIR/killed" ]] && exit 3; printf '{"state":"live"}\n' ;;
esac
EOF
chmod +x "$TMP_DIR/bin/hc-kill"
out="$(HC_BIN="$TMP_DIR/bin/hc-kill" notify_restart_follower 2>&1)"
[[ "$(cat "$TMP_DIR/killed")" == bercail-notify ]] || fail "update did not restart the follower"
[[ "$out" == "restarted the notify follower (hc terminal bercail-notify)" ]] || fail "restart output: $out"
printf 'PASS: update restarts the live follower\n'

# Right after that, before the desk mod starts the new follower, doctor says
# restarting and passes; once the window is over, a follower still gone is missing.
[[ "$(cat "$(notify_restart_file)")" =~ ^[0-9]+$ ]] || fail "restart not recorded"
out="$(HC_BIN="$TMP_DIR/bin/hc-kill" doctor_notify)" || fail "doctor failed during the restart: $out"
printf '%s' "$out" | grep -q 'restarting  notify follower' || fail "restarting: $out"
printf '%s' "$out" | grep -q 'missing  notify follower' && fail "missing during the restart: $out"
printf '%s\n' "$(( $(date +%s) - DOCTOR_NOTIFY_RESTART_WINDOW - 1 ))" >"$(notify_restart_file)"
out="$(HC_BIN="$TMP_DIR/bin/hc-kill" doctor_notify)" && fail "a gone follower passed doctor: $out"
printf '%s' "$out" | grep -q 'missing  notify follower' || fail "missing after the window: $out"
printf 'PASS: doctor reports restarting right after update, missing once the window passes\n'

# Neither bad state nor an update with no live follower grants a new window.
for stamp in invalid "$(( $(date +%s) + 600 ))"; do
  printf '%s\n' "$stamp" >"$(notify_restart_file)"
  out="$(HC_BIN="$TMP_DIR/bin/hc-kill" doctor_notify)" && fail "bad restart stamp passed doctor: $stamp"
  [[ "$out" == *'missing  notify follower'* ]] || fail "bad stamp: $out"
done
rm -f "$(notify_restart_file)"
HC_BIN="$TMP_DIR/bin/hc-kill" notify_restart_follower
[[ ! -e "$(notify_restart_file)" ]] || fail "missing follower got a restart window"
out="$(HC_BIN="$TMP_DIR/bin/hc-kill" doctor_notify)" && fail "missing follower passed without a stamp"
[[ "$out" == *'missing  notify follower'* ]] || fail "no stamp: $out"
printf 'PASS: invalid, future, and absent restart stamps do not hide a missing follower\n'

# A failed kill leaves no grace period; a new run clears a successful restart.
out="$(HC_BIN="$TMP_DIR/bin/hc" notify_restart_follower 2>&1)"
[[ "$out" == *'could not restart'* ]] || fail "failed kill: $out"
[[ ! -e "$(notify_restart_file)" ]] || fail "failed kill left a restart stamp"
rm -f "$TMP_DIR/killed"
HC_BIN="$TMP_DIR/bin/hc-kill" notify_restart_follower >/dev/null
HC_BIN="$TMP_DIR/bin/hc-kill" notify_run
[[ ! -e "$(notify_restart_file)" ]] || fail "new run left a restart stamp"
out="$(HC_BIN="$TMP_DIR/bin/hc" doctor_notify)" || fail "new follower failed doctor: $out"
[[ "$out" == *'ok  notify follower'* ]] || fail "new follower: $out"
out="$(HC_BIN="$TMP_DIR/bin/hc-kill" doctor_notify)" && fail "new follower's death hidden by restart stamp"
[[ "$out" == *'missing  notify follower'* ]] || fail "new follower's death: $out"
printf 'PASS: failed kills and completed restarts leave no grace period\n'

# notify add: url and key from stdin, written 0600, then tested; the key is never printed.
rm -f "$XDG_CONFIG_HOME/bercail/notify.d/"*.toml
: >"$TMP_DIR/headers.txt"
out="$(cd "$desk" && printf 'https://example.invalid/new\npasted-key\n' | notify_add bot-two --auth bearer 2>&1)" \
  || fail "notify add: $out"
added="$XDG_CONFIG_HOME/bercail/notify.d/bot-two.toml"
[[ "$(_notify_mode "$added")" == 600 ]] || fail "mode: $(_notify_mode "$added")"
[[ "$(notify_sink_value "$added" url)" == https://example.invalid/new ]] || fail "url: $(cat "$added")"
[[ "$(notify_sink_value "$added" repos)" == myapp ]] || fail "repos default: $(cat "$added")"
[[ "$(notify_sink_value "$added" notify)" == "finished, blocked" ]] || fail "notify default"
grep -q 'Authorization: Bearer pasted-key' "$TMP_DIR/headers.txt" || fail "add did not test with the key"
grep -q 'X-Automation-Key' "$TMP_DIR/headers.txt" && fail "--auth bearer sent the automation header"
printf '%s' "$out" | grep -q 'bot-two HTTP 200' || fail "add output: $out"
printf '%s' "$out" | grep -q pasted-key && fail "add printed the key: $out"
notify_status | grep -q '^- bot-two ' || fail "status does not list bot-two"
ls -A "$XDG_CONFIG_HOME/bercail/notify.d" | grep -q '^\.' && fail "temp file left behind"
printf 'PASS: notify add writes a 0600 sink from stdin, defaults repos to this checkout, and tests it\n'

# An existing sink is shown redacted and kept without --yes; --yes replaces it.
out="$(cd "$TMP_DIR" && printf 'https://example.invalid/other\nother-key\n' | notify_add bot-two 2>&1)" \
  && fail "replaced without --yes"
printf '%s' "$out" | grep -q 'url=https://example.invalid/\.\.\. key=set' || fail "redacted show: $out"
printf '%s' "$out" | grep -q 'pasted-key\|/new' && fail "existing values leaked: $out"
[[ "$(notify_sink_value "$added" url)" == https://example.invalid/new ]] || fail "kept sink changed"
out="$(cd "$TMP_DIR" && BERCAIL_NOTIFY_URL=https://example.invalid/env BERCAIL_NOTIFY_KEY=env-key \
  CURL_CODE=401 notify_add bot-two --yes </dev/null 2>&1)" && fail "a 401 must fail add"
printf '%s' "$out" | grep -q 'key or auth mode is wrong' || fail "401 hint: $out"
printf '%s' "$out" | grep -q 'env-key' && fail "401 output leaked the key: $out"
[[ "$(notify_sink_value "$added" repos)" == "" ]] || fail "outside a checkout repos should be all"
printf 'PASS: notify add asks before replacing, reads the environment, and names a 401 as a bad key\n'

notify_add bot-three --key oops </dev/null 2>/dev/null && fail "--key must be refused"
[[ ! -e "$XDG_CONFIG_HOME/bercail/notify.d/bot-three.toml" ]] || fail "--key wrote a sink"
printf 'PASS: notify add refuses a key on the command line\n'

# A stale `panes` line is dropped by the follower, keeping the mode.
printf 'panes = agent\n' >>"$added"
notify_drop_stale_keys "$added"
grep -q panes "$added" && fail "panes kept"
[[ "$(_notify_mode "$added")" == 600 ]] || fail "migration changed the mode"
printf 'PASS: the stale panes key is migrated away\n'

# Repo coverage. team covers myapp; a checkout of `other` is in no sink.
rm -f "$XDG_CONFIG_HOME/bercail/notify.d/"*.toml
git init -q "$TMP_DIR/other"
git -C "$TMP_DIR/other" commit -q --allow-empty -m init
notify_check "$TMP_DIR/other" 2>"$TMP_DIR/err" || fail "no sinks at all must not warn"
[[ ! -s "$TMP_DIR/err" ]] || fail "no sinks warned: $(cat "$TMP_DIR/err")"
team="$XDG_CONFIG_HOME/bercail/notify.d/team.toml"
printf 'url = "https://example.invalid/team"\nkey = "team-key"\nauth = both\nrepos = myapp\nnotify = finished, blocked\n' >"$team"
chmod 600 "$team"
notify_check "$desk" 2>"$TMP_DIR/err" || fail "a covered repo warned: $(cat "$TMP_DIR/err")"
[[ ! -s "$TMP_DIR/err" ]] || fail "a covered repo printed: $(cat "$TMP_DIR/err")"
notify_check "$TMP_DIR/other" 2>"$TMP_DIR/err" && fail "an uncovered repo passed"
[[ "$(wc -l <"$TMP_DIR/err")" -eq 1 ]] || fail "want one warning line: $(cat "$TMP_DIR/err")"
grep -q "no enabled sink covers repo 'other'.*bercail notify repo add team other" "$TMP_DIR/err" \
  || fail "warning: $(cat "$TMP_DIR/err")"
sed -i 's/^repos = myapp/repos = myapp\nenabled = false/' "$team"
notify_check "$desk" 2>/dev/null && fail "a disabled sink must not count"
sed -i '/^enabled = false/d' "$team"
printf 'PASS: notify check warns once for a repo no enabled sink covers, and not without sinks\n'

# handoff-spawn --branch runs that check on the new desk's checkout: the
# warning reaches stderr, stdout stays the spawn JSON, and the spawn succeeds.
# shellcheck source=skills/handoff/scripts/handoff-spawn
source "$ROOT/skills/handoff/scripts/handoff-spawn"
grep -q 'handoff_notify_check "$sibling"' "$ROOT/skills/handoff/scripts/handoff-spawn" \
  || fail "handoff-spawn --branch does not run the check"
out="$(BERCAIL_BIN="$ROOT/bin/bercail" handoff_notify_check "$TMP_DIR/other" 2>"$TMP_DIR/err")" \
  || fail "the check must not fail the spawn"
[[ -z "$out" ]] || fail "the check wrote to stdout: $out"
[[ "$(wc -l <"$TMP_DIR/err")" -eq 1 ]] || fail "handoff want one line: $(cat "$TMP_DIR/err")"
grep -q 'bercail notify repo add team other' "$TMP_DIR/err" || fail "handoff warning: $(cat "$TMP_DIR/err")"
grep -q team-key "$TMP_DIR/err" && fail "handoff warning leaked the key"
BERCAIL_BIN="$ROOT/bin/bercail" handoff_notify_check "$desk" 2>"$TMP_DIR/err" || fail "covered handoff"
[[ ! -s "$TMP_DIR/err" ]] || fail "covered handoff warned: $(cat "$TMP_DIR/err")"
BERCAIL_BIN="$TMP_DIR/no-bercail" handoff_notify_check "$TMP_DIR/other" 2>"$TMP_DIR/err" || fail "no bercail"
[[ ! -s "$TMP_DIR/err" ]] || fail "no bercail warned: $(cat "$TMP_DIR/err")"
printf 'PASS: handoff-spawn warns on stderr for an uncovered repo and still succeeds\n'

# doctor lists repos with a live desk that no enabled sink covers.
cat >"$TMP_DIR/bin/hc-cover" <<EOF
#!/usr/bin/env bash
case "\$1" in
  ls) jq -nc --arg a "$desk" --arg b "$TMP_DIR/other" '{terminals:[
        {address:"t1", state:"live", cwd:\$a}, {address:"t2", state:"live", cwd:\$b},
        {address:"t3", state:"live", cwd:\$b}, {address:"t4", state:"finished", cwd:"/"}]}' ;;
  get) printf '{"state":"live"}\n' ;;
esac
EOF
chmod +x "$TMP_DIR/bin/hc-cover"
printf '{"pid":1,"started_at":%s}\n' "$(date +%s)" >"$(notify_follower_file)"
out="$(HC_BIN="$TMP_DIR/bin/hc-cover" doctor_notify)" || fail "an uncovered repo must not fail doctor: $out"
[[ "$(grep -c uncovered <<<"$out")" -eq 1 ]] || fail "doctor uncovered lines: $out"
grep -q 'uncovered  repo other has a live desk but no enabled notify sink covers it (add it: bercail notify repo add team other)' \
  <<<"$out" || fail "doctor uncovered: $out"
grep -q 'repo myapp' <<<"$out" && fail "doctor listed a covered repo: $out"
grep -q 'team-key\|example.invalid' <<<"$out" && fail "doctor leaks: $out"
printf 'PASS: doctor lists a repo whose live desk no sink covers\n'

# notify repo add / remove edit the repos list in place.
before_mode="$(_notify_mode "$team")"
out="$(cd "$TMP_DIR/other" && notify_repo add team 2>&1)" || fail "repo add: $out"
[[ "$(notify_sink_value "$team" repos)" == "myapp, other" ]] || fail "repo add: $(cat "$team")"
[[ "$(_notify_mode "$team")" == "$before_mode" ]] || fail "repo add changed the mode"
[[ "$(notify_sink_value "$team" key)" == team-key && "$(notify_sink_value "$team" notify)" == "finished, blocked" ]] \
  || fail "repo add lost lines: $(cat "$team")"
grep -q team-key <<<"$out" && fail "repo add printed the key: $out"
ls -A "$XDG_CONFIG_HOME/bercail/notify.d" | grep -q '^\.' && fail "repo add left a temp file"
notify_check "$TMP_DIR/other" 2>/dev/null || fail "an added repo still warns"
out="$(notify_repo add team other)" || fail "repo add again: $out"
grep -q 'already covers other' <<<"$out" || fail "repo add again: $out"
[[ "$(grep -c '^repos' "$team")" -eq 1 ]] || fail "repos line duplicated: $(cat "$team")"
out="$("$ROOT/bin/bercail" notify repo remove team OTHER)" || fail "repo remove via the CLI: $out"
[[ "$(notify_sink_value "$team" repos)" == myapp ]] || fail "repo remove: $(cat "$team")"
out="$(notify_repo remove team nope)" || fail "remove absent: $out"
grep -q 'does not list nope' <<<"$out" || fail "remove absent: $out"
cp "$team" "$TMP_DIR/team.before"
notify_repo remove team myapp 2>"$TMP_DIR/err" && fail "removing the only repo must not widen the sink"
grep -q 'only repo' "$TMP_DIR/err" || fail "only repo: $(cat "$TMP_DIR/err")"
cmp -s "$team" "$TMP_DIR/team.before" || fail "a refused remove changed the file"
notify_repo remove team 2>/dev/null && fail "remove needs a repo"
notify_repo add nosuch myapp 2>/dev/null && fail "repo add to a missing sink"
notify_repo add team 'a b' 2>/dev/null && fail "a repo with a blank"
(cd "$TMP_DIR" && notify_repo add team 2>/dev/null) && fail "repo add outside a checkout needs a name"
printf 'PASS: notify repo add and remove edit the list, keep the rest, and refuse to widen a sink\n'

# An --all-repos sink covers everything: both are no-ops and say so.
everyone="$XDG_CONFIG_HOME/bercail/notify.d/everyone.toml"
printf 'url = "https://example.invalid/all"\nrepos = ""\nspaces = ""\n' >"$everyone"
cp "$everyone" "$TMP_DIR/everyone.before"
for action in add remove; do
  out="$(notify_repo "$action" everyone other)" || fail "all-repos $action: $out"
  grep -q 'covers every repo' <<<"$out" || fail "all-repos $action: $out"
done
cmp -s "$everyone" "$TMP_DIR/everyone.before" || fail "an all-repos sink was edited"
rm -f "$everyone"
# An old sink filtered only by space (`workspaces`, no repos line) still loads, and gets one.
old="$XDG_CONFIG_HOME/bercail/notify.d/old.toml"
printf 'url = "https://example.invalid/old"\nworkspaces = "*_Other"\n' >"$old"
notify_repo add old other >/dev/null || fail "repo add to an old sink"
[[ "$(notify_sink_value "$old" repos)" == other && "$(notify_sink_value "$old" workspaces)" == "*_Other" ]] \
  || fail "old sink: $(cat "$old")"
printf 'PASS: repo add and remove are no-ops on an --all-repos sink; an old sink gains a repos line\n'
