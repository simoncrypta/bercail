#!/usr/bin/env bash
# shellcheck shell=bash
# The deps routine, run = "deps" (docs/routines.md#the-deps-routine): the
# dependency tracker's open GitHub issues, read with gh issue list only.
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
# Nobody waits on a routine: bd gets well past the 3 seconds or more a call
# takes under load (bercail-xtdl).
# shellcheck disable=SC2034 # read by _shep_bd
SHEP_BD_WAIT=10

_source_failed() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

github="${BERCAIL_UPSTREAM#https://github.com/}"

# The person's bercail checkout: the one of Shep's repos whose origin is
# bercail's GitHub repo. Two would each hold their own beads, so a finding
# could not say which one links it.
_shep_need_policy
checkouts=()
while IFS=$'\t' read -r main _; do
  url="$(git -C "$main" remote get-url origin 2>/dev/null)" || continue
  url="${url%/}"
  url="${url%.git}"
  [[ "$url" == "https://github.com/$github" || "$url" == "git@github.com:$github" || "$url" == "ssh://git@github.com/$github" ]] \
    && checkouts+=("$main")
done < <(_shep_repo_list)
((${#checkouts[@]} > 0)) \
  || _source_failed "no bercail checkout among Shep's repos (bercail shep repos); add its path to $(shep_state_dir)/repos"
((${#checkouts[@]} == 1)) \
  || _source_failed "Shep knows ${#checkouts[@]} bercail checkouts (${checkouts[*]}); retire all but one, so its beads say which deps issues have a job"
checkout="${checkouts[0]}"
[[ -d "$checkout/.beads" ]] || _source_failed "$checkout has no beads, so no issue there can name a deps issue"

issues="$(gh issue list --repo "$github" --label deps --state open --limit 500 --json number,title,labels,url </dev/null)" \
  && jq -e 'type == "array"' <<<"$issues" >/dev/null 2>&1 \
  || _source_failed "gh did not list the open deps issues of $github (gh issue list --repo $github --label deps)"
beads="$(cd "$checkout" && _shep_bd list --all --json --limit 0 </dev/null 2>/dev/null)" \
  && jq -e 'type == "array"' <<<"$beads" >/dev/null 2>&1 \
  || _source_failed "bd did not list the issues in $checkout"

# One finding per deps:<name> label, the newest issue's when two have it. Its
# version is the title's last word; the tracker's own failing issue has none.
# A beads issue links it when its external ref is gh-<number> or the URL, or
# its title or description holds the URL not followed by a digit: issues/7 is
# not issues/72. A bare #71 or "tuicr 0.30.0" in prose does not: the issue
# that planned this routine reads so too.
jq -c --arg repo "$checkout" --slurpfile beads <(printf '%s' "$beads") '
  [.[] | . as $i | (.labels[].name | select(startswith("deps:"))) as $key | $i + {key: $key}]
  | group_by(.key) | map(max_by(.number))[]
  | .url as $url | "gh-\(.number)" as $ref
  | ([$beads[0][] | select(.external_ref == $ref or .external_ref == $url
        or ((.title + "\n" + (.description // "")) | split($url)[1:] | any(test("^[0-9]") | not)))
      | {id, closed: (.status == "closed")}] | sort_by(.closed)) as $linked
  | (.title | split(" ") | last) as $version
  | {key, title,
     detail: ([$url,
       (if .key == "deps:tracker" then empty else "version \($version)" end),
       (if $linked == [] then "no beads issue links it"
        else "linked by " + ($linked | map(.id + (if .closed then " (closed)" else " (open)" end)) | join(", ")) end)]
       | join("; ")),
     repo: $repo}
  + (if $linked == [] then {} else {issue: $linked[0].id} end)' <<<"$issues"
