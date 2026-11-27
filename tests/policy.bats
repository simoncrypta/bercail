#!/usr/bin/env bats
# bercail policy: the repo's .bercail/policy.toml, the local override, trust by
# hash (a loosening value counts only once trusted, and an edit goes back to the
# default), the old commit key, and what the guard decides from that JSON. A temp HOME.

setup() {
  load test_helper
  # node through mise needs the real HOME: find it before isolate moves HOME.
  NODE="$(mise which node 2>/dev/null || command -v node 2>/dev/null || true)"
  isolate
  set -o pipefail
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
  export GIT_CONFIG_NOSYSTEM=1
  mkdir -p "$XDG_CONFIG_HOME/bercail"
  git config --global user.name test
  git config --global user.email test@example.com
  git config --global init.defaultBranch main
  CONFIG="$XDG_CONFIG_HOME/bercail/config.toml"
  TRUST="$XDG_STATE_HOME/bercail/policy-trust.json"
  unset BERCAIL_CONFIG
}

policy() { "$ROOT/bin/bercail" policy "$@"; }
field() { policy show --json "$1" | jq -r "$2"; }

# bats 1.13 eval's a test name inside double quotes, so the " in
# [policy."<main checkout>"] is read as a redirection and that test never
# starts. Assign the name instead, only when this is the runner's function.
# gather-tests uses a different one; leaving it keeps `bats -f` on the PASS text.
# shellcheck disable=SC2317,SC2329
if declare -f bats_test_function | grep -q 'printf -v test_description'; then
  bats_test_function() {
    local tags=() current_tags=() test_description=""
    while (( $# > 0 )); do
      case "$1" in
        --description) test_description="$2"; shift 2 ;;
        --tags)
          if [[ -n "$2" ]]; then
            IFS=',' read -ra current_tags <<<"$2"
            tags+=("${current_tags[@]}")
          fi
          shift 2
          ;;
        --) shift; break ;;
        *) printf 'ERROR: unknown option %s for bats_test_function\n' "$1" >&2; exit 1 ;;
      esac
    done
    if (( ${#tags[@]} > 1 )); then
      bats_sort tags "${tags[@]}"
    fi
    BATS_TEST_NAMES+=("$*")
    local quoted_parameters
    printf -v quoted_parameters ' %q' "$@"
    quoted_parameters=${quoted_parameters:1}
    if [[ ${BATS_TEST_NAME-} == "$quoted_parameters" ]]; then
      # shellcheck disable=SC2034
      BATS_TEST_TAGS=("${tags[@]+${tags[@]}}")
      export BATS_TEST_DESCRIPTION="${test_description-$*}"
      # shellcheck disable=SC2034
      BATS_TEST_COMMAND=("$@")
    fi
  }
fi

# Sets REPO and WT: a repo with a remote, one commit, a linked worktree.
init_repo() {
  REPO="$BATS_TEST_TMPDIR/repo"
  git init -q "$REPO"
  git -C "$REPO" remote add origin https://example.com/repo.git
  git -C "$REPO" commit -q --allow-empty -m init
  git -C "$REPO" worktree add -q -b feature "$BATS_TEST_TMPDIR/repo.feature"
  WT="$BATS_TEST_TMPDIR/repo.feature"
  REPO="$(cd "$REPO" && pwd -P)"
  WT="$(cd "$WT" && pwd -P)"
}

write_policy() {
  mkdir -p "$1/.bercail"
  cat >"$1/.bercail/policy.toml" <<'EOF'
# team policy
push = 'main'   # no prompt
integrate = "direct"
pr_draft = true
release = "Bump \"VERSION\", then tag v*."
agent_may_release = false
rules = """
Use gh, never gt.
Simon merges."""
EOF
}

# The committed policy, merged into the worktree. Untrusted until a test trusts it.
commit_policy() {
  init_repo
  write_policy "$REPO"
  git -C "$REPO" add .bercail/policy.toml
  git -C "$REPO" commit -q -m policy
  git -C "$WT" merge -q main
}

# Sets SCRATCH: a repo under $TMPDIR with no remote, which used to be a special case.
scratch_repo() {
  SCRATCH="$TMPDIR/scratch-$BATS_TEST_NUMBER"
  git init -q "$SCRATCH"
  SCRATCH="$(cd "$SCRATCH" && pwd -P)"
}

@test "no policy file is the default" {
  local REPO WT
  init_repo
  [[ "$(field "$REPO" '.policy | [.push, .agent_may_release, has("commit")] | join(" ")')" == "ask false false" ]] \
    || fail "no policy is not the default: $(policy show --json "$REPO")"
  [[ "$(field "$REPO" '[.sources[]] | unique | join(",")')" == default ]] || fail "sources without a policy"
  [[ "$(field "$REPO" '.file')" == "" ]] || fail "a file with no policy"
}

@test "merge_reversible: unset and false are false, true counts only once trusted or set locally" {
  local REPO WT
  init_repo
  [[ "$(field "$REPO" '.policy.merge_reversible')" == false ]] || fail "unset is not false"
  mkdir -p "$REPO/.bercail"
  printf 'merge_reversible = false\n' >"$REPO/.bercail/policy.toml"
  [[ "$(field "$REPO" '[.policy.merge_reversible, .sources.merge_reversible] | join(" ")')" == "false repo" ]] || fail "false"
  printf 'merge_reversible = true\n' >"$REPO/.bercail/policy.toml"
  [[ "$(field "$REPO" '.policy.merge_reversible')" == false ]] || fail "an untrusted true counted"
  [[ "$(field "$REPO" '.untrusted | join(",")')" == merge_reversible ]] || fail "the untrusted true is not named"
  policy trust "$REPO" >/dev/null
  [[ "$(field "$REPO" '.policy.merge_reversible')" == true ]] || fail "a trusted true did not count"
  policy untrust "$REPO" >/dev/null
  printf '[policy."%s"]\nmerge_reversible = true\n' "$REPO" >"$CONFIG"
  [[ "$(field "$REPO" '[.policy.merge_reversible, .sources.merge_reversible] | join(" ")')" == "true local" ]] \
    || fail "your own override needs no trust"
  printf 'merge_reversible = "yes"\n' >"$REPO/.bercail/policy.toml"
  rm "$CONFIG"
  [[ "$(policy show --json "$REPO" 2>&1 >/dev/null)" == *'merge_reversible = "yes" is not allowed'* ]] || fail "a non-boolean passed"
}

@test "rebase_keeps_pick: unset is false, true counts only once trusted or set locally" {
  local REPO WT
  init_repo
  [[ "$(field "$REPO" '.policy.rebase_keeps_pick')" == false ]] || fail "unset is not false"
  mkdir -p "$REPO/.bercail"
  printf 'rebase_keeps_pick = true\n' >"$REPO/.bercail/policy.toml"
  [[ "$(field "$REPO" '.policy.rebase_keeps_pick')" == false ]] || fail "an untrusted true counted"
  [[ "$(field "$REPO" '.untrusted | join(",")')" == rebase_keeps_pick ]] || fail "the untrusted true is not named"
  policy trust "$REPO" >/dev/null
  [[ "$(field "$REPO" '.policy.rebase_keeps_pick')" == true ]] || fail "a trusted true did not count"
  policy untrust "$REPO" >/dev/null
  on_tty "$ROOT/bin/bercail" config set "policy.\"$REPO\"" rebase_keeps_pick true >/dev/null || fail "config set does not know the key"
  [[ "$(field "$REPO" '[.policy.rebase_keeps_pick, .sources.rebase_keeps_pick] | join(" ")')" == "true local" ]] \
    || fail "your own override needs no trust"
  rm "$CONFIG"
  printf 'rebase_keeps_pick = "yes"\n' >"$REPO/.bercail/policy.toml"
  [[ "$(policy show --json "$REPO" 2>&1 >/dev/null)" == *'rebase_keeps_pick = "yes" is not allowed'* ]] || fail "a non-boolean passed"
}

@test "shep_may_run: what Shep runs with no card counts only once trusted or set locally, and only the three it knows" {
  local REPO WT
  init_repo
  [[ "$(field "$REPO" '.policy.shep_may_run | length')" == 0 ]] || fail "unset is not empty"
  mkdir -p "$REPO/.bercail"
  printf 'shep_may_run = ["cleanup", "trail link", "trail merge"]\n' >"$REPO/.bercail/policy.toml"
  [[ "$(field "$REPO" '.policy.shep_may_run | length')" == 0 ]] || fail "an untrusted list counted"
  [[ "$(field "$REPO" '.untrusted | join(",")')" == shep_may_run ]] || fail "the untrusted list is not named"
  policy trust "$REPO" >/dev/null
  [[ "$(field "$REPO" '.policy.shep_may_run | join(",")')" == "cleanup,trail link,trail merge" ]] || fail "a trusted list did not count"
  [[ "$(field "$REPO" '.prompt')" == *"Shep runs these here with no guard card while the repo reads private, and the guard warns: cleanup, trail link, trail merge."* ]] \
    || fail "prompt: $(field "$REPO" '.prompt')"
  policy untrust "$REPO" >/dev/null
  printf '[policy."%s"]\nshep_may_run = ["trail link"]\n' "$REPO" >"$CONFIG"
  [[ "$(field "$REPO" '[(.policy.shep_may_run | join(",")), .sources.shep_may_run] | join(" ")')" == "trail link local" ]] \
    || fail "your own override needs no trust"
  rm "$CONFIG"
  for bad in '["deploy"]' '["cleanup", "cleanup"]' '"cleanup"'; do
    printf 'shep_may_run = %s\n' "$bad" >"$REPO/.bercail/policy.toml"
    [[ "$(policy show --json "$REPO" 2>&1 >/dev/null)" == *"shep_may_run = "*" is not allowed"* ]] || fail "$bad passed"
  done
}

@test "an untrusted policy cannot loosen the guard" {
  local REPO WT out
  commit_policy
  out="$(policy show --json "$REPO")"
  jq -e '.policy.push == "ask" and .policy.integrate == "direct" and .policy.pr_draft == true' <<<"$out" >/dev/null \
    || fail "untrusted loosening applied: $out"
  jq -e '.untrusted == ["push"] and (.sources.push | test("repo says main, not trusted"))' <<<"$out" >/dev/null \
    || fail "untrusted values are not named: $out"
  jq -e '.policy.release == "Bump \"VERSION\", then tag v*." and .policy.rules == "Use gh, never gt.\nSimon merges."' <<<"$out" >/dev/null \
    || fail "strings did not parse: $out"
  jq -e '.prompt | test("Use gh, never gt.") and test("guard asks the person first") and test("is not trusted")
    and test("Commit: a commit is local, so the guard lets it run with a warning")' <<<"$out" >/dev/null \
    || fail "the prompt text: $(jq -r .prompt <<<"$out")"
  policy show "$REPO" | grep -q "not trusted: bercail policy trust" || fail "show does not say how to trust"
}

@test "a trusted policy applies in the main checkout and its worktrees" {
  local REPO WT out
  commit_policy
  out="$(policy trust "$REPO")"
  [[ "$out" == *"trusted $REPO/.bercail/policy.toml"* && "$out" == *"agents now: push main"* ]] \
    || fail "trust did not say what it trusted: $out"
  if field "$REPO" .prompt | grep -q "is not trusted"; then fail "a trusted policy is labeled untrusted"; fi
  jq -e --arg m "$REPO" '.[$m].sha256 | length == 64' "$TRUST" >/dev/null || fail "no hash in $(cat "$TRUST")"
  [[ "$(field "$REPO" '[.trusted, .policy.push] | join(" ")')" == "true main" ]] || fail "trust did not apply"
  [[ "$(field "$WT" '[.repo, .trusted, .policy.push] | join(" ")')" == "$REPO true main" ]] \
    || fail "the worktree does not share the trust: $(policy show --json "$WT")"
}

@test "an edited file or untrust goes back to asking" {
  local REPO WT
  commit_policy
  policy trust "$REPO" >/dev/null
  printf 'pr_draft = false\n' >>"$WT/.bercail/policy.toml"
  [[ "$(field "$WT" '[.trusted, .policy.push] | join(" ")')" == "false ask" ]] \
    || fail "an edited policy kept its trust: $(policy show --json "$WT")"
  [[ "$(field "$REPO" '.trusted')" == true ]] || fail "the main checkout lost its trust"
  git -C "$WT" checkout -q -- .bercail/policy.toml
  policy untrust "$REPO" | grep -q "untrusted $REPO" || fail "untrust said nothing"
  [[ "$(field "$REPO" '[.trusted, .policy.push] | join(" ")')" == "false ask" ]] || fail "untrust did not go back to asking"
}

@test "preview shows the sha256, the repo, the file and the diff against the version last trusted, and writes nothing" {
  local REPO WT out old hash
  commit_policy
  hash="$(field "$REPO" .sha256)"
  out="$(policy preview "$REPO")"
  [[ "$out" == "sha256: $hash"$'\n'"repo:   $REPO"$'\n'"file:   $REPO/.bercail/policy.toml"$'\n'* ]] || fail "head: $out"
  [[ "$out" == *"No version of it was trusted before; the whole file:"*"+push = 'main'   # no prompt"* ]] || fail "first: $out"
  [[ ! -e "$TRUST" ]] || fail "a preview wrote $(cat "$TRUST")"
  policy trust "$REPO" >/dev/null
  old="$(git -C "$REPO" rev-parse HEAD)"
  printf 'merge_reversible = true\n' >>"$REPO/.bercail/policy.toml"
  git -C "$REPO" commit -qam loosen
  out="$(policy preview "$REPO")"
  [[ "$out" == *"against the version last trusted (sha256 $hash, "*", in commit ${old:0:12}):"* ]] || fail "last: $out"
  [[ "$out" == *$'\n+merge_reversible = true'* && "$out" != *"+push"* ]] || fail "diff: $out"
  [[ "$(field "$REPO" .trusted)" == false ]] || fail "a preview trusted it"
  # A version trusted but never committed: the whole file, saying so.
  printf 'pr_draft = false\n' >>"$REPO/.bercail/policy.toml"
  policy trust "$REPO" >/dev/null
  git -C "$REPO" checkout -q -- .bercail/policy.toml
  out="$(policy preview "$REPO")"
  [[ "$out" == *"is in no commit on HEAD; the whole file:"*"+push = 'main'"* ]] || fail "uncommitted: $out"
  policy trust "$REPO" >/dev/null
  [[ "$(policy preview "$REPO")" == *"It is trusted already, as this sha256"* ]] || fail "already"
}

@test "preview shows no text from a linked policy file or folder" {
  local REPO WT err
  commit_policy
  printf 'secret = "kept-outside"\n' >"$BATS_TEST_TMPDIR/outside.toml"
  ln -sf "$BATS_TEST_TMPDIR/outside.toml" "$WT/.bercail/policy.toml"
  err="$(policy preview "$WT" 2>&1)" && fail "a linked file was shown: $err"
  [[ "$err" == *"is a link, so its text may be outside the checkout"* && "$err" != *kept-outside* ]] || fail "error: $err"
  rm -r "$WT/.bercail" && ln -s "$BATS_TEST_TMPDIR" "$WT/.bercail"
  cp "$REPO/.bercail/policy.toml" "$BATS_TEST_TMPDIR/policy.toml"
  err="$(policy preview "$WT" 2>&1)" && fail "a linked folder was shown: $err"
  [[ "$err" == *"is a link"* ]] || fail "error: $err"
}

@test "trust-pinned trusts the file only while its sha256 and its main checkout are the ones given" {
  local REPO WT err hash other
  commit_policy
  hash="$(field "$REPO" .sha256)"
  err="$(policy trust-pinned "$(printf '0%.0s' {1..64})" "$REPO" "$REPO" 2>&1)" && fail "a stale hash trusted it"
  [[ "$err" == *"is sha256 ${hash:0:12} now, not the 000000000000 its card showed; nothing trusted"* ]] || fail "error: $err"
  # The same bytes in another repo: the hash alone would trust them there.
  other="$BATS_TEST_TMPDIR/other"
  git init -q "$other" && mkdir "$other/.bercail" && cp "$REPO/.bercail/policy.toml" "$other/.bercail/"
  other="$(cd "$other" && pwd -P)"
  err="$(policy trust-pinned "$hash" "$REPO" "$other" 2>&1)" && fail "another repo was trusted"
  [[ "$err" == *"$other is a checkout of $other now, not the $REPO its card showed; nothing trusted"* ]] || fail "error: $err"
  [[ ! -e "$TRUST" ]] || fail "trusted on a stale card: $(cat "$TRUST")"
  for bad in "short $REPO $REPO" "$hash relative $REPO" "$hash $REPO"; do
    # shellcheck disable=SC2086 # its words
    err="$(policy trust-pinned $bad 2>&1)" && fail "$bad ran"
    [[ "$err" == *"usage: bercail policy trust-pinned SHA256 MAIN_CHECKOUT REPO"* ]] || fail "error: $err"
  done
  [[ "$(policy trust-pinned "$hash" "$REPO" "$WT")" == "trusted $WT/.bercail/policy.toml"* ]] || fail "not trusted"
  [[ "$(field "$REPO" .trusted)" == true ]] || fail "the right hash and repo did not trust it"
}

@test 'config.toml [policy."<main checkout>"] overrides without trust' {
  local REPO WT out
  commit_policy
  cat >"$CONFIG" <<EOF
[git]
"~/elsewhere" = "gh"

[policy."${REPO/#$HOME/\~}"]
push = "branch"
integrate = "pr"

[policy."/somewhere/else"]
push = "main"
EOF
  out="$(policy show --json "$WT")"
  jq -e '.policy.push == "branch" and .sources.push == "local" and .policy.integrate == "pr"' <<<"$out" >/dev/null \
    || fail "the local override: $out"
}

@test "bad values warn and fall back" {
  local REPO WT err
  commit_policy
  printf 'push = "always"\nmerge = "yes"\nintegrate = maybe\n' >"$WT/.bercail/policy.toml"
  err="$(policy show --json "$WT" 2>&1 >/dev/null)"
  [[ "$err" == *'push = "always" is not allowed'* && "$err" == *"unknown key merge"* && "$err" == *"integrate = maybe"* ]] \
    || fail "warnings: $err"
  git -C "$WT" checkout -q -- .bercail/policy.toml
}

@test "an old commit key is ignored with a warning, and a temp repo with no remote is no special case" {
  local SCRATCH err
  scratch_repo
  mkdir -p "$SCRATCH/.bercail" && printf 'commit = "allow"\npush = "ask"\n' >"$SCRATCH/.bercail/policy.toml"
  err="$(policy show --json "$SCRATCH" 2>&1 >/dev/null)"
  [[ "$err" == *"unknown key commit, ignored"* ]] || fail "an old commit key did not warn: $err"
  [[ "$(field "$SCRATCH" '[has("scratch"), (.policy | has("commit")), .policy.push] | join(" ")' 2>/dev/null)" == "false false ask" ]] \
    || fail "scratch or commit is still in the policy: $(policy show --json "$SCRATCH" 2>/dev/null)"
  if policy show "$SCRATCH" 2>/dev/null | grep -q "^scratch:"; then fail "show still has a scratch line"; fi
}

@test "errors say what is wrong" {
  local SCRATCH err
  scratch_repo
  err="$(policy show "$BATS_TEST_TMPDIR" 2>&1)" && fail "a non-checkout succeeded"
  [[ "$err" == *"is not a git checkout"* ]] || fail "non-checkout error: $err"
  err="$(policy trust "$SCRATCH" 2>&1)" && fail "trusting a repo with no policy succeeded"
  [[ "$err" == *"does not exist; nothing to trust"* ]] || fail "trust error: $err"
}

@test "the guard decides from bercail policy show --json" {
  local REPO WT SCRATCH node
  [[ -n "$NODE" ]] || unavailable "node not found"
  node="$NODE"
  commit_policy
  scratch_repo
  printf '[git]\n"%s" = "gh"\n' "$SCRATCH" >"$CONFIG"
  decide() {
    policy show --json "$1" | "$node" --no-warnings --input-type=module -e '
      import { readFileSync } from "node:fs";
      const { decideBash, policyFromJson } = await import(process.argv[1]);
      const json = JSON.parse(readFileSync(0, "utf8"));
      const headless = process.argv[3] === "headless" || process.argv[3] === "shep-bg";
      const input = { role: headless && process.argv[3] !== "shep-bg" ? "" : process.argv[3], hasUI: !headless, cwd: json.root,
        policies: { [json.root]: policyFromJson(json) }, branches: { [json.root]: "feature" } };
      const got = decideBash(process.argv[2], input);
      console.log(got.action + (got.warnings ? "+warning" : ""));
    ' "$ROOT/bstack/pi/extensions/guard.ts" "$2" "${3:-}"
  }
  # A commit warns in a repo that asks, desk or headless; the judge and background
  # Shep are refused; a push there still asks, and is refused headless.
  [[ "$(decide "$WT" "git commit -m x")" == allow+warning ]] || fail "untrusted commit did not warn"
  [[ "$(decide "$WT" "git commit -m x" headless)" == allow+warning ]] || fail "untrusted headless commit did not warn"
  [[ "$(decide "$WT" "git commit -m x" judge)" == block ]] || fail "a judge's commit went through"
  [[ "$(decide "$WT" "git commit -m x" shep-bg)" == block ]] || fail "a background Shep's commit went through"
  [[ "$(decide "$WT" "git push origin main")" == ask ]] || fail "untrusted push did not ask"
  [[ "$(decide "$WT" "git push origin main" headless)" == block ]] || fail "untrusted headless push was not blocked"
  policy trust "$WT" >/dev/null
  [[ "$(decide "$WT" "git commit -m x")" == allow+warning ]] || fail "trusted commit did not warn"
  [[ "$(decide "$WT" "git push origin main")" == allow ]] || fail "trusted push to main did not go through"
  [[ "$(decide "$WT" "git push origin main" headless)" == allow ]] || fail "trusted headless push did not go through"
  [[ "$(decide "$WT" "git push --force origin feature")" == block ]] || fail "force-push under a trusted policy"
  [[ "$(decide "$WT" "git tag v1.0.0")" == ask ]] || fail "a tag without agent_may_release"
  [[ "$(field "$WT" .entire)" == false ]] || fail "no .entire/settings.json: Entire is off"
  [[ "$(decide "$WT" "git push --all origin")" == allow ]] || fail "push --all under push = main, no Entire"
  mkdir -p "$WT/.entire" && printf '{"enabled": true}\n' >"$WT/.entire/settings.json"
  [[ "$(field "$WT" .entire)" == true ]] || fail "show --json says Entire is on"
  [[ "$(decide "$WT" "git push --all origin")" == block ]] || fail "push --all where Entire keeps shadow branches"
  rm -rf "$WT/.entire"
  printf 'rules = "changed"\n' >>"$WT/.bercail/policy.toml"
  [[ "$(decide "$WT" "git push origin main")" == ask ]] || fail "an edited policy still allowed the push"
  git -C "$WT" checkout -q -- .bercail/policy.toml
  : >"$CONFIG"
  [[ "$(decide "$SCRATCH" "git commit -m x" headless)" == allow+warning ]] || fail "a temp repo's commit did not warn"
  [[ "$(decide "$SCRATCH" "git push /tmp/x.git HEAD:main")" == ask ]] || fail "a temp repo's push did not ask"
}

# A policy file in the main checkout with the review keys in $1, untracked.
review_policy() {
  mkdir -p "$REPO/.bercail"
  printf '%b' "$1" >"$REPO/.bercail/policy.toml"
}

@test "review keys: by stakes, no high-stakes path, and budgets of 400 and 1000 lines by default" {
  local REPO WT
  init_repo
  [[ "$(field "$REPO" '.policy | [.review, (.high_stakes | length), .diff_budget, .review_budget] | join(" ")')" == "by-stakes 0 400 1000" ]] \
    || fail "defaults: $(policy show --json "$REPO" | jq -c .policy)"
}

@test "review keys: review none and a bigger budget wait for trust; high_stakes and a smaller budget apply at once" {
  local REPO WT out
  init_repo
  review_policy 'review = "none"\ndiff_budget = 800\nreview_budget = 500\nhigh_stakes = ["lib/policy.sh"]\n'
  out="$(policy show --json "$REPO")"
  jq -e '.policy.review == "by-stakes" and .policy.diff_budget == 400 and .policy.review_budget == 500
    and .policy.high_stakes == ["lib/policy.sh"] and .untrusted == ["review", "diff_budget"]' <<<"$out" >/dev/null \
    || fail "untrusted: $out"
  policy trust "$REPO" >/dev/null
  [[ "$(field "$REPO" '.policy | [.review, .diff_budget] | join(" ")')" == "none 800" ]] || fail "trusted: $(policy show --json "$REPO" | jq -c .policy)"
}

@test "review keys: high_stakes takes one glob a line, without blanks or comments, or a one-line array, and show lists them" {
  local REPO WT
  init_repo
  review_policy 'high_stakes = """\nlib/policy.sh\n# the installer\n  install.sh  \n\n"""\n'
  [[ "$(field "$REPO" '.policy.high_stakes | join(",")')" == "lib/policy.sh,install.sh" ]] || fail "lines: $(policy show --json "$REPO" | jq -c .policy.high_stakes)"
  policy show "$REPO" | grep -qx '  install.sh' || fail "show lists the globs: $(policy show "$REPO")"
  review_policy 'high_stakes = ["workers/", "site/worker*"]\n'
  [[ "$(field "$REPO" '.policy.high_stakes | join(",")')" == "workers/,site/worker*" ]] || fail "array: $(policy show --json "$REPO" | jq -c .policy.high_stakes)"
}

@test "review keys: bad values warn and fall back" {
  local REPO WT err
  init_repo
  mkdir -p "$REPO/.bercail"
  printf 'review = "sometimes"\nhigh_stakes = ["../outside", ":(top)x"]\ndiff_budget = 0\nreview_budget = "lots"\n' >"$REPO/.bercail/policy.toml"
  err="$(policy show --json "$REPO" 2>&1 >/dev/null)"
  [[ "$err" == *'review = "sometimes" is not allowed'* && "$err" == *'high_stakes = ["../outside",":(top)x"] is not allowed'* \
    && "$err" == *'diff_budget = 0 is not allowed'* && "$err" == *'review_budget = "lots" is not allowed'* ]] || fail "warnings: $err"
  [[ "$(field "$REPO" '[.sources.review, .sources.high_stakes, .sources.diff_budget] | join(" ")' 2>/dev/null)" == "default default default" ]] \
    || fail "bad values were used: $(policy show --json "$REPO" 2>/dev/null | jq -c .sources)"
}

@test "required_ci: a list of workflow files, empty by default, that counts only once trusted" {
  local REPO WT out err
  init_repo
  [[ "$(field "$REPO" '.policy.required_ci | tojson')" == '[]' ]] || fail "default: $(policy show --json "$REPO" | jq -c .policy)"
  review_policy 'required_ci = [".github/workflows/ci.yml", ".github/workflows/lint.yaml"]\n'
  out="$(policy show --json "$REPO")"
  jq -e '.policy.required_ci == [] and .untrusted == ["required_ci"]' <<<"$out" >/dev/null || fail "untrusted counted: $out"
  policy trust "$REPO" >/dev/null
  [[ "$(field "$REPO" '[.policy.required_ci[], .sources.required_ci] | join(" ")')" == ".github/workflows/ci.yml .github/workflows/lint.yaml repo" ]] \
    || fail "trusted: $(policy show --json "$REPO" | jq -c .policy)"
  for bad in '"ci.yml"' '[".github/workflows/ci.yml", ".github/workflows/ci.yml"]' '["ci.yml"]' \
    '[".github/workflows/../x.yml"]' '[".github/workflows/ci.txt"]' '[7]'; do
    review_policy "required_ci = $bad\n"
    policy trust "$REPO" >/dev/null
    err="$(policy show --json "$REPO" 2>&1 >/dev/null)"
    [[ "$err" == *'required_ci = '*' is not allowed'* ]] || fail "$bad passed: $err"
    [[ "$(field "$REPO" '[(.policy.required_ci | tojson), .sources.required_ci] | join(" ")' 2>/dev/null)" == "[] default" ]] \
      || fail "$bad was used: $(policy show --json "$REPO" 2>/dev/null | jq -c .policy.required_ci)"
  done
}
