#!/usr/bin/env bats
# Which git backend a repo gets (gh, gt, origin): lib/git-backend.sh against
# real repos, with gt's files written by hand and a fake origin. Any gt command
# initializes the repo it runs in, so a stray one must not read as Graphite
# (bercail-wc1).
# Each @test runs in its own process, so its exports are meant to end with it.
# shellcheck disable=SC2030,SC2031

setup() {
  load test_helper
  isolate
  set -o pipefail
  # shellcheck source=/dev/null
  source "$ROOT/lib/git-backend.sh"
}

git_dir() { git -C "$1" rev-parse --path-format=absolute --git-common-dir; }

# What any gt command leaves behind in a repo: the config, nothing tracked.
graphite_auto_init() {
  printf '{"trunk":"master","trunks":[{"name":"master"}]}\n' >"$(git_dir "$1")/.graphite_repo_config"
}

# Does bercail pick gt for REPO? Warnings stay on stderr.
uses_gt() {
  local backend
  backend="$(git_backend "$1")"
  [[ "$backend" == gt ]]
}

# Current gt stores every branch it has seen. Only tracked branches have a parent.
graphite_db_row() {
  local parent=null
  [[ -z "${3:-}" ]] || parent="'$3'"
  sqlite3 "$(git_dir "$1")/.graphite_metadata.db" \
    "create table if not exists branch_metadata (branch_name text primary key, parent_branch_name text);
     insert into branch_metadata values ('$2', $parent);"
}

@test "an auto-created Graphite config, even with a trunk ref, is not Graphite" {
  local repo="$BATS_TEST_TMPDIR/plain"
  git_init "$repo"
  uses_gt "$repo" && fail "plain repo must not count as Graphite"
  graphite_auto_init "$repo"
  uses_gt "$repo" && fail "an auto-created config must not count as Graphite"
  git -C "$repo" update-ref refs/branch-metadata/master HEAD
  if uses_gt "$repo"; then
    fail "metadata for trunk alone must not count as Graphite"
  fi
}

@test "branch metadata refs for a non-trunk branch are Graphite, from any worktree" {
  local repo="$BATS_TEST_TMPDIR/gt-refs" sibling="$BATS_TEST_TMPDIR/gt-refs.feat"
  git_init "$repo"
  git -C "$repo" worktree add -q -b feat "$sibling"
  graphite_auto_init "$repo"
  git -C "$repo" update-ref refs/branch-metadata/stack/one HEAD
  uses_gt "$repo" || fail "a tracked branch ref must count as Graphite"
  uses_gt "$sibling" || fail "a linked worktree shares the refs"
}

@test "metadata refs of any configured trunk do not count" {
  local repo="$BATS_TEST_TMPDIR/gt-trunks"
  git_init "$repo"
  printf '{"trunk":"main","trunks":[{"name":"main"},{"name":"sandbox"}]}\n' >"$(git_dir "$repo")/.graphite_repo_config"
  git -C "$repo" update-ref refs/branch-metadata/sandbox HEAD
  if uses_gt "$repo"; then
    fail "every trunk is excluded, not only the first"
  fi
}

@test "the metadata store counts only rows with a parent; unreadable skips Graphite and warns" {
  local repo="$BATS_TEST_TMPDIR/gt-db" err
  git_init "$repo"
  graphite_auto_init "$repo"
  export HANDOFF_SQLITE3_BIN="$BATS_TEST_TMPDIR/no-sqlite3"
  : >"$(git_dir "$repo")/.graphite_metadata.db"
  err="$(uses_gt "$repo" 2>&1)" && fail "an unreadable store is not evidence of Graphite: $err"
  grep -q 'under \[git\]' <<<"$err" || fail "unreadable store should name the override: $err"
  unset HANDOFF_SQLITE3_BIN
  need sqlite3
  err="$(uses_gt "$repo" 2>&1)" && fail "an unknown schema is not evidence of Graphite: $err"
  grep -q 'under \[git\]' <<<"$err" || fail "unknown schema should name the override: $err"
  rm -f "$(git_dir "$repo")/.graphite_metadata.db"
  graphite_db_row "$repo" master
  graphite_db_row "$repo" stray-branch
  err="$(uses_gt "$repo" 2>&1)" && fail "rows with no parent are only what auto-init saw: $err"
  grep -q 'tracks no branch' <<<"$err" || fail "say why Graphite is off, and how to turn it on: $err"
  grep -q 'cannot read' <<<"$err" && fail "a readable store is not unreadable: $err"
  graphite_db_row "$repo" feat master
  uses_gt "$repo" || fail "a branch with a parent is tracked: Graphite"
}

@test "[git] in config.toml settles the backend for one repo, from any worktree" {
  local plain="$BATS_TEST_TMPDIR/ov-plain" real="$BATS_TEST_TMPDIR/ov-real" sibling="$BATS_TEST_TMPDIR/ov-real.feat" cfg="$BATS_TEST_TMPDIR/ov.toml"
  local home="$BATS_TEST_TMPDIR/ov-home"
  git_init "$plain"
  git_init "$real"
  git -C "$real" worktree add -q -b feat "$sibling"
  graphite_auto_init "$real"
  git -C "$real" update-ref refs/branch-metadata/feat HEAD
  export BERCAIL_CONFIG="$cfg"
  cat >"$cfg" <<EOF
[git] # by main checkout
"$real" = "gh"   # no longer stacks here
'$plain' = "gt"

[bstack]
"$BATS_TEST_TMPDIR/ov-other" = "gt"
EOF
  uses_gt "$real" && fail "gh wins over refs"
  uses_gt "$sibling" && fail "a linked worktree uses its main checkout's entry"
  uses_gt "$plain" || fail "gt wins over no signal at all"
  [[ -z "$(git_backend "$plain" 2>&1 >/dev/null)" ]] || fail "a repo that has settled it hears nothing"
  cat >"$cfg" <<EOF
[bstack]
"$real" = "gh"

[git]
"$BATS_TEST_TMPDIR/ov-other" = "gh"
"$plain" = "maybe"
EOF
  uses_gt "$real" || fail "a key in another section or for another repo is ignored"
  [[ "$(git_backend "$plain" 2>/dev/null)" == gh ]] || fail "a value that is not gh, gt or origin is ignored"
  printf '["git"]\n"%s" = "origin"\n' "$plain" >"$cfg"
  [[ "$(git_backend "$plain")" == origin ]] || fail "a quoted table name is the same table"
  mkdir -p "$home"
  git_init "$home/repo"
  printf '[git]\n"~/repo" = "gt"\n' >"$cfg"
  [[ "$(HOME="$home" git_backend "$home/repo")" == gt ]] || fail "home-relative keys expand to the home directory"
  rm -f "$cfg"
  uses_gt "$real" || fail "no config file falls through to detection"
  unset BERCAIL_CONFIG
}

@test "a [graphite] entry no longer chooses the backend" {
  local plain="$BATS_TEST_TMPDIR/old-plain" cfg="$BATS_TEST_TMPDIR/old.toml"
  git_init "$plain"
  export BERCAIL_CONFIG="$cfg"
  printf '[graphite]\n"%s" = true\n' "$plain" >"$cfg"
  [[ "$(git_backend "$plain")" == gh ]] || fail "[graphite] is still read: $(git_backend "$plain")"
  unset BERCAIL_CONFIG
}

_origin_remote() {
  git -C "$1" remote remove origin 2>/dev/null || true
  git -C "$1" remote add origin "$2"
}

@test "Origin host match is offline; a GitHub remote is never probed" {
  local repo="$BATS_TEST_TMPDIR/ori-off" bin="$BATS_TEST_TMPDIR/ori-off-bin" log="$BATS_TEST_TMPDIR/ori-off.log"
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
  if git_backend_origin_remote "$repo"; then
    fail "a lookalike path on github.com is not Origin"
  fi
}

@test "Origin ownership is mirrorStatus; unknown ownership warns and stays gh" {
  local repo="$BATS_TEST_TMPDIR/ori-own" bin="$BATS_TEST_TMPDIR/ori-own-bin" log="$BATS_TEST_TMPDIR/ori-own.log" status
  git_init "$repo"
  _origin_remote "$repo" https://origin.cursor.com/acme/widgets.git
  mkdir -p "$bin"
  cat >"$bin/origin" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$log"
if [[ "\$*" == *"repo view --json mirrorStatus"* ]]; then
  printf '%s\n' "{\"mirrorStatus\":\"$BATS_TEST_TMPDIR/ori-status\"}"
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
  [[ "$(PATH="/usr/bin:/bin" git_backend "$repo" 2>"$BATS_TEST_TMPDIR/ori-missing.err")" == gh ]] \
    || fail "missing origin CLI is unknown ownership, so gh"
  grep -q '\[git\]' "$BATS_TEST_TMPDIR/ori-missing.err" || fail "missing CLI should name the override: $(cat "$BATS_TEST_TMPDIR/ori-missing.err")"
  cat >"$bin/origin" <<'EOF'
#!/bin/sh
printf 'origin: not logged in\n' >&2
exit 1
EOF
  chmod +x "$bin/origin"
  [[ "$(PATH="$bin:$PATH" git_backend "$repo" 2>"$BATS_TEST_TMPDIR/ori-fail.err")" == gh ]] \
    || fail "a failed ownership probe is gh"
  grep -q 'origin repo view failed' "$BATS_TEST_TMPDIR/ori-fail.err" || fail "failed probe should say why: $(cat "$BATS_TEST_TMPDIR/ori-fail.err")"
  grep -q '\[git\]' "$BATS_TEST_TMPDIR/ori-fail.err" || fail "failed probe should name the override: $(cat "$BATS_TEST_TMPDIR/ori-fail.err")"
  cat >"$bin/origin" <<'EOF'
#!/bin/sh
exit 130
EOF
  chmod +x "$bin/origin"
  local rc=0 out
  out="$(PATH="$bin:$PATH" git_backend "$repo" 2>"$BATS_TEST_TMPDIR/ori-int.err")" || rc=$?
  [[ "$rc" -eq 130 ]] || fail "an interrupted probe must exit 130, not guess gh (rc=$rc out=$out)"
  [[ -z "$out" ]] || fail "an interrupted probe must not print a backend: $out"
  grep -q 'using gh' "$BATS_TEST_TMPDIR/ori-int.err" && fail "interrupt is not an unknown-ownership fallback: $(cat "$BATS_TEST_TMPDIR/ori-int.err")"
  unset BERCAIL_ORIGIN_LOG ORIGIN_STATUS
}

@test "graphite config path is resolved against the repo root" {
  local repo="$BATS_TEST_TMPDIR/gt-rel"
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
  [[ "$(git_backend_graphite_config "$repo")" == "$cfg" ]] \
    || fail "graphite config path should resolve relative git-path"
  (
    cd "$BATS_TEST_TMPDIR"
    uses_gt "$repo" || fail "gt from another cwd"
    got="$(git_backend_graphite_config "$repo")"
    [[ "$got" == "$cfg" ]] || fail "track helper must not depend on cwd, got $got"
  )
}
