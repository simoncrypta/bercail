#!/usr/bin/env bats
# One pick lands a job (docs/plans/one-pick-landing.md, step 6): bercail land ask
# puts up a land card, and on the person's Ship it the worker, bercail land run,
# commits, pushes a CI branch, waits for CI, pushes the trunk, closes the issue,
# cleans up the desk and fast-forwards the main checkout. Real git repos, origin
# a bare repo behind a stand-in ssh as git@github.com:o/app.git; stand-ins for
# gh, hc, bd and the Herdr app at the process boundary; poll and timeout 0.

setup() {
  load test_helper
  isolate
  need git jq node flock
  set -o pipefail
  unset BERCAIL_CONFIG HC_TERMINAL_ID BERCAIL_SELF
  export BERCAIL_ROLE=shep BERCAIL_LAND_POLL=0 BERCAIL_LAND_TIMEOUT=0
  export FAKE="$BATS_TEST_TMPDIR/bin" STATE="$BATS_TEST_TMPDIR/fake" LOG="$BATS_TEST_TMPDIR/argv"
  export HERDR_APP_BIN="$FAKE/herdr-app" HC_BIN="$FAKE/hc" BERCAIL_HERDR_LAYOUT="$ROOT/config/worktrunk/herdr-layout.sh"
  export PATH="$FAKE:$PATH"
  mkdir -p "$STATE"
  : >"$LOG"
  # The worker drops GIT_CONFIG_*, so git's settings live in HOME, as the person's do.
  git config --global user.name Simon
  git config --global user.email simon@example.com
  git config --global init.defaultBranch master
  BERCAIL="$ROOT/bin/bercail"
  SHEP="$XDG_STATE_HOME/bercail/shep"
  INBOX="$SHEP/inbox"
  GH="$BATS_TEST_TMPDIR/github"
  ORIGIN="$GH/o/app.git"
  MAIN="$HOME/Work/app"
  WT="$HOME/Work/app.login"
  mkdir -p "$GH/o" "$INBOX" "$XDG_STATE_HOME/bercail/desk-sessions"
  stand_ins
  git init -q --bare -b master "$ORIGIN"
  git_init "$MAIN"
  git -C "$MAIN" branch -M master
  mkdir -p "$MAIN/.bercail"
  printf 'push = "main"\nintegrate = "direct"\nrequired_ci = [".github/workflows/ci.yml"]\n' >"$MAIN/.bercail/policy.toml"
  git -C "$MAIN" add -f .bercail/policy.toml
  git -C "$MAIN" commit -qm policy
  printf '.bercail/\n' >>"$MAIN/.git/info/exclude"
  git -C "$MAIN" remote add origin git@github.com:o/app.git
  git -C "$MAIN" config core.sshCommand "$FAKE/ssh"
  git -C "$MAIN" config ssh.variant simple
  git -C "$MAIN" push -q -u origin master
  git -C "$MAIN" remote set-head origin master
  MAIN="$(cd "$MAIN" && pwd -P)" WT="$(cd "$HOME/Work" && pwd -P)/app.login"
  "$BERCAIL" policy trust "$MAIN" >/dev/null
  desk "$WT" login app-1 t9 sp1
  printf 'new\n' >>"$WT/file.txt"
  git -C "$WT" add file.txt
  described "$WT" "file: add a line"
}

# Stand-ins at the process boundary, each logging its argv to $LOG.
stand_ins() {
  mkdir -p "$FAKE"
  # ssh: serves git@github.com:<path> from the bare repos under $GH.
  printf '#!/bin/sh\nfor last; do :; done\ncd %q && exec sh -c "$last"\n' "$GH" >"$FAKE/ssh"
  # The Herdr app: no window here, so cleanup finds the space through hc.
  printf '#!/bin/sh\nexit 1\n' >"$FAKE/herdr-app"
  # hc: terminals in $STATE/hc.json. run logs the start, as the Herdr server
  # would get it, and the test runs it; $STATE/run-fails makes it fail.
  # $STATE/hc-down: hc answers nothing.
  cat >"$FAKE/hc" <<'SH'
#!/usr/bin/env bash
printf 'hc %s\n' "$*" >>"$LOG"
[[ ! -f "$STATE/hc-down" ]] || exit 1
st="$STATE/hc.json"
case "$1" in
  run)
    [[ ! -f "$STATE/run-fails" ]] || { echo "hc: the server is gone" >&2; exit 1; }
    while [[ $# -gt 0 && "$1" != -- ]]; do shift; done
    shift
    printf '%q ' "$@" >>"$STATE/starts"
    printf '\n' >>"$STATE/starts"
    printf '{"address":"t50"}\n' ;;
  ls)
    want=()
    while [[ $# -gt 0 ]]; do [[ "$1" != --label ]] || want+=("$2"); shift; done
    jq --args '{terminals: [.[] | select(. as $t | $ARGS.positional
        | all(split("=") as [$k, $v] | $t.labels[$k] == $v)) | {address, state, cwd, labels: null}]}' \
      "${want[@]}" <"$st" ;;
  get)
    jq -e --arg a "$2" '.[] | select(.address == $a)' "$st" \
      || { printf '{"error":{"kind":"not_found","message":"no terminal"}}\n'; exit 3; } ;;
  kill) jq --arg a "$2" 'map(if .address == $a then .state = "finished" else . end)' "$st" >"$st.tmp" && mv "$st.tmp" "$st" ;;
  rm) jq --arg a "$2" 'map(select(.address != $a))' "$st" >"$st.tmp" && mv "$st.tmp" "$st" ;;
esac
SH
  # gh: the required and optional workflows, and the push runs of the commit and
  # branch asked about, from $STATE/ci: one run a line, "<workflow id> <status>
  # <conclusion> [branch] [attempt]". Each call first runs $STATE/on-ci, if any.
  cat >"$FAKE/gh" <<'SH'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >>"$LOG"
case "$1 $2" in
  "workflow list") printf '[{"id":7,"path":".github/workflows/ci.yml"},{"id":9,"path":".github/workflows/site.yml"}]\n' ;;
  "run list")
    [[ ! -x "$STATE/on-ci" ]] || "$STATE/on-ci"
    while [[ $# -gt 0 ]]; do
      case "$1" in --commit) sha="$2" ;; --branch) branch="$2" ;; --limit) limit="$2" ;; esac
      shift
    done
    n=0
    while read -r id status conclusion other attempt; do
      [[ -n "$id" ]] || continue
      n=$((n + 1))
      [[ -n "$other" && "$other" != - ]] || other="$branch"
      jq -nc --argjson id "$id" --arg s "$status" --arg c "$conclusion" --arg sha "$sha" --arg b "$other" \
        --argjson n "$n" --argjson a "${attempt:-1}" \
        '{databaseId: $n, workflowDatabaseId: $id, headBranch: $b, headSha: $sha, attempt: $a, status: $s, conclusion: $c}'
    done < <(cat "$STATE/ci" 2>/dev/null) | jq -s --argjson limit "$limit" '.[:$limit]' ;;
  *) exit 2 ;;
esac
SH
  # bd: app-1 and app-2, open until closed. $STATE/on-close runs on a close.
  cat >"$FAKE/bd" <<'SH'
#!/usr/bin/env bash
printf 'bd %s\n' "$*" >>"$LOG"
case "$1" in
  show)
    [[ -f "$STATE/issue-$2.json" ]] || exit 1
    jq -c --arg s "$(cat "$STATE/status-$2" 2>/dev/null || echo open)" '[. + {status: $s}]' "$STATE/issue-$2.json" ;;
  close)
    [[ ! -x "$STATE/on-close" ]] || "$STATE/on-close"
    echo closed >"$STATE/status-$2" ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$FAKE"/*
}

# A desk: worktree DIR on BRANCH for ISSUE, its live desk terminal T and space
# SP, its handoff record and desk session record.
desk() {
  local dir="$1" branch="$2" issue="$3" t="$4" sp="$5"
  git -C "$MAIN" worktree add -q -b "$branch" "$dir"
  jq -nc --arg i "$issue" --arg b "$branch" --arg t "$t" \
    '{id: $i, title: "Login", metadata: {bercail_task: {branch: $b, owner: {desk: $t}}}}' >"$STATE/issue-$issue.json"
  jq -nc --arg p "$dir" --arg i "$issue" --arg b "$branch" '{path: $p, issue: $i, branch: $b, stage: "bstack"}' \
    >>"$XDG_STATE_HOME/bercail/handoffs.jsonl"
  jq -nc --arg t "$t" --arg p "$dir" --arg i "$issue" --arg sp "$sp" \
    '{address: $t, session: "desk-session-\($t)", cwd: $p, harness: "pi", issue: $i, space: $sp}' \
    >"$XDG_STATE_HOME/bercail/desk-sessions/$t.json"
  [[ -f "$STATE/hc.json" ]] || echo '[]' >"$STATE/hc.json"
  jq --arg t "$t" --arg p "$dir" --arg i "$issue" --arg sp "$sp" '. + [{address: $t, state: "live", reason: null,
      cwd: $p, labels: {"bercail.role": "agent", "bercail.issue": $i, "bercail.space": $sp},
      records: {"desk-session-\($t)": {app: "pi", state: "idle"}}}]' "$STATE/hc.json" >"$STATE/hc.tmp"
  mv "$STATE/hc.tmp" "$STATE/hc.json"
}

# Evidence and a stamped description titled TITLE for DIR's staged change.
described() {
  local dir="$1" title="$2"
  mkdir -p "$dir/.bercail"
  jq -n --arg t "$(git -C "$dir" write-tree)" \
    '{tree: $t, checks: [{kind: "test", command: "bash tests/run.sh", exit_code: 0, evidence: "all passed"}]}' >"$dir/.bercail/validate.json"
  printf -- '---\ntitle: %s\n---\nAdds a line for readers of file.txt.\n\nValidation: bash tests/run.sh passed.\n' \
    "$title" >"$dir/.bercail/description.md"
  (cd "$dir" && "$BERCAIL" describe stamp >/dev/null) || fail "stamp $dir"
}

question() { "$BERCAIL" shep question "$@"; }
# The card's token from land ask's line.
ask() { "$BERCAIL" land ask "${1:-$WT}" | grep -o '^Q[0-9]*@[0-9]*'; }
# The person's pick on the panel.
pick() {
  jq -nc --arg t "$1" --arg c "${2:-Ship it}" '{requestId: "pick-\($t)-\($c)", token: $t, choice: $c, source: "panel picker"}' \
    | question answer
}
# What the worker's terminal runs, as hc run got it.
run_worker() { eval "$(tail -n 1 "$STATE/starts")"; }
card() { question get "$1"; }
trunk() { git --git-dir="$ORIGIN" rev-parse master; }
ref() { git --git-dir="$ORIGIN" rev-parse --verify --quiet "$1" || true; }
# The land events in Shep's inbox.
events() { cat "$INBOX"/land-*.json 2>/dev/null; }

@test "one pick lands it: one commit on the trunk, the job closed, the desk and worktree gone, main synced, one event" {
  local base token out sha ci_ref
  base="$(trunk)"
  echo "7 completed success" >"$STATE/ci"
  echo "9 completed failure" >>"$STATE/ci"
  out="$("$BERCAIL" land ask "$WT")" || fail "ask: $out"
  token="$(grep -o '^Q[0-9]*@[0-9]*' <<<"$out")"
  [[ "$out" == "$token is up on the Decisions panel: Ship it or Not yet. No LGTM needed."* ]] || fail "ask said: $out"
  ci_ref="$(card "$token" | jq -r .land.ciRef)"
  out="$(pick "$token")" || fail "pick: $out"
  jq -e .accepted <<<"$out" >/dev/null || fail "pick: $out"
  grep -q "hc run --bg --name land-q1-1 --cwd / --outlive-parent --no-notify --rm" "$LOG" || fail "no worker start: $(cat "$LOG")"
  [[ "$(cat "$STATE/starts")" == "env BERCAIL_ROLE=shep XDG_STATE_HOME=$XDG_STATE_HOME $ROOT/bin/bercail land run $token "* ]] \
    || fail "the worker's command: $(cat "$STATE/starts")"
  # Until it ends, the card shows how far it got, waits on no one, and takes no other card for the job.
  question panel | jq -e --arg t "$token" '.cards == [.cards[] | select(.token == $t and .status == "landing"
    and .landing == {step: null, detail: null, at: null})]' >/dev/null || fail "panel: $(question panel | jq -c .cards)"
  question pending | jq -e --arg t "$token" '.pending == [] and [.landing[] | "\(.id)@\(.revision)"] == [$t]' >/dev/null \
    || fail "pending: $(question pending)"
  [[ "$(question waiting)" == *$'Landing:\n- app-1: Land: file: add a line · picked; waiting for its worker' ]] \
    || fail "board: $(question waiting)"
  out="$(run_worker 2>&1)" || fail "worker: $out"
  [[ "$out" == "$token: landed" ]] || fail "worker said: $out"
  sha="$(trunk)"
  # One commit, on the trunk's pinned tip, of the pinned tree and text: never a merge.
  [[ "$(git --git-dir="$ORIGIN" rev-list --parents -n 1 "$sha")" == "$sha $base" ]] || fail "not one commit on $base"
  [[ "$(git --git-dir="$ORIGIN" log -1 --format=%s "$sha")" == "file: add a line" ]] || fail "subject"
  [[ "$(git --git-dir="$ORIGIN" rev-parse "$sha^{tree}")" == "$(card "$token" | jq -r .target.stagedTree)" ]] || fail "tree"
  [[ "$(ref "$ci_ref")" == "$sha" ]] || fail "the CI branch $ci_ref holds $(ref "$ci_ref"), not $sha"
  [[ -z "$(ref refs/heads/login)" ]] || fail "the desk's branch was pushed"
  [[ "$(cat "$STATE/status-app-1")" == closed ]] || fail "the job is open"
  grep -q "bd close app-1 --reason Landed on master as $sha from land card $token" "$LOG" || fail "close: $(grep '^bd' "$LOG")"
  [[ ! -e "$WT" ]] || fail "the worktree stays"
  grep -qx 'hc kill t9' "$LOG" || fail "the desk was not ended: $(grep '^hc' "$LOG")"
  [[ "$(git -C "$MAIN" rev-parse HEAD)" == "$sha" ]] || fail "main is not fast-forwarded"
  # The ledger: one card, its result, told once; no guard card or other question after the pick.
  card "$token" | jq -e --arg sha "$sha" '.landing.result | .outcome == "landed" and .commit == $sha
    and .step == "close" and .warnings == [] and .told == true' >/dev/null || fail "result: $(card "$token" | jq -c .landing)"
  [[ "$(question json | jq '.questions | length')" == 1 ]] || fail "another question was asked"
  [[ "$(ls "$INBOX")" == "land-Q1-1.json" ]] || fail "Shep's inbox: $(ls "$INBOX")"
  events | jq -e --arg sha "$sha" --arg t "$token" '.schema == "bercail.land/v2" and .event_id == "land:\($t)"
    and .outcome == "landed" and .commit == $sha and .issue == "app-1" and .trunk == "master" and .repo == "app"' >/dev/null \
    || fail "event: $(events)"
  [[ -s "$XDG_STATE_HOME/bercail/land/Q1-1.log" ]] || fail "no log"
  [[ "$(stat -c %a "$XDG_STATE_HOME/bercail/land/Q1-1.log")" == 600 ]] || fail "the log is not private"
}

@test "land ask refuses what one pick cannot land, says how to fix it, and puts up no card" {
  local out other
  # The main checkout, or the trunk itself.
  out="$("$BERCAIL" land ask "$MAIN" 2>&1)" && fail "asked on the main checkout: $out"
  [[ "$out" == *"is the repo's main checkout: land a desk's own worktree"* ]] || fail "main: $out"
  # A repo one pick cannot land: an untrusted policy, or one that integrates by PR.
  "$BERCAIL" policy untrust "$MAIN" >/dev/null
  out="$("$BERCAIL" land ask "$WT" 2>&1)" && fail "asked on an untrusted policy: $out"
  [[ "$out" == *"one land card cannot land this repo: its policy is not trusted; land it as before, with bercail land $WT"* ]] \
    || fail "untrusted: $out"
  "$BERCAIL" policy trust "$MAIN" >/dev/null
  mkdir -p "$XDG_CONFIG_HOME/bercail"
  printf '[policy."%s"]\nintegrate = "pr"\n' "$MAIN" >"$XDG_CONFIG_HOME/bercail/config.toml"
  out="$("$BERCAIL" land ask "$WT" 2>&1)" && fail "asked on a PR repo: $out"
  [[ "$out" == *"it integrates by pr, not straight to the trunk"* ]] || fail "pr: $out"
  rm "$XDG_CONFIG_HOME/bercail/config.toml"
  # No job to close.
  other="$HOME/Work/app.other"
  git -C "$MAIN" worktree add -q -b other "$other"
  out="$("$BERCAIL" land ask "$other" 2>&1)" && fail "asked with no job: $out"
  [[ "$out" == *"has no beads issue in its handoff record"* ]] || fail "no issue: $out"
  # A merge of anything but the trunk's tip on origin.
  git -C "$MAIN" commit -q --allow-empty -m "not the trunk"
  git -C "$MAIN" rev-parse HEAD >"$(git -C "$WT" rev-parse --absolute-git-dir)/MERGE_HEAD"
  out="$("$BERCAIL" land ask "$WT" 2>&1)" && fail "asked on another merge: $out"
  [[ "$out" == *"is merging something other than master on origin"* ]] || fail "merge: $out"
  rm "$(git -C "$WT" rev-parse --absolute-git-dir)/MERGE_HEAD"
  git -C "$MAIN" reset -q --hard HEAD~1
  # A description that no longer describes the staged tree.
  cp "$WT/file.txt" "$STATE/file.txt"
  printf 'more\n' >>"$WT/file.txt"
  git -C "$WT" add file.txt
  out="$("$BERCAIL" land ask "$WT" 2>&1)" && fail "asked on a stale description: $out"
  [[ "$out" == *"does not check out"*"the desk runs /validate"* ]] || fail "stale: $out"
  cp "$STATE/file.txt" "$WT/file.txt"
  git -C "$WT" add file.txt
  # A trunk that moved past HEAD.
  git -C "$MAIN" commit -q --allow-empty -m moved
  git -C "$MAIN" push -q origin master
  out="$("$BERCAIL" land ask "$WT" 2>&1)" && fail "asked behind the trunk: $out"
  [[ "$out" == *"not master on origin"*"the desk brings its staged change onto master's tip"* ]] || fail "behind: $out"
  [[ "$(question json | jq '.questions | length')" == 0 ]] || fail "a refusal put up a card"
  git -C "$MAIN" reset -q --hard HEAD~1
  git -C "$MAIN" push -q -f origin master
  # One card at a time for the job.
  ask >/dev/null || fail "the first ask"
  out="$("$BERCAIL" land ask "$WT" 2>&1)" && fail "a second card: $out"
  [[ "$out" == *"Q1@1 is pending for the same worktree, branch or job"* ]] || fail "second: $out"
  [[ "$(question json | jq '.questions | length')" == 1 ]] || fail "two cards"
}

@test "a card on the main checkout cannot be made, and a forged one started by hand pushes nothing" {
  local token base out
  base="$(trunk)"
  jq -nc --arg p "$MAIN" '{path: $p, issue: "app-1", branch: "master"}' >>"$XDG_STATE_HOME/bercail/handoffs.jsonl"
  out="$(jq -nc --arg wt "$MAIN" '{requestId: "forged", prompt: "Land: x", origin: {event: "x", session: "s", entry: null},
    worktree: $wt, issue: "app-1"}' | question land-create 2>&1)" && fail "a card on the main checkout: $out"
  [[ "$(question json | jq '.questions | length')" == 0 ]] || fail "it made a card"
  token="$(ask)" || fail "ask"
  pick "$token" >/dev/null
  # The ledger edited to name the main checkout: the worker's first check stops it.
  jq --arg m "$MAIN" '.questions[0].target.worktree = $m' "$SHEP/questions.json" >"$SHEP/q.tmp"
  mv "$SHEP/q.tmp" "$SHEP/questions.json"
  out="$("$BERCAIL" land run "$token" 2>&1)" || fail "worker: $out"
  [[ "$out" == "$token: changed ("*"registered changed"* ]] || fail "worker said: $out"
  [[ "$(trunk)" == "$base" && "$(git --git-dir="$ORIGIN" for-each-ref | wc -l)" == 1 ]] || fail "something was pushed"
  [[ "$(git -C "$MAIN" rev-parse HEAD)" == "$base" ]] || fail "the main checkout got a commit"
}

@test "a fact that moved after the pick stops the chain at changed, and nothing is committed or pushed" {
  local base token out name n=0
  base="$(trunk)"
  echo "7 completed success" >"$STATE/ci"
  for name in tree head branch description policy url desk backend; do
    n=$((n + 1))
    token="$(ask)" || fail "$name: ask"
    pick "$token" | jq -e .accepted >/dev/null || fail "$name: pick"
    case "$name" in
      tree) printf 'more\n' >>"$WT/file.txt"; git -C "$WT" add file.txt ;;
      head) git -C "$WT" commit -q --allow-empty -m "a desk commit" ;;
      branch) git -C "$WT" checkout -q -b elsewhere ;;
      description) sed -i 's/^Adds a line/Adds two lines/' "$WT/.bercail/description.md"; (cd "$WT" && "$BERCAIL" describe stamp >/dev/null) ;;
      policy) mkdir -p "$XDG_CONFIG_HOME/bercail"; printf '[policy."%s"]\ndiff_budget = 1\n' "$MAIN" >"$XDG_CONFIG_HOME/bercail/config.toml" ;;
      url) git -C "$MAIN" remote set-url origin git@github.com:o/fork.git ;;
      desk) jq 'map(if .address == "t9" then .state = "done" else . end)' "$STATE/hc.json" >"$STATE/hc.tmp"; mv "$STATE/hc.tmp" "$STATE/hc.json" ;;
      backend) mkdir -p "$XDG_CONFIG_HOME/bercail"; printf '[git]\n"%s" = "gt"\n' "$MAIN" >"$XDG_CONFIG_HOME/bercail/config.toml" ;;
    esac
    out="$(run_worker 2>&1)" || fail "$name: worker: $out"
    [[ "$out" == "$token: changed ("* ]] || fail "$name: worker said: $out"
    card "$token" | jq -e '.landing.result | .outcome == "changed" and .step == "check" and .commit == null' >/dev/null \
      || fail "$name: result $(card "$token" | jq -c .landing.result)"
    [[ "$(trunk)" == "$base" && "$(git --git-dir="$ORIGIN" for-each-ref | wc -l)" == 1 ]] || fail "$name: something was pushed"
    case "$name" in
      tree) git -C "$WT" checkout -q HEAD -- file.txt; printf 'new\n' >>"$WT/file.txt"; git -C "$WT" add file.txt ;;
      head) git -C "$WT" reset -q --soft HEAD~1 ;;
      branch) git -C "$WT" checkout -q login ;;
      description) sed -i 's/^Adds two lines/Adds a line/' "$WT/.bercail/description.md"; (cd "$WT" && "$BERCAIL" describe stamp >/dev/null) ;;
      policy) rm "$XDG_CONFIG_HOME/bercail/config.toml" ;;
      url) git -C "$MAIN" remote set-url origin git@github.com:o/app.git ;;
      desk) jq 'map(if .address == "t9" then .state = "live" else . end)' "$STATE/hc.json" >"$STATE/hc.tmp"; mv "$STATE/hc.tmp" "$STATE/hc.json" ;;
      backend) rm "$XDG_CONFIG_HOME/bercail/config.toml" ;;
    esac
    [[ "$(git -C "$WT" rev-parse HEAD)" == "$base" ]] || fail "$name: HEAD moved"
  done
  [[ "$(events | jq -s length)" == "$n" ]] || fail "want one event a card: $(ls "$INBOX")"
}

@test "a hook that changes the commit stops it at unknown, and nothing is pushed" {
  local base token out
  base="$(trunk)"
  echo "7 completed success" >"$STATE/ci"
  printf '#!/bin/sh\nprintf "\\nSigned-off-by: a hook\\n" >>"$1"\n' >"$MAIN/.git/hooks/commit-msg"
  chmod +x "$MAIN/.git/hooks/commit-msg"
  token="$(ask)"
  pick "$token" >/dev/null
  out="$(run_worker 2>&1)" || fail "worker: $out"
  [[ "$out" == "$token: unknown (the commit "*"a hook changed it, so nothing was pushed)" ]] || fail "worker said: $out"
  card "$token" | jq -e --arg h "$(git -C "$WT" rev-parse HEAD)" '.landing.result | .commit == $h and .step == "commit"' >/dev/null \
    || fail "result: $(card "$token" | jq -c .landing.result)"
  [[ "$(trunk)" == "$base" && "$(git --git-dir="$ORIGIN" for-each-ref | wc -l)" == 1 ]] || fail "something was pushed"
}

@test "CI that is red, rerun red, missing, on another branch, or cut short never reaches the trunk" {
  local base token out spec ci_ref
  base="$(trunk)"
  for spec in "ci-failed|7 completed failure;9 completed success" "ci-failed|7 completed success - 1;7 completed failure - 2" \
    "ci-timeout|9 completed success" "ci-timeout|7 completed success other" "ci-timeout|7 completed success;9 completed success"; do
    tr ';' '\n' <<<"${spec#*|}" >"$STATE/ci"
    if [[ "$spec" == *";9 completed success" && "$spec" == ci-timeout* ]]; then export BERCAIL_LAND_RUN_LIMIT=2; fi
    token="$(ask)" || fail "$spec: ask"
    ci_ref="$(card "$token" | jq -r .land.ciRef)"
    pick "$token" >/dev/null
    out="$(run_worker 2>&1)" || fail "$spec: worker: $out"
    unset BERCAIL_LAND_RUN_LIMIT
    [[ "$out" == "$token: ${spec%%|*} ("* ]] || fail "$spec: worker said: $out"
    [[ "$(trunk)" == "$base" ]] || fail "$spec: the trunk moved"
    [[ "$(ref "$ci_ref")" == "$(git -C "$WT" rev-parse HEAD)" ]] || fail "$spec: its CI branch is not its commit"
    card "$token" | jq -e '.landing.result.step == "ci"' >/dev/null || fail "$spec: $(card "$token" | jq -c .landing.result)"
    # The desk puts its change back on the trunk for the next card.
    git -C "$WT" reset -q --soft "$base"
  done
  [[ "$(question json | jq -r '[.questions[].landing.result.why] | join("\n")')" == *"may be cut short at 2 runs"* ]] \
    || fail "the cut-short list is not named"
}

@test "a trunk that moves during CI stops it at behind, and the trunk keeps the other commit" {
  local token out moved
  echo "7 completed success" >"$STATE/ci"
  moved="$(git --git-dir="$ORIGIN" commit-tree -p master -m "someone else" "master^{tree}")"
  printf '#!/bin/sh\ngit --git-dir=%q update-ref refs/heads/master %s\n' "$ORIGIN" "$moved" >"$STATE/on-ci"
  chmod +x "$STATE/on-ci"
  token="$(ask)"
  pick "$token" >/dev/null
  out="$(run_worker 2>&1)" || fail "worker: $out"
  [[ "$out" == "$token: behind (master is now ${moved:0:12} on the remote"* ]] || fail "worker said: $out"
  [[ "$(trunk)" == "$moved" ]] || fail "the trunk is not the other commit"
  events | jq -e '.outcome == "behind" and .step == "trunk"' >/dev/null || fail "event: $(events)"
}

@test "two chains on one trunk commit: one lands and the other stops at behind" {
  local a b out pids=()
  echo "7 completed success" >"$STATE/ci"
  desk "$HOME/Work/app.search" search app-2 t8 sp2
  printf 'search\n' >"$HOME/Work/app.search/search.txt"
  git -C "$HOME/Work/app.search" add search.txt
  described "$HOME/Work/app.search" "search: add it"
  a="$(ask)" && b="$(ask "$HOME/Work/app.search")" || fail "ask"
  pick "$a" >/dev/null && pick "$b" >/dev/null
  # A barrier: neither chain reads CI until both have pushed their CI branch.
  printf '#!/bin/sh\n: >"%s/at-ci.$PPID"\nfor i in $(seq 400); do [ "$(ls "%s" | grep -c "^at-ci")" -ge 2 ] && exit 0; sleep 0.05; done\n: >"%s/barrier-timeout"\n' \
    "$STATE" "$STATE" "$STATE" >"$STATE/on-ci"
  chmod +x "$STATE/on-ci"
  while read -r line; do
    eval "$line" >"$STATE/out.${#pids[@]}" 2>&1 &
    pids+=($!)
  done <"$STATE/starts"
  wait "${pids[@]}"
  [[ ! -e "$STATE/barrier-timeout" ]] || fail "the two chains never met at CI"
  out="$(cat "$STATE"/out.*)"
  [[ "$(grep -c ': landed$' <<<"$out")" == 1 && "$(grep -c ': behind (master is now' <<<"$out")" == 1 ]] || fail "workers said: $out"
  [[ "$(git --git-dir="$ORIGIN" rev-list --count master)" == 3 ]] || fail "the trunk did not get exactly one of them"
}

@test "a guard that cannot pin the trunk push refuses it, and the trunk is unchanged" {
  local base token out
  base="$(trunk)"
  echo "7 completed success" >"$STATE/ci"
  # During CI, a url rule that rewrites origin's push URL to itself: the card's facts hold,
  # but the guard's own pinning refuses a rewritten URL.
  printf '#!/bin/sh\ngit -C %q config url.git@github.com:o/app.git.pushInsteadOf git@github.com:o/app.git\n' "$MAIN" >"$STATE/on-ci"
  chmod +x "$STATE/on-ci"
  token="$(ask)"
  pick "$token" >/dev/null
  out="$(run_worker 2>&1)" || fail "worker: $out"
  [[ "$out" == "$token: refused (the trunk push: the guard pins it to other facts: "*"a url.* rule rewrites origin's push URL)" ]] \
    || fail "worker said: $out"
  [[ "$(trunk)" == "$base" ]] || fail "the trunk moved"
}

@test "two workers on one pick run the chain once, and a declined card's worker runs nothing" {
  local token out pids=()
  echo "7 completed success" >"$STATE/ci"
  token="$(ask)"
  pick "$token" >/dev/null
  for i in 1 2; do
    run_worker >"$STATE/out.$i" 2>&1 &
    pids+=($!)
  done
  wait "${pids[@]}"
  out="$(cat "$STATE"/out.*)"
  [[ "$(grep -c "^$token: landed$" <<<"$out")" == 1 && "$(grep -c '^not run: its chain was already claimed at' <<<"$out")" == 1 ]] \
    || fail "workers said: $out"
  [[ "$(git --git-dir="$ORIGIN" rev-list --count master)" == 3 ]] || fail "not one commit"
  # Not yet: Shep hears the decision, and a worker started by hand runs nothing.
  desk "$HOME/Work/app.search" search app-2 t8 sp2
  printf 'search\n' >"$HOME/Work/app.search/search.txt"
  git -C "$HOME/Work/app.search" add search.txt
  described "$HOME/Work/app.search" "search: add it"
  token="$(ask "$HOME/Work/app.search")"
  pick "$token" "Not yet" | jq -e .accepted >/dev/null || fail "decline"
  [[ -f "$INBOX/decision-Q2-1.json" ]] || fail "no decision event: $(ls "$INBOX")"
  [[ "$(wc -l <"$STATE/starts")" == 1 ]] || fail "a decline started a worker"
  out="$("$BERCAIL" land run "$token" 2>&1)" || fail "worker: $out"
  [[ "$out" == "not run: not the person's Ship it on a land card's panel" ]] || fail "worker said: $out"
  [[ "$(git --git-dir="$ORIGIN" rev-list --count master)" == 3 && -z "$(ref "$(card "$token" | jq -r .land.ciRef)")" ]] \
    || fail "the declined change was pushed"
}

@test "a cleanup that does not hold lands with a warning, and the worktree and the job stay" {
  local token out
  echo "7 completed success" >"$STATE/ci"
  # A locked worktree, which bercail cleanup refuses.
  git -C "$MAIN" worktree lock "$WT"
  token="$(ask)"
  pick "$token" >/dev/null
  out="$(run_worker 2>&1)" || fail "worker: $out"
  [[ "$out" == "$token: landed" ]] || fail "worker said: $out"
  [[ -d "$WT" ]] || fail "the worktree went"
  card "$token" | jq -e --arg wt "$WT" '.landing.result.warnings == ["bercail cleanup of \($wt) did not finish (its log says why), so the desk t9 or its worktree may stay",
    "app-1 stays open until that is done"]' >/dev/null || fail "warnings: $(card "$token" | jq -c .landing.result.warnings)"
  [[ ! -e "$STATE/status-app-1" ]] && ! grep -q '^bd close' "$LOG" || fail "the job was closed"
  [[ "$(git -C "$MAIN" rev-parse HEAD)" == "$(trunk)" ]] || fail "main was not synced"
}

@test "a desk's merge of a moved trunk lands as one commit with the merge's exact tree, never a merge commit" {
  local token out moved tree sha c1 gd desc base_orig
  echo "7 completed success" >"$STATE/ci"
  base_orig="$(trunk)"
  # The desk's reviewed commit, then the trunk moves on (making file.txt high-stakes) and the desk merges it in.
  git -C "$WT" commit -q -m "file: add a line"
  c1="$(git -C "$WT" rev-parse HEAD)"
  printf 'high_stakes = """\nfile.txt\n"""\n' >>"$MAIN/.bercail/policy.toml"
  printf 'other\n' >"$MAIN/other.txt"
  git -C "$MAIN" add other.txt
  git -C "$MAIN" add -f .bercail/policy.toml
  git -C "$MAIN" commit -qm "someone else"
  git -C "$MAIN" push -q origin master
  "$BERCAIL" policy trust "$MAIN" >/dev/null
  moved="$(trunk)"
  git -C "$WT" fetch -q origin
  git -C "$WT" merge -q --no-commit --no-ff origin/master
  tree="$(git -C "$WT" write-tree)"
  gd="$(git -C "$WT" rev-parse --absolute-git-dir)"
  # A refusal changes nothing: a stale description, then a card the ledger refuses (its desk is gone).
  printf 'more\n' >"$WT/more.txt"
  git -C "$WT" add more.txt
  out="$("$BERCAIL" land ask "$WT" 2>&1)" && fail "asked on a stale description: $out"
  git -C "$WT" rm -q --cached more.txt
  rm "$WT/more.txt"
  [[ -f "$gd/MERGE_HEAD" && "$(git -C "$WT" rev-parse HEAD)" == "$c1" ]] || fail "a stale description moved the merge"
  described "$WT" "file: add a line"
  desc="$(cat "$WT/.bercail/description.md")"
  # A merge that holds an autostash, which ending it would move to the stash list.
  : >"$gd/MERGE_AUTOSTASH"
  out="$("$BERCAIL" land ask "$WT" 2>&1)" && fail "asked on an autostash: $out"
  [[ "$out" == *"holds an autostash"* && -f "$gd/MERGE_HEAD" && "$(git -C "$WT" rev-parse HEAD)" == "$c1" ]] || fail "autostash: $out"
  rm "$gd/MERGE_AUTOSTASH"
  printf '%s\n' "$base_orig" >"$gd/ORIG_HEAD"
  jq 'map(if .address == "t9" then .state = "done" else . end)' "$STATE/hc.json" >"$STATE/hc.tmp" && mv "$STATE/hc.tmp" "$STATE/hc.json"
  out="$("$BERCAIL" land ask "$WT" 2>&1)" && fail "asked with its desk gone: $out"
  [[ "$out" == *"the desk's merge is as it was"* ]] || fail "refusal: $out"
  [[ "$(git -C "$WT" rev-parse MERGE_HEAD)" == "$moved" && "$(git -C "$WT" rev-parse HEAD)" == "$c1" ]] || fail "the merge was not put back"
  [[ "$(cat "$gd/ORIG_HEAD")" == "$base_orig" ]] || fail "ORIG_HEAD was rewritten: $(cat "$gd/ORIG_HEAD")"
  [[ "$(git -C "$WT" write-tree)" == "$tree" && "$(cat "$WT/.bercail/description.md")" == "$desc" ]] || fail "the tree or description changed"
  jq 'map(if .address == "t9" then .state = "live" else . end)' "$STATE/hc.json" >"$STATE/hc.tmp" && mv "$STATE/hc.tmp" "$STATE/hc.json"
  out="$("$BERCAIL" land ask "$WT")" || fail "ask: $out"
  [[ "$out" == *"LGTM, ship it or Not yet. The desk's merge of master lands as one commit with its exact tree. It needs the person's LGTM: it touches file.txt."* ]] \
    || fail "ask said: $out"
  token="$(grep -o '^Q[0-9]*@[0-9]*' <<<"$out")"
  card "$token" | jq -e --arg m "$moved" --arg t "$tree" '.target.head == $m and .target.stagedTree == $t' >/dev/null \
    || fail "card: $(card "$token" | jq -c .target)"
  pick "$token" "LGTM, ship it" >/dev/null
  out="$(run_worker 2>&1)" || fail "worker: $out"
  [[ "$out" == "$token: landed" ]] || fail "worker said: $out"
  sha="$(trunk)"
  [[ "$(git --git-dir="$ORIGIN" rev-list --parents -n 1 "$sha")" == "$sha $moved" ]] || fail "not one commit on $moved"
  [[ "$(git --git-dir="$ORIGIN" rev-parse "$sha^{tree}")" == "$tree" ]] || fail "not the merge's tree"
  [[ "$(git --git-dir="$ORIGIN" log -1 --format=%B "$sha")" == *"reviewed by Simon"* ]] || fail "no reviewer: $(git --git-dir="$ORIGIN" log -1 --format=%B "$sha")"
}

@test "the sweep starts a worker for a pick that has none, and records unknown only for a claimed worker that is gone" {
  local token
  token="$(ask)"
  # hc run fails at the pick: the reservation stays, and the sweep starts it again.
  : >"$STATE/run-fails"
  pick "$token" | jq -e .accepted >/dev/null || fail "pick"
  [[ ! -f "$STATE/starts" ]] || fail "a failed hc run started a worker"
  rm "$STATE/run-fails"
  question expire | jq -e --arg t "$token" '. == ["\($t) started"]' >/dev/null || fail "the sweep did not start it"
  card "$token" | jq -e '.landing.starts | length == 2' >/dev/null || fail "starts: $(card "$token" | jq -c .landing)"
  # A worker that died before its claim: its terminal is gone, so another starts.
  question expire | jq -e --arg t "$token" '. == ["\($t) started"]' >/dev/null || fail "no restart"
  # A crash before the first reservation.
  jq 'del(.questions[0].landing)' "$SHEP/questions.json" >"$SHEP/q.tmp" && mv "$SHEP/q.tmp" "$SHEP/questions.json"
  question expire | jq -e --arg t "$token" '. == ["\($t) started"]' >/dev/null || fail "no start after a crash"
  # A worker hc reports live, or hc that cannot answer: the sweep waits.
  jq '. + [{address: "land-q1-1", state: "live", cwd: "/", labels: {}}]' "$STATE/hc.json" >"$STATE/hc.tmp" && mv "$STATE/hc.tmp" "$STATE/hc.json"
  question expire | jq -e '. == []' >/dev/null || fail "it started a second worker beside a live one"
  question land-claim "$token" | jq -e .accepted >/dev/null || fail "claim"
  : >"$STATE/hc-down"
  question expire | jq -e '. == []' >/dev/null || fail "it acted while hc could not answer"
  rm "$STATE/hc-down"
  question expire | jq -e '. == []' >/dev/null || fail "it acted on a live worker"
  # The claimed worker is gone with no result: unknown, told once.
  jq 'map(select(.address != "land-q1-1"))' "$STATE/hc.json" >"$STATE/hc.tmp" && mv "$STATE/hc.tmp" "$STATE/hc.json"
  question expire | jq -e --arg t "$token" '. == ["\($t) unknown", "\($t) told"]' >/dev/null || fail "no unknown"
  events | jq -e '.outcome == "unknown" and .step == null and (.why | startswith("its worker land-q1-1 ended"))' >/dev/null \
    || fail "event: $(events)"
  question expire | jq -e '. == []' >/dev/null || fail "a second sweep acted again"
}

@test "a result whose event was lost, or written but not marked, reaches Shep once, and never after its receipt is pruned" {
  local token first
  token="$(ask)"
  pick "$token" >/dev/null
  question land-claim "$token" >/dev/null
  question land-step "$token" check >/dev/null
  jq -nc --arg t "$token" '{token: $t, outcome: "changed", commit: null, why: "stagedTree changed", warnings: [], log: "/l"}' \
    | question land-result >/dev/null
  # The worker died between its result and its event.
  question expire | jq -e --arg t "$token" '. == ["\($t) told"]' >/dev/null || fail "not told"
  first="$(cat "$INBOX/land-Q1-1.json")"
  question expire | jq -e '. == []' >/dev/null || fail "told twice"
  # Written into the inbox, then the worker died before told: the file is kept as it is.
  jq '.questions[0].landing.result |= del(.told)' "$SHEP/questions.json" >"$SHEP/q.tmp" && mv "$SHEP/q.tmp" "$SHEP/questions.json"
  question expire | jq -e --arg t "$token" '. == ["\($t) told"]' >/dev/null || fail "not marked"
  [[ "$(cat "$INBOX/land-Q1-1.json")" == "$first" ]] || fail "the event was written again"
  # Shep read it (delivered/), then the receipt was pruned: nothing is sent again.
  mkdir -p "$SHEP/delivered"
  mv "$INBOX/land-Q1-1.json" "$SHEP/delivered/"
  rm "$SHEP/delivered/land-Q1-1.json"
  question expire | jq -e '. == []' >/dev/null || fail "sent after its receipt was pruned"
  [[ ! -e "$INBOX/land-Q1-1.json" ]] || fail "a second event"
}

# A staged change to the repo's policy file in the desk's worktree, described; prints its sha256.
policy_change() {
  printf 'rules = "%s"\n' "$1" >>"$WT/.bercail/policy.toml"
  git -C "$WT" add -f .bercail/policy.toml
  described "$WT" "policy: $1"
  git -C "$WT" cat-file blob :.bercail/policy.toml | sha256sum | cut -d' ' -f1
}
trusted_hash() { jq -r --arg m "$MAIN" '.[$m].sha256' "$XDG_STATE_HOME/bercail/policy-trust.json"; }

@test "approving a change to the policy file trusts exactly its new file once its commit is on the trunk" {
  local hash token out brief
  echo "7 completed success" >"$STATE/ci"
  hash="$(policy_change "Land with one card.")"
  out="$("$BERCAIL" land ask "$WT")" || fail "ask: $out"
  [[ "$out" == *"LGTM, ship it or Not yet."*"It needs the person's LGTM: it touches .bercail/policy.toml."* ]] || fail "ask said: $out"
  token="$(grep -o '^Q[0-9]*@[0-9]*' <<<"$out")"
  # The card shows the new file's sha256 and the policy diff.
  brief="$(card "$token" | jq -r .brief)"
  [[ "$brief" == *"once its commit is on master, it trusts that file, sha256 $hash, as bercail policy trust would."* ]] \
    || fail "brief: $brief"
  [[ "$brief" == *$'The policy diff:\n'*'+rules = "Land with one card."'* ]] || fail "no diff in the brief: $brief"
  card "$token" | jq -e --arg h "$hash" '.land.policyTrust == $h' >/dev/null || fail "not pinned"
  [[ "$(trusted_hash)" != "$hash" ]] || fail "trusted before the pick"
  pick "$token" "LGTM, ship it" >/dev/null
  out="$(run_worker 2>&1)" || fail "worker: $out"
  [[ "$out" == "$token: landed" ]] || fail "worker said: $out"
  [[ "$(trusted_hash)" == "$hash" ]] || fail "trusts $(trusted_hash), not $hash"
  "$BERCAIL" policy show --json "$MAIN" | jq -e '.trusted and .policy.rules == "Land with one card."' >/dev/null \
    || fail "the main checkout's policy: $("$BERCAIL" policy show --json "$MAIN" | jq -c '{trusted, rules: .policy.rules}')"
  card "$token" | jq -e --arg h "$hash" '.landing.result | .trusted == $h and .warnings == []' >/dev/null \
    || fail "result: $(card "$token" | jq -c .landing.result)"
  events | jq -e --arg h "$hash" '.trusted == $h' >/dev/null || fail "event: $(events)"
  [[ "$(cat "$STATE/status-app-1")" == closed ]] || fail "the job is open"
}

@test "a policy changed after the pick, or a landed file of another hash, is not trusted, and the result says why" {
  local hash token out old
  echo "7 completed success" >"$STATE/ci"
  old="$(trusted_hash)"
  hash="$(policy_change "Land with one card.")"
  token="$(ask)"
  pick "$token" "LGTM, ship it" >/dev/null
  printf 'rules = "Something else."\n' >>"$WT/.bercail/policy.toml"
  git -C "$WT" add -f .bercail/policy.toml
  out="$(run_worker 2>&1)" || fail "worker: $out"
  [[ "$out" == "$token: changed ("*"stagedTree changed"* ]] || fail "worker said: $out"
  [[ "$(trusted_hash)" == "$old" ]] || fail "a policy changed after the pick was trusted"
  # A card whose pinned hash is not the file that lands (the ledger edited to another).
  git -C "$WT" checkout -q HEAD -- .bercail/policy.toml
  hash="$(policy_change "Land with one card.")"
  token="$(ask)"
  pick "$token" "LGTM, ship it" >/dev/null
  jq --arg t "${token%@*}" '(.questions[] | select(.id == $t) | .land.policyTrust) = ("f" * 64)' "$SHEP/questions.json" >"$SHEP/q.tmp"
  mv "$SHEP/q.tmp" "$SHEP/questions.json"
  out="$(run_worker 2>&1)" || fail "worker: $out"
  [[ "$out" == "$token: landed" ]] || fail "worker said: $out"
  [[ "$(trusted_hash)" == "$old" ]] || fail "another hash was trusted"
  card "$token" | jq -e --arg h "${hash:0:12}" '.landing.result | (has("trusted") | not) and .warnings == [
    ".bercail/policy.toml on master at \(.commit[0:12]) has sha256 \($h), not the card'"'"'s ffffffffffff, so it is not trusted",
    "app-1 stays open until that is done"]' >/dev/null || fail "result: $(card "$token" | jq -c .landing.result)"
  [[ ! -e "$STATE/status-app-1" ]] || fail "the job was closed"
}

@test "a trust that cannot be written lands with a warning, and the job stays open" {
  local hash token out
  [[ "$(id -u)" != 0 ]] || skip "root writes into a folder of mode 500"
  echo "7 completed success" >"$STATE/ci"
  hash="$(policy_change "Land with one card.")"
  token="$(ask)"
  pick "$token" "LGTM, ship it" >/dev/null
  # The trust registry's folder takes no new file; the chain's own folders are already there.
  mkdir -p "$XDG_STATE_HOME/bercail/land"
  chmod 500 "$XDG_STATE_HOME/bercail"
  out="$(run_worker 2>&1)"
  chmod 700 "$XDG_STATE_HOME/bercail"
  [[ "$out" == "$token: landed" ]] || fail "worker said: $out"
  [[ "$(git --git-dir="$ORIGIN" rev-parse "master^{tree}")" == "$(card "$token" | jq -r .target.stagedTree)" ]] || fail "not landed"
  [[ "$(trusted_hash)" != "$hash" ]] || fail "trusted"
  card "$token" | jq -e --arg h "${hash:0:12}" '.landing.result | (has("trusted") | not) and .warnings == [
    "the trust of .bercail/policy.toml, sha256 \($h), could not be written (the log says why), so it is not trusted",
    "app-1 stays open until that is done"]' >/dev/null || fail "result: $(card "$token" | jq -c .landing.result)"
  [[ ! -e "$STATE/status-app-1" ]] || fail "the job was closed"
}
