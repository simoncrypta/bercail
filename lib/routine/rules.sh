#!/usr/bin/env bash
# shellcheck shell=bash
# The rules routine, run = "rules" (docs/routines.md#the-rules-routine). It
# only reads: Shep's standing rules, hc's terminals, and the question ledger.
# It prints a finding a line for each rule that no longer applies, with why;
# Shep asks before it forgets any (shep/SHEP.md). It keeps no state.
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

_source_failed() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

now="$(_routine_now)"
printf -v today '%(%Y-%m-%d)T' "$now"
printf -v hour '%(%H)T' "$now"

# The desks hc has, and each card whose approval was claimed: by a push, by a
# guard card's worker, or by a land chain.
desks="$(_shep_hc ls --json | jq -ce '[.terminals[].address]' 2>/dev/null)" \
  || _source_failed "hc did not list its terminals (hc ls --json)"
claims="$(shep_question json 2>/dev/null \
  | jq -ce '[.questions[] | {id, revision, at: (.pushed.at // .guardClaim.at // .landing.claim.at)} | select(.at != null)]' 2>/dev/null)" \
  || _source_failed "the question ledger could not be read (bercail shep questions --json --all)"

# The rule lines, as _shep_rules lists them, but a file that is there and
# cannot be read fails the run: read as no rules, it would drop every finding.
prefs="$(shep_prefs_file)"
lines=""
if [[ -e "$prefs" ]]; then
  lines="$(grep '^- ' "$prefs" 2>/dev/null)" || (($? == 1)) || _source_failed "could not read $prefs"
fi

# Each rule as "KEY<TAB>DATE [SCOPE] RULE", in the order bercail shep list
# numbers them. The key is a hash of the rule's text, never its number: a
# number shifts when an earlier rule is forgotten.
rules=""
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  line="${line#- }"
  hash="$(printf '%s' "$line" | sha256sum)" || _source_failed "could not hash a rule (sha256sum)"
  rules+="${hash:0:12}"$'\t'"$line"$'\n'
done <<<"$lines"

jq -Rnc --arg now "${today}T$hour" --slurpfile desks <(printf '%s' "$desks") --slurpfile claims <(printf '%s' "$claims") '
  def D: "[0-9]{4}-[0-9]{2}-[0-9]{2}";
  def dates($re; $flags): [match($re; $flags) | .captures[0].string];
  def listed: if length < 2 then join("") else (.[:-1] | join(", ")) + " and " + .[-1] end;
  def distinct: reduce .[] as $x ([]; if any(.[]; . == $x) then . else . + [$x] end);
  def stop: ["the", "and", "for", "that", "this", "with", "from", "when", "then", "than", "are", "was", "has",
    "have", "his", "her", "its", "not", "but", "can", "may", "any", "all", "each", "into", "also", "too", "you",
    "your", "they", "them", "what", "which", "who", "will", "would", "should", "shep", "simon"];
  def words: ascii_downcase | [scan("[a-z0-9]+") | select(length >= 3 and (test("^[0-9]+$") | not))] | unique - stop;

  # When each day or night the rule is for ends, as "YYYY-MM-DDTHH" on the
  # local clock: a night ends at noon the next day. A date the rule gives wins
  # over tonight or today, which count from the day it was remembered. A bare
  # date is no cue, and neither is a today that starts something.
  def cues: . as $r | .rule
    | ((dates("\\bnight of (\(D))(?![0-9])"; "gi") + dates("(?:^|[^\\w-])(\(D))(?:/[0-9]{1,2})? night\\b"; "gi")
        | map({night: true, date: .}))
       + (dates("\\bon (\(D))(?![0-9])"; "gi") + dates("^(\(D))(?::| \\()"; "") | map({night: false, date: .})))
    | if length > 0 then .
      else [(select($r.rule | test("\\b(tonight|going to sleep|during the night|for the night)\\b"; "i")) | {night: true, date: $r.date}),
            (select($r.rule | test("\\b(for today|today only|just today)\\b"; "i")) | {night: false, date: $r.date})] end
    # A date that is none, 2026-13-45, is no cue.
    | map(. + {end: ((try (.date + "T00:00:00Z" | fromdateiso8601 + 86400 | strftime("%Y-%m-%d")) catch null) as $next
        | if $next == null then null elif .night then $next + "T12" else $next + "T00" end)})
    | map(select(.end != null));
  # Past once every day and night it is for is.
  def past: cues | select(length > 0 and all(.[]; .end <= $now)) | max_by(.end)
    | if .night then "for the night of \(.date), now past" else "for \(.date), now past" end;

  # The desks it is for: its scope, and each id beside the word desk. A rule
  # that also names a desk on another machine, vps/t1aa, is not looked up:
  # hc may not list the desks of that machine, so it may be live.
  def named: select(.rule | test("\\bdesks?\\b"; "i") and test("/t[0-9][0-9a-z]*\\b"; "i") | not)
    | [(.scope | select(test("^t[0-9][0-9a-z]*$"; "i"))),
      (.rule | select(test("\\bdesks?\\b"; "i")) | match("(?:^|[^\\w/-])(t[0-9][0-9a-z]*)\\b"; "gi") | .captures[0].string)]
    | map(ascii_downcase) | distinct;
  def gone: named | select(length > 0 and all(.[]; IN($desks[0][]) | not))
    | "for desk\(if length > 1 then "s" else "" end) \(listed), which hc no longer has";

  # A permission for one use, and a card it names was claimed. "Once Q1@1 is
  # claimed, ..." is a condition, not one use.
  def used: .rule
    | select(test("\\bonce(?:$|[[:punct:]]| (?:only|on|for|per|more|again|without|as|and|or|to|in)\\b)|\\b(?:one-time|one time|single-use|a single)\\b"; "i"))
    | first(match("\\bQ([0-9]+)(?:@([0-9]+))?\\b"; "gi") | .captures as [$id, $rev]
        | $claims[0][] | select(.id == "Q" + $id.string and ($rev.string == null or (.revision | tostring) == $rev.string))
        | "names \(.id)@\(.revision), a once-only permission used on \(.at[:10])");

  [inputs | capture("^(?<key>[0-9a-f]{12})\t(?<line>.*)$")
    | . + (.line | capture("^(?<date>\(D)) \\[(?<scope>[^\\]]*)\\] (?<rule>.*)$"))
    | . + {reasons: [past, gone, used], words: (.rule | words), text: (.rule | ascii_downcase | rtrimstr("."))}]
  # Maybe covered by a later rule of its scope or of all: one that says the
  # same, or shares most of its words. That only names the pair: Shep judges.
  # From the last rule back, so the later rule is one that stays, with no
  # reason of its own.
  | reduce range(length - 1; -1; -1) as $i (.; .[$i] as $r
      | [.[$i + 1:][] | select(.reasons == [] and (.scope == $r.scope or .scope == "all"))
          | . + {shared: (.words - (.words - $r.words) | length)}
          | select(.text == $r.text or (.shared >= 4 and .shared * 5 >= 3 * ($r.words | length)))] as $later
      # The one sharing the most, and the earliest of those: sort_by keeps their order.
      | .[$i].reasons += ($later | sort_by(-.shared)[:1]
          | map("may be covered by a later rule of the same or wider scope: \(.line)")))
  # A line there twice has one key, and the runner refuses a key twice.
  | reduce (.[] | select(.reasons != [])) as $r ([]; if any(.[]; .key == $r.key) then . else . + [$r] end)
  | .[] | {key: "rules:\(.key)", title: (.reasons | join("; ") | (.[:1] | ascii_upcase) + .[1:]), detail: .line}' <<<"$rules"
