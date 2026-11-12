#!/usr/bin/env bats
# Agent status webhooks: the follower, its payloads, sinks, doctor, and the
# notify add / repo / check commands, against a fake curl and fake hc.
# `event done` passes the status done. ls | grep checks for hidden temp files.
# shellcheck disable=SC1010,SC2010

setup() {
  load test_helper
  isolate
  # As in the old set -euo pipefail: a pipeline that fails anywhere fails the test.
  set -o pipefail
  export HERDR_APP_BIN="$BATS_TEST_TMPDIR/no-herdr-app"
  export NOTIFY_RETRY_SLEEP=0
  export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
  export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
  mkdir -p "$XDG_CONFIG_HOME/bercail/notify.d" "$BATS_TEST_TMPDIR/bin"

  # A fake curl: records the body and headers it was given, answers $CURL_CODE.
  cat >"$BATS_TEST_TMPDIR/bin/curl" <<EOF
#!/usr/bin/env bash
hdr=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -H) hdr="\${2#@}"; shift 2 ;;
    *) shift ;;
  esac
done
cat >>"$BATS_TEST_TMPDIR/bodies.jsonl"
printf '\n' >>"$BATS_TEST_TMPDIR/bodies.jsonl"
cat "\$hdr" >>"$BATS_TEST_TMPDIR/headers.txt"
printf '%s' "\${CURL_CODE:-200}"
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/curl"
  export NOTIFY_CURL="$BATS_TEST_TMPDIR/bin/curl"

  # shellcheck source=/dev/null
  source "$ROOT/lib/notify.sh"
  # shellcheck source=/dev/null
  source "$ROOT/lib/shep.sh"

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
  git init -q "$BATS_TEST_TMPDIR/myapp"
  git -C "$BATS_TEST_TMPDIR/myapp" commit -q --allow-empty -m init
  git -C "$BATS_TEST_TMPDIR/myapp" worktree add -q -b feat "$BATS_TEST_TMPDIR/myapp.feat"
  desk="$BATS_TEST_TMPDIR/myapp.feat"
  mkdir -p "$XDG_STATE_HOME/agentic-dev"
  jq -nc --arg p "$desk" '{path:$p, branch:"feat", issue:"myapp-1", issue_title:"Fix the login", stage:"bstack", harness:"pi"}' \
    >"$XDG_STATE_HOME/agentic-dev/handoffs.jsonl"
  : >"$BATS_TEST_TMPDIR/bodies.jsonl"
}

# One `hc events` line: every terminal, the desk with STATUS.
event() {
  jq -nc --arg s "$1" --arg cwd "$desk" '{seq:1, terminals:[
    {address:"t5", state:"live", status:{state:"working", app:"pi"}, labels:{"herdr.space":"sp1"}, cwd:"/"},
    {address:"t9", state:"live", status:(if $s == "" then null else {state:$s, app:"pi"} end),
     labels:{"bercail.role":"agent","bercail.space":"sp1"}, cwd:$cwd, title:"Beads\tissue myapp-1"}]}'
}

# hc sends heartbeats between snapshots; they carry no terminals.
heartbeat() {
  printf '{"jsonrpc":"2.0","method":"heartbeat","params":{"seq":%s}}\n' "$1"
}

# What hc actually sends after its snapshot: an `event` per changed fact.
status_event() {
  jq -nc --arg t "${2:-t9}" --arg s "$1" '{jsonrpc:"2.0", method:"event", params:{seq:9, terminal:$t,
    type:"status", data:{records:{}, reported:true,
      status:(if $s == "" then null else {app:"pi", state:$s, msg:"Reading"} end)}}}'
}

kinds() {
  jq -sc '[.[] | select(. != null) | .kind]' "$BATS_TEST_TMPDIR/bodies.jsonl" 2>/dev/null
}

# The desk's statuses over a session: done seen first, then working->done, blocked twice, blocked->done.
follow_session() {
  { event done; event working; event working; event done; event idle; event working; event blocked; event blocked; event done; } \
    | notify_follow
}

load_doctor() {
  # shellcheck source=/dev/null
  source "$ROOT/lib/doctor.sh"
  log() { printf '%s\n' "$*"; }
}

# hc that says every terminal it is asked about is live.
hc_live() {
  cat >"$BATS_TEST_TMPDIR/bin/hc" <<'EOF'
#!/usr/bin/env bash
printf '{"state":"live"}\n'
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/hc"
}

# Like hc: killing a --rm terminal removes it, and kill then answers not_found (exit 3).
hc_kill() {
  cat >"$BATS_TEST_TMPDIR/bin/hc-kill" <<EOF
#!/usr/bin/env bash
case "\$1" in
  kill) printf '%s\n' "\$2" >>"$BATS_TEST_TMPDIR/killed"; exit 3 ;;
  get) [[ -s "$BATS_TEST_TMPDIR/killed" ]] && exit 3; printf '{"state":"live"}\n' ;;
esac
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/hc-kill"
}

# bercail update ended the live follower.
restarted_follower() {
  load_doctor
  hc_kill
  RESTART_OUT="$(HC_BIN="$BATS_TEST_TMPDIR/bin/hc-kill" notify_restart_follower 2>&1)"
}

# notify add bot-two from this checkout, with a pasted url and key.
add_bot_two() {
  rm -f "$XDG_CONFIG_HOME/bercail/notify.d/"*.toml
  : >"$BATS_TEST_TMPDIR/headers.txt"
  ADD_OUT="$(cd "$desk" && printf 'https://example.invalid/new\npasted-key\n' | notify_add bot-two --auth bearer 2>&1)" \
    || fail "notify add: $ADD_OUT"
  added="$XDG_CONFIG_HOME/bercail/notify.d/bot-two.toml"
}

# A checkout of `other`, and no sinks at all.
other_no_sinks() {
  rm -f "$XDG_CONFIG_HOME/bercail/notify.d/"*.toml
  git init -q "$BATS_TEST_TMPDIR/other"
  git -C "$BATS_TEST_TMPDIR/other" commit -q --allow-empty -m init
}

# Then one sink, team, covering myapp: `other` is in no sink.
add_team() {
  team="$XDG_CONFIG_HOME/bercail/notify.d/team.toml"
  printf 'url = "https://example.invalid/team"\nkey = "team-key"\nauth = both\nrepos = myapp\nnotify = finished, blocked\n' >"$team"
  chmod 600 "$team"
}

team_and_other() {
  other_no_sinks
  add_team
}

@test "a desk seen done first is not reported; working->done, blocked once, blocked->done are" {
  local got
  follow_session
  got="$(kinds)"
  [[ "$got" == '["finished","blocked","finished"]' ]] || fail "kinds: $got"
}

@test "the payload names the desk, its space and handoff; the key goes in headers only" {
  local first
  follow_session
  first="$(head -n 1 "$BATS_TEST_TMPDIR/bodies.jsonl")"
  jq -e --arg p "$desk" '
    .schema == "bercail.agent_status/v2" and .sink == "work-shep"
    and .agent.address == "t9" and .agent.status == "done" and .agent.previous_status == "working"
    and .agent.app == "pi" and .agent.title == "Beads issue myapp-1"
    and .space.id == "sp1" and .space.repo == "myapp" and .space.checkout_path == $p and .space.linked == true
    and .desk.issue == "myapp-1" and .desk.issue_title == "Fix the login" and .desk.stage == "bstack" and .desk.branch == "feat"
    and .text == "myapp-1: Fix the login. Desk t9 finished."' <<<"$first" >/dev/null \
    || fail "payload: $first"
  jq -se '.[1].kind == "blocked" and .[1].text == "myapp-1: Fix the login. Desk t9 is blocked." and .[1].desk.issue_title == "Fix the login"' \
    "$BATS_TEST_TMPDIR/bodies.jsonl" >/dev/null || fail "blocked text: $(sed -n 2p "$BATS_TEST_TMPDIR/bodies.jsonl")"
  grep -q 'Authorization: Bearer secret-key' "$BATS_TEST_TMPDIR/headers.txt" || fail "bearer header"
  grep -q 'X-Automation-Key: secret-key' "$BATS_TEST_TMPDIR/headers.txt" || fail "automation key header"
  if grep -q secret-key "$BATS_TEST_TMPDIR/bodies.jsonl"; then fail "the key must not be in the body"; fi
}

@test "an empty field keeps the others in place" {
  # An agent that reports no app: the empty field must not shift the others.
  { event working; event working | jq -c '.terminals[1].status = {state:"done"}'; } | notify_follow
  jq -e --arg p "$desk" '.agent.app == null and .space.id == "sp1" and .space.checkout_path == $p' \
    "$BATS_TEST_TMPDIR/bodies.jsonl" >/dev/null || fail "empty app shifted fields: $(cat "$BATS_TEST_TMPDIR/bodies.jsonl")"
}

@test "heartbeats and other non-snapshot lines keep desk statuses; finished and blocked post" {
  local got
  { event working; heartbeat 3706; event done; } | notify_follow
  got="$(kinds)"
  [[ "$got" == '["finished"]' ]] || fail "heartbeat between working and done: $got"
  jq -e '.sink == "work-shep" and .space.repo == "myapp" and .space.linked == true' \
    "$BATS_TEST_TMPDIR/bodies.jsonl" >/dev/null || fail "heartbeat finished payload: $(cat "$BATS_TEST_TMPDIR/bodies.jsonl")"
  : >"$BATS_TEST_TMPDIR/bodies.jsonl"
  { event working; heartbeat 1; printf 'not json\n'; heartbeat 2; event blocked; } | notify_follow
  got="$(kinds)"
  [[ "$got" == '["blocked"]' ]] || fail "heartbeat between working and blocked: $got"
}

@test "a snapshot under params is read like a top-level one" {
  local got
  { event working; event done | jq -c '{jsonrpc:"2.0", method:"snapshot", params:.}'; } | notify_follow
  got="$(kinds)"
  [[ "$got" == '["finished"]' ]] || fail "params snapshot: $got"
}

@test "status events after the snapshot post finished and blocked, and the follower records them" {
  local got
  # (The 10:43 miss: the follower read the snapshot and nothing after it.)
  { event working; heartbeat 4054
    printf '{"jsonrpc":"2.0","method":"event","params":{"seq":4055,"terminal":"t9","type":"size","data":{"cols":200,"rows":120}}}\n'
    status_event working; status_event working; status_event done; status_event idle
    status_event working; status_event blocked; status_event working; status_event done; } | notify_follow
  got="$(kinds)"
  [[ "$got" == '["finished","blocked","finished"]' ]] || fail "event deltas: $got"
  jq -se --arg p "$desk" '.[0] | .agent.address == "t9" and .agent.status == "done"
    and .agent.previous_status == "working" and .space.id == "sp1" and .space.repo == "myapp"
    and .space.checkout_path == $p and .desk.issue == "myapp-1"' "$BATS_TEST_TMPDIR/bodies.jsonl" >/dev/null \
    || fail "event delta payload: $(head -n 1 "$BATS_TEST_TMPDIR/bodies.jsonl")"
  jq -e '.last_transition.address == "t9" and .last_transition.kind == "finished" and .last_transition_at > 0' \
    "$(notify_follower_file)" >/dev/null || fail "follower record: $(cat "$(notify_follower_file)")"
}

@test "a desk started later is looked up, labels and all; a finished terminal is forgotten" {
  # A desk started after the snapshot: the follower asks hc where it is.
  cat >"$BATS_TEST_TMPDIR/bin/hc-get" <<EOF
#!/usr/bin/env bash
[[ "\$1 \$2" == "get t12" ]] || exit 1
jq -nc --arg cwd "$desk" '{address:"t12", state:"live", cwd:\$cwd, title:"New desk",
  labels:{"bercail.role":"agent","bercail.space":"sp2","bercail.issue":"bg-1","bercail.issue_title":"Wait for CI",
    "bercail.shep":"bg"}, status:{app:"pi", state:"idle"}}'
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/hc-get"
  { event working; status_event working t12; status_event done t12;
    printf '{"jsonrpc":"2.0","method":"event","params":{"seq":5,"terminal":"t9","type":"finished","data":{}}}\n'
    status_event done; } | HC_BIN="$BATS_TEST_TMPDIR/bin/hc-get" notify_follow
  jq -se 'length == 1 and .[0].agent.address == "t12" and .[0].space.id == "sp2" and .[0].agent.title == "New desk"
    and .[0].agent.role == "shep-bg" and .[0].desk.issue == "bg-1" and .[0].desk.issue_title == "Wait for CI"
    and .[0].desk.stage == null' \
    "$BATS_TEST_TMPDIR/bodies.jsonl" >/dev/null || fail "new desk / finished desk: $(cat "$BATS_TEST_TMPDIR/bodies.jsonl")"
}

@test "repos filter skips other repos" {
  sed -i 's/^repos = myapp/repos = other/' "$sink"
  { event working; event done; } | notify_follow
  [[ ! -s "$BATS_TEST_TMPDIR/bodies.jsonl" ]] || fail "a sink for another repo got: $(cat "$BATS_TEST_TMPDIR/bodies.jsonl")"
}

@test "a group/other-readable key is not sent" {
  chmod 644 "$sink"
  { event working; event done; } | notify_follow 2>"$BATS_TEST_TMPDIR/err"
  [[ ! -s "$BATS_TEST_TMPDIR/bodies.jsonl" ]] || fail "insecure sink must not post"
  grep -q 'chmod 600' "$BATS_TEST_TMPDIR/err" || fail "insecure message: $(cat "$BATS_TEST_TMPDIR/err")"
}

@test "a rejected key is recorded and status prints no url or key" {
  local out
  { event working; event done; } | CURL_CODE=401 notify_follow 2>/dev/null
  out="$(notify_status)"
  grep -q 'auth_failed=true' <<<"$out" || fail "status: $out"
  if grep -q 'secret-key\|example.invalid' <<<"$out"; then fail "status leaks: $out"; fi
}

@test "notify test sends a kind=test payload" {
  local out
  out="$(notify_test work-shep)" || fail "test send: $out"
  [[ "$out" == "work-shep HTTP 200 event test:"[0-9]* ]] || fail "test output: $out"
  jq -e 'select(.kind == "test") | .desk.issue_title == null and .text == "Test from bercail (sink work-shep)."' \
    "$BATS_TEST_TMPDIR/bodies.jsonl" >/dev/null || fail "test payload: $(jq -c 'select(.kind == "test")' "$BATS_TEST_TMPDIR/bodies.jsonl")"
}

@test "payload text names the issue and the desk" {
  local agent space noname desk_t notitle noissue dotted cut
  agent='{"address":"t9","app":"pi","status":"done","previous_status":"working","title":null}'
  space='{"id":"sp1","name":"Readable-titles_Bercail","repo":"bercail","checkout_path":"/w","linked":true}'
  noname='{"id":"sp1","name":null,"repo":"bercail","checkout_path":"/w","linked":true}'
  desk_t='{"branch":"readable-titles","issue":"bercail-wb1","issue_title":"Show the issue title next to every bd and desk id","stage":"bstack","harness":"pi","result":null}'
  notitle='{"branch":"readable-titles","issue":"bercail-wb1","issue_title":null,"stage":"bstack","harness":"pi","result":null}'
  noissue='{"branch":null,"issue":null,"issue_title":null,"stage":null,"harness":null,"result":null}'
  dotted='{"branch":"readable-titles","issue":"bercail-wb1","issue_title":"Show the title.","stage":"bstack","harness":"pi","result":null}'
  payload_text() { notify_payload "$1" work-shep "$agent" "$2" "$3" e1 | jq -r .text; }
  [[ "$(payload_text finished "$space" "$desk_t")" == "bercail-wb1: Show the issue title next to every bd and desk id. Desk t9 (Readable-titles_Bercail) finished." ]] \
    || fail "finished text: $(payload_text finished "$space" "$desk_t")"
  [[ "$(payload_text blocked "$space" "$desk_t")" == "bercail-wb1: Show the issue title next to every bd and desk id. Desk t9 (Readable-titles_Bercail) is blocked." ]] \
    || fail "blocked text: $(payload_text blocked "$space" "$desk_t")"
  [[ "$(payload_text finished "$space" "$noissue")" == "Desk t9 (Readable-titles_Bercail) finished." ]] \
    || fail "no issue text: $(payload_text finished "$space" "$noissue")"
  [[ "$(payload_text finished "$space" "$notitle")" == "bercail-wb1. Desk t9 (Readable-titles_Bercail) finished." ]] \
    || fail "bare id text: $(payload_text finished "$space" "$notitle")"
  [[ "$(payload_text finished "$noname" "$desk_t")" == "bercail-wb1: Show the issue title next to every bd and desk id. Desk t9 finished." ]] \
    || fail "no space name: $(payload_text finished "$noname" "$desk_t")"
  [[ "$(payload_text finished "$space" "$dotted")" == "bercail-wb1: Show the title. Desk t9 (Readable-titles_Bercail) finished." ]] \
    || fail "trailing period: $(payload_text finished "$space" "$dotted")"
  cut='{"branch":"readable-titles","issue":"bercail-wb1","issue_title":"Show the issue…","stage":"bstack","harness":"pi","result":null}'
  [[ "$(payload_text finished "$space" "$cut")" == "bercail-wb1: Show the issue… Desk t9 (Readable-titles_Bercail) finished." ]] \
    || fail "truncated title: $(payload_text finished "$space" "$cut")"
}

@test "doctor notes the last post next to a live follower" {
  local st out want
  # A follower that has posted: it left its record and the sink's delivery state.
  { event working; event done; } | notify_follow
  load_doctor
  hc_live
  st="$(_notify_sink_state_file work-shep)"
  jq -c '.last_ok_at = 1793314928 | .auth_failed = false' "$st" >"$st.new" && mv "$st.new" "$st"
  out="$(HC_BIN="$BATS_TEST_TMPDIR/bin/hc" doctor_notify)" || fail "doctor_notify: $out"
  want="last post $(date -d @1793314928 '+%Y-%m-%d %H:%M' 2>/dev/null || date -r 1793314928 '+%Y-%m-%d %H:%M')"
  grep -q "ok  notify follower (hc terminal bercail-notify; $want)" <<<"$out" || fail "doctor: $out"
  if grep -q 'secret-key\|example.invalid' <<<"$out"; then fail "doctor leaks: $out"; fi
  rm -f "$st"
  out="$(HC_BIN="$BATS_TEST_TMPDIR/bin/hc" doctor_notify)" || fail "doctor_notify without state: $out"
  grep -q 'last post never' <<<"$out" || fail "doctor never: $out"
}

@test "doctor flags a live follower that missed a desk finishing, or runs older code" {
  local now out
  load_doctor
  now="$(date +%s)"
  cat >"$BATS_TEST_TMPDIR/bin/hc-desk" <<EOF
#!/usr/bin/env bash
case "\$1" in
  ls) printf '{"terminals":[{"address":"t3s","state":"live"}]}\n' ;;
  get) [[ "\$2" == t3s ]] && printf '{"address":"t3s","state":"live","status":{"state":"done"},"status_ms":%s}\n' "$(( (now - 30) * 1000 ))" \
    || printf '{"state":"live"}\n' ;;
esac
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/hc-desk"
  printf '{"pid":1,"started_at":%s}\n' "$((now - 600))" >"$(notify_follower_file)"
  if out="$(HC_BIN="$BATS_TEST_TMPDIR/bin/hc-desk" doctor_notify)"; then fail "a deaf follower passed doctor: $out"; fi
  grep -q 'deaf  notify follower is live but missed desk t3s finishing or blocking' <<<"$out" || fail "deaf: $out"
  cat >"$BATS_TEST_TMPDIR/bin/hc-titled" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  ls) printf '{"terminals":[{"address":"t3s","state":"live"}]}\n' ;;
  get)
    if [[ "$2" == t3s ]]; then
      jq -nc --argjson ms "$HC_STATUS_MS" --arg title "${HC_ISSUE_TITLE:-}" '
        {address:"t3s", state:"live", status:{state:"done"}, status_ms:$ms,
         labels: ({"bercail.issue":"bercail-wb1"} + (if $title == "" then {} else {"bercail.issue_title":$title} end))}'
    else
      printf '{"state":"live"}\n'
    fi
    ;;
esac
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/hc-titled"
  if out="$(HC_BIN="$BATS_TEST_TMPDIR/bin/hc-titled" HC_STATUS_MS="$(( (now - 30) * 1000 ))" HC_ISSUE_TITLE='Show the title' doctor_notify)"; then
    fail "titled miss passed: $out"
  fi
  grep -q 'missed desk t3s (bercail-wb1: Show the title) finishing or blocking' <<<"$out" || fail "titled deaf: $out"
  if out="$(HC_BIN="$BATS_TEST_TMPDIR/bin/hc-titled" HC_STATUS_MS="$(( (now - 30) * 1000 ))" HC_ISSUE_TITLE='' doctor_notify)"; then
    fail "bare id miss passed: $out"
  fi
  grep -q 'missed desk t3s (bercail-wb1) finishing or blocking' <<<"$out" || fail "bare id deaf: $out"
  printf '{"pid":1,"started_at":%s,"last_transition_at":%s}\n' "$((now - 600))" "$((now - 29))" >"$(notify_follower_file)"
  out="$(HC_BIN="$BATS_TEST_TMPDIR/bin/hc-desk" doctor_notify)" || fail "a follower that saw it: $out"
  printf '{"pid":1,"started_at":%s}\n' "$((now - 10))" >"$(notify_follower_file)"
  out="$(HC_BIN="$BATS_TEST_TMPDIR/bin/hc-desk" doctor_notify)" || fail "a finish before the follower started: $out"
  rm -f "$(notify_follower_file)"
  if out="$(HC_BIN="$BATS_TEST_TMPDIR/bin/hc-desk" doctor_notify)"; then fail "an old follower passed doctor"; fi
  grep -q 'runs an older bercail' <<<"$out" || fail "old follower: $out"
}

@test "update restarts the live follower" {
  restarted_follower
  [[ "$(cat "$BATS_TEST_TMPDIR/killed")" == bercail-notify ]] || fail "update did not restart the follower"
  [[ "$RESTART_OUT" == "restarted the notify follower (hc terminal bercail-notify)" ]] || fail "restart output: $RESTART_OUT"
}

@test "doctor reports restarting right after update, missing once the window passes" {
  local out
  # Right after the restart, before the desk mod starts the new follower.
  restarted_follower
  [[ "$(cat "$(notify_restart_file)")" =~ ^[0-9]+$ ]] || fail "restart not recorded"
  out="$(HC_BIN="$BATS_TEST_TMPDIR/bin/hc-kill" doctor_notify)" || fail "doctor failed during the restart: $out"
  grep -q 'restarting  notify follower' <<<"$out" || fail "restarting: $out"
  if grep -q 'missing  notify follower' <<<"$out"; then fail "missing during the restart: $out"; fi
  printf '%s\n' "$(( $(date +%s) - DOCTOR_NOTIFY_RESTART_WINDOW - 1 ))" >"$(notify_restart_file)"
  if out="$(HC_BIN="$BATS_TEST_TMPDIR/bin/hc-kill" doctor_notify)"; then fail "a gone follower passed doctor: $out"; fi
  grep -q 'missing  notify follower' <<<"$out" || fail "missing after the window: $out"
}

@test "invalid, future, and absent restart stamps do not hide a missing follower" {
  local stamp out
  # Neither bad state nor an update with no live follower grants a new window.
  restarted_follower
  for stamp in invalid "$(( $(date +%s) + 600 ))"; do
    printf '%s\n' "$stamp" >"$(notify_restart_file)"
    if out="$(HC_BIN="$BATS_TEST_TMPDIR/bin/hc-kill" doctor_notify)"; then fail "bad restart stamp passed doctor: $stamp"; fi
    [[ "$out" == *'missing  notify follower'* ]] || fail "bad stamp: $out"
  done
  rm -f "$(notify_restart_file)"
  HC_BIN="$BATS_TEST_TMPDIR/bin/hc-kill" notify_restart_follower
  [[ ! -e "$(notify_restart_file)" ]] || fail "missing follower got a restart window"
  if out="$(HC_BIN="$BATS_TEST_TMPDIR/bin/hc-kill" doctor_notify)"; then fail "missing follower passed without a stamp"; fi
  [[ "$out" == *'missing  notify follower'* ]] || fail "no stamp: $out"
}

@test "failed kills and completed restarts leave no grace period" {
  local out
  load_doctor
  hc_live
  hc_kill
  out="$(HC_BIN="$BATS_TEST_TMPDIR/bin/hc" notify_restart_follower 2>&1)"
  [[ "$out" == *'could not restart'* ]] || fail "failed kill: $out"
  [[ ! -e "$(notify_restart_file)" ]] || fail "failed kill left a restart stamp"
  rm -f "$BATS_TEST_TMPDIR/killed"
  HC_BIN="$BATS_TEST_TMPDIR/bin/hc-kill" notify_restart_follower >/dev/null
  HC_BIN="$BATS_TEST_TMPDIR/bin/hc-kill" notify_run
  [[ ! -e "$(notify_restart_file)" ]] || fail "new run left a restart stamp"
  out="$(HC_BIN="$BATS_TEST_TMPDIR/bin/hc" doctor_notify)" || fail "new follower failed doctor: $out"
  [[ "$out" == *'ok  notify follower'* ]] || fail "new follower: $out"
  if out="$(HC_BIN="$BATS_TEST_TMPDIR/bin/hc-kill" doctor_notify)"; then fail "new follower's death hidden by restart stamp"; fi
  [[ "$out" == *'missing  notify follower'* ]] || fail "new follower's death: $out"
}

@test "notify add writes a 0600 sink from stdin, defaults repos to this checkout, and tests it" {
  add_bot_two
  [[ "$(_notify_mode "$added")" == 600 ]] || fail "mode: $(_notify_mode "$added")"
  [[ "$(notify_sink_value "$added" url)" == https://example.invalid/new ]] || fail "url: $(cat "$added")"
  [[ "$(notify_sink_value "$added" repos)" == myapp ]] || fail "repos default: $(cat "$added")"
  [[ "$(notify_sink_value "$added" notify)" == "finished, blocked" ]] || fail "notify default"
  grep -q 'Authorization: Bearer pasted-key' "$BATS_TEST_TMPDIR/headers.txt" || fail "add did not test with the key"
  if grep -q 'X-Automation-Key' "$BATS_TEST_TMPDIR/headers.txt"; then fail "--auth bearer sent the automation header"; fi
  grep -q 'bot-two HTTP 200' <<<"$ADD_OUT" || fail "add output: $ADD_OUT"
  if grep -q pasted-key <<<"$ADD_OUT"; then fail "add printed the key: $ADD_OUT"; fi
  notify_status | grep -q '^- bot-two ' || fail "status does not list bot-two"
  if ls -A "$XDG_CONFIG_HOME/bercail/notify.d" | grep -q '^\.'; then fail "temp file left behind"; fi
}

@test "notify add asks before replacing, reads the environment, and names a 401 as a bad key" {
  local out
  # An existing sink is shown redacted and kept without --yes; --yes replaces it.
  add_bot_two
  if out="$(cd "$BATS_TEST_TMPDIR" && printf 'https://example.invalid/other\nother-key\n' | notify_add bot-two 2>&1)"; then
    fail "replaced without --yes"
  fi
  grep -q 'url=https://example.invalid/\.\.\. key=set' <<<"$out" || fail "redacted show: $out"
  if grep -q 'pasted-key\|/new' <<<"$out"; then fail "existing values leaked: $out"; fi
  [[ "$(notify_sink_value "$added" url)" == https://example.invalid/new ]] || fail "kept sink changed"
  if out="$(cd "$BATS_TEST_TMPDIR" && BERCAIL_NOTIFY_URL=https://example.invalid/env BERCAIL_NOTIFY_KEY=env-key \
    CURL_CODE=401 notify_add bot-two --yes </dev/null 2>&1)"; then
    fail "a 401 must fail add"
  fi
  grep -q 'key or auth mode is wrong' <<<"$out" || fail "401 hint: $out"
  if grep -q 'env-key' <<<"$out"; then fail "401 output leaked the key: $out"; fi
  [[ "$(notify_sink_value "$added" repos)" == "" ]] || fail "outside a checkout repos should be all"
}

@test "notify add refuses a key on the command line" {
  if notify_add bot-three --key oops </dev/null 2>/dev/null; then fail "--key must be refused"; fi
  [[ ! -e "$XDG_CONFIG_HOME/bercail/notify.d/bot-three.toml" ]] || fail "--key wrote a sink"
}

@test "the stale panes key is migrated away" {
  # A stale `panes` line is dropped by the follower, keeping the mode.
  add_bot_two
  printf 'panes = agent\n' >>"$added"
  notify_drop_stale_keys "$added"
  if grep -q panes "$added"; then fail "panes kept"; fi
  [[ "$(_notify_mode "$added")" == 600 ]] || fail "migration changed the mode"
}

@test "notify check warns once for a repo no enabled sink covers, and not without sinks" {
  other_no_sinks
  notify_check "$BATS_TEST_TMPDIR/other" 2>"$BATS_TEST_TMPDIR/err" || fail "no sinks at all must not warn"
  [[ ! -s "$BATS_TEST_TMPDIR/err" ]] || fail "no sinks warned: $(cat "$BATS_TEST_TMPDIR/err")"
  add_team
  notify_check "$desk" 2>"$BATS_TEST_TMPDIR/err" || fail "a covered repo warned: $(cat "$BATS_TEST_TMPDIR/err")"
  [[ ! -s "$BATS_TEST_TMPDIR/err" ]] || fail "a covered repo printed: $(cat "$BATS_TEST_TMPDIR/err")"
  if notify_check "$BATS_TEST_TMPDIR/other" 2>"$BATS_TEST_TMPDIR/err"; then fail "an uncovered repo passed"; fi
  [[ "$(wc -l <"$BATS_TEST_TMPDIR/err")" -eq 1 ]] || fail "want one warning line: $(cat "$BATS_TEST_TMPDIR/err")"
  grep -q "no enabled sink covers repo 'other'.*bercail notify repo add team other" "$BATS_TEST_TMPDIR/err" \
    || fail "warning: $(cat "$BATS_TEST_TMPDIR/err")"
  sed -i 's/^repos = myapp/repos = myapp\nenabled = false/' "$team"
  if notify_check "$desk" 2>/dev/null; then fail "a disabled sink must not count"; fi
}

@test "the handoff notify check warns on stderr for an uncovered repo and still succeeds" {
  local out
  team_and_other
  # shellcheck source=/dev/null
  source "$ROOT/skills/handoff/scripts/handoff-spawn"
  out="$(BERCAIL_BIN="$ROOT/bin/bercail" handoff_notify_check "$BATS_TEST_TMPDIR/other" 2>"$BATS_TEST_TMPDIR/err")" \
    || fail "the check must not fail the spawn"
  [[ -z "$out" ]] || fail "the check wrote to stdout: $out"
  [[ "$(wc -l <"$BATS_TEST_TMPDIR/err")" -eq 1 ]] || fail "handoff want one line: $(cat "$BATS_TEST_TMPDIR/err")"
  grep -q 'bercail notify repo add team other' "$BATS_TEST_TMPDIR/err" || fail "handoff warning: $(cat "$BATS_TEST_TMPDIR/err")"
  if grep -q team-key "$BATS_TEST_TMPDIR/err"; then fail "handoff warning leaked the key"; fi
  BERCAIL_BIN="$ROOT/bin/bercail" handoff_notify_check "$desk" 2>"$BATS_TEST_TMPDIR/err" || fail "covered handoff"
  [[ ! -s "$BATS_TEST_TMPDIR/err" ]] || fail "covered handoff warned: $(cat "$BATS_TEST_TMPDIR/err")"
  BERCAIL_BIN="$BATS_TEST_TMPDIR/no-bercail" handoff_notify_check "$BATS_TEST_TMPDIR/other" 2>"$BATS_TEST_TMPDIR/err" || fail "no bercail"
  [[ ! -s "$BATS_TEST_TMPDIR/err" ]] || fail "no bercail warned: $(cat "$BATS_TEST_TMPDIR/err")"
}

@test "doctor lists a repo whose live desk no sink covers" {
  local out
  team_and_other
  load_doctor
  cat >"$BATS_TEST_TMPDIR/bin/hc-cover" <<EOF
#!/usr/bin/env bash
case "\$1" in
  ls) jq -nc --arg a "$desk" --arg b "$BATS_TEST_TMPDIR/other" '{terminals:[
        {address:"t1", state:"live", cwd:\$a}, {address:"t2", state:"live", cwd:\$b},
        {address:"t3", state:"live", cwd:\$b}, {address:"t4", state:"finished", cwd:"/"}]}' ;;
  get) printf '{"state":"live"}\n' ;;
esac
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/hc-cover"
  printf '{"pid":1,"started_at":%s}\n' "$(date +%s)" >"$(notify_follower_file)"
  out="$(HC_BIN="$BATS_TEST_TMPDIR/bin/hc-cover" doctor_notify)" || fail "an uncovered repo must not fail doctor: $out"
  [[ "$(grep -c uncovered <<<"$out")" -eq 1 ]] || fail "doctor uncovered lines: $out"
  grep -q 'uncovered  repo other has a live desk but no enabled notify sink covers it (add it: bercail notify repo add team other)' \
    <<<"$out" || fail "doctor uncovered: $out"
  if grep -q 'repo myapp' <<<"$out"; then fail "doctor listed a covered repo: $out"; fi
  if grep -q 'team-key\|example.invalid' <<<"$out"; then fail "doctor leaks: $out"; fi
}

@test "notify repo add and remove edit the list, keep the rest, and refuse to widen a sink" {
  local before_mode out
  team_and_other
  before_mode="$(_notify_mode "$team")"
  out="$(cd "$BATS_TEST_TMPDIR/other" && notify_repo add team 2>&1)" || fail "repo add: $out"
  [[ "$(notify_sink_value "$team" repos)" == "myapp, other" ]] || fail "repo add: $(cat "$team")"
  [[ "$(_notify_mode "$team")" == "$before_mode" ]] || fail "repo add changed the mode"
  [[ "$(notify_sink_value "$team" key)" == team-key && "$(notify_sink_value "$team" notify)" == "finished, blocked" ]] \
    || fail "repo add lost lines: $(cat "$team")"
  if grep -q team-key <<<"$out"; then fail "repo add printed the key: $out"; fi
  if ls -A "$XDG_CONFIG_HOME/bercail/notify.d" | grep -q '^\.'; then fail "repo add left a temp file"; fi
  notify_check "$BATS_TEST_TMPDIR/other" 2>/dev/null || fail "an added repo still warns"
  out="$(notify_repo add team other)" || fail "repo add again: $out"
  grep -q 'already covers other' <<<"$out" || fail "repo add again: $out"
  [[ "$(grep -c '^repos' "$team")" -eq 1 ]] || fail "repos line duplicated: $(cat "$team")"
  out="$("$ROOT/bin/bercail" notify repo remove team OTHER)" || fail "repo remove via the CLI: $out"
  [[ "$(notify_sink_value "$team" repos)" == myapp ]] || fail "repo remove: $(cat "$team")"
  out="$(notify_repo remove team nope)" || fail "remove absent: $out"
  grep -q 'does not list nope' <<<"$out" || fail "remove absent: $out"
  cp "$team" "$BATS_TEST_TMPDIR/team.before"
  if notify_repo remove team myapp 2>"$BATS_TEST_TMPDIR/err"; then fail "removing the only repo must not widen the sink"; fi
  grep -q 'only repo' "$BATS_TEST_TMPDIR/err" || fail "only repo: $(cat "$BATS_TEST_TMPDIR/err")"
  cmp -s "$team" "$BATS_TEST_TMPDIR/team.before" || fail "a refused remove changed the file"
  if notify_repo remove team 2>/dev/null; then fail "remove needs a repo"; fi
  if notify_repo add nosuch myapp 2>/dev/null; then fail "repo add to a missing sink"; fi
  if notify_repo add team 'a b' 2>/dev/null; then fail "a repo with a blank"; fi
  if (cd "$BATS_TEST_TMPDIR" && notify_repo add team 2>/dev/null); then fail "repo add outside a checkout needs a name"; fi
}

@test "repo add and remove are no-ops on an --all-repos sink; an old sink gains a repos line" {
  local everyone old action out
  team_and_other
  # An --all-repos sink covers everything: both are no-ops and say so.
  everyone="$XDG_CONFIG_HOME/bercail/notify.d/everyone.toml"
  printf 'url = "https://example.invalid/all"\nrepos = ""\nspaces = ""\n' >"$everyone"
  cp "$everyone" "$BATS_TEST_TMPDIR/everyone.before"
  for action in add remove; do
    out="$(notify_repo "$action" everyone other)" || fail "all-repos $action: $out"
    grep -q 'covers every repo' <<<"$out" || fail "all-repos $action: $out"
  done
  cmp -s "$everyone" "$BATS_TEST_TMPDIR/everyone.before" || fail "an all-repos sink was edited"
  rm -f "$everyone"
  # An old sink filtered only by space (`workspaces`, no repos line) still loads, and gets one.
  old="$XDG_CONFIG_HOME/bercail/notify.d/old.toml"
  printf 'url = "https://example.invalid/old"\nworkspaces = "*_Other"\n' >"$old"
  notify_repo add old other >/dev/null || fail "repo add to an old sink"
  [[ "$(notify_sink_value "$old" repos)" == other && "$(notify_sink_value "$old" workspaces)" == "*_Other" ]] \
    || fail "old sink: $(cat "$old")"
}
