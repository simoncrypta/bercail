#!/usr/bin/env bash
# shellcheck shell=bash
# The issues routine, run = "issues" (docs/routines.md#the-issues-routine). It
# only reads: its repo's ready issues with its label, from its source; hc's
# desks; the handoff records; the test slots; the review queue; and the
# question ledger. It prints at most one finding, the issue to offer next;
# Shep asks the person before a desk starts on it (shep/SHEP.md). It keeps no
# state: what the person answered is in the ledger, on the cards Shep asks
# with the topic routine:<name>, that issue and that repo.
#
# Under load it offers nothing: one line on stderr, nothing on stdout, and
# status 75, which the runner logs as skipped (load). Only load is 75. A
# source that fails fails the run, whatever its status: a run that left its
# finding out would drop its hash, and the next one would send it again as new.
#
# lib/routine/source/<source>.sh defines issues_source_<source> REPO LABEL
# [ARGV...], ARGV being source_command. It prints the repo's ready issues with
# the label, one JSON object a line:
#   {id, title, priority, url, created}
# id is the job's in that repo, a beads id or trail:N, as a card and a dispatch
# take it; priority a number, the lowest first, or null; url a string or null;
# created an ISO time or null. On failure, status 1 and why on stderr.
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
# shellcheck source=lib/slots.sh
source "$lib/slots.sh"
# The ledger and the queue run this checkout's bercail, not another on PATH.
[[ ! -x "$lib/../bin/bercail" ]] || export BERCAIL_SELF="$lib/../bin/bercail"

LOAD=75
# With this many desks working, the person has enough to review.
WORKING=2
NOT_NOW=$((7 * 86400))
# Nobody waits on a routine: bd and the queue get well past what a call takes
# under load (bercail-xtdl).
# shellcheck disable=SC2034 # read by _shep_bd and shep_queue
SHEP_BD_WAIT=10 SHEP_QUEUE_WAIT="${BERCAIL_SHEP_QUEUE_WAIT:-30}"

name="${1:?usage: issues.sh <routine name>}"

# A time as RFC 3339 writes it, in epoch seconds: bd's, the ledger's, a source's.
# An offset or a fraction would misplace it in an order by its text.
EPOCH='def epoch: (capture("^(?<d>[0-9]{4}-[0-9]{2}-[0-9]{2})[Tt ](?<t>[0-9]{2}:[0-9]{2}:[0-9]{2})(?<f>\\.[0-9]+)?(?<z>[Zz]|[+-][0-9]{2}:[0-9]{2})$")
      // error("not an RFC 3339 time"))
  | ("\(.d)T\(.t)Z" | fromdateiso8601) + (.f // "0" | tonumber)
    - (if .z | test("^[Zz]$") then 0 else (.z[:1] + "1" | tonumber) * ((.z[1:3] | tonumber) * 3600 + (.z[4:] | tonumber) * 60) end);'

_source_failed() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

# Under load: why, in one line, and nothing offered.
_load() {
  printf '%s\n' "$*" >&2
  exit "$LOAD"
}

entry="$(routine_entry "$name" --valid)" || exit 1
repo="$(jq -r .repo <<<"$entry")" label="$(jq -r .label <<<"$entry")" source="$(jq -r .source <<<"$entry")"
mapfile -d '' -t argv < <(jq -j '.source_command // [] | .[] | . + "\u0000"' <<<"$entry")
[[ "$repo" != \~/* ]] || repo="$HOME/${repo#\~/}"
[[ "${argv[0]:-}" != \~/* ]] || argv[0]="$HOME/${argv[0]#\~/}"
main="$(_shep_main_of "$repo")" || _source_failed "$repo is not a git checkout; fix repo in [routine.$name] of $BERCAIL_USER_CONFIG"
# The repo as a card's target names it: its shared git dir.
common="$(cd "$(git -C "$main" rev-parse --path-format=absolute --git-common-dir)" && pwd -P)" \
  || _source_failed "git could not name the git dir of $main"
# shellcheck source=/dev/null
source "$lib/routine/source/$source.sh"
now="$(_routine_now)"

desks="$(_shep_desks_json)" || _source_failed "hc did not list the desks"
working="$(jq -r --argjson n "$WORKING" '[.[] | select(.state == "working" and (.bg | not)) | .address]
  | select(length >= $n) | "\(length) desks are working (\(join(", ")))"' <<<"$desks")"
[[ -z "$working" ]] || _load "$working"

# Its cards the person answered or Shep withdrew, as {issue, token, said, at}:
# said is the choice, or "withdrawn"; at, epoch seconds.
cards="$(shep_question json 2>/dev/null | jq -ce --arg repo "$common" --arg topic "routine:$name" "$EPOCH"'
  [.questions[] | select(.kind == "planning" and .target.repo == $repo and .target.topic == $topic and .target.issue != null)
    | {issue: .target.issue, token: "\(.id)@\(.revision)"}
      + if .status == "answered" then {said: .answer.choice, at: (.answer.at | epoch)}
        elif .status == "withdrawn" then {said: "withdrawn", at: (.withdrawal.at | epoch)}
        else empty end]' 2>/dev/null)" \
  || _source_failed "the question ledger could not be read (bercail shep questions --json --all)"

# A manual desk can take the job before a Start is answered. Only a dispatch
# made with that card's token, to that desk, occupies the routine's slot.
started="$(jq -r --slurpfile cards <(printf '%s' "$cards") --arg main "$main" '
  .[] | select(.repo == $main or .repo == "") as $d | $cards[0][]
  | select(.said == "Start" and .issue == $d.issue) | [$d.address, .issue, .token] | @tsv' <<<"$desks")"
while IFS=$'\t' read -r desk issue token; do
  [[ -n "$desk" ]] || continue
  if _shep_is_trail "$issue"; then
    creation="$(_shep_job show "$issue" --repo "$main" --json | jq -c .record.creation)"
  else
    creation="$(_shep_bd_issue "$main" "$issue" | jq -c .metadata.bercail_task.creation)"
  fi || _source_failed "could not check which dispatch started $desk on $issue"
  if jq -e --arg t "$token" --arg d "$desk" '.id == $t and .result.desk == $d' <<<"$creation" >/dev/null; then
    _load "desk $desk on $issue, which it offered, is still open"
  fi
done <<<"$started"

# A test run waiting for a slot (lib/slots.sh): its file, while its pid lives.
for file in "$(slot_dir)"/wait.*; do
  [[ -f "$file" ]] && kill -0 "${file##*.}" 2>/dev/null || continue
  _load "a test run waits for a slot"
done

queue="$(shep_queue --repo "$main" --json 2>/dev/null)" && jq -e '.repo | type == "object"' <<<"$queue" >/dev/null 2>&1 \
  || _source_failed "the review queue of $main could not be read (bercail shep queue --repo $main --json)"
over="$(jq -r '.repo | select(.over) | "\(.lines) lines wait on review in \(.path), over its budget of \(.budget)"' <<<"$queue")"
[[ -z "$over" ]] || _load "$over"

found="$("issues_source_$source" "$main" "$label" "${argv[@]}")" || exit 1
issues="$(jq -Rsc "$EPOCH"'
  def kind($f; $t; $n): if .[$f] == null or (.[$f] | type) == $t then . else error("line \($n): \($f) must be a \($t)") end;
  [split("\n") | to_entries[] | select(.value | test("\\S")) | (.key + 1) as $n
    | (try (.value | fromjson) catch null)
    | if type != "object" then error("line \($n) is not a JSON object")
      elif (.id | type) != "string" or (.id | test("^([A-Za-z0-9][A-Za-z0-9._-]*|trail:[1-9][0-9]{0,8})$") | not)
      then error("line \($n) has no id that is a beads id or trail:N")
      elif (.title | type) != "string" then error("line \($n) has no title")
      else kind("priority"; "number"; $n) | kind("url"; "string"; $n) | kind("created"; "string"; $n)
        | {id, title, priority, url, created,
           at: (.created | if . == null then null else (try epoch catch error("line \($n): created must be an RFC 3339 time")) end)} end]' \
  <<<"$found" 2>&1)" \
  || _source_failed "the $source source printed bad output: $(sed -n 's/^jq: error ([^)]*): //p' <<<"$issues" | head -n 1)"

# The issues with a handoff record in this repo: a line of handoffs.jsonl on
# one of the repo's checkouts, or, once its checkout is gone, one that names
# this repo or none (as dispatch reads them, lib/shep-task.ts).
handed=()
records="$(notify_handoffs_file)"
if [[ -e "$records" ]]; then
  rows="$(jq -nRr --slurpfile issues <(printf '%s' "$issues") 'inputs | select(length > 0) | fromjson | select(type == "object" and (.path | type) == "string")
    | select(.issue as $i | any($issues[0][]; .id == $i)) | [.issue, .path, .branch // "", .repo // ""] | join("\u001f")' "$records")" \
    || _source_failed "could not read $records"
  while IFS=$'\x1f' read -r issue path branch from; do
    [[ -n "$issue" ]] || continue
    of="$(_shep_main_of "$path" "$branch")" || of="$from"
    [[ -n "$of" && "$of" != "$main" ]] || handed+=("$issue")
  done <<<"$rows"
fi

# The pick: none with a desk on it, a handoff record, a Skip, or a Not now
# under 7 days old; then the highest priority, then the oldest. An earlier
# card that no longer holds it back is named in its detail, so the finding
# reads as changed and is sent again: a Not now past its 7 days, a Start that
# started no desk, a card withdrawn.
jq -c --slurpfile desks <(printf '%s' "$desks") --slurpfile cards <(printf '%s' "$cards") --arg main "$main" \
  --argjson now "$now" --argjson wait "$NOT_NOW" --args '
  def held: .said == "Skip this issue" or (.said == "Not now" and .at + $wait > $now);
  [.[] | .id as $id
    | select(any($desks[0][]; .issue == $id and (.repo == $main or .repo == "")) | not)
    | select($ARGS.positional | index($id) | not)
    | . + {cards: [$cards[0][] | select(.issue == $id)]}
    | select(any(.cards[]; held) | not)]
  | sort_by([.priority // infinite, .at // infinite, .id]) | first // empty
  | (.cards | max_by(.at)) as $last
  | {key: "issue:\(.id)", title: "\(.id): \(.title | gsub("\\s+"; " "))",
     detail: ([([(.priority // empty | "P\(.)"), (.created // empty | "created \(.[:10])"), .url // empty] | join(", ")),
               ($last // empty | "asked before as \(.token): \(.said) on \(.at | todate | .[:10])")]
              | map(select(. != "")) | join("; ")),
     repo: $main, issue: .id}' "${handed[@]}" <<<"$issues"
