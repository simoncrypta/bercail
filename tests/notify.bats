#!/usr/bin/env bats
# The desk follower: it reads `hc events` from a fake hc and writes each finish
# or block to Shep's inbox, with a current source projection beside it.
# `event done` passes the status done. The sink commands are gone.
# shellcheck disable=SC1010

setup() {
  load test_helper
  isolate
  # As in the old set -euo pipefail: a pipeline that fails anywhere fails the test.
  set -o pipefail
  export HERDR_APP_BIN="$BATS_TEST_TMPDIR/no-herdr-app" HC_BIN="$BATS_TEST_TMPDIR/no-hc"
  export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
  export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
  mkdir -p "$BATS_TEST_TMPDIR/bin"

  # shellcheck source=/dev/null
  source "$ROOT/lib/notify.sh"
  # shellcheck source=/dev/null
  source "$ROOT/lib/shep.sh"
  # A clock that ticks once per read, so one desk's two finishes get two inbox files.
  _notify_now() {
    local t
    t="$(( $(cat "$BATS_TEST_TMPDIR/clock" 2>/dev/null || printf 1794886800) + 1 ))"
    printf '%s' "$t" >"$BATS_TEST_TMPDIR/clock"
    printf '%s' "$t"
  }

  # A checkout whose main worktree is named myapp, with a handoff record.
  git init -q "$BATS_TEST_TMPDIR/myapp"
  git -C "$BATS_TEST_TMPDIR/myapp" commit -q --allow-empty -m init
  git -C "$BATS_TEST_TMPDIR/myapp" worktree add -q -b feat "$BATS_TEST_TMPDIR/myapp.feat"
  desk="$BATS_TEST_TMPDIR/myapp.feat"
  mkdir -p "$XDG_STATE_HOME/bercail"
  jq -nc --arg p "$desk" '{path:$p, branch:"feat", issue:"myapp-1", issue_title:"Fix the login", stage:"bstack", harness:"pi"}' \
    >"$XDG_STATE_HOME/bercail/handoffs.jsonl"
  # Shep has started once: its inbox exists, so the follower writes to it.
  mkdir -p "$(shep_state_dir)/inbox"
}

# Shep's inbox events, oldest first by the second (and sequence) in their id.
events() {
  find "$(shep_state_dir)/inbox" -maxdepth 1 -name '*.json' -exec cat {} + \
    | jq -sc 'sort_by(.event_id | split(":")[2] | tonumber? // 0)'
}

kinds() {
  events | jq -c 'map(.kind)'
}

@test "an incomplete provider review projects a stable blocked episode rather than a new finish" {
  mkdir -p "$desk/.bercail"
  printf '%s\n' '{"status":"blocked","summary":"review incomplete","session_id":"session-237","issue":"myapp-1","completion":"incomplete","reason":"provider_safety_block","provider_error":{"reason":"provider_safety_block","completion":"incomplete","episode_id":"session-237:user-1","candidate":"tree-237","phase":"final-review","role":"judge"}}' >"$desk/.bercail/handoff-result.json"
  notify_desk_changed t9 working done pi sp1 "$desk" 'Review' myapp-1 'Fix the login'
  notify_desk_changed t9 working done pi sp1 "$desk" 'Review' myapp-1 'Fix the login'
  events | jq -e 'length == 1 and all(.[]; .kind == "blocked" and .event_id == "provider-error:session-237:user-1:blocked"
    and .desk.result.provider_error.candidate == "tree-237" and (.text | contains("is blocked")))' >/dev/null \
    || fail "want one blocked episode: $(events)"
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
  jq -nc --arg t "${2:-t9}" --arg s "$1" --argjson seq "${3:-null}" '
    {jsonrpc:"2.0", method:"event", params:{seq:$seq, terminal:$t,
    type:"status", data:{records:{}, reported:true,
      status:(if $s == "" then null else {app:"pi", state:$s, msg:"Reading"} end)}}}'
}

# The desk's statuses over a session: done seen first, then working->done, blocked twice, blocked->done.
follow_session() {
  { event done; event working; event working; event done; event idle; event working; event blocked; event blocked; event done; } \
    | notify_follow
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

# Reconciliation is a current projection beside the inbox, never a historical event.
source_state() {
  printf '%s/source-state.json' "$(shep_state_dir)"
}

@test "first-seen terminal states reconcile for Shep without invented events" {
  local state status
  mkdir -p "$desk/.bercail"
  printf '{"issue":"myapp-1","summary":"untrusted-answer","status":"ready"}\n' >"$desk/.bercail/handoff-result.json"
  for status in done idle blocked; do
    event "$status" | jq -c '.terminals[1].title = "untrusted-title"
      | .terminals[1].labels += {"bercail.issue":"bg-2","bercail.issue_title":"untrusted-issue-title","bercail.shep":"bg"}' \
      | notify_follow
    state="$(source_state)"
    [[ -f "$state" ]] || fail "no source projection for first-seen $status"
    jq -e --arg p "$desk" --arg s "$status" '
      .source == "bercail" and .schema == "bercail.source_state/v1" and .kind == "reconciliation"
      and (.observed_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T"))
      and .history_gap == true and .possibly_stale == true and (has("event_id") | not)
      and (.desks | length) == 1 and (.desks[0] | .observed_at != null
        and .agent == {address:"t9",app:"pi",status:$s,role:"shep-bg"}
        and .space.id == "sp1" and .space.repo == "myapp" and .space.checkout_path == $p
        and .desk.issue == "bg-2" and .desk.branch == "feat" and .desk.stage == null)
      and ([.. | objects | has("event_id") or has("title") or has("issue_title") or has("result")] | any | not)
    ' "$state" >/dev/null || fail "bad $status projection: $(<"$state")"
  done
  [[ -z "$(find "$(shep_state_dir)/inbox" -type f -print)" ]] || fail "invented source event"
  [[ "$(stat -c %a "$state")" == 600 ]] || fail "source projection is not private"
  if grep -q 'untrusted-' "$state"; then fail "source projection contains desk-authored prose"; fi
  [[ -z "$(find "$(shep_state_dir)" -maxdepth 1 -name '.source-state.*' -print)" ]] || fail "source temp file leaked"
}

@test "notify run keeps ordinary events separate from current source reconciliation" {
  { event working; status_event done; } >"$BATS_TEST_TMPDIR/source-stream.jsonl"
  cat >"$BATS_TEST_TMPDIR/bin/hc" <<EOF
#!/usr/bin/env bash
printf '%s\\n' "\$*" >>"$BATS_TEST_TMPDIR/source-hc.log"
[[ "\$1" == events ]] || exit 1
cat "$BATS_TEST_TMPDIR/source-stream.jsonl"
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/hc"
  HC_BIN="$BATS_TEST_TMPDIR/bin/hc" notify_run
  [[ -f "$(source_state)" ]] || fail "notify run did not publish source reconciliation"
  jq -e '.desks[0].agent.status == "done"' "$(source_state)" >/dev/null || fail "source not current"
  [[ "$(find "$(shep_state_dir)/inbox" -name '*.json' | wc -l)" -eq 1 ]] || fail "source became an inbox event"
  jq -e '.kind == "finished" and (.event_id | startswith("t9:finished:"))' \
    "$(shep_state_dir)/inbox/"*.json >/dev/null || fail "ordinary source event lost its identity"
  grep -qx 'events --json --label bercail.role=agent' "$BATS_TEST_TMPDIR/source-hc.log" || fail "did not use fake hc events"
}

@test "missed snapshots replace source mappings and status deltas clear stale terminal observations" {
  { event working
    event done | jq -c '.terminals[1].address = "t12"
      | .terminals[1].labels += {"bercail.issue":"other-2","bercail.space":"sp2"}
      | {jsonrpc:"2.0",method:"missed",params:.}'
    status_event working t12
  } | notify_follow
  [[ -f "$(source_state)" ]] || fail "no missed-snapshot projection"
  jq -e '.desks | length == 1 and .[0].agent.address == "t12" and .[0].agent.status == "working"
    and .[0].space.id == "sp2" and .[0].desk.issue == "other-2"' "$(source_state)" >/dev/null \
    || fail "missed snapshot retained old mapping or stale done status: $(<"$(source_state)")"
  [[ "$(kinds)" == '[]' ]] || fail "first-seen missed snapshot fabricated a transition: $(kinds)"
}

@test "reconciliation survives follower restart and malformed source does not erase valid state" {
  event done | notify_follow
  [[ -f "$(source_state)" ]] || fail "no initial source projection"
  event blocked | notify_follow
  jq -e '.desks[0].agent.status == "blocked"' "$(source_state)" >/dev/null || fail "restart missed blocked"
  cp "$(source_state)" "$BATS_TEST_TMPDIR/source.before"
  printf '%s\n' 'not json' '{"method":"missed","params":{}}' '{"terminals":null}' \
    '{"terminals":[null]}' '{"terminals":[{"address":"bad","state":"live","labels":{},"status":"bad"}]}' \
    '{"terminals":[{"address":"t9","state":"live","labels":{"bercail.role":"agent"},"status":{"state":{}}}]}' \
    | notify_follow
  cmp -s "$(source_state)" "$BATS_TEST_TMPDIR/source.before" || fail "malformed snapshot erased source"
}

@test "malformed status deltas do not replace a valid source observation" {
  { event blocked
    printf '%s\n' '{"method":"event","params":{"terminal":"t9","type":"status","data":{"status":"bad"}}}' \
      '{"method":"event","params":{"terminal":"t9","type":"status","data":{"status":{"state":{}}}}}'
  } | notify_follow
  [[ -f "$(source_state)" ]] || fail "no source projection"
  jq -e '.desks[0].agent.status == "blocked"' "$(source_state)" >/dev/null || fail "malformed delta replaced source status"
}

@test "whole empty snapshots and gone terminal events remove source mappings" {
  local gone
  for gone in finished removed lost; do
    { event done
      jq -nc --arg type "$gone" '{method:"event",params:{terminal:"t9",type:$type,data:{}}}'
    } | notify_follow
    [[ -f "$(source_state)" ]] || fail "no source projection"
    jq -e '.desks == []' "$(source_state)" >/dev/null || fail "$gone retained source mapping"
  done
  { event done; printf '{"terminals":[]}\n'; } | notify_follow
  jq -e '.desks == []' "$(source_state)" >/dev/null || fail "whole empty snapshot retained gone desk"
}

@test "failed label and restart lookups discard the old source mapping" {
  local type
  cat >"$BATS_TEST_TMPDIR/bin/hc-gone" <<EOF
#!/usr/bin/env bash
printf '%s\\n' "\$*" >>"$BATS_TEST_TMPDIR/source-hc.log"
exit 1
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/hc-gone"
  for type in labels restarted; do
    { event done
      jq -nc --arg type "$type" '{method:"event",params:{terminal:"t9",type:$type,data:{}}}'
    } | HC_BIN="$BATS_TEST_TMPDIR/bin/hc-gone" notify_follow
    [[ -f "$(source_state)" ]] || fail "no source projection"
    jq -e '.desks == []' "$(source_state)" >/dev/null || fail "$type lookup failure retained old mapping"
  done
  [[ "$(grep -c '^get t9 --json$' "$BATS_TEST_TMPDIR/source-hc.log")" -eq 2 ]] || fail "did not use fake hc lookup"
}

@test "empty missed snapshots forget all mapping before a terminal address is reused" {
  local next="$BATS_TEST_TMPDIR/new-app"
  git init -q "$next"
  git -C "$next" commit -q --allow-empty -m init
  cat >"$BATS_TEST_TMPDIR/bin/hc-reused" <<EOF
#!/usr/bin/env bash
printf '%s\\n' "\$*" >>"$BATS_TEST_TMPDIR/source-hc.log"
[[ "\$1 \$2" == 'get t9' ]] || exit 1
jq -nc --arg cwd "$next" '{address:"t9",state:"live",cwd:\$cwd,title:"Replacement desk",
  status:{state:"working",app:"pi"},labels:{"bercail.role":"agent","bercail.space":"new-space",
    "bercail.issue":"new-2","bercail.issue_title":"Replacement job","bercail.shep":"bg"}}'
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/hc-reused"
  { event done
    printf '{"method":"missed","params":{"terminals":[]}}\n'
    status_event working
    status_event blocked
  } | HC_BIN="$BATS_TEST_TMPDIR/bin/hc-reused" notify_follow
  [[ -f "$BATS_TEST_TMPDIR/source-hc.log" ]] || fail "reused address skipped hc lookup after empty snapshot"
  [[ "$(grep -c '^get t9 --json$' "$BATS_TEST_TMPDIR/source-hc.log")" -eq 1 ]] || fail "replacement mapping not looked up once"
  jq -e --arg p "$next" '.desks | length == 1 and (.[0] | .agent.address == "t9"
    and .agent.status == "blocked" and .agent.role == "shep-bg" and .space.id == "new-space"
    and .space.checkout_path == $p and .space.repo == "new-app" and .desk.issue == "new-2")' \
    "$(source_state)" >/dev/null || fail "reused address retained source mapping"
  jq -e --arg p "$next" '.kind == "blocked" and .space.id == "new-space" and .space.checkout_path == $p
    and .desk.issue == "new-2" and .desk.issue_title == "Replacement job" and .agent.title == "Replacement desk"' \
    "$(shep_state_dir)/inbox/"*.json >/dev/null || fail "reused address retained event mapping"
}

@test "source reconciliation creates no inbox before Shep first starts" {
  rm -rf "$(shep_state_dir)"
  event done | notify_follow
  [[ ! -e "$(shep_state_dir)" ]] || fail "source reconciliation started an unused Shep inbox"
}

inbox_count() {
  find "$(shep_state_dir)/inbox" -name '*.json' | wc -l
}

@test "a replayed finish does not replace the next turn's finish even with no new report" {
  # Same desk, issue and report throughout. Drain both turns in one second.
  _notify_now() { printf '1794886882'; }
  { event working
    status_event done t9 10
    status_event working t9 11
    status_event done t9 10
    status_event done t9 12
    status_event working t9 11
    status_event done t9 12
  } | notify_follow
  local ids
  ids="$(events | jq -c 'map([.kind, (.event_id | split(":")[2])])')"
  [[ "$ids" == '[["finished","1794886882.10"],["finished","1794886882.12"]]' ]] || fail "expected both real finishes, not their replays: $ids"
  [[ "$(inbox_count)" -eq 2 ]] || fail "Shep must get both turns even in one second"
}

@test "a labels lookup that already sees done never puts the source ahead of the queued events" {
  local labels='{"method":"event","params":{"terminal":"t9","type":"labels","data":{}}}'
  cat >"$BATS_TEST_TMPDIR/bin/hc-ahead" <<EOF
#!/usr/bin/env bash
[[ "\$1 \$2" == 'get t9' ]] || exit 1
jq -nc --arg cwd "$desk" '{address:"t9",state:"live",cwd:\$cwd,status:{state:"done",app:"pi"},
  labels:{"bercail.role":"agent","bercail.space":"sp1","bercail.issue":"myapp-1"}}'
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/hc-ahead"
  { event working; printf '%s\n' "$labels"; } | HC_BIN="$BATS_TEST_TMPDIR/bin/hc-ahead" notify_follow
  if jq -e '.desks[0].agent.status == "done"' "$(source_state)" >/dev/null && [[ "$(inbox_count)" -eq 0 ]]; then
    fail "the source says done with no finish queued, so Shep reads a gap notice, then the finish"
  fi
  rm -f "$(shep_state_dir)/inbox/"*.json
  { event working; printf '%s\n' "$labels"; status_event blocked; status_event done; } \
    | HC_BIN="$BATS_TEST_TMPDIR/bin/hc-ahead" notify_follow
  [[ "$(kinds)" == '["blocked","finished"]' ]] || fail "the queued statuses must be reported once, in order: $(kinds)"
  jq -e '.desks[0].agent.status == "done"' "$(source_state)" >/dev/null || fail "source not current"
}

@test "a desk seen done first is not reported; working->done, blocked once, blocked->done are" {
  local got
  follow_session
  got="$(kinds)"
  [[ "$got" == '["finished","blocked","finished"]' ]] || fail "kinds: $got"
}

@test "the event names the desk, its space and handoff" {
  local first
  follow_session
  first="$(events | jq -c '.[0]')"
  jq -e --arg p "$desk" '
    .schema == "bercail.agent_status/v2" and .sink == "shep"
    and .agent.address == "t9" and .agent.status == "done" and .agent.previous_status == "working"
    and .agent.app == "pi" and .agent.title == "Beads issue myapp-1"
    and .space.id == "sp1" and .space.repo == "myapp" and .space.checkout_path == $p and .space.linked == true
    and .desk.issue == "myapp-1" and .desk.issue_title == "Fix the login" and .desk.stage == "bstack" and .desk.branch == "feat"
    and .text == "myapp-1: Fix the login. Desk t9 finished."' <<<"$first" >/dev/null \
    || fail "payload: $first"
  events | jq -e '.[1].kind == "blocked" and .[1].text == "myapp-1: Fix the login. Desk t9 is blocked." and .[1].desk.issue_title == "Fix the login"' \
    >/dev/null || fail "blocked text: $(events | jq -c '.[1]')"
}

@test "an empty field keeps the others in place" {
  # An agent that reports no app: the empty field must not shift the others.
  { event working; event working | jq -c '.terminals[1].status = {state:"done"}'; } | notify_follow
  events | jq -e --arg p "$desk" '.[0] | .agent.app == null and .space.id == "sp1" and .space.checkout_path == $p' \
    >/dev/null || fail "empty app shifted fields: $(events)"
}

@test "heartbeats and other non-snapshot lines keep desk statuses; finished and blocked are queued" {
  local got
  { event working; heartbeat 3706; event done; } | notify_follow
  got="$(kinds)"
  [[ "$got" == '["finished"]' ]] || fail "heartbeat between working and done: $got"
  events | jq -e '.[0] | .sink == "shep" and .space.repo == "myapp" and .space.linked == true' \
    >/dev/null || fail "heartbeat finished event: $(events)"
  rm -f "$(shep_state_dir)/inbox/"*.json
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

@test "status events after the snapshot queue finished and blocked" {
  local got
  # (The 10:43 miss: the follower read the snapshot and nothing after it.)
  { event working; heartbeat 4054
    printf '{"jsonrpc":"2.0","method":"event","params":{"seq":4055,"terminal":"t9","type":"size","data":{"cols":200,"rows":120}}}\n'
    status_event working; status_event working; status_event done; status_event idle
    status_event working; status_event blocked; status_event working; status_event done; } | notify_follow
  got="$(kinds)"
  [[ "$got" == '["finished","blocked","finished"]' ]] || fail "event deltas: $got"
  events | jq -e --arg p "$desk" '.[0] | .agent.address == "t9" and .agent.status == "done"
    and .agent.previous_status == "working" and .space.id == "sp1" and .space.repo == "myapp"
    and .space.checkout_path == $p and .desk.issue == "myapp-1"' >/dev/null \
    || fail "event delta payload: $(events | jq -c '.[0]')"
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
  events | jq -e 'length == 1 and .[0].agent.address == "t12" and .[0].space.id == "sp2" and .[0].agent.title == "New desk"
    and .[0].agent.role == "shep-bg" and .[0].desk.issue == "bg-1" and .[0].desk.issue_title == "Wait for CI"
    and .[0].desk.stage == null' \
    >/dev/null || fail "new desk / finished desk: $(events)"
}

@test "with no window here, a desk's space is named from the Shell bercail made for it" {
  local got
  export HC_STATE="$BATS_TEST_TMPDIR/hc.json" HC_LOG="$BATS_TEST_TMPDIR/hc.log"
  printf '[{"address":"t3","cwd":"/w","parent":null,"state":"live","labels":{"herdr.space":"sp9","bercail.space_name":"Feat_Myapp"}}]' >"$HC_STATE"
  got="$(HC_BIN="$ROOT/tests/fixtures/hc-core" notify_space_info sp9 "")"
  jq -e '.id == "sp9" and .name == "Feat_Myapp"' <<<"$got" >/dev/null || fail "space info: $got"
  got="$(HC_BIN="$ROOT/tests/fixtures/hc-core" notify_space_info sp-other "")"
  jq -e '.id == "sp-other" and .name == null' <<<"$got" >/dev/null || fail "a space hc has no Shell for has no name: $got"
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
  payload_text() { notify_payload "$1" "$agent" "$2" "$3" e1 | jq -r .text; }
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

@test "update restarts the live follower" {
  local out
  hc_kill
  out="$(HC_BIN="$BATS_TEST_TMPDIR/bin/hc-kill" notify_restart_follower 2>&1)"
  [[ "$(cat "$BATS_TEST_TMPDIR/killed")" == bercail-notify ]] || fail "update did not restart the follower"
  [[ "$out" == "restarted the notify follower (hc terminal bercail-notify)" ]] || fail "restart output: $out"
}

@test "update says so when the follower outlives its kill" {
  local out
  cat >"$BATS_TEST_TMPDIR/bin/hc" <<'EOF'
#!/usr/bin/env bash
printf '{"state":"live"}\n'
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/hc"
  out="$(HC_BIN="$BATS_TEST_TMPDIR/bin/hc" notify_restart_follower 2>&1)" || fail "a failed restart must not fail update"
  [[ "$out" == 'could not restart the notify follower; run: hc kill bercail-notify' ]] || fail "failed kill: $out"
}

# A curl that logs any call: nothing may post anywhere.
curl_logs() {
  cat >"$BATS_TEST_TMPDIR/bin/curl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$BATS_TEST_TMPDIR/curl.log"
printf 200
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/curl"
}

# A fake hc whose event stream is one desk going from working to done.
desk_finishes() {
  { event working; status_event done; } >"$BATS_TEST_TMPDIR/stream.jsonl"
  cat >"$BATS_TEST_TMPDIR/bin/hc" <<EOF
#!/usr/bin/env bash
[[ "\$1" == events ]] || exit 1
cat "$BATS_TEST_TMPDIR/stream.jsonl"
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/hc"
}

@test "bercail notify run puts a finished desk in Shep's inbox and posts nothing to a leftover sink" {
  local out
  desk_finishes
  curl_logs
  # A sink file from before v0.18: bercail no longer reads it.
  mkdir -p "$XDG_CONFIG_HOME/bercail/notify.d"
  printf 'url = "https://example.invalid/hook"\nkey = "old-key"\n' >"$XDG_CONFIG_HOME/bercail/notify.d/old.toml"
  chmod 600 "$XDG_CONFIG_HOME/bercail/notify.d/old.toml"
  out="$(PATH="$BATS_TEST_TMPDIR/bin:$PATH" HC_BIN="$BATS_TEST_TMPDIR/bin/hc" NOTIFY_CURL="$BATS_TEST_TMPDIR/bin/curl" \
    "$ROOT/bin/bercail" notify run 2>&1)" || fail "notify run: $out"
  events | jq -e --arg p "$desk" 'length == 1 and (.[0] | .kind == "finished" and .sink == "shep"
    and .agent.address == "t9" and .space.checkout_path == $p and .desk.issue == "myapp-1"
    and .text == "myapp-1: Fix the login. Desk t9 finished.")' >/dev/null || fail "Shep's inbox: $(events)"
  [[ ! -e "$BATS_TEST_TMPDIR/curl.log" ]] || fail "the follower posted to a sink: $(cat "$BATS_TEST_TMPDIR/curl.log")"
}

@test "the sink commands are gone: notify add, status, test, repo and check fail and write nothing" {
  local cmd out
  curl_logs
  for cmd in "" status "add bot" "test bot" "repo add bot myapp" check; do
    # shellcheck disable=SC2086 # each cmd is its words
    if out="$(cd "$desk" && printf 'https://example.invalid/new\nkey\n' \
      | PATH="$BATS_TEST_TMPDIR/bin:$PATH" NOTIFY_CURL="$BATS_TEST_TMPDIR/bin/curl" "$ROOT/bin/bercail" notify $cmd 2>&1)"; then
      fail "bercail notify $cmd still runs: $out"
    fi
    [[ "$out" == *"only run is left"* ]] || fail "bercail notify $cmd: $out"
  done
  [[ ! -e "$XDG_CONFIG_HOME/bercail/notify.d" ]] || fail "a sink was written: $(ls -A "$XDG_CONFIG_HOME/bercail/notify.d")"
  [[ ! -e "$BATS_TEST_TMPDIR/curl.log" ]] || fail "something posted: $(cat "$BATS_TEST_TMPDIR/curl.log")"
}
