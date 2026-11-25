#!/usr/bin/env bash
# --check runs the branch selection, or Vitest when Bats needs all four shards.
# --shard I/N always plans the whole suite, never against a moving branch ref.
# The job installs the tools its tests need before running tests/run.sh.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
args=("$@") full=""
if [[ "${1:-}" == --check ]]; then
  args=()
  case "$GITHUB_EVENT_NAME:$GITHUB_REF" in
    pull_request:*) args=(--affected "origin/$GITHUB_BASE_REF") ;;
    # The land worker waits on this exact candidate before updating master.
    push:refs/heads/master | push:refs/heads/bercail-land/*) ;;
    push:refs/heads/*) args=(--affected origin/master) ;;
  esac
  # Assigned first: a plan that fails stops here, not in the comparison.
  items="$(bash tests/plan.sh ${args[@]+"${args[@]}"})"
  everything="$(bash tests/plan.sh)"
  [[ "$items" != "$everything" ]] || { args=(--vitest); items=vitest; full=1; }
else
  items="$(bash tests/plan.sh "$@")"
fi
printf 'tests/plan.sh %s:\n%s\n' "${args[*]}" "${items:-  nothing to run}"
[[ -z "$full" ]] || printf 'The whole suite: the shards run the .bats files.\n'
{
  printf 'args=%s\n' "${args[*]}"
  [[ -z "$items" ]] || printf 'run=1\n'
  ! grep -q '\.bats$' <<<"$items" || printf 'bats=1\n'
  ! grep -Fxq tests/handoff_beads.bats <<<"$items" || printf 'tools=github:gastownhall/beads@%s\n' "${BD_VERSION:?}"
  ! grep -Fxq tests/statechart.bats <<<"$items" || printf 'statechart=1\n'
  [[ -z "$full" ]] || printf 'full=1\n'
} >>"$GITHUB_OUTPUT"
if [[ ! -e ~/.config/bercail/config.toml ]]; then
  mkdir -p ~/.config/bercail
  printf '[tests]\nslots = 1\n' >~/.config/bercail/config.toml
fi
