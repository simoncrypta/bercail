#!/usr/bin/env bash
# shellcheck shell=bash
# What Shep knows beyond its session: the person's repos, a lean brief per
# issue, the job board, what waits on the person's review, the person's
# standing rules, the mistakes ledger, and Shep's own compaction settings.
# Sourced by lib/shep.sh.
#
#   bercail shep repos [--json]
#   bercail shep brief ISSUE [--repo DIR] [--budget CHARS]
#   bercail shep board
#   bercail shep queue [--repo DIR] [--json]
#   bercail shep remember "RULE" [--scope SCOPE] | forget N | list
#   bercail shep mistake KEY "WHAT" [--group ID] [--repo DIR] [--issue ID] | mistake group | mistake list

# The describe, policy and git-backend libs, on first use: the piped installer
# sources this file without them.
_shep_need_policy() {
  declare -F desc_change >/dev/null && return 0
  # shellcheck source=lib/describe.sh
  source "$(dirname "${BASH_SOURCE[0]}")/describe.sh"
}

# Context tokens at which Pi compacts Shep, and the recent tokens it keeps.
SHEP_COMPACT_AT=250000
SHEP_KEEP_RECENT=50000
# A report comment longer than this is cut in the brief.
SHEP_BRIEF_BUDGET=1500

_shep_hc() { _git_backend_bounded 2 "${HC_BIN:-hc}" "$@" 2>/dev/null </dev/null; }

# An explicit checkout wins over inherited store/git addressing.
_shep_bd() {
  local key
  local -a clean=()
  _shep_need_policy
  while IFS= read -r key; do
    [[ "$key" =~ ^(BD_|BEADS_|GIT_) ]] && clean+=(-u "$key")
  done < <(compgen -e)
  _git_backend_bounded 2 env "${clean[@]}" bd "$@"
}

# A trail job, trail:N (lib/jobs.ts), wherever a beads id goes in an Entire repo.
_shep_is_trail() { [[ "$1" =~ ^trail:[1-9][0-9]{0,8}$ ]]; }

# bercail job, from this lib: a trail's comments and records, and Entire's view of it.
_shep_job() {
  _shep_need_policy
  _git_backend_bounded 20 node "$(dirname "${BASH_SOURCE[0]}")/jobs.ts" "$@"
}

# A beads id or a trail, else says so.
_shep_job_id_ok() {
  [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]] || _shep_is_trail "$1" && return 0
  _shep_err "issue id '$1' is neither a beads id nor a trail (trail:N)"
  return 1
}

# Why a job is not found in a repo, by its kind.
_shep_job_unknown() {
  if _shep_is_trail "$1"; then printf 'Entire has no %s for %s (bercail job show %s --repo %s)' "$1" "$2" "$1" "$2"
  else printf 'bd does not know %s in %s' "$1" "$2"; fi
}

# --- known repos ----------------------------------------------------------------

# Every folder bercail has seen a repo in, as "source<TAB>path", plus
# "<TAB>branch" for a handoff: the [git] and [policy."<path>"] keys
# of config.toml, trusted policies, handoff records, live desks, and Shep's
# extras file (one path per line).
_shep_repo_candidates() {
  local config trust extras
  config="$(_git_backend_config_file)"
  if [[ -f "$config" ]]; then
    toml_records "$config" | jq -r '
      if .section == ["git"] and has("key") then "config\t" + .key
      elif (.section | length) == 2 and .section[0] == "policy" then "config\t" + .section[1]
      else empty end' | sort -u
  fi
  trust="$(policy_trust_file)"
  [[ ! -f "$trust" ]] || jq -r 'keys[] | "trust\t" + .' "$trust" 2>/dev/null || true
  [[ ! -f "$(notify_handoffs_file)" ]] || jq -nrR 'inputs | fromjson? | select(type == "object" and (.path | type) == "string")
    | ["handoffs", .path, (.branch // "")] | @tsv' "$(notify_handoffs_file)" 2>/dev/null || true
  if [[ $# -gt 0 ]]; then
    printf '%s\n' "$1"
  else
    _shep_desks_json
  fi | jq -r '.[] | select(.cwd) | "desks\t" + .cwd' 2>/dev/null || true
  extras="$(shep_state_dir)/repos"
  [[ ! -f "$extras" ]] || awk '{ sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, "") } $0 != "" && !/^#/ { print "extras\t" $0 }' "$extras"
  return 0
}

# Main checkouts, one "path<TAB>source,source" line each, sorted by path.
# Candidates that are not a git checkout any more are dropped.
_shep_repo_list() {
  local src path branch main
  local -A mains=()
  _shep_repo_candidates "$@" | awk -F'\t' '$2 != "" && !seen[$0]++' | while IFS=$'\t' read -r src path branch; do
    # shellcheck disable=SC2088 # a literal ~/ from config.toml or the extras file
    [[ "$path" != "~/"* ]] || path="$HOME/${path#"~/"}"
    _shep_handoff_path path "$branch"
    [[ -v 'mains[$path]' ]] || mains[$path]="$(_shep_main_of "$path")" || mains[$path]=""
    main="${mains[$path]}"
    [[ -z "$main" ]] || printf '%s\t%s\n' "$main" "$src"
  done | sort -u | awk -F'\t' '
    !($1 in from) { order[++n] = $1; from[$1] = $2; next }
    { from[$1] = from[$1] "," $2 }
    END { for (i = 1; i <= n; i++) print order[i] "\t" from[order[i]] }'
}

# The repo's issues that are not closed, as [{id, title, status, labels}].
# Fails when it has no beads, or bd does not answer within 10 seconds.
_shep_open_issues() {
  local main="$1" raw
  [[ -d "$main/.beads" ]] || return 1
  raw="$(cd "$main" && _shep_bd list --all --json --limit 0 </dev/null 2>/dev/null)" || return 1
  jq -c '[(if type == "array" then .[] else empty end) | select(.status != "closed")
    | {id, title, status, labels: (.labels // [])}]' <<<"$raw" 2>/dev/null
}

# An Entire repo's open trails, as {issues, complete, review}: the trails still
# in flight in the issues' shape, with what their "Blocked by:" line still waits
# on, how many are complete but still open (merged, and nobody closed them), and
# the numbers of those in review (phase building), which the queue reads from it.
# A trail is in progress once dispatched (it has a job record) or past planning
# (it has a branch). Fails when Entire does not answer.
_shep_open_trails() {
  local raw
  # Within the board's 10 seconds, so a slow Entire is this repo's UNKNOWN, not the board's.
  _shep_need_policy
  raw="$(_git_backend_bounded 6 node "$(dirname "${BASH_SOURCE[0]}")/jobs.ts" list --repo "$1" --json </dev/null 2>/dev/null)" || return 1
  jq -ce '{issues: [.[] | select(.phase != "complete")
      | {id, title, phase, labels: [], waiting: .waiting_on,
         status: (if .record != null or ((.phase // "planning") | IN("planning", "draft") | not) then "in_progress" else "open" end)}],
     complete: ([.[] | select(.phase == "complete")] | length),
     review: [.[] | select(.phase == "building") | .id | ltrimstr("trail:")]}' <<<"$raw" 2>/dev/null
}

# Known repos as a JSON array: path, git backend, policy (trusted, untrusted,
# none), open issue count (null without beads or trails), where bercail saw the
# repo, and the open issues themselves for the board: beads issues, and in an
# Entire repo its open trails (complete: the trails left to close).
_shep_repos_json() {
  local main from backend policy issues beads trails
  while IFS=$'\t' read -r main from; do
    backend="$(git_backend "$main" 2>/dev/null)" || backend=""
    policy="$(policy_json "$main" 2>/dev/null \
      | jq -r 'if .file == "" then "none" elif .trusted then "trusted" else "untrusted" end' 2>/dev/null)" || policy=""
    beads=false
    [[ ! -d "$main/.beads" ]] || beads=true
    issues="$(_shep_open_issues "$main")" || issues=null
    trails=null
    [[ "$backend" != entire ]] || trails="$(_shep_open_trails "$main")" || trails=false
    jq -nc --arg path "$main" --arg from "$from" --arg backend "$backend" --arg policy "$policy" --argjson issues "$issues" --argjson beads "$beads" \
      --argjson trails "$trails" '
      # A source that failed makes the whole list UNKNOWN, never a shorter one.
      (if $trails == false or ($beads and $issues == null) or ($issues == null and $trails == null) then null
       else ($issues // []) + ($trails.issues // []) end) as $all
      | {path: $path, backend: (if $backend == "" then null else $backend end),
       policy: (if $policy == "" then null else $policy end),
       open: (if $all == null then null else ($all | length) end), from: ($from | split(",")), issues: $all, beads:$beads,
       entire: ($backend == "entire"), complete: (if ($trails | type) == "object" then $trails.complete else null end),
       review: (if ($trails | type) == "object" then $trails.review elif $trails == false then false else null end)}'
  done < <(_shep_repo_list) | jq -sc .
}

# jq helpers for paths and titles, shared by the views below.
SHEP_JQ_DEFS='
  def tilde: if startswith($home + "/") then "~" + .[($home | length):] else . end;
  def cut($n): if length > $n then (.[0:($n - 1)] | sub(" +$"; "")) + "…" else . end;
  def flat: gsub("[[:space:][:cntrl:]]+"; " ") | sub("^ +"; "") | sub(" +$"; "");
  def unknown_open: if .open != null then "\(.open) open"
    elif .beads or .entire then "UNKNOWN (\([if .beads then "beads" else empty end, if .entire then "Entire" else empty end] | join(" or ")) unavailable)"
    else "no beads" end;'

shep_repos() {
  local json=0 out
  _shep_need_policy
  case "${1:-}" in
    --json) json=1 ;;
    "") ;;
    *) _shep_err "usage: bercail shep repos [--json]"; return 1 ;;
  esac
  out="$(_shep_repos_json)"
  if ((json)); then
    jq 'map(del(.issues, .beads, .entire, .complete, .review))' <<<"$out"
    return 0
  fi
  jq -r --arg home "$HOME" --arg state "$(shep_state_dir)" "$SHEP_JQ_DEFS"'
    if length == 0 then "no repos yet: bercail learns them from handoffs, live desks, config.toml, and \($state)/repos"
    else (map(.path | tilde | length) | max) as $w
      | .[] | (.path | tilde) as $p
      | "\($p)\(if $w > ($p | length) then " " * ($w - ($p | length)) else "" end)  \(.backend // "?")  "
        + ({trusted: "policy trusted  ", untrusted: "policy untrusted", none: "no policy       "}[.policy // ""] // "policy ?        ")
        + "  " + unknown_open + "  (\(.from | join(", ")))"
    end' <<<"$out"
}

# --- desks, handoffs, brief, board -------------------------------------------------

# Live desks and background Sheps: address, name, cwd, state (working, done,
# blocked, idle), and the issue, title, space and model (handoff --model) on
# their labels. Fails when hc does not answer.
_shep_desks_json() {
  local get="${1:-_shep_hc}" addr detail main rows snapshot
  _shep_need_policy
  rows="$(_shep_hc ls --json --label bercail.role=agent)" || return 1
  jq -e '.terminals | type == "array"' <<<"$rows" >/dev/null || return 1
  snapshot="$(
    while IFS= read -r addr; do
      detail="$("$get" get "$addr" --json 2>/dev/null </dev/null)" || exit 1
      main="$(_shep_main_of "$(jq -r '.cwd // ""' <<<"$detail")")" || main=""
      jq -c --arg repo "$main" '{address, name, cwd, repo:$repo, state: (.status.state // "unknown"),
        issue: .labels["bercail.issue"], title: .labels["bercail.issue_title"], space: .labels["bercail.space"],
        model: .labels["bercail.model"], bg: (.labels["bercail.shep"] == "bg")}' <<<"$detail"
    done < <(jq -r '.terminals[] | select(.state == "live") | .address' <<<"$rows")
  )" || return 1
  jq -sc '[.[] | select(.address)]' <<<"$snapshot"
}

# A per-repo projection for status only. Dispatch checks every live candidate;
# it never treats this latest-record summary as proof of ownership.
_shep_records_json() {
  local file row path branch main
  local -A mains=()
  file="$(notify_handoffs_file)"
  [[ -f "$file" ]] || { printf '{}'; return 0; }
  _shep_need_policy
  while IFS=$'\x1f' read -r path branch row; do
    _shep_handoff_path path "$branch"
    [[ -v 'mains[$path]' ]] || mains[$path]="$(_shep_main_of "$path")" || mains[$path]=""
    main="${mains[$path]}"
    [[ -z "$main" ]] || printf '%s\x1f%s\n' "$main" "$row"
  done < <(jq -Rr 'fromjson? | select(type == "object" and .issue and (.path | strings | length > 0))
    | [.path, (.branch // ""), tojson] | join("\u001f")' "$file") \
    | jq -nRc 'reduce inputs as $line ({};
      ($line | index("\u001f")) as $i | ($line[:$i]) as $repo | ($line[$i+1:] | fromjson) as $r
      | .[($repo + "\u001f" + $r.issue)] = ($r + {repo: $repo}))'
}

# Normalize the caller's path before looking up a checkout: a gone handoff at
# <main>.<branch> still identifies <main>.
_shep_handoff_path() {
  local -n checkout="$1"
  local branch="$2"
  if [[ ! -d "$checkout" && -n "$branch" && "$checkout" == *".$branch" ]]; then
    checkout="${checkout%".$branch"}"
  fi
}

_shep_main_of() {
  local path="$1"
  _shep_handoff_path path "${2:-}"
  [[ -d "$path" ]] || return 1
  git_backend_main "$path" 2>/dev/null
}

# The issue as bd prints it from DIR, one JSON object.
_shep_bd_issue() {
  local raw
  raw="$(cd "$1" && _shep_bd show "$2" --json 2>/dev/null </dev/null)" || return 1
  jq -ce 'if type == "array" then .[0] else . end | select(type == "object" and .id)' <<<"$raw" 2>/dev/null
}

# The last lines of a blocked desk's screen, where its question is: no blank
# lines or rules, at most 15 lines and 1200 characters.
_shep_screen_tail() {
  _shep_hc read "$1" | sed 's/[[:space:]]*$//' | grep -v '^[─━═[:space:]]*$' | tail -n 15 | cut -c1-200 | head -c 1200 || true
}

shep_brief() {
  local issue="" repo="" budget="$SHEP_BRIEF_BUDGET" records desks rec desk main="" issue_json comments screen="" candidate
  local worktree change staged="" hints more
  local usage="usage: bercail shep brief ISSUE [--repo DIR] [--budget CHARS]"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo) repo="${2:-}"; shift 2 || shift $# ;;
      --repo=*) repo="${1#*=}"; shift ;;
      --budget) budget="${2:-}"; shift 2 || shift $# ;;
      --budget=*) budget="${1#*=}"; shift ;;
      -*) _shep_err "$usage"; return 1 ;;
      *) [[ -z "$issue" ]] || { _shep_err "$usage"; return 1; }; issue="$1"; shift ;;
    esac
  done
  [[ -n "$issue" ]] || { _shep_err "$usage"; return 1; }
  _shep_job_id_ok "$issue" || return 1
  _shep_need_policy
  [[ "$budget" =~ ^[0-9]+$ && "$budget" -ge 200 ]] || { _shep_err "--budget takes a number of characters, 200 or more"; return 1; }
  records="$(_shep_records_json)"
  desks="$(_shep_desks_json)"
  if [[ -n "$repo" ]]; then
    main="$(_shep_main_of "$repo")" || { _shep_err "$repo is not a git checkout"; return 1; }
    repo="$main"
  else
    hints="$(jq -nc --arg id "$issue" --argjson ds "$desks" --argjson rs "$records" '[($ds[] | select(.issue == $id) | .repo), ($rs[] | select(.issue == $id) | .repo)] | map(select(. != "" and . != null)) | unique')"
    [[ "$(jq length <<<"$hints")" -lt 2 ]] || { _shep_err "$issue exists in more than one repo; pass --repo explicitly"; return 1; }
    repo="$(jq -r '.[0] // ""' <<<"$hints")"
  fi
  rec="$(jq -c --arg id "$issue" --arg repo "$repo" '.[($repo + "\u001f" + $id)] // null' <<<"$records")"
  desk="$(jq -c --arg id "$issue" --arg repo "$repo" --argjson rec "$rec" '
    map(select(.repo == $repo)) | (map(select(.issue == $id)) | first) // (if $rec.desk then map(select(.address == $rec.desk and (.issue // $id) == $id)) | first else null end)' <<<"$desks")"
  # Unambiguous hints are convenience, never a cross-repo ownership transfer.
  if [[ -n "$repo" ]]; then
    main="$(_shep_main_of "$repo")" || { _shep_err "$repo is not a git checkout"; return 1; }
  else
    main="$(_shep_main_of "$(jq -r '.path // empty' <<<"$rec")" "$(jq -r '.branch // empty' <<<"$rec")")" \
      || main="$(_shep_main_of "$(jq -r '.cwd // empty' <<<"$desk")")" || main=""
    # Trail numbers repeat across repos: only a desk or a record names a trail's.
    if [[ -z "$main" ]] && ! _shep_is_trail "$issue"; then
      while IFS=$'\t' read -r candidate _; do
        [[ -d "$candidate/.beads" ]] && _shep_bd_issue "$candidate" "$issue" >/dev/null && { main="$candidate"; break; }
      done < <(_shep_repo_list)
    fi
  fi
  [[ -n "$main" ]] || { _shep_err "no known repo has $issue; pass its checkout with --repo"; return 1; }
  if _shep_is_trail "$issue"; then
    issue_json="$(_shep_job show "$issue" --repo "$main" --json </dev/null)" \
      || { _shep_err "$(_shep_job_unknown "$issue" "$main"); pass its checkout with --repo"; return 1; }
    comments="$(jq -c '.comments' <<<"$issue_json")"
    issue_json="$(jq -c 'del(.comments, .body, .record)' <<<"$issue_json")"
    more="bercail job show $issue --repo $main"
  else
    issue_json="$(_shep_bd_issue "$main" "$issue")" \
      || { _shep_err "bd does not know $issue in $main; pass its checkout with --repo"; return 1; }
    comments="$(cd "$main" && _shep_bd comments "$issue" --json 2>/dev/null </dev/null | jq -c 'if type == "array" then . else [] end' 2>/dev/null)" || comments='[]'
    more="bd comments $issue"
  fi
  [[ -n "$comments" ]] || comments='[]'
  if [[ "$(jq -r '.state // empty' <<<"$desk")" == blocked ]]; then
    screen="$(_shep_screen_tail "$(jq -r .address <<<"$desk")")"
  fi
  worktree="$(jq -r '$rec.path // .cwd // empty' --argjson rec "$rec" <<<"${desk:-null}")"
  if [[ -n "$worktree" && -d "$worktree" ]] && change="$(desc_change "$worktree" 2>/dev/null)" \
    && jq -e '.files > 0' <<<"$change" >/dev/null 2>&1; then
    staged="staged: $(desc_change_line "$change") · $(_shep_described "$worktree" | jq -r 'if .ok then "describe check ok" else "describe check fails: \(.why)" end')"
  fi
  jq -nr --arg home "$HOME" --arg repo "$main" --argjson issue "$issue_json" --argjson comments "$comments" \
    --argjson rec "$rec" --argjson desk "$desk" --arg screen "$screen" --argjson budget "$budget" --arg staged "$staged" \
    --arg more "$more" "$SHEP_JQ_DEFS"'
    def who: if $desk.bg then "background Shep \($desk.name // $desk.address)" else "desk \($desk.address)" end;
    def trim($n):
      if length <= $n then .
      else (($n * 2 / 3) | floor) as $h | ($n - $h) as $t
        | .[0:$h] + "\n[… \(length - $n) characters cut; the whole comment: \($more)]\n" + .[(length - $t):] end;
    ($issue.id) as $id
    | ([$comments | to_entries[] | select((.value.text // "") | startswith("bercail handoff:") or startswith("bercail todo:") | not)]) as $reports
    | "\($id): \($issue.title // "" | flat)",
      ([$issue.status, $issue.phase,
        ($issue.priority | if type == "number" then "P\(.)" elif . == null or . == "none" then empty else "priority \(.)" end),
        $issue.issue_type, $issue.url]
        | map(select(. != null and . != "")) | join(" "))
        + (if ($issue.labels // []) | length > 0 then " · labels \($issue.labels | join(", "))" else "" end)
        + " · repo \($repo | tilde)",
      (if ($issue.waiting_on // []) | length > 0 then "blocked: waits on \($issue.waiting_on | join(", "))"
       elif ($issue.blocked_by // []) | length > 0 then "ready: \($issue.blocked_by | join(", ")) closed or merged" else empty end),
      ([ (if $desk then "\(who) \($desk.state)" elif $rec.desk then "desk \($rec.desk) gone" else "no desk" end),
         (if ($desk.space // $rec.space) then "space " + ([$rec.label, ($desk.space // $rec.space)] | map(select(.)) | if length == 2 then "\(.[0]) (\(.[1]))" else .[0] end) else empty end),
         (if $rec.branch then "branch \($rec.branch)" else empty end),
         (if ($rec.path // $desk.cwd) then "worktree \(($rec.path // $desk.cwd) | tilde)" else empty end),
         ((if $desk then $desk.model else $rec.model end) | if . then "model \(.)" else empty end) ] | join(" · ")),
      (if $staged != "" then $staged else empty end),
      ($comments[] | (.text // "") | select(startswith("bercail todo:")) | "todo:" + ltrimstr("bercail todo:") | flat),
      (if $screen != "" then "\(who) is blocked; its screen ends with:", ($screen | split("\n")[] | "  | " + .),
        "(the whole screen: hc read \($desk.address) --lines 60)" else empty end),
      (if ($reports | length) == 0 then
         "no report yet (\($comments | length) comment\(if ($comments | length) == 1 then "" else "s" end); \($more))"
       else ($reports[-1].value) as $c
         | "latest report: comment \($reports[-1].key + 1) of \($comments | length), \($c.author // "?") at \($c.created_at // "?" | sub("T"; " ") | sub(":[0-9]{2}(\\.[0-9]+)?Z$"; "")) (\($c.text | length) characters):",
           ($c.text | gsub("\n{3,}"; "\n\n") | sub("\n+$"; "") | trim($budget))
       end)'
}

# One line per open job across the known repos, then what waits on the person:
# desks, and the todos only they can do. A job is an issue that is not closed
# and has a live desk or status in_progress or blocked. The rest of a repo's
# open issues are a count, with how many of them were handed off to a desk
# that is gone.
shep_board() {
  local out rc=0
  _shep_need_policy
  out="$(_git_backend_bounded 10 "${BERCAIL_SELF:-bercail}" shep board-snapshot "$@")" || rc=$?
  [[ -z "$out" ]] || printf '%s\n' "$out"
  if ((rc)); then printf 'Board incomplete: UNKNOWN (status sources failed or exceeded 10s); dispatch is not gated on this snapshot.\n' >&2; fi
  return "$rc"
}

_shep_board_snapshot() {
  local repos desks records todos fd decisions queue rc=0
  [[ $# -eq 0 ]] || { _shep_err "usage: bercail shep board"; return 1; }
  _shep_need_policy
  # The cards waiting on the person, from the ledger, never from Shep's prose. Their live
  # checks run beside the board's own reads, within 4 seconds, so they cost it no time.
  exec {fd}< <(_git_backend_bounded 4 shep_question waiting 2>/dev/null && printf 'ok\n')
  repos="$(_shep_repos_json)" || return 1
  desks="$(_shep_desks_json)" || return 1
  records="$(_shep_records_json)" || return 1
  # shellcheck source=lib/todo.sh
  declare -F todo_board_json >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/todo.sh"
  todos="$(todo_board_json)"
  jq -nr --arg home "$HOME" --argjson repos "$repos" --argjson desks "$desks" --argjson rec "$records" \
    --argjson todos "$todos" "$SHEP_JQ_DEFS"'
    def who($d): if $d.bg then "background Shep \($d.name // $d.address)" else "desk \($d.address)" end;
    def head($j): "\($j.id): \($j.title // "" | flat | cut(70))";
    # With the repo: another repo may have an issue, a desk or a handoff with that id.
    def brief($j): "bercail shep brief \($j.id) --repo \($j.repo | @sh)";
    ($desks | map(select(.issue)) | map({key: (.repo + "\u001f" + .issue), value: .}) | from_entries) as $live
    | [ $repos[] | . as $r | ($r.issues // [])[] | . as $i | ($rec[($r.path + "\u001f" + $i.id)]) as $h | ($live[($r.path + "\u001f" + $i.id)]) as $d
        | select($d or $i.status == "in_progress" or $i.status == "blocked")
        | {repo: $r.path, id: $i.id, title: $i.title, status: $i.status, phase: $i.phase, waiting: $i.waiting, desk: $d, rec: $h} ] as $jobs
    | ([$repos[] | .path as $repo | (.issues // [])[] | $repo + "\u001f" + .id]) as $open
    | ( $repos[] | . as $r | [$jobs[] | select(.repo == $r.path)] as $mine | select($mine | length > 0)
        | ([$mine[].id]) as $ids
        | ([$r.issues[] | select(.id as $x | ($ids | index($x) | not) and $rec[($r.path + "\u001f" + $x)].desk)] | length) as $gone
        | "\($r.path | tilde): \($mine | length) job\(if ($mine | length) == 1 then "" else "s" end)"
          + (if ($r.open - ($mine | length)) > 0 then ", \($r.open - ($mine | length)) other open issues"
              + (if $gone > 0 then " (\($gone) handed off to a desk that is gone)" else "" end) else "" end),
          ($mine[] | "- " + head(.)
            + (if .phase then " [\(.phase)]" elif .status != "open" then " [\(.status)]" else "" end)
            + (if (.waiting // []) | length > 0 then " · blocked by \(.waiting | join(", "))" else "" end)
            + " · " + (if .desk then "\(who(.desk)) \(.desk.state)" elif .rec.desk then "desk \(.rec.desk) gone" else "no desk" end)
            + " · " + (.rec.branch // "-")
            + ((if .desk then .desk.model else .rec.model end) | if . then " · model \(.)" else "" end)) ),
      ([ $repos[] | . as $r | select(([$jobs[] | select(.repo == $r.path)] | length) == 0)
         | "\($r.path | tilde) (" + unknown_open + ")" ]
       | if length > 0 then "Other repos: " + join(", ") else empty end),
      ($repos[] | . as $r | [($r.issues // [])[] | select((.waiting // []) | length > 0)
         | select(.id as $x | $jobs | any(.repo == $r.path and .id == $x) | not) | "\(.id) by \(.waiting | join(", "))"]
       | select(length > 0) | "\($r.path | tilde): blocked, not started: " + join("; ")),
      ($repos[] | . as $r | [($r.issues // [])[] | select(.phase and .status == "open" and ((.waiting // []) | length == 0))
         | select(.id as $x | $jobs | any(.repo == $r.path and .id == $x) | not) | .id]
       | select(length > 0) | "\($r.path | tilde): ready, not started: " + join(", ")),
      ($repos[] | select((.complete // 0) > 0)
       | "\(.path | tilde): \(.complete) complete trail\(if .complete == 1 then "" else "s" end) still open; close each with entire trail update N --status closed (bercail job list --repo \(.path | tilde))"),
      ([ $desks[] | select(.issue and ((.repo + "\u001f" + .issue) as $x | $open | index($x) | not)) | "\(who(.)) \(.state) (\(.issue))" ]
       | if length > 0 then "Desks on closed or unknown issues: " + join(", ") else empty end),
      "Waiting on the person:",
      ([ ($jobs[] | select(.desk) | . as $j
           | if .desk.state == "blocked" then "- " + head($j) + ": \(who(.desk)) is blocked; \(brief($j)) shows what it asks"
             elif (.desk.state == "done" or .desk.state == "idle") then
               "- " + head($j) + ": \(who(.desk)) finished; " + (if .desk.bg then "report it from \(brief($j)), then hc kill \(.desk.name // .desk.address)" else "read its report in \(brief($j)), then review its staged changes in its space" end)
             else empty end),
         ($desks[] | select((.issue | not) and .state == "blocked") | "- \(who(.)) (\(.cwd // "?" | tilde)) is blocked"),
         ($todos // [] | .[] | . as $t | def tag: if .issue then " for \(.issue)" else "" end;
           if .error then "- todos\(if .target then " in \(.target)" else "" end): \(.error)"
           else (.open[] | "- todo\(tag): \(.title | flat | cut(70))" + (if .due then " · due \(.due)" else "" end)
                  + " · open in \($t.target)" + (if .url then " · \(.url)" else "" end)),
                (.finished[] | "- todo\(tag): \(.title // "" | flat | cut(70)) · done in \($t.target); "
                  + (if .issue then "continue \(.issue), then " else "" end) + "bercail todo done \(.id)") end) ]
       | if length > 0 then .[] else "- nothing" end)'
  # shellcheck source=lib/routine.sh
  declare -F routine_board_line >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/routine.sh"
  routine_board_line
  queue="$(_shep_queue_text "$(_shep_queue_json "$repos" "$desks" "$records")")" || rc=$?
  decisions="$(cat <&"$fd")"
  exec {fd}<&-
  if [[ "$decisions" == *$'\n'ok ]]; then printf '%s\n' "${decisions%$'\n'ok}"
  else printf 'Decisions: UNKNOWN (the ledger could not be read, or its cards checked within 4s; the Decisions panel shows them)\n'; fi
  [[ -z "$queue" ]] || printf '%s\n' "$queue"
  return "$rc"
}

# --- review queue -------------------------------------------------------------------

# Reads the workers on file descriptors FD..., in order, closing each, and
# appends what they printed to the variable VAR. A worker is a process
# substitution, not a file, so a timeout's kill leaves no result behind. Fails
# when one did not end with ok: a worker that dies says nothing.
_shep_workers_read() {
  local var="$1" fd got rc=0
  shift
  for fd in "$@"; do
    got="$(cat <&"$fd")"
    exec {fd}<&-
    [[ "$got" == ok || "$got" == *$'\n'ok ]] || rc=1
    printf -v "$var" '%s%s' "${!var}" "${got%ok}"
  done
  return "$rc"
}

# Open PRs in the GitHub repo MAIN that wait on the person, as a JSON array: not
# a draft, not approved, and either asking LOGIN for a review or opened from a
# handoff's branch (BRANCHES, a JSON array). Lines leave lockfiles out. []
# without a github.com remote. A failed query is UNKNOWN, never an empty list.
_shep_queue_prs() {
  local main="$1" login="$2" branches="$3" raw
  grep -q 'github\.com[:/]' <<<"$(git -C "$main" remote -v 2>/dev/null)" || { printf '[]'; return 0; }
  raw="$(cd "$main" && _git_backend_bounded 2 "${GH_BIN:-gh}" pr list --state open --limit 100 \
    --json number,title,url,isDraft,reviewDecision,headRefName,reviewRequests,files,createdAt </dev/null 2>/dev/null)" \
    || return 1
  jq -c --arg repo "$main" --arg login "$login" --argjson branches "$branches" --arg locks "$DESC_LOCKFILES" '
    ($locks | split(" ")) as $l
    | [.[]? | select((.isDraft | not) and .reviewDecision != "APPROVED"
        and (([.reviewRequests[]?.login] | index($login)) or (.headRefName | IN($branches[]))))
      | {kind: "pr", repo: $repo, number, title, url, branch: .headRefName, state: "review", since: .createdAt,
         lines: ([.files[]? | select(.path | split("/") | last | IN($l[]) | not) | .additions + .deletions] | add // 0)}]' \
    <<<"$raw" 2>/dev/null
}

# An Entire repo's trail changes in review, as a JSON array: the open changes
# in MAIN's repo on its open trails in the building phase, each with its open
# findings and its gate state. The change's lines were counted when it was
# staged, so it brings none here: its findings and gates are what wait. []
# when origin is not on Entire. A failed or malformed read is UNKNOWN, never an
# empty list. REVIEW, the trail numbers in review as a JSON array, comes from the
# board's list of the repo's trails (false when that list failed: UNKNOWN with no
# second try); without it, bercail job list reads them, so a
# refresh lists a repo's trails once (with its pages), whatever their number
# (Simon's budget). Only trails in review are shown, in parallel, as each read
# takes about a second and the queue has six (see _shep_workers_read).
_shep_queue_trails() {
  local main="$1" review="${2:-}" url project name trails n fd out=""
  local -a fds=()
  url="$(git -C "$main" remote get-url origin 2>/dev/null)" || return 1
  [[ "$url" =~ ^entire://[^/]+/(et/[^/]+)/([^/]+)$ ]] || { printf '[]'; return 0; }
  project="${BASH_REMATCH[1]}" name="${BASH_REMATCH[2]}"
  [[ "$review" != false ]] || return 1
  if [[ -z "$review" || "$review" == null ]]; then
    review="$(_git_backend_bounded 4 node "$(dirname "${BASH_SOURCE[0]}")/jobs.ts" list --repo "$main" --json </dev/null 2>/dev/null \
      | jq -ce '[.[] | select(.phase == "building") | .id | ltrimstr("trail:")]' 2>/dev/null)" || return 1
  fi
  trails="$(jq -er 'join(" ")' <<<"$review" 2>/dev/null)" || return 1
  for n in $trails; do
    exec {fd}< <(_shep_queue_trail "$main" "$project" "$name" "$n" && printf 'ok\n')
    fds+=("$fd")
  done
  _shep_workers_read out "${fds[@]}" && jq -sc . <<<"$out"
}

# Trail N's open changes in repo NAME, one queue item a line (see
# _shep_queue_trails). Each change's findings are read at once.
_shep_queue_trail() {
  local main="$1" project="$2" name="$3" n="$4" show trail changes change fd out=""
  local -a fds=()
  show="$(cd "$main" && _git_backend_bounded 4 entire trail show "$n" --project "$project" \
    --json </dev/null 2>/dev/null)" || return 1
  trail="$(jq -ce '{number, title}' <<<"$show" 2>/dev/null)" || return 1
  changes="$(jq -ce --arg name "$name" '.changes | if type == "array" then map(select(.repository == $name and .status == "open"))
    else error("no changes") end' <<<"$show" 2>/dev/null)" || return 1
  while IFS= read -r change; do
    exec {fd}< <(_shep_queue_trail_change "$main" "$project" "$name" "$trail" "$change" </dev/null && printf 'ok\n')
    fds+=("$fd")
  done < <(jq -c '.[]' <<<"$changes")
  _shep_workers_read out "${fds[@]}" && printf '%s' "$out"
}

# One open CHANGE of trail TRAIL ({number, title}) in repo NAME, as a queue item.
_shep_queue_trail_change() {
  local main="$1" project="$2" name="$3" trail="$4" change="$5" counts
  # Only the counts: a page of findings can be larger than an argument may be.
  counts="$(cd "$main" && _git_backend_bounded 4 entire trail finding list --trail "$name/$(jq -r .number <<<"$change")" \
    --project "$project" --json </dev/null 2>/dev/null \
    | jq -ce '.counts | {open: .Open, high: .OpenHigh, medium: .OpenMedium, low: .OpenLow}
        | if all(.[]; type == "number") then . else error("no finding counts") end' 2>/dev/null)" || return 1
  jq -c --arg repo "$main" --arg name "$name" --argjson t "$trail" --argjson f "$counts" '
    # Null is unknown, never mergeable (entire agent-help trail show).
    def gates: .mergeability as $m
      | if ($m.head_sha // "") == "" then {state: "unknown", text: "no gate state yet"}
        else [$m.gates[]? | select(.blocking)] as $g
        | [$g[] | select(.status == "failed" or .outcome == "failed") | .gate_key] as $failed
        | if ($failed | length) > 0 then {state: "failed", text: "\($failed | join(", ")) failed"}
          elif $m.mergeable == true then {state: "ready", text: "every blocking gate passed"}
          else {state: "pending", text: "waiting on \([$g[] | select(.status | IN("passed", "skipped") | not) | .gate_key]
                  | if length > 0 then join(", ") else "mergeability" end)"} end end;
    {kind: "trail", repo: $repo, trail: $t.number, repository: $name, number, title: $t.title, url, branch,
     state: "review", since: .updatedAt, lines: 0, findings: $f, gates: gates}' <<<"$change"
}

# The issue as bd prints it from MAIN, given at most 10 seconds; fails when the
# repo has no beads or bd does not answer.
_shep_queue_issue() {
  local raw
  [[ -d "$1/.beads" ]] || return 1
  raw="$(cd "$1" && _shep_bd show "$2" --json </dev/null 2>/dev/null)" || return 1
  jq -ce 'if type == "array" then .[0] else . end | select(type == "object" and .id)' <<<"$raw" 2>/dev/null
}

# A folder's checkout, resolved: two spellings of one worktree compare equal.
_shep_top() {
  (cd "$1" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null) || return 1
}

# When the worktree's changes were last staged: its index's mtime, in seconds.
_shep_staged_at() {
  local index
  index="$(cd "$1" && git rev-parse --path-format=absolute --git-path index 2>/dev/null)" || return 1
  stat -c %Y "$index" 2>/dev/null || stat -f %m "$index" 2>/dev/null
}

# What describe check says of the worktree's staged change, as {ok, why}: why
# is the first thing it fails on. A check that cannot run is not ok. It reads a
# copy of the index: git write-tree rewrites the index, and the queue's order is
# when the index last changed. With SKIP_IDS, it skips the beads-id rule.
_shep_described() {
  local root="$1" skip_ids="${2:-}" index copy state=""
  index="$(cd "$root" && git rev-parse --path-format=absolute --git-path index 2>/dev/null)" \
    && copy="$(mktemp)" && cp -p "$index" "$copy" \
    && state="$(GIT_INDEX_FILE="$copy" desc_state "$root" "$skip_ids" 2>/dev/null)"
  [[ -z "${copy:-}" ]] || rm -f "$copy"
  [[ -n "$state" ]] || { printf '{"ok":false,"why":"describe check did not run"}\n'; return 0; }
  jq -c --arg root "$root/" '.fails as $f
    | {ok: ($f | length == 0),
       why: (($f[0] // "") | split($root) | join("")) + (if ($f | length) > 1 then " (+\($f | length - 1) more)" else "" end)}' <<<"$state"
}

# What a staged worktree is to the person, from records only: {state, why, by,
# title}. state: review, or lgtm when its policy wants the person's LGTM (an
# unknown one may want it too: change.review says);
# superseded when bd supersede or bd duplicate names a replacement, or the
# issue's latest handoff went to another worktree that is still there; cleanup
# when the issue is closed; unknown when bd cannot say. Parent and child links
# are not read: a child does not say it replaces its parent.
_shep_queue_state() {
  local main="$1" issue="$2" path="$3" change="$4" records="$5" bd=null moved="" latest top
  if [[ -n "$issue" ]]; then
    bd="$(_shep_queue_issue "$main" "$issue")" || bd=null
    latest="$(jq -r --arg id "$issue" --arg repo "$main" '.[($repo + "\u001f" + $id)].path // empty' <<<"$records")"
    if [[ -n "$latest" ]] && top="$(_shep_top "$path")" && latest="$(_shep_top "$latest")" && [[ "$latest" != "$top" ]]; then
      moved="$latest"
    fi
  fi
  jq -nc --arg issue "$issue" --argjson bd "$bd" --arg moved "$moved" --argjson change "$change" \
    --arg beads "$([[ -d "$main/.beads" ]] && echo 1)" '
    (if $change.review == "required" then {state: "lgtm"} else {state: "review"} end) as $waits
    | if $issue == "" then $waits
      elif $bd == null then {state: "unknown", why: (if $beads == "" then "the repo has no beads" else "bd does not answer for \($issue)" end)}
      else ([$bd.dependencies[]? | {to: (.depends_on_id // .id), type: (.dependency_type // .type)}
              | select(.type == "supersedes" or .type == "duplicates")] | first) as $d
        | {title: $bd.title}
          + if $d then {state: "superseded", by: $d.to,
                        why: (if $d.type == "supersedes" then "superseded by \($d.to)" else "a duplicate of \($d.to)" end)}
            elif $bd.status == "closed" then {state: "unknown", why: "issue closed but staged changes remain; custody/outcome unproven"}
            elif $moved != "" then {state: "superseded", by: $moved, why: "its job moved to another worktree"}
            else $waits end
      end'
}

# The Herdr spaces open in the window, as {ids, paths}: their ids, and the
# folders they and their terminals sit in on this machine. Fails when no window
# answers, so no worktree is called spaceless on a guess.
_shep_live_spaces() {
  local spaces terms
  spaces="$(_git_backend_bounded 2 "${HERDR_APP_BIN:-herdr-app}" ls 2>/dev/null </dev/null)" || return 1
  terms="$(_shep_hc ls --json)" && jq -e 'type == "object"' <<<"$terms" >/dev/null 2>&1 || terms='{}'
  jq -nce --argjson t "$terms" '
    ([$t.terminals[]? | select(.cwd) | {key: .address, value: .cwd}] | from_entries) as $cwd
    | input.spaces | arrays
    | {ids: map(.id), paths: [.[] | select(.machine == null) | .folder, (.tabs[]?.terminals[]?.terminal | strings | $cwd[.])] | map(strings) | unique}' \
    <<<"$spaces" 2>/dev/null
}

# One repo's staged worktrees as a JSON array of queue items. The candidates
# come on stdin, a line each: path, issue, title, desk and space, \x1f apart.
# They are read one after another: bd serves one read at a time in a repo.
_shep_queue_staged() {
  local main="$1" records="$2" live="$3" path issue title desk space change state since described items='[]'
  # \x1f, not a tab: read would merge an empty title's two tabs into one.
  while IFS=$'\x1f' read -r path issue title desk space; do
    git -C "$path" diff --cached --quiet 2>/dev/null && continue
    change="$(desc_change "$path" 2>/dev/null </dev/null)" || continue
    jq -e '.files > 0' <<<"$change" >/dev/null 2>&1 || continue
    if [[ -n "$live" ]] && ! jq -e --arg s "$space" --arg p "$path" '(.ids | index($s)) or (.paths | index($p))' <<<"$live" >/dev/null; then
      # A title lookup must not hold up the snapshot for an already-classified row.
      state='{"state":"stale","why":"no Herdr space"}'
    else
      state="$(_shep_queue_state "$main" "$issue" "$path" "$change" "$records" </dev/null)"
    fi
    since="$(_shep_staged_at "$path")" || since=""
    # Only a change that waits on the person gets the check. It skips the beads-id
    # rule: the queue reads no full beads list.
    described=null
    jq -e '.state | IN("cleanup", "superseded", "stale")' <<<"$state" >/dev/null \
      || described="$(_shep_described "$path" skip-ids </dev/null)"
    items="$(jq -c --arg repo "$main" --arg path "$path" --arg issue "$issue" --arg title "$title" --arg desk "$desk" \
      --arg space "$space" --arg since "$since" --argjson change "$change" --argjson state "$state" --argjson described "$described" '
      def opt: if . == "" then null else . end;
      . + [{kind: "staged", repo: $repo, path: $path, issue: ($issue | opt),
            title: (($title | opt) // $state.title), desk: ($desk | opt), space: ($space | opt),
            since: (if $since == "" then null else ($since | tonumber | todate) end),
            state: $state.state, why: $state.why, by: $state.by, change: $change, described: $described}]' <<<"$items")" || return 1
  done
  printf '%s\n' "$items"
}

# What waits on the person's review, as JSON: {schema, at, items, repos}. An
# item is a worktree with staged changes whose desk is not working (done, idle,
# blocked, or gone), or an open PR that waits on them. Each has a state (see
# _shep_queue_state; a PR is review; stale when no open Herdr space has the
# worktree) and counts against the review budget unless it is cleanup,
# superseded or stale. Counted items come first, the longest
# waiting first. repos has each repo's counted lines against its policy's
# review_budget, for the repos with items.
#
# Each repo's staged worktrees, open PRs and trails are read at once (see
# _shep_workers_read): each read can take seconds, and one after another they
# outgrew the queue's cap (bercail-f6ux).
_shep_queue_json() {
  local repos="$1" desks="$2" records="$3" path issue title desk space main review trails branches login="" live fd items="" policy rc=0
  local -a order=() fds=()
  local -A rows=()
  live="$(_shep_live_spaces)" || live=""
  while IFS=$'\x1f' read -r path issue title desk space; do
    main="$(_shep_main_of "$path")" || continue
    jq -e --arg m "$main" 'any(.[]; .path == $m)' <<<"$repos" >/dev/null || continue
    [[ -n "${rows[$main]:-}" ]] || order+=("$main")
    rows[$main]+="$path"$'\x1f'"$issue"$'\x1f'"$title"$'\x1f'"$desk"$'\x1f'"$space"$'\n'
  done < <(jq -nr --argjson repos "$repos" --argjson desks "$desks" --argjson rec "$records" '
    def one(f): map(f | select(. != null and . != "")) | first // "";
    ([$repos[].issues // [] | .[] | {key: .id, value: .title}] | from_entries) as $titles
    | ([$desks[] | select(.bg | not) | select(.cwd) | {path: .cwd, issue, title, desk: .address, space, state}]
       + [$rec | to_entries[] | select(.value.path) | {path: .value.path, issue: .value.issue, title: null, desk: .value.desk, space: .value.space, state: "gone"}]) as $all
    | ($all | group_by(.path)[] | select(all(.[]; .state != "working")))
    | one(.issue) as $issue
    | [.[0].path, $issue, (one(.title) | if . == "" then $titles[$issue] // "" else . end), one(.desk), one(.space)] | join("\u001f")')
  for main in "${order[@]}"; do
    exec {fd}< <(_shep_queue_staged "$main" "$records" "$live" <<<"${rows[$main]%$'\n'}" && printf 'ok\n')
    fds+=("$fd")
  done
  while IFS= read -r main; do
    review="$(jq -c --arg m "$main" '(first(.[] | select(.path == $m)) // {}) | .review' <<<"$repos")"
    # The desk that made the change, by its handoff's branch, lends its worktree and space.
    exec {fd}< <(trails="$(_shep_queue_trails "$main" "$review" </dev/null)" \
      && jq -c --argjson rec "$records" --arg m "$main" '[.[] | . as $i
        | ([$rec[] | select(.repo == $m and .branch == $i.branch)] | first) as $r
        | $i + (if $r then {path: $r.path, space: $r.space} else {} end)]' <<<"$trails" \
      && printf 'ok\n')
    fds+=("$fd")
  done < <(jq -r '.[] | select(.backend == "entire") | .path' <<<"$repos")
  while IFS= read -r main; do
    grep -q 'github\.com[:/]' <<<"$(git -C "$main" remote -v 2>/dev/null)" || continue
    if [[ -z "$login" ]]; then
      login="$(_git_backend_bounded 2 "${GH_BIN:-gh}" api user --jq .login </dev/null 2>/dev/null)" || login=""
      [[ -n "$login" ]] || { rc=1; break; }
    fi
    # A handoff's worktree is <main>.<branch>, gone or not.
    branches="$(jq -c --arg m "$main" '[.[] | select(.branch and .path and .repo == $m) | .branch]' <<<"$records")"
    exec {fd}< <(_shep_queue_prs "$main" "$login" "$branches" </dev/null && printf 'ok\n')
    fds+=("$fd")
  done < <(jq -r '.[] | select(.backend == "gh") | .path' <<<"$repos")
  _shep_workers_read items "${fds[@]}" && ((rc == 0)) && items="$(jq -sc 'add // []' <<<"$items")" || return 1
  jq -r '[.[].repo] | unique[]' <<<"$items" | while IFS= read -r main; do
    policy="$(policy_json "$main" 2>/dev/null | jq -c .policy)" || policy=""
    printf '%s\t%s\n' "$main" "${policy:-$POLICY_DEFAULTS}"
  done | jq -nRc --argjson items "$items" --argjson defaults "$POLICY_DEFAULTS" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    ([inputs | split("\t") | {key: .[0], value: (.[1] | fromjson? // $defaults)}] | from_entries) as $p
    | ($items | map(.counts = (.state | IN("cleanup", "superseded", "stale") | not))
        | sort_by([(if .counts then 0 else 1 end), (.since // "~")])) as $items
    | {schema: "bercail.queue/v1", at: $at, items: $items,
       repos: [$items | group_by(.repo)[] | .[0].repo as $r | map(select(.counts)) as $w
         | ([$w[] | .lines // .change.lines] | add // 0) as $lines
         | {path: $r, lines: $lines, changes: ($w | length),
            budget: ($p[$r].review_budget // $defaults.review_budget),
            over: ($lines > ($p[$r].review_budget // $defaults.review_budget))}]}'
}

# The queue for a person to read: what waits, by repo, then each repo's
# cleanup and superseded worktrees, which do not count, and one line for its
# stale worktrees with no Herdr space. With .repo (shep queue
# --repo), a last line says whether that repo is over its review budget, so
# Shep asks before another desk there.
_shep_queue_text() {
  jq -nr --arg home "$HOME" --argjson q "$1" "$SHEP_JQ_DEFS"'
    def size: (.lines // .change.lines) as $n | "\($n) line\(if $n == 1 then "" else "s" end)";
    def findings: .findings | if .open == 0 then "no open findings"
      else "\(.open) open finding\(if .open == 1 then "" else "s" end)"
        + (["high", "medium", "low"] as $k | [$k[] as $s | .[$s] | select(. > 0) | "\(.) \($s)"]
           | if length > 0 then " (\(join(", ")))" else "" end) end;
    def line:
      if .kind == "pr" then "PR #\(.number): \(.title // "" | flat | cut(70)) · \(size) · \(.url)"
      elif .kind == "trail" then "trail \(.trail): \(.title // "" | flat | cut(70)) · change \(.repository)/\(.number) · \(findings)"
        + " · gates: \(.gates.text) · \(.url)"
      else (if .issue then .issue + (if .title then ": \(.title | flat | cut(70))" else "" end) else (.path | tilde) end)
        + ((.change.files - .change.left_out.files) as $n | " · \(size) staged in \($n) file\(if $n == 1 then "" else "s" end)")
        + " · stakes \(.change.stakes)" + (if .counts and .change.review == "required" then ", needs the person'"'"'s LGTM" else "" end)
        + (.described | if . == null then "" elif .ok then " · described" else " · describe check fails: \(.why | flat | cut(90))" end)
        + ({unknown: " · state unknown: \(.why)", cleanup: " · \(.why), a cleanup candidate",
            superseded: " · \(.why)" + (if (.by // "") | startswith("/") then " (\(.by | tilde))" else "" end)}[.state] // "")
        + (if .issue then " · \(.path | tilde)" else "" end) end;
    ($q.items | map(select(.counts))) as $w
    | if ($q.items | length) == 0 then (if $q.repo then "Review queue: nothing waits on the person." else empty end)
    else
      (if ($w | length) == 0 then "Review queue: nothing waits on the person."
       else "Review queue: \([$q.repos[].lines] | add) lines in \($w | length) change\(if ($w | length) == 1 then "" else "s" end)" end),
      ($q.repos[] | . as $r
        | (if $r.changes > 0 then "\($r.path | tilde): \($r.lines) of \($r.budget) lines" + (if $r.over then ", over its review budget" else "" end)
           else "\($r.path | tilde): nothing waits" end),
          ($w[] | select(.repo == $r.path) | "- " + line),
          ($q.items[] | select(.repo == $r.path and (.counts | not) and .state != "stale") | "- not counted: " + line),
          ([$q.items[] | select(.repo == $r.path and .state == "stale") | .path | tilde]
           | select(length > 0)
           | "- not counted: \(length) stale worktree\(if length == 1 then "" else "s" end) with no Herdr space, cleanup candidates: \(join(", "))"))
    end,
    ($q.repo // empty
      | if .over then
          "\(.path | tilde) is over its review budget: \(.lines) lines wait on the person, the budget is \(.budget). Report it; accepted work is not held for review budget."
        else "\(.path | tilde): \(.lines) of \(.budget) lines wait on the person; a new desk fits its review budget." end)'
}

# How long the queue's status sources get, in seconds. Tests raise it so a
# loaded machine cannot turn their queue into UNKNOWN.
SHEP_QUEUE_WAIT="${BERCAIL_SHEP_QUEUE_WAIT:-6}"

shep_queue() {
  local out rc=0
  _shep_need_policy
  out="$(_git_backend_bounded "$SHEP_QUEUE_WAIT" "${BERCAIL_SELF:-bercail}" shep queue-snapshot "$@")" || rc=$?
  if ((rc)); then
    if [[ " $* " == *" --json "* ]]; then
      printf '{"schema":"bercail.queue/v1","status":"unknown","items":null,"repos":null,"error":"status sources failed or exceeded %ss; not a dispatch gate"}\n' "$SHEP_QUEUE_WAIT"
    else
      printf 'Review queue: UNKNOWN (status sources failed or exceeded %ss); accepted work can still dispatch.\n' "$SHEP_QUEUE_WAIT" >&2
    fi
    return "$rc"
  fi
  [[ -z "$out" ]] || printf '%s\n' "$out"
}

_shep_queue_snapshot() {
  local repo="" main="" queue budget json=0 repos desks records backends path
  local usage="usage: bercail shep queue [--repo DIR] [--json]"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo) repo="${2:-}"; shift 2 || shift $# ;;
      --repo=*) repo="${1#*=}"; shift ;;
      --json) json=1; shift ;;
      *) _shep_err "$usage"; return 1 ;;
    esac
  done
  _shep_need_policy
  if [[ -n "$repo" ]]; then
    main="$(_shep_main_of "$repo")" || { _shep_err "$repo is not a git checkout"; return 1; }
  fi
  # The outer queue deadline bounds required desk details as one scan, with no per-desk polling delay.
  desks="$(_shep_desks_json "${HC_BIN:-hc}")" || return 1
  records="$(_shep_records_json)" || return 1
  if [[ -n "$main" ]]; then
    repos="$(jq -nc --arg path "$main" --arg backend "$(git_backend "$main")" '[{path:$path,backend:$backend}]')"
  else
    # The queue reads issue details only for staged candidates, not the board's full issue lists.
    backends="$(while IFS=$'\t' read -r path _; do
      printf '%s\t%s\n' "$path" "$(git_backend "$path" 2>/dev/null)"
    done < <(_shep_repo_list "$desks"))"
    repos="$(jq -Rnc '[inputs | split("\t") | select(length == 2) | {path: .[0], backend: .[1]}]' <<<"$backends")"
  fi
  queue="$(_shep_queue_json "$repos" "$desks" "$records")" || return 1
  if [[ -n "$main" ]]; then
    budget="$(policy_json "$main" 2>/dev/null | jq -r .policy.review_budget)" || budget=""
    queue="$(jq -c --arg m "$main" --argjson b "${budget:-$(jq .review_budget <<<"$POLICY_DEFAULTS")}" '
      . + {repo: ((.repos[] | select(.path == $m)) // {path: $m, lines: 0, changes: 0} | .budget = $b | .over = (.lines > $b))}' <<<"$queue")"
  fi
  if ((json)); then
    jq . <<<"$queue"
    return 0
  fi
  _shep_queue_text "$queue"
}

# --- standing rules ---------------------------------------------------------------

SHEP_PREFS_HEAD="# Standing rules the person gave Shep. Edit them with bercail shep remember, forget, and list."

shep_prefs_file() {
  printf '%s/preferences.md' "$(shep_state_dir)"
}

# The rules, one "- DATE [SCOPE] RULE" line each.
_shep_rules() {
  local file
  file="$(shep_prefs_file)"
  [[ ! -f "$file" ]] || grep '^- ' "$file" || true
}

shep_remember() {
  local rule="" scope="all" file line
  local usage='usage: bercail shep remember "RULE" [--scope all|REPO|ISSUE|DESK]'
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --scope) scope="${2:-}"; shift 2 || shift $# ;;
      --scope=*) scope="${1#*=}"; shift ;;
      -*) _shep_err "$usage"; return 1 ;;
      *) [[ -z "$rule" ]] || { _shep_err "$usage (quote the rule)"; return 1; }; rule="$1"; shift ;;
    esac
  done
  rule="$(printf '%s' "$rule" | tr '\n\t\r' '   ' | sed 's/  */ /g; s/^ //; s/ $//')"
  scope="$(printf '%s' "$scope" | tr -d '[]\n\t\r' | sed 's/^ *//; s/ *$//')"
  [[ -n "$rule" && -n "$scope" ]] || { _shep_err "$usage"; return 1; }
  file="$(shep_prefs_file)"
  mkdir -p "$(dirname "$file")"
  [[ -s "$file" ]] || printf '%s\n\n' "$SHEP_PREFS_HEAD" >"$file"
  # ENVIRON, not -v: awk would read a backslash in the rule as an escape.
  line="$(SHEP_WANT="[$scope] $rule" awk '/^- / && substr($0, index($0, "[")) == ENVIRON["SHEP_WANT"] { print substr($0, 3); exit }' "$file")"
  if [[ -n "$line" ]]; then
    printf 'already a standing rule: %s\n' "$line"
    return 0
  fi
  line="- $(date +%Y-%m-%d) [$scope] $rule"
  printf '%s\n' "$line" >>"$file"
  printf 'remembered: %s\n' "${line#- }"
}

shep_list() {
  local rules
  [[ $# -eq 0 ]] || { _shep_err "usage: bercail shep list"; return 1; }
  rules="$(_shep_rules)"
  if [[ -z "$rules" ]]; then
    printf 'no standing rules yet; add one with: bercail shep remember "RULE" [--scope SCOPE]\n'
    return 0
  fi
  awk '{ print NR ". " substr($0, 3) }' <<<"$rules"
}

# Drops rule N (as list numbers them), keeping every other line.
shep_forget() {
  local n="${1:-}" file count gone tmp
  [[ $# -eq 1 && "$n" =~ ^[0-9]+$ && "$n" -ge 1 ]] || { _shep_err "usage: bercail shep forget N (N from bercail shep list)"; return 1; }
  file="$(shep_prefs_file)"
  count="$(_shep_rules | grep -c '' || true)"
  [[ "$n" -le "$count" ]] || { _shep_err "there is no rule $n; bercail shep list shows $count"; return 1; }
  gone="$(_shep_rules | sed -n "${n}p")"
  tmp="$(mktemp "$file.XXXXXX")"
  awk -v n="$n" '/^- / && ++i == n { next } { print }' "$file" >"$tmp" && mv "$tmp" "$file"
  printf 'forgot: %s\n' "${gone#- }"
}

# --- mistakes ledger -------------------------------------------------------------------

# One JSON line per mistake seen: {at, key, what, repo, issue}. A group seen twice
# asks for a fix in the system instead of another fix by hand.
shep_mistakes_file() {
  printf '%s/mistakes.jsonl' "$(shep_state_dir)"
}

# {groups: {ID: {name, against}}, keys: {KEY: ID}}: one cause shows up under many
# keys, so the twice-rule counts a key's group, and the group says what it counts
# against.
shep_mistake_groups_file() {
  printf '%s/mistake-groups.json' "$(shep_state_dir)"
}

SHEP_MISTAKE_USAGE='usage: bercail shep mistake KEY "WHAT" [--group ID] [--repo DIR] [--issue ID] | mistake group ID "NAME" --against process|tool|conduct [KEY...] | mistake list'
SHEP_MISTAKE_KEY_ERR="KEY is a short name in a-z, 0-9 and -, the same each time the mistake shows up (bercail shep mistake list shows the ones in use)"
SHEP_MISTAKE_JQ_DEFS="$SHEP_JQ_DEFS"'
  def times: "\(.) time\(if . == 1 then "" else "s" end)";
  def where: [.issue, (.repo // empty | tilde)] | map(select(.));
  def against: {process: "the process", tool: "a tool", conduct: "conduct"}[.] // .;'

_shep_mistake_groups() {
  local file
  file="$(shep_mistake_groups_file)"
  if [[ -s "$file" ]]; then jq -c '{groups: (.groups // {}), keys: (.keys // {})}' "$file"
  else printf '{"groups":{},"keys":{}}\n'; fi
}

# Replaces the groups file with stdin, whole.
_shep_mistake_groups_write() {
  local file tmp
  file="$(shep_mistake_groups_file)"
  mkdir -p "$(dirname "$file")"
  tmp="$(mktemp "$file.XXXXXX")"
  cat >"$tmp" && mv "$tmp" "$file"
}

shep_mistake() {
  local key="" what="" group="" repo="" issue="" main="" file groups had
  [[ "${1:-}" != list ]] || { shift; _shep_mistake_list "$@"; return; }
  [[ "${1:-}" != group ]] || { shift; _shep_mistake_group "$@"; return; }
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --group) group="${2:-}"; shift 2 || shift $# ;;
      --group=*) group="${1#*=}"; shift ;;
      --repo) repo="${2:-}"; shift 2 || shift $# ;;
      --repo=*) repo="${1#*=}"; shift ;;
      --issue) issue="${2:-}"; shift 2 || shift $# ;;
      --issue=*) issue="${1#*=}"; shift ;;
      -*) _shep_err "$SHEP_MISTAKE_USAGE"; return 1 ;;
      *)
        if [[ -z "$key" ]]; then key="$1"
        elif [[ -z "$what" ]]; then what="$1"
        else _shep_err "$SHEP_MISTAKE_USAGE (quote WHAT)"; return 1; fi
        shift ;;
    esac
  done
  what="$(printf '%s' "$what" | tr '\n\t\r' '   ' | sed 's/  */ /g; s/^ //; s/ $//')"
  [[ -n "$key" && -n "$what" ]] || { _shep_err "$SHEP_MISTAKE_USAGE"; return 1; }
  [[ "$key" =~ ^[a-z0-9][a-z0-9-]{0,39}$ ]] || { _shep_err "$SHEP_MISTAKE_KEY_ERR"; return 1; }
  [[ -z "$issue" ]] || _shep_job_id_ok "$issue" || return 1
  if [[ -n "$repo" ]]; then
    _shep_need_policy
    main="$(_shep_main_of "$repo")" || { _shep_err "$repo is not a git checkout"; return 1; }
  fi
  groups="$(_shep_mistake_groups)" || { _shep_err "$(shep_mistake_groups_file) is not JSON; fix or remove it"; return 1; }
  had="$(jq -r --arg k "$key" '.keys[$k] // empty' <<<"$groups")"
  if [[ -z "$group" ]]; then
    group="$had"
    [[ -n "$group" ]] || { _shep_err "$key is in no group yet: give it a --group (bercail shep mistake list shows the groups)"; return 1; }
  elif [[ -n "$had" && "$had" != "$group" ]]; then
    # A move changes the count of every past entry, so it is its own command.
    _shep_err "$key is in group $had; move it, with all its entries, by: bercail shep mistake group $group \"NAME\" --against KIND $key"
    return 1
  elif ! jq -e --arg g "$group" '.groups | has($g)' <<<"$groups" >/dev/null; then
    _shep_err "there is no group $group; make it with: bercail shep mistake group $group \"NAME\" --against process|tool|conduct"
    return 1
  elif [[ -z "$had" ]]; then
    groups="$(jq -c --arg k "$key" --arg g "$group" '.keys[$k] = $g' <<<"$groups")"
    _shep_mistake_groups_write <<<"$groups"
  fi
  file="$(shep_mistakes_file)"
  mkdir -p "$(dirname "$file")"
  jq -nc --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg key "$key" --arg what "$what" --arg repo "$main" --arg issue "$issue" \
    '{at: $at, key: $key, what: $what} + (if $repo == "" then {} else {repo: $repo} end) + (if $issue == "" then {} else {issue: $issue} end)' >>"$file"
  printf 'recorded %s (%s): %s\n' "$key" "$group" "$what"
  jq -nr --arg home "$HOME" --arg g "$group" --argjson groups "$groups" "$SHEP_MISTAKE_JQ_DEFS"'
    [inputs | select(type == "object" and $groups.keys[.key] == $g)] as $es | ($es | length) as $n
    | select($n >= 2) | $es[0] as $f | $groups.groups[$g] as $gr | ($es | map(.key) | unique | length) as $k
    | "\($g) \($gr.name) has now happened \($n | times) under \($k) key\(if $k == 1 then "" else "s" end); the first: \($f.at[0:10])"
      + ($f | where | if length > 0 then " (" + join(", ") + ")" else "" end) + ".",
      {process: "It counts against the process, not the desks: file an issue that removes or simplifies the step that caused it, instead of adding a check on the desks.",
       conduct: "A mistake seen twice is fixed in the system: file an issue for a rule in SHEP.md or a skill, or a check that catches it, instead of fixing it by hand again."}[$gr.against]
      // "A mistake seen twice is fixed in the system: file an issue for a guardrail (a lint rule, a test, the guard, or a doctor check) instead of fixing it by hand again."' "$file"
}

# Makes or renames group ID and moves each KEY into it, recorded yet or not.
_shep_mistake_group() {
  local id="" name="" against="" key groups usage='usage: bercail shep mistake group ID "NAME" --against process|tool|conduct [KEY...]'
  local -a keys=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --against) against="${2:-}"; shift 2 || shift $# ;;
      --against=*) against="${1#*=}"; shift ;;
      -*) _shep_err "$usage"; return 1 ;;
      *)
        if [[ -z "$id" ]]; then id="$1"
        elif [[ -z "$name" ]]; then name="$1"
        else keys+=("$1"); fi
        shift ;;
    esac
  done
  name="$(printf '%s' "$name" | tr '\n\t\r' '   ' | sed 's/  */ /g; s/^ //; s/ $//')"
  [[ -n "$id" && -n "$name" ]] || { _shep_err "$usage"; return 1; }
  [[ "$id" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,15}$ ]] || { _shep_err "ID is a short name in A-Z, a-z, 0-9 and -, such as G2"; return 1; }
  [[ "$against" =~ ^(process|tool|conduct)$ ]] \
    || { _shep_err "--against is process, tool or conduct: what the group's mistakes count against, and so what fixes them"; return 1; }
  for key in "${keys[@]}"; do
    [[ "$key" =~ ^[a-z0-9][a-z0-9-]{0,39}$ ]] || { _shep_err "$SHEP_MISTAKE_KEY_ERR"; return 1; }
  done
  groups="$(_shep_mistake_groups)" || { _shep_err "$(shep_mistake_groups_file) is not JSON; fix or remove it"; return 1; }
  groups="$(jq -c --arg id "$id" --arg name "$name" --arg against "$against" \
    '.groups[$id] = {name: $name, against: $against} | .keys += ($ARGS.positional | map({key: ., value: $id}) | from_entries)' \
    --args "${keys[@]}" <<<"$groups")"
  _shep_mistake_groups_write <<<"$groups"
  jq -r --arg home "$HOME" --arg id "$id" "$SHEP_MISTAKE_JQ_DEFS"'.groups[$id] as $g | ([.keys[] | select(. == $id)] | length) as $k
    | "group \($id) \($g.name): counts against \($g.against | against), \($k) key\(if $k == 1 then "" else "s" end)"' <<<"$groups"
}

# Each group with its count, the most frequent first, then its keys the same
# way, then one line per time it happened. Keys in no group come last.
_shep_mistake_list() {
  local file groups
  [[ $# -eq 0 ]] || { _shep_err "$SHEP_MISTAKE_USAGE"; return 1; }
  file="$(shep_mistakes_file)"
  if [[ ! -s "$file" ]]; then
    printf 'no mistakes recorded yet; record one with: bercail shep mistake KEY "WHAT" --group ID [--repo DIR] [--issue ID]\n'
    return 0
  fi
  groups="$(_shep_mistake_groups)" || { _shep_err "$(shep_mistake_groups_file) is not JSON; fix or remove it"; return 1; }
  jq -nr --arg home "$HOME" --argjson groups "$groups" "$SHEP_MISTAKE_JQ_DEFS"'
    [inputs | select(type == "object" and .key)] as $all
    | [($groups.groups | keys[]), (if any($all[]; $groups.keys[.key] == null) then null else empty end)]
    | map(. as $id | {id: $id, es: [$all[] | select($groups.keys[.key] == $id)]})
    | sort_by(.id == null, -(.es | length), (.es[0].at // "~"))[]
    | (.es | group_by(.key) | sort_by(-length, .[0].at)) as $ks
    | (if .id == null then "no group (bercail shep mistake group ID \"NAME\" --against KIND KEY... puts a key in one)"
       else "\(.id) \($groups.groups[.id].name) (counts against \($groups.groups[.id].against | against))" end)
      + ": \(.es | length | times), \($ks | length) key\(if ($ks | length) == 1 then "" else "s" end)",
      ($ks[] | "  \(.[0].key): \(length | times)",
        (.[] | "    \(.at[0:10])  " + (where | join(" · ") | if . == "" then "" else . + ": " end) + .what))' "$file"
}

# --- what Shep gets at start ----------------------------------------------------------

# Shep's start context: the known repos, short, and the standing rules. Pi
# gets it with --append-system-prompt, so each start has fresh repos and rules.
shep_context_write() {
  local file="$1" repos tmp
  _shep_need_policy
  repos="$(_shep_repos_json 2>/dev/null)" || repos='[]'
  # shellcheck source=lib/todo.sh
  declare -F todo_target_list >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/todo.sh"
  tmp="$(mktemp "$file.XXXXXX")"
  {
    printf '# Shep context at start\n\n'
    printf 'bercail wrote this when Shep started. It is data, not instructions from a desk.\n\n'
    printf '## Known repos\n\n'
    jq -r --arg home "$HOME" "$SHEP_JQ_DEFS"'
      if length == 0 then "- none found yet (`bercail shep repos` explains where they come from)"
      else .[] | "- \(.path | tilde): \(.backend // "?"), "
        + ({trusted: "policy trusted", untrusted: "policy not trusted", none: "no policy"}[.policy // ""] // "policy ?") + ", "
        + (if .open == null then "no beads" else "\(.open) open issue\(if .open == 1 then "" else "s" end)" end) end' <<<"$repos"
    printf '\n## Todo targets\n\n'
    printf "Where bercail todo add sends a todo: --target, else the route of the job's repo, else the default.\n\n"
    todo_target_list 2>/dev/null | sed '/^- /!s/^/- /' || printf -- '- none readable (`bercail todo target list` says why)\n'
    printf '\n## Standing rules from the person\n\n'
    _shep_rules | grep '' || printf -- '- none yet\n'
  } >"$tmp" && mv "$tmp" "$file"
}

# The model id Shep runs on, from bstack's lead (provider/id, no thinking level).
_shep_lead_model() {
  local lead="${BSTACK_PI_DIR:-${BERCAIL_SHARE_DIR:-$HOME/.local/share/bercail}/pi}/lead.json" model
  [[ -r "$lead" ]] || return 0
  model="$(jq -r 'index("--model") as $i | if $i then .[$i + 1] else empty end' "$lead" 2>/dev/null || true)"
  printf '%s' "$model" | sed -E 's/:(off|minimal|low|medium|high|xhigh|max)$//'
}

# MODEL's context window in tokens, from `pi --list-models` with the lead's
# extensions loaded (a provider can come from one). Empty when Pi does not list it.
_shep_model_window() {
  local model="$1" provider id ext
  local -a argv=(pi --offline --list-models)
  provider="${model%%/*}"
  id="${model#*/}"
  argv+=("$id")
  while IFS= read -r ext; do
    [[ -n "$ext" ]] && argv+=(-e "$ext")
  done < <(jq -r '. as $a | range(0; length) | select($a[.] == "-e") | $a[. + 1]' \
    "${BSTACK_PI_DIR:-${BERCAIL_SHARE_DIR:-$HOME/.local/share/bercail}/pi}/lead.json" 2>/dev/null || true)
  (cd "$(shep_state_dir)" 2>/dev/null || cd /; env -u ANTHROPIC_API_KEY -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN \
    "${argv[@]}" </dev/null 2>/dev/null) | awk -v p="$provider" -v m="$id" '
    $1 == p && $2 == m {
      v = $3; mult = 1
      if (v ~ /[Kk]$/) { mult = 1000; sub(/[Kk]$/, "", v) }
      else if (v ~ /[Mm]$/) { mult = 1000000; sub(/[Mm]$/, "", v) }
      if (v ~ /^[0-9]+(\.[0-9]+)?$/) printf "%d\n", v * mult + 0.5
      exit
    }' || true
}

# A [shep] key of config.toml that must be a whole number, else DEFAULT.
_shep_config_tokens() {
  local key="$1" default="$2" value
  value="$(toml_value "$BERCAIL_USER_CONFIG" shep "$key")"
  [[ -n "$value" ]] || { printf '%s' "$default"; return 0; }
  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    _shep_err "[shep] $key = $value in config.toml is not a number of tokens; using $default"
    value="$default"
  fi
  printf '%s' "$value"
}

# Shep's compaction, in its workspace's .pi/settings.json (Pi's project
# settings; Shep runs Pi there with --approve so they load). Auto-compaction
# stays on. For the lead model, reserveTokens = window - compact_at, so Pi
# compacts once the context passes compact_at, or sooner on the Claude bridge;
# keepRecentTokens is keep_recent for every model. The default compact_at on a
# smaller window leaves Pi's threshold without a word; one the person set says
# why it could not apply.
# Other keys in the file are kept.
shep_settings_write() {
  local file="$1" at keep model window="" reserve="" compaction tmp current='{}' set=0
  [[ -z "$(toml_value "$BERCAIL_USER_CONFIG" shep compact_at)" ]] || set=1
  at="$(_shep_config_tokens compact_at "$SHEP_COMPACT_AT")"
  keep="$(_shep_config_tokens keep_recent "$SHEP_KEEP_RECENT")"
  model="$(_shep_lead_model)"
  if [[ -n "$model" && "$at" -gt 0 ]]; then
    window="$(_shep_model_window "$model")"
    if [[ -z "$window" ]]; then
      _shep_err "pi --list-models does not show $model's context window; Shep compacts when that window is nearly full"
    elif ((at >= window)); then
      ((set == 0)) || _shep_err "[shep] compact_at = $at is not below $model's $window-token window; Shep compacts when the window is nearly full"
    else
      reserve=$((window - at))
    fi
  fi
  # This entry wins over the bridge's reserve in Pi's settings.json (bstack deploy).
  if [[ "$model" == claude-bridge/* && -n "$reserve" ]] && ((reserve < BSTACK_PI_BRIDGE_RESERVE)); then
    reserve="$BSTACK_PI_BRIDGE_RESERVE"
  fi
  compaction="$(jq -nc --argjson keep "$keep" --arg model "$model" --arg reserve "$reserve" '
    {enabled: true, keepRecentTokens: $keep}
    + (if $model == "" then {} else
        {modelOverrides: {($model): ({keepRecentTokens: $keep} + (if $reserve == "" then {} else {reserveTokens: ($reserve | tonumber)} end))}} end)')"
  mkdir -p "$(dirname "$file")"
  [[ ! -s "$file" ]] || current="$(jq -c 'if type == "object" then . else {} end' "$file" 2>/dev/null)" || current='{}'
  tmp="$(mktemp "$file.XXXXXX")"
  jq --argjson c "$compaction" '.compaction = $c' <<<"$current" >"$tmp" && mv "$tmp" "$file"
}
