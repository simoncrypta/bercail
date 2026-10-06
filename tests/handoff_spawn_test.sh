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

test_usage() {
  local rc=0
  "$ROOT/skills/handoff/scripts/handoff-spawn" --help >/dev/null 2>&1 || rc=$?
  [[ "$rc" -eq 2 ]] || fail "usage should exit 2, got $rc"
  printf 'PASS: handoff-spawn --help exits 2\n'
}

test_issue_prompt_is_only_the_id() {
  [[ "$(handoff_issue_prompt bercail-0s1)" == bercail-0s1 ]] || fail "prompt is the bare id"
  handoff_issue_id_ok bercail-0s1 || fail "plain beads id"
  handoff_issue_id_ok bercail-0s1.2 || fail "child beads id"
  handoff_issue_id_ok --help && fail "flag is not an id"
  handoff_issue_id_ok ../x && fail "path is not an id"
  handoff_issue_id_ok 'bercail-0s1 rm' && fail "space is not an id"
  [[ ! -d "$ROOT/skills/handoff/prompts" ]] || fail "prompt files must be gone"
  [[ ! -e "$ROOT/skills/handoff/scripts/handoff-brief" ]] || fail "handoff-brief must be gone"
  printf 'PASS: the agent prompt is only the beads issue id\n'
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
  printf '%s' "$out" | jq -e 'has("pstack")|not' >/dev/null || fail "info must not report pstack: $out"
  printf 'PASS: --info reports dirty, graphite, and herdr without agent inspection\n'
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
  got="$(handoff_result_json "Lbl" "/tmp/wt" "br" "bercail-0s1" 0 0 1)"
  printf '%s' "$got" | jq -e '.issue == "bercail-0s1" and (has("task")|not)' >/dev/null || fail "issue: $got"
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

test_issue_is_required_and_prompt_flags_are_gone() {
  local rc=0 err flag out
  err="$("$ROOT/skills/handoff/scripts/handoff-spawn" --branch foo --stage cursor 2>&1)" || rc=$?
  [[ "$rc" -eq 1 ]] || fail "missing --issue should exit 1, got $rc ($err)"
  printf '%s' "$err" | grep -q -- '--issue' || fail "missing --issue message: $err"
  rc=0
  err="$("$ROOT/skills/handoff/scripts/handoff-spawn" --stage start --issue '../etc' --dry-run 2>&1)" || rc=$?
  [[ "$rc" -eq 1 ]] || fail "bad issue id should exit 1, got $rc ($err)"
  printf '%s' "$err" | grep -q 'not a beads issue id' || fail "bad id message: $err"
  for flag in --stash-prompt --take-pending --plan; do
    rc=0
    "$ROOT/skills/handoff/scripts/handoff-spawn" --branch foo --stage cursor --issue bercail-0s1 "$flag" >/dev/null 2>&1 || rc=$?
    [[ "$rc" -eq 2 ]] || fail "$flag should be gone (usage), got $rc"
  done
  for flag in --prompt-file --brief; do
    rc=0
    "$ROOT/skills/handoff/scripts/handoff-spawn" --stage start --issue bercail-0s1 "$flag" x >/dev/null 2>&1 || rc=$?
    [[ "$rc" -eq 2 ]] || fail "$flag should be gone (usage), got $rc"
  done
  printf '#!/bin/sh\nexit 1\n' >"$TMP_DIR/no-herdr"
  chmod +x "$TMP_DIR/no-herdr"
  out="$(HERDR_BIN_PATH="$TMP_DIR/no-herdr" HANDOFF_BD_BIN="$TMP_DIR/no-bd" \
    "$ROOT/skills/handoff/scripts/handoff-spawn" --info)"
  printf '%s' "$out" | jq -e '(has("pending_prompt")|not) and .beads == false' >/dev/null \
    || fail "--info should report beads and no pending prompt: $out"
  printf 'PASS: --issue is required; prompt-file, stash, pending, plan, and brief flags are gone\n'
}

test_rejects_prompt_after_double_dash() {
  local rc=0 err
  err="$("$ROOT/skills/handoff/scripts/handoff-spawn" --branch foo --stage cursor --issue bercail-0s1 --clean -- 'QA cedar-pg' 2>&1)" || rc=$?
  [[ "$rc" -eq 1 ]] || fail "-- prompt should exit 1, got $rc ($err)"
  printf '%s' "$err" | grep -q 'there is no prompt argument' \
    || fail "double-dash message: $err"
  printf 'PASS: argv after -- is rejected so Auto-review does not bind a payload\n'
}

test_graphite_rev_parse_is_not_enough
test_copy_dirty_is_working_tree_not_index
test_usage
test_issue_prompt_is_only_the_id
test_graphite_track_uses_resolved_config_path
test_info_json_reports_graphite_and_dirty
test_info_json_socket_without_herdr_env
test_result_json_records_unconfirmed_agent
test_parent_workspace_required_without_herdr_env
test_issue_is_required_and_prompt_flags_are_gone
test_rejects_prompt_after_double_dash

test_intro_does_not_invoke_review_skill() {
  grep -q 'agentic-dev.layout' "$ROOT/skills/handoff/scripts/handoff-spawn" \
    || fail "handoff intro should name agentic-dev.layout"
  grep -q 'never agentic-dev.dev-layout' "$ROOT/skills/handoff/scripts/handoff-spawn" \
    || fail "handoff intro should forbid the old plugin id"
  grep -q 'review/SKILL.md' "$ROOT/skills/handoff/scripts/handoff-spawn" \
    && fail "handoff intro must not tell the child to load the review skill"
  grep -q 'leave them uncommitted for human review' "$ROOT/skills/handoff/scripts/handoff-spawn" \
    || fail "handoff intro should tell the child to keep changes staged, not committed"
  printf 'PASS: handoff intro does not open review via the review skill\n'
}

test_intro_does_not_invoke_review_skill

test_no_cursor_only_mode() {
  declare -F handoff_stage_poteto >/dev/null && fail "the cursor-only poteto mode must be gone"
  declare -F handoff_has_pstack >/dev/null && fail "pstack detection must be gone"
  grep -rqi 'poteto\|pstack' "$ROOT/skills/handoff/SKILL.md" "$ROOT/skills/handoff/scripts/handoff-spawn" \
    && fail "handoff must not mention poteto-mode or pstack"
  handoff_stage_field arena binary && fail "arena is not a stage yet"
  handoff_stage_field implement binary && fail "implement is not a stage yet"
  handoff_stage_field review binary && fail "review pane is not a stage yet"
  [[ "$(handoff_stage_field cursor binary)" == cursor-agent ]] || fail "cursor binary"
  [[ "$(handoff_stage_field cursor mode)" == headless ]] || fail "cursor mode is a headless peer"
  [[ "$(handoff_stage_field start mode)" == headless ]] || fail "start mode"
  [[ "$(handoff_stage_field start binary)" == claude ]] || fail "start binary stays claude"
  [[ "$(handoff_stage_field codex binary)" == codex ]] || fail "codex binary"
  [[ "$(handoff_stage_field codex mode)" == headless ]] || fail "codex mode"
  grep -q 'WT_HERDR_AGENT_CMD=cursor-agent' "$ROOT/skills/handoff/scripts/handoff-spawn" \
    && fail "handoff-spawn must not hardcode WT_HERDR_AGENT_CMD=cursor-agent"
  grep -q 'WT_HERDR_AGENT_CMD="$pane_bin"' "$ROOT/skills/handoff/scripts/handoff-spawn" \
    || fail "pane stage must publish the table binary via WT_HERDR_AGENT_CMD"
  grep -q 'WT_HERDR_AGENT_PROMPT="$prompt"' "$ROOT/skills/handoff/scripts/handoff-spawn" \
    || fail "pane stage must pass the issue prompt inline"
  grep -q 'PROMPT_FILE' "$ROOT/skills/handoff/scripts/handoff-spawn" \
    && fail "handoff-spawn must not use a prompt file"
  printf 'PASS: no cursor-only mode; every binary comes from the stage table\n'
}

test_model_resolves_opus_55_not_max_slug() {
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
  printf 'PASS: opus-5.5 resolves to the catalog id, never a *-max slug\n'
}

ISSUE=bercail-0s1

# Stub bd: knows $BD_KNOWN ids, logs comments, reports $BD_BEADS_DIR.
_bd_stub() {
  mkdir -p "$TMP_DIR/bdbin"
  cat >"$TMP_DIR/bdbin/bd" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  show)
    [[ " ${BD_KNOWN:-} " == *" $2 "* ]] || { echo "no issue $2" >&2; exit 1; }
    printf '[{"id":"%s"}]\n' "$2"
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

_start_fixture() {
  local wt="$1" catalog="$TMP_DIR/catalog.json"
  mkdir -p "$wt"
  cat >"$catalog" <<'JSON'
{"catalog":{"config":{"models":[{"id":"claude-opus-5-5","name":"Opus 5.5"}]}}}
JSON
  export BERCAIL_CLAUDE_MODEL_CATALOG="$catalog"
  _bd_stub
  unset BD_BEADS_DIR
}

test_start_stage_dry_run() {
  local wt="$TMP_DIR/start-dry" out
  _start_fixture "$wt"
  printf '#!/bin/sh\necho herdr-called >>"$TMP_DIR/herdr-hit"\nexit 9\n' >"$TMP_DIR/herdr-bomb"
  chmod +x "$TMP_DIR/herdr-bomb"
  out="$(cd "$wt" && HERDR_BIN_PATH="$TMP_DIR/herdr-bomb" \
    "$ROOT/skills/handoff/scripts/handoff-spawn" --stage start --issue "$ISSUE" --worktree "$wt" --dry-run)"
  printf '%s' "$out" | jq -e '.dry_run == true and .mode == "headless" and .stage == "start"' >/dev/null \
    || fail "dry-run json: $out"
  printf '%s' "$out" | jq -e '.model == "claude-opus-5-5"' >/dev/null || fail "model: $out"
  printf '%s' "$out" | jq -e '.command[1] == "--print" and .command[2] == "--model" and .command[3] == "claude-opus-5-5"' >/dev/null \
    || fail "argv model: $out"
  printf '%s' "$out" | jq -e 'any(.command[]; . == "--session-id") and (any(.command[]; . == "--resume") | not)' >/dev/null \
    || fail "first start should pass --session-id and not --resume: $out"
  printf '%s' "$out" | jq -e 'any(.command[]; test("poteto"))|not' >/dev/null \
    || fail "start argv must not mention poteto: $out"
  printf '%s' "$out" | jq -e --arg id "$ISSUE" '.issue == $id and .command[-1] == $id and .command[-2] == "--"' >/dev/null \
    || fail "start prompt must be only the issue id: $out"
  printf '%s' "$out" | jq -e 'any(.command[]; . == "Read,Edit,Write,Bash") and any(.command[]; . == "Bash(bd *)")' >/dev/null \
    || fail "claude must be allowed to run bd: $out"
  [[ ! -s "$BD_COMMENTS" ]] || fail "dry-run must not comment on the issue"
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
[[ "${*: -1}" == "$BERCAIL_ISSUE" && "${*: -2:1}" == -- ]] || exit 6
if [[ "${BERCAIL_EXPECT_RESUME:-}" == 1 ]]; then
  [[ "$*" == *"--resume ${BERCAIL_SESSION_ID}"* ]] || exit 4
else
  [[ "$*" == *"--session-id ${BERCAIL_SESSION_ID}"* ]] || exit 5
fi
jq -nc '{status:"ready", summary:"restated the ask and wrote a plan"}' >"$BERCAIL_RESULT_PATH"
STUB
  chmod +x "$stub"
  export HANDOFF_ARGV_LOG="$TMP_DIR/argv-log"
  export HANDOFF_CLAUDE_BIN="$stub"
  out="$(cd "$wt" && "$ROOT/skills/handoff/scripts/handoff-spawn" --stage start --issue "$ISSUE" --worktree "$wt")"
  printf '%s' "$out" | jq -e '.ok == true and .dry_run == false and .resume == false' >/dev/null \
    || fail "start json: $out"
  sid="$(jq -r '.session_id' "$wt/.bercail/handoff-result.json")"
  jq -e --arg sid "$sid" \
    '.status=="ready" and (.summary|length>0) and .session_id==$sid' \
    "$wt/.bercail/handoff-result.json" >/dev/null \
    || fail "result shape: $(cat "$wt/.bercail/handoff-result.json")"
  grep -q 'herdr' "$HANDOFF_ARGV_LOG" && fail "fixture argv called herdr: $(cat "$HANDOFF_ARGV_LOG")"
  grep -q "^$ISSUE"$'\t'"bercail handoff: stage start, headless claude, worktree $wt" "$BD_COMMENTS" \
    || fail "handoff should comment the worktree on the issue: $(cat "$BD_COMMENTS")"
  grep -qF "$wt/.bercail/handoff-result.json" "$BD_COMMENTS" \
    || fail "issue comment should name the result file: $(cat "$BD_COMMENTS")"
  grep -q 'poteto' "$HANDOFF_ARGV_LOG" && fail "fixture argv used poteto"
  export BERCAIL_EXPECT_RESUME=1
  out="$(cd "$wt" && "$ROOT/skills/handoff/scripts/handoff-spawn" \
    --stage start --issue "$ISSUE" --worktree "$wt" --resume "$sid")"
  printf '%s' "$out" | jq -e '.resume == true' >/dev/null || fail "resume json: $out"
  grep -q -- "--resume $sid" "$HANDOFF_ARGV_LOG" || fail "resume argv: $(cat "$HANDOFF_ARGV_LOG")"
  grep -q -- '--session-id' "$HANDOFF_ARGV_LOG" && fail "re-handoff must not mint a new --session-id"
  err="$(cd "$wt" && "$ROOT/skills/handoff/scripts/handoff-spawn" --stage arena --issue "$ISSUE" --dry-run 2>&1)" || rc=$?
  [[ "$rc" -eq 1 ]] || fail "unknown stage should exit 1, got $rc ($err)"
  printf '%s' "$err" | grep -q 'unknown stage' || fail "unknown stage message: $err"
  unset HANDOFF_CLAUDE_BIN HANDOFF_ARGV_LOG BERCAIL_EXPECT_RESUME BERCAIL_CLAUDE_MODEL_CATALOG
  printf 'PASS: start fixture writes handoff-result.json; re-handoff uses --resume\n'
}

test_no_cursor_only_mode
test_model_resolves_opus_55_not_max_slug
test_start_stage_dry_run
test_start_stage_resume_and_fixture_result

test_codex_headless_argv_shape() {
  local sid="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
  handoff_build_headless_argv codex /stub/codex "" "$sid" 0 "do the job"
  [[ "${HANDOFF_START_ARGV[0]}" == /stub/codex ]] || fail "bin: ${HANDOFF_START_ARGV[0]}"
  [[ "${HANDOFF_START_ARGV[1]}" == exec ]] || fail "exec: ${HANDOFF_START_ARGV[1]}"
  local joined=" ${HANDOFF_START_ARGV[*]} "
  [[ "$joined" == *" --json "* ]] || fail "missing --json: $joined"
  [[ "$joined" == *" -m "* ]] && fail "no model spec should omit -m: $joined"
  [[ "$joined" == *" --print "* ]] && fail "codex argv must not use claude --print: $joined"
  [[ "$joined" == *" --session-id "* ]] && fail "codex first start must not mint --session-id: $joined"
  [[ "$joined" == *" resume "* ]] && fail "first start must not pass resume: $joined"
  [[ "$joined" == *" poteto "* ]] && fail "codex argv used poteto"
  handoff_build_headless_argv codex /stub/codex gpt-test-model "$sid" 0 "do the job"
  joined=" ${HANDOFF_START_ARGV[*]} "
  [[ "$joined" == *" -m gpt-test-model "* ]] || fail "table model should pass -m: $joined"
  handoff_build_headless_argv codex /stub/codex gpt-test-model "$sid" 1 "continue"
  joined=" ${HANDOFF_START_ARGV[*]} "
  [[ "$joined" == *" exec --json --sandbox workspace-write resume -m gpt-test-model $sid "* ]] \
    || fail "resume subcommand: $joined"
  [[ "$joined" == *" --resume "* ]] && fail "codex resume is a subcommand, not --resume: $joined"
  [[ "$joined" == *" --ask-for-approval "* ]] && fail "codex exec --help has no --ask-for-approval: $joined"
  printf 'PASS: codex argv is exec --json, optional -m, resume SESSION\n'
}

test_codex_thread_id_from_jsonl() {
  local log="$TMP_DIR/codex.jsonl" id
  printf '%s\n' \
    '{"type":"turn.started"}' \
    '{"type":"thread.started","thread_id":"0199a213-81c0-7800-8aa1-bbab2a035a53"}' \
    '{"type":"turn.completed"}' >"$log"
  id="$(handoff_codex_thread_id "$log")"
  [[ "$id" == 0199a213-81c0-7800-8aa1-bbab2a035a53 ]] || fail "thread_id: $id"
  printf 'PASS: Codex JSONL thread.started yields thread_id\n'
}

test_codex_stage_dry_run() {
  local wt="$TMP_DIR/codex-dry" out sid="bbbbbbbb-cccc-dddd-eeee-ffffffffffff"
  _start_fixture "$wt"
  out="$(cd "$wt" && HERDR_BIN_PATH="$TMP_DIR/herdr-bomb" \
    "$ROOT/skills/handoff/scripts/handoff-spawn" --stage codex --issue "$ISSUE" --worktree "$wt" --dry-run)"
  printf '%s' "$out" | jq -e '.dry_run == true and .mode == "headless" and .stage == "codex" and .binary == "codex"' >/dev/null \
    || fail "codex dry-run json: $out"
  printf '%s' "$out" | jq -e '.command[1] == "exec" and any(.command[]; . == "--json") and any(.command[]; . == "--sandbox")' >/dev/null \
    || fail "codex exec --json --sandbox: $out"
  printf '%s' "$out" | jq -e 'any(.command[]; . == "-m")|not' >/dev/null \
    || fail "default codex row omits -m: $out"
  printf '%s' "$out" | jq -e 'any(.command[]; . == "--print")|not' >/dev/null \
    || fail "codex must not use --print: $out"
  printf '%s' "$out" | jq -e '(any(.command[]; . == "--session-id") | not) and (any(.command[]; . == "resume") | not)' >/dev/null \
    || fail "first codex start has no session flag: $out"
  printf '%s' "$out" | jq -e '.session_id == ""' >/dev/null \
    || fail "first codex dry-run must not mint a uuid: $out"
  printf '%s' "$out" | jq -e 'any(.command[]; test("poteto|herdr|cursor-agent"))|not' >/dev/null \
    || fail "codex argv leaked pane bits: $out"
  [[ ! -f "$wt/.bercail/handoff-result.json" ]] || fail "codex dry-run must not write a result"
  out="$(cd "$wt" && "$ROOT/skills/handoff/scripts/handoff-spawn" \
    --stage start --issue "$ISSUE" --binary codex --worktree "$wt" --dry-run)"
  printf '%s' "$out" | jq -e '.stage == "start" and .binary == "codex" and .command[1] == "exec"' >/dev/null \
    || fail "--binary codex on start: $out"
  printf '%s' "$out" | jq -e 'any(.command[]; . == "-m")|not' >/dev/null \
    || fail "start --binary codex must not pass opus-5.5 as -m: $out"
  out="$(cd "$wt" && "$ROOT/skills/handoff/scripts/handoff-spawn" \
    --stage codex --issue "$ISSUE" --worktree "$wt" --resume "$sid" --dry-run)"
  printf '%s' "$out" | jq -e '.resume == true' >/dev/null || fail "codex resume json: $out"
  printf '%s' "$out" | jq -e --arg sid "$sid" \
    'any(.command[]; . == "resume") and any(.command[]; . == $sid)' >/dev/null \
    || fail "codex exec resume SESSION: $out"
  printf '%s' "$out" | jq -e 'any(.command[]; . == "--resume")|not' >/dev/null \
    || fail "codex must not pass --resume: $out"
  local rc=0 err
  err="$(cd "$wt" && "$ROOT/skills/handoff/scripts/handoff-spawn" \
    --stage start --issue "$ISSUE" --binary cursor --worktree "$wt" --dry-run 2>&1)" || rc=$?
  [[ "$rc" -eq 1 ]] || fail "bad --binary should exit 1, got $rc ($err)"
  printf '%s' "$err" | grep -q 'claude, codex, or cursor-agent' || fail "bad --binary message: $err"
  unset BERCAIL_CLAUDE_MODEL_CATALOG
  printf 'PASS: codex dry-run is exec --json; resume is exec resume; --binary selects it\n'
}

test_codex_fixture_records_thread_id() {
  local wt="$TMP_DIR/codex-run" out stub="$TMP_DIR/bin/codex" tid="0199a213-81c0-7800-8aa1-bbab2a035a53"
  mkdir -p "$TMP_DIR/bin"
  _start_fixture "$wt"
  cat >"$stub" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >"${HANDOFF_ARGV_LOG:?}"
[[ "$1" == exec ]] || exit 2
[[ " $* " == *" --json "* ]] || exit 3
if [[ "${BERCAIL_EXPECT_RESUME:-}" == 1 ]]; then
  [[ " $* " == *" resume ${BERCAIL_SESSION_ID} "* ]] || exit 4
else
  [[ " $* " == *" resume "* ]] && exit 5
fi
printf '%s\n' "{\"type\":\"thread.started\",\"thread_id\":\"${CODEX_THREAD_ID}\"}"
jq -nc --arg sid "$BERCAIL_SESSION_ID" \
  '{status:"ready", summary:"restated the ask and wrote a plan", session_id:$sid}' \
  >"$BERCAIL_RESULT_PATH"
STUB
  chmod +x "$stub"
  export HANDOFF_ARGV_LOG="$TMP_DIR/codex-argv-log"
  export HANDOFF_CODEX_BIN="$stub"
  export CODEX_THREAD_ID="$tid"
  out="$(cd "$wt" && "$ROOT/skills/handoff/scripts/handoff-spawn" --stage codex --issue "$ISSUE" --worktree "$wt")"
  printf '%s' "$out" | jq -e '.ok == true and .binary == "codex" and .dry_run == false' >/dev/null \
    || fail "codex start json: $out"
  jq -e --arg tid "$tid" '.status=="ready" and .session_id==$tid' \
    "$wt/.bercail/handoff-result.json" >/dev/null \
    || fail "result must record Codex thread_id: $(cat "$wt/.bercail/handoff-result.json")"
  grep -q -- '--print' "$HANDOFF_ARGV_LOG" && fail "codex fixture used --print"
  export BERCAIL_EXPECT_RESUME=1
  out="$(cd "$wt" && "$ROOT/skills/handoff/scripts/handoff-spawn" \
    --stage codex --issue "$ISSUE" --worktree "$wt" --resume "$tid")"
  printf '%s' "$out" | jq -e '.resume == true' >/dev/null || fail "codex resume json: $out"
  grep -q -- "resume $tid" "$HANDOFF_ARGV_LOG" || fail "resume argv: $(cat "$HANDOFF_ARGV_LOG")"
  grep -q -- '--resume' "$HANDOFF_ARGV_LOG" && fail "re-handoff must use exec resume, not --resume"
  unset HANDOFF_CODEX_BIN HANDOFF_ARGV_LOG BERCAIL_EXPECT_RESUME CODEX_THREAD_ID BERCAIL_CLAUDE_MODEL_CATALOG
  printf 'PASS: Codex fixture writes thread_id into handoff-result.json; re-handoff uses exec resume\n'
}

test_headless_prompt_is_the_issue_id() {
  local wt="$TMP_DIR/prompt-id" stage out outside="$TMP_DIR/main-checkout/.beads"
  _start_fixture "$wt"
  for stage in start codex cursor; do
    out="$(cd "$wt" && "$ROOT/skills/handoff/scripts/handoff-spawn" --stage "$stage" --issue "$ISSUE" --worktree "$wt" --dry-run)"
    printf '%s' "$out" | jq -e --arg id "$ISSUE" '.command[-1] == $id and .command[-2] == "--" and .bd_present == true' >/dev/null \
      || fail "$stage prompt must be only the issue id: $out"
    printf '%s' "$out" | jq -e 'any(.command[]; . == "--add-dir")|not' >/dev/null \
      || fail "$stage: .beads inside the worktree needs no --add-dir: $out"
  done
  # A linked worktree resolves the main checkout's .beads; the harness must reach it.
  export BD_BEADS_DIR="$outside"
  for stage in start codex cursor; do
    out="$(cd "$wt" && "$ROOT/skills/handoff/scripts/handoff-spawn" --stage "$stage" --issue "$ISSUE" --worktree "$wt" --dry-run)"
    printf '%s' "$out" | jq -e --arg d "$outside" \
      '[.command | to_entries[] | select(.value == "--add-dir") | .key + 1] as $i | ($i | length) == 1 and .command[$i[0]] == $d' >/dev/null \
      || fail "$stage must --add-dir the outside .beads: $out"
  done
  out="$(cd "$wt" && "$ROOT/skills/handoff/scripts/handoff-spawn" --stage codex --issue "$ISSUE" --worktree "$wt" \
    --resume 0199a213-81c0-7800-8aa1-bbab2a035a53 --dry-run)"
  printf '%s' "$out" | jq -e '(.command | index("--add-dir")) < (.command | index("resume"))' >/dev/null \
    || fail "codex --add-dir must precede the resume subcommand: $out"
  unset BD_BEADS_DIR BERCAIL_CLAUDE_MODEL_CATALOG
  printf 'PASS: each headless prompt is the issue id; an outside .beads gets --add-dir\n'
}

test_codex_headless_argv_shape
test_codex_thread_id_from_jsonl
test_codex_stage_dry_run
test_codex_fixture_records_thread_id
test_headless_prompt_is_the_issue_id

test_cursor_headless_argv_shape() {
  local sid="cccccccc-dddd-eeee-ffff-000000000001"
  handoff_build_headless_argv cursor-agent /stub/cursor-agent "" "$sid" 0 "do the job"
  [[ "${HANDOFF_START_ARGV[0]}" == /stub/cursor-agent ]] || fail "bin: ${HANDOFF_START_ARGV[0]}"
  [[ "${HANDOFF_START_ARGV[1]}" == --print ]] || fail "print: ${HANDOFF_START_ARGV[1]}"
  local joined=" ${HANDOFF_START_ARGV[*]} "
  [[ "$joined" == *" --output-format json "* ]] || fail "missing json output: $joined"
  [[ "$joined" == *" --session-id "* ]] && fail "cursor-agent has no --session-id: $joined"
  [[ "$joined" == *" --resume "* ]] && fail "first start must not pass --resume: $joined"
  [[ "$joined" == *" exec "* ]] && fail "cursor-agent argv must not use codex exec: $joined"
  [[ "$joined" == *" --model "* ]] && fail "no model spec should omit --model: $joined"
  [[ "$joined" == *" poteto "* ]] && fail "cursor-agent argv used poteto"
  handoff_build_headless_argv cursor-agent /stub/cursor-agent grok-test-model "$sid" 0 "do the job"
  joined=" ${HANDOFF_START_ARGV[*]} "
  [[ "$joined" == *" --model grok-test-model "* ]] || fail "table model should pass --model: $joined"
  handoff_build_headless_argv cursor-agent /stub/cursor-agent grok-test-model "$sid" 1 "continue"
  joined=" ${HANDOFF_START_ARGV[*]} "
  [[ "$joined" == *" --resume $sid "* ]] || fail "resume flag: $joined"
  [[ "$joined" == *" resume $sid "* && "$joined" != *" --resume $sid "* ]] && fail "must not use codex resume subcommand: $joined"
  printf 'PASS: cursor-agent argv is --print --output-format json, optional --model, --resume SESSION\n'
}

test_cursor_session_id_from_json() {
  local log="$TMP_DIR/cursor.json" id
  printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"ok","session_id":"dddddddd-eeee-ffff-0000-111111111111"}' >"$log"
  id="$(handoff_cursor_session_id "$log")"
  [[ "$id" == dddddddd-eeee-ffff-0000-111111111111 ]] || fail "session_id: $id"
  printf 'PASS: cursor-agent JSON result yields session_id\n'
}

test_cursor_stage_dry_run() {
  local wt="$TMP_DIR/cursor-dry" out sid="eeeeeeee-ffff-0000-1111-222222222222"
  _start_fixture "$wt"
  out="$(cd "$wt" && HERDR_BIN_PATH="$TMP_DIR/herdr-bomb" \
    "$ROOT/skills/handoff/scripts/handoff-spawn" --stage cursor --issue "$ISSUE" --worktree "$wt" --dry-run)"
  printf '%s' "$out" | jq -e '.dry_run == true and .mode == "headless" and .stage == "cursor" and .binary == "cursor-agent"' >/dev/null \
    || fail "cursor dry-run json: $out"
  printf '%s' "$out" | jq -e '.command[1] == "--print" and any(.command[]; . == "--output-format")' >/dev/null \
    || fail "cursor-agent --print --output-format: $out"
  printf '%s' "$out" | jq -e 'any(.command[]; . == "json")' >/dev/null \
    || fail "cursor-agent json output: $out"
  printf '%s' "$out" | jq -e 'any(.command[]; . == "--model")|not' >/dev/null \
    || fail "default cursor row omits --model: $out"
  printf '%s' "$out" | jq -e 'any(.command[]; . == "--session-id")|not' >/dev/null \
    || fail "cursor-agent first start has no --session-id: $out"
  printf '%s' "$out" | jq -e 'any(.command[]; . == "exec")|not' >/dev/null \
    || fail "cursor-agent must not use codex exec: $out"
  printf '%s' "$out" | jq -e '.session_id == ""' >/dev/null \
    || fail "first cursor dry-run must not mint a uuid: $out"
  printf '%s' "$out" | jq -e 'any(.command[]; test("poteto|herdr"))|not' >/dev/null \
    || fail "cursor argv leaked pane bits: $out"
  [[ ! -f "$wt/.bercail/handoff-result.json" ]] || fail "cursor dry-run must not write a result"
  out="$(cd "$wt" && "$ROOT/skills/handoff/scripts/handoff-spawn" \
    --stage start --issue "$ISSUE" --binary cursor-agent --worktree "$wt" --dry-run)"
  printf '%s' "$out" | jq -e '.stage == "start" and .binary == "cursor-agent" and .command[1] == "--print"' >/dev/null \
    || fail "--binary cursor-agent on start: $out"
  printf '%s' "$out" | jq -e 'any(.command[]; . == "--model")|not' >/dev/null \
    || fail "start --binary cursor-agent must not pass opus-5.5 as --model: $out"
  out="$(cd "$wt" && "$ROOT/skills/handoff/scripts/handoff-spawn" \
    --stage cursor --issue "$ISSUE" --worktree "$wt" --resume "$sid" --dry-run)"
  printf '%s' "$out" | jq -e '.resume == true' >/dev/null || fail "cursor resume json: $out"
  printf '%s' "$out" | jq -e --arg sid "$sid" \
    'any(.command[]; . == "--resume") and any(.command[]; . == $sid)' >/dev/null \
    || fail "cursor-agent --resume SESSION: $out"
  printf '%s' "$out" | jq -e 'any(.command[]; . == "--session-id")|not' >/dev/null \
    || fail "cursor-agent must not pass --session-id: $out"
  unset BERCAIL_CLAUDE_MODEL_CATALOG
  printf 'PASS: cursor dry-run is --print json; resume is --resume; --binary selects it\n'
}

test_cursor_fixture_records_session_id() {
  local wt="$TMP_DIR/cursor-run" out stub="$TMP_DIR/bin/cursor-agent" sid="ffffffff-0000-1111-2222-333333333333"
  mkdir -p "$TMP_DIR/bin"
  _start_fixture "$wt"
  cat >"$stub" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >"${HANDOFF_ARGV_LOG:?}"
[[ " $* " == *" --print "* ]] || exit 2
[[ " $* " == *" --output-format json "* ]] || exit 3
if [[ "${BERCAIL_EXPECT_RESUME:-}" == 1 ]]; then
  [[ " $* " == *" --resume ${BERCAIL_SESSION_ID} "* ]] || exit 4
else
  [[ " $* " == *" --resume "* ]] && exit 5
  [[ " $* " == *" --session-id "* ]] && exit 6
fi
printf '%s\n' "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":\"ok\",\"session_id\":\"${CURSOR_SESSION_ID}\"}"
jq -nc --arg sid "$CURSOR_SESSION_ID" \
  '{status:"ready", summary:"restated the ask and wrote a plan", session_id:$sid}' \
  >"$BERCAIL_RESULT_PATH"
STUB
  chmod +x "$stub"
  export HANDOFF_ARGV_LOG="$TMP_DIR/cursor-argv-log"
  export HANDOFF_CURSOR_BIN="$stub"
  export CURSOR_SESSION_ID="$sid"
  out="$(cd "$wt" && "$ROOT/skills/handoff/scripts/handoff-spawn" --stage cursor --issue "$ISSUE" --worktree "$wt")"
  printf '%s' "$out" | jq -e '.ok == true and .binary == "cursor-agent" and .dry_run == false' >/dev/null \
    || fail "cursor start json: $out"
  jq -e --arg sid "$sid" '.status=="ready" and .session_id==$sid' \
    "$wt/.bercail/handoff-result.json" >/dev/null \
    || fail "result must record cursor-agent session_id: $(cat "$wt/.bercail/handoff-result.json")"
  grep -q -- 'exec' "$HANDOFF_ARGV_LOG" && fail "cursor fixture used codex exec"
  grep -q -- '--session-id' "$HANDOFF_ARGV_LOG" && fail "cursor fixture used --session-id"
  export BERCAIL_EXPECT_RESUME=1
  out="$(cd "$wt" && "$ROOT/skills/handoff/scripts/handoff-spawn" \
    --stage cursor --issue "$ISSUE" --worktree "$wt" --resume "$sid")"
  printf '%s' "$out" | jq -e '.resume == true' >/dev/null || fail "cursor resume json: $out"
  grep -q -- "--resume $sid" "$HANDOFF_ARGV_LOG" || fail "resume argv: $(cat "$HANDOFF_ARGV_LOG")"
  grep -q -- '--session-id' "$HANDOFF_ARGV_LOG" && fail "re-handoff must use --resume, not --session-id"
  unset HANDOFF_CURSOR_BIN HANDOFF_ARGV_LOG BERCAIL_EXPECT_RESUME CURSOR_SESSION_ID BERCAIL_CLAUDE_MODEL_CATALOG
  printf 'PASS: cursor-agent fixture writes session_id into handoff-result.json; re-handoff uses --resume\n'
}

test_cursor_headless_argv_shape
test_cursor_session_id_from_json
test_cursor_stage_dry_run
test_cursor_fixture_records_session_id

test_missing_harness_blocks_without_fallback() {
  local wt="$TMP_DIR/missing-claude" rc=0 err
  _start_fixture "$wt"
  unset HANDOFF_CODEX_BIN
  export HANDOFF_CLAUDE_BIN="$TMP_DIR/no-such-claude"
  err="$(cd "$wt" && \
    "$ROOT/skills/handoff/scripts/handoff-spawn" --stage start --issue "$ISSUE" --worktree "$wt" 2>"$TMP_DIR/missing.err")" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "missing claude should exit nonzero, got 0 ($err)"
  grep -q 'not on PATH' "$TMP_DIR/missing.err" || fail "stderr should say not on PATH: $(cat "$TMP_DIR/missing.err")"
  jq -e '.status=="blocked" and (.summary|test("claude"))' \
    "$wt/.bercail/handoff-result.json" >/dev/null \
    || fail "blocked result: $(cat "$wt/.bercail/handoff-result.json")"
  printf '%s' "$err" | jq -e '.status=="blocked" and (has("command")|not)' >/dev/null \
    || fail "stdout should be the blocked result, not a start command: $err"
  rc=0
  unset HANDOFF_CLAUDE_BIN
  export HANDOFF_CURSOR_BIN="$TMP_DIR/no-such-cursor-agent"
  err="$(cd "$wt" && "$ROOT/skills/handoff/scripts/handoff-spawn" \
    --stage cursor --issue "$ISSUE" --branch feat --clean --workspace w1 2>&1)" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "missing cursor-agent should exit nonzero"
  printf '%s' "$err" | grep -q 'cursor-agent is not on PATH' \
    || fail "pane missing message: $err"
  printf '%s' "$err" | grep -q 'wt ' && fail "must fail before wt: $err"
  rc=0
  unset HANDOFF_CURSOR_BIN
  export HANDOFF_CURSOR_BIN="$TMP_DIR/no-such-cursor-agent-headless"
  err="$(cd "$wt" && "$ROOT/skills/handoff/scripts/handoff-spawn" \
    --stage cursor --issue "$ISSUE" --worktree "$wt" 2>"$TMP_DIR/missing-cursor.err")" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "missing headless cursor-agent should exit nonzero, got 0 ($err)"
  grep -q 'not on PATH' "$TMP_DIR/missing-cursor.err" \
    || fail "stderr should say not on PATH: $(cat "$TMP_DIR/missing-cursor.err")"
  jq -e '.status=="blocked" and (.summary|test("cursor-agent"))' \
    "$wt/.bercail/handoff-result.json" >/dev/null \
    || fail "blocked cursor result: $(cat "$wt/.bercail/handoff-result.json")"
  printf '%s' "$err" | jq -e '.status=="blocked" and (has("command")|not)' >/dev/null \
    || fail "stdout should be the blocked result, not a start command: $err"
  grep -q 'claude' "$wt/.bercail/handoff-result.json" \
    && fail "must not fall through to claude: $(cat "$wt/.bercail/handoff-result.json")"
  unset HANDOFF_CURSOR_BIN BERCAIL_CLAUDE_MODEL_CATALOG
  printf 'PASS: missing harness writes blocked result and does not fall through\n'
}

test_missing_harness_blocks_without_fallback


test_dry_run_prints_all_three_stages() {
  local wt="$TMP_DIR/all-dry" out stage want rc=0 err
  _start_fixture "$wt"
  export HANDOFF_CLAUDE_BIN="$TMP_DIR/gone-claude"
  export HANDOFF_CODEX_BIN="$TMP_DIR/gone-codex"
  export HANDOFF_CURSOR_BIN="$TMP_DIR/gone-cursor-agent"
  export HANDOFF_BD_BIN="$TMP_DIR/gone-bd"
  for stage in start codex cursor; do
    case "$stage" in
      start) want=gone-claude ;;
      codex) want=gone-codex ;;
      cursor) want=gone-cursor-agent ;;
    esac
    out="$(cd "$wt" && "$ROOT/skills/handoff/scripts/handoff-spawn" \
      --stage "$stage" --issue "$ISSUE" --worktree "$wt" --dry-run)"
    printf '%s' "$out" | jq -e --arg want "$TMP_DIR/$want" \
      '.dry_run == true and .present == false and .bd_present == false and .command[0] == $want and (.command | length) > 2' >/dev/null \
      || fail "$stage dry-run should print its own argv even when missing: $out"
    printf '%s' "$out" | jq -e 'any(.command[]; test("poteto")) | not' >/dev/null \
      || fail "$stage headless argv must not use /poteto-mode: $out"
  done
  [[ ! -f "$wt/.bercail/handoff-result.json" ]] || fail "dry-run must not write a result"
  _bd_stub
  err="$(cd "$wt" && "$ROOT/skills/handoff/scripts/handoff-spawn" \
    --stage codex --issue "$ISSUE" --worktree "$wt" 2>/dev/null)" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "missing codex should exit nonzero"
  jq -e '.status=="blocked" and (.summary|test("codex"))' "$wt/.bercail/handoff-result.json" >/dev/null \
    || fail "missing codex should block: $(cat "$wt/.bercail/handoff-result.json")"
  unset HANDOFF_CLAUDE_BIN HANDOFF_CODEX_BIN HANDOFF_CURSOR_BIN BERCAIL_CLAUDE_MODEL_CATALOG
  printf 'PASS: dry-run prints argv for start, codex, and cursor; missing codex blocks\n'
}

test_dry_run_prints_all_three_stages

test_missing_bd_or_issue_blocks() {
  local wt="$TMP_DIR/bd-block" rc=0 out stub="$TMP_DIR/bin/claude"
  _start_fixture "$wt"
  mkdir -p "$TMP_DIR/bin"
  printf '#!/bin/sh\necho ran >"%s/claude-ran"\n' "$TMP_DIR" >"$stub"
  chmod +x "$stub"
  export HANDOFF_CLAUDE_BIN="$stub"
  export HANDOFF_BD_BIN="$TMP_DIR/no-such-bd"
  out="$(cd "$wt" && "$ROOT/skills/handoff/scripts/handoff-spawn" --stage start --issue "$ISSUE" --worktree "$wt" 2>/dev/null)" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "missing bd should exit nonzero"
  jq -e '.status=="blocked" and (.summary|test("bd \\(beads\\) is not on PATH"))' "$wt/.bercail/handoff-result.json" >/dev/null \
    || fail "missing bd should block: $(cat "$wt/.bercail/handoff-result.json")"
  _bd_stub
  rc=0
  out="$(cd "$wt" && "$ROOT/skills/handoff/scripts/handoff-spawn" --stage start --issue bercail-nope --worktree "$wt" 2>/dev/null)" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "unknown issue should exit nonzero"
  jq -e '.status=="blocked" and (.summary|test("bercail-nope not found"))' "$wt/.bercail/handoff-result.json" >/dev/null \
    || fail "unknown issue should block: $(cat "$wt/.bercail/handoff-result.json")"
  [[ ! -f "$TMP_DIR/claude-ran" ]] || fail "harness must not start without a real issue"
  [[ ! -s "$BD_COMMENTS" ]] || fail "blocked handoff must not comment: $(cat "$BD_COMMENTS")"
  unset HANDOFF_CLAUDE_BIN BERCAIL_CLAUDE_MODEL_CATALOG
  printf 'PASS: missing bd or an unknown issue writes a blocked result and starts nothing\n'
}

test_missing_bd_or_issue_blocks

test_stage_is_required_and_any_stage_can_branch() {
  local rc=0 err stage want
  err="$("$ROOT/skills/handoff/scripts/handoff-spawn" --branch foo --issue "$ISSUE" 2>&1)" || rc=$?
  [[ "$rc" -eq 1 ]] || fail "missing --stage should exit 1, got $rc ($err)"
  printf '%s' "$err" | grep -q 'does not pick a harness' || fail "missing --stage message: $err"
  rc=0
  err="$("$ROOT/skills/handoff/scripts/handoff-spawn" --issue "$ISSUE" --dry-run 2>&1)" || rc=$?
  [[ "$rc" -eq 1 ]] || fail "headless without --stage should exit 1, got $rc ($err)"
  export HANDOFF_CLAUDE_BIN="$TMP_DIR/gone-claude" HANDOFF_CODEX_BIN="$TMP_DIR/gone-codex" \
    HANDOFF_CURSOR_BIN="$TMP_DIR/gone-cursor-agent"
  for stage in start codex cursor; do
    case "$stage" in
      start) want=claude ;;
      codex) want=codex ;;
      cursor) want=cursor-agent ;;
    esac
    rc=0
    err="$("$ROOT/skills/handoff/scripts/handoff-spawn" --branch feat --stage "$stage" --issue "$ISSUE" --clean --workspace w1 2>&1)" || rc=$?
    [[ "$rc" -eq 1 ]] || fail "$stage pane with a missing binary should exit 1, got $rc ($err)"
    printf '%s' "$err" | grep -q "requested harness $want is not on PATH" \
      || fail "$stage --branch should be a pane for $want, not refused: $err"
    printf '%s' "$err" | grep -q 'does not create a branch' && fail "$stage must be allowed a --branch pane: $err"
  done
  unset HANDOFF_CLAUDE_BIN HANDOFF_CODEX_BIN HANDOFF_CURSOR_BIN
  printf 'PASS: --stage is required; claude, codex, and cursor-agent can each run a --branch pane\n'
}

test_stage_is_required_and_any_stage_can_branch

test_no_session_id_is_not_invented() {
  local wt="$TMP_DIR/no-tid" stub="$TMP_DIR/bin/codex-quiet" rc=0
  mkdir -p "$TMP_DIR/bin"
  _start_fixture "$wt"
  # A Codex run whose log has no thread.started line.
  printf '#!/usr/bin/env bash\njq -nc %s >"$BERCAIL_RESULT_PATH"\n' \
    "'{status:\"ready\", summary:\"planned the fix\"}'" >"$stub"
  chmod +x "$stub"
  export HANDOFF_CODEX_BIN="$stub"
  (cd "$wt" && "$ROOT/skills/handoff/scripts/handoff-spawn" --stage codex --issue "$ISSUE" --worktree "$wt" >/dev/null) || rc=$?
  [[ "$rc" -eq 0 ]] || fail "a ready result without a session id should still exit 0, got $rc"
  jq -e '.status == "ready" and .session_id == "none" and (.summary | startswith("planned the fix")) and (.summary | test("cannot be resumed"))' \
    "$wt/.bercail/handoff-result.json" >/dev/null \
    || fail "keep the agent's result, say there is no session: $(cat "$wt/.bercail/handoff-result.json")"
  export HANDOFF_CODEX_BIN="$TMP_DIR/gone-codex"
  rc=0
  (cd "$wt" && "$ROOT/skills/handoff/scripts/handoff-spawn" --stage codex --issue "$ISSUE" --worktree "$wt" >/dev/null 2>&1) || rc=$?
  [[ "$rc" -ne 0 ]] || fail "missing codex should exit nonzero"
  jq -e '.status == "blocked" and .session_id == "none"' "$wt/.bercail/handoff-result.json" >/dev/null \
    || fail "blocked before a codex run has no session to invent: $(cat "$wt/.bercail/handoff-result.json")"
  rc=0
  (cd "$wt" && "$ROOT/skills/handoff/scripts/handoff-spawn" --stage codex --issue "$ISSUE" --worktree "$wt" --resume none --dry-run >/dev/null 2>&1) || rc=$?
  [[ "$rc" -eq 1 ]] || fail "--resume none must be refused, got $rc"
  unset HANDOFF_CODEX_BIN BERCAIL_CLAUDE_MODEL_CATALOG
  printf 'PASS: no session id from the CLI gives session_id none, never an invented uuid\n'
}

test_no_session_id_is_not_invented
