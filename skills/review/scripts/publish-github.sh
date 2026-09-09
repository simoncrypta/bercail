#!/usr/bin/env bash
# Post tuicr user comments as one GitHub PR review. Never posts agent comments.
# Exit 0: posted (or dry-run). Exit 2: usage / no session / no PR / nothing to post.
set -euo pipefail

TUICR_BIN="${TUICR_BIN:-tuicr}"
GH_BIN="${GH_BIN:-gh}"
REPO="."
EVENT="COMMENT"
BODY=""
DRY_RUN=0

usage() {
  printf 'usage: publish-github.sh --repo <path> [--event comment|approve|request-changes] [--body <text>] [--dry-run]\n' >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      [[ $# -ge 2 ]] || usage
      REPO="$2"
      shift 2
      ;;
    --event)
      [[ $# -ge 2 ]] || usage
      case "$2" in
        comment|COMMENT) EVENT="COMMENT" ;;
        approve|APPROVE) EVENT="APPROVE" ;;
        request-changes|REQUEST_CHANGES|request_changes) EVENT="REQUEST_CHANGES" ;;
        *) usage ;;
      esac
      shift 2
      ;;
    --body)
      [[ $# -ge 2 ]] || usage
      BODY="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      usage
      ;;
  esac
done

cd "$REPO"

if ! command -v "$TUICR_BIN" >/dev/null 2>&1; then
  printf 'publish-github: tuicr not found\n' >&2
  exit 2
fi
if ! command -v "$GH_BIN" >/dev/null 2>&1; then
  printf 'publish-github: gh not found\n' >&2
  exit 2
fi

list_out=""
list_rc=0
set +e
list_out="$("$TUICR_BIN" review list --repo . 2>/dev/null)"
list_rc=$?
set -e
if [[ "$list_rc" -ne 0 ]]; then
  printf 'publish-github: no tuicr session\n' >&2
  exit 2
fi

slug="$(printf '%s' "$list_out" | jq -r '
  (if type == "array" then . else [] end) as $all
  | ($all | map(select(.active == true)) | first)
    // ($all | map(select(.kind == "pr")) | first)
    // ($all | first)
  | .slug // empty
')"
if [[ -z "$slug" ]]; then
  printf 'publish-github: no tuicr session\n' >&2
  exit 2
fi

comments_out=""
set +e
comments_out="$("$TUICR_BIN" review comments --repo . --session "$slug" 2>/dev/null)"
set -e

comments="$(printf '%s' "$comments_out" | jq -c '
  def is_agent:
    ((.author // .username // "user") | ascii_downcase) as $a
    | $a == "cursor-agent" or $a == "cursor" or $a == "codex"
      or $a == "claude" or $a == "claude-code" or $a == "grok"
      or $a == "gpt" or $a == "copilot" or $a == "agent"
      or ($a | startswith("cursor-"))
      or ($a | startswith("claude"));
  def items: if type == "array" then . else (.comments // []) end;
  [
    items[]
    | select(is_agent | not)
    | {
        path: (.path // .filePath // .file // ""),
        line: (.start_line // .newLine // .new_line // .line // null),
        oldLine: (.oldLine // .old_line // null),
        sideRaw: (.side // "new"),
        body: (.content // .summary // .body // .text // "")
      }
    | select(.path != "" and .body != "")
    | if .line != null then
        {path, line: (.line | tonumber), side: (if .sideRaw == "old" then "LEFT" else "RIGHT" end), body}
      elif .oldLine != null then
        {path, line: (.oldLine | tonumber), side: "LEFT", body}
      else
        empty
      end
  ]
')"

if [[ "$(printf '%s' "$comments" | jq 'length')" -eq 0 ]]; then
  printf 'publish-github: no user comments with a file and line to post\n' >&2
  exit 2
fi

pr_json=""
set +e
pr_json="$("$GH_BIN" pr view --json number,url,headRefOid 2>/dev/null)"
set -e
number="$(printf '%s' "$pr_json" | jq -r '.number // empty')"
sha="$(printf '%s' "$pr_json" | jq -r '.headRefOid // empty')"
url="$(printf '%s' "$pr_json" | jq -r '.url // empty')"
if [[ -z "$number" || -z "$sha" ]]; then
  printf 'publish-github: no pull request for this branch (gh pr create first)\n' >&2
  exit 2
fi

payload="$(jq -n \
  --arg commit "$sha" \
  --arg event "$EVENT" \
  --arg body "$BODY" \
  --argjson comments "$comments" \
  '{commit_id: $commit, event: $event, comments: $comments}
   + (if $body == "" then {} else {body: $body} end)')"

if [[ "$DRY_RUN" -eq 1 ]]; then
  printf '%s\n' "$payload"
  exit 0
fi

post_review() {
  local event="$1"
  printf '%s' "$payload" | jq --arg event "$event" '.event = $event' \
    | "$GH_BIN" api "repos/{owner}/{repo}/pulls/${number}/reviews" --method POST --input -
}

resp=""
rc=0
set +e
resp="$(post_review "$EVENT" 2>&1)"
rc=$?
set -e
if [[ "$rc" -ne 0 && "$EVENT" != "COMMENT" ]]; then
  # Authors cannot APPROVE / REQUEST_CHANGES on their own PR.
  set +e
  resp="$(post_review COMMENT 2>&1)"
  rc=$?
  set -e
  EVENT="COMMENT"
fi
if [[ "$rc" -ne 0 ]]; then
  printf 'publish-github: GitHub rejected the review\n%s\n' "$resp" >&2
  exit 2
fi

html="$(printf '%s' "$resp" | jq -r '.html_url // empty')"
printf 'published %s user comment(s) to %s (%s)\n' \
  "$(printf '%s' "$comments" | jq 'length')" \
  "${html:-$url}" \
  "$EVENT"
