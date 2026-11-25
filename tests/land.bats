#!/usr/bin/env bats
# bercail land: Shep commits a desk's described change and waits in the
# background for the branch's CI; the result reaches Shep's inbox as one land
# event (bercail-auev). Stand-ins for hc (runs the wait in the foreground) and
# gh (answers run list from $RUNS); a temp HOME.

setup() {
  load test_helper
  isolate
  need git jq
  set -o pipefail
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig" GIT_CONFIG_NOSYSTEM=1
  git config --global user.name test
  git config --global user.email test@example.com
  git config --global init.defaultBranch main
  unset BERCAIL_CONFIG
  export LOG="$BATS_TEST_TMPDIR/log" RUNS="$BATS_TEST_TMPDIR/runs.json"
  export PATH="$BATS_TEST_TMPDIR/bin:/usr/bin:/bin"
  export BERCAIL_ROLE=shep BERCAIL_LAND_POLL=0 BERCAIL_LAND_TIMEOUT=0
  : >"$LOG"
  # hc: logs its argv, then runs the command after -- where hc run would start it.
  cat >"$BATS_TEST_TMPDIR/bin/hc" <<'EOF'
#!/usr/bin/env bash
printf 'hc %s\n' "$*" >>"$LOG"
while [[ $# -gt 0 && "$1" != -- ]]; do shift; done
shift
"$@" >>"$LOG" 2>&1 || exit 1
printf '{"address":"t1","name":"land-x"}\n'
EOF
  # gh: run list prints $RUNS, and logs what it was asked.
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >>"$LOG"
[[ "$1 $2" == "run list" ]] || exit 1
cat "$RUNS"
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/"*
  INBOX="$XDG_STATE_HOME/bercail/shep/inbox"
  mkdir -p "$INBOX"
  REPO="$BATS_TEST_TMPDIR/repo"
  git_init "$REPO"
  git -C "$REPO" checkout -qb feature
  cd "$REPO" || return 1
}

land() { "$ROOT/bin/bercail" land "$@"; }

# A staged change with evidence and a stamped description titled $1.
described() {
  printf 'new\n' >>file.txt
  git add file.txt
  mkdir -p .bercail
  jq -n --arg t "$(git write-tree)" \
    '{tree: $t, checks: [{kind: "test", command: "bash tests/run.sh", exit_code: 0, evidence: "all passed"}]}' >.bercail/validate.json
  printf -- '---\ntitle: %s\n---\nAdds a line for readers of file.txt.\n\nValidation: bash tests/run.sh passed.\n' \
    "${1:-file: add a line}" >.bercail/description.md
  "$ROOT/bin/bercail" describe stamp >/dev/null || fail "stamp"
}

# CI runs for the commit, one per argument: name:status:conclusion.
runs() {
  local spec
  for spec in "$@"; do
    IFS=: read -r name status conclusion <<<"$spec"
    jq -nc --arg n "$name" --arg s "$status" --arg c "$conclusion" \
      '{databaseId: 1, name: $n, status: $s, conclusion: $c, url: "https://github.com/o/r/actions/runs/1"}'
  done | jq -s . >"$RUNS"
}

# A committed policy that integrates straight to the trunk, where land refuses a moved base.
direct() {
  mkdir -p .bercail
  printf 'integrate = "direct"\n' >.bercail/policy.toml
  git add -f .bercail/policy.toml && git commit -qm policy
}

# The one event in Shep's inbox.
event() {
  local files=("$INBOX"/*.json)
  [[ ${#files[@]} -eq 1 && -f "${files[0]}" ]] || fail "want one event in $INBOX: $(ls -A "$INBOX")" || return
  cat "${files[0]}"
}

@test "a green branch is committed with its described text and reaches Shep as ready" {
  described "file: add a line"
  runs CI:completed:success
  run land "$REPO"
  [ "$status" -eq 0 ] || fail "land: $output"
  [ "$(git log -1 --format=%s)" = "file: add a line" ] || fail "subject: $(git log -1 --format=%s)"
  git diff --cached --quiet || fail "the staged change was not committed"
  sha="$(git rev-parse HEAD)"
  grep -q "gh run list --commit $sha --branch feature --event push" "$LOG" || fail "gh not asked about the branch push: $(cat "$LOG")"
  grep -q -- "--label bercail.land_head=$sha" "$LOG" || fail "hc labels: $(cat "$LOG")"
  [[ "$output" == *"git -C $REPO push origin feature"* ]] || fail "no push step for Shep: $output"
  ev="$(event)" || return 1
  jq -e --arg sha "$sha" '.source == "bercail" and .kind == "land" and .land.status == "ready"
    and .land.head == $sha and .land.branch == "feature" and .space.checkout_path != null' <<<"$ev" >/dev/null \
    || fail "event: $ev"
  [[ "$(jq -r .text <<<"$ev")" == *"is ready to land: CI passed"*"git push origin $sha:main"* ]] || fail "text: $ev"
}

@test "in an Entire repo land commits and starts no CI wait: the trail's gates decide" {
  git -C "$REPO" remote add origin entire://aws-us-east-2.entire.io/et/acme/widgets
  described "file: add a line"
  run land "$REPO"
  [ "$status" -eq 0 ] || fail "land: $output"
  [ "$(git log -1 --format=%s)" = "file: add a line" ] || fail "subject: $(git log -1 --format=%s)"
  ! grep -q '^hc \|^gh ' "$LOG" || fail "a wait was started or gh asked: $(cat "$LOG")"
  [[ -z "$(ls -A "$INBOX")" ]] || fail "an event: $(ls -A "$INBOX")"
  [[ "$output" == *"no CI wait"*"trail's gates decide"*"entire trail show"* ]] || fail "no word on the gates: $output"
  [[ "$output" == *"git -C $REPO push origin feature"* ]] || fail "no push step for Shep: $output"
}

@test "an interrupted backend probe commits nothing and starts no wait" {
  git -C "$REPO" remote add origin https://origin.cursor.com/git/acme/widgets
  printf '#!/bin/sh\nexit 130\n' >"$BATS_TEST_TMPDIR/bin/origin"
  chmod +x "$BATS_TEST_TMPDIR/bin/origin"
  described
  head="$(git rev-parse HEAD)"
  run land "$REPO"
  [ "$status" -eq 130 ] || fail "want 130: $status $output"
  [ "$(git rev-parse HEAD)" = "$head" ] || fail "it committed"
  ! grep -q '^hc ' "$LOG" || fail "a wait was started: $(cat "$LOG")"
}

@test "on red CI no event says ready" {
  # Skipped or neutral alone is not a pass.
  for spec in "Lint:completed:success CI:completed:failure" "Lint:completed:success CI:completed:cancelled" \
    CI:completed:skipped CI:completed:neutral; do
    rm -f "$INBOX"/*.json
    # shellcheck disable=SC2086 # one run per word
    runs $spec
    run land --wait "$(git rev-parse HEAD)" "$REPO"
    [ "$status" -eq 0 ] || fail "wait: $output"
    ev="$(event)" || return 1
    jq -e '.land.status == "failed"' <<<"$ev" >/dev/null || fail "$spec: $ev"
    [[ "$(jq -r .text <<<"$ev")" != *ready* && "$(jq -r .text <<<"$ev")" == *"CI did not pass"*"Do not land it"* ]] \
      || fail "$spec text: $ev"
  done
}

@test "a green commit the branch has moved past is not ready" {
  runs CI:completed:success
  tested="$(git rev-parse HEAD)"
  git commit -q --allow-empty -m later
  run land --wait "$tested" "$REPO"
  [ "$status" -eq 0 ] || fail "wait: $output"
  ev="$(event)" || return 1
  jq -e '.land.status == "moved"' <<<"$ev" >/dev/null || fail "$ev"
  [[ "$(jq -r .text <<<"$ev")" != *"is ready"* && "$(jq -r .text <<<"$ev")" == *"Do not land it"* ]] || fail "text: $ev"
}

@test "a run still going, none at all, or no list from gh when time is up times out, never ready" {
  for spec in running none empty; do
    rm -f "$INBOX"/*.json
    case "$spec" in
      running) runs CI:in_progress: ;;
      none) printf '[]\n' >"$RUNS" ;;
      empty) : >"$RUNS" ;;
    esac
    run land --wait "$(git rev-parse HEAD)" "$REPO"
    [ "$status" -eq 0 ] || fail "$spec wait: $output"
    ev="$(event)" || return 1
    jq -e '.land.status == "timeout"' <<<"$ev" >/dev/null || fail "$spec: $ev"
    [[ "$(jq -r .text <<<"$ev")" == "No CI result for"*"Do not land it yet." ]] || fail "$spec text: $ev"
    [[ "$spec" != none || "$(jq -r .text <<<"$ev")" == *"is the branch pushed to origin?"* ]] || fail "no hint to push: $ev"
  done
}

@test "a desk running land is refused, and nothing is committed or waited on" {
  described
  head="$(git rev-parse HEAD)"
  for role in "" autopilot judge shep-bg; do
    BERCAIL_ROLE="$role" run land "$REPO"
    [ "$status" -ne 0 ] || fail "role '$role' landed"
    [[ "$output" == *"landing is Shep's"* ]] || fail "role '$role': $output"
    BERCAIL_ROLE="$role" run land --wait "$head" "$REPO"
    [ "$status" -ne 0 ] || fail "role '$role' started a wait"
  done
  [ "$(git rev-parse HEAD)" = "$head" ] || fail "a commit was made"
  [ ! -s "$LOG" ] || fail "hc or gh ran: $(cat "$LOG")"
}

@test "a stale description is refused before any commit" {
  described
  printf 'more\n' >>file.txt
  git add file.txt
  head="$(git rev-parse HEAD)"
  run land "$REPO"
  [ "$status" -ne 0 ] || fail "landed a stale description"
  [[ "$output" == *"stale"* ]] || fail "$output"
  [ "$(git rev-parse HEAD)" = "$head" ] || fail "a commit was made"
  [ ! -s "$LOG" ] || fail "hc or gh ran: $(cat "$LOG")"
}

@test "where the policy integrates direct, a trunk that moved past the change is refused before any commit, with /validate on the new base for the desk" {
  direct
  # The local trunk, then origin's as last fetched, one commit past the branch.
  base="$(git rev-parse HEAD)"
  for ref in refs/heads/main refs/remotes/origin/main; do
    described
    git update-ref "$ref" "$(git commit-tree -p "$base" -m later "$(git rev-parse "$base^{tree}")")"
    run land "$REPO"
    [ "$status" -ne 0 ] || fail "$ref: landed on a moved base: $output"
    [[ "$output" == *"the base moved: ${ref#refs/*/} has 1 commit(s)"*"rerun /validate"*"no commit was made"* ]] || fail "$ref: $output"
    [ "$(git rev-parse HEAD)" = "$base" ] || fail "$ref: a commit was made"
    ! git diff --cached --quiet || fail "$ref: the staged change is gone"
    [ ! -s "$LOG" ] || fail "$ref: hc or gh ran: $(cat "$LOG")"
    git update-ref "$ref" "$base"
    git reset -q --hard
  done
}

@test "where the policy integrates direct, a trunk that moves while land reads it is refused, not only warned of" {
  direct
  described
  head="$(git rev-parse HEAD)"
  # git: after the first count of the trunk's commits HEAD is not on, the trunk moves.
  cat >"$BATS_TEST_TMPDIR/bin/git" <<'GIT'
#!/usr/bin/env bash
/usr/bin/git "$@"
rc=$?
if [[ "$*" == *"rev-list --count HEAD..refs/heads/main" && ! -e "$BATS_TEST_TMPDIR/moved" ]]; then
  : >"$BATS_TEST_TMPDIR/moved"
  /usr/bin/git update-ref refs/heads/main "$(/usr/bin/git commit-tree -p main -m later "$(/usr/bin/git rev-parse 'main^{tree}')")"
fi
exit "$rc"
GIT
  chmod +x "$BATS_TEST_TMPDIR/bin/git"
  run land "$REPO"
  [ -e "$BATS_TEST_TMPDIR/moved" ] || fail "the trunk never moved: $output"
  [ "$status" -ne 0 ] || fail "landed on a trunk that moved: $output"
  [[ "$output" == *"refusing to commit: the base moved: main has 1 commit(s)"* ]] || fail "$output"
  [ "$(git rev-parse HEAD)" = "$head" ] || fail "a commit was made"
  [ ! -s "$LOG" ] || fail "hc or gh ran: $(cat "$LOG")"
}

@test "where the policy integrates direct, a rerun after the commit is refused once the trunk moved past it, and starts no wait" {
  direct
  described
  runs CI:completed:success
  land "$REPO" >/dev/null || fail "first land"
  head="$(git rev-parse HEAD)"
  : >"$LOG"
  git update-ref refs/heads/main "$(git commit-tree -p main -m later "$(git rev-parse 'main^{tree}')")"
  run land "$REPO"
  [ "$status" -ne 0 ] || fail "rerun on a moved base: $output"
  [[ "$output" == *"the base moved: main has 1 commit(s)"* ]] || fail "$output"
  [ "$(git rev-parse HEAD)" = "$head" ] || fail "a commit was made"
  [ ! -s "$LOG" ] || fail "hc or gh ran: $(cat "$LOG")"
}

@test "a PR branch whose trunk moved is committed with a warning and waited on: the PR's merge checks it" {
  base="$(git rev-parse HEAD)"
  # No policy (the default), then integrate = "pr".
  for policy in "" 'integrate = "pr"'; do
    mkdir -p .bercail
    printf '%s\n' "$policy" >.bercail/policy.toml
    described
    runs CI:completed:success
    git update-ref refs/heads/main "$(git commit-tree -p "$base" -m later "$(git rev-parse "$base^{tree}")")"
    run land "$REPO"
    [ "$status" -eq 0 ] || fail "${policy:-default}: refused: $output"
    [[ "$output" == *"warn: the base moved: main has 1 commit(s)"* ]] || fail "${policy:-default}: no warning: $output"
    [ "$(git rev-parse HEAD^)" = "$base" ] || fail "${policy:-default}: no commit was made"
    grep -q '^hc run' "$LOG" || fail "${policy:-default}: no wait started: $(cat "$LOG")"
    git reset -q --hard "$base"
    git update-ref refs/heads/main "$base"
    : >"$LOG"
  done
}

@test "where the policy integrates direct, a staged merge of the trunk's tip is on the trunk: committed as the merge, no moved base" {
  direct
  git branch -f main HEAD
  base="$(git rev-parse HEAD)"
  git checkout -q main
  printf 'trunk\n' >trunk.txt && git add trunk.txt && git commit -qm trunk
  git checkout -q feature
  git merge -q --no-commit --no-ff main
  described
  runs CI:completed:success
  run land "$REPO"
  [ "$status" -eq 0 ] || fail "refused: $output"
  [[ "$output" != *"base moved"* ]] || fail "called the base moved: $output"
  [ "$(git rev-parse HEAD^1) $(git rev-parse HEAD^2)" = "$base $(git rev-parse main)" ] || fail "not the merge: $(git log --format='%H %P' -1)"
}

@test "a staged merge of the trunk whose tree is HEAD's is still committed as the merge, never taken as already landed" {
  direct
  git branch -f main HEAD
  # Both sides make the same edit, so the merge's tree is HEAD's.
  printf 'same\n' >>file.txt && git commit -qam same
  base="$(git rev-parse HEAD)"
  git checkout -q main
  printf 'same\n' >>file.txt && git commit -qam 'same on the trunk'
  git checkout -q feature
  git merge -q --no-commit --no-ff main
  [ "$(git write-tree)" = "$(git rev-parse 'HEAD^{tree}')" ] || fail "the merge changed the tree"
  jq -n --arg t "$(git write-tree)" \
    '{tree: $t, checks: [{kind: "test", command: "bash tests/run.sh", exit_code: 0, evidence: "all passed"}]}' >.bercail/validate.json
  printf -- '---\ntitle: merge the trunk\n---\nBrings the branch onto the trunk.\n\nValidation: bash tests/run.sh passed.\n' >.bercail/description.md
  "$ROOT/bin/bercail" describe stamp >/dev/null || fail "stamp"
  runs CI:completed:success
  run land "$REPO"
  [ "$status" -eq 0 ] || fail "refused: $output"
  [[ "$output" != *"no new commit"* ]] || fail "took the merge as landed: $output"
  [ "$(git rev-parse HEAD^1) $(git rev-parse HEAD^2)" = "$base $(git rev-parse main)" ] || fail "not the merge: $(git log --format='%H %P' -1)"
}

@test "a described change on the trunk itself is refused: it has no branch CI to wait for" {
  git checkout -q main
  described
  head="$(git rev-parse HEAD)"
  run land "$REPO"
  [ "$status" -ne 0 ] || fail "landed on main"
  [[ "$output" == *"is on main itself"* ]] || fail "$output"
  [ "$(git rev-parse HEAD)" = "$head" ] || fail "a commit was made"
  [ ! -s "$LOG" ] || fail "hc or gh ran: $(cat "$LOG")"
}

@test "a rerun after the commit waits on HEAD without a second commit" {
  described
  runs CI:completed:success
  land "$REPO" >/dev/null || fail "first land"
  head="$(git rev-parse HEAD)"
  rm -f "$INBOX"/*.json
  run land "$REPO"
  [ "$status" -eq 0 ] || fail "rerun: $output"
  [[ "$output" == *"no new commit"* ]] || fail "$output"
  [ "$(git rev-parse HEAD)" = "$head" ] || fail "a second commit was made"
  jq -e '.land.status == "ready"' <<<"$(event)" >/dev/null || fail "no ready event on the rerun"
}
