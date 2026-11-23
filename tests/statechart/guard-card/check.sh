#!/usr/bin/env bash
# Checks GuardCard.tla in every config (on tla-ts), and writes what the repo keeps:
# chart/ (Simon's chart, from chart.cfg) and sha256sums (what it was made from;
# tests/guard_ask.bats fails when they are stale). tests/guard_ask.bats has a case
# for each of the model's steps on the worker and the ledger. Needs tla-ts:
# [bstack] statechart = true, or TLA_TS. Run it after any change here.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
statechart=../../../skills/statechart/scripts/statechart-bstack
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Each config, what the checker must say: holds, or the rules it must break. A planted
# bug that breaks nothing would prove nothing.
expect=(
  "chart:holds"
  "full:holds"
  "bug-NoDeadlineCheck:RunsOnlyOnAllowOrSafeDefault"
  "bug-Upgrade:RunsOnlyOnAllowOrSafeDefault WaitsNeverDefaults"
  "bug-DefaultOverAnswer:EventSaysWhoAllowed RunsOnlyOnAllowOrSafeDefault YourPickStands"
  "bug-EarlyDefault:DefaultOnlyPastDeadline DefaultOnlyWatched RunsOnlyOnAllowOrSafeDefault"
  "bug-NoLastCheck:RunsOnlyOnAllowOrSafeDefault"
  "bug-Unwatched:DefaultOnlyWatched"
  "bug-OptInPublic:NoCardOnlyOptedInPrivate RunsOnlyOnAllowOrSafeDefault"
)
bad=0
for pair in "${expect[@]}"; do
  cfg="${pair%%:*}" want="${pair#*:}" code=0
  "$statechart" GuardCard.tla --config "$cfg.cfg" --view view.mjs --out "$tmp/$cfg" >"$tmp/$cfg.log" 2>&1 || code=$?
  broke="$(sed -n 's/^## \(.*\) breaks$/\1/p' "$tmp/$cfg/report.md" 2>/dev/null | sort | xargs)"
  if [[ "$want" == holds ]]; then
    [[ "$code" -eq 0 && -z "$broke" ]] && result=ok || result="FAIL (exit $code, breaks: ${broke:-nothing})"
  else
    [[ "$code" -eq 1 && "$broke" == "$(tr ' ' '\n' <<<"$want" | sort | xargs)" ]] \
      && result=ok || result="FAIL (exit $code, breaks: ${broke:-nothing}; want $want)"
  fi
  printf '%-22s %-72s %s\n' "$cfg" "$want" "$result"
  [[ "$result" == ok ]] || { bad=1; tail -5 "$tmp/$cfg.log" >&2; }
done
((bad == 0)) || exit 1

rm -rf chart
mkdir chart
cp "$tmp/chart/report.md" "$tmp/chart/chart.mmd" "$tmp/chart/chart.pi.md" chart/
sha256sum GuardCard.tla ./*.cfg view.mjs >sha256sums
