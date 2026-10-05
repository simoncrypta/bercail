# Handoff stage table and headless runner. Sourced by handoff-spawn.
# The job lives in a beads issue (bd). An agent's prompt is only the issue id.
# shellcheck shell=bash

handoff_stage_table() {
  cat <<'TABLE'
# name	binary	mode	model
start	claude	headless	opus-5.5
codex	codex	headless	-
cursor	cursor-agent	headless	-
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

handoff_stage_model_for_binary() {
  local want="$1" line n binary mode model
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" && "$line" != \#* ]] || continue
    IFS=$'\t' read -r n binary mode model <<<"$line"
    [[ "$binary" == "$want" ]] || continue
    printf '%s' "$model"
    return 0
  done < <(handoff_stage_table)
  printf '%s' "-"
}

handoff_stage_names_json() {
  handoff_stage_table \
    | awk -F '\t' 'NF >= 1 && $1 !~ /^#/ { print $1 }' \
    | jq -R . | jq -sc .
}

handoff_abspath() {
  local path="$1"
  if [[ -d "$path" ]]; then
    (cd "$path" && pwd -P)
  else
    printf '%s' "$path"
  fi
}

handoff_result_path() {
  printf '%s/.bercail/handoff-result.json' "$1"
}

handoff_bd_bin() {
  printf '%s' "${HANDOFF_BD_BIN:-bd}"
}

# Beads ids are a prefix, a dash, and a hash, with optional .N children
# (bercail-0s1, bercail-0s1.2). Reject anything that could be a flag or a path.
handoff_issue_id_ok() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_]*-[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

handoff_issue_exists() {
  local dir="$1" id="$2"
  (cd "$dir" && "$(handoff_bd_bin)" show "$id" --json >/dev/null 2>&1)
}

# The .beads dir bd resolves from DIR. A linked worktree resolves the main
# checkout's .beads, which is outside the worktree a sandboxed harness may write.
handoff_beads_dir() {
  local dir="$1" out
  out="$(cd "$dir" && "$(handoff_bd_bin)" context --json 2>/dev/null)" || return 1
  out="$(jq -r '.beads_dir // empty' <<<"$out" 2>/dev/null)" || return 1
  [[ -n "$out" ]] || return 1
  printf '%s' "$out"
}

handoff_issue_comment() {
  local dir="$1" id="$2" text="$3"
  printf '%s' "$text" | (cd "$dir" && "$(handoff_bd_bin)" comment "$id" --stdin >/dev/null) \
    || printf 'handoff: could not add the handoff comment to %s\n' "$id" >&2
}

# The whole agent prompt, the same for every harness: the beads issue id.
# Shep owns the workflow; bercail adds no per-binary mode.
handoff_issue_prompt() {
  printf '%s' "$1"
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

# session_id when there is no resumable session (codex or cursor-agent blocked
# before it ran, or its log had no id). Not a uuid, so --resume refuses it.
HANDOFF_NO_SESSION="none"

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

# opus-5.5 -> catalog id whose name is "Opus 5.5". Never a *-max slug.
# If the catalog has no Opus 5.5, the first other claude-opus id. If there is
# no catalog, the help-text alias "opus" (claude --help does not list full ids).
handoff_resolve_model() {
  local spec="$1" catalog id
  [[ -n "$spec" && "$spec" != "-" ]] || return 0
  if [[ "$spec" == *max ]]; then
    handoff_die "refusing *-max model slug: $spec"
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

handoff_headless_bin() {
  local binary="$1"
  case "$binary" in
    claude) printf '%s' "${HANDOFF_CLAUDE_BIN:-$binary}" ;;
    codex) printf '%s' "${HANDOFF_CODEX_BIN:-$binary}" ;;
    cursor-agent) printf '%s' "${HANDOFF_CURSOR_BIN:-$binary}" ;;
    *) handoff_die "unsupported headless binary: $binary" ;;
  esac
}

handoff_bin_present() {
  local bin="$1"
  [[ -n "$bin" ]] || return 1
  if [[ "$bin" == /* || "$bin" == ./* ]]; then
    [[ -x "$bin" ]]
    return $?
  fi
  command -v "$bin" >/dev/null 2>&1
}

handoff_block() {
  local dest="$1" summary="$2" session="$3"
  handoff_write_result "$dest" blocked "$summary" "$session"
  printf 'handoff: %s\n' "$summary" >&2
  return 1
}

handoff_block_missing_harness() {
  local dest="$1" binary="$2" session="$3"
  handoff_block "$dest" "requested harness ${binary} is not on PATH. Install it, or name another stage or --binary yourself (bercail harness lists what is present). Bercail does not switch harnesses." "$session"
}

# Codex JSONL: developers.openai.com/codex/noninteractive.md
handoff_codex_thread_id() {
  local log="$1" id
  [[ -f "$log" ]] || return 1
  id="$(jq -r 'select(.type == "thread.started") | .thread_id // empty' "$log" 2>/dev/null | awk 'NF { print; exit }')"
  [[ -n "$id" ]] || return 1
  printf '%s' "$id"
}

handoff_codex_model() {
  local spec="$1"
  [[ -n "$spec" && "$spec" != "-" ]] || return 0
  printf '%s' "$spec"
}

# cursor-agent --print --output-format json: a single result object with session_id.
handoff_cursor_session_id() {
  local log="$1" id
  [[ -f "$log" ]] || return 1
  id="$(jq -r 'select(.type == "result") | .session_id // empty' "$log" 2>/dev/null | awk 'NF { print; exit }')"
  if [[ -z "$id" || "$id" == null ]]; then
    id="$(jq -r '.session_id // empty' "$log" 2>/dev/null | awk 'NF { print; exit }')"
  fi
  [[ -n "$id" && "$id" != null ]] || return 1
  printf '%s' "$id"
}

handoff_cursor_model() {
  local spec="$1"
  [[ -n "$spec" && "$spec" != "-" ]] || return 0
  printf '%s' "$spec"
}

handoff_resolve_headless_model() {
  local binary="$1" spec="$2"
  case "$binary" in
    claude)
      handoff_resolve_model "$spec"
      ;;
    codex)
      handoff_codex_model "$spec"
      ;;
    cursor-agent)
      handoff_cursor_model "$spec"
      ;;
    *)
      handoff_die "unsupported headless binary: $binary"
      ;;
  esac
}

# Codex exec defaults to read-only; writes need --sandbox workspace-write
# (developers.openai.com/codex/noninteractive.md).
# beads_dir is set only when bd's .beads sits outside the worktree (a linked
# worktree), so the agent can run bd show/comment/close there.
handoff_build_headless_argv() {
  local binary="$1" bin="$2" model="$3" session="$4" resumed="$5" prompt="$6" beads_dir="${7:-}"
  case "$binary" in
    claude)
      [[ -n "$model" ]] || handoff_die "claude headless run needs a model"
      # claude --help: --tools picks built-ins; --allowedTools pre-approves
      # "Bash(bd *)" so --print never needs a permission prompt for bd.
      HANDOFF_START_ARGV=("$bin" --print --model "$model" --output-format json --permission-mode acceptEdits
        --tools "Read,Edit,Write,Bash" --allowedTools "Bash(bd *)")
      if [[ -n "$beads_dir" ]]; then
        HANDOFF_START_ARGV+=(--add-dir "$beads_dir")
      fi
      if [[ "$resumed" -eq 1 ]]; then
        HANDOFF_START_ARGV+=(--resume "$session")
      else
        HANDOFF_START_ARGV+=(--session-id "$session")
      fi
      HANDOFF_START_ARGV+=(-- "$prompt")
      ;;
    codex)
      # codex exec --help: --json, -s/--sandbox, -m, --add-dir. No --ask-for-approval on exec.
      # codex exec resume --help: -m, --json, SESSION_ID. No --sandbox or --add-dir
      # there, so both stay on exec before the resume subcommand.
      HANDOFF_START_ARGV=("$bin" exec --json --sandbox workspace-write)
      if [[ -n "$beads_dir" ]]; then
        HANDOFF_START_ARGV+=(--add-dir "$beads_dir")
      fi
      if [[ "$resumed" -eq 1 ]]; then
        HANDOFF_START_ARGV+=(resume)
      fi
      if [[ -n "$model" ]]; then
        HANDOFF_START_ARGV+=(-m "$model")
      fi
      if [[ "$resumed" -eq 1 ]]; then
        HANDOFF_START_ARGV+=("$session")
      fi
      HANDOFF_START_ARGV+=(-- "$prompt")
      ;;
    cursor-agent)
      # cursor-agent --help: --print, --output-format json, --model, --resume [chatId],
      # --trust, --force, --add-dir. No --session-id. Resume is --resume, not a subcommand.
      HANDOFF_START_ARGV=("$bin" --print --output-format json --trust --force)
      if [[ -n "$beads_dir" ]]; then
        HANDOFF_START_ARGV+=(--add-dir "$beads_dir")
      fi
      if [[ -n "$model" ]]; then
        HANDOFF_START_ARGV+=(--model "$model")
      fi
      if [[ "$resumed" -eq 1 ]]; then
        HANDOFF_START_ARGV+=(--resume "$session")
      fi
      HANDOFF_START_ARGV+=(-- "$prompt")
      ;;
    *)
      handoff_die "unsupported headless binary: $binary"
      ;;
  esac
}

# What the agent learns from the issue, not from a prompt: where to work and
# where to write the result. Added as a bd comment on each real handoff.
handoff_headless_comment_text() {
  local stage="$1" binary="$2" worktree="$3" result="$4" session="$5" resumed="$6"
  local session_line
  if [[ -n "$session" ]]; then
    session_line="session_id is ${session}."
  else
    session_line="session_id is filled in by bercail from this run."
  fi
  if [[ "$resumed" -eq 1 ]]; then
    session_line="Re-handoff of the same session. ${session_line}"
  fi
  printf 'bercail handoff: stage %s, headless %s, worktree %s.\nWork only in that checkout. Do not open a terminal UI or start another agent.\nWhen you stop, write %s as JSON: status ready|blocked|failed, summary, session_id. %s If this issue is too thin to act on, write status blocked and say what is missing.' \
    "$stage" "$binary" "$worktree" "$result" "$session_line"
}

handoff_run_headless() {
  local stage="$1" worktree="$2" issue="$3" resume="$4" dry="$5" binary_override="${6:-}"
  local mode binary native model_spec model session="" resumed=0 prompt bd beads_dir=""
  local result log bin cmd_json out rc=0 tid present=false bd_present=false

  command -v jq >/dev/null 2>&1 || handoff_die "jq is required"
  mode="$(handoff_stage_field "$stage" mode)" || handoff_die "unknown stage: $stage"
  [[ "$mode" == headless ]] || handoff_die "stage $stage is not headless"
  binary="$(handoff_stage_field "$stage" binary)" || handoff_die "unknown stage: $stage"
  native="$binary"
  if [[ -n "$binary_override" ]]; then
    case "$binary_override" in
      claude|codex|cursor-agent) binary="$binary_override" ;;
      *) handoff_die "headless --binary must be claude, codex, or cursor-agent: $binary_override" ;;
    esac
  fi
  if [[ -n "$binary_override" && "$binary" != "$native" ]]; then
    model_spec="$(handoff_stage_model_for_binary "$binary")"
  else
    model_spec="$(handoff_stage_field "$stage" model)" || handoff_die "unknown stage: $stage"
  fi
  model="$(handoff_resolve_headless_model "$binary" "$model_spec")"
  if [[ "$binary" == claude && -z "$model" ]]; then
    handoff_die "stage $stage has no model"
  fi

  [[ -n "$issue" ]] || handoff_die "stage $stage needs --issue <beads id> (the prompt is only the issue id)"
  handoff_issue_id_ok "$issue" || handoff_die "not a beads issue id: $issue"
  [[ -n "$worktree" ]] || worktree="$PWD"
  [[ -d "$worktree" ]] || handoff_die "worktree not found: $worktree"
  worktree="$(handoff_abspath "$worktree")"
  result="$(handoff_result_path "$worktree")"

  if [[ -n "$resume" ]]; then
    handoff_is_uuid "$resume" || handoff_die "resume session_id must be a uuid: $resume"
    session="$resume"
    resumed=1
  elif [[ "$binary" == claude ]]; then
    session="$(handoff_new_session_id)"
    handoff_is_uuid "$session" || handoff_die "could not mint a session uuid"
  fi

  bd="$(handoff_bd_bin)"
  if handoff_bin_present "$bd"; then
    bd_present=true
    beads_dir="$(handoff_beads_dir "$worktree" || true)"
    if [[ -n "$beads_dir" && "$beads_dir/" == "$worktree/"* ]]; then
      beads_dir=""
    fi
  fi

  bin="$(handoff_headless_bin "$binary")"
  if [[ "$dry" -ne 1 ]]; then
    if [[ "$bd_present" != true ]]; then
      [[ -n "$session" ]] || session="$HANDOFF_NO_SESSION"
      handoff_block "$result" "bd (beads) is not on PATH. The job is a beads issue; install beads (bercail update installs it)." "$session" || true
      cat -- "$result"; printf '\n'
      return 1
    fi
    if ! handoff_issue_exists "$worktree" "$issue"; then
      [[ -n "$session" ]] || session="$HANDOFF_NO_SESSION"
      handoff_block "$result" "beads issue ${issue} not found from ${worktree} (bd show ${issue})." "$session" || true
      cat -- "$result"; printf '\n'
      return 1
    fi
    if ! handoff_bin_present "$bin"; then
      [[ -n "$session" ]] || session="$HANDOFF_NO_SESSION"
      handoff_block_missing_harness "$result" "$binary" "$session" || true
      cat -- "$result"; printf '\n'
      return 1
    fi
  fi

  prompt="$(handoff_issue_prompt "$issue")"
  handoff_build_headless_argv "$binary" "$bin" "$model" "$session" "$resumed" "$prompt" "$beads_dir"

  cmd_json="$(printf '%s\0' "${HANDOFF_START_ARGV[@]}" | jq -Rs 'split("\u0000") | .[:-1]')"
  if handoff_bin_present "$bin"; then
    present=true
  fi

  out="$(jq -nc \
    --arg stage "$stage" \
    --arg mode "$mode" \
    --arg binary "$binary" \
    --arg model "$model" \
    --arg worktree "$worktree" \
    --arg issue "$issue" \
    --arg result "$result" \
    --arg session_id "$session" \
    --argjson resume "$([[ "$resumed" -eq 1 ]] && printf true || printf false)" \
    --argjson dry_run "$([[ "$dry" -eq 1 ]] && printf true || printf false)" \
    --argjson present "$present" \
    --argjson bd_present "$bd_present" \
    --argjson command "$cmd_json" \
    '{ok:true,stage:$stage,mode:$mode,binary:$binary,model:$model,worktree:$worktree,issue:$issue,result:$result,session_id:$session_id,resume:$resume,dry_run:$dry_run,present:$present,bd_present:$bd_present,command:$command}')"

  if [[ "$dry" -eq 1 ]]; then
    printf '%s\n' "$out"
    return 0
  fi

  handoff_issue_comment "$worktree" "$issue" \
    "$(handoff_headless_comment_text "$stage" "$binary" "$worktree" "$result" "$session" "$resumed")"

  mkdir -p "$worktree/.bercail"
  rm -f -- "$result"
  log="$worktree/.bercail/start.log"
  export BERCAIL_ISSUE="$issue"
  export BERCAIL_RESULT_PATH="$result"
  export BERCAIL_SESSION_ID="$session"
  export BERCAIL_STAGE="$stage"
  set +e
  (cd "$worktree" && "${HANDOFF_START_ARGV[@]}" >"$log" 2>&1)
  rc=$?
  set -e
  tid=""
  case "$binary" in
    codex) tid="$(handoff_codex_thread_id "$log" || true)" ;;
    cursor-agent) tid="$(handoff_cursor_session_id "$log" || true)" ;;
  esac
  if [[ -n "$tid" ]]; then
    session="$tid"
    out="$(jq --arg session_id "$session" '.session_id = $session_id' <<<"$out")"
  fi
  # bercail knows the session id; the agent only has to write status and summary.
  # Keep the agent's own uuid if the CLI log had none. Never invent one: a
  # made-up id would look resumable. Say so in the summary instead.
  if [[ -f "$result" ]] && jq -e 'type == "object"' "$result" >/dev/null 2>&1; then
    local filled
    filled="$(jq --arg session_id "$session" --arg none "$HANDOFF_NO_SESSION" '
      (.session_id | type == "string" and test("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")) as $own
      | .status = (if (.status == "ready" or .status == "blocked" or .status == "failed") then .status else "failed" end)
      | .summary = (if (.summary | type == "string" and length > 0) then .summary else "headless stage finished without a usable summary" end)
      | if ($session_id | length) > 0 then .session_id = $session_id
        elif $own then .
        else .session_id = $none | .summary += " (bercail found no session id in the CLI log, so this run cannot be resumed.)"
        end
    ' "$result")"
    printf '%s\n' "$filled" >"$result"
  fi
  if [[ ! -f "$result" ]] || ! handoff_result_ok "$result"; then
    [[ "$rc" -eq 0 ]] && rc=1
    [[ -n "$session" ]] || session="$HANDOFF_NO_SESSION"
    handoff_write_result "$result" failed "headless stage exited ${rc} without a result file" "$session"
  fi
  if [[ "$rc" -ne 0 ]]; then
    printf 'handoff: %s exited %s; result is %s\n' "$bin" "$rc" "$result" >&2
    return "$rc"
  fi
  printf '%s\n' "$out"
}
