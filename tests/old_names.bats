#!/usr/bin/env bats
# What an update does with the names bercail left behind at v1:
# ~/.local/state/agentic-dev, where the handoff log lived, the agentic-dev
# command, [graphite] in config.toml, and workspaces in a notify sink.

# shellcheck disable=SC2034 # DRY_RUN and LOCAL_BIN are read by the sourced libs.
# The libs define their own run(), so these tests capture output by hand.

setup() {
  load test_helper
  isolate
  # shellcheck source=/dev/null
  source "$ROOT/lib/common.sh"
  # shellcheck source=/dev/null
  source "$ROOT/lib/config.sh"
  # shellcheck source=/dev/null
  source "$ROOT/lib/git-backend.sh"
  # shellcheck source=/dev/null
  source "$ROOT/lib/notify.sh"
  DRY_RUN=0
  CONFIG="$BERCAIL_USER_CONFIG"
  SINKS="$XDG_CONFIG_HOME/bercail/notify.d"
  mkdir -p "$SINKS"
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

@test "an update moves [graphite] true and false to [git] gt and gh" {
  local stacks="$BATS_TEST_TMPDIR/stacks" plain="$BATS_TEST_TMPDIR/plain"
  git init -q "$stacks"
  git init -q "$plain"
  cat >"$CONFIG" <<EOF
[layout]
review = "tuicr"

[graphite] # by main checkout
"$stacks" = true   # no stack right now
'$plain' = false

[shep]
rollover = 1
EOF
  migrate_graphite_config >/dev/null
  [[ "$(git_backend "$stacks")" == gt && "$(git_backend "$plain")" == gh ]] \
    || fail "the backends changed: $(git_backend "$stacks") $(git_backend "$plain")"
  grep -q graphite "$CONFIG" && fail "[graphite] is still there: $(cat "$CONFIG")"
  grep -qF "\"$stacks\" = \"gt\"   # no stack right now" "$CONFIG" || fail "the entry lost its comment: $(cat "$CONFIG")"
  [[ "$(grep -A1 -e '^\[layout\]' -e '^\[shep\]' "$CONFIG" | grep -v '^--')" == '[layout]
review = "tuicr"
[shep]
rollover = 1' ]] || fail "the other sections changed: $(cat "$CONFIG")"
}

@test "a repo [git] already names keeps its entry when [graphite] moves" {
  local both="$BATS_TEST_TMPDIR/both" only="$BATS_TEST_TMPDIR/only"
  git init -q "$both"
  git init -q "$only"
  cat >"$CONFIG" <<EOF
[graphite]
"$both" = true
"$only" = true
# why these are here
"$BATS_TEST_TMPDIR/typo" = yes

[git]
"$both" = "origin"

[shep]
rollover = 1
EOF
  migrate_graphite_config >/dev/null
  [[ "$(git_backend "$both")" == origin ]] || fail "[git] lost to [graphite]: $(cat "$CONFIG")"
  [[ "$(git_backend "$only")" == gt ]] || fail "the [graphite] entry did not move: $(cat "$CONFIG")"
  [[ "$(grep -cF "\"$both\"" "$CONFIG")" == 1 ]] || fail "a repo is named twice: $(cat "$CONFIG")"
  [[ "$(sed -n '/^\[git\]/,/^\[shep\]/p' "$CONFIG")" == "[git]
\"$both\" = \"origin\"
\"$only\" = \"gt\"

[shep]" ]] || fail "the moved entry is not at the end of [git]: $(cat "$CONFIG")"
  # What the rewrite cannot read as true or false stays where it was.
  grep -qx '\[graphite\]' "$CONFIG" && grep -qF 'typo" = yes' "$CONFIG" || fail "an entry was lost: $(cat "$CONFIG")"
}

@test "a second update, a config with no [graphite], and a dry run change nothing" {
  local repo="$BATS_TEST_TMPDIR/again" dotfiles="$BATS_TEST_TMPDIR/dotfiles.toml" out
  git init -q "$repo"
  printf '[graphite]\n"%s" = true\n' "$repo" >"$dotfiles"
  ln -s "$dotfiles" "$CONFIG"
  cp "$dotfiles" "$BATS_TEST_TMPDIR/before"
  out="$(DRY_RUN=1 migrate_graphite_config 2>&1)" || fail "the dry run failed: $out"
  cmp -s "$dotfiles" "$BATS_TEST_TMPDIR/before" || fail "a dry run rewrote the config"
  [[ "$out" == *"would move the [graphite] entries"* ]] || fail "the dry run did not say what it would do: $out"

  migrate_graphite_config >/dev/null
  [[ -L "$CONFIG" ]] || fail "the config was a link into someone's dotfiles and is now a file"
  cp "$dotfiles" "$BATS_TEST_TMPDIR/after"
  out="$(migrate_graphite_config 2>&1)"
  cmp -s "$dotfiles" "$BATS_TEST_TMPDIR/after" || fail "the second run rewrote the config"
  [[ -z "$out" ]] || fail "the second run reported a move: $out"
}

@test "an update renames workspaces to spaces in a sink and keeps its mode" {
  local sink="$SINKS/old.toml"
  printf 'url = "https://example.invalid/hook"\nkey = "s3cret"\nworkspaces = "*_Other"\n' >"$sink"
  chmod 600 "$sink"
  notify_rename_workspaces >/dev/null
  [[ "$(notify_sink_value "$sink" spaces)" == '*_Other' ]] || fail "the filter was lost: $(cat "$sink")"
  grep -q workspaces "$sink" && fail "workspaces is still there: $(cat "$sink")"
  [[ "$(stat -c %a "$sink")" == 600 ]] || fail "a sink that holds a key changed mode"
  notify_sink_wants "$sink" finished '{"name":"repo_Other"}' || fail "the sink no longer takes the space it filtered for"
  notify_sink_wants "$sink" finished '{"name":"repo_Mine"}' && fail "the sink takes a space it filtered out"
  cp "$sink" "$BATS_TEST_TMPDIR/after"
  notify_rename_workspaces >/dev/null
  cmp -s "$sink" "$BATS_TEST_TMPDIR/after" || fail "the second run rewrote the sink"
}

@test "a sink that set both keeps spaces, which was the one read" {
  local sink="$SINKS/both.toml" empty="$SINKS/empty.toml"
  printf 'url = "https://example.invalid/a"\nspaces = "new_*"\nworkspaces = "old_*"\n' >"$sink"
  printf 'url = "https://example.invalid/b"\nspaces = ""\nworkspaces = "old_*"\n' >"$empty"
  notify_rename_workspaces >/dev/null
  [[ "$(grep spaces "$sink")" == 'spaces = "new_*"' ]] || fail "both set: $(cat "$sink")"
  [[ "$(grep spaces "$empty")" == 'spaces = "old_*"' ]] || fail "an empty spaces fell back to workspaces: $(cat "$empty")"
}
