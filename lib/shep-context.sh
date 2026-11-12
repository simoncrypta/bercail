#!/usr/bin/env bash
# shellcheck shell=bash
# What Shep knows beyond its session: the person's repos, a lean brief per
# issue, the job board, the person's standing rules, and Shep's own compaction
# settings. Sourced by lib/shep.sh.
#
#   bercail shep repos [--json]
#   bercail shep brief ISSUE [--repo DIR] [--budget CHARS]
#   bercail shep board
#   bercail shep remember "RULE" [--scope SCOPE] | forget N | list

# The policy and git-backend libs, on first use: the piped installer sources
# this file without them.
_shep_need_policy() {
  declare -F policy_json >/dev/null && return 0
  # shellcheck source=lib/policy.sh
  source "$(dirname "${BASH_SOURCE[0]}")/policy.sh"
}

# Context tokens at which Pi compacts Shep, and the recent tokens it keeps.
SHEP_COMPACT_AT=250000
SHEP_KEEP_RECENT=50000
# A report comment longer than this is cut in the brief.
SHEP_BRIEF_BUDGET=1500

_shep_hc() { "${HC_BIN:-hc}" "$@" 2>/dev/null </dev/null; }

# --- known repos ----------------------------------------------------------------

# Every folder bercail has seen a repo in, as "source<TAB>path", plus
# "<TAB>branch" for a handoff: the [git], [graphite] and [policy."<path>"] keys
# of config.toml, trusted policies, handoff records, live desks, and Shep's
# extras file (one path per line).
_shep_repo_candidates() {
  local config trust extras
  config="$(_git_backend_config_file)"
  if [[ -f "$config" ]]; then
    awk '
      /^[[:space:]]*\[/ {
        h = $0
        sub(/^[[:space:]]*\[[[:space:]]*/, "", h); sub(/[[:space:]]*\][[:space:]]*(#.*)?$/, "", h)
        sec = h
        if (h ~ /^policy\.".*"$/ || h ~ /^policy\.\047.*\047$/) print "config\t" substr(h, 9, length(h) - 9)
        next
      }
      sec == "git" || sec == "graphite" {
        line = $0; sub(/^[[:space:]]*/, "", line); q = substr(line, 1, 1)
        if (q != "\"" && q != "\047") next
        line = substr(line, 2); i = index(line, q)
        if (i > 1) print "config\t" substr(line, 1, i - 1)
      }' "$config"
  fi
  trust="$(policy_trust_file)"
  [[ ! -f "$trust" ]] || jq -r 'keys[] | "trust\t" + .' "$trust" 2>/dev/null || true
  [[ ! -f "$(notify_handoffs_file)" ]] || jq -nrR 'inputs | fromjson? | select(type == "object" and (.path | type) == "string")
    | ["handoffs", .path, (.branch // "")] | @tsv' "$(notify_handoffs_file)" 2>/dev/null || true
  _shep_desks_json | jq -r '.[] | select(.cwd) | "desks\t" + .cwd' 2>/dev/null || true
  extras="$(shep_state_dir)/repos"
  [[ ! -f "$extras" ]] || awk '{ sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, "") } $0 != "" && !/^#/ { print "extras\t" $0 }' "$extras"
  return 0
}

# Main checkouts, one "path<TAB>source,source" line each, sorted by path.
# Candidates that are not a git checkout any more are dropped.
_shep_repo_list() {
  local src path branch main
  _shep_repo_candidates | awk -F'\t' '$2 != "" && !seen[$0]++' | while IFS=$'\t' read -r src path branch; do
    # shellcheck disable=SC2088 # a literal ~/ from config.toml or the extras file
    [[ "$path" != "~/"* ]] || path="$HOME/${path#"~/"}"
    main="$(_shep_main_of "$path" "$branch")" || continue
    printf '%s\t%s\n' "$main" "$src"
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
  raw="$(cd "$main" && _git_backend_bounded 10 bd list --json --brief --limit 0 </dev/null 2>/dev/null)" || return 1
  jq -c '[(if type == "array" then .[] else empty end) | select(.status != "closed")
    | {id, title, status, labels: (.labels // [])}]' <<<"$raw" 2>/dev/null
}

# Known repos as a JSON array: path, git backend, policy (trusted, untrusted,
# none), open issue count (null without beads), where bercail saw the repo,
# and the open issues themselves for the board.
_shep_repos_json() {
  local main from backend policy issues
  while IFS=$'\t' read -r main from; do
    backend="$(git_backend "$main" 2>/dev/null)" || backend=""
    policy="$(policy_json "$main" 2>/dev/null \
      | jq -r 'if .file == "" then "none" elif .trusted then "trusted" else "untrusted" end' 2>/dev/null)" || policy=""
    issues="$(_shep_open_issues "$main")" || issues=null
    jq -nc --arg path "$main" --arg from "$from" --arg backend "$backend" --arg policy "$policy" --argjson issues "$issues" '
      {path: $path, backend: (if $backend == "" then null else $backend end),
       policy: (if $policy == "" then null else $policy end),
       open: (if $issues == null then null else ($issues | length) end), from: ($from | split(",")), issues: $issues}'
  done < <(_shep_repo_list) | jq -sc .
}

# jq helpers for paths and titles, shared by the views below.
SHEP_JQ_DEFS='
  def tilde: if startswith($home + "/") then "~" + .[($home | length):] else . end;
  def cut($n): if length > $n then (.[0:($n - 1)] | sub(" +$"; "")) + "…" else . end;
  def flat: gsub("[[:space:][:cntrl:]]+"; " ") | sub("^ +"; "") | sub(" +$"; "");'

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
    jq 'map(del(.issues))' <<<"$out"
    return 0
  fi
  jq -r --arg home "$HOME" --arg state "$(shep_state_dir)" "$SHEP_JQ_DEFS"'
    if length == 0 then "no repos yet: bercail learns them from handoffs, live desks, config.toml, and \($state)/repos"
    else (map(.path | tilde | length) | max) as $w
      | .[] | (.path | tilde) as $p
      | "\($p)\(if $w > ($p | length) then " " * ($w - ($p | length)) else "" end)  \(.backend // "?")  "
        + ({trusted: "policy trusted  ", untrusted: "policy untrusted", none: "no policy       "}[.policy // ""] // "policy ?        ")
        + "  " + (if .open == null then "no beads" else "\(.open) open" end) + "  (\(.from | join(", ")))"
    end' <<<"$out"
}

# --- desks, handoffs, brief, board -------------------------------------------------

# Live desks and background Sheps: address, name, cwd, state (working, done,
# blocked, idle), and the issue, title, space and model (handoff --model) on
# their labels. [] when hc does not answer.
_shep_desks_json() {
  local addr
  { _shep_hc ls --json --label bercail.role=agent || true; } \
    | jq -r '.terminals[]? | select(.state == "live") | .address' 2>/dev/null \
    | while IFS= read -r addr; do
      _shep_hc get "$addr" --json | jq -c '{address, name, cwd, state: (.status.state // "unknown"),
        issue: .labels["bercail.issue"], title: .labels["bercail.issue_title"], space: .labels["bercail.space"],
        model: .labels["bercail.model"], bg: (.labels["bercail.shep"] == "bg")}' 2>/dev/null || true
    done | jq -sc '[.[] | select(.address)]'
}

# The latest handoff record per issue: {"<id>": {desk, space, label, branch, path, model}}.
_shep_records_json() {
  local file
  file="$(notify_handoffs_file)"
  [[ -f "$file" ]] || { printf '{}'; return 0; }
  jq -ncR '[inputs | fromjson? | select(type == "object" and (.issue | type) == "string" and .issue != "")]
    | map({key: .issue, value: {desk, space, label, branch, path, model}}) | from_entries' "$file" 2>/dev/null || printf '{}'
}

# The main checkout of a folder. A handoff's worktree that is gone gives
# <main> from <main>.<branch>, the name handoff-spawn uses.
_shep_main_of() {
  local path="$1" branch="${2:-}"
  [[ -n "$path" ]] || return 1
  if [[ ! -d "$path" && -n "$branch" && "$path" == *".$branch" ]]; then
    path="${path%".$branch"}"
  fi
  [[ -d "$path" ]] || return 1
  git_backend_main "$path" 2>/dev/null
}

# The issue as bd prints it from DIR, one JSON object.
_shep_bd_issue() {
  local raw
  raw="$(cd "$1" && bd show "$2" --json 2>/dev/null </dev/null)" || return 1
  jq -ce 'if type == "array" then .[0] else . end | select(type == "object" and .id)' <<<"$raw" 2>/dev/null
}

# The last lines of a blocked desk's screen, where its question is: no blank
# lines or rules, at most 15 lines and 1200 characters.
_shep_screen_tail() {
  _shep_hc read "$1" | sed 's/[[:space:]]*$//' | grep -v '^[─━═[:space:]]*$' | tail -n 15 | cut -c1-200 | head -c 1200 || true
}

shep_brief() {
  local issue="" repo="" budget="$SHEP_BRIEF_BUDGET" records desks rec desk main="" issue_json comments screen="" candidate
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
  [[ "$issue" =~ ^[A-Za-z0-9._-]+$ ]] || { _shep_err "issue id '$issue' has characters a beads id does not"; return 1; }
  _shep_need_policy
  [[ "$budget" =~ ^[0-9]+$ && "$budget" -ge 200 ]] || { _shep_err "--budget takes a number of characters, 200 or more"; return 1; }
  records="$(_shep_records_json)"
  desks="$(_shep_desks_json)"
  rec="$(jq -c --arg id "$issue" '.[$id] // null' <<<"$records")"
  desk="$(jq -c --arg id "$issue" --argjson rec "$rec" '
    (map(select(.issue == $id)) | first) // (if $rec.desk then map(select(.address == $rec.desk and (.issue // $id) == $id)) | first else null end)' <<<"$desks")"
  # The repo: --repo, else the handoff's, the desk's, or the known repo whose bd knows the issue.
  if [[ -n "$repo" ]]; then
    main="$(_shep_main_of "$repo")" || { _shep_err "$repo is not a git checkout"; return 1; }
  else
    main="$(_shep_main_of "$(jq -r '.path // empty' <<<"$rec")" "$(jq -r '.branch // empty' <<<"$rec")")" \
      || main="$(_shep_main_of "$(jq -r '.cwd // empty' <<<"$desk")")" || main=""
    if [[ -z "$main" ]]; then
      while IFS=$'\t' read -r candidate _; do
        [[ -d "$candidate/.beads" ]] && _shep_bd_issue "$candidate" "$issue" >/dev/null && { main="$candidate"; break; }
      done < <(_shep_repo_list)
    fi
  fi
  [[ -n "$main" ]] || { _shep_err "no known repo has $issue; pass its checkout with --repo"; return 1; }
  issue_json="$(_shep_bd_issue "$main" "$issue")" \
    || { _shep_err "bd does not know $issue in $main; pass its checkout with --repo"; return 1; }
  comments="$(cd "$main" && bd comments "$issue" --json 2>/dev/null </dev/null | jq -c 'if type == "array" then . else [] end' 2>/dev/null)" || comments='[]'
  [[ -n "$comments" ]] || comments='[]'
  if [[ "$(jq -r '.state // empty' <<<"$desk")" == blocked ]]; then
    screen="$(_shep_screen_tail "$(jq -r .address <<<"$desk")")"
  fi
  jq -nr --arg home "$HOME" --arg repo "$main" --argjson issue "$issue_json" --argjson comments "$comments" \
    --argjson rec "$rec" --argjson desk "$desk" --arg screen "$screen" --argjson budget "$budget" "$SHEP_JQ_DEFS"'
    def who: if $desk.bg then "background Shep \($desk.name // $desk.address)" else "desk \($desk.address)" end;
    def trim($n; $id):
      if length <= $n then .
      else (($n * 2 / 3) | floor) as $h | ($n - $h) as $t
        | .[0:$h] + "\n[… \(length - $n) characters cut; the whole comment: bd comments \($id)]\n" + .[(length - $t):] end;
    ($issue.id) as $id
    | ([$comments | to_entries[] | select((.value.text // "") | startswith("bercail handoff:") | not)]) as $reports
    | "\($id): \($issue.title // "" | flat)",
      ([$issue.status, (if $issue.priority != null then "P\($issue.priority)" else empty end), $issue.issue_type]
        | map(select(. != null and . != "")) | join(" "))
        + (if ($issue.labels // []) | length > 0 then " · labels \($issue.labels | join(", "))" else "" end)
        + " · repo \($repo | tilde)",
      ([ (if $desk then "\(who) \($desk.state)" elif $rec.desk then "desk \($rec.desk) gone" else "no desk" end),
         (if ($desk.space // $rec.space) then "space " + ([$rec.label, ($desk.space // $rec.space)] | map(select(.)) | if length == 2 then "\(.[0]) (\(.[1]))" else .[0] end) else empty end),
         (if $rec.branch then "branch \($rec.branch)" else empty end),
         (if ($rec.path // $desk.cwd) then "worktree \(($rec.path // $desk.cwd) | tilde)" else empty end),
         ((if $desk then $desk.model else $rec.model end) | if . then "model \(.)" else empty end) ] | join(" · ")),
      (if $screen != "" then "\(who) is blocked; its screen ends with:", ($screen | split("\n")[] | "  | " + .),
        "(the whole screen: hc read \($desk.address) --lines 60)" else empty end),
      (if ($reports | length) == 0 then
         "no report yet (\($comments | length) comment\(if ($comments | length) == 1 then "" else "s" end); bd comments \($id))"
       else ($reports[-1].value) as $c
         | "latest report: comment \($reports[-1].key + 1) of \($comments | length), \($c.author // "?") at \($c.created_at // "?" | sub("T"; " ") | sub(":[0-9]{2}(\\.[0-9]+)?Z$"; "")) (\($c.text | length) characters):",
           ($c.text | gsub("\n{3,}"; "\n\n") | sub("\n+$"; "") | trim($budget; $id))
       end)'
}

# One line per open job across the known repos, then what waits on the person.
# A job is an issue that is not closed and has a live desk or status
# in_progress or blocked. The rest of a repo's open issues are a count, with
# how many of them were handed off to a desk that is gone.
shep_board() {
  local repos desks records
  [[ $# -eq 0 ]] || { _shep_err "usage: bercail shep board"; return 1; }
  _shep_need_policy
  repos="$(_shep_repos_json)"
  desks="$(_shep_desks_json)"
  records="$(_shep_records_json)"
  jq -nr --arg home "$HOME" --argjson repos "$repos" --argjson desks "$desks" --argjson rec "$records" "$SHEP_JQ_DEFS"'
    def who($d): if $d.bg then "background Shep \($d.name // $d.address)" else "desk \($d.address)" end;
    def head($j): "\($j.id): \($j.title // "" | flat | cut(70))";
    ($desks | map(select(.issue)) | map({key: .issue, value: .}) | from_entries) as $live
    | [ $repos[] | . as $r | ($r.issues // [])[] | . as $i | ($rec[$i.id]) as $h | ($live[$i.id]) as $d
        | select($d or $i.status == "in_progress" or $i.status == "blocked")
        | {repo: $r.path, id: $i.id, title: $i.title, status: $i.status, desk: $d, rec: $h} ] as $jobs
    | ([$repos[].issues // [] | .[].id]) as $open
    | ( $repos[] | . as $r | [$jobs[] | select(.repo == $r.path)] as $mine | select($mine | length > 0)
        | ([$mine[].id]) as $ids
        | ([$r.issues[] | select(.id as $x | ($ids | index($x) | not) and $rec[$x].desk)] | length) as $gone
        | "\($r.path | tilde): \($mine | length) job\(if ($mine | length) == 1 then "" else "s" end)"
          + (if ($r.open - ($mine | length)) > 0 then ", \($r.open - ($mine | length)) other open issues"
              + (if $gone > 0 then " (\($gone) handed off to a desk that is gone)" else "" end) else "" end),
          ($mine[] | "- " + head(.)
            + (if .status != "open" then " [\(.status)]" else "" end)
            + " · " + (if .desk then "\(who(.desk)) \(.desk.state)" elif .rec.desk then "desk \(.rec.desk) gone" else "no desk" end)
            + " · " + (.rec.branch // "-")
            + ((if .desk then .desk.model else .rec.model end) | if . then " · model \(.)" else "" end)) ),
      ([ $repos[] | . as $r | select(([$jobs[] | select(.repo == $r.path)] | length) == 0)
         | "\($r.path | tilde) (" + (if .open == null then "no beads" else "\(.open) open" end) + ")" ]
       | if length > 0 then "Other repos: " + join(", ") else empty end),
      ([ $desks[] | select(.issue and (.issue as $x | $open | index($x) | not)) | "\(who(.)) \(.state) (\(.issue))" ]
       | if length > 0 then "Desks on closed or unknown issues: " + join(", ") else empty end),
      "Waiting on the person:",
      ([ ($jobs[] | select(.desk) | . as $j
           | if .desk.state == "blocked" then "- " + head($j) + ": \(who(.desk)) is blocked; bercail shep brief \(.id) shows what it asks"
             elif (.desk.state == "done" or .desk.state == "idle") then
               "- " + head($j) + ": \(who(.desk)) finished; " + (if .desk.bg then "report it, then hc kill \(.desk.name // .desk.address)" else "review its staged changes in its space" end)
             else empty end),
         ($desks[] | select((.issue | not) and .state == "blocked") | "- \(who(.)) (\(.cwd // "?" | tilde)) is blocked") ]
       | if length > 0 then .[] else "- nothing" end)'
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

# --- what Shep gets at start ----------------------------------------------------------

# Shep's start context: the known repos, short, and the standing rules. Pi
# gets it with --append-system-prompt, so each start has fresh repos and rules.
shep_context_write() {
  local file="$1" repos tmp
  _shep_need_policy
  repos="$(_shep_repos_json 2>/dev/null)" || repos='[]'
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
  value="$(_bstack_toml_get shep "$key")"
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
  [[ -z "$(_bstack_toml_get shep compact_at)" ]] || set=1
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
