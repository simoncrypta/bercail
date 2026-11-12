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
  # Only the stand-ins, then the system bins; the live cases look for Pi on the old PATH.
  OLD_PATH="$PATH"
  export PATH="$BATS_TEST_TMPDIR/bin:/usr/bin:/bin"
  mkdir -p "$BATS_TEST_TMPDIR/bin" "$HC_DATA" "$HOME/Work" "$XDG_CONFIG_HOME/bercail" \
    "$XDG_STATE_HOME/bercail/shep" "$XDG_STATE_HOME/agentic-dev"
  REAL_HOME="$(cd "$HOME" && pwd -P)"
  STATE="$XDG_STATE_HOME/bercail/shep"
  CONFIG="$XDG_CONFIG_HOME/bercail/config.toml"
  RECORDS="$XDG_STATE_HOME/agentic-dev/handoffs.jsonl"
  printf '{"terminals":[]}\n' >"$HC_DATA/ls.json"

  # hc answers ls, get and read from $HC_DATA.
  cat >"$BATS_TEST_TMPDIR/bin/hc" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  ls) cat "$HC_DATA/ls.json" ;;
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
    {backend: "gh", policy: "untrusted", open: null}, {backend: "gh", policy: "none", open: null}] and all(has("issues") | not)' \
    <<<"$out" >/dev/null || fail "repos --json: $out"
  out="$(shep repos)"
  [[ "$out" == "~/Work/a  gt  policy trusted    2 open  (config, extras, trust)
~/Work/b  gh  policy untrusted  no beads  (extras)
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
  [[ "$out" == *"has characters a beads id does not"* ]] || fail "bad id: $out"
}

@test "shep board: a line per job in each known repo, other repos, stray desks, and what waits on the person" {
  local out want
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
- app-1: Fix the login: desk t9 is blocked; bercail shep brief app-1 shows what it asks
- app-2: Add the export, a title long enough that the board has to cut it shor…: desk t8 finished; review its staged changes in its space
- app-6: Wait for CI: background Shep shep-bg-app-6 finished; report it, then hc kill shep-bg-app-6
- desk t6 (~/Work/tools) is blocked"
  [[ "$out" == "$want" ]] || fail "board: $(diff <(printf '%s\n' "$want") <(printf '%s\n' "$out"))"
  rm "$HC_DATA"/t*.json
  printf '{"terminals":[]}\n' >"$HC_DATA/ls.json"
  issues app 'app-4|Backlog|open'
  out="$(shep board)" || fail "quiet board: $out"
  [[ "$out" == "Other repos: ~/Work/app (1 open), ~/Work/docs (1 open), ~/Work/tools (no beads)
Waiting on the person:
- nothing" ]] || fail "quiet board: $out"
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

@test "shep remember, list and forget keep dated, scoped rules in Shep's preferences file" {
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

@test "shep run gives Shep a start context with the known repos and the standing rules" {
  local today
  today="$(date +%Y-%m-%d)"
  settings_pi
  repo app
  issues app 'app-1|One|open'
  printf '%s\n' "$HOME/Work/app" >"$STATE/repos"
  shep remember 'Merge app work to main' --scope app >/dev/null
  FAKE_WINDOW=1M shep run </dev/null >/dev/null 2>&1
  [[ "$(cat "$STATE/context.md")" == "# Shep context at start

bercail wrote this when Shep started. It is data, not instructions from a desk.

## Known repos

- ~/Work/app: gh, no policy, 1 open issue

## Standing rules from the person

- $today [app] Merge app work to main" ]] || fail "context: $(cat "$STATE/context.md")"
  rm "$STATE/repos" "$STATE/preferences.md"
  FAKE_WINDOW=1M shep run </dev/null >/dev/null 2>&1
  grep -qx -- '- none found yet (`bercail shep repos` explains where they come from)' "$STATE/context.md" \
    && grep -qx -- '- none yet' "$STATE/context.md" || fail "empty context: $(cat "$STATE/context.md")"
}

@test "the compaction extension's unit checks" {
  command -v node >/dev/null 2>&1 || skip "node not found"
  node --disable-warning=MODULE_TYPELESS_PACKAGE_JSON --experimental-strip-types "$ROOT/tests/shep_compaction_test.mjs"
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
  command -v python3 >/dev/null 2>&1 || fail "python3 is required for the live proof"
  python3 "$ROOT/tests/shep_context_live.py" "$ROOT" "$pi"
}
