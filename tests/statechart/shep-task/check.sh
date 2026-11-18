#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../../.." && pwd)"
spec="$root/tests/statechart/shep-task"
base="$root/.bercail/statechart/shep-task"
mkdir -p "$base"
out="$(mktemp -d "$base/check.XXXXXX")"
checker="${STATECHART_CHECKER:-$HOME/.agents/skills/statechart/scripts/statechart-bstack}"
mkdir -p "$out"
"$checker" "$spec/TaskDelivery.tla" --config "$spec/full.cfg" --view "$spec/view.mjs" --out "$out/full"
for bug in replay stale; do
  rc=0
  "$checker" "$spec/TaskDelivery.tla" --config "$spec/$bug-bug.cfg" --view "$spec/view.mjs" --out "$out/$bug-bug" || rc=$?
  [[ "$rc" == 1 ]] || { echo "$bug plant did not break its rule (exit $rc)" >&2; exit 1; }
done
"$checker" graph "$spec/TaskDelivery.tla" "$spec/full.cfg" "$spec/graph.json"
(cd "$root" && sha256sum tests/statechart/shep-task/{TaskDelivery.tla,full.cfg,view.mjs,graph.json} config/pi/extensions/bercail-desk.ts >"$spec/sha256.txt")
