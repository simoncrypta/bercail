#!/usr/bin/env bash
# Checks ShepInbox.tla with TLC in every config, and writes what the repo keeps:
# chart/ (Simon's chart, from chart.cfg), graph.json (the graph
# tests/shep_inbox_statechart.test.ts replays on inbox.ts) and sha256sums (what
# they were made from; that test fails when they are stale). Needs TLC and Java:
# [bstack] statechart = true, or TLA2TOOLS and JAVA. Run it after any change here.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
statechart=../../../skills/statechart/scripts/statechart-bstack
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Each config, what TLC must say: holds, or the rules it must break. A planted
# bug that breaks nothing would prove nothing.
expect=(
  "chart:holds"
  "replay:holds"
  "full:holds"
  "bug-source-after-claim:OneReportPerFinish"
  "bug-claimed-only:NeverLost"
  "bug-no-lock:OneConsumer SavedOnce ShownAgainOnlyAfterLostReply"
)
bad=0
for pair in "${expect[@]}"; do
  cfg="${pair%%:*}" want="${pair#*:}" code=0
  "$statechart" ShepInbox.tla --config "$cfg.cfg" --view view.mjs --out "$tmp/$cfg" >"$tmp/$cfg.log" 2>&1 || code=$?
  broke="$(sed -n 's/^## \(.*\) breaks$/\1/p' "$tmp/$cfg/report.md" 2>/dev/null | sort | xargs)"
  if [[ "$want" == holds ]]; then
    [[ "$code" -eq 0 && -z "$broke" ]] && result=ok || result="FAIL (exit $code, breaks: ${broke:-nothing})"
  else
    [[ "$code" -eq 1 && "$broke" == "$(tr ' ' '\n' <<<"$want" | sort | xargs)" ]] \
      && result=ok || result="FAIL (exit $code, breaks: ${broke:-nothing}; want $want)"
  fi
  printf '%-24s %-58s %s\n' "$cfg" "$want" "$result"
  [[ "$result" == ok ]] || { bad=1; tail -5 "$tmp/$cfg.log" >&2; }
done
((bad == 0)) || exit 1

rm -rf chart
mkdir chart
cp "$tmp/chart/report.md" "$tmp/chart/chart.mmd" "$tmp/chart/chart.pi.md" chart/
"$statechart" graph ShepInbox.tla replay.cfg graph.json
sha256sum ShepInbox.tla ./*.cfg view.mjs >sha256sums
