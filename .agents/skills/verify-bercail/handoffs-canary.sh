#!/usr/bin/env bash
# The suite must not write the real handoff log. Other desks may, during the run.
# usage: handoffs-canary.sh LOG BEFORE ROOT ADDED
# BEFORE is a copy of LOG from before the run, and ROOT the run's TMPDIR. Passes
# when LOG still starts with BEFORE byte for byte and no line added since names
# a path under ROOT: those came from a test. A line naming any other path is
# another desk's spawn. Every added line goes to ADDED, for the reader.
set -uo pipefail

log="$1" before="$2" root="$3" added="$4"
[[ -f "$log" ]] || log=/dev/null
size="$(wc -c <"$before")"
if ! cmp -s -n "$size" "$before" "$log"; then
  printf 'handoffs-canary: lines already in the handoff log changed during the run\n' >&2
  exit 1
fi
tail -c "+$((size + 1))" "$log" >"$added"
[[ -s "$added" ]] || { rm -f "$added"; exit 0; }
if grep -qF -- "$root/" "$added"; then
  printf 'handoffs-canary: a test wrote the real handoff log (lines naming %s in %s)\n' "$root" "$added" >&2
  exit 1
fi
