#!/usr/bin/env bash
# Snapshot paths, sibling ownership, and object-only fetches. No network.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=lib/review.sh
source "$ROOT/lib/review.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

jq -n '{body: "## Summary\n\nLoom: https://example.test/video\n\nFreeze both counts at the terminal date."}' >"$TMP_DIR/pr.json"
[[ "$(_review_summary "$TMP_DIR/pr.json")" == 'Freeze both counts at the terminal date.' ]] \
  || fail 'summary includes a heading or video link instead of intent'

main="$TMP_DIR/repo"
git init -qb main "$main"
printf 'base\n' >"$main/old.txt"
git -C "$main" add .
git -C "$main" commit -qm base
base="$(git -C "$main" rev-parse HEAD)"
names=('café.txt' $'tab\tname.txt' 'quote"name.txt' 'slash\name.txt' '[part].txt' 'new name.txt')
for name in "${names[@]}"; do printf 'context: %s\n' "$name" >"$main/$name"; done
git -C "$main" mv old.txt renamed.txt
git -C "$main" add .
mkdir -p "$main/libs/dep"
git -C "$main" update-index --add --cacheinfo 160000,1111111111111111111111111111111111111111,libs/dep
git -C "$main" commit -qm paths
head="$(git -C "$main" rev-parse HEAD)"
_review_snapshot "$main" "$head" "$base" "$TMP_DIR/source"
for name in "${names[@]}" renamed.txt; do
  cmp "$main/$name" "$TMP_DIR/source/$name" || fail "snapshot changed path $name"
done
[[ ! -e "$TMP_DIR/source/libs/dep" ]] || fail 'snapshot tried to copy a submodule'
printf 'PASS: snapshots preserve special filenames and renames, and skip submodule pointers\n'

git clone -q --bare "$main" "$TMP_DIR/legacy.git"
git --git-dir="$TMP_DIR/legacy.git" worktree add -q --detach "$TMP_DIR/legacy-review" "$base"
if _review_main_of "$TMP_DIR/legacy-review"; then
  fail 'treated a legacy private bare review clone as the main checkout'
fi
[[ "$(_review_main_of "$main")" == "$main" ]] || fail 'did not resolve the normal main checkout'

R_STACK="$TMP_DIR/stack-5"
mkdir -p "$R_STACK"
sibling="$main.review-5"
git -C "$main" worktree add -qb user-work "$sibling" "$base"
printf 'user edit\n' >>"$sibling/old.txt"
git -C "$sibling" add .
before="$(git -C "$sibling" status --porcelain)"
if (_review_ensure_worktree "$main" "$sibling" "$head") >"$TMP_DIR/refused" 2>&1; then
  fail 'reused an unmarked user worktree'
fi
[[ "$(git -C "$sibling" branch --show-current)" == user-work ]] || fail 'detached the user branch'
[[ "$(git -C "$sibling" rev-parse HEAD)" == "$base" ]] || fail 'moved the user head'
[[ "$(git -C "$sibling" status --porcelain)" == "$before" ]] || fail 'changed staged user edits'

owned="$main.review-6"
_review_ensure_worktree "$main" "$owned" "$base"
_review_write_marker "$owned" "$R_STACK"
_review_ensure_worktree "$main" "$owned" "$head"
printf 'user edit\n' >>"$owned/renamed.txt"
if (_review_ensure_worktree "$main" "$owned" "$base") >"$TMP_DIR/refused-dirty" 2>&1; then
  fail 'moved a dirty review worktree'
fi
[[ "$(git -C "$owned" rev-parse HEAD)" == "$head" ]] || fail 'moved the dirty review head'
git -C "$owned" switch -qc user-review
if (_review_ensure_worktree "$main" "$owned" "$base") >"$TMP_DIR/refused-attached" 2>&1; then
  fail 'detached a user branch in the review worktree'
fi
[[ "$(git -C "$owned" branch --show-current)" == user-review ]] || fail 'detached the review user branch'
printf 'PASS: existing user siblings, dirty review worktrees and attached branches stay untouched\n'

clone="$TMP_DIR/fetch"
git clone -q --no-local "$main" "$clone"
git -C "$clone" for-each-ref >"$TMP_DIR/refs-before"
cp "$clone/.git/config" "$TMP_DIR/config-before"
printf 'existing fetch state\n' >"$clone/.git/FETCH_HEAD"
for version in one two; do
  printf '%s\n' "$version" >>"$main/renamed.txt"
  git -C "$main" commit -qam "$version"
  sha="$(git -C "$main" rev-parse HEAD)"
  git -C "$main" update-ref refs/pull/99/head "$sha"
  _review_fetch_objects "$clone" main "$base" 99 "$sha"
  git -C "$clone" cat-file -e "$sha^{commit}" || fail 'missing fetched commit'
done
git -C "$clone" for-each-ref >"$TMP_DIR/refs-after"
cmp "$TMP_DIR/refs-before" "$TMP_DIR/refs-after" || fail 'object fetch changed refs'
cmp "$TMP_DIR/config-before" "$clone/.git/config" || fail 'object fetch changed config'
[[ "$(cat "$clone/.git/FETCH_HEAD")" == 'existing fetch state' ]] || fail 'object fetch changed FETCH_HEAD'
printf 'PASS: repeated pull-head fetches add objects without changing refs, config or FETCH_HEAD\n'
