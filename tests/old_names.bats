#!/usr/bin/env bats
# What an update does with the names bercail left behind at v1:
# ~/.local/state/agentic-dev, where the handoff log lived, and the agentic-dev command.

# shellcheck disable=SC2034 # DRY_RUN and LOCAL_BIN are read by the sourced libs.
# The libs define their own run(), so these tests capture output by hand.

setup() {
  load test_helper
  isolate
  # shellcheck source=/dev/null
  source "$ROOT/lib/common.sh"
  # shellcheck source=/dev/null
  source "$ROOT/lib/config.sh"
  DRY_RUN=0
  OLD="$XDG_STATE_HOME/agentic-dev" NEW="$XDG_STATE_HOME/bercail"
  REPO="$BATS_TEST_TMPDIR/repo"
  LOCAL_BIN="$HOME/.local/bin"
  mkdir -p "$OLD" "$REPO" "$REPO.feat" "$LOCAL_BIN"
}

# A handoff record for PATH on BRANCH, as releases before v1 wrote it.
record() {
  jq -nc --arg path "$1" --arg branch "${2:-}" --arg issue "${3:-}" '{ok: true, path: $path, branch: $branch, issue: $issue}'
}

@test "an update moves the handoff log to bercail's state dir and links the old path to it" {
  record "$REPO.feat" feat a-1 >"$OLD/handoffs.jsonl"
  mkdir "$OLD/handoff-prompts"
  migrate_state_dir
  [[ "$(jq -r .issue "$NEW/handoffs.jsonl")" == a-1 ]] || fail "the record did not move: $(cat "$NEW/handoffs.jsonl" 2>&1)"
  [[ -d "$NEW/handoff-prompts" ]] || fail "handoff-prompts did not move"
  [[ -L "$OLD" && "$OLD" -ef "$NEW" ]] || fail "$OLD is not a link to $NEW"
}

@test "a record appended through the old path after the move lands in the new log" {
  record "$REPO.feat" feat a-1 >"$OLD/handoffs.jsonl"
  migrate_state_dir
  record "$REPO.feat" feat a-2 >>"$OLD/handoffs.jsonl"
  [[ "$(jq -r .issue "$NEW/handoffs.jsonl" | tr '\n' ' ')" == "a-1 a-2 " ]] || fail "new log: $(cat "$NEW/handoffs.jsonl")"
}

@test "the move keeps bercail's own state and puts the old records before the new ones" {
  mkdir -p "$NEW/shep"
  echo kept >"$NEW/shep/preferences.md"
  record "$REPO.feat" feat new-1 >"$NEW/handoffs.jsonl"
  record "$REPO.feat" feat old-1 >"$OLD/handoffs.jsonl"
  migrate_state_dir
  [[ "$(jq -r .issue "$NEW/handoffs.jsonl" | tr '\n' ' ')" == "old-1 new-1 " ]] || fail "new log: $(cat "$NEW/handoffs.jsonl")"
  [[ "$(cat "$NEW/shep/preferences.md")" == kept ]] || fail "bercail's state changed"
  [[ -L "$OLD" ]] || fail "$OLD is not a link"
}

@test "a second update leaves the moved log and the link as they are" {
  record "$REPO.feat" feat a-1 >"$OLD/handoffs.jsonl"
  migrate_state_dir
  local before
  before="$(sha256sum <"$NEW/handoffs.jsonl")"
  out="$(migrate_state_dir 2>&1)" || fail "second run failed: $out"
  [[ -z "$out" ]] || fail "second run: $out"
  [[ "$(sha256sum <"$NEW/handoffs.jsonl")" == "$before" && -L "$OLD" ]] || fail "the second run changed the log or the link"
}

@test "the move drops the records no reader can use: no folder, or not a record" {
  {
    record "$REPO.feat" feat live
    record "$REPO.gone" gone main-only
    record "$BATS_TEST_TMPDIR/nowhere.x" x dead
    echo 'not json'
    echo '{"ok":true}'
  } >"$OLD/handoffs.jsonl"
  out="$(migrate_state_dir 2>&1)" || fail "the move failed: $out"
  [[ "$(jq -r .issue "$NEW/handoffs.jsonl" | tr '\n' ' ')" == "live main-only " ]] || fail "kept: $(cat "$NEW/handoffs.jsonl")"
  [[ "$out" == *"dropped 3 "* ]] || fail "the update did not say what it dropped: $out"
}

@test "a name both dirs hold stays in the old dir, and the update says so" {
  record "$REPO.feat" feat a-1 >"$OLD/handoffs.jsonl"
  mkdir -p "$NEW"
  echo ours >"$NEW/notes"
  echo theirs >"$OLD/notes"
  out="$(migrate_state_dir 2>&1)" || fail "the move failed: $out"
  [[ "$(cat "$NEW/notes")" == ours && "$(cat "$OLD/notes")" == theirs ]] || fail "a file was overwritten or lost"
  [[ -f "$NEW/handoffs.jsonl" && ! -e "$OLD/handoffs.jsonl" ]] || fail "the log did not move"
  [[ "$out" == *"$OLD"* && "$out" == *notes* ]] || fail "the update did not name what is left: $out"
}

@test "a dry run moves nothing" {
  record "$REPO.feat" feat a-1 >"$OLD/handoffs.jsonl"
  out="$(DRY_RUN=1 migrate_state_dir 2>&1)" || fail "the dry run failed: $out"
  [[ -f "$OLD/handoffs.jsonl" && ! -L "$OLD" && ! -e "$NEW/handoffs.jsonl" ]] || fail "a dry run changed the state dirs: $out"
}

@test "an update removes the agentic-dev command an older release installed" {
  cp "$ROOT/bin/agentic-dev" "$LOCAL_BIN/agentic-dev"
  remove_agentic_dev_shim >/dev/null
  [[ ! -e "$LOCAL_BIN/agentic-dev" ]] || fail "the shim is still there"
}

@test "an update leaves a file named agentic-dev that is not bercail's" {
  printf '#!/bin/sh\necho mine\n' >"$LOCAL_BIN/agentic-dev"
  remove_agentic_dev_shim >/dev/null
  [[ "$(sh "$LOCAL_BIN/agentic-dev")" == mine ]] || fail "someone else's agentic-dev was removed"
}
