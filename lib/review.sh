#!/usr/bin/env bash
# shellcheck shell=bash
# bercail review-pr: review someone else's PR stack by intent and decisions.
#
# One stack is one run dir, one detached sibling worktree of the source
# checkout, and one Herdr space named by the root (bottom) PR. The run dir is
#   ${XDG_STATE_HOME:-~/.local/state}/bercail/reviews/<host>/<owner>/<repo>/stack-<root>/
# with stack.json, stack.md, and per PR and head sha
#   pr-<n>/<sha>/ pr.json intent.md diff.patch ci.json source/ review.json run.json
# The worktree is <main>.review-<root> (for example ~/Work/leftlane_app.review-123),
# registered to the source git dir. It is not under the state dir.
#
# No local checkout: a normal clone goes to $HOME/Work/<repo>, or
# $HOME/Work/<owner>-<repo> when that first path exists and is a different
# repo. Never overwrite. The review worktree is the sibling of that clone.
# A clone made here is not Graphite-initialized.
#
# Gather is plain gh and git. Diffs are git diff <parent>...<head>, not trunk.
# The decisions pass is one Pi reviewer turn per non-thin PR (bstack's
# review.json: the lead's model, read-only tools), serially in the visible desk
# (parallel and headless without Herdr).
# Each pass reads pr-<n>/<sha>/source/,
# a snapshot of the changed text files at that sha, and cannot see the worktree.
# Agents never post to GitHub.

REVIEW_SCHEMA="bercail.review/v1"
REVIEW_PR_FIELDS="number,title,body,url,author,isDraft,baseRefName,headRefName,headRefOid,baseRefOid,isCrossRepository,closingIssuesReferences,files,statusCheckRollup"

# shellcheck source=lib/stack.sh
source "$(dirname "${BASH_SOURCE[0]}")/stack.sh"
# shellcheck source=lib/review-desk.sh
source "$(dirname "${BASH_SOURCE[0]}")/review-desk.sh"

_review_root() {
  printf '%s/bercail/reviews' "${XDG_STATE_HOME:-$HOME/.local/state}"
}

# This bercail, for the commands the Stack tab runs.
_review_self() {
  if [[ -n "${BERCAIL_SELF:-}" ]]; then
    printf '%s' "$BERCAIL_SELF"
  else
    command -v bercail
  fi
}

_review_need() {
  local bin
  for bin in "$@"; do
    command -v "$bin" >/dev/null 2>&1 || die "review-pr needs $bin on PATH"
  done
}

_review_now() {
  printf '%s' "${EPOCHREALTIME:-$(date +%s)}"
}

_review_since() {
  awk -v a="$1" -v b="$(_review_now)" 'BEGIN { printf "%.1f", b - a }'
}

# Write stdin to FILE in one step: the Stack tab may read it at any time.
_review_write() {
  local tmp
  tmp="$(mktemp "$1.XXXXXX")"
  cat >"$tmp" && mv "$tmp" "$1"
}

# One process at a time per PR head and job (pass, open): a symlink to the
# owner's pid, made in one step. A lock whose owner is gone is taken over.
_review_lock() {
  local lock="$1.lock"
  # Every acquisition participates, including fresh owners. Otherwise a
  # recoverer could unlink an owner that acquired between its check and rm.
  mkdir "$lock.reap" 2>/dev/null || return 1
  if _review_locked "$1"; then
    rmdir "$lock.reap"
    return 1
  fi
  rm -f "$lock"
  local rc=0
  ln -s "${BASHPID:-$$}" "$lock" 2>/dev/null || rc=$?
  rmdir "$lock.reap"
  return "$rc"
}

_review_lock_wait() {
  local path="$1" secs="${2:-10}" i
  for ((i = 0; i < secs * 10; i++)); do
    _review_lock "$path" && return 0
    sleep 0.1
  done
  return 1
}

_review_unlock() {
  [[ "$(readlink "$1.lock" 2>/dev/null)" != "${BASHPID:-$$}" ]] || rm -f "$1.lock"
}

_review_locked() {
  local pid
  pid="$(readlink "$1.lock" 2>/dev/null)" || return 1
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

_review_passes_live() {
  local lock
  for lock in "$1"/pr-*/*/pass.lock "$1"/pr-*/*/pass.lock.reap; do
    # pass.lock is a symlink to a pid, so -e (follows the link) is false.
    [[ -L "$lock" || -d "$lock" ]] || continue
    [[ "$lock" == *.reap ]] && return 0
    _review_locked "${lock%.lock}" && return 0
  done
  return 1
}

# bercail's Herdr helpers (the worktrunk hooks use the same file). True when
# the app is running.
_review_herdr() {
  local helper="${BERCAIL_HERDR_LAYOUT:-$HOME/.config/worktrunk/herdr-layout.sh}"
  [[ -f "$helper" ]] || return 1
  if ! declare -F _wt_herdr_app_running >/dev/null; then
    # shellcheck source=/dev/null
    source "$helper"
  fi
  _wt_herdr_app_running
}

# --- source checkout ----------------------------------------------------------

_review_origin_matches() {
  local url host="${4:-}"
  url="$(git -C "$1" remote get-url origin 2>/dev/null)" || return 1
  url="${url%/}"
  url="${url%.git}"
  [[ "${url,,}" == *[/:]"${2,,}/${3,,}" ]] || return 1
  if [[ "$host" == origin.cursor.com ]]; then
    git_backend_origin_remote "$1"
  else
    ! git_backend_origin_remote "$1"
  fi
}

# Written only into a checkout this command created, never into the user's repo.
_review_marker_matches() {
  local f
  f="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)/bercail-review-repo" || return 1
  [[ -f "$f" && "$(<"$f")" == "$2/$3/$4" ]]
}

_review_is_repo() {
  _review_origin_matches "$1" "$3" "$4" "$2" || _review_marker_matches "$1" "$2" "$3" "$4"
}

_review_main_of() {
  local main
  main="$(git -C "$1" worktree list --porcelain | awk '/^worktree / { print substr($0, 10); exit }')"
  [[ -n "$main" && "$(git -C "$main" rev-parse --is-inside-work-tree 2>/dev/null)" == true ]] || return 1
  printf '%s\n' "$main"
}

# The source repo's main worktree, if one is already on disk. Empty otherwise.
_review_find_source() {
  local host="$1" owner="$2" repo="$3" dir
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    && _review_is_repo "$PWD" "$host" "$owner" "$repo"; then
    _review_main_of "$PWD" && return 0
  fi
  if _review_herdr; then
    while IFS= read -r dir; do
      [[ -d "$dir" ]] || continue
      if _review_is_repo "$dir" "$host" "$owner" "$repo"; then
        _review_main_of "$dir" && return 0
      fi
    done < <("$HERDR_APP" ls 2>/dev/null | jq -r '.spaces[]?.folder // empty' | sort -u)
  fi
  for dir in "$HOME/Work/$repo" "$HOME/Work/$owner-$repo"; do
    if [[ -e "$dir" ]] && _review_is_repo "$dir" "$host" "$owner" "$repo"; then
      _review_main_of "$dir" && return 0
    fi
  done
  return 1
}

# No local checkout: clone a normal repo outside the state dir. Do not overwrite
# an existing path that is not this repo.
_review_fallback_checkout() {
  local host="$1" owner="$2" repo="$3" slug
  slug="$host/$owner/$repo"
  local primary="$HOME/Work/$repo" alt="$HOME/Work/$owner-$repo" dest=""
  if _review_is_repo "$primary" "$host" "$owner" "$repo" 2>/dev/null; then
    dest="$primary"
  elif [[ ! -e "$primary" ]]; then
    dest="$primary"
  elif _review_is_repo "$alt" "$host" "$owner" "$repo" 2>/dev/null; then
    dest="$alt"
  elif [[ ! -e "$alt" ]]; then
    dest="$alt"
  else
    die "refusing to overwrite $primary or $alt; neither is a checkout of $slug"
  fi
  if [[ ! -e "$dest/.git" ]]; then
    mkdir -p "$(dirname "$dest")"
    if [[ "${R_BACKEND:-gh}" == origin ]]; then
      origin repo clone "$owner/$repo" "$dest" >&2 || die "could not clone $slug to $dest"
    else
      _stack_gh repo clone "$slug" "$dest" -- --quiet >&2 || die "could not clone $slug to $dest"
    fi
    printf '%s\n' "$slug" > "$(git -C "$dest" rev-parse --path-format=absolute --git-common-dir)/bercail-review-repo"
  fi
  _review_main_of "$dest"
}

# Sibling of the source main checkout. Herdr's layout helper names the space
# Review-<root>_<Repo> from this basename.
_review_sibling_path() {
  local main="$1" root="$2"
  main="$(cd "$main" && pwd -P)"
  printf '%s.review-%s' "$main" "$root"
}

# Pull refs and the root base commit into the source object DB. No branch ref
# is a destination, and FETCH_HEAD is left alone (other worktrees share it).
_review_fetch_objects() {
  local main="$1" trunk="$2" base="$3"
  shift 3
  local n sha
  local -a specs=() missing=()
  while [[ $# -ge 2 ]]; do
    n="$1"
    sha="$2"
    shift 2
    if ! git -C "$main" cat-file -e "$sha^{commit}" 2>/dev/null; then
      if [[ "${R_BACKEND:-gh}" == origin ]]; then
        specs+=("$sha")
      else
        specs+=("refs/pull/$n/head")
      fi
      missing+=("$n" "$sha")
    fi
  done
  if ! git -C "$main" cat-file -e "$base^{commit}" 2>/dev/null; then
    specs+=("refs/heads/${trunk}")
  fi
  if [[ ${#specs[@]} -gt 0 ]]; then
    GIT_TERMINAL_PROMPT=0 git -C "$main" fetch --quiet --no-write-fetch-head --no-tags --refmap= \
      --no-recurse-submodules origin "${specs[@]}" >&2 \
      || { printf 'git fetch of pull refs failed in %s\n' "$main" >&2; return 1; }
  fi
  if ! git -C "$main" cat-file -e "$base^{commit}" 2>/dev/null; then
    GIT_TERMINAL_PROMPT=0 git -C "$main" fetch --quiet --no-write-fetch-head --no-tags --refmap= \
      --no-recurse-submodules origin "$base" >&2 \
      || { printf 'could not fetch base %s into %s\n' "$base" "$main" >&2; return 1; }
  fi
  git -C "$main" cat-file -e "$base^{commit}" 2>/dev/null \
    || { printf 'base %s is not in the source object database\n' "$base" >&2; return 1; }
  local i
  for ((i = 0; i < ${#missing[@]}; i += 2)); do
    n="${missing[$i]}"
    sha="${missing[$((i + 1))]}"
    git -C "$main" cat-file -e "$sha^{commit}" 2>/dev/null || {
      printf 'head %s is not on pull/%s/head (pushed since?); run review-pr again\n' "$sha" "$n" >&2
      return 1
    }
  done
}

_review_ensure_worktree() {
  local main="$1" sibling="$2" sha="$3" a b
  if [[ -e "$sibling" ]]; then
    [[ -e "$sibling/.git" ]] || die "refusing to overwrite $sibling"
    a="$(git -C "$main" rev-parse --path-format=absolute --git-common-dir)"
    b="$(git -C "$sibling" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" \
      || die "refusing to overwrite $sibling"
    [[ "$a" == "$b" ]] || die "refusing to overwrite $sibling: not a worktree of $main"
    _review_check_worktree "$sibling"
    git -C "$sibling" switch --quiet --detach "$sha"
  else
    git -C "$main" worktree add --quiet --detach "$sibling" "$sha"
  fi
}

_review_check_worktree() {
  local wt="$1" gd
  gd="$(git -C "$wt" rev-parse --absolute-git-dir)" || return 1
  [[ ! -L "$wt" && -f "$gd/bercail-review-stack" && "$(<"$gd/bercail-review-stack")" == "$R_STACK" ]] \
    || die "refusing to switch $wt: not this stack's review worktree"
  # Detached, or on a PR's branch that review-pr checkout put it on.
  local branch
  if branch="$(git -C "$wt" symbolic-ref -q HEAD)" && branch="${branch#refs/heads/}" \
    && ! jq -e --arg b "$branch" 'any(.prs[]; .head == $b)' "$R_STACK/stack.json" >/dev/null 2>&1; then
    die "refusing to switch $wt: it is on $branch, not detached or on a PR's branch"
  fi
  [[ -z "$(git -C "$wt" status --porcelain)" ]] \
    || die "refusing to switch $wt: it has local changes"
}

# Outside the checkout, in the per-worktree git dir, so card/dir find the stack
# from the sibling cwd. Not git config, and not a file in the worktree.
_review_write_marker() {
  local gd
  gd="$(git -C "$1" rev-parse --absolute-git-dir)"
  printf '%s\n' "$2" >"$gd/bercail-review-stack"
}

_review_read_marker() {
  local gd stack
  gd="$(git rev-parse --absolute-git-dir 2>/dev/null)" || return 1
  [[ -f "$gd/bercail-review-stack" ]] || return 1
  stack="$(<"$gd/bercail-review-stack")"
  [[ -f "$stack/stack.json" ]] || return 1
  printf '%s' "$stack"
}

# --- snapshot -----------------------------------------------------------------

# One ERE for the shell predicate and the jq test, so the two call sites cannot drift.
REVIEW_LOCKISH='(^|/)(package-lock\.json|npm-shrinkwrap\.json|yarn\.lock|pnpm-lock\.yaml|bun\.lockb?|Cargo\.lock|Gemfile\.lock|poetry\.lock|uv\.lock|composer\.lock|go\.sum|mix\.lock|Podfile\.lock|flake\.lock)$|(^|/)(dist|vendor|node_modules)/|\.(min\.js|map|snap)$|[._-]generated[._-]'

_review_safe_path() {
  local p="$1" part
  [[ -n "$p" && "$p" != /* && "$p" != -* && "$p" != *:* && "$p" != *$'\n'* ]] || return 1
  local -a parts=()
  IFS=/ read -r -a parts <<<"$p"
  for part in "${parts[@]}"; do
    [[ -n "$part" && "$part" != "." && "$part" != ".." && "$part" != ".git" ]] || return 1
  done
}

# Changed text files at SHA, as regular files. A symlink blob is its target
# text, never a link. Lock and generated paths are omitted. Nothing is written
# outside DEST, and nothing is copied to the pass's cwd.
_review_snapshot() {
  local main="$1" sha="$2" base="$3" dest="$4" mb path blob entry
  rm -rf "$dest"
  mkdir -p "$dest"
  mb="$(git -C "$main" merge-base "$base" "$sha")" || return 1
  while IFS= read -r -d '' path; do
    _review_safe_path "$path" || { printf 'skipping unsafe path %s\n' "$path" >&2; continue; }
    [[ "$path" =~ $REVIEW_LOCKISH ]] && continue
    entry="$(git --literal-pathspecs -C "$main" ls-tree "$sha" -- "$path")" || return 1
    # A gitlink points into another repository, not a text file at this head.
    [[ "$entry" == "160000 "* ]] && continue
    blob="$(mktemp)"
    git -C "$main" --no-pager show "$sha:$path" >"$blob" || { rm -f "$blob"; return 1; }
    # grep treats NUL as end of pattern, so compare sizes instead.
    if [[ "$(head -c 8192 "$blob" | wc -c)" != "$(head -c 8192 "$blob" | tr -d '\0' | wc -c)" ]]; then
      rm -f "$blob"
      continue
    fi
    mkdir -p "$dest/$(dirname "$path")"
    mv "$blob" "$dest/$path"
  done < <(git -C "$main" diff-tree -r --no-commit-id --name-only --diff-filter=ACMRT -M -z "$mb" "$sha")
}

# --- gather helpers -----------------------------------------------------------

# gh pr checks exits non-zero while checks are pending or failing (and when
# there are none) but still prints the JSON. Without JSON, the rollup from gh
# pr view stands in, in the same shape.
_review_pr_view() {
  local n="$1" slug="$2"
  if [[ "${R_BACKEND:-gh}" == origin ]]; then
    local raw
    raw="$(origin pr view "$n" -R "${slug#*/}" --json number,title,body,url,author,isDraft,baseRefName,headRefName,headRefOid,baseRefOid,files)" || return 1
    jq '. + {isCrossRepository:false, closingIssuesReferences:[], statusCheckRollup:[]}
      | .author = (if (.author | type) == "object" then .author + {login:(.author.login // .author.displayName // .author.id // "")}
                   else {login:(.author // "")} end)
      | .files = [.files[]? | . + {changeType:(.changeKind // "modified")} ]' <<<"$raw"
  else
    _stack_gh pr view "$n" -R "$slug" --json "$REVIEW_PR_FIELDS"
  fi
}

_review_ci() {
  local n="$1" slug="$2" dir="$3" raw
  if [[ "${R_BACKEND:-gh}" == origin ]]; then
    raw="$(origin pr checks "$n" -R "${slug#*/}" --json name,status,conclusion,detailsUrl 2>/dev/null)" || true
    if ! jq -e 'type == "array"' <<<"$raw" >/dev/null 2>&1; then
      printf 'could not read Origin checks for PR #%s\n' "$n" >&2
      return 1
    fi
    jq '[.[] | ((.conclusion // .status // "") | ascii_upcase) as $s |
      {name, state:$s, workflow:"", link:(.detailsUrl // ""),
       bucket:(if $s == "SUCCESS" then "pass" elif ($s | IN("FAILURE","FAILING","ERROR","TIMED_OUT","ACTION_REQUIRED")) then "fail"
         elif $s == "CANCELLED" then "cancel" elif ($s | IN("SKIPPED","NEUTRAL")) then "skipping" else "pending" end)}]' <<<"$raw" | _review_write "$dir/ci.json"
    return
  fi
  raw="$(_stack_gh pr checks "$n" -R "$slug" --json name,bucket,state,workflow,link 2>/dev/null)" || true
  if jq -e 'type == "array"' <<<"$raw" >/dev/null 2>&1; then
    printf '%s\n' "$raw" | _review_write "$dir/ci.json"
    return 0
  fi
  jq '[.statusCheckRollup[]? |
      ([.conclusion, .state, .status] | map(select(. != null and . != "")) | first // "" | ascii_upcase) as $s |
      {name: (.name // .context // ""), workflow: (.workflowName // ""), state: $s,
       link: (.detailsUrl // .targetUrl // ""),
       bucket: (if $s == "SUCCESS" then "pass"
         elif ($s | IN("FAILURE", "ERROR", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE")) then "fail"
         elif $s == "CANCELLED" then "cancel"
         elif ($s | IN("SKIPPED", "NEUTRAL")) then "skipping"
         else "pending" end)}]' "$dir/pr.json" | _review_write "$dir/ci.json"
}

# Closing issues (GitHub), one JSON object per line.
_review_issues() {
  local url
  jq -r '.closingIssuesReferences[]?.url // empty' "$1" | while IFS= read -r url; do
    _stack_gh issue view "$url" --json number,title,body,url 2>/dev/null | jq -c . || true
  done
}

# Linear ids (LEF-123) in the title or body, or leading the branch name. Only
# recorded: Shep fetches them.
_review_linear_ids() {
  {
    jq -r '.title, (.body // "")' "$1"
    jq -r '.headRefName' "$1" | tr '/' '\n' | { grep -oiE '^[a-z]{2,6}-[0-9]+' || true; } | tr '[:lower:]' '[:upper:]'
  } | { grep -oE '\b[A-Z][A-Z0-9]{1,5}-[0-9]{1,6}\b' || true; } \
    | { grep -vE '^(UTF|SHA|ISO|RFC|CVE|GPT|HTTP|TLS|SSL|PEP|ES|MD|PR|CI|ID)-' || true; } | sort -u | jq -Rnc '[inputs]'
}

# Thin rules, no model: empty body, a body that only restates the title, no
# linked issue (GitHub closing issue or Linear id), or "part N of M" and nothing
# else. A JSON array of flags.
_review_thin() {
  jq -c --argjson linear "$2" '
    def norm: ascii_downcase | gsub("[^a-z0-9]+"; " ") | sub("^ "; "") | sub(" $"; "");
    def part: "(?i)\\b(part|pr)\\s*\\d+\\s*(of|/)\\s*\\d+";
    ((.body // "") | gsub("<!--[\\s\\S]*?-->"; "")) as $body
    | ($body | norm) as $b | (.title | norm) as $t
    | [ (if $b == "" then "empty_body" else empty end),
        (if $b != "" and ($b == $t or ($t | contains($b))) then "restates_title" else empty end),
        (if (.closingIssuesReferences | length) == 0 and ($linear | length) == 0 then "no_linked_issue" else empty end),
        (if ($body | test(part)) and (($body | gsub(part; "") | norm) as $rest | $rest == "" or $rest == $t)
         then "part_n_of_m_only" else empty end) ]' "$1"
}

_review_intent_md() {
  local pr="$1" issues="$2" linear="$3" thin="$4" commits="$5"
  jq -r --slurpfile issues "$issues" --argjson linear "$linear" --argjson thin "$thin" \
    --rawfile commits "$commits" --arg lockish "$REVIEW_LOCKISH" '
    def lockish: test($lockish);
    "# PR #\(.number): \(.title)",
    "",
    "- url: \(.url)",
    "- author: \(.author.login)",
    "- base: \(.baseRefName), head: \(.headRefName) @ \(.headRefOid)",
    (if .isDraft then "- draft" else empty end),
    "- thin: \(if ($thin | length) == 0 then "none" else ($thin | join(", ")) end)",
    "",
    "## Comparison clues",
    "",
    "Infer intent from diff.patch first, then compare it with these clues.",
    "Issues may be loose or sloppy; commit messages are further clues.",
    "PR title/body are the weakest clues and may be stale.",
    "",
    "## Linked issues",
    "",
    (if ($issues | length) == 0 then
       (if ((.closingIssuesReferences // []) | length) > 0 or ($linear | length) > 0
        then "Linked issue content was not fetched; comparison is unavailable."
        else "No linked issue clues to compare; still infer intent from the code." end)
     else ($issues[] | "### #\(.number) \(.title)\n\n\(.url)\n\n\(.body // "")\n") end),
    (if ($linear | length) > 0
      then "", "## Linear", "", "Detected, not fetched: \($linear | join(", ")). An id alone is not issue content."
      else empty end),
    "",
    "## Commit messages",
    "",
    (if ($commits | test("\\S")) then $commits else "(none)" end),
    "",
    "## PR body (weak hint)",
    "",
    (if (.body // "" | test("\\S")) then .body else "(empty)" end),
    "",
    "## Changed files",
    "",
    (.files[]? | "- \(.path) (+\(.additions) -\(.deletions), \(.changeType | ascii_downcase))\(if (.path | lockish) then " [lock or generated: name only]" else "" end)")
  ' "$pr"
}

_review_stack_md() {
  local stack="$1" trunk="$2" via="$3"
  jq -r --arg trunk "$trunk" --arg via "$via" '
    "# Stack #\(.root) \(.owner)/\(.repo)",
    "",
    "via \($via), trunk \($trunk)",
    "",
    (.prs | to_entries[] | "\(.key + 1). #\(.value.number) \(.value.title) — base \(.value.base) @ \(.value.base_sha[0:7]) — head \(.value.head) @ \(.value.head_sha[0:7])"),
    "",
    "## Intent",
    "",
    (.prs[] | "- #\(.number): \(if .intent == "" then .title else .intent end)")
  ' "$stack"
}

# --- the stack ----------------------------------------------------------------

# Sets R_STACK, R_N (the PR, default the stack's current), R_SHA (--head, else
# the PR's head in stack.json), R_DIR, R_WT from --stack DIR,
# $BERCAIL_REVIEW_STACK, the stack dir, or the sibling worktree's gitdir marker.
_review_load() {
  local top head=""
  R_STACK="${BERCAIL_REVIEW_STACK:-}"
  R_N=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --stack) R_STACK="${2:-}"; shift 2 ;;
      --head) head="${2:-}"; shift 2 ;;
      [0-9]*) R_N="$1"; shift ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  if [[ -z "$R_STACK" ]]; then
    if [[ -f "$PWD/stack.json" ]]; then
      R_STACK="$PWD"
    elif top="$(_review_read_marker)"; then
      R_STACK="$top"
    fi
  fi
  [[ -n "$R_STACK" && -f "$R_STACK/stack.json" ]] \
    || die "no review stack here; pass --stack DIR (bercail review-pr <url> prints it)"
  [[ -n "$R_N" ]] || R_N="$(jq -r '.current' "$R_STACK/stack.json")"
  R_SHA="$(jq -r --argjson n "$R_N" '.prs[] | select(.number == $n) | .head_sha' "$R_STACK/stack.json")"
  [[ -n "$R_SHA" && "$R_SHA" != null ]] || die "PR #$R_N is not in the stack at $R_STACK"
  R_SHA="${head:-$R_SHA}"
  R_DIR="$R_STACK/pr-$R_N/$R_SHA"
  [[ -d "$R_DIR" ]] || die "no run dir for PR #$R_N at $R_SHA"
  R_WT="$(jq -r '.worktree' "$R_STACK/stack.json")"
  R_BACKEND="$(jq -r '.git // (if .via == "origin" then "origin" elif .via == "graphite" then "gt" else "gh" end)' "$R_STACK/stack.json")"
}

_review_stack_get() {
  jq -r "$1" "$R_STACK/stack.json"
}

# One line about a PR's pass: running, else from run.json, else waiting.
_review_status() {
  local dir="$1" thin="$2"
  if _review_locked "$dir/pass"; then
    printf 'running'
  elif [[ -L "$dir/pass.lock" && ! -f "$dir/run.json" ]]; then
    printf 'failed: the pass stopped before it finished; bercail review-pr run'
  elif [[ -f "$dir/run.json" ]]; then
    jq -r 'if .status == "ready" then "ready: \(.summary)" else "\(.status): \(.reason // .summary // "")" end' "$dir/run.json"
  elif [[ "$thin" != "[]" ]]; then
    printf 'waiting: thin (%s); bercail review-pr run' "$(jq -r 'join(", ")' <<<"$thin")"
  else
    printf 'waiting: bercail review-pr run'
  fi
}

_review_ci_counts() {
  jq -c 'reduce .[]? as $c ({}; .[$c.bucket // "pending"] += 1)' "$1" 2>/dev/null || printf '{}'
}

# Detach the decisions pass from whoever asked (Shep's shell, the Stack tab).
_review_spawn() {
  local log="$1"
  shift
  if command -v setsid >/dev/null 2>&1; then
    setsid -f "$@" >"$log" 2>&1 </dev/null
  else
    nohup "$@" >"$log" 2>&1 </dev/null &
  fi
}

_review_wait_all() {
  local pid rc=0
  for pid in "$@"; do
    wait "$pid" || rc=1
  done
  return "$rc"
}

# The space and its Stack tab. Prints the space id.
# The name comes from the sibling path (Review-<root>_<Repo>), not a hand-built label.
_review_space() {
  local label space keep
  label="$(_wt_generate_session_name "$R_WT")"
  WT_HERDR_NO_DESK=1 wt_herdr_layout_create "$label" "$R_WT" >&2 || return 1
  space="$(_wt_herdr_space_by_folder "$R_WT")"
  [[ -n "$space" ]] || return 1
  if ! _review_has_mod; then
    warn "the Herdr app has no bercail-review mod, so the space has no Stack tab; run: bercail update"
  else
    keep="$(_wt_herdr_focused_space)"
    _review_mod_tab "$space" >/dev/null || return 1
    _wt_herdr_keep_user_focus "$keep"
  fi
  printf '%s' "$space"
}

# --- bercail review-pr <url-or-branch> ------------------------------------------

_review_parse_url() {
  local url="$1"
  if [[ "$url" =~ ^https?://review\.cursor\.com/pr/([^/]+)/([^/]+)/([0-9]+) ]]; then
    R_HOST=origin.cursor.com R_OWNER="${BASH_REMATCH[1]}" R_REPO="${BASH_REMATCH[2]}" R_WANT="${BASH_REMATCH[3]}"
    R_BACKEND=origin
    return
  elif [[ "$url" =~ ^https?://cursor\.com/codebase/([^/]+)/([^/]+)/pull/([0-9]+) ]]; then
    R_HOST=origin.cursor.com R_OWNER="${BASH_REMATCH[1]}" R_REPO="${BASH_REMATCH[2]}" R_WANT="${BASH_REMATCH[3]}"
    R_BACKEND=origin
    return
  fi
  [[ "$url" =~ ^https?://([^/]+)/([^/]+)/([^/]+)/pull/([0-9]+) ]] \
    || die "not a pull request URL: ${url:-(none)} (https://github.com/OWNER/REPO/pull/N)"
  R_HOST="${BASH_REMATCH[1]}"
  R_OWNER="${BASH_REMATCH[2]}"
  R_REPO="${BASH_REMATCH[3]}"
  R_WANT="${BASH_REMATCH[4]}"
}

review_start() {
  local url="" branch="" run=1 arg host owner repo n slug t0 tmp order via trunk
  local source="" root sha base main sibling space="" gather dir linear thin desk_ready=0
  local -a numbers=() jobs=() fetch_args=() to_spawn=()
  declare -A spawned=()
  for arg in "$@"; do
    case "$arg" in
      --no-run) run=0 ;;
      http://*|https://*) url="$arg" ;;
      -*) die "usage: bercail review-pr <PR url or branch> [--no-run]" ;;
      *) branch="$arg" ;;
    esac
  done
  [[ -n "$url" || -n "$branch" ]] || die "usage: bercail review-pr <PR url or branch> [--no-run]"
  _review_need jq git
  R_BACKEND=gh
  t0="$(_review_now)"
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf $(printf '%q' "$tmp")" EXIT

  if [[ -n "$branch" ]]; then
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
      || die "pass a PR url, or run review-pr from a checkout of the repo"
    local listed count
    R_BACKEND="$(git_backend "$PWD")"
    local pr_cli=_stack_gh
    [[ "$R_BACKEND" != origin ]] || pr_cli=origin
    listed="$("$pr_cli" pr list --head "$branch" --state open --limit 20 --json number,url)" \
      || die "gh pr list --head $branch failed"
    count="$(jq 'length' <<<"$listed")"
    if [[ "$count" -gt 1 ]]; then
      die "ambiguous: $count open PRs have head $branch; pass the PR url"
    fi
    [[ "$count" -eq 1 ]] || die "no open PR for branch $branch"
    url="$(jq -r '.[0].url' <<<"$listed")"
  fi
  _review_parse_url "$url"
  host="$R_HOST" owner="$R_OWNER" repo="$R_REPO" n="$R_WANT"
  slug="$host/$owner/$repo"

  source="$(_review_find_source "$host" "$owner" "$repo" || true)"
  if [[ "$R_BACKEND" != origin && -n "$source" ]]; then
    R_BACKEND="$(git_backend "$source")"
  fi
  if [[ "$R_BACKEND" == origin ]]; then _review_need origin; else _review_need gh; fi
  _review_pr_view "$n" "$slug" >"$tmp/pr-$n.json" 2>"$tmp/view.err" \
    || die "PR view $n -R $slug: $(<"$tmp/view.err")"
  if [[ -z "$source" ]]; then
    source="$(_review_fallback_checkout "$host" "$owner" "$repo")" || die "no checkout for $slug"
  fi
  local sync
  sync="$(_review_root)/$host/$owner/$repo/gt-sync"
  if [[ "$R_BACKEND" != origin && -n "$source" ]]; then
    local repo_dir
    repo_dir="$(_review_root)/$host/$owner/$repo"
    mkdir -p "$repo_dir"
    _review_lock "$repo_dir/$R_BACKEND" || die "$R_BACKEND stack discovery is busy; try again when it ends"
    if ! stack_discover "$slug" "$tmp/pr-$n.json" "$source" "$sync" "$R_BACKEND" >"$tmp/order.json"; then
      _review_unlock "$repo_dir/$R_BACKEND"
      die "could not discover the $R_BACKEND stack for PR #$n"
    fi
    _review_unlock "$repo_dir/$R_BACKEND"
  else
    stack_discover "$slug" "$tmp/pr-$n.json" "$source" "$sync" "$R_BACKEND" >"$tmp/order.json" \
      || die "could not discover the stack for PR #$n"
  fi
  order="$(<"$tmp/order.json")"
  jq -e --argjson n "$n" '.numbers | index($n) != null' <<<"$order" >/dev/null \
    || die "stack discovery did not include PR #$n"
  via="$(jq -r '.via' <<<"$order")"
  trunk="$(jq -r '.trunk' <<<"$order")"
  while IFS= read -r arg; do
    [[ -n "$arg" ]] && numbers+=("$arg")
  done < <(jq -r '.numbers[]' <<<"$order")
  root="${numbers[0]}"
  R_STACK="$(_review_root)/$host/$owner/$repo/stack-$root"

  main="$(cd "$source" && pwd -P)"
  sibling="$(_review_sibling_path "$main" "$root")"

  mkdir -p "$R_STACK"
  _review_lock "$R_STACK/context" || die "the review stack is busy gathering; try again when it ends"
  # shellcheck disable=SC2064
  trap '_review_unlock "$R_STACK/context"; rm -rf '"$(printf '%q' "$tmp")" EXIT
  if _review_passes_live "$R_STACK"; then
    die "the review stack is busy gathering or running a pass; try again when it ends"
  fi

  local num
  for num in "${numbers[@]}"; do
    if [[ ! -s "$tmp/pr-$num.json" ]]; then
      _review_pr_view "$num" "$slug" >"$tmp/pr-$num.json" 2>"$tmp/view-$num.err" &
      jobs+=("$!")
    fi
  done
  if [[ ${#jobs[@]} -gt 0 ]]; then
    _review_wait_all "${jobs[@]}" || die "gh pr view failed for a PR in the stack"
    jobs=()
  fi

  local prev="" base_sha head_sha prdir
  for num in "${numbers[@]}"; do
    head_sha="$(jq -r '.headRefOid' "$tmp/pr-$num.json")"
    if [[ -z "$prev" ]]; then
      base_sha="$(jq -r '.baseRefOid // empty' "$tmp/pr-$num.json")"
      if [[ -z "$base_sha" ]]; then
        base_sha="$(git -C "$main" rev-parse --verify "$trunk" 2>/dev/null || true)"
      fi
      [[ -n "$base_sha" ]] || die "PR #$num has no base sha (baseRefOid or trunk $trunk)"
    else
      base_sha="$prev"
    fi
    prev="$head_sha"
    prdir="$R_STACK/pr-$num/$head_sha"
    mkdir -p "$prdir"
    _review_write "$prdir/pr.json" <"$tmp/pr-$num.json"
    printf '%s\n' "$base_sha" >"$tmp/base-$num"
    fetch_args+=("$num" "$head_sha")
    _review_ci "$num" "$slug" "$prdir" &
    jobs+=("$!")
    _review_issues "$prdir/pr.json" >"$tmp/issues-$num.jsonl" &
    jobs+=("$!")
  done
  _review_fetch_objects "$main" "$trunk" "$(<"$tmp/base-$root")" "${fetch_args[@]}" &
  jobs+=("$!")
  _review_wait_all "${jobs[@]}" || die "gather failed while fetching checks, issues, or heads"
  jobs=()

  for num in "${numbers[@]}"; do
    head_sha="$(jq -r '.headRefOid' "$tmp/pr-$num.json")"
    base_sha="$(<"$tmp/base-$num")"
    prdir="$R_STACK/pr-$num/$head_sha"
    (
      git -C "$main" --no-pager diff --no-ext-diff "$base_sha...$head_sha" >"$tmp/diff-$num" \
        && git -C "$main" --no-pager log --no-show-signature --no-decorate --format='commit %H%n%B' "$base_sha..$head_sha" -- >"$tmp/commits-$num" \
        && _review_snapshot "$main" "$head_sha" "$base_sha" "$prdir/source"
    ) &
    jobs+=("$!")
  done
  _review_wait_all "${jobs[@]}" || die "could not diff or snapshot a PR in the stack"

  local -a pr_rows=()
  for num in "${numbers[@]}"; do
    head_sha="$(jq -r '.headRefOid' "$tmp/pr-$num.json")"
    base_sha="$(<"$tmp/base-$num")"
    prdir="$R_STACK/pr-$num/$head_sha"
    _review_write "$prdir/diff.patch" <"$tmp/diff-$num"
    [[ -f "$tmp/issues-$num.jsonl" ]] || : >"$tmp/issues-$num.jsonl"
    linear="$(_review_linear_ids "$prdir/pr.json")"
    thin="$(_review_thin "$prdir/pr.json" "$linear")"
    _review_intent_md "$prdir/pr.json" "$tmp/issues-$num.jsonl" "$linear" "$thin" "$tmp/commits-$num" | _review_write "$prdir/intent.md"
    jq -nc --slurpfile pr "$prdir/pr.json" --argjson thin "$thin" --argjson linear "$linear" --arg base "$base_sha" \
      '$pr[0] as $p | {number: $p.number, title: $p.title, author: $p.author.login, url: $p.url, draft: $p.isDraft,
        base: $p.baseRefName, head: $p.headRefName, head_sha: $p.headRefOid, base_sha: $base,
        linked: [$p.closingIssuesReferences[]?.number], linear: $linear, thin: $thin,
        intent: "Awaiting code-based intent inference."}' >"$tmp/row-$num.json"
    pr_rows+=("$tmp/row-$num.json")
  done

  jq -n --arg host "$host" --arg owner "$owner" --arg repo "$repo" --arg via "$via" --arg trunk "$trunk" --arg git "$R_BACKEND" \
    --arg wt "$sibling" --arg main "$main" --argjson root "$root" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --slurpfile prs <(cat "${pr_rows[@]}") \
    '{schema: "bercail.stack/v1", host: $host, owner: $owner, repo: $repo, git: $git, via: $via, trunk: $trunk,
      root: $root, current: $root, worktree: $wt, source: $main, space: null, gathered_at: $at,
      prs: $prs}' >"$tmp/stack.json"
  _review_stack_md "$tmp/stack.json" "$trunk" "$via" >"$tmp/stack.md"

  sha="$(jq -r --argjson n "$root" '.prs[] | select(.number == $n) | .head_sha' "$tmp/stack.json")"
  _review_ensure_worktree "$main" "$sibling" "$sha" >&2 \
    || die "could not put the review worktree $sibling at $sha"
  _review_write_marker "$sibling" "$R_STACK"
  _review_write "$R_STACK/stack.json" <"$tmp/stack.json"
  _review_write "$R_STACK/stack.md" <"$tmp/stack.md"
  R_WT="$sibling"

  if _review_herdr; then
    space="$(_review_space)" || { warn "the Herdr space for $sibling did not open; passes not started"; space=""; run=0; }
    if [[ -n "$space" ]]; then
      jq --arg s "$space" '.space = $s' "$R_STACK/stack.json" | _review_write "$R_STACK/stack.json"
      if _review_desk_session "$space" >/dev/null; then
        desk_ready=1
      else
        warn "the review desk is unavailable; passes not started"
        run=0
      fi
    fi
  fi

  for num in "${numbers[@]}"; do
    thin="$(jq -c --argjson n "$num" '.prs[] | select(.number == $n) | .thin' "$R_STACK/stack.json")"
    head_sha="$(jq -r --argjson n "$num" '.prs[] | select(.number == $n) | .head_sha' "$R_STACK/stack.json")"
    dir="$R_STACK/pr-$num/$head_sha"
    if [[ "$run" -eq 0 || "$thin" != "[]" ]]; then
      continue
    fi
    if _review_locked "$dir/pass"; then
      continue
    fi
    if [[ -f "$dir/run.json" && "$(jq -r '.status' "$dir/run.json")" == ready ]]; then
      continue
    fi
    to_spawn+=("$num")
  done

  gather="$(_review_since "$t0")"
  jq --argjson g "$gather" '.gather_s = $g' "$R_STACK/stack.json" | _review_write "$R_STACK/stack.json"
  _review_unlock "$R_STACK/context"

  local spawn_n spawn_sha
  for spawn_n in "${to_spawn[@]}"; do
    spawn_sha="$(jq -r --argjson n "$spawn_n" '.prs[] | select(.number == $n) | .head_sha' "$R_STACK/stack.json")"
    dir="$R_STACK/pr-$spawn_n/$spawn_sha"
    _review_need pi
    _review_spawn "$dir/pass.log" "$(_review_self)" review-pr run "$spawn_n" --head "$spawn_sha" --stack "$R_STACK"
    spawned["$spawn_n"]=1
  done
  [[ "$desk_ready" != 1 || ${#to_spawn[@]} -gt 0 ]] || _review_spawn_summary

  local rows="[]" row_n row_sha row_dir row_pass row_sum row_ci
  for num in "${numbers[@]}"; do
    row_n="$num"
    row_sha="$(jq -r --argjson n "$num" '.prs[] | select(.number == $n) | .head_sha' "$R_STACK/stack.json")"
    row_dir="$R_STACK/pr-$num/$row_sha"
    if [[ -n "${spawned[$num]:-}" ]]; then
      row_pass=started
    elif _review_locked "$row_dir/pass"; then
      row_pass=running
    elif [[ -f "$row_dir/run.json" && "$(jq -r '.status' "$row_dir/run.json")" == ready ]]; then
      row_pass="done"
    else
      row_pass=waiting
    fi
    row_sum="$(jq -er 'select(.intent_analysis != null) | .why' "$row_dir/review.json" 2>/dev/null \
      || printf 'Awaiting code-based intent inference.')"
    row_ci="$(_review_ci_counts "$row_dir/ci.json")"
    rows="$(jq -nc --argjson rows "$rows" --argjson n "$row_n" --arg pass "$row_pass" --arg dir "$row_dir" \
      --arg summary "$row_sum" --argjson ci "$row_ci" \
      '$rows + [{number: $n, pass: $pass, dir: $dir, summary: $summary, ci: $ci}]')"
  done
  local agg_pass next=""
  if jq -ne --argjson rows "$rows" 'any($rows[]; .pass == "started")' >/dev/null; then
    agg_pass=started
  elif jq -ne --argjson rows "$rows" 'any($rows[]; .pass == "running")' >/dev/null; then
    agg_pass=running
  elif jq -ne --argjson rows "$rows" 'any($rows[]; .pass == "waiting")' >/dev/null; then
    agg_pass=waiting
    next="bercail review-pr run --stack $R_STACK"
  else
    agg_pass="done"
  fi

  jq -n --slurpfile stack "$R_STACK/stack.json" --argjson rows "$rows" --arg pass "$agg_pass" \
    --arg url "$url" --arg stackdir "$R_STACK" --argjson gather "$gather" --arg next "$next" '
    $stack[0] as $s | {
      schema: "bercail.review-pr/v1", url: $url, repo: "\($s.owner)/\($s.repo)",
      stack: $stackdir, worktree: $s.worktree, space: $s.space,
      prs: [$s.prs[] as $p | ($rows[] | select(.number == $p.number)) as $r | {
        number: $p.number, title: $p.title, author: $p.author, url: $p.url, head_sha: $p.head_sha,
        dir: $r.dir, summary: $r.summary, linked: $p.linked, linear: $p.linear, ci: $r.ci,
        thin: $p.thin, pass: $r.pass}],
      thin: ([$s.prs[].thin[]] | length > 0),
      pass: $pass,
      next: (if $next == "" then null else $next end),
      gather_s: $gather
    }'
}

# --- bercail review-pr run ------------------------------------------------------

# The last fenced json block (or bare ``` block) of the agent's reply.
_review_json_block() {
  awk '
    /^[[:space:]]*```(json)?[[:space:]]*$/ && !inb { inb = 1; buf = ""; next }
    inb && /^[[:space:]]*```[[:space:]]*$/ { inb = 0; last = buf; found = 1; next }
    inb { buf = buf $0 "\n" }
    END { if (found) printf "%s", last }'
}

# run.json for a pass that stops before it writes one (killed, or an error).
_review_run_died() {
  [[ -f "$R_DIR/run.json" ]] && return 0
  local session
  session="$(_review_turn_session "$R_DIR/pass.jsonl")"
  jq -n --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg session "$session" \
    '{status: "failed", summary: "", session_id: (if $session == "" then null else $session end), finished_at: $at,
      reason: "the pass stopped before it finished; see pass.err and pass.log"}' \
    | _review_write "$R_DIR/run.json"
}

_review_run_finish() {
  if [[ -n "${R_CHILD:-}" ]]; then
    _review_turn_cancel "$R_DIR/pass.jsonl"
    kill "$R_CHILD" 2>/dev/null || true
    wait "$R_CHILD" 2>/dev/null || true
  fi
  if [[ "${R_STARTED:-0}" -eq 1 ]]; then
    _review_run_died
    if [[ "$(jq -r .status "$R_DIR/run.json")" != ready ]]; then
      rm -f "$R_DIR/review.json"
    fi
  fi
  _review_unlock "$R_STACK/context"
  _review_unlock "$R_DIR/pass"
  _review_unlock "$R_STACK/desk-pass"
}

# Validate the model's untrusted output before a card or tuicr ever reads it.
# Older saved cards remain valid summary inputs without intent_analysis.
_review_valid_reply() {
  jq -se '
    def text: type == "string";
    def optional_text: . == null or text;
    def line: if type == "number" then . > 0 and . == floor else false end;
    def evidence:
      type == "object" and (.file | text) and
      (.file | test("^/|(^|/)\\.\\.(/|$)") | not) and
      (.line == null or (.line | line)) and
      (.end_line == null or ((.end_line | line) and .line != null and .end_line >= .line)) and
      (.side == null or (.side | IN("old", "new")));
    def inference:
      type == "object" and (.confidence | IN("high", "medium", "low")) and
      (.evidence | type == "array") and all(.evidence[]; evidence and (.file | length > 0)) and
      (.clues | type == "array" and length > 0) and all(.clues[];
        type == "object" and (.source | text and length > 0) and (.detail | text and length > 0) and
        (.alignment | IN("agrees", "more", "less", "different", "stale", "unavailable"))) and
      (.assessment | text and length > 0);
    def review: type == "object" and (.why | text) and (.why_source | optional_text) and
    (.intent_analysis == null or ((.why | length > 0) and .why_source == "diff" and (.intent_analysis | inference))) and
    (.decisions | type == "array") and
    all(.decisions[];
      type == "object" and (.statement | text) and
      (.kind | IN("approach", "scope", "dependency", "schema", "api", "behavior", "migration", "flag")) and
      (.fits_intent | IN("yes", "partial", "no", "unclear")) and
      (.stated | optional_text) and (.alternative | optional_text) and (.question | optional_text) and
      (.evidence | type == "array") and all(.evidence[]; evidence)) and
    ((.unmet_intent // []) | type == "array") and
    all((.unmet_intent // [])[];
      type == "object" and (.promise | text) and (.source | optional_text) and (.question | optional_text)) and
    ((.questions // []) | type == "array") and
    all((.questions // [])[]; type == "object" and (.text | text));
    length == 1 and (.[0] | review)
  ' >/dev/null 2>&1
}

# One pass. Holds the stack lock only long enough to register this PR's pass lock.
review_run_one() {
  _review_load "$@"
  _review_need pi jq
  _review_pi_argv
  local t0 rc=0 session text block status reason="" summary="" prompt err gathered desk=""
  _review_lock_wait "$R_STACK/context" 15 || die "the review stack is busy gathering; try again"
  if ! _review_lock "$R_DIR/pass"; then
    _review_unlock "$R_STACK/context"
    die "a decisions pass for PR #$R_N is already running"
  fi
  _review_unlock "$R_STACK/context"
  R_STARTED=0
  trap '_review_run_finish' EXIT
  trap 'exit 143' TERM
  trap 'exit 130' INT
  gathered="$(jq -r --argjson n "$R_N" '.prs[] | select(.number == $n) | .head_sha' "$R_STACK/stack.json")"
  if [[ "$R_SHA" != "$gathered" ]]; then
    R_STARTED=1
    rm -f "$R_DIR/run.json" "$R_DIR/review.json"
    jq -n --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg sha "$R_SHA" --arg cur "$gathered" \
      '{status: "failed", summary: "", session_id: null, finished_at: $at,
        reason: "queued head \($sha[0:7]) is not the gathered head \($cur[0:7]) in stack.json; run review-pr again"}' \
      | _review_write "$R_DIR/run.json"
    cat "$R_DIR/run.json"
    return 1
  fi
  # Cwd is the stack dir, not the worktree and not the reviewed repo, so Pi
  # loads no project config or context files from the author's repo.
  prompt="Review the PR in pr-$R_N/$R_SHA/ (a bercail review-pr run dir). Files at that head that this PR changes are in pr-$R_N/$R_SHA/source/ (text only; a symlink is the link target as text, not a link). Follow your instructions and end with the one JSON block."
  if _review_herdr; then
    desk="$(_review_desk_session)" || return 1
    _review_lock_wait "$R_STACK/desk-pass" 3600 || die "the review desk is busy; try again later"
  fi
  t0="$(_review_now)"
  : >"$R_DIR/pass.jsonl"
  : >"$R_DIR/pass.err"
  R_STARTED=1
  rm -f "$R_DIR/run.json" "$R_DIR/review.json"
  _review_turn "$R_DIR/pass.jsonl" "$R_DIR/pass.err" "$prompt" "$desk" &
  R_CHILD=$!
  wait "$R_CHILD" || rc=$?
  R_CHILD=""
  _review_unlock "$R_STACK/desk-pass"

  session="$(_review_turn_session "$R_DIR/pass.jsonl")"
  text="$(_review_turn_text "$R_DIR/pass.jsonl")"
  block="$(_review_json_block <<<"$text")"
  [[ -n "$block" ]] || block="$text"
  # Pi exits 0 when the provider failed.
  if [[ "$rc" -eq 0 ]] && pi_turn_failed "$R_DIR/pass.jsonl"; then
    rc=failed
  fi
  if jq -se 'length == 1 and (.[0] | type == "object" and (.blocked | type) == "string")' <<<"$block" >/dev/null 2>&1; then
    status=blocked
    reason="$(jq -r '.blocked' <<<"$block")"
  elif [[ "$rc" == 0 ]] && _review_valid_reply <<<"$block" \
    && jq -e '.intent_analysis != null' <<<"$block" >/dev/null \
    && { [[ ! -s "$R_DIR/diff.patch" ]] || jq -e '.intent_analysis.evidence | length > 0' <<<"$block" >/dev/null; }; then
    status=ready
    jq --arg schema "$REVIEW_SCHEMA" --argjson pr "$R_N" --arg sha "$R_SHA" --arg session "$session" '
      {schema: $schema, pr: $pr, head_sha: $sha, session_id: $session,
       why: .why, why_source: (.why_source // null), intent_analysis: .intent_analysis, decisions: .decisions,
       unmet_intent: (.unmet_intent // []), questions: (.questions // [])}' <<<"$block" \
      | _review_write "$R_DIR/review.json"
    summary="$(jq -r '"\(.decisions | length) decisions, \([.decisions[] | select(.stated == null)] | length) undocumented, \(.unmet_intent | length) unmet, \(([.decisions[] | select(.question)] | length) + ([.unmet_intent[] | select(.question)] | length) + (.questions | length)) questions"' "$R_DIR/review.json")"
  else
    status=failed
    err="$(_review_turn_error "$R_DIR/pass.jsonl" "$R_DIR/pass.err")"
    if [[ "$rc" == failed ]]; then
      reason="pi failed${err:+: $err}"
    elif [[ "$rc" != 0 ]]; then
      reason="pi exited $rc${err:+: $err}"
    elif [[ -n "$text" ]]; then
      reason="the reply is not a valid decisions JSON block"
    else
      reason="no reply${err:+: $err}"
    fi
  fi
  jq -n --arg status "$status" --arg summary "$summary" --arg session "$session" --arg reason "$reason" \
    --argjson seconds "$(_review_since "$t0")" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    {status: $status, summary: $summary, session_id: (if $session == "" then null else $session end),
     seconds: $seconds, finished_at: $at} + (if $reason == "" then {} else {reason: $reason} end)' \
    | _review_write "$R_DIR/run.json"

  cat "$R_DIR/run.json"
  [[ -z "$desk" || "$status" != ready ]] || _review_spawn_summary
  [[ "$status" != failed ]]
}

# No N: one PR runs even if thin. A longer stack starts every non-thin
# PR that is not already ready or running.
review_run_waiting() {
  local pr n sha thin dir out rc=0
  if _review_herdr; then _review_desk_session >/dev/null || return 1; fi
  local -a pids=()
  local tmp
  tmp="$(mktemp -d)"
  local i=0
  while IFS= read -r pr; do
    n="$(jq -r '.number' <<<"$pr")"
    sha="$(jq -r '.head_sha' <<<"$pr")"
    thin="$(jq -c '.thin // []' <<<"$pr")"
    dir="$R_STACK/pr-$n/$sha"
    [[ "$thin" == "[]" ]] || continue
    _review_locked "$dir/pass" && continue
    if [[ -f "$dir/run.json" && "$(jq -r '.status' "$dir/run.json")" == ready ]]; then
      continue
    fi
    "$(_review_self)" review-pr run "$n" --head "$sha" --stack "$R_STACK" >"$tmp/$i.json" 2>"$tmp/$i.err" &
    pids+=("$!")
    i=$((i + 1))
  done < <(jq -c '.prs[]' "$R_STACK/stack.json")
  local pid
  for pid in "${pids[@]+"${pids[@]}"}"; do
    wait "$pid" || rc=1
  done
  if [[ "$i" -eq 0 ]]; then
    printf '%s\n' '{"prs":[]}'
  else
    jq -s '.' "$tmp"/*.json
  fi
  rm -rf "$tmp"
  return "$rc"
}

review_run() {
  local stack="" head="" n=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --stack) stack="${2:-}"; shift 2 ;;
      --head) head="${2:-}"; shift 2 ;;
      [0-9]*) n="$1"; shift ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  local -a load=()
  [[ -z "$stack" ]] || load+=(--stack "$stack")
  if [[ -n "$n" ]]; then
    [[ -z "$head" ]] || load+=(--head "$head")
    review_run_one "$n" "${load[@]}"
    return
  fi
  _review_load "${load[@]}"
  local count
  count="$(jq '.prs | length' "$R_STACK/stack.json")"
  if [[ "$count" -eq 1 ]]; then
    review_run_one "$R_N" "${load[@]}"
    return
  fi
  review_run_waiting
}

# --- card, rows, ui -------------------------------------------------------------

# Questions for the author, in seeding order: each decision's (anchored at its
# first evidence), each unmet promise's, then the whole-PR ones.
REVIEW_JQ_DEFS='
def loc: if . == null or .file == null then ""
  else .file + (if .line then ":\(.line)" + (if (.end_line // .line) != .line then "-\(.end_line)" else "" end) else "" end) end;
def questions: [ (.decisions // [] | .[] | select(.question) | {text: .question, at: ((.evidence // [])[0])}),
  (.unmet_intent // [] | .[] | select(.question) | {text: .question, at: null}),
  (.questions // [] | .[] | {text: (if type == "object" then .text else . end), at: null}) | select(.text) ];
'

review_card() {
  _review_load "$@"
  local pr review="null" ci="[]" thin
  pr="$(jq -c --argjson n "$R_N" '.prs[] | select(.number == $n)' "$R_STACK/stack.json")"
  thin="$(jq -c '.thin // []' <<<"$pr")"
  [[ -f "$R_DIR/review.json" ]] && review="$(jq -c . "$R_DIR/review.json" 2>/dev/null || printf null)"
  [[ -f "$R_DIR/ci.json" ]] && ci="$(jq -c . "$R_DIR/ci.json" 2>/dev/null || printf '[]')"
  jq -nr --argjson p "$pr" --argjson r "$review" --argjson ci "$ci" \
    --arg status "$(_review_status "$R_DIR" "$thin")" "$REVIEW_JQ_DEFS"'
    def pad($w): (. + "          ")[0:$w];
    def order: {fail: 0, pending: 1, cancel: 2, pass: 3, skipping: 4}[.bucket // "pending"] // 5;
    "PR #\($p.number)  \($p.title)",
    "by \($p.author) · \($p.base) ← \($p.head) · \($p.head_sha[0:7])\(if $p.draft then " · draft" else "" end)",
    $p.url,
    (if ($p.thin | length) > 0 then "thin: \($p.thin | join(", "))" else empty end),
    "",
    (if $r == null then "Decisions pass: \($status)"
     else
       (if $r.intent_analysis then "Inferred intent (best guess)" else "Saved review context (Re-review for code-based intent)" end),
       "  \($r.why // "(not given)")\(if $r.why_source then "  [\($r.why_source)]" else "" end)",
       (if $r.intent_analysis then
         "  Confidence: \($r.intent_analysis.confidence)",
         "  Evidence: \($r.intent_analysis.evidence | map(loc) | join(", "))",
         "  Right thing to build: \($r.intent_analysis.assessment)",
         "", "Clue comparison",
         ($r.intent_analysis.clues[] | "  \(.alignment) · \(.source): \(.detail)")
        else empty end),
       "",
       "Decisions (\($r.decisions | length), \([$r.decisions[] | select(.stated == null)] | length) undocumented)",
       ($r.decisions | to_entries[] | .key as $i | .value |
         "  \($i + 1). [\(.kind // "?")] \(.statement // "")",
         "     \((.evidence // [])[0] | loc)  \(if .stated == null then "UNDOCUMENTED" else "stated: \(.stated)" end) · fits intent: \(.fits_intent // "unclear")",
         (if .alternative then "     over: \(.alternative)" else empty end)),
       (if ($r.unmet_intent | length) > 0
        then "", "Intent with no change",
             ($r.unmet_intent[] | "  - \(.promise)\(if .source then "  [\(.source)]" else "" end)")
        else empty end),
       ($r | questions) as $q
       | (if ($q | length) > 0
          then "", "Questions for the author",
               ($q | to_entries[] | "  \(.key + 1). \(if .value.at.file then (.value.at | loc) else "(whole PR)" end)  \(.value.text)")
          else empty end)
     end),
    "",
    (if ($ci | length) == 0 then "CI  no checks"
     else
       (reduce $ci[] as $c ({}; .[$c.bucket // "pending"] += 1)) as $k
       | "CI  \([("fail", "pending", "cancel", "pass", "skipping") | select($k[.]) | "\($k[.]) \(.)"] | join(" · "))",
         ($ci | sort_by(order) | .[] |
           "  \(.bucket // "pending" | pad(8)) \(.name)\(if (.workflow // "") != "" then " (\(.workflow))" else "" end)\(if (.bucket == "fail" or .bucket == "pending") and (.link // "") != "" then "  \(.link)" else "" end)")
     end),
    "",
    "[t] tuicr with these questions as [AI Agent] drafts · [o] open in the browser"'
}

# A file's JSON, or $2 when it is missing or not JSON.
_review_json() {
  jq -c . "$1" 2>/dev/null || printf '%s' "$2"
}

# Everything the Stack tab mod (bercail-review) shows, as one JSON document. It
# only reads the run dir: stack.json, stack.md, and per PR run.json, review.json
# and ci.json, with the pass status the card prints.
review_state() {
  _review_load "$@"
  local pr n sha thin dir status i=0 tmp
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf $(printf '%q' "$tmp")" EXIT
  # Files, not arguments: a stack's cards outgrow one argv string.
  if [[ "$(jq '.prs | length' "$R_STACK/stack.json")" -gt 1 && -f "$R_STACK/stack.md" ]]; then
    cp "$R_STACK/stack.md" "$tmp/header"
  else
    : >"$tmp/header"
  fi
  while IFS= read -r pr; do
    n="$(jq -r '.number' <<<"$pr")"
    sha="$(jq -r '.head_sha' <<<"$pr")"
    thin="$(jq -c '.thin // []' <<<"$pr")"
    dir="$R_STACK/pr-$n/$sha"
    status="$(_review_status "$dir" "$thin")"
    _review_json "$dir/review.json" null >"$tmp/review"
    _review_json "$dir/ci.json" '[]' >"$tmp/ci"
    i=$((i + 1))
    jq -n --argjson p "$pr" --arg dir "$dir" --arg status "$status" \
      --slurpfile review "$tmp/review" --slurpfile ci "$tmp/ci" \
      "$REVIEW_JQ_DEFS"'
      $review[0] as $review
      | $p + {dir: $dir, status: $status, pass: ($status | split(":")[0]),
        intent: (if $review.intent_analysis != null then $review.why
          elif $review != null then "Re-review for code-based intent."
          else "Awaiting code-based intent inference." end),
        review: $review, ci: ($ci[0] // []),
        questions: (if $review == null then [] else [$review | questions[] | {text, at: (.at | loc | select(. != "") // null)}] end)}' \
      >"$tmp/pr-$(printf '%04d' "$i")"
  done < <(jq -c '.prs[]' "$R_STACK/stack.json")
  _review_summary_state "$tmp/summary-input.json" >"$tmp/summary.json"
  jq -n --slurpfile s "$R_STACK/stack.json" --slurpfile prs <(cat "$tmp"/pr-* 2>/dev/null) --arg stack "$R_STACK" \
    --slurpfile summary "$tmp/summary.json" \
    --rawfile header "$tmp/header" '
    $s[0] as $s | {schema: "bercail.review-ui/v1", stack: $stack,
      repo: "\($s.owner)/\($s.repo)",
      root: $s.root, current: $s.current, source: $s.source,
      header: (if $header == "" then null else $header end), prs: $prs, summary: $summary[0]}'
}

# The Stack tab mod, when Herdr has it.
_review_has_mod() {
  [[ -f "$HERDR_APP_CONFIG_DIR/mods/bercail-review/main.js" ]]
}

# The space's native Stack tab.
_review_stack_tab() {
  "$HERDR_APP" ls 2>/dev/null | jq -r --arg id "$1" '
    first(.spaces[] | select(.id == $id) | .tabs[]?
      | select(.name == "Stack" and ((.terminals // []) | length == 0)) | .id) // empty'
}

# Open the mod in this space, unless its tab is already there.
_review_mod_tab() {
  local space="$1" tab out
  tab="$(_review_stack_tab "$space")"
  if [[ -z "$tab" ]]; then
    out="$("$HERDR_APP" "do" tab.new "$(jq -cn --arg space "$space" --arg stack "$R_STACK" --arg self "$(_review_self)" \
      '{space: $space, name: "Stack", mod: "bercail-review", props: {stack: $stack, bercail: $self}}')")" || return 1
    tab="$(jq -er '.tab' <<<"$out")" || return 1
  fi
  printf '%s\n' "$tab"
}

# Sets R_SPACE, the review space in the Herdr app, or dies saying what to do.
_review_space_id() {
  _review_herdr || die "the Herdr app is not running; review-pr shows its stack there. Open it, then: bercail review-pr $1"
  R_SPACE="$(_wt_herdr_space_by_folder "$R_WT")"
  [[ -n "$R_SPACE" ]] || die "no Herdr space on $R_WT; run bercail review-pr <url> again"
}

# Show the review space's Stack tab (the bercail-review mod), or make it.
review_ui() {
  _review_load "$@"
  local space tab
  _review_space_id ui
  space="$R_SPACE"
  _review_has_mod || die "the Herdr app has no bercail-review mod; run: bercail update"
  tab="$(_review_mod_tab "$space")" || die "herdr-app did not open the Stack tab in $space: $tab"
  "$HERDR_APP" "do" space.select --id "$space" >/dev/null 2>&1 || true
  "$HERDR_APP" "do" tab.select --id "$tab" >/dev/null 2>&1 || true
  if _review_desk_session "$space" >/dev/null; then
    _review_spawn_summary
  else
    warn "the review desk is unavailable; showing saved cards without starting desk work"
  fi
}

# Move the review worktree only. The source checkout is not switched.
review_select() {
  _review_load "$@"
  _review_lock_wait "$R_STACK/context" 30 || die "the review stack is busy gathering; try again"
  trap '_review_unlock "$R_STACK/context"' EXIT
  local sha
  sha="$(jq -r --argjson n "$R_N" '.prs[] | select(.number == $n) | .head_sha' "$R_STACK/stack.json")"
  _review_check_worktree "$R_WT"
  git -C "$R_WT" switch --quiet --detach "$sha" || die "could not detach $R_WT at $sha"
  jq --argjson n "$R_N" '.current = $n' "$R_STACK/stack.json" | _review_write "$R_STACK/stack.json"
}

# The review worktree on PR N's branch, for a shell in it. A missing local branch
# is made at the PR head (not for a fork's PR). One that exists is used only when it is at the head:
# bercail never moves a branch of yours, and a branch checked out in another
# worktree can't be checked out here. Then the worktree is at the head, detached,
# and the note says why. Prints {worktree, branch, note}.
review_checkout() {
  _review_load "$@"
  # Under the Stack tab's 30 s exec, so a busy stack says so.
  _review_lock_wait "$R_STACK/context" 10 || die "the review stack is busy gathering; try again"
  trap '_review_unlock "$R_STACK/context"' EXIT
  local sha branch tip where on="" note=""
  sha="$(jq -r --argjson n "$R_N" '.prs[] | select(.number == $n) | .head_sha' "$R_STACK/stack.json")"
  branch="$(jq -r --argjson n "$R_N" '.prs[] | select(.number == $n) | .head' "$R_STACK/stack.json")"
  _review_check_worktree "$R_WT"
  where="$(git -C "$R_WT" worktree list --porcelain | awk -v want="branch refs/heads/$branch" '
    /^worktree / { w = substr($0, 10) } $0 == want { print w; exit }')"
  if [[ "$(jq -r '.isCrossRepository // false' "$R_DIR/pr.json" 2>/dev/null)" == true ]]; then
    note="$branch is a fork's branch; no local branch is made for it"
  elif ! git check-ref-format --branch "$branch" >/dev/null 2>&1; then
    note="$branch is not a branch name git takes"
  elif [[ -n "$where" && "$(cd "$where" && pwd -P)" != "$(cd "$R_WT" && pwd -P)" ]]; then
    note="$branch is checked out in $where"
  elif tip="$(git -C "$R_WT" rev-parse -q --verify "refs/heads/$branch^{commit}")"; then
    if [[ "$tip" == "$sha" ]]; then
      git -C "$R_WT" switch --quiet "$branch" && on="$branch"
    else
      note="your $branch is at ${tip:0:7}, not the PR head ${sha:0:7}; it is left alone"
    fi
  else
    git -C "$R_WT" switch --quiet --create "$branch" "$sha" && on="$branch"
  fi
  if [[ -z "$on" ]]; then
    git -C "$R_WT" switch --quiet --detach "$sha" || die "could not detach $R_WT at $sha"
  fi
  jq --argjson n "$R_N" '.current = $n' "$R_STACK/stack.json" | _review_write "$R_STACK/stack.json"
  jq -n --arg wt "$R_WT" --arg branch "$on" --arg note "$note" \
    '{worktree: $wt, branch: (if $branch == "" then null else $branch end), note: (if $note == "" then null else $note end)}'
}

# Re-review: gather the stack again (heads, CI, bodies), then run PR N's pass
# again, even if it was ready.
review_rereview() {
  _review_load "$@"
  if _review_herdr; then _review_desk_session >/dev/null || return 1; fi
  local self url source
  self="$(_review_self)"
  url="$(jq -r '.root as $r | .prs[] | select(.number == $r) | .url' "$R_STACK/stack.json")"
  source="$(_review_stack_get .source)"
  (cd "$source" && "$self" review-pr "$url" --no-run) >&2 || die "could not gather the stack again"
  # A gather puts the worktree and current back on the root: this PR again.
  "$self" review-pr select "$R_N" --stack "$R_STACK" >&2 || die "could not move the review worktree back to #$R_N"
  exec "$self" review-pr run "$R_N" --stack "$R_STACK"
}

# --- open: tuicr, seeded with the questions --------------------------------------

# The live tuicr session for a PR (its slug ends with $2), or nothing.
_review_tuicr_slug() {
  tuicr review list --repo "$1" 2>/dev/null | jq -r --arg want "$2" '
    first(.[]? | select(.kind == "pr" and .active == true and (.slug | ascii_downcase | endswith($want))) | .slug) // empty' \
    2>/dev/null || true
}

# The space's "Review #N" tab on `tuicr pr N`, made fresh: one tuicr per review
# space, so any Review tab goes first. A tab can't tell whether its tuicr still
# runs, and tuicr keeps the drafts in its session, not in the tab.
_review_review_tab() {
  local space="$1" id
  while IFS= read -r id; do
    [[ -z "$id" ]] || "$HERDR_APP" "do" tab.close --id "$id" --confirmed true >/dev/null 2>&1 || true
  done < <("$HERDR_APP" ls 2>/dev/null | jq -r --arg id "$space" '.spaces[] | select(.id == $id) | .tabs[]?
    | select(.name == "Review" or (.name | startswith("Review #"))) | .id')
  "$HERDR_APP" "do" tab.new "$(jq -cn --arg space "$space" --arg n "$R_N" --arg wt "$R_WT" \
    '{space: $space, name: "Review #\($n)", folder: $wt, argv: ["tuicr", "pr", $n, "--no-update-check"]}')" >/dev/null \
    || die "herdr-app did not open the Review #$R_N tab"
}

review_open() {
  _review_load "$@"
  if [[ "$R_BACKEND" == origin ]]; then
    # tuicr pr supports GitHub/GitLab, not Origin. Keep this forge-native.
    _review_need origin jq
    origin pr view "$R_N" -R "$(_review_stack_get .owner)/$(_review_stack_get .repo)" --web >/dev/null \
      || die "could not open Origin PR #$R_N"
    jq -n --argjson number "$R_N" --arg url "$(jq -r .url "$R_DIR/pr.json")" --arg context "$R_DIR" \
      '{number:$number, url:$url, context:$context, note:"Origin opened in the browser; review cards remain in the local context, not seeded into tuicr."}'
    return
  fi
  _review_need tuicr jq
  local owner repo space want slug="" i secs payload out id seeded="[]"
  _review_lock "$R_DIR/open" || die "PR #$R_N is already being opened in tuicr"
  trap 'rm -f "$R_DIR/open.lock"' EXIT
  owner="$(_review_stack_get .owner)"
  repo="$(_review_stack_get .repo)"
  _review_space_id "open $R_N"
  space="$R_SPACE"
  want=":${owner,,}/${repo,,}/pr/$R_N"
  _review_review_tab "$space"

  # tuicr errors on a PR slug it has not opened: wait for its live session.
  secs="${BERCAIL_REVIEW_OPEN_WAIT:-60}"
  for ((i = 0; i < secs * 2; i++)); do
    slug="$(_review_tuicr_slug "$owner/$repo" "$want")"
    [[ -n "$slug" ]] && break
    sleep 0.5
  done
  [[ -n "$slug" ]] || die "tuicr did not open PR #$R_N within ${secs}s; see its Review #$R_N tab"

  if [[ -f "$R_DIR/seeded.json" ]]; then
    info "already seeded; delete $R_DIR/seeded.json to seed again" >&2
    cat "$R_DIR/seeded.json"
    return 0
  fi
  if [[ ! -f "$R_DIR/review.json" ]]; then
    jq -n --arg s "$slug" '{session: $s, comments: [], note: "no review.json yet: nothing to seed"}'
    return 0
  fi
  while IFS= read -r payload; do
    if ! out="$(tuicr review add --session "$slug" --input - <<<"$payload" 2>/dev/null)"; then
      # A line tuicr can't anchor: the question goes in as a review comment naming it.
      payload="$(jq -c '{content: ("[AI Agent] (\(.file):\(.line // .start_line // "")) " + (.content | ltrimstr("[AI Agent] "))),
        type, username}' <<<"$payload")"
      out="$(tuicr review add --session "$slug" --input - <<<"$payload")" || { warn "tuicr did not take: $payload"; continue; }
    fi
    id="$(jq -r '.id // .comment.id // empty' <<<"$out" 2>/dev/null || true)"
    seeded="$(jq -c --arg id "$id" --argjson p "$payload" \
      '. + [{id: $id, file: ($p.file // null), line: ($p.line // $p.start_line // null), content: $p.content}]' <<<"$seeded")"
  done < <(jq -c "$REVIEW_JQ_DEFS"'questions[] |
    {content: ("[AI Agent] " + .text), type: "note", username: "bstack"}
    + (if .at.file then {file: .at.file, side: (.at.side // "new")}
         + (if .at.line and (.at.end_line // .at.line) != .at.line then {start_line: .at.line, end_line: .at.end_line}
            elif .at.line then {line: .at.line} else {} end)
       else {} end)' "$R_DIR/review.json")
  jq -n --arg s "$slug" --argjson c "$seeded" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{session: $s, seeded_at: $at, comments: $c}' | _review_write "$R_DIR/seeded.json"
  cat "$R_DIR/seeded.json"
}

# --- close: the worktree, the run dir, and the space -------------------------

# The run dir of the stack holding PR N in the repo dirs given: stack-N, else
# the one stack that lists N. Prints nothing when there is none.
_review_stack_of() {
  local n="$1" dir f
  local -a hits=()
  shift
  for dir in "$@"; do
    if [[ -d "$dir/stack-$n" ]]; then
      hits+=("$dir/stack-$n")
      continue
    fi
    for f in "$dir"/stack-*/stack.json; do
      [[ -f "$f" ]] || continue
      if jq -e --argjson n "$n" 'any(.prs[]; .number == $n)' "$f" >/dev/null 2>&1; then
        hits+=("${f%/stack.json}")
      fi
    done
  done
  [[ ${#hits[@]} -le 1 ]] || die "PR #$n is in ${#hits[@]} review stacks (${hits[*]}); pass --stack DIR"
  printf '%s' "${hits[0]:-}"
}

# Only a worktree review-pr made for this stack is removed, and never one with
# work in it unless --force.
_review_close_check() {
  local wt="$1" force="$2" gd marked="" head
  gd="$(git -C "$wt" rev-parse --absolute-git-dir 2>/dev/null)" \
    || die "refusing to remove $wt: not a git worktree; move it away, then close again"
  [[ "$gd" != "$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir)" ]] \
    || die "refusing to remove $wt: it is a main checkout"
  [[ ! -f "$gd/bercail-review-stack" ]] || marked="$(cd "$(<"$gd/bercail-review-stack")" 2>/dev/null && pwd -P || true)"
  [[ ! -L "$wt" && "$marked" == "$R_STACK" ]] \
    || die "refusing to remove $wt: not this stack's review worktree"
  [[ "$force" -eq 0 ]] || return 0
  [[ -z "$(git -C "$wt" status --porcelain)" ]] \
    || die "refusing to remove $wt: it has local changes; commit or move them, or pass --force to drop them"
  # A commit made on the detached worktree is on no branch and would go with it.
  head="$(git -C "$wt" rev-parse HEAD)"
  if ! git -C "$wt" symbolic-ref -q HEAD >/dev/null \
    && ! jq -e --arg sha "$head" 'any(.prs[]; .head_sha == $sha)' "$R_STACK/stack.json" >/dev/null; then
    die "refusing to remove $wt: its HEAD $head is on no branch and is no PR's head; put a branch on it (git -C $wt switch -c NAME), or pass --force to drop it"
  fi
}

# Remove what review-pr <url> made for one stack: its worktree, its desk, its
# run dir, then its Herdr space. The space goes last, since close may run from a
# terminal in it. Nothing left to remove is not an error.
review_close() {
  local force=0 n="" url="" stack="${BERCAIL_REVIEW_STACK:-}" root dir host origin_host="" lock wt="" src="" common="" branch="" space="" desk keep
  local usage="usage: bercail review-pr close [<PR url> | N] [--stack DIR] [--force]"
  local -a repos=() rm_args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force) force=1; shift ;;
      --stack) [[ -n "${2:-}" ]] || die "$usage"; stack="$2"; shift 2 ;;
      http://*|https://*) url="$1"; shift ;;
      *) [[ "$1" =~ ^[0-9]+$ ]] || die "$usage"; n="$1"; shift ;;
    esac
  done
  root="$(_review_root)"
  if [[ -n "$url" ]]; then
    _review_parse_url "$url"
    n="$R_WANT"
    repos=("$root/$R_HOST/$R_OWNER/$R_REPO")
  else
    if [[ -z "$stack" ]]; then
      if [[ -f "$PWD/stack.json" ]]; then stack="$PWD"; else stack="$(_review_read_marker || true)"; fi
    fi
    if [[ -n "$n" && -n "$stack" ]]; then
      repos=("$(dirname "$stack")")
    elif [[ -n "$n" ]]; then
      # N alone: the reviews of the repo this checkout is. An origin that names
      # another host is another repo; an ssh alias or a path names none.
      [[ "$(git remote get-url origin 2>/dev/null)" =~ ^([a-z+]+://([^@/]+@)?|[^@/]+@)([^/:]+) ]] \
        && origin_host="${BASH_REMATCH[3],,}"
      for dir in "$root"/*/*/*/; do
        dir="${dir%/}"
        [[ -d "$dir" ]] || continue
        host="$(basename "$(dirname "$(dirname "$dir")")")"
        _review_is_repo "$PWD" "$host" "$(basename "$(dirname "$dir")")" "$(basename "$dir")" || continue
        [[ "$host" == origin.cursor.com || "$origin_host" != *.* || "$origin_host" == "${host,,}" ]] || continue
        repos+=("$dir")
      done
      [[ ${#repos[@]} -gt 0 ]] \
        || die "no review of this checkout's repo; run close $n in a checkout of the repo, or pass the PR url"
    fi
    [[ -n "$n" || -n "$stack" ]] || die "no review stack here; $usage"
  fi
  if [[ -n "$n" ]]; then
    stack="$(_review_stack_of "$n" "${repos[@]}")" || exit 1
  fi
  if [[ -z "$stack" || ! -d "$stack" ]]; then
    info "nothing to close${n:+ for PR #$n}"
    return 0
  fi
  R_STACK="$(cd "$stack" && pwd -P)"
  root="$(cd "$root" 2>/dev/null && pwd -P)" || root=""
  [[ -n "$root" && "${R_STACK#"$root"/}" =~ ^[^/]+/[^/]+/[^/]+/stack-[0-9]+$ ]] \
    || die "$R_STACK is not a review run dir under $(_review_root)"
  _review_lock "$R_STACK/context" || die "the review stack is busy gathering; try again when it ends"
  trap '_review_unlock "$R_STACK/context"' EXIT
  # Any other lock: a pass, the desk's summary or start, or an open seeding tuicr.
  while IFS= read -r lock; do
    [[ "$lock" != "$R_STACK/context.lock" ]] || continue
    if [[ "$lock" == *.reap ]] || _review_locked "${lock%.lock}"; then
      die "the review stack is in use (${lock#"$R_STACK"/}); let it end, then close"
    fi
  done < <(find "$R_STACK" -maxdepth 3 \( -name '*.lock' -o -name '*.lock.reap' \))

  if [[ -f "$R_STACK/stack.json" ]]; then
    wt="$(jq -r '.worktree // empty' "$R_STACK/stack.json")"
    src="$(jq -r '.source // empty' "$R_STACK/stack.json")"
    space="$(jq -r '.space // empty' "$R_STACK/stack.json")"
  fi
  if [[ -n "$wt" && -e "$wt" ]]; then
    _review_close_check "$wt" "$force"
    wt="$(cd "$wt" && pwd -P)"
    common="$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir)"
    branch="$(git -C "$wt" symbolic-ref -q --short HEAD || true)"
  elif [[ -n "$wt" && -n "$src" ]]; then
    # Gone from disk; the source checkout may still list it.
    common="$(git -C "$src" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
    if [[ -z "$common" ]] || ! git --git-dir="$common" worktree list --porcelain | grep -qxF "worktree $wt"; then
      common=""
    fi
  fi
  if [[ -n "$wt" ]] && _review_herdr; then
    space="$(_wt_herdr_space_by_folder "$wt" || true)"
  elif [[ -n "$space" ]]; then
    warn "the Herdr app is not running; close the review space there by hand"
    space=""
  fi

  # Off the worktree before it goes; close may run from inside it.
  cd /
  if [[ -n "$common" ]]; then
    [[ "$force" -eq 0 ]] || rm_args+=(--force)
    git --git-dir="$common" worktree remove "${rm_args[@]}" "$wt" \
      || die "could not remove the review worktree $wt"
    info "removed worktree $wt"
    [[ -z "$branch" ]] || info "branch $branch stays in ${src:-the source checkout}; delete it with git branch -d when done"
  fi
  # The desk's Pi runs in the run dir, so it ends first.
  if [[ -n "$space" ]]; then
    desk="$(_wt_herdr_space_desk "$space" || true)"
    if [[ -n "$desk" ]]; then
      "$HC" kill "$desk" >/dev/null 2>&1 || true
      "$HC" rm "$desk" >/dev/null 2>&1 || true
    fi
  fi
  rm -rf "$R_STACK"
  info "removed run dir $R_STACK"
  if [[ -n "$space" ]]; then
    keep="$(_wt_herdr_focused_space || true)"
    "$HERDR_APP" "do" space.close --id "$space" --confirmed true >/dev/null \
      || die "herdr-app did not close space $space; close it by hand"
    info "closed Herdr space $space"
    [[ "$keep" == "$space" ]] || _wt_herdr_keep_user_focus "$keep"
  fi
}

review_usage() {
  cat <<'EOF'
Usage: bercail review-pr <command>

  <PR url or branch> [--no-run]
                        gather the whole stack into the root PR's run dir, one
                        detached sibling worktree, and a Herdr space. Thin PRs
                        wait; the rest start. JSON lists thin flags and pass
                        per PR. A single thin PR still waits for: review-pr run
  run [N]               N reviews that PR, even if thin. No N starts every
                        non-thin waiting pass in parallel (a stack of one runs
                        even if thin).
  card [N]              print the PR's card
  ui                    show the Stack tab (the bercail-review mod) in the
                        review space; needs the Herdr app
  state                 the stack, cards, and pass status as JSON (the mod's input)
  summarize             retry the desk's summary of an entirely ready stack
  select [N]            git switch --detach to that PR in the review worktree
  checkout [N]          the review worktree on that PR's branch (made at the head
                        if missing; never moves a branch of yours)
  rereview [N]          gather the stack again, then run that PR's pass again
  open [N]              a Review #N tab with tuicr pr N, seeded with the questions
  dir [N]               print the PR's run dir
  close [<PR url> | N] [--force]
                        remove the stack's worktree, run dir, and Herdr space
                        (desk and Stack tab). Refuses a worktree with local
                        changes unless --force. Nothing left to remove is fine.

run, card, ui, state, summarize, select, checkout, rereview, open, dir, and close take --stack DIR, or find the stack
from the review worktree they run in. N defaults to the stack's current PR;
close N finds the stack holding PR N for the checkout it runs in.
EOF
}

cmd_review_pr() {
  local sub="${1:-}"
  case "$sub" in
    ""|help|-h|--help) review_usage ;;
    run) shift; review_run "$@" ;;
    card) shift; review_card "$@" ;;
    ui) shift; review_ui "$@" ;;
    state) shift; review_state "$@" ;;
    summarize) shift; review_summarize "$@" ;;
    select) shift; review_select "$@" ;;
    checkout) shift; review_checkout "$@" ;;
    rereview) shift; review_rereview "$@" ;;
    open) shift; review_open "$@" ;;
    dir) shift; _review_load "$@"; printf '%s\n' "$R_DIR" ;;
    close) shift; review_close "$@" ;;
    *) review_start "$@" ;;
  esac
}
