#!/usr/bin/env bash
# shellcheck shell=bash
# Landing a desk's change, for Shep only: check the description, commit the
# staged tree with its text, and start a background wait for the branch's CI.
# The wait ends with one event in Shep's inbox: ready, failed, moved or timeout. land
# never pushes: Shep pushes the branch, and on a ready event lands it the way
# the repo's policy says, with plain git, gh or entire under its guard.
#
#   bercail land <worktree> [--reviewed-by NAME]
#   bercail land --wait SHA <worktree>     what the background terminal runs
#
# In a repo that commits straight to its trunk with a trusted push = "main" and
# a required_ci gate (docs/plans/one-pick-landing.md), one land card does all of
# it instead: Shep asks it, and the person's pick on the panel starts a
# model-free worker that commits, pushes, waits for CI, pushes the trunk, closes
# the job, cleans up the desk and syncs the main checkout.
#
#   bercail land ask <worktree>            put the card up
#   bercail land run Qn@rev                the worker; only the person's pick starts it

# shellcheck source=lib/describe.sh
source "$(dirname "${BASH_SOURCE[0]}")/describe.sh"

LAND_USAGE="usage: bercail land <worktree> [--reviewed-by NAME] | bercail land ask <worktree>"

_land_err() {
  printf 'bercail land: %s\n' "$*" >&2
}

# Commit the described tree, unless HEAD already is it (a land rerun after its
# commit), then start the wait on that commit.
land_run() {
  local dir="$1" reviewer="$2" root branch trunk msg sha described name
  local hc="${HC_BIN:-hc}"
  root="$(_desc_root "$dir")" || return 1
  branch="$(git -C "$root" symbolic-ref --quiet --short HEAD 2>/dev/null)" \
    || { _land_err "$root is on no branch: land a desk's branch, so its CI runs before the trunk"; return 1; }
  trunk="$(git_backend_trunk "$root")"
  [[ "$branch" != "$trunk" ]] \
    || { _land_err "$root is on $trunk itself: land a desk's branch, so its CI runs before $trunk"; return 1; }
  msg="$(_desc_print commit "$root" "$reviewer")" || return 1
  if git -C "$root" diff --cached --quiet; then
    described="$(_desc_meta "$root/$DESC_FILE" tree)"
    [[ "$(git -C "$root" rev-parse 'HEAD^{tree}')" == "$described" ]] \
      || { _land_err "nothing is staged in $root: the desk stages its change and runs /validate"; return 1; }
    printf 'HEAD is already the described tree; no new commit\n'
  else
    git -C "$root" commit -q -F - <<<"$msg" \
      || { _land_err "git commit failed in $root; its error is above, and nothing was committed"; return 1; }
  fi
  sha="$(git -C "$root" rev-parse HEAD)"
  name="land-${sha:0:12}"
  # hc run starts the wait from the Herdr server, so only this env prefix reaches it.
  "$hc" run --bg --name "$name" --cwd "$root" --outlive-parent --no-notify --rm \
    --label bercail.land=wait --label "bercail.land_head=$sha" -- \
    env BERCAIL_ROLE=shep "XDG_STATE_HOME=${XDG_STATE_HOME:-$HOME/.local/state}" \
    "${BERCAIL_SELF:-bercail}" land --wait "$sha" "$root" </dev/null >/dev/null \
    || { _land_err "committed ${sha:0:12} on $branch, but hc could not start the CI wait (its error is above); rerun bercail land $root"; return 1; }
  printf 'committed %s on %s: %s\n' "${sha:0:12}" "$branch" "$(head -n 1 <<<"$msg")"
  printf 'waiting for CI on it in hc terminal %s; the result comes to Shep as a land event\n' "$name"
  printf 'next: git -C %q push origin %q, so its CI runs\n' "$root" "$branch"
}

# The push runs of BRANCH at SHA as {status, runs, note}: ready once they all
# finished and at least one passed (skipped and neutral alone are not a pass),
# failed once any finished otherwise or none passed, else pending.
_land_ci() {
  local root="$1" sha="$2" branch="$3" raw
  raw="$(cd "$root" && gh run list --commit "$sha" --branch "$branch" --event push \
    --json name,status,conclusion,url --limit 50 2>&1)" \
    || { jq -nc --arg e "${raw//$'\n'/ }" '{status: "pending", runs: [], note: "gh run list failed: \($e)"}'; return 0; }
  jq -ec '
    def ok: . == "success" or . == "skipped" or . == "neutral";
    select(type == "array") | map({name, conclusion, url}) as $runs
    | if length == 0 then {status: "pending", runs: [], note: "no CI run for it yet: is the branch pushed to origin?"}
      elif any(.[]; .status == "completed" and (.conclusion | ok | not)) then {status: "failed", runs: $runs}
      elif all(.[]; .status == "completed") and any(.[]; .conclusion == "success") then {status: "ready", runs: $runs}
      elif all(.[]; .status == "completed") then {status: "failed", runs: $runs}
      else {status: "pending", runs: $runs, note: "CI still running"} end' <<<"$raw" 2>/dev/null \
    || jq -nc '{status: "pending", runs: [], note: "gh run list printed no list of runs"}'
}

# What Shep reads, from facts only: no desk-authored text.
_land_event() {
  local root="$1" sha="$2" branch="$3" ci="$4" minutes="$5" repo main info trunk moved
  main="$(git_backend_main "$root" 2>/dev/null || printf '%s' "$root")"
  repo="$(basename "$main")"
  info="$(notify_desk_info "$root" "")"
  trunk="$(git_backend_trunk "$root")"
  moved="$(git -C "$root" rev-parse --verify --quiet "refs/heads/$branch" || true)"
  jq -nc --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg sha "$sha" --arg branch "$branch" \
    --arg repo "$repo" --arg root "$root" --argjson ci "$ci" --argjson desk "$info" --arg min "$minutes" \
    --arg trunk "$trunk" --arg moved "$moved" '
    ($sha[0:12]) as $short
    | ([$ci.runs[] | select(.conclusion != "success") | "\(.name) \(.conclusion // "unfinished")"] | join(", ")) as $bad
    | (if $ci.status == "ready" and $moved != $sha then "moved" else $ci.status end) as $status
    | {source: "bercail", schema: "bercail.land/v1", kind: "land", sink: "shep", at: $at,
       event_id: "land:\($sha):\($at)",
       land: {status: $status, head: $sha, branch: $branch, runs: $ci.runs},
       space: {repo: $repo, checkout_path: $root}, desk: {issue: $desk.issue, issue_title: $desk.issue_title},
       text: (
         if $status == "ready" then "\($branch) at \($short) in \($repo) is ready to land: CI passed. Land that commit the way the repo policy says (straight to main: git push origin \($sha):\($trunk))."
         elif $status == "moved" then "CI passed on \($branch) at \($short) in \($repo), but the branch has moved on to \($moved[0:12]). Do not land it: the new commits need review and their own bercail land."
         elif $status == "failed" then "CI did not pass on \($branch) at \($short) in \($repo) (\($bad)). Do not land it: the desk fixes it."
         else "No CI result for \($branch) at \($short) in \($repo) after \($min) minutes (\($ci.note // "CI still running")). Do not land it yet." end)}'
}

# Write the event whole into Shep's inbox (tmp, then mv), as the follower does.
_land_enqueue() {
  local event="$1" inbox name tmp
  inbox="$(shep_inbox_dir)"
  [[ -n "$inbox" ]] || { _land_err "no Shep inbox in $(shep_state_dir): start Shep once; the event was: $event"; return 1; }
  name="$(jq -r '.event_id' <<<"$event" | tr -c 'A-Za-z0-9._-' '_').json"
  tmp="$(umask 077 && mktemp "$inbox/.event.XXXXXX")" || return 1
  printf '%s\n' "$event" >"$tmp" && mv -f "$tmp" "$inbox/$name"
}

# Poll SHA's CI until it is ready or failed, or the time is up (timeout); then
# one event. A ready commit the branch has moved past is moved, never ready.
land_wait() {
  local sha="$1" dir="$2" root branch ci start now event
  local poll="${BERCAIL_LAND_POLL:-30}" limit="${BERCAIL_LAND_TIMEOUT:-7200}"
  root="$(_desc_root "$dir")" || return 1
  branch="$(git -C "$root" symbolic-ref --quiet --short HEAD 2>/dev/null)" \
    || { _land_err "$root is on no branch: the wait reads the CI of the branch land committed on"; return 1; }
  start="$(date +%s)"
  while :; do
    ci="$(_land_ci "$root" "$sha" "$branch")"
    [[ "$(jq -r .status <<<"$ci")" == pending ]] || break
    now="$(date +%s)"
    ((now - start < limit)) || break
    sleep "$poll"
  done
  ci="$(jq -c 'if .status == "pending" then .status = "timeout" else . end' <<<"$ci")"
  event="$(_land_event "$root" "$sha" "$branch" "$ci" "$(((limit + 59) / 60))")" \
    || { _land_err "could not write the land event for ${sha:0:12}; CI said: $ci"; return 1; }
  printf 'CI on %s: %s\n' "${sha:0:12}" "$(jq -r .land.status <<<"$event")"
  _land_enqueue "$event"
}

# Why ROOT's repo cannot land from one card, or nothing: integration direct with
# a trusted push = "main", on the gh backend, with a required_ci gate.
_land_profile() {
  local root="$1" policy backend
  policy="$(policy_json "$root")" || { printf 'its policy cannot be read'; return 0; }
  backend="$(git_backend "$root")"
  jq -r --arg backend "$backend" '
    if $backend != "gh" then "its git backend is \($backend), not gh"
    elif .trusted != true then "its policy is not trusted"
    elif .policy.integrate != "direct" then "it integrates by \(.policy.integrate), not straight to the trunk"
    elif .policy.push != "main" then "its policy says push = \(.policy.push), not main"
    elif (.policy.required_ci // []) == [] then "its policy names no required_ci workflow"
    else empty end' <<<"$policy"
}

# Put back a desk's merge as land_ask found it: HEAD, the merge's own files, ORIG_HEAD
# (which the reset rewrites) and the description, from SAVED.
_land_unflatten() {
  local root="$1" gd="$2" saved="$3" name
  git -C "$root" reset -q --soft "$(cat "$saved/HEAD")"
  for name in MERGE_HEAD MERGE_MSG MERGE_MODE AUTO_MERGE ORIG_HEAD; do
    if [[ -f "$saved/$name" ]]; then cp "$saved/$name" "$gd/$name"; else rm -f "$gd/$name"; fi
  done
  cp "$saved/description.md" "$root/$DESC_FILE"
  rm -rf "$saved"
}

# One land card for a desk's described change, through the ledger's land-create,
# which pins every fact. It refuses, with the fix, what one pick cannot land.
land_ask() {
  local dir="$1" root gd common branch trunk why issue remote head title card token flat="" saved="" name
  root="$(_desc_root "$dir")" || return 1
  gd="$(git -C "$root" rev-parse --absolute-git-dir)"
  common="$(git -C "$root" rev-parse --path-format=absolute --git-common-dir)"
  [[ "$gd" != "$common" ]] \
    || { _land_err "$root is the repo's main checkout: land a desk's own worktree"; return 1; }
  branch="$(git -C "$root" symbolic-ref --quiet --short HEAD 2>/dev/null)" \
    || { _land_err "$root is on no branch: land a desk's branch"; return 1; }
  trunk="$(git_backend_trunk "$root")"
  [[ "$branch" != "$trunk" ]] || { _land_err "$root is on $trunk itself: land a desk's branch"; return 1; }
  # The repo's policy, as its main checkout has it: a desk's edit to the file on its branch
  # does not change what lands it.
  why="$(_land_profile "$(git_backend_main "$root")")"
  [[ -z "$why" ]] || { _land_err "one land card cannot land this repo: $why; land it as before, with bercail land $root"; return 1; }
  issue="$(notify_desk_info "$root" "" | jq -r '.issue // empty')"
  [[ -n "$issue" && "$issue" != trail:* ]] \
    || { _land_err "$root has no beads issue in its handoff record: a land card closes the job it lands"; return 1; }
  remote="$(git -C "$root" ls-remote origin "refs/heads/$trunk" | awk -v ref="refs/heads/$trunk" '$2 == ref { print $1 }')" \
    || { _land_err "could not read $trunk on origin; nothing was asked"; return 1; }
  desc_state "$root" | jq -e '.fails | length == 0' >/dev/null \
    || { _land_err "the description of $root does not check out (bercail describe check $root): the desk runs /validate"; return 1; }
  # A desk that merged the trunk into its branch: the trunk takes one commit, never a merge,
  # so the merge's exact tree lands as one commit on the trunk's tip. HEAD moves there with
  # the staged tree as it is, and the description's stamp records that tip as its base. A
  # card the ledger then refuses puts the merge back as it was.
  if git -C "$root" rev-parse --quiet --verify MERGE_HEAD >/dev/null; then
    [[ "$(grep -c . "$gd/MERGE_HEAD")" == 1 && -n "$remote" && "$(git -C "$root" rev-parse MERGE_HEAD)" == "$remote" ]] \
      || { _land_err "$root is merging something other than $trunk on origin (${remote:0:12}): the desk merges only $trunk's tip, or ends the merge, and runs /validate again"; return 1; }
    [[ -z "$(git -C "$root" diff --name-only --diff-filter=U)" ]] \
      || { _land_err "$root still has merge conflicts: the desk resolves and stages them, and runs /validate again"; return 1; }
    [[ ! -e "$gd/MERGE_AUTOSTASH" ]] \
      || { _land_err "$root's merge holds an autostash, which ending the merge would move to the stash list: the desk commits or drops what it stashed, and runs /validate again"; return 1; }
    saved="$(mktemp -d)" && git -C "$root" rev-parse HEAD >"$saved/HEAD" && cp "$root/$DESC_FILE" "$saved/description.md" \
      || { _land_err "could not keep $root's merge state to put back; nothing was asked"; return 1; }
    for name in MERGE_HEAD MERGE_MSG MERGE_MODE AUTO_MERGE ORIG_HEAD; do
      [[ ! -f "$gd/$name" ]] || cp "$gd/$name" "$saved/$name"
    done
    git -C "$root" merge --quit && git -C "$root" reset -q --soft "$remote" && _desc_stamp "$root" >/dev/null \
      || { _land_unflatten "$root" "$gd" "$saved"; _land_err "could not put HEAD on $trunk's tip with the merged tree staged in $root; its merge is as it was, and nothing was asked"; return 1; }
    flat=" The desk's merge of $trunk lands as one commit with its exact tree."
  fi
  head="$(git -C "$root" rev-parse HEAD)"
  [[ -n "$remote" && "$head" == "$remote" ]] \
    || { _land_err "HEAD in $root is ${head:0:12}, not $trunk on origin (${remote:0:12}): the desk brings its staged change onto $trunk's tip and runs /validate again, so the tree the person reviews is the tree that lands"; return 1; }
  title="$(_desc_title "$root/$DESC_FILE")"
  card="$(jq -nc --arg id "land-ask-$issue-$(date +%s%N)-$$" --arg prompt "Land: $title" --arg wt "$root" --arg issue "$issue" \
    '{requestId: $id, prompt: $prompt, origin: {event: "land-ask:\($issue)", session: "shep", entry: null}, worktree: $wt, issue: $issue}' \
    | shep_question land-create)" || {
    why="no land card was put up (the ledger's reason is above)"
    [[ -z "$saved" ]] || { _land_unflatten "$root" "$gd" "$saved"; why+="; the desk's merge is as it was"; }
    _land_err "$why"
    return 1
  }
  [[ -z "$saved" ]] || rm -rf "$saved"
  token="$(jq -r '"\(.id)@\(.revision)"' <<<"$card")"
  jq -r --arg token "$token" --arg flat "$flat" '
    "\($token) is up on the Decisions panel: \(.options | join(" or ")).\($flat) "
    + (if .land.review.required then "It needs the person'"'"'s LGTM: it touches \(.land.review.highStakes | join(", "))." else "No LGTM needed." end)
    + " Its pick runs the rest, and the result comes to you as one land event."' <<<"$card"
}

# The land worker's state, set once it claimed its card.
LAND_TOKEN="" LAND_LOG="" LAND_COMMIT="" LAND_DONE=0 LAND_CHILD="" LAND_WT="" LAND_TRUSTED="" LAND_LANDED=0
LAND_WARNINGS=()

# Run ARGV under a time limit of $1 seconds, in its own process group, stdin
# closed, its output in the log. Exits as the command did; 124 or above 128 is
# killed or out of time.
_land_exec() {
  local limit="$1" rc=0
  shift
  timeout -k 10 "$limit" "$@" </dev/null >>"$LAND_LOG" 2>&1 &
  LAND_CHILD=$!
  wait "$LAND_CHILD" || rc=$?
  LAND_CHILD=""
  return "$rc"
}

# The ledger's step the chain starts now, and what it says.
_land_step() {
  printf '%s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "${2:-}" >>"$LAND_LOG"
  shep_question land-step "$LAND_TOKEN" "$@" | jq -e .accepted >/dev/null \
    || _land_stop unknown "the ledger refused its $1 step"
}

# The chain's one result, then its one land event; the worker ends. Past the trunk
# push the change landed: a later stop is a warning on landed, and the job stays open.
_land_stop() {
  local outcome="$1" why="${2:-}" input
  if [[ "$outcome" != landed && "$LAND_LANDED" -eq 1 ]]; then
    LAND_WARNINGS+=("the chain stopped after the trunk push ($why), so cleanup, sync or close may not have run, and the job stays open")
    outcome=landed why=""
  fi
  input="$(jq -nc --arg token "$LAND_TOKEN" --arg outcome "$outcome" --arg commit "$LAND_COMMIT" --arg why "$why" \
    --arg log "$LAND_LOG" --arg trusted "$LAND_TRUSTED" --args '{token: $token, outcome: $outcome,
      commit: (if $commit == "" then null else $commit end), warnings: $ARGS.positional, log: $log}
      + (if $why == "" then {} else {why: $why} end) + (if $trusted == "" then {} else {trusted: $trusted} end)' \
    "${LAND_WARNINGS[@]}")"
  printf '%s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$outcome" "$why" >>"$LAND_LOG"
  LAND_DONE=1
  shep_question land-result <<<"$input" >/dev/null || _land_err "could not record $outcome for $LAND_TOKEN; Shep's sweep records it as unknown"
  shep_question land-tell "$LAND_TOKEN" >/dev/null || _land_err "could not tell Shep of $LAND_TOKEN; Shep's sweep tells it"
  printf '%s: %s%s\n' "$LAND_TOKEN" "$outcome" "${why:+ ($why)}"
  exit 0
}

# A worker that ends any other way after its claim: its step may have half run.
_land_died() {
  [[ "$LAND_DONE" -eq 1 || -z "$LAND_TOKEN" ]] && return 0
  [[ -z "$LAND_CHILD" ]] || kill -KILL -- "-$LAND_CHILD" 2>/dev/null || true
  _land_stop unknown "its worker stopped before it recorded a result"
}

# Every pinned fact read again (land-check), and the git backend still gh, as
# land ask required. With the chain's commit, HEAD must be that commit; with
# --landed, the trunk on the remote too. Prints why not.
_land_fresh() {
  local out backend
  backend="$(git_backend "$LAND_WT" 2>/dev/null)" || backend="unknown"
  [[ "$backend" == gh ]] || { printf 'the git backend is now %s, not gh' "$backend"; return 1; }
  out="$(shep_question land-check "$LAND_TOKEN" "$@")" || { printf 'the check could not run'; return 1; }
  jq -e '.status == "fresh"' <<<"$out" >/dev/null && return 0
  jq -r '.reasons | join(", ")' <<<"$out"
  return 1
}

# The guard's own decision on COMMAND as Shep, and the facts it pins: a veto. It
# must say EXPECTED, and pin exactly the facts WANT (JSON). Prints why not.
_land_decide() {
  local bin="$1" command="$2" expected="$3" want="$4" cwd="$5" out
  out="$(jq -nc --arg c "$command" --arg d "$cwd" '{command: $c, cwd: $d}' | "$bin" guard decide 2>>"$LAND_LOG")" \
    || { printf 'the guard could not decide on it'; return 1; }
  jq -e --arg want "$expected" '.action == $want' <<<"$out" >/dev/null \
    || { jq -r --arg want "$expected" '"the guard says \(.action), not \($want)\(if .reason then ": " + .reason else "" end)"' <<<"$out"; return 1; }
  jq -e --argjson want "$want" '.facts == $want' <<<"$out" >/dev/null \
    || { jq -rc '"the guard pins it to other facts: \(.facts // .why)"' <<<"$out"; return 1; }
}

# The facts the guard pins a push of SHA to REF from DIR to: the card's URL and no other.
_land_push_facts() {
  jq -nc --arg dir "$1" --arg gd "$(realpath "$(git -C "$1" rev-parse --absolute-git-dir)")" --arg url "$2" --arg spec "$3:$4" \
    '{kind: "push", dir: $dir, gitDir: $gd, url: $url, refspecs: [$spec]}'
}

# A branch's commit on the remote at URL, or nothing.
_land_remote() {
  local dir="$1" url="$2" ref="$3"
  timeout 60 git -C "$dir" ls-remote --end-of-options "$url" "$ref" </dev/null | awk -v ref="$ref" '$2 == ref { print $1 }'
}

# The required workflows' push runs of the chain's commit on its CI branch, as
# {state, passed, total, why}: green when each one's latest run is completed
# with success; failed once any is completed otherwise; else pending. A list as
# long as its limit may be cut short, so it is never green.
_land_gate() {
  local github="$1" sha="$2" branch="$3" ids="$4" limit="${BERCAIL_LAND_RUN_LIMIT:-100}" raw
  raw="$(timeout 60 gh run list --repo "$github" --commit "$sha" --branch "$branch" --event push \
    --json databaseId,workflowDatabaseId,headBranch,headSha,attempt,status,conclusion --limit "$limit" </dev/null 2>&1)" \
    || { jq -nc --arg e "${raw//$'\n'/ }" '{state: "pending", passed: 0, total: 0, why: "gh run list failed: \($e)"}'; return 0; }
  jq -ec --arg sha "$sha" --arg branch "$branch" --argjson ids "$ids" --argjson limit "$limit" '
    select(type == "array") | . as $all
    | [$ids[] as $w | {path: $w.path, run: ([$all[] | select(.workflowDatabaseId == $w.id and .headSha == $sha and .headBranch == $branch)]
        | sort_by(.databaseId, .attempt) | last)}] as $req
    | ([$req[] | select(.run.status == "completed" and .run.conclusion == "success")] | length) as $passed
    | [$req[] | select(.run.status == "completed" and .run.conclusion != "success")] as $bad
    | {passed: $passed, total: ($ids | length)}
    + if ($bad | length) > 0 then {state: "failed", why: ([$bad[] | "\(.path) \(.run.conclusion)"] | join(", "))}
      elif ($all | length) >= $limit then {state: "pending", why: "the run list may be cut short at \($limit) runs"}
      elif $passed == ($ids | length) then {state: "green"}
      else {state: "pending", why: ([$req[] | select(.run == null) | "\(.path) has no run"] + [$req[] | select(.run != null and .run.status != "completed") | "\(.path) is \(.run.status)"] | join(", "))} end' \
    <<<"$raw" 2>/dev/null \
    || jq -nc '{state: "pending", passed: 0, total: 0, why: "gh run list printed no list of runs"}'
}

# The worker on the person's Ship it: claim it, then each effect in order, each
# with its own facts checked again just before it runs. A stop is final: nothing
# is retried or replayed, and the result comes to Shep as one land event.
land_chain() {
  local token="$1" claim q wt branch head tree base trunk issue url github ci_ref ids reviewer bin desk
  local main msg sha why ci state said="" poll limit start lock fd remote var rc dir trust landed
  local -a f
  [[ "$token" =~ ^Q[1-9][0-9]*@[1-9][0-9]*$ ]] || { _land_err "land run takes a card's Qn@rev token"; return 1; }
  # No inherited git addressing or config: the facts are read, and the effects run, on the pinned repo.
  for var in GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_NAMESPACE GIT_ALTERNATE_OBJECT_DIRECTORIES $(compgen -e | grep '^GIT_CONFIG' || true); do
    unset "$var"
  done
  export GIT_TERMINAL_PROMPT=0
  claim="$(shep_question land-claim "$token")" || return 1
  if ! jq -e .accepted <<<"$claim" >/dev/null; then
    printf 'not run: %s\n' "$(jq -r .reason <<<"$claim")"
    return 0
  fi
  LAND_TOKEN="$token"
  dir="$(dirname "$(shep_state_dir)")/land"
  (umask 077 && mkdir -p "$dir" && : >>"$dir/${token/@/-}.log")
  LAND_LOG="$dir/${token/@/-}.log"
  trap _land_died EXIT
  trap 'exit 1' TERM INT HUP
  q="$(shep_question get "$token")" || _land_stop unknown "its card could not be read"
  mapfile -t f < <(jq -r '.target.worktree, .target.branch, .target.head, .target.stagedTree, .target.base,
    .target.baseRef, .target.issue, .land.url, .land.github, .land.ciRef, (.land.reviewer // ""), .land.bercail,
    .target.desk, (.land.policyTrust // "")' <<<"$q")
  wt="${f[0]}" branch="${f[1]}" head="${f[2]}" tree="${f[3]}" base="${f[4]}" trunk="${f[5]}" issue="${f[6]}"
  url="${f[7]}" github="${f[8]}" ci_ref="${f[9]}" reviewer="${f[10]}" bin="${f[11]}" desk="${f[12]}" trust="${f[13]}"
  ids="$(jq -c .land.requiredCi <<<"$q")"
  LAND_WT="$wt"
  cd / || _land_stop unknown "could not leave the worktree's folder"

  _land_step check
  why="$(_land_fresh)" || _land_stop changed "$why"
  # The pushes run from the main checkout, which shares the worktree's objects: the guard
  # decides them on the repo's policy there, not on a desk's edit to it.
  main="$(realpath "$(git -C "$wt" worktree list --porcelain | sed -n '1s/^worktree //p')")"

  _land_step commit "tree ${tree:0:12} on ${head:0:12}"
  msg="$dir/${token/@/-}.message"
  "$bin" describe commit ${reviewer:+--reviewed-by "$reviewer"} "$wt" >"$msg" 2>>"$LAND_LOG" \
    || _land_stop changed "its description no longer prints a commit text"
  [[ "$(sha256sum <"$msg" | cut -d' ' -f1)" == "$(jq -r .land.description.message <<<"$q")" ]] \
    || _land_stop changed "its commit text changed"
  why="$(_land_fresh)" || _land_stop changed "$why"
  [[ "$(git -C "$wt" write-tree)" == "$tree" ]] || _land_stop changed "the index is not the pinned tree"
  _land_exec 600 git -C "$wt" commit -q --cleanup=verbatim -F "$msg" || {
    rc=$?
    [[ "$(git -C "$wt" rev-parse HEAD)" != "$head" ]] && _land_stop unknown "git commit exited $rc after HEAD moved"
    ((rc == 124 || rc > 128)) && _land_stop unknown "git commit was killed or ran out of time"
    _land_stop refused "git commit exited $rc, and nothing was committed (a hook may have refused it; see the log)"
  }
  sha="$(git -C "$wt" rev-parse HEAD)"
  LAND_COMMIT="$sha"
  # What git wrote, read back: a hook that changed it changed what the person picked.
  [[ "$(git -C "$wt" --no-replace-objects cat-file commit "$sha" | sed -n '/^$/q; /^\(tree\|parent\) /p')" \
    == "tree $tree"$'\n'"parent $head" ]] \
    && cmp -s "$msg" <(git -C "$wt" --no-replace-objects cat-file commit "$sha" | sed '1,/^$/d') \
    || _land_stop unknown "the commit ${sha:0:12} is not the pinned tree, parent and text: a hook changed it, so nothing was pushed"

  _land_step push "${sha:0:12} to ${ci_ref#refs/heads/}"
  why="$(_land_fresh "$sha")" || _land_stop changed "$why"
  remote="$(_land_remote "$wt" "$url" "$ci_ref")" || _land_stop push-failed "could not read $url"
  [[ -z "$remote" ]] || _land_stop changed "its CI branch ${ci_ref#refs/heads/} is already on the remote"
  why="$(_land_decide "$bin" "git -C $main push origin $sha:$ci_ref" allow "$(_land_push_facts "$main" "$url" "$sha" "$ci_ref")" "$main")" \
    || _land_stop refused "the branch push: $why"
  _land_exec 300 git -C "$main" push --no-follow-tags --recurse-submodules=no "$url" "$sha^{commit}:$ci_ref" || {
    rc=$?
    ((rc == 124 || rc > 128)) && _land_stop unknown "the branch push was killed or ran out of time"
    _land_stop push-failed "the push to ${ci_ref#refs/heads/} exited $rc"
  }

  _land_step ci "waiting for CI (0 of $(jq length <<<"$ids") runs passed)"
  poll="${BERCAIL_LAND_POLL:-30}" limit="${BERCAIL_LAND_TIMEOUT:-7200}" start="$(date +%s)"
  while :; do
    ci="$(_land_gate "$github" "$sha" "${ci_ref#refs/heads/}" "$ids")"
    state="$(jq -r .state <<<"$ci")"
    [[ "$state" != failed ]] || _land_stop ci-failed "$(jq -r .why <<<"$ci")"
    [[ "$state" != green ]] || break
    # The ledger keeps a step's detail each time it changes, not each poll.
    if [[ "$(jq -r '"waiting for CI (\(.passed) of \(.total) runs passed)"' <<<"$ci")" != "$said" ]]; then
      said="$(jq -r '"waiting for CI (\(.passed) of \(.total) runs passed)"' <<<"$ci")"
      _land_step ci "$said"
    fi
    (($(date +%s) - start < limit)) || _land_stop ci-timeout "$(jq -r .why <<<"$ci")"
    sleep "$poll"
  done

  _land_step trunk "${sha:0:12} to $trunk"
  # One landing at a time per repo; a person's push meanwhile still fails the push as behind.
  lock="$dir/$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir | sha256sum | cut -c1-16).lock"
  exec {fd}>>"$lock"
  flock -w 600 "$fd" || _land_stop unknown "another landing in this repo held its lock for ten minutes"
  remote="$(_land_remote "$wt" "$url" "refs/heads/$trunk")" || _land_stop push-failed "could not read $url"
  [[ "$remote" == "$base" ]] || _land_stop behind "$trunk is now ${remote:0:12} on the remote, not ${base:0:12}"
  ci="$(_land_gate "$github" "$sha" "${ci_ref#refs/heads/}" "$ids")"
  [[ "$(jq -r .state <<<"$ci")" == green ]] \
    || _land_stop ci-failed "CI was no longer green on a second read: $(jq -r '.why // .state' <<<"$ci")"
  why="$(_land_fresh "$sha")" || _land_stop changed "$why"
  why="$(_land_decide "$bin" "git -C $main push origin $sha:refs/heads/$trunk" allow \
    "$(_land_push_facts "$main" "$url" "$sha" "refs/heads/$trunk")" "$main")" \
    || _land_stop refused "the trunk push: $why"
  _land_exec 300 git -C "$main" push --no-follow-tags --recurse-submodules=no "$url" "$sha^{commit}:refs/heads/$trunk" || {
    rc=$?
    ((rc == 124 || rc > 128)) && _land_stop unknown "the trunk push was killed or ran out of time"
    remote="$(_land_remote "$wt" "$url" "refs/heads/$trunk")" || true
    [[ "$remote" == "$base" ]] || _land_stop behind "$trunk moved to ${remote:0:12} during the push"
    _land_stop push-failed "the push to $trunk exited $rc"
  }
  remote="$(_land_remote "$wt" "$url" "refs/heads/$trunk")" || true
  [[ "$remote" == "$sha" ]] || _land_stop unknown "the push to $trunk exited 0, but $trunk reads ${remote:0:12} on the remote"
  LAND_LANDED=1
  flock -u "$fd"
  # As git push origin would record it, now that the remote said so: cleanup reads it.
  git -C "$wt" update-ref "refs/remotes/origin/$trunk" "$sha" 2>>"$LAND_LOG" || true

  _land_step cleanup "$wt"
  if ! why="$(_land_fresh "$sha" --landed)"; then
    LAND_WARNINGS+=("the desk and its worktree stay: $why")
  elif ! why="$(_land_decide "$bin" "bercail cleanup $wt" ask "$(jq -nc --arg wt "$wt" --arg b "$branch" --arg sha "$sha" \
    '{kind: "cleanup", worktree: $wt, branch: $b, head: $sha}')" /)"; then
    LAND_WARNINGS+=("the desk and its worktree stay: $why")
  elif ! _land_exec 600 "$bin" cleanup "$wt"; then
    LAND_WARNINGS+=("bercail cleanup of $wt did not finish (its log says why), so the desk $desk or its worktree may stay")
  fi

  _land_step sync "$main"
  if [[ "$(git -C "$main" symbolic-ref --quiet HEAD 2>/dev/null)" != "refs/heads/$trunk" ]]; then
    LAND_WARNINGS+=("the main checkout $main is not on $trunk, so it was not fast-forwarded")
  elif [[ -n "$(git -C "$main" status --porcelain --untracked-files=no 2>&1)" ]]; then
    LAND_WARNINGS+=("the main checkout $main has changes, so it was not fast-forwarded")
  elif ! git -C "$main" merge-base --is-ancestor HEAD "$sha" 2>/dev/null; then
    LAND_WARNINGS+=("the main checkout $main has commits $trunk does not, so it was not fast-forwarded")
  elif ! _land_exec 120 git -C "$main" merge --ff-only -q "$sha"; then
    LAND_WARNINGS+=("git merge --ff-only in $main failed, so it was not fast-forwarded")
  fi
  # A change to the policy file the person approved: now that its commit is on the trunk,
  # trust exactly the file the card showed, as bercail policy trust would.
  if [[ -n "$trust" ]]; then
    landed="$(git -C "$main" cat-file blob "$sha:$POLICY_FILE" 2>/dev/null | sha256sum | cut -d' ' -f1)" || landed=""
    if [[ "$landed" != "$trust" ]]; then
      LAND_WARNINGS+=("$POLICY_FILE on $trunk at ${sha:0:12} has sha256 ${landed:0:12}, not the card's ${trust:0:12}, so it is not trusted")
    elif ! policy_trust_hash "$(git_backend_main "$main")" "$(git_backend_main "$main")/$POLICY_FILE" "$trust" 2>>"$LAND_LOG"; then
      LAND_WARNINGS+=("the trust of $POLICY_FILE, sha256 ${trust:0:12}, could not be written (the log says why), so it is not trusted")
    else
      LAND_TRUSTED="$trust"
      _land_step sync "trusted $POLICY_FILE, sha256 ${trust:0:12}"
    fi
  fi

  # The job closes only once the rest held; otherwise it stays open for Shep to finish.
  _land_step close "$issue"
  if ((${#LAND_WARNINGS[@]})); then
    LAND_WARNINGS+=("$issue stays open until that is done")
  elif [[ "$(cd "$main" && timeout 60 bd show "$issue" --json </dev/null 2>>"$LAND_LOG" | jq -r --arg id "$issue" '.[] | select(.id == $id) | .status')" == closed ]]; then
    LAND_WARNINGS+=("$issue was already closed")
  elif ! (cd "$main" && _land_exec 60 bd close "$issue" --reason "Landed on $trunk as $sha from land card $token"); then
    LAND_WARNINGS+=("bd close $issue failed, so the job is still open")
  fi
  _land_stop landed
}

cmd_land() {
  local dir="" reviewer="" sha=""
  [[ "${BERCAIL_ROLE:-}" == shep ]] || {
    _land_err "landing is Shep's (BERCAIL_ROLE=shep): a desk stages its change and finishes with /validate, and Shep lands it"
    return 1
  }
  case "${1:-}" in
    ask)
      [[ $# -eq 2 && "$2" != -* ]] || { _land_err "usage: bercail land ask <worktree>"; return 1; }
      land_ask "$2"
      return ;;
    run)
      [[ $# -eq 2 ]] || { _land_err "usage: bercail land run Qn@rev (only the person's pick starts it)"; return 1; }
      land_chain "$2"
      return ;;
  esac
  while (($#)); do
    case "$1" in
      --reviewed-by)
        reviewer="${2:-}"
        [[ -n "$reviewer" && "$reviewer" != *$'\n'* ]] || { _land_err "--reviewed-by takes the reviewer's name"; return 1; }
        shift ;;
      --wait)
        sha="${2:-}"
        [[ "$sha" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] || { _land_err "--wait takes the full commit id"; return 1; }
        shift ;;
      -*) _land_err "unknown option: $1; $LAND_USAGE"; return 1 ;;
      *) [[ -z "$dir" ]] || { _land_err "$LAND_USAGE"; return 1; }; dir="$1" ;;
    esac
    shift
  done
  [[ -n "$dir" ]] || { _land_err "$LAND_USAGE"; return 1; }
  if [[ -n "$sha" ]]; then
    land_wait "$sha" "$dir"
  else
    land_run "$dir" "$reviewer"
  fi
}
