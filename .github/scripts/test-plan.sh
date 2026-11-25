#!/usr/bin/env bash
# What a CI test job runs: tests/plan.sh with the job's options, and on a
# branch or PR only what the change since its base needs (--affected). A push
# to master or a tag, the nightly run and a manual run test everything. Writes
# the step outputs `args`, for tests/run.sh, and `run` when there is something
# to run. Also gives the run every core: a runner holds one run, so it takes
# one test slot, unless it has a bercail config of its own.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
args=("$@")
case "$GITHUB_EVENT_NAME:$GITHUB_REF" in
  pull_request:*) args+=(--affected "origin/$GITHUB_BASE_REF") ;;
  push:refs/heads/master) ;;
  push:refs/heads/*) args+=(--affected origin/master) ;;
esac
items="$(bash tests/plan.sh "${args[@]}")"
printf 'tests/plan.sh %s:\n%s\n' "${args[*]}" "${items:-  nothing to run}"
{
  printf 'args=%s\n' "${args[*]}"
  [[ -z "$items" ]] || printf 'run=1\n'
} >>"$GITHUB_OUTPUT"
if [[ ! -e ~/.config/bercail/config.toml ]]; then
  mkdir -p ~/.config/bercail
  printf '[tests]\nslots = 1\n' >~/.config/bercail/config.toml
fi
