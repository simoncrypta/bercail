#!/usr/bin/env bash
# shellcheck shell=bash
# bercail review-pr: review someone else's PR by its intent and its decisions.
#
# One stack (slice 1: a stack of one PR) is one run dir, one detached worktree,
# and one Herdr space. The run dir is
#   ${XDG_STATE_HOME:-~/.local/state}/bercail/reviews/<host>/<owner>/<repo>/stack-<root>/
# with stack.json, worktree/ (the repo at the PR head), and per PR and head sha
#   pr-<n>/<sha>/ pr.json intent.md diff.patch ci.json review.json run.json seeded.json
# Gather is plain gh and git. The decisions pass is one bstack-pr-review
# opencode run per PR, read-only. Agents never post to GitHub.

REVIEW_SCHEMA="bercail.review/v1"
REVIEW_PR_FIELDS="number,title,body,url,author,isDraft,baseRefName,headRefName,headRefOid,closingIssuesReferences,files,statusCheckRollup"

_review_root() {
  printf '%s/bercail/reviews' "${XDG_STATE_HOME:-$HOME/.local/state}"
}

# This bercail, for the commands the Stack tab and fzf keys run.
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

_review_unlock() {
  [[ "$(readlink "$1.lock" 2>/dev/null)" != "${BASHPID:-$$}" ]] || rm -f "$1.lock"
}

_review_locked() {
  local pid
  pid="$(readlink "$1.lock" 2>/dev/null)" || return 1
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
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

# --- gather -------------------------------------------------------------------

# DIR's common git dir when its origin is OWNER/REPO (any host alias or scheme).
_review_git_dir_for() {
  local url
  url="$(git -C "$1" remote get-url origin 2>/dev/null)" || return 1
  url="${url%/}"
  url="${url%.git}"
  [[ "${url,,}" == *[/:]"${2,,}/${3,,}" ]] || return 1
  git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null
}

# Reviews use a private bare clone, so symlink checkout policy never changes
# the source repo's config. Prefer a local clone of a matching checkout.
_review_repo() (
  local host="$1" owner="$2" repo="$3" n="$4" sha="$5" wt="$6" gd source="" dir origin
  gd="$(_review_root)/$host/$owner/$repo/clone.git"
  _review_lock "${gd%/*}/repository" || { printf 'review repository is busy; retry after the other gather\n' >&2; return 1; }
  trap '_review_unlock "${gd%/*}/repository"' EXIT
  if [[ -e "$wt/.git" ]]; then
    [[ "$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir)" == "$gd" ]] || {
      printf 'recreate review worktree %s: it predates the private review clone\n' "$wt" >&2
      return 1
    }
  fi
  if [[ ! -d "$gd" ]]; then
    source="$(_review_git_dir_for "$PWD" "$owner" "$repo")" || source=""
    if [[ -z "$source" ]] && _review_herdr; then
      while IFS= read -r dir; do
        [[ -d "$dir" ]] || continue
        source="$(_review_git_dir_for "$dir" "$owner" "$repo")" && break
        source=""
      done < <("$HERDR_APP" ls 2>/dev/null | jq -r '.spaces[]?.folder // empty' | sort -u)
    fi
    if [[ -n "$source" ]]; then
      origin="$(git --git-dir="$source" remote get-url origin)" || return 1
      git clone --bare --quiet "$source" "$gd" >&2 || return 1
      git --git-dir="$gd" remote set-url origin "$origin" || return 1
    else
      gh repo clone "$host/$owner/$repo" "$gd" -- --bare --filter=blob:none --quiet >&2 \
        || { printf 'could not clone %s/%s/%s\n' "$host" "$owner" "$repo" >&2; return 1; }
    fi
  fi
  if [[ "$(git --git-dir="$gd" config --get core.symlinks || true)" != false ]]; then
    git --git-dir="$gd" config core.symlinks false || return 1
  fi
  if ! git --git-dir="$gd" cat-file -e "$sha^{commit}" 2>/dev/null; then
    git --git-dir="$gd" fetch --quiet origin "refs/pull/$n/head" >&2 \
      || { printf 'git fetch origin pull/%s/head failed in %s\n' "$n" "$gd" >&2; return 1; }
    git --git-dir="$gd" cat-file -e "$sha^{commit}" 2>/dev/null \
      || { printf 'head %s is not on pull/%s/head (pushed since?); run review-pr again\n' "$sha" "$n" >&2; return 1; }
  fi
  printf '%s' "$gd"
)

# The stack's one worktree, detached at SHA. Nobody edits in a review space, so
# moving it is a plain switch.
_review_worktree() {
  local gd="$1" wt="$2" sha="$3"
  if [[ -e "$wt/.git" ]]; then
    [[ "$(git -C "$wt" rev-parse HEAD 2>/dev/null)" == "$sha" ]] || git -c core.symlinks=false -C "$wt" switch --quiet --detach "$sha"
  else
    git --git-dir="$gd" worktree prune
    git -c core.symlinks=false --git-dir="$gd" worktree add --quiet --detach "$wt" "$sha"
  fi
}

# gh pr checks exits non-zero while checks are pending or failing (and when
# there are none) but still prints the JSON. Without JSON, the rollup from gh
# pr view stands in, in the same shape.
_review_ci() {
  local n="$1" slug="$2" dir="$3" raw
  raw="$(gh pr checks "$n" -R "$slug" --json name,bucket,state,workflow,link 2>/dev/null)" || true
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
    gh issue view "$url" --json number,title,body,url 2>/dev/null | jq -c . || true
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
  local pr="$1" issues="$2" linear="$3" thin="$4"
  jq -r --slurpfile issues "$issues" --argjson linear "$linear" --argjson thin "$thin" '
    def lockish: test("(^|/)(package-lock\\.json|npm-shrinkwrap\\.json|yarn\\.lock|pnpm-lock\\.yaml|bun\\.lockb?|Cargo\\.lock|Gemfile\\.lock|poetry\\.lock|uv\\.lock|composer\\.lock|go\\.sum|mix\\.lock|Podfile\\.lock|flake\\.lock)$")
      or test("(^|/)(dist|vendor|node_modules)/") or test("\\.(min\\.js|map|snap)$") or test("[._-]generated[._-]");
    "# PR #\(.number): \(.title)",
    "",
    "- url: \(.url)",
    "- author: \(.author.login)",
    "- base: \(.baseRefName), head: \(.headRefName) @ \(.headRefOid)",
    (if .isDraft then "- draft" else empty end),
    "- thin: \(if ($thin | length) == 0 then "none" else ($thin | join(", ")) end)",
    "",
    "## PR body",
    "",
    (if (.body // "" | test("\\S")) then .body else "(empty)" end),
    "",
    "## Linked issues",
    "",
    (if ($issues | length) == 0 then "(none)"
     else ($issues[] | "### #\(.number) \(.title)\n\n\(.url)\n\n\(.body // "")\n") end),
    (if ($linear | length) > 0
     then "", "## Linear", "", "Detected, not fetched: \($linear | join(", ")). Shep fetches them into issue.md."
     else empty end),
    "",
    "## Changed files",
    "",
    (.files[]? | "- \(.path) (+\(.additions) -\(.deletions), \(.changeType | ascii_downcase))\(if (.path | lockish) then " [lock or generated: name only]" else "" end)")
  ' "$pr"
}

# --- the stack ----------------------------------------------------------------

# Sets R_STACK, R_N (the PR, default the stack's current), R_SHA (--head, else
# the PR's head in stack.json), R_DIR, R_WT from --stack DIR,
# $BERCAIL_REVIEW_STACK, or the review worktree or stack dir around $PWD.
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
    elif top="$(git rev-parse --show-toplevel 2>/dev/null)" && [[ -f "$(dirname "$top")/stack.json" ]]; then
      R_STACK="$(dirname "$top")"
    fi
  fi
  [[ -n "$R_STACK" && -f "$R_STACK/stack.json" ]] \
    || die "no review stack here; pass --stack DIR (bercail review-pr <url> prints it)"
  [[ -n "$R_N" ]] || R_N="$(jq -r '.current' "$R_STACK/stack.json")"
  R_SHA="$(jq -r --argjson n "$R_N" '.prs[] | select(.number == $n) | .head_sha' "$R_STACK/stack.json")"
  [[ -n "$R_SHA" ]] || die "PR #$R_N is not in the stack at $R_STACK"
  R_SHA="${head:-$R_SHA}"
  R_DIR="$R_STACK/pr-$R_N/$R_SHA"
  [[ -d "$R_DIR" ]] || die "no run dir for PR #$R_N at $R_SHA"
  R_WT="$(jq -r '.worktree' "$R_STACK/stack.json")"
}

_review_stack_get() {
  jq -r "$1" "$R_STACK/stack.json"
}

_review_cmd() {
  local self
  self="$(_review_self)"
  printf '%q review-pr %s --stack %q' "$self" "$1" "$R_STACK"
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

# Detach the decisions pass from whoever asked (Shep's shell, an fzf key).
_review_spawn() {
  local log="$1"
  shift
  if command -v setsid >/dev/null 2>&1; then
    setsid -f "$@" >"$log" 2>&1 </dev/null
  else
    nohup "$@" >"$log" 2>&1 </dev/null &
  fi
}

# The space, its desk, and its Stack tab. Prints the space id.
_review_space() {
  local n="$1" repo="${2,,}" label space keep argv cmd
  label="Review-${n}_${repo^}"
  wt_herdr_layout_create "$label" "$R_WT" >&2 || return 1
  space="$(_wt_herdr_space_by_folder "$R_WT")"
  [[ -n "$space" ]] || return 1
  if ! "$HERDR_APP" ls 2>/dev/null \
    | jq -e --arg id "$space" '.spaces[] | select(.id == $id) | .tabs[]? | select(.name == "Stack")' >/dev/null; then
    # The tab's shell is not the caller's: put mise and ~/.local/bin on PATH.
    cmd="PATH=\"\$HOME/.local/bin:\$HOME/.local/share/mise/shims:\$PATH\"; exec $(_review_cmd ui)"
    argv="$(jq -cn --arg cmd "$cmd" '["bash", "-lc", $cmd]')"
    keep="$(_wt_herdr_focused_space)"
    "$HERDR_APP" "do" tab.new --space "$space" --name Stack --folder "$R_WT" --argv "$argv" >/dev/null || return 1
    _wt_herdr_keep_user_focus "$keep"
  fi
  printf '%s' "$space"
}

# --- bercail review-pr <url> ----------------------------------------------------

review_start() {
  local url="" run=1 arg host owner repo n slug t0 tmp sha dir gd linear thin space="" pass gather
  for arg in "$@"; do
    case "$arg" in
      --no-run) run=0 ;;
      http://*|https://*) url="$arg" ;;
      *) die "usage: bercail review-pr <https://github.com/OWNER/REPO/pull/N> [--no-run]" ;;
    esac
  done
  [[ "$url" =~ ^https?://([^/]+)/([^/]+)/([^/]+)/pull/([0-9]+) ]] \
    || die "not a pull request URL: ${url:-(none)} (https://github.com/OWNER/REPO/pull/N)"
  host="${BASH_REMATCH[1]}" owner="${BASH_REMATCH[2]}" repo="${BASH_REMATCH[3]}" n="${BASH_REMATCH[4]}"
  slug="$host/$owner/$repo"
  _review_need gh jq git
  t0="$(_review_now)"
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" EXIT

  gh pr view "$n" -R "$slug" --json "$REVIEW_PR_FIELDS" >"$tmp/pr.json" 2>"$tmp/view.err" \
    || die "gh pr view $n -R $slug: $(<"$tmp/view.err")"
  sha="$(jq -r '.headRefOid' "$tmp/pr.json")"
  R_STACK="$(_review_root)/$host/$owner/$repo/stack-$n"
  R_N="$n" R_SHA="$sha" R_DIR="$R_STACK/pr-$n/$sha" R_WT="$R_STACK/worktree"
  dir="$R_DIR"
  mkdir -p "$dir"
  _review_lock "$R_STACK/context" || die "the review stack is busy gathering or running a pass; try again when it ends"
  # shellcheck disable=SC2064
  trap '_review_unlock "$R_STACK/context"; rm -rf '"$(printf '%q' "$tmp")" EXIT
  _review_write "$dir/pr.json" <"$tmp/pr.json"

  # Everything else at once: diff, checks, linked issues, the PR head.
  gh pr diff "$n" -R "$slug" >"$tmp/diff.patch" 2>"$tmp/diff.err" &
  local diff_job=$!
  _review_ci "$n" "$slug" "$dir" &
  _review_issues "$dir/pr.json" >"$tmp/issues.jsonl" &
  _review_repo "$host" "$owner" "$repo" "$n" "$sha" "$R_WT" >"$tmp/gitdir" 2>"$tmp/repo.err" &
  local repo_job=$!
  wait "$diff_job" || die "gh pr diff $n -R $slug: $(<"$tmp/diff.err")"
  _review_write "$dir/diff.patch" <"$tmp/diff.patch"
  wait "$repo_job" || die "$(<"$tmp/repo.err")"
  wait
  gd="$(<"$tmp/gitdir")"

  linear="$(_review_linear_ids "$dir/pr.json")"
  thin="$(_review_thin "$dir/pr.json" "$linear")"
  _review_intent_md "$dir/pr.json" "$tmp/issues.jsonl" "$linear" "$thin" | _review_write "$dir/intent.md"
  _review_worktree "$gd" "$R_WT" "$sha" >&2 || die "could not put the review worktree $R_WT at $sha"

  jq -n --slurpfile pr "$dir/pr.json" --argjson thin "$thin" --argjson linear "$linear" \
    --arg host "$host" --arg owner "$owner" --arg repo "$repo" --arg wt "$R_WT" --arg gd "$gd" \
    --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    $pr[0] as $p | {
      schema: "bercail.stack/v1", host: $host, owner: $owner, repo: $repo,
      root: $p.number, current: $p.number, worktree: $wt, git_dir: $gd, space: null, gathered_at: $at,
      prs: [{number: $p.number, title: $p.title, author: $p.author.login, url: $p.url, draft: $p.isDraft,
             base: $p.baseRefName, head: $p.headRefName, head_sha: $p.headRefOid,
             linked: [$p.closingIssuesReferences[]?.number], linear: $linear, thin: $thin}]
    }' | _review_write "$R_STACK/stack.json"
  gather="$(_review_since "$t0")"

  if _review_herdr; then
    space="$(_review_space "$n" "$repo")" || { warn "the Herdr space for $R_WT did not open"; space=""; }
    if [[ -n "$space" ]]; then
      jq --arg s "$space" '.space = $s' "$R_STACK/stack.json" | _review_write "$R_STACK/stack.json"
    fi
  fi

  if _review_locked "$dir/pass"; then
    pass=running
  elif [[ -f "$dir/run.json" && "$(jq -r '.status' "$dir/run.json")" == ready ]]; then
    pass="done"
  elif [[ "$thin" != "[]" || "$run" -eq 0 ]]; then
    pass=waiting
  else
    _review_need opencode
    _review_unlock "$R_STACK/context"
    _review_spawn "$dir/pass.log" "$(_review_self)" review-pr run "$n" --head "$sha" --stack "$R_STACK"
    pass=started
  fi

  jq -n --slurpfile stack "$R_STACK/stack.json" --argjson ci "$(_review_ci_counts "$dir/ci.json")" \
    --arg dir "$dir" --arg pass "$pass" --arg url "$url" --argjson gather "$gather" \
    --arg summary "$(jq -r '((.body // "") | gsub("<!--[\\s\\S]*?-->"; "") | split("\n")
        | map(gsub("^[#>*\\s-]+"; "") | select(test("\\S"))) | .[0] // "")[0:160]' "$dir/pr.json")" '
    $stack[0] as $s | {
      schema: "bercail.review-pr/v1", url: $url, repo: "\($s.owner)/\($s.repo)",
      stack: ($dir | sub("/pr-[0-9]+/[^/]+$"; "")), worktree: $s.worktree, space: $s.space,
      prs: [$s.prs[] | {number, title, author, url, head_sha, dir: $dir, summary: $summary,
                        linked, linear, ci: $ci, thin}],
      thin: ([$s.prs[].thin[]] | length > 0),
      pass: $pass,
      next: (if $pass == "waiting" then "bercail review-pr run --stack \($dir | sub("/pr-[0-9]+/[^/]+$"; ""))" else null end),
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
  session="$(jq -rRn 'first(inputs | fromjson? | .sessionID? // empty | select(. != "")) // ""' "$R_DIR/pass.jsonl" 2>/dev/null || true)"
  jq -n --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg session "$session" \
    '{status: "failed", summary: "", session_id: (if $session == "" then null else $session end), finished_at: $at,
      reason: "the pass stopped before it finished; see pass.err and pass.log"}' \
    | _review_write "$R_DIR/run.json"
}

_review_run_finish() {
  if [[ -n "${R_CHILD:-}" ]]; then
    kill "$R_CHILD" 2>/dev/null || true
    wait "$R_CHILD" 2>/dev/null || true
  fi
  _review_run_died
  if [[ "$(jq -r .status "$R_DIR/run.json")" != ready ]]; then
    rm -f "$R_DIR/review.json"
  fi
  _review_unlock "$R_STACK/context"
  _review_unlock "$R_DIR/pass"
  # Reload only after releasing the lock, so the row no longer says running.
  if [[ -S "$R_STACK/ui.sock" ]] && command -v curl >/dev/null 2>&1; then
    curl -fsS -m 2 --unix-socket "$R_STACK/ui.sock" http://localhost \
      -d "reload($(_review_cmd rows))" >/dev/null 2>&1 || true
  fi
}

# Validate the model's untrusted output before a card or tuicr ever reads it.
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
    def review: type == "object" and (.why | text) and (.why_source | optional_text) and
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

review_run() {
  _review_load "$@"
  _review_need opencode jq
  local t0 rc=0 session text block status reason="" summary="" prompt err id=""
  local -a model=()
  _review_lock "$R_DIR/pass" || die "a decisions pass for PR #$R_N is already running"
  trap '_review_run_finish' EXIT
  trap 'exit 143' TERM
  trap 'exit 130' INT
  _review_lock "$R_STACK/context" || die "the review stack is busy gathering or running a pass"
  rm -f "$R_DIR/run.json" "$R_DIR/review.json"
  if [[ "$(git -C "$R_WT" rev-parse HEAD 2>/dev/null)" != "$R_SHA" ]]; then
    jq -n --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg sha "$R_SHA" \
      '{status: "failed", summary: "", session_id: null, finished_at: $at,
        reason: "the worktree is no longer at \($sha[0:7]); run review-pr <url> again"}' | _review_write "$R_DIR/run.json"
    cat "$R_DIR/run.json"
    return 1
  fi
  # Older review worktrees may predate core.symlinks=false. Don't let a read
  # through an author's symlink escape the agent's external-directory deny.
  [[ -z "$(find "$R_WT" -type l -print -quit)" ]] || die "the review worktree contains symlinks; recreate it before running the pass"
  t0="$(_review_now)"
  # The pass runs in the stack dir, not the worktree, so the reviewed repo's
  # opencode config and plugins stay out. --model is the lead from [bstack],
  # resolved in that dir: `opencode models` reads cwd config, and the running
  # server can still have the previous agent model. No lead model: omit --model.
  prompt="Review the PR in pr-$R_N/$R_SHA/ (a bercail review-pr run dir). The repo at that head is ./worktree/, here in the current dir, not under pr-$R_N/. Follow your instructions and end with the one JSON block."
  id="$(cd "$R_STACK" && bstack_load_state reload >/dev/null && bstack_role_model lead || true)"
  [[ -n "$id" ]] && model=(--model "$id")
  (cd "$R_STACK" && exec opencode run --format json --agent bstack-pr-review "${model[@]}" "$prompt") \
    >"$R_DIR/pass.jsonl" 2>"$R_DIR/pass.err" &
  R_CHILD=$!
  wait "$R_CHILD" || rc=$?
  R_CHILD=""

  session="$(jq -rRn 'first(inputs | fromjson? | .sessionID? // empty | select(. != "")) // ""' "$R_DIR/pass.jsonl")"
  text="$(jq -rR 'fromjson? | select(.type? == "text") | .part.text // empty' "$R_DIR/pass.jsonl")"
  block="$(_review_json_block <<<"$text")"
  [[ -n "$block" ]] || block="$text"
  if jq -se 'length == 1 and (.[0] | type == "object" and (.blocked | type) == "string")' <<<"$block" >/dev/null 2>&1; then
    status=blocked
    reason="$(jq -r '.blocked' <<<"$block")"
  elif [[ "$rc" -eq 0 ]] && _review_valid_reply <<<"$block"; then
    status=ready
    jq --arg schema "$REVIEW_SCHEMA" --argjson pr "$R_N" --arg sha "$R_SHA" --arg session "$session" '
      {schema: $schema, pr: $pr, head_sha: $sha, session_id: $session,
       why: .why, why_source: (.why_source // null), decisions: .decisions,
       unmet_intent: (.unmet_intent // []), questions: (.questions // [])}' <<<"$block" \
      | _review_write "$R_DIR/review.json"
    summary="$(jq -r '"\(.decisions | length) decisions, \([.decisions[] | select(.stated == null)] | length) undocumented, \(.unmet_intent | length) unmet, \(([.decisions[] | select(.question)] | length) + ([.unmet_intent[] | select(.question)] | length) + (.questions | length)) questions"' "$R_DIR/review.json")"
  else
    status=failed
    err="$(jq -rR 'fromjson? | select(.type? == "error") | (.error.data.message? // .error.message? // (.error | tostring)) | split("\n")[0]' "$R_DIR/pass.jsonl" | tail -1)"
    [[ -n "$err" ]] || err="$(tail -1 "$R_DIR/pass.err" 2>/dev/null || true)"
    if [[ "$rc" -ne 0 ]]; then
      reason="opencode exited $rc${err:+: $err}"
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
  [[ "$status" != failed ]]
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
       "Why",
       "  \($r.why // "(not given)")\(if $r.why_source then "  [\($r.why_source)]" else "" end)",
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

review_rows() {
  _review_load "$@"
  local pr n sha thin dir ci
  jq -c '.prs[]' "$R_STACK/stack.json" | while IFS= read -r pr; do
    n="$(jq -r '.number' <<<"$pr")"
    sha="$(jq -r '.head_sha' <<<"$pr")"
    thin="$(jq -c '.thin // []' <<<"$pr")"
    dir="$R_STACK/pr-$n/$sha"
    ci="$(jq -r 'if length == 0 then "no checks" else ([to_entries[] | "\(.value) \(.key)"] | join(", ")) end' \
      <<<"$(_review_ci_counts "$dir/ci.json")")"
    printf '%s\t#%s  %s  ·  %s  ·  CI %s\n' "$n" "$n" "$(jq -r '.title' <<<"$pr")" \
      "$(_review_status "$dir" "$thin")" "$ci"
  done
}

# The Stack tab: one row per PR, the card in the preview. `review-pr run` reloads
# it through --listen when run.json lands.
review_ui() {
  _review_load "$@"
  _review_need fzf
  local sock="$R_STACK/ui.sock" slug
  slug="$(_review_stack_get '"\(.host)/\(.owner)/\(.repo)"')"
  rm -f "$sock"
  (review_rows --stack "$R_STACK") | FZF_DEFAULT_OPTS="" fzf \
    --listen="$sock" --disabled --no-sort --layout=reverse --delimiter=$'\t' --with-nth=2 \
    --header="t: tuicr with the questions · o: open in the browser · ctrl-c: quit" \
    --preview="$(_review_cmd card) {1}" --preview-window="down,85%,wrap,border-top" \
    --bind="load:refresh-preview" --bind="enter:ignore,esc:ignore" \
    --bind="t:execute-silent($(_review_cmd open) {1} >>$(printf '%q' "$R_STACK/open.log") 2>&1 &)" \
    --bind="o:execute-silent(gh pr view {1} -R $(printf '%q' "$slug") --web >/dev/null 2>&1 &)" \
    || true
  rm -f "$sock"
}

# --- open: tuicr, seeded with the questions --------------------------------------

review_open() {
  _review_load "$@"
  _review_need tuicr jq
  local owner repo space term want slug="" i secs payload out id seeded="[]"
  _review_lock "$R_DIR/open" || die "PR #$R_N is already being opened in tuicr"
  trap 'rm -f "$R_DIR/open.lock"' EXIT
  owner="$(_review_stack_get .owner)"
  repo="$(_review_stack_get .repo)"
  _review_herdr || die "the Herdr app is not running; open it, then: bercail review-pr open $R_N"
  space="$(_wt_herdr_space_by_folder "$R_WT")"
  [[ -n "$space" ]] || die "no Herdr space on $R_WT; run bercail review-pr <url> again"
  # The review space's own terminal: the mod acts on that terminal's space.
  term="$(_wt_herdr_space_shell "$space")"
  [[ -n "$term" ]] || die "the review space has no terminal to send the command from"
  "$HERDR_APP" "do" "bercail-desk.review-pr-$R_N:$term" >/dev/null \
    || die "herdr-app did not take bercail-desk.review-pr-$R_N"

  # tuicr errors on a PR slug it has not opened: wait for its live session.
  want=":${owner,,}/${repo,,}/pr/$R_N"
  secs="${BERCAIL_REVIEW_OPEN_WAIT:-60}"
  for ((i = 0; i < secs * 2; i++)); do
    slug="$(tuicr review list --repo "$owner/$repo" 2>/dev/null | jq -r --arg want "$want" '
      first(.[]? | select(.kind == "pr" and .active == true and (.slug | ascii_downcase | endswith($want))) | .slug) // empty' 2>/dev/null || true)"
    [[ -n "$slug" ]] && break
    sleep 0.5
  done
  [[ -n "$slug" ]] || die "tuicr did not open PR #$R_N within ${secs}s (does the desk mod know review-pr? bercail update)"

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

# --- bercail review-pr ------------------------------------------------------------

review_usage() {
  cat <<'EOF'
Usage: bercail review-pr <command>

  <PR url> [--no-run]   gather the PR into its run dir, put a detached worktree
                        and a Herdr space (Review-<n>_<Repo>) on it, and print
                        JSON for Shep: thin flags per PR, CI, the run dir. With
                        no thin flag the decisions pass starts on its own.
  run [N]               the decisions pass (bstack-pr-review): review.json, run.json
  card [N]              print the PR's card
  ui                    the Stack tab: fzf, the card in the preview (t, o)
  open [N]              the Review tab with tuicr pr N, seeded with the questions
  dir [N]               print the PR's run dir

run, card, ui, open, and dir take --stack DIR, or find the stack from the review
worktree they run in. N defaults to the stack's current PR.
EOF
}

cmd_review_pr() {
  local sub="${1:-}"
  case "$sub" in
    ""|help|-h|--help) review_usage ;;
    run) shift; review_run "$@" ;;
    card) shift; review_card "$@" ;;
    rows) shift; review_rows "$@" ;;
    ui) shift; review_ui "$@" ;;
    open) shift; review_open "$@" ;;
    dir) shift; _review_load "$@"; printf '%s\n' "$R_DIR" ;;
    *) review_start "$@" ;;
  esac
}
