#!/usr/bin/env bats
# shellcheck disable=SC2088 # the expected output has literal ~/ paths
# What Shep knows beyond its session: known repos, the brief and the board,
# standing rules, its start context, and its compaction settings and extension.
# Stand-ins for hc, bd and pi; real git; a temp HOME. The live half runs the
# installed Pi with a scripted offline model.

setup() {
  load test_helper
  isolate
  set -o pipefail
  export HERDR_APP_BIN="$BATS_TEST_TMPDIR/no-herdr-app"
  export LOG="$BATS_TEST_TMPDIR/log" HC_DATA="$BATS_TEST_TMPDIR/hc"
  # The queue's 6s budget is for a person waiting; a loaded test machine must
  # not turn a fixture's queue into UNKNOWN (bercail-5wm8.33).
  export BERCAIL_SHEP_QUEUE_WAIT=120
  # Only the stand-ins, then the system bins; the live cases look for Pi on the old PATH.
  OLD_PATH="$PATH"
  export PATH="$BATS_TEST_TMPDIR/bin:/usr/bin:/bin"
  mkdir -p "$BATS_TEST_TMPDIR/bin" "$HC_DATA" "$HOME/Work" "$XDG_CONFIG_HOME/bercail" \
    "$XDG_STATE_HOME/bercail/shep"
  REAL_HOME="$(cd "$HOME" && pwd -P)"
  STATE="$XDG_STATE_HOME/bercail/shep"
  CONFIG="$XDG_CONFIG_HOME/bercail/config.toml"
  RECORDS="$XDG_STATE_HOME/bercail/handoffs.jsonl"
  printf '{"terminals":[]}\n' >"$HC_DATA/ls.json"

  # hc answers ls, get and read from $HC_DATA.
  cat >"$BATS_TEST_TMPDIR/bin/hc" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  ls) printf 'hc ls %s\n' "$*" >>"$LOG"; cat "$HC_DATA/ls.json" ;;
  get) cat "$HC_DATA/$2.json" 2>/dev/null || { printf '{"error":{"kind":"not_found"}}\n'; exit 5; } ;;
  read) cat "$HC_DATA/$2.screen" 2>/dev/null || exit 5 ;;
  *) exit 2 ;;
esac
EOF
  # bd answers from the repo it runs in: .beads/fake/{list,<id>,<id>.comments}.json.
  cat >"$BATS_TEST_TMPDIR/bin/bd" <<'EOF'
#!/usr/bin/env bash
printf 'bd %s in %s\n' "$*" "$PWD" >>"$LOG"
dir="$PWD/.beads/fake"
# show ID waits, up to 30s, for the file that $dir/ID.wait names.
if [[ "$1" == show && -e "$dir/$2.wait" ]]; then
  for _ in $(seq 300); do [[ -e "$(cat "$dir/$2.wait")" ]] && break; sleep 0.1; done
fi
case "$1" in
  list) cat "$dir/list.json" 2>/dev/null || exit 1 ;;
  show) cat "$dir/$2.json" 2>/dev/null || exit 1 ;;
  comments) cat "$dir/$2.comments.json" 2>/dev/null || printf '[]\n' ;;
  *) exit 2 ;;
esac
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/"*
  : >"$LOG"
}

shep() { "$ROOT/bin/bercail" shep "$@"; }

# A main checkout under ~/Work with one commit, so worktrees can hang off it.
repo() {
  local dir="$HOME/Work/$1"
  git init -q -b main "$dir"
  git -C "$dir" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
  mkdir -p "$dir/.beads/fake"
}

# A linked worktree of repo $1 on branch $2, at ~/Work/$1.$2.
worktree() {
  git -C "$HOME/Work/$1" worktree add -q -b "$2" "$HOME/Work/$1.$2"
}

# bd's data for repo $1: list of {id,title,status} as `id|title|status` args.
issues() {
  local name="$1" row
  shift
  for row in "$@"; do
    printf '%s\n' "$row"
  done | jq -R 'split("|") | {id: .[0], title: .[1], status: .[2], labels: []}' | jq -s . \
    >"$HOME/Work/$name/.beads/fake/list.json"
}

# A live terminal for hc: desk ADDR CWD STATE [LABELS-JSON] [NAME].
desk() {
  local labels="${4:-"{}"}"
  jq -n --arg a "$1" --arg cwd "$2" --arg s "$3" --argjson l "$labels" --arg name "${5:-}" \
    '{address: $a, name: (if $name == "" then null else $name end), cwd: $cwd, state: "live",
      status: {app: "pi", state: $s}, labels: ({"bercail.role": "agent"} + $l)}' >"$HC_DATA/$1.json"
  jq --arg a "$1" --arg cwd "$2" '.terminals += [{address: $a, cwd: $cwd, state: "live"}]' "$HC_DATA/ls.json" >"$HC_DATA/ls.tmp"
  mv "$HC_DATA/ls.tmp" "$HC_DATA/ls.json"
}

record() { jq -nc "$@" >>"$RECORDS"; }

@test "shep repos finds the main checkouts from config, trusted policies, handoffs, live desks and the extras file" {
  local name out want
  for name in a b c d e f g; do repo "$name"; done
  worktree c feat
  worktree e desk
  mkdir -p "$HOME/Work/e.desk/sub"
  cat >"$CONFIG" <<EOF
[git]
"~/Work/a" = "gh"

[policy."$HOME/Work/b"]
commit = "ask"
EOF
  jq -n --arg g "$HOME/Work/g" '{($g): {file: "x", sha256: "y"}}' >"$XDG_STATE_HOME/bercail/policy-trust.json"
  record --arg p "$HOME/Work/c.feat" '{path: $p, branch: "feat", issue: "c-1"}'
  record --arg p "$HOME/Work/d.gone" '{path: $p, branch: "gone", issue: "d-1"}'
  record --arg p "$HOME/Work/nothere" '{path: $p, issue: "x-1"}'
  printf 'not json\n' >>"$RECORDS"
  desk t9 "$HOME/Work/e.desk/sub" working
  desk t8 "$HOME" idle
  printf '# my other repos\n  ~/Work/f  \n/no/such/repo\n\n' >"$STATE/repos"
  out="$(shep repos --json)" || fail "repos: $out"
  want='[{"path":"/Work/a","from":["config"]},{"path":"/Work/b","from":["config"]},{"path":"/Work/c","from":["handoffs"]},
    {"path":"/Work/d","from":["handoffs"]},{"path":"/Work/e","from":["desks"]},{"path":"/Work/f","from":["extras"]},
    {"path":"/Work/g","from":["trust"]}]'
  jq -e --arg h "$REAL_HOME" --argjson want "$want" 'map({path: (.path | ltrimstr($h)), from}) == $want' <<<"$out" >/dev/null \
    || fail "repos: $(jq -c --arg h "$REAL_HOME" 'map({path: (.path | ltrimstr($h)), from})' <<<"$out")"
}

@test "shep repos shows each repo's git backend, policy trust and open issue count" {
  local out
  repo a
  repo b
  repo c
  rm -rf "$HOME/Work/c/.beads"
  mkdir -p "$HOME/Work/a/.bercail" "$HOME/Work/b/.bercail"
  printf 'commit = "allow"\n' >"$HOME/Work/a/.bercail/policy.toml"
  printf 'commit = "allow"\n' >"$HOME/Work/b/.bercail/policy.toml"
  "$ROOT/bin/bercail" policy trust "$HOME/Work/a" >/dev/null
  printf '[git]\n"~/Work/a" = "gt"\n' >"$CONFIG"
  issues a 'a-1|One|open' 'a-2|Two|in_progress' 'a-3|Three|closed'
  printf '%s\n' "$HOME/Work/a" "$HOME/Work/b" "$HOME/Work/c" >"$STATE/repos"
  out="$(shep repos --json)" || fail "repos: $out"
  jq -e '[.[] | {backend, policy, open}] == [{backend: "gt", policy: "trusted", open: 2},
    {backend: "gh", policy: "untrusted", open: null}, {backend: "gh", policy: "none", open: null}]' \
    <<<"$out" >/dev/null || fail "repos --json: $out"
  out="$(shep repos)"
  [[ "$out" == "~/Work/a  gt  policy trusted    2 open  (config, extras, trust)
~/Work/b  gh  policy untrusted  UNKNOWN (beads unavailable)  (extras)
~/Work/c  gh  no policy         no beads  (extras)" ]] || fail "repos: $out"
}

# Repo app with a desk worktree for app-1, its issue, three comments, and a
# blocked desk t9 whose screen holds the question.
brief_fixture() {
  local i
  repo app
  worktree app login
  jq -n '{id: "app-1", title: "Fix the\nlogin", status: "in_progress", priority: 1, issue_type: "bug", labels: ["auth", "web"]}' \
    >"$HOME/Work/app/.beads/fake/app-1.json"
  jq -n --arg long "REPORT-HEAD $(printf 'x%.0s' {1..2600}) REPORT-TAIL" '[
    {author: "Simon", created_at: "2026-11-10T11:00:00Z", text: "bercail handoff: stage bstack, desk agent pi"},
    {author: "Desk", created_at: "2026-11-10T11:30:00Z", text: "first report"},
    {author: "Desk", created_at: "2026-11-10T12:00:05Z", text: $long}]' >"$HOME/Work/app/.beads/fake/app-1.comments.json"
  record --arg p "$HOME/Work/app.login" '{path: $p, branch: "login", issue: "app-1", desk: "t9", space: "sp1", label: "Login_App"}'
  desk t9 "$HOME/Work/app.login" blocked '{"bercail.issue": "app-1", "bercail.space": "sp1"}'
  {
    for i in $(seq 1 30); do printf 'screen line %s   \n' "$i"; done
    printf '────────────\n\n   \nAllow git push origin main? [y/n]\n'
  } >"$HC_DATA/t9.screen"
}

@test "shep brief: the issue, its desk, the blocked desk's question, and the latest report cut to the budget" {
  local out head screen report want
  brief_fixture
  # From outside the repo: the handoff record names it.
  out="$(cd "$BATS_TEST_TMPDIR" && shep brief app-1)" || fail "brief: $out"
  head="$(sed -n 1,4p <<<"$out")"
  want="app-1: Fix the login
in_progress P1 bug · labels auth, web · repo ~/Work/app
desk t9 blocked · space Login_App (sp1) · branch login · worktree ~/Work/app.login
desk t9 is blocked; its screen ends with:"
  [[ "$head" == "$want" ]] || fail "brief head: $(diff <(printf '%s\n' "$want") <(printf '%s\n' "$head"))"
  screen="$(sed -n '/^  | /p' <<<"$out")"
  [[ "$(wc -l <<<"$screen")" -eq 15 && "$(sed -n 1p <<<"$screen")" == "  | screen line 17" \
    && "$(tail -n 1 <<<"$screen")" == "  | Allow git push origin main? [y/n]" ]] || fail "screen: $screen"
  grep -qx '(the whole screen: hc read t9 --lines 60)' <<<"$out" || fail "no pointer to the screen: $out"
  grep -qx 'latest report: comment 3 of 3, Desk at 2026-11-10 12:00 (2624 characters):' <<<"$out" || fail "report head: $out"
  report="$(sed -n '/^latest report/,$p' <<<"$out" | tail -n +2)"
  [[ "$report" == "REPORT-HEAD "*$'\n[… 1124 characters cut; the whole comment: bd comments app-1]\n'*" REPORT-TAIL" ]] \
    || fail "report not cut to head and tail: $report"
  (( ${#report} <= 1500 + 70 )) || fail "report is ${#report} characters for a 1500 budget"
  out="$(shep brief app-1 --budget 300 | sed -n '/^latest report/,$p' | tail -n +2)"
  (( ${#out} <= 300 + 70 )) && [[ "$out" == *"2324 characters cut"* ]] || fail "--budget 300: ${#out} characters: $out"
  ! grep -q 'first report\|bercail handoff' <<<"$(shep brief app-1)" || fail "an older comment is in the brief"
}

@test "shep brief: no desk or report, a desk that is gone, and an issue no known repo has" {
  local out
  repo app
  printf '%s\n' "$HOME/Work/app" >"$STATE/repos"
  jq -n '{id: "app-2", title: "Plan the API", status: "open", priority: 2, issue_type: "task", labels: []}' >"$HOME/Work/app/.beads/fake/app-2.json"
  jq -n '[{author: "Simon", created_at: "2026-11-10T11:00:00Z", text: "bercail handoff: stage bstack"}]' >"$HOME/Work/app/.beads/fake/app-2.comments.json"
  jq -n '[{id: "app-3", title: "Old job", status: "open", labels: []}]' >"$HOME/Work/app/.beads/fake/app-3.json"
  record --arg p "$HOME/Work/app.old" '{path: $p, branch: "old", issue: "app-3", desk: "t5", space: "sp5"}'
  out="$(cd "$BATS_TEST_TMPDIR" && shep brief app-2)" || fail "brief app-2: $out"
  [[ "$out" == "app-2: Plan the API
open P2 task · repo ~/Work/app
no desk
no report yet (1 comment; bd comments app-2)" ]] || fail "brief app-2: $out"
  out="$(shep brief app-3)" || fail "brief app-3: $out"
  [[ "$out" == "app-3: Old job
open · repo ~/Work/app
desk t5 gone · space sp5 · branch old · worktree ~/Work/app.old
no report yet (0 comments; bd comments app-3)" ]] || fail "brief app-3: $out"
  out="$(shep brief app-9 2>&1)" && fail "brief of an unknown issue passed: $out"
  [[ "$out" == "bercail shep: no known repo has app-9; pass its checkout with --repo" ]] || fail "unknown: $out"
  out="$(shep brief app-2 --repo "$BATS_TEST_TMPDIR" 2>&1)" && fail "brief with a --repo that is no checkout passed"
  [[ "$out" == *"is not a git checkout"* ]] || fail "bad --repo: $out"
  out="$(shep brief 'app 2;x' 2>&1)" && fail "a bad id passed"
  [[ "$out" == *"is neither a beads id nor a trail (trail:N)"* ]] || fail "bad id: $out"
}

@test "shep board: a line per job in each known repo, other repos, stray desks, and what waits on the person" {
  local out want
  need node
  repo app
  repo docs
  repo tools
  rm -rf "$HOME/Work/tools/.beads"
  printf '%s\n' "$HOME/Work/app" "$HOME/Work/docs" "$HOME/Work/tools" >"$STATE/repos"
  issues app 'app-1|Fix the login|in_progress' 'app-2|Add the export, a title long enough that the board has to cut it short now|open' \
    'app-3|Old job|open' 'app-4|Backlog|open' 'app-5|Done already|closed' 'app-6|Wait for CI|open' 'app-7|Blocked on a decision|blocked'
  issues docs 'docs-1|Write the guide|open'
  record --arg p "$HOME/Work/app.login" '{path: $p, branch: "login", issue: "app-1", desk: "t9"}'
  record --arg p "$HOME/Work/app.export" '{path: $p, branch: "export", issue: "app-2", desk: "t8"}'
  record --arg p "$HOME/Work/app.old" '{path: $p, branch: "old", issue: "app-3", desk: "t5"}'
  desk t9 "$HOME/Work/app" blocked '{"bercail.issue": "app-1"}'
  desk t8 "$HOME/Work/app" "done" '{"bercail.issue": "app-2"}'
  desk t20 "$HOME/Work/app" idle '{"bercail.issue": "app-6", "bercail.shep": "bg"}' shep-bg-app-6
  desk t7 "$HOME/Work/app" "done" '{"bercail.issue": "app-5"}'
  desk t6 "$HOME/Work/tools" blocked
  out="$(shep board)" || fail "board: $out"
  want="~/Work/app: 4 jobs, 2 other open issues (1 handed off to a desk that is gone)
- app-1: Fix the login [in_progress] · desk t9 blocked · login
- app-2: Add the export, a title long enough that the board has to cut it shor… · desk t8 done · export
- app-6: Wait for CI · background Shep shep-bg-app-6 idle · -
- app-7: Blocked on a decision [blocked] · no desk · -
Other repos: ~/Work/docs (1 open), ~/Work/tools (no beads)
Desks on closed or unknown issues: desk t7 done (app-5)
Waiting on the person:
- app-1: Fix the login: desk t9 is blocked; bercail shep brief app-1 --repo '$HOME/Work/app' shows what it asks
- app-2: Add the export, a title long enough that the board has to cut it shor…: desk t8 finished; read its report in bercail shep brief app-2 --repo '$HOME/Work/app', then review its staged changes in its space
- app-6: Wait for CI: background Shep shep-bg-app-6 finished; report it from bercail shep brief app-6 --repo '$HOME/Work/app', then hc kill shep-bg-app-6
- desk t6 (~/Work/tools) is blocked
Decisions:
- nothing"
  [[ "$out" == "$want" ]] || fail "board: $(diff <(printf '%s\n' "$want") <(printf '%s\n' "$out"))"
  rm "$HC_DATA"/t*.json
  printf '{"terminals":[]}\n' >"$HC_DATA/ls.json"
  issues app 'app-4|Backlog|open'
  out="$(shep board)" || fail "quiet board: $out"
  [[ "$out" == "Other repos: ~/Work/app (1 open), ~/Work/docs (1 open), ~/Work/tools (no beads)
Waiting on the person:
- nothing
Decisions:
- nothing" ]] || fail "quiet board: $out"
}

@test "shep board, brief and queue read a handoff record set larger than one argument may be" {
  local out pad
  need node
  repo app
  worktree app login
  git -C "$HOME/Work/app" remote add origin git@github.com:o/app.git
  issues app 'app-1|Fix the login|in_progress'
  jq -n '{id:"app-1",title:"Fix the login",status:"in_progress"}' >"$HOME/Work/app/.beads/fake/app-1.json"
  record --arg p "$HOME/Work/app.login" '{path: $p, branch: "login", issue: "app-1", desk: "t9"}'
  # Linux caps one argument at 32 pages (128 KiB): 700 gone handoffs with 200-character
  # branches are past it, in the records and in the queue's list of their branches.
  pad="$(printf '%200s' '' | tr ' ' x)"
  jq -nc --arg w "$HOME/Work/app" --arg pad "$pad" \
    'range(700) | "\(.)-\($pad)" as $b | {path: "\($w).\($b)", branch: $b, issue: "app-old-\(.)", desk: "t5"}' >>"$RECORDS"
  jq -n '[{number: 7, title: "Login PR", url: "u7", isDraft: false, reviewDecision: "", headRefName: "login", reviewRequests: [], files: []}]' \
    >"$HC_DATA/prs.json"
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$1 $2" in
  "api user") printf 'simon\n' ;;
  "pr list") cat "$HC_DATA/prs.json" ;;
  *) exit 2 ;;
esac
GH
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  desk t9 "$HOME/Work/app.login" blocked '{"bercail.issue": "app-1"}'
  out="$(shep board 2>&1)" || fail "board: $out"
  [[ "$out" == *"- app-1: Fix the login [in_progress] · desk t9 blocked · login"* ]] || fail "board: $out"
  out="$(shep brief app-1 2>&1)" || fail "brief: $out"
  [[ "$out" == *"desk t9 blocked · branch login"* ]] || fail "brief: $out"
  out="$(shep queue --json 2>&1)" || fail "queue: $out"
  jq -e '[.items[] | {kind, number, branch}] == [{kind: "pr", number: 7, branch: "login"}]' <<<"$out" >/dev/null || fail "queue: $out"
}

@test "shep board lists the ledger's pending cards under Decisions, and nothing once they are answered" {
  local out
  need node
  repo app
  jq -n --arg repo "$HOME/Work/app" '{requestId:"r1", kind:"planning", prompt:"Which desk first?", options:["auth","search"],
    origin:{event:"chat", session:"shep-1", entry:null}, repo:$repo, issue:null, topic:"plan", desk:null, base:null, action:null}' \
    | shep question create >/dev/null || fail "no question"
  out="$(shep board)" || fail "board: $out"
  [[ "$out" == *$'\nDecisions:\n- app: Which desk first?' ]] || fail "the pending card is not on the board: $out"
  jq -n '{requestId:"a1", token:"Q1@1", choice:"auth", source:"panel picker"}' | shep question answer >/dev/null
  out="$(shep board)" || fail "board: $out"
  [[ "$out" == *$'\nDecisions:\n- nothing' ]] || fail "an answered card is still on the board: $out"
  # A card whose check waits for the queue's first read runs beside the board, so it is
  # listed; one that outlasts its 4 seconds is UNKNOWN, and the rest of the board still prints.
  jq -n '[{id: "app-1", title: "Fix the login", status: "in_progress", labels: []}]' >"$HOME/Work/app/.beads/fake/app-1.json"
  jq -n --arg repo "$HOME/Work/app" '{requestId:"r2", kind:"planning", prompt:"Login first?", options:["yes","no"],
    origin:{event:"chat", session:"shep-1", entry:null}, repo:$repo, issue:"app-1", topic:"login", desk:null, base:null, action:null}' \
    | shep question create >/dev/null || fail "no issue question"
  export HERDR_APP_BIN="$BATS_TEST_TMPDIR/bin/herdr-app"
  printf '#!/bin/sh\n: >"%s/queue-read"\nprintf %s\n' "$BATS_TEST_TMPDIR" "'{\"spaces\":[]}'" >"$HERDR_APP_BIN"
  chmod +x "$HERDR_APP_BIN"
  printf '%s\n' "$BATS_TEST_TMPDIR/queue-read" >"$HOME/Work/app/.beads/fake/app-1.wait"
  out="$(shep board)" || fail "board beside a waiting check: $out"
  [[ "$out" == *$'\nDecisions:\n- app-1: Login first?' ]] || fail "the check did not run beside the board: $out"
  printf '%s\n' "$BATS_TEST_TMPDIR/never" >"$HOME/Work/app/.beads/fake/app-1.wait"
  out="$(shep board)" || fail "board with a slow check: $out"
  [[ "$out" == *$'Waiting on the person:\n- nothing\nDecisions: UNKNOWN (the ledger could not be read, or its cards checked within 4s; the Decisions panel shows them)' ]] \
    || fail "a slow check is not UNKNOWN beside the rest of the board: $out"
  rm "$HOME/Work/app/.beads/fake/app-1.wait"
  printf 'not json\n' >"$STATE/questions.json"
  out="$(shep board)" || fail "board: $out"
  [[ "$out" == *$'\nDecisions: UNKNOWN (the ledger could not be read, or its cards checked within 4s; the Decisions panel shows them)' ]] \
    || fail "an unreadable ledger is not UNKNOWN: $out"
}

@test "shep brief and board show a desk's --model from its label, or its handoff when the desk is gone" {
  local out
  repo app
  printf '%s\n' "$HOME/Work/app" >"$STATE/repos"
  issues app 'app-1|Fix the login|in_progress' 'app-2|Old job|in_progress' 'app-3|Plain|in_progress'
  jq -n '{id: "app-1", title: "Fix the login", status: "in_progress", labels: []}' >"$HOME/Work/app/.beads/fake/app-1.json"
  jq -n '{id: "app-2", title: "Old job", status: "in_progress", labels: []}' >"$HOME/Work/app/.beads/fake/app-2.json"
  record --arg p "$HOME/Work/app.login" '{path: $p, branch: "login", issue: "app-1", desk: "t9", model: "claude-bridge/fable:low"}'
  record --arg p "$HOME/Work/app.old" '{path: $p, branch: "old", issue: "app-2", desk: "t5", model: "claude-bridge/fable:high"}'
  record --arg p "$HOME/Work/app.plain" '{path: $p, branch: "plain", issue: "app-3", desk: "t4"}'
  desk t9 "$HOME/Work/app" working '{"bercail.issue": "app-1", "bercail.model": "claude-bridge/fable:high"}'
  desk t4 "$HOME/Work/app" working '{"bercail.issue": "app-3"}'
  out="$(shep brief app-1)" || fail "brief app-1: $out"
  grep -qx 'desk t9 working · branch login · worktree ~/Work/app.login · model claude-bridge/fable:high' <<<"$out" \
    || fail "a live desk's model is its label: $out"
  out="$(shep brief app-2)" || fail "brief app-2: $out"
  grep -qx 'desk t5 gone · branch old · worktree ~/Work/app.old · model claude-bridge/fable:high' <<<"$out" \
    || fail "a gone desk's model is its handoff's: $out"
  out="$(shep board)" || fail "board: $out"
  grep -qx -- '- app-1: Fix the login \[in_progress\] · desk t9 working · login · model claude-bridge/fable:high' <<<"$out" \
    || fail "board, live desk: $out"
  grep -qx -- '- app-2: Old job \[in_progress\] · desk t5 gone · old · model claude-bridge/fable:high' <<<"$out" \
    || fail "board, gone desk: $out"
  grep -qx -- '- app-3: Plain \[in_progress\] · desk t4 working · plain' <<<"$out" \
    || fail "board, a desk on the lead names no model: $out"
}

@test "shep remember, list and forget keep dated rules with their scope in Shep's preferences file" {
  local out today file="$STATE/preferences.md"
  today="$(date +%Y-%m-%d)"
  out="$(shep list)"
  [[ "$out" == 'no standing rules yet; add one with: bercail shep remember "RULE" [--scope SCOPE]' ]] || fail "empty list: $out"
  out="$(shep remember $'Merge bercail work straight to master\n  and push' --scope bercail)"
  [[ "$out" == "remembered: $today [bercail] Merge bercail work straight to master and push" ]] || fail "remember: $out"
  out="$(shep remember 'Never block: waits go to a background Shep (\n stays)')"
  [[ "$out" == "remembered: $today [all] Never block: waits go to a background Shep (\\n stays)" ]] || fail "remember: $out"
  shep remember 'Answer its approval prompts' --scope bercail-cm0 >/dev/null
  out="$(shep remember 'Never block: waits go to a background Shep (\n stays)')"
  [[ "$out" == "already a standing rule: $today [all] Never block: waits go to a background Shep (\\n stays)" ]] || fail "duplicate: $out"
  out="$(shep list)"
  [[ "$out" == "1. $today [bercail] Merge bercail work straight to master and push
2. $today [all] Never block: waits go to a background Shep (\\n stays)
3. $today [bercail-cm0] Answer its approval prompts" ]] || fail "list: $out"
  out="$(shep forget 1)"
  [[ "$out" == "forgot: $today [bercail] Merge bercail work straight to master and push" ]] || fail "forget: $out"
  [[ "$(shep list)" == "1. $today [all] Never block"*$'\n'"2. $today [bercail-cm0] Answer its approval prompts" ]] || fail "after forget: $(shep list)"
  [[ "$(head -n 1 "$file")" == "# Standing rules the person gave Shep."* ]] || fail "header lost: $(cat "$file")"
  out="$(shep forget 3 2>&1)" && fail "forget 3 of 2 passed"
  [[ "$out" == "bercail shep: there is no rule 3; bercail shep list shows 2" ]] || fail "forget 3: $out"
  out="$(shep forget x 2>&1)" && fail "forget x passed"
  [[ "$out" == *"usage: bercail shep forget N"* ]] || fail "forget x: $out"
  out="$(shep remember '  ' 2>&1)" && fail "an empty rule passed"
  [[ "$out" == *'usage: bercail shep remember "RULE"'* ]] || fail "empty rule: $out"
  out="$(shep remember one two 2>&1)" && fail "an unquoted rule passed"
  [[ "$out" == *"(quote the rule)"* ]] || fail "two words: $out"
}

# The review queue's fixture in ~/Work/app, a GitHub repo whose policy marks
# lib/*.sh high-stakes and allows 10 lines of review: app-2's desk is done with
# 6 lines staged (and a lockfile), app-3's desk is gone with 2 lines staged and
# its issue closed, and app-4's desk is still working on 3. gh lists 5 open PRs.
queue_fixture() {
  repo app
  repo docs
  git -C "$HOME/Work/app" remote add origin git@github.com:o/app.git
  mkdir -p "$HOME/Work/app/.bercail"
  printf 'high_stakes = ["lib/*.sh"]\nreview_budget = 10\n' >"$HOME/Work/app/.bercail/policy.toml"
  git -C "$HOME/Work/app" add .bercail/policy.toml
  git -C "$HOME/Work/app" -c user.name=t -c user.email=t@example.invalid commit -q -m policy
  printf '%s\n' "$HOME/Work/app" "$HOME/Work/docs" >"$STATE/repos"
  issues app 'app-2|Add the export|in_progress' 'app-3|Old job|closed' 'app-4|Still going|in_progress'
  jq -n '{id: "app-2", title: "Add the export", status: "in_progress", labels: []}' >"$HOME/Work/app/.beads/fake/app-2.json"
  jq -n '{id: "app-3", title: "Old job", status: "closed", labels: []}' >"$HOME/Work/app/.beads/fake/app-3.json"
  worktree app export
  worktree app old
  worktree app busy
  mkdir -p "$HOME/Work/app.export/lib"
  seq 1 6 >"$HOME/Work/app.export/lib/a.sh"
  seq 1 40 >"$HOME/Work/app.export/yarn.lock"
  # The queue sorts by index mtime; give export an earlier second than old.
  stage_at "$HOME/Work/app.export" 1700000000
  seq 1 2 >"$HOME/Work/app.old/notes.md"
  stage_at "$HOME/Work/app.old" 1700000001
  seq 1 3 >"$HOME/Work/app.busy/wip.md"
  git -C "$HOME/Work/app.busy" add wip.md
  record --arg p "$HOME/Work/app.export" '{path: $p, branch: "export", issue: "app-2", desk: "t8"}'
  record --arg p "$HOME/Work/app.old" '{path: $p, branch: "old", issue: "app-3", desk: "t5"}'
  record --arg p "$HOME/Work/app.busy" '{path: $p, branch: "busy", issue: "app-4", desk: "t4"}'
  desk t8 "$HOME/Work/app.export" "done" '{"bercail.issue": "app-2", "bercail.issue_title": "Add the export"}'
  desk t4 "$HOME/Work/app.busy" working '{"bercail.issue": "app-4"}'
  # 12 asks simon for a review; 15 is the old handoff's branch. 13 is a draft,
  # 14 is approved, 16 is someone else's with no ask.
  jq -n '[
    {number: 12, title: "Teammate fix", url: "https://github.com/o/app/pull/12", isDraft: false, reviewDecision: "REVIEW_REQUIRED",
     headRefName: "fix", reviewRequests: [{login: "simon"}], files: [{path: "a.go", additions: 3, deletions: 1}, {path: "go.sum", additions: 90, deletions: 0}]},
    {number: 13, title: "Draft", url: "u13", isDraft: true, reviewDecision: "", headRefName: "d", reviewRequests: [{login: "simon"}], files: []},
    {number: 14, title: "Approved", url: "u14", isDraft: false, reviewDecision: "APPROVED", headRefName: "export", reviewRequests: [], files: []},
    {number: 15, title: "Old job PR", url: "https://github.com/o/app/pull/15", isDraft: false, reviewDecision: "", headRefName: "old",
     reviewRequests: [], files: [{path: "x.md", additions: 3, deletions: 0}]},
    {number: 16, title: "Theirs", url: "u16", isDraft: false, reviewDecision: "", headRefName: "theirs", reviewRequests: [{login: "ana"}], files: []}]' \
    >"$HC_DATA/prs.json"
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'GH'
#!/usr/bin/env bash
printf 'gh %s in %s\n' "$*" "$PWD" >>"$LOG"
case "$1 $2" in
  "api user") printf 'simon\n' ;;
  "pr list") cat "$HC_DATA/prs.json" ;;
  *) exit 2 ;;
esac
GH
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
}

@test "shep queue: staged work no desk is still on and PRs that wait on the person, their size and stakes, against the repo's review budget" {
  local out want
  queue_fixture
  out="$(shep queue --repo "$HOME/Work/app.export")" || fail "queue: $out"
  want="Review queue: 15 lines in 4 changes
~/Work/app: 15 of 10 lines, over its review budget
- app-2: Add the export · 6 lines staged in 1 file · stakes high, needs the person's LGTM · describe check fails: no .bercail/description.md: run /validate · ~/Work/app.export
- app-3: Old job · 2 lines staged in 1 file · stakes low · describe check fails: no .bercail/description.md: run /validate · state unknown: issue closed but staged changes remain; custody/outcome unproven · ~/Work/app.old
- PR #12: Teammate fix · 4 lines · https://github.com/o/app/pull/12
- PR #15: Old job PR · 3 lines · https://github.com/o/app/pull/15
~/Work/app is over its review budget: 15 lines wait on the person, the budget is 10. Report it; accepted work is not held for review budget."
  [[ "$out" == "$want" ]] || fail "queue: $(diff <(printf '%s\n' "$want") <(printf '%s\n' "$out"))"
  if grep -q "^gh .* in $HOME/Work/docs\$" "$LOG"; then fail "gh ran in a repo with no GitHub remote: $(cat "$LOG")"; fi
}

@test "shep queue: a repo within its budget, and nothing waiting" {
  local out
  queue_fixture
  out="$(shep queue --repo "$HOME/Work/docs")"
  [[ "$out" == "Review queue: nothing waits on the person."*$'\n'"~/Work/docs: 0 of 1000 lines wait on the person; a new desk fits its review budget." ]] \
    || fail "a repo with nothing waiting: $out"
  git -C "$HOME/Work/app.export" reset -q
  git -C "$HOME/Work/app.old" reset -q
  printf '[]\n' >"$HC_DATA/prs.json"
  out="$(shep queue --repo "$HOME/Work/app")"
  [[ "$out" == "Review queue: nothing waits on the person.
~/Work/app: 0 of 10 lines wait on the person; a new desk fits its review budget." ]] || fail "empty queue: $out"
}

# ~/Work/kvm, hosted on Entire as et/lab/kvm, and an entire stand-in that reads
# $HC_DATA/entire/: list.json (list-<token>.json for a later page), show-<n>.json
# and findings-<repo>-<n>.json. bercail job list reads the trails, on Node.
trail_fixture() {
  need node
  repo kvm
  git -C "$HOME/Work/kvm" remote add origin entire://aws-us-east-2.entire.io/et/lab/kvm
  printf '%s\n' "$HOME/Work/kvm" >"$STATE/repos"
  worktree kvm fix
  record --arg p "$HOME/Work/kvm.fix" '{path: $p, branch: "fix", issue: "trail:7", space: "sp3"}'
  trail_data
  cat >"$BATS_TEST_TMPDIR/bin/entire" <<'EOF'
#!/usr/bin/env bash
printf 'entire %s\n' "$*" >>"$LOG"
d="$HC_DATA/entire"
[[ " $* " == *" --project et/lab "* ]] || exit 2
case "$1 $2 $3" in
  "trail list --project") [[ " $* " == *" --repo entire://aws-us-east-2.entire.io/et/lab/kvm "* ]] || exit 2
    page="$(sed -n 's/.* --page-token \([^ ]*\).*/\1/p' <<<"$*")"
    cat "$d/list${page:+-$page}.json" ;;
  "trail show "*) cat "$d/show-$3.json" ;;
  "trail finding list") [[ "$4" == --trail ]] && cat "$d/findings-${5/\//-}.json" ;;
  *) exit 2 ;;
esac
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/entire"
}

# The open trails. Trail 7 waits on approvals with three open findings;
# trail 6 passed its gates. Trail 7's change in another repo, trail 5 (planning)
# and trail 8 (complete) are not this checkout's review.
trail_data() {
  local d="$HC_DATA/entire"
  mkdir -p "$d"
  jq -n '{items: [{number: 8, phase: "complete"}, {number: 7, phase: "building"}, {number: 6, phase: "building"},
    {number: 5, phase: "planning"}] | map(.status = "open"), nextPageToken: null}' >"$d/list.json"
  jq -n '{number: 7, title: "Read the gateway frames", changes: [
    {repository: "kvm", number: 9, branch: "fix", status: "open", updatedAt: "2026-11-19T10:00:00Z",
     url: "https://entire.com/et/lab/-/trails/7/changes/kvm/9",
     mergeability: {head_sha: "abc", mergeable: false, gates: [
       {gate_key: "approvals", blocking: true, status: "pending"}, {gate_key: "findings", blocking: true, status: "passed"},
       {gate_key: "checks", blocking: false, status: "failed"}]}},
    {repository: "kvm", number: 4, branch: "old", status: "merged", url: "u4", mergeability: null},
    {repository: "web", number: 2, branch: "fix", status: "open", url: "u-web", mergeability: null}]}' >"$d/show-7.json"
  jq -n '{number: 6, title: "Pin the transport", changes: [
    {repository: "kvm", number: 11, branch: "pin", status: "open", updatedAt: "2026-11-18T10:00:00Z",
     url: "https://entire.com/et/lab/-/trails/6/changes/kvm/11",
     mergeability: {head_sha: "def", mergeable: true, gates: [{gate_key: "approvals", blocking: true, status: "passed"}]}}]}' \
    >"$d/show-6.json"
  jq -n '{counts: {Open: 3, OpenHigh: 1, OpenMedium: 0, OpenLow: 2, Resolved: 4}, findings: []}' >"$d/findings-kvm-9.json"
  jq -n '{counts: {Open: 0, OpenHigh: 0, OpenMedium: 0, OpenLow: 0}, findings: []}' >"$d/findings-kvm-11.json"
}

@test "shep queue and board: an Entire repo's trail changes in review, with their open findings, gates and trail links" {
  local out want
  trail_fixture
  out="$(shep queue --repo "$HOME/Work/kvm")" || fail "queue: $out"
  want="Review queue: 0 lines in 2 changes
~/Work/kvm: 0 of 1000 lines
- trail 6: Pin the transport · change kvm/11 · no open findings · gates: every blocking gate passed · https://entire.com/et/lab/-/trails/6/changes/kvm/11
- trail 7: Read the gateway frames · change kvm/9 · 3 open findings (1 high, 2 low) · gates: waiting on approvals · https://entire.com/et/lab/-/trails/7/changes/kvm/9
~/Work/kvm: 0 of 1000 lines wait on the person; a new desk fits its review budget."
  [[ "$out" == "$want" ]] || fail "queue: $(diff <(printf '%s\n' "$want") <(printf '%s\n' "$out"))"
  out="$(shep queue --repo "$HOME/Work/kvm" --json)" || fail "queue: $out"
  jq -e --arg p "$HOME/Work/kvm.fix" '.items[1] | .kind == "trail" and .trail == 7 and .counts and .space == "sp3" and .path == $p
    and .findings == {open: 3, high: 1, medium: 0, low: 2} and .gates.state == "pending"' <<<"$out" >/dev/null || fail "json: $out"
  out="$(shep board)" || fail "board: $out"
  [[ "$out" == *$'\n- trail 7: Read the gateway frames · change kvm/9 · 3 open findings (1 high, 2 low) · '* ]] || fail "board: $out"
  if grep '^entire ' "$LOG" | grep -v -E '^entire trail (list|show|finding list) '; then fail "entire ran more than reads"; fi
  if grep -E '^entire trail (show|finding list) .*(\b[58]\b|web)' "$LOG"; then fail "read trails that are not in review here"; fi
}

@test "shep queue: a failed or malformed trail read is UNKNOWN, never a queue without the trail" {
  local out file body
  trail_fixture
  # Entire fails, or exits 0 with nothing or with what is not its JSON: each is UNKNOWN.
  while IFS='|' read -r file body; do
    trail_data
    if [[ "$body" == gone ]]; then rm "$HC_DATA/entire/$file.json"; else printf '%s' "$body" >"$HC_DATA/entire/$file.json"; fi
    out="$(shep queue --repo "$HOME/Work/kvm" --json)" && fail "$file $body: $out"
    jq -e '.status == "unknown" and .items == null' <<<"$out" >/dev/null || fail "$file $body: $out"
  done <<'EOF'
findings-kvm-9|gone
findings-kvm-9|not json
findings-kvm-9|{}
findings-kvm-9|
show-7|{"changes":{"a":1}}
show-7|
list|{"nextPageToken":null}
list|{"items":[],"nextPageToken":false}
list|
EOF
  # A second page is read, never cut: a trail in review there is in the queue; a
  # page that fails is UNKNOWN.
  trail_data
  jq '.nextPageToken = "p2" | .items |= map(select(.number != 6))' "$HC_DATA/entire/list.json" >"$HC_DATA/entire/list.tmp"
  mv "$HC_DATA/entire/list.tmp" "$HC_DATA/entire/list.json"
  jq -n '{items: [{number: 6, phase: "building", status: "open"}], nextPageToken: null}' >"$HC_DATA/entire/list-p2.json"
  : >"$LOG"
  out="$(shep queue --repo "$HOME/Work/kvm" --json)" || fail "a second page: $out"
  jq -e '[.items[] | .trail] == [6, 7]' <<<"$out" >/dev/null || fail "a second page: $out"
  [[ "$(grep -c '^entire trail list ' "$LOG")" == 2 ]] || fail "pages: $(cat "$LOG")"
  rm "$HC_DATA/entire/list-p2.json"
  out="$(shep queue --repo "$HOME/Work/kvm" --json)" && fail "a failed second page: $out"
  jq -e '.status == "unknown"' <<<"$out" >/dev/null || fail "a failed second page: $out"
}

@test "shep queue: a trail worker that dies is UNKNOWN, never a trail with nothing in review" {
  trail_fixture
  run bash -c 'set -euo pipefail; for f in common git-backend shep-context; do source "$ROOT/lib/$f.sh"; done
    _shep_queue_trail() { kill -KILL "$BASHPID"; }
    _shep_queue_trails "$HOME/Work/kvm"'
  [[ "$status" -ne 0 ]] || fail "a dead worker read as: $output"
}

@test "shep queue: a trail's open changes have their findings read at once" {
  local out
  trail_fixture
  # Trail 7's two changes meet in their findings reads, inside the 4s bound.
  barrier 2
  jq '.changes += [{repository: "kvm", number: 12, branch: "more", status: "open", url: "u12", mergeability: null}]' \
    "$HC_DATA/entire/show-7.json" >"$HC_DATA/entire/show.tmp"
  mv "$HC_DATA/entire/show.tmp" "$HC_DATA/entire/show-7.json"
  cp "$HC_DATA/entire/findings-kvm-11.json" "$HC_DATA/entire/findings-kvm-12.json"
  mv "$BATS_TEST_TMPDIR/bin/entire" "$BATS_TEST_TMPDIR/bin/entire-data"
  cat >"$BATS_TEST_TMPDIR/bin/entire" <<'EOF'
#!/usr/bin/env bash
case "$*" in "trail finding list --trail kvm/9 "* | "trail finding list --trail kvm/12 "*) meet "${5/\//-}" || exit 1 ;; esac
exec entire-data "$@"
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/entire"

  out="$(shep queue --repo "$HOME/Work/kvm" --json)" || fail "queue: $out"

  jq -e '[.items[] | [.trail, .number]] == [[6, 11], [7, 9], [7, 12]]' <<<"$out" >/dev/null \
    || fail "queue: $(jq -c '[.items[] | [.trail, .number]]' <<<"$out")"
}

@test "shep queue and board: one trail list a refresh, and a show and findings only for each trail in review, however many trails" {
  local calls
  trail_fixture
  shep queue --repo "$HOME/Work/kvm" >/dev/null
  calls="$(grep -c '^entire ' "$LOG")"
  [[ "$calls" == 5 && "$(grep -c '^entire trail list ' "$LOG")" == 1 ]] || fail "queue: $(cat "$LOG")"
  : >"$LOG"
  shep board >/dev/null
  [[ "$(grep -c '^entire ' "$LOG")" == 5 && "$(grep -c '^entire trail list ' "$LOG")" == 1 ]] || fail "board: $(cat "$LOG")"
  # 96 more open trails, a full page, none in review: planning (with a desk's handoff, too) and complete.
  record --arg p "$HOME/Work/kvm.plan" '{path: $p, branch: "plan", issue: "trail:20", space: "sp4"}'
  jq '.items += [range(20; 116) | {number: ., status: "open", phase: (if . % 2 == 0 then "planning" else "complete" end)}]' \
    "$HC_DATA/entire/list.json" >"$HC_DATA/entire/list.tmp"
  mv "$HC_DATA/entire/list.tmp" "$HC_DATA/entire/list.json"
  : >"$LOG"
  shep queue --repo "$HOME/Work/kvm" >/dev/null
  [[ "$(grep -c '^entire ' "$LOG")" == "$calls" ]] || fail "Entire calls grew from $calls: $(cat "$LOG")"
  [[ "$(grep -c '^entire trail show ' "$LOG")" == 2 && "$(grep -c '^entire trail finding list ' "$LOG")" == 2 ]] \
    || fail "a show or findings read for a trail not in review: $(cat "$LOG")"
}

@test "shep queue: a page of large findings is read from Entire's output, not from an argument" {
  local out
  trail_fixture
  jq -n '{counts: {Open: 100, OpenHigh: 0, OpenMedium: 100, OpenLow: 0},
    findings: [range(100) | {body: ("x" * 4000), severity: "medium", status: "open"}]}' >"$HC_DATA/entire/findings-kvm-9.json"
  out="$(shep queue --repo "$HOME/Work/kvm")" || fail "queue: $out"
  [[ "$out" == *"- trail 7: Read the gateway frames · change kvm/9 · 100 open findings (100 medium) · "* ]] || fail "$out"
}

@test "shep board ends with the review queue, and leaves it out when nothing waits" {
  local out
  queue_fixture
  out="$(shep board)" || fail "board: $out"
  [[ "$out" == *$'\nWaiting on the person:\n'*$'\nReview queue: 15 lines in 4 changes\n~/Work/app: 15 of 10 lines, over its review budget\n- app-2: '* ]] \
    || fail "the board does not end with the queue: $out"
  git -C "$HOME/Work/app.export" reset -q
  git -C "$HOME/Work/app.old" reset -q
  printf '[]\n' >"$HC_DATA/prs.json"
  [[ "$(shep board)" != *"Review queue"* ]] || fail "an empty queue is on the board: $(shep board)"
}

# A worktree of ~/Work/web on branch $1 with $2 lines staged in $1.md, last
# staged at epoch $3. Its files are older, as git add leaves them, or git
# status would rewrite the index.
staged() {
  local wt="$HOME/Work/web.$1"
  worktree web "$1"
  seq 1 "$2" >"$wt/$1.md"
  stage_at "$wt" "$3"
}

# git add in worktree $1 at epoch $2: every file a minute older than the index.
stage_at() {
  find "$1" -name .git -prune -o -type f -exec touch -d "@$(($2 - 60))" {} +
  git -C "$1" add -A
  touch -d "@$2" "$(git -C "$1" rev-parse --path-format=absolute --git-path index)"
}

# bd show's answer for web-$1: STATUS, and a dependency of TYPE on web-$4.
bd_issue() {
  jq -n --arg id "web-$1" --arg s "$2" --arg t "${3:-}" --arg to "web-${4:-}" \
    '{id: $id, title: "Job \($id)", status: $s,
      dependencies: (if $t == "" then null else [{id: $to, title: "new", status: "open", dependency_type: $t}] end)}' \
    >"$HOME/Work/web/.beads/fake/web-$1.json"
}

@test "shep queue --json: each staged worktree's state from beads and the handoff records; only review, LGTM and unknown count; an unknown one keeps its LGTM" {
  local out
  repo web
  mkdir -p "$HOME/Work/web/.bercail"
  printf 'high_stakes = ["ops/*"]\nreview_budget = 100\n' >"$HOME/Work/web/.bercail/policy.toml"
  git -C "$HOME/Work/web" add .bercail/policy.toml
  git -C "$HOME/Work/web" -c user.name=t -c user.email=t@example.invalid commit -q -m policy
  printf '%s\n' "$HOME/Work/web" >"$STATE/repos"
  issues web 'web-1|Job web-1|in_progress' 'web-5|Job web-5|open' 'web-6|Job web-6|in_progress' 'web-8|Job web-8|open'
  staged one 1 1700000500
  mkdir -p "$HOME/Work/web.one/ops"
  seq 1 4 >"$HOME/Work/web.one/ops/deploy"
  stage_at "$HOME/Work/web.one" 1700000500
  bd_issue 1 in_progress
  staged two 20 1700000100
  bd_issue 2 closed supersedes 5
  staged three 30 1700000200
  bd_issue 3 closed duplicates 5
  staged four 40 1700000300
  bd_issue 4 closed
  # web-6 moved to a fresh worktree; its old desk still sits idle on the old one.
  staged old 60 1700000050
  worktree web new
  bd_issue 6 in_progress
  # web-7: bd does not answer, and it touches a high-stakes path.
  worktree web seven
  seq 1 7 >"$HOME/Work/web.seven/seven.md"
  mkdir -p "$HOME/Work/web.seven/ops"
  seq 1 3 >"$HOME/Work/web.seven/ops/run"
  stage_at "$HOME/Work/web.seven" 1700000400
  staged eight 8 1700000600
  bd_issue 8 open
  staged mine 9 1700000000
  record --arg p "$HOME/Work/web.one" '{path: $p, branch: "one", issue: "web-1", desk: "t1", space: "sp1"}'
  record --arg p "$HOME/Work/web.two" '{path: $p, branch: "two", issue: "web-2", desk: "t2"}'
  record --arg p "$HOME/Work/web.three" '{path: $p, branch: "three", issue: "web-3", desk: "t3"}'
  record --arg p "$HOME/Work/web.four" '{path: $p, branch: "four", issue: "web-4", desk: "t4"}'
  record --arg p "$HOME/Work/web.old" '{path: $p, branch: "old", issue: "web-6", desk: "t5"}'
  record --arg p "$HOME/Work/web.new" '{path: $p, branch: "new", issue: "web-6", desk: "t6"}'
  record --arg p "$HOME/Work/web.seven" '{path: $p, branch: "seven", issue: "web-7", desk: "t7"}'
  record --arg p "$HOME/Work/web.eight" '{path: $p, branch: "eight", issue: "web-8", desk: "t8"}'
  desk t5 "$HOME/Work/web.old" idle '{"bercail.issue": "web-6", "bercail.space": "sp5"}'
  desk t9 "$HOME/Work/web.mine" "done" '{"bercail.space": "sp9"}'

  out="$(shep queue --json)" || fail "queue --json: $out"
  jq -e '.schema == "bercail.queue/v1" and (.at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$"))' <<<"$out" >/dev/null \
    || fail "no schema or source time: $out"
  # Counted first, the longest waiting first; then what does not count.
  jq -e --arg h "$REAL_HOME" '[.items[] | [(.issue // (.path | ltrimstr($h))), .state, .counts, (.by // "" | ltrimstr($h)), .space, .since]] == [
    ["/Work/web.mine", "review", true, "", "sp9", "2023-11-14T22:13:20Z"],
    ["web-4", "unknown", true, "", null, "2023-11-14T22:18:20Z"],
    ["web-7", "unknown", true, "", null, "2023-11-14T22:20:00Z"],
    ["web-1", "lgtm", true, "", "sp1", "2023-11-14T22:21:40Z"],
    ["web-8", "review", true, "", null, "2023-11-14T22:23:20Z"],
    ["web-6", "superseded", false, "/Work/web.new", "sp5", "2023-11-14T22:14:10Z"],
    ["web-2", "superseded", false, "web-5", null, "2023-11-14T22:15:00Z"],
    ["web-3", "superseded", false, "web-5", null, "2023-11-14T22:16:40Z"]]' <<<"$out" >/dev/null \
    || fail "states: $(jq -c --arg h "$REAL_HOME" '[.items[] | [(.issue // (.path | ltrimstr($h))), .state, .counts, (.by // "" | ltrimstr($h)), .space, .since]]' <<<"$out")"
  jq -e '.repos == [{path: .repos[0].path, lines: 72, changes: 5, budget: 100, over: false}]' <<<"$out" >/dev/null \
    || fail "the budget counts cleanup or superseded work: $(jq -c .repos <<<"$out")"
  jq -e '[.items[] | select(.issue == "web-4" or .issue == "web-1") | .title] == ["Job web-4", "Job web-1"]' <<<"$out" >/dev/null \
    || fail "a closed issue's title is not read from bd: $(jq -c '[.items[] | .title]' <<<"$out")"

  out="$(shep queue)" || fail "queue: $out"
  [[ "$out" == "Review queue: 72 lines in 5 changes
~/Work/web: 72 of 100 lines
- ~/Work/web.mine · 9 lines staged in 1 file · stakes low · describe check fails: no .bercail/description.md: run /validate
- web-4: Job web-4 · 40 lines staged in 1 file · stakes low · describe check fails: no .bercail/description.md: run /validate · state unknown: issue closed but staged changes remain; custody/outcome unproven · ~/Work/web.four
- web-7 · 10 lines staged in 2 files · stakes high, needs the person's LGTM · describe check fails: no .bercail/description.md: run /validate · state unknown: bd does not answer for web-7 · ~/Work/web.seven
- web-1: Job web-1 · 5 lines staged in 2 files · stakes high, needs the person's LGTM · describe check fails: no .bercail/description.md: run /validate · ~/Work/web.one
- web-8: Job web-8 · 8 lines staged in 1 file · stakes low · describe check fails: no .bercail/description.md: run /validate · ~/Work/web.eight
- not counted: web-6: Job web-6 · 60 lines staged in 1 file · stakes low · its job moved to another worktree (~/Work/web.new) · ~/Work/web.old
- not counted: web-2: Job web-2 · 20 lines staged in 1 file · stakes low · superseded by web-5 · ~/Work/web.two
- not counted: web-3: Job web-3 · 30 lines staged in 1 file · stakes low · a duplicate of web-5 · ~/Work/web.three" ]] \
    || fail "queue text: $out"
}

@test "shep queue: a closed issue with staged work is unknown custody, never an automatic cleanup candidate" {
  local out
  repo web
  printf '%s\n' "$HOME/Work/web" >"$STATE/repos"
  staged four 4 1700000300
  bd_issue 4 closed
  record --arg p "$HOME/Work/web.four" '{path: $p, branch: "four", issue: "web-4", desk: "t4"}'
  out="$(shep queue --repo "$HOME/Work/web")" || fail "queue: $out"
  [[ "$out" == "Review queue: 4 lines in 1 change
~/Work/web: 4 of 1000 lines
- web-4: Job web-4 · 4 lines staged in 1 file · stakes low · describe check fails: no .bercail/description.md: run /validate · state unknown: issue closed but staged changes remain; custody/outcome unproven · ~/Work/web.four
~/Work/web: 4 of 1000 lines wait on the person; a new desk fits its review budget." ]] || fail "cleanup only: $out"
}

# Four staged worktrees of ~/Work/web and the window's spaces: web.spaced's record
# names live space sp1, web.folder is space sp2's folder, web.term's desk t9 sits
# in space sp3 (whose folder is ~), and web.gone's space sp-gone is closed.
spaces_fixture() {
  repo web
  printf '%s\n' "$HOME/Work/web" >"$STATE/repos"
  issues web 'web-1|Job web-1|in_progress' 'web-2|Job web-2|in_progress' 'web-3|Job web-3|in_progress' 'web-4|Job web-4|in_progress'
  staged spaced 3 1700000100
  staged folder 4 1700000200
  staged term 2 1700000300
  staged gone 5 1700000400
  local n
  for n in 1 2 3 4; do bd_issue "$n" in_progress; done
  record --arg p "$HOME/Work/web.spaced" '{path: $p, branch: "spaced", issue: "web-1", desk: "t1", space: "sp1"}'
  record --arg p "$HOME/Work/web.folder" '{path: $p, branch: "folder", issue: "web-2", desk: "t2"}'
  record --arg p "$HOME/Work/web.term" '{path: $p, branch: "term", issue: "web-3", desk: "t9"}'
  record --arg p "$HOME/Work/web.gone" '{path: $p, branch: "gone", issue: "web-4", desk: "t4", space: "sp-gone"}'
  desk t9 "$HOME/Work/web.term" "done" '{"bercail.issue": "web-3"}'
  jq -n --arg h "$HOME" '{spaces: [
    {id: "sp1", folder: "/elsewhere", machine: null, tabs: []},
    {id: "sp2", folder: "\($h)/Work/web.folder", machine: null, tabs: []},
    {id: "sp3", folder: $h, machine: null, tabs: [{terminals: [{terminal: "t9"}]}]},
    {id: "box/sp4", folder: "\($h)/Work/web.gone", machine: "box", tabs: []}]}' >"$HC_DATA/spaces.json"
  printf '#!/usr/bin/env bash\n[[ "$1" == ls ]] && cat "$HC_DATA/spaces.json"\n' >"$HERDR_APP_BIN"
  chmod +x "$HERDR_APP_BIN"
}

@test "shep queue: a staged worktree no open Herdr space has is a stale cleanup candidate, not counted" {
  local out
  spaces_fixture
  out="$(shep queue --repo "$HOME/Work/web")" || fail "queue: $out"
  [[ "$out" == "Review queue: 9 lines in 3 changes
~/Work/web: 9 of 1000 lines
- web-1: Job web-1 · 3 lines staged in 1 file · stakes low · describe check fails: no .bercail/description.md: run /validate · ~/Work/web.spaced
- web-2: Job web-2 · 4 lines staged in 1 file · stakes low · describe check fails: no .bercail/description.md: run /validate · ~/Work/web.folder
- web-3: Job web-3 · 2 lines staged in 1 file · stakes low · describe check fails: no .bercail/description.md: run /validate · ~/Work/web.term
- not counted: 1 stale worktree with no Herdr space, cleanup candidates: ~/Work/web.gone
~/Work/web: 9 of 1000 lines wait on the person; a new desk fits its review budget." ]] || fail "queue: $out"
  out="$(shep queue --json)" || fail "queue --json: $out"
  jq -e '[.items[] | [.issue, .state, .counts, .why]] == [
      ["web-1", "review", true, null], ["web-2", "review", true, null], ["web-3", "review", true, null],
      ["web-4", "stale", false, "no Herdr space"]]
    and .repos == [{path: .repos[0].path, lines: 9, changes: 3, budget: 1000, over: false}]' <<<"$out" >/dev/null \
    || fail "queue --json: $(jq -c '[.items[] | [.issue, .state, .counts]], .repos' <<<"$out")"
}

@test "shep queue returns 14 stale worktrees without looking up their optional titles" {
  local n branch out
  repo web
  for n in {1..14}; do
    branch="gone$n"
    staged "$branch" 1 "$((1700000000 + n))"
    bd_issue "$n" in_progress
    record --arg p "$HOME/Work/web.$branch" --arg b "$branch" --arg id "web-$n" '{path: $p, branch: $b, issue: $id}'
  done
  printf '#!/bin/sh\necho '\''{"spaces":[]}'\''\n' >"$HERDR_APP_BIN"
  chmod +x "$HERDR_APP_BIN"

  out="$(shep queue --json)" || fail "queue --json: $out"
  jq -e '[.items[].issue] == [range(1; 15) | "web-\(.)"]
    and all(.items[]; .state == "stale" and .counts == false)
    and .repos[0].changes == 0' <<<"$out"
  if grep -q '^bd show ' "$LOG"; then fail "queue queried Beads for stale rows: $(grep '^bd show ' "$LOG")"; fi
}

@test "shep queue: with no Herdr window answering, a worktree is not called stale" {
  local out
  spaces_fixture
  printf '#!/usr/bin/env bash\nexit 1\n' >"$HERDR_APP_BIN"
  out="$(shep queue --json)" || fail "queue --json: $out"
  jq -e '[.items[] | [.issue, .state, .counts]] == [
      ["web-1", "review", true], ["web-2", "review", true], ["web-3", "review", true], ["web-4", "review", true]]' <<<"$out" >/dev/null \
    || fail "queue --json: $(jq -c '[.items[] | [.issue, .state, .counts]]' <<<"$out")"
}

@test "shep brief and queue show the job's staged size, stakes and describe check" {
  local out
  queue_fixture
  out="$(shep brief app-2)" || fail "brief: $out"
  grep -qx "staged: 6 lines in 1 file (1 more left out: lockfiles, generated or binary), stakes high: lib/a.sh; the person reviews it before it is committed or merged · describe check fails: no .bercail/description.md: run /validate" <<<"$out" \
    || fail "brief does not show the staged change: $out"
  (
    cd "$HOME/Work/app.export" || exit 1
    jq -n --arg t "$(git write-tree)" '{tree: $t, checks: [{kind: "test", command: "bash tests/run.sh", exit_code: 0, evidence: "all passed"}]}' >.bercail/validate.json
    printf -- '---\ntitle: Add the export\n---\nAdds the export for readers of lib/a.sh.\n\nValidation: bash tests/run.sh passed.\n' >.bercail/description.md
    "$ROOT/bin/bercail" describe stamp >/dev/null
  ) || fail "stamp"
  out="$(shep brief app-2)" || fail "brief: $out"
  [[ "$out" == *"stakes high: lib/a.sh; the person reviews it before it is committed or merged · describe check ok"* ]] || fail "described: $out"
  out="$(shep queue --repo "$HOME/Work/app")" || fail "queue: $out"
  [[ "$out" == *"app-2: Add the export · 6 lines staged in 1 file · stakes high, needs the person's LGTM · described · ~/Work/app.export"* ]] || fail "queue: $out"
}

@test "shep mistake records each time, with where it happened and its key's group" {
  local out file="$STATE/mistakes.jsonl"
  repo app
  worktree app login
  shep mistake group G7 "Test isolation" --against tool >/dev/null
  out="$(shep mistake pipefail-grep-q $'printf | grep -q under pipefail\n  SIGPIPEd' --group G7 --repo "$HOME/Work/app.login" --issue app-1)"
  [[ "$out" == "recorded pipefail-grep-q (G7): printf | grep -q under pipefail SIGPIPEd" ]] || fail "first: $out"
  jq -e --arg r "$REAL_HOME/Work/app" '.key == "pipefail-grep-q" and .repo == $r and .issue == "app-1" and (.at | test("^[0-9]{4}-"))' "$file" >/dev/null \
    || fail "the line: $(cat "$file")"
  out="$(shep mistake pipefail-grep-q "again, no --group")" || fail "a grouped key needs no --group: $out"
  [[ "$out" == "recorded pipefail-grep-q (G7): again, no --group"* ]] || fail "second: $out"
}

@test "shep mistake group makes or renames a group and moves keys into it" {
  local out
  out="$(shep mistake group G2 "Bespoke checks" --against process verify-log-word-match)"
  [[ "$out" == "group G2 Bespoke checks: counts against the process, 1 key" ]] || fail "make: $out"
  out="$(shep mistake group G7 "Test isolation" --against tool verify-log-word-match tests-touch-real-state)"
  [[ "$out" == "group G7 Test isolation: counts against a tool, 2 keys" ]] || fail "move: $out"
  out="$(shep mistake group G2 "Bespoke verification" --against process)"
  [[ "$out" == "group G2 Bespoke verification: counts against the process, 0 keys" ]] || fail "rename: $out"
  jq -e '.groups.G2 == {name: "Bespoke verification", against: "process"} and .keys == {"verify-log-word-match": "G7", "tests-touch-real-state": "G7"}' \
    "$STATE/mistake-groups.json" >/dev/null || fail "the file: $(cat "$STATE/mistake-groups.json")"
  out="$(shep mistake verify-log-word-match "matched a word in the log" --group G2 2>&1)" && fail "--group moved a grouped key"
  [[ "$out" == *'verify-log-word-match is in group G7; move it, with all its entries, by: bercail shep mistake group G2 "NAME" --against KIND verify-log-word-match'* ]] \
    || fail "move by record: $out"
  [[ ! -e "$STATE/mistakes.jsonl" ]] || fail "a refused mistake was written: $(cat "$STATE/mistakes.jsonl")"
}

@test "shep mistake asks for a fix from the second time a group shows up, by what the group counts against" {
  local out today
  today="$(date -u +%Y-%m-%d)"
  repo app
  shep mistake group G2 "Bespoke verification" --against process verify-log-word-match native-response-shape-assumption >/dev/null
  shep mistake group G5 "Landing by hand" --against conduct merged-on-red-ci >/dev/null
  shep mistake group G7 "Test isolation" --against tool pipefail-grep-q >/dev/null
  out="$(shep mistake verify-log-word-match "first" --repo "$HOME/Work/app" --issue app-1)"
  [[ "$out" == "recorded verify-log-word-match (G2): first" ]] || fail "first of a group: $out"
  shep mistake pipefail-grep-q "another group" >/dev/null
  out="$(shep mistake native-response-shape-assumption "another key, same cause" --issue app-2)"
  [[ "$out" == "recorded native-response-shape-assumption (G2): another key, same cause
G2 Bespoke verification has now happened 2 times under 2 keys; the first: $today (app-1, ~/Work/app).
It counts against the process, not the desks: file an issue that removes or simplifies the step that caused it, instead of adding a check on the desks." ]] \
    || fail "process: $out"
  out="$(shep mistake pipefail-grep-q "the same in doctor")"
  [[ "$out" == *"G7 Test isolation has now happened 2 times under 1 key; the first: $today."$'\n'"A mistake seen twice is fixed in the system: file an issue for a guardrail (a lint rule, a test, the guard, or a doctor check) instead of fixing it by hand again." ]] \
    || fail "tool: $out"
  shep mistake merged-on-red-ci "first" >/dev/null
  out="$(shep mistake merged-on-red-ci "again")"
  [[ "$out" == *"file an issue for a rule in SHEP.md or a skill, or a check that catches it, instead of fixing it by hand again." ]] || fail "conduct: $out"
}

@test "shep mistake list prints each group with its counts, then its keys, the most frequent first" {
  local out today
  today="$(date -u +%Y-%m-%d)"
  out="$(shep mistake list)"
  [[ "$out" == 'no mistakes recorded yet; record one with: bercail shep mistake KEY "WHAT" --group ID [--repo DIR] [--issue ID]' ]] || fail "empty list: $out"
  shep mistake group G8 "Spend" --against tool >/dev/null
  shep mistake group G5 "Landing by hand" --against conduct >/dev/null
  shep mistake group G7 "Test isolation" --against tool >/dev/null
  shep mistake desk-pushed-main "pushed master itself" --group G5 >/dev/null
  shep mistake pipefail-grep-q "first" --issue app-1 --group G7 >/dev/null
  shep mistake pipefail-grep-q "second" >/dev/null
  shep mistake tests-touch-real-state "wrote the real handoffs.jsonl" --group G7 >/dev/null
  printf '{"at":"2026-11-13T00:00:00Z","key":"old-key","what":"from before groups"}\n' >>"$STATE/mistakes.jsonl"
  out="$(shep mistake list)"
  [[ "$out" == "G7 Test isolation (counts against a tool): 3 times, 2 keys
  pipefail-grep-q: 2 times
    $today  app-1: first
    $today  second
  tests-touch-real-state: 1 time
    $today  wrote the real handoffs.jsonl
G5 Landing by hand (counts against conduct): 1 time, 1 key
  desk-pushed-main: 1 time
    $today  pushed master itself
G8 Spend (counts against a tool): 0 times, 0 keys
no group (bercail shep mistake group ID \"NAME\" --against KIND KEY... puts a key in one): 1 time, 1 key
  old-key: 1 time
    2026-11-13  from before groups" ]] || fail "list: $out"
}

@test "shep mistake refuses a bad key, no WHAT, a new key with no group, or a --repo that is no checkout, and writes nothing" {
  local out
  out="$(shep mistake 'Bad Key' x 2>&1)" && fail "a bad key passed"
  [[ "$out" == *"KEY is a short name in a-z, 0-9 and -"* ]] || fail "bad key: $out"
  out="$(shep mistake some-key 2>&1)" && fail "no WHAT passed"
  [[ "$out" == *'usage: bercail shep mistake KEY "WHAT"'* ]] || fail "no what: $out"
  out="$(shep mistake some-key x 2>&1)" && fail "a new key with no group passed"
  [[ "$out" == *"some-key is in no group yet: give it a --group"* ]] || fail "no group: $out"
  out="$(shep mistake some-key x --group G9 2>&1)" && fail "a group that does not exist passed"
  [[ "$out" == *'there is no group G9; make it with: bercail shep mistake group G9 "NAME" --against process|tool|conduct'* ]] || fail "unknown group: $out"
  shep mistake group G9 "Secrets" --against conduct >/dev/null
  out="$(shep mistake some-key x --group G9 --repo "$BATS_TEST_TMPDIR" 2>&1)" && fail "a --repo that is no checkout passed"
  [[ "$out" == *"is not a git checkout"* ]] || fail "bad repo: $out"
  [[ ! -e "$STATE/mistakes.jsonl" ]] || fail "a refused mistake was written: $(cat "$STATE/mistakes.jsonl")"
  jq -e '.keys == {}' "$STATE/mistake-groups.json" >/dev/null || fail "a refused mistake moved a key: $(cat "$STATE/mistake-groups.json")"
  out="$(shep mistake group G9 "Secrets" --against people 2>&1)" && fail "a bad --against passed"
  [[ "$out" == *"--against is process, tool or conduct"* ]] || fail "bad against: $out"
  out="$(shep mistake group G9 "Secrets" --against tool 'Bad Key' 2>&1)" && fail "a bad key in a group passed"
  [[ "$out" == *"KEY is a short name"* ]] || fail "bad group key: $out"
  jq -e '.groups.G9.against == "conduct"' "$STATE/mistake-groups.json" >/dev/null || fail "a refused group was written: $(cat "$STATE/mistake-groups.json")"
}

# pi: logs each run; --list-models prints the table for $FAKE_WINDOW (none when empty).
settings_pi() {
  cat >"$BATS_TEST_TMPDIR/bin/pi" <<'EOF'
#!/usr/bin/env bash
if [[ " $* " == *" --list-models "* ]]; then
  printf 'pi-list %s\n' "$*" >>"$LOG"
  printf 'provider  model  context  max-out\n'
  [[ -z "${FAKE_WINDOW:-}" ]] || printf '%s      lead   %s       128K\n' "${FAKE_PROVIDER:-fake}" "$FAKE_WINDOW"
  exit 0
fi
{ printf 'pi cwd=%s state=%s bin=%s rollover=%s\n' "$PWD" "${BERCAIL_SHEP_STATE:-}" "${BERCAIL_SHEP_BIN:-}" "${BERCAIL_SHEP_ROLLOVER:-}"
  printf 'pi-arg %s\n' "$@"; } >>"$LOG"
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/pi"
  mkdir -p "$HOME/.local/share/bercail/pi"
  jq -n --arg p "${FAKE_PROVIDER:-fake}" '["pi","--model","\($p)/lead:high","-e","/x/provider.ts"]' >"$HOME/.local/share/bercail/pi/lead.json"
}

@test "shep run keeps the Claude bridge's reserve when compact_at is close to the window" {
  local out file="$STATE/workspace/.pi/settings.json"
  export FAKE_PROVIDER=claude-bridge
  settings_pi
  printf '[shep]\ncompact_at = 190000\n' >"$CONFIG"
  out="$(FAKE_WINDOW=200K shep run </dev/null 2>&1)" || fail "run: $out"
  jq -e '.compaction.modelOverrides["claude-bridge/lead"].reserveTokens == 40000' "$file" >/dev/null || fail "near the window: $(cat "$file")"
  printf '[shep]\ncompact_at = 100000\n' >"$CONFIG"
  FAKE_WINDOW=200K shep run </dev/null >/dev/null 2>&1
  jq -e '.compaction.modelOverrides["claude-bridge/lead"].reserveTokens == 100000' "$file" >/dev/null || fail "well below: $(cat "$file")"
}

@test "shep run puts Shep's compaction in its workspace settings, for the lead model, and Pi trusts that folder" {
  local out args file="$STATE/workspace/.pi/settings.json"
  settings_pi
  out="$(FAKE_WINDOW=1M shep run </dev/null 2>&1)" || fail "run: $out"
  [[ -z "$out" ]] || fail "run printed: $out"
  jq -e '. == {compaction: {enabled: true, keepRecentTokens: 50000,
    modelOverrides: {"fake/lead": {keepRecentTokens: 50000, reserveTokens: 750000}}}}' "$file" >/dev/null || fail "settings: $(cat "$file")"
  grep -qx "pi-list --offline --list-models lead -e /x/provider.ts" "$LOG" || fail "the window lookup: $(grep pi-list "$LOG")"
  grep -qx "pi cwd=$STATE/workspace state=$STATE bin=$ROOT/bin/bercail rollover=0" "$LOG" || fail "Pi env: $(grep '^pi cwd' "$LOG")"
  args="$(sed -n 's/^pi-arg //p' "$LOG" | tr '\n' ' ')"
  [[ "$args" == *"--approve "* && "$args" == *"-e $HOME/.local/share/bercail/shep/pi/compaction.ts "* \
    && "$args" == *"--append-system-prompt $STATE/context.md "* ]] || fail "Pi argv: $args"

  # config.toml [shep] sets both numbers and rollover; other settings in the file stay.
  printf '[shep]\ncompact_at = 100000\nkeep_recent = 30000\nrollover = true\n' >"$CONFIG"
  jq '.theme = "dark"' "$file" >"$file.new" && mv "$file.new" "$file"
  : >"$LOG"
  FAKE_WINDOW=200K shep run </dev/null >/dev/null 2>&1
  jq -e '.theme == "dark" and .compaction == {enabled: true, keepRecentTokens: 30000,
    modelOverrides: {"fake/lead": {keepRecentTokens: 30000, reserveTokens: 100000}}}' "$file" >/dev/null || fail "config: $(cat "$file")"
  grep -q '^pi cwd=.* rollover=1$' "$LOG" || fail "rollover: $(grep '^pi cwd' "$LOG")"
}

@test "shep run keeps Pi's own threshold, and says why, when it cannot place compact_at or write the settings" {
  local out file="$STATE/workspace/.pi/settings.json"
  settings_pi
  printf '[shep]\ncompact_at = lots\n' >"$CONFIG"
  out="$(FAKE_WINDOW=1M shep run </dev/null 2>&1)"
  [[ "$out" == "bercail shep: [shep] compact_at = lots in config.toml is not a number of tokens; using 250000" ]] || fail "bad number: $out"
  jq -e '.compaction.modelOverrides["fake/lead"].reserveTokens == 750000' "$file" >/dev/null || fail "bad number: $(cat "$file")"
  printf '[shep]\ncompact_at = 300000\n' >"$CONFIG"
  out="$(FAKE_WINDOW=200K shep run </dev/null 2>&1)"
  [[ "$out" == "bercail shep: [shep] compact_at = 300000 is not below fake/lead's 200000-token window; Shep compacts when the window is nearly full" ]] \
    || fail "too big: $out"
  jq -e '.compaction.modelOverrides["fake/lead"] == {keepRecentTokens: 50000}' "$file" >/dev/null || fail "too big: $(cat "$file")"
  rm "$CONFIG"
  out="$(FAKE_WINDOW=200K shep run </dev/null 2>&1)"
  [[ -z "$out" ]] && jq -e '.compaction.modelOverrides["fake/lead"] == {keepRecentTokens: 50000}' "$file" >/dev/null \
    || fail "the default on a 200K window: $out $(cat "$file")"
  out="$(FAKE_WINDOW="" shep run </dev/null 2>&1)"
  [[ "$out" == "bercail shep: pi --list-models does not show fake/lead's context window; Shep compacts when that window is nearly full" ]] \
    || fail "unlisted: $out"
  printf '[shep]\ncompact_at = 0\n' >"$CONFIG"
  out="$(FAKE_WINDOW=1M shep run </dev/null 2>&1)"
  [[ -z "$out" ]] && jq -e '.compaction.modelOverrides["fake/lead"] == {keepRecentTokens: 50000}' "$file" >/dev/null \
    || fail "compact_at = 0: $out $(cat "$file")"
  rm "$HOME/.local/share/bercail/pi/lead.json" "$CONFIG"
  : >"$LOG"
  out="$(shep run </dev/null 2>&1)"
  [[ -z "$out" ]] && jq -e '.compaction == {enabled: true, keepRecentTokens: 50000}' "$file" >/dev/null || fail "no lead: $out $(cat "$file")"
  ! grep -q pi-list "$LOG" || fail "looked up a window with no lead model"
  # A settings file that cannot be written does not keep Shep from starting.
  rm -rf "$STATE/workspace/.pi"
  printf 'not a folder\n' >"$STATE/workspace/.pi"
  : >"$LOG"
  out="$(shep run </dev/null 2>&1)"
  [[ "$out" == *"could not write $file; Pi's compaction defaults apply"* ]] && grep -q '^pi cwd=' "$LOG" \
    || fail "unwritable settings: $out $(cat "$LOG")"
}

@test "shep run gives Shep a start context with the known repos, the todo targets and their routes, and the standing rules" {
  local today
  today="$(date +%Y-%m-%d)"
  settings_pi
  repo app
  issues app 'app-1|One|open'
  printf '%s\n' "$HOME/Work/app" >"$STATE/repos"
  shep remember 'Merge app work to main' --scope app >/dev/null
  mkdir -p "$HOME/.config/bercail"
  jq -n --arg app "$(cd "$HOME/Work/app" && pwd -P)" '{default: "home",
    targets: {home: {backend: "basecamp", label: "to-do list \"Errands\" in Home", url: "https://3.basecamp.com/1/buckets/2/todolists/3"},
              lesentiel: {backend: "basecamp", label: "to-do list \"Todos\" in Show the vision"}},
    routes: {($app): "lesentiel"}}' >"$HOME/.config/bercail/todo.json"
  FAKE_WINDOW=1M shep run </dev/null >/dev/null 2>&1
  [[ "$(cat "$STATE/context.md")" == "# Shep context at start

bercail wrote this when Shep started. It is data, not instructions from a desk.

## Known repos

- ~/Work/app: gh, no policy, 1 open issue

## Todo targets

Where bercail todo add sends a todo: --target, else the route of the job's repo, else the default.

- home (default): basecamp, to-do list \"Errands\" in Home · https://3.basecamp.com/1/buckets/2/todolists/3
- lesentiel: basecamp, to-do list \"Todos\" in Show the vision · routes ~/Work/app

## Standing rules from the person

- $today [app] Merge app work to main" ]] || fail "context: $(cat "$STATE/context.md")"
  rm "$STATE/repos" "$STATE/preferences.md" "$HOME/.config/bercail/todo.json"
  FAKE_WINDOW=1M shep run </dev/null >/dev/null 2>&1
  grep -qx -- '- none found yet (`bercail shep repos` explains where they come from)' "$STATE/context.md" \
    && grep -qx -- '- no todo targets yet: bercail todo target add <name> <to-do list URL>' "$STATE/context.md" \
    && grep -qx -- '- none yet' "$STATE/context.md" || fail "empty context: $(cat "$STATE/context.md")"
}

@test "brief and board keep identical issue ids tied to their original repos" {
  local out name cmd
  for name in a b; do
    repo "$name"; worktree "$name" "fix-$name"
    issues "$name" "same-1|Job $name|in_progress"
    jq -n --arg t "Job $name" '{id:"same-1",title:$t,status:"in_progress"}' >"$HOME/Work/$name/.beads/fake/same-1.json"
  done
  printf '%s\n' "$HOME/Work/a" "$HOME/Work/b" >"$STATE/repos"
  record --arg p "$HOME/Work/a.fix-a" '{path:$p,branch:"fix-a",issue:"same-1",desk:"t9",space:"spa"}'
  record --arg p "$HOME/Work/b.fix-b" '{path:$p,branch:"fix-b",issue:"same-1",desk:"t8",space:"spb"}'
  desk t9 "$HOME/Work/a.fix-a" working '{"bercail.issue":"same-1","bercail.space":"spa"}'
  desk t8 "$HOME/Work/b.fix-b" working '{"bercail.issue":"same-1","bercail.space":"spb"}'
  out="$(shep brief same-1 2>&1)" && fail "$out"
  [[ "$out" == *"more than one repo"* ]]
  out="$(shep brief same-1 --repo "$HOME/Work/a")" || fail "$out"
  [[ "$out" == *"desk t9"* && "$out" != *"desk t8"* && "$out" == *"fix-a"* ]]
  out="$(shep board)" || fail "$out"
  [[ "$out" == *"Job a"*"desk t9"*"fix-a"* && "$out" == *"Job b"*"desk t8"*"fix-b"* ]]
  # A finished desk's line names a brief that runs: with the repo, since b has same-1 too.
  desk t9 "$HOME/Work/a.fix-a" "done" '{"bercail.issue":"same-1","bercail.space":"spa"}'
  out="$(shep board)" || fail "$out"
  cmd="$(sed -n 's/.*desk t9 finished; read its report in \(.*\), then review.*/\1/p' <<<"$out")"
  [[ "$cmd" == "bercail shep brief same-1 --repo '$HOME/Work/a'" ]] || fail "board: $out"
  out="$(eval "${cmd/bercail shep/shep}")" || fail "$cmd: $out"
  [[ "$out" == *"desk t9 done"* && "$out" == *"fix-a"* ]] || fail "$out"
  # b's same-1 is closed and its desk gone, but its handoff still names it.
  issues b "same-1|Job b|closed"
  rm "$HC_DATA/t8.json"
  jq 'del(.terminals[] | select(.address == "t8"))' "$HC_DATA/ls.json" >"$HC_DATA/ls.tmp"
  mv "$HC_DATA/ls.tmp" "$HC_DATA/ls.json"
  out="$(shep board)" || fail "$out"
  cmd="$(sed -n 's/.*desk t9 finished; read its report in \(.*\), then review.*/\1/p' <<<"$out")"
  out="$(eval "${cmd/bercail shep/shep}")" || fail "$cmd: $out"
  [[ "$out" == *"desk t9 done"* ]] || fail "$out"
}

@test "a v0.17 request ledger no longer keeps a closed issue on the board, the queue or the brief" {
  local out file
  queue_fixture
  file="$HOME/Work/app/.beads/fake/app-3.json"
  jq '.metadata.bercail_task={requests:[{id:"amend2",outcome:"publish",authoring:"gt m -a",status:"queued",next:"Original desk processes this work"}]}' "$file" >"$BATS_TEST_TMPDIR/r"
  mv "$BATS_TEST_TMPDIR/r" "$file"
  jq --slurpfile r "$file" 'map(if .id == "app-3" then .metadata=$r[0].metadata else . end)' "$HOME/Work/app/.beads/fake/list.json" >"$BATS_TEST_TMPDIR/r"
  mv "$BATS_TEST_TMPDIR/r" "$HOME/Work/app/.beads/fake/list.json"
  out="$(shep queue --repo "$HOME/Work/app" --json)" || fail "$out"
  jq -e 'any(.items[]; .issue == "app-3" and .state == "unknown") and all(.items[]; .state != "outstanding")' <<<"$out" || fail "$out"
  out="$(shep brief app-3 --repo "$HOME/Work/app")" || fail "$out"
  [[ "$out" != *"amend2"* && "$out" != *"request"* ]] || fail "$out"
  out="$(shep board)" || fail "$out"
  [[ "$out" != *"amend2"* && "$out" != *"requested work remains"* ]] || fail "$out"
}

@test "repo queue neither queries unrelated slow GitHub repos nor waits on their status" {
  local out
  queue_fixture
  git -C "$HOME/Work/docs" remote add origin https://github.com/o/docs.git
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'EOF'
#!/bin/sh
case "$PWD" in */docs) echo unrelated >>"$LOG"; exec sleep 30 ;; esac
case "$1" in api) echo me ;; pr) cat "$HC_DATA/prs.json" ;; esac
EOF
  out="$(shep queue --repo "$HOME/Work/app" --json)" || fail "$out"
  jq -e '.repos | length == 1' <<<"$out"
  ! grep -q unrelated "$LOG"
}

@test "the global queue reads 30 desks once and skips full Beads lists" {
  local name branch out
  for name in app api web; do
    repo "$name"
    for branch in {1..10}; do
      worktree "$name" "feat$branch"
      desk "t-$name-$branch" "$HOME/Work/$name.feat$branch" idle
    done
  done
  printf 'change\n' >"$HOME/Work/web.feat10/change"
  git -C "$HOME/Work/web.feat10" add change

  out="$(shep queue --json)" || fail "queue --json: $out"

  jq -e --arg path "$REAL_HOME/Work/web.feat10" '[.items[] | [.path, .state]] == [[$path, "review"]]' <<<"$out"
  [[ "$(grep -c 'hc ls .*--label' "$LOG")" == 1 ]]
  ! grep -q '^bd list ' "$LOG"
}

# A stand-in, meet NAME, that marks NAME started and waits up to 5s for N
# names in all; it fails if they never come. Reads that meet must run at once:
# one after another, the first is cut off by its bound before the rest start.
barrier() {
  export BARRIER="$BATS_TEST_TMPDIR/barrier"
  mkdir -p "$BARRIER"
  cat >"$BATS_TEST_TMPDIR/bin/meet" <<EOF
#!/usr/bin/env bash
touch "\$BARRIER/\$1"
for _ in \$(seq 100); do
  [[ "\$(find "\$BARRIER" -type f | wc -l)" -ge $1 ]] && exit 0
  sleep 0.05
done
exit 1
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/meet"
}

@test "the global queue reads each repo's staged work and open PRs at once, not one repo after another" {
  local name out
  # bd show and gh pr list meet in each of two repos, inside their 2s bounds.
  barrier 4
  cat >"$BATS_TEST_TMPDIR/bin/bd" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == show ]] && meet "bd-${PWD##*/}" && cat "$PWD/.beads/fake/$2.json"
EOF
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "api user") printf 'simon\n' ;;
  "pr list") meet "gh-${PWD##*/}" && printf '[]\n' ;;
  *) exit 2 ;;
esac
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/"*
  for name in a b; do
    repo "$name"
    git -C "$HOME/Work/$name" remote add origin "git@github.com:o/$name.git"
    jq -n --arg id "$name-1" '{id: $id, title: "Job \($id)", status: "in_progress"}' >"$HOME/Work/$name/.beads/fake/$name-1.json"
    worktree "$name" feat
    seq 1 3 >"$HOME/Work/$name.feat/notes.md"
    git -C "$HOME/Work/$name.feat" add notes.md
    record --arg p "$HOME/Work/$name.feat" --arg id "$name-1" '{path: $p, branch: "feat", issue: $id}'
  done
  printf '%s\n' "$HOME/Work/a" "$HOME/Work/b" >"$STATE/repos"

  out="$(shep queue --json)" || fail "queue: $out"

  jq -e '[.items[] | [.issue, .title, .state]] == [["a-1", "Job a-1", "review"], ["b-1", "Job b-1", "review"]]' <<<"$out" >/dev/null \
    || fail "queue: $(jq -c '[.items[] | {issue, title, state, why}]' <<<"$out")"
}

@test "a staged item the queue cannot build is UNKNOWN, never an empty queue" {
  local path
  repo a
  worktree a feat
  path="$HOME/Work/a.feat"
  seq 1 3 >"$path/notes.md"
  git -C "$path" add notes.md
  run bash -c 'set -euo pipefail; source "$ROOT/lib/common.sh"; for n in "${BERCAIL_LIBS[@]}"; do source "$ROOT/lib/$n.sh"; done
    _shep_need_policy
    _shep_queue_state() { printf "not json\n"; }
    _shep_queue_json "$(jq -nc --arg m "$HOME/Work/a" "[{path: \$m, backend: \"gh\"}]")" \
      "$(jq -nc --arg p "$1" "[{address: \"t1\", cwd: \$p, state: \"idle\", issue: \"a-1\"}]")" "{}"' _ "$path"
  [[ "$status" -ne 0 ]] || fail "an unbuilt item read as: $output"
}

@test "slow or failed PR status is bounded UNKNOWN, never an invented empty queue" {
  local out start
  queue_fixture
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'EOF'
#!/bin/sh
case "$1" in api) echo me ;; pr) exit 3 ;; esac
EOF
  out="$(unset BERCAIL_SHEP_QUEUE_WAIT; shep queue --repo "$HOME/Work/app" --json)" && fail "$out"
  jq -e '.status == "unknown" and .items == null and .repos == null
    and .error == "status sources failed or exceeded 6s; not a dispatch gate"' <<<"$out"
  printf '#!/bin/sh\nexec sleep 30\n' >"$BATS_TEST_TMPDIR/bin/gh"
  start=$SECONDS
  out="$(shep queue --repo "$HOME/Work/app" --json)" && fail "$out"
  [[ $((SECONDS-start)) -lt 8 ]] || fail "repo intake exceeded eight seconds"
  jq -e '.status == "unknown" and .items == null' <<<"$out"
}

@test "BERCAIL_SHEP_QUEUE_WAIT sets the queue's budget: a source past it, though inside its own bound, makes the queue UNKNOWN" {
  local out
  # herdr-app answers inside its own 2s bound, but after the queue's 1s.
  printf '#!/bin/sh\nsleep 1.5\necho '\''{"spaces":[]}'\''\n' >"$HERDR_APP_BIN"
  chmod +x "$HERDR_APP_BIN"
  out="$(BERCAIL_SHEP_QUEUE_WAIT=1 shep queue --json)" && fail "a 1s budget let a 1.5s source through: $out"
  jq -e '.status == "unknown" and .error == "status sources failed or exceeded 1s; not a dispatch gate"' <<<"$out"
  out="$(BERCAIL_SHEP_QUEUE_WAIT=1 shep queue 2>&1)" && fail "$out"
  [[ "$out" == "Review queue: UNKNOWN (status sources failed or exceeded 1s); accepted work can still dispatch." ]] || fail "$out"
}

# bats test_tags=live
@test "live: Pi loads Shep's workspace settings only when the folder is trusted, context files or not" {
  local pi ws="$HOME/.local/state/bercail/shep/workspace" flags out
  pi="$(PATH="$OLD_PATH" real_pi)"
  [[ -n "$pi" ]] || skip "Pi not found; live proof not run"
  mkdir -p "$ws/.pi"
  printf '{"compaction":{"keepRecentTokens":4242}}\n' >"$ws/.pi/settings.json"
  cat >"$BATS_TEST_TMPDIR/probe.ts" <<'EOF'
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent"
import { appendFileSync } from "node:fs"
export default function (pi: ExtensionAPI) {
  pi.on("session_start", () => {
    appendFileSync(process.env.PROBE_OUT!, `${process.env.PROBE_FLAGS} ${(pi.getSettings() as any).compaction?.keepRecentTokens ?? "none"}\n`)
  })
}
EOF
  for flags in "--no-context-files" "--no-context-files --approve" "--approve" ""; do
    # shellcheck disable=SC2086
    (cd "$ws" && PI_OFFLINE=1 PROBE_OUT="$BATS_TEST_TMPDIR/probe.out" PROBE_FLAGS="[$flags]" \
      "$pi" --model fake/model -e "$ROOT/tests/shep_pi_provider.ts" -e "$BATS_TEST_TMPDIR/probe.ts" $flags --no-session -p hi \
      </dev/null >/dev/null 2>&1) || fail "pi $flags failed"
  done
  out="$(cat "$BATS_TEST_TMPDIR/probe.out")"
  [[ "$out" == "[--no-context-files] none
[--no-context-files --approve] 4242
[--approve] 4242
[] none" ]] || fail "project settings: $out"
}

# bats test_tags=live
@test "live: Shep compacts with the board, a new rule and its decisions, at compact_at, and rolls over" {
  local pi
  pi="$(PATH="$OLD_PATH" real_pi)"
  [[ -n "$pi" ]] || skip "Pi not found; live proof not run"
  command -v script >/dev/null 2>&1 || fail "script (util-linux) is required for the live proof"
  "$(PATH="$OLD_PATH" command -v node)" "$ROOT/tests/shep_context_live.ts" "$ROOT" "$pi"
}
