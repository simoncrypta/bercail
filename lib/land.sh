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

# shellcheck source=lib/describe.sh
source "$(dirname "${BASH_SOURCE[0]}")/describe.sh"

LAND_USAGE="usage: bercail land <worktree> [--reviewed-by NAME]"

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

cmd_land() {
  local dir="" reviewer="" sha=""
  [[ "${BERCAIL_ROLE:-}" == shep ]] || {
    _land_err "landing is Shep's (BERCAIL_ROLE=shep): a desk stages its change and finishes with /validate, and Shep lands it"
    return 1
  }
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
