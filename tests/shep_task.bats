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
  show) sleep "${TASK_BD_SLOW:-0}"; cat "$TASK_DATA/$2.json" ;;
  list) jq -s . "$TASK_DATA/"*.json ;;
  update)
    # TASK_CLOSE_ONCE_QUEUED: someone closes the issue once a follow-up is queued.
    if [[ -n ${TASK_CLOSE_ONCE_QUEUED:-} && ! -e "$TASK_DATA/closed-once" ]] \
      && find "$XDG_STATE_HOME/bercail/desk-follow-ups" -name '*.json' 2>/dev/null | grep -q .; then
      jq '.status = "closed"' "$TASK_DATA/$2.json" >"$TASK_DATA/tmp" && mv "$TASK_DATA/tmp" "$TASK_DATA/$2.json"
      touch "$TASK_DATA/closed-once"
    fi
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
 ls) shopt -s nullglob; files=("$TASK_DATA/"t*.hc) want='{}'
     # --label K=V keeps the terminals carrying every such label, as hc does.
     while (($#)); do [[ $1 != --label ]] || want="$(jq -c --arg kv "$2" '. + {($kv | split("=")[0]): ($kv | split("=")[1:] | join("="))}' <<<"$want")"; shift; done
     if ((${#files[@]})); then jq -s --argjson want "$want" '{terminals: [.[] | select(.labels as $l | $want | to_entries | all(.value == $l[.key]))]}' "${files[@]}"; else echo '{"terminals":[]}'; fi ;;
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
  pr_head
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
  mkdir -p "$XDG_RUNTIME_DIR/bercail/open-sessions"
  jq -n --arg s "$session" --arg ticks "$TICKS" --argjson pid "$PID" '{pid:$pid,start_ticks:$ticks,sessions:[$s]}' >"$XDG_RUNTIME_DIR/bercail/open-sessions/$PID.json"
  jq -n --arg id "$id" --arg cwd "$REPO.fix" --argjson pid "$PID" '{address:$id,cwd:$cwd,state:"live",foreground:{pid:$pid},labels:{"bercail.role":"agent","bercail.issue":"app-1","bercail.space":"sp1"},status:{state:"working"}}' >"$TASK_DATA/$id.hc"
  jq -n --arg id "$id" --arg cwd "$REPO.fix" --arg s "$session" --arg f "$file" --arg ticks "$TICKS" --argjson pid "$PID" '{address:$id,cwd:$cwd,session:$s,session_file:$f,space:"sp1",issue:"app-1",harness:"pi",pid:$pid,start_ticks:$ticks,follow_up:1}' >"$XDG_STATE_HOME/bercail/desk-sessions/$id.json"
}

request() {
  jq -nc --arg repo "$REPO" --arg id "${1:-r1}" '{repo:$repo,issue:"app-1",target:"https://github.com/o/app/pull/12/",requestId:$id,stage:"autopilot",message:"Amend with gt m -a and publish the new head"}'
}

task() { "$ROOT/bin/bercail" shep task "$@"; }

@test "follow-ups reuse the original visible owner and reopen a closed task without authority" {
  local out
  out="$(request | task dispatch)" || fail "$out"
  jq -e '.owner.desk == "t9" and .owner.session == "s1" and .status == "queued" and .authority == false' <<<"$out"
  request | task dispatch >/dev/null
  request r2 | task dispatch >/dev/null
  [[ "$(find "$XDG_STATE_HOME/bercail/desk-follow-ups" -name '*.json' | wc -l)" == 2 ]]
  jq -e '.status == "in_progress" and .metadata.bercail_task.owner.session == "s1"' "$TASK_DATA/app-1.json"
  ! grep -Eq 'hc (run|send|keys|kill|rm)' "$LOG"
}

@test "dispatch waits out a bd that takes 5 seconds, past the old 3" {
  local out
  out="$(request | TASK_BD_SLOW=5 task dispatch)" || fail "$out"
  jq -e '.status == "queued" and .owner.desk == "t9"' <<<"$out"
}

@test "dispatch is the only task command, and a v0.17 field is named, not ignored" {
  local out op
  for op in status block receipt; do
    out="$(request | task "$op" 2>&1)" && fail "$op: $out"
    [[ "$out" == *"usage: bercail shep task dispatch"* ]] || fail "$op: $out"
  done
  out="$(request | jq '.outcome="publish" | .authoring="gt m -a"' | task dispatch 2>&1)" && fail "$out"
  [[ "$out" == *"unknown task field outcome, authoring"* ]] || fail "$out"
  out="$(request | task dispatch --wait 2>&1)" && fail "$out"
  [[ "$out" == *"unknown flag --wait; dispatch takes --wait-ready, --dry-run"* ]] || fail "$out"
  [[ ! -e "$LOG" ]] || fail "a refused flag still ran: $(cat "$LOG")"
  [[ ! -d "$XDG_STATE_HOME/bercail/desk-follow-ups" ]]
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
  [[ "$out" == *"ambiguous owners t8, t9"* ]] || fail "the refusal lists the owners: $out"
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
  jq -e '.metadata.bercail_task.owner.session == "s1"' "$TASK_DATA/app-1.json"
  [[ "$(find "$XDG_STATE_HOME/bercail/desk-follow-ups" -name '*.json' | wc -l)" == 1 ]]
}

@test "a desk restored onto its same session with a new pid takes the follow-up, and its record moves to that pid" {
  local out old="$PID"
  request | task dispatch >/dev/null
  # A reboot and bercail desk restore: the same desk and session, a new Pi process.
  kill "$PID"; wait "$PID" 2>/dev/null || true
  rm "$XDG_RUNTIME_DIR/bercail/open-sessions/$PID.json"
  start_pi PID
  TICKS="$(awk '{print $22}' "/proc/$PID/stat")"
  owner t9 s1
  [[ "$PID" != "$old" ]] || fail "the restored Pi kept pid $old"
  out="$(request r2 | task dispatch)" || fail "$out"
  jq -e --argjson pid "$PID" '.status == "queued" and .owner.desk == "t9" and .owner.session == "s1" and .owner.pid == $pid' <<<"$out" || fail "$out"
  jq -e --argjson pid "$PID" --arg ticks "$TICKS" '.metadata.bercail_task.owner | .pid == $pid and .start_ticks == $ticks' "$TASK_DATA/app-1.json"
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
  file="$(find "$XDG_STATE_HOME/bercail/desk-follow-ups" -name '*.json')"
  [[ -f "$file" ]] || fail "the retry did not queue it again"
  jq '.delivery="unknown"' "$file" >"$BATS_TEST_TMPDIR/msg"
  mv "$BATS_TEST_TMPDIR/msg" "$file"
  request | task dispatch >/dev/null
  jq -e '.delivery == "unknown"' "$file"
  out="$(request | jq '.message="different effect"' | task dispatch 2>&1)" && fail "$out"
  [[ "$out" == *"payload changed"* ]]
}

# The only fake launch effects here are a log line and the handoffs.jsonl line a
# finished spawn writes; no real Herdr process runs.
partial_launch() {
  rm "$TASK_DATA/"*.hc "$XDG_STATE_HOME/bercail/handoffs.jsonl"
  export BERCAIL_HANDOFF_SPAWN="$BATS_TEST_TMPDIR/bin/spawn"
  cat >"$BERCAIL_HANDOFF_SPAWN" <<'EOF'
#!/usr/bin/env bash
printf 'spawn %s\n' "$*" >>"$LOG"
printf '{"ok":false,"agent_started":false,"path":"%s.partial","space":"sp-new","branch":"fresh","issue":"app-1"}\n' "$PWD" >>"$XDG_STATE_HOME/bercail/handoffs.jsonl"
tail -1 "$XDG_STATE_HOME/bercail/handoffs.jsonl"
EOF
  chmod +x "$BERCAIL_HANDOFF_SPAWN"
}

# A first dispatch for a new bstack desk on branch $2 (fresh by default).
create() { request "${1:-r1}" | jq --arg b "${2:-fresh}" '.branch=$b | .stage="bstack"'; }

@test "a spawn that ended partial reserves the job: while its space is open, a retry reports UNKNOWN and a new request launches nothing" {
  local out
  partial_then
  out="$(create r1 fix | task dispatch 2>&1)" && fail "$out"
  shell_in t30 "$REPO"
  out="$(create r1 fix | task dispatch)" || fail "$out"
  jq -e '.status == "unknown" and .authority == false and .retry and (.next | contains("space sp-new of the partial creation is still open"))' <<<"$out" || fail "$out"
  [[ "$(grep -c '^spawn ' "$LOG")" == 1 ]]
  jq -e '.status == "in_progress" and .metadata.bercail_task.creation.status == "unknown"' "$TASK_DATA/app-1.json"
  # A line with no space cannot show that space closed.
  rm "$TASK_DATA/t30.hc"
  jq -c 'del(.space)' "$XDG_STATE_HOME/bercail/handoffs.jsonl" >"$BATS_TEST_TMPDIR/r"
  mv "$BATS_TEST_TMPDIR/r" "$XDG_STATE_HOME/bercail/handoffs.jsonl"
  out="$(create r1 fix | task dispatch)" || fail "$out"
  jq -e '.status == "unknown" and (.next | contains("recorded no space"))' <<<"$out" || fail "$out"
  # A line that does not say its spawn started no agent may have started one.
  jq -c 'del(.agent_started)' "$XDG_STATE_HOME/bercail/handoffs.jsonl" >"$BATS_TEST_TMPDIR/r"
  mv "$BATS_TEST_TMPDIR/r" "$XDG_STATE_HOME/bercail/handoffs.jsonl"
  out="$(create r1 fix | task dispatch)" || fail "$out"
  jq -e '.status == "unknown" and (.next | contains("handoffs.jsonl has a line"))' <<<"$out" || fail "$out"
  [[ "$(grep -c '^spawn ' "$LOG")" == 1 ]]
  out="$(create r2 fix | task dispatch 2>&1)" && fail "$out"
  [[ "$(grep -c '^spawn ' "$LOG")" == 1 ]] || fail "a new request launched again: $out"
}

# A spawn that starts desk $1 in $2: it logs its argv, makes the worktree when it
# is missing, writes the desk's hc record and its handoffs.jsonl line, and prints that line.
spawn_ok() {
  export BERCAIL_HANDOFF_SPAWN="$BATS_TEST_TMPDIR/bin/spawn" TASK_DESK="$1" TASK_PATH="$2" TASK_REPO="$REPO"
  cat >"$BERCAIL_HANDOFF_SPAWN" <<'EOF'
#!/usr/bin/env bash
printf 'spawn %s\n' "$*" >>"$LOG"
while (($#)); do case "$1" in --issue) issue="$2" ;; --branch) branch="$2" ;; esac; shift; done
[[ -d "$TASK_PATH" ]] || git -C "$TASK_REPO" worktree add -qb "$branch" "$TASK_PATH"
jq -nc --arg d "$TASK_DESK" --arg p "$TASK_PATH" --arg i "$issue" '{address:$d,cwd:$p,state:"live",labels:{"bercail.role":"agent","bercail.space":"sp-new","bercail.issue":$i}}' >"$TASK_DATA/$TASK_DESK.hc"
jq -nc --arg d "$TASK_DESK" --arg p "$TASK_PATH" --arg i "$issue" --arg b "$branch" '{ok:true,agent_started:true,path:$p,branch:$b,space:"sp-new",desk:$d,session:"s-new",issue:$i}' >>"$XDG_STATE_HOME/bercail/handoffs.jsonl"
tail -1 "$XDG_STATE_HOME/bercail/handoffs.jsonl"
EOF
  chmod +x "$BERCAIL_HANDOFF_SPAWN"
}

# An idle shell $1 in folder $2, as a space's first terminal shows in hc.
shell_in() {
  jq -nc --arg a "$1" --arg p "$2" '{address:$a,cwd:$p,state:"live",foreground:{name:"bash"},labels:{"herdr.space":"sp-new"}}' >"$TASK_DATA/$1.hc"
}

# The first spawn makes the fresh worktree and its space's shell, starts a child,
# then hangs past [shep] spawn_timeout. A retry finishes it as spawn_ok does.
slow_launch() {
  rm "$TASK_DATA/"*.hc "$XDG_STATE_HOME/bercail/handoffs.jsonl"
  mkdir -p "$XDG_CONFIG_HOME/bercail"
  printf '[shep]\nspawn_timeout = 1\n' >"$XDG_CONFIG_HOME/bercail/config.toml"
  spawn_ok t21 "$REPO.fresh"
  mv "$BERCAIL_HANDOFF_SPAWN" "$BATS_TEST_TMPDIR/bin/finish"
  export TASK_REPO="$REPO" TASK_CHILD="$BATS_TEST_TMPDIR/child"
  cat >"$BERCAIL_HANDOFF_SPAWN" <<'EOF'
#!/usr/bin/env bash
[[ -f "$TASK_CHILD" ]] && exec "$(dirname "$0")/finish" "$@"
printf 'spawn %s\n' "$*" >>"$LOG"
git -C "$TASK_REPO" worktree add -qb fresh "$TASK_REPO.fresh"
jq -nc --arg p "$TASK_REPO.fresh" '{address:"t20",cwd:$p,state:"live",foreground:{name:"bash"},labels:{"herdr.space":"sp-new"}}' >"$TASK_DATA/t20.hc"
sleep 60 &
echo $! >"$TASK_CHILD"
wait
EOF
  chmod +x "$BERCAIL_HANDOFF_SPAWN"
}

@test "a spawn past spawn_timeout is stopped with its children, and a retry finishes it in the clean worktree" {
  local out child
  slow_launch
  out="$(create | task dispatch 2>&1)" && fail "$out"
  [[ "$out" == *"did not finish in 1s"* ]] || fail "$out"
  child="$(cat "$TASK_CHILD")"
  ! kill -0 "$child" 2>/dev/null || fail "the spawn's child $child outlived the timeout"
  jq -e '.metadata.bercail_task.creation | .status == "unknown" and (.reason | contains("spawn_timeout"))' "$TASK_DATA/app-1.json"
  out="$(create | task dispatch)" || fail "$out"
  jq -e --arg p "$REPO.fresh" '.status == "started" and .creation.desk == "t21" and .creation.path == $p and .retry' <<<"$out"
  [[ "$(grep -c '^spawn ' "$LOG")" == 2 ]]
  grep '^spawn ' "$LOG" | tail -1 | grep -q -- '--branch fresh --stage bstack .*--reuse-worktree' || fail "$(cat "$LOG")"
  jq -e '.metadata.bercail_task.creation | .status == "started" and (has("reason") | not)' "$TASK_DATA/app-1.json"
}

@test "a partial creation stays UNKNOWN when its worktree has changes, a busy terminal or a desk" {
  local out
  slow_launch
  create | task dispatch >/dev/null 2>&1 && fail "the slow spawn should time out"
  echo edit >>"$REPO.fresh/file.txt"
  out="$(create | task dispatch)" || fail "$out"
  jq -e '.status == "unknown" and (.next | contains("has changes"))' <<<"$out"
  git -C "$REPO.fresh" checkout -q file.txt
  jq '.foreground.name="npm"' "$TASK_DATA/t20.hc" >"$BATS_TEST_TMPDIR/t"; mv "$BATS_TEST_TMPDIR/t" "$TASK_DATA/t20.hc"
  out="$(create | task dispatch)" || fail "$out"
  jq -e '.status == "unknown" and (.next | contains("not an idle shell"))' <<<"$out"
  shell_in t20 "$REPO.fresh"
  jq -nc '{address:"t22",cwd:"/",state:"live",labels:{"bercail.role":"agent","bercail.issue":"app-1"}}' >"$TASK_DATA/t22.hc"
  jq -c --arg p "$REPO.fresh" '.cwd=$p' "$TASK_DATA/t22.hc" >"$BATS_TEST_TMPDIR/t"; mv "$BATS_TEST_TMPDIR/t" "$TASK_DATA/t22.hc"
  out="$(create | task dispatch)" || fail "$out"
  jq -e '.status == "unknown" and (.next | contains("t22 is live for app-1"))' <<<"$out"
  [[ "$(grep -c '^spawn ' "$LOG")" == 1 ]]
}

@test "a partial creation that left no worktree starts again on retry" {
  local out
  slow_launch
  create | task dispatch >/dev/null 2>&1 && fail "the slow spawn should time out"
  rm "$TASK_DATA/t20.hc"
  git -C "$REPO" worktree remove "$REPO.fresh"
  git -C "$REPO" branch -qD fresh
  out="$(create | task dispatch)" || fail "$out"
  jq -e '.status == "started" and .creation.desk == "t21"' <<<"$out"
  grep '^spawn ' "$LOG" | tail -1 | grep -q -- '--reuse-worktree' && fail "nothing was left to reuse: $(cat "$LOG")"
  [[ "$(grep -c '^spawn ' "$LOG")" == 2 ]]
}

# The first spawn ends partial the way handoff-spawn logs it: no desk, ok and
# agent_started false, the fix checkout, space sp-new and the session it pinned
# ($1, s-pinned by default). Later spawns run bin/finish.
partial_then() {
  rm -f "$TASK_DATA/"*.hc
  : >"$XDG_STATE_HOME/bercail/handoffs.jsonl"
  export BERCAIL_HANDOFF_SPAWN="$BATS_TEST_TMPDIR/bin/spawn" TASK_MARK="$BATS_TEST_TMPDIR/partial-done" TASK_REPO="$REPO" TASK_PINNED="${1:-s-pinned}"
  cat >"$BERCAIL_HANDOFF_SPAWN" <<'EOF'
#!/usr/bin/env bash
[[ -f "$TASK_MARK" ]] && exec "$(dirname "$0")/finish" "$@"
touch "$TASK_MARK"
printf 'spawn %s\n' "$*" >>"$LOG"
jq -nc --arg p "$TASK_REPO.fix" --arg s "$TASK_PINNED" '{ok:false,agent_started:false,path:$p,branch:"fix",issue:"app-1",space:"sp-new",session:$s,target:"pr:12",error:"partial visible creation; inspect these facts, do not relaunch"}' | tee -a "$XDG_STATE_HOME/bercail/handoffs.jsonl"
exit 1
EOF
  chmod +x "$BERCAIL_HANDOFF_SPAWN"
}

@test "once a partial creation's space is closed, a retry of its id finishes it in its clean worktree, and the next binds that desk" {
  local out
  cp "$TASK_DATA/t9.hc" "$BATS_TEST_TMPDIR/original.hc"
  partial_then
  export TASK_ORIGINAL="$BATS_TEST_TMPDIR/original.hc"
  cat >"$BATS_TEST_TMPDIR/bin/finish" <<'EOF'
#!/usr/bin/env bash
printf 'spawn %s\n' "$*" >>"$LOG"
cp "$TASK_ORIGINAL" "$TASK_DATA/t9.hc"
jq -nc --arg p "$TASK_REPO.fix" '{ok:true,agent_started:true,path:$p,branch:"fix",space:"sp1",desk:"t9",session:"s1",issue:"app-1",target:"pr:12"}' | tee -a "$XDG_STATE_HOME/bercail/handoffs.jsonl"
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/finish"
  out="$(create r1 fix | task dispatch 2>&1)" && fail "$out"
  out="$(create r1 fix | task dispatch)" || fail "$out"
  jq -e '.status == "started" and .creation.desk == "t9" and .retry' <<<"$out" || fail "$out"
  grep '^spawn ' "$LOG" | tail -1 | grep -q -- '--branch fix .*--reuse-worktree' || fail "$(cat "$LOG")"
  # The partial line's pinned session and space name no desk: they do not conflict with the one that finished it.
  out="$(create r1 fix | task dispatch)" || fail "$out"
  jq -e '.status == "queued" and .owner.desk == "t9" and .owner.session == "s1"' <<<"$out" || fail "$out"
  [[ "$(grep -c '^spawn ' "$LOG")" == 2 ]]
}

@test "a partial creation's desk that came up after all is bound by a retry of its id, only with the session its line names" {
  local out
  cp "$TASK_DATA/t9.hc" "$BATS_TEST_TMPDIR/original.hc"
  partial_then s-other
  out="$(create r1 fix | task dispatch 2>&1)" && fail "$out"
  # t9, the space's desk, comes up after the spawn ended.
  cp "$BATS_TEST_TMPDIR/original.hc" "$TASK_DATA/t9.hc"
  jq -c '.space = "sp1"' "$XDG_STATE_HOME/bercail/handoffs.jsonl" >"$BATS_TEST_TMPDIR/r"
  mv "$BATS_TEST_TMPDIR/r" "$XDG_STATE_HOME/bercail/handoffs.jsonl"
  out="$(create r1 fix | task dispatch)" || fail "$out"
  jq -e '.status == "unknown" and (.next | contains("mapping conflicts"))' <<<"$out" || fail "another session is not the pinned one: $out"
  jq -c 'del(.session)' "$XDG_STATE_HOME/bercail/handoffs.jsonl" >"$BATS_TEST_TMPDIR/r"
  mv "$BATS_TEST_TMPDIR/r" "$XDG_STATE_HOME/bercail/handoffs.jsonl"
  out="$(create r1 fix | task dispatch)" || fail "$out"
  jq -e '.status == "unknown" and (.next | contains("not the session and space the partial creation pinned"))' <<<"$out" || fail "no pinned session, no binding: $out"
  jq -c '.session = "s1"' "$XDG_STATE_HOME/bercail/handoffs.jsonl" >"$BATS_TEST_TMPDIR/r"
  mv "$BATS_TEST_TMPDIR/r" "$XDG_STATE_HOME/bercail/handoffs.jsonl"
  out="$(create r1 fix | task dispatch)" || fail "$out"
  jq -e '.status == "queued" and .owner.desk == "t9" and .owner.session == "s1" and .retry' <<<"$out" || fail "$out"
  jq -e '.metadata.bercail_task | .owner.desk == "t9" and (.creation | .status == "started" and (has("reason") | not))' "$TASK_DATA/app-1.json"
  [[ "$(find "$XDG_STATE_HOME/bercail/desk-follow-ups" -name '*.json' | wc -l)" == 1 ]]
  [[ "$(grep -c '^spawn ' "$LOG")" == 1 ]]
}

@test "a partial line's pinned session and space stop counting once a later spawn followed it and its space is closed, never its checkout" {
  local out partial launched record="$XDG_STATE_HOME/bercail/handoffs.jsonl"
  partial="$(jq -nc --arg p "$REPO.fix" '{ok:false,agent_started:false,path:$p,branch:"fix",issue:"app-1",space:"sp-new",session:"s-old",target:"pr:12"}')"
  launched="$(head -1 "$record" | jq -c '. + {ok:true,agent_started:true,session:"s1"}')"
  printf '%s\n%s\n' "$partial" "$launched" >"$record"
  out="$(request | task dispatch)" || fail "$out"
  jq -e '.status == "queued" and .owner.desk == "t9"' <<<"$out" || fail "$out"
  shell_in t30 "$REPO"
  out="$(request r2 | task dispatch 2>&1)" && fail "$out"
  [[ "$out" == *"space sp-new of the partial creation is still open"* ]] || fail "a desk may still come up there: $out"
  rm "$TASK_DATA/t30.hc"
  printf '%s\n%s\n' "$(jq -c '.branch = "other"' <<<"$partial")" "$launched" >"$record"
  out="$(request r3 | task dispatch 2>&1)" && fail "$out"
  [[ "$out" == *"mapping conflicts"* ]] || fail "a partial line's branch still counts: $out"
  # A second partial creation whose pinned desk came up, after the first one's space closed.
  printf '%s\n%s\n' "$partial" "$(jq -c '.session = "s1" | .space = "sp1"' <<<"$partial")" >"$record"
  out="$(request r4 | task dispatch)" || fail "$out"
  jq -e '.status == "queued" and .owner.desk == "t9"' <<<"$out" || fail "$out"
  # The first one pinned another session in the space that desk holds.
  printf '%s\n%s\n' "$(jq -c '.space = "sp1"' <<<"$partial")" "$(jq -c '.session = "s1" | .space = "sp1"' <<<"$partial")" >"$record"
  out="$(request r5 | task dispatch 2>&1)" && fail "$out"
  [[ "$out" == *"space sp1 of the partial creation is still open (terminal t9)"* ]] || fail "$out"
}

@test "a new request with adoptReason adopts the checkout a partial creation left, once its space is closed" {
  local out
  orphan
  mv "$BERCAIL_HANDOFF_SPAWN" "$BATS_TEST_TMPDIR/bin/finish"
  partial_then
  out="$(create r1 fix | task dispatch 2>&1)" && fail "$out"
  shell_in t31 "$REPO"
  out="$(adopt r2 | task dispatch 2>&1)" && fail "$out"
  [[ "$out" == *"space sp-new of the partial creation is still open"* ]] || fail "$out"
  out="$(adopt r3 | jq 'del(.adoptReason)' | task dispatch 2>&1)" && fail "$out"
  [[ "$out" == *"original owner missing/stale"* && "$out" == *"retry request r1"* ]] || fail "no reason, no adoption: $out"
  rm "$TASK_DATA/t31.hc"
  out="$(adopt r2 | task dispatch)" || fail "$out"
  jq -e '.status == "started" and .creation.desk == "t10" and (.warning | startswith("Adopted: desk t9 exited"))' <<<"$out" || fail "$out"
  grep '^spawn ' "$LOG" | tail -1 | grep -q -- '--adopt-reason desk t9 exited' || fail "$(cat "$LOG")"
  out="$(create r1 fix | task dispatch 2>&1)" && fail "$out"
  [[ "$out" == *"request r1 is retired"* ]] || fail "$out"
  [[ "$(grep -c '^spawn ' "$LOG")" == 2 ]]
}

@test "a new desk on a PR's own branch starts at its head, and stage autopilot starts an autopilot" {
  local out
  rm "$TASK_DATA/t9.hc" "$XDG_STATE_HOME/bercail/handoffs.jsonl"
  spawn_ok t21 "$REPO.fix"
  out="$(request | jq '.branch="fresh"' | task dispatch 2>&1)" && fail "$out"
  [[ "$out" == *"stage autopilot starts a desk only on an open PR's own branch"* ]] || fail "$out"
  grep -q '^spawn ' "$LOG" && fail "a refused autopilot must not spawn"
  out="$(request | jq '.branch="fix"' | task dispatch)" || fail "$out"
  jq -e '.status == "started" and .creation.desk == "t21"' <<<"$out"
  grep -q -- '^spawn --branch fix --stage autopilot .*--target pr:12 .*--existing-branch' "$LOG" || fail "$(cat "$LOG")"
}

@test "a v0.17 request ledger is dropped on the next save, and a retry of its UNKNOWN autopilot launches nothing off the PR's branch" {
  local out
  rm "$TASK_DATA/t9.hc" "$XDG_STATE_HOME/bercail/handoffs.jsonl"
  spawn_ok t21 "$REPO.fresh"
  # The record as v0.17 saved it: a request ledger, with an UNKNOWN creation.
  jq --arg repo "$(realpath "$REPO")" '.metadata.bercail_task = {v:1,repo:$repo,target:"pr:12",owner:null,branch:"fresh",
    requests:[{id:"r1",sequence:0,payload:"old",outcome:"publish",stage:"autopilot",message:"Amend with gt m -a and publish the new head",authoring:"gt m -a",status:"unknown",next:""}]}' \
    "$TASK_DATA/app-1.json" >"$BATS_TEST_TMPDIR/t"
  mv "$BATS_TEST_TMPDIR/t" "$TASK_DATA/app-1.json"
  out="$(request | jq '.branch="fresh"' | task dispatch)" || fail "$out"
  jq -e '.status == "unknown" and (.next | contains("stage autopilot starts a desk only on pr:12'"'"'s own branch"))' <<<"$out" || fail "$out"
  out="$(request r9 | jq '.branch="fresh"' | task dispatch 2>&1)" && fail "$out"
  [[ "$out" == *"creation outcome UNKNOWN"* ]] || fail "$out"
  ! grep -q '^spawn ' "$LOG" || fail "no desk may start: $(cat "$LOG")"
  # A follow-up to a live owner saves the record without the ledger.
  owner t9 s1
  jq -nc --arg p "$REPO.fix" '{path:$p,branch:"fix",issue:"app-1",space:"sp1",desk:"t9",target:"pr:12"}' >"$XDG_STATE_HOME/bercail/handoffs.jsonl"
  jq '.metadata.bercail_task.branch="fix"' "$TASK_DATA/app-1.json" >"$BATS_TEST_TMPDIR/t"
  mv "$BATS_TEST_TMPDIR/t" "$TASK_DATA/app-1.json"
  out="$(request r2 | task dispatch)" || fail "$out"
  jq -e '.status == "queued" and .owner.desk == "t9"' <<<"$out"
  jq -e '.metadata.bercail_task | (has("requests") | not) and .v == 2 and .owner.desk == "t9"' "$TASK_DATA/app-1.json"
}

@test "a target held by an issue closed as superseded moves to its successor once none of its desks is live" {
  local out
  jq -n '{id:"app-2",title:"Autopilot the PR",status:"open",metadata:{}}' >"$TASK_DATA/app-2.json"
  spawn_ok t21 "$REPO.fix"
  out="$(request | jq '.issue="app-2" | .branch="fix"' | task dispatch 2>&1)" && fail "$out"
  [[ "$out" == *"already owned by app-1"* && "$out" == *"bd supersede app-1 --with app-2"* ]] || fail "$out"
  jq '.dependencies=[{issue_id:"app-1",depends_on_id:"app-2",type:"supersedes"}]' "$TASK_DATA/app-1.json" >"$BATS_TEST_TMPDIR/t"
  mv "$BATS_TEST_TMPDIR/t" "$TASK_DATA/app-1.json"
  out="$(request | jq '.issue="app-2" | .branch="fix"' | task dispatch 2>&1)" && fail "$out"
  [[ "$out" == *"superseded issue app-1 still has live desk t9"* ]] || fail "$out"
  rm "$TASK_DATA/t9.hc"
  out="$(request | jq '.issue="app-2" | .branch="fix"' | task dispatch)" || fail "$out"
  jq -e '.status == "started" and .creation.desk == "t21" and .creation.issue == "app-2"' <<<"$out"
  grep -q -- '--existing-branch --released app-1' "$LOG" || fail "$(cat "$LOG")"
}

@test "repo serialization covers concurrent issue aliases, not just the same issue" {
  local a b
  partial_launch
  jq -n '{id:"app-2",title:"Alias",metadata:{}}' >"$TASK_DATA/app-2.json"
  create | task dispatch >"$BATS_TEST_TMPDIR/a" 2>&1 & a=$!
  create r2 other | jq '.issue="app-2"' | task dispatch >"$BATS_TEST_TMPDIR/b" 2>&1 & b=$!
  wait "$a" || true
  wait "$b" || true
  [[ "$(grep -c '^spawn ' "$LOG")" == 1 ]]
  jq -se '[.[].metadata.bercail_task.creation // empty] | length == 1' "$TASK_DATA/app-"*.json
}

@test "same issue id in another repo does not inherit this repo's owner" {
  local other="$BATS_TEST_TMPDIR/other" data="$BATS_TEST_TMPDIR/other-issues" out
  request | task dispatch >/dev/null
  git_init "$other"
  git -C "$other" remote add origin https://github.com/o/app.git
  mkdir -p "$data"
  jq -n '{id:"app-1",title:"Unrelated",metadata:{}}' >"$data/app-1.json"
  export BERCAIL_HANDOFF_SPAWN="$BATS_TEST_TMPDIR/bin/spawn"
  printf '#!/bin/sh\necho "{\"ok\":false,\"agent_started\":false}"\n' >"$BERCAIL_HANDOFF_SPAWN"
  chmod +x "$BERCAIL_HANDOFF_SPAWN"
  out="$(create r1 other | jq --arg repo "$other" '.repo=$repo' | TASK_DATA="$data" task dispatch 2>&1)" && fail "$out"
  jq -e --arg repo "$other" '.metadata.bercail_task.repo == $repo and .metadata.bercail_task.owner == null' "$data/app-1.json"
  jq -e --arg repo "$REPO" '.metadata.bercail_task.repo == $repo and .metadata.bercail_task.owner.desk == "t9"' "$TASK_DATA/app-1.json"
}

@test "task namespace merge keeps an unrelated metadata edit during the update" {
  export TASK_CONCURRENT_METADATA=1
  jq '.metadata.external="old external marker"' "$TASK_DATA/app-1.json" >"$TASK_DATA/tmp"
  mv "$TASK_DATA/tmp" "$TASK_DATA/app-1.json"
  request | task dispatch >/dev/null
  jq -e '.metadata.external == "newer unrelated value" and .metadata.bercail_task.owner.desk == "t9"' "$TASK_DATA/app-1.json"
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
  jq -e '.status == "started" and .creation.desk == "t9"' <<<"$out"
  jq -e '.metadata.external == "keep this concurrent annotation"' "$TASK_DATA/app-1.json"
  out="$(request | jq '.branch="fix"' | task dispatch)" || fail "$out"
  jq -e '.status == "queued" and .owner.session == "s1"' <<<"$out"
  request | jq '.branch="fix"' | task dispatch >/dev/null
  [[ "$(grep -c '^spawn ' "$LOG")" == 1 ]]
  [[ "$(find "$XDG_STATE_HOME/bercail/desk-follow-ups" -name '*.json' | wc -l)" == 1 ]]
}

@test "a retry of the creation, once its desk is restored onto its session with a new pid, queues there and saves that pid" {
  local out
  partial_launch
  export TASK_ORIGINAL="$BATS_TEST_TMPDIR/original.hc" TASK_REPO="$REPO"
  owner t9 s1
  mv "$TASK_DATA/t9.hc" "$TASK_ORIGINAL"
  cat >"$BERCAIL_HANDOFF_SPAWN" <<'EOF'
#!/usr/bin/env bash
cp "$TASK_ORIGINAL" "$TASK_DATA/t9.hc"
jq -nc --arg p "$TASK_REPO.fix" '{ok:true,agent_started:true,path:$p,branch:"fix",space:"sp1",desk:"t9",session:"s1",issue:"app-1",target:"pr:12"}' | tee "$XDG_STATE_HOME/bercail/handoffs.jsonl"
EOF
  request | jq '.branch="fix"' | task dispatch >/dev/null
  # A follow-up binds the owner before the creation's own message is queued.
  request r2 | task dispatch >/dev/null
  kill "$PID"; wait "$PID" 2>/dev/null || true
  rm "$XDG_RUNTIME_DIR/bercail/open-sessions/$PID.json"
  start_pi PID
  TICKS="$(awk '{print $22}' "/proc/$PID/stat")"
  owner t9 s1
  out="$(request | jq '.branch="fix"' | task dispatch)" || fail "$out"
  jq -e --argjson pid "$PID" '.status == "queued" and .retry and .owner.pid == $pid' <<<"$out" || fail "$out"
  jq -e --argjson pid "$PID" --arg ticks "$TICKS" '.metadata.bercail_task.owner | .pid == $pid and .start_ticks == $ticks' "$TASK_DATA/app-1.json"
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
# TASK_LATE: the new desk's record shows up once dispatch has saved the started creation.
if [[ -n ${TASK_LATE:-} ]]; then
  {
    until jq -e '.metadata.bercail_task.creation.status == "started"' "$TASK_DATA/app-1.json" >/dev/null 2>&1; do sleep 0.1; done
    sleep 0.5
    mv "$TASK_LATE" "$XDG_STATE_HOME/bercail/desk-sessions/t10.json"
  } </dev/null >/dev/null 2>&1 &
fi
jq -nc --arg p "$TASK_REPO.fix" --arg r "${*: -1}" '{ok:true,agent_started:true,path:$p,branch:"fix",space:"sp1",desk:"t10",session:"s2",issue:"app-1",target:"pr:12",adoptReason:$r}' | tee -a "$XDG_STATE_HOME/bercail/handoffs.jsonl"
SPAWN
  chmod +x "$BERCAIL_HANDOFF_SPAWN"
  pr_head
}

# gh pr view answers that the PR's head is $PR_HEAD (fix by default), at $PR_OID.
pr_head() {
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'GH'
#!/bin/sh
jq -nc --arg h "${PR_HEAD:-fix}" --arg oid "${PR_OID:-}" '{headRefName:$h,headRefOid:$oid,isCrossRepository:false}'
GH
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
}

adopt() { request "${1:-r1}" | jq '.adoptReason="desk t9 exited; Simon asked to update the PR"'; }

@test "dispatch adopts a gone desk's checkout by itself, in a new session, and says so" {
  local out
  orphan
  jq -nc --arg cwd "$REPO.fix" '{address:"t178",cwd:$cwd,state:"live",labels:{"bercail.role":"agent","bercail.space":"sp1"}}' >"$TASK_DATA/t178.hc"
  out="$(request | task dispatch 2>&1)" && fail "$out"
  [[ "$out" == *"live desk t178"* ]] || fail "an occupied checkout is not adoptable: $out"
  rm "$TASK_DATA/t178.hc"
  out="$(request | task dispatch)" || fail "$out"
  jq -e '.status == "started" and .creation.desk == "t10" and .creation.session == "s2"' <<<"$out"
  jq -e '.adopted.from[0].desk == "t9" and .adopted.staged == 0 and (.warning | startswith("Adopted: desk t9 is gone, so desk t10 starts a new session") and contains("Tell the person"))' <<<"$out" || fail "$out"
  grep -q -- '--branch fix .*--adopt-reason desk t9 is gone$' "$LOG" || fail "$(cat "$LOG")"
  jq -e '.metadata.bercail_task.adoptions[0] | .reason == "desk t9 is gone" and .request == "r1" and .branch == "fix" and .from[0].desk == "t9"' "$TASK_DATA/app-1.json"
  # Its retry queues the message, and says again what was adopted.
  out="$(request | task dispatch)" || fail "$out"
  jq -e '.status == "queued" and .owner.desk == "t10" and .owner.session == "s2" and (.warning | startswith("Adopted: desk t9 is gone"))' <<<"$out" || fail "$out"
  out="$(request r2 | task dispatch)" || fail "$out"
  jq -e '.status == "queued" and .owner.desk == "t10"' <<<"$out"
  [[ "$(grep -c '^spawn ' "$LOG")" == 1 ]]
}

@test "a recorded desk still live without its labels, or a spawn that started no desk, is not adopted" {
  local out
  cp "$TASK_DATA/t9.hc" "$BATS_TEST_TMPDIR/t9.hc"
  orphan
  jq 'del(.labels["bercail.role"])' "$BATS_TEST_TMPDIR/t9.hc" >"$TASK_DATA/t9.hc"
  out="$(request | task dispatch 2>&1)" && fail "$out"
  [[ "$out" == *"recorded desk t9 is still live"* ]] || fail "$out"
  rm "$TASK_DATA/t9.hc"
  # handoff-spawn logs a partial creation too: no desk, ok false.
  jq -nc --arg p "$REPO.fix" '{ok:false,agent_started:false,path:$p,branch:"fix",issue:"app-1",space:"",desk:"",target:"pr:12"}' >"$XDG_STATE_HOME/bercail/handoffs.jsonl"
  out="$(request | task dispatch 2>&1)" && fail "$out"
  [[ "$out" == *"original owner missing/stale"* ]] || fail "$out"
  # A failed spawn may log the desk it found in the space without starting it.
  jq -nc --arg p "$REPO.fix" '{ok:false,agent_started:false,path:$p,branch:"fix",issue:"app-1",space:"sp1",desk:"t9",target:"pr:12"}' >"$XDG_STATE_HOME/bercail/handoffs.jsonl"
  out="$(request | task dispatch 2>&1)" && fail "$out"
  [[ "$out" == *"original owner missing/stale"* ]] || fail "$out"
  ! grep -q '^spawn ' "$LOG" || fail "a refused adoption spawned: $(cat "$LOG")"
}

@test "an adoption names the staged change the person has not reviewed, and leaves it staged" {
  local out
  orphan
  echo draft >"$REPO.fix/draft.txt"
  git -C "$REPO.fix" add draft.txt
  out="$(request | task dispatch)" || fail "$out"
  jq -e '.adopted.staged == 1 and (.warning | contains("It holds 1 staged file the person has not reviewed"))' <<<"$out" || fail "$out"
  jq -e '.metadata.bercail_task.adoptions[0].staged == 1' "$TASK_DATA/app-1.json"
  [[ "$(git -C "$REPO.fix" diff --cached --name-only)" == draft.txt ]]
}

@test "an adoptReason, when Shep has one, is the reason recorded" {
  local out
  orphan
  out="$(adopt | task dispatch)" || fail "$out"
  jq -e '.adopted.reason == "desk t9 exited; Simon asked to update the PR"' <<<"$out" || fail "$out"
  grep -q -- '--adopt-reason desk t9 exited; Simon asked to update the PR$' "$LOG"
  jq -e '.metadata.bercail_task.adoptions[0].reason == "desk t9 exited; Simon asked to update the PR"' "$TASK_DATA/app-1.json"
}

@test "--wait-ready returns once the new desk's Pi claims its session, with the message queued there" {
  local out record="$XDG_STATE_HOME/bercail/desk-sessions/t10.json"
  orphan
  # The new desk's Pi writes its record a moment after the spawn returns.
  mv "$record" "$BATS_TEST_TMPDIR/t10.json"
  export TASK_LATE="$BATS_TEST_TMPDIR/t10.json"
  out="$(request | task dispatch --wait-ready)" || fail "$out"
  jq -e '.status == "queued" and .ready and .owner.desk == "t10" and .owner.session == "s2" and .creation.desk == "t10" and .adopted.from[0].desk == "t9" and (has("retry") | not)' <<<"$out" || fail "$out"
  [[ "$(find "$XDG_STATE_HOME/bercail/desk-follow-ups/t10" -name '*.json' | wc -l)" == 1 ]]
  grep -q '"id":"r1"' "$XDG_STATE_HOME/bercail/desk-follow-ups/t10/"*.json
  # Its answer was lost: the retry finds the queued message and says again what was adopted.
  out="$(request | task dispatch --wait-ready)" || fail "$out"
  jq -e '.status == "queued" and .retry and .owner.desk == "t10" and (.warning | startswith("Adopted: desk t9 is gone"))' <<<"$out" || fail "$out"
  [[ "$(find "$XDG_STATE_HOME/bercail/desk-follow-ups/t10" -name '*.json' | wc -l)" == 1 ]]
  [[ "$(grep -c '^spawn ' "$LOG")" == 1 ]]
}

@test "--wait-ready keeps the adoption's answer when the new desk cannot take the message" {
  local out record="$XDG_STATE_HOME/bercail/desk-sessions/t10.json"
  orphan
  jq '.start_ticks="stale"' "$record" >"$BATS_TEST_TMPDIR/r" && mv "$BATS_TEST_TMPDIR/r" "$record"
  out="$(request | task dispatch --wait-ready)" || fail "$out"
  jq -e '.status == "started" and .ready == false and .creation.desk == "t10" and .adopted.from[0].desk == "t9" and (.warning | startswith("Adopted:")) and (.next | contains("not queued: stale process for t10"))' <<<"$out" || fail "$out"
  [[ ! -d "$XDG_STATE_HOME/bercail/desk-follow-ups/t10" ]]
}

@test "--wait-ready gives up after a minute with the desk started and how to finish" {
  local out clock="$BATS_TEST_TMPDIR/clock.mjs"
  orphan
  rm "$XDG_STATE_HOME/bercail/desk-sessions/t10.json"
  # Each read of the clock is 30 s later, so the minute passes at once.
  printf 'let now = 0;\nDate.now = () => (now += 30000);\n' >"$clock"
  out="$(request | NODE_OPTIONS="--import=$clock" task dispatch --wait-ready)" || fail "$out"
  jq -e '.status == "started" and .ready == false and (.next | contains("retry this requestId once it is up"))' <<<"$out" || fail "$out"
  [[ ! -d "$XDG_STATE_HOME/bercail/desk-follow-ups/t10" ]]
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

@test "an adopting desk inherits no earlier follow-up from the gone owner" {
  local out
  request | task dispatch >/dev/null
  orphan
  out="$(adopt r2 | task dispatch)" || fail "$out"
  jq -e '.status == "started"' <<<"$out"
  adopt r2 | task dispatch >/dev/null
  out="$(request | task dispatch)" || fail "$out"
  jq -e '.status == "queued" and .owner.desk == "t9" and .retry' <<<"$out" || fail "$out"
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

@test "a retry of the creation an adoption replaced is refused, and never reaches the adopting desk" {
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
  # r0's answer is lost before its retry queues anything.
  request r0 | jq '.branch="fix"' | task dispatch >/dev/null
  orphan
  adopt r1 | task dispatch >/dev/null
  adopt r1 | task dispatch >/dev/null
  out="$(request r0 | jq '.branch="fix"' | task dispatch 2>&1)" && fail "$out"
  [[ "$out" == *"request r0 is retired"* ]] || fail "$out"
  ! grep -rq '"id":"r0"' "$XDG_STATE_HOME/bercail/desk-follow-ups/t10" || fail "r0 went to the adopting desk"
}

# The record as v0.17 saved it, with request $1 at status $2.
v017_record() {
  jq --arg repo "$(realpath "$REPO")" --arg id "$1" --arg s "$2" '.metadata.bercail_task={v:1,repo:$repo,target:"pr:12",owner:null,branch:"fix",
    requests:[{id:$id,sequence:0,payload:"hashed the v0.17 way",outcome:"publish",stage:"autopilot",message:"Amend with gt m -a and publish the new head",status:$s,next:"Retry this requestId"}]}' \
    "$TASK_DATA/app-1.json" >"$BATS_TEST_TMPDIR/issue"
  mv "$BATS_TEST_TMPDIR/issue" "$TASK_DATA/app-1.json"
}

@test "a v0.17 UNKNOWN creation still stops an adoption" {
  local out
  orphan
  v017_record lost-spawn unknown
  out="$(adopt r1 | task dispatch 2>&1)" && fail "$out"
  [[ "$out" == *"creation outcome UNKNOWN"* ]] || fail "$out"
  ! grep -q '^spawn ' "$LOG" || fail "an UNKNOWN creation was replaced: $(cat "$LOG")"
}

@test "a v0.17 UNKNOWN creation is finished by a retry of its id, as its next says" {
  local out
  slow_launch
  create lost-spawn | jq '.stage="bstack"' | task dispatch >/dev/null 2>&1 && fail "the slow spawn should time out"
  jq '.metadata.bercail_task |= (del(.creation) | .v=1 | .requests=[{id:"lost-spawn",sequence:0,payload:"hashed the v0.17 way",outcome:"stage",stage:"bstack",message:"Amend with gt m -a and publish the new head",status:"unknown",next:"Retry this requestId"}])' \
    "$TASK_DATA/app-1.json" >"$BATS_TEST_TMPDIR/issue"
  mv "$BATS_TEST_TMPDIR/issue" "$TASK_DATA/app-1.json"
  out="$(create lost-spawn | task dispatch)" || fail "$out"
  jq -e '.retry and .status == "started" and .creation.desk == "t21"' <<<"$out" || fail "$out"
  jq -e '.metadata.bercail_task | (has("requests") | not) and .creation.id == "lost-spawn"' "$TASK_DATA/app-1.json"
}

@test "a stray file among the desks' follow-up folders does not stop dispatch" {
  local out
  mkdir -p "$XDG_STATE_HOME/bercail/desk-follow-ups"
  touch "$XDG_STATE_HOME/bercail/desk-follow-ups/.DS_Store"
  out="$(request | task dispatch 2>&1)" || fail "$out"
  jq -e '.status == "queued" and .owner.desk == "t9"' <<<"$out"
}

@test "after a v0.17 adoption, the creation it blocked stays retired, also once the record is saved again" {
  local out
  orphan
  # As v0.17 left it: r0 started t9 and was never queued; r1 adopted the checkout on t10.
  jq --arg repo "$(realpath "$REPO")" --arg p "$(realpath "$REPO.fix")" '.metadata.bercail_task={v:1,repo:$repo,target:"pr:12",owner:null,branch:"fix",
    requests:[{id:"r0",sequence:0,payload:"v0.17",outcome:"stage",stage:"autopilot",message:"Amend with gt m -a and publish the new head",status:"blocked",
        reason:"original owner gone; its checkout was adopted by request r1, so this request did not move to the new session",creation:{desk:"t9",session:"s1",space:"sp1",path:$p}},
      {id:"r1",sequence:1,payload:"v0.17",outcome:"stage",stage:"autopilot",message:"Adopt",status:"awaiting-session",creation:{desk:"t10",session:"s2",space:"sp1",path:$p}}],
    adoptions:[{request:"r1",reason:"desk t9 exited",at:"2026-11-18T00:00:00Z",path:$p,branch:"fix",from:[{desk:"t9",session:"s1",space:"sp1"}]}]}' \
    "$TASK_DATA/app-1.json" >"$BATS_TEST_TMPDIR/issue"
  mv "$BATS_TEST_TMPDIR/issue" "$TASK_DATA/app-1.json"
  cp "$TASK_NEW" "$TASK_DATA/t10.hc"
  jq -c '. + {desk:"t10",session:"s2",adoptReason:"desk t9 exited"}' "$XDG_STATE_HOME/bercail/handoffs.jsonl" >>"$XDG_STATE_HOME/bercail/handoffs.jsonl"
  out="$(request r0 | task dispatch 2>&1)" && fail "$out"
  [[ "$out" == *"request r0 is retired"* ]] || fail "$out"
  out="$(request r2 | task dispatch)" || fail "$out"
  jq -e '.status == "queued" and .owner.desk == "t10"' <<<"$out" || fail "$out"
  jq -e '.metadata.bercail_task | (has("requests") | not) and .retired == ["r0"]' "$TASK_DATA/app-1.json"
  out="$(request r0 | task dispatch 2>&1)" && fail "$out"
  [[ "$out" == *"request r0 is retired"* ]] || fail "after the save: $out"
  ! grep -rq '"id":"r0"' "$XDG_STATE_HOME/bercail/desk-follow-ups/t10" || fail "r0 went to the adopting desk"
}

@test "a retry of v0.17 work matches on its message and stage, since its payload was hashed another way" {
  local out file
  # A v0.17 follow-up file for r1: the same hash in its name, a payload of the old kind.
  request | task dispatch >/dev/null
  file="$(find "$XDG_STATE_HOME/bercail/desk-follow-ups" -name '*.json')"
  jq -c '.v=1 | .request.payload="v0.17" | .request.outcome="publish"' "$file" >"$BATS_TEST_TMPDIR/f"
  mv "$BATS_TEST_TMPDIR/f" "$file"
  out="$(request | task dispatch)" || fail "$out"
  jq -e '.status == "queued" and .retry and .owner.desk == "t9"' <<<"$out" || fail "$out"
  out="$(request | jq '.message="something else"' | task dispatch 2>&1)" && fail "$out"
  [[ "$out" == *"payload changed"* ]] || fail "$out"
  # A v0.17 creation that started: a changed message is not its retry either.
  v017_record r5 awaiting-session
  out="$(request r5 | jq '.message="something else"' | task dispatch 2>&1)" && fail "$out"
  [[ "$out" == *"payload changed"* ]] || fail "$out"
  [[ "$(find "$XDG_STATE_HOME/bercail/desk-follow-ups" -name '*.json' | wc -l)" == 1 ]]
}

@test "a v0.17 creation blocked by hand before an adoption is not sent to the adopting desk" {
  local out
  orphan
  # task block left its own reason on r0, so the v0.17 adoption skipped it.
  jq --arg repo "$(realpath "$REPO")" --arg p "$(realpath "$REPO.fix")" '.metadata.bercail_task={v:1,repo:$repo,target:"pr:12",owner:null,branch:"fix",
    requests:[{id:"r0",sequence:0,payload:"v0.17",outcome:"stage",stage:"autopilot",message:"Amend with gt m -a and publish the new head",status:"blocked",
        reason:"do not run without the original backend",next:"await direction",creation:{desk:"t9",session:"s1",space:"sp1",path:$p}},
      {id:"r1",sequence:1,payload:"v0.17",outcome:"stage",stage:"autopilot",message:"Adopt",status:"awaiting-session",creation:{desk:"t10",session:"s2",space:"sp1",path:$p}}],
    adoptions:[{request:"r1",reason:"desk t9 exited",at:"2026-11-18T00:00:00Z",path:$p,branch:"fix",from:[{desk:"t9",session:"s1",space:"sp1"}]}]}' \
    "$TASK_DATA/app-1.json" >"$BATS_TEST_TMPDIR/issue"
  mv "$BATS_TEST_TMPDIR/issue" "$TASK_DATA/app-1.json"
  cp "$TASK_NEW" "$TASK_DATA/t10.hc"
  jq -c '. + {desk:"t10",session:"s2",adoptReason:"desk t9 exited"}' "$XDG_STATE_HOME/bercail/handoffs.jsonl" >>"$XDG_STATE_HOME/bercail/handoffs.jsonl"
  out="$(request r0 | task dispatch 2>&1)" && fail "$out"
  [[ "$out" == *"request r0 is retired"* ]] || fail "$out"
  [[ ! -d "$XDG_STATE_HOME/bercail/desk-follow-ups/t10" ]] || fail "r0 went to the adopting desk"
}

@test "a follow-up saved for its owner but not yet queued is retired by an adoption, and a plain retry queues it" {
  local out dir="$XDG_STATE_HOME/bercail/desk-follow-ups"
  mkdir -p "$dir"
  touch "$dir/t9" # a file where t9's folder goes: the write fails after the save
  out="$(request half | task dispatch 2>&1)" && fail "$out"
  jq -e '.status == "in_progress" and .metadata.bercail_task.owner.session == "s1"' "$TASK_DATA/app-1.json"
  rm "$dir/t9"
  out="$(request half | jq '.message="different work, same id"' | task dispatch 2>&1)" && fail "$out"
  [[ "$out" == *"payload changed"* ]] || fail "a changed retry: $out"
  [[ ! -d "$dir/t9" ]] || fail "the changed retry was queued"
  out="$(request constructor | task dispatch)" || fail "a new id is not a retry of pending work: $out"
  jq -e '.status == "queued" and .owner.desk == "t9"' <<<"$out"
  out="$(request half | task dispatch)" || fail "the same desk takes its retry: $out"
  jq -e '.status == "queued" and .owner.desk == "t9"' <<<"$out"
  # Again for another follow-up, then t9 is gone and t10 adopts its checkout.
  mv "$dir/t9" "$BATS_TEST_TMPDIR/t9-queue"
  touch "$dir/t9"
  out="$(request lost | task dispatch 2>&1)" && fail "$out"
  rm "$dir/t9"
  mv "$BATS_TEST_TMPDIR/t9-queue" "$dir/t9"
  orphan
  adopt r1 | task dispatch >/dev/null
  out="$(request lost | task dispatch 2>&1)" && fail "$out"
  [[ "$out" == *"request lost is retired"* ]] || fail "$out"
  ! grep -rq '"id":"lost"' "$dir/t10" 2>/dev/null || fail "lost went to the adopting desk"
}

@test "an issue closed while a follow-up is queued stays closed" {
  local out
  export TASK_CLOSE_ONCE_QUEUED=1
  out="$(request | task dispatch)" || fail "$out"
  jq -e '.status == "queued" and .owner.desk == "t9"' <<<"$out"
  [[ -e "$TASK_DATA/closed-once" ]] || fail "the close did not happen"
  jq -e '.status == "closed" and (.metadata.bercail_task | has("pending") | not)' "$TASK_DATA/app-1.json" || fail "$(cat "$TASK_DATA/app-1.json")"
  [[ "$(grep -c -- '--status in_progress' "$LOG")" == 1 ]] || fail "$(cat "$LOG")"
}

@test "a follow-up dispatched later goes after the earlier one, even when the clock went back" {
  local clock="$BATS_TEST_TMPDIR/clock.mjs" file order
  printf 'Date.now = () => Number(process.env.TASK_CLOCK);\n' >"$clock"
  request earlier | TASK_CLOCK=1795114321000 NODE_OPTIONS="--import=$clock" task dispatch >/dev/null
  request later | TASK_CLOCK=1795114320000 NODE_OPTIONS="--import=$clock" task dispatch >/dev/null
  # The desk takes its files in name order.
  order="$(for file in "$XDG_STATE_HOME/bercail/desk-follow-ups/t9"/*.json; do jq -r '.request.id' "$file"; done)"
  [[ "$order" == $'earlier\nlater' ]] || fail "the desk would take: ${order//$'\n'/, }"
}

# A bstack job on its own target, task:app-1. Its first dispatch queues to t9,
# whose handoff the setup records, so the task names t9 its owner.
job() {
  jq -nc --arg repo "$REPO" --arg id "${1:-r1}" '{repo:$repo,issue:"app-1",target:"task:app-1",requestId:$id,stage:"bstack",message:"Build the login"}'
}

# bercail cleanup retired $REPO.fix: desk t9 and its Pi ended, the worktree
# went, branch fix stayed, and retired.jsonl says so, after t9's handoff.
retire_fix() {
  kill "$PID" && wait "$PID" 2>/dev/null || true
  PID=
  rm "$TASK_DATA/t9.hc"
  git -C "$REPO" worktree remove --force "$REPO.fix"
  jq -nc --arg at "$(date -u -d '-1 minute' +%Y-%m-%dT%H:%M:%SZ)" --arg p "$REPO.fix" --arg r "$REPO" \
    '{v:1,at:$at,path:$p,repo:$r,branch:"fix"}' >>"$XDG_STATE_HOME/bercail/retired.jsonl"
}

# A handoff-spawn that starts desk t10 (session s2, space sp1) in a new
# worktree $REPO.<branch>, on the branch as it is when it exists, and logs the
# handoff with its time, as handoff-spawn does.
spawn_new() {
  export BERCAIL_HANDOFF_SPAWN="$BATS_TEST_TMPDIR/bin/spawn" TASK_REPO="$REPO"
  cat >"$BERCAIL_HANDOFF_SPAWN" <<'SPAWN'
#!/usr/bin/env bash
printf 'spawn %s\n' "$*" >>"$LOG"
while (($#)); do [[ $1 != --branch ]] || branch="$2"; shift; done
wt="$TASK_REPO.$branch"
git -C "$TASK_REPO" worktree add -q "$wt" "$branch" 2>/dev/null || git -C "$TASK_REPO" worktree add -qb "$branch" "$wt"
jq -n --arg cwd "$wt" '{address:"t10",cwd:$cwd,state:"live",labels:{"bercail.role":"agent","bercail.issue":"app-1","bercail.space":"sp1"}}' >"$TASK_DATA/t10.hc"
jq -nc --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg p "$wt" --arg b "$branch" \
  '{at:$at,ok:true,agent_started:true,path:$p,branch:$b,space:"sp1",desk:"t10",session:"s2",issue:"app-1",target:"task:app-1"}' \
  | tee -a "$XDG_STATE_HOME/bercail/handoffs.jsonl"
SPAWN
  chmod +x "$BERCAIL_HANDOFF_SPAWN"
}

@test "a task whose checkout bercail cleanup retired gets a new desk on a new branch" {
  local out
  spawn_new
  job | task dispatch >/dev/null || fail "first dispatch"
  retire_fix
  out="$(job r2 | jq '.branch="next"' | task dispatch)" || fail "$out"
  jq -e --arg p "$REPO.next" '.status == "started" and .creation.desk == "t10" and .creation.path == $p' <<<"$out" || fail "$out"
  grep -q -- '^spawn --branch next ' "$LOG" || fail "$(cat "$LOG")"
  ! grep -q -- '--existing-branch' "$LOG" || fail "a new branch is cut: $(cat "$LOG")"
  jq -e '.metadata.bercail_task | .owner == null and .branch == "next" and .creation.id == "r2"' "$TASK_DATA/app-1.json" \
    || fail "$(jq .metadata "$TASK_DATA/app-1.json")"
}

@test "a task whose checkout bercail cleanup retired starts again on its kept branch, and follow-ups reach only the new desk" {
  local out
  spawn_new
  job | task dispatch >/dev/null || fail "first dispatch"
  retire_fix
  out="$(job r2 | task dispatch)" || fail "$out"
  jq -e '.status == "started" and .creation.desk == "t10" and .creation.branch == "fix"' <<<"$out" || fail "$out"
  grep -q -- '^spawn --branch fix .*--existing-branch' "$LOG" || fail "the kept branch, as it is: $(cat "$LOG")"
  # The new desk's Pi comes up in the new checkout, at the old one's path.
  start_pi PID
  TICKS="$(awk '{print $22}' "/proc/$PID/stat")"
  owner t10 s2
  out="$(job r2 | task dispatch)" || fail "$out"
  jq -e '.status == "queued" and .owner.desk == "t10" and .owner.session == "s2"' <<<"$out" || fail "$out"
  out="$(job r3 | task dispatch)" || fail "$out"
  jq -e '.status == "queued" and .owner.desk == "t10"' <<<"$out" || fail "$out"
  [[ "$(find "$XDG_STATE_HOME/bercail/desk-follow-ups/t9" -name '*.json' | wc -l)" == 1 ]] || fail "t9 keeps only r1"
  [[ "$(find "$XDG_STATE_HOME/bercail/desk-follow-ups/t10" -name '*.json' | wc -l)" == 2 ]] || fail "t10 gets r2 and r3"
  [[ "$(grep -c '^spawn ' "$LOG")" == 1 ]]
}

@test "a checkout gone some other way still refuses, and the refusal names the command that retires it" {
  local out
  spawn_new
  jq -c '.at = "2026-11-20T10:00:00Z"' "$XDG_STATE_HOME/bercail/handoffs.jsonl" >"$BATS_TEST_TMPDIR/h"
  mv "$BATS_TEST_TMPDIR/h" "$XDG_STATE_HOME/bercail/handoffs.jsonl"
  job | task dispatch >/dev/null || fail "first dispatch"
  kill "$PID" && wait "$PID" 2>/dev/null || true
  PID=
  rm "$TASK_DATA/t9.hc"
  rm -rf "$REPO.fix"
  git -C "$REPO" worktree prune
  out="$(job r2 | task dispatch 2>&1)" && fail "$out"
  [[ "$out" == *"the checkout $REPO.fix of desk t9 is gone, and bercail cleanup did not retire it"*"run it alone (the guard asks the person on a Decisions card, or runs it where the repo's shep_may_run lists cleanup): bercail cleanup --gone '$REPO.fix'"* ]] \
    || fail "$out"
  # A retirement of that path before t9's handoff is of an earlier checkout,
  # and one in the same second cannot say which came first.
  for at in 2026-11-19T10:00:00Z 2026-11-20T10:00:00Z; do
    jq -nc --arg p "$REPO.fix" --arg at "$at" '{v:1,at:$at,path:$p,branch:"fix"}' >"$XDG_STATE_HOME/bercail/retired.jsonl"
    out="$(job r2 | task dispatch 2>&1)" && fail "$at: $out"
    [[ "$out" == *"bercail cleanup did not retire it"* ]] || fail "$at: $out"
  done
  printf '{"path":\n' >>"$XDG_STATE_HOME/bercail/retired.jsonl"
  out="$(job r2 | task dispatch 2>&1)" && fail "$out"
  [[ "$out" == *"malformed line in $XDG_STATE_HOME/bercail/retired.jsonl"* ]] || fail "$out"
  sed -i '$d' "$XDG_STATE_HOME/bercail/retired.jsonl"
  ! grep -q '^spawn ' "$LOG" || fail "a refusal spawned: $(cat "$LOG")"
  "$ROOT/bin/bercail" cleanup --gone "$REPO.fix" || fail "cleanup --gone"
  out="$(job r2 | task dispatch)" || fail "$out"
  jq -e '.status == "started" and .creation.desk == "t10"' <<<"$out" || fail "$out"
}

@test "a retry of a creation after cleanup that left no desk checks out the kept branch again" {
  local out
  spawn_new
  job | task dispatch >/dev/null || fail "first dispatch"
  retire_fix
  mv "$BERCAIL_HANDOFF_SPAWN" "$BATS_TEST_TMPDIR/spawn.ok"
  printf '#!/bin/sh\nprintf "spawn %%s\\n" "$*" >>"$LOG"\nexit 1\n' >"$BERCAIL_HANDOFF_SPAWN"
  chmod +x "$BERCAIL_HANDOFF_SPAWN"
  out="$(job r2 | task dispatch 2>&1)" && fail "a failed spawn passed: $out"
  jq -e '.metadata.bercail_task.creation | .id == "r2" and .status == "unknown"' "$TASK_DATA/app-1.json" || fail "$(jq .metadata "$TASK_DATA/app-1.json")"
  mv "$BATS_TEST_TMPDIR/spawn.ok" "$BERCAIL_HANDOFF_SPAWN"
  out="$(job r2 | task dispatch)" || fail "$out"
  jq -e '.status == "started" and .creation.desk == "t10" and .creation.branch == "fix"' <<<"$out" || fail "$out"
  [[ "$(grep -c -- '^spawn --branch fix .*--existing-branch' "$LOG")" == 2 ]] || fail "$(cat "$LOG")"
}

@test "a job with no task record whose checkout cleanup retired starts again on the branch its handoff names" {
  local out
  spawn_new
  retire_fix
  out="$(job | task dispatch)" || fail "$out"
  jq -e '.status == "started" and .creation.branch == "fix"' <<<"$out" || fail "$out"
  grep -q -- '^spawn --branch fix .*--existing-branch' "$LOG" || fail "$(cat "$LOG")"
}

@test "a follow-up saved for a desk cleanup retired is not sent again as the new desk's first request" {
  local out dir="$XDG_STATE_HOME/bercail/desk-follow-ups"
  spawn_new
  mkdir -p "$dir"
  touch "$dir/t9" # a file where t9's folder goes: the write fails after the save
  out="$(job half | task dispatch 2>&1)" && fail "$out"
  rm "$dir/t9"
  retire_fix
  out="$(job half | task dispatch 2>&1)" && fail "$out"
  [[ "$out" == *"request half was for desk t9, gone with its retired checkout"* ]] || fail "$out"
  ! grep -q '^spawn ' "$LOG" || fail "$(cat "$LOG")"
  out="$(job r2 | task dispatch)" || fail "$out"
  jq -e '.status == "started" and .creation.desk == "t10"' <<<"$out" || fail "$out"
  jq -e '.metadata.bercail_task | .creation.id == "r2" and (.retired | index("half")) and (has("pending") | not)' "$TASK_DATA/app-1.json" || fail "$(jq .metadata "$TASK_DATA/app-1.json")"
}

# The issue, every entry under bercail's state with each file's contents, and
# each checkout's git index, as they are now, to show a dry run left them.
snapshot() {
  jq -S . "$TASK_DATA/app-1.json"
  find "$XDG_STATE_HOME/bercail" | sort
  find "$XDG_STATE_HOME/bercail" -type f -exec sha256sum {} + | sort
  find "$REPO/.git" -name index -exec sha256sum {} + | sort
}

@test "--dry-run names the live owner a follow-up would reach, and queues and records nothing" {
  local out before
  before="$(snapshot)"
  out="$(request | task dispatch --dry-run)" || fail "$out"
  jq -e '.dry_run and .status == "would-queue" and .owner.desk == "t9" and .owner.session == "s1" and .authority == false and (has("path") | not)' <<<"$out" || fail "$out"
  [[ "$(snapshot)" == "$before" ]] || fail "the dry run changed state"
  ! grep -q '^bd update' "$LOG" || fail "$(cat "$LOG")"
  [[ ! -e "$REPO/.git/bercail-task.lock" ]]
}

@test "--dry-run says which desk, branch and adoption a real run would start, and starts none" {
  local out before
  orphan
  echo draft >"$REPO.fix/draft.txt"
  git -C "$REPO.fix" add draft.txt
  before="$(snapshot)"
  out="$(request | task dispatch --dry-run)" || fail "$out"
  jq -e '.dry_run and .status == "would-start" and .branch == "fix" and (.spawn | index("--adopt-reason")) and .adopted.from[0].desk == "t9" and .adopted.staged == 1 and (.warning | startswith("Adopted: desk t9 is gone"))' <<<"$out" || fail "$out"
  [[ "$(snapshot)" == "$before" ]] || fail "the dry run changed state"
  ! grep -Eq '^(spawn |bd update)' "$LOG" || fail "$(cat "$LOG")"
  out="$(request | task dispatch)" || fail "$out"
  jq -e '.status == "started" and .creation.desk == "t10"' <<<"$out" || fail "$out"
}

@test "--dry-run of a first desk gives the handoff-spawn argv, and of an UNKNOWN creation's retry finishes nothing" {
  local out before
  slow_launch
  before="$(snapshot)"
  out="$(create | task dispatch --dry-run)" || fail "$out"
  jq -e '.dry_run and .status == "would-start" and .branch == "fresh" and .spawn[0:4] == ["--branch","fresh","--stage","bstack"]' <<<"$out" || fail "$out"
  [[ "$(snapshot)" == "$before" ]] || fail "the dry run changed state"
  create | task dispatch >/dev/null 2>&1 && fail "the slow spawn should time out"
  # A stat change git status would write back to the worktree's index.
  touch -d '-1 hour' "$REPO.fresh/file.txt"
  before="$(snapshot)"
  out="$(create | task dispatch --dry-run)" || fail "$out"
  jq -e '.dry_run and .status == "would-start" and .retry and (.spawn | index("--reuse-worktree"))' <<<"$out" || fail "$out"
  [[ "$(snapshot)" == "$before" ]] || fail "the dry run changed state"
  jq -e '.metadata.bercail_task.creation.status == "unknown"' "$TASK_DATA/app-1.json"
  [[ "$(grep -c '^spawn ' "$LOG")" == 1 ]]
}

@test "--dry-run refuses what a real run refuses, with the same words" {
  local dry real before lock="$REPO/.git/bercail-task.lock"
  owner t8 s2
  before="$(snapshot)"
  dry="$(request | task dispatch --dry-run 2>&1)" && fail "$dry"
  [[ "$(snapshot)" == "$before" ]] || fail "the dry run changed state"
  real="$(request | task dispatch 2>&1)" && fail "$real"
  [[ "$dry" == *"ambiguous owners t8, t9"* && "$dry" == "$real" ]] || fail "dry: $dry; real: $real"
  rm "$TASK_DATA/t8.hc"
  # Another dispatch's lock, and a dangling link where it goes: mkdir fails on both.
  for held in dir link; do
    if [[ $held == dir ]]; then mkdir "$lock"; else ln -s "$BATS_TEST_TMPDIR/nowhere" "$lock"; fi
    dry="$(request | task dispatch --dry-run 2>&1)" && fail "$held: $dry"
    real="$(request | task dispatch 2>&1)" && fail "$held: $real"
    [[ "$dry" == *"dispatch lock held"* && "$dry" == "$real" ]] || fail "$held: dry: $dry; real: $real"
    [[ -L "$lock" || -d "$lock" ]] || fail "the dry run removed another dispatch's lock"
    rm -r "$lock"
  done
  [[ ! -d "$XDG_STATE_HOME/bercail/desk-follow-ups" ]]
}

on_model() { create "${2:-r1}" | jq --arg m "${1:-openai/gpt-6.2-astra}" '.model=$m'; }

# handoff-spawn's --check-model knows only openai/gpt-6.2-astra, as a Pi listing
# that one would; every other call goes to the spawn stand-in already set.
lists_astra() {
  mv "$BERCAIL_HANDOFF_SPAWN" "$BERCAIL_HANDOFF_SPAWN-desk"
  cat >"$BERCAIL_HANDOFF_SPAWN" <<'EOF'
#!/usr/bin/env bash
[[ $1 == --check-model ]] || exec "$0-desk" "$@"
printf 'check %s\n' "$2" >>"$LOG"
[[ $2 == openai/gpt-6.2-astra ]] || { echo "handoff-spawn: Pi has no model $2. pi --list-models lists the ones you can use." >&2; exit 1; }
EOF
  chmod +x "$BERCAIL_HANDOFF_SPAWN"
}

@test "a first desk starts on the model dispatch names, the issue records it, and a retry of its UNKNOWN creation keeps it" {
  local out
  slow_launch
  lists_astra
  out="$(on_model | task dispatch --dry-run)" || fail "$out"
  jq -e '.status == "would-start" and (.spawn | index(["--model","openai/gpt-6.2-astra"]))' <<<"$out" || fail "$out"
  on_model | task dispatch >/dev/null 2>&1 && fail "the slow spawn should time out"
  jq -e '.metadata.bercail_task.creation | .status == "unknown" and .model == "openai/gpt-6.2-astra"' "$TASK_DATA/app-1.json" || fail "$(jq .metadata "$TASK_DATA/app-1.json")"
  out="$(create | task dispatch 2>&1)" && fail "$out"
  [[ "$out" == *"requestId payload changed"* ]] || fail "a retry without the model is other work: $out"
  out="$(on_model | task dispatch)" || fail "$out"
  jq -e '.status == "started" and .retry' <<<"$out" || fail "$out"
  [[ "$(grep -c -- '^spawn --branch fresh --stage bstack .*--model openai/gpt-6.2-astra' "$LOG")" == 2 ]] || fail "$(cat "$LOG")"
}

@test "a model Pi does not list is refused before the creation is recorded, so the same id can name the right one" {
  local out dry before
  rm "$TASK_DATA/t9.hc" "$XDG_STATE_HOME/bercail/handoffs.jsonl"
  spawn_ok t21 "$REPO.fresh"
  lists_astra
  before="$(snapshot)"
  dry="$(on_model openai/gpt-6.2-astro | task dispatch --dry-run 2>&1)" && fail "$dry"
  [[ "$(snapshot)" == "$before" ]] || fail "the dry run changed state"
  out="$(on_model openai/gpt-6.2-astro | task dispatch 2>&1)" && fail "$out"
  [[ "$out" == *"Pi has no model openai/gpt-6.2-astro."* && "$dry" == "$out" ]] || fail "dry: $dry; real: $out"
  ! grep -q '^spawn ' "$LOG" || fail "$(cat "$LOG")"
  jq -e '.metadata.bercail_task | has("creation") | not' "$TASK_DATA/app-1.json" || fail "$(jq .metadata "$TASK_DATA/app-1.json")"
  out="$(on_model | task dispatch)" || fail "$out"
  jq -e '.status == "started" and .creation.desk == "t21"' <<<"$out" || fail "$out"
  grep -q -- '^spawn --branch fresh .*--model openai/gpt-6.2-astra' "$LOG" || fail "$(cat "$LOG")"
}

@test "a retry of a v0.17 creation that adds a model is other work, since v0.17 had none" {
  local out
  slow_launch
  create lost-spawn | task dispatch >/dev/null 2>&1 && fail "the slow spawn should time out"
  jq '.metadata.bercail_task |= (del(.creation) | .v=1 | .requests=[{id:"lost-spawn",sequence:0,payload:"hashed the v0.17 way",outcome:"stage",stage:"bstack",message:"Amend with gt m -a and publish the new head",status:"unknown",next:"Retry this requestId"}])' \
    "$TASK_DATA/app-1.json" >"$BATS_TEST_TMPDIR/issue"
  mv "$BATS_TEST_TMPDIR/issue" "$TASK_DATA/app-1.json"
  out="$(on_model openai/gpt-6.2-astra lost-spawn | task dispatch --dry-run 2>&1)" && fail "$out"
  [[ "$out" == *"requestId payload changed"* ]] || fail "$out"
}

@test "a follow-up to a live desk refuses a model and names bercail desk model, in a dry run too" {
  local out dry
  out="$(request | jq '.model="openai/gpt-6.2-astra"' | task dispatch 2>&1)" && fail "$out"
  [[ "$out" == *"desk t9 is live, and a follow-up runs on its model; switch it with bercail desk model t9 openai/gpt-6.2-astra"* ]] || fail "$out"
  dry="$(request | jq '.model="openai/gpt-6.2-astra"' | task dispatch --dry-run 2>&1)" && fail "$dry"
  [[ "$dry" == "$out" ]] || fail "dry: $dry; real: $out"
  [[ ! -d "$XDG_STATE_HOME/bercail/desk-follow-ups" ]]
  ! grep -q '^bd update' "$LOG" || fail "$(cat "$LOG")"
  out="$(request | jq '.model="gpt-6.2-astra"' | task dispatch 2>&1)" && fail "$out"
  [[ "$out" == *"model takes PROVIDER/MODEL[:thinking]"* ]] || fail "$out"
}
