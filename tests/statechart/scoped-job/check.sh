#!/usr/bin/env bash
# TLC checks plus its complete bounded graph for the real QuestionStore replay.
# No installs. Evidence goes outside the checkout; only reproducible artifacts stay.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
statechart=../../../skills/statechart/scripts/statechart-bstack
root="${MODEL_OUT:-/tmp/bercail-qsoa-build/model}"
mkdir -p "$root"
out="$(mktemp -d "$root/run.XXXXXX")"
printf 'TLC evidence: %s\n' "$out"
expect=(
  "full:holds"
  "replay:holds"
  "bug-ingress:SupportedIngressOnly"
  "bug-stale-review:FreshCandidateReview"
  "bug-replay:NoAutomaticReplay"
)
for pair in "${expect[@]}"; do
  cfg="${pair%%:*}" want="${pair#*:}" code=0
  "$statechart" ScopedJob.tla --config "$cfg.cfg" --view view.mjs --out "$out/$cfg" >"$out/$cfg.log" 2>&1 || code=$?
  if [[ ! -f "$out/$cfg/report.md" ]]; then
    printf '%s: no TLC report (exit %s)\n' "$cfg" "$code" >&2
    tail -30 "$out/$cfg.log" >&2
    exit 1
  fi
  broke="$(sed -n 's/^## \(.*\) breaks$/\1/p' "$out/$cfg/report.md" | sort | xargs)"
  if [[ "$want" == holds ]]; then
    [[ "$code" -eq 0 && -z "$broke" ]] || { printf '%s: FAIL (exit %s, breaks %s)\n' "$cfg" "$code" "$broke"; tail -20 "$out/$cfg.log"; exit 1; }
  else
    [[ "$code" -eq 1 && "$broke" == "$want" ]] || { printf '%s: FAIL (exit %s, breaks %s, expected %s)\n' "$cfg" "$code" "$broke" "$want"; tail -20 "$out/$cfg.log"; exit 1; }
  fi
  printf '%-24s %s\n' "$cfg" "$want"
done
"$statechart" graph ScopedJob.tla replay.cfg graph.json
sha256sum ScopedJob.tla ./*.cfg view.mjs graph.json >sha256sums
