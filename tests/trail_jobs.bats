#!/usr/bin/env bats
# shellcheck disable=SC2088 # the expected output has literal ~/ paths
# Trails as jobs in an Entire repo: trail:N wherever a beads id goes. A
# stand-in entire keeps trails as JSON files; hc, handoff-spawn and Pi are
# stand-ins too; real git; a temp HOME.

setup() {
  load test_helper
  isolate
  need node
  set -o pipefail
  unset HC_BIN BERCAIL_HANDOFF_SPAWN BERCAIL_ROLE
  export ENTIRE_BIN="$BATS_TEST_TMPDIR/bin/entire"
  export HERDR_APP_BIN="$BATS_TEST_TMPDIR/no-herdr-app" BERCAIL_SHEP_QUEUE_WAIT=120
  export PATH="$BATS_TEST_TMPDIR/bin:/usr/bin:/bin"
  export LOG="$BATS_TEST_TMPDIR/log" TRAILS="$BATS_TEST_TMPDIR/trails" HC_DATA="$BATS_TEST_TMPDIR/hc"
  mkdir -p "$TRAILS" "$HC_DATA" "$HOME/Work" "$XDG_STATE_HOME/bercail/shep"
  printf '{"terminals":[]}\n' >"$HC_DATA/ls.json"
  : >"$LOG"
  REPO="$HOME/Work/app"
  git init -q -b main "$REPO"
  git -C "$REPO" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
  git -C "$REPO" config user.name Simon
  git -C "$REPO" remote add origin entire://entire.example/et/proj/app
  REPO="$(cd "$REPO" && pwd -P)"
  printf '%s\n' "$REPO" >"$XDG_STATE_HOME/bercail/shep/repos"

  # entire: trails are $TRAILS/<n>.json, each scoped to .repo (app by default);
  # a repo of another project than et/proj has its own, in $TRAILS.<project>.
  # It refuses comments, as it does in an agent session, and a list without
  # --project, as the real one does. A list gives $PAGE trails a page.
  cat >"$BATS_TEST_TMPDIR/bin/entire" <<'EOF'
#!/usr/bin/env bash
printf 'entire %s\n' "$*" >>"$LOG"
[[ -z "${ENTIRE_DOWN:-}" ]] || { echo "dial tcp: network is unreachable" >&2; exit 1; }
flag() { local want="$1"; shift; while (($#)); do [[ "$1" == "$want" ]] && { printf '%s' "$2"; return; }; shift; done; }
proj="$(git remote get-url origin 2>/dev/null | cut -d/ -f5)"
[[ "${proj:-proj}" == proj ]] || TRAILS="$TRAILS.$proj"
case "$1 $2" in
  "trail show")
    [[ -f "$TRAILS/$3.json" ]] || { echo "project trail #$3 not found in et/proj" >&2; exit 1; }
    cat "$TRAILS/$3.json" ;;
  "trail list")
    [[ "$(flag --project "$@")" == "et/${proj:-proj}" ]] || { echo "--project is required" >&2; exit 1; }
    [[ -z "${ENTIRE_SHAPE:-}" ]] || { echo "$ENTIRE_SHAPE"; exit 0; }
    shopt -s nullglob; files=("$TRAILS"/[0-9]*.json); at="$(flag --page-token "$@")"
    jq -s --arg s "$(flag --status "$@")" --arg r "$(flag --repo "$@")" --argjson at "${at:-0}" \
      --argjson page "${PAGE:-100}" '
      [.[] | (.repo // "app") as $mine | select(($s == "" or .status == $s) and ($r == "" or ($r | endswith("/" + $mine)))) | del(.changes)]
      | sort_by(-.number) | {items: .[$at:$at + $page], nextPageToken: (if length > $at + $page then "\($at + $page)" else null end)}' \
      "${files[@]}" /dev/null ;;
  "trail create")
    n=$(( $(find "$TRAILS" -name '*.json' | wc -l) + 1 ))
    jq -n --argjson n "$n" --arg t "$(flag --title "$@")" --arg b "$(flag --body "$@")" --arg type "$(flag --type "$@")" \
      '{number: $n, title: $t, body: $b, type: $type, priority: "none", status: "open", phase: "planning", repoIds: ["R-app"],
        url: "https://entire.example/et/proj/-/trails/\($n)", changes: []}' | tee "$TRAILS/$n.json" ;;
  "trail update")
    [[ -z "${UPDATE_DOWN:-}" ]] || { echo "dial tcp: network is unreachable" >&2; exit 1; }
    jq --arg s "$(flag --status "$@")" --arg b "$(flag --body "$@")" --argjson body "$([[ " $* " == *" --body "* ]] && echo true || echo false)" \
      'if $s != "" then .status = $s else . end | if $body then .body = $b else . end' "$TRAILS/$3.json" >"$TRAILS/tmp" && mv "$TRAILS/tmp" "$TRAILS/$3.json"
    cat "$TRAILS/$3.json" ;;
  "trail merge")
    # A change <repo>/<n>: merged, unless its gates hold it ($MERGE_HELD).
    [[ -z "${MERGE_HELD:-}" ]] || { echo "blocking gates pending: approvals" >&2; exit 1; }
    for f in "$TRAILS"/[0-9]*.json; do
      jq --arg c "$3" '.changes |= map(if "\(.repository)/\(.number)" == $c then .status = "merged" else . end)' "$f" >"$TRAILS/tmp" && mv "$TRAILS/tmp" "$f"
    done
    echo "Merged $3" ;;
  "repo view") echo "{\"id\":\"R-$(git remote get-url origin | awk -F/ '{print $NF}')\"}" ;;
  "trail comment") echo "refusing \`entire trail comment add\` from a Pi session: trail comments are for people" >&2; exit 1 ;;
  *) exit 2 ;;
esac
EOF
  # hc answers ls and get from $HC_DATA, the way bercail reads desks.
  cat >"$BATS_TEST_TMPDIR/bin/hc" <<'EOF'
#!/usr/bin/env bash
printf 'hc %s\n' "$*" >>"$LOG"
case "$1" in
  ls) cat "$HC_DATA/ls.json" ;;
  get) cat "$HC_DATA/$2.json" 2>/dev/null || { printf '{"error":{"kind":"not_found"}}\n'; exit 5; } ;;
  read) exit 5 ;;
  run) printf '%s\n' "$@" >"$HC_DATA/run"
       while (($#)); do [[ "$1" == --name ]] && name="$2"; shift; done
       printf '{"address":"t20","cwd":"/x","name":"%s"}\n' "$name" ;;
  *) exit 8 ;;
esac
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/"{entire,hc}
}

bercail() { "$ROOT/bin/bercail" "$@"; }

# A trail as entire keeps it: trail N TITLE STATUS PHASE [BODY] [REPO].
trail() {
  jq -n --argjson n "$1" --arg t "$2" --arg s "$3" --arg p "$4" --arg b "${5:-}" --arg r "${6:-app}" \
    '{number: $n, id: "T\($n)", title: $t, body: $b, type: "task", priority: "none", status: $s, phase: $p, repo: $r, repoIds: ["R-\($r)"],
      url: "https://entire.example/et/proj/-/trails/\($n)", changes: []}' >"$TRAILS/$1.json"
}

# A live desk for hc: desk ADDR CWD STATE ISSUE.
desk() {
  jq -n --arg a "$1" --arg cwd "$2" --arg s "$3" --arg i "$4" \
    '{address: $a, cwd: $cwd, state: "live", status: {app: "pi", state: $s},
      labels: {"bercail.role": "agent", "bercail.issue": $i, "bercail.space": "sp-new"}}' >"$HC_DATA/$1.json"
  jq --arg a "$1" --arg cwd "$2" '.terminals += [{address: $a, cwd: $cwd, state: "live"}]' "$HC_DATA/ls.json" >"$HC_DATA/ls.tmp"
  mv "$HC_DATA/ls.tmp" "$HC_DATA/ls.json"
}

# A handoff-spawn that starts desk t21 ($SPAWN_DESK) in a new worktree of the
# branch, as the real one reports it, and adds its handoff comment through bercail job.
spawn_ok() {
  export BERCAIL_HANDOFF_SPAWN="$BATS_TEST_TMPDIR/bin/spawn" ROOT REPO
  cat >"$BERCAIL_HANDOFF_SPAWN" <<'EOF'
#!/usr/bin/env bash
printf 'spawn %s\n' "$*" >>"$LOG"
while (($#)); do case "$1" in --issue) issue="$2" ;; --branch) branch="$2" ;; esac; shift; done
desk="${SPAWN_DESK:-t21}"
[[ -d "$REPO.$branch" ]] || git -C "$REPO" worktree add -q "$REPO.$branch" "$branch" 2>/dev/null \
  || git -C "$REPO" worktree add -qb "$branch" "$REPO.$branch"
printf 'bercail handoff: stage bstack, linked worktree %s' "$REPO.$branch" | "$ROOT/bin/bercail" job comment "$issue" --repo "$REPO.$branch" >/dev/null
jq -n --arg d "$desk" --arg p "$REPO.$branch" --arg i "$issue" '{address:$d,cwd:$p,state:"live",status:{app:"pi",state:"working"},
  labels:{"bercail.role":"agent","bercail.space":"sp-new","bercail.issue":$i}}' >"$HC_DATA/$desk.json"
jq --arg d "$desk" --arg cwd "$REPO.$branch" '.terminals += [{address: $d, cwd: $cwd, state: "live"}]' "$HC_DATA/ls.json" >"$HC_DATA/ls.tmp"
mv "$HC_DATA/ls.tmp" "$HC_DATA/ls.json"
jq -nc --arg d "$desk" --arg p "$REPO.$branch" --arg i "$issue" --arg b "$branch" \
  '{ok:true,agent_started:true,path:$p,branch:$b,space:"sp-new",desk:$d,session:"s-\($d)",issue:$i}' \
  | tee -a "$XDG_STATE_HOME/bercail/handoffs.jsonl"
EOF
  chmod +x "$BERCAIL_HANDOFF_SPAWN"
}

dispatch() {
  jq -nc --arg repo "$REPO" '{repo:$repo,target:"trail:1",requestId:"r1",stage:"bstack",message:"Do the research",branch:"login"}' \
    | jq -c "${1:-.}" | bercail shep task dispatch "${@:2}"
}

record_file() { printf '%s' "$XDG_STATE_HOME/bercail/jobs/app-$(printf '%s' "$REPO" | sha256sum | cut -c1-12)/$1"; }

@test "a trail goes from create to dispatch, report and close, and its job record stays on this machine" {
  local out
  spawn_ok
  # Shep creates the job as a trail with no branch.
  out="$(cd "$REPO" && entire trail create --no-branch --title "Research the login flow" --body "Find where the session expires." --type task --json)"
  jq -e '.number == 1 and .phase == "planning"' <<<"$out" >/dev/null || fail "create: $out"

  out="$(dispatch)" || fail "dispatch: $out"
  jq -e '.status == "started" and .creation.desk == "t21" and .creation.issue == "trail:1" and .authority == false' <<<"$out" >/dev/null \
    || fail "dispatch: $out"
  grep -q -- "^spawn --branch login --stage bstack --issue trail:1 --target trail:1 " "$LOG" || fail "spawn argv: $(cat "$LOG")"
  jq -e --arg repo "$REPO" '.v == 2 and .repo == $repo and .target == "trail:1" and .branch == "login"
    and .creation.status == "started" and .creation.message == "Do the research"' "$(record_file 1.json)" >/dev/null \
    || fail "job record: $(cat "$(record_file 1.json)")"
  ! grep -Eq '^entire trail (update|comment|link)' "$LOG" || fail "dispatch wrote to the trail: $(cat "$LOG")"

  out="$(bercail shep board)" || fail "board: $out"
  grep -qx -- '- trail:1: Research the login flow \[planning\] · desk t21 working · login' <<<"$out" || fail "board while working: $out"

  # The desk reports from its worktree; Entire would refuse it as a trail comment.
  out="$(cd "$REPO.login" && printf 'Found it: the session expires after 15 minutes.\n' | bercail job comment trail:1)" || fail "comment: $out"
  out="$(bercail shep brief trail:1 --repo "$REPO")" || fail "brief: $out"
  [[ "$out" == "trail:1: Research the login flow
open planning task https://entire.example/et/proj/-/trails/1 · repo ~/Work/app
desk t21 working · space sp-new · branch login · worktree ~/Work/app.login
latest report: comment 2 of 2, Simon at "*" (47 characters):
Found it: the session expires after 15 minutes." ]] || fail "brief: $out"
  out="$(bercail job show trail:1 --repo "$REPO")" || fail "show: $out"
  [[ "$out" == *"Find where the session expires."*"bercail handoff: stage bstack"*"Found it"* ]] || fail "show: $out"

  # A job with no code ends once its report is in: Shep closes the trail.
  (cd "$REPO" && entire trail update 1 --status closed --json >/dev/null)
  rm "$HC_DATA/t21.json"
  printf '{"terminals":[]}\n' >"$HC_DATA/ls.json"
  out="$(bercail shep board)" || fail "board after close: $out"
  ! grep -q 'trail:1' <<<"$out" || fail "a closed trail is still on the board: $out"
}

@test "dispatch refuses a closed trail, a trail target for another job, and a beads target for a trail" {
  local out
  spawn_ok
  trail 1 "Research" closed complete
  out="$(dispatch 2>&1)" && fail "a closed trail took a desk: $out"
  [[ "$out" == *"trail:1 is closed; reopen it with entire trail update 1 --status open"* ]] || fail "closed: $out"
  trail 1 "Research" open planning
  out="$(dispatch '.issue = "trail:1" | .target = "trail:2"' 2>&1)" && fail "$out"
  [[ "$out" == *"a trail job's target is its own trail: dispatch trail:1 with target trail:1"* ]] || fail "other trail: $out"
  out="$(dispatch '.issue = "trail:1" | .target = "pr:12"' 2>&1)" && fail "$out"
  [[ "$out" == *"a trail job's target is its own trail"* ]] || fail "pr target: $out"
  ! grep -q '^spawn ' "$LOG" || fail "a refused dispatch spawned: $(cat "$LOG")"
  [[ ! -e "$(record_file 1.json)" ]] || fail "a refused dispatch wrote a record"
}

@test "bercail job shows a trail with its changes and comments, and refuses a comment on a trail Entire does not have" {
  local out
  trail 4 "Ship the export" open review "The CSV export, behind a flag."
  jq '.changes = [{repository: "app", number: 9, branch: "export", base: "main", status: "open", url: "u"}]' "$TRAILS/4.json" >"$TRAILS/t"
  mv "$TRAILS/t" "$TRAILS/4.json"
  out="$(cd "$REPO" && bercail job show trail:4)" || fail "show: $out"
  [[ "$out" == "trail:4: Ship the export
open · review · task · priority none · https://entire.example/et/proj/-/trails/4

The CSV export, behind a flag.

Changes:
- change app/9: export into main, open

No comments on this machine yet. Add one with: bercail job comment trail:4 <<'EOF'

People's discussion on Entire: entire trail comment list --trail 4" ]] || fail "show: $out"
  out="$(cd "$REPO" && bercail job show trail:4 --json)" || fail "show --json: $out"
  jq -e '.id == "trail:4" and .trail_id == "T4" and .url == "https://entire.example/et/proj/-/trails/4"' <<<"$out" >/dev/null \
    || fail "show --json: $out"
  out="$(cd "$REPO" && printf 'report' | bercail job comment trail:5 2>&1)" && fail "a comment on a missing trail passed: $out"
  [[ "$out" == *"entire trail show 5 failed in $REPO: project trail #5 not found in et/proj"* ]] || fail "missing: $out"
  out="$(cd "$REPO" && printf '  \n' | bercail job comment trail:4 2>&1)" && fail "an empty comment passed: $out"
  [[ "$out" == *"the comment is empty"* ]] || fail "empty: $out"
  out="$(cd "$REPO" && bercail job show 4 2>&1)" && fail "a bare number passed: $out"
  [[ "$out" == *"4 is not a trail job; a trail is trail:<n>"* ]] || fail "bare number: $out"
  [[ ! -e "$(record_file 5.comments.jsonl)" && ! -e "$(record_file 4.comments.jsonl)" ]] || fail "a refused comment was written"
}

@test "the board lists an Entire repo's trails in flight, counts the complete ones left to close, and is UNKNOWN when Entire does not answer" {
  local out want
  trail 1 "Plan the API" open planning
  trail 2 "Ship the export" open review
  trail 3 "Merged last week" open complete
  trail 4 "Merged too" open complete
  trail 5 "Closed" closed closed
  out="$(bercail shep board)" || fail "board: $out"
  want="~/Work/app: 1 job, 1 other open issues
- trail:2: Ship the export [review] · no desk · -
~/Work/app: ready, not started: trail:1
~/Work/app: 2 complete trails still open; close each with entire trail update N --status closed (bercail job list --repo ~/Work/app)
Waiting on the person:
- nothing
Decisions:
- nothing"
  [[ "$out" == "$want" ]] || fail "board: $(diff <(printf '%s\n' "$want") <(printf '%s\n' "$out"))"
  grep -q '^entire trail list --project et/proj --repo entire://entire.example/et/proj/app --status open --limit 100 --json$' "$LOG" \
    || fail "list: $(cat "$LOG")"
  # The repo is UNKNOWN, and so is the review queue, which reads no second list.
  : >"$LOG"
  out="$(ENTIRE_DOWN=1 bercail shep board 2>"$BATS_TEST_TMPDIR/err")" && fail "board offline passed: $out"
  [[ "$out" == "Other repos: ~/Work/app (UNKNOWN (Entire unavailable))"* && "$(cat "$BATS_TEST_TMPDIR/err")" == *"Board incomplete: UNKNOWN"* ]] \
    || fail "offline board: $out $(cat "$BATS_TEST_TMPDIR/err")"
  [[ "$(grep -c '^entire ' "$LOG")" == 1 ]] || fail "listed again: $(cat "$LOG")"
  out="$(ENTIRE_SHAPE='{"error":"response shape changed"}' bercail shep board 2>/dev/null)" && fail "board on a changed answer passed: $out"
  [[ "$out" == "Other repos: ~/Work/app (UNKNOWN (Entire unavailable))"* ]] || fail "an answer of another shape read as no trails: $out"
}

@test "a Blocked by line keeps a trail blocked until its blockers close or merge, and names an unknown number or an unreadable line" {
  local out
  spawn_ok
  trail 2 "Ship the schema" open review
  trail 3 "Old work" closed closed
  trail 1 "Research the login flow" open planning $'Find where it expires.\nBlocked by: #2, #3'
  out="$(dispatch 2>&1)" && fail "a blocked trail took a desk: $out"
  [[ "$out" == *"trail:1 is blocked by #2; dispatch it once they are closed or merged"* ]] || fail "blocked: $out"
  ! grep -q '^spawn ' "$LOG" || fail "a blocked trail spawned"
  out="$(bercail shep brief trail:1 --repo "$REPO")" || fail "brief: $out"
  [[ "$(sed -n 3p <<<"$out")" == "blocked: waits on #2" ]] || fail "brief blocked: $out"
  # A blocker open in the repo is in its open list: no project-wide read. A
  # comment reads no blockers at all.
  trail 6 "Follow the schema" open planning 'Blocked by: #2'
  : >"$LOG"
  out="$(cd "$REPO" && bercail job show trail:6 --json)" || fail "show: $out"
  jq -e '.waiting_on == ["#2"]' <<<"$out" >/dev/null || fail "show: $out"
  [[ "$(grep -c '^entire trail list ' "$LOG")" == 1 ]] && grep -q -- '--status open' <<<"$(grep '^entire trail list ' "$LOG")" \
    || fail "show read more than the repo's open list: $(cat "$LOG")"
  : >"$LOG"
  (cd "$REPO" && printf 'note' | bercail job comment trail:6 >/dev/null) || fail "comment on a blocked trail"
  ! grep -q '^entire trail list ' "$LOG" || fail "a comment read blockers: $(cat "$LOG")"
  rm "$TRAILS/6.json"
  out="$(bercail shep board)" || fail "board: $out"
  grep -qx '~/Work/app: blocked, not started: trail:1 by #2' <<<"$out" || fail "board blocked: $out"
  out="$(bercail job list --repo "$REPO")" || fail "list: $out"
  [[ "$out" == "trail:2: Ship the schema · review · ready
trail:1: Research the login flow · planning · blocked by #2" ]] || fail "list: $out"

  # Merged is done too: once #2's phase is complete, the trail is ready.
  trail 2 "Ship the schema" open complete
  out="$(bercail shep brief trail:1 --repo "$REPO")" || fail "brief: $out"
  [[ "$(sed -n 3p <<<"$out")" == "ready: #2, #3 closed or merged" ]] || fail "brief ready: $out"
  out="$(bercail shep board)" || fail "board: $out"
  grep -qx '~/Work/app: ready, not started: trail:1' <<<"$out" || fail "board ready: $out"
  out="$(dispatch)" || fail "a ready trail did not dispatch: $out"
  jq -e '.status == "started"' <<<"$out" >/dev/null || fail "dispatch: $out"

  trail 4 "Wait on nothing real" open planning 'Blocked by: #99'
  trail 5 "Wait on a typo" open planning 'Blocked by: 12 and #2'
  out="$(bercail job list --repo "$REPO")" || fail "list: $out"
  [[ "$out" == *"trail:4: Wait on nothing real · planning · blocked by #99 (no such trail)"* ]] || fail "unknown number: $out"
  [[ "$out" == *"trail:5: Wait on a typo · planning · blocked by an unreadable line: Blocked by: 12 and #2 (write it as Blocked by: #12, #15)"* ]] \
    || fail "malformed line: $out"
}

@test "the board reads an Entire repo's trails with one list call, whatever their number, pages past 100, and lists the project once for blockers outside the repo" {
  local n
  for n in 1 2 3; do trail "$n" "Trail $n" open planning; done
  : >"$LOG"
  bercail shep board >/dev/null || fail "board"
  [[ "$(grep -c '^entire ' "$LOG")" == 1 && "$(grep -c '^entire trail list ' "$LOG")" == 1 ]] || fail "3 trails: $(cat "$LOG")"
  # 57 more open trails, and 150 closed ones the list leaves out.
  for n in $(seq 4 60); do trail "$n" "Trail $n" open review; done
  for n in $(seq 300 449); do trail "$n" "Closed $n" closed closed; done
  : >"$LOG"
  bercail shep board >/dev/null || fail "board"
  [[ "$(grep -c '^entire ' "$LOG")" == 1 ]] || fail "60 open trails and a closed history took more than one call: $(cat "$LOG")"
  rm "$TRAILS"/{3,4}[0-9][0-9].json
  # Blockers in another repo of the project, or in none: one more list, for the project.
  for n in $(seq 61 70); do trail "$n" "Blocked $n" open planning "Blocked by: #$((n + 100)), #$((n + 200))"; trail "$((n + 100))" "Web $n" open review "" web; done
  : >"$LOG"
  out="$(bercail shep board)" || fail "board with blockers: $out"
  [[ "$(grep -c '^entire trail list ' "$LOG")" == 2 && "$(grep -c '^entire trail show ' "$LOG")" == 0 ]] || fail "blockers: $(cat "$LOG")"
  grep -q '^entire trail list --project et/proj --limit 100 --json$' "$LOG" || fail "no project list: $(cat "$LOG")"
  [[ "$out" == *"trail:70 by #170, #270 (no such trail)"* ]] || fail "blocked: $out"
  rm "$TRAILS"/{6[1-9],70,16[1-9],170}.json
  : >"$LOG"
  out="$(PAGE=25 bercail shep board)" || fail "paged board: $out"
  [[ "$(grep -c '^entire trail list ' "$LOG")" == 3 && "$out" == *"~/Work/app: 57 jobs, 3 other open issues"* ]] \
    || fail "pages: $(cat "$LOG") $out"
}

@test "adopting a gone desk's checkout on a blocked trail goes on, and warns with its blockers" {
  local out
  spawn_ok
  trail 2 "Ship the schema" open review
  trail 1 "Research the login flow" open planning "Find where it expires."
  dispatch >/dev/null || fail "first dispatch"
  # The desk is gone, its checkout stays, and the trail now waits on #2.
  rm "$HC_DATA/t21.json"
  printf '{"terminals":[]}\n' >"$HC_DATA/ls.json"
  trail 1 "Research the login flow" open planning $'Find where it expires.\nBlocked by: #2'
  out="$(dispatch '.requestId = "r2" | del(.branch)')" || fail "adoption: $out"
  jq -e '.status == "started" and (.warning | contains("Adopted:") and contains("trail:1 is blocked by #2"))' <<<"$out" >/dev/null \
    || fail "adoption warning: $out"
}

@test "a trail whose desk bercail cleanup retired gets a new desk in a fresh worktree of its kept branch" {
  local out
  spawn_ok
  trail 1 "Research the login flow" open planning "Find where it expires."
  dispatch >/dev/null || fail "first dispatch"
  # Cleanup ended t21, removed its worktree, kept branch login, and said so.
  mv "$HC_DATA/t21.json" "$BATS_TEST_TMPDIR/t21.json"
  printf '{"terminals":[]}\n' >"$HC_DATA/ls.json"
  git -C "$REPO" worktree remove --force "$REPO.login"
  jq -nc --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg p "$REPO.login" --arg r "$REPO" \
    '{v:1,at:$at,path:$p,repo:$r,branch:"login"}' >"$XDG_STATE_HOME/bercail/retired.jsonl"
  # A desk of that checkout still live, without its job's label, is not gone.
  jq '.labels |= del(.["bercail.issue"])' "$BATS_TEST_TMPDIR/t21.json" >"$HC_DATA/t21.json"
  printf '{"terminals":[{"address":"t21","cwd":"%s","state":"live"}]}\n' "$REPO" >"$HC_DATA/ls.json"
  out="$(dispatch '.requestId = "r2"' 2>&1)" && fail "a live desk was replaced: $out"
  [[ "$out" == *"desk t21 of a retired checkout is still live"* ]] || fail "$out"
  rm "$HC_DATA/t21.json"
  printf '{"terminals":[]}\n' >"$HC_DATA/ls.json"
  out="$(dispatch '.requestId = "r2" | .message = "Merge main into the branch"')" || fail "dispatch after cleanup: $out"
  jq -e --arg p "$REPO.login" '.status == "started" and .creation.desk == "t21" and .creation.path == $p' <<<"$out" >/dev/null \
    || fail "dispatch after cleanup: $out"
  [[ "$(grep -c '^spawn --branch login --stage bstack --issue trail:1 --target trail:1 .*--existing-branch' "$LOG")" == 1 ]] \
    || fail "spawn argv: $(cat "$LOG")"
  jq -e '.creation.id == "r2" and .creation.message == "Merge main into the branch" and .owner == null and (.retired | index("r1"))' \
    "$(record_file 1.json)" >/dev/null || fail "job record: $(cat "$(record_file 1.json)")"
}

@test "a retry of a creation that left no desk does not start one once the trail is blocked" {
  local out
  trail 2 "Ship the schema" open review
  trail 1 "Research the login flow" open planning "Find where it expires."
  export BERCAIL_HANDOFF_SPAWN="$BATS_TEST_TMPDIR/bin/spawn"
  printf '#!/bin/sh\nprintf "spawn %%s\\n" "$*" >>"$LOG"\nexit 1\n' >"$BERCAIL_HANDOFF_SPAWN"
  chmod +x "$BERCAIL_HANDOFF_SPAWN"
  out="$(dispatch 2>&1)" && fail "a failed spawn passed: $out"
  jq -e '.creation.status == "unknown"' "$(record_file 1.json)" >/dev/null || fail "record: $(cat "$(record_file 1.json)")"
  trail 1 "Research the login flow" open planning $'Find where it expires.\nBlocked by: #2'
  out="$(dispatch)" || fail "retry: $out"
  jq -e '.status == "unknown" and (.next | startswith("Not finished: trail:1 is blocked by #2"))' <<<"$out" >/dev/null || fail "retry: $out"
  [[ "$(grep -c '^spawn ' "$LOG")" == 1 ]] || fail "the retry spawned: $(cat "$LOG")"
}

# parent N BRANCH DESK: trail N gets desk DESK in a worktree of BRANCH, which
# stages its work there. gone DESK: the desk ends; its checkout stays.
parent() {
  SPAWN_DESK="$3" dispatch ".target = \"trail:$1\" | .requestId = \"p$1\" | .branch = \"$2\"" >/dev/null || fail "dispatch of parent trail:$1"
  printf 'work of trail %s\n' "$1" >"$REPO.$2/work-$1.txt"
  git -C "$REPO.$2" add "work-$1.txt"
}
gone() {
  rm "$HC_DATA/$1.json"
  jq --arg a "$1" '.terminals |= map(select(.address != $a))' "$HC_DATA/ls.json" >"$HC_DATA/ls.tmp"
  mv "$HC_DATA/ls.tmp" "$HC_DATA/ls.json"
}
stacked() { dispatch ".stackedOn = $1 | .stackReason = \"Simon: start on the staged work\" | ${2:-.}" "${@:3}"; }

teardown() {
  local pid
  for pid in "${PI_PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
}

# live_pi DESK DIR ISSUE: what dispatch verifies of a live desk spawn_ok
# started. A Pi stand-in runs in DIR (bash blocked in read, as in
# tests/shep_task.bats), with its desk record, session file and session claim.
PI_PIDS=()
live_pi() {
  local n pid ticks file="$BATS_TEST_TMPDIR/$1.jsonl"
  mkdir -p "$BATS_TEST_TMPDIR/pi" "$XDG_STATE_HOME/bercail/desk-sessions" "$XDG_RUNTIME_DIR/bercail/open-sessions"
  [[ -e "$BATS_TEST_TMPDIR/pi/pi" ]] || cp "$BASH" "$BATS_TEST_TMPDIR/pi/pi"
  mkfifo "$BATS_TEST_TMPDIR/pi/$1.hold"
  (cd "$2" && exec "$BATS_TEST_TMPDIR/pi/pi" -c 'read -rt 120 <>"$0"' "$BATS_TEST_TMPDIR/pi/$1.hold") >/dev/null 2>&1 &
  pid=$!
  PI_PIDS+=("$pid")
  for ((n = 0; n < 200; n++)); do
    [[ "$(basename "$(readlink "/proc/$pid/exe")")" == pi ]] && break
    sleep 0.01
  done
  [[ "$n" -lt 200 ]] || fail "the Pi stand-in did not exec"
  ticks="$(awk '{print $22}' "/proc/$pid/stat")"
  jq -nc --arg s "s-$1" --arg cwd "$2" '{type:"session",version:3,id:$s,cwd:$cwd}' >"$file"
  jq -n --arg s "s-$1" --arg ticks "$ticks" --argjson pid "$pid" '{pid:$pid,start_ticks:$ticks,sessions:[$s]}' \
    >"$XDG_RUNTIME_DIR/bercail/open-sessions/$pid.json"
  jq -n --arg a "$1" --arg cwd "$2" --arg i "$3" --arg f "$file" --arg ticks "$ticks" --argjson pid "$pid" \
    '{address:$a,cwd:$cwd,session:"s-\($a)",session_file:$f,space:"sp-new",issue:$i,harness:"pi",pid:$pid,start_ticks:$ticks,follow_up:1}' \
    >"$XDG_STATE_HOME/bercail/desk-sessions/$1.json"
  jq --argjson pid "$pid" '.foreground = {pid: $pid}' "$HC_DATA/$1.json" >"$HC_DATA/tmp" && mv "$HC_DATA/tmp" "$HC_DATA/$1.json"
}

@test "a blocked trail starts on its blocker's staged checkout with stackedOn, the trail stays as it was, and a dispatch without it still refuses" {
  local out reason="Simon: start on the staged work"
  spawn_ok
  trail 2 "Ship the schema" open review
  parent 2 schema t22
  gone t22
  trail 1 "Research the login flow" open planning $'Find where it expires.\nBlocked by: #2'
  cp "$TRAILS/1.json" "$BATS_TEST_TMPDIR/before.json"
  : >"$LOG"
  out="$(dispatch 2>&1)" && fail "a blocked trail took a desk: $out"
  [[ "$out" == *"trail:1 is blocked by #2"*"stackedOn"*"stackReason"* && "$out" != *"entire trail update"* ]] || fail "refusal: $out"
  # A dry run verifies the same, and starts and records nothing.
  out="$(stacked '["trail:2"]' . --dry-run)" || fail "dry run: $out"
  jq -e --arg p "$REPO.schema" '.dry_run and .status == "would-start" and .stacked.parents[0].path == $p' <<<"$out" >/dev/null || fail "dry run: $out"
  ! grep -q '^spawn ' "$LOG" || fail "a refusal or a dry run spawned: $(cat "$LOG")"
  [[ ! -e "$(record_file 1.json)" ]] || fail "a refusal or a dry run wrote a record"

  out="$(stacked '["trail:2"]')" || fail "stacked dispatch: $out"
  jq -e --arg p "$REPO.schema" --arg r "$reason" '.status == "started" and .creation.desk == "t21" and .authority == false
    and .stacked == {reason: $r, parents: [{trail: "trail:2", path: $p, branch: "schema", staged: 1}]}' <<<"$out" >/dev/null \
    || fail "stacked dispatch: $out"
  [[ "$(grep -c '^spawn --branch login --stage bstack --issue trail:1 --target trail:1 ' "$LOG")" == 1 ]] || fail "spawn argv: $(cat "$LOG")"
  jq -e --arg p "$REPO.schema" --arg r "$reason" '.creation.status == "started"
    and .stack == {reason: $r, parents: [{trail: "trail:2", path: $p, branch: "schema", staged: 1}]}' "$(record_file 1.json)" >/dev/null \
    || fail "job record: $(cat "$(record_file 1.json)")"
  # Nothing was written to a trail, and no parent's work was copied into the new checkout.
  ! grep -Eq '^entire trail (update|comment|link|create|merge)' "$LOG" || fail "dispatch wrote to a trail: $(cat "$LOG")"
  cmp "$TRAILS/1.json" "$BATS_TEST_TMPDIR/before.json" || fail "the trail changed"
  [[ ! -e "$REPO.login/work-2.txt" && -z "$(git -C "$REPO.login" status --porcelain)" ]] || fail "the parent's work was copied in"
  out="$(bercail job list --repo "$REPO")" || fail "list: $out"
  grep -qx 'trail:1: Research the login flow · planning · blocked by #2 · dispatched' <<<"$out" || fail "the trail no longer reads blocked: $out"

  # The desk's first prompt is bercail job show: it names where the parent's work is.
  out="$(cd "$REPO.login" && bercail job show trail:1)" || fail "show: $out"
  [[ "$out" == *"
blocked: waits on #2
Parent worktrees at dispatch ($reason):
- trail:2: $REPO.schema · branch schema · 1 staged file, desk gone

Find where it expires."* ]] || fail "show: $out"
  # The same request without stackedOn is another request.
  out="$(dispatch 2>&1)" && fail "a retry without stackedOn passed: $out"
  [[ "$out" == *"requestId payload changed; this is not a retry"* ]] || fail "changed payload: $out"
  # Once #2 has merged, its work is on main: the path is no longer named.
  trail 2 "Ship the schema" open complete
  out="$(cd "$REPO.login" && bercail job show trail:1)" || fail "show once merged: $out"
  [[ "$out" == *"ready: #2 closed or merged"* && "$out" != *"$REPO.schema"* ]] || fail "show once merged: $out"
}

@test "a stacked dispatch reads a blocker's work from its live desk once that desk verifies, never from its label alone" {
  local out
  spawn_ok
  trail 2 "Ship the schema" open review
  SPAWN_DESK=t22 dispatch '.target = "trail:2" | .requestId = "p2" | .branch = "schema"' >/dev/null || fail "dispatch of the parent"
  trail 1 "Research the login flow" open planning 'Blocked by: #2'
  : >"$LOG"
  # A live terminal labelled for trail:2, with no desk record behind it.
  out="$(stacked '["trail:2"]' 2>&1)" && fail "a label alone was taken as the parent's desk: $out"
  [[ "$out" == *"cannot stack trail:1 on trail:2: missing desk record for t22"*"No desk was started" ]] || fail "label alone: $out"
  ! grep -q '^spawn ' "$LOG" || fail "the refusal spawned: $(cat "$LOG")"
  live_pi t22 "$REPO.schema" trail:2
  out="$(stacked '["trail:2"]')" || fail "stacked on a live desk: $out"
  jq -e --arg p "$REPO.schema" '.status == "started" and .stacked.parents == [{trail: "trail:2", path: $p, branch: "schema", desk: "t22"}]' \
    <<<"$out" >/dev/null || fail "stacked on a live desk: $out"
  out="$(cd "$REPO.login" && bercail job show trail:1)" || fail "show: $out"
  grep -qxF -- "- trail:2: $REPO.schema · branch schema · desk t22 live" <<<"$out" || fail "show: $out"
  # Once the new desk's Pi is up, a retry queues its message there; a follow-up takes no stackedOn.
  live_pi t21 "$REPO.login" trail:1
  out="$(stacked '["trail:2"]')" || fail "retry: $out"
  jq -e '.status == "queued" and .owner.desk == "t21" and .retry' <<<"$out" >/dev/null || fail "retry: $out"
  out="$(stacked '["trail:2"]' '.requestId = "r2"' 2>&1)" && fail "a follow-up took stackedOn: $out"
  [[ "$out" == *"stackedOn starts a new desk, and trail:1 has live desk t21; dispatch without stackedOn"* ]] || fail "follow-up: $out"
  [[ "$(grep -c '^spawn ' "$LOG")" == 1 ]] || fail "a second desk started: $(cat "$LOG")"
}

@test "a stacked dispatch refuses unless stackedOn names exactly the open blockers and each one's recorded work is there to read" {
  local out other="$HOME/Work/web" both=$'Find where it expires.\nBlocked by: #2, #3'
  spawn_ok
  trail 2 "Ship the schema" open review
  trail 3 "Ship the API" open review
  trail 4 "Unrelated" open review
  parent 2 schema t22
  gone t22
  trail 1 "Research the login flow" open planning "$both"
  : >"$LOG"
  refused() {
    out="$(stacked "$1" "${3:-.}" 2>&1)" && fail "$1 started a desk: $out"
    [[ "$out" == *"$2"* ]] || fail "$1: $out"
  }
  # The two fields go together, on a trail, with trails named once.
  out="$(dispatch '.stackedOn = ["trail:2", "trail:3"]' 2>&1)" && fail "no reason: $out"
  [[ "$out" == *"stackedOn and stackReason go together: on a trail"* ]] || fail "no reason: $out"
  refused '["trail:2", "trail:3"]' "stackedOn and stackReason go together" '.stackReason = "  "'
  refused '["trail:1"]' "stackedOn and stackReason go together"
  refused '["#2", "trail:3"]' "stackedOn and stackReason go together"
  refused '["trail:2", "trail:2"]' "stackedOn and stackReason go together"
  refused '"trail:2"' "stackedOn and stackReason go together"
  refused '["trail:2", "trail:3"]' "stackedOn and stackReason go together" '.target = "task:app-1" | .issue = "app-1"'
  # Every open blocker, and no other trail.
  refused '["trail:2"]' "stackedOn must name exactly what trail:1 still waits on (#2, #3)"
  refused '["trail:2", "trail:3", "trail:4"]' "stackedOn must name exactly what trail:1 still waits on (#2, #3)"
  # trail:3 was never dispatched: no desk, no record.
  refused '["trail:2", "trail:3"]' "cannot stack trail:1 on trail:3: it has no live desk, and no record of one that started"
  # A line that names a staged checkout but no desk that started, and one of another repo.
  git -C "$REPO" worktree add -qb api "$REPO.api"
  printf 'x\n' >"$REPO.api/x" && git -C "$REPO.api" add x
  jq -nc --arg p "$REPO.api" '{path:$p,branch:"api",issue:"trail:3"}' >>"$XDG_STATE_HOME/bercail/handoffs.jsonl"
  refused '["trail:2", "trail:3"]' "cannot stack trail:1 on trail:3: it has no live desk, and no record of one that started"
  git init -q -b main "$other"
  git -C "$other" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
  git -C "$other" worktree add -qb api "$other.api"
  printf 'x\n' >"$other.api/x" && git -C "$other.api" add x
  jq -nc --arg p "$other.api" '{ok:true,agent_started:true,path:$p,branch:"api",desk:"t30",issue:"trail:3"}' >>"$XDG_STATE_HOME/bercail/handoffs.jsonl"
  refused '["trail:2", "trail:3"]' "cannot stack trail:1 on trail:3: it has no live desk, and no record of one that started"
  # A desk that started and is gone, with nothing staged in its checkout.
  jq -nc --arg p "$REPO.api" '{ok:true,agent_started:true,path:$p,branch:"api",desk:"t23",issue:"trail:3"}' >>"$XDG_STATE_HOME/bercail/handoffs.jsonl"
  git -C "$REPO.api" rm -q --cached x
  refused '["trail:2", "trail:3"]' "cannot stack trail:1 on trail:3: its desk is gone, and $REPO.api has nothing staged"
  # Staged, but the checkout is no longer on the recorded branch.
  git -C "$REPO.api" add x
  git -C "$REPO.api" switch -qc other
  refused '["trail:2", "trail:3"]' "cannot stack trail:1 on trail:3: $REPO.api is no longer api in this repo"
  git -C "$REPO.api" switch -q api
  out="$(stacked '["trail:2", "trail:3"]' . --dry-run)" || fail "both parents staged: $out"
  jq -e '.status == "would-start" and (.stacked.parents | map(.trail) == ["trail:2", "trail:3"])' <<<"$out" >/dev/null || fail "both parents staged: $out"
  # A folder inside the worktree is on its branch, and is not the worktree.
  mkdir "$REPO.api/sub"
  grep -v '"trail:3"' "$XDG_STATE_HOME/bercail/handoffs.jsonl" >"$BATS_TEST_TMPDIR/h"
  jq -nc --arg p "$REPO.api/sub" '{ok:true,agent_started:true,path:$p,branch:"api",desk:"t23",issue:"trail:3"}' >>"$BATS_TEST_TMPDIR/h"
  cp "$BATS_TEST_TMPDIR/h" "$XDG_STATE_HOME/bercail/handoffs.jsonl"
  refused '["trail:2", "trail:3"]' "cannot stack trail:1 on trail:3: $REPO.api/sub is not the worktree of api"
  # The job still names the owner of a checkout bercail cleanup retired, and
  # someone made a worktree of that branch at that path again, with staged files.
  grep -v '"trail:3"' "$BATS_TEST_TMPDIR/h" >"$XDG_STATE_HOME/bercail/handoffs.jsonl"
  jq -nc --arg p "$REPO.api" '{ok:true,agent_started:true,path:$p,branch:"api",desk:"t23",issue:"trail:3"}' >>"$XDG_STATE_HOME/bercail/handoffs.jsonl"
  out="$(stacked '["trail:2", "trail:3"]' . --dry-run)" || fail "the recorded checkout, before its retirement: $out"
  jq -n --arg r "$REPO" --arg p "$REPO.api" '{v:2,repo:$r,target:"trail:3",branch:"api",
    owner:{desk:"t23",space:"sp-new",cwd:$p,branch:"api",session:"s-t23",session_file:"/x",pid:1,start_ticks:"1"}}' >"$(record_file 3.json)"
  jq -nc --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg p "$REPO.api" --arg r "$REPO" \
    '{v:1,at:$at,path:$p,repo:$r,branch:"api"}' >"$XDG_STATE_HOME/bercail/retired.jsonl"
  refused '["trail:2", "trail:3"]' "cannot stack trail:1 on trail:3: it has no live desk, and no record of one that started in a checkout still kept"

  # A blocker of another repo of the project, one Entire does not have, and an unreadable line.
  trail 5 "Web work" open review "" web
  trail 1 "Research the login flow" open planning 'Blocked by: #2, #5'
  refused '["trail:2", "trail:5"]' "cannot stack trail:1 on trail:5: trail:5 is not a trail of $REPO"
  trail 1 "Research the login flow" open planning 'Blocked by: #2, #99'
  refused '["trail:2", "trail:99"]' "stackedOn must name exactly what trail:1 still waits on (#2, #99 (no such trail)); a missing trail or an unreadable line cannot be stacked on"
  trail 1 "Research the login flow" open planning $'Blocked by: #2\nBlocked by: 3 and more'
  refused '["trail:2"]' "a missing trail or an unreadable line cannot be stacked on"
  # A trail that waits on nothing takes no stackedOn.
  trail 1 "Research the login flow" open planning "Find where it expires."
  refused '["trail:2"]' "stackedOn must name exactly what trail:1 still waits on (nothing)"
  ! grep -q '^spawn ' "$LOG" || fail "a refused dispatch spawned: $(cat "$LOG")"
  [[ ! -e "$(record_file 1.json)" ]] || fail "a refused dispatch wrote a record"
  ! grep -Eq '^entire trail (update|comment|link|create|merge)' "$LOG" || fail "a refusal wrote to a trail: $(cat "$LOG")"

  # A gone desk's checkout is adopted, blocked or not: stackedOn is not for it.
  dispatch >/dev/null || fail "first dispatch"
  gone t21
  trail 1 "Research the login flow" open planning "$both"
  : >"$LOG"
  refused '["trail:2", "trail:3"]' "trail:1 has its gone desk's checkout $REPO.login, which a new desk adopts; dispatch without stackedOn" '.requestId = "r2"'
  ! grep -q '^spawn ' "$LOG" || fail "the refused adoption spawned: $(cat "$LOG")"
  jq -e '.creation.id == "r1" and (has("adoptions") | not) and (has("stack") | not)' "$(record_file 1.json)" >/dev/null \
    || fail "the refused adoption was recorded: $(cat "$(record_file 1.json)")"
}

@test "a gone parent with an unresolved index has no staged tree to build on" {
  spawn_ok
  trail 1 Child open planning 'Blocked by: #2'
  trail 2 Schema open review
  parent 2 schema t22
  gone t22
  git -C "$REPO.schema" -c user.email=t@example.invalid commit -qm schema
  printf 'other\n' >"$REPO/work-2.txt"
  git -C "$REPO" add work-2.txt
  git -C "$REPO" -c user.email=t@example.invalid commit -qm other
  run git -C "$REPO.schema" -c user.email=t@example.invalid merge main
  [[ "$status" == 1 && -n "$(git -C "$REPO.schema" ls-files -u)" ]] || fail "expected a conflicted index: $output"
  run stacked '["trail:2"]' . --dry-run
  [[ "$status" != 0 && "$output" == *"trail:2:"*"unmerged entries"* ]] || fail "$output"
}

@test "a handoff in the same second as retirement cannot vouch for a gone parent's checkout" {
  spawn_ok
  trail 1 Child open planning 'Blocked by: #2'
  trail 2 Schema open review
  parent 2 schema t22
  gone t22
  local at=2026-01-15T12:00:00Z log="$XDG_STATE_HOME/bercail/handoffs.jsonl"
  jq -c --arg at "$at" '.at = $at' "$log" >"$BATS_TEST_TMPDIR/line" && mv "$BATS_TEST_TMPDIR/line" "$log"
  git -C "$REPO" worktree remove --force "$REPO.schema"
  jq -nc --arg at "$at" --arg p "$REPO.schema" '{path:$p,at:$at}' >"$XDG_STATE_HOME/bercail/retired.jsonl"
  git -C "$REPO" worktree add -q "$REPO.schema" schema
  touch "$REPO.schema/unrelated" && git -C "$REPO.schema" add unrelated
  run stacked '["trail:2"]' . --dry-run
  [[ "$status" != 0 && "$output" == *"cannot stack trail:1 on trail:2"* ]] || fail "$output"
}

@test "a retry of a stacked creation that left no desk reads again where the open blockers are, and goes on once one has landed" {
  local out
  spawn_ok
  trail 2 "Ship the schema" open review
  trail 3 "Ship the API" open review
  trail 4 "Added later" open review
  parent 2 schema t22
  gone t22
  parent 3 api t23
  gone t23
  trail 1 "Research the login flow" open planning 'Blocked by: #2, #3'
  printf '#!/bin/sh\nprintf "spawn %%s\\n" "$*" >>"$LOG"\nexit 1\n' >"$BERCAIL_HANDOFF_SPAWN"
  : >"$LOG"
  out="$(stacked '["trail:2", "trail:3"]' 2>&1)" && fail "a failed spawn passed: $out"
  jq -e '.creation.status == "unknown" and (.stack.parents | map(.trail) == ["trail:2", "trail:3"])' "$(record_file 1.json)" >/dev/null \
    || fail "record: $(cat "$(record_file 1.json)")"
  spawn_ok
  # A blocker added since is not one the person chose to stack on.
  trail 1 "Research the login flow" open planning 'Blocked by: #2, #3, #4'
  out="$(stacked '["trail:2", "trail:3"]')" || fail "retry with a new blocker: $out"
  jq -e '.status == "unknown" and (.next | startswith("Not finished: stackedOn must name exactly what trail:1 still waits on (#2, #3, #4)"))' <<<"$out" >/dev/null \
    || fail "retry with a new blocker: $out"
  [[ "$(grep -c '^spawn ' "$LOG")" == 1 ]] || fail "the retry spawned: $(cat "$LOG")"
  # #2 landed and its checkout is gone: the retry needs only #3's work, and names no path of #2.
  trail 1 "Research the login flow" open planning 'Blocked by: #2, #3'
  trail 2 "Ship the schema" open complete
  git -C "$REPO" worktree remove --force "$REPO.schema"
  out="$(stacked '["trail:2", "trail:3"]')" || fail "retry once #2 landed: $out"
  jq -e '.status == "started" and .retry' <<<"$out" >/dev/null || fail "retry once #2 landed: $out"
  jq -e --arg p "$REPO.api" '.creation.status == "started" and .stack.parents == [{trail: "trail:3", path: $p, branch: "api", staged: 1}]' \
    "$(record_file 1.json)" >/dev/null || fail "record after the retry: $(cat "$(record_file 1.json)")"
  out="$(cd "$REPO.login" && bercail job show trail:1)" || fail "show: $out"
  [[ "$out" == *"- trail:3: $REPO.api · branch api · 1 staged file, desk gone"* && "$out" != *"$REPO.schema"* ]] || fail "show: $out"
}

@test "a creation recorded without a payload hash is not retried with stackedOn" {
  local out
  trail 2 "Ship the schema" open review
  trail 1 "Research the login flow" open planning 'Blocked by: #2'
  mkdir -p "$(dirname "$(record_file 1.json)")"
  jq -n --arg r "$REPO" '{v:2,repo:$r,target:"trail:1",branch:"login",owner:null,
    creation:{id:"r1",payload:"",stage:"bstack",message:"Do the research",status:"unknown",next:""}}' >"$(record_file 1.json)"
  out="$(stacked '["trail:2"]' 2>&1)" && fail "stackedOn rode a request that had none: $out"
  [[ "$out" == *"requestId payload changed; this is not a retry"* ]] || fail "$out"
}

@test "two repos of one Entire project keep their trails apart on the board, in dispatch and in a desk's report" {
  local out other="$HOME/Work/web"
  spawn_ok
  git init -q -b main "$other"
  git -C "$other" remote add origin entire://entire.example/et/proj/web
  printf '%s\n' "$REPO" "$other" >"$XDG_STATE_HOME/bercail/shep/repos"
  trail 1 "App only" open review "" app
  trail 2 "Web only" open review "" web
  out="$(bercail shep board)" || fail "board: $out"
  [[ "$out" == *"~/Work/app: 1 job"*"- trail:1: App only"*"~/Work/web: 1 job"*"- trail:2: Web only"* ]] || fail "board: $out"
  [[ "$(grep -c 'trail:1' <<<"$out")" == 1 && "$(grep -c 'trail:2' <<<"$out")" == 1 ]] || fail "a trail is under both repos: $out"
  out="$(dispatch '.target = "trail:2"' 2>&1)" && fail "app's checkout took web's trail: $out"
  [[ "$out" == *"trail:2 is not a trail of $REPO; use the checkout of the repo it belongs to"* ]] || fail "wrong repo: $out"
  # A desk in the wrong checkout cannot put its report in this repo's comments.
  out="$(cd "$other" && printf 'report' | bercail job comment trail:1 2>&1)" && fail "web's checkout commented on app's trail: $out"
  [[ "$out" == *"trail:1 is not a trail of"*"/Work/web"* ]] || fail "wrong checkout: $out"
  # A question binds to the trail project-wide, by its Entire id, whatever the checkout's local comments hold.
  mkdir -p "$(dirname "$(record_file 2.comments.jsonl)")"
  printf 'not json\n' >"$(record_file 2.comments.jsonl)"
  out="$(bercail job id trail:2 --repo "$REPO")" || fail "job id: $out"
  jq -e '. == {id: "trail:2", trail_id: "T2", url: "https://entire.example/et/proj/-/trails/2"}' <<<"$out" >/dev/null || fail "job id: $out"
}


@test "shep bg and mistake take a trail where they take a beads id, and a trail's worker is named by its repo" {
  local out app share="$HOME/.local/share/bercail"
  # shep bg: Pi on the lead's guard, told to read the trail through bercail job.
  mkdir -p "$share/shep/pi" "$share/pi"
  cp "$ROOT/shep/BACKGROUND.md" "$share/shep/"
  cp "$ROOT/shep/pi/"*.ts "$share/shep/pi/"
  touch "$BATS_TEST_TMPDIR/guard.ts"
  jq -n --arg guard "$BATS_TEST_TMPDIR/guard.ts" '["pi","--model","fake/lead","-e",$guard]' >"$share/pi/lead.json"
  trail 3 "Wait for the trail's gates" open planning
  app="shep-bg-app-$(printf '%s' "$REPO" | sha256sum | cut -c1-4)-trail-3"
  out="$(bercail shep bg --issue trail:3 --cwd "$REPO")" || fail "bg: $out"
  jq -e --arg n "$app" '.name == $n and .issue == "trail:3" and .issue_title == "Wait for the trail'"'"'s gates"' <<<"$out" >/dev/null \
    || fail "bg: $out"
  grep -qx 'bercail.issue=trail:3' "$HC_DATA/run" || fail "label: $(cat "$HC_DATA/run")"
  grep -qx 'Your job is trail:3: Wait for the trail'"'"'s gates. Run `bercail job show trail:3` (its body and comments) and do exactly what it describes, then stop.' \
    "$HC_DATA/run" || fail "prompt: $(cat "$HC_DATA/run")"
  # Its worker is live: the same trail from a worktree of the repo is the same worker.
  printf '{"address":"t20","state":"live"}\n' >"$HC_DATA/$app.json"
  git -C "$REPO" worktree add -qb wait "$REPO.wait"
  out="$(bercail shep bg --issue trail:3 --cwd "$REPO.wait" 2>&1)" && fail "a second app trail:3 started: $out"
  [[ "$out" == *"$app is already running"* ]] || fail "live name: $out"
  # A repo of the same name in another project has its own trail 3, and its own worker.
  mkdir -p "$HOME/Other" "$TRAILS.proj2"
  git init -q -b main "$HOME/Other/app"
  git -C "$HOME/Other/app" remote add origin entire://entire.example/et/proj2/app
  cp "$TRAILS/3.json" "$TRAILS.proj2/3.json"
  out="$(bercail shep bg --issue trail:3 --cwd "$HOME/Other/app")" || fail "bg in the other app: $out"
  jq -e --arg n "$app" '.name != $n and (.name | test("^shep-bg-app-[0-9a-f]{4}-trail-3$"))' <<<"$out" >/dev/null || fail "other bg: $out"
  out="$(bercail shep bg --issue trail:8 --cwd "$REPO" 2>&1)" && fail "bg on a missing trail: $out"
  [[ "$out" == *"Entire has no trail:8 for $REPO"* ]] || fail "missing trail: $out"

  # mistake: the ledger keeps the trail.
  bercail shep mistake group G1 "Wrong trail" --against process >/dev/null
  bercail shep mistake wrong-trail "Read trail:3's gates on the wrong head" --group G1 --repo "$REPO" --issue trail:3 >/dev/null
  jq -e '.issue == "trail:3"' "$XDG_STATE_HOME/bercail/shep/mistakes.jsonl" >/dev/null || fail "mistake: $(cat "$XDG_STATE_HOME/bercail/shep/mistakes.jsonl")"
  out="$(bercail shep mistake wrong-trail "x" --issue 'trail:x;y' 2>&1)" && fail "a bad id passed: $out"
  [[ "$out" == *"is neither a beads id nor a trail (trail:N)"* ]] || fail "bad id: $out"
}

# origin_up: origin's entire:// URL reaches a bare repo here, through a stand-in for
# Entire's git remote helper, and holds main.
origin_up() {
  export ORIGIN_GIT="$BATS_TEST_TMPDIR/origin.git"
  [[ -d "$ORIGIN_GIT" ]] && return
  cat >"$BATS_TEST_TMPDIR/bin/git-remote-entire" <<'EOF'
#!/usr/bin/env bash
while read -r cmd arg; do
  case "$cmd" in
    capabilities) printf 'connect\n\n' ;;
    connect) printf '\n'; exec git "${arg#git-}" "$ORIGIN_GIT" ;;
    *) exit 1 ;;
  esac
done
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/git-remote-entire"
  git init -q --bare "$ORIGIN_GIT"
  git -C "$REPO" push -q origin main
}

# changes N 'R/C:STATUS'...: trail N's changes, in the repo/number form entire shows,
# each with its branch b<C> on origin at main's tip, the head Entire shows.
changes() {
  local n="$1" c list="[]"
  shift
  origin_up
  for c in "$@"; do
    git -C "$REPO" push -q origin "main:refs/heads/b$(cut -d/ -f2 <<<"${c%%:*}")"
    list="$(jq -c --arg r "${c%%/*}" --argjson num "$(cut -d/ -f2 <<<"${c%%:*}")" --arg s "${c##*:}" \
      --arg head "$(git -C "$REPO" rev-parse main)" \
      '. + [{repository: $r, repositoryId: "R-\($r)", number: $num, branch: "b\($num)", base: "main", status: $s, url: "u",
        mergeability: {head_sha: $head}}]' <<<"$list")"
  done
  jq --argjson c "$list" '.changes = $c' "$TRAILS/$n.json" >"$TRAILS/t" && mv "$TRAILS/t" "$TRAILS/$n.json"
}

@test "job merge merges a trail's one open change and closes the trail in the same step" {
  local out
  trail 3 "Ship the export" open building
  changes 3 app/9:open app/7:merged
  out="$(cd "$REPO" && bercail job merge trail:3)" || fail "merge: $out"
  [[ "$out" == "merged app/9; closed trail:3" ]] || fail "merge: $out"
  grep -q '^entire trail merge app/9$' "$LOG" || fail "no merge of the change: $(cat "$LOG")"
  jq -e '.status == "closed" and (.changes | all(.status == "merged"))' "$TRAILS/3.json" >/dev/null || fail "$(cat "$TRAILS/3.json")"
  # Merged on entire.com and left open: job merge names the close, and writes nothing.
  trail 4 "Merged by hand" open complete
  changes 4 app/12:merged
  : >"$LOG"
  out="$(cd "$REPO" && bercail job merge trail:4 2>&1)" && fail "merged by hand passed: $out"
  [[ "$out" == *"trail:4 has no open change: its work is merged; close it with entire trail update 4 --status closed once"* ]] || fail "$out"
  ! grep -qE '^entire trail (merge|update)' "$LOG" || fail "$(cat "$LOG")"
}

@test "job merge keeps the trail open while a change in any repo is open, and asks which change when it has several" {
  local out
  trail 3 "Two repos" open building
  changes 3 app/9:open api/10:open
  out="$(cd "$REPO" && bercail job merge trail:3 2>&1)" && fail "merged with two open changes: $out"
  [[ "$out" == *"trail:3 has 2 open changes (app/9, api/10); pass the one to merge with --change"* ]] || fail "$out"
  out="$(cd "$REPO" && bercail job merge trail:3 --change app/8 2>&1)" && fail "merged a change not on the trail: $out"
  [[ "$out" == *"app/8 is not an open change of trail:3"* ]] || fail "$out"
  ! grep -q '^entire trail merge' "$LOG" || fail "a refused merge ran: $(cat "$LOG")"
  out="$(cd "$REPO" && bercail job merge trail:3 --change app/9)" || fail "merge: $out"
  [[ "$out" == "merged app/9; trail:3 stays open for api/10" ]] || fail "$out"
  jq -e '.status == "open"' "$TRAILS/3.json" >/dev/null || fail "closed with api/10 open: $(cat "$TRAILS/3.json")"
}

@test "job merge refuses a change behind its base on origin, whose merged tree no gate checked, and merges it once it holds the base" {
  local out head
  trail 3 "Add r2 buckets" open building
  changes 3 app/9:open
  git -C "$REPO" config user.email s@example.invalid
  git -C "$REPO" switch -qc b9
  git -C "$REPO" commit -q --allow-empty -m "r2 buckets"
  head="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" push -q origin b9
  # Another trail merged onto main meanwhile, from another clone: this one has not seen it.
  git clone -q -b main "$ORIGIN_GIT" "$BATS_TEST_TMPDIR/other"
  git -C "$BATS_TEST_TMPDIR/other" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m "strict schema"
  git -C "$BATS_TEST_TMPDIR/other" push -q origin main
  jq --arg h "$head" '.changes[0].mergeability.head_sha = $h' "$TRAILS/3.json" >"$TRAILS/t" && mv "$TRAILS/t" "$TRAILS/3.json"
  : >"$LOG"
  out="$(cd "$REPO" && bercail job merge trail:3 2>&1)" && fail "merged behind its base: $out"
  [[ "$out" == *"app/9 at ${head:0:12} is behind main on origin ($(git -C "$ORIGIN_GIT" rev-parse --short=12 main)): merging it now would put a tree on main that no check ran on"* ]] || fail "$out"
  [[ "$out" == *"entire trail update-branch app/9"*"nothing was merged or closed" ]] || fail "$out"
  ! grep -qE '^entire trail (merge|update)' "$LOG" || fail "a change behind its base was merged: $(cat "$LOG")"
  # The branch merges main in: its new head holds the base, so it merges.
  git -C "$REPO" pull -q --no-rebase --no-edit origin main
  git -C "$REPO" push -q origin b9
  jq --arg h "$(git -C "$REPO" rev-parse HEAD)" '.changes[0].mergeability.head_sha = $h' "$TRAILS/3.json" >"$TRAILS/t" && mv "$TRAILS/t" "$TRAILS/3.json"
  out="$(cd "$REPO" && bercail job merge trail:3)" || fail "merge once up to date: $out"
  [[ "$out" == "merged app/9; closed trail:3" ]] || fail "$out"
}

@test "job merge checks the base only where it can: no head yet, another repo's change, a head origin's branch moved past, a shallow clone, or an origin it cannot read merge nothing" {
  local out
  trail 3 "Two repos" open building
  changes 3 app/9:open api/10:open
  out="$(cd "$REPO" && bercail job merge trail:3 --change api/10 2>&1)" && fail "merged another repo's change: $out"
  [[ "$out" == *"api/10 is a change of api, not of $REPO: merge it from a checkout of api"* ]] || fail "$out"
  jq '.changes[0].mergeability = null' "$TRAILS/3.json" >"$TRAILS/t" && mv "$TRAILS/t" "$TRAILS/3.json"
  out="$(cd "$REPO" && bercail job merge trail:3 --change app/9 2>&1)" && fail "merged with no head: $out"
  [[ "$out" == *"entire trail show gives no head commit, branch and base for app/9 yet"* ]] || fail "$out"
  # Entire shows a head the branch on origin has moved past: its gates are of another tree.
  changes 3 app/9:open
  git -C "$REPO" config user.email s@example.invalid
  git -C "$REPO" commit -q --allow-empty -m "after the gates"
  git -C "$REPO" push -q origin HEAD:refs/heads/b9
  out="$(cd "$REPO" && bercail job merge trail:3 2>&1)" && fail "merged a head origin's branch is not at: $out"
  [[ "$out" == *"origin's b9 is $(git -C "$REPO" rev-parse --short=12 HEAD), not $(git -C "$REPO" rev-parse --short=12 HEAD~1), the head Entire shows"* ]] || fail "$out"
  # A shallow clone lacks the history that joins the branch to main: unknown, not behind.
  git clone -q --depth 1 -b b9 "file://$ORIGIN_GIT" "$HOME/Work/shallow"
  git -C "$HOME/Work/shallow" remote set-url origin entire://entire.example/et/proj/app
  jq --arg h "$(git -C "$REPO" rev-parse HEAD)" '.changes[0].mergeability.head_sha = $h' "$TRAILS/3.json" >"$TRAILS/t" && mv "$TRAILS/t" "$TRAILS/3.json"
  out="$(cd "$HOME/Work/shallow" && bercail job merge trail:3 2>&1)" && fail "merged from a shallow clone: $out"
  [[ "$out" == *"is a shallow clone, so whether app/9 holds main's tip is not known: git fetch --unshallow origin there"* ]] || fail "$out"
  rm -rf "$ORIGIN_GIT"
  out="$(cd "$REPO" && bercail job merge trail:3 2>&1)" && fail "merged with origin unreadable: $out"
  [[ "$out" == *"could not check app/9 against main on origin: "*"; nothing was merged or closed" ]] || fail "$out"
  ! grep -q '^entire trail merge' "$LOG" || fail "$(cat "$LOG")"
}

@test "job merge closes nothing when Entire refuses the merge, names the close when it fails, and leaves a closed trail alone" {
  local out
  trail 3 "Held" open building
  changes 3 app/9:open
  out="$(cd "$REPO" && MERGE_HELD=1 bercail job merge trail:3 2>&1)" && fail "a held merge passed: $out"
  [[ "$out" == *"entire trail merge app/9 failed in $REPO, and nothing was closed:"*"blocking gates pending: approvals"* ]] || fail "$out"
  ! grep -q '^entire trail update' "$LOG" || fail "a held merge closed the trail: $(cat "$LOG")"
  # The close fails after the merge: it says so, and names the close to run.
  out="$(cd "$REPO" && UPDATE_DOWN=1 bercail job merge trail:3 2>&1)" && fail "a failed close passed: $out"
  [[ "$out" == *"merged app/9, but trail:3 is not closed: "*"network is unreachable"*"; close it with entire trail update 3 --status closed once entire trail show 3 shows no open change" ]] || fail "$out"
  jq -e '.status == "open" and .changes[0].status == "merged"' "$TRAILS/3.json" >/dev/null || fail "$(cat "$TRAILS/3.json")"
  (cd "$REPO" && entire trail update 3 --status closed --json >/dev/null)
  : >"$LOG"
  out="$(cd "$REPO" && bercail job merge trail:3)" || fail "closed rerun: $out"
  [[ "$out" == "trail:3 is already closed" ]] || fail "closed rerun: $out"
  # A closed trail with a change still open is not merged until it is reopened.
  changes 3 app/9:merged api/11:open
  out="$(cd "$REPO" && bercail job merge trail:3 2>&1)" && fail "merged into a closed trail: $out"
  [[ "$out" == *"trail:3 is closed with api/11 open; reopen it with entire trail update 3 --status open first"* ]] || fail "$out"
  ! grep -qE '^entire trail (merge|update)' "$LOG" || fail "a closed trail was written: $(cat "$LOG")"

  # Entire leaves the list out when there are none; another shape is not an empty one.
  trail 5 "Nothing shipped" open planning
  jq 'del(.changes)' "$TRAILS/5.json" >"$TRAILS/t" && mv "$TRAILS/t" "$TRAILS/5.json"
  out="$(cd "$REPO" && bercail job merge trail:5 2>&1)" && fail "merged a trail with no change: $out"
  [[ "$out" == *"trail:5 has no change to merge; when its work landed elsewhere, close it with bercail job supersede trail:5"* ]] || fail "$out"
  trail 4 "No list" open building
  jq '.changes = {"app/9": "merged"}' "$TRAILS/4.json" >"$TRAILS/t" && mv "$TRAILS/t" "$TRAILS/4.json"
  : >"$LOG"
  out="$(cd "$REPO" && bercail job merge trail:4 2>&1)" && fail "merged with changes of another shape: $out"
  [[ "$out" == *"entire trail show for trail:4 returned changes that are not a list; nothing was merged or closed"* ]] || fail "$out"
  ! grep -qE '^entire trail (merge|update)' "$LOG" || fail "$(cat "$LOG")"
}

@test "job supersede closes a trail with a line pointing at the trail or commit that holds its work" {
  local out sha
  trail 41 "run_check crop" open planning "Crop run_check."
  trail 25 "Wave 2 checks" closed closed
  out="$(cd "$REPO" && bercail job supersede trail:41 --with trail:25)" || fail "supersede: $out"
  [[ "$out" == "closed trail:41: Superseded by: #25 https://entire.example/et/proj/-/trails/25" ]] || fail "$out"
  jq -e '.status == "closed" and .body == "Crop run_check.\n\nSuperseded by: #25 https://entire.example/et/proj/-/trails/25"' \
    "$TRAILS/41.json" >/dev/null || fail "$(cat "$TRAILS/41.json")"
  # A rerun keeps one pointer.
  (cd "$REPO" && bercail job supersede trail:41 --with trail:25 >/dev/null) || fail "rerun"
  [[ "$(jq -r .body "$TRAILS/41.json" | grep -c '^Superseded by:')" == 1 ]] || fail "$(cat "$TRAILS/41.json")"

  trail 42 "Plan" open planning
  sha="$(git -C "$REPO" rev-parse HEAD)"
  out="$(cd "$REPO" && bercail job supersede trail:42 --with "${sha:0:7}")" || fail "commit: $out"
  jq -e --arg s "$sha" '.status == "closed" and .body == "Superseded by: commit \($s)"' "$TRAILS/42.json" >/dev/null \
    || fail "$(cat "$TRAILS/42.json")"

  trail 43 "Plan" open planning
  : >"$LOG"
  out="$(cd "$REPO" && bercail job supersede trail:43 --with nope 2>&1)" && fail "a pointer to nothing passed: $out"
  [[ "$out" == *"--with nope is neither trail:<n> nor a commit of $REPO"* ]] || fail "$out"
  out="$(cd "$REPO" && bercail job supersede trail:43 --with trail:43 2>&1)" && fail "$out"
  [[ "$out" == *"trail:43 cannot supersede itself"* ]] || fail "$out"
  ! grep -q '^entire trail update' "$LOG" || fail "a refused supersede wrote the trail: $(cat "$LOG")"
}
