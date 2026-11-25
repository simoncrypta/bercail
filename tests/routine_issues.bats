#!/usr/bin/env bats
# The issues routine (lib/routine/issues.sh): which issue it offers from a
# stand-in bd or source command, and when it offers none, run as bercail
# routine run runs it. Stand-ins for hc, bd and the clock; real git, the real
# runner, the real review queue and the real question ledger. Each @test is
# its own HOME.

DAY=1795478400 # 2026-11-24 00:00 UTC

assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected '$1' got '$2'"; }

setup() {
  load test_helper
  isolate
  need git jq flock sha256sum node
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH" TZ=UTC
  export HC_DATA="$BATS_TEST_TMPDIR/hc" HC_BIN="$BATS_TEST_TMPDIR/bin/hc"
  # No Herdr window: the queue calls no worktree stale.
  export HERDR_APP_BIN="$BATS_TEST_TMPDIR/no-herdr-app"
  # The queue's wait is for a person; a loaded test machine must not make it UNKNOWN.
  export BERCAIL_SHEP_QUEUE_WAIT=120
  STATE="$XDG_STATE_HOME/bercail/shep" ROUTINE="$XDG_STATE_HOME/bercail/routines/issues"
  RECORDS="$XDG_STATE_HOME/bercail/handoffs.jsonl" CONFIG="$XDG_CONFIG_HOME/bercail/config.toml"
  ERR="$BATS_TEST_TMPDIR/err"
  mkdir -p "$HC_DATA" "$STATE/inbox" "$XDG_CONFIG_HOME/bercail"
  echo '[]' >"$HC_DATA/terminals.json"
  printf '[routine.issues]\nrun = "issues"\nevery = "4h"\nrepo = "~/Work/app"\n' >"$CONFIG"

  # hc: terminals in $HC_DATA/terminals.json, each {address, state, cwd, status,
  # labels}. ls, like the real one, prints no labels and filters by them; get
  # prints the whole terminal. $HC_DATA/status: the status every call ends with.
  cat >"$HC_BIN" <<'SH'
#!/usr/bin/env bash
[[ ! -f "$HC_DATA/status" ]] || exit "$(cat "$HC_DATA/status")"
case "$1" in
  ls)
    want=()
    while [[ $# -gt 0 ]]; do [[ "$1" != --label ]] || want+=("$2"); shift; done
    jq --args '{terminals: [.[] | select(. as $t | $ARGS.positional
        | all(split("=") as [$k, $v] | $t.labels[$k] == $v)) | {address, state, cwd}]}' \
      "${want[@]}" <"$HC_DATA/terminals.json" ;;
  get) jq -e --arg a "$2" '.[] | select(.address == $a)' "$HC_DATA/terminals.json" ;;
  *) exit 2 ;;
esac
SH
  # bd answers from .beads/fake of the repo it runs in, and logs its arguments
  # in argv there. ready lists issues.json whole, whatever -l names: the label
  # and the status are the routine's to check too. show prints one issue, list
  # them all. A status file there: the status every call ends with. ready.json,
  # when there: what ready prints instead.
  cat >"$BATS_TEST_TMPDIR/bin/bd" <<'SH'
#!/usr/bin/env bash
dir="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")/.beads/fake"
printf '%s\n' "$*" >>"$dir/argv"
[[ ! -f "$dir/status" ]] || exit "$(cat "$dir/status")"
case "$1" in
  ready) cat "$dir/ready.json" 2>/dev/null || cat "$dir/issues.json" ;;
  show) jq -e --arg id "$2" '[.[] | select(.id == $id)] | select(length == 1)' "$dir/issues.json" ;;
  list) cat "$dir/issues.json" ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$HC_BIN" "$BATS_TEST_TMPDIR/bin/bd"

  # app: the repo the routine reads. other: another repo, with its own beads.
  for repo in app other; do
    git_init "$HOME/Work/$repo"
    mkdir -p "$HOME/Work/$repo/.beads/fake"
    printf '.beads/\n' >>"$HOME/Work/$repo/.git/info/exclude"
    echo '[]' >"$HOME/Work/$repo/.beads/fake/issues.json"
  done
  APP="$(cd "$HOME/Work/app" && pwd -P)" OTHER="$(cd "$HOME/Work/other" && pwd -P)"
  clock $((DAY + 36000))
}

# clock EPOCH: date +%s says EPOCH from now on.
clock() {
  printf '#!/bin/sh\n[ "$1" = "+%%s" ] && echo %s || exec %s "$@"\n' "$1" "$(PATH=/usr/bin:/bin command -v date)" \
    >"$BATS_TEST_TMPDIR/bin/date"
  chmod +x "$BATS_TEST_TMPDIR/bin/date"
}

# issue ID PRIORITY CREATED [FIELDS-JSON] [REPO]: an open issue of app, or of
# REPO, labelled routine, as bd ready --json --brief prints one. FIELDS replaces
# or adds fields.
issue() {
  local file="${5:-$APP}/.beads/fake/issues.json"
  jq --arg id "$1" --argjson p "$2" --arg c "$3" --argjson more "${4:-null}" \
    '. + [{id: $id, title: "Issue \($id)", status: "open", priority: $p, issue_type: "task", created_at: $c,
           updated_at: $c, labels: ["routine"], dependency_count: 0, dependent_count: 0, comment_count: 0} + ($more // {})]' \
    "$file" >"$file.tmp"
  mv "$file.tmp" "$file"
}

# desk ADDR CWD STATE [ISSUE] [LABELS-JSON]: a live desk, as hc get prints one.
desk() {
  jq --arg a "$1" --arg cwd "$2" --arg s "$3" --arg i "${4:-}" --argjson more "${5:-null}" \
    '. + [{address: $a, name: null, state: "live", cwd: $cwd, status: {app: "pi", state: $s},
           labels: ({"bercail.role": "agent"} + (if $i == "" then {} else {"bercail.issue": $i} end) + ($more // {}))}]' \
    "$HC_DATA/terminals.json" >"$HC_DATA/terminals.tmp"
  mv "$HC_DATA/terminals.tmp" "$HC_DATA/terminals.json"
}

# card ISSUE [TOPIC] [REPO]: the routine's Start card on ISSUE, asked through
# the real question CLI as Shep asks it; prints its token.
card() {
  jq -nc --arg i "$1" --arg t "${2:-routine:issues}" --arg repo "${3:-$APP}" '{requestId: "ask-\($i)-\($t)-\($repo)",
      kind: "planning", prompt: "Start a desk on \($i)?", options: ["Start", "Not now", "Skip this issue"],
      origin: {event: "routine:issues:20261124T100000Z", session: "shep-1", entry: null},
      repo: $repo, issue: $i, topic: $t, desk: null, base: null, action: null}' \
    | "$ROOT/bin/bercail" shep question create | jq -r '"\(.id)@\(.revision)"'
}

# ledger [JQ ARGS...] FILTER: rewrite the question ledger with JQ.
ledger() {
  jq "$@" "$STATE/questions.json" >"$STATE/questions.tmp" && mv "$STATE/questions.tmp" "$STATE/questions.json"
}

# answered TOKEN CHOICE AT: the person picked CHOICE on the panel, at AT.
answered() {
  jq -nc --arg t "$1" --arg c "$2" '{requestId: "pick-\($t)", token: $t, choice: $c, source: "panel picker"}' \
    | "$ROOT/bin/bercail" shep question answer >/dev/null || fail "answer $1" || return
  ledger --arg id "${1%@*}" --arg at "$3" '(.questions[] | select(.id == $id) | .answer.at) = $at'
}

# withdrawn TOKEN AT: Shep withdrew the card, at AT.
withdrawn() {
  jq -nc --arg t "$1" '{requestId: "drop-\($t)", token: $t, reason: "moot"}' \
    | "$ROOT/bin/bercail" shep question withdraw >/dev/null || fail "withdraw $1" || return
  ledger --arg id "${1%@*}" --arg at "$2" '(.questions[] | select(.id == $id) | .withdrawal.at) = $at'
}

routine() { "$ROOT/bin/bercail" routine "$@"; }
# What the query prints, run as the runner runs it: from HOME, nothing on stdin.
query() { (cd "$HOME" && bash "$ROOT/lib/routine/issues.sh" issues </dev/null); }
# offers ID [DETAIL]: the query offers ID of app, and nothing else.
offers() {
  local out
  out="$(query)" || fail "the query failed: $out" || return
  assert_eq "$(jq -nc --arg id "$1" --arg d "${2-P2, created 2026-11-01}" --arg repo "$APP" \
    '{key: "issue:\($id)", title: "\($id): Issue \($id)", detail: $d, repo: $repo, issue: $id}')" "$out" "the finding"
}
# loaded WHY: under load the query offers nothing: status 75, WHY alone on
# stderr, nothing on stdout.
loaded() {
  local out rc=0
  out="$(query 2>"$ERR")" || rc=$?
  assert_eq 75 "$rc" "the query's status ($(cat "$ERR"))" || return
  assert_eq "" "$out" "its stdout" || return
  assert_eq "$1" "$(cat "$ERR")" "its stderr"
}
# fails WHY: the query fails, with status 1 and never load's 75, and WHY is
# the last line on stderr.
fails() {
  local out rc=0
  out="$(query 2>"$ERR")" || rc=$?
  assert_eq 1 "$rc" "the query's status ($(cat "$ERR"))" || return
  assert_eq "" "$out" "its stdout" || return
  assert_eq "error: $1" "$(tail -n 1 "$ERR")" "its last line on stderr"
}
# source_command BODY: the routine reads its issues from a script with BODY.
source_command() {
  mkdir -p "$HOME/bin"
  printf '#!/usr/bin/env bash\n%s\n' "$1" >"$HOME/bin/issues"
  chmod +x "$HOME/bin/issues"
  printf 'source = "command"\nsource_command = ["~/bin/issues", "--ready"]\n' >>"$CONFIG"
}

@test "the issues routine offers the ready issue of highest priority, then the oldest, with its repo and issue" {
  issue app-1 2 2026-11-01T08:00:00Z
  issue app-2 1 2026-11-03T08:00:00Z
  # Created an hour before app-4, though its text sorts after: an offset, and a fraction.
  issue app-3 1 2026-11-02T10:00:00.5+02:00
  issue app-4 1 2026-11-02T09:00:00Z
  issue app-5 3 2026-10-01T08:00:00Z
  offers app-3 "P1, created 2026-11-02"
  assert_eq "ready --json --limit 0 --brief -l routine" "$(cat "$APP/.beads/fake/argv")" "what it asked bd, in app"
}

@test "the issues routine offers nothing when no issue is ready" {
  local out
  out="$(query 2>&1)" || fail "the query failed: $out"
  assert_eq "" "$out" "what it prints"
}

@test "the issues routine never offers an issue without its label, or one that is not open" {
  local out
  issue app-1 0 2026-11-01T08:00:00Z '{"labels": ["night"]}'
  issue app-2 0 2026-11-01T08:00:00Z '{"labels": []}'
  issue app-3 0 2026-11-01T08:00:00Z '{"status": "in_progress"}'
  out="$(query 2>&1)" || fail "the query failed: $out"
  assert_eq "" "$out" "what it prints"
}

@test "the issues routine reads the label its entry names" {
  printf 'label = "night"\n' >>"$CONFIG"
  issue app-1 1 2026-11-01T08:00:00Z
  issue app-2 2 2026-11-01T08:00:00Z '{"labels": ["night"]}'
  offers app-2
  assert_eq "ready --json --limit 0 --brief -l night" "$(cat "$APP/.beads/fake/argv")" "what it asked bd"
}

@test "the issues routine skips an issue with a live desk on it, not one whose desk is in another repo" {
  issue app-1 1 2026-11-01T08:00:00Z
  issue app-2 2 2026-11-01T08:00:00Z
  desk t1 "$OTHER" idle app-1
  offers app-1 "P1, created 2026-11-01"
  desk t2 "$APP" idle app-1
  offers app-2
}

@test "the issues routine skips an issue with a handoff record in its repo, its checkout there or gone, not one of another repo" {
  issue app-1 1 2026-11-01T08:00:00Z
  issue app-2 1 2026-11-02T08:00:00Z
  issue app-3 2 2026-11-01T08:00:00Z
  git -C "$APP" worktree add -q -b fix "$APP.fix"
  printf 'not json\n{}\n' >"$RECORDS"
  fails "could not read $RECORDS"  # Dispatch cannot establish ownership either.
  : >"$RECORDS"
  jq -nc --arg p "$OTHER" '{v: 1, path: $p, issue: "app-1"}, {v: 1, path: $p, issue: "app-2"}' >>"$RECORDS"
  offers app-1 "P1, created 2026-11-01"
  jq -nc --arg p "$APP.fix" --arg gone "$APP.gone" --arg r "$APP" \
    '{v: 1, path: $p, branch: "fix", issue: "app-1"}, {v: 1, path: $gone, branch: "gone", issue: "app-2", repo: $r}' >>"$RECORDS"
  offers app-3
}

@test "the issues routine skips an issue a dispatch recorded its task on" {
  issue app-1 1 2026-11-01T08:00:00Z '{"metadata": {"bercail_task": {"v": 2, "owner": null}}}'
  issue app-2 2 2026-11-01T08:00:00Z
  offers app-2
}

@test "the issues routine does not offer an issue said Not now to for 7 days, then offers it again and names that card" {
  local token
  issue app-1 1 2026-11-01T08:00:00Z
  issue app-2 2 2026-11-01T08:00:00Z
  token="$(card app-1)"
  answered "$token" "Not now" 2026-11-24T10:00:00.000Z
  clock $((DAY + 36000 + 7 * 86400 - 1))
  offers app-2
  clock $((DAY + 36000 + 7 * 86400))
  offers app-1 "P1, created 2026-11-01; asked before as $token: Not now on 2026-11-24"
}

@test "the issues routine never offers an issue said Skip this issue to" {
  issue app-1 1 2026-11-01T08:00:00Z
  issue app-2 2 2026-11-01T08:00:00Z
  answered "$(card app-1)" "Skip this issue" 2026-11-24T10:00:00.000Z
  clock $((DAY + 400 * 86400))
  offers app-2
}

@test "the issues routine takes a Not now only from its own card: not another topic's, another repo's, or one still waiting" {
  issue app-1 1 2026-11-01T08:00:00Z
  issue app-1 1 2026-11-01T08:00:00Z "" "$OTHER"
  answered "$(card app-1 routine:other)" "Not now" 2026-11-24T10:00:00.000Z
  answered "$(card app-1 routine:issues "$OTHER")" "Not now" 2026-11-24T10:00:00.000Z
  card app-1 >/dev/null
  offers app-1 "P1, created 2026-11-01"
}

@test "the issues routine keeps an issue said Start to its pick while no desk or record has it, and names a card withdrawn" {
  local start gone
  issue app-1 1 2026-11-01T08:00:00Z
  start="$(card app-1)"
  answered "$start" Start 2026-11-24T09:00:00.000Z
  offers app-1 "P1, created 2026-11-01; asked before as $start: Start on 2026-11-24"
  ledger '.requests = []'
  gone="$(card app-1)"
  withdrawn "$gone" 2026-11-24T09:30:00.000Z
  offers app-1 "P1, created 2026-11-01; asked before as $gone: withdrawn on 2026-11-24"
}

@test "the issues routine offers nothing while 2 desks are working, wherever they are; one working, a background Shep and a done desk are no load" {
  issue app-1 2 2026-11-01T08:00:00Z
  desk t1 "$OTHER" working
  desk t2 "$APP" "done"
  desk t3 "$HOME" working "" '{"bercail.shep": "bg"}'
  offers app-1
  desk t4 "$HOME" working
  rm "$APP/.beads/fake/argv"
  loaded "2 desks are working (t1, t4)"
  [[ ! -e "$APP/.beads/fake/argv" ]] || fail "it read the source under load: $(cat "$APP/.beads/fake/argv")"
}

@test "only the desk created by a Start card holds the routine's desk slot" {
  issue app-1 2 2026-11-01T08:00:00Z
  issue app-2 2 2026-11-02T08:00:00Z '{"status": "in_progress"}'
  issue app-3 2 2026-11-03T08:00:00Z '{"status": "in_progress"}'
  # app-3's desk was started by hand: no card of the routine's says Start.
  desk t3 "$APP" idle app-3
  offers app-1
  local token file="$APP/.beads/fake/issues.json"
  token="$(card app-2)"
  desk t2 "$APP" "done" app-2
  answered "$token" Start 2026-11-24T09:00:00.000Z
  offers app-1  # The manual desk predates the answer; Start has not dispatched it.
  jq --arg token "$token" '(.[] | select(.id == "app-2")).metadata.bercail_task.creation =
    {id: $token, result: {desk: "t2"}}' "$file" >"$file.tmp"
  mv "$file.tmp" "$file"
  loaded "desk t2 on app-2, which it offered, is still open"
}

@test "the issues routine offers nothing while a test run waits for a slot, and a dead waiter's file is no load" {
  issue app-1 2 2026-11-01T08:00:00Z
  mkdir -p "$XDG_STATE_HOME/bercail/test-slots"
  # No pid is above the kernel's highest, 2^22.
  echo 'tests/run.sh, gone' >"$XDG_STATE_HOME/bercail/test-slots/wait.4194305"
  offers app-1
  echo 'tests/run.sh, waiting' >"$XDG_STATE_HOME/bercail/test-slots/wait.$$"
  loaded "a test run waits for a slot"
  [[ -e "$XDG_STATE_HOME/bercail/test-slots/wait.4194305" ]] || fail "the routine removed a waiter's file: it only reads"
}

@test "the issues routine offers nothing while the repo's review queue is over its review budget" {
  issue app-1 2 2026-11-01T08:00:00Z
  issue app-9 2 2026-10-01T08:00:00Z '{"status": "in_progress"}'
  mkdir -p "$APP/.bercail"
  printf 'review_budget = 6\n' >"$APP/.bercail/policy.toml"
  git -C "$APP" add .bercail/policy.toml
  git -C "$APP" commit -qm policy
  # app-9's desk is done, with 6 lines staged for the person's review.
  git -C "$APP" worktree add -q -b export "$APP.export"
  seq 1 6 >"$APP.export/export.txt"
  git -C "$APP.export" add export.txt
  jq -nc --arg p "$APP.export" '{v: 1, path: $p, branch: "export", issue: "app-9", desk: "t9"}' >"$RECORDS"
  desk t9 "$APP.export" "done" app-9
  offers app-1
  seq 1 7 >"$APP.export/export.txt"
  git -C "$APP.export" add export.txt
  loaded "7 lines wait on review in $APP, over its budget of 6"
}

@test "the issues routine fails, and is never under load, when hc does not list the desks, even with status 75" {
  issue app-1 2 2026-11-01T08:00:00Z
  echo 75 >"$HC_DATA/status"
  fails "hc did not list the desks"
}

@test "the issues routine fails when bd does not list the issues, even with status 75, or lists something else" {
  issue app-1 2 2026-11-01T08:00:00Z
  echo 75 >"$APP/.beads/fake/status"
  fails "bd could not list the ready issues of $APP (bd ready --json -l routine, status 75)"
  rm "$APP/.beads/fake/status"
  for body in '' 'null' '{"id": "app-1"}' '[1]' 'not json'; do
    printf '%s\n' "$body" >"$APP/.beads/fake/ready.json"
    fails "bd listed the ready issues of $APP as something other than a JSON array of issues" || fail "for: $body"
  done
}

@test "the issues routine fails when the question ledger cannot be read" {
  issue app-1 2 2026-11-01T08:00:00Z
  echo 'not a ledger' >"$STATE/questions.json"
  fails "the question ledger could not be read (bercail shep questions --json --all)"
}

@test "the issues routine fails when its repo is not a git checkout" {
  printf '[routine.issues]\nrun = "issues"\nevery = "4h"\nrepo = "~/Work/nowhere"\n' >"$CONFIG"
  fails "$HOME/Work/nowhere is not a git checkout; fix repo in [routine.issues] of $CONFIG"
}

@test "a source command runs in the repo with the label, and its issues are picked as bd's are" {
  issue app-2 1 2026-11-01T08:00:00Z
  desk t1 "$APP" idle app-2
  # shellcheck disable=SC2016 # expands in the script
  source_command 'printf "%s in %s for %s of %s\n" "$*" "$PWD" "$BERCAIL_ROUTINE_LABEL" "$BERCAIL_ROUTINE_REPO" >"$HOME/argv"
cat "$HOME/issues.jsonl"'
  jq -nc '{id: "app-1", title: "Issue app-1", priority: 2, url: "https://example.test/1", created: "2026-11-01T08:00:00Z"},
    {id: "app-2", title: "Issue app-2", priority: 1, url: null, created: "2026-11-01T08:00:00Z"},
    {id: "trail:7", title: "Issue trail:7", priority: null, created: null}' >"$HOME/issues.jsonl"
  offers app-1 "P2, created 2026-11-01, https://example.test/1"
  assert_eq "--ready in $APP for routine of $APP" "$(cat "$HOME/argv")" "how the command ran"
  [[ ! -e "$APP/.beads/fake/argv" ]] || fail "it asked bd too: $(cat "$APP/.beads/fake/argv")"
  desk t2 "$APP" idle app-1
  offers trail:7 ""
}

@test "a source command that fails, even with status 75, fails the routine and is never load" {
  source_command 'echo "{\"id\": \"app-1\", \"title\": \"Issue app-1\"}"; echo "no token" >&2; exit 75'
  fails "the source command $HOME/bin/issues failed (status 75)"
}

@test "a source command's line that is not an issue fails the routine: no object, id, title, or a field of another kind" {
  local line why
  # shellcheck disable=SC2016 # expands in the script
  source_command 'cat "$HOME/issues.jsonl"'
  while IFS='|' read -r line why; do
    printf '%s\n' '{"id": "app-1", "title": "Issue app-1"}' "$line" >"$HOME/issues.jsonl"
    fails "the command source printed bad output: $why" || fail "for: $line"
  done <<'EOF'
[]|line 2 is not a JSON object
not json|line 2 is not a JSON object
{"title": "No id"}|line 2 has no id that is a beads id or trail:N
{"id": "-rf", "title": "A flag"}|line 2 has no id that is a beads id or trail:N
{"id": "a b", "title": "A space"}|line 2 has no id that is a beads id or trail:N
{"id": "app-2"}|line 2 has no title
{"id": "app-2", "title": "T", "priority": "1"}|line 2: priority must be a number
{"id": "app-2", "title": "T", "url": 3}|line 2: url must be a string
{"id": "app-2", "title": "T", "created": "yesterday"}|line 2: created must be an RFC 3339 time
EOF
}

# The last run's line in runs.jsonl, its id and times left out.
last_run() { tail -n 1 "$ROUTINE/runs.jsonl" | jq -c 'del(.id, .due, .start, .end)'; }
# The routine's events in Shep's inbox: a card's answer is an event there too.
events() { find "$STATE/inbox" -name 'routine_issues_*.json' | wc -l; }

@test "a run under load is skipped (load): its slot is met, the earlier offer's hash is kept, and no event is sent" {
  local out sent start=$((DAY + 36000))
  issue app-1 2 2026-11-01T08:00:00Z
  out="$(routine run issues)" || fail "the first run: $out"
  [[ "$out" == "issues: emitted, 1 found (1 new, 0 changed); run "* ]] || fail "the first run: $out"
  sent="$(jq -c .sent "$ROUTINE/state.json")"
  jq -e 'has("issue:app-1")' <<<"$sent" >/dev/null || fail "the offer's hash is not kept: $sent"
  assert_eq "$((start + 4 * 3600))" "$(jq .next_due "$ROUTINE/state.json")" "next due after the first run"
  desk t1 "$HOME" working
  desk t2 "$HOME" working
  clock $((start + 4 * 3600))
  out="$(routine run issues)" || fail "the run under load: $out"
  [[ "$out" == "issues: skipped (load): 2 desks are working (t1, t2); run "* ]] || fail "the run under load: $out"
  assert_eq '{"outcome":"skipped","reason":"load","detail":"2 desks are working (t1, t2)","counts":null,"event":null,"error":null}' \
    "$(last_run)" "the run's line"
  assert_eq "$sent" "$(jq -c .sent "$ROUTINE/state.json")" "the hashes sent"
  assert_eq "$((start + 8 * 3600)) 0 false" "$(jq -r '"\(.next_due) \(.failures) \(.paused)"' "$ROUTINE/state.json")" \
    "next due, failures in a row, paused"
  assert_eq 1 "$(events)" "the events in Shep's inbox"
}

@test "a dry run under load says skipped (load) and writes nothing" {
  local out
  issue app-1 2 2026-11-01T08:00:00Z
  routine run issues >/dev/null
  desk t1 "$HOME" working
  desk t2 "$HOME" working
  sha256sum "$ROUTINE/state.json" "$ROUTINE/runs.jsonl" >"$BATS_TEST_TMPDIR/sums"
  out="$(routine run issues --dry-run)" || fail "the dry run: $out"
  assert_eq "issues: skipped (load): 2 desks are working (t1, t2); dry run, nothing written" "$out" "the dry run"
  sha256sum -c --quiet "$BATS_TEST_TMPDIR/sums" || fail "the dry run wrote the routine's state"
  assert_eq 1 "$(events)" "the events in Shep's inbox"
}

@test "a dry run prints the issue it would offer, for Shep's recheck before a dispatch" {
  local out
  issue app-1 2 2026-11-01T08:00:00Z
  out="$(routine run issues --dry-run)" || fail "the dry run: $out"
  assert_eq "issues: emitted, 1 found (1 new, 0 changed); dry run, nothing written
  new      issue:app-1  app-1: Issue app-1
           P2, created 2026-11-01 ($APP, app-1)" "$out" "the dry run"
  [[ ! -e "$ROUTINE/state.json" && "$(events)" -eq 0 ]] || fail "the dry run wrote state or an event"
  routine run issues >/dev/null
  out="$(routine run issues --dry-run)"
  [[ "$out" == *"skipped (quiet), 1 found"* && "$out" == *"same     issue:app-1"* ]] || fail "still eligible: $out"
}

@test "a run whose source command ends with status 75 failed: it is not skipped (load)" {
  local out rc=0
  source_command 'exit 75'
  out="$(routine run issues 2>&1)" || rc=$?
  assert_eq 1 "$rc" "the run's status ($out)"
  assert_eq "{\"outcome\":\"failed\",\"reason\":null,\"counts\":null,\"event\":null,\"error\":\"exit 1: error: the source command $HOME/bin/issues failed (status 75)\"}" \
    "$(last_run)" "the run's line"
  assert_eq 1 "$(jq .failures "$ROUTINE/state.json")" "failures in a row"
}

@test "an issue said Not now to is sent again once its 7 days are over, though no run between dropped its hash" {
  local out token start=$((DAY + 36000))
  issue app-1 2 2026-11-01T08:00:00Z
  routine run issues >/dev/null
  token="$(card app-1)"
  answered "$token" "Not now" 2026-11-24T10:00:00.000Z
  jq -e '.sent | has("issue:app-1")' "$ROUTINE/state.json" >/dev/null || fail "the first offer's hash is not kept"
  clock $((start + 7 * 86400))
  out="$(routine run issues)" || fail "the run after 7 days: $out"
  [[ "$out" == "issues: emitted, 1 found (0 new, 1 changed); run "* ]] || fail "the run after 7 days: $out"
  assert_eq 2 "$(events)" "the events in Shep's inbox"
}
