#!/usr/bin/env bash
# shellcheck shell=bash
# Handoff worktrees must write to the main checkout's beads database.
# wt step copy-ignored (worktrunk pre-start) copies the gitignored Dolt store
# into the new worktree; bd then uses that copy. Both spawn paths have to
# point the worktree back at the main store without deleting the copy.
set -euo pipefail

unset BASH_ENV
export __MISE_BASH_ENV_LOADED=1
unset BEADS_DIR BD_BEADS_DIR HANDOFF_BD_BIN

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

comment_has() {
  local dir="$1" id="$2" needle="$3" text
  text="$(cd "$dir" && bd comments "$id" --json | jq -r '.[].text')"
  printf '%s' "$text" | grep -F -q "$needle" \
    || fail "missing comment [$needle] from $dir: $text"
}

# CI has no bd. This test needs the real one, so skip rather than fail there.
if ! command -v bd >/dev/null 2>&1; then
  printf 'SKIP: bd not found\n'
  exit 0
fi
command -v jq >/dev/null 2>&1 || fail "jq is required"

beads_dir_of() {
  (cd "$1" && bd context --json 2>/dev/null | jq -r '.beads_dir')
}

# The bug: a linked worktree whose .beads holds a copied Dolt store.
plant_copied_database() {
  local main="$1" wt="$2"
  git -C "$main" worktree add -q -b "$(basename "$wt")" "$wt"
  cp -a "$main/.beads/embeddeddolt" "$wt/.beads/embeddeddolt"
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

setup_repo() {
  local main="$1"
  git_init "$main"
  (cd "$main" && bd init --non-interactive --quiet --prefix beadwt >"$TMP_DIR/bd-init.log" 2>&1)
  git -C "$main" add -A
  git -C "$main" diff --cached --quiet || git -C "$main" commit -qm 'beads'
}

# Issue created after the copy, so only the main store has it.
new_issue() {
  local main="$1" title="$2"
  (cd "$main" && bd create "$title" -t task -p 2 --json -q) | jq -r '.id'
}

assert_shared() {
  local main="$1" wt="$2" id="$3" marker="$4" got
  got="$(beads_dir_of "$wt")"
  [[ "$got" == "$main/.beads" ]] || fail "bd context in $wt is $got, want $main/.beads"
  [[ -d "$wt/.beads/embeddeddolt" ]] || fail "copied database should be left in place: $wt"
  (cd "$wt" && bd comments add "$id" "$marker" -q >/dev/null)
  (cd "$main" && bd comments "$id") | grep -q "$marker" \
    || fail "comment from $wt did not land in the main store"
  local status
  status="$(git -C "$wt" status --porcelain)"
  [[ "$status" != *redirect* ]] || fail "redirect must stay gitignored: $status"
}

test_headless_spawn_uses_main_beads() {
  local main="$TMP_DIR/headless-main" wt="$TMP_DIR/headless-main.feat" id marker="headless-marker" stub
  setup_repo "$main"
  plant_copied_database "$main" "$wt"
  id="$(new_issue "$main" "headless job")"
  [[ "$(beads_dir_of "$wt")" == "$wt/.beads" ]] \
    || fail "precondition: copied store should shadow the main beads dir"

  stub="$TMP_DIR/bin/claude"
  mkdir -p "$TMP_DIR/bin"
  cat >"$stub" <<'STUB'
#!/usr/bin/env bash
jq -nc --arg sid "${BERCAIL_SESSION_ID:-none}" \
  '{status:"ready", summary:"ok", session_id:$sid}' >"$BERCAIL_RESULT_PATH"
STUB
  chmod +x "$stub"
  cat >"$TMP_DIR/catalog.json" <<'JSON'
{"catalog":{"config":{"models":[{"id":"claude-opus-5-5","name":"Opus 5.5"}]}}}
JSON

  (cd "$main" && HANDOFF_CLAUDE_BIN="$stub" BERCAIL_CLAUDE_MODEL_CATALOG="$TMP_DIR/catalog.json" \
    "$ROOT/skills/handoff/scripts/handoff-spawn" \
    --stage start --issue "$id" --worktree "$wt" >/dev/null)

  assert_shared "$main" "$wt" "$id" "$marker"
  comment_has "$main" "$id" "headless claude"
  printf 'PASS: headless spawn writes to the main checkout beads dir\n'
}

test_branch_spawn_uses_main_beads() {
  local main="$TMP_DIR/desk-main" wt="$TMP_DIR/desk-main.feat" id marker="desk-marker"
  local home bin fake_wt fake_herdr helper
  setup_repo "$main"
  id="$(new_issue "$main" "desk job")"

  home="$TMP_DIR/home"
  bin="$TMP_DIR/desk-bin"
  mkdir -p "$home/.config/worktrunk" "$bin"
  fake_wt="$bin/wt"
  fake_herdr="$bin/herdr-app"
  helper="$home/.config/worktrunk/herdr-layout.sh"

  # wt switch --create, plus the pre-start copy of the gitignored Dolt store.
  cat >"$fake_wt" <<'WT'
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
  chmod +x "$fake_wt"
  cat >"$fake_herdr" <<'HERDR'
#!/bin/sh
printf '%s\n' '{"space":"sp1"}'
HERDR
  chmod +x "$fake_herdr"
  cat >"$helper" <<'HELPER'
_wt_herdr_keep_user_focus() { :; }
_wt_generate_session_name() { printf 'Feat_Repo'; }
wt_herdr_handoff_agent() { return 0; }
_wt_herdr_space_by_folder() { printf 'sp1'; }
_wt_herdr_space_desk() { printf 'desk1'; }
HELPER
  printf '#!/bin/sh\nexit 0\n' >"$bin/claude"
  chmod +x "$bin/claude"

  (
    cd "$main"
    HOME="$home" PATH="$bin:$PATH" HERDR_APP_BIN="$fake_herdr" \
      "$ROOT/skills/handoff/scripts/handoff-spawn" \
      --branch feat --stage start --issue "$id" --clean >/dev/null
  )

  [[ -d "$wt" ]] || fail "spawn did not create $wt"
  assert_shared "$main" "$wt" "$id" "$marker"
  comment_has "$main" "$id" "desk agent claude"
  printf 'PASS: --branch spawn writes to the main checkout beads dir\n'
}

test_headless_spawn_uses_main_beads
test_branch_spawn_uses_main_beads
