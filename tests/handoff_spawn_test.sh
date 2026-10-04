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
  local out path rc=0 err saved_path
  export XDG_STATE_HOME="$TMP_DIR/xdg-state"
  export HOME="$TMP_DIR/empty-home"
  unset HERDR_ENV HERDR_WORKSPACE_ID
  printf '#!/bin/sh\nexit 1\n' >"$TMP_DIR/no-herdr"
  chmod +x "$TMP_DIR/no-herdr"
  # CI images may not have wt. Stub it so spawn fails later at the missing
  # helper, after --take-pending has already consumed the pending file.
  mkdir -p "$TMP_DIR/bin"
  printf '#!/bin/sh\nexit 1\n' >"$TMP_DIR/bin/wt"
  chmod +x "$TMP_DIR/bin/wt"
  saved_path="$PATH"
  export PATH="$TMP_DIR/bin:$PATH"
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
  PATH="$saved_path"
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
  printf 'PASS: handoff intro does not open review via the review skill\n'
}

test_intro_does_not_invoke_review_skill

test_poteto_only_for_cursor_binary() {
  local got
  got="$(handoff_prompt_text $'intro' start)"
  [[ "$got" == intro ]] || fail "start stage must not prefix poteto, got ${got:0:40}"
  got="$(handoff_prompt_text $'intro' cursor)"
  [[ "$got" == /poteto-mode$'\n\n'"intro" ]] || fail "cursor stage should prefix poteto"
  handoff_stage_field arena binary && fail "arena is not a stage yet"
  handoff_stage_field implement binary && fail "implement is not a stage yet"
  handoff_stage_field review binary && fail "review pane is not a stage yet"
  [[ "$(handoff_stage_field cursor binary)" == cursor-agent ]] || fail "cursor binary"
  [[ "$(handoff_stage_field start mode)" == headless ]] || fail "start mode"
  grep -q 'WT_HERDR_AGENT_CMD=cursor-agent' "$ROOT/skills/handoff/scripts/handoff-spawn" \
    && fail "handoff-spawn must not hardcode WT_HERDR_AGENT_CMD=cursor-agent"
  grep -q 'WT_HERDR_AGENT_CMD="$binary"' "$ROOT/skills/handoff/scripts/handoff-spawn" \
    || fail "pane stage must publish the table binary via WT_HERDR_AGENT_CMD"
  printf 'PASS: poteto and cursor-agent come from the stage table\n'
}

test_model_resolves_opus_55_not_pstack_slug() {
  local catalog="$TMP_DIR/catalog.json" id
  cat >"$catalog" <<'JSON'
{"catalog":{"config":{"models":[
  {"id":"claude-opus-5-5-max","name":"Opus 5.5 Max"},
  {"id":"claude-opus-5-5","name":"Opus 5.5"},
  {"id":"claude-opus-4-6","name":"Opus 4.6"}
]}}}
JSON
  id="$(BERCAIL_CLAUDE_MODEL_CATALOG="$catalog" handoff_resolve_model opus-5.5)"
  [[ "$id" == claude-opus-5-5 ]] || fail "expected claude-opus-5-5, got $id"
  cat >"$catalog" <<'JSON'
{"catalog":{"config":{"models":[
  {"id":"claude-opus-4-8-max","name":"nope"},
  {"id":"claude-opus-4-6","name":"Opus 4.6"}
]}}}
JSON
  id="$(BERCAIL_CLAUDE_MODEL_CATALOG="$catalog" handoff_resolve_model opus-5.5 2>"$TMP_DIR/model-err")"
  [[ "$id" == claude-opus-4-6 ]] || fail "closest opus should skip -max, got $id"
  printf '%s' "$(cat "$TMP_DIR/model-err")" | grep -q 'closest opus' \
    || fail "should say it fell back: $(cat "$TMP_DIR/model-err")"
  id="$(BERCAIL_CLAUDE_MODEL_CATALOG="$TMP_DIR/no-catalog.json" handoff_resolve_model opus-5.5 2>"$TMP_DIR/model-err")"
  [[ "$id" == opus ]] || fail "missing catalog should use alias opus, got $id"
  printf 'PASS: opus-5.5 resolves to the catalog id, never the pstack slug\n'
}

test_brief_sources_share_one_shape() {
  local wt="$TMP_DIR/brief-wt" a b c
  mkdir -p "$wt"
  printf 'ship the login fix\n' >"$TMP_DIR/ask.txt"
  "$ROOT/skills/handoff/scripts/handoff-brief" \
    --source ask --worktree "$wt" --repo https://github.com/acme/app \
    --ask-file "$TMP_DIR/ask.txt" --link https://example.com/note >/dev/null
  a="$(jq -c 'keys' "$wt/.bercail/job-brief.json")"
  "$ROOT/skills/handoff/scripts/handoff-brief" \
    --source linear --worktree "$wt" --repo https://github.com/acme/app \
    --link https://linear.app/issue/ABC-1 >/dev/null <<'EOF'
Linear: fix login
EOF
  b="$(jq -c 'keys' "$wt/.bercail/job-brief.json")"
  printf 'a note\n' | "$ROOT/skills/handoff/scripts/handoff-brief" \
    --source note --worktree "$wt" --repo /tmp/app >/dev/null
  c="$(jq -c 'keys' "$wt/.bercail/job-brief.json")"
  [[ "$a" == "$b" && "$b" == "$c" ]] || fail "brief keys differ: $a $b $c"
  jq -e '.ask and .repo and (.links|type=="array") and .source=="note"' \
    "$wt/.bercail/job-brief.json" >/dev/null \
    || fail "brief shape: $(cat "$wt/.bercail/job-brief.json")"
  local rc=0 err
  err="$("$ROOT/skills/handoff/scripts/handoff-brief" --source ask --worktree "$wt" --repo x -- 'on argv' 2>&1)" || rc=$?
  [[ "$rc" -eq 1 ]] || fail "ask on argv should exit 1, got $rc ($err)"
  printf 'PASS: linear, ask, and note write one job brief\n'
}

_start_fixture() {
  local wt="$1" catalog="$TMP_DIR/catalog.json"
  mkdir -p "$wt"
  cat >"$catalog" <<'JSON'
{"catalog":{"config":{"models":[{"id":"claude-opus-5-5","name":"Opus 5.5"}]}}}
JSON
  printf 'fix the login timeout\n' >"$TMP_DIR/ask.txt"
  "$ROOT/skills/handoff/scripts/handoff-brief" \
    --source ask --worktree "$wt" --repo https://github.com/acme/app \
    --ask-file "$TMP_DIR/ask.txt" >/dev/null
  export BERCAIL_CLAUDE_MODEL_CATALOG="$catalog"
}

test_start_stage_dry_run() {
  local wt="$TMP_DIR/start-dry" out
  _start_fixture "$wt"
  printf '#!/bin/sh\necho herdr-called >>"$TMP_DIR/herdr-hit"\nexit 9\n' >"$TMP_DIR/herdr-bomb"
  chmod +x "$TMP_DIR/herdr-bomb"
  out="$(cd "$wt" && HERDR_BIN_PATH="$TMP_DIR/herdr-bomb" \
    "$ROOT/skills/handoff/scripts/handoff-spawn" --stage start --worktree "$wt" --dry-run)"
  printf '%s' "$out" | jq -e '.dry_run == true and .mode == "headless" and .stage == "start"' >/dev/null \
    || fail "dry-run json: $out"
  printf '%s' "$out" | jq -e '.model == "claude-opus-5-5"' >/dev/null || fail "model: $out"
  printf '%s' "$out" | jq -e '.command[1] == "--print" and .command[2] == "--model" and .command[3] == "claude-opus-5-5"' >/dev/null \
    || fail "argv model: $out"
  printf '%s' "$out" | jq -e 'any(.command[]; . == "--session-id") and (any(.command[]; . == "--resume") | not)' >/dev/null \
    || fail "first start should pass --session-id and not --resume: $out"
  printf '%s' "$out" | jq -e 'any(.command[]; test("poteto"))|not' >/dev/null \
    || fail "start argv must not mention poteto: $out"
  printf '%s' "$out" | jq -e 'any(.command[]; test("herdr|cursor-agent"))|not' >/dev/null \
    || fail "start argv must not launch herdr or cursor-agent: $out"
  [[ ! -f "$TMP_DIR/herdr-hit" ]] || fail "dry-run must not call herdr"
  [[ ! -f "$wt/.bercail/handoff-result.json" ]] || fail "dry-run must not write a result"
  printf 'PASS: start dry-run is headless claude --print --model claude-opus-5-5\n'
}

test_start_stage_resume_and_fixture_result() {
  local wt="$TMP_DIR/start-run" out sid stub="$TMP_DIR/bin/claude" rc=0 err
  mkdir -p "$TMP_DIR/bin"
  _start_fixture "$wt"
  cat >"$stub" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >"${HANDOFF_ARGV_LOG:?}"
[[ "$*" == *--print* ]] || exit 2
[[ "$*" == *"--model claude-opus-5-5"* ]] || exit 3
if [[ "${BERCAIL_EXPECT_RESUME:-}" == 1 ]]; then
  [[ "$*" == *"--resume ${BERCAIL_SESSION_ID}"* ]] || exit 4
else
  [[ "$*" == *"--session-id ${BERCAIL_SESSION_ID}"* ]] || exit 5
fi
jq -nc --arg sid "$BERCAIL_SESSION_ID" \
  '{status:"ready", summary:"restated the ask and wrote a plan", session_id:$sid}' \
  >"$BERCAIL_RESULT_PATH"
STUB
  chmod +x "$stub"
  export HANDOFF_ARGV_LOG="$TMP_DIR/argv-log"
  export HANDOFF_CLAUDE_BIN="$stub"
  out="$(cd "$wt" && "$ROOT/skills/handoff/scripts/handoff-spawn" --stage start --worktree "$wt")"
  printf '%s' "$out" | jq -e '.ok == true and .dry_run == false and .resume == false' >/dev/null \
    || fail "start json: $out"
  sid="$(jq -r '.session_id' "$wt/.bercail/handoff-result.json")"
  jq -e --arg sid "$sid" \
    '.status=="ready" and (.summary|length>0) and .session_id==$sid' \
    "$wt/.bercail/handoff-result.json" >/dev/null \
    || fail "result shape: $(cat "$wt/.bercail/handoff-result.json")"
  grep -q 'herdr' "$HANDOFF_ARGV_LOG" && fail "fixture argv called herdr: $(cat "$HANDOFF_ARGV_LOG")"
  grep -q 'poteto' "$HANDOFF_ARGV_LOG" && fail "fixture argv used poteto"
  export BERCAIL_EXPECT_RESUME=1
  out="$(cd "$wt" && "$ROOT/skills/handoff/scripts/handoff-spawn" \
    --stage start --worktree "$wt" --resume "$sid")"
  printf '%s' "$out" | jq -e '.resume == true' >/dev/null || fail "resume json: $out"
  grep -q -- "--resume $sid" "$HANDOFF_ARGV_LOG" || fail "resume argv: $(cat "$HANDOFF_ARGV_LOG")"
  grep -q -- '--session-id' "$HANDOFF_ARGV_LOG" && fail "re-handoff must not mint a new --session-id"
  err="$(cd "$wt" && "$ROOT/skills/handoff/scripts/handoff-spawn" --stage arena --dry-run 2>&1)" || rc=$?
  [[ "$rc" -eq 1 ]] || fail "unknown stage should exit 1, got $rc ($err)"
  printf '%s' "$err" | grep -q 'unknown stage' || fail "unknown stage message: $err"
  unset HANDOFF_CLAUDE_BIN HANDOFF_ARGV_LOG BERCAIL_EXPECT_RESUME BERCAIL_CLAUDE_MODEL_CATALOG
  printf 'PASS: start fixture writes handoff-result.json; re-handoff uses --resume\n'
}

test_poteto_only_for_cursor_binary
test_model_resolves_opus_55_not_pstack_slug
test_brief_sources_share_one_shape
test_start_stage_dry_run
test_start_stage_resume_and_fixture_result
