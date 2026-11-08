#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail
unset BASH_ENV HC_TERMINAL_ID BERCAIL_REVIEW_STACK
export __MISE_BASH_ENV_LOADED=1
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/config" XDG_STATE_HOME="$TMP/state"
export BERCAIL_CONFIG="$TMP/config.toml"
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
export FIX="$TMP/fixtures" LOG="$TMP/log"
mkdir -p "$HOME" "$FIX" "$LOG" "$TMP/bin"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
# shellcheck source=lib/review.sh
source "$ROOT/lib/review.sh"

# Two truly dependent branches, published only as heads (not GitHub pull refs).
export REMOTE="$TMP/remote.git"
git init -q --bare -b main "$REMOTE"
git init -q -b main "$TMP/seed"
git -C "$TMP/seed" config user.name test
git -C "$TMP/seed" config user.email test@example.com
printf 'base\n' >"$TMP/seed/file"
git -C "$TMP/seed" add file && git -C "$TMP/seed" commit -qm base
BASE="$(git -C "$TMP/seed" rev-parse HEAD)"
git -C "$TMP/seed" switch -qc one
printf 'one\n' >>"$TMP/seed/file"
git -C "$TMP/seed" commit -qam one
ONE="$(git -C "$TMP/seed" rev-parse HEAD)"
git -C "$TMP/seed" switch -qc two
printf 'two\n' >>"$TMP/seed/file"
git -C "$TMP/seed" commit -qam two
TWO="$(git -C "$TMP/seed" rev-parse HEAD)"
git -C "$TMP/seed" push -q "$TMP/remote.git" main one two
git clone -q "$TMP/remote.git" "$TMP/work"
WORK="$TMP/work"
export WORK
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
cat >"$TMP/bin/origin" <<'SH'
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
cat >"$TMP/bin/gh" <<'SH'
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
printf '#!/usr/bin/env bash\nexit 1\n' >"$TMP/bin/herdr-app"
printf '#!/usr/bin/env bash\necho "gt must not run" >&2; exit 99\n' >"$TMP/bin/gt"
chmod +x "$TMP/bin/"*
export PATH="$TMP/bin:$PATH" HERDR_APP="$TMP/bin/herdr-app"

# The selected PR can be in a different stack than the source's current branch.
cat >"$WORK/.git/gh-stack" <<'JSON'
{"schemaVersion":1,"repository":"github.com/acme/widgets","stacks":[{"trunk":{"branch":"main"},"branches":[{"branch":"one","pullRequest":{"number":1}},{"branch":"two","pullRequest":{"number":2}}]}]}
JSON
jq '.url = "https://github.com/acme/widgets/pull/2"' "$FIX/pr-2.json" >"$FIX/gh-entry.json"
before="$(git -C "$WORK" status --porcelain);$(git -C "$WORK" rev-parse HEAD);$(cksum "$WORK/.git/gh-stack")"
order="$(stack_discover github.com/acme/widgets "$FIX/gh-entry.json" "$WORK" "$TMP/gh-sync" gh)"
[[ "$(jq -r '.via' <<<"$order")" == gh-stack && "$(jq -c .numbers <<<"$order")" == '[1,2]' ]] || fail "gh stack order: $order"
[[ "$before" == "$(git -C "$WORK" status --porcelain);$(git -C "$WORK" rev-parse HEAD);$(cksum "$WORK/.git/gh-stack")" ]] || fail 'gh stack modified source'
printf 'PASS: gh stack selects requested PR and refreshes only a private clone\n'
printf 'advance\n' >>"$TMP/seed/file"
git -C "$TMP/seed" commit -qam advance
git -C "$TMP/seed" push -q "$TMP/remote.git" two
ADVANCED="$(git -C "$TMP/seed" rev-parse HEAD)"
jq --arg sha "$ADVANCED" '.headRefOid = $sha' "$FIX/gh-entry.json" >"$FIX/gh-advanced.json"
stack_discover github.com/acme/widgets "$FIX/gh-advanced.json" "$WORK" "$TMP/gh-sync" gh >/dev/null
[[ -z "$(git -C "$TMP/gh-sync" status --porcelain)" ]] || fail 'repeat gather left private index dirty'
[[ "$(git -C "$TMP/gh-sync" rev-parse HEAD)" == "$ADVANCED" ]] || fail 'stale source hid latest remote head'
[[ "$(git -C "$WORK" rev-parse HEAD)" == "$BASE" ]] || fail 'repeat gather changed source'
printf 'PASS: repeat gh gather fetches missing heads and keeps its private index clean\n'
mv "$WORK/.git/gh-stack" "$TMP/saved-catalog"
export FAKE_STACK_API=found
order="$(stack_discover github.com/acme/widgets "$FIX/gh-entry.json" "$WORK" "$TMP/remote-sync" gh)"
[[ "$(jq -r .via <<<"$order")" == gh-stack ]] || fail 'remote-only native stack missed'
[[ ! -e "$WORK/.git/gh-stack" ]] || fail 'remote discovery wrote source catalog'
cp "$TMP/saved-catalog" "$TMP/remote-sync/.git/gh-stack"
stack_discover github.com/acme/widgets "$FIX/gh-entry.json" "$WORK" "$TMP/remote-sync" gh >/dev/null
FAKE_STACK_API=missing
rc=0
_stack_gh_stack "$WORK" "$FIX/pr-2.json" "$TMP/missing-sync" github.com/acme/widgets >/dev/null || rc=$?
[[ "$rc" == 3 ]] || fail '404 should fall back to GitHub walk'
FAKE_STACK_API=broken
rc=0
_stack_gh_stack "$WORK" "$FIX/pr-2.json" "$TMP/broken-sync" github.com/acme/widgets >/dev/null 2>&1 || rc=$?
[[ "$rc" == 1 ]] || fail 'auth failure should not masquerade as no native stack'
unset FAKE_STACK_API
printf 'PASS: remote-only gh stacks use native checkout; only empty/404 falls back\n'

# Origin is explicit here so the live forge is never contacted by the fixture.
printf '[git]\n"%s" = "origin"\n' "$WORK" >"$BERCAIL_CONFIG"
printf 'origin.cursor.com/acme/widgets\n' >"$WORK/.git/bercail-review-repo"
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
printf 'PASS: Origin review accepts both URL formats and branches, gathers native stack/PR/checks without gh\n'
(cd "$TMP" && "$ROOT/bin/bercail" review-pr https://review.cursor.com/pr/acme/widgets/2 --no-run) >/dev/null
[[ -d "$HOME/Work/widgets/.git" ]] || fail 'Origin fallback did not clone'
[[ ! -s "$LOG/gh" ]] || fail 'Origin fallback called gh'
git -C "$WORK" remote set-url origin https://origin-staging.cursor.com/git/acme/widgets.git
_review_origin_matches "$WORK" acme widgets origin.cursor.com || fail 'Origin environment remote rejected'
git -C "$WORK" remote set-url origin https://origin.cursor.com.evil/acme/widgets.git
_review_origin_matches "$WORK" acme widgets origin.cursor.com && fail 'lookalike Origin host accepted'
printf 'PASS: Origin fallback clone and exact environment-host matching\n'

# Refuse graph ambiguity rather than choosing a partial path.
linear='{"trunk":"main","members":[{"branch":"a","parent":"main","number":1},{"branch":"b","parent":"main","number":2}]}'
rc=0
_stack_native_order "$linear" >/dev/null || rc=$?
[[ "$rc" == 2 ]] || fail 'native fork must signal ambiguity'
cycle='{"trunk":"main","members":[{"branch":"a","parent":"b","number":1},{"branch":"b","parent":"a","number":2}]}'
_stack_native_order "$cycle" >/dev/null 2>&1 && fail 'native cycle accepted'
trunk_cycle='{"trunk":"main","members":[{"branch":"a","parent":"main","number":1},{"branch":"main","parent":"a","number":2}]}'
_stack_native_order "$trunk_cycle" >/dev/null 2>&1 && fail 'cycle through trunk accepted'
duplicate='{"trunk":"main","members":[{"branch":"a","parent":"main","number":1},{"branch":"b","parent":"a","number":1}]}'
_stack_native_order "$duplicate" >/dev/null 2>&1 && fail 'duplicate PR accepted'
printf 'PASS: native stack forks, cycles, and duplicate PRs are refused\n'
