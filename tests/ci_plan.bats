#!/usr/bin/env bats
# .github/scripts/test-plan.sh: what each CI job runs for the event that
# started it. A stand-in tests/plan.sh, so the readers map can change freely.

setup() {
  load test_helper
  isolate
  tree="$BATS_TEST_TMPDIR/tree"
  mkdir -p "$tree/.github/scripts" "$tree/tests"
  cp "$ROOT/.github/scripts/test-plan.sh" "$tree/.github/scripts/"
  # The whole suite is a, b and vitest; --affected prints the file `affected`.
  cat >"$tree/tests/plan.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$BATS_TEST_TMPDIR/plan.log"
case "${1:-}" in
  '') printf '%s\n' tests/a.bats tests/b.bats vitest ;;
  --affected) cat "$BATS_TEST_TMPDIR/affected" ;;
  --vitest) printf 'vitest\n' ;;
  --shard) printf 'tests/b.bats\n' ;;
esac
EOF
  printf 'tests/a.bats\n' >"$BATS_TEST_TMPDIR/affected"
  export BD_VERSION=1.2.3 GITHUB_OUTPUT="$BATS_TEST_TMPDIR/output"
  : >"$GITHUB_OUTPUT"
}

# Runs the adapter for EVENT and REF with the options after them.
adapt() {
  GITHUB_EVENT_NAME="$1" GITHUB_REF="$2" GITHUB_BASE_REF="${BASE_REF:-}" run bash "$tree/.github/scripts/test-plan.sh" "${@:3}"
}

@test "a branch whose change needs part of the suite runs it in check, and spawns no shard" {
  adapt push refs/heads/feature --check
  [[ "$status" -eq 0 ]] || fail "status $status: $output"
  [[ "$(cat "$GITHUB_OUTPUT")" == $'args=--affected origin/master\nrun=1\nbats=1' ]] || fail "$(cat "$GITHUB_OUTPUT")"
}

@test "only suites using real beads or tla-ts request their setup" {
  printf '%s\n' tests/handoff_beads.bats tests/statechart.bats >"$BATS_TEST_TMPDIR/affected"
  adapt push refs/heads/feature --check
  [[ "$status" == 0 ]]
  grep -Fxq 'tools=github:gastownhall/beads@1.2.3' "$GITHUB_OUTPUT"
  grep -Fxq 'statechart=1' "$GITHUB_OUTPUT"
}

@test "a PR plans against its base branch" {
  BASE_REF=release adapt pull_request refs/pull/7/merge --check
  [[ "$(cat "$GITHUB_OUTPUT")" == $'args=--affected origin/release\nrun=1\nbats=1' ]] || fail "$(cat "$GITHUB_OUTPUT")"
}

@test "a branch whose change needs everything runs vitest in check and the bats in the shards" {
  printf '%s\n' tests/a.bats tests/b.bats vitest >"$BATS_TEST_TMPDIR/affected"
  adapt push refs/heads/feature --check
  [[ "$status" -eq 0 ]] || fail "status $status: $output"
  [[ "$(cat "$GITHUB_OUTPUT")" == $'args=--vitest\nrun=1\nfull=1' ]] || fail "$(cat "$GITHUB_OUTPUT")"
  [[ "$output" == *"the shards run the .bats files"* ]] || fail "$output"
}

@test "a land candidate, master, a tag, the nightly and a manual run test everything, whatever the change" {
  local event
  for event in push:refs/heads/bercail-land/login/0123456789ab push:refs/heads/master push:refs/tags/v1.2.3 schedule:refs/heads/master workflow_dispatch:refs/heads/feature; do
    : >"$GITHUB_OUTPUT"
    : >"$BATS_TEST_TMPDIR/plan.log"
    adapt "${event%%:*}" "${event#*:}" --check
    [[ "$(cat "$GITHUB_OUTPUT")" == $'args=--vitest\nrun=1\nfull=1' ]] || fail "$event: $(cat "$GITHUB_OUTPUT")"
    if grep -q -- --affected "$BATS_TEST_TMPDIR/plan.log"; then fail "$event planned against a base"; fi
  done
}

@test "a shard runs its part of the whole suite, never only a branch's change" {
  adapt push refs/heads/feature --shard 2/4
  [[ "$status" -eq 0 ]] || fail "status $status: $output"
  [[ "$(cat "$GITHUB_OUTPUT")" == $'args=--shard 2/4\nrun=1\nbats=1' ]] || fail "$(cat "$GITHUB_OUTPUT")"
  [[ "$(cat "$BATS_TEST_TMPDIR/plan.log")" == "--shard 2/4" ]] || fail "$(cat "$BATS_TEST_TMPDIR/plan.log")"
}

@test "a plan that fails fails the step and writes no outputs" {
  sed -i '2i exit 3' "$tree/tests/plan.sh"
  adapt push refs/heads/feature --check
  [[ "$status" -ne 0 ]] || fail "a failed plan passed: $output"
  [[ ! -s "$GITHUB_OUTPUT" ]] || fail "outputs: $(cat "$GITHUB_OUTPUT")"
}
