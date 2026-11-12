#!/usr/bin/env bats
# Snapshot paths, sibling ownership, and object-only fetches. No network.

setup() {
  load test_helper
  isolate
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
  # shellcheck source=/dev/null
  source "$ROOT/lib/common.sh"
  # shellcheck source=/dev/null
  source "$ROOT/lib/review.sh"

  main="$BATS_TEST_TMPDIR/repo"
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
}

# A marked review worktree at the head, with a user edit in it.
dirty_review_worktree() {
  R_STACK="$BATS_TEST_TMPDIR/stack-5"
  mkdir -p "$R_STACK"
  owned="$main.review-6"
  _review_ensure_worktree "$main" "$owned" "$base"
  _review_write_marker "$owned" "$R_STACK"
  _review_ensure_worktree "$main" "$owned" "$head"
  printf 'user edit\n' >>"$owned/renamed.txt"
}

@test "snapshots preserve special filenames and renames, and skip submodule pointers" {
  _review_snapshot "$main" "$head" "$base" "$BATS_TEST_TMPDIR/source"
  for name in "${names[@]}" renamed.txt; do
    cmp "$main/$name" "$BATS_TEST_TMPDIR/source/$name" || fail "snapshot changed path $name"
  done
  [[ ! -e "$BATS_TEST_TMPDIR/source/libs/dep" ]] || fail 'snapshot tried to copy a submodule'
}

@test "a legacy private bare review clone is not taken for the main checkout" {
  git clone -q --bare "$main" "$BATS_TEST_TMPDIR/legacy.git"
  git --git-dir="$BATS_TEST_TMPDIR/legacy.git" worktree add -q --detach "$BATS_TEST_TMPDIR/legacy-review" "$base"
  if _review_main_of "$BATS_TEST_TMPDIR/legacy-review"; then
    fail 'treated a legacy private bare review clone as the main checkout'
  fi
  [[ "$(_review_main_of "$main")" == "$main" ]] || fail 'did not resolve the normal main checkout'
}

@test "an existing unmarked user sibling stays untouched" {
  local sibling before
  R_STACK="$BATS_TEST_TMPDIR/stack-5"
  mkdir -p "$R_STACK"
  sibling="$main.review-5"
  git -C "$main" worktree add -qb user-work "$sibling" "$base"
  printf 'user edit\n' >>"$sibling/old.txt"
  git -C "$sibling" add .
  before="$(git -C "$sibling" status --porcelain)"
  if (_review_ensure_worktree "$main" "$sibling" "$head") >"$BATS_TEST_TMPDIR/refused" 2>&1; then
    fail 'reused an unmarked user worktree'
  fi
  [[ "$(git -C "$sibling" branch --show-current)" == user-work ]] || fail 'detached the user branch'
  [[ "$(git -C "$sibling" rev-parse HEAD)" == "$base" ]] || fail 'moved the user head'
  [[ "$(git -C "$sibling" status --porcelain)" == "$before" ]] || fail 'changed staged user edits'
}

@test "a dirty review worktree stays untouched" {
  dirty_review_worktree
  if (_review_ensure_worktree "$main" "$owned" "$base") >"$BATS_TEST_TMPDIR/refused-dirty" 2>&1; then
    fail 'moved a dirty review worktree'
  fi
  [[ "$(git -C "$owned" rev-parse HEAD)" == "$head" ]] || fail 'moved the dirty review head'
}

@test "a user branch attached in the review worktree stays untouched" {
  dirty_review_worktree
  git -C "$owned" switch -qc user-review
  if (_review_ensure_worktree "$main" "$owned" "$base") >"$BATS_TEST_TMPDIR/refused-attached" 2>&1; then
    fail 'detached a user branch in the review worktree'
  fi
  [[ "$(git -C "$owned" branch --show-current)" == user-review ]] || fail 'detached the review user branch'
}

@test "repeated pull-head fetches add objects without changing refs, config or FETCH_HEAD" {
  local clone="$BATS_TEST_TMPDIR/fetch" version sha
  git clone -q --no-local "$main" "$clone"
  git -C "$clone" for-each-ref >"$BATS_TEST_TMPDIR/refs-before"
  cp "$clone/.git/config" "$BATS_TEST_TMPDIR/config-before"
  printf 'existing fetch state\n' >"$clone/.git/FETCH_HEAD"
  for version in one two; do
    printf '%s\n' "$version" >>"$main/renamed.txt"
    git -C "$main" commit -qam "$version"
    sha="$(git -C "$main" rev-parse HEAD)"
    git -C "$main" update-ref refs/pull/99/head "$sha"
    _review_fetch_objects "$clone" main "$base" 99 "$sha"
    git -C "$clone" cat-file -e "$sha^{commit}" || fail 'missing fetched commit'
  done
  git -C "$clone" for-each-ref >"$BATS_TEST_TMPDIR/refs-after"
  cmp "$BATS_TEST_TMPDIR/refs-before" "$BATS_TEST_TMPDIR/refs-after" || fail 'object fetch changed refs'
  cmp "$BATS_TEST_TMPDIR/config-before" "$clone/.git/config" || fail 'object fetch changed config'
  [[ "$(cat "$clone/.git/FETCH_HEAD")" == 'existing fetch state' ]] || fail 'object fetch changed FETCH_HEAD'
}
