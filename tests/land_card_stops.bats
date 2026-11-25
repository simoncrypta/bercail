#!/usr/bin/env bats
# Where one land card's chain stops or refuses (docs/plans/one-pick-landing.md,
# step 6): land ask refusing what one pick cannot land, a card on the main
# checkout, a fact that moved after the pick, a hook that changes the commit,
# CI that does not pass, a trunk that moves during CI, and a guard that cannot
# pin the trunk push. In each, nothing that should not land reaches the trunk.
# The chains that land are in tests/land_card.bats; the fixture is
# tests/land_card.bash.

setup() {
  load test_helper
  isolate
  load land_card
  land_setup
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

# A land card picked, then FACT moved before its worker ran: the chain stops
# at changed in its first check, commits nothing, pushes nothing, and tells
# Shep once.
moved_fact() {
  local fact="$1" base token out head
  base="$(trunk)"
  echo "7 completed success" >"$STATE/ci"
  token="$(ask)" || fail "ask"
  pick "$token" | jq -e .accepted >/dev/null || fail "pick"
  case "$fact" in
    tree) printf 'more\n' >>"$WT/file.txt"; git -C "$WT" add file.txt ;;
    head) git -C "$WT" commit -q --allow-empty -m "a desk commit" ;;
    branch) git -C "$WT" checkout -q -b elsewhere ;;
    description) sed -i 's/^Adds a line/Adds two lines/' "$WT/.bercail/description.md"; (cd "$WT" && "$BERCAIL" describe stamp >/dev/null) ;;
    policy) mkdir -p "$XDG_CONFIG_HOME/bercail"; printf '[policy."%s"]\ndiff_budget = 1\n' "$MAIN" >"$XDG_CONFIG_HOME/bercail/config.toml" ;;
    url) git -C "$MAIN" remote set-url origin git@github.com:o/fork.git ;;
    desk) jq 'map(if .address == "t9" then .state = "done" else . end)' "$STATE/hc.json" >"$STATE/hc.tmp"; mv "$STATE/hc.tmp" "$STATE/hc.json" ;;
    backend) mkdir -p "$XDG_CONFIG_HOME/bercail"; printf '[git]\n"%s" = "gt"\n' "$MAIN" >"$XDG_CONFIG_HOME/bercail/config.toml" ;;
  esac
  head="$(git -C "$WT" rev-parse HEAD)"
  out="$(run_worker 2>&1)" || fail "worker: $out"
  [[ "$out" == "$token: changed ("* ]] || fail "worker said: $out"
  card "$token" | jq -e '.landing.result | .outcome == "changed" and .step == "check" and .commit == null' >/dev/null \
    || fail "result $(card "$token" | jq -c .landing.result)"
  [[ "$(trunk)" == "$base" && "$(git --git-dir="$ORIGIN" for-each-ref | wc -l)" == 1 ]] || fail "something was pushed"
  [[ "$(git -C "$WT" rev-parse HEAD)" == "$head" ]] || fail "HEAD moved"
  # The job's branch too, when the desk switched off it.
  [[ "$fact" != branch || "$(git -C "$WT" rev-parse login)" == "$base" ]] || fail "login moved"
  [[ "$(events | jq -s length)" == 1 ]] || fail "want one event: $(ls "$INBOX")"
}

@test "a staged tree that moved after the pick stops the chain at changed, and nothing is committed or pushed" {
  moved_fact tree
}

@test "a desk commit after the pick stops the chain at changed, and nothing is committed or pushed" {
  moved_fact head
}

@test "a branch switched after the pick stops the chain at changed, and nothing is committed or pushed" {
  moved_fact branch
}

@test "a description restamped after the pick stops the chain at changed, and nothing is committed or pushed" {
  moved_fact description
}

@test "a policy setting changed after the pick stops the chain at changed, and nothing is committed or pushed" {
  moved_fact policy
}

@test "an origin URL changed after the pick stops the chain at changed, and nothing is committed or pushed" {
  moved_fact url
}

@test "a desk that ended after the pick stops the chain at changed, and nothing is committed or pushed" {
  moved_fact desk
}

@test "a git backend changed after the pick stops the chain at changed, and nothing is committed or pushed" {
  moved_fact backend
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

# CI's push runs are RUNS, one a line as tests/land_card.bash's gh reads them:
# the chain stops at OUTCOME in its ci step, the trunk does not move, and the
# card's CI branch holds its commit.
ci_stops() {
  local outcome="$1" runs="$2" base token out ci_ref
  base="$(trunk)"
  printf '%s\n' "$runs" >"$STATE/ci"
  token="$(ask)" || fail "ask"
  ci_ref="$(card "$token" | jq -r .land.ciRef)"
  pick "$token" >/dev/null
  out="$(run_worker 2>&1)" || fail "worker: $out"
  [[ "$out" == "$token: $outcome ("* ]] || fail "worker said: $out"
  [[ "$(trunk)" == "$base" ]] || fail "the trunk moved"
  [[ "$(ref "$ci_ref")" == "$(git -C "$WT" rev-parse HEAD)" ]] || fail "its CI branch is not its commit"
  card "$token" | jq -e '.landing.result.step == "ci"' >/dev/null || fail "$(card "$token" | jq -c .landing.result)"
}

@test "required CI that is red never reaches the trunk" {
  ci_stops ci-failed $'7 completed failure\n9 completed success'
}

@test "required CI that is rerun red never reaches the trunk" {
  ci_stops ci-failed $'7 completed success - 1\n7 completed failure - 2'
}

@test "required CI that is missing never reaches the trunk" {
  ci_stops ci-timeout '9 completed success'
}

@test "required CI that passed on another branch never reaches the trunk" {
  ci_stops ci-timeout '7 completed success other'
}

@test "CI runs cut short at the run limit never reach the trunk, and the result says they may be cut short" {
  export BERCAIL_LAND_RUN_LIMIT=2
  ci_stops ci-timeout $'7 completed success\n9 completed success'
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
