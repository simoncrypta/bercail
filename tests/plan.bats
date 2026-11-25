#!/usr/bin/env bats
# tests/plan.sh: what CI's shards run, and what a branch's change needs.

setup() {
  load test_helper
  isolate
  need git
  # A tree of its own: the planner, a weights table, and .bats files to deal.
  tree="$BATS_TEST_TMPDIR/tree"
  mkdir -p "$tree/tests" "$tree/docs" "$tree/lib"
  cp "$ROOT/tests/plan.sh" "$tree/tests/"
  local f
  for f in a b c d e layout_config desk_mod review_pr spaces_mod suite; do
    : >"$tree/tests/$f.bats"
  done
  printf '# seconds\ntests/a.bats\t100\ntests/b.bats\t60\ntests/c.bats\t50\ntests/d.bats\t10\n' >"$tree/tests/weights.tsv"
  printf 'x\n' >"$tree/docs/guide.md"
  printf 'x\n' >"$tree/docs/config.md"
  printf 'x\n' >"$tree/lib/land.sh"
  git_init "$tree"
  git -C "$tree" add -A
  git -C "$tree" commit -qm tree
  git -C "$tree" branch -q base
}

plan() {
  bash "$tree/tests/plan.sh" "$@"
}

@test "the shards of the real suite are disjoint, and together are every .bats file" {
  local n i
  for n in 1 3 8; do
    for ((i = 1; i <= n; i++)); do
      bash "$ROOT/tests/plan.sh" --shard "$i/$n"
    done | sort >"$BATS_TEST_TMPDIR/dealt"
    (cd "$ROOT" && printf '%s\n' tests/*.bats) | diff - "$BATS_TEST_TMPDIR/dealt" || fail "$n shards do not deal each file once"
  done
}

@test "a shard takes the longest file left while it has the least, and a file the table lacks counts as its mean" {
  # Longest first: a 100, b 60, the six the table lacks at their mean 55 each
  # by name, c 50, d 10. Shard 1 gets a, e, review_pr, suite, then d, at 265
  # against 275. Each lists its files in the order it took them.
  [[ "$(plan --shard 1/2 | paste -sd ' ')" == "tests/a.bats tests/e.bats tests/review_pr.bats tests/suite.bats tests/d.bats" ]] \
    || fail "shard 1: $(plan --shard 1/2 | paste -sd ' ')"
  [[ "$(plan --shard 2/2 | paste -sd ' ')" == "tests/b.bats tests/desk_mod.bats tests/layout_config.bats tests/spaces_mod.bats tests/c.bats" ]] \
    || fail "shard 2: $(plan --shard 2/2 | paste -sd ' ')"
  rm "$tree/tests/weights.tsv"
  [[ "$( (plan --shard 1/2; plan --shard 2/2) | wc -l)" == 10 ]] || fail "without a table the files were not all dealt"
}

@test "vitest is in no shard, and --vitest lists only it" {
  if plan --shard 1/1 | grep -qx vitest; then fail "a shard took vitest"; fi
  [[ "$(plan --vitest)" == vitest ]] || fail "--vitest: $(plan --vitest)"
  plan | grep -qx vitest || fail "the whole suite has no vitest"
}

@test "a shard out of range, or a shard with --vitest, is refused" {
  local bad
  for bad in 0/8 9/8 1 a/b; do
    run plan --shard "$bad"
    [[ "$status" -eq 2 && "$output" == *"--shard takes I/N"* ]] || fail "$bad: $status $output"
  done
  run plan --shard 1/2 --vitest
  [[ "$status" -eq 2 ]] || fail "--shard with --vitest: $status $output"
}

@test "a docs change runs its readers and the smoke file; a doc no test reads runs only the smoke file" {
  printf 'more\n' >>"$tree/docs/config.md"
  printf 'more\n' >>"$tree/docs/guide.md"
  [[ "$(plan --affected base | paste -sd ' ')" == "tests/desk_mod.bats tests/layout_config.bats tests/suite.bats" ]] \
    || fail "docs: $(plan --affected base | paste -sd ' ')"
  git -C "$tree" checkout -q -- docs/config.md
  [[ "$(plan --affected base)" == tests/suite.bats ]] || fail "guide only: $(plan --affected base)"
}

@test "a change to code, a test, or a new file anywhere but docs runs everything" {
  local path
  for path in lib/land.sh tests/a.bats tests/new.bats; do
    git -C "$tree" checkout -q -- .
    rm -f "$tree/tests/new.bats"
    printf 'more\n' >>"$tree/$path"
    [[ "$(plan --affected base)" == "$(plan)" ]] || fail "$path: $(plan --affected base | paste -sd ' ')"
  done
}

@test "a committed change counts, and so do both sides of a rename" {
  git -C "$tree" mv lib/land.sh docs/land.md
  git -C "$tree" commit -qm moved
  [[ "$(plan --affected base)" == "$(plan)" ]] || fail "a rename out of lib: $(plan --affected base | paste -sd ' ')"
  git -C "$tree" reset -q --hard base
  printf 'more\n' >>"$tree/docs/guide.md"
  git -C "$tree" commit -qam guide
  [[ "$(plan --affected base)" == tests/suite.bats ]] || fail "a committed doc: $(plan --affected base)"
}

@test "with no merge base, the plan is everything and says why" {
  run plan --affected no-such-ref
  [[ "$status" -eq 0 ]] || fail "status $status: $output"
  [[ "$output" == "tests/plan.sh: no merge base with no-such-ref; running everything"$'\n'"$(plan)" ]] || fail "$output"
}

@test "a shard of a branch's plan deals only what the change needs" {
  printf 'more\n' >>"$tree/docs/config.md"
  [[ "$( (plan --affected base --shard 1/2; plan --affected base --shard 2/2) | sort | paste -sd ' ')" \
    == "tests/desk_mod.bats tests/layout_config.bats tests/suite.bats" ]] || fail "$(plan --affected base --shard 1/2)"
  [[ -z "$(plan --affected base --vitest)" ]] || fail "a docs change ran vitest"
}

@test "a git that cannot list the change runs everything and says why" {
  printf 'more\n' >>"$tree/docs/guide.md"
  printf 'broken\n' >"$BATS_TEST_TMPDIR/index"
  GIT_INDEX_FILE="$BATS_TEST_TMPDIR/index" run plan --affected base
  [[ "$status" -eq 0 ]] || fail "status $status: $output"
  [[ "$output" == *"tests/plan.sh: git could not list the change since base; running everything"*$'\n'"$(plan)" ]] || fail "$output"
}
