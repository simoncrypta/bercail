#!/usr/bin/env bats

setup() {
  load test_helper
  isolate
  need node
  unset HC_BIN HANDOFF_BD_BIN BD_BIN BERCAIL_TASK_RESERVED BERCAIL_ROLE BERCAIL_HANDOFF_SPAWN
  export PATH="$BATS_TEST_TMPDIR/bin:/usr/bin:/bin"
  export ROOT LOG="$BATS_TEST_TMPDIR/calls" TASK_DATA="$BATS_TEST_TMPDIR/issues"
  mkdir -p "$TASK_DATA" "$XDG_STATE_HOME/bercail/desk-sessions"
  git_init "$BATS_TEST_TMPDIR/repo"
  REPO="$BATS_TEST_TMPDIR/repo"
  printf '.bercail/\n' >>"$REPO/.git/info/exclude"
  git -C "$REPO" remote add origin https://github.com/o/app.git
  git -C "$REPO" worktree add -qb fix "$REPO.fix"
  jq -n '{id:"app-1",title:"Repair login",status:"closed",metadata:{}}' >"$TASK_DATA/app-1.json"
  cat >"$BATS_TEST_TMPDIR/bin/bd" <<'EOF'
#!/usr/bin/env bash
printf 'bd %s\n' "$*" >>"$LOG"
case "$1" in
  show) cat "$TASK_DATA/$2.json" ;;
  list) jq -s . "$TASK_DATA/"*.json ;;
  update)
    id="$2"; shift 2
    while (($#)); do
      case "$1" in
        --metadata)
          if [[ ${TASK_CONCURRENT_METADATA:-} == 1 ]]; then
            jq '.metadata.external="newer unrelated value"' "$TASK_DATA/$id.json" >"$TASK_DATA/tmp"
            mv "$TASK_DATA/tmp" "$TASK_DATA/$id.json"
          fi
          jq --slurpfile m "${2#@}" '.metadata = ((.metadata // {}) + $m[0])' "$TASK_DATA/$id.json" >"$TASK_DATA/tmp"; shift 2 ;;
        --status) jq --arg s "$2" '.status = $s' "$TASK_DATA/$id.json" >"$TASK_DATA/tmp"; shift 2 ;;
        --json) shift; continue ;;
        *) exit 2 ;;
      esac
      mv "$TASK_DATA/tmp" "$TASK_DATA/$id.json"
    done
    cat "$TASK_DATA/$id.json" ;;
  *) exit 2 ;;
esac
EOF
  cat >"$BATS_TEST_TMPDIR/bin/hc" <<'EOF'
#!/usr/bin/env bash
printf 'hc %s\n' "$*" >>"$LOG"
case "$1" in
 ls) shopt -s nullglob; files=("$TASK_DATA/"t*.hc)
     if ((${#files[@]})); then jq -s '{terminals:.}' "${files[@]}"; else echo '{"terminals":[]}'; fi ;;
 get) cat "$TASK_DATA/$2.hc" ;;
 *) exit 8 ;;
esac
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/"{hc,bd}
  # An OS-level Pi stand-in, never the installed Pi or a live Herdr desk.
  cp "$BASH" "$BATS_TEST_TMPDIR/bin/pi"
  mkfifo "$BATS_TEST_TMPDIR/pi.hold"
  start_pi PID
  TICKS="$(awk '{print $22}' "/proc/$PID/stat")"
  owner t9 s1
  jq -nc --arg p "$REPO.fix" '{path:$p,branch:"fix",issue:"app-1",space:"sp1",desk:"t9",target:"pr:12"}' >"$XDG_STATE_HOME/bercail/handoffs.jsonl"
}

teardown() {
  local pid
  for pid in "${PID:-}" "${OTHER_PID:-}"; do
    [[ -n "$pid" ]] || continue
    kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
  done
}

# Starts the Pi stand-in in the worktree, waits until /proc names it pi, and
# sets the variable named $1 to its pid. It is bash blocked in a builtin read,
# not a renamed sleep: a multicall coreutils (uutils, on Ubuntu 26.04) picks
# its applet from argv[0], so a copy named pi exits at once.
start_pi() {
  local pid n
  (cd "$REPO.fix" && exec "$BATS_TEST_TMPDIR/bin/pi" -c 'read -rt 120 <>"$0"' "$BATS_TEST_TMPDIR/pi.hold") >/dev/null 2>&1 &
  pid=$!
  for ((n=0; n<200; n++)); do
    [[ "$(basename "$(readlink "/proc/$pid/exe")")" == pi ]] && break
    sleep 0.01
  done
  [[ "$n" -lt 200 ]] || fail "fake Pi did not exec"
  printf -v "$1" %s "$pid"
}

owner() {
  local id="$1" session="$2" file="$TASK_DATA/$2.jsonl"
  jq -nc --arg s "$session" --arg cwd "$REPO.fix" '{type:"session",version:3,id:$s,cwd:$cwd}' >"$file"
  echo '{"type":"custom","id":"anchor","parentId":null,"customType":"fixture"}' >>"$file"
  mkdir -p "$XDG_STATE_HOME/bercail/runtime"
  jq -n --arg s "$session" --arg f "$file" --arg ticks "$TICKS" --argjson pid "$PID" '{pid:$pid,start_ticks:$ticks,session:$s,session_file:$f,leaf:"anchor",generation:"fixture",guard_generation:"UNKNOWN"}' >"$XDG_STATE_HOME/bercail/runtime/$PID.json"
  mkdir -p "$XDG_RUNTIME_DIR/bercail/open-sessions"
  jq -n --arg s "$session" --arg ticks "$TICKS" --argjson pid "$PID" '{pid:$pid,start_ticks:$ticks,sessions:[$s]}' >"$XDG_RUNTIME_DIR/bercail/open-sessions/$PID.json"
  jq -n --arg id "$id" --arg cwd "$REPO.fix" --argjson pid "$PID" '{address:$id,cwd:$cwd,state:"live",foreground:{pid:$pid},labels:{"bercail.role":"agent","bercail.issue":"app-1","bercail.space":"sp1"},status:{state:"working"}}' >"$TASK_DATA/$id.hc"
  jq -n --arg id "$id" --arg cwd "$REPO.fix" --arg s "$session" --arg f "$file" --arg ticks "$TICKS" --argjson pid "$PID" '{address:$id,cwd:$cwd,session:$s,session_file:$f,space:"sp1",issue:"app-1",harness:"pi",pid:$pid,start_ticks:$ticks,follow_up:1}' >"$XDG_STATE_HOME/bercail/desk-sessions/$id.json"
}

request() {
  jq -nc --arg repo "$REPO" --arg id "${1:-r1}" '{repo:$repo,issue:"app-1",target:"https://github.com/o/app/pull/12/",requestId:$id,outcome:"publish",stage:"autopilot",message:"Amend with gt m -a and publish the new head",authoring:"gt m -a"}'
}

task() { "$ROOT/bin/bercail" shep task "$@"; }

@test "follow-ups reuse the original visible owner and reopen a closed task without authority" {
  local out
  out="$(request | task dispatch)" || fail "$out"
  jq -e '.owner.desk == "t9" and .owner.session == "s1" and .status == "queued" and .authority == false' <<<"$out"
  request | task dispatch >/dev/null
  request r2 | task dispatch >/dev/null
  [[ "$(find "$XDG_STATE_HOME/bercail/desk-follow-ups" -name '*.json' | wc -l)" == 2 ]]
  jq -e '.status == "in_progress" and .metadata.bercail_task.requests[0].authoring == "gt m -a" and .metadata.bercail_task.requests[0].outcome == "publish"' "$TASK_DATA/app-1.json"
  ! grep -Eq 'hc (run|send|keys|kill|rm)' "$LOG"
}

@test "a different branch cannot silently replace an existing task owner" {
  local out
  out="$(request | jq '.branch="another-prep"' | task dispatch 2>&1)" && fail "$out"
  [[ "$out" == *"branch"* && "$out" == *"original"* ]]
  ! grep -Eq 'hc (run|send|keys|kill|rm)' "$LOG"
}

@test "stale, missing and ambiguous owners stop rather than spawn" {
  local out
  owner t8 s2
  out="$(request | task dispatch 2>&1)" && fail "$out"
  [[ "$out" == *"ambiguous"* ]]
  rm "$TASK_DATA/t8.hc" "$XDG_STATE_HOME/bercail/desk-sessions/t8.json"
  jq '.start_ticks="stale"' "$XDG_STATE_HOME/bercail/desk-sessions/t9.json" >"$BATS_TEST_TMPDIR/r"
  mv "$BATS_TEST_TMPDIR/r" "$XDG_STATE_HOME/bercail/desk-sessions/t9.json"
  out="$(request | task dispatch 2>&1)" && fail "$out"
  [[ "$out" == *"stale"* ]]
  rm "$XDG_STATE_HOME/bercail/desk-sessions/t9.json"
  out="$(request | task dispatch 2>&1)" && fail "$out"
  [[ "$out" == *"record"* ]]
  ! grep -Eq 'hc (run|send|keys|kill|rm)' "$LOG"
}

@test "a changed session cannot inherit an accepted request or its intent" {
  local out
  request | task dispatch >/dev/null
  owner t9 replacement
  out="$(request r2 | task dispatch 2>&1)" && fail "$out"
  [[ "$out" == *"session"* ]]
  jq -e '.metadata.bercail_task.owner.session == "s1" and (.metadata.bercail_task.requests | length) == 1' "$TASK_DATA/app-1.json"
}

@test "a backend blocker preserves the requested authoring and publication outcome" {
  local out
  request | task dispatch >/dev/null
  request | jq '. + {reason:"gt modify restacks a child; native executor unsupported",next:"Resolve descendant scope in the original desk"}' | task block >/dev/null
  out="$(request | task status)"
  jq -e '.requests[0].status == "blocked" and .requests[0].authoring == "gt m -a" and .requests[0].outcome == "publish" and (.requests[0].reason | contains("restacks"))' <<<"$out"
}

@test "repo path aliases deduplicate; issue aliases and a foreign PR URL cannot take a target" {
  local out
  ln -s "$REPO" "$BATS_TEST_TMPDIR/alias"
  request | task dispatch >/dev/null
  request | jq --arg repo "$BATS_TEST_TMPDIR/alias" '.repo=$repo' | task dispatch >/dev/null
  jq -n '{id:"app-2",title:"Alias",metadata:{}}' >"$TASK_DATA/app-2.json"
  out="$(request r2 | jq '.issue="app-2" | .target="pr:12"' | task dispatch 2>&1)" && fail "$out"
  [[ "$out" == *"already owned by app-1"* ]]
  out="$(request r2 | jq '.target="https://github.com/other/repo/pull/12"' | task dispatch 2>&1)" && fail "$out"
  [[ "$out" == *"another repository"* ]]
  [[ "$(find "$XDG_STATE_HOME/bercail/desk-follow-ups" -name '*.json' | wc -l)" == 1 ]]
}

@test "a retry repairs only an absent queue file; a claimed send is never replayed" {
  local file out
  request | task dispatch >/dev/null
  file="$(find "$XDG_STATE_HOME/bercail/desk-follow-ups" -name '*.json')"
  rm "$file"
  request | task dispatch >/dev/null
  [[ -f "$file" ]]
  jq '.delivery="unknown"' "$file" >"$BATS_TEST_TMPDIR/msg"
  mv "$BATS_TEST_TMPDIR/msg" "$file"
  request | task dispatch >/dev/null
  jq -e '.delivery == "unknown"' "$file"
  out="$(request | jq '.message="different effect"' | task dispatch 2>&1)" && fail "$out"
  [[ "$out" == *"payload changed"* ]]
}

# The only fake launch effect here is a log line; no real Herdr process runs.
partial_launch() {
  rm "$TASK_DATA/"*.hc "$XDG_STATE_HOME/bercail/handoffs.jsonl"
  export BERCAIL_HANDOFF_SPAWN="$BATS_TEST_TMPDIR/bin/spawn"
  cat >"$BERCAIL_HANDOFF_SPAWN" <<'EOF'
#!/usr/bin/env bash
printf 'spawn %s\n' "$*" >>"$LOG"
printf '{"ok":true,"agent_started":false,"path":"%s.partial","space":"sp-new","branch":"fresh"}\n' "$PWD"
EOF
  chmod +x "$BERCAIL_HANDOFF_SPAWN"
}

@test "partial initial creation reserves the job; retry reports UNKNOWN instead of launching again" {
  local out
  partial_launch
  out="$(request | jq '.branch="fresh"' | task dispatch 2>&1)" && fail "$out"
  [[ "$out" == *"partial visible creation"* ]]
  out="$(request | jq '.branch="fresh"' | task dispatch)" || fail "$out"
  jq -e '.status == "unknown" and .authority == false and .retry' <<<"$out"
  [[ "$(grep -c '^spawn ' "$LOG")" == 1 ]]
  jq -e '.status == "in_progress" and .metadata.bercail_task.requests[0].outcome == "publish"' "$TASK_DATA/app-1.json"
  out="$(request r2 | jq '.branch="fresh"' | task dispatch 2>&1)" && fail "$out"
  [[ "$out" == *"UNKNOWN"* ]]
}

@test "repo serialization covers concurrent issue aliases, not just the same issue" {
  local a b
  partial_launch
  jq -n '{id:"app-2",title:"Alias",metadata:{}}' >"$TASK_DATA/app-2.json"
  request | jq '.branch="fresh"' | task dispatch >"$BATS_TEST_TMPDIR/a" 2>&1 & a=$!
  request r2 | jq '.issue="app-2" | .branch="other"' | task dispatch >"$BATS_TEST_TMPDIR/b" 2>&1 & b=$!
  wait "$a" || true
  wait "$b" || true
  [[ "$(grep -c '^spawn ' "$LOG")" == 1 ]]
  jq -se '[.[].metadata.bercail_task.requests[]?] | length == 1' "$TASK_DATA/app-"*.json
}

@test "same issue id in another repo does not inherit this repo's owner or outcome" {
  local other="$BATS_TEST_TMPDIR/other" data="$BATS_TEST_TMPDIR/other-issues" out
  request | task dispatch >/dev/null
  git_init "$other"
  git -C "$other" remote add origin https://github.com/o/app.git
  mkdir -p "$data"
  jq -n '{id:"app-1",title:"Unrelated",metadata:{}}' >"$data/app-1.json"
  export BERCAIL_HANDOFF_SPAWN="$BATS_TEST_TMPDIR/bin/spawn"
  printf '#!/bin/sh\necho "{\"ok\":false,\"agent_started\":false}"\n' >"$BERCAIL_HANDOFF_SPAWN"
  chmod +x "$BERCAIL_HANDOFF_SPAWN"
  out="$(request | jq --arg repo "$other" '.repo=$repo | .branch="other"' | TASK_DATA="$data" task dispatch 2>&1)" && fail "$out"
  jq -e --arg repo "$other" '.metadata.bercail_task.repo == $repo and .metadata.bercail_task.owner == null' "$data/app-1.json"
  jq -e --arg repo "$REPO" '.metadata.bercail_task.repo == $repo and .metadata.bercail_task.owner.desk == "t9"' "$TASK_DATA/app-1.json"
}

# Persist the event shapes produced by the extension. Separate from dispatch:
# an accepted/queued request cannot supply its own execution evidence.
executed() {
  local command="${1:-isolated tests}" close="${2:-}" head tree leaf id
  head="$(git -C "$REPO.fix" rev-parse HEAD)"; tree="$(git -C "$REPO.fix" write-tree)"
  leaf="$(tail -1 "$TASK_DATA/s1.jsonl" | jq -r .id)"; id="$(wc -l <"$TASK_DATA/s1.jsonl")"
  if ! grep -q 'bercail-task-work' "$TASK_DATA/s1.jsonl"; then
    jq -nc --arg repo "$REPO" --arg p "$leaf" '{type:"custom_message",id:"work",parentId:$p,customType:"bercail-task-work",details:{repo:$repo,issue:"app-1",requestId:"r1",authority:false}}' >>"$TASK_DATA/s1.jsonl"
    leaf=work
  fi
  jq -nc --arg repo "$REPO" --arg p "$leaf" --arg id "effect$id" --arg call "call$id" --arg head "$head" --arg tree "$tree" --arg cmd "$command" --arg close "$close" \
    '{type:"custom",id:$id,parentId:$p,customType:"bercail-task-effect",data:{repo:$repo,issue:"app-1",requestId:"r1",authority:false,session:"s1",toolCallId:$call,command:$cmd,exit_code:0,before:{head:$head,tree:$tree},after:{head:$head,tree:$tree}}} | if $close == "" then . else .data += {close:$close,open_before:[{id:$close,generation:"g1"}],open_after:[]} end' >>"$TASK_DATA/s1.jsonl"
  jq -nc --arg id "result$id" --arg p "effect$id" --arg call "call$id" '{type:"message",id:$id,parentId:$p,message:{role:"toolResult",toolCallId:$call,isError:false,structuredContent:{exit_code:0}}}' >>"$TASK_DATA/s1.jsonl"
  jq --arg leaf "result$id" '.leaf=$leaf' "$XDG_STATE_HOME/bercail/runtime/$PID.json" >"$BATS_TEST_TMPDIR/leaf"
  mv "$BATS_TEST_TMPDIR/leaf" "$XDG_STATE_HOME/bercail/runtime/$PID.json"
  if [[ "$command" == "isolated tests" ]]; then
    mkdir -p "$REPO.fix/.bercail"
    jq -n --arg tree "$tree" '{tree:$tree,checks:[{kind:"test",command:"isolated tests",exit_code:0,evidence:"fixture"}]}' >"$REPO.fix/.bercail/validate.json"
  fi
}

proof() {
  jq -nc --arg repo "$REPO" --arg head "$(git -C "$REPO.fix" rev-parse HEAD)" --arg tree "$(git -C "$REPO.fix" write-tree)" \
    '{repo:$repo,issue:"app-1",requestId:"r1",desk:"t9",session:"s1",proof:{head:$head,tree:$tree,validation:{head:$head,tree:$tree,command:"isolated tests",exit_code:0}}}'
}

@test "old reports and a claimed native authoring result cannot complete an amend/publish follow-up" {
  local out
  request | task dispatch >/dev/null
  echo amended >>"$REPO.fix/file.txt"
  git -C "$REPO.fix" commit -qam "changed without the requested native amendment"
  executed
  out="$(proof | task receipt 2>&1)" && fail "$out"
  [[ "$out" == *"native authoring receipt unavailable for gt m -a"* ]]
  out="$(proof | jq '.proof.tree="old-tree"' | task receipt 2>&1)" && fail "$out"
  [[ "$out" == *"fresh validation"* ]]
  jq -e '.metadata.bercail_task.requests[0].status != "complete"' "$TASK_DATA/app-1.json"
}

@test "publication completes only for the current remote head and that head's CI, never old green" {
  local out old head remote="$BATS_TEST_TMPDIR/remote.git"
  git init --bare -q "$remote"
  git -C "$REPO" remote set-url origin "$remote"
  git -C "$REPO.fix" push -q origin fix
  old="$(git -C "$REPO.fix" rev-parse HEAD)"
  export BERCAIL_SHEP_BIN="$BATS_TEST_TMPDIR/bin/description" TASK_CI="$BATS_TEST_TMPDIR/ci"
  printf '#!/bin/sh\nexit 0\n' >"$BERCAIL_SHEP_BIN"
  printf '#!/bin/sh\ncat "$TASK_CI"\n' >"$BATS_TEST_TMPDIR/bin/gh"
  chmod +x "$BERCAIL_SHEP_BIN" "$BATS_TEST_TMPDIR/bin/gh"
  jq -n --arg h "$old" '{headRefOid:$h,headRefName:"fix",statusCheckRollup:[{conclusion:"SUCCESS"}]}' >"$TASK_CI"
  request | jq '.target="pr:12" | .authoring=""' | task dispatch >/dev/null
  executed
  out="$(proof | task receipt 2>&1)" && fail "$out"
  [[ "$out" == *"unchanged old published/green head"* ]]
  echo new >>"$REPO.fix/file.txt"
  git -C "$REPO.fix" commit -qam "amend requested work"
  head="$(git -C "$REPO.fix" rev-parse HEAD)"
  executed
  out="$(proof | task receipt 2>&1)" && fail "$out"
  [[ "$out" == *"not published"* ]]
  git -C "$REPO.fix" push -q origin fix
  out="$(proof | task receipt 2>&1)" && fail "$out"
  [[ "$out" == *"new-head CI"* ]]
  jq -n --arg h "$head" '{headRefOid:$h,headRefName:"fix",statusCheckRollup:[{conclusion:"SUCCESS"}]}' >"$TASK_CI"
  out="$(proof | task receipt)" || fail "$out"
  jq -e '.outstanding == 0 and .requests[0].status == "complete" and .authority == false' <<<"$out"
  request r2 | jq '.target="pr:12" | .authoring=""' | task dispatch >/dev/null
  out="$(proof | jq '.requestId="r2"' | task receipt 2>&1)" && fail "$out"
  [[ "$out" == *"no complete matching persisted work message"* ]]
  out="$(request | task status)"
  jq -e '.requests[1].status == "queued" and (.requests | length) == 2' <<<"$out"
}

@test "publication can complete an already authored but previously unpublished head" {
  local old head out remote="$BATS_TEST_TMPDIR/remote.git"
  git init --bare -q "$remote"
  git -C "$REPO" remote set-url origin "$remote"
  git -C "$REPO.fix" push -q origin fix
  old="$(git -C "$REPO.fix" rev-parse HEAD)"
  echo new >>"$REPO.fix/file.txt"
  git -C "$REPO.fix" commit -qam 'authored before publication request'
  head="$(git -C "$REPO.fix" rev-parse HEAD)"
  export BERCAIL_SHEP_BIN="$BATS_TEST_TMPDIR/bin/description" TASK_CI="$BATS_TEST_TMPDIR/ci"
  printf '#!/bin/sh\nexit 0\n' >"$BERCAIL_SHEP_BIN"
  printf '#!/bin/sh\ncat "$TASK_CI"\n' >"$BATS_TEST_TMPDIR/bin/gh"
  chmod +x "$BERCAIL_SHEP_BIN" "$BATS_TEST_TMPDIR/bin/gh"
  jq -n --arg h "$old" '{headRefOid:$h,headRefName:"fix",statusCheckRollup:[{conclusion:"SUCCESS"}]}' >"$TASK_CI"
  request | jq '.target="pr:12" | .authoring=""' | task dispatch >/dev/null
  git -C "$REPO.fix" push -q origin fix
  jq -n --arg h "$head" '{headRefOid:$h,headRefName:"fix",statusCheckRollup:[{conclusion:"SUCCESS"}]}' >"$TASK_CI"
  executed
  out="$(proof | task receipt)" || fail "$out"
  jq -e --arg h "$head" '.outstanding == 0 and .requests[0].receipt.head == $h' <<<"$out"
  proof | jq '.proof={}' | task receipt | jq -e --arg h "$head" '.retry and .requests[0].receipt.head == $h'
  proof | jq '.reason="supplemental readback failed" | .next="try again" | del(.proof,.desk,.session)' | task block | jq -e '.retry and .outstanding == 0'
}

@test "task namespace merge keeps an unrelated metadata edit during the update" {
  export TASK_CONCURRENT_METADATA=1
  jq '.metadata.external="old external marker"' "$TASK_DATA/app-1.json" >"$TASK_DATA/tmp"
  mv "$TASK_DATA/tmp" "$TASK_DATA/app-1.json"
  request | task dispatch >/dev/null
  jq -e '.metadata.external == "newer unrelated value" and .metadata.bercail_task.requests[0].id == "r1"' "$TASK_DATA/app-1.json"
}

@test "cleanup audit is not completion; OPEN survivors and partial custody stay explicit" {
  local out
  export HERDR_APP_BIN="$BATS_TEST_TMPDIR/bin/native" TASK_OPEN="$BATS_TEST_TMPDIR/open"
  printf '#!/bin/sh\ncat "$TASK_OPEN"\n' >"$HERDR_APP_BIN"
  chmod +x "$HERDR_APP_BIN"
  echo '{"spaces":[{"id":"sp-old", "generation":"g1"}]}' >"$TASK_OPEN"
  out="$(request | jq '.outcome="cleanup" | .authoring="" | .targets=[{space:"invented",generation:"g1"}]' | task dispatch 2>&1)" && fail "$out"
  [[ "$out" == *"not in the observed native OPEN snapshot"* ]]
  request | jq '.outcome="cleanup" | .authoring="" | .targets=[{space:"sp-old",generation:"g1"}]' | task dispatch >/dev/null
  out="$(request | jq '.outcome="cleanup" | .authoring="" | .targets=[{space:"different",generation:"g1"}]' | task dispatch 2>&1)" && fail "$out"
  [[ "$out" == *"payload changed"* ]]
  executed
  out="$(proof | jq '.proof.results=[]' | task receipt 2>&1)" && fail "$out"
  [[ "$out" == *"per-target"* ]]
  out="$(proof | jq '.proof.results=[{space:"sp-old",generation:"g1",status:"KEEP",custody:"invented retention"}]' | task receipt 2>&1)" && fail "$out"
  [[ "$out" == *"cannot silently weaken"* ]]
  out="$(proof | jq '.proof.results=[{space:"sp-old",generation:"g1",status:"CLOSED",custody:"app-1: Repair login, r1"}]' | task receipt 2>&1)" && fail "$out"
  [[ "$out" == *"still OPEN"* ]]
  proof | jq '.proof.results=[{space:"sp-old",generation:"g1",status:"PARTIAL",custody:"app-1: Repair login, r1"}]' | task receipt | jq -e '.requests[0].status == "partial"'
  echo '{"spaces":[{"id":"sp-active"}]}' >"$TASK_OPEN"
  out="$(proof | jq '.proof.results=[{space:"sp-old",generation:"g1",status:"CLOSED",custody:"app-1: Repair login, r1"}]' | task receipt 2>&1)" && fail "$out"
  [[ "$out" == *"missing observed native closure receipt"* ]]
  executed "herdr-app do space.close --id sp-old --confirmed true" sp-old
  out="$(proof | jq '.proof.results=[{space:"sp-old",generation:"g1",status:"CLOSED",custody:"app-1: Repair login, r1"}]' | task receipt)" || fail "$out"
  jq -e '.outstanding == 0 and .requests[0].receipt.open == ["sp-active"] and (.requests[0].receipt.history | contains("not global closure gates"))' <<<"$out"
}

@test "initial adoption rejects conflicting original mapping and unrelated foreground or session claim" {
  local out record="$XDG_STATE_HOME/bercail/handoffs.jsonl"
  jq -c '.space="different"' "$record" >"$BATS_TEST_TMPDIR/r"
  mv "$BATS_TEST_TMPDIR/r" "$record"
  out="$(request | task dispatch 2>&1)" && fail "$out"
  [[ "$out" == *"mapping conflicts"* ]]
  jq -c '.space="sp1"' "$record" >"$BATS_TEST_TMPDIR/r"; mv "$BATS_TEST_TMPDIR/r" "$record"
  jq '.foreground={}' "$TASK_DATA/t9.hc" >"$BATS_TEST_TMPDIR/r"; mv "$BATS_TEST_TMPDIR/r" "$TASK_DATA/t9.hc"
  out="$(request | task dispatch 2>&1)" && fail "$out"
  [[ "$out" == *"foreground"* ]]
  owner t9 s1
  rm "$XDG_RUNTIME_DIR/bercail/open-sessions/$PID.json"
  out="$(request | task dispatch 2>&1)" && fail "$out"
  [[ "$out" == *"open-sessions"* ]]
  ! grep -Eq 'hc (run|send|keys|kill|rm)' "$LOG"
}

@test "legacy PR branch ownership is resolved before another issue can prepare a duplicate" {
  local out
  jq -n '{id:"app-2",title:"Alias",metadata:{}}' >"$TASK_DATA/app-2.json"
  jq -c 'del(.target)' "$XDG_STATE_HOME/bercail/handoffs.jsonl" >"$BATS_TEST_TMPDIR/r"
  mv "$BATS_TEST_TMPDIR/r" "$XDG_STATE_HOME/bercail/handoffs.jsonl"
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'EOF'
#!/bin/sh
printf '%s\n' '{"headRefName":"fix","isCrossRepository":false}'
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  out="$(request | jq '.issue="app-2" | .branch="another-prep"' | task dispatch 2>&1)" && fail "$out"
  [[ "$out" == *"already owned by app-1"* ]]
  ! grep -Eq 'hc (run|send|keys|kill|rm)' "$LOG"
}

@test "successful initial tuple binds its original startup on retry without a second launch" {
  local out
  cp "$TASK_DATA/t9.hc" "$BATS_TEST_TMPDIR/original.hc"
  partial_launch
  export TASK_ORIGINAL="$BATS_TEST_TMPDIR/original.hc" TASK_REPO="$REPO"
  cat >"$BERCAIL_HANDOFF_SPAWN" <<'EOF'
#!/usr/bin/env bash
printf 'spawn %s\n' "$*" >>"$LOG"
cp "$TASK_ORIGINAL" "$TASK_DATA/t9.hc"
jq '.metadata.external="keep this concurrent annotation"' "$TASK_DATA/app-1.json" >"$TASK_DATA/other"
mv "$TASK_DATA/other" "$TASK_DATA/app-1.json"
jq -nc --arg p "$TASK_REPO.fix" '{ok:true,agent_started:true,path:$p,branch:"fix",space:"sp1",desk:"t9",session:"s1",issue:"app-1",target:"pr:12"}' >"$XDG_STATE_HOME/bercail/handoffs.jsonl"
cat "$XDG_STATE_HOME/bercail/handoffs.jsonl"
EOF
  out="$(request | jq '.branch="fix"' | task dispatch)" || fail "$out"
  jq -e '.status == "awaiting-session" and .creation.desk == "t9"' <<<"$out"
  jq -e '.metadata.external == "keep this concurrent annotation"' "$TASK_DATA/app-1.json"
  out="$(request | jq '.branch="fix"' | task dispatch)" || fail "$out"
  jq -e '.status == "queued" and .owner.session == "s1"' <<<"$out"
  request | jq '.branch="fix"' | task dispatch >/dev/null
  [[ "$(grep -c '^spawn ' "$LOG")" == 1 ]]
  [[ "$(find "$XDG_STATE_HOME/bercail/desk-follow-ups" -name '*.json' | wc -l)" == 1 ]]
}

@test "abandoned JSONL tail is not the original runtime's active branch" {
  local out bytes
  request | jq '.outcome="stage" | .authoring=""' | task dispatch >/dev/null
  executed
  bytes="$(sha256sum "$TASK_DATA/s1.jsonl")"
  jq '.leaf="anchor"' "$XDG_STATE_HOME/bercail/runtime/$PID.json" >"$BATS_TEST_TMPDIR/leaf"
  mv "$BATS_TEST_TMPDIR/leaf" "$XDG_STATE_HOME/bercail/runtime/$PID.json"
  [[ "$(sha256sum "$TASK_DATA/s1.jsonl")" == "$bytes" ]]
  out="$(proof | task receipt 2>&1)" && fail "$out"
  [[ "$out" == *"no complete matching persisted work message"* ]]
}

@test "a competing exact-session process is ambiguous even without a coding role label" {
  local out ticks
  start_pi OTHER_PID
  ticks="$(awk '{print $22}' "/proc/$OTHER_PID/stat")"
  jq -n --argjson pid "$OTHER_PID" --arg ticks "$ticks" '{pid:$pid,start_ticks:$ticks,sessions:["s1"]}' >"$XDG_RUNTIME_DIR/bercail/open-sessions/$OTHER_PID.json"
  out="$(request | task dispatch 2>&1)" && fail "$out"
  [[ "$out" == *"exact-session process claims"* ]]
  ! grep -Eq 'hc (run|send|keys|kill|rm)' "$LOG"
}

@test "terminal cleanup can reconcile its original owner's durable receipt after native closure ended Pi" {
  local out
  export HERDR_APP_BIN="$BATS_TEST_TMPDIR/bin/native" TASK_OPEN="$BATS_TEST_TMPDIR/open"
  printf '#!/bin/sh\ncat "$TASK_OPEN"\n' >"$HERDR_APP_BIN"; chmod +x "$HERDR_APP_BIN"
  echo '{"spaces":[{"id":"sp1","generation":"g1"}]}' >"$TASK_OPEN"
  request | jq '.outcome="cleanup" | .authoring="" | .targets=[{space:"sp1",generation:"g1"}]' | task dispatch >/dev/null
  executed
  executed "herdr-app do space.close --id sp1 --confirmed true" sp1
  echo '{"spaces":[]}' >"$TASK_OPEN"
  kill "$PID"; wait "$PID" 2>/dev/null || true
  out="$(proof | jq '.proof.results=[{space:"sp1",generation:"g1",status:"CLOSED",custody:"app-1: Repair login, r1"}]' | task receipt)" || fail "$out"
  jq -e '.outstanding == 0 and .owner.session == "s1" and .authority == false' <<<"$out"
}

# The original desk t9 is gone. A stand-in spawn starts t10 in the same checkout
# with a new session, s2, and logs that adoption the way handoff-spawn does.
orphan() {
  rm "$TASK_DATA/t9.hc"
  owner t10 s2
  mv "$TASK_DATA/t10.hc" "$BATS_TEST_TMPDIR/t10.hc"
  export BERCAIL_HANDOFF_SPAWN="$BATS_TEST_TMPDIR/bin/spawn" TASK_NEW="$BATS_TEST_TMPDIR/t10.hc" TASK_REPO="$REPO"
  cat >"$BERCAIL_HANDOFF_SPAWN" <<'SPAWN'
#!/usr/bin/env bash
printf 'spawn %s\n' "$*" >>"$LOG"
cp "$TASK_NEW" "$TASK_DATA/t10.hc"
jq -nc --arg p "$TASK_REPO.fix" --arg r "${*: -1}" '{ok:true,agent_started:true,path:$p,branch:"fix",space:"sp1",desk:"t10",session:"s2",issue:"app-1",target:"pr:12",adoptReason:$r}' | tee -a "$XDG_STATE_HOME/bercail/handoffs.jsonl"
SPAWN
  chmod +x "$BERCAIL_HANDOFF_SPAWN"
  pr_head
}

# gh pr view answers that the PR's head is $PR_HEAD, fix by default.
pr_head() {
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'GH'
#!/bin/sh
jq -nc --arg h "${PR_HEAD:-fix}" '{headRefName:$h,isCrossRepository:false}'
GH
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
}

adopt() { request "${1:-r1}" | jq '.adoptReason="desk t9 exited; Simon asked to update the PR"'; }

@test "a PR branch whose desk is gone is adopted only with a recorded reason, in a new session on its checkout" {
  local out
  orphan
  out="$(request | task dispatch 2>&1)" && fail "$out"
  [[ "$out" == *"missing/stale"* ]]
  jq -nc --arg cwd "$REPO.fix" '{address:"t178",cwd:$cwd,state:"live",labels:{"bercail.role":"agent","bercail.space":"sp1"}}' >"$TASK_DATA/t178.hc"
  out="$(adopt | task dispatch 2>&1)" && fail "$out"
  [[ "$out" == *"live desk t178"* ]] || fail "an occupied checkout is not adoptable: $out"
  rm "$TASK_DATA/t178.hc"
  out="$(adopt | task dispatch)" || fail "$out"
  jq -e '.status == "awaiting-session" and .creation.desk == "t10" and .creation.session == "s2"' <<<"$out"
  grep -q -- '--branch fix .*--adopt-reason desk t9 exited; Simon asked to update the PR' "$LOG"
  jq -e '.metadata.bercail_task.adoptions[0] | .reason == "desk t9 exited; Simon asked to update the PR" and .request == "r1" and .branch == "fix" and .from[0].desk == "t9"' "$TASK_DATA/app-1.json"
  out="$(adopt | task dispatch)" || fail "$out"
  jq -e '.status == "queued" and .owner.desk == "t10" and .owner.session == "s2"' <<<"$out"
  out="$(request r2 | task dispatch)" || fail "$out"
  jq -e '.status == "queued" and .owner.desk == "t10"' <<<"$out"
  [[ "$(grep -c '^spawn ' "$LOG")" == 1 ]]
}

@test "adoption still refuses a live, stale, ambiguous or unbound owner" {
  local out
  out="$(adopt | task dispatch 2>&1)" && fail "$out"
  [[ "$out" == *"live original owner t9"* ]]
  owner t8 s2
  out="$(adopt | task dispatch 2>&1)" && fail "$out"
  [[ "$out" == *"ambiguous"* ]]
  rm "$TASK_DATA/t8.hc"
  jq '.start_ticks="stale"' "$XDG_STATE_HOME/bercail/desk-sessions/t9.json" >"$BATS_TEST_TMPDIR/r"
  mv "$BATS_TEST_TMPDIR/r" "$XDG_STATE_HOME/bercail/desk-sessions/t9.json"
  out="$(adopt | task dispatch 2>&1)" && fail "$out"
  [[ "$out" == *"stale"* ]]
  orphan
  out="$(adopt | PR_HEAD=other task dispatch 2>&1)" && fail "$out"
  [[ "$out" == *"not bound"* ]]
  out="$(adopt | jq '.adoptReason=" "' | task dispatch 2>&1)" && fail "$out"
  [[ "$out" == *"adoptReason"* ]]
  grep -q '^spawn ' "$LOG" && fail "a refused adoption must not spawn"
  ! grep -Eq 'hc (run|send|keys|kill|rm)' "$LOG"
}

@test "an adopting desk inherits no earlier request from the gone owner" {
  local out
  request | task dispatch >/dev/null
  orphan
  out="$(adopt r2 | task dispatch)" || fail "$out"
  jq -e '.status == "awaiting-session"' <<<"$out"
  jq -e '.metadata.bercail_task.requests[0] | .status == "blocked" and (.reason | contains("adopted"))' "$TASK_DATA/app-1.json"
  adopt r2 | task dispatch >/dev/null
  out="$(request | task dispatch)" || fail "$out"
  jq -e '.status == "blocked" and .retry' <<<"$out"
  [[ "$(find "$XDG_STATE_HOME/bercail/desk-follow-ups/t10" -name '*.json' | wc -l)" == 1 ]]
  ! grep -rq '"id":"r1"' "$XDG_STATE_HOME/bercail/desk-follow-ups/t10"
}

@test "after adopting a task dispatch created, follow-ups go to the adopting desk" {
  local out
  cp "$TASK_DATA/t9.hc" "$BATS_TEST_TMPDIR/original.hc"
  partial_launch
  export TASK_ORIGINAL="$BATS_TEST_TMPDIR/original.hc" TASK_REPO="$REPO"
  cat >"$BERCAIL_HANDOFF_SPAWN" <<'SPAWN'
#!/usr/bin/env bash
printf 'spawn %s\n' "$*" >>"$LOG"
cp "$TASK_ORIGINAL" "$TASK_DATA/t9.hc"
jq -nc --arg p "$TASK_REPO.fix" '{ok:true,agent_started:true,path:$p,branch:"fix",space:"sp1",desk:"t9",session:"s1",issue:"app-1",target:"pr:12"}' | tee "$XDG_STATE_HOME/bercail/handoffs.jsonl"
SPAWN
  request r0 | jq '.branch="fix"' | task dispatch >/dev/null
  request r0 | jq '.branch="fix"' | task dispatch >/dev/null
  orphan
  adopt | task dispatch >/dev/null
  adopt | task dispatch >/dev/null
  out="$(request r2 | task dispatch)" || fail "$out"
  jq -e '.status == "queued" and .owner.desk == "t10" and .owner.session == "s2"' <<<"$out"
}

@test "adoption needs a recorded owner and never takes the main checkout" {
  local out main
  orphan
  rm "$XDG_STATE_HOME/bercail/handoffs.jsonl"
  out="$(adopt | jq '.branch="fix"' | task dispatch 2>&1)" && fail "$out"
  [[ "$out" == *"nothing recorded"* ]]
  main="$(git -C "$REPO" branch --show-current)"
  jq -nc --arg p "$REPO" --arg b "$main" '{path:$p,branch:$b,issue:"app-1",desk:"t9",target:"pr:12"}' >"$XDG_STATE_HOME/bercail/handoffs.jsonl"
  out="$(adopt | PR_HEAD="$main" task dispatch 2>&1)" && fail "$out"
  [[ "$out" == *"main checkout"* ]]
  grep -q '^spawn ' "$LOG" && fail "a refused adoption must not spawn"
  [[ "$(jq '.metadata.bercail_task' "$TASK_DATA/app-1.json")" == null ]]
}

@test "adoption keeps the UNKNOWN refusal after an uncertain creation" {
  local out
  partial_launch
  pr_head
  out="$(request | jq '.branch="fix"' | task dispatch 2>&1)" && fail "$out"
  jq -nc --arg p "$REPO.fix" '{ok:false,path:$p,branch:"fix",issue:"app-1",target:"pr:12"}' >"$XDG_STATE_HOME/bercail/handoffs.jsonl"
  out="$(adopt r2 | task dispatch 2>&1)" && fail "$out"
  [[ "$out" == *"UNKNOWN"* ]]
  [[ "$(grep -c '^spawn ' "$LOG")" == 1 ]]
}
