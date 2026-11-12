#!/usr/bin/env bash
# shellcheck shell=bash
# Pi can exit 0 after an error or aborted turn. The last assistant message_end,
# not a prior error followed by a successful retry, decides the result.
pi_turn_failed() {
  local log="$1"
  [[ -f "$log" ]] || return 1
  jq -e -s -R '
    [ split("\n")[] | fromjson? | select(type == "object" and .type == "message_end" and (.message.role == "assistant")) ]
    | last | . != null and (.message.stopReason | IN("error", "aborted"))
  ' "$log" >/dev/null 2>&1
}
