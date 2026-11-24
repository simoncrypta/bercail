#!/usr/bin/env bats
# policy init only prepares files in an explicitly named checkout, never trust.

setup() {
  load test_helper
  isolate
  set -o pipefail
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig" GIT_CONFIG_NOSYSTEM=1
  local variable
  for variable in $(compgen -v | grep -E '^(HC|HERDR|BERCAIL|BEADS|BD|HANDOFF)_|^BASH_ENV$'); do unset "$variable"; done
  git config --global user.name test
  git config --global user.email test@example.com
  git config --global init.defaultBranch main
  CONFIG="$XDG_CONFIG_HOME/bercail/config.toml"
  TRUST="$XDG_STATE_HOME/bercail/policy-trust.json"
  mkdir -p "$(dirname "$CONFIG")" "$(dirname "$TRUST")"
  printf '# owner config\n' >"$CONFIG"
  printf '{}\n' >"$TRUST"
  export TOOL_CALLS="$BATS_TEST_TMPDIR/tool-calls"
  local tool
  for tool in hc gh gt origin entire pi bd curl op; do
    printf '#!/bin/sh\nprintf "%%s %%s\\n" "%s" "$*" >>"$TOOL_CALLS"\nexit 91\n' "$tool" >"$BATS_TEST_TMPDIR/bin/$tool"
    chmod +x "$BATS_TEST_TMPDIR/bin/$tool"
  done
  REPO="$BATS_TEST_TMPDIR/repo with spaces"
  git init -q "$REPO"
  git -C "$REPO" remote add origin https://example.com/repo.git
  printf 'baseline\n' >"$REPO/file.txt"
  git -C "$REPO" add file.txt
  git -C "$REPO" commit -q -m init
}

policy() { "$ROOT/bin/bercail" policy "$@"; }
init_guarded() { policy init --repo "$REPO" --profile guarded --backend gh "$@"; }
init_entire() { policy init --repo "$REPO" --profile branch-trail --backend entire "$@"; }
entire_remote() {
  git -C "$REPO" remote set-url origin entire://example.com/et/sample-project/sample-repo
  mkdir -p "$REPO/.entire"
  printf '{"enabled":true}\n' >"$REPO/.entire/settings.json"
}

@test "init previews explicit guarded policy without writing any destination or owner state" {
  local before
  before="$(sha256sum "$CONFIG" "$TRUST" "$REPO/.git/index")"
  run policy init --repo "$REPO" --profile guarded --backend gh --verify sample
  [[ "$status" -eq 0 ]] || fail "explicit preview failed: $output"
  [[ "$output" == *"$REPO/.bercail/policy.toml"* && "$output" == *"$REPO/.agents/skills/verify-sample/SKILL.md"* ]] || fail "preview omits destinations: $output"
  [[ "$output" == *'push = "ask"'* && "$output" != *'commit ='* && "$output" == *'review = "always"'* && "$output" == *'INCOMPLETE'* ]] || fail "preview omits safe contents: $output"
  [[ ! -e "$REPO/.bercail" && ! -e "$REPO/.agents" ]] || fail "preview created directories"
  [[ "$(sha256sum "$CONFIG" "$TRUST" "$REPO/.git/index")" == "$before" && ! -e "$TOOL_CALLS" ]] || fail "preview touched owner state, index or invoked a live tool"
}

@test "init refuses bootstrap without explicit repo profile and backend" {
  local args
  for args in repo profile backend; do
    case "$args" in
      repo) run policy init --profile guarded --backend gh ;;
      profile) run policy init --repo "$REPO" --backend gh ;;
      backend) run policy init --repo "$REPO" --profile guarded ;;
    esac
    [[ "$status" -ne 0 && "$output" == *'requires explicit'* ]] || fail "missing $args accepted: $output"
  done
  run policy init
  [[ "$status" -ne 0 && "$output" == *'requires explicit'* ]] || fail "empty init accepted: $output"
  [[ ! -e "$REPO/.bercail" && ! -e "$REPO/.agents" ]] || fail "refusal wrote files"
}

@test "init refuses unknown options profiles backends and duplicate values" {
  local option
  for option in --trusted --yes --verified --apply --force --output; do
    run init_guarded "$option"
    [[ "$status" -ne 0 && "$output" == *"unknown option: $option"* ]] || fail "unsupported shortcut accepted: $output"
  done
  run init_guarded --profile branch-pr
  [[ "$status" -ne 0 && "$output" == *'duplicate option: --profile'* ]] || fail "duplicate accepted: $output"
  run policy init --repo "$REPO" --profile permissive --backend gh --write
  [[ "$status" -ne 0 && "$output" == *'unknown profile: permissive'* ]] || fail "profile accepted: $output"
  run policy init --repo "$REPO" --profile guarded --backend unknown --write
  [[ "$status" -ne 0 && "$output" == *'unsupported backend: unknown'* ]] || fail "backend accepted: $output"
  run init_guarded --verify
  [[ "$status" -ne 0 && "$output" == *'requires a value'* ]] || fail "missing value accepted: $output"
  [[ ! -e "$REPO/.bercail" ]] || fail "invalid arguments wrote files"
}

@test "init write prepares guarded policy but no evidence trust or executable starter" {
  local before file out
  before="$(sha256sum "$CONFIG" "$TRUST")"
  run init_guarded --verify sample --write
  [[ "$status" -eq 0 ]] || fail "write failed: $output"
  file="$REPO/.bercail/policy.toml"
  [[ "$output" == *"sha256: $(sha256sum "$file" | cut -d' ' -f1)"* ]] || fail "hash differs: $output"
  [[ "$output" == *'Init never creates or changes trust'* && "$output" == *'Existing matching trust and local overrides may already apply'* ]] || fail "trust caveat missing: $output"
  [[ "$output" == *'bercail policy trust '* && "$output" == *'other branches/desks are unchanged'* ]] || fail "separate adoption/trust missing: $output"
  out="$(policy show --json "$REPO")"
  jq -e '.trusted == false and .policy.push == "ask" and .policy.review == "always" and .policy.agent_may_release == false and .policy.integrate == ""' <<<"$out" >/dev/null || fail "unsafe policy: $out"
  [[ "$(find "$REPO/.agents" -type f | wc -l)" -eq 1 && -f "$REPO/.agents/skills/verify-sample/SKILL.md" ]] || fail "unexpected starter files"
  [[ ! -e "$REPO/.bercail/description.md" && ! -e "$REPO/.bercail/verify" ]] || fail "fabricated validation evidence"
  [[ "$(sha256sum "$CONFIG" "$TRUST")" == "$before" && ! -e "$TOOL_CALLS" ]] || fail "write touched owner state or invoked a live tool"
}

@test "branch-pr requires explicit choice and does not activate its looser values without trust" {
  local out
  run policy init --repo "$REPO" --profile branch-pr --backend gh --write
  [[ "$status" -eq 0 ]] || fail "branch-pr failed: $output"
  if grep -q '^commit' "$REPO/.bercail/policy.toml"; then fail "branch-pr wrote the old commit key"; fi
  grep -qx 'push = "branch"' "$REPO/.bercail/policy.toml" || fail "branch-pr did not request branch"
  out="$(policy show --json "$REPO")"
  jq -e '.trusted == false and .policy.push == "ask" and .policy.review == "always" and .policy.agent_may_release == false and .policy.integrate == "pr" and .policy.pr_draft == true' <<<"$out" >/dev/null || fail "branch-pr self-trusted: $out"
  [[ ! -e "$TOOL_CALLS" ]] || fail "branch-pr invoked external setup"
}

@test "existing owner trust permits branch publication but creates no validation or human approval" {
  local hash before out
  policy init --repo "$REPO" --profile branch-pr --backend gh --verify sample --write >/dev/null
  hash="$(sha256sum "$REPO/.bercail/policy.toml" | cut -d' ' -f1)"
  jq -n --arg repo "$REPO" --arg hash "$hash" '{($repo): {sha256: $hash}}' >"$TRUST"
  before="$(sha256sum "$TRUST" "$CONFIG")"
  run policy init --repo "$REPO" --profile branch-pr --backend gh --verify sample --write
  [[ "$status" -eq 0 && "$output" == *'Existing matching trust and local overrides may already apply'* ]] || fail "matching trust caveat missing: $output"
  out="$(policy show --json "$REPO")"
  jq -e '.trusted == true and .policy.push == "branch" and .policy.review == "always" and .policy.agent_may_release == false' <<<"$out" >/dev/null || fail "independent gates collapsed: $out"
  [[ "$(sha256sum "$TRUST" "$CONFIG")" == "$before" && ! -e "$TOOL_CALLS" ]] || fail "existing owner state changed"
  [[ "$(find "$REPO/.bercail" -type f | wc -l)" -eq 1 ]] || fail "fabricated evidence or approval"
  grep -q 'INCOMPLETE' "$REPO/.agents/skills/verify-sample/SKILL.md" || fail "trust completed verification"
}

@test "existing local owner overrides remain effective and unchanged" {
  local before out
  printf '[policy."%s"]\npush = "branch"\n' "$REPO" >"$CONFIG"
  before="$(sha256sum "$TRUST" "$CONFIG")"
  run init_guarded --write
  [[ "$status" -eq 0 && "$output" == *'Existing matching trust and local overrides may already apply'* ]] || fail "local override caveat missing: $output"
  out="$(policy show --json "$REPO")"
  jq -e '.trusted == false and .policy.push == "branch" and .sources.push == "local" and .policy.review == "always"' <<<"$out" >/dev/null || fail "local override lost: $out"
  [[ "$(sha256sum "$TRUST" "$CONFIG")" == "$before" ]] || fail "local override changed"
}

@test "identical repeated writes preserve inode mtime bytes and matching trust" {
  local file stamp before hash out
  init_guarded --verify sample --write >/dev/null
  file="$REPO/.bercail/policy.toml"
  touch -t 200001010000 "$file" "$REPO/.agents/skills/verify-sample/SKILL.md"
  stamp="$(stat -c '%i %Y' "$file" "$REPO/.agents/skills/verify-sample/SKILL.md")"
  hash="$(sha256sum "$file" | cut -d' ' -f1)"
  jq -n --arg repo "$REPO" --arg hash "$hash" '{($repo): {sha256: $hash}}' >"$TRUST"
  before="$(sha256sum "$CONFIG" "$TRUST" "$file" "$REPO/.agents/skills/verify-sample/SKILL.md")"
  run init_guarded --verify sample --write
  [[ "$status" -eq 0 && "$output" == *'Identical: no change.'* && "$output" == *'push = "ask"'* && "$output" == *'INCOMPLETE'* ]] || fail "repeat omits contents or failed: $output"
  [[ "$(stat -c '%i %Y' "$file" "$REPO/.agents/skills/verify-sample/SKILL.md")" == "$stamp" ]] || fail "repeat replaced or touched files"
  [[ "$(sha256sum "$CONFIG" "$TRUST" "$file" "$REPO/.agents/skills/verify-sample/SKILL.md")" == "$before" ]] || fail "repeat changed bytes"
  out="$(policy show --json "$REPO")"
  jq -e '.trusted == true' <<<"$out" >/dev/null || fail "identical hash lost trust: $out"
}

@test "existing different policy including unknown schema is preserved without merging" {
  local text before
  mkdir -p "$REPO/.bercail"
  for text in 'commit = "allow"' 'schema = 99' '[future.policy]'; do
    printf '%s\n' "$text" >"$REPO/.bercail/policy.toml"
    before="$(sha256sum "$REPO/.bercail/policy.toml")"
    run init_guarded --verify sample --write
    [[ "$status" -ne 0 && "$output" == *'conflict:'* ]] || fail "conflicting file accepted: $output"
    [[ "$(sha256sum "$REPO/.bercail/policy.toml")" == "$before" && ! -e "$REPO/.agents" ]] || fail "conflict changed destinations"
  done
}

@test "all destinations preflight before any directory or policy write" {
  mkdir -p "$REPO/.agents/skills/verify-sample"
  printf 'existing skill\n' >"$REPO/.agents/skills/verify-sample/SKILL.md"
  run init_guarded --verify sample --write
  [[ "$status" -ne 0 && "$output" == *'conflict:'* ]] || fail "skill conflict accepted: $output"
  [[ ! -e "$REPO/.bercail" ]] || fail "policy was created before skill preflight"
  [[ "$(<"$REPO/.agents/skills/verify-sample/SKILL.md")" == 'existing skill' ]] || fail "existing skill changed"
}

@test "init refuses symlink components and dangling target without changing outside files" {
  local outside before
  outside="$BATS_TEST_TMPDIR/outside"
  mkdir -p "$outside"
  printf 'outside\n' >"$outside/policy.toml"
  before="$(sha256sum "$outside/policy.toml")"
  ln -s "$outside" "$REPO/.bercail"
  run init_guarded --write
  [[ "$status" -ne 0 && "$output" == *'symlink component'* ]] || fail "symlink directory accepted: $output"
  [[ "$(sha256sum "$outside/policy.toml")" == "$before" ]] || fail "outside bytes changed"
  rm "$REPO/.bercail"
  mkdir -p "$REPO/.bercail"
  ln -s "$outside/missing" "$REPO/.bercail/policy.toml"
  run init_guarded --write
  [[ "$status" -ne 0 && "$output" == *'symlink component'* && ! -e "$outside/missing" ]] || fail "dangling symlink accepted: $output"
}

@test "init refuses symlinked skill ancestors before creating policy" {
  local component
  mkdir -p "$BATS_TEST_TMPDIR/outside"
  for component in .agents .agents/skills .agents/skills/verify-sample; do
    mkdir -p "$(dirname "$REPO/$component")"
    ln -s "$BATS_TEST_TMPDIR/outside" "$REPO/$component"
    run init_guarded --verify sample --write
    [[ "$status" -ne 0 && "$output" == *'symlink component'* ]] || fail "symlink $component accepted: $output"
    [[ ! -e "$REPO/.bercail" && ! -e "$BATS_TEST_TMPDIR/outside/SKILL.md" ]] || fail "symlink preflight wrote files"
    rm "$REPO/$component"
  done
}

@test "init refuses symlink repo inputs and non-checkouts" {
  ln -s "$REPO" "$BATS_TEST_TMPDIR/repo-link"
  run policy init --repo "$BATS_TEST_TMPDIR/repo-link" --profile guarded --backend gh --write
  [[ "$status" -ne 0 && "$output" == *'symlink component'* ]] || fail "symlink repo accepted: $output"
  run policy init --repo "$BATS_TEST_TMPDIR" --profile guarded --backend gh --write
  [[ "$status" -ne 0 && "$output" == *'not a git checkout'* ]] || fail "non-checkout accepted: $output"
}

@test "init refuses hardlinked targets even if identical" {
  init_guarded --write >/dev/null
  ln "$REPO/.bercail/policy.toml" "$BATS_TEST_TMPDIR/hardlink"
  run init_guarded --write
  [[ "$status" -ne 0 && "$output" == *'hardlinked target'* ]] || fail "hardlink accepted: $output"
  [[ -f "$BATS_TEST_TMPDIR/hardlink" ]] || fail "hardlink changed"
}

@test "init refuses non-regular targets and non-directory components" {
  mkdir -p "$REPO/.bercail/policy.toml"
  run init_guarded --write
  [[ "$status" -ne 0 && "$output" == *'not a regular file'* ]] || fail "directory target accepted: $output"
  rmdir "$REPO/.bercail/policy.toml" "$REPO/.bercail"
  printf 'not a directory\n' >"$REPO/.bercail"
  run init_guarded --write
  [[ "$status" -ne 0 && "$output" == *'not a directory'* ]] || fail "file component accepted: $output"
}

@test "verification names cannot escape fixed destination or violate portable skill names" {
  local name
  for name in '../outside' '/outside' 'a/b' 'Upper' '-x' 'x-' 'x--y' "$(printf '%058d' 0)"; do
    run init_guarded --verify "$name" --write
    [[ "$status" -ne 0 && "$output" == *'invalid verification name'* ]] || fail "name accepted ($name): $output"
    [[ ! -e "$REPO/.bercail" && ! -e "$REPO/.agents" ]] || fail "invalid name wrote files"
  done
}

@test "canonical subdirectory and relative inputs target only the current worktree with main trust identity" {
  local wt hash before out
  init_guarded --write >/dev/null
  hash="$(sha256sum "$REPO/.bercail/policy.toml" | cut -d' ' -f1)"
  jq -n --arg repo "$REPO" --arg hash "$hash" '{($repo): {sha256: $hash}}' >"$TRUST"
  before="$(sha256sum "$REPO/.bercail/policy.toml" "$TRUST" "$CONFIG")"
  wt="$BATS_TEST_TMPDIR/worktree - feature"
  git -C "$REPO" worktree add -q -b feature "$wt"
  mkdir -p "$wt/subdir"
  cd "$wt/subdir"
  run policy init --repo . --profile branch-pr --backend gh --verify sample --write
  [[ "$status" -eq 0 && "$output" == *"Target: $wt/.bercail/policy.toml"* && "$output" == *"Main identity (not a write target): $REPO"* ]] || fail "worktree resolution failed: $output"
  [[ ! -e "$wt/subdir/.bercail" && "$(sha256sum "$REPO/.bercail/policy.toml" "$TRUST" "$CONFIG")" == "$before" ]] || fail "worktree write touched main or owner state"
  out="$(policy show --json "$wt")"
  jq -e --arg repo "$REPO" '.repo == $repo and .trusted == false and .policy.push == "ask"' <<<"$out" >/dev/null || fail "changed worktree hash trusted: $out"
}

@test "init rejects an explicit non-gh override without changing owner configuration" {
  local before
  printf '[git]\n"%s" = "origin"\n' "$REPO" >"$CONFIG"
  before="$(sha256sum "$CONFIG" "$TRUST")"
  run init_guarded --write
  [[ "$status" -ne 0 && "$output" == *'configured backend is origin'* ]] || fail "override conflict accepted: $output"
  [[ ! -e "$REPO/.bercail" && "$(sha256sum "$CONFIG" "$TRUST")" == "$before" && ! -e "$TOOL_CALLS" ]] || fail "override refusal changed state"
}

@test "offline conflicting backend evidence refuses unless the owner already selected gh" {
  local url
  for url in 'https://origin.cursor.com/org/repo' 'entire://example.com/et/project/repo'; do
    git -C "$REPO" remote set-url origin "$url"
    run init_guarded --write
    [[ "$status" -ne 0 && "$output" == *'offline backend evidence outside gh-only scaffold support'* ]] || fail "offline conflict accepted: $output"
  done
  git -C "$REPO" remote set-url origin https://example.com/repo.git
  printf '{}\n' >"$REPO/.git/.graphite_repo_config"
  run init_guarded --write
  [[ "$status" -ne 0 && "$output" == *'offline backend evidence outside gh-only scaffold support'* ]] || fail "Graphite config accepted: $output"
  printf '[git]\n"%s" = "gh"\n' "$REPO" >"$CONFIG"
  run init_guarded --write
  [[ "$status" -eq 0 && -f "$REPO/.bercail/policy.toml" && ! -e "$TOOL_CALLS" ]] || fail "explicit gh override did not win offline: $output"
}

@test "Entire GitHub mirror preserves the exact gh scaffold bytes without backend probes" {
  local profile push expected
  git -C "$REPO" remote set-url origin entire://example.com/gh/owner/repo
  for profile in guarded branch-pr; do
    if [[ "$profile" == guarded ]]; then push=ask; else push=branch; fi
    expected="$(printf '%s\n' '# Prepared by bercail policy init; review before adopting.' "push = \"$push\""
      if [[ "$profile" == branch-pr ]]; then printf '%s\n' 'integrate = "pr"' 'pr_draft = true'; fi
      printf '%s\n' 'agent_may_release = false' 'review = "always"' 'rules = "Use gh. Permission to publish is not validation evidence or human review."')"
    run policy init --repo "$REPO" --profile "$profile" --backend gh
    [[ "$status" -eq 0 && ! -e "$TOOL_CALLS" ]] || fail "GitHub mirror rejected or probed: $output"
    # Diff lines preserve the full original gh candidate, not just its parsed values.
    [[ "$output" == *"$(printf '%s\n' "$expected" | awk '{print "+" $0}')"* ]] || fail "gh scaffold bytes changed: $output"
  done
}

@test "Entire preview is offline immutable and prescribes project Trail rules without a schema expansion" {
  entire_remote
  local before
  before="$(sha256sum "$CONFIG" "$TRUST" "$REPO/.git/index")"
  run init_entire --verify sample
  [[ "$status" -eq 0 ]] || fail "Entire preview failed: $output"
  [[ "$output" == *'backend: entire'* && "$output" == *"$REPO/.bercail/policy.toml"* && "$output" == *"$REPO/.agents/skills/verify-sample/SKILL.md"* ]] || fail "Entire targets missing: $output"
  [[ "$output" == *'project-level Trail'* && "$output" == *'multiple branches and repositories'* && "$output" == *'true parent/base'* ]] || fail "Trail scope/base missing: $output"
  [[ "$output" == *'only when asked'* && "$output" == *'entire trail update'* && "$output" == *'Stage changes and leave them uncommitted'* ]] || fail "deliberate workflow missing: $output"
  [[ "$output" == *'Only the human or Shep explicitly asked to merge'* && "$output" == *'independent gates'* ]] || fail "merge gates missing: $output"
  [[ "$output" == *'Trail workflow is rules text'* && "$output" != *'integrate ='* && "$output" != *'pr_draft ='* && "$output" != *'Use gh.'* && "$output" != *'gh stack'* ]] || fail "Entire expanded schema or emitted GitHub workflow: $output"
  [[ "$output" == *'INCOMPLETE'* && ! -e "$REPO/.bercail" && ! -e "$REPO/.agents" ]] || fail "preview wrote or completed starter"
  [[ "$(sha256sum "$CONFIG" "$TRUST" "$REPO/.git/index")" == "$before" && ! -e "$TOOL_CALLS" ]] || fail "preview touched authority/index or ran a backend"
}

@test "Entire writes idempotently and leaves trust evidence and human review independent" {
  entire_remote
  local file skill hash stamp before out
  run init_entire --verify sample --write
  [[ "$status" -eq 0 ]] || fail "Entire write failed: $output"
  file="$REPO/.bercail/policy.toml" skill="$REPO/.agents/skills/verify-sample/SKILL.md"
  hash="$(sha256sum "$file" | cut -d' ' -f1)"
  [[ "$output" == *"sha256: $hash"* ]] || fail "Entire hash missing: $output"
  out="$(policy show --json "$REPO")"
  jq -e '.trusted == false and .policy.push == "ask" and .policy.integrate == "" and .policy.review == "always" and .policy.agent_may_release == false' <<<"$out" >/dev/null || fail "Entire self-trusted: $out"
  jq -n --arg repo "$REPO" --arg hash "$hash" '{($repo): {sha256: $hash}}' >"$TRUST"
  touch -t 200001010000 "$file" "$skill"
  stamp="$(stat -c '%i %Y' "$file" "$skill")"
  before="$(sha256sum "$CONFIG" "$TRUST" "$file" "$skill")"
  run init_entire --verify sample --write
  [[ "$status" -eq 0 && "$output" == *'Identical: no change.'* ]] || fail "Entire repeat failed: $output"
  [[ "$(stat -c '%i %Y' "$file" "$skill")" == "$stamp" && "$(sha256sum "$CONFIG" "$TRUST" "$file" "$skill")" == "$before" ]] || fail "repeat changed files"
  out="$(policy show --json "$REPO")"
  jq -e '.trusted == true and .policy.push == "branch" and .policy.integrate == "" and .policy.review == "always" and .policy.agent_may_release == false' <<<"$out" >/dev/null || fail "Entire gates collapsed: $out"
  printf '\n# reviewed change\n' >>"$file"
  out="$(policy show --json "$REPO")"
  jq -e '.trusted == false and .policy.push == "ask"' <<<"$out" >/dev/null || fail "changed Entire hash trusted: $out"
  [[ "$(find "$REPO/.bercail" -type f | wc -l)" -eq 1 && ! -e "$TOOL_CALLS" ]] || fail "fabricated evidence or tool calls"
  grep -q 'STOP: this starter is not verification evidence' "$skill" || fail "starter no longer incomplete"
}

@test "Entire guarded is supported and backend-specific publishing profiles cannot cross" {
  entire_remote
  run policy init --repo "$REPO" --profile guarded --backend entire
  [[ "$status" -eq 0 && "$output" == *'push = "ask"'* && "$output" == *'project-level Trail'* ]] || fail "Entire guarded failed: $output"
  run policy init --repo "$REPO" --profile branch-pr --backend entire --write
  [[ "$status" -ne 0 && "$output" == *'branch-pr requires --backend gh'* ]] || fail "Entire PR profile accepted: $output"
  run policy init --repo "$REPO" --profile branch-trail --backend gh --write
  [[ "$status" -ne 0 && "$output" == *'branch-trail requires --backend entire'* ]] || fail "gh Trail profile accepted: $output"
  [[ ! -e "$REPO/.bercail" && ! -e "$TOOL_CALLS" ]] || fail "profile failure wrote or probed"
}

@test "Entire requires et hosting evidence absent an explicit matching owner override" {
  local url
  for url in https://github.com/owner/repo.git entire://example.com/gh/owner/repo https://example.com/repo.git; do
    git -C "$REPO" remote set-url origin "$url"
    run init_entire --write
    [[ "$status" -ne 0 && "$output" == *'entire scaffold requires'* ]] || fail "Entire without et evidence accepted: $output"
    [[ ! -e "$REPO/.bercail" ]] || fail "evidence failure wrote files"
  done
  git -C "$REPO" remote remove origin
  run init_entire --write
  [[ "$status" -ne 0 && "$output" == *'entire scaffold requires'* ]] || fail "no remote accepted: $output"
  printf '[git]\n"%s" = "entire"\n' "$REPO" >"$CONFIG"
  local before
  before="$(sha256sum "$CONFIG" "$TRUST")"
  run init_entire --write
  [[ "$status" -eq 0 ]] || fail "explicit Entire override did not win: $output"
  [[ "$(sha256sum "$CONFIG" "$TRUST")" == "$before" && ! -e "$TOOL_CALLS" ]] || fail "override mutated or probed"
}

@test "supported backend overrides reject mismatches for both scaffolds" {
  local configured requested before
  entire_remote
  for configured in gh gt origin entire; do
    printf '[git]\n"%s" = "%s"\n' "$REPO" "$configured" >"$CONFIG"
    before="$(sha256sum "$CONFIG" "$TRUST")"
    for requested in gh entire; do
      [[ "$configured" != "$requested" ]] || continue
      run policy init --repo "$REPO" --profile guarded --backend "$requested" --write
      [[ "$status" -ne 0 && "$output" == *"configured backend is $configured"* ]] || fail "backend mismatch accepted: $output"
      [[ ! -e "$REPO/.bercail" && "$(sha256sum "$CONFIG" "$TRUST")" == "$before" ]] || fail "mismatch wrote files"
    done
  done
  [[ ! -e "$TOOL_CALLS" ]] || fail "mismatch probed backend"
}

@test "unknown malformed or ambiguous git overrides cannot silently fall back for either backend" {
  local backend value before
  for backend in gh entire; do
    if [[ "$backend" == entire ]]; then entire_remote; fi
    for value in '"unknown"' 'true' '["gh"]' 'gh' '"gh' '"entire" trailing' '""' '"""unterminated'; do
      printf '[git]\n"%s" = %s\n' "$REPO" "$value" >"$CONFIG"
      before="$(sha256sum "$CONFIG" "$TRUST")"
      run policy init --repo "$REPO" --profile guarded --backend "$backend" --write
      [[ "$status" -ne 0 && "$output" == *'invalid git backend configuration'* ]] || fail "invalid override ($value) silently accepted: $output"
      [[ ! -e "$REPO/.bercail" && "$(sha256sum "$CONFIG" "$TRUST")" == "$before" ]] || fail "invalid override changed state"
    done
    printf '[git]\n"%s" "gh"\n' "$REPO" >"$CONFIG"
    run policy init --repo "$REPO" --profile guarded --backend "$backend" --write
    [[ "$status" -ne 0 && "$output" == *'invalid git backend configuration'* ]] || fail "malformed git line accepted: $output"
    printf '[git\n"%s" = "gh"\n' "$REPO" >"$CONFIG"
    run policy init --repo "$REPO" --profile guarded --backend "$backend" --write
    [[ "$status" -ne 0 && "$output" == *'invalid git backend configuration'* ]] || fail "malformed git table accepted: $output"
  done
  [[ ! -e "$TOOL_CALLS" ]] || fail "invalid override probed backend"
}

@test "duplicate matching git overrides refuse even when canonical aliases or equal values are used" {
  local backend alias second before
  entire_remote
  for backend in gh entire; do
    for alias in "$REPO" "$REPO/./"; do
      for second in gh entire; do
        printf '[git]\n"%s" = "gh"\n"%s" = "%s"\n' "$REPO" "$alias" "$second" >"$CONFIG"
        before="$(sha256sum "$CONFIG" "$TRUST")"
        run policy init --repo "$REPO" --profile guarded --backend "$backend" --write
        [[ "$status" -ne 0 && "$output" == *'multiple git backend entries match'* ]] || fail "ambiguous override silently selected: $output"
        [[ ! -e "$REPO/.bercail" && "$(sha256sum "$CONFIG" "$TRUST")" == "$before" && ! -e "$TOOL_CALLS" ]] || fail "ambiguous override changed state or probed"
      done
    done
  done
}

@test "Entire rendered prompt routes through Trail parent rules and forbids direct-main and desk approvals" {
  entire_remote
  local out
  init_entire --write >/dev/null
  out="$(policy show --json "$REPO")"
  jq -e '.entire == true and .policy.integrate == "" and .policy.pr_draft == false and
    (.prompt | contains("project-level Trail") and contains("true parent/base") and
      contains("Do not publish directly to main or master") and contains("Desks must not approve or merge Trails") and
      (contains("- Integrate: through a pull request") | not) and (contains("changes go straight to the main branch") | not))' <<<"$out" >/dev/null || fail "Entire prompt lost its Trail-only rules: $out"
}

@test "unrelated unknown overrides do not prevent Entire setup" {
  entire_remote
  printf '[git]\n"%s/other" = "unknown"\n' "$BATS_TEST_TMPDIR" >"$CONFIG"
  run init_entire --write
  [[ "$status" -eq 0 && ! -e "$TOOL_CALLS" ]] || fail "unrelated override blocked Entire: $output"
}

@test "Entire refuses Origin and Graphite evidence but matching override wins" {
  git -C "$REPO" remote set-url origin https://origin.cursor.com/org/repo
  run init_entire --write
  [[ "$status" -ne 0 && "$output" == *'offline backend evidence'* ]] || fail "Entire on Origin accepted: $output"
  entire_remote
  printf '{}\n' >"$REPO/.git/.graphite_repo_config"
  run init_entire --write
  [[ "$status" -ne 0 && "$output" == *'offline backend evidence'* ]] || fail "Entire with Graphite accepted: $output"
  printf '[git]\n"%s" = "entire"\n' "$REPO" >"$CONFIG"
  run init_entire --write
  [[ "$status" -eq 0 && ! -e "$TOOL_CALLS" ]] || fail "matching Entire override lost precedence: $output"
}

@test "Entire worktree uses canonical main override and main trust hash without writing main" {
  local wt before hash out
  printf '[git]\n"%s/./" = "entire"\n' "$REPO" >"$CONFIG"
  init_entire --write >/dev/null
  hash="$(sha256sum "$REPO/.bercail/policy.toml" | cut -d' ' -f1)"
  jq -n --arg repo "$REPO" --arg hash "$hash" '{($repo): {sha256: $hash}}' >"$TRUST"
  wt="$BATS_TEST_TMPDIR/entire feature"
  git -C "$REPO" worktree add -q -b entire-feature "$wt"
  printf '[git]\n"%s/./" = "entire"\n"%s" = "gh"\n' "$REPO" "$wt" >"$CONFIG"
  before="$(sha256sum "$REPO/.bercail/policy.toml" "$CONFIG" "$TRUST")"
  mkdir -p "$wt/subdir"
  cd "$wt/subdir"
  run policy init --repo . --profile branch-trail --backend entire --verify sample --write
  [[ "$status" -eq 0 && "$output" == *"Target: $wt/.bercail/policy.toml"* && "$output" == *"Main identity (not a write target): $REPO"* ]] || fail "Entire worktree override failed: $output"
  [[ "$(sha256sum "$REPO/.bercail/policy.toml" "$CONFIG" "$TRUST")" == "$before" && ! -e "$wt/subdir/.bercail" && ! -e "$TOOL_CALLS" ]] || fail "worktree modified main or probed"
  out="$(policy show --json "$wt")"
  jq -e --arg repo "$REPO" '.repo == $repo and .trusted == true and .policy.push == "branch" and .policy.review == "always"' <<<"$out" >/dev/null || fail "main hash not used: $out"
  printf '\n# changed candidate\n' >>"$wt/.bercail/policy.toml"
  out="$(policy show --json "$wt")"
  jq -e '.trusted == false and .policy.push == "ask"' <<<"$out" >/dev/null || fail "changed worktree hash trusted: $out"
}

@test "Entire policy and skill conflicts preflight without overwriting or partial preparation" {
  entire_remote
  local before
  mkdir -p "$REPO/.agents/skills/verify-sample"
  printf 'reviewed existing skill\n' >"$REPO/.agents/skills/verify-sample/SKILL.md"
  before="$(sha256sum "$REPO/.agents/skills/verify-sample/SKILL.md")"
  run init_entire --verify sample --write
  [[ "$status" -ne 0 && "$output" == *'conflict:'* && ! -e "$REPO/.bercail" ]] || fail "Entire skill conflict wrote policy: $output"
  [[ "$(sha256sum "$REPO/.agents/skills/verify-sample/SKILL.md")" == "$before" ]] || fail "skill changed"
  mkdir -p "$REPO/.bercail"
  printf 'future_schema = 99\n' >"$REPO/.bercail/policy.toml"
  before="$(sha256sum "$REPO/.bercail/policy.toml" "$REPO/.agents/skills/verify-sample/SKILL.md")"
  run init_entire --verify sample --write
  [[ "$status" -ne 0 && "$output" == *'conflict:'* && "$(sha256sum "$REPO/.bercail/policy.toml" "$REPO/.agents/skills/verify-sample/SKILL.md")" == "$before" ]] || fail "Entire policy conflict changed files: $output"
  [[ ! -e "$TOOL_CALLS" ]] || fail "conflict probed backend"
}

@test "Entire unsafe paths refuse before any write outside or inside checkout" {
  entire_remote
  local outside="$BATS_TEST_TMPDIR/outside"
  mkdir -p "$outside"
  ln -s "$outside" "$REPO/.agents"
  run init_entire --verify sample --write
  [[ "$status" -ne 0 && "$output" == *'symlink component'* && ! -e "$REPO/.bercail" && -z "$(find "$outside" -type f)" ]] || fail "Entire unsafe skill path accepted: $output"
  rm "$REPO/.agents"
  printf 'not a directory\n' >"$REPO/.bercail"
  run init_entire --write
  [[ "$status" -ne 0 && "$output" == *'not a directory'* ]] || fail "Entire unsafe policy parent accepted: $output"
  run init_entire --verify ../outside --write
  [[ "$status" -ne 0 && "$output" == *'invalid verification name'* && ! -e "$TOOL_CALLS" ]] || fail "Entire traversal accepted or probed: $output"
}

@test "concurrent static file creation is never overwritten" {
  local real_mkdir
  real_mkdir="$(command -v mkdir)"
  export RACE_TARGET="$REPO/.bercail/policy.toml"
  printf '#!/bin/bash\n%q "$@" || exit\nif [[ "$*" == *"/.bercail" ]]; then printf "concurrent writer\\n" >"$RACE_TARGET"; fi\n' "$real_mkdir" >"$BATS_TEST_TMPDIR/bin/mkdir"
  chmod +x "$BATS_TEST_TMPDIR/bin/mkdir"
  run init_guarded --write
  [[ "$status" -ne 0 && "$output" == *'conflict:'* ]] || fail "concurrent creation accepted: $output"
  [[ "$(<"$RACE_TARGET")" == 'concurrent writer' ]] || fail "concurrent creator overwritten"
}

@test "ambient git directory selectors cannot redirect explicit repo writes" {
  local var
  for var in GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE; do
    run env "$var=" "$ROOT/bin/bercail" policy init --repo "$REPO" --profile guarded --backend gh --write
    [[ "$status" -ne 0 && "$output" == *'--repo must select the checkout'* ]] || fail "ambient $var accepted: $output"
    [[ ! -e "$REPO/.bercail" ]] || fail "ambient selector wrote files"
  done
}

@test "control characters in a resolved repo path are refused even with dot input" {
  local odd="$BATS_TEST_TMPDIR/repo"$'\n'"hidden"
  git -C "$REPO" worktree add -q -b odd "$odd"
  cd "$odd"
  run policy init --repo . --profile guarded --backend gh --write
  [[ "$status" -ne 0 && "$output" == *'control characters'* ]] || fail "newline cwd accepted: $output"
  [[ ! -e "$odd/.bercail" ]] || fail "newline cwd wrote files"
}

@test "directory write errors return failure without claiming completion" {
  printf '#!/bin/sh\nexit 73\n' >"$BATS_TEST_TMPDIR/bin/mkdir"
  chmod +x "$BATS_TEST_TMPDIR/bin/mkdir"
  run init_guarded --write
  [[ "$status" -ne 0 && "$output" == *'cannot create parent directory'* ]] || fail "mkdir error ignored: $output"
  [[ ! -e "$REPO/.bercail" ]] || fail "failed mkdir left policy"
}
