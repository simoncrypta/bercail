#!/usr/bin/env bats
# Handoff worktrees must write to the main checkout's beads database.
# wt step copy-ignored (worktrunk pre-start) copies the gitignored Dolt store
# into the new worktree; bd then uses that copy. Both spawn paths have to
# point the worktree back at the main store without deleting the copy.
#
# Two kinds of test. On the real bd: bd follows the redirect bercail writes,
# which a fake can't prove. On a fake bd: what bercail hands bd from the
# worktree (the redirect, cwd, argv, env) and the handoff log, everywhere.

setup() {
  load test_helper
  isolate
  command -v jq >/dev/null 2>&1 || fail "jq is required"
  main="$BATS_TEST_TMPDIR/main"
  wt="$BATS_TEST_TMPDIR/main.feat"
}

# The real bd and a fresh store in the main checkout. CI installs bd, so there
# a missing one fails instead of skipping.
real_bd() {
  if ! command -v bd >/dev/null 2>&1; then
    [[ -z "${CI:-}" ]] || fail "bd not found; CI must install it (.github/workflows/ci.yml)"
    skip "bd not found"
  fi
  git_init "$main"
  (cd "$main" && bd init --non-interactive --quiet --prefix beadwt >/dev/null 2>&1)
  git -C "$main" add -A
  git -C "$main" diff --cached --quiet || git -C "$main" commit -qm 'beads'
}

# A bd that resolves its store as bd does for these cases: .beads/redirect,
# else a copied store in this checkout, else the main checkout's. Issue ids
# live in <store>/issues, comments in <store>/comments. Each call logs
# cwd, argv and BEADS_DIR to $BD_CALLS.
fake_bd() {
  local bin="$BATS_TEST_TMPDIR/fake-bd"
  mkdir -p "$bin"
  cat >"$bin/bd" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
jq -nc --arg cwd "$PWD" --arg beads_dir "${BEADS_DIR:-}" '{cwd:$cwd, beads_dir:$beads_dir, argv:$ARGS.positional}' \
  --args -- "$@" >>"$BD_CALLS"
if [[ -f .beads/redirect ]]; then
  store="$(cat .beads/redirect)"
elif [[ -d .beads/embeddeddolt ]]; then
  store="$PWD/.beads"
else
  store="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")/.beads"
fi
case "$1" in
  context) jq -nc --arg d "$store" '{beads_dir:$d}' ;;
  show) grep -qxF "$2" "$store/issues" 2>/dev/null && jq -nc --arg id "$2" '[{id:$id, title:"a job"}]' ;;
  comment) [[ "${3:-}" == --stdin ]] && printf '%s\t%s\n' "$2" "$(cat)" >>"$store/comments" ;;
  *) exit 2 ;;
esac
STUB
  chmod +x "$bin/bd"
  export PATH="$bin:$PATH" BD_CALLS="$BATS_TEST_TMPDIR/bd-calls"
  git_init "$main"
  mkdir -p "$main/.beads/embeddeddolt"
  printf '*\n!.gitignore\n' >"$main/.beads/.gitignore"
  git -C "$main" add -A
  git -C "$main" commit -qm 'beads'
}

git_init() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" config user.email test@example.com
  git -C "$dir" config user.name test
  printf 'base\n' >"$dir/file.txt"
  git -C "$dir" add file.txt
  git -C "$dir" commit -qm base
}

beads_dir_of() {
  (cd "$1" && bd context --json 2>/dev/null | jq -r '.beads_dir')
}

# Issue created after the copy, so only the main store has it. On the fake bd
# (fake_bd set BD_CALLS) an issue is a line in the main store's issues file.
new_issue() {
  if [[ -n "${BD_CALLS:-}" ]]; then
    printf 'beadwt-1\n' | tee -a "$main/.beads/issues"
    return
  fi
  (cd "$main" && bd create "$1" -t task -p 2 --json -q) | jq -r '.id'
}

comment_has() {
  local dir="$1" id="$2" needle="$3" text
  text="$(cd "$dir" && bd comments "$id" --json | jq -r '.[].text')"
  printf '%s' "$text" | grep -F -q "$needle" \
    || fail "missing comment [$needle] from $dir: $text"
}

# The worktree's bd reads and writes the main store, and keeps its copy.
assert_shared() {
  local id="$1" marker="$2" got status
  got="$(beads_dir_of "$wt")"
  [[ "$got" == "$main/.beads" ]] || fail "bd context in $wt is $got, want $main/.beads"
  [[ -d "$wt/.beads/embeddeddolt" ]] || fail "copied database should be left in place: $wt"
  (cd "$wt" && bd comments add "$id" "$marker" -q >/dev/null)
  (cd "$main" && bd comments "$id") | grep -q "$marker" \
    || fail "comment from $wt did not land in the main store"
  status="$(git -C "$wt" status --porcelain)"
  [[ "$status" != *redirect* ]] || fail "redirect must stay gitignored: $status"
}

# A linked worktree whose .beads holds a copied Dolt store, then a headless spawn.
spawn_headless() {
  local stub="$BATS_TEST_TMPDIR/bin/pi" profile="$BATS_TEST_TMPDIR/pi-profile"
  git -C "$main" worktree add -q -b feat "$wt"
  cp -a "$main/.beads/embeddeddolt" "$wt/.beads/embeddeddolt"
  id="$(new_issue "headless job")"
  [[ "$(beads_dir_of "$wt")" == "$wt/.beads" ]] \
    || fail "precondition: copied store should shadow the main beads dir"
  mkdir -p "${stub%/*}" "$profile/extensions" "$profile/agents"
  printf '// guard\n' >"$profile/extensions/guard.ts"
  jq -n --arg guard "$profile/extensions/guard.ts" --arg model "claude-bridge/lead-model:high" \
    '["pi","--model",$model,"-e","npm:pi-claude-bridge@0.11.0","-e",$guard]' >"$profile/lead.json"
  cat >"$stub" <<'STUB'
#!/usr/bin/env bash
jq -nc --arg sid "${BERCAIL_SESSION_ID:-none}" \
  '{status:"ready", summary:"ok", session_id:$sid}' >"$BERCAIL_RESULT_PATH"
STUB
  chmod +x "$stub"
  (cd "$main" && HANDOFF_PI_BIN="$stub" HANDOFF_PI_PROFILE="$profile" \
    "$ROOT/skills/handoff/scripts/handoff-spawn" \
    --stage bstack --issue "$id" --worktree "$wt" >/dev/null)
}

# wt switch --create with worktrunk's pre-start copy of the Dolt store, then a --branch spawn.
spawn_branch() {
  local bin="$BATS_TEST_TMPDIR/desk-bin"
  mkdir -p "$HOME/.config/worktrunk" "$bin"
  id="$(new_issue "desk job")"
  cat >"$bin/wt" <<'WT'
#!/usr/bin/env bash
set -euo pipefail
branch=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --create) branch="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "$branch" ]] || exit 1
main="$(git worktree list --porcelain | awk '/^worktree / { print substr($0, 10); exit }')"
dest="${main}.${branch}"
git -C "$main" worktree add -q -b "$branch" "$dest"
cp -a "$main/.beads/embeddeddolt" "$dest/.beads/embeddeddolt"
WT
  cat >"$bin/herdr-app" <<'HERDR'
#!/bin/sh
printf '%s\n' '{"space":"sp1"}'
HERDR
  chmod +x "$bin/wt" "$bin/herdr-app"
  cat >"$HOME/.config/worktrunk/herdr-layout.sh" <<'HELPER'
_wt_herdr_keep_user_focus() { :; }
_wt_generate_session_name() { printf 'Feat_Repo'; }
wt_herdr_handoff_agent() { return 0; }
_wt_herdr_space_by_folder() { printf 'sp1'; }
_wt_herdr_space_desk() { printf 'desk1'; }
HELPER
  mkdir -p "$XDG_CONFIG_HOME/bercail" "$HOME/.local/share/bercail/pi/extensions"
  printf '[bstack]\nenabled = true\n' >"$XDG_CONFIG_HOME/bercail/config.toml"
  printf '// guard\n' >"$HOME/.local/share/bercail/pi/extensions/guard.ts"
  jq -n --arg guard "$HOME/.local/share/bercail/pi/extensions/guard.ts" --arg model "claude-bridge/lead-model:high" \
    '["pi","--model",$model,"-e","npm:pi-claude-bridge@0.11.0","-e",$guard]' \
    >"$HOME/.local/share/bercail/pi/lead.json"
  (cd "$main" && PATH="$bin:$PATH" HERDR_APP_BIN="$bin/herdr-app" \
    "$ROOT/skills/handoff/scripts/handoff-spawn" \
    --branch feat --stage bstack --issue "$id" --clean >/dev/null)
  [[ -d "$wt" ]] || fail "spawn did not create $wt"
}

@test "headless spawn: the worktree writes to the main checkout's beads store" {
  real_bd
  spawn_headless
  assert_shared "$id" headless-marker
  comment_has "$main" "$id" "headless pi"
}

@test "--branch spawn: the worktree writes to the main checkout's beads store" {
  real_bd
  spawn_branch
  assert_shared "$id" desk-marker
  comment_has "$main" "$id" "desk agent pi"
}

# What bercail hands bd from the worktree, on the fake: the store it resolves
# there is the main one, it keeps the copy, and it calls bd in the worktree
# with no BEADS_DIR override.
assert_handed_main_store() {
  local store calls
  store="$(cd "$main" && pwd -P)/.beads"
  [[ "$(cat "$wt/.beads/redirect" 2>/dev/null)" == "$store" ]] \
    || fail "redirect in $wt/.beads should hold $store: $(cat "$wt/.beads/redirect" 2>&1)"
  [[ -d "$wt/.beads/embeddeddolt" ]] || fail "copied database should be left in place: $wt"
  calls="$(jq -c --arg wt "$(cd "$wt" && pwd -P)" 'select(.cwd == $wt)' "$BD_CALLS")"
  [[ -n "$calls" ]] || fail "no bd call ran in $wt: $(cat "$BD_CALLS")"
  jq -se 'all(.beads_dir == "")' <<<"$calls" >/dev/null || fail "BEADS_DIR passed to bd: $calls"
  jq -se --arg id "$id" 'any(.argv == ["comment", $id, "--stdin"])' <<<"$calls" >/dev/null \
    || fail "the handoff comment was not bd comment $id --stdin in $wt: $calls"
  [[ ! -e "$wt/.beads/comments" ]] || fail "a comment went to the copied store: $(cat "$wt/.beads/comments")"
}

@test "headless spawn: bd in the worktree gets the main store, the issue, and the comment" {
  fake_bd
  spawn_headless
  assert_handed_main_store
  jq -e '.status == "ready"' "$wt/.bercail/handoff-result.json" >/dev/null \
    || fail "the issue should be found through the main store: $(cat "$wt/.bercail/handoff-result.json")"
  jq -se --arg id "$id" --arg wt "$(cd "$wt" && pwd -P)" 'any(.cwd == $wt and .argv == ["show", $id, "--json"])' "$BD_CALLS" >/dev/null \
    || fail "no bd show $id --json in $wt: $(cat "$BD_CALLS")"
  grep -F "$id" "$main/.beads/comments" | grep -q 'headless pi' \
    || fail "the headless comment should land in the main store: $(cat "$main/.beads/comments" 2>&1)"
}

@test "--branch spawn: the handoff comment goes from the worktree to the main store" {
  fake_bd
  spawn_branch
  assert_handed_main_store
  grep -F "$id" "$main/.beads/comments" | grep -q 'desk agent pi' \
    || fail "the handoff comment should land in the main store: $(cat "$main/.beads/comments" 2>&1)"
}

@test "--branch spawn: logs the issue to handoffs.jsonl under XDG_STATE_HOME" {
  fake_bd
  spawn_branch
  jq -e --arg id "$id" 'select(.issue == $id)' "$XDG_STATE_HOME/agentic-dev/handoffs.jsonl" >/dev/null \
    || fail "no line for $id in $XDG_STATE_HOME/agentic-dev/handoffs.jsonl"
}
