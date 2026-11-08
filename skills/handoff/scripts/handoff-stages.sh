# Handoff stage table and headless runner. Sourced by handoff-spawn.
# The job lives in a beads issue (bd). An agent's prompt is one line pointing at it.
# shellcheck shell=bash

# bstack and autopilot run Pi unless [bstack] harness is explicitly opencode.
handoff_stage_table() {
  local bin=pi
  [[ "$(_handoff_bstack_get harness)" == opencode ]] && bin=opencode
  printf '# name\tbinary\tmode\tmodel\n'
  printf 'start\tclaude\theadless\topus-5.5\n'
  printf 'codex\tcodex\theadless\t-\n'
  printf 'cursor\tcursor-agent\theadless\t-\n'
  printf 'bstack\t%s\theadless\tlead\n' "$bin"
  printf 'autopilot\t%s\theadless\tlead\n' "$bin"
}

if ! declare -F handoff_die >/dev/null 2>&1; then
  handoff_die() {
    printf 'handoff: %s\n' "$*" >&2
    exit 1
  }
fi

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

# The .beads dir bd resolves from DIR. A linked worktree with no local database
# resolves the main checkout's .beads, outside the worktree a sandboxed harness
# may write. A copied local database resolves inside the worktree.
handoff_beads_dir() {
  local dir="$1" out
  out="$(cd "$dir" && "$(handoff_bd_bin)" context --json 2>/dev/null)" || return 1
  out="$(jq -r '.beads_dir // empty' <<<"$out" 2>/dev/null)" || return 1
  [[ -n "$out" ]] || return 1
  printf '%s' "$out"
}

# wt step copy-ignored copies the gitignored Dolt store into a new worktree,
# and bd then writes there instead of the main checkout. A redirect points bd
# back. The copy stays; existing worktree databases are not removed.
handoff_share_main_beads() {
  local worktree="$1" main target current
  main="$(handoff_git_main "$worktree" 2>/dev/null || true)"
  [[ -n "$main" && -d "$main" ]] || return 0
  main="$(handoff_abspath "$main")"
  worktree="$(handoff_abspath "$worktree")"
  [[ "$worktree" != "$main" ]] || return 0
  [[ -d "$main/.beads" ]] || return 0
  target="$(handoff_abspath "$main/.beads")"
  current="$(handoff_beads_dir "$worktree" 2>/dev/null || true)"
  if [[ -n "$current" && -d "$current" ]]; then
    current="$(handoff_abspath "$current")"
    [[ "$current" == "$target" ]] && return 0
  fi
  mkdir -p "$worktree/.beads"
  # Absolute: bd follows it, and a relative path is resolved from the worktree
  # root, which is easy to get one directory wrong.
  printf '%s\n' "$target" >"$worktree/.beads/redirect"
}

handoff_issue_comment() {
  local dir="$1" id="$2" text="$3"
  printf '%s' "$text" | (cd "$dir" && "$(handoff_bd_bin)" comment "$id" --stdin >/dev/null) \
    || printf 'handoff: could not add the handoff comment to %s\n' "$id" >&2
}

# Past this, a title is the first max-1 characters, right-trimmed, plus "…".
HANDOFF_TITLE_MAX=60

# Title of beads issue ID from DIR. Empty, and 0, on any failure (missing bd,
# unknown issue, bad JSON). Whitespace and control runs become one space.
handoff_issue_title() {
  local dir="$1" id="$2" raw="" title=""
  raw="$(cd "$dir" && "$(handoff_bd_bin)" show "$id" --json 2>/dev/null)" || return 0
  title="$(jq -r --argjson max "$HANDOFF_TITLE_MAX" '
    (if type == "array" then .[0] else . end).title // ""
    | gsub("[[:space:][:cntrl:]]+"; " ")
    | gsub("^ +| +$"; "")
    | if length > $max then (.[0:($max - 1)] | gsub(" +$"; "")) + "…" else . end
  ' <<<"$raw" 2>/dev/null)" || return 0
  printf '%s' "$title"
}

# The whole agent prompt, the same for every harness: one line pointing at the
# beads issue. TITLE, when set, is named after the id; its own "." or a
# truncation's "…" ends the clause. A bare id stays the old sentence.
# Shep owns the workflow; bercail adds no per-binary mode.
handoff_issue_prompt() {
  local id="$1" title="${2:-}" stop="."
  title="${title%.}"
  [[ "$title" != *… ]] || stop=""
  if [[ -n "$title" ]]; then
    printf 'Your job is beads issue %s: %s%s Run `bd show %s` (read its comments too) and do the work it describes.' "$id" "$title" "$stop" "$id"
  else
    printf 'Your job is beads issue %s. Run `bd show %s` (read its comments too) and do the work it describes.' "$id" "$id"
  fi
}

# reason is optional. Empty omits the field; Shep reads it, and unknown fields
# do not fail handoff_result_ok. The only value the runner writes is usage-limit.
handoff_write_result() {
  local dest="$1" status="$2" summary="$3" session="$4" reason="${5:-}"
  mkdir -p "$(dirname "$dest")"
  jq -nc \
    --arg status "$status" \
    --arg summary "$summary" \
    --arg session_id "$session" \
    --arg reason "$reason" \
    '{status:$status, summary:$summary, session_id:$session_id}
     + if $reason == "" then {} else {reason:$reason} end' >"$dest"
}

# issue, and issue_title when known, on a result file. Other fields stay.
handoff_stamp_issue() {
  local dest="$1" issue="$2" title="${3:-}" stamped
  [[ -f "$dest" ]] || return 0
  stamped="$(jq -c --arg issue "$issue" --arg issue_title "$title" '
    . + {issue:$issue} + (if $issue_title == "" then {} else {issue_title:$issue_title} end)
  ' "$dest" 2>/dev/null)" || return 0
  printf '%s\n' "$stamped" >"$dest"
}

# verification is optional: [{kind, command, exit_code, evidence}]. A statechart
# entry may carry spec and chart in place of command and evidence (bercail-86a).
HANDOFF_VERIFICATION_DEF='
  def verification_ok:
    .verification | . == null or (type == "array" and all(.[];
      type == "object"
      and (.kind == "test" or .kind == "verify-skill" or .kind == "statechart")
      and (.exit_code | type == "number")
      and (((.command | type == "string") and (.evidence | type == "string"))
        or (.kind == "statechart" and (.spec | type == "string") and (.chart | type == "string")))));
'

handoff_result_ok() {
  jq -e "$HANDOFF_VERIFICATION_DEF"'
    (.status == "ready" or .status == "blocked" or .status == "failed")
    and (.summary | type == "string" and length > 0)
    and (.session_id | type == "string" and length > 0)
    and verification_ok
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
    opencode) printf '%s' "${HANDOFF_OPENCODE_BIN:-$binary}" ;;
    pi) printf '%s' "${HANDOFF_PI_BIN:-pi}" ;;
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

# opencode run --format json: one JSON object per line, each with sessionID.
handoff_opencode_session_id() {
  local log="$1" id
  [[ -f "$log" ]] || return 1
  id="$(jq -r '.sessionID // empty' "$log" 2>/dev/null | awk 'NF { print; exit }')"
  [[ -n "$id" ]] || return 1
  printf '%s' "$id"
}

# usage-limit when LOG is a plan limit, else nothing. Prints the reason; does not
# rerun. ChatGPT is the session error type provider.chatgpt-limit, or the code
# subscription_sharing_usage_limit_exceeded in that error's body. Claude is a
# sentence Claude Code 2.1.316 composes ("You've hit your 5-hour limit", the
# weekly, Opus, Sonnet, and Fable lines, "You're out of usage credits") or the
# recorded extra-usage billing sentence. That sentence is read from the error
# event, or from stderr when the process exits before one. Other JSON is not a
# limit. A provider.rate-limit, including a bare HTTP 429, is not one: xAI's
# weekly-limit body is unverified.
# Pi json mode: a session header, then events. Other harness logs are not this.
handoff_log_is_pi() {
  local log="$1"
  [[ -f "$log" ]] || return 1
  jq -e -s -R '
    [ split("\n")[] | fromjson? | select(type == "object") ]
    | any(.[]; .type == "session" or .type == "message_end")
  ' "$log" >/dev/null 2>&1
}

# The last assistant message_end decides. A plain 429 is not a plan limit.
handoff_pi_usage_limit_reason() {
  local log="$1"
  local phrase="You've hit your (5-hour|weekly|Opus|Sonnet|Fable) limit|You've hit your usage limit|You've hit your limit|You've reached your Fable limit|You're out of usage credits|Third-party apps now draw from your extra usage, not your plan limits|Claude quota exceeded — rate limit|You're out of extra usage|You have hit your ChatGPT usage limit|You've reached your ChatGPT workspace's usage limit|subscription_sharing_usage_limit_exceeded"
  if jq -e -s -R --arg phrase "$phrase" '
    [ split("\n")[] | fromjson? | select(type == "object" and .type == "message_end" and (.message.role == "assistant")) ] as $ends
    | ($ends | last) as $last
    | $last != null
    and $last.message.stopReason == "error"
    and (($last.message.errorMessage // "") | test($phrase))
  ' "$log" >/dev/null 2>&1; then
    printf 'usage-limit'
  fi
}

# Pi exits 0 when the provider failed. The last assistant message_end says so.
handoff_pi_provider_failed() {
  local log="$1"
  [[ -f "$log" ]] || return 1
  jq -e -s -R '
    [ split("\n")[] | fromjson? | select(type == "object" and .type == "message_end" and (.message.role == "assistant")) ]
    | last | .message.stopReason == "error"
  ' "$log" >/dev/null 2>&1
}

handoff_pi_session_id() {
  local log="$1" id
  [[ -f "$log" ]] || return 1
  id="$(jq -r -s -R '
    [ split("\n")[] | fromjson? | select(type == "object" and .type == "session") ][0].id // empty
  ' "$log" 2>/dev/null)"
  [[ -n "$id" && "$id" != null ]] || return 1
  printf '%s' "$id"
}

handoff_usage_limit_reason() {
  local log="$1" events
  local phrase="You've hit your (5-hour|weekly|Opus|Sonnet|Fable) limit|You've hit your usage limit|You've hit your limit|You've reached your Fable limit|You're out of usage credits|Third-party apps now draw from your extra usage, not your plan limits"
  [[ -f "$log" ]] || return 0
  if handoff_log_is_pi "$log"; then
    handoff_pi_usage_limit_reason "$log"
    return 0
  fi
  events="$(jq -c -R 'fromjson? | select(type == "object" and .type == "error" and (.error | type == "object")) | .error' "$log" 2>/dev/null || true)"
  # A JSON error event decides. Stderr counts only when the process exits first.
  if [[ -n "$events" ]]; then
    if jq -e -s --arg phrase "$phrase" '
      def hit: test($phrase);
      any(.[];
        .type == "provider.chatgpt-limit"
        or ((.response.body // "") | if type == "string" then contains("subscription_sharing_usage_limit_exceeded") else false end)
        or ((.message // "") | hit)
        or ((.response.body // "") | if type == "string" then hit else false end)
      )
    ' <<<"$events" >/dev/null 2>&1; then
      printf 'usage-limit'
    fi
    return 0
  fi
  # grep reads to the end (no -q): with pipefail, an early exit would SIGPIPE jq
  # on a long log and hide the match.
  if jq -R -r 'select(try (fromjson | type == "object") catch false | not)' "$log" | grep -E "$phrase" >/dev/null; then
    printf 'usage-limit'
  fi
}

handoff_is_opencode_session() {
  [[ "$1" =~ ^ses_[A-Za-z0-9]+$ ]]
}

# [bstack] KEY in bercail's config.toml, unquoted (a quoted value keeps its #variant).
_handoff_bstack_get() {
  local key="$1" config="${BERCAIL_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/bercail/config.toml}"
  [[ -f "$config" ]] || return 0
  awk -v key="$key" '
    /^[[:space:]]*\[/ { sec = $0; gsub(/[[:space:]]/, "", sec); next }
    sec != "[bstack]" || $0 !~ "^[[:space:]]*" key "[[:space:]]*=" { next }
    {
      line = $0
      sub("^[[:space:]]*" key "[[:space:]]*=[[:space:]]*", "", line)
      if (line ~ /^"/) { sub(/^"/, "", line); sub(/".*$/, "", line) }
      else sub(/[[:space:]]*#.*$/, "", line)
      print line
      exit
    }' "$config"
}

# A family's model when config.toml leaves it on auto: what bercail's last deploy
# picked (~/.local/share/bercail/bstack-models, family=model).
_handoff_bstack_resolved() {
  local file="${BERCAIL_BSTACK_MODELS:-$HOME/.local/share/bercail/bstack-models}"
  [[ -f "$file" ]] || return 0
  awk -F= -v key="$1" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$file"
}

# A bstack role (lead, build, judge) or family (claude, gpt, grok) -> the opencode
# model bercail's config.toml gives it, as `bercail bstack status` shows it: a
# role on a family with no model takes the next one that has one. A family named
# directly (--binary opencode on start or codex) does not. Nothing: opencode uses
# the bstack agent's model.
handoff_bstack_model() {
  local spec="$1" family model
  local -a order=()
  case "$spec" in
    lead|judge|build)
      order=(claude gpt grok)
      [[ "$1" == build ]] && order=(grok gpt claude)
      spec="$(_handoff_bstack_get "$1")"
      [[ -n "$spec" ]] || spec="${order[0]}"
      ;;
  esac
  case "$spec" in
    claude|gpt|grok) ;;
    -|"") return 0 ;;
    *) printf '%s' "$spec"; return 0 ;;
  esac
  for family in "$spec" "${order[@]}"; do
    model="$(_handoff_bstack_get "$family")"
    [[ -n "$model" ]] || model="$(_handoff_bstack_resolved "$family")"
    if [[ -n "$model" ]]; then
      printf '%s' "$model"
      return 0
    fi
  done
}

# --binary opencode on another stage keeps that stage's provider, through opencode.
handoff_opencode_spec_for_stage() {
  case "$1" in
    start) printf 'claude' ;;
    codex) printf 'gpt' ;;
    *) printf 'lead' ;;
  esac
}

# --binary pi mirrors that: start is claude, codex is gpt, the rest is the lead.
handoff_pi_spec_for_stage() {
  case "$1" in
    start) printf 'claude' ;;
    codex) printf 'gpt' ;;
    *) printf 'lead' ;;
  esac
}

handoff_pi_profile() {
  printf '%s' "${HANDOFF_PI_PROFILE:-$HOME/.local/share/bercail/pi}"
}

handoff_pi_lead_file() {
  printf '%s/lead.json' "$(handoff_pi_profile)"
}

handoff_pi_guard_path() {
  printf '%s/extensions/guard.ts' "$(handoff_pi_profile)"
}

handoff_pi_has_guard() {
  local lead="$1" guard="$2"
  jq -e --arg guard "$guard" '
    type == "array" and (
      . as $a
      | any(range(0; if length > 1 then length - 1 else 0 end); $a[.] == "-e" and $a[. + 1] == $guard)
    )
  ' "$lead" >/dev/null 2>&1
}

handoff_pi_lead_model() {
  jq -r '
    . as $a
    | [ range(0; if length > 1 then length - 1 else 0 end) | select($a[.] == "--model") | $a[. + 1] ][0] // empty
  ' "$1"
}

# models file is family=model#effort. Pi's --model wants the effort as :effort.
handoff_pi_family_model() {
  local family="$1" file model
  file="$(handoff_pi_profile)/models"
  [[ -f "$file" ]] || return 1
  model="$(awk -F= -v key="$family" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$file")"
  [[ -n "$model" ]] || return 1
  printf '%s' "${model/\#/:}"
}

# Sets HANDOFF_PI_LEAD and HANDOFF_PI_MODEL. On failure, HANDOFF_PI_BLOCK is the summary.
handoff_pi_prepare() {
  local spec="$1" lead guard
  HANDOFF_PI_BLOCK=""
  HANDOFF_PI_MODEL=""
  HANDOFF_PI_LEAD=""
  lead="$(handoff_pi_lead_file)"
  guard="$(handoff_pi_guard_path)"
  if [[ ! -f "$lead" ]]; then
    HANDOFF_PI_BLOCK="Pi lead profile is missing (${lead}). Run bercail update."
    return 1
  fi
  if ! jq -e 'type == "array"' "$lead" >/dev/null 2>&1; then
    HANDOFF_PI_BLOCK="Pi lead profile is not a JSON argv (${lead}). Run bercail update."
    return 1
  fi
  if ! handoff_pi_has_guard "$lead" "$guard"; then
    HANDOFF_PI_BLOCK="Pi lead profile has no guard (${guard}). Run bercail update."
    return 1
  fi
  HANDOFF_PI_LEAD="$lead"
  if [[ "$spec" == lead || -z "$spec" ]]; then
    HANDOFF_PI_MODEL="$(handoff_pi_lead_model "$lead")"
    return 0
  fi
  HANDOFF_PI_MODEL="$(handoff_pi_family_model "$spec" || true)"
  if [[ -z "$HANDOFF_PI_MODEL" ]]; then
    HANDOFF_PI_BLOCK="Pi profile has no ${spec} model ($(handoff_pi_profile)/models). Run bercail update."
    return 1
  fi
}

# env prefix, then pi -p --mode json --session-id, then lead.json[1:], then the headless brief.
# No --add-dir: Pi has no sandbox flag for a beads dir outside the worktree.
handoff_build_pi_argv() {
  local bin="$1" session="$2" prompt="$3" stage="$4" lead="$5" model="$6"
  local -a args=() replaced=()
  local arg i=0 saw=0
  while IFS= read -r -d '' arg; do
    args+=("$arg")
  done < <(jq -j '.[1:][] | ., "\u0000"' "$lead")
  while [[ $i -lt ${#args[@]} ]]; do
    if [[ "${args[$i]}" == --model ]]; then
      saw=1
      if [[ -n "$model" ]]; then
        replaced+=(--model "$model")
      fi
      i=$((i + 2))
      continue
    fi
    replaced+=("${args[$i]}")
    i=$((i + 1))
  done
  if [[ "$saw" -eq 0 && -n "$model" ]]; then
    replaced=(--model "$model" "${replaced[@]+"${replaced[@]}"}")
  fi
  # No HC_TERMINAL_ID: a run started from a desk is not that desk.
  HANDOFF_START_ARGV=(env -u ANTHROPIC_API_KEY -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN -u BERCAIL_ROLE -u HC_TERMINAL_ID)
  [[ "$stage" == autopilot ]] && HANDOFF_START_ARGV+=(BERCAIL_ROLE=autopilot)
  HANDOFF_START_ARGV+=("$bin" -p --mode json --session-id "$session")
  if [[ ${#replaced[@]} -gt 0 ]]; then
    HANDOFF_START_ARGV+=("${replaced[@]}")
  fi
  HANDOFF_START_ARGV+=(--append-system-prompt "$(handoff_pi_profile)/agents/bstack-headless.md")
  [[ "$stage" == autopilot ]] && HANDOFF_START_ARGV+=(--append-system-prompt "$(handoff_pi_profile)/agents/bstack-autopilot.md")
  HANDOFF_START_ARGV+=(-- "$prompt")
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
    opencode)
      handoff_bstack_model "$spec"
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
  local agent="${8:-bstack}"
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
    opencode)
      # opencode run --help: --format json, --agent, --model provider/model#variant,
      # --session (continue that session). No --auto: a headless run rejects every
      # "ask" (commit, push, merge) and the model goes on without it. Only
      # bstack-autopilot allows commit and push. A beads dir outside the worktree
      # is allowed by opencode's default external_directory rule (no --add-dir).
      HANDOFF_START_ARGV=("$bin" run --format json --agent "$agent")
      if [[ -n "$model" ]]; then
        HANDOFF_START_ARGV+=(--model "$model")
      fi
      if [[ "$resumed" -eq 1 ]]; then
        HANDOFF_START_ARGV+=(--session "$session")
      fi
      HANDOFF_START_ARGV+=("$prompt")
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
  printf 'bercail handoff: stage %s, headless %s, worktree %s.\nWork only in that checkout. Do not open a terminal UI or start another agent.\nWhen you stop, write %s as JSON: status ready|blocked|failed, summary, session_id, and post the same summary on this issue as a bd comment. %s If this issue is too thin to act on, write status blocked and say what is missing.' \
    "$stage" "$binary" "$worktree" "$result" "$session_line"
}

handoff_run_headless() {
  local stage="$1" worktree="$2" issue="$3" resume="$4" dry="$5" binary_override="${6:-}"
  local mode binary native model_spec model session="" resumed=0 prompt bd beads_dir=""
  local result log bin cmd_json out rc=0 tid present=false bd_present=false reason="" issue_title=""

  command -v jq >/dev/null 2>&1 || handoff_die "jq is required"
  mode="$(handoff_stage_field "$stage" mode)" || handoff_die "unknown stage: $stage"
  [[ "$mode" == headless ]] || handoff_die "stage $stage is not headless"
  binary="$(handoff_stage_field "$stage" binary)" || handoff_die "unknown stage: $stage"
  native="$binary"
  if [[ "$stage" == autopilot && -n "$binary_override" && "$binary_override" != opencode && "$binary_override" != pi ]]; then
    handoff_die "stage autopilot accepts --binary pi or --binary opencode, nothing else: $binary_override"
  fi
  if [[ -n "$binary_override" ]]; then
    case "$binary_override" in
      claude|codex|cursor-agent|opencode|pi) binary="$binary_override" ;;
      *) handoff_die "headless --binary must be claude, codex, cursor-agent, opencode, or pi: $binary_override" ;;
    esac
  fi
  if [[ -n "$binary_override" && "$binary" != "$native" && "$binary" == opencode ]]; then
    model_spec="$(handoff_opencode_spec_for_stage "$stage")"
  elif [[ -n "$binary_override" && "$binary" != "$native" && "$binary" == pi ]]; then
    model_spec="$(handoff_pi_spec_for_stage "$stage")"
  elif [[ -n "$binary_override" && "$binary" != "$native" ]]; then
    model_spec="$(handoff_stage_model_for_binary "$binary")"
  else
    model_spec="$(handoff_stage_field "$stage" model)" || handoff_die "unknown stage: $stage"
  fi
  if [[ "$binary" == pi ]]; then
    model=""
  else
    model="$(handoff_resolve_headless_model "$binary" "$model_spec")"
  fi
  if [[ "$binary" == claude && -z "$model" ]]; then
    handoff_die "stage $stage has no model"
  fi

  [[ -n "$issue" ]] || handoff_die "stage $stage needs --issue <beads id> (the prompt points at that issue)"
  handoff_issue_id_ok "$issue" || handoff_die "not a beads issue id: $issue"
  [[ -n "$worktree" ]] || worktree="$PWD"
  [[ -d "$worktree" ]] || handoff_die "worktree not found: $worktree"
  worktree="$(handoff_abspath "$worktree")"
  result="$(handoff_result_path "$worktree")"

  if [[ -n "$resume" && "$binary" == opencode ]]; then
    handoff_is_opencode_session "$resume" || handoff_die "resume session_id must be an opencode session (ses_...): $resume"
    session="$resume"
    resumed=1
  elif [[ -n "$resume" && "$binary" == pi ]]; then
    if handoff_is_opencode_session "$resume"; then
      handoff_die "opencode sessions cannot be resumed on Pi: $resume"
    fi
    handoff_is_uuid "$resume" || handoff_die "resume session_id must be a uuid: $resume"
    session="$resume"
    resumed=1
  elif [[ -n "$resume" ]]; then
    handoff_is_uuid "$resume" || handoff_die "resume session_id must be a uuid: $resume"
    session="$resume"
    resumed=1
  elif [[ "$binary" == claude || "$binary" == pi ]]; then
    session="$(handoff_new_session_id)"
    handoff_is_uuid "$session" || handoff_die "could not mint a session uuid"
  fi

  if [[ "$binary" == pi ]]; then
    if ! handoff_pi_prepare "$model_spec"; then
      # A dry run writes nothing: a blocked result would replace a resumable one.
      [[ "$dry" -ne 1 ]] || handoff_die "$HANDOFF_PI_BLOCK"
      [[ -n "$session" ]] || session="$HANDOFF_NO_SESSION"
      handoff_block "$result" "$HANDOFF_PI_BLOCK" "$session" || true
      cat -- "$result"; printf '\n'
      return 1
    fi
    model="$HANDOFF_PI_MODEL"
  fi

  bd="$(handoff_bd_bin)"
  if handoff_bin_present "$bd"; then
    bd_present=true
    # Before the issue check and --add-dir: a copied store would hide the issue
    # and keep the harness inside the worktree.
    if [[ "$dry" -ne 1 ]]; then
      handoff_share_main_beads "$worktree"
    fi
    beads_dir="$(handoff_beads_dir "$worktree" || true)"
    if [[ -n "$beads_dir" && "$beads_dir/" == "$worktree/"* ]]; then
      beads_dir=""
    fi
    issue_title="$(handoff_issue_title "$worktree" "$issue")"
  fi

  bin="$(handoff_headless_bin "$binary")"
  if [[ "$dry" -ne 1 ]]; then
    if [[ "$bd_present" != true ]]; then
      [[ -n "$session" ]] || session="$HANDOFF_NO_SESSION"
      handoff_block "$result" "bd (beads) is not on PATH. The job is a beads issue; install beads (bercail update installs it)." "$session" || true
      handoff_stamp_issue "$result" "$issue" "$issue_title"
      cat -- "$result"; printf '\n'
      return 1
    fi
    if ! handoff_issue_exists "$worktree" "$issue"; then
      [[ -n "$session" ]] || session="$HANDOFF_NO_SESSION"
      handoff_block "$result" "beads issue ${issue} not found from ${worktree} (bd show ${issue})." "$session" || true
      handoff_stamp_issue "$result" "$issue" "$issue_title"
      cat -- "$result"; printf '\n'
      return 1
    fi
    if ! handoff_bin_present "$bin"; then
      [[ -n "$session" ]] || session="$HANDOFF_NO_SESSION"
      handoff_block_missing_harness "$result" "$binary" "$session" || true
      handoff_stamp_issue "$result" "$issue" "$issue_title"
      cat -- "$result"; printf '\n'
      return 1
    fi
  fi

  prompt="$(handoff_issue_prompt "$issue" "$issue_title")"
  local agent=bstack
  [[ "$stage" == autopilot ]] && agent=bstack-autopilot
  if [[ "$binary" == pi ]]; then
    handoff_build_pi_argv "$bin" "$session" "$prompt" "$stage" "$HANDOFF_PI_LEAD" "$model"
  else
    handoff_build_headless_argv "$binary" "$bin" "$model" "$session" "$resumed" "$prompt" "$beads_dir" "$agent"
  fi

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
    --arg issue_title "$issue_title" \
    '{ok:true,stage:$stage,mode:$mode,binary:$binary,model:$model,worktree:$worktree,issue:$issue,result:$result,session_id:$session_id,resume:$resume,dry_run:$dry_run,present:$present,bd_present:$bd_present,command:$command}
     + (if $issue_title == "" then {} else {issue_title:$issue_title} end)')"

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
    opencode) tid="$(handoff_opencode_session_id "$log" || true)" ;;
    pi) tid="$(handoff_pi_session_id "$log" || true)" ;;
  esac
  if [[ "$binary" == pi ]]; then
    if [[ -n "$tid" && "$tid" != "$session" ]]; then
      printf 'handoff: Pi session header is %s, not %s; using the header\n' "$tid" "$session" >&2
      session="$tid"
      out="$(jq --arg session_id "$session" '.session_id = $session_id' <<<"$out")"
    fi
    if handoff_pi_provider_failed "$log"; then
      rc=1
    fi
  elif [[ -n "$tid" ]]; then
    session="$tid"
    out="$(jq --arg session_id "$session" '.session_id = $session_id' <<<"$out")"
  fi
  # The exhausted plan cannot be trusted to name its own limit. Classify the CLI
  # log and stamp reason; do not start another command.
  if [[ "$rc" -ne 0 ]]; then
    reason="$(handoff_usage_limit_reason "$log")"
  fi
  # bercail knows the session id; the agent only has to write status and summary.
  # Keep the agent's own uuid if the CLI log had none. Never invent one: a
  # made-up id would look resumable. Say so in the summary instead.
  if [[ -f "$result" ]] && jq -e 'type == "object"' "$result" >/dev/null 2>&1; then
    local filled
    filled="$(jq --arg session_id "$session" --arg none "$HANDOFF_NO_SESSION" --arg reason "$reason" "$HANDOFF_VERIFICATION_DEF"'
      (.session_id | type == "string" and test("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")) as $own
      | .status = (if (.status == "ready" or .status == "blocked" or .status == "failed") then .status else "failed" end)
      | .summary = (if (.summary | type == "string" and length > 0) then .summary else "headless stage finished without a usable summary" end)
      | if ($session_id | length) > 0 then .session_id = $session_id
        elif $own then .
        else .session_id = $none | .summary += " (bercail found no session id in the CLI log, so this run cannot be resumed.)"
        end
      | if $reason != "" then .reason = $reason else del(.reason) end
      | if verification_ok then . else del(.verification) | .summary += " (bercail dropped a malformed verification list.)" end
    ' "$result")"
    printf '%s\n' "$filled" >"$result"
  fi
  if [[ ! -f "$result" ]] || ! handoff_result_ok "$result"; then
    [[ "$rc" -eq 0 ]] && rc=1
    [[ -n "$session" ]] || session="$HANDOFF_NO_SESSION"
    handoff_write_result "$result" failed "headless stage exited ${rc} without a result file" "$session" "$reason"
  fi
  handoff_stamp_issue "$result" "$issue" "$issue_title"
  if [[ "$rc" -ne 0 ]]; then
    printf 'handoff: %s exited %s; result is %s\n' "$bin" "$rc" "$result" >&2
    return "$rc"
  fi
  printf '%s\n' "$out"
}
