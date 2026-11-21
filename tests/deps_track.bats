#!/usr/bin/env bats
# The dependency tracker (.github/scripts/deps-track.sh), run on a copy in a temp
# repo with its own lib/deps.json. Stand-in gh and curl serve the recorded
# responses in tests/fixtures/deps/, laid out by URL, and log each call; a
# stand-in date fixes the clock. A git: source clones a local upstream made in
# the test. No network.

# shellcheck disable=SC2016 # single-quoted text is literal stand-in code.

setup() {
  load test_helper
  isolate
  need jq
  FIX="$ROOT/tests/fixtures/deps" STATE="$BATS_TEST_TMPDIR/state" REPO="$BATS_TEST_TMPDIR/repo"
  local bin="$BATS_TEST_TMPDIR/bin" real_date
  real_date="$(command -v date)"
  mkdir -p "$STATE" "$REPO/.github/scripts" "$REPO/lib" "$bin"
  cp "$ROOT/.github/scripts/deps-track.sh" "$REPO/.github/scripts/"
  printf '[]\n' >"$STATE/issues.json"
  printf '[]\n' >"$STATE/runs.json"
  # gh: a release or commit from the fixtures, the open issues and deps.yml's
  # runs from $STATE. The writes only log, but an issue's labels must have been
  # created first, as on GitHub.
  cat >"$bin/gh" <<'EOF'
#!/usr/bin/env bash
jq -cn '$ARGS.positional' --args -- "$@" >>"$STATE/gh.jsonl"
case "$1 $2" in
  "api "*)
    [[ -f "$FIX/api.github.com/$2" ]] || { echo 'gh: Not Found (HTTP 404)' >&2; exit 1; }
    cat "$FIX/api.github.com/$2" ;;
  "issue list") cat "$STATE/issues.json" ;;
  "label create") echo "$3" >>"$STATE/labels" ;;
  "issue create")
    while (($#)); do
      [[ "$1" != --label ]] || grep -qxF -- "$2" "$STATE/labels" 2>/dev/null \
        || { echo "could not add label: '$2' not found" >&2; exit 1; }
      shift
    done
    echo https://github.test/o/r/issues/100 ;;
  "run list")
    [[ ! -e "$STATE/runs-fail" ]] || { echo 'HTTP 403: Resource not accessible by integration' >&2; exit 1; }
    cat "$STATE/runs.json" ;;
esac
EOF
  # curl: the fixture at the URL's path, and its .headers file for -D.
  cat >"$bin/curl" <<'EOF'
#!/usr/bin/env bash
jq -cn '$ARGS.positional' --args -- "$@" >>"$STATE/curl.jsonl"
url="" headers=""
while (($#)); do
  case "$1" in
    -D) headers="$2"; shift ;;
    https://*) url="${1#https://}" ;;
  esac
  shift
done
[[ -f "$FIX/$url" ]] || { echo 'curl: (22) The requested URL returned error: 404' >&2; exit 22; }
[[ -z "$headers" ]] || cp "$FIX/$url.headers" "$headers"
cat "$FIX/$url"
EOF
  cat >"$bin/date" <<EOF
#!/usr/bin/env bash
[[ "\$*" != +%s ]] || { echo "\$DEPS_TEST_NOW"; exit; }
exec "$real_date" "\$@"
EOF
  chmod +x "$bin/gh" "$bin/curl" "$bin/date"
  DEPS_TEST_NOW="$(date -u -d 2026-11-14T12:00:00Z +%s)"
  export PATH="$bin:$PATH" FIX STATE DEPS_TEST_NOW DEPS_GIT_BASE="file://$BATS_TEST_TMPDIR/upstream"
}

# git:owner/plugins, served over file:// with filters on, as GitHub serves it: a
# statechart skill, its tests, a license, and a README bercail does not copy.
# Sets PLUGINS and BASE, its first commit.
upstream() {
  PLUGINS="$BATS_TEST_TMPDIR/upstream/owner/plugins"
  git init -q -b main "$PLUGINS"
  git -C "$PLUGINS" config uploadpack.allowFilter true
  BASE="$(commit base pstack/skills/statechart/SKILL.md pstack/skills/statechart/scripts/run.ts \
    pstack/skills/statechart/scripts/test/run.test.ts pstack/LICENSE README.md)"
}

# A commit to the upstream, with subject $1, that changes each file after it. Prints its sha.
commit() {
  local subject="$1" file
  shift
  for file in "$@"; do
    mkdir -p "$(dirname "$PLUGINS/$file")"
    printf '%s\n' "$subject" >>"$PLUGINS/$file"
  done
  git -C "$PLUGINS" add -A
  git -C "$PLUGINS" -c user.name=test -c user.email=test@example.com commit -qm "$subject"
  git -C "$PLUGINS" rev-parse HEAD
}

# The statechart entry as lib/deps.json has it, at known $1, on git:owner/plugins.
vendored() {
  entry pstack-statechart git:owner/plugins "$1" '["skills/statechart/UPSTREAM.md"]' \
    | jq -c '.paths = ["pstack/skills/statechart", ":!pstack/skills/statechart/scripts/test", "pstack/LICENSE"]'
}

# A manifest entry: name, source, known, then pinned_in as a JSON array.
entry() {
  jq -cn --arg name "$1" --arg source "$2" --arg known "$3" --argjson pinned "${4:-[]}" \
    '{name: $name, source: $source, min: null, why: null, known: $known, pinned_in: $pinned, notes: null}'
}

manifest() {
  printf '%s\n' "$@" | jq -s . >"$REPO/lib/deps.json"
}

# An open issue with label deps and each label from $3 on.
open_issue() {
  jq --argjson n "$1" --arg title "$2" \
    '. + [{number: $n, title: $title, labels: ([{name: "deps"}] + ($ARGS.positional | map({name: .})))}]' \
    "$STATE/issues.json" --args -- "${@:3}" >"$STATE/issues.next"
  mv "$STATE/issues.next" "$STATE/issues.json"
}

# Runs the tracker as deps.yml does. Sets out and rc.
track() {
  if out="$(GITHUB_STEP_SUMMARY="$STATE/summary.md" GITHUB_RUN_ID=42 GITHUB_SERVER_URL=https://github.test \
    GITHUB_REPOSITORY=o/r bash "$REPO/.github/scripts/deps-track.sh" "$@" 2>&1)"; then rc=0; else rc=$?; fi
}

# The gh calls whose first two words are $1, one JSON argv a line.
gh_calls() {
  [[ -f "$STATE/gh.jsonl" ]] || return 0
  jq -c --arg cmd "$1" 'select(.[0:2] | join(" ") == $cmd)' "$STATE/gh.jsonl"
}

# The value after flag $2 in the argv $1.
arg() {
  jq -r --arg flag "$2" '. as $a | [range(length) | select($a[.] == $flag) | $a[. + 1]] | join(" ")' <<<"$1"
}

# No issue was opened, edited, commented on or closed.
assert_no_writes() {
  local cmd
  for cmd in "issue create" "issue edit" "issue comment" "issue close"; do
    [[ -z "$(gh_calls "$cmd")" ]] || fail "$1: gh $cmd ran: $(gh_calls "$cmd")"
  done
}

@test "a release newer than known opens one issue, labelled deps and deps:<tool>" {
  manifest "$(entry tuicr github:agavra/tuicr 0.27.0)"
  track check
  [[ "$rc" -eq 0 ]] || fail "rc $rc: $out"
  local create
  create="$(gh_calls "issue create")"
  [[ "$(wc -l <<<"$create")" -eq 1 ]] || fail "one issue: $create"
  [[ "$(arg "$create" --title)" == "deps: tuicr 0.28.0" ]] || fail "title: $create"
  [[ "$(arg "$create" --label)" == "deps deps:tuicr" ]] || fail "labels: $create"
  [[ "$(arg "$create" --body)" == *"0.27.0 → **0.28.0**, released 2026-10-26."* ]] || fail "delta: $create"
  [[ "$(arg "$create" --body)" == *"https://github.com/agavra/tuicr/releases/tag/v0.28.0"* ]] || fail "notes link: $create"
  [[ -n "$(gh_calls "label create" | grep -F '"deps:tuicr"')" ]] || fail "deps:tuicr is created on first use: $(gh_calls "label create")"
}

@test "a tool at its known version opens nothing" {
  manifest "$(entry tuicr github:agavra/tuicr 0.28.0)"
  track check
  [[ "$rc" -eq 0 ]] || fail "rc $rc: $out"
  assert_no_writes "up to date"
  [[ "$out" == *"tuicr: up to date"* ]] || fail "$out"
}

@test "a newer release moves the open issue on instead of opening a second" {
  manifest "$(entry tuicr github:agavra/tuicr 0.26.0)"
  open_issue 7 "deps: tuicr 0.27.0" deps:tuicr
  track check
  [[ "$rc" -eq 0 ]] || fail "rc $rc: $out"
  [[ -z "$(gh_calls "issue create")" ]] || fail "a second issue: $(gh_calls "issue create")"
  local edit comment
  edit="$(gh_calls "issue edit")" comment="$(gh_calls "issue comment")"
  [[ "$(jq -r '.[2]' <<<"$edit")" == 7 && "$(arg "$edit" --title)" == "deps: tuicr 0.28.0" ]] || fail "retitled: $edit"
  [[ "$(arg "$edit" --body)" == *"0.26.0 → **0.28.0**"* ]] || fail "body: $edit"
  [[ "$(jq -r '.[2]' <<<"$comment")" == 7 && "$(arg "$comment" --body)" == "0.27.0 is superseded by 0.28.0: "* ]] \
    || fail "comment: $comment"
}

@test "known catching up closes the tool's issue" {
  manifest "$(entry tuicr github:agavra/tuicr 0.28.0)"
  open_issue 7 "deps: tuicr 0.28.0" deps:tuicr
  track check
  [[ "$rc" -eq 0 ]] || fail "rc $rc: $out"
  local close
  close="$(gh_calls "issue close")"
  [[ "$(jq -r '.[2]' <<<"$close")" == 7 ]] || fail "closed #7: $close"
  [[ "$(arg "$close" --comment)" == "lib/deps.json knows tuicr 0.28.0 now." ]] || fail "comment: $close"
  [[ -z "$(gh_calls "issue create")$(gh_calls "issue edit")" ]] || fail "only a close: $(cat "$STATE/gh.jsonl")"
}

@test "a release under a day old opens nothing yet" {
  manifest "$(entry tuicr github:agavra/tuicr 0.27.0)"
  # tuicr 0.28.0 came out 2026-10-26T08:14:24Z.
  DEPS_TEST_NOW="$(date -u -d '2026-10-27T08:14:23Z' +%s)" track check
  [[ "$rc" -eq 0 ]] || fail "rc $rc: $out"
  assert_no_writes "under a day"
  [[ "$out" == *"tuicr: under a day old, waiting"* ]] || fail "$out"
}

@test "a prerelease opens nothing" {
  # Node's newest 27 is v27.0.0-alpha.0.1.0.
  manifest "$(entry node node:27 26.13.1)"
  track check
  [[ "$rc" -eq 0 ]] || fail "rc $rc: $out"
  assert_no_writes "prerelease"
  [[ "$out" == *"node: prerelease, ignored"* ]] || fail "$out"
}

@test "a failed lookup opens the tracker issue, still checks the rest, and exits 1" {
  # tuicr is up to date, so no tool issue creates the deps label first.
  manifest "$(entry gone npm:no-such-package 1.0.0)" "$(entry tuicr github:agavra/tuicr 0.28.0)"
  track check
  [[ "$rc" -eq 1 ]] || fail "rc $rc: $out"
  local tracker
  tracker="$(gh_calls "issue create" | jq -c 'select(index("deps: tracker failing"))')"
  [[ -n "$tracker" ]] || fail "no tracker issue: $(gh_calls "issue create")"
  [[ "$(arg "$tracker" --label)" == "deps deps:tracker" ]] || fail "labels: $tracker"
  [[ "$(arg "$tracker" --body)" == *"- gone: npm:no-such-package: curl: (22) The requested URL returned error: 404"* ]] \
    || fail "names the source and its error: $tracker"
  [[ "$(arg "$tracker" --body)" == *"https://github.test/o/r/actions/runs/42"* ]] || fail "links the run: $tracker"
  [[ "$out" == *"tuicr: up to date"* ]] || fail "tuicr was not checked: $out"
  grep -qF '| gone | 1.0.0 |  | **failed:** npm:no-such-package: curl: (22)' "$STATE/summary.md" \
    || fail "the run summary lists the failure: $out"
}

@test "a failure while the tracker issue is open updates it instead of opening another" {
  manifest "$(entry gone npm:no-such-package 1.0.0)"
  open_issue 9 "deps: tracker failing" deps:tracker
  track check
  [[ "$rc" -eq 1 ]] || fail "rc $rc: $out"
  [[ -z "$(gh_calls "issue create")" ]] || fail "a second tracker issue: $(gh_calls "issue create")"
  [[ "$(gh_calls "issue edit" | jq -r '.[2]')" == 9 ]] || fail "updated #9: $(gh_calls "issue edit")"
}

@test "a clean run closes the tracker issue" {
  manifest "$(entry tuicr github:agavra/tuicr 0.28.0)"
  open_issue 9 "deps: tracker failing" deps:tracker
  track check
  [[ "$rc" -eq 0 ]] || fail "rc $rc: $out"
  local close
  close="$(gh_calls "issue close")"
  [[ "$(jq -r '.[2]' <<<"$close")" == 9 ]] || fail "closed #9: $close"
  [[ "$(arg "$close" --comment)" == "Every lookup worked in https://github.test/o/r/actions/runs/42." ]] || fail "comment: $close"
}

@test "source none makes no lookup and is listed in the run summary" {
  manifest "$(entry workers-compatibility-date none 2026-07-01)"
  track check
  [[ "$rc" -eq 0 ]] || fail "rc $rc: $out"
  [[ ! -e "$STATE/curl.jsonl" && -z "$(gh_calls "api repos")" ]] || fail "looked up: $(cat "$STATE"/*.jsonl)"
  grep -qxF '| workers-compatibility-date | 2026-07-01 |  | no feed: check by hand |' "$STATE/summary.md" \
    || fail "summary: $(cat "$STATE/summary.md")"
}

@test "an action's issue names the commit to pin it to" {
  manifest "$(entry actions/checkout action:actions/checkout 7.0.0)"
  track check
  [[ "$rc" -eq 0 ]] || fail "rc $rc: $out"
  local create
  create="$(gh_calls "issue create")"
  [[ "$(arg "$create" --title)" == "deps: actions/checkout 7.0.1" ]] || fail "title: $create"
  [[ "$(arg "$create" --body)" == *'`uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1`'* ]] \
    || fail "the SHA to move to: $create"
}

@test "an npm release comes from the registry, with its publish time" {
  manifest "$(entry wrangler npm:wrangler 4.107.0)"
  # 4.162.0 came out 2026-11-13T17:04:39Z.
  DEPS_TEST_NOW="$(date -u -d 2026-11-15T12:00:00Z +%s)" track check
  [[ "$rc" -eq 0 ]] || fail "rc $rc: $out"
  local create
  create="$(gh_calls "issue create")"
  [[ "$(arg "$create" --title)" == "deps: wrangler 4.162.0" ]] || fail "title: $create"
  [[ "$(arg "$create" --body)" == *"released 2026-11-13."*"https://www.npmjs.com/package/wrangler/v/4.162.0"* ]] \
    || fail "date and link: $create"
  [[ "$(jq -r 'index("--max-time") as $i | .[$i + 1]' "$STATE/curl.jsonl")" == 20 ]] || fail "bounded: $(cat "$STATE/curl.jsonl")"
}

@test "a Herdr release counts its age from latest.json's Last-Modified" {
  manifest "$(entry herdr-app herdr:app 0.1.14)"
  # latest.json for 0.1.15 was last modified Tue, 10 Nov 2026 19:24:23 GMT.
  DEPS_TEST_NOW="$(date -u -d '2026-11-10T20:24:23Z' +%s)" track check
  assert_no_writes "an hour after Last-Modified"
  track check
  [[ "$rc" -eq 0 ]] || fail "rc $rc: $out"
  local create
  create="$(gh_calls "issue create")"
  [[ "$(arg "$create" --title)" == "deps: herdr-app 0.1.15" ]] || fail "title: $create"
  [[ "$(arg "$create" --body)" == *"released 2026-11-10."*"> Herdr 0.1.15"* ]] || fail "date and notes: $create"
}

@test "Node is tracked within its major" {
  manifest "$(entry node node:26 26.13.0)"
  track check
  [[ "$rc" -eq 0 ]] || fail "rc $rc: $out"
  [[ "$(arg "$(gh_calls "issue create")" --title)" == "deps: node 26.13.1" ]] || fail "$(gh_calls "issue create")"
}

@test "a git: source whose copied paths moved past known opens one vendor issue with the log, diffstat and compare link" {
  upstream
  local target create body
  target="$(commit 'run.ts reads CRLF (#12)' pstack/skills/statechart/scripts/run.ts)"
  manifest "$(vendored "$BASE")"
  track check
  [[ "$rc" -eq 0 ]] || fail "rc $rc: $out"
  create="$(gh_calls "issue create")"
  [[ "$(wc -l <<<"$create")" -eq 1 ]] || fail "one issue: $create"
  [[ "$(arg "$create" --title)" == "vendor: pstack-statechart $target" ]] || fail "title: $create"
  [[ "$(arg "$create" --label)" == "deps deps:pstack-statechart vendor" ]] || fail "labels: $create"
  body="$(arg "$create" --body)"
  [[ "$body" == "**pstack-statechart** \`${BASE:0:12}\` → \`${target:0:12}\`."* ]] || fail "delta: $body"
  [[ "$body" == *"$(git -C "$PLUGINS" log -1 --oneline "$target")"* ]] || fail "the log: $body"
  [[ "$body" == *" pstack/skills/statechart/scripts/run.ts | 1 +"* ]] || fail "the diffstat: $body"
  [[ "$body" == *"https://github.com/owner/plugins/compare/$BASE...$target"* ]] || fail "compare link: $body"
  [[ "$body" == *'- `skills/statechart/UPSTREAM.md`'* && "$body" == *"set \`known\` to $target"* ]] || fail "pinned_in and the step: $body"
  [[ "$out" == *"pstack-statechart: opened an issue"* ]] || fail "$out"
}

@test "a git: source is current when the commits past known leave its paths alone" {
  upstream
  local known
  # known is past the last commit to touch the paths, and the tip is past known.
  known="$(commit docs README.md)"
  commit 'more docs' README.md >/dev/null
  manifest "$(vendored "$known")"
  track check
  [[ "$rc" -eq 0 ]] || fail "rc $rc: $out"
  assert_no_writes "current"
  [[ "$out" == *"pstack-statechart: up to date"* ]] || fail "$out"
}

@test "a commit that changes only upstream's tests opens no vendor issue" {
  upstream
  commit 'more tests' pstack/skills/statechart/scripts/test/run.test.ts >/dev/null
  manifest "$(vendored "$BASE")"
  track check
  [[ "$rc" -eq 0 ]] || fail "rc $rc: $out"
  assert_no_writes "test-only"
  [[ "$out" == *"pstack-statechart: up to date"* ]] || fail "$out"
}

@test "a commit that changes only the license opens a vendor issue for it, not for a later test-only tip" {
  upstream
  local target create body
  target="$(commit 'license year' pstack/LICENSE)"
  commit 'more tests' pstack/skills/statechart/scripts/test/run.test.ts >/dev/null
  manifest "$(vendored "$BASE")"
  track check
  [[ "$rc" -eq 0 ]] || fail "rc $rc: $out"
  create="$(gh_calls "issue create")"
  [[ "$(arg "$create" --title)" == "vendor: pstack-statechart $target" ]] || fail "title: $create"
  [[ "$(arg "$create" --label)" == "deps deps:pstack-statechart vendor" ]] || fail "labels: $create"
  body="$(arg "$create" --body)"
  [[ "$body" == *" pstack/LICENSE | 1 +"* && "$body" == *" 1 file changed"* ]] || fail "the diffstat: $body"
  [[ "$body" != *"more tests"* && "$body" != *run.test.ts* ]] || fail "upstream's tests are left out: $body"
}

@test "a known that upstream's rewritten history no longer holds fails the lookup and opens no vendor issue" {
  upstream
  local gone create
  gone="$(commit 'force-pushed away' pstack/skills/statechart/SKILL.md)"
  git -C "$PLUGINS" reset -q --hard "$BASE"
  commit rewritten pstack/skills/statechart/SKILL.md >/dev/null
  manifest "$(vendored "$gone")"
  track check
  [[ "$rc" -eq 1 ]] || fail "rc $rc: $out"
  create="$(gh_calls "issue create")"
  [[ "$(wc -l <<<"$create")" -eq 1 && "$(arg "$create" --title)" == "deps: tracker failing" ]] || fail "only the tracker issue: $create"
  [[ "$(arg "$create" --body)" == *"- pstack-statechart: git:owner/plugins: known $gone is not on its default branch: upstream rewrote its history, or known is wrong"* ]] \
    || fail "names the entry and why: $create"
}

@test "a newer target retitles the open vendor issue and comments on it instead of opening a second" {
  upstream
  local first second edit comment body
  first="$(commit first pstack/skills/statechart/scripts/run.ts)"
  second="$(commit second pstack/skills/statechart/SKILL.md)"
  open_issue 7 "vendor: pstack-statechart $first" deps:pstack-statechart vendor
  manifest "$(vendored "$BASE")"
  track check
  [[ "$rc" -eq 0 ]] || fail "rc $rc: $out"
  [[ -z "$(gh_calls "issue create")" ]] || fail "a second issue: $(gh_calls "issue create")"
  edit="$(gh_calls "issue edit")" comment="$(gh_calls "issue comment")"
  [[ "$(jq -r '.[2]' <<<"$edit")" == 7 && "$(arg "$edit" --title)" == "vendor: pstack-statechart $second" ]] || fail "retitled: $edit"
  body="$(arg "$edit" --body)"
  [[ "$body" == *"$(git -C "$PLUGINS" log -1 --oneline "$second")"* && "$body" == *"$(git -C "$PLUGINS" log -1 --oneline "$first")"* \
    && "$body" == *" 2 files changed"* ]] || fail "the body covers both commits: $body"
  [[ "$body" == *"https://github.com/owner/plugins/compare/$BASE...$second"* ]] || fail "compare link: $body"
  [[ "$(jq -r '.[2]' <<<"$comment")" == 7 ]] || fail "commented on #7: $comment"
  [[ "$(arg "$comment" --body)" == "$first is superseded by $second: https://github.com/owner/plugins/compare/$first...$second" ]] \
    || fail "comment: $comment"
}

@test "known reaching past the vendor issue's target closes it" {
  upstream
  local target known close
  target="$(commit first pstack/skills/statechart/scripts/run.ts)"
  # The move pinned the tip, past the commit the issue names.
  known="$(commit docs README.md)"
  open_issue 7 "vendor: pstack-statechart $target" deps:pstack-statechart vendor
  manifest "$(vendored "$known")"
  track check
  [[ "$rc" -eq 0 ]] || fail "rc $rc: $out"
  close="$(gh_calls "issue close")"
  [[ "$(jq -r '.[2]' <<<"$close")" == 7 ]] || fail "closed #7: $close"
  [[ "$(arg "$close" --comment)" == "lib/deps.json knows pstack-statechart $known now." ]] || fail "comment: $close"
  [[ -z "$(gh_calls "issue create")$(gh_calls "issue edit")$(gh_calls "issue comment")" ]] || fail "only a close: $(cat "$STATE/gh.jsonl")"
}

@test "an open vendor issue whose commit is not on upstream's branch fails the lookup and stays open" {
  upstream
  local missing=0123456789abcdef0123456789abcdef01234567
  open_issue 7 "vendor: pstack-statechart $missing" deps:pstack-statechart vendor
  manifest "$(vendored "$BASE")"
  track check
  [[ "$rc" -eq 1 ]] || fail "rc $rc: $out"
  [[ -z "$(gh_calls "issue close")" ]] || fail "closed: $(gh_calls "issue close")"
  [[ "$(arg "$(gh_calls "issue create")" --body)" == *"- pstack-statechart: git:owner/plugins: #7's title ends in $missing, not a commit on its default branch"* ]] \
    || fail "the tracker issue says why: $(gh_calls "issue create")"
}

@test "an open issue whose title does not end in a full commit is left alone, even when git could read it" {
  upstream
  open_issue 7 "Release notes HEAD" deps:pstack-statechart
  manifest "$(vendored "$BASE")"
  track check
  [[ "$rc" -eq 1 ]] || fail "rc $rc: $out"
  [[ -z "$(gh_calls "issue close")$(gh_calls "issue edit")$(gh_calls "issue comment")" ]] || fail "wrote to #7: $(cat "$STATE/gh.jsonl")"
  [[ "$(arg "$(gh_calls "issue create")" --body)" == *"- pstack-statechart: git:owner/plugins: #7's title ends in HEAD, not a commit on its default branch"* ]] \
    || fail "the tracker issue says why: $(gh_calls "issue create")"
}

@test "an open vendor issue already at the target is left as it is" {
  upstream
  local target
  target="$(commit first pstack/skills/statechart/scripts/run.ts)"
  open_issue 7 "vendor: pstack-statechart $target" deps:pstack-statechart vendor
  manifest "$(vendored "$BASE")"
  track check
  [[ "$rc" -eq 0 ]] || fail "rc $rc: $out"
  assert_no_writes "at the target"
  [[ "$out" == *"pstack-statechart: #7 open"* ]] || fail "$out"
}

@test "a merge onto the default branch that brings in a copied change is the target, not the side branch's commit" {
  upstream
  local merge
  git -C "$PLUGINS" checkout -q -b side
  commit 'side change' pstack/skills/statechart/scripts/run.ts >/dev/null
  git -C "$PLUGINS" checkout -q main
  commit docs README.md >/dev/null
  git -C "$PLUGINS" -c user.name=test -c user.email=test@example.com merge -q --no-ff -m 'merge side (#3)' side
  merge="$(git -C "$PLUGINS" rev-parse HEAD)"
  manifest "$(vendored "$BASE")"
  track check
  [[ "$rc" -eq 0 ]] || fail "rc $rc: $out"
  [[ "$(arg "$(gh_calls "issue create")" --title)" == "vendor: pstack-statechart $merge" ]] || fail "title: $(gh_calls "issue create")"
}

@test "a pathspec git cannot read fails the lookup and the run goes on to the next entry" {
  upstream
  manifest "$(vendored "$BASE" | jq -c '.paths = [":(not-a-magic)src"]')" "$(entry tuicr github:agavra/tuicr 0.28.0)"
  track check
  [[ "$rc" -eq 1 ]] || fail "rc $rc: $out"
  [[ "$(arg "$(gh_calls "issue create")" --body)" == *"- pstack-statechart: git:owner/plugins: "*"not-a-magic"* ]] \
    || fail "the tracker issue names git's error: $(gh_calls "issue create")"
  [[ "$out" == *"tuicr: up to date"* ]] || fail "tuicr was not checked: $out"
}

@test "pins takes a git: entry with paths, and fails one whose known is not a full commit or paths on another source" {
  manifest "$(vendored 3dbd22ff12742fb28c9700b9760baa29ed41dc13)"
  track pins
  [[ "$rc" -eq 0 && -z "$out" ]] || fail "a full commit, rc $rc: $out"
  manifest "$(vendored 3dbd22f)"
  track pins
  [[ "$rc" -eq 1 && "$out" == "::error file=lib/deps.json::every entry needs"* ]] || fail "a short commit, rc $rc: $out"
  manifest "$(entry tuicr github:agavra/tuicr 0.28.0 | jq -c '.paths = ["src"]')"
  track pins
  [[ "$rc" -eq 1 && "$out" == "::error file=lib/deps.json::every entry needs"* ]] || fail "paths on github:, rc $rc: $out"
  manifest "$(vendored 3dbd22ff12742fb28c9700b9760baa29ed41dc13 | jq -c '.paths = false')"
  track pins
  [[ "$rc" -eq 1 && "$out" == "::error file=lib/deps.json::every entry needs"* ]] || fail "paths not a list, rc $rc: $out"
}

@test "a pin that disagrees with known fails pins and warns in check, naming the file and line" {
  mkdir -p "$REPO/.github/workflows"
  printf 'jobs:\n  lint:\n    env:\n      TUICR_VERSION: 0.27.0\n' >"$REPO/.github/workflows/ci.yml"
  manifest "$(entry tuicr github:agavra/tuicr 0.28.0 '[".github/workflows/ci.yml:TUICR_VERSION"]')"
  local want='::warning file=.github/workflows/ci.yml,line=4::tuicr: .github/workflows/ci.yml pins 0.27.0; lib/deps.json knows 0.28.0'
  track pins
  [[ "$rc" -eq 1 && "$out" == "$want" ]] || fail "pins, rc $rc: $out"
  track check
  [[ "$rc" -eq 0 && "$out" == *"$want"* ]] || fail "check, rc $rc: $out"
}

@test "pins fails on a manifest entry without a field" {
  manifest '{"name": "tuicr", "source": "github:agavra/tuicr", "known": "0.28.0", "pinned_in": []}'
  track pins
  [[ "$rc" -eq 1 && "$out" == "::error file=lib/deps.json::every entry needs"* ]] || fail "rc $rc: $out"
}

@test "this tree's pins agree with lib/deps.json" {
  if out="$(bash "$ROOT/.github/scripts/deps-track.sh" pins 2>&1)"; then rc=0; else rc=$?; fi
  [[ "$rc" -eq 0 && -z "$out" ]] || fail "rc $rc: $out"
}

@test "stale warns when deps.yml last succeeded over 3 days ago" {
  printf '[{"createdAt": "2026-11-10T07:17:00Z"}]\n' >"$STATE/runs.json"
  track stale
  [[ "$rc" -eq 0 && "$out" == "::warning::the dependency tracker (deps.yml) last succeeded 4 days ago, on 2026-11-10:"* ]] \
    || fail "rc $rc: $out"
  [[ "$(gh_calls "run list")" == '["run","list","--workflow","deps.yml","--status","success",'* ]] || fail "$(gh_calls "run list")"
}

@test "stale says nothing when deps.yml succeeded in the last 3 days" {
  printf '[{"createdAt": "2026-11-12T07:17:00Z"}]\n' >"$STATE/runs.json"
  track stale
  [[ "$rc" -eq 0 && -z "$out" ]] || fail "rc $rc: $out"
}

@test "stale warns without failing when deps.yml never succeeded" {
  track stale
  [[ "$rc" -eq 0 && "$out" == "::warning::the dependency tracker (deps.yml) has never succeeded"* ]] || fail "rc $rc: $out"
}

@test "stale warns without failing when gh cannot list the runs" {
  : >"$STATE/runs-fail"
  track stale
  [[ "$rc" -eq 0 && "$out" == "::warning::could not read deps.yml's runs: HTTP 403: Resource not accessible by integration" ]] \
    || fail "rc $rc: $out"
}

@test "doctor reads tuicr's minimum from lib/deps.json" {
  local lib="$BATS_TEST_TMPDIR/lib" bin="$BATS_TEST_TMPDIR/tuicr-bin"
  mkdir -p "$lib" "$bin"
  cp "$ROOT/lib/deps.sh" "$lib/"
  jq 'map(if .name == "tuicr" then .min = "9.9.9" else . end)' "$ROOT/lib/deps.json" >"$lib/deps.json"
  printf '#!/bin/sh\necho "tuicr 1.0.0"\n' >"$bin/tuicr"
  chmod +x "$bin/tuicr"
  # shellcheck source=lib/detect.sh disable=SC1091
  source "$ROOT/lib/detect.sh"
  # shellcheck source=/dev/null
  source "$lib/deps.sh"
  log() { printf '%s\n' "$*"; }
  out="$(PATH="$bin:$PATH" doctor_dependencies 2>&1)" || true
  grep -q "^  outdated  tuicr (.*; found 1.0.0, required >=9.9.9) (configured review)$" <<<"$out" || fail "$out"
}
