#!/usr/bin/env bash
# shellcheck shell=bash
# The issues routine's beads source: the repo's ready issues with the label, as
# bd ready lists them, so none in progress, blocked or deferred. One a
# dispatch already recorded on (metadata.bercail_task) is left out.
#
# Sourced by lib/routine/issues.sh, which defines the interface.

issues_source_beads() {
  local repo="$1" label="$2" raw rc=0
  raw="$(cd "$repo" && _shep_bd ready --json --limit 0 --brief -l "$label" 2>/dev/null </dev/null)" || rc=$?
  if ((rc != 0)); then
    printf 'error: bd could not list the ready issues of %s (bd ready --json -l %s, status %s)\n' "$repo" "$label" "$rc" >&2
    return 1
  fi
  # One array, or it is not bd's answer; and of it only what is open and has the label.
  jq -sc --arg label "$label" 'if length == 1 and (.[0] | type) == "array" then .[0] else error("not one array") end
    | map(select(.status == "open" and (.labels // [] | index($label)) and .metadata.bercail_task == null)
        | {id, title, priority, url: null, created: .created_at}) | .[]' <<<"$raw" 2>/dev/null && return 0
  printf 'error: bd listed the ready issues of %s as something other than a JSON array of issues\n' "$repo" >&2
  return 1
}
