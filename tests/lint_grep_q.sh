#!/usr/bin/env bash
# shellcheck shell=bash
# Fails on `printf … | grep -q` (or echo, or grep -m) in the shell files named.
# Under pipefail, grep can exit at its first match before the writer is done;
# the writer dies of SIGPIPE and the pipeline fails about once in a thousand
# runs (ledger key pipefail-grep-q). Every file is checked, not only those that
# say pipefail: a file that sources lib/common.sh runs under it too.
# tests/lint.sh runs this on every tracked shell file.
set -euo pipefail

# printf or echo where a command starts, its arguments, a pipe, then a grep
# with -q, -m, --quiet, --silent or --max-count among its options.
re='(^|[;&|({!]|\b(if|then|do|elif|else|while|until)\b)[[:space:]]*(printf|echo)[[:space:]][^|;&]*\|[[:space:]]*grep([[:space:]]+-[[:alnum:]-]+)*[[:space:]]+(-[[:alnum:]]*[qm]|--quiet|--silent|--max-count)'

# grep exits 1 on no match, and 2 on a file it cannot read, which must fail.
hits="$(grep -nHE "$re" "$@")" || [[ $? -eq 1 ]]
hits="$(grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' <<<"$hits" || true)"
[[ -n "$hits" ]] || exit 0
printf '%s\n' "$hits" >&2
printf 'lint: printf or echo piped into grep -q or -m, above: grep can exit before printf is done, and under pipefail the SIGPIPE fails the pipeline. Use grep -q PATTERN <<<"$var", [[ ]], or case.\n' >&2
exit 1
