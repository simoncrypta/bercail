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
