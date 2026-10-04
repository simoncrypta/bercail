# Handoff stage table and headless runner. Sourced by handoff-spawn and handoff-brief.
# shellcheck shell=bash

# One row per named stage. The router reads this table; it does not special-case
# a binary. Add a row (and, for headless, prompts/<stage>.txt) to extend.
# Do not add arena, implement, or the Composer review pane in this slice.
#
# name <TAB> binary <TAB> mode <TAB> model
#   mode:  headless | pane
#   model: "-" or "opus-5.5" (resolved from the claude model catalog)
# /poteto-mode is not a column. It is prefixed only when mode=pane and the
# binary is cursor or cursor-agent.
handoff_stage_table() {
  cat <<'TABLE'
# name	binary	mode	model
# headless writes <worktree>/.bercail/handoff-result.json and does not open a Herdr pane.
# pane publishes binary via WT_HERDR_AGENT_CMD (lifecycle.sh already honors it).
start	claude	headless	opus-5.5
cursor	cursor-agent	pane	-
TABLE
}

if ! declare -F handoff_die >/dev/null 2>&1; then
  handoff_die() {
    printf 'handoff: %s\n' "$*" >&2
    exit 1
  }
fi

_handoff_lib_dir() {
  cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
}

handoff_stage_field() {
  local name="$1" field="$2" line n binary mode model
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" && "$line" != \#* ]] || continue
    IFS=$'\t' read -r n binary mode model <<<"$line"
    [[ "$n" == "$name" ]] || continue
    case "$field" in
      binary) printf '%s' "$binary" ;;
      mode) printf '%s' "$mode" ;;
      model) printf '%s' "$model" ;;
      *) return 1 ;;
    esac
    return 0
  done < <(handoff_stage_table)
  return 1
}

handoff_stage_names_json() {
  handoff_stage_table \
    | awk -F '\t' 'NF >= 1 && $1 !~ /^#/ { print $1 }' \
    | jq -R . | jq -sc .
}

# True when this stage's pane prompt should start with /poteto-mode.
handoff_stage_poteto() {
  local stage="$1" mode binary
  mode="$(handoff_stage_field "$stage" mode)" || return 1
  binary="$(handoff_stage_field "$stage" binary)" || return 1
  [[ "$mode" == pane ]] || return 1
  case "$binary" in
    cursor|cursor-agent) return 0 ;;
  esac
  return 1
}

handoff_abspath() {
  local path="$1"
  if [[ -d "$path" ]]; then
    (cd "$path" && pwd -P)
  else
    printf '%s' "$path"
  fi
}

handoff_brief_path() {
  printf '%s/.bercail/job-brief.json' "$1"
}

handoff_result_path() {
  printf '%s/.bercail/handoff-result.json' "$1"
}

handoff_json_string_array() {
  local out='[]' item
  for item in "$@"; do
    out="$(jq -nc --argjson arr "$out" --arg item "$item" '$arr + [$item]')"
  done
  printf '%s' "$out"
}

# Intake is not a stage. linear, ask, and note all write the same brief.
handoff_write_brief() {
  local dest="$1" ask="$2" repo="$3" source="$4"
  shift 4
  local links
  links="$(handoff_json_string_array "$@")"
  mkdir -p "$(dirname "$dest")"
  jq -nc \
    --arg ask "$ask" \
    --arg repo "$repo" \
    --arg source "$source" \
    --argjson links "$links" \
    '{ask:$ask, repo:$repo, links:$links, source:$source}' >"$dest"
}

handoff_brief_ok() {
  jq -e '
    (.ask | type == "string" and length > 0)
    and (.repo | type == "string" and length > 0)
    and (.links | type == "array")
    and (.source == "linear" or .source == "ask" or .source == "note")
  ' "$1" >/dev/null
}

handoff_write_result() {
  local dest="$1" status="$2" summary="$3" session="$4"
  mkdir -p "$(dirname "$dest")"
  jq -nc \
    --arg status "$status" \
    --arg summary "$summary" \
    --arg session_id "$session" \
    '{status:$status, summary:$summary, session_id:$session_id}' >"$dest"
}

handoff_result_ok() {
  jq -e '
    (.status == "ready" or .status == "blocked" or .status == "failed")
    and (.summary | type == "string" and length > 0)
    and (.session_id | type == "string" and length > 0)
  ' "$1" >/dev/null
}

handoff_is_uuid() {
  [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

handoff_new_session_id() {
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    tr -d '[:space:]' </proc/sys/kernel/random/uuid
    return 0
  fi
  python3 -c 'import uuid; print(uuid.uuid4())'
}

handoff_claude_catalog_file() {
  local dir newest
  if [[ -n "${BERCAIL_CLAUDE_MODEL_CATALOG:-}" ]]; then
    [[ -f "$BERCAIL_CLAUDE_MODEL_CATALOG" ]] || return 1
    printf '%s' "$BERCAIL_CLAUDE_MODEL_CATALOG"
    return 0
  fi
  dir="${HOME}/.claude/cache/model-catalog"
  [[ -d "$dir" ]] || return 1
  newest="$(find "$dir" -type f -name '*.json' -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk 'NR==1 { print $2 }')"
  [[ -n "$newest" && -f "$newest" ]] || return 1
  printf '%s' "$newest"
}

# opus-5.5 -> catalog id whose name is "Opus 5.5". Never the pstack slug *-max.
# If the catalog has no Opus 5.5, the first other claude-opus id. If there is
# no catalog, the help-text alias "opus" (claude --help does not list full ids).
handoff_resolve_model() {
  local spec="$1" catalog id
  [[ -n "$spec" && "$spec" != "-" ]] || return 0
  if [[ "$spec" == *max ]]; then
    handoff_die "refusing pstack model slug: $spec"
  fi
  if [[ "$spec" != opus-5.5 ]]; then
    printf '%s' "$spec"
    return 0
  fi
  catalog="$(handoff_claude_catalog_file 2>/dev/null || true)"
  if [[ -n "$catalog" ]]; then
    id="$(jq -r '
      .catalog.config.models[]?
      | select(.name == "Opus 5.5")
      | .id
      | select(endswith("-max") | not)
    ' "$catalog" | head -1)"
    if [[ -n "$id" && "$id" != null ]]; then
      printf '%s' "$id"
      return 0
    fi
    id="$(jq -r '
      .catalog.config.models[]?
      | .id
      | select(startswith("claude-opus"))
      | select(endswith("-max") | not)
    ' "$catalog" | head -1)"
    if [[ -n "$id" && "$id" != null ]]; then
      printf 'handoff: catalog has no Opus 5.5 id; using closest opus %s\n' "$id" >&2
      printf '%s' "$id"
      return 0
    fi
  fi
  printf 'handoff: claude model catalog has no Opus 5.5 id; using alias opus\n' >&2
  printf '%s' "opus"
}

handoff_render_template() {
  local file="$1" brief="$2" result="$3" session="$4" resume_note="$5" text
  [[ -f "$file" ]] || handoff_die "no prompt template for this stage: $file"
  text="$(cat -- "$file")"
  text="${text//@BRIEF@/$brief}"
  text="${text//@RESULT@/$result}"
  text="${text//@SESSION@/$session}"
  text="${text//@RESUME_NOTE@/$resume_note}"
  printf '%s' "$text"
}

handoff_prompt_template() {
  local stage="$1" path
  path="$(_handoff_lib_dir)/../prompts/${stage}.txt"
  [[ -f "$path" ]] || handoff_die "stage $stage has no prompt template ($path)"
  printf '%s' "$path"
}

# Headless stage: one claude --print process. No Herdr pane, no ANSI scrape.
# Re-handoff passes --resume <session_id> instead of killing a pane.
handoff_run_headless() {
  local stage="$1" worktree="$2" brief="$3" resume="$4" dry="$5"
  local mode binary model_spec model session resumed=0 template resume_note prompt
  local result log bin cmd_json out rc=0

  command -v jq >/dev/null 2>&1 || handoff_die "jq is required"
  mode="$(handoff_stage_field "$stage" mode)" || handoff_die "unknown stage: $stage"
  [[ "$mode" == headless ]] || handoff_die "stage $stage is not headless"
  binary="$(handoff_stage_field "$stage" binary)" || handoff_die "unknown stage: $stage"
  model_spec="$(handoff_stage_field "$stage" model)" || handoff_die "unknown stage: $stage"
  model="$(handoff_resolve_model "$model_spec")"
  [[ -n "$model" ]] || handoff_die "stage $stage has no model"

  [[ -n "$worktree" ]] || worktree="$PWD"
  [[ -d "$worktree" ]] || handoff_die "worktree not found: $worktree"
  worktree="$(handoff_abspath "$worktree")"
  [[ -n "$brief" ]] || brief="$(handoff_brief_path "$worktree")"
  [[ -f "$brief" ]] || handoff_die "job brief not found: $brief (write it with handoff-brief before this stage)"
  handoff_brief_ok "$brief" || handoff_die "job brief must have ask, repo, links, and source linear|ask|note: $brief"
  brief="$(handoff_abspath "$(dirname "$brief")")/$(basename "$brief")"

  result="$(handoff_result_path "$worktree")"
  if [[ -n "$resume" ]]; then
    handoff_is_uuid "$resume" || handoff_die "resume session_id must be a uuid: $resume"
    session="$resume"
    resumed=1
    resume_note="This is a re-handoff of the same session. Continue it. Do not start a new one. Keep session_id as ${session}."
  else
    session="$(handoff_new_session_id)"
    handoff_is_uuid "$session" || handoff_die "could not mint a session uuid"
    resume_note="This is the first start. Use session_id ${session}."
  fi

  template="$(handoff_prompt_template "$stage")"
  prompt="$(handoff_render_template "$template" "$brief" "$result" "$session" "$resume_note")"
  if [[ "$prompt" == /poteto-mode* || "$prompt" == *"/poteto-mode"* ]]; then
    handoff_die "headless stage $stage must not use /poteto-mode"
  fi

  bin="${HANDOFF_CLAUDE_BIN:-$binary}"
  HANDOFF_START_ARGV=("$bin" --print --model "$model" --output-format json --permission-mode acceptEdits --tools "Read,Edit,Write")
  if [[ "$resumed" -eq 1 ]]; then
    HANDOFF_START_ARGV+=(--resume "$session")
  else
    HANDOFF_START_ARGV+=(--session-id "$session")
  fi
  HANDOFF_START_ARGV+=(-- "$prompt")

  cmd_json="$(printf '%s\0' "${HANDOFF_START_ARGV[@]}" | jq -Rs 'split("\u0000") | .[:-1]')"

  out="$(jq -nc \
    --arg stage "$stage" \
    --arg mode "$mode" \
    --arg binary "$binary" \
    --arg model "$model" \
    --arg worktree "$worktree" \
    --arg brief "$brief" \
    --arg result "$result" \
    --arg session_id "$session" \
    --argjson resume "$([[ "$resumed" -eq 1 ]] && printf true || printf false)" \
    --argjson dry_run "$([[ "$dry" -eq 1 ]] && printf true || printf false)" \
    --argjson command "$cmd_json" \
    '{ok:true,stage:$stage,mode:$mode,binary:$binary,model:$model,worktree:$worktree,brief:$brief,result:$result,session_id:$session_id,resume:$resume,dry_run:$dry_run,command:$command}')"

  if [[ "$dry" -eq 1 ]]; then
    printf '%s\n' "$out"
    return 0
  fi

  mkdir -p "$worktree/.bercail"
  log="$worktree/.bercail/start.log"
  export BERCAIL_BRIEF_PATH="$brief"
  export BERCAIL_RESULT_PATH="$result"
  export BERCAIL_SESSION_ID="$session"
  export BERCAIL_STAGE="$stage"
  set +e
  (cd "$worktree" && "${HANDOFF_START_ARGV[@]}" >"$log" 2>&1)
  rc=$?
  set -e
  if [[ ! -f "$result" ]] || ! handoff_result_ok "$result"; then
    [[ "$rc" -eq 0 ]] && rc=1
    if [[ -f "$result" ]] && jq -e 'type == "object"' "$result" >/dev/null 2>&1; then
      local filled
      filled="$(jq --arg session_id "$session" '
        .session_id = (if (.session_id | type == "string" and length > 0) then .session_id else $session_id end)
        | .status = (if (.status == "ready" or .status == "blocked" or .status == "failed") then .status else "failed" end)
        | .summary = (if (.summary | type == "string" and length > 0) then .summary else "start stage finished without a usable summary" end)
      ' "$result")"
      printf '%s\n' "$filled" >"$result"
    else
      handoff_write_result "$result" failed "start stage exited ${rc} without a result file" "$session"
    fi
  fi
  if ! handoff_result_ok "$result"; then
    handoff_die "result file is not status/summary/session_id: $result"
  fi
  if [[ "$rc" -ne 0 ]]; then
    printf 'handoff: %s exited %s; result is %s\n' "$bin" "$rc" "$result" >&2
    return "$rc"
  fi
  printf '%s\n' "$out"
}
