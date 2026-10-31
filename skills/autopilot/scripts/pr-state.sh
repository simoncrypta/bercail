#!/usr/bin/env bash
# One snapshot of a PR for autopilot: checks, unanswered review threads, merge
# state, and the next thing to do. --wait polls until that changes.
# Exit 0: snapshot printed. Exit 2: usage / gh missing / no PR. Exit 124: wait timed out (snapshot printed).
set -euo pipefail

GH_BIN="${GH_BIN:-gh}"
REPO="."
PR=""
WAIT=0
INTERVAL="${AUTOPILOT_POLL_SECONDS:-30}"

usage() {
  printf 'usage: pr-state.sh [--repo <path>] [--pr <number>] [--wait <seconds>]\n' >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      [[ $# -ge 2 ]] || usage
      REPO="$2"
      shift 2
      ;;
    --pr)
      [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]] || usage
      PR="$2"
      shift 2
      ;;
    --wait)
      [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]] || usage
      WAIT="$2"
      shift 2
      ;;
    *)
      usage
      ;;
  esac
done

cd "$REPO"

if ! command -v "$GH_BIN" >/dev/null 2>&1; then
  printf 'pr-state: gh not found\n' >&2
  exit 2
fi

THREADS_QUERY='query($owner: String!, $name: String!, $n: Int!) {
  viewer { login }
  repository(owner: $owner, name: $name) {
    pullRequest(number: $n) {
      reviewThreads(first: 100) {
        nodes {
          id isResolved isOutdated path line
          comments(last: 20) { nodes { author { login __typename } body url } }
        }
      }
    }
  }
}'

snapshot() {
  local pr_json checks_json threads_json owner name number
  pr_json="$("$GH_BIN" pr view ${PR:+"$PR"} \
    --json number,url,state,isDraft,headRefName,headRefOid,baseRefName,mergeable,mergeStateStatus,reviewDecision \
    2>/dev/null)" || return 2
  number="$(jq -r '.number // empty' <<<"$pr_json")"
  [[ -n "$number" ]] || return 2
  # https://github.com/OWNER/NAME/pull/N
  owner="$(jq -r '.url | split("/")[3]' <<<"$pr_json")"
  name="$(jq -r '.url | split("/")[4]' <<<"$pr_json")"

  # gh pr checks exits 8 while checks are pending and 1 when one failed; the JSON is still printed.
  checks_json="$("$GH_BIN" pr checks "$number" --json name,bucket,state,workflow,link 2>/dev/null || true)"
  jq -e 'type == "array"' <<<"$checks_json" >/dev/null 2>&1 || checks_json='[]'

  threads_json="$("$GH_BIN" api graphql -f query="$THREADS_QUERY" \
    -F owner="$owner" -F name="$name" -F n="$number" 2>/dev/null || true)"
  jq -e '.data' <<<"$threads_json" >/dev/null 2>&1 || threads_json='{"data":{}}'

  jq -n --argjson pr "$pr_json" --argjson checks "$checks_json" --argjson t "$threads_json" '
    def bucket($b): [$checks[] | select(.bucket == $b)];
    ($t.data.viewer.login // "") as $me
    | [ ($t.data.repository.pullRequest.reviewThreads.nodes // [])[]
        | select(.isResolved | not)
        | .comments.nodes as $c
        # A thread whose last word is ours waits on the reviewer, not on us.
        | select(($c | length) > 0 and ($c | last | .author.login // "") != $me)
        | {
            id, path, line, outdated: .isOutdated,
            author: ($c | first | .author.login // "ghost"),
            bot: (($c | first | .author.__typename) == "Bot"
                  or (($c | first | .author.login // "") | endswith("[bot]"))),
            body: ($c | last | .body),
            url: ($c | first | .url)
          }
      ] as $threads
    | (bucket("fail") + bucket("cancel")) as $failing
    | bucket("pending") as $pending
    | {
        number: $pr.number, url: $pr.url, branch: $pr.headRefName, base: $pr.baseRefName,
        head: $pr.headRefOid, state: $pr.state, draft: $pr.isDraft,
        mergeable: $pr.mergeable, merge_state: $pr.mergeStateStatus, review: $pr.reviewDecision,
        checks: {
          pass: (bucket("pass") | length), fail: ($failing | length),
          pending: ($pending | length), skipping: (bucket("skipping") | length)
        },
        failing: [ $failing[] | {
          name, workflow, link,
          run: ((.link // "") | capture("/actions/runs/(?<id>[0-9]+)").id // null)
        } ],
        pending: [ $pending[].name ],
        threads: $threads,
        next: (
          if $pr.state == "MERGED" then "merged"
          elif $pr.state == "CLOSED" then "closed"
          elif $pr.mergeable == "CONFLICTING" then "conflicts"
          elif ($failing | length) > 0 then "fix-ci"
          elif ($threads | length) > 0 then "answer-threads"
          elif ($pending | length) > 0 then "wait-ci"
          else "green"
          end
        )
      }'
}

# What --wait compares: a new head, a check that finished, a thread that came or went.
fingerprint() {
  jq -c '[.head, .next, .checks, [.threads[].id], .mergeable]' <<<"$1"
}

if ! state="$(snapshot)"; then
  printf 'pr-state: no pull request for %s\n' "${PR:-this branch}" >&2
  exit 2
fi

if [[ "$WAIT" -gt 0 && "$(jq -r .next <<<"$state")" == "wait-ci" ]]; then
  start="$(fingerprint "$state")"
  deadline=$((SECONDS + WAIT))
  while :; do
    if [[ "$SECONDS" -ge "$deadline" ]]; then
      printf '%s\n' "$state"
      exit 124
    fi
    sleep "$INTERVAL"
    state="$(snapshot)" || exit 2
    [[ "$(fingerprint "$state")" == "$start" ]] || break
  done
fi

printf '%s\n' "$state"
