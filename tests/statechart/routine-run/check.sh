#!/usr/bin/env bash
# Checks RoutineRun.tla in every config (on tla-ts), and writes what the repo keeps:
# chart/ (Simon's chart, from chart.cfg) and sha256sums (what it was made from;
# tests/routine.bats fails when they are stale). tests/routine.bats has a case
# for each of the model's steps on lib/routine.sh. Needs tla-ts:
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
  "bug-NoLock:OneRunPerRoutine OneEventPerChange"
  "bug-NoCap:AtMostCap"
  "bug-StaleWrite:PauseSticks"
  "bug-LockInChild:LockOnlyWhileRunning"
)
bad=0
for pair in "${expect[@]}"; do
  cfg="${pair%%:*}" want="${pair#*:}" code=0
  "$statechart" RoutineRun.tla --config "$cfg.cfg" --view view.mjs --out "$tmp/$cfg" >"$tmp/$cfg.log" 2>&1 || code=$?
  broke="$(sed -n 's/^## \(.*\) breaks$/\1/p' "$tmp/$cfg/report.md" 2>/dev/null | sort | xargs)"
  if [[ "$want" == holds ]]; then
    [[ "$code" -eq 0 && -z "$broke" ]] && result=ok || result="FAIL (exit $code, breaks: ${broke:-nothing})"
  else
    [[ "$code" -eq 1 && "$broke" == "$(tr ' ' '\n' <<<"$want" | sort | xargs)" ]] \
      && result=ok || result="FAIL (exit $code, breaks: ${broke:-nothing}; want $want)"
  fi
  printf '%-18s %-44s %s\n' "$cfg" "$want" "$result"
  [[ "$result" == ok ]] || { bad=1; tail -5 "$tmp/$cfg.log" >&2; }
done
((bad == 0)) || exit 1

rm -rf chart
mkdir chart
cp "$tmp/chart/report.md" "$tmp/chart/chart.mmd" "$tmp/chart/chart.pi.md" chart/
sha256sum RoutineRun.tla ./*.cfg view.mjs >sha256sums
