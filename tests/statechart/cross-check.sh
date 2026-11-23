#!/usr/bin/env bash
# Runs every config of each spec folder named (by default, each one beside this
# script) on tla-ts and on TLC 1.7.4, and fails when the two disagree: the exit
# code, report.md, the charts, and for a replay*.cfg the state graph. Only 0
# (holds) and 1 (breaks) are verdicts: any other exit on either side fails.
# tla-ts is the one lib/statechart's lockfile pins, installed here with npm ci,
# so a bump tests the new version. Run it on a tla-ts bump, on a change to
# statechart-bstack or its shim, and on a new spec that is the proof for a risky
# change (docs/development.md#statecharts). It needs npm, and JAVA (java 11 or
# later) and TLA2TOOLS (tla2tools.jar 1.7.4, checked by its sha256).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
statechart="$root/skills/statechart/scripts/statechart-bstack"
tlc_url=https://github.com/tlaplus/tlaplus/releases/download/v1.7.4/tla2tools.jar
tlc_sha256=936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88

jar="${TLA2TOOLS:-}" java="${JAVA:-}"
if [[ ! -r "$jar" || ! -x "$java" ]]; then
  echo "cross-check: set TLA2TOOLS to tla2tools.jar 1.7.4 ($tlc_url) and JAVA to java 11 or later" >&2
  exit 2
fi
jar="$(cd "$(dirname "$jar")" && pwd)/${jar##*/}"
java="$(cd "$(dirname "$java")" && pwd)/${java##*/}"
if command -v sha256sum >/dev/null; then sum="$(sha256sum "$jar")"; else sum="$(shasum -a 256 "$jar")"; fi
sum="${sum%% *}"
if [[ "$sum" != "$tlc_sha256" ]]; then
  echo "cross-check: $jar is not tla2tools.jar 1.7.4 (sha256 $sum). Fix: download $tlc_url" >&2
  exit 2
fi
(($#)) || set -- "$here"/*/
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cp "$root/lib/statechart/package.json" "$root/lib/statechart/package-lock.json" "$tmp/"
npm ci --prefix "$tmp" --ignore-scripts --omit=dev --no-audit --no-fund --no-update-notifier >"$tmp/npm.log" 2>&1 \
  || { cat "$tmp/npm.log" >&2; echo "cross-check: npm could not install lib/statechart's tla-ts" >&2; exit 2; }
tla_ts="$tmp/node_modules/tla-ts/dist/cli.js"
echo "tla-ts $(jq -r .version "$tmp/node_modules/tla-ts/package.json") against TLC 1.7.4 ($java)"

# ENGINE ARGS...: statechart-bstack on tla-ts or on TLC, from the spec's folder.
on() {
  local engine="$1"
  shift
  if [[ "$engine" == tlc ]]; then
    env -u TLA_TS TLA2TOOLS="$jar" JAVA="$java" "$statechart" "$@"
  else
    env -u TLA2TOOLS -u JAVA TLA_TS="$tla_ts" "$statechart" "$@"
  fi
}

bad=0 n=0
for dir in "$@"; do
  dir="${dir%/}"
  specs=("$dir"/*.tla)
  [[ ${#specs[@]} -eq 1 && -f "${specs[0]}" ]] || { echo "cross-check: $dir needs exactly one .tla" >&2; exit 2; }
  spec="${specs[0]##*/}" view=()
  [[ ! -f "$dir/view.mjs" ]] || view=(--view view.mjs)
  for cfg in "$dir"/*.cfg; do
    cfg="${cfg##*/}" name="${dir##*/}/${cfg%.cfg}"
    n=$((n + 1)) out="$tmp/$n" codes=() diffs=()
    for engine in tla-ts tlc; do
      code=0
      (cd "$dir" && on "$engine" "$spec" --config "$cfg" "${view[@]}" --out "$out.$engine") >"$out.$engine.log" 2>&1 || code=$?
      codes+=("$code")
      [[ "$code" == 0 || "$code" == 1 ]] || diffs+=("exit $code on $engine")
      [[ -f "$out.$engine/report.md" ]] || diffs+=("no report.md on $engine")
      if [[ "$cfg" == replay*.cfg ]]; then
        (cd "$dir" && on "$engine" graph "$spec" "$cfg" "$out.$engine.json") >>"$out.$engine.log" 2>&1 \
          && [[ -f "$out.$engine.json" ]] || diffs+=("no graph on $engine")
      fi
    done
    [[ "${codes[0]}" == "${codes[1]}" ]] || diffs+=("exit ${codes[0]}/${codes[1]}")
    for f in report.md chart.mmd chart.pi.md; do
      [[ -e "$out.tla-ts/$f" || -e "$out.tlc/$f" ]] || continue
      cmp -s "$out.tla-ts/$f" "$out.tlc/$f" || diffs+=("$f")
    done
    if [[ "$cfg" == replay*.cfg ]] && [[ -f "$out.tla-ts.json" || -f "$out.tlc.json" ]]; then
      cmp -s "$out.tla-ts.json" "$out.tlc.json" || diffs+=("graph")
    fi
    if ((${#diffs[@]})); then
      bad=1
      printf '%-36s differs: %s\n' "$name" "$(IFS=,; echo "${diffs[*]}")"
      tail -n 3 "$out.tla-ts.log" "$out.tlc.log" >&2 || true
    else
      printf '%-36s same (exit %s)\n' "$name" "${codes[0]}"
    fi
  done
done
((bad == 0))
