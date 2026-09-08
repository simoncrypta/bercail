#!/usr/bin/env bash
# shellcheck shell=bash
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

test_graphite_rev_parse_is_not_enough() {
  local repo="$TMP_DIR/plain"
  git_init "$repo"
  local printed
  printed="$(git -C "$repo" rev-parse --git-path .graphite_repo_config)"
  [[ -n "$printed" ]] || fail "rev-parse always prints a path"
  handoff_is_graphite "$repo" && fail "plain repo must not count as Graphite"
  mkdir -p "$(dirname "$repo/$printed")"
  if [[ "$printed" == /* ]]; then
    printf '{}\n' >"$printed"
  else
    printf '{}\n' >"$repo/$printed"
  fi
  handoff_is_graphite "$repo" || fail "file present must count as Graphite"
  printf 'PASS: Graphite detection is test -f of git-path, not rev-parse alone\n'
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

test_one_line_flattens_prompt() {
  local got
  got="$(handoff_one_line $'fix auth\nplease')"
  [[ "$got" == "fix auth please" ]] || fail "one-line: $got"
  printf 'PASS: task summary flattens newlines\n'
}

test_usage() {
  local rc=0
  "$ROOT/skills/handoff/scripts/handoff-spawn" --help >/dev/null 2>&1 || rc=$?
  [[ "$rc" -eq 2 ]] || fail "usage should exit 2, got $rc"
  printf 'PASS: handoff-spawn --help exits 2\n'
}

test_prompt_text_prefixes_poteto_mode() {
  local got
  got="$(handoff_prompt_text $'intro\n\nfix auth')"
  [[ "$got" == /poteto-mode$'\n\n'"intro"$'\n\n'"fix auth" ]] \
    || fail "should prefix /poteto-mode, got ${got:0:80}"
  got="$(handoff_prompt_text $'/poteto-mode\n\nalready')"
  [[ "$got" == $'/poteto-mode\n\nalready' ]] || fail "must not double-prefix"
  printf 'PASS: prompt wrap prefixes /poteto-mode once\n'
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

test_info_json_reports_graphite_and_dirty() {
  local repo="$TMP_DIR/info-repo" out
  git_init "$repo"
  printf 'dirty\n' >>"$repo/file.txt"
  printf 'loose\n' >"$repo/untracked.txt"
  mkdir -p "$(dirname "$(git -C "$repo" rev-parse --git-path .graphite_repo_config)")"
  printed="$(git -C "$repo" rev-parse --git-path .graphite_repo_config)"
  if [[ "$printed" == /* ]]; then
    printf '{}\n' >"$printed"
  else
    printf '{}\n' >"$repo/$printed"
  fi
  printf '#!/bin/sh\nexit 1\n' >"$TMP_DIR/no-herdr"
  chmod +x "$TMP_DIR/no-herdr"
  unset HERDR_ENV HERDR_WORKSPACE_ID HANDOFF_WORKSPACE
  out="$(cd "$repo" && HERDR_BIN_PATH="$TMP_DIR/no-herdr" \
    CURSOR_CONFIG_DIR="$TMP_DIR/no-cursor" \
    "$ROOT/skills/handoff/scripts/handoff-spawn" --info)"
  printf '%s' "$out" | jq -e '.dirty == true' >/dev/null || fail "info dirty: $out"
  printf '%s' "$out" | jq -e '.graphite == true' >/dev/null || fail "info graphite: $out"
  printf '%s' "$out" | jq -e '.default_copy == "dirty"' >/dev/null || fail "info default_copy: $out"
  printf '%s' "$out" | jq -e '.herdr == false' >/dev/null || fail "info herdr: $out"
  printf '%s' "$out" | jq -e '.herdr_env == false' >/dev/null || fail "info herdr_env: $out"
  printf '%s' "$out" | jq -e '.socket == false' >/dev/null || fail "info socket: $out"
  printf '%s' "$out" | jq -e '.main_checkout == true' >/dev/null || fail "info main_checkout: $out"
  printf '%s' "$out" | jq -e '.pstack == false' >/dev/null || fail "info pstack without plugin: $out"
  printf 'PASS: --info reports dirty, graphite, and herdr without agent inspection\n'
}

test_info_json_reports_pstack_when_plugin_present() {
  local repo="$TMP_DIR/info-pstack" out cursor
  git_init "$repo"
  cursor="$TMP_DIR/cursor-home"
  mkdir -p "$cursor/plugins/cache/cursor-public/pstack/deadbeef/skills/poteto-mode"
  printf '# poteto-mode\n' >"$cursor/plugins/cache/cursor-public/pstack/deadbeef/skills/poteto-mode/SKILL.md"
  printf '#!/bin/sh\nexit 1\n' >"$TMP_DIR/no-herdr"
  chmod +x "$TMP_DIR/no-herdr"
  unset HERDR_ENV HERDR_WORKSPACE_ID HANDOFF_WORKSPACE
  out="$(cd "$repo" && HERDR_BIN_PATH="$TMP_DIR/no-herdr" CURSOR_CONFIG_DIR="$cursor" \
    "$ROOT/skills/handoff/scripts/handoff-spawn" --info)"
  printf '%s' "$out" | jq -e '.pstack == true' >/dev/null || fail "info pstack: $out"
  printf 'PASS: --info reports pstack when poteto-mode is installed\n'
}

test_info_json_socket_without_herdr_env() {
  local repo="$TMP_DIR/info-socket" out
  git_init "$repo"
  cat >"$TMP_DIR/fake-herdr" <<'EOF'
#!/bin/sh
echo '{"result":{"workspaces":[]}}'
EOF
  chmod +x "$TMP_DIR/fake-herdr"
  unset HERDR_ENV
  export HERDR_WORKSPACE_ID=w26
  out="$(cd "$repo" && HERDR_BIN_PATH="$TMP_DIR/fake-herdr" \
    "$ROOT/skills/handoff/scripts/handoff-spawn" --info)"
  unset HERDR_WORKSPACE_ID
  printf '%s' "$out" | jq -e '.herdr == true' >/dev/null || fail "socket herdr: $out"
  printf '%s' "$out" | jq -e '.herdr_env == false' >/dev/null || fail "socket herdr_env: $out"
  printf '%s' "$out" | jq -e '.socket == true' >/dev/null || fail "socket flag: $out"
  printf '%s' "$out" | jq -e '.workspace == "w26"' >/dev/null || fail "socket workspace: $out"
  printf 'PASS: --info treats a live Herdr socket as herdr without HERDR_ENV\n'
}

test_result_json_records_unconfirmed_agent() {
  local got
  got="$(handoff_result_json "Lbl" "/tmp/wt" "br" "do the thing" 0 0 1)"
  printf '%s' "$got" | jq -e '.ok == true' >/dev/null || fail "ok: $got"
  printf '%s' "$got" | jq -e '.agent_started == false' >/dev/null || fail "started: $got"
  printf '%s' "$got" | jq -e '.graphite == true' >/dev/null || fail "graphite: $got"
  printf '%s' "$got" | jq -e '.path == "/tmp/wt"' >/dev/null || fail "path: $got"
  printf 'PASS: result JSON is emitted when agent start is unconfirmed\n'
}

test_parent_workspace_required_without_herdr_env() {
  unset HERDR_ENV HERDR_WORKSPACE_ID HANDOFF_WORKSPACE
  handoff_parent_workspace && fail "parent workspace must be empty"
  HANDOFF_WORKSPACE=w26
  [[ "$(handoff_parent_workspace)" == w26 ]] || fail " --workspace should win"
  unset HANDOFF_WORKSPACE
  HERDR_WORKSPACE_ID=w9
  [[ "$(handoff_parent_workspace)" == w9 ]] || fail "HERDR_WORKSPACE_ID fallback"
  printf 'PASS: parent workspace comes from --workspace or HERDR_WORKSPACE_ID\n'
}

test_prompt_file_missing_dies() {
  local rc=0 err
  err="$("$ROOT/skills/handoff/scripts/handoff-spawn" --branch foo --prompt-file "$TMP_DIR/no-such-prompt" 2>&1)" || rc=$?
  [[ "$rc" -eq 1 ]] || fail "missing prompt file should exit 1, got $rc ($err)"
  printf '%s' "$err" | grep -q 'prompt file not found' \
    || fail "missing prompt file message: $err"
  printf 'PASS: --prompt-file dies before Herdr when the file is missing\n'
}

test_rejects_prompt_after_double_dash() {
  local rc=0 err
  err="$("$ROOT/skills/handoff/scripts/handoff-spawn" --branch foo --clean -- 'QA cedar-pg' 2>&1)" || rc=$?
  [[ "$rc" -eq 1 ]] || fail "-- prompt should exit 1, got $rc ($err)"
  printf '%s' "$err" | grep -q 'do not pass the prompt after --' \
    || fail "double-dash message: $err"
  printf 'PASS: argv after -- is rejected so Auto-review does not bind a payload\n'
}

test_stash_and_take_pending() {
  local out path rc=0 err
  export XDG_STATE_HOME="$TMP_DIR/xdg-state"
  export HOME="$TMP_DIR/empty-home"
  unset HERDR_ENV HERDR_WORKSPACE_ID
  printf '#!/bin/sh\nexit 1\n' >"$TMP_DIR/no-herdr"
  chmod +x "$TMP_DIR/no-herdr"
  out="$(printf 'QA cedar-pg beta' | "$ROOT/skills/handoff/scripts/handoff-spawn" --stash-prompt)"
  path="$(printf '%s' "$out" | jq -r '.pending_prompt')"
  [[ -f "$path" ]] || fail "stash should write $path ($out)"
  grep -q 'QA cedar-pg beta' "$path" || fail "stash contents: $(cat "$path")"
  out="$(HERDR_BIN_PATH="$TMP_DIR/no-herdr" "$ROOT/skills/handoff/scripts/handoff-spawn" --info)"
  printf '%s' "$out" | jq -e '.pending_prompt_present == true' >/dev/null \
    || fail "info should see pending: $out"
  err="$("$ROOT/skills/handoff/scripts/handoff-spawn" --branch pg-beta --clean --workspace w26 --take-pending 2>&1)" || rc=$?
  [[ "$rc" -eq 1 ]] || fail "take-pending should fail later without helper, got $rc ($err)"
  [[ ! -f "$path" ]] || fail "take-pending must consume the pending file"
  printf '%s' "$err" | grep -q 'missing' \
    || fail "expected missing helper after consume: $err"
  unset XDG_STATE_HOME HOME
  printf 'PASS: --stash-prompt / --take-pending keep the prompt off argv\n'
}

test_graphite_rev_parse_is_not_enough
test_copy_dirty_is_working_tree_not_index
test_one_line_flattens_prompt
test_usage
test_prompt_text_prefixes_poteto_mode
test_graphite_track_uses_resolved_config_path
test_info_json_reports_graphite_and_dirty
test_info_json_reports_pstack_when_plugin_present
test_info_json_socket_without_herdr_env
test_result_json_records_unconfirmed_agent
test_parent_workspace_required_without_herdr_env
test_prompt_file_missing_dies
test_rejects_prompt_after_double_dash
test_stash_and_take_pending

test_intro_does_not_invoke_review_skill() {
  grep -q 'agentic-dev.layout' "$ROOT/skills/handoff/scripts/handoff-spawn" \
    || fail "handoff intro should name agentic-dev.layout"
  grep -q 'never agentic-dev.dev-layout' "$ROOT/skills/handoff/scripts/handoff-spawn" \
    || fail "handoff intro should forbid the old plugin id"
  grep -q 'review/SKILL.md' "$ROOT/skills/handoff/scripts/handoff-spawn" \
    && fail "handoff intro must not tell the child to load the review skill"
  printf 'PASS: handoff intro does not open hunk via the review skill\n'
}

test_intro_does_not_invoke_review_skill
