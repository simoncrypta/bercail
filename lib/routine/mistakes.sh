#!/usr/bin/env bash
# shellcheck shell=bash
# The mistakes routine, run = "mistakes" (docs/routines.md#the-mistakes-routine).
# It only reads: the mistakes ledger, each known repo's beads issues, and the
# trails its entries name. It prints a finding a line for each group that grew
# since the last run with its fix missing or not holding; Shep files the issue
# (shep/SHEP.md). Its one write is routines/<name>/counts.json, each group's
# count, and never on a dry run.
#
# A source that fails fails the run, as in the cleanup routine.
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
# Nobody waits on a routine: bd gets well past the 3 seconds or more a call
# takes under load (bercail-xtdl).
# shellcheck disable=SC2034 # read by _shep_bd
SHEP_BD_WAIT=10

name="${1:?usage: mistakes.sh <routine name>}"

_source_failed() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

_shep_need_policy
list="$(shep_mistake list --json)" && jq -e 'type == "array"' <<<"$list" >/dev/null \
  || _source_failed "the mistakes ledger could not be read (bercail shep mistake list --json)"

# Every issue in each known repo with beads, and in each repo an entry names:
# a {repo, issues: {id: {status, labels, closed_at}}} line a repo, one bd list each.
issues="$(mktemp)" err="$(mktemp)"
trap 'rm -f "$issues" "$err"' EXIT
while IFS= read -r main; do
  [[ -d "$main/.beads" ]] || continue
  rc=0
  raw="$(cd "$main" && _shep_bd list --all --json --limit 0 --brief 2>/dev/null </dev/null)" || rc=$?
  ((rc == 0)) || _source_failed "bd could not list the issues of $main (status $rc)"
  jq -c --arg r "$main" '{repo: $r, issues: (map({key: .id, value: {status, labels: (.labels // []), closed_at}}) | from_entries)}' \
    <<<"$raw" >>"$issues" 2>/dev/null || _source_failed "bd listed the issues of $main as something other than JSON"
done < <({ _shep_repo_list | cut -f1; jq -r '.[] | select(.id) | .issues[].repo // empty' <<<"$list"; } | sort -u)

# Each trail an entry of a group names, as {repo: {trail: open}}. A trail
# Entire could not show may be open, so it fails the run.
trails='{}'
while IFS=$'\t' read -r main id; do
  rc=0
  raw="$(_shep_job show "$id" --repo "$main" --json 2>"$err" </dev/null)" || rc=$?
  ((rc == 0)) || _source_failed "could not read $id in $main (status $rc)$(tail -n 1 "$err" | sed 's/^/: /')"
  trails="$(jq -c --arg r "$main" --arg id "$id" --argjson t "$raw" \
    '.[$r][$id] = ($t.status != "closed" and $t.phase != "complete")' <<<"$trails")" \
    || _source_failed "bercail job show $id --repo $main printed something other than JSON"
done < <(jq -r '[.[] | select(.id) | .issues[] | select(.repo and (.id | startswith("trail:")))] | unique[] | [.repo, .id] | @tsv' <<<"$list")

# The counts the last run saw, once the runner kept what that run found: its
# state.json has that run's id as kept. Otherwise the counts that run started from.
dir="$(routine_dir)/$name"
was="$(jq -c 'if type == "object" then . else {} end' "$dir/counts.json" 2>/dev/null || printf '{}')"
kept="$(routine_state "$name" | jq -r '.kept // ""')" || _source_failed "could not read the runner's state of $name"
before="$(jq -c --arg kept "$kept" 'if $kept != "" and .run == $kept then .counts // {} else .before // {} end' <<<"$was")"

found="$(jq -c --slurpfile issues "$issues" --argjson trails "$trails" --argjson before "$before" '
  def epoch: sub("\\.[0-9]+"; "") | fromdateiso8601;
  def closed_at: .closed_at // "" | epoch? // 0;
  def times: "\(.) time\(if . == 1 then "" else "s" end)";
  def against: {process: "the process", tool: "a tool", conduct: "conduct"}[.] // .;
  # A beads id named with no repo is looked up in every repo; a trail with no
  # repo cannot be, so it may be open.
  def open: . as $i | if (.id | startswith("trail:")) then (if .repo then $trails[.repo][.id] else true end)
    else any($issues[] | select($i.repo == null or .repo == $i.repo) | .issues[$i.id].status; . != null and . != "closed") end;
  .[] | select(.id and .count > ($before[.id] // 0)) | .id as $g
  | [$issues[] | .repo as $r | .issues | to_entries[] | select(.value.labels | index("mistake:\($g)"))
      | {id: .key, repo: $r} + .value] as $fixes
  | select(all($fixes[]; .status == "closed") and all(.issues[]; open | not))
  | "\($g) \(.name) has happened \(.count | times), counts against \(.against | against)" as $head
  | (.keys | map("\(.key) \(.count | times)") | join(", ")) as $detail
  | if ($fixes | length) == 0 then select(.count >= 2) | {key: "mistake:\($g)", title: "\($head), and has no open issue", detail: $detail}
    else ($fixes | max_by(closed_at)) as $fix
      | [.keys[].entries[] | select((.at | epoch) > ($fix | closed_at))] as $after
      | select($after | length > 0)
      | {key: "mistake:\($g)", title: "\($head): \($after | length | times) since its fix \($fix.id) closed on \($fix.closed_at[0:10])",
         detail: $detail, repo: $fix.repo, issue: $fix.id} end' <<<"$list")"

if [[ "${BERCAIL_ROUTINE_DRY_RUN:-0}" != 1 ]]; then
  mkdir -p "$dir"
  _routine_write "$dir/counts.json" "$(jq -c --argjson before "$before" --arg run "${BERCAIL_ROUTINE_RUN:-}" '
    {run: $run, counts: (map(select(.id) | {(.id): .count}) | add // {}), before: $before}' <<<"$list")" \
    || _source_failed "could not write $dir/counts.json"
fi
[[ -z "$found" ]] || printf '%s\n' "$found"
