#!/usr/bin/env bats
# One pick lands a job (docs/plans/one-pick-landing.md, step 6): bercail land ask
# puts up a land card, and on the person's Ship it the worker, bercail land run,
# commits, pushes a CI branch, waits for CI, pushes the trunk, closes the issue,
# cleans up the desk and fast-forwards the main checkout. This file covers the
# chains that land: one pick, two chains on one trunk commit, two workers on
# one pick, a cleanup that does not hold, a desk's merge of a moved trunk, the
# sweep, a lost event, and the trust of a landed policy file, from a land card or
# a push card. Where the chain stops or refuses is in tests/land_card_stops.bats;
# the fixture is tests/land_card.bash.

setup() {
  load test_helper
  isolate
  load land_card
  land_setup
}

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
  jq '. + [{address: "land-q1-1", state: "live", pid: (length + 101), cwd: "/", labels: {}}]' "$STATE/hc.json" >"$STATE/hc.tmp" && mv "$STATE/hc.tmp" "$STATE/hc.json"
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

@test "a push card's pick trusts the policy file its commit pushes to origin's trunk, once, and only once it is there" {
  local hash token other out sha spec base rc
  [[ "$(id -u)" != 0 ]] || skip "root writes into a folder of mode 500"
  base="$(trunk)"
  hash="$(policy_change "Push with a card.")"
  git -C "$WT" commit -qm "policy: push with a card"
  sha="$(git -C "$WT" rev-parse HEAD)"
  spec="$sha^{commit}:refs/heads/master"
  git init -q --bare "$GH/fork.git"
  git -C "$MAIN" remote add fork "$GH/fork.git"
  push_card() {
    jq -nc --arg wt "$WT" --arg remote "$1" --arg ref "$2" '{requestId: "push-\($remote)-\($ref)", kind: "action",
        prompt: "Push it?", options: ["Push it", "Not yet"], origin: {event: "land:1", session: "shep", entry: null},
        repo: $wt, issue: "app-1", topic: "app-1-push-\($remote)-\($ref)", desk: "t9", base: "origin/master",
        action: "push", push: {approves: "Push it", remote: $remote, refs: [$ref]}}' \
      | question create | jq -r '"\(.id)@\(.revision)"'
  }
  token="$(push_card origin refs/heads/master)"
  # The card pins the reviewed tree's new policy file; a push to another branch, or to a fork's master, pins none.
  card "$token" | jq -e --arg h "$hash" '.push.policyTrust == $h' >/dev/null || fail "not pinned: $(card "$token" | jq -c .push)"
  for other in "$(push_card origin refs/heads/ci-login)" "$(push_card fork refs/heads/master)"; do
    card "$other" | jq -e '.push | has("policyTrust") | not' >/dev/null || fail "pinned: $(card "$other" | jq -c .push)"
    [[ "$(question policy-trust "$other")" == '{"trusted":null}' ]] || fail "a card with no pin: $(question policy-trust "$other")"
  done
  pick "$token" "Push it" >/dev/null
  # Approved, but not pushed yet: the trunk is not the commit, so nothing is trusted or spent.
  out="$(question push-approval "$WT" origin "$spec")"
  jq -e --arg t "$token" '.approved == $t' >/dev/null <<<"$out" || fail "push-approval: $out"
  out="$(question policy-trust "$token")" || fail "policy-trust: $out"
  [[ "$out" == "{\"trusted\":null,\"reason\":\"$token refs/heads/master on git@github.com:o/app.git is ${base:0:12}, not ${sha:0:12}\"}" ]] \
    || fail "before the push: $out"
  [[ "$(trusted_hash)" != "$hash" ]] || fail "trusted before the push"
  git -C "$WT" push -q origin "$spec"
  # A trust that cannot be written spends nothing: the same command trusts it once it can.
  chmod 500 "$XDG_STATE_HOME/bercail"
  rc=0
  out="$(question policy-trust "$token" 2>&1)" || rc=$?
  chmod 700 "$XDG_STATE_HOME/bercail"
  ((rc != 0)) || fail "a write that failed passed: $out"
  card "$token" | jq -e 'has("policyTrusted") | not' >/dev/null || fail "spent on a failed write: $(card "$token" | jq -c .policyTrusted)"
  # A copy of the ledger elsewhere trusts only in the registry beside it, never this one.
  mkdir -p "$BATS_TEST_TMPDIR/elsewhere/shep"
  cp "$SHEP/questions.json" "$BATS_TEST_TMPDIR/elsewhere/shep/"
  BERCAIL_SHEP_STATE="$BATS_TEST_TMPDIR/elsewhere/shep" node "$ROOT/shep/pi/question-cli.ts" policy-trust "$token" >/dev/null \
    || fail "the copy did not run"
  [[ "$(trusted_hash)" != "$hash" ]] || fail "a ledger elsewhere trusted it here"
  [[ "$(stat -c %a "$BATS_TEST_TMPDIR/elsewhere/policy-trust.json")" == 600 ]] || fail "the registry is not private"
  out="$(question policy-trust "$token")" || fail "policy-trust: $out"
  [[ "$out" == "{\"trusted\":\"$hash\",\"repo\":\"$MAIN\"}" ]] || fail "after the push: $out"
  [[ "$(trusted_hash)" == "$hash" ]] || fail "trusts $(trusted_hash), not $hash"
  card "$token" | jq -e --arg h "$hash" '.policyTrusted.sha256 == $h' >/dev/null || fail "not recorded: $(card "$token" | jq -c .)"
  git -C "$MAIN" merge -q --ff-only "$sha"
  "$BERCAIL" policy show --json "$MAIN" | jq -e '.trusted and .policy.rules == "Push with a card."' >/dev/null \
    || fail "the main checkout's policy: $("$BERCAIL" policy show --json "$MAIN" | jq -c '{trusted, rules: .policy.rules}')"
  # One answer trusts once: after an untrust, the same card trusts nothing again.
  "$BERCAIL" policy untrust "$MAIN" >/dev/null
  out="$(question policy-trust "$token")" || fail "policy-trust: $out"
  [[ "$out" == "{\"trusted\":null,\"reason\":\"$token already trusted it, at "*'"}' ]] || fail "a second trust: $out"
  "$BERCAIL" policy show --json "$MAIN" | jq -e '.trusted | not' >/dev/null || fail "trusted again"
}
