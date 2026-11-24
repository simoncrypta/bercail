#!/usr/bin/env bash
# shellcheck shell=bash
# The cleanup routine, run = "cleanup" (docs/routines.md#cleanup). It only
# reads, and prints a finding a line for what should be retired or asked
# about; Shep acts on each after the person's pick (shep/SHEP.md). Its one
# write is routines/<name>/seen-done.json, when it first saw each desk done,
# and never on a dry run.
#
# A source that fails fails the run: a run that left its findings out would
# drop their hashes, and the next one would send them again as new.
set -euo pipefail

lib="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/common.sh
source "$lib/common.sh"
for n in "${BERCAIL_LIBS[@]}"; do
  # shellcheck source=/dev/null
  source "$lib/$n.sh"
done
# shellcheck source=lib/routine.sh
source "$lib/routine.sh"
# shellcheck source=lib/cleanup.sh
source "$lib/cleanup.sh"
# The question ledger checks cards with this checkout's bercail, not another on PATH.
[[ ! -x "$lib/../bin/bercail" ]] || export BERCAIL_SELF="$lib/../bin/bercail"

# A desk done on a later local day, and at least 20 hours after it was first
# seen so: a day apart, a 23-hour day too. A card waiting over 3 days is old.
SEEN_GAP=$((20 * 3600))
CARD_AGE=$((3 * 86400))
# Nobody waits on a routine: bd gets well past the 3 seconds or more a call
# takes under load (bercail-xtdl).
# shellcheck disable=SC2034 # read by _shep_bd
SHEP_BD_WAIT=10

name="${1:?usage: cleanup.sh <routine name>}"
now="$(_routine_now)"
results=""

_source_failed() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

# finding KEY TITLE [DETAIL] [REPO] [ISSUE]: one line of what it found.
finding() {
  results+="$(jq -nc --arg key "$1" --arg title "$2" --arg detail "${3:-}" --arg repo "${4:-}" --arg issue "${5:-}" \
    '{key: $key, title: $title} + ({detail: $detail, repo: $repo, issue: $issue} | with_entries(select(.value != "")))')"$'\n'
}

# A folder's worktree by its real path, or status 1.
_top() { [[ -n "$1" ]] && (cd "$1" && cd "$(git rev-parse --show-toplevel)" && pwd -P) 2>/dev/null; }

# The job ID in repo MAIN as "closed|open<TAB>title" in $job, or status 1
# when it cannot be read: an unread job is not closed. A trail merged is
# closed too. A lookup killed or out of time fails the run: that job
# may be closed, and a run without its findings would send them again as new.
# Read once a run.
declare -A jobs=()
_job() {
  local main="$1" id="$2" raw rc=0
  job=""
  if [[ ! -v "jobs[$main/$id]" ]]; then
    if _shep_is_trail "$id"; then
      raw="$(_shep_job show "$id" --repo "$main" --json 2>/dev/null </dev/null)" || rc=$?
    else
      raw="$(_shep_bd_issue "$main" "$id")" || rc=$?
    fi
    ((rc != 124 && rc < 128)) || _source_failed "the lookup of $id in $main was killed or ran out of time (status $rc)"
    ((rc == 0)) || raw=""
    jobs[$main/$id]="$(jq -r 'select(.status) | [if .status == "closed" or .phase == "complete" then "closed" else "open" end,
      (.title // "" | gsub("[[:space:]]+"; " "))] | @tsv' <<<"${raw:-null}" 2>/dev/null)" || jobs[$main/$id]=""
  fi
  job="${jobs[$main/$id]}"
  [[ -n "$job" ]]
}

# Worktree TOP is gone, or going: its folder is, or its .git is, which git
# worktree remove takes before the index. A folder that cannot be searched
# does not tell, so it is not gone.
_gone() {
  [[ -x "${1%/*}" ]] || return 1
  [[ -e "$1" ]] || return 0
  [[ -x "$1" && ! -e "$1/.git" && ! -L "$1/.git" ]]
}

# Nothing staged in worktree TOP (status 0), staged changes (1), or the
# worktree gone since it was found (2). Read without refreshing its index, and
# never a checkout above it. An index git cannot read in a worktree still
# there fails the run.
_unstaged() {
  local rc=0
  GIT_OPTIONAL_LOCKS=0 GIT_CEILING_DIRECTORIES="${1%/*}" git -C "$1" diff --cached --quiet 2>/dev/null || rc=$?
  if ((rc > 1)); then
    ! _gone "$1" || return 2
    _source_failed "git could not read the index of $1"
  fi
  return "$rc"
}

desks="$(_shep_desks_json)" || _source_failed "hc did not list the desks"
# Each desk with the worktree it sits in.
desks="$(while IFS= read -r d; do
  jq -c --arg top "$(_top "$(jq -r '.cwd // ""' <<<"$d")" || true)" '. + {top: $top}' <<<"$d"
done < <(jq -c '.[]' <<<"$desks") | jq -sc .)"
# The window's spaces, when one runs on this machine; with none, cleanup reads
# spaces from hc.
window=""
_cleanup_herdr_helpers || _source_failed "no Herdr helpers (herdr-layout.sh); run bercail update"
if _wt_herdr_app_running; then
  window="$("$HERDR_APP" ls)" && jq -e '.spaces | type == "array"' <<<"$window" >/dev/null 2>&1 \
    || _source_failed "herdr-app did not list its spaces"
fi
records="$(notify_handoffs_file)"
if [[ -f "$records" ]]; then
  records="$(jq -Rnc '[inputs | fromjson? | select(type == "object" and (.path | type) == "string" and (.issue | type) == "string")]' "$records")"
else
  records='[]'
fi

# Worktrees on a closed job: retire one cleanup --check passes, ask about one
# with staged changes. Each is the latest handoff's on its folder, on that
# handoff's branch, and every desk in it or in the space cleanup finds on it
# (cleanup ends them all) is on that same job: done for a cleanup, not working
# for staged changes, as the review queue counts them.
while IFS= read -r rec; do
  path="$(jq -r .path <<<"$rec")" issue="$(jq -r .issue <<<"$rec")" branch="$(jq -r '.branch // ""' <<<"$rec")"
  top="$(_top "$path")" && [[ "$top" == "$(cd "$path" && pwd -P)" ]] || continue
  [[ "$(git -C "$top" rev-parse --absolute-git-dir)" != "$(git -C "$top" rev-parse --path-format=absolute --git-common-dir)" ]] || continue
  [[ -z "$branch" || "$(git -C "$top" symbolic-ref -q --short HEAD || true)" == "$branch" ]] || continue
  main="$(_shep_main_of "$top")" || continue
  _job "$main" "$issue" && [[ "$job" == closed$'\t'* ]] || continue
  rc=0
  space="$(_cleanup_space "$top" "$window")" || rc=$?
  ((rc != 5)) || continue
  ((rc == 0)) || _source_failed "could not tell which Herdr space is on $top: hc did not answer in full"
  there="$(jq -c --arg top "$top" --arg space "$space" '[.[] | select(.top == $top or ($space != "" and .space == $space))]' <<<"$desks")"
  jq -e --arg issue "$issue" 'all(.[]; .issue == $issue and .state != "working")' <<<"$there" >/dev/null || continue
  rc=0
  _unstaged "$top" || rc=$?
  ((rc != 2)) || continue
  if ((rc == 1)); then
    finding "staged-closed:$top" "$issue: ${job#*$'\t'} is closed, but its worktree has staged changes" "$top" "$main" "$issue"
    continue
  fi
  jq -e 'all(.[]; .state | IN("done", "idle"))' <<<"$there" >/dev/null || continue
  rc=0
  err="$( (HC_TERMINAL_ID="" cmd_cleanup --check "$top") 2>&1 >/dev/null)" || rc=$?
  if ((rc == 0)); then
    finding "cleanup:$top" "$issue: ${job#*$'\t'} is closed; bercail cleanup can retire its worktree" \
      "$top${branch:+ (branch $branch)}" "$main" "$issue"
  elif ((rc == 2)); then
    _source_failed "cleanup --check $top could not read what it needs: $(sed -n 's/^error: //p' <<<"$err" | tail -n 1)"
  fi
done < <(jq -c 'group_by(.path) | map(last) | .[]' <<<"$records")

# Desks done on an open job with nothing staged, in two runs a day apart:
# seen-done.json keeps when each was first seen so, and drops one that is not.
dir="$(routine_dir)/$name"
seen="$(jq -c 'if type == "object" then . else {} end' "$dir/seen-done.json" 2>/dev/null || printf '{}')"
next='{}'
while IFS= read -r d; do
  address="$(jq -r .address <<<"$d")" issue="$(jq -r .issue <<<"$d")" top="$(jq -r .top <<<"$d")"
  [[ -n "$top" ]] && _unstaged "$top" || continue
  _job "$(jq -r .repo <<<"$d")" "$issue" && [[ "$job" == open$'\t'* ]] || continue
  at="$(jq -r --arg a "$address" --arg i "$issue" '.[$a] | select(.issue == $i) | .at' <<<"$seen")"
  [[ "$at" =~ ^[0-9]+$ ]] || at="$now"
  next="$(jq -c --arg a "$address" --arg i "$issue" --argjson at "$at" '.[$a] = {issue: $i, at: $at}' <<<"$next")"
  if ((now - at >= SEEN_GAP)) && [[ "$(printf '%(%Y%m%d)T' "$now")" > "$(printf '%(%Y%m%d)T' "$at")" ]]; then
    finding "done-desk:$address" "$issue: ${job#*$'\t'}: desk $address finished, with nothing staged" "$top" \
      "$(jq -r .repo <<<"$d")" "$issue"
  fi
done < <(jq -c '.[] | select((.bg | not) and .issue and (.state | IN("done", "idle")))' <<<"$desks")

# Background Sheps that finished and are still live; a blocked one waits.
while IFS=$'\t' read -r address who issue title repo; do
  finding "bg-done:$address" "background Shep $who ($issue: $title) finished and is still live" "" "$repo" "$issue"
done < <(jq -r '.[] | select(.bg and (.state | IN("done", "idle")))
  | [.address, (.name // .address), (.issue // "?"), (.title // ""), (.repo // "")] | @tsv' <<<"$desks")

# This machine's spaces that a handoff opened on a worktree now gone. With no
# window there are no spaces to read.
if [[ -n "$window" ]]; then
  while IFS=$'\t' read -r space folder label repo; do
    [[ ! -e "$folder" && ! -L "$folder" && -d "$(dirname "$folder")" && -x "$(dirname "$folder")" ]] || continue
    finding "space:$space" "Herdr space $label is still open on $folder, which is gone" "" "$repo"
  done < <(jq -r --argjson spaces "$(jq -c '[.spaces[] | select(.machine == null and (.folder // "" | startswith("/")))]' <<<"$window")" '
    .[] as $r | $spaces[] | select(.id == $r.space and .folder == $r.path) | [.id, .folder, (.name // .id), ($r.repo // "")] | @tsv' \
    <<<"$records" | sort -u -t $'\t' -k1,1)
fi

# The question ledger: old cards, Discuss terminals on a settled card, and a
# thread topic with no card waiting.
ledger="$(shep_question json 2>/dev/null)" && jq -e '.questions | type == "array"' <<<"$ledger" >/dev/null \
  || _source_failed "the question ledger could not be read (bercail shep questions --json --all)"
# Waiting: pending, or a default nobody said OK to or reversed.
ledger="$(jq -c --argjson now "$now" '
  def epoch: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
  .questions |= map(. + {token: "\(.id)@\(.revision)",
    waiting: (.status == "pending" or (.status == "answered" and .answer.source == "default after timeout" and (.settled | not))),
    old: (if .status == "pending" then $now - (.createdAt | epoch) else $now - (.answer.at // .createdAt | epoch) end)})' <<<"$ledger")"
# Each old pending card's live check, as {token: status}: the panel's, without
# the panel's describe check of each worktree.
checks='{}'
while IFS= read -r token; do
  status="$(shep_question check "$token" 2>/dev/null | jq -er .status)" \
    || _source_failed "the live check of card $token did not run (bercail shep question check $token)"
  checks="$(jq -c --arg t "$token" --arg s "$status" '.[$t] = $s' <<<"$checks")"
done < <(jq -r --argjson age "$CARD_AGE" '.questions[] | select(.status == "pending" and .old > $age and (.landing | not)) | .token' <<<"$ledger")
while IFS= read -r q; do
  finding "card:$(jq -r .token <<<"$q")" "$(jq -r .title <<<"$q")" "" "$(jq -r '.target.repo // ""' <<<"$q")" \
    "$(jq -r '.target.issue // ""' <<<"$q")"
done < <(jq -c --argjson age "$CARD_AGE" --argjson check "$checks" '
  def cut: gsub("[[:space:]]+"; " ") | if length > 120 then .[:119] + "…" else . end;
  .questions[] | select(.waiting and .old > $age and (.landing | not))
  | if .status == "pending" then select($check[.token] | IN("stale", "unavailable"))
      | . + {title: "\(.token) (\(.kind)) no longer checks out, and was asked over 3 days ago: \(.prompt | cut)"}
    else . + {title: "\(.token) (\(.kind)) defaulted to \(.answer.choice | tojson) over 3 days ago, and nobody said OK: \(.prompt | cut)"} end' \
  <<<"$ledger")

discuss="$(_shep_hc ls --json --label bercail.role=shep-discuss)" && jq -e '.terminals | type == "array"' <<<"$discuss" >/dev/null \
  || _source_failed "hc did not list the Discuss terminals"
while IFS= read -r address; do
  token="$(_shep_hc get "$address" --json | jq -er '.labels["bercail.question"] // ""')" \
    || _source_failed "hc could not read Discuss terminal $address"
  status="$(jq -r --arg t "$token" '.questions[] | select(.token == $t and (.waiting | not)) | .status' <<<"$ledger")"
  [[ -z "$status" ]] || finding "discuss:$address" "Discuss terminal $address is open on $token, whose card is $status"
done < <(jq -r '.terminals[] | select(.state == "live" and (.address | contains("/") | not)) | .address' <<<"$discuss")

topic="$(jq -r '.selected as $s | select($s != null and (any(.questions[]; .target.topic == $s and .waiting) | not)) | $s' <<<"$ledger")"
[[ -z "$topic" ]] || finding "thread:$topic" "Shep's thread topic $topic has no card waiting"

if [[ "${BERCAIL_ROUTINE_DRY_RUN:-0}" != 1 ]]; then
  mkdir -p "$dir"
  _routine_write "$dir/seen-done.json" "$next" || _source_failed "could not write $dir/seen-done.json"
fi
printf '%s' "$results"
