#!/usr/bin/env bats
# bercail describe: a change's description in .bercail/description.md, checked
# against the staged tree it was stamped for, the repo's PR template, and the
# standard's mechanical rules. Each @test builds its own repo in a temp HOME.

setup() {
  load test_helper
  isolate
  need git jq
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig" GIT_CONFIG_NOSYSTEM=1
  git config --global user.name test
  git config --global user.email test@example.com
  git config --global init.defaultBranch main
  unset BERCAIL_CONFIG
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  REPO="$BATS_TEST_TMPDIR/repo"
  git_init "$REPO"
  cd "$REPO" || return 1
}

describe() { "$ROOT/bin/bercail" describe "$@"; }

# Stage a change.
change() {
  printf '%s\n' "${1:-new}" >>file.txt
  git add file.txt
}

# validate.json for the staged tree, with one check that exited $1 (default 0).
evidence() {
  mkdir -p .bercail
  jq -n --arg t "$(git write-tree)" --argjson rc "${1:-0}" \
    '{tree: $t, checks: [{kind: "test", command: "bash tests/run.sh", exit_code: $rc, evidence: "all passed"}]}' >.bercail/validate.json
}

# description.md with TITLE and the body on stdin.
description() {
  mkdir -p .bercail
  { printf -- '---\ntitle: %s\n---\n' "$1"; cat; } >.bercail/description.md
}

plain_body() {
  printf 'Adds a line for readers of file.txt.\n\nValidation: bash tests/run.sh passed.\n'
}

# What body prints with no desk record and no review: the plain body and the line.
NOBODY=$'\n\nWritten with bercail; not yet reviewed'


# A change with evidence and a stamped plain description.
described() {
  change
  evidence
  plain_body | description "file: add a line"
  describe stamp >/dev/null || fail "stamp"
}

leftlane_template() {
  mkdir -p .github
  printf '# Summary\n\nLoom:\n\n# Changes\n\n# How to test\n\n# Notes for the reviewer\n' >.github/pull_request_template.md
  git add .github && git commit -qm template
}

@test "template: .github/ wins over the root and docs/, in any case; a template dir is a choice, never a pick" {
  mkdir -p .github docs
  printf '# Root\n' >PULL_REQUEST_TEMPLATE.md
  printf '# Docs\n' >docs/pull_request_template.md
  git add . && git commit -qm templates
  [[ "$(describe template)" == PULL_REQUEST_TEMPLATE.md ]] || fail "the root beats docs/: $(describe template)"
  printf '# Hidden\n' >.github/pull_request_template.md
  [[ "$(describe template)" == .github/pull_request_template.md ]] || fail ".github/ first: $(describe template)"

  git rm -q PULL_REQUEST_TEMPLATE.md docs/pull_request_template.md && rm .github/pull_request_template.md
  mkdir -p .github/PULL_REQUEST_TEMPLATE
  printf '# Bug\n' >.github/PULL_REQUEST_TEMPLATE/bug.md
  printf '# Feature\n' >.github/PULL_REQUEST_TEMPLATE/feature.md
  describe template --json | jq -e '.template == null and .choices == [".github/PULL_REQUEST_TEMPLATE/bug.md", ".github/PULL_REQUEST_TEMPLATE/feature.md"]' >/dev/null \
    || fail "a dir: $(describe template --json)"
  [[ "$(describe template)" == "pick one: .github/PULL_REQUEST_TEMPLATE/bug.md, .github/PULL_REQUEST_TEMPLATE/feature.md" ]] \
    || fail "$(describe template)"
}

@test "template: the policy's pr_template pins one or says none; a path outside the repo is ignored" {
  leftlane_template
  mkdir -p .bercail docs
  printf '# Ours\n' >docs/pr.md
  printf 'pr_template = "docs/pr.md"\n' >.bercail/policy.toml
  [[ "$(describe template)" == docs/pr.md ]] || fail "pinned: $(describe template)"
  printf 'pr_template = "none"\n' >.bercail/policy.toml
  [[ "$(describe template)" == none ]] || fail "none: $(describe template)"
  printf 'pr_template = "../elsewhere.md"\n' >.bercail/policy.toml
  [[ "$(describe template 2>/dev/null)" == .github/pull_request_template.md ]] || fail "a .. path must not count"
  "$ROOT/bin/bercail" policy show . 2>&1 | grep -q 'pr_template = "../elsewhere.md" is not allowed' || fail "the policy says why"
}

@test "stamp: needs the description, its title, and checks recorded for the staged tree; then records the tree" {
  change
  describe stamp 2>&1 | grep -q 'write the description first' || fail "no description"
  printf 'body\n' | description ""
  describe stamp 2>&1 | grep -q 'has no title' || fail "no title"
  plain_body | description "file: add a line"
  describe stamp 2>&1 | grep -q 'must record the checks for the staged tree' || fail "no evidence"
  evidence
  change more
  describe stamp 2>&1 | grep -q 'must record the checks for the staged tree' || fail "evidence for an older tree"
  evidence
  describe stamp >/dev/null || fail "stamp"
  [[ "$(sed -n 2,3p .bercail/description.md)" == "title: file: add a line"$'\n'"tree: $(git write-tree)" ]] \
    || fail "frontmatter: $(cat .bercail/description.md)"
  [[ "$(describe body)" == "$(plain_body)$NOBODY" ]] || fail "the body is kept: $(describe body)"
}

@test "stamp keeps .bercail/ out of git once, through info/exclude, and leaves a repo that ignores it alone" {
  described
  [[ "$(grep -c '^\.bercail/\*$' .git/info/exclude)" == 1 ]] || fail "excluded once: $(cat .git/info/exclude)"
  describe stamp >/dev/null
  [[ "$(grep -c '^\.bercail/\*$' .git/info/exclude)" == 1 ]] || fail "not twice"
  [[ -z "$(git status --porcelain -- .bercail)" ]] || fail "status shows .bercail"

  local other="$BATS_TEST_TMPDIR/other"
  git_init "$other"
  printf '.bercail/\n' >"$other/.gitignore"
  git -C "$other" add .gitignore && git -C "$other" commit -qm ignore
  cd "$other" || return 1
  described
  if grep -q bercail .git/info/exclude; then fail "the repo already ignores it"; fi
}

@test "check: a fresh description passes, an edit after the stamp makes it stale, and the commit keeps it fresh" {
  described
  describe check >/dev/null 2>&1 || fail "fresh: $(describe check 2>&1)"
  change again
  describe check 2>&1 | grep -q '^fail: stale: it describes tree' || fail "stale: $(describe check 2>&1)"
  describe body >/dev/null 2>&1 && fail "body refuses a stale description"
  git reset -q file.txt && git checkout -q file.txt
  change
  git commit -qF <(describe commit) || fail "commit"
  describe check >/dev/null 2>&1 || fail "after the commit, HEAD's tree is the one described: $(describe check 2>&1)"
  [[ "$(git log -1 --format=%B)" == "file: add a line"$'\n\n'"$(plain_body)$NOBODY" ]] || fail "the commit message is the description: $(git log -1 --format=%B)"
}

@test "check: the template's sections, in order and filled; an empty label line fails, a dropped one warns; no template comment" {
  leftlane_template
  change
  evidence
  printf '# Summary\n\nAdds a line.\n\nLoom:\n\n# Changes\n\n# Notes for the reviewer\n\nNone: small.\n\n<!-- Describe how to test -->\n' \
    | description "file: add a line"
  describe stamp >/dev/null
  local out
  out="$(describe check 2>&1)" && fail "must fail: $out"
  grep -qF 'fail: the template section "How to test" is missing' <<<"$out" || fail "missing section: $out"
  grep -qF 'fail: the section "Changes" is empty' <<<"$out" || fail "empty section: $out"
  grep -qF 'fail: the line "Loom:" is empty' <<<"$out" || fail "empty label: $out"
  grep -qF 'fail: a template comment' <<<"$out" || fail "comment: $out"

  printf '# Changes\n\nOne line.\n\n# Summary\n\nAdds a line.\n\n# How to test\n\nRan the suite.\n\n# Notes for the reviewer\n\nNone: small.\n' \
    | description "file: add a line"
  describe stamp >/dev/null
  out="$(describe check 2>&1)" && fail "out of order must fail: $out"
  grep -qF 'not in the template order' <<<"$out" || fail "order: $out"

  printf '# Summary\n\nAdds a line.\n\n# Changes\n\nOne line.\n\n# How to test\n\nRan the suite.\n\n# Notes for the reviewer\n\nNone: small.\n' \
    | description "file: add a line"
  describe stamp >/dev/null
  out="$(describe check 2>&1)" || fail "complete: $out"
  grep -qF 'warn: the template line "Loom:" was dropped' <<<"$out" || fail "dropped label warns: $out"
}

@test "check: a beads id in the title or body fails; a hyphenated word that is not one passes" {
  mkdir -p .beads
  cat >"$BATS_TEST_TMPDIR/bin/bd" <<'SH'
#!/usr/bin/env bash
[[ "$*" == "list --all --json --limit 0" ]] && echo '[{"id": "repo-tj2"}, {"id": "repo-abc"}]'
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/bd"
  change
  evidence
  printf 'Adds a line, as repo-tj2 asks.\n\nThe repo-desk mod is unchanged.\n' | description "file: add a line"
  describe stamp >/dev/null
  local out
  out="$(describe check 2>&1)" && fail "a beads id must fail: $out"
  grep -qF 'fail: repo-tj2 is a beads id' <<<"$out" || fail "names it: $out"
  if grep -q 'repo-desk' <<<"$out"; then fail "repo-desk is not an id: $out"; fi
  plain_body | description "repo-abc: add a line"
  describe stamp >/dev/null
  describe check 2>&1 | grep -qF 'fail: repo-abc is a beads id' || fail "in the title too"
}

@test "check: a title over 72 characters fails; with commitlint the title must read type(scope): subject" {
  change
  evidence
  plain_body | description "$(printf 'x%.0s' {1..73})"
  describe stamp >/dev/null
  describe check 2>&1 | grep -qF 'fail: the title is 73 characters' || fail "long title"
  printf '{"extends": ["@commitlint/config-conventional"]}\n' >.commitlintrc.json
  git add .commitlintrc.json
  evidence
  plain_body | description "Add a line"
  describe stamp >/dev/null
  describe check 2>&1 | grep -qF 'Conventional Commits' || fail "conventional"
  plain_body | description "feat(file): add a line"
  describe stamp >/dev/null
  describe check >/dev/null 2>&1 || fail "a conventional title passes: $(describe check 2>&1)"
}

@test "title: a YAML-quoted title gives the subject a plain one does; a subject still in quotes fails" {
  local plain
  described
  plain="$(describe commit)"
  plain_body | description '"file: add a line"'
  describe stamp >/dev/null
  [[ "$(describe commit)" == "$plain" ]] || fail "double-quoted: $(describe commit 2>&1)"
  plain_body | description "'file: add a line'"
  describe stamp >/dev/null
  [[ "$(describe commit)" == "$plain" ]] || fail "single-quoted: $(describe commit 2>&1)"
  plain_body | description "'file''s line: say \"hi\"'"
  describe stamp >/dev/null
  [[ "$(describe title)" == "file's line: say \"hi\"" ]] || fail "single-quoted escape: $(describe title 2>&1)"
  plain_body | description '"file: say \"hi\""'
  describe stamp >/dev/null
  [[ "$(describe title)" == 'file: say "hi"' ]] || fail "double-quoted escape: $(describe title 2>&1)"
  plain_body | description '"\"file: add a line\""'
  describe stamp >/dev/null
  describe check 2>&1 | grep -qF 'fail: the title is in quotes' || fail "a quoted subject: $(describe check 2>&1)"
  describe commit >/dev/null 2>&1 && fail "commit printed a quoted subject"
  return 0
}

@test "check: a direct-commit repo uses commit style and no template" {
  leftlane_template
  described
  describe check 2>&1 | grep -qF 'the template section "Summary" is missing' || fail "pr style follows the template"
  printf 'integrate = "direct"\n' >.bercail/policy.toml
  describe check --json | jq -e '.style == "commit" and .template == null' >/dev/null || fail "commit style: $(describe check --json)"
  describe check >/dev/null 2>&1 || fail "a plain commit message passes: $(describe check 2>&1)"
  describe stamp >/dev/null
  if grep -q '^template:' .bercail/description.md; then fail "commit style records no template"; fi
}

@test "check: staged .bercail runtime files fail; a failing check and changes outside the index warn" {
  change
  evidence 1
  plain_body | description "file: add a line"
  describe stamp >/dev/null
  local out
  out="$(describe check 2>&1)" || fail "warnings do not fail: $out"
  grep -qF 'warn: the check `bash tests/run.sh` exited 1' <<<"$out" || fail "failing check: $out"
  printf 'scratch\n' >scratch.txt
  describe check 2>&1 | grep -qF 'warn: changes outside the index' || fail "untracked file"
  rm scratch.txt
  git add -f .bercail/description.md
  evidence 1
  describe stamp >/dev/null
  describe check 2>&1 | grep -qF 'fail: .bercail/ runtime files are staged' || fail "staged runtime file"
}

@test "title, body and commit print the text for git and the forges; with no description they say /validate" {
  described
  [[ "$(describe title)" == "file: add a line" ]] || fail "title"
  [[ "$(describe body)" == "$(plain_body)$NOBODY" ]] || fail "body"
  [[ "$(describe commit)" == "file: add a line"$'\n\n'"$(plain_body)$NOBODY" ]] || fail "commit: $(describe commit)"
  rm .bercail/description.md
  describe commit 2>&1 | grep -qF 'run /validate' && ! describe commit >/dev/null 2>&1 || fail "no description"
}

@test "provenance: the desk's recorded model, the reviewer only when given, the policy's form, never by hand" {
  local sessions="$XDG_STATE_HOME/bercail/desk-sessions"
  mkdir -p "$sessions"
  jq -n --arg c "$REPO" '{address: "t1", cwd: $c, harness: "pi", args: ["--model", "old/model-1:low"]}' >"$sessions/t1.json"
  touch -d '1 hour ago' "$sessions/t1.json"
  jq -n --arg c "$REPO" '{address: "t2", cwd: $c, harness: "pi", args: ["--model", "claude-bridge/claude-opus-5-5:high", "-e", "x"]}' >"$sessions/t2.json"
  jq -n '{address: "t3", cwd: "/elsewhere", harness: "pi", args: ["--model", "other/model"]}' >"$sessions/t3.json"
  described
  grep -qx 'agent: Pi, claude-opus-5-5' .bercail/description.md || fail "the newest record for this folder: $(cat .bercail/description.md)"
  [[ "$(describe body | tail -1)" == "Written with bercail (Pi, claude-opus-5-5); not yet reviewed" ]] || fail "line: $(describe body)"
  [[ "$(describe commit --reviewed-by Simon | tail -1)" == "Written with bercail (Pi, claude-opus-5-5); reviewed by Simon" ]] || fail "reviewed"
  printf 'provenance = "trailer"\n' >.bercail/policy.toml
  [[ "$(describe commit --reviewed-by Simon | tail -3)" == $'\nAssisted-by: bercail (Pi, claude-opus-5-5)\nReviewed-by: Simon' ]] \
    || fail "trailer: $(describe commit --reviewed-by Simon)"
  git commit -qF <(describe commit --reviewed-by Simon) || fail "commit"
  [[ "$(git log -1 --format='%(trailers:key=Assisted-by,valueonly)')" == "bercail (Pi, claude-opus-5-5)" ]] || fail "git reads the trailer"
  printf 'provenance = "none"\n' >.bercail/policy.toml
  [[ "$(describe body)" == "$(plain_body)" ]] || fail "none: $(describe body)"
  describe body --reviewed-by "" 2>&1 | grep -qF -- "--reviewed-by takes the reviewer's name" || fail "an empty reviewer"
  printf 'provenance = "always"\n' >.bercail/policy.toml
  "$ROOT/bin/bercail" policy show . 2>&1 | grep -qF 'provenance = "always" is not allowed' || fail "the policy says why"

  { plain_body; printf '\nWritten with bercail (Pi, gpt-6); reviewed by Simon\n'; } | description "file: add a line"
  change again
  evidence
  describe stamp >/dev/null
  describe check 2>&1 | grep -qF 'fail: a provenance line is written by hand' || fail "by hand: $(describe check 2>&1)"
}

# The policy in $1, committed, so it is no edit of its own.
committed_policy() {
  mkdir -p .bercail
  printf '%b' "$1" >.bercail/policy.toml
  git add -f .bercail/policy.toml && git commit -qm policy
}

@test "stakes: a staged path the policy's high_stakes names makes the change high-stakes, and stamp records it" {
  committed_policy 'high_stakes = """\nlib/\ninstall.sh\n"""\n'
  described
  grep -qx 'stakes: low' .bercail/description.md && grep -qx 'review: optional' .bercail/description.md \
    || fail "a path no glob names is low stakes: $(cat .bercail/description.md)"
  mkdir -p lib && printf 'x\n' >lib/policy.sh
  git add lib/policy.sh
  evidence
  describe stamp | grep -qx 'the change: 2 lines in 2 files, stakes high: lib/policy.sh; the person reviews it before it is committed or merged' \
    || fail "stamp says: $(describe stamp)"
  grep -qx 'stakes: high' .bercail/description.md && grep -qx 'review: required' .bercail/description.md \
    || fail "frontmatter: $(cat .bercail/description.md)"
}

@test "stakes: an edit to the policy file, staged or not, makes the change high-stakes" {
  committed_policy 'high_stakes = ["lib/"]\n'
  mkdir -p lib && printf 'x\n' >lib/a.sh
  git add lib/a.sh
  printf 'high_stakes = []\n' >.bercail/policy.toml
  describe check --json | jq -e '.change | .stakes == "high" and .high_stakes == [".bercail/policy.toml"] and .review == "required"' >/dev/null \
    || fail "an unstaged edit lowered the stakes: $(describe check --json | jq -c .change)"
  git add -f .bercail/policy.toml
  describe check --json | jq -e '.change.high_stakes == [".bercail/policy.toml"]' >/dev/null \
    || fail "a staged edit: $(describe check --json | jq -c .change)"
}

@test "stakes: once the change is committed, check measures it from the commit the stamp saw, never a made-up one" {
  local before after
  committed_policy 'integrate = "direct"\nhigh_stakes = ["file.txt"]\n'
  described
  before="$(describe check --json | jq -c .change)"
  # A base: that is no ancestor of HEAD, here a commit of the index itself, is ignored.
  sed -i "s/^base: .*/base: $(git commit-tree "$(git write-tree)" -p HEAD -m forged)/" .bercail/description.md
  [[ "$(describe check --json | jq -c .change)" == "$before" ]] || fail "a forged base lowered the stakes: $(describe check --json | jq -c .change)"
  describe stamp >/dev/null
  git commit -qF <(describe commit --reviewed-by Simon) || fail "commit"
  after="$(describe check --json | jq -c .change)"
  [[ "$after" == "$before" ]] || fail "the committed change: $after, staged it was $before"
  jq -e '.files == 1 and .lines == 1 and .stakes == "high"' <<<"$after" >/dev/null || fail "measured: $after"
  describe commit 2>&1 | grep -qF 'pass --reviewed-by' || fail "the gate holds after the commit: $(describe commit 2>&1)"

  printf 'integrate = "direct"\n' >.bercail/policy.toml
  git add -f .bercail/policy.toml
  change again
  evidence
  plain_body | description "file: add another line"
  describe stamp >/dev/null
  git commit -qF <(describe commit --reviewed-by Simon) || fail "commit the policy edit"
  describe check --json | jq -e '.change.high_stakes == [".bercail/policy.toml"]' >/dev/null \
    || fail "a committed policy edit lowered the stakes: $(describe check --json | jq -c .change)"
}

@test "stakes: review = always makes a low-stakes change wait for the person" {
  mkdir -p "$XDG_CONFIG_HOME/bercail"
  printf '[policy."%s"]\nreview = "always"\n' "$(pwd -P)" >"$XDG_CONFIG_HOME/bercail/config.toml"
  change
  describe check --json | jq -e '.change | .stakes == "low" and .review == "required"' >/dev/null \
    || fail "review always: $(describe check --json | jq -c .change)"
}

@test "size: a change over the diff budget warns and never fails; lockfiles, generated and binary files are left out" {
  local out
  mkdir -p .bercail
  printf 'diff_budget = 5\n' >.bercail/policy.toml
  printf 'gen.js linguist-generated\n' >.gitattributes
  seq 1 3 >notes.txt
  seq 1 90 >package-lock.json
  seq 1 90 >gen.js
  printf '\0\1\2' >logo.bin
  git add .gitattributes notes.txt package-lock.json gen.js logo.bin
  evidence
  plain_body | description "notes: add lines"
  describe stamp >/dev/null
  describe check --json | jq -e '.change | .lines == 4 and .files == 5 and .left_out == {files: 3, lines: 180} and .over_budget == false' >/dev/null \
    || fail "counted: $(describe check --json | jq -c .change)"
  [[ "$(describe check 2>&1)" != *"diff budget"* ]] || fail "4 lines warned: $(describe check 2>&1)"
  seq 4 5 >>notes.txt
  git add notes.txt
  evidence
  describe stamp >/dev/null
  out="$(describe check 2>&1)" || fail "over the budget failed the check: $out"
  grep -qx 'warn: the change is 6 lines added and removed, over the diff budget of 5 (lockfiles and generated files left out): split it, or say in the description why it is one change' <<<"$out" \
    || fail "no size warning: $out"
}

@test "commit: a change the person reviews first needs --reviewed-by where the repo commits straight to main" {
  local out
  committed_policy 'integrate = "direct"\nhigh_stakes = ["file.txt"]\n'
  described
  out="$(describe commit 2>&1)" && fail "commit printed a message for an unreviewed high-stakes change: $out"
  [[ "$out" == *'stakes high: file.txt; the person reviews it before it is committed or merged, and this repo commits straight to main: once they gave their LGTM, pass --reviewed-by "<their name>"' ]] \
    || fail "the refusal: $out"
  [[ "$(describe commit --reviewed-by Simon | tail -1)" == "Written with bercail; reviewed by Simon" ]] || fail "with the reviewer: $(describe commit --reviewed-by Simon 2>&1)"
  describe body >/dev/null || fail "body is not gated"
}

@test "commit: a PR repo's commit and a low-stakes change need no reviewer" {
  committed_policy 'integrate = "pr"\nhigh_stakes = ["file.txt"]\n'
  described
  describe commit >/dev/null || fail "a PR repo's commit is gated: the person reviews the PR"
  committed_policy 'integrate = "direct"\n'
  described
  describe commit >/dev/null || fail "a low-stakes change is gated: $(describe commit 2>&1)"
}

@test "--checkpoints: the branch's Entire-Checkpoint trailers survive a squash and a reworded amend, once each" {
  git commit -qm base --allow-empty
  local base
  base="$(git rev-parse HEAD)"
  git commit -q --allow-empty -m $'one\n\nEntire-Checkpoint: 01AAA'
  git commit -q --allow-empty -m $'two\n\nEntire-Checkpoint: 01BBB\nEntire-Checkpoint: 01AAA'
  git commit -q --allow-empty -m 'three, no agent'
  described
  [[ "$(describe body --checkpoints "$base")" == "$(plain_body)$NOBODY"$'\n\nEntire-Checkpoint: 01AAA\nEntire-Checkpoint: 01BBB' ]] \
    || fail "line form: $(describe body --checkpoints "$base")"
  [[ "$(describe body --checkpoints HEAD)" == "$(plain_body)$NOBODY" ]] || fail "nothing since HEAD"
  printf 'provenance = "trailer"\n' >.bercail/policy.toml
  git commit -qF <(describe commit --reviewed-by Simon --checkpoints "$base") || fail "commit"
  [[ "$(git log -1 --format='%(trailers:key=Entire-Checkpoint,valueonly,separator=%x20)')" == "01AAA 01BBB" ]] \
    || fail "git reads them in the provenance's block: $(git log -1 --format=%B)"
  [[ "$(git log -1 --format='%(trailers:key=Assisted-by,valueonly)')" == "bercail" ]] || fail "provenance kept"
  printf 'provenance = "none"\n' >.bercail/policy.toml
  [[ "$(describe body --checkpoints "$base")" == "$(plain_body)"$'\n\nEntire-Checkpoint: 01AAA\nEntire-Checkpoint: 01BBB' ]] \
    || fail "none: $(describe body --checkpoints "$base")"
  describe body --checkpoints nope 2>&1 | grep -qF -- '--checkpoints nope names no commit' || fail "a bad base"
  describe body --checkpoints 2>&1 | grep -qF -- '--checkpoints takes the base ref' || fail "no base"
}
