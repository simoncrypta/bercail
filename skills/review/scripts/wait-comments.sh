#!/usr/bin/env bash
# Wait until tuicr has new human comments, the live session disappears, or timeout.
# Exit 0: print new comments JSON. Exit 2: no session. Exit 124: timeout.
set -euo pipefail

TUICR_BIN="${TUICR_BIN:-tuicr}"
REPO="."
TIMEOUT=600
INTERVAL="${WAIT_COMMENTS_POLL_SECONDS:-2}"

usage() {
  printf 'usage: wait-comments.sh --repo <path> [--timeout <seconds>]\n' >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      [[ $# -ge 2 ]] || usage
      REPO="$2"
      shift 2
      ;;
    --timeout)
      [[ $# -ge 2 ]] || usage
      TIMEOUT="$2"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      usage
      ;;
  esac
done

[[ "$TIMEOUT" =~ ^[0-9]+$ ]] || usage

is_agent_author_jq() {
  cat <<'JQ'
def is_agent:
  ((.author // .username // "user") | ascii_downcase) as $a
  | $a == "cursor-agent" or $a == "cursor" or $a == "codex"
    or $a == "claude" or $a == "claude-code" or $a == "grok"
    or $a == "gpt" or $a == "copilot" or $a == "agent"
    or ($a | startswith("cursor-"))
    or ($a | startswith("claude"));
JQ
}

comment_ids() {
  local json="$1"
  printf '%s' "$json" | jq -r '
    '"$(is_agent_author_jq)"'
    ((.comments // .) | if type == "array" then . else [] end)
    | .[]
    | select(is_agent | not)
    | (.id // .noteId // .commentId // empty)
  ' 2>/dev/null || true
}

list_sessions() {
  local out rc=0
  set +e
  out="$("$TUICR_BIN" review list --repo "$REPO" 2>/dev/null)"
  rc=$?
  set -e
  [[ "$rc" -eq 0 ]] || return 2
  printf '%s' "$out"
  return 0
}

active_slug() {
  local json="$1"
  printf '%s' "$json" | jq -r '
    (if type == "array" then . else [] end)
    | map(select(.active == true))
    | first
    | .slug // empty
  ' 2>/dev/null || true
}

list_comments() {
  local slug="$1" out rc=0
  set +e
  out="$("$TUICR_BIN" review comments --repo "$REPO" --session "$slug" 2>/dev/null)"
  rc=$?
  set -e
  [[ "$rc" -eq 0 ]] || return 2
  printf '%s' "$out" | jq '
    if type == "array" then {comments: .}
    elif type == "object" then .
    else {comments: []}
    end
  ' 2>/dev/null || printf '%s' '{"comments":[]}'
  return 0
}

ids_to_lines() {
  comment_ids "$1" | awk 'NF' | sort -u
}

new_ids_since() {
  local baseline="$1" current="$2"
  comm -13 <(printf '%s\n' "$baseline") <(printf '%s\n' "$current")
}

filter_comments() {
  local json="$1"
  shift
  local -a ids=("$@")
  local jq_ids
  jq_ids="$(printf '%s\n' "${ids[@]}" | jq -R . | jq -s .)"
  printf '%s' "$json" | jq --argjson ids "$jq_ids" '
    '"$(is_agent_author_jq)"'
    def items: (.comments // .) | if type == "array" then . else [] end;
    def cid: .id // .noteId // .commentId // "";
    {comments: [items[] | select(is_agent | not) | select(cid as $c | $ids | index($c))]}
  '
}

start="$SECONDS"
sessions=""
if ! sessions="$(list_sessions)"; then
  exit 2
fi
slug="$(active_slug "$sessions")"
[[ -n "$slug" ]] || exit 2

json=""
if ! json="$(list_comments "$slug")"; then
  exit 2
fi
baseline="$(ids_to_lines "$json")"

while (( SECONDS - start < TIMEOUT )); do
  sleep "$INTERVAL"
  if ! sessions="$(list_sessions)"; then
    exit 2
  fi
  slug="$(active_slug "$sessions")"
  [[ -n "$slug" ]] || exit 2
  if ! json="$(list_comments "$slug")"; then
    exit 2
  fi
  current="$(ids_to_lines "$json")"
  mapfile -t added < <(new_ids_since "$baseline" "$current")
  if ((${#added[@]})); then
    filter_comments "$json" "${added[@]}"
    printf '\n'
    exit 0
  fi
done

exit 124
