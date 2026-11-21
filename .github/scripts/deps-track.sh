#!/usr/bin/env bash
# The dependency tracker (docs/development.md#dependency-tracker). It reads
# lib/deps.json and keeps one GitHub issue open per tool while a stable release
# newer than its `known` version is out, and one per vendored copy while its
# upstream has a commit past `known` that changes what bercail copies.
#
#   deps-track.sh check [--dry-run]  look up each tool; open, update or close its issue
#   deps-track.sh pins               offline: the manifest's shape, and every keyed pin agrees with known
#   deps-track.sh stale              warn when deps.yml last succeeded over 3 days ago
#
# gh needs GH_TOKEN and GH_REPO; deps.yml sets them.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MANIFEST="$ROOT/lib/deps.json"
# A release under a day old may still be pulled or patched, and mise holds it
# back that long (docs/install.md), so bercail could not install it yet.
MIN_AGE=86400
# GitHub turns a schedule off after 60 days without a push; this is the alarm.
STALE_AFTER=$((3 * 86400))
TRACKER_TITLE="deps: tracker failing"
# Where a git: source is cloned from; the tests point it at local repos.
GIT_BASE="${DEPS_GIT_BASE:-https://github.com}"
# The clone, and each blob fetch after it, fails instead of asking for a login.
export GIT_TERMINAL_PROMPT=0
NOW="$(date +%s)"
DRY_RUN=0
FAILED=()
ROWS=()
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# The version in a tag: v0.28.0 and jq-1.8.2 are 0.28.0 and 1.8.2.
norm() {
  printf '%s' "${1#"${1%%[0-9]*}"}"
}

# A release, not an rc, beta, nightly or build.
stable() {
  [[ "$1" =~ ^[0-9]+(\.[0-9]+)*$ ]]
}

# Whether version $1 is newer than $2.
newer() {
  [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" == "$1" ]]
}

# GNU date reads an empty date as today's midnight, so a feed without one fails here.
epoch() {
  [[ -n "$1" ]] || { echo 'the release has no date' >&2; return 1; }
  date -u -d "$1" +%s
}

# The last thing a failed lookup said.
last_error() {
  local msg
  msg="$(grep . "$TMP/err" | tail -1)" || true
  printf '%s' "${msg:-no release found}"
}

fetch() {
  curl -fsS --compressed --max-time 20 "$@"
}

# Each lookup prints {tag, published, url, notes?} for the newest release.
lookup_github() {
  gh api "repos/$1/releases/latest" | jq '{tag: .tag_name, published: .published_at, url: .html_url}'
}

lookup_npm() {
  fetch "https://registry.npmjs.org/${1/\//%2f}" | jq --arg pkg "$1" \
    '.["dist-tags"].latest as $v | {tag: $v, published: .time[$v], url: "https://www.npmjs.com/package/\($pkg)/v/\($v)"}'
}

# latest.json has no date; its Last-Modified is when the release replaced it.
lookup_herdr() {
  local url="https://releases.herdr.dev/$1/latest.json" body date
  body="$(fetch -D "$TMP/headers" "$url")"
  date="$(sed -n 's/^last-modified: *//Ip' "$TMP/headers" | tr -d '\r')"
  jq --arg date "$date" '{tag: .version, published: $date, url: "https://herdr.dev/changelog", notes: .notes}' <<<"$body"
}

# The newest release of major $1; index.json lists the newest first.
lookup_node() {
  fetch https://nodejs.org/dist/index.json | jq --arg m "v$1." \
    'first(.[] | select(.version | startswith($m))) | {tag: .version, published: .date, url: "https://nodejs.org/en/blog/release/\(.version)"}'
}

lookup() {
  local source="$1"
  case "$source" in
    github:* | action:*) lookup_github "${source#*:}" ;;
    npm:*) lookup_npm "${source#npm:}" ;;
    herdr:app | herdr:core) lookup_herdr "${source#herdr:}" ;;
    node:*) lookup_node "${source#node:}" ;;
    *) printf 'unknown source %s\n' "$source" >&2; return 1 ;;
  esac
}

row() {
  ROWS+=("| $1 | $2 | $3 | $4 |")
  printf '%s: %s\n' "$1" "$4"
}

fail() {
  FAILED+=("$1: $2")
  row "$1" "${3:-}" "" "**failed:** $2"
  printf '::error::%s: %s\n' "$1" "$2"
}

# The issue writes go through here, so --dry-run can say what it would do instead.
gh_write() {
  local arg elide=0
  local -a shown=()
  if ((DRY_RUN == 0)); then
    gh "$@"
    return
  fi
  for arg in "$@"; do
    if ((elide)); then shown+=("<${#arg} chars>") elide=0; else shown+=("$arg"); fi
    [[ "$arg" != --body && "$arg" != --comment ]] || elide=1
  done
  printf 'would run: gh %s\n' "${shown[*]}" >&2
}

# Each label is created before the issue that uses it: gh will not add a missing one.
# Labels after the third are the caller's to create.
open_issue() {
  local title="$1" body="$2" label="$3" extra
  local -a labels=(--label deps --label "$label")
  for extra in "${@:4}"; do labels+=(--label "$extra"); done
  gh_write label create deps --color 0366d6 --description "A dependency moved on (.github/workflows/deps.yml)" --force >/dev/null
  gh_write label create "$label" --color c5def5 --force >/dev/null
  gh_write issue create --title "$title" --body "$body" "${labels[@]}" >/dev/null
}

# The issue body for a release of tool entry $1: what moved, where bercail pins
# it, and what to check before `known` moves. $2 is the lookup, $3 its version,
# $4 when it came out (epoch), $5 the source's repo, $6 an action's commit.
issue_body() {
  local entry="$1" rel="$2" version="$3" published="$4" arg="$5" sha="${6:-}"
  local known released
  known="$(jq -r .known <<<"$entry")"
  released="$(date -u -d "@$published" +%F)"
  printf '**%s** %s → **%s**, released %s.\n\nRelease notes: %s\n' \
    "$(jq -r .name <<<"$entry")" "$known" "$version" "$released" "$(jq -r .url <<<"$rel")"
  [[ -z "$sha" ]] || printf '\nMove the pin to `uses: %s@%s # %s` in each file below.\n' "$arg" "$sha" "$(jq -r .tag <<<"$rel")"
  jq -r '.notes // empty | "\n" + (split("\n") | map("> " + .) | join("\n"))' <<<"$rel"
  jq -r '"\n" + (if (.pinned_in | length) > 0 then "Pinned in:\n" + (.pinned_in | map("- `\(.)`") | join("\n"))
      else "Nothing in bercail pins it." end)
    + (if .min then "\n\nMinimum: \(.min). \(.why // "")" else "" end)
    + (if .notes then "\n\nNotes: \(.notes)" else "" end)' <<<"$entry"
  cat <<EOF

- [ ] New features bercail could use
- [ ] Workarounds in bercail this makes unnecessary
- [ ] Breaking changes that touch bercail
- [ ] Should the minimum move? (lib/deps.json, docs/, lib/help.sh)
- [ ] Set \`known\` to $version in lib/deps.json; the next run closes this issue

Opened by .github/workflows/deps.yml.
EOF
}

# One tool: close its issue once known has caught up, and open or move it on
# when a stable release newer than known is a day old.
track() {
  local entry="$1" issues="$2" name source known rel tag version published number="" title="" have="" body sha=""
  name="$(jq -r .name <<<"$entry")" source="$(jq -r .source <<<"$entry")" known="$(jq -r .known <<<"$entry")"
  if [[ "$source" == none ]]; then
    row "$name" "$known" "" "no feed: check by hand"
    return 0
  fi
  if [[ "$source" == git:* ]]; then
    track_git "$entry" "$issues"
    return 0
  fi
  if ! rel="$(lookup "$source" 2>"$TMP/err")" || ! tag="$(jq -er '.tag // empty' <<<"$rel" 2>>"$TMP/err")" \
    || ! published="$(epoch "$(jq -r '.published // empty' <<<"$rel")" 2>>"$TMP/err")"; then
    fail "$name" "$source: $(last_error)" "$known"
    return 0
  fi
  version="$(norm "$tag")"
  IFS=$'\t' read -r number title < <(jq -r --arg l "deps:$name" \
    'first(.[] | select(any(.labels[]; .name == $l))) | [.number, .title] | @tsv' <<<"$issues") || true
  have="${title##* }"
  if [[ -n "$number" ]] && ! newer "$have" "$known"; then
    gh_write issue close "$number" --comment "lib/deps.json knows $name $known now." >/dev/null \
      || { fail "$name" "could not close #$number" "$known"; return 0; }
    number=""
  fi
  if ! stable "$version"; then
    row "$name" "$known" "$version" "prerelease, ignored"
    return 0
  fi
  if ! newer "$version" "$known"; then
    row "$name" "$known" "$version" "up to date"
    return 0
  fi
  if ((NOW - published < MIN_AGE)); then
    row "$name" "$known" "$version" "under a day old, waiting"
    return 0
  fi
  if [[ -n "$number" && "$have" == "$version" ]]; then
    row "$name" "$known" "$version" "#$number open"
    return 0
  fi
  if [[ "$source" == action:* ]] && ! sha="$(gh api "repos/${source#action:}/commits/$tag" 2>"$TMP/err" | jq -er .sha)"; then
    fail "$name" "the commit of ${source#action:} $tag: $(last_error)" "$known"
    return 0
  fi
  body="$(issue_body "$entry" "$rel" "$version" "$published" "${source#*:}" "$sha")"
  if [[ -z "$number" ]]; then
    open_issue "deps: $name $version" "$body" "deps:$name" || { fail "$name" "could not open its issue" "$known"; return 0; }
    row "$name" "$known" "$version" "opened an issue"
  else
    { gh_write issue edit "$number" --title "deps: $name $version" --body "$body" >/dev/null \
      && gh_write issue comment "$number" --body "$have is superseded by $version: $(jq -r .url <<<"$rel")" >/dev/null; } \
      || { fail "$name" "could not update #$number" "$known"; return 0; }
    row "$name" "$known" "$version" "moved #$number on from $have"
  fi
}

# The issue body for vendored entry $1 whose upstream clone $2 has moved to
# commit $3; the rest are its paths. What changed in them since known, and
# where the steps for a move are.
vendor_body() {
  local entry="$1" dir="$2" target="$3" known repo log stat
  shift 3
  known="$(jq -r .known <<<"$entry")" repo="$(jq -r '.source | ltrimstr("git:")' <<<"$entry")"
  # --stat fetches the blobs it compares; set -e is off under the caller's if.
  log="$(git -C "$dir" log --oneline "$known..$target" -- "$@")" || return
  stat="$(git -C "$dir" diff --stat=1000 "$known" "$target" -- "$@")" || return
  printf '**%s** `%s` → `%s`.\n\nCompare: https://github.com/%s/compare/%s...%s\n' \
    "$(jq -r .name <<<"$entry")" "${known:0:12}" "${target:0:12}" "$repo" "$known" "$target"
  jq -r '.paths // empty | "\nPaths bercail copies: " + (map("`\(.)`") | join(", "))' <<<"$entry"
  printf '\nCommits:\n\n```\n%s\n```\n\nFiles:\n\n```\n%s\n```\n' "$log" "$stat"
  jq -r '"\n" + (if (.pinned_in | length) > 0 then "Pinned in:\n" + (.pinned_in | map("- `\(.)`") | join("\n"))
      else "Nothing in bercail pins it." end)
    + (if .notes then "\n\nNotes: \(.notes)" else "" end)' <<<"$entry"
  cat <<EOF

To take it, move the copy as its \`UPSTREAM.md\` says, then set \`known\` to $target in lib/deps.json; the next run closes this issue.

Opened by .github/workflows/deps.yml.
EOF
}

# One vendored copy (git:<owner>/<repo>): a blobless clone of upstream's default
# branch, and one issue while a first-parent commit past known changes its
# paths. The issue closes once known reaches the commit it names.
track_git() {
  local entry="$1" issues="$2" name repo known short dir tip target number="" title="" have="" body
  local -a paths
  name="$(jq -r .name <<<"$entry")" repo="$(jq -r '.source | ltrimstr("git:")' <<<"$entry")" known="$(jq -r .known <<<"$entry")"
  short="${known:0:12}"
  mapfile -t paths < <(jq -r '.paths // ["."] | .[]' <<<"$entry")
  dir="$(mktemp -d "$TMP/git.XXXXXX")"
  # Not shallow: the check needs known and its ancestry. No code from the clone runs.
  if ! git clone -q --filter=blob:none --no-checkout --single-branch "$GIT_BASE/$repo" "$dir" 2>"$TMP/err" \
    || ! tip="$(git -C "$dir" rev-parse HEAD 2>"$TMP/err")"; then
    fail "$name" "git:$repo: $(last_error)" "$short"
    return 0
  fi
  if ! git -C "$dir" merge-base --is-ancestor "$known" "$tip" 2>/dev/null; then
    fail "$name" "git:$repo: known $known is not on its default branch: upstream rewrote its history, or known is wrong" "$short"
    return 0
  fi
  # A move may pin a commit past the last one to touch paths, so this counts
  # from known, not from that commit.
  if ! target="$(git -C "$dir" rev-list --first-parent -1 "$known..$tip" -- "${paths[@]}" 2>"$TMP/err")"; then
    fail "$name" "git:$repo: $(last_error)" "$short"
    return 0
  fi
  IFS=$'\t' read -r number title < <(jq -r --arg l "deps:$name" \
    'first(.[] | select(any(.labels[]; .name == $l))) | [.number, .title] | @tsv' <<<"$issues") || true
  have="${title##* }"
  if [[ -n "$number" ]]; then
    # Only a full commit: git would read a word such as HEAD as a revision.
    if [[ ! "$have" =~ ^[0-9a-f]{40}$ ]] || ! git -C "$dir" merge-base --is-ancestor "$have" "$tip" 2>/dev/null; then
      fail "$name" "git:$repo: #$number's title ends in $have, not a commit on its default branch" "$short"
      return 0
    fi
    if git -C "$dir" merge-base --is-ancestor "$have" "$known"; then
      gh_write issue close "$number" --comment "lib/deps.json knows $name $known now." >/dev/null \
        || { fail "$name" "could not close #$number" "$short"; return 0; }
      number=""
    fi
  fi
  if [[ -z "$target" ]]; then
    row "$name" "$short" "${tip:0:12}" "up to date"
    return 0
  fi
  if [[ -n "$number" && "$have" == "$target" ]]; then
    row "$name" "$short" "${target:0:12}" "#$number open"
    return 0
  fi
  if ! body="$(vendor_body "$entry" "$dir" "$target" "${paths[@]}" 2>"$TMP/err")"; then
    fail "$name" "git:$repo: $(last_error)" "$short"
    return 0
  fi
  if [[ -z "$number" ]]; then
    { gh_write label create vendor --color fbca04 --description "A vendored copy's upstream moved (lib/deps.json)" --force >/dev/null \
      && open_issue "vendor: $name $target" "$body" "deps:$name" vendor; } \
      || { fail "$name" "could not open its issue" "$short"; return 0; }
    row "$name" "$short" "${target:0:12}" "opened an issue"
  else
    { gh_write issue edit "$number" --title "vendor: $name $target" --body "$body" >/dev/null \
      && gh_write issue comment "$number" --body "$have is superseded by $target: https://github.com/$repo/compare/$have...$target" >/dev/null; } \
      || { fail "$name" "could not update #$number" "$short"; return 0; }
    row "$name" "$short" "${target:0:12}" "moved #$number on from ${have:0:12}"
  fi
}

# Open, update or close the one tracker issue after the run.
report_failures() {
  local issues="$1" number body run
  run="a run by hand"
  [[ -z "${GITHUB_RUN_ID:-}" ]] || run="$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
  number="$(jq -r 'first(.[] | select(any(.labels[]; .name == "deps:tracker"))) | .number' <<<"$issues")"
  if ((${#FAILED[@]} == 0)); then
    [[ -z "$number" ]] || gh_write issue close "$number" --comment "Every lookup worked in $run." >/dev/null
    return 0
  fi
  body="$(printf 'The dependency tracker could not check these in %s:\n\n' "$run"; printf -- '- %s\n' "${FAILED[@]}"
    printf '\nThe other tools were checked. This issue closes on the next run where every lookup works.\n')"
  if [[ -n "$number" ]]; then
    gh_write issue edit "$number" --body "$body" >/dev/null
  else
    open_issue "$TRACKER_TITLE" "$body" deps:tracker
  fi
}

# Each pinned_in entry "path:KEY" says the version is written on the lines of
# path that hold KEY; each must be the tool's known version. A bare path is
# only a pointer. Prints a warning per disagreement; fails when there is one.
check_pins() {
  local bad=0 name known ref file key lineno line found
  if ! jq -e 'type == "array" and all(.[]; (.name | type) == "string" and (.known | type) == "string"
      and (.pinned_in | type) == "array" and has("min") and has("why") and has("notes")
      and (.source | test("^(github:|action:|git:)[^/]+/[^/]+$|^npm:.|^herdr:(app|core)$|^node:[0-9]+$|^none$"))
      and if (.source | startswith("git:")) then (.known | test("^[0-9a-f]{40}$"))
        and ((has("paths") | not) or (.paths | type == "array" and length > 0 and all(.[]; type == "string" and length > 0)))
      else has("paths") | not end)' \
    "$MANIFEST" >/dev/null; then
    printf '::error file=lib/deps.json::every entry needs name, source (github:, action:, git:, npm:, herdr:app, herdr:core, node:<major> or none), min, why, known, pinned_in and notes; a git: entry knows a full commit, and only a git: entry may list paths, as git pathspecs\n'
    return 1
  fi
  while IFS=$'\t' read -r name known ref; do
    [[ "$ref" == *:* ]] || continue
    file="${ref%%:*}" key="${ref#*:}" found=0
    while IFS=: read -r lineno line; do
      line="$(grep -oE '[0-9]+([.-][0-9]+)+' <<<"$line" | tail -1)" || continue
      found=1
      [[ "$(norm "$line")" != "$known" ]] || continue
      printf '::warning file=%s,line=%s::%s: %s pins %s; lib/deps.json knows %s\n' "$file" "$lineno" "$name" "$file" "$line" "$known"
      bad=1
    done < <(grep -nF -- "$key" "$ROOT/$file" 2>/dev/null || true)
    ((found)) || { printf '::warning file=lib/deps.json::%s: no version on a line of %s with %s\n' "$name" "$file" "$key"; bad=1; }
  done < <(jq -r '.[] | .name as $n | .known as $k | .pinned_in[] | [$n, $k, .] | @tsv' "$MANIFEST")
  return "$bad"
}

cmd_check() {
  local issues entry
  local -a entries
  [[ "${1:-}" != --dry-run ]] || DRY_RUN=1
  check_pins || true
  issues="$(gh issue list --label deps --state open --limit 500 --json number,title,labels)" \
    || { printf '::error::could not list the open deps issues\n'; return 1; }
  mapfile -t entries < <(jq -c '.[]' "$MANIFEST")
  for entry in "${entries[@]}"; do
    track "$entry" "$issues"
  done
  report_failures "$issues"
  {
    printf '| Tool | Known | Latest | Result |\n|---|---|---|---|\n'
    printf '%s\n' "${ROWS[@]}"
  } >>"${GITHUB_STEP_SUMMARY:-/dev/null}"
  ((${#FAILED[@]} == 0))
}

# Never fails: a lint run should not go red because the tracker went quiet.
cmd_stale() {
  local last age
  if ! last="$(gh run list --workflow deps.yml --status success --limit 1 --json createdAt 2>"$TMP/err" | jq -r '.[0].createdAt // empty')"; then
    printf "::warning::could not read deps.yml's runs: %s\n" "$(last_error)"
    return 0
  fi
  if [[ -z "$last" ]]; then
    printf '::warning::the dependency tracker (deps.yml) has never succeeded: run it from the Actions tab\n'
    return 0
  fi
  age=$((NOW - $(epoch "$last")))
  ((age > STALE_AFTER)) || return 0
  printf "::warning::the dependency tracker (deps.yml) last succeeded %s days ago, on %s: check its runs, and turn its schedule back on in the Actions tab if GitHub turned it off\n" "$((age / 86400))" "${last%%T*}"
}

case "${1:-}" in
  check) shift; cmd_check "$@" ;;
  pins) check_pins ;;
  stale) cmd_stale ;;
  *) printf 'usage: deps-track.sh check [--dry-run] | pins | stale\n' >&2; exit 2 ;;
esac
