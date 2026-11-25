#!/usr/bin/env bash
# shellcheck shell=bash
# Prints what a unit run runs, one item a line: each tests/*.bats file, and
# `vitest` for the TypeScript tests (vp test). tests/run.sh runs them; CI asks
# first, to skip the setup of a shard with nothing to run.
#   --affected BASE  only what the change since BASE needs (affected, below)
#   --shard I/N      only the .bats files of shard I of N: longest first by
#                    tests/weights.tsv, each to the shard with the least so far
#   --vitest         only vitest
# The same tree gives every shard the same split, so each file runs in exactly
# one of them. A file missing from weights.tsv counts as the mean; a stale
# table only unbalances the shards.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Every item of the unit suite.
all_items() {
  printf '%s\n' tests/*.bats vitest
}

# Reviewed readers, including indirect CLI calls (e.g. a land runs cleanup).
# Don't guess from matching filenames: unknown paths and shared helpers need
# the full suite. A .bats file is a standalone suite, not a shared .bash file.
readers() {
  case "$1" in
    docs/config.md) printf '%s\n' tests/layout_config.bats tests/desk_mod.bats ;;
    docs/cli.md) printf '%s\n' tests/review_pr.bats ;;
    docs/keys.md) printf '%s\n' tests/spaces_mod.bats ;;
    docs/shep.md) printf '%s\n' vitest ;;
    docs/*.md | AGENTS.md | LICENSE) ;;
    tests/*.bats)
      [[ "$1" =~ ^tests/[[:alnum:]_]+\.bats$ && -f "$1" ]] || return 1
      printf '%s\n' "$1" ;;
    tests/*.test.ts) [[ -f "$1" ]] || return 1; printf '%s\n' vitest ;;
    skills/handoff/scripts/handoff-spawn)
      printf '%s\n' tests/{bstack,handoff_beads,handoff_spawn,skills_deploy,usage_limit_reason,worktrunk_live}.bats ;;
    skills/handoff/SKILL.md) printf '%s\n' tests/{doctor_stale,skills_deploy}.bats ;;
    lib/routine/cleanup.sh | lib/routine/deps.sh | lib/routine/mistakes.sh | lib/routine/rules.sh)
      local name="${1##*/}"
      printf '%s\n' tests/routine.bats "tests/routine_${name%.sh}.bats" ;;
    lib/cleanup.sh)
      printf '%s\n' tests/{cleanup,routine_cleanup,shep_task,trail_jobs,land_card,land_card_stops}.bats ;;
    lib/shep-task.ts) printf '%s\n' tests/{shep,shep_task,trail_jobs}.bats vitest ;;
    lib/shep-context.sh) printf '%s\n' tests/{shep,shep_context,todo,trail_jobs,routine_rules,routine_mistakes,routine_cleanup,routine_deps}.bats vitest ;;
    shep/SHEP.md | shep/pi/compaction.ts) printf '%s\n' tests/shep.bats vitest ;;
    *) return 1 ;;
  esac
}

# What the change since BASE (committed, staged, unstaged or new; both sides
# of a rename) needs: the readers of each changed path, and tests/suite.bats
# always. Everything, when the base is unknown or a path has no entry in
# readers. CI runs this on a branch; master and the nightly run run it all.
affected() {
  local base="$1" since path diff new
  local -a changed
  if ! since="$(git merge-base "$base" HEAD 2>/dev/null)"; then
    printf 'tests/plan.sh: no merge base with %s; running everything\n' "$base" >&2
    all_items
    return
  fi
  # A git that fails would read as no change: everything, not the smoke file.
  if ! diff="$(git diff --no-renames --name-only "$since" --)" || ! new="$(git ls-files -o --exclude-standard)"; then
    printf 'tests/plan.sh: git could not list the change since %s; running everything\n' "$base" >&2
    all_items
    return
  fi
  mapfile -t changed < <(printf '%s\n%s\n' "$diff" "$new" | grep . | sort -u)
  {
    printf 'tests/suite.bats\n'
    for path in ${changed[@]+"${changed[@]}"}; do
      readers "$path" || { all_items; return; }
    done
  } | sort -u
}

# Shard I of N of the items on stdin, longest first: bats starts the files in
# that order, so a long test does not start last.
shard() {
  local i="$1" n="$2"
  awk -v OFS='\t' 'BEGIN {
      while ((getline line <"tests/weights.tsv") > 0)
        if (line !~ /^#/ && split(line, f, "\t") == 2) { w[f[1]] = f[2]; sum += f[2]; known++ }
    }
    { print ($0 in w ? w[$0] : (known ? sum / known : 1)), $0 }' |
    sort -t$'\t' -k1,1gr -k2,2 |
    awk -F'\t' -v i="$i" -v n="$n" '{
      best = 1
      for (s = 2; s <= n; s++) if (load[s] < load[best]) best = s
      load[best] += $1
      if (best == i) print $2
    }'
}

base="" part="" only=""
while (($#)); do
  case "$1" in
    --affected) base="${2:?--affected needs a base, such as origin/master}"; shift 2 ;;
    --shard) part="${2:?--shard needs I/N}"; shift 2 ;;
    --vitest) only=vitest; shift ;;
    *) printf 'tests/plan.sh: unknown option %s\n' "$1" >&2; exit 2 ;;
  esac
done
if [[ -n "$part" ]]; then
  [[ "$part" =~ ^([1-9][0-9]*)/([1-9][0-9]*)$ ]] && ((BASH_REMATCH[1] <= BASH_REMATCH[2])) ||
    { printf 'tests/plan.sh: --shard takes I/N with 1 <= I <= N, not %s\n' "$part" >&2; exit 2; }
  [[ -z "$only" ]] || { printf 'tests/plan.sh: --shard picks .bats files and --vitest none; give one\n' >&2; exit 2; }
  only=bats i="${BASH_REMATCH[1]}" n="${BASH_REMATCH[2]}"
fi
if [[ -n "$base" ]]; then affected "$base"; else all_items; fi |
  case "$only" in
    bats) { grep -v '^vitest$' || true; } | shard "$i" "$n" ;;
    vitest) grep -x vitest || true ;;
    *) cat ;;
  esac
