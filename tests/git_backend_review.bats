#!/usr/bin/env bats
# review-pr stack discovery through the gh and Origin git backends, against
# fake gh, origin, gt, and herdr-app. No network.

setup() {
  load test_helper
  isolate
  export BERCAIL_CONFIG="$BATS_TEST_TMPDIR/config.toml"
  export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
  export FIX="$BATS_TEST_TMPDIR/fixtures" LOG="$BATS_TEST_TMPDIR/log"
  mkdir -p "$FIX" "$LOG" "$BATS_TEST_TMPDIR/bin"
  # shellcheck source=/dev/null
  source "$ROOT/lib/review.sh"

  # Two truly dependent branches, published only as heads (not GitHub pull refs).
  local seed="$BATS_TEST_TMPDIR/seed" n head parent sha base
  export REMOTE="$BATS_TEST_TMPDIR/remote.git"
  git init -q --bare -b main "$REMOTE"
  git init -q -b main "$seed"
  git -C "$seed" config user.name test
  git -C "$seed" config user.email test@example.com
  printf 'base\n' >"$seed/file"
  git -C "$seed" add file && git -C "$seed" commit -qm base
  BASE="$(git -C "$seed" rev-parse HEAD)"
  git -C "$seed" switch -qc one
  printf 'one\n' >>"$seed/file"
  git -C "$seed" commit -qam one
  ONE="$(git -C "$seed" rev-parse HEAD)"
  git -C "$seed" switch -qc two
  printf 'two\n' >>"$seed/file"
  git -C "$seed" commit -qam two
  TWO="$(git -C "$seed" rev-parse HEAD)"
  git -C "$seed" push -q "$REMOTE" main one two
  git clone -q "$REMOTE" "$BATS_TEST_TMPDIR/work"
  export WORK="$BATS_TEST_TMPDIR/work"
  for n in 1 2; do
    head=one parent=main sha="$ONE" base="$BASE"
    if [[ "$n" == 2 ]]; then head=two parent=one sha="$TWO" base="$ONE"; fi
    jq -n --argjson n "$n" --arg head "$head" --arg parent "$parent" --arg sha "$sha" --arg base "$base" \
      '{number:$n,title:("Change " + ($n|tostring)),body:"An independently useful slice.",url:("https://review.cursor.com/pr/acme/widgets/"+($n|tostring)),
        author:{id:"actor-1",kind:"user",displayName:"Test Author",avatarUrl:""},isDraft:false,baseRefName:$parent,headRefName:$head,headRefOid:$sha,baseRefOid:$base,
        files:[{path:"file",changeKind:"modified",isBinary:false,additions:1,deletions:0}]}' >"$FIX/pr-$n.json"
  done
  cat >"$FIX/native.json" <<'JSON'
{"source":"remote","trunk":"main","members":[{"branch":"two","parent":"one","number":2},{"branch":"one","parent":"main","number":1}]}
JSON
  cat >"$BATS_TEST_TMPDIR/bin/origin" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$LOG/origin"
case "$1 $2" in
  'stack view')
    git rev-parse --git-dir >/dev/null 2>&1 && exit 9
    [[ "$*" == *'--json source,trunk,members'* && "$*" == *'-R acme/widgets'* ]] || exit 9
    cat "$FIX/native.json" ;;
  'pr view')
    [[ "$*" != *closingIssuesReferences* && "$*" != *statusCheckRollup* && "$*" != *'-R origin.cursor.com/'* ]] || exit 9
    cat "$FIX/pr-$3.json" ;;
  'pr checks') printf '[{"name":"test","status":"completed","conclusion":"success","detailsUrl":"https://ci/test"}]\n' ;;
  'pr list') printf '[{"number":2,"url":"https://cursor.com/codebase/acme/widgets/pull/2"}]\n' ;;
  'repo clone') git clone -q "$REMOTE" "$4" ;;
  *) exit 9 ;;
esac
SH
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$PWD $*" >>"$LOG/gh"
case "$1 $2" in
  'stack view')
    [[ "$PWD" != "$WORK" ]] || exit 9
    printf '{"trunk":"main","branches":[{"name":"one","base":"SHA-NOT-BRANCH","pr":{"number":1}},{"name":"two","base":"SHA-NOT-BRANCH","pr":{"number":2}}]}\n' ;;
  'repo view') printf '{"defaultBranchRef":{"name":"main"}}\n' ;;
  'api --hostname')
    case "${FAKE_STACK_API:-}" in
      found) printf '[{"pull_requests":[{"number":1},{"number":2}]}]\n' ;;
      missing) echo 'gh: Not Found (HTTP 404)' >&2; exit 1 ;;
      broken) echo 'gh: Unauthorized (HTTP 401)' >&2; exit 1 ;;
      *) echo '[]' ;;
    esac ;;
  'stack checkout') [[ "$PWD" != "$WORK" && "$3" == https://* && ! -e .git/gh-stack ]] || exit 9 ;;
  *) exit 9 ;;
esac
SH
  printf '#!/usr/bin/env bash\nexit 1\n' >"$BATS_TEST_TMPDIR/bin/herdr-app"
  printf '#!/usr/bin/env bash\necho "gt must not run" >&2; exit 99\n' >"$BATS_TEST_TMPDIR/bin/gt"
  chmod +x "$BATS_TEST_TMPDIR/bin/"*
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH" HERDR_APP="$BATS_TEST_TMPDIR/bin/herdr-app"
}

# The selected PR can be in a different stack than the source's current branch.
gh_stack_catalog() {
  cat >"$WORK/.git/gh-stack" <<'JSON'
{"schemaVersion":1,"repository":"github.com/acme/widgets","stacks":[{"trunk":{"branch":"main"},"branches":[{"branch":"one","pullRequest":{"number":1}},{"branch":"two","pullRequest":{"number":2}}]}]}
JSON
  jq '.url = "https://github.com/acme/widgets/pull/2"' "$FIX/pr-2.json" >"$FIX/gh-entry.json"
}

# Origin is explicit here so the live forge is never contacted by the fixture.
origin_config() {
  printf '[git]\n"%s" = "origin"\n' "$WORK" >"$BERCAIL_CONFIG"
  printf 'origin.cursor.com/acme/widgets\n' >"$WORK/.git/bercail-review-repo"
}

@test "gh stack selects requested PR and refreshes only a private clone" {
  local before order
  gh_stack_catalog
  before="$(git -C "$WORK" status --porcelain);$(git -C "$WORK" rev-parse HEAD);$(cksum "$WORK/.git/gh-stack")"
  order="$(stack_discover github.com/acme/widgets "$FIX/gh-entry.json" "$WORK" "$BATS_TEST_TMPDIR/gh-sync" gh)"
  [[ "$(jq -r '.via' <<<"$order")" == gh-stack && "$(jq -c .numbers <<<"$order")" == '[1,2]' ]] || fail "gh stack order: $order"
  [[ "$before" == "$(git -C "$WORK" status --porcelain);$(git -C "$WORK" rev-parse HEAD);$(cksum "$WORK/.git/gh-stack")" ]] || fail 'gh stack modified source'
}

@test "repeat gh gather fetches missing heads and keeps its private index clean" {
  local seed="$BATS_TEST_TMPDIR/seed" advanced
  gh_stack_catalog
  stack_discover github.com/acme/widgets "$FIX/gh-entry.json" "$WORK" "$BATS_TEST_TMPDIR/gh-sync" gh >/dev/null
  printf 'advance\n' >>"$seed/file"
  git -C "$seed" commit -qam advance
  git -C "$seed" push -q "$REMOTE" two
  advanced="$(git -C "$seed" rev-parse HEAD)"
  jq --arg sha "$advanced" '.headRefOid = $sha' "$FIX/gh-entry.json" >"$FIX/gh-advanced.json"
  stack_discover github.com/acme/widgets "$FIX/gh-advanced.json" "$WORK" "$BATS_TEST_TMPDIR/gh-sync" gh >/dev/null
  [[ -z "$(git -C "$BATS_TEST_TMPDIR/gh-sync" status --porcelain)" ]] || fail 'repeat gather left private index dirty'
  [[ "$(git -C "$BATS_TEST_TMPDIR/gh-sync" rev-parse HEAD)" == "$advanced" ]] || fail 'stale source hid latest remote head'
  [[ "$(git -C "$WORK" rev-parse HEAD)" == "$BASE" ]] || fail 'repeat gather changed source'
}

@test "remote-only gh stacks use native checkout and leave the source catalog alone" {
  local order
  gh_stack_catalog
  mv "$WORK/.git/gh-stack" "$BATS_TEST_TMPDIR/saved-catalog"
  order="$(FAKE_STACK_API=found stack_discover github.com/acme/widgets "$FIX/gh-entry.json" "$WORK" "$BATS_TEST_TMPDIR/remote-sync" gh)"
  [[ "$(jq -r .via <<<"$order")" == gh-stack ]] || fail 'remote-only native stack missed'
  [[ ! -e "$WORK/.git/gh-stack" ]] || fail 'remote discovery wrote source catalog'
  cp "$BATS_TEST_TMPDIR/saved-catalog" "$BATS_TEST_TMPDIR/remote-sync/.git/gh-stack"
  FAKE_STACK_API=found stack_discover github.com/acme/widgets "$FIX/gh-entry.json" "$WORK" "$BATS_TEST_TMPDIR/remote-sync" gh >/dev/null
}

@test "remote-only gh stacks: only empty/404 falls back to the GitHub walk" {
  local rc
  gh_stack_catalog
  mv "$WORK/.git/gh-stack" "$BATS_TEST_TMPDIR/saved-catalog"
  rc=0
  FAKE_STACK_API=missing _stack_gh_stack "$WORK" "$FIX/pr-2.json" "$BATS_TEST_TMPDIR/missing-sync" github.com/acme/widgets >/dev/null || rc=$?
  [[ "$rc" == 3 ]] || fail '404 should fall back to GitHub walk'
  rc=0
  FAKE_STACK_API=broken _stack_gh_stack "$WORK" "$FIX/pr-2.json" "$BATS_TEST_TMPDIR/broken-sync" github.com/acme/widgets >/dev/null 2>&1 || rc=$?
  [[ "$rc" == 1 ]] || fail 'auth failure should not masquerade as no native stack'
}

@test "Origin review accepts both URL formats and branches, gathers native stack/PR/checks without gh" {
  local url out stack
  origin_config
  : >"$LOG/gh"
  for url in https://review.cursor.com/pr/acme/widgets/2 https://cursor.com/codebase/acme/widgets/pull/2; do
    out="$(cd "$WORK" && "$ROOT/bin/bercail" review-pr "$url" --no-run)"
    stack="$(jq -r .stack <<<"$out")"
    [[ "$(jq -c '[.prs[].number]' "$stack/stack.json")" == '[1,2]' ]] || fail 'Origin order'
    [[ "$(jq -r .git "$stack/stack.json")" == origin ]] || fail 'Origin enum persisted'
    [[ "$(jq -r '.prs[0].author' "$stack/stack.json")" == 'Test Author' ]] || fail 'Origin author normalization'
    [[ "$(jq -r '.[0].bucket' "$stack/pr-2/$TWO/ci.json")" == pass ]] || fail 'Origin CI normalization'
    [[ "$(git -C "$WORK" branch --show-current)" == main ]] || fail 'Origin moved source branch'
  done
  [[ ! -s "$LOG/gh" ]] || fail 'Origin review called gh'
  "$ROOT/bin/bercail" review-pr open 2 --stack "$stack" >/dev/null
  grep -q 'pr view 2 -R acme/widgets --web' "$LOG/origin" || fail 'Origin review open must use native browser, not tuicr pr'
  (cd "$WORK" && "$ROOT/bin/bercail" review-pr two --no-run) >/dev/null
}

@test "Origin fallback clones to ~/Work/<repo> without gh" {
  origin_config
  (cd "$BATS_TEST_TMPDIR" && "$ROOT/bin/bercail" review-pr https://review.cursor.com/pr/acme/widgets/2 --no-run) >/dev/null
  [[ -d "$HOME/Work/widgets/.git" ]] || fail 'Origin fallback did not clone'
  [[ ! -s "$LOG/gh" ]] || fail 'Origin fallback called gh'
}

@test "Origin remotes match environment hosts exactly, not lookalikes" {
  git -C "$WORK" remote set-url origin https://origin-staging.cursor.com/git/acme/widgets.git
  _review_origin_matches "$WORK" acme widgets origin.cursor.com || fail 'Origin environment remote rejected'
  git -C "$WORK" remote set-url origin https://origin.cursor.com.evil/acme/widgets.git
  if _review_origin_matches "$WORK" acme widgets origin.cursor.com; then fail 'lookalike Origin host accepted'; fi
}

@test "native stack forks, cycles, and duplicate PRs are refused" {
  # Refuse graph ambiguity rather than choosing a partial path.
  local linear cycle trunk_cycle duplicate rc=0
  linear='{"trunk":"main","members":[{"branch":"a","parent":"main","number":1},{"branch":"b","parent":"main","number":2}]}'
  _stack_native_order "$linear" >/dev/null || rc=$?
  [[ "$rc" == 2 ]] || fail 'native fork must signal ambiguity'
  cycle='{"trunk":"main","members":[{"branch":"a","parent":"b","number":1},{"branch":"b","parent":"a","number":2}]}'
  _stack_native_order "$cycle" >/dev/null 2>&1 && fail 'native cycle accepted'
  trunk_cycle='{"trunk":"main","members":[{"branch":"a","parent":"main","number":1},{"branch":"main","parent":"a","number":2}]}'
  _stack_native_order "$trunk_cycle" >/dev/null 2>&1 && fail 'cycle through trunk accepted'
  duplicate='{"trunk":"main","members":[{"branch":"a","parent":"main","number":1},{"branch":"b","parent":"a","number":1}]}'
  if _stack_native_order "$duplicate" >/dev/null 2>&1; then fail 'duplicate PR accepted'; fi
}
