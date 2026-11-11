#!/usr/bin/env bash
# shellcheck shell=bash
# Fixtures contain shell code whose variables must expand only when executed.
# shellcheck disable=SC2016
set -euo pipefail

unset BASH_ENV
export __MISE_BASH_ENV_LOADED=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# shellcheck disable=SC1090
source "$ROOT/skills/handoff/scripts/handoff-spawn"

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

git_dir() { git -C "$1" rev-parse --path-format=absolute --git-common-dir; }

# What any gt command leaves behind in a repo: the config, nothing tracked.
graphite_auto_init() {
  printf '{"trunk":"master","trunks":[{"name":"master"}]}\n' >"$(git_dir "$1")/.graphite_repo_config"
}

# Current gt stores every branch it has seen. Only tracked branches have a parent.
graphite_db_row() {
  local parent=null
  [[ -z "${3:-}" ]] || parent="'$3'"
  sqlite3 "$(git_dir "$1")/.graphite_metadata.db" \
    "create table if not exists branch_metadata (branch_name text primary key, parent_branch_name text);
     insert into branch_metadata values ('$2', $parent);"
}

test_graphite_config_file_alone_is_not_graphite() {
  local repo="$TMP_DIR/plain"
  git_init "$repo"
  handoff_is_graphite "$repo" && fail "plain repo must not count as Graphite"
  graphite_auto_init "$repo"
  handoff_is_graphite "$repo" && fail "an auto-created config must not count as Graphite"
  git -C "$repo" update-ref refs/branch-metadata/master HEAD
  handoff_is_graphite "$repo" && fail "metadata for trunk alone must not count as Graphite"
  printf 'PASS: an auto-created Graphite config, even with a trunk ref, is not Graphite\n'
}

test_graphite_metadata_refs_are_graphite() {
  local repo="$TMP_DIR/gt-refs" sibling="$TMP_DIR/gt-refs.feat"
  git_init "$repo"
  git -C "$repo" worktree add -q -b feat "$sibling"
  graphite_auto_init "$repo"
  git -C "$repo" update-ref refs/branch-metadata/stack/one HEAD
  handoff_is_graphite "$repo" || fail "a tracked branch ref must count as Graphite"
  handoff_is_graphite "$sibling" || fail "a linked worktree shares the refs"
  printf 'PASS: branch metadata refs for a non-trunk branch are Graphite, from any worktree\n'
}

test_graphite_second_trunk_ref_is_not_graphite() {
  local repo="$TMP_DIR/gt-trunks"
  git_init "$repo"
  printf '{"trunk":"main","trunks":[{"name":"main"},{"name":"sandbox"}]}\n' >"$(git_dir "$repo")/.graphite_repo_config"
  git -C "$repo" update-ref refs/branch-metadata/sandbox HEAD
  handoff_is_graphite "$repo" && fail "every trunk is excluded, not only the first"
  printf 'PASS: metadata refs of any configured trunk do not count\n'
}

test_graphite_metadata_db_rows() {
  local repo="$TMP_DIR/gt-db" err
  git_init "$repo"
  graphite_auto_init "$repo"
  export HANDOFF_SQLITE3_BIN="$TMP_DIR/no-sqlite3"
  : >"$(git_dir "$repo")/.graphite_metadata.db"
  err="$(handoff_is_graphite "$repo" 2>&1)" && fail "an unreadable store is not evidence of Graphite: $err"
  printf '%s' "$err" | grep -q '\[graphite\]' || fail "unreadable store should name the override: $err"
  unset HANDOFF_SQLITE3_BIN
  if ! command -v sqlite3 >/dev/null 2>&1; then
    printf 'SKIP: sqlite3 not found; the store rows are untested\n'
    return 0
  fi
  err="$(handoff_is_graphite "$repo" 2>&1)" && fail "an unknown schema is not evidence of Graphite: $err"
  printf '%s' "$err" | grep -q '\[graphite\]' || fail "unknown schema should name the override: $err"
  rm -f "$(git_dir "$repo")/.graphite_metadata.db"
  graphite_db_row "$repo" master
  graphite_db_row "$repo" stray-branch
  err="$(handoff_is_graphite "$repo" 2>&1)" && fail "rows with no parent are only what auto-init saw: $err"
  printf '%s' "$err" | grep -q 'tracks no branch' || fail "say why Graphite is off, and how to turn it on: $err"
  printf '%s' "$err" | grep -q 'cannot read' && fail "a readable store is not unreadable: $err"
  graphite_db_row "$repo" feat master
  handoff_is_graphite "$repo" || fail "a branch with a parent is tracked: Graphite"
  printf 'PASS: the metadata store counts only rows with a parent; unreadable skips Graphite and warns\n'
}

test_graphite_config_override() {
  local plain="$TMP_DIR/ov-plain" real="$TMP_DIR/ov-real" sibling="$TMP_DIR/ov-real.feat" cfg="$TMP_DIR/ov.toml"
  local home="$TMP_DIR/ov-home"
  git_init "$plain"
  git_init "$real"
  git -C "$real" worktree add -q -b feat "$sibling"
  graphite_auto_init "$real"
  git -C "$real" update-ref refs/branch-metadata/feat HEAD
  export BERCAIL_CONFIG="$cfg"
  cat >"$cfg" <<EOF
[graphite] # by main checkout
"$real" = false   # no longer stacks here
'$plain' = true

[bstack]
"$TMP_DIR/ov-other" = true
EOF
  handoff_is_graphite "$real" && fail "false wins over refs"
  handoff_is_graphite "$sibling" && fail "a linked worktree uses its main checkout's entry"
  handoff_is_graphite "$plain" || fail "true wins over no signal at all"
  cat >"$cfg" <<EOF
[bstack]
"$real" = false

[graphite]
"$TMP_DIR/ov-other" = false
"$plain" = maybe
EOF
  handoff_is_graphite "$real" || fail "a key in another section or for another repo is ignored"
  handoff_is_graphite "$plain" && fail "a value that is not a boolean is ignored"
  printf '["graphite"]\n"%s" = true\n' "$plain" >"$cfg"
  handoff_is_graphite "$plain" || fail "a quoted table name is the same table"
  [[ -z "$(handoff_is_graphite "$plain" 2>&1)" ]] || fail "a repo that has settled it hears nothing"
  mkdir -p "$home"
  git_init "$home/repo"
  printf '[graphite]\n"~/repo" = true\n' >"$cfg"
  (HOME="$home"; handoff_is_graphite "$home/repo") || fail "home-relative config keys expand to the home directory"
  rm -f "$cfg"
  handoff_is_graphite "$real" || fail "no config file falls through to detection"
  unset BERCAIL_CONFIG
  printf 'PASS: [graphite] in config.toml overrides detection for one repo, from any worktree\n'
}

test_git_enum_override_beats_graphite_and_detection() {
  local plain="$TMP_DIR/git-plain" tracked="$TMP_DIR/git-tracked" cfg="$TMP_DIR/git.toml" home="$TMP_DIR/git-home"
  git_init "$plain"
  git_init "$tracked"
  graphite_auto_init "$tracked"
  git -C "$tracked" update-ref refs/branch-metadata/feat HEAD
  export BERCAIL_CONFIG="$cfg"
  cat >"$cfg" <<EOF
[graphite]
"$tracked" = true
"$plain" = false

[git]
"$tracked" = "gh"
"$plain" = "origin"
EOF
  [[ "$(git_backend "$tracked")" == gh ]] || fail "[git] wins over [graphite] true and over refs: $(git_backend "$tracked")"
  [[ "$(git_backend "$plain")" == origin ]] || fail "[git] origin wins over [graphite] false"
  handoff_is_graphite "$tracked" && fail "gh override is not graphite"
  [[ -z "$(git_backend "$plain" 2>&1 >/dev/null)" ]] || fail "a settled [git] entry is silent"
  cat >"$cfg" <<EOF
[git]
"$plain" = "maybe"

[graphite]
"$plain" = true
EOF
  [[ "$(git_backend "$plain")" == gt ]] || fail "a non-enum [git] value is ignored and [graphite] still maps"
  printf '[git]\n"~/repo" = "gt"\n' >"$cfg"
  mkdir -p "$home"
  git_init "$home/repo"
  [[ "$(HOME="$home" git_backend "$home/repo")" == gt ]] || fail "home-relative [git] keys expand to the home directory"
  unset BERCAIL_CONFIG
  printf 'PASS: [git] enum overrides [graphite] and detection; bad values are ignored\n'
}

_origin_remote() {
  git -C "$1" remote remove origin 2>/dev/null || true
  git -C "$1" remote add origin "$2"
}

test_origin_remote_is_offline_until_the_host_matches() {
  local repo="$TMP_DIR/ori-off" bin="$TMP_DIR/ori-off-bin" log="$TMP_DIR/ori-off.log"
  git_init "$repo"
  mkdir -p "$bin"
  cat >"$bin/origin" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$log"
printf '%s\n' '{"mirrorStatus":"no-mirror"}'
EOF
  chmod +x "$bin/origin"
  : >"$log"
  _origin_remote "$repo" https://github.com/acme/widgets.git
  [[ "$(PATH="$bin:$PATH" git_backend "$repo")" == gh ]] || fail "a GitHub remote is gh"
  [[ ! -s "$log" ]] || fail "origin must not be probed for a GitHub remote: $(cat "$log")"
  git_backend_origin_remote "$repo" && fail "github.com is not an Origin git host"
  _origin_remote "$repo" git@origin.cursor.com:acme/widgets.git
  git_backend_origin_remote "$repo" || fail "scp origin.cursor.com is an Origin git host"
  _origin_remote "$repo" https://origin.cursor.com/git/acme/widgets.git
  git_backend_origin_remote "$repo" || fail "/git/org/repo is an Origin git host"
  _origin_remote "$repo" https://origin-staging.cursor.com/acme/widgets
  git_backend_origin_remote "$repo" || fail "origin-<id>.cursor.com is an Origin git host"
  _origin_remote "$repo" https://github.com/origin.cursor.com/acme/widgets.git
  git_backend_origin_remote "$repo" && fail "a lookalike path on github.com is not Origin"
  printf 'PASS: Origin host match is offline; a GitHub remote is never probed\n'
}

test_origin_ownership_uses_mirror_status() {
  local repo="$TMP_DIR/ori-own" bin="$TMP_DIR/ori-own-bin" log="$TMP_DIR/ori-own.log" status
  git_init "$repo"
  _origin_remote "$repo" https://origin.cursor.com/acme/widgets.git
  mkdir -p "$bin"
  cat >"$bin/origin" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$log"
if [[ "\$*" == *"repo view --json mirrorStatus"* ]]; then
  printf '%s\n' "{\"mirrorStatus\":\"$TMP_DIR/ori-status\"}"
  # status file holds the value; the JSON is written below by the test via env
  printf '%s\n' "{\"mirrorStatus\":\"\${ORIGIN_STATUS}\"}"
  exit 0
fi
exit 1
EOF
  # The fake above prints two JSON lines when ORIGIN_STATUS is set. Rewrite it cleanly.
  cat >"$bin/origin" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$BERCAIL_ORIGIN_LOG"
if [ "$1" = "repo" ] && [ "$2" = "view" ]; then
  printf '%s\n' "{\"mirrorStatus\":\"${ORIGIN_STATUS}\"}"
  exit 0
fi
exit 1
EOF
  chmod +x "$bin/origin"
  export BERCAIL_ORIGIN_LOG="$log"
  for status in no-mirror outbound; do
    : >"$log"
    [[ "$(PATH="$bin:$PATH" ORIGIN_STATUS="$status" git_backend "$repo")" == origin ]] \
      || fail "$status must be origin"
    grep -q 'repo view --json mirrorStatus' "$log" || fail "ownership probe missing: $(cat "$log")"
  done
  : >"$log"
  [[ "$(PATH="$bin:$PATH" ORIGIN_STATUS=inbound git_backend "$repo")" == gh ]] \
    || fail "inbound mirror is GitHub-owned"
  [[ "$(PATH="$bin:$PATH" ORIGIN_STATUS=other git_backend "$repo")" == gh ]] \
    || fail "any other mirrorStatus is gh"
  : >"$log"
  [[ "$(PATH="/usr/bin:/bin" git_backend "$repo" 2>"$TMP_DIR/ori-missing.err")" == gh ]] \
    || fail "missing origin CLI is unknown ownership, so gh"
  grep -q '\[git\]' "$TMP_DIR/ori-missing.err" || fail "missing CLI should name the override: $(cat "$TMP_DIR/ori-missing.err")"
  cat >"$bin/origin" <<'EOF'
#!/bin/sh
printf 'origin: not logged in\n' >&2
exit 1
EOF
  chmod +x "$bin/origin"
  [[ "$(PATH="$bin:$PATH" git_backend "$repo" 2>"$TMP_DIR/ori-fail.err")" == gh ]] \
    || fail "a failed ownership probe is gh"
  grep -q 'origin repo view failed' "$TMP_DIR/ori-fail.err" || fail "failed probe should say why: $(cat "$TMP_DIR/ori-fail.err")"
  grep -q '\[git\]' "$TMP_DIR/ori-fail.err" || fail "failed probe should name the override: $(cat "$TMP_DIR/ori-fail.err")"
  cat >"$bin/origin" <<'EOF'
#!/bin/sh
exit 130
EOF
  chmod +x "$bin/origin"
  local rc=0 out
  out="$(PATH="$bin:$PATH" git_backend "$repo" 2>"$TMP_DIR/ori-int.err")" || rc=$?
  [[ "$rc" -eq 130 ]] || fail "an interrupted probe must exit 130, not guess gh (rc=$rc out=$out)"
  [[ -z "$out" ]] || fail "an interrupted probe must not print a backend: $out"
  grep -q 'using gh' "$TMP_DIR/ori-int.err" && fail "interrupt is not an unknown-ownership fallback: $(cat "$TMP_DIR/ori-int.err")"
  unset BERCAIL_ORIGIN_LOG ORIGIN_STATUS
  printf 'PASS: Origin ownership is mirrorStatus; unknown ownership warns and stays gh\n'
}

test_copy_dirty_is_working_tree_not_index() {
  local main="$TMP_DIR/main" sibling="$TMP_DIR/sibling"
  git_init "$main"
  git -C "$main" worktree add --detach -q "$sibling"

  printf 'base\nstaged\n' >"$main/file.txt"
  git -C "$main" add file.txt
  printf 'base\nstaged\nunstaged\n' >"$main/file.txt"
  printf 'loose\n' >"$main/untracked.txt"

  handoff_copy_dirty "$main" "$sibling"

  grep -qx 'loose' "$sibling/untracked.txt" || fail "untracked file should be copied"
  git -C "$sibling" diff --cached --quiet \
    || fail "sibling index must stay at HEAD (no git add)"
  git -C "$sibling" diff --quiet HEAD \
    && fail "sibling working tree should include tracked dirty files"
  grep -q unstaged "$sibling/file.txt" || fail "unstaged edit missing in sibling"
  git -C "$sibling" ls-files --error-unmatch untracked.txt >/dev/null 2>&1 \
    && fail "untracked copy must not be git-added"
  printf 'PASS: dirty copy is working tree only (no git add)\n'
}

test_usage() {
  local rc=0
  "$ROOT/skills/handoff/scripts/handoff-spawn" --help >/dev/null 2>&1 || rc=$?
  [[ "$rc" -eq 2 ]] || fail "usage should exit 2, got $rc"
  printf 'PASS: handoff-spawn --help exits 2\n'
}

test_issue_prompt_points_at_the_issue() {
  [[ "$(handoff_issue_prompt bercail-0s1)" == 'Your job is beads issue bercail-0s1. Run `bd show bercail-0s1` (read its comments too) and do the work it describes.' ]] \
    || fail "prompt points at the issue: $(handoff_issue_prompt bercail-0s1)"
  [[ "$(handoff_issue_prompt bercail-0s1 'Show the title')" == 'Your job is beads issue bercail-0s1: Show the title. Run `bd show bercail-0s1` (read its comments too) and do the work it describes.' ]] \
    || fail "prompt with a title: $(handoff_issue_prompt bercail-0s1 'Show the title')"
  [[ "$(handoff_issue_prompt bercail-0s1 'Done.')" == 'Your job is beads issue bercail-0s1: Done. Run `bd show bercail-0s1` (read its comments too) and do the work it describes.' ]] \
    || fail "a trailing period on the title must not read as two: $(handoff_issue_prompt bercail-0s1 'Done.')"
  handoff_issue_id_ok bercail-0s1 || fail "plain beads id"
  handoff_issue_id_ok bercail-0s1.2 || fail "child beads id"
  handoff_issue_id_ok --help && fail "flag is not an id"
  handoff_issue_id_ok ../x && fail "path is not an id"
  handoff_issue_id_ok 'bercail-0s1 rm' && fail "space is not an id"
  [[ ! -d "$ROOT/skills/handoff/prompts" ]] || fail "prompt files must be gone"
  [[ ! -e "$ROOT/skills/handoff/scripts/handoff-brief" ]] || fail "handoff-brief must be gone"
  printf 'PASS: the agent prompt is one line pointing at the beads issue\n'
}

test_graphite_track_uses_resolved_config_path() {
  local repo="$TMP_DIR/gt-rel"
  git_init "$repo"
  local printed cfg
  printed="$(git -C "$repo" rev-parse --git-path .graphite_repo_config)"
  if [[ "$printed" == /* ]]; then
    cfg="$printed"
  else
    cfg="$repo/$printed"
  fi
  mkdir -p "$(dirname "$cfg")"
  printf '{"trunk":"master"}\n' >"$cfg"
  git -C "$repo" update-ref refs/branch-metadata/feat HEAD
  [[ "$(handoff_graphite_config "$repo")" == "$cfg" ]] \
    || fail "graphite config path should resolve relative git-path"
  (
    cd "$TMP_DIR"
    handoff_is_graphite "$repo" || fail "is_graphite from other cwd"
    got="$(handoff_graphite_config "$repo")"
    [[ "$got" == "$cfg" ]] || fail "track helper must not depend on cwd, got $got"
  )
  printf 'PASS: graphite config path is resolved against the repo root\n'
}

test_graphite_tracks_new_branch_in_linked_worktree() {
  local repo="$TMP_DIR/gt-linked" sibling="$TMP_DIR/gt-linked.feat" bin="$TMP_DIR/gt-bin"
  git_init "$repo"
  git -C "$repo" worktree add -q -b feat "$sibling"
  printf '{"trunk":"master"}\n' >"$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir)/.graphite_repo_config"
  mkdir -p "$bin"
  # A fake gt: a new branch has no parent yet.
  cat >"$bin/gt" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$TMP_DIR/gt.log"
case "\$*" in *" parent "*) exit 1 ;; esac
EOF
  chmod +x "$bin/gt"
  : >"$TMP_DIR/gt.log"
  PATH="$bin:$PATH" handoff_track_graphite "$sibling"
  grep -qxF -- "--cwd $sibling track --parent master --no-interactive" "$TMP_DIR/gt.log" \
    || fail "new branch should be tracked on trunk; log=$(cat "$TMP_DIR/gt.log")"
  printf 'PASS: a new branch in a linked worktree is gt tracked on trunk\n'
}

test_info_json_reports_graphite_and_dirty() {
  local repo="$TMP_DIR/info-repo" out
  git_init "$repo"
  printf 'dirty\n' >>"$repo/file.txt"
  printf 'loose\n' >"$repo/untracked.txt"
  # git -C prints the path relative to $repo, not to the cwd.
  printed="$(git -C "$repo" rev-parse --git-path .graphite_repo_config)"
  [[ "$printed" == /* ]] || printed="$repo/$printed"
  mkdir -p "$(dirname "$printed")"
  printf '{}\n' >"$printed"
  printf '#!/bin/sh\nexit 1\n' >"$TMP_DIR/no-herdr"
  chmod +x "$TMP_DIR/no-herdr"
  unset HC_TERMINAL_ID HANDOFF_SPACE
  out="$(cd "$repo" && HERDR_APP_BIN="$TMP_DIR/no-herdr" \
    "$ROOT/skills/handoff/scripts/handoff-spawn" --info)"
  printf '%s' "$out" | jq -e '.graphite == false and .git == "gh"' >/dev/null || fail "info with only an auto-created config: $out"
  git -C "$repo" update-ref refs/branch-metadata/feat HEAD
  out="$(cd "$repo" && HERDR_APP_BIN="$TMP_DIR/no-herdr" \
    "$ROOT/skills/handoff/scripts/handoff-spawn" --info)"
  printf '%s' "$out" | jq -e '.dirty == true' >/dev/null || fail "info dirty: $out"
  printf '%s' "$out" | jq -e '.graphite == true and .git == "gt"' >/dev/null || fail "info graphite: $out"
  printf '%s' "$out" | jq -e '.default_copy == "dirty"' >/dev/null || fail "info default_copy: $out"
  printf '%s' "$out" | jq -e '.herdr == false' >/dev/null || fail "info herdr: $out"
  printf '%s' "$out" | jq -e '.herdr_env == false' >/dev/null || fail "info herdr_env: $out"
  printf '%s' "$out" | jq -e '.socket == false' >/dev/null || fail "info socket: $out"
  printf '%s' "$out" | jq -e '.main_checkout == true' >/dev/null || fail "info main_checkout: $out"
  printf '%s' "$out" | jq -e 'has("pstack")|not' >/dev/null || fail "info must not report pstack: $out"
  printf 'PASS: --info reports dirty, graphite, and herdr without agent inspection\n'
}

test_info_json_socket_without_herdr_env() {
  local repo="$TMP_DIR/info-socket" out
  git_init "$repo"
  cat >"$TMP_DIR/fake-herdr-app" <<'EOF'
#!/bin/sh
echo '{"space":"sp26"}'
EOF
  chmod +x "$TMP_DIR/fake-herdr-app"
  unset HC_TERMINAL_ID HANDOFF_SPACE
  out="$(cd "$repo" && HERDR_APP_BIN="$TMP_DIR/fake-herdr-app" \
    "$ROOT/skills/handoff/scripts/handoff-spawn" --info)"
  printf '%s' "$out" | jq -e '.herdr == true' >/dev/null || fail "socket herdr: $out"
  printf '%s' "$out" | jq -e '.herdr_env == false' >/dev/null || fail "socket herdr_env: $out"
  printf '%s' "$out" | jq -e '.socket == true' >/dev/null || fail "socket flag: $out"
  printf '%s' "$out" | jq -e '.space == "sp26" and .workspace == "sp26"' >/dev/null || fail "socket space: $out"
  printf 'PASS: --info treats a live Herdr app as herdr outside an hc terminal\n'
}

test_result_json_records_unconfirmed_agent() {
  local got
  got="$(handoff_result_json "Lbl" "/tmp/wt" "br" "bercail-0s1" 0 0 1)"
  printf '%s' "$got" | jq -e '.issue == "bercail-0s1" and (has("task")|not)' >/dev/null || fail "issue: $got"
  printf '%s' "$got" | jq -e '.ok == true' >/dev/null || fail "ok: $got"
  printf '%s' "$got" | jq -e '.agent_started == false' >/dev/null || fail "started: $got"
  printf '%s' "$got" | jq -e '.graphite == true' >/dev/null || fail "graphite: $got"
  printf '%s' "$got" | jq -e '.path == "/tmp/wt"' >/dev/null || fail "path: $got"
  printf '%s' "$got" | jq -e '(has("stage")|not) and (has("harness")|not) and (has("issue_title")|not)' >/dev/null || fail "no stage: $got"
  got="$(handoff_result_json "Lbl" "/tmp/wt" "br" "bercail-0s1" 1 0 0 bstack pi "" "" "Show the title")"
  printf '%s' "$got" | jq -e '.issue_title == "Show the title" and .stage == "bstack" and .harness == "pi" and (has("space")|not)' >/dev/null \
    || fail "issue_title: $got"
  got="$(handoff_result_json "Lbl" "/tmp/wt" "br" "bercail-0s1" 1 0 0 bstack pi)"
  printf '%s' "$got" | jq -e '.stage == "bstack" and .harness == "pi"' >/dev/null || fail "stage/harness: $got"
  printf 'PASS: result JSON is emitted when agent start is unconfirmed\n'
}

test_parent_workspace_required_without_herdr_env() {
  unset HANDOFF_SPACE
  HERDR_APP_BIN="$TMP_DIR/no-herdr" handoff_shown_space && fail "parent workspace must be empty"
  HANDOFF_SPACE=sp26
  [[ "$(HERDR_APP_BIN="$TMP_DIR/no-herdr" handoff_shown_space)" == sp26 ]] || fail "--space should win"
  unset HANDOFF_SPACE
  [[ "$(HERDR_APP_BIN="$TMP_DIR/fake-herdr-app" handoff_shown_space)" == sp26 ]] || fail "shown space fallback"
  printf 'PASS: the space kept shown comes from --space or the shown space\n'
}

test_issue_is_required_and_prompt_flags_are_gone() {
  local rc=0 err flag out
  err="$("$ROOT/skills/handoff/scripts/handoff-spawn" --branch foo --stage bstack 2>&1)" || rc=$?
  [[ "$rc" -eq 1 ]] || fail "missing --issue should exit 1, got $rc ($err)"
  printf '%s' "$err" | grep -q -- '--issue' || fail "missing --issue message: $err"
  rc=0
  err="$("$ROOT/skills/handoff/scripts/handoff-spawn" --stage bstack --issue '../etc' --dry-run 2>&1)" || rc=$?
  [[ "$rc" -eq 1 ]] || fail "bad issue id should exit 1, got $rc ($err)"
  printf '%s' "$err" | grep -q 'not a beads issue id' || fail "bad id message: $err"
  for flag in --stash-prompt --take-pending --plan; do
    rc=0
    "$ROOT/skills/handoff/scripts/handoff-spawn" --branch foo --stage bstack --issue bercail-0s1 "$flag" >/dev/null 2>&1 || rc=$?
    [[ "$rc" -eq 2 ]] || fail "$flag should be gone (usage), got $rc"
  done
  for flag in --prompt-file --brief; do
    rc=0
    "$ROOT/skills/handoff/scripts/handoff-spawn" --stage bstack --issue bercail-0s1 "$flag" x >/dev/null 2>&1 || rc=$?
    [[ "$rc" -eq 2 ]] || fail "$flag should be gone (usage), got $rc"
  done
  printf '#!/bin/sh\nexit 1\n' >"$TMP_DIR/no-herdr"
  chmod +x "$TMP_DIR/no-herdr"
  out="$(HERDR_APP_BIN="$TMP_DIR/no-herdr" HANDOFF_BD_BIN="$TMP_DIR/no-bd" \
    "$ROOT/skills/handoff/scripts/handoff-spawn" --info)"
  printf '%s' "$out" | jq -e '(has("pending_prompt")|not) and .beads == false' >/dev/null \
    || fail "--info should report beads and no pending prompt: $out"
  printf 'PASS: --issue is required; prompt-file, stash, pending, plan, and brief flags are gone\n'
}

test_rejects_prompt_after_double_dash() {
  local rc=0 err
  err="$("$ROOT/skills/handoff/scripts/handoff-spawn" --branch foo --stage bstack --issue bercail-0s1 --clean -- 'QA cedar-pg' 2>&1)" || rc=$?
  [[ "$rc" -eq 1 ]] || fail "-- prompt should exit 1, got $rc ($err)"
  printf '%s' "$err" | grep -q 'there is no prompt argument' \
    || fail "double-dash message: $err"
  printf 'PASS: argv after -- is rejected so Auto-review does not bind a payload\n'
}

test_graphite_tracks_base_as_parent() {
  local repo="$TMP_DIR/gt-base" sibling="$TMP_DIR/gt-base.feat" bin="$TMP_DIR/gt-base-bin"
  git_init "$repo"
  git -C "$repo" branch parent-branch
  git -C "$repo" worktree add -q -b feat "$sibling" parent-branch
  printf '{"trunk":"master"}\n' >"$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir)/.graphite_repo_config"
  mkdir -p "$bin"
  cat >"$bin/gt" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$TMP_DIR/gt-base.log"
case "\$*" in *" parent "*) exit 1 ;; esac
EOF
  chmod +x "$bin/gt"
  : >"$TMP_DIR/gt-base.log"
  PATH="$bin:$PATH" handoff_track_graphite "$sibling" parent-branch
  grep -qxF -- "--cwd $sibling track --parent parent-branch --no-interactive" "$TMP_DIR/gt-base.log" \
    || fail "--base branch should be the gt parent; log=$(cat "$TMP_DIR/gt-base.log")"
  printf 'PASS: with --base, gt tracks the new branch on that base\n'
}

test_base_needs_branch() {
  local rc=0 err
  err="$("$ROOT/skills/handoff/scripts/handoff-spawn" --stage bstack --issue bercail-0s1 --base foo --dry-run 2>&1)" || rc=$?
  [[ "$rc" -eq 1 ]] || fail "--base without --branch should exit 1, got $rc ($err)"
  printf '%s' "$err" | grep -q -- '--base needs --branch' || fail "--base message: $err"
  err="$("$ROOT/skills/handoff/scripts/handoff-spawn" --help 2>&1)" || true
  printf '%s' "$err" | grep -q -- '--base BRANCH' || fail "--help should document --base"
  printf 'PASS: --base needs --branch and is in --help\n'
}

test_graphite_config_file_alone_is_not_graphite
test_git_enum_override_beats_graphite_and_detection
test_origin_remote_is_offline_until_the_host_matches
test_origin_ownership_uses_mirror_status
test_graphite_metadata_refs_are_graphite
test_graphite_second_trunk_ref_is_not_graphite
test_graphite_metadata_db_rows
test_graphite_config_override
test_copy_dirty_is_working_tree_not_index
test_usage
test_issue_prompt_points_at_the_issue
test_graphite_track_uses_resolved_config_path
test_graphite_tracks_new_branch_in_linked_worktree
test_graphite_tracks_base_as_parent
test_base_needs_branch
test_info_json_reports_graphite_and_dirty
test_info_json_socket_without_herdr_env
test_result_json_records_unconfirmed_agent
test_parent_workspace_required_without_herdr_env
test_issue_is_required_and_prompt_flags_are_gone
test_rejects_prompt_after_double_dash

test_intro_does_not_invoke_review_skill() {
  grep -q 'when the desk agent finishes, Review opens itself in this space' "$ROOT/skills/handoff/scripts/handoff-spawn" \
    || fail "handoff intro should say Review opens itself"
  grep -q 'post your final report on this issue with bd comment' "$ROOT/skills/handoff/scripts/handoff-spawn" \
    || fail "a desk reports on the issue, where headless runs and Shep read it"
  local res
  res="$(handoff_result_json L /p b i 1 0 1 bstack pi sp9 t28)"
  printf '%s' "$res" | jq -e '.space == "sp9" and .desk == "t28" and .ok and .stage == "bstack" and .harness == "pi"' >/dev/null \
    || fail "spawn JSON names the space and desk: $res"
  grep -q 'agentic-dev.layout' "$ROOT/skills/handoff/scripts/handoff-spawn" \
    && fail "handoff intro must not name the old Herdr plugin"
  grep -q 'review/SKILL.md' "$ROOT/skills/handoff/scripts/handoff-spawn" \
    && fail "handoff intro must not tell the child to load the review skill"
  grep -q 'leave them uncommitted for human review' "$ROOT/skills/handoff/scripts/handoff-spawn" \
    || fail "handoff intro should tell the child to keep changes staged, not committed"
  printf 'PASS: handoff intro does not open review via the review skill\n'
}

test_intro_does_not_invoke_review_skill

test_stage_table_is_pi_only() {
  declare -F handoff_stage_poteto >/dev/null && fail "the poteto mode must be gone"
  declare -F handoff_has_pstack >/dev/null && fail "pstack detection must be gone"
  declare -F handoff_build_headless_argv >/dev/null && fail "non-Pi argv builder must be gone"
  declare -F handoff_resolve_model >/dev/null && fail "model catalog resolver must be gone"
  declare -F handoff_bstack_model >/dev/null && fail "provider model lookup must be gone"
  grep -rqi 'poteto\|pstack' "$ROOT/skills/handoff/SKILL.md" "$ROOT/skills/handoff/scripts/handoff-spawn" \
    && fail "handoff must not mention poteto-mode or pstack"
  handoff_stage_field arena binary && fail "arena is not a stage yet"
  handoff_stage_field implement binary && fail "implement is not a stage yet"
  handoff_stage_field review binary && fail "review pane is not a stage yet"
  handoff_stage_field start binary && fail "start is not a stage"
  [[ "$(handoff_stage_field bstack binary)" == pi ]] || fail "bstack binary"
  [[ "$(handoff_stage_field bstack mode)" == headless ]] || fail "bstack mode"
  [[ "$(handoff_stage_field bstack model)" == lead ]] || fail "bstack model"
  [[ "$(handoff_stage_field autopilot binary)" == pi ]] || fail "autopilot binary"
  [[ "$(handoff_stage_field autopilot mode)" == headless ]] || fail "autopilot mode"
  [[ "$(handoff_stage_names_json)" == '["bstack","autopilot"]' ]] || fail "stage names: $(handoff_stage_names_json)"
  grep -q 'WT_HERDR_AGENT_CMD' "$ROOT/skills/handoff/scripts/handoff-spawn" \
    && fail "the desk runs Pi's lead; handoff names no agent command"
  grep -q 'WT_HERDR_AGENT_PROMPT="$prompt"' "$ROOT/skills/handoff/scripts/handoff-spawn" \
    || fail "pane stage must pass the issue prompt inline"
  grep -q 'PROMPT_FILE' "$ROOT/skills/handoff/scripts/handoff-spawn" \
    && fail "handoff-spawn must not use a prompt file"
  printf 'PASS: stages are bstack and autopilot on Pi\n'
}

ISSUE='bercail-0s1'

# Stub bd: knows $BD_KNOWN ids, logs comments, reports $BD_BEADS_DIR.
_bd_stub() {
  mkdir -p "$TMP_DIR/bdbin"
  cat >"$TMP_DIR/bdbin/bd" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  show)
    [[ " ${BD_KNOWN:-} " == *" $2 "* ]] || { echo "no issue $2" >&2; exit 1; }
    if [[ -n "${BD_TITLE:-}" ]]; then
      jq -nc --arg id "$2" --arg title "$BD_TITLE" '[{id:$id, title:$title}]'
    else
      jq -nc --arg id "$2" '[{id:$id}]'
    fi
    ;;
  comment)
    [[ "${3:-}" == --stdin ]] || exit 3
    printf '%s\t%s\n' "$2" "$(cat)" >>"${BD_COMMENTS:?}"
    ;;
  context)
    printf '{"beads_dir":"%s"}\n' "${BD_BEADS_DIR:-$PWD/.beads}"
    ;;
  *) exit 2 ;;
esac
STUB
  chmod +x "$TMP_DIR/bdbin/bd"
  export HANDOFF_BD_BIN="$TMP_DIR/bdbin/bd"
  export BD_KNOWN="$ISSUE"
  export BD_COMMENTS="$TMP_DIR/bd-comments"
  : >"$BD_COMMENTS"
}

# Lead profile so a Pi stage can build argv. The binary is missing until a test overrides it.
_pi_ready() {
  local profile="$TMP_DIR/pi-profile" guard="$TMP_DIR/pi-profile/extensions/guard.ts"
  mkdir -p "$profile/extensions" "$profile/agents" "$TMP_DIR/bin"
  printf '// guard\n' >"$guard"
  jq -n --arg guard "$guard" --arg model "claude-bridge/lead-model:high" \
    '["pi","--model",$model,"-e","npm:pi-claude-bridge@0.11.0","-e",$guard]' >"$profile/lead.json"
  export HANDOFF_PI_PROFILE="$profile"
  export HANDOFF_PI_BIN="$TMP_DIR/bin/pi-missing"
}

_start_fixture() {
  local wt="$1"
  mkdir -p "$wt"
  _bd_stub
  _pi_ready
  unset BD_BEADS_DIR
}

test_stage_table_is_pi_only

test_result_ok_verification() {
  local f="$TMP_DIR/verification.json"
  local base='{"status":"ready","summary":"done","session_id":"s1"}' good bad
  ok_with() { jq -c --argjson v "$1" '. + {verification: $v}' <<<"$base" >"$f"; handoff_result_ok "$f"; }
  printf '%s\n' "$base" >"$f"
  handoff_result_ok "$f" || fail "a result without verification still passes"
  for good in '[]' \
    '[{"kind":"test","command":"bash t.sh","exit_code":0,"evidence":"t.log"}]' \
    '[{"kind":"verify-skill","command":"run.sh","exit_code":1,"evidence":".bercail/verify/x"},{"kind":"statechart","command":"statechart a.tla","exit_code":0,"evidence":"tlc.out"}]' \
    '[{"kind":"statechart","spec":"a.tla","exit_code":0,"rules_broken":[],"chart":"chart.mmd","replayed":false}]'; do
    ok_with "$good" || fail "should pass: $good"
  done
  for bad in '"passed"' 'false' '[1]' \
    '[{"kind":"vibes","command":"x","exit_code":0,"evidence":"e"}]' \
    '[{"kind":"test","command":"x","exit_code":"0","evidence":"e"}]' \
    '[{"kind":"test","exit_code":0,"evidence":"e"}]' \
    '[{"kind":"test","command":"x","exit_code":0}]' \
    '[{"kind":"statechart","exit_code":0}]'; do
    if ok_with "$bad"; then fail "should fail: $bad"; fi
  done
  jq -nc '{status:"ready", summary:"done"}' >"$f"
  if handoff_result_ok "$f"; then fail "session_id stays required"; fi
  printf 'PASS: handoff_result_ok takes an optional, well-formed verification array\n'
}

# A headless run whose agent writes $1 as its result.
_run_with_agent_result() {
  local wt="$1" result="$2" stub="$TMP_DIR/bin/pi-verify"
  mkdir -p "$TMP_DIR/bin"
  _start_fixture "$wt"
  cat >"$stub" <<STUB
#!/usr/bin/env bash
printf '%s\n' '$result' >"\$BERCAIL_RESULT_PATH"
STUB
  chmod +x "$stub"
  HANDOFF_PI_BIN="$stub" "$ROOT/skills/handoff/scripts/handoff-spawn" --stage bstack --issue "$ISSUE" --worktree "$wt" >/dev/null
}

test_runner_keeps_verification() {
  local wt="$TMP_DIR/verify-keep" got
  _run_with_agent_result "$wt" '{"status":"ready","summary":"proved","verification":[{"kind":"test","command":"bash t.sh","exit_code":0,"evidence":"t.log"}]}' \
    || fail "run with verification"
  got="$wt/.bercail/handoff-result.json"
  jq -e '.status == "ready" and .summary == "proved" and (.session_id | length > 0)
    and .verification == [{kind:"test",command:"bash t.sh",exit_code:0,evidence:"t.log"}]' "$got" >/dev/null \
    || fail "verification must survive the run: $(cat "$got")"

  wt="$TMP_DIR/verify-drop"
  _run_with_agent_result "$wt" '{"status":"ready","summary":"proved","verification":"all good"}' \
    || fail "a malformed verification list must not fail the run"
  got="$wt/.bercail/handoff-result.json"
  jq -e '.status == "ready" and (.summary | startswith("proved")) and (.summary | contains("malformed verification"))
    and (has("verification") | not)' "$got" >/dev/null \
    || fail "a malformed list is dropped and the result stands: $(cat "$got")"
  printf 'PASS: the runner keeps a good verification list and drops only a malformed one\n'
}

test_result_ok_verification
test_runner_keeps_verification

test_headless_prompt_points_at_the_issue() {
  local wt="$TMP_DIR/prompt-id" stage out
  _start_fixture "$wt"
  for stage in bstack autopilot; do
    out="$(cd "$wt" && "$ROOT/skills/handoff/scripts/handoff-spawn" --stage "$stage" --issue "$ISSUE" --worktree "$wt" --dry-run)"
    printf '%s' "$out" | jq -e --arg id "$ISSUE" '(.command[-1] | startswith("Your job is beads issue \($id).")) and .command[-2] == "--" and .bd_present == true' >/dev/null \
      || fail "$stage prompt must point at the issue: $out"
    printf '%s' "$out" | jq -e 'any(.command[]; . == "--add-dir")|not' >/dev/null \
      || fail "$stage argv must not pass --add-dir: $out"
  done
  export BD_BEADS_DIR="$TMP_DIR/main-checkout/.beads"
  out="$(cd "$wt" && "$ROOT/skills/handoff/scripts/handoff-spawn" --stage bstack --issue "$ISSUE" --worktree "$wt" --dry-run)"
  printf '%s' "$out" | jq -e 'any(.command[]; . == "--add-dir")|not' >/dev/null \
    || fail "an outside .beads still gets no --add-dir: $out"
  unset BD_BEADS_DIR
  printf 'PASS: each headless prompt points at the issue; Pi has no --add-dir\n'
}

test_missing_pi_blocks_without_fallback() {
  local wt="$TMP_DIR/missing-pi" rc=0 err
  _start_fixture "$wt"
  export HANDOFF_PI_BIN="$TMP_DIR/no-such-pi"
  err="$(cd "$wt" && \
    "$ROOT/skills/handoff/scripts/handoff-spawn" --stage bstack --issue "$ISSUE" --worktree "$wt" 2>"$TMP_DIR/missing.err")" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "missing pi should exit nonzero, got 0 ($err)"
  grep -q 'not on PATH' "$TMP_DIR/missing.err" || fail "stderr should say not on PATH: $(cat "$TMP_DIR/missing.err")"
  jq -e '.status=="blocked" and (.summary|test("pi")) and (.session_id | test("^[0-9a-fA-F-]{36}$"))' \
    "$wt/.bercail/handoff-result.json" >/dev/null \
    || fail "blocked result: $(cat "$wt/.bercail/handoff-result.json")"
  printf '%s' "$err" | jq -e '.status=="blocked" and (has("command")|not)' >/dev/null \
    || fail "stdout should be the blocked result, not a start command: $err"
  printf 'PASS: missing pi writes a blocked result and does not fall through\n'
}

test_dry_run_prints_pi_stages() {
  local wt="$TMP_DIR/all-dry" out stage rc=0 err
  _start_fixture "$wt"
  export HANDOFF_PI_BIN="$TMP_DIR/gone-pi"
  export HANDOFF_BD_BIN="$TMP_DIR/gone-bd"
  for stage in bstack autopilot; do
    out="$(cd "$wt" && "$ROOT/skills/handoff/scripts/handoff-spawn" \
      --stage "$stage" --issue "$ISSUE" --worktree "$wt" --dry-run)"
    printf '%s' "$out" | jq -e --arg want "$HANDOFF_PI_BIN" \
      '.dry_run == true and .present == false and .bd_present == false and .binary == "pi" and any(.command[]; . == $want) and (.command | length) > 2' >/dev/null \
      || fail "$stage dry-run should print its argv even when pi is missing: $out"
  done
  [[ ! -f "$wt/.bercail/handoff-result.json" ]] || fail "dry-run must not write a result"
  _bd_stub
  _pi_ready
  export HANDOFF_PI_BIN="$TMP_DIR/gone-pi"
  err="$(cd "$wt" && "$ROOT/skills/handoff/scripts/handoff-spawn" \
    --stage bstack --issue "$ISSUE" --worktree "$wt" 2>/dev/null)" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "missing pi should exit nonzero"
  jq -e '.status=="blocked" and (.summary|test("pi is not on PATH"))' "$wt/.bercail/handoff-result.json" >/dev/null \
    || fail "missing pi should block: $(cat "$wt/.bercail/handoff-result.json")"
  printf 'PASS: dry-run prints argv for bstack and autopilot; missing pi blocks\n'
}

test_missing_bd_or_issue_blocks() {
  local wt="$TMP_DIR/bd-block" rc=0 out stub="$TMP_DIR/bin/pi-ran"
  _start_fixture "$wt"
  mkdir -p "$TMP_DIR/bin"
  printf '#!/bin/sh\necho ran >"%s/pi-ran"\n' "$TMP_DIR" >"$stub"
  chmod +x "$stub"
  export HANDOFF_PI_BIN="$stub"
  export HANDOFF_BD_BIN="$TMP_DIR/no-such-bd"
  out="$(cd "$wt" && "$ROOT/skills/handoff/scripts/handoff-spawn" --stage bstack --issue "$ISSUE" --worktree "$wt" 2>/dev/null)" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "missing bd should exit nonzero"
  jq -e '.status=="blocked" and (.summary|test("bd \\(beads\\) is not on PATH"))' "$wt/.bercail/handoff-result.json" >/dev/null \
    || fail "missing bd should block: $(cat "$wt/.bercail/handoff-result.json")"
  _bd_stub
  rc=0
  out="$(cd "$wt" && "$ROOT/skills/handoff/scripts/handoff-spawn" --stage bstack --issue bercail-nope --worktree "$wt" 2>/dev/null)" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "unknown issue should exit nonzero"
  jq -e '.status=="blocked" and (.summary|test("bercail-nope not found"))' "$wt/.bercail/handoff-result.json" >/dev/null \
    || fail "unknown issue should block: $(cat "$wt/.bercail/handoff-result.json")"
  [[ ! -f "$TMP_DIR/pi-ran" ]] || fail "pi must not start without a real issue"
  [[ ! -s "$BD_COMMENTS" ]] || fail "blocked handoff must not comment: $(cat "$BD_COMMENTS")"
  printf 'PASS: missing bd or an unknown issue writes a blocked result and starts nothing\n'
}

test_stage_is_required_and_branch_needs_bstack() {
  local rc=0 err
  err="$("$ROOT/skills/handoff/scripts/handoff-spawn" --branch foo --issue "$ISSUE" 2>&1)" || rc=$?
  [[ "$rc" -eq 1 ]] || fail "missing --stage should exit 1, got $rc ($err)"
  printf '%s' "$err" | grep -q 'does not pick a stage' || fail "missing --stage message: $err"
  rc=0
  err="$("$ROOT/skills/handoff/scripts/handoff-spawn" --issue "$ISSUE" --dry-run 2>&1)" || rc=$?
  [[ "$rc" -eq 1 ]] || fail "headless without --stage should exit 1, got $rc ($err)"
  rc=0
  err="$(BERCAIL_CONFIG="$TMP_DIR/no-config.toml" \
    "$ROOT/skills/handoff/scripts/handoff-spawn" --branch feat --stage bstack --issue "$ISSUE" --clean --workspace w1 2>&1)" || rc=$?
  [[ "$rc" -eq 1 ]] || fail "bstack off should exit 1, got $rc ($err)"
  printf '%s' "$err" | grep -q 'needs bstack on' || fail "bstack off message: $err"
  printf '%s' "$err" | grep -q 'wt ' && fail "must fail before wt: $err"
  rc=0
  printf '[bstack]\nenabled = true\n' >"$TMP_DIR/bstack-on.toml"
  err="$(BERCAIL_CONFIG="$TMP_DIR/bstack-on.toml" HANDOFF_PI_PROFILE="$TMP_DIR/no-pi-profile" \
    "$ROOT/skills/handoff/scripts/handoff-spawn" --branch feat --stage bstack --issue "$ISSUE" --clean 2>&1)" || rc=$?
  [[ "$rc" -eq 1 ]] || fail "missing lead profile should exit 1, got $rc ($err)"
  printf '%s' "$err" | grep -q 'lead profile is missing' || fail "missing profile message: $err"
  printf '%s' "$err" | grep -q 'wt ' && fail "must fail before wt: $err"
  rc=0
  err="$(BERCAIL_CONFIG="$TMP_DIR/bstack-on.toml" \
    "$ROOT/skills/handoff/scripts/handoff-spawn" --branch feat --stage autopilot --issue "$ISSUE" --clean 2>&1)" || rc=$?
  [[ "$rc" -eq 1 ]] || fail "autopilot --branch should exit 1, got $rc ($err)"
  printf '%s' "$err" | grep -q 'headless' || fail "autopilot --branch message: $err"
  rc=0
  err="$("$ROOT/skills/handoff/scripts/handoff-spawn" --stage bstack --issue "$ISSUE" --binary pi --dry-run 2>&1)" || rc=$?
  [[ "$rc" -eq 2 ]] || fail "--binary should be gone (usage), got $rc ($err)"
  printf 'PASS: --stage is required; a Pi desk needs bstack on and a lead profile\n'
}

test_resume_must_be_a_uuid() {
  local wt="$TMP_DIR/resume-uuid" rc=0 err stub="$TMP_DIR/bin/pi-quiet"
  _start_fixture "$wt"
  mkdir -p "$TMP_DIR/bin"
  # A Pi run whose log has no session header keeps the minted uuid.
  printf '#!/usr/bin/env bash\njq -nc %s >"$BERCAIL_RESULT_PATH"\n' \
    "'{status:\"ready\", summary:\"planned the fix\"}'" >"$stub"
  chmod +x "$stub"
  export HANDOFF_PI_BIN="$stub"
  (cd "$wt" && "$ROOT/skills/handoff/scripts/handoff-spawn" --stage bstack --issue "$ISSUE" --worktree "$wt" >/dev/null) || rc=$?
  [[ "$rc" -eq 0 ]] || fail "a ready result without a session header should still exit 0, got $rc"
  jq -e '.status == "ready" and (.session_id | test("^[0-9a-fA-F-]{36}$")) and (.summary | startswith("planned the fix")) and (.summary | test("cannot be resumed") | not)' \
    "$wt/.bercail/handoff-result.json" >/dev/null \
    || fail "minted uuid stays when the log has no header: $(cat "$wt/.bercail/handoff-result.json")"
  rc=0
  (cd "$wt" && "$ROOT/skills/handoff/scripts/handoff-spawn" --stage bstack --issue "$ISSUE" --worktree "$wt" --resume none --dry-run >/dev/null 2>&1) || rc=$?
  [[ "$rc" -eq 1 ]] || fail "--resume none must be refused, got $rc"
  rc=0
  err="$(cd "$wt" && "$ROOT/skills/handoff/scripts/handoff-spawn" --stage bstack --issue "$ISSUE" --worktree "$wt" --resume ses_abc --dry-run 2>&1)" || rc=$?
  [[ "$rc" -eq 1 ]] || fail "non-uuid resume should exit 1, got $rc"
  printf '%s' "$err" | grep -q 'must be a uuid' || fail "resume message: $err"
  unset HANDOFF_PI_BIN
  printf 'PASS: Pi keeps the minted uuid; --resume refuses anything that is not a uuid\n'
}

test_headless_prompt_points_at_the_issue
test_missing_pi_blocks_without_fallback
test_dry_run_prints_pi_stages
test_missing_bd_or_issue_blocks
test_stage_is_required_and_branch_needs_bstack
test_resume_must_be_a_uuid

_fake_gt() {
  local bin="$1" log="$2" body="$3"
  mkdir -p "$bin"
  : >"$log"
  cat >"$bin/gt" <<EOF
#!/usr/bin/env bash
printf '%s\\n' "\$*" >>"$log"
args=" \$* "
$body
EOF
  chmod +x "$bin/gt"
}

_track_fixture() {
  local repo="$1" sibling="$1.feat"
  git_init "$repo"
  git -C "$repo" branch parent-branch
  git -C "$repo" worktree add -q -b feat "$sibling" parent-branch
  graphite_auto_init "$repo"
}

test_track_already_tracked_does_nothing() {
  local repo="$TMP_DIR/tr-done" bin="$TMP_DIR/tr-done-bin" log="$TMP_DIR/tr-done.log"
  _track_fixture "$repo"
  _fake_gt "$bin" "$log" 'exit 0'
  PATH="$bin:$PATH" handoff_track_graphite "$repo.feat" parent-branch
  grep -q ' track ' "$log" && fail "a branch with a parent is not tracked again: $(cat "$log")"
  printf 'PASS: a branch gt already knows is left alone\n'
}

test_track_tracks_an_untracked_parent_first() {
  local repo="$TMP_DIR/tr-parent" bin="$TMP_DIR/tr-parent-bin" log="$TMP_DIR/tr-parent.log" order
  _track_fixture "$repo"
  # Like gt: the new branch can't sit on a parent until that parent is tracked.
  _fake_gt "$bin" "$log" "
case \"\$args\" in
  *' parent --no-interactive '*) exit 1 ;;
  *' track parent-branch --parent master '*) : >'$TMP_DIR/tr-parent-tracked'; exit 0 ;;
  *' track --parent parent-branch '*) [[ -f '$TMP_DIR/tr-parent-tracked' ]] ;;
  *' branch info '*) echo 'ERROR: Cannot perform this operation on untracked branch parent-branch.' >&2; exit 1 ;;
  *) exit 7 ;;
esac"
  PATH="$bin:$PATH" handoff_track_graphite "$repo.feat" parent-branch
  order="$(grep -c . "$log")"
  [[ "$order" -eq 5 ]] || fail "parent check, try, is parent tracked, track parent, retry; log=$(cat "$log")"
  [[ "$(sed -n 5p "$log")" == "--cwd $repo.feat track --parent parent-branch --no-interactive" ]] \
    || fail "the branch should end up on its real parent; log=$(cat "$log")"
  grep -q -- '--force' "$log" && fail "--force must never run: $(cat "$log")"
  printf 'PASS: an untracked --base is tracked on trunk first, then the branch on it\n'
}

test_track_falls_back_to_trunk_with_a_warning() {
  local repo="$TMP_DIR/tr-trunk" bin="$TMP_DIR/tr-trunk-bin" log="$TMP_DIR/tr-trunk.log" err
  _track_fixture "$repo"
  _fake_gt "$bin" "$log" "
case \"\$args\" in
  *' track --parent master '*) exit 0 ;;
  *' branch info '*) echo 'ERROR: Could not find branch parent-branch.' >&2; exit 1 ;;
  *) exit 1 ;;
esac"
  err="$(PATH="$bin:$PATH" handoff_track_graphite "$repo.feat" parent-branch 2>&1)" \
    || fail "fallback must not fail: $err"
  [[ "$(tail -1 "$log")" == "--cwd $repo.feat track --parent master --no-interactive" ]] \
    || fail "should end on trunk; log=$(cat "$log")"
  printf '%s' "$err" | grep -q 'parent-branch' || fail "warn that the parent was not used: $err"
  printf '%s' "$err" | grep -qE '\[[0-9]+\]' && fail "job notices on stderr: $err"
  grep -q -- '--force' "$log" && fail "--force must never run: $(cat "$log")"
  printf 'PASS: when the parent cannot be tracked the branch goes on trunk, with a warning\n'
}

test_track_leaves_a_tracked_parent_in_its_stack() {
  local repo="$TMP_DIR/tr-stack" bin="$TMP_DIR/tr-stack-bin" log="$TMP_DIR/tr-stack.log" err
  _track_fixture "$repo"
  # The parent is tracked, so this failure is about something else.
  _fake_gt "$bin" "$log" "
case \"\$args\" in
  *' branch info --branch parent-branch '*) exit 0 ;;
  *) exit 1 ;;
esac"
  err="$(PATH="$bin:$PATH" handoff_track_graphite "$repo.feat" parent-branch 2>&1)" || fail "must not fail: $err"
  grep -q ' track parent-branch ' "$log" && fail "re-tracking a tracked parent cuts it out of its stack: $(cat "$log")"
  grep -q ' track --parent master ' "$log" && fail "a stacked branch must not silently move to trunk: $(cat "$log")"
  printf '%s' "$err" | grep -q 'gt track --parent parent-branch' || fail "warn with the real parent: $err"
  printf 'PASS: a gt failure never re-parents a tracked --base or moves the branch to trunk\n'
}

# A locked store fails every gt call, then clears: the repair must not run on that.
test_track_transient_failure_never_touches_the_parent() {
  local repo="$TMP_DIR/tr-lock" bin="$TMP_DIR/tr-lock-bin" log="$TMP_DIR/tr-lock.log" err
  _track_fixture "$repo"
  _fake_gt "$bin" "$log" "
case \"\$args\" in
  *' track parent-branch '*) exit 0 ;;
  *' track --parent master '*) exit 0 ;;
  *) echo 'database is locked' >&2; exit 1 ;;
esac"
  err="$(PATH="$bin:$PATH" handoff_track_graphite "$repo.feat" parent-branch 2>&1)" || fail "must not fail: $err"
  grep -q ' track parent-branch ' "$log" && fail "a failure that is not 'untracked' re-parented the base: $(cat "$log")"
  grep -q ' track --parent master ' "$log" && fail "a failure that is not 'untracked' moved the branch to trunk: $(cat "$log")"
  printf '%s' "$err" | grep -q 'gt track --parent parent-branch' || fail "warn with the real parent: $err"
  printf 'PASS: only an untracked or unknown --base is repaired; a locked store changes nothing\n'
}

test_track_child_left_behind_does_not_hold_the_caller() {
  local repo="$TMP_DIR/tr-left" bin="$TMP_DIR/tr-left-bin" log="$TMP_DIR/tr-left.log" err start
  _track_fixture "$repo"
  _fake_gt "$bin" "$log" "
case \"\$args\" in
  *' parent --no-interactive '*) exit 1 ;;
  *' track '*) sleep 300 & exit 1 ;;
  *) exit 0 ;;
esac"
  start=$SECONDS
  err="$(PATH="$bin:$PATH" handoff_track_graphite "$repo.feat" parent-branch 2>&1)" || fail "must not fail: $err"
  [[ $((SECONDS - start)) -lt 15 ]] || fail "a child gt left behind held the capture for $((SECONDS - start))s"
  printf 'PASS: a child gt leaves behind cannot hold the pipes of the caller\n'
}

test_track_bad_timeout_is_ignored() {
  local repo="$TMP_DIR/tr-badt" bin="$TMP_DIR/tr-badt-bin" log="$TMP_DIR/tr-badt.log" value err
  _track_fixture "$repo"
  for value in abc 1.5 30s 0 ''; do
    _fake_gt "$bin" "$log" "case \"\$args\" in *' parent --no-interactive '*) exit 1 ;; esac"
    err="$( (set -e; PATH="$bin:$PATH" HANDOFF_GT_TIMEOUT="$value" handoff_track_graphite "$repo.feat"; printf 'still-here\n') 2>&1)" \
      || fail "HANDOFF_GT_TIMEOUT=$value aborted: $err"
    printf '%s' "$err" | grep -q 'still-here' || fail "HANDOFF_GT_TIMEOUT=$value: $err"
    grep -q ' track --parent master ' "$log" || fail "HANDOFF_GT_TIMEOUT=$value skipped gt: $(cat "$log")"
  done
  printf 'PASS: a bad HANDOFF_GT_TIMEOUT falls back to the default\n'
}

test_track_failure_warns_and_continues() {
  local repo="$TMP_DIR/tr-fail" bin="$TMP_DIR/tr-fail-bin" log="$TMP_DIR/tr-fail.log" err rc=0
  _track_fixture "$repo"
  _fake_gt "$bin" "$log" 'exit 1'
  err="$( (set -e; PATH="$bin:$PATH" handoff_track_graphite "$repo.feat" parent-branch; printf 'still-here\n') 2>&1)" || rc=$?
  [[ "$rc" -eq 0 ]] || fail "a failed gt must not abort: rc=$rc $err"
  printf '%s' "$err" | grep -q 'still-here' || fail "must keep going: $err"
  printf '%s' "$err" | grep -q 'gt track' || fail "must warn with what to run: $err"
  grep -q -- '--force' "$log" && fail "--force must never run: $(cat "$log")"
  printf 'PASS: gt track failing warns and returns\n'
}

test_track_timeout_is_bounded_and_kills_the_group() {
  local repo="$TMP_DIR/tr-hang" bin="$TMP_DIR/tr-hang-bin" log="$TMP_DIR/tr-hang.log" err start body
  _track_fixture "$repo"
  # The sleep is a grandchild holding stderr: $(...) below only returns once it is dead.
  for body in \
    'sleep 300 & wait' \
    'trap "" TERM; sleep 300 & wait; sleep 300' \
    'case "$args" in *" parent "*) exit 1 ;; esac; sleep 300 & wait'; do
    _fake_gt "$bin" "$log" "$body"
    start=$SECONDS
    err="$(PATH="$bin:$PATH" HANDOFF_GT_TIMEOUT=1 handoff_track_graphite "$repo.feat" parent-branch 2>&1)" \
      || fail "a hung gt must not abort: $err"
    [[ $((SECONDS - start)) -lt 15 ]] || fail "hung gt held the spawn for $((SECONDS - start))s: $body"
    printf '%s' "$err" | grep -q 'did not finish' || fail "must warn that gt hung: $err"
    printf '%s' "$err" | grep -qE '\[[0-9]+\]' && fail "job notices on stderr: $err"
    [[ "$(grep -c ' track ' "$log")" -le 1 ]] || fail "no more gt once one has hung: $(cat "$log")"
  done
  printf 'PASS: a hung gt is killed with its children, warned about, and not retried\n'
}

# Spawns usually run from a terminal, where job control has a foreground to manage.
test_track_timeout_under_a_terminal() {
  # shellcheck disable=SC2015 # Either an absent script or an unsupported -qec skips.
  command -v script >/dev/null 2>&1 && script -qec true /dev/null >/dev/null 2>&1 || {
    printf 'SKIP: no util-linux script for a pty\n'
    return 0
  }
  local repo="$TMP_DIR/tr-pty" bin="$TMP_DIR/tr-pty-bin" log="$TMP_DIR/tr-pty.log" run="$TMP_DIR/tr-pty.sh" out rc=0
  _track_fixture "$repo"
  _fake_gt "$bin" "$log" 'sleep 300 & wait'
  cat >"$run" <<EOF
source "$ROOT/skills/handoff/scripts/handoff-spawn"
PATH="$bin:\$PATH" HANDOFF_GT_TIMEOUT=1 handoff_track_graphite "$repo.feat" parent-branch
echo "returned rc=\$?"
EOF
  # handoff_bounded: a regression here is a hang, so the suite must not wait on it.
  out="$(handoff_bounded 20 script -qec "bash $run" /dev/null </dev/null)" || rc=$?
  [[ "$rc" -eq 0 ]] || fail "a hung gt under a terminal held the spawn: rc=$rc $out"
  printf '%s' "$out" | grep -q 'returned rc=0' || fail "should return 0: $out"
  printf '%s' "$out" | grep -q 'did not finish' || fail "should warn: $out"
  printf '%s' "$out" | grep -qE '\[[0-9]+\]\+?[[:space:]]+(Done|Exit|Terminated|Killed)' && fail "job notices on stderr: $out"
  printf 'PASS: a hung gt is bounded under a controlling terminal, with no job notices\n'
}

test_track_ctrl_c_kills_gt() {
  # shellcheck disable=SC2015 # Either an absent script or an unsupported -qec skips.
  command -v script >/dev/null 2>&1 && script -qec true /dev/null >/dev/null 2>&1 || {
    printf 'SKIP: no util-linux script for a pty\n'
    return 0
  }
  local repo="$TMP_DIR/tr-int" bin="$TMP_DIR/tr-int-bin" log="$TMP_DIR/tr-int.log" run="$TMP_DIR/tr-int.sh" pids="$TMP_DIR/tr-int.pid" pid
  _track_fixture "$repo"
  _fake_gt "$bin" "$log" "sleep 300 & echo \$! >'$pids'; wait"
  cat >"$run" <<EOF
source "$ROOT/skills/handoff/scripts/handoff-spawn"
PATH="$bin:\$PATH" handoff_track_graphite "$repo.feat"
: >"$TMP_DIR/tr-int-carried-on"
EOF
  # Not handoff_bounded: its background job does not read this pipe. util-linux has timeout.
  (sleep 1; printf '\003'; sleep 1) | timeout 15 script -qec "bash $run" /dev/null >/dev/null 2>&1 || true
  [[ -s "$pids" ]] || fail "the fake gt never ran: $(cat "$log")"
  pid="$(<"$pids")"
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid"
    fail "Ctrl-C left gt running with nothing to bound it"
  fi
  [[ "$(grep -c . "$log")" -eq 1 ]] || fail "Ctrl-C must stop the gt calls: $(cat "$log")"
  [[ ! -e "$TMP_DIR/tr-int-carried-on" ]] || fail "Ctrl-C must stop the spawn"
  printf 'PASS: Ctrl-C during a hung gt kills it and stops the spawn\n'
}

test_track_output_stays_off_stdout() {
  local repo="$TMP_DIR/tr-out" bin="$TMP_DIR/tr-out-bin" log="$TMP_DIR/tr-out.log" out
  _track_fixture "$repo"
  _fake_gt "$bin" "$log" "echo chatter; case \"\$args\" in *' parent --no-interactive '*) exit 1 ;; esac"
  out="$(PATH="$bin:$PATH" handoff_track_graphite "$repo.feat" 2>/dev/null)"
  [[ -z "$out" ]] || fail "spawn's stdout is the JSON result, got: $out"
  printf 'PASS: gt output never reaches the JSON on stdout\n'
}

test_track_sigterm_kills_gt() {
  command -v setsid >/dev/null 2>&1 || {
    printf 'SKIP: no setsid for the SIGTERM process-group test\n'
    return 0
  }
  local repo="$TMP_DIR/tr-term" bin="$TMP_DIR/tr-term-bin" log="$TMP_DIR/tr-term.log"
  local run="$TMP_DIR/tr-term.sh" ready="$TMP_DIR/tr-term.ready" pidfile="$TMP_DIR/tr-term.pid"
  local runner group pid attempt
  _track_fixture "$repo"
  _fake_gt "$bin" "$log" "echo \$\$ >'$pidfile'; exec sleep 300"
  cat >"$run" <<EOF
source "$ROOT/skills/handoff/scripts/handoff-spawn"
echo \$\$ >"$ready"
PATH="$bin:\$PATH" HANDOFF_GT_TIMEOUT=1 handoff_track_graphite "$repo.feat"
EOF
  # The caller and watchdog share this new group; gt has its own.
  setsid bash "$run" >"$TMP_DIR/tr-term.out" 2>&1 &
  runner=$!
  for ((attempt=0; attempt<50; attempt++)); do
    [[ ! -s "$ready" || ! -s "$pidfile" ]] || break
    sleep 0.1
  done
  if [[ ! -s "$ready" || ! -s "$pidfile" ]]; then
    kill -TERM "$runner" 2>/dev/null || true
    wait "$runner" 2>/dev/null || true
    fail "the SIGTERM fixture did not start: $(cat "$TMP_DIR/tr-term.out")"
  fi
  group="$(<"$ready")"
  pid="$(<"$pidfile")"
  kill -TERM -- "-$group"
  wait "$runner" 2>/dev/null || true
  for ((attempt=0; attempt<30; attempt++)); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL -- "-$pid" 2>/dev/null || true
    fail "SIGTERM killed the watchdog but left gt running"
  fi
  printf 'PASS: SIGTERM to the spawn process group also kills gt\n'
}

test_track_trunk_from_trunks_list() {
  local repo="$TMP_DIR/tr-list" bin="$TMP_DIR/tr-list-bin" log="$TMP_DIR/tr-list.log"
  _track_fixture "$repo"
  printf '{"trunks":[{"name":"develop"}]}\n' >"$(git_dir "$repo")/.graphite_repo_config"
  _fake_gt "$bin" "$log" "case \"\$args\" in *' parent --no-interactive '*) exit 1 ;; esac"
  PATH="$bin:$PATH" handoff_track_graphite "$repo.feat"
  grep -qxF -- "--cwd $repo.feat track --parent develop --no-interactive" "$log" \
    || fail "a config with only trunks[] names trunk; log=$(cat "$log")"
  printf 'PASS: trunk is read from trunks[] when trunk is absent\n'
}

test_track_on_without_config_warns() {
  local repo="$TMP_DIR/tr-nocfg" bin="$TMP_DIR/tr-nocfg-bin" log="$TMP_DIR/tr-nocfg.log" err
  git_init "$repo"
  _fake_gt "$bin" "$log" 'exit 0'
  err="$(PATH="$bin:$PATH" handoff_track_graphite "$repo" 2>&1)" || fail "must not fail: $err"
  [[ ! -s "$log" ]] || fail "gt auto-inits on any command; never run it here: $(cat "$log")"
  printf '%s' "$err" | grep -q 'gt init' || fail "should say to run gt init: $err"
  printf 'PASS: Graphite forced on with no gt config warns instead of letting gt auto-init\n'
}

# A whole --branch spawn with stubs for everything but git and the gt under test.
_spawn_branch() {
  local name="$1" repo="$2" bin="$3" home="$4" base="${5:-}"
  mkdir -p "$home/.config/worktrunk"
  cat >"$bin/wt" <<'WT'
#!/usr/bin/env bash
branch="" base=HEAD
while [[ $# -gt 0 ]]; do
  case "$1" in
    --create) branch="$2"; shift 2 ;;
    --base) base="$2"; shift 2 ;;
    *) shift ;;
  esac
done
main="$(git worktree list --porcelain | awk '/^worktree / { print substr($0, 10); exit }')"
git -C "$main" worktree add -q -b "$branch" "$main.$branch" "$base"
WT
  cat >"$bin/herdr-app" <<'HERDR'
#!/bin/sh
printf '%s\n' '{"space":"sp1"}'
HERDR
  chmod +x "$bin/wt" "$bin/herdr-app"
  _pi_ready
  printf '[bstack]\nenabled = true\n' >"$TMP_DIR/$name-bstack.toml"
  cat >"$home/.config/worktrunk/herdr-layout.sh" <<HELPER
_wt_herdr_keep_user_focus() { :; }
_wt_generate_session_name() { printf 'Lbl'; }
wt_herdr_handoff_agent() { : >"$TMP_DIR/$name-desk-started"; }
_wt_herdr_space_by_folder() { printf 'sp1'; }
_wt_herdr_space_desk() { printf 'desk1'; }
HELPER
  _bd_stub
  : >"$BD_COMMENTS"
  (
    cd "$repo"
    HOME="$home" PATH="$bin:$PATH" HERDR_APP_BIN="$bin/herdr-app" HANDOFF_GT_TIMEOUT=1 \
      XDG_STATE_HOME="$TMP_DIR/$name-state" BERCAIL_BIN="$TMP_DIR/no-bercail" \
      BERCAIL_CONFIG="$TMP_DIR/$name-bstack.toml" HANDOFF_PI_PROFILE="$HANDOFF_PI_PROFILE" \
      "$ROOT/skills/handoff/scripts/handoff-spawn" \
      --branch feat --stage bstack --issue "$ISSUE" --clean ${base:+--base "$base"}
  )
}

test_spawn_in_a_plain_repo_with_a_stray_config() {
  local repo="$TMP_DIR/sp-stray" bin="$TMP_DIR/sp-stray-bin" log="$TMP_DIR/sp-stray.log" out
  git_init "$repo"
  graphite_auto_init "$repo"
  _fake_gt "$bin" "$log" 'exit 1'
  out="$(_spawn_branch sp-stray "$repo" "$bin" "$TMP_DIR/sp-stray-home")" || fail "spawn failed: $out"
  printf '%s' "$out" | jq -e '.graphite == false and .agent_started == true' >/dev/null || fail "spawn json: $out"
  [[ ! -s "$log" ]] || fail "gt must not run in a plain repo: $(cat "$log")"
  grep -q 'Use gt' "$BD_COMMENTS" && fail "no gt intro in a plain repo: $(cat "$BD_COMMENTS")"
  grep -q 'bercail handoff: stage bstack' "$BD_COMMENTS" || fail "intro missing: $(cat "$BD_COMMENTS")"
  printf 'PASS: a plain repo with a stray config spawns with no gt and no gt intro\n'
}

test_spawn_survives_a_hung_gt() {
  local repo="$TMP_DIR/sp-hang" bin="$TMP_DIR/sp-hang-bin" log="$TMP_DIR/sp-hang.log" out
  git_init "$repo"
  graphite_auto_init "$repo"
  git -C "$repo" update-ref refs/branch-metadata/other HEAD
  _fake_gt "$bin" "$log" 'sleep 300 & wait'
  out="$(_spawn_branch sp-hang "$repo" "$bin" "$TMP_DIR/sp-hang-home" 2>"$TMP_DIR/sp-hang.err")" \
    || fail "a hung gt must not abort the spawn: $out $(cat "$TMP_DIR/sp-hang.err")"
  printf '%s' "$out" | jq -e '.graphite == true and .agent_started == true' >/dev/null || fail "spawn json: $out"
  [[ -f "$TMP_DIR/sp-hang-desk-started" ]] || fail "the desk must still start"
  grep -q 'did not finish' "$TMP_DIR/sp-hang.err" || fail "warn: $(cat "$TMP_DIR/sp-hang.err")"
  grep -q 'Use gt' "$BD_COMMENTS" || fail "a real Graphite repo keeps the gt intro: $(cat "$BD_COMMENTS")"
  printf 'PASS: a hung gt warns and the desk still starts\n'
}

test_spawn_without_sqlite_skips_gt() {
  local repo="$TMP_DIR/sp-nosql" bin="$TMP_DIR/sp-nosql-bin" log="$TMP_DIR/sp-nosql.log" out
  git_init "$repo"
  graphite_auto_init "$repo"
  : >"$(git_dir "$repo")/.graphite_metadata.db"
  _fake_gt "$bin" "$log" 'exit 1'
  out="$(HANDOFF_SQLITE3_BIN="$TMP_DIR/no-sqlite3" \
    _spawn_branch sp-nosql "$repo" "$bin" "$TMP_DIR/sp-nosql-home" 2>"$TMP_DIR/sp-nosql.err")" \
    || fail "spawn failed: $out"
  printf '%s' "$out" | jq -e '.graphite == false and .agent_started == true' >/dev/null || fail "spawn json: $out"
  [[ ! -s "$log" ]] || fail "gt must not run when detection is inconclusive: $(cat "$log")"
  grep -q 'Use gt' "$BD_COMMENTS" && fail "no gt intro without evidence of Graphite"
  grep -q 'cannot read' "$TMP_DIR/sp-nosql.err" || fail "warn about sqlite3: $(cat "$TMP_DIR/sp-nosql.err")"
  printf 'PASS: missing sqlite3 cannot turn a plain repo into Graphite or block the desk\n'
}

test_spawn_survives_a_failed_gt() {
  local repo="$TMP_DIR/sp-fail" bin="$TMP_DIR/sp-fail-bin" log="$TMP_DIR/sp-fail.log" out
  git_init "$repo"
  graphite_auto_init "$repo"
  git -C "$repo" update-ref refs/branch-metadata/other HEAD
  _fake_gt "$bin" "$log" 'exit 1'
  out="$(_spawn_branch sp-fail "$repo" "$bin" "$TMP_DIR/sp-fail-home" 2>"$TMP_DIR/sp-fail.err")" \
    || fail "a failed gt must not abort the spawn: $out"
  printf '%s' "$out" | jq -e '.graphite == true and .agent_started == true' >/dev/null || fail "spawn json: $out"
  [[ -f "$TMP_DIR/sp-fail-desk-started" ]] || fail "the desk must still start"
  grep -q 'gt failed' "$TMP_DIR/sp-fail.err" || fail "warn: $(cat "$TMP_DIR/sp-fail.err")"
  printf 'PASS: a failed gt warns and the desk still starts\n'
}

test_spawn_real_graphite_tracks_trunk() {
  local repo="$TMP_DIR/sp-real" bin="$TMP_DIR/sp-real-bin" log="$TMP_DIR/sp-real.log" out
  git_init "$repo"
  graphite_auto_init "$repo"
  git -C "$repo" update-ref refs/branch-metadata/other HEAD
  _fake_gt "$bin" "$log" "case \"\$args\" in *' parent --no-interactive '*) exit 1 ;; esac"
  out="$(_spawn_branch sp-real "$repo" "$bin" "$TMP_DIR/sp-real-home" 2>/dev/null)" || fail "spawn failed: $out"
  printf '%s' "$out" | jq -e '.graphite == true and .agent_started == true' >/dev/null || fail "spawn json: $out"
  grep -qxF -- "--cwd $repo.feat track --parent master --no-interactive" "$log" \
    || fail "a real stack still gets gt track on trunk; log=$(cat "$log")"
  grep -c ' track ' "$log" | grep -qx 1 || fail "one track call is enough: $(cat "$log")"
  grep -q 'Use gt' "$BD_COMMENTS" || fail "a real Graphite repo keeps the gt intro: $(cat "$BD_COMMENTS")"
  printf 'PASS: a real Graphite repo spawns with gt track and the gt intro, as before\n'
}

test_spawn_real_stack_tracks_on_its_base() {
  local repo="$TMP_DIR/sp-stack" bin="$TMP_DIR/sp-stack-bin" log="$TMP_DIR/sp-stack.log" out
  git_init "$repo"
  graphite_auto_init "$repo"
  git -C "$repo" branch stack-one
  git -C "$repo" update-ref refs/branch-metadata/stack-one HEAD
  _fake_gt "$bin" "$log" "case \"\$args\" in *' parent --no-interactive '*) exit 1 ;; esac"
  out="$(_spawn_branch sp-stack "$repo" "$bin" "$TMP_DIR/sp-stack-home" stack-one 2>/dev/null)" || fail "spawn failed: $out"
  printf '%s' "$out" | jq -e '.graphite == true and .agent_started == true and .base == "stack-one"' >/dev/null || fail "spawn json: $out"
  [[ "$(grep ' track ' "$log")" == "--cwd $repo.feat track --parent stack-one --no-interactive" ]] \
    || fail "a stack gets exactly one gt track, on its base; log=$(cat "$log")"
  grep -q 'Use gt' "$BD_COMMENTS" || fail "a real Graphite repo keeps the gt intro: $(cat "$BD_COMMENTS")"
  printf 'PASS: a real stack spawned with --base is tracked on that base, as before\n'
}

_fake_logger() {
  local bin="$1" name="$2" log="$3"
  mkdir -p "$bin"
  : >"$log"
  cat >"$bin/$name" <<EOF
#!/bin/sh
printf '%s\n' "\$(pwd) \$*" >>"$log"
exit 0
EOF
  chmod +x "$bin/$name"
}

test_gh_base_inits_a_new_stack_and_refuses_a_middle_parent() {
  local repo="$TMP_DIR/gh-init" bin="$TMP_DIR/gh-init-bin" log="$TMP_DIR/gh-init.log" trunk
  git_init "$repo"
  trunk="$(git -C "$repo" branch --show-current)"
  git -C "$repo" branch parent-branch
  git -C "$repo" worktree add -q -b feat "$repo.feat" parent-branch
  _fake_logger "$bin" gh "$log"
  _fake_logger "$bin" gt "$TMP_DIR/gh-init-gt.log"
  PATH="$bin:$PATH" handoff_track_gh "$repo.feat" feat parent-branch
  grep -q "stack init --base $trunk parent-branch feat" "$log" \
    || fail "a new dependent is gh stack init; log=$(cat "$log")"
  [[ "$(awk '{ print $1 }' "$log")" == "$repo.feat" ]] || fail "init runs in the child worktree: $(cat "$log")"
  [[ ! -s "$TMP_DIR/gh-init-gt.log" ]] || fail "gt must not run for gh: $(cat "$TMP_DIR/gh-init-gt.log")"
  local catalog
  catalog="$(git_dir "$repo")/gh-stack"
  jq -n --arg p parent-branch '{stacks:[{trunk:{branch:"main"},branches:[{branch:"bottom"},{branch:$p},{branch:"tip"}]}]}' >"$catalog"
  : >"$log"
  local err
  err="$(PATH="$bin:$PATH" handoff_track_gh "$repo.feat" feat parent-branch 2>&1)" || fail "a middle parent must not fail the spawn: $err"
  [[ ! -s "$log" ]] || fail "a middle parent must not call gh stack: $(cat "$log")"
  printf '%s' "$err" | grep -q 'not the top' || fail "say why it was not attached: $err"
  printf 'PASS: gh --base inits a stack, and a middle parent is not attached\n'
}

test_gh_base_adds_from_the_parent_worktree() {
  local repo="$TMP_DIR/gh-add" bin="$TMP_DIR/gh-add-bin" log="$TMP_DIR/gh-add.log"
  git_init "$repo"
  git -C "$repo" branch parent-branch
  git -C "$repo" worktree add -q "$repo.parent" parent-branch
  git -C "$repo" worktree add -q -b feat "$repo.feat" parent-branch
  jq -n '{stacks:[{trunk:{branch:"main"},branches:[{branch:"parent-branch"}]}]}' >"$(git_dir "$repo")/gh-stack"
  _fake_logger "$bin" gh "$log"
  PATH="$bin:$PATH" handoff_track_gh "$repo.feat" feat parent-branch
  [[ "$(cat "$log")" == "$repo.parent stack add feat" ]] \
    || fail "add runs in the worktree that has the top checked out; log=$(cat "$log")"
  printf 'PASS: gh stack add uses the parent worktree and does not switch main\n'
}

test_origin_base_tracks_locally() {
  local repo="$TMP_DIR/ori-track" bin="$TMP_DIR/ori-track-bin" log="$TMP_DIR/ori-track.log"
  git_init "$repo"
  git -C "$repo" branch parent-branch
  git -C "$repo" worktree add -q -b feat "$repo.feat" parent-branch
  _fake_logger "$bin" origin "$log"
  _fake_logger "$bin" gt "$TMP_DIR/ori-track-gt.log"
  PATH="$bin:$PATH" handoff_track_origin "$repo.feat" feat parent-branch
  [[ "$(cat "$log")" == "$repo.feat stack track feat --onto parent-branch --json" ]] \
    || fail "origin stack track --onto; log=$(cat "$log")"
  [[ ! -s "$TMP_DIR/ori-track-gt.log" ]] || fail "gt must not run for origin"
  printf 'PASS: origin --base is origin stack track, local, not gt\n'
}

test_spawn_gh_base_does_not_call_gt() {
  local repo="$TMP_DIR/sp-gh" bin="$TMP_DIR/sp-gh-bin" log="$TMP_DIR/sp-gh.log" gtlog="$TMP_DIR/sp-gh-gt.log" out
  git_init "$repo"
  git -C "$repo" branch parent-branch
  _fake_logger "$bin" gh "$log"
  _fake_logger "$bin" gt "$gtlog"
  out="$(_spawn_branch sp-gh "$repo" "$bin" "$TMP_DIR/sp-gh-home" parent-branch 2>"$TMP_DIR/sp-gh.err")" \
    || fail "spawn failed: $out $(cat "$TMP_DIR/sp-gh.err")"
  printf '%s' "$out" | jq -e '.graphite == false and .agent_started == true and .base == "parent-branch" and (has("git")|not)' >/dev/null \
    || fail "spawn json keeps the old contract: $out"
  grep -q 'stack init' "$log" || fail "spawn --base on gh records a stack; log=$(cat "$log")"
  [[ ! -s "$gtlog" ]] || fail "gt must not run: $(cat "$gtlog")"
  grep -q 'Use gt' "$BD_COMMENTS" && fail "no gt intro on gh: $(cat "$BD_COMMENTS")"
  grep -q 'gh stack' "$BD_COMMENTS" || fail "the desk is told to use gh stack: $(cat "$BD_COMMENTS")"
  printf 'PASS: a gh --base spawn uses gh stack, not gt, and does not change the result JSON\n'
}

test_track_already_tracked_does_nothing
test_track_tracks_an_untracked_parent_first
test_track_falls_back_to_trunk_with_a_warning
test_track_leaves_a_tracked_parent_in_its_stack
test_track_transient_failure_never_touches_the_parent
test_track_child_left_behind_does_not_hold_the_caller
test_track_bad_timeout_is_ignored
test_track_ctrl_c_kills_gt
test_track_sigterm_kills_gt
test_track_failure_warns_and_continues
test_track_timeout_is_bounded_and_kills_the_group
test_track_timeout_under_a_terminal
test_track_output_stays_off_stdout
test_track_trunk_from_trunks_list
test_track_on_without_config_warns
test_spawn_in_a_plain_repo_with_a_stray_config
test_spawn_survives_a_hung_gt
test_spawn_without_sqlite_skips_gt
test_spawn_survives_a_failed_gt
test_spawn_real_graphite_tracks_trunk
test_spawn_real_stack_tracks_on_its_base
test_gh_base_inits_a_new_stack_and_refuses_a_middle_parent
test_gh_base_adds_from_the_parent_worktree
test_origin_base_tracks_locally
test_spawn_gh_base_does_not_call_gt

test_issue_title_normalises_and_degrades() {
  local wt="$TMP_DIR/title-norm" got err long want messy
  mkdir -p "$wt"
  _bd_stub
  long="$(printf '%70s' '' | tr ' ' 'x')"
  want="${long:0:59}"$'…'
  got="$(BD_TITLE="$long" handoff_issue_title "$wt" "$ISSUE")" || fail "title lookup failed"
  [[ "$got" == "$want" ]] || fail "70-char title should be 60 with an ellipsis: ${#got} [$got]"
  [[ "$(handoff_issue_prompt "$ISSUE" "$got")" == "Your job is beads issue $ISSUE: $want Run \`bd show $ISSUE\` (read its comments too) and do the work it describes." ]] \
    || fail "truncated title in the prompt: $(handoff_issue_prompt "$ISSUE" "$got")"

  messy="$(printf 'say "hi" \\ path\n\tand')"
  got="$(BD_TITLE="$messy" handoff_issue_title "$wt" "$ISSUE")" || fail "messy title lookup failed"
  [[ "$got" == 'say "hi" \ path and' ]] || fail "normalised title: [$got]"
  if printf '%s' "$got" | grep -q '[[:cntrl:]]'; then fail "title must be one line: [$got]"; fi

  err="$(HANDOFF_BD_BIN="$TMP_DIR/no-such-bd" handoff_issue_title "$wt" "$ISSUE" 2>&1)" || fail "missing bd must not fail the lookup"
  [[ -z "$err" ]] || fail "missing bd should print nothing: $err"
  err="$(BD_KNOWN=other handoff_issue_title "$wt" "$ISSUE" 2>&1)" || fail "unknown issue must not fail the lookup"
  [[ -z "$err" ]] || fail "unknown issue should print nothing: $err"
  printf 'PASS: a title is truncated, one line, and a missing bd or issue is a bare id\n'
}

test_issue_title_on_headless_runs() {
  local wt="$TMP_DIR/title-head" out stub="$TMP_DIR/bin/title-pi" rc=0
  local title='Show the title' messy long want
  mkdir -p "$TMP_DIR/bin"
  _start_fixture "$wt"
  messy="$(printf 'say "hi" \\ path\n\tand')"
  out="$(cd "$wt" && BD_TITLE="$messy" \
    "$ROOT/skills/handoff/scripts/handoff-spawn" --stage bstack --issue "$ISSUE" --worktree "$wt" --dry-run 2>"$TMP_DIR/title-dry.err")" \
    || fail "dry-run with a title failed: $out $(cat "$TMP_DIR/title-dry.err")"
  [[ ! -s "$TMP_DIR/title-dry.err" ]] || fail "title lookup must not write stderr: $(cat "$TMP_DIR/title-dry.err")"
  printf '%s' "$out" | jq -e --arg id "$ISSUE" --arg t 'say "hi" \ path and' '
    .issue_title == $t
    and (.command[-1] | test("\n|\t") | not)
    and .command[-1] == ("Your job is beads issue " + $id + ": " + $t + ". Run `bd show " + $id + "` (read its comments too) and do the work it describes.")
  ' >/dev/null || fail "dry-run prompt/json: $out"
  [[ ! -f "$wt/.bercail/handoff-result.json" ]] || fail "dry-run must not write a result"

  long="$(printf '%70s' '' | tr ' ' 'x')"
  want="${long:0:59}"$'\u2026'
  out="$(cd "$wt" && BD_TITLE="$long" \
    "$ROOT/skills/handoff/scripts/handoff-spawn" --stage bstack --issue "$ISSUE" --worktree "$wt" --dry-run)"
  printf '%s' "$out" | jq -e --arg t "$want" '.issue_title == $t and (.command[-1] | contains($t))' >/dev/null \
    || fail "dry-run should carry the truncated title: $out"

  out="$(cd "$wt" && BD_KNOWN=other \
    "$ROOT/skills/handoff/scripts/handoff-spawn" --stage bstack --issue "$ISSUE" --worktree "$wt" --dry-run 2>"$TMP_DIR/title-unk.err")" \
    || fail "unknown issue dry-run must not fail: $(cat "$TMP_DIR/title-unk.err")"
  printf '%s' "$out" | jq -e --arg id "$ISSUE" '(has("issue_title") | not) and (.command[-1] | startswith("Your job is beads issue " + $id + "."))' >/dev/null \
    || fail "unknown issue stays a bare id: $out"
  [[ ! -s "$TMP_DIR/title-unk.err" ]] || fail "unknown issue dry-run stderr: $(cat "$TMP_DIR/title-unk.err")"

  cat >"$stub" <<'STUB'
#!/bin/sh
jq -nc '{status:"ready", summary:"done the work"}' >"$BERCAIL_RESULT_PATH"
STUB
  chmod +x "$stub"
  out="$(cd "$wt" && BD_TITLE="$title" HANDOFF_PI_BIN="$stub" \
    "$ROOT/skills/handoff/scripts/handoff-spawn" --stage bstack --issue "$ISSUE" --worktree "$wt")" \
    || fail "titled run failed: $out"
  printf '%s' "$out" | jq -e --arg t "$title" --arg id "$ISSUE" '.issue == $id and .issue_title == $t' >/dev/null \
    || fail "out json: $out"
  jq -e --arg t "$title" --arg id "$ISSUE" \
    '.status == "ready" and .issue == $id and .issue_title == $t' \
    "$wt/.bercail/handoff-result.json" >/dev/null \
    || fail "result file: $(cat "$wt/.bercail/handoff-result.json")"
  handoff_result_ok "$wt/.bercail/handoff-result.json" || fail "stamped result must still pass handoff_result_ok"

  rm -f "$wt/.bercail/handoff-result.json"
  rc=0
  out="$(cd "$wt" && BD_TITLE="$title" HANDOFF_PI_BIN="$TMP_DIR/no-such-pi" \
    "$ROOT/skills/handoff/scripts/handoff-spawn" --stage bstack --issue "$ISSUE" --worktree "$wt" 2>/dev/null)" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "missing harness should still block"
  jq -e --arg t "$title" --arg id "$ISSUE" \
    '.status == "blocked" and .issue == $id and .issue_title == $t' \
    "$wt/.bercail/handoff-result.json" >/dev/null \
    || fail "blocked result should carry the title: $(cat "$wt/.bercail/handoff-result.json")"

  rc=0
  out="$(cd "$wt" && HANDOFF_PI_BIN="$stub" \
    "$ROOT/skills/handoff/scripts/handoff-spawn" --stage bstack --issue bercail-nope --worktree "$wt" 2>/dev/null)" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "unknown issue should block"
  jq -e '.status == "blocked" and .issue == "bercail-nope" and (has("issue_title") | not)' \
    "$wt/.bercail/handoff-result.json" >/dev/null \
    || fail "unknown issue is a bare id: $(cat "$wt/.bercail/handoff-result.json")"

  rc=0
  out="$(cd "$wt" && HANDOFF_BD_BIN="$TMP_DIR/no-such-bd" HANDOFF_PI_BIN="$stub" \
    "$ROOT/skills/handoff/scripts/handoff-spawn" --stage bstack --issue "$ISSUE" --worktree "$wt" 2>"$TMP_DIR/title-bd.err")" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "missing bd should block"
  jq -e --arg id "$ISSUE" '.status == "blocked" and .issue == $id and (has("issue_title") | not)' \
    "$wt/.bercail/handoff-result.json" >/dev/null \
    || fail "missing bd is a bare id: $(cat "$wt/.bercail/handoff-result.json")"
  grep -q 'jq:' "$TMP_DIR/title-bd.err" && fail "missing bd must not surface a title error: $(cat "$TMP_DIR/title-bd.err")"

  out="$(cd "$wt" && HANDOFF_BD_BIN="$TMP_DIR/no-such-bd" \
    "$ROOT/skills/handoff/scripts/handoff-spawn" --stage bstack --issue "$ISSUE" --worktree "$wt" --dry-run 2>"$TMP_DIR/title-bd-dry.err")" \
    || fail "dry-run with missing bd failed: $(cat "$TMP_DIR/title-bd-dry.err")"
  printf '%s' "$out" | jq -e --arg id "$ISSUE" '(has("issue_title") | not) and (.command[-1] | startswith("Your job is beads issue " + $id + "."))' >/dev/null \
    || fail "missing bd dry-run should keep the bare prompt: $out"
  [[ ! -s "$TMP_DIR/title-bd-dry.err" ]] || fail "missing bd dry-run stderr: $(cat "$TMP_DIR/title-bd-dry.err")"
  unset HANDOFF_PI_BIN
  printf 'PASS: headless JSON and the result file carry the title, or the bare id\n'
}

test_branch_carries_issue_title() {
  local repo="$TMP_DIR/title-branch" bin="$TMP_DIR/title-branch-bin" home="$TMP_DIR/title-branch-home"
  local state="$TMP_DIR/title-branch-state" out title='Say "hi"'
  local folder="$TMP_DIR/title-folder" hclog="$TMP_DIR/title-hc.log" argv="$TMP_DIR/title-hc.argv"
  git_init "$repo"
  mkdir -p "$bin" "$home/.config/worktrunk"
  cp "$ROOT/config/worktrunk/herdr-layout.sh" "$home/.config/worktrunk/herdr-layout.sh"
  cat >"$bin/wt" <<'WT'
#!/usr/bin/env bash
branch=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --create) branch="$2"; shift 2 ;;
    *) shift ;;
  esac
done
main="$(git worktree list --porcelain | awk '/^worktree / { print substr($0, 10); exit }')"
git -C "$main" worktree add -q -b "$branch" "$main.$branch" HEAD
printf '%s' "$(cd "$main.$branch" && pwd -P)" >"$TITLE_FOLDER"
WT
  cat >"$bin/herdr-app" <<'HERDR'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "status ") printf '{"space":"sp-keep"}\n' ;;
  "ls ")
    f=""
    [[ -f "$TITLE_FOLDER" ]] && f="$(cat "$TITLE_FOLDER")"
    if [[ -n "$f" ]]; then
      jq -nc --arg f "$f" '{spaces:[{id:"sp1",name:"Lbl",folder:$f,tabs:[{terminals:[{terminal:"t9"}]}]}]}'
    else
      printf '{"spaces":[]}\n'
    fi
    ;;
  "do space.new")
    printf '%s' "$6" >"$TITLE_FOLDER"
    printf '{"space":"sp1"}\n'
    ;;
  *) printf '{"ok":true}\n' ;;
esac
HERDR
  cat >"$bin/hc" <<'HC'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TITLE_HC_LOG"
if [[ "$1" == run ]]; then
  printf '%s\0' "$@" | jq -Rs 'split("\u0000") | .[:-1]' >"$TITLE_HC_ARGV"
fi
case "$1" in
  ls) printf '{"terminals":[]}\n' ;;
  *) printf '{}\n' ;;
esac
HC
  chmod +x "$bin/wt" "$bin/herdr-app" "$bin/hc"
  _bd_stub
  _pi_ready
  printf '[bstack]\nenabled = true\n' >"$TMP_DIR/title-bstack.toml"
  : >"$BD_COMMENTS"
  : >"$hclog"
  export TITLE_FOLDER="$folder" TITLE_HC_LOG="$hclog" TITLE_HC_ARGV="$argv"
  out="$(cd "$repo" && BD_TITLE="$title" HOME="$home" PATH="$bin:$PATH" \
    HERDR_APP_BIN="$bin/herdr-app" HC_BIN="$bin/hc" \
    XDG_STATE_HOME="$state" BERCAIL_BIN="$TMP_DIR/no-bercail" \
    BERCAIL_CONFIG="$TMP_DIR/title-bstack.toml" HANDOFF_PI_PROFILE="$HANDOFF_PI_PROFILE" \
    "$ROOT/skills/handoff/scripts/handoff-spawn" \
    --branch feat --stage bstack --issue "$ISSUE" --clean 2>"$TMP_DIR/title-branch.err")" \
    || fail "branch spawn failed: $out $(cat "$TMP_DIR/title-branch.err")"
  printf '%s' "$out" | jq -e --arg t "$title" --arg id "$ISSUE" \
    '.issue == $id and .issue_title == $t and .agent_started == true' >/dev/null \
    || fail "branch json: $out $(cat "$TMP_DIR/title-branch.err")"
  jq -e --arg t "$title" --arg id "$ISSUE" '.issue == $id and .issue_title == $t' \
    "$state/agentic-dev/handoffs.jsonl" >/dev/null \
    || fail "handoffs.jsonl: $(cat "$state/agentic-dev/handoffs.jsonl")"
  jq -e --arg issue "bercail.issue=$ISSUE" --arg titled "bercail.issue_title=$title" \
    'index($issue) and index($titled)' "$argv" >/dev/null \
    || fail "hc run labels: $(cat "$argv" 2>/dev/null) log=$(cat "$hclog")"
  unset TITLE_FOLDER TITLE_HC_LOG TITLE_HC_ARGV
  printf 'PASS: a --branch spawn puts the title in JSON, handoffs.jsonl, and the desk labels\n'
}

test_issue_title_normalises_and_degrades
test_issue_title_on_headless_runs
test_branch_carries_issue_title

_pi_profile() {
  local profile="$TMP_DIR/pi-profile" guard="$TMP_DIR/pi-profile/extensions/guard.ts"
  mkdir -p "$profile/extensions" "$profile/agents"
  printf '// guard\n' >"$guard"
  jq -n --arg guard "$guard" --arg model "claude-bridge/lead-model:high" \
    --arg prompts "$profile/prompts" --arg instructions "$profile/instructions.md" \
    '["pi","--model",$model,"-e","npm:pi-claude-bridge@0.11.0","-e",$guard,"--prompt-template",$prompts,"--append-system-prompt",$instructions]' \
    >"$profile/lead.json"
  printf '%s' "$profile"
}

test_pi_headless_stage() {
  local saved_config="${BERCAIL_CONFIG-}" saved_profile="${HANDOFF_PI_PROFILE-}"
  local profile wt out err rc=0 sid stub
  profile="$(_pi_profile)"
  printf '[bstack]\nenabled = true\n' >"$TMP_DIR/pi.toml"
  export BERCAIL_CONFIG="$TMP_DIR/pi.toml"
  export HANDOFF_PI_PROFILE="$profile"
  export HANDOFF_PI_BIN="$TMP_DIR/bin/pi-missing"
  wt="$TMP_DIR/pi-dry"
  mkdir -p "$wt"

  out="$(cd "$wt" && "$ROOT/skills/handoff/scripts/handoff-spawn" --stage bstack --issue "$ISSUE" --worktree "$wt" --dry-run)"
  printf '%s' "$out" | jq -e --arg bin "$HANDOFF_PI_BIN" --arg profile "$profile" --arg model "claude-bridge/lead-model:high" --arg id "$ISSUE" '
    .dry_run == true and .binary == "pi" and .model == $model and .stage == "bstack"
    and .command[0:11] == ["env","-u","ANTHROPIC_API_KEY","-u","ANTHROPIC_BASE_URL","-u","ANTHROPIC_AUTH_TOKEN","-u","BERCAIL_ROLE","-u","HC_TERMINAL_ID"]
    and (any(.command[]; . == "BERCAIL_ROLE=autopilot") | not)
    and .command[11] == $bin
    and .command[12:16] == ["-p","--mode","json","--session-id"]
    and (.command[16] | test("^[0-9a-fA-F-]{36}$"))
    and .session_id == .command[16]
    and .command[(.command | index("--model")) + 1] == $model
    and any(.command[]; . == ($profile + "/extensions/guard.ts"))
    and any(.command[]; . == ($profile + "/agents/bstack-headless.md"))
    and (any(.command[]; . == ($profile + "/agents/bstack-autopilot.md")) | not)
    and (any(.command[]; . == "--add-dir") | not)
    and .command[-2] == "--"
    and (.command[-1] | startswith("Your job is beads issue " + $id))
  ' >/dev/null || fail "bstack pi argv: $out"

  out="$(cd "$wt" && "$ROOT/skills/handoff/scripts/handoff-spawn" --stage autopilot --issue "$ISSUE" --worktree "$wt" --dry-run)"
  printf '%s' "$out" | jq -e --arg bin "$HANDOFF_PI_BIN" --arg profile "$profile" '
    .binary == "pi" and .stage == "autopilot"
    and .command[0:11] == ["env","-u","ANTHROPIC_API_KEY","-u","ANTHROPIC_BASE_URL","-u","ANTHROPIC_AUTH_TOKEN","-u","BERCAIL_ROLE","-u","HC_TERMINAL_ID"]
    and .command[11] == "BERCAIL_ROLE=autopilot"
    and .command[12] == $bin
    and .command[13:17] == ["-p","--mode","json","--session-id"]
    and any(.command[]; . == ($profile + "/agents/bstack-headless.md"))
    and any(.command[]; . == ($profile + "/agents/bstack-autopilot.md"))
    and .command[-2] == "--"
  ' >/dev/null || fail "autopilot pi argv: $out"

  sid=aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee
  out="$(cd "$wt" && "$ROOT/skills/handoff/scripts/handoff-spawn" --stage bstack --issue "$ISSUE" --worktree "$wt" --resume "$sid" --dry-run)"
  printf '%s' "$out" | jq -e --arg sid "$sid" '.resume == true and .session_id == $sid and .command[(.command | index("--session-id")) + 1] == $sid and (any(.command[]; . == "--resume") | not)' >/dev/null \
    || fail "pi resume reuses the uuid: $out"
  rc=0
  err="$(cd "$wt" && "$ROOT/skills/handoff/scripts/handoff-spawn" --stage bstack --issue "$ISSUE" --worktree "$wt" --resume ses_abc --dry-run 2>&1)" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "ses_ resume should fail"
  printf '%s' "$err" | grep -q 'must be a uuid' || fail "non-uuid resume message: $err"

  export HANDOFF_PI_PROFILE="$TMP_DIR/no-pi-profile"
  mkdir -p "$HANDOFF_PI_PROFILE"
  rm -f "$wt/.bercail/handoff-result.json"
  rc=0
  err="$(cd "$wt" && "$ROOT/skills/handoff/scripts/handoff-spawn" --stage bstack --issue "$ISSUE" --worktree "$wt" --dry-run 2>&1)" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "missing lead.json should fail a dry run"
  printf '%s' "$err" | grep -q 'bercail update' || fail "missing lead.json dry-run message: $err"
  [[ ! -e "$wt/.bercail/handoff-result.json" ]] || fail "a dry run writes no result file"
  rc=0
  err="$(cd "$wt" && "$ROOT/skills/handoff/scripts/handoff-spawn" --stage bstack --issue "$ISSUE" --worktree "$wt" 2>&1)" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "missing lead.json should block"
  jq -e '.status == "blocked" and (.summary | test("bercail update"))' "$wt/.bercail/handoff-result.json" >/dev/null \
    || fail "missing lead.json result: $(cat "$wt/.bercail/handoff-result.json") $err"
  rm -f "$wt/.bercail/handoff-result.json"
  jq -n --arg model "claude-bridge/lead-model:high" '["pi","--model",$model,"-e","npm:pi-claude-bridge@0.11.0"]' >"$HANDOFF_PI_PROFILE/lead.json"
  rc=0
  err="$(cd "$wt" && "$ROOT/skills/handoff/scripts/handoff-spawn" --stage bstack --issue "$ISSUE" --worktree "$wt" 2>&1)" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "missing guard should block"
  jq -e '.status == "blocked" and (.summary | test("guard")) and (.summary | test("bercail update"))' "$wt/.bercail/handoff-result.json" >/dev/null \
    || fail "missing guard result: $(cat "$wt/.bercail/handoff-result.json")"
  export HANDOFF_PI_PROFILE="$profile"

  _bd_stub
  stub="$TMP_DIR/bin/pi"
  mkdir -p "$TMP_DIR/bin"
  cat >"$stub" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${PI_STUB_MODE:-}" == error ]]; then
  printf '%s\n' '{"type":"session","version":3,"id":"bbbbbbbb-cccc-4ddd-8eee-ffffffffffff"}'
  printf '%s\n' '{"type":"message_end","message":{"role":"assistant","stopReason":"error","errorMessage":"provider exploded"}}'
  exit 0
fi
printf '%s\n' '{"type":"session","version":3,"id":"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"}'
printf '%s\n' '{"type":"agent_settled"}'
jq -nc '{status:"ready", summary:"wrote the fix"}' >"$BERCAIL_RESULT_PATH"
exit 0
STUB
  chmod +x "$stub"
  export HANDOFF_PI_BIN="$stub"
  local runwt="$TMP_DIR/pi-run" errf="$TMP_DIR/pi-header.err"
  mkdir -p "$runwt"
  out="$(cd "$runwt" && "$ROOT/skills/handoff/scripts/handoff-spawn" --stage bstack --issue "$ISSUE" --worktree "$runwt" 2>"$errf")"
  grep -q 'using the header' "$errf" || fail "header mismatch should be said: $(cat "$errf")"
  jq -e '.status == "ready" and .session_id == "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"' "$runwt/.bercail/handoff-result.json" >/dev/null \
    || fail "header session: $(cat "$runwt/.bercail/handoff-result.json")"
  grep -q "stage bstack, headless pi, worktree $runwt" "$BD_COMMENTS" \
    || fail "handoff should comment the worktree on the issue: $(cat "$BD_COMMENTS")"

  export PI_STUB_MODE=error
  local failwt="$TMP_DIR/pi-fail"
  mkdir -p "$failwt"
  rc=0
  out="$(cd "$failwt" && "$ROOT/skills/handoff/scripts/handoff-spawn" --stage bstack --issue "$ISSUE" --worktree "$failwt" 2>"$TMP_DIR/pi-fail.err")" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "pi exit 0 with an error message_end should fail"
  jq -e '.status == "failed" and .session_id == "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff" and (has("reason") | not)' \
    "$failwt/.bercail/handoff-result.json" >/dev/null \
    || fail "pi provider error result: $(cat "$failwt/.bercail/handoff-result.json")"
  unset PI_STUB_MODE

  if [[ -n "$saved_config" ]]; then export BERCAIL_CONFIG="$saved_config"; else unset BERCAIL_CONFIG; fi
  if [[ -n "$saved_profile" ]]; then export HANDOFF_PI_PROFILE="$saved_profile"; else unset HANDOFF_PI_PROFILE; fi
  unset HANDOFF_PI_BIN
  printf 'PASS: headless bstack and autopilot run Pi\n'
}

test_pi_headless_stage
