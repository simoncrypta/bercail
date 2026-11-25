#!/usr/bin/env bash
# shellcheck shell=bash
# The issues routine's command source, source = "command": your own query,
# source_command, run in the repo with nothing on stdin. It gets the repo and
# the label as BERCAIL_ROUTINE_REPO and BERCAIL_ROUTINE_LABEL, and prints only
# issues that have the label and are ready to start.
#
# Sourced by lib/routine/issues.sh, which defines the interface.

issues_source_command() {
  local repo="$1" label="$2" rc=0
  shift 2
  (cd "$repo" && BERCAIL_ROUTINE_REPO="$repo" BERCAIL_ROUTINE_LABEL="$label" exec "$@" </dev/null) || rc=$?
  ((rc == 0)) && return 0
  printf 'error: the source command %s failed (status %s)\n' "$1" "$rc" >&2
  return 1
}
