# Headless Pi runner. Sourced by handoff-spawn.
# The job lives in a beads issue (bd), or in an Entire repo a trail (trail:N,
# through bercail job). An agent's prompt is one line pointing at it.
# Stages are bstack and autopilot. Both run Pi.
# shellcheck shell=bash

if ! declare -F handoff_die >/dev/null 2>&1; then
  handoff_die() {
    printf 'handoff: %s\n' "$*" >&2
    exit 1
  }
fi

_HANDOFF_STAGES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=skills/handoff/scripts/git-backend.sh
source "$_HANDOFF_STAGES_DIR/git-backend.sh"
# shellcheck source=skills/handoff/scripts/pi-log.sh
source "$_HANDOFF_STAGES_DIR/pi-log.sh"

handoff_result_path() {
  printf '%s/.bercail/handoff-result.json' "$1"
}

handoff_bd_bin() {
  printf '%s' "${HANDOFF_BD_BIN:-bd}"
}

# Beads ids are a prefix, a dash, and a hash, with optional .N children
# (bercail-0s1, bercail-0s1.2), or trail:N. Reject anything that could be a flag or a path.
handoff_issue_id_ok() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_]*-[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || handoff_is_trail "$1"
}

# An Entire trail job: trail:<project trail number>.
handoff_is_trail() {
  [[ "$1" =~ ^trail:[1-9][0-9]{0,8}$ ]]
}

# A trail job is read and commented through bercail job: its comments stay on
# this machine, since Entire refuses trail comments from an agent session.
handoff_job() {
  "${BERCAIL_BIN:-bercail}" job "$@"
}

# The command that shows the job, for prompts and errors.
handoff_show_cmd() {
  if handoff_is_trail "$1"; then printf 'bercail job show %s' "$1"; else printf 'bd show %s' "$1"; fi
}

# Where the desk posts its report, for the handoff comment.
handoff_report_cmd() {
  if handoff_is_trail "$1"; then printf 'this trail with bercail job comment %s (the report on stdin)' "$1"
  else printf 'this issue with bd comment %s' "$1"; fi
}

handoff_issue_exists() {
  local dir="$1" id="$2"
  if handoff_is_trail "$id"; then
    handoff_job show "$id" --repo "$dir" --json 2>/dev/null </dev/null | jq -e '.status == "open"' >/dev/null
    return
  fi
  (cd "$dir" && "$(handoff_bd_bin)" show "$id" --json >/dev/null 2>&1)
}

# The .beads dir bd resolves from DIR. A linked worktree with no local database
# resolves the main checkout's .beads. A copied local database resolves inside
# the worktree.
handoff_beads_dir() {
  local dir="$1" out
  out="$(cd "$dir" && "$(handoff_bd_bin)" context --json 2>/dev/null)" || return 1
  out="$(jq -r '.beads_dir // empty' <<<"$out" 2>/dev/null)" || return 1
  [[ -n "$out" ]] || return 1
  printf '%s' "$out"
}

# wt step copy-ignored without bercail's exclude (a person's own worktrunk
# config) copies the gitignored Dolt store into a new worktree, and bd then
# writes there instead of the main checkout. A redirect points bd back. The
# copy stays; existing worktree databases are not removed.
handoff_share_main_beads() {
  local worktree="$1" main target current
  main="$(git_backend_main "$worktree" 2>/dev/null || true)"
  [[ -n "$main" ]] || return 0
  worktree="$(_git_backend_realpath "$worktree")"
  [[ "$worktree" != "$main" ]] || return 0
  [[ -d "$main/.beads" ]] || return 0
  target="$(_git_backend_realpath "$main/.beads")"
  current="$(handoff_beads_dir "$worktree" 2>/dev/null || true)"
  if [[ -n "$current" && -d "$current" ]]; then
    current="$(_git_backend_realpath "$current")"
    [[ "$current" == "$target" ]] && return 0
  fi
  mkdir -p "$worktree/.beads"
  # Absolute: bd follows it, and a relative path is resolved from the worktree
  # root, which is easy to get one directory wrong.
  printf '%s\n' "$target" >"$worktree/.beads/redirect"
}

handoff_issue_comment() {
  local dir="$1" id="$2" text="$3"
  if handoff_is_trail "$id"; then
    printf '%s' "$text" | handoff_job comment "$id" --repo "$dir" >/dev/null \
      || printf 'handoff: could not add the handoff comment to %s\n' "$id" >&2
    return 0
  fi
  printf '%s' "$text" | (cd "$dir" && "$(handoff_bd_bin)" comment "$id" --stdin >/dev/null) \
    || printf 'handoff: could not add the handoff comment to %s\n' "$id" >&2
}

# Past this, a title is the first max-1 characters, right-trimmed, plus "…".
HANDOFF_TITLE_MAX=60

# Title of beads issue ID from DIR. Empty, and 0, on any failure (missing bd,
# unknown issue, bad JSON). Whitespace and control runs become one space.
handoff_issue_title() {
  local dir="$1" id="$2" raw="" title=""
  if handoff_is_trail "$id"; then
    raw="$(handoff_job show "$id" --repo "$dir" --json 2>/dev/null </dev/null)" || return 0
  else
    raw="$(cd "$dir" && "$(handoff_bd_bin)" show "$id" --json 2>/dev/null)" || return 0
  fi
  title="$(jq -r --argjson max "$HANDOFF_TITLE_MAX" '
    (if type == "array" then .[0] else . end).title // ""
    | gsub("[[:space:][:cntrl:]]+"; " ")
    | gsub("^ +| +$"; "")
    | if length > $max then (.[0:($max - 1)] | gsub(" +$"; "")) + "…" else . end
  ' <<<"$raw" 2>/dev/null)" || return 0
  printf '%s' "$title"
}

# How the agent commits, pushes, and releases, for the handoff comment: only
# when asked, then as the repo's git policy says. Its prompt carries the whole
# policy; the comment names it in one line. No bercail: no summary.
handoff_policy_line() {
  local bercail="${BERCAIL_BIN:-bercail}" brief=""
  if command -v "$bercail" >/dev/null 2>&1; then
    brief="$("$bercail" policy show --json "$1" 2>/dev/null </dev/null | jq -r '.brief // empty' 2>/dev/null || true)"
  fi
  printf "Commit, push, or release only when asked, and then the way this repo's git policy says (bercail policy show%s)." "${brief:+: $brief}"
}

# The whole agent prompt: one line pointing at the beads issue. TITLE, when
# set, is named after the id; its own "." or a truncation's "…" ends the
# clause.
# Shep owns the workflow; bercail adds no per-stage mode.
handoff_issue_prompt() {
  local id="$1" title="${2:-}" stop="."
  title="${title%.}"
  [[ "$title" != *… ]] || stop=""
  if handoff_is_trail "$id"; then
    printf 'Your job is %s%s Run `bercail job show %s` (its body and comments) and do the work it describes.' \
      "$id" "${title:+: $title}$stop" "$id"
  elif [[ -n "$title" ]]; then
    printf 'Your job is beads issue %s: %s%s Run `bd show %s` (read its comments too) and do the work it describes.' "$id" "$title" "$stop" "$id"
  else
    printf 'Your job is beads issue %s. Run `bd show %s` (read its comments too) and do the work it describes.' "$id" "$id"
  fi
}

# Keep the legacy plan-limit reason; typed provider failures are also projected below.
handoff_write_result() {
  local dest="$1" status="$2" summary="$3" session="$4" reason="${5:-}" prior="${6:-}"
  mkdir -p "$(dirname "$dest")"
  jq -nc \
    --arg status "$status" \
    --arg summary "$summary" \
    --arg session_id "$session" \
    --arg reason "$reason" \
    --arg prior "$prior" \
    '{status:$status, summary:$summary, session_id:$session_id}
     + (if $reason == "" then {} else {reason:$reason} end)
     + (if $prior == "" then {} else {prior_result:$prior} end)' >"$dest"
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

# verification is optional: [{kind, command, exit_code, evidence}].
HANDOFF_VERIFICATION_DEF='
  def verification_ok:
    .verification | . == null or (type == "array" and all(.[];
      type == "object"
      and (.kind == "test" or .kind == "verify-skill")
      and (.exit_code | type == "number")
      and (.command | type == "string")
      and (.evidence | type == "string")));
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

# session_id when there is no resumable session. Not a uuid, so --resume refuses it.
HANDOFF_NO_SESSION="none"

handoff_bin_present() {
  local bin="$1"
  [[ -n "$bin" ]] || return 1
  if [[ "$bin" == /* || "$bin" == ./* ]]; then
    [[ -x "$bin" ]]
    return $?
  fi
  command -v "$bin" >/dev/null 2>&1
}

# Keep one invocation's result beside its log so relative evidence pointers still resolve.
handoff_preserve_result() {
  local dest="$1" dir log history prior=''
  dir="$(dirname "$dest")"
  log="$dir/start.log"
  [[ -f "$dest" || -f "$log" ]] || return 0
  mkdir -p "$dir/handoff-history" || return 1
  history="$(mktemp -d "$dir/handoff-history/run.XXXXXX")" || return 1
  if [[ -f "$dest" ]]; then
    prior="$history/handoff-result.json"
    mv -- "$dest" "$prior" || return 1
  fi
  if [[ -f "$log" ]]; then
    mv -- "$log" "$history/start.log" || return 1
  fi
  printf '%s' "$prior"
}

handoff_block() {
  local dest="$1" summary="$2" session="$3" prior
  prior="$(handoff_preserve_result "$dest")" || handoff_die "could not preserve prior handoff evidence; no replacement result was written"
  handoff_write_result "$dest" blocked "$summary" "$session" '' "$prior"
  printf 'handoff: %s\n' "$summary" >&2
  return 1
}

# The last assistant message_end decides. A plain 429 is not a plan limit.
handoff_pi_usage_limit_reason() {
  local log="$1"
  local failure
  failure="$(handoff_pi_provider_error "$log")"
  [[ "$(jq -r '.reason // empty' <<<"$failure")" == usage_limit ]] || return 0
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

# Use the same classifier as the extension; this helper ships with the required Pi profile.
handoff_pi_provider_error() {
  node "$(handoff_pi_profile)/extensions/provider-error.ts" "$1"
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

# Pi's thinking levels, the suffix of a --model value (provider/id:high).
HANDOFF_PI_THINKING="off minimal low medium high xhigh max"

handoff_pi_has_thinking() {
  [[ "$1" == *:* && " $HANDOFF_PI_THINKING " == *" ${1##*:} "* ]]
}

# MODEL as given when it names a thinking level, else with the lead's.
handoff_pi_with_thinking() {
  local model="$1" lead_model
  if ! handoff_pi_has_thinking "$model"; then
    lead_model="$(handoff_pi_lead_model "$2")"
    if handoff_pi_has_thinking "$lead_model"; then
      model+=":${lead_model##*:}"
    fi
  fi
  printf '%s' "$model"
}

# Dies unless Pi lists MODEL's provider/id with the lead's extensions loaded:
# a provider can come from one (claude-bridge).
handoff_pi_model_check() {
  local bin="$1" lead="$2" model="$3" id ext list
  local -a argv=("$bin" --offline --list-models)
  id="$model"
  if handoff_pi_has_thinking "$id"; then
    id="${id%:*}"
  fi
  while IFS= read -r -d '' ext; do
    argv+=(-e "$ext")
  done < <(jq -j '. as $a | range(1; length - 1) | select($a[.] == "-e") | $a[. + 1], "\u0000"' "$lead")
  list="$(env -u ANTHROPIC_API_KEY -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN "${argv[@]}" </dev/null 2>/dev/null)" \
    || handoff_die "pi --list-models failed, so --model $model cannot be checked. Run ${argv[*]} to see why."
  awk -v want="$id" 'NR > 1 && $1 "/" $2 == want { found = 1 } END { exit !found }' <<<"$list" \
    || handoff_die "Pi has no model $id. pi --list-models lists the ones you can use."
}

# Sets HANDOFF_PI_LEAD and HANDOFF_PI_MODEL from the lead profile.
# On failure, HANDOFF_PI_BLOCK is the summary.
handoff_pi_prepare() {
  local lead guard
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
  if [[ ! -r "$(handoff_pi_profile)/extensions/provider-error.ts" ]]; then
    HANDOFF_PI_BLOCK="Pi provider-error helper is missing. Run bercail update."
    return 1
  fi
  if ! command -v node >/dev/null 2>&1 || ! node "$(handoff_pi_profile)/extensions/provider-error.ts" --check >/dev/null 2>&1; then
    HANDOFF_PI_BLOCK="Node.js with built-in TypeScript support is required for provider-error classification. Install Node.js 22.19 or newer, then retry."
    return 1
  fi
  HANDOFF_PI_LEAD="$lead"
  HANDOFF_PI_MODEL="$(handoff_pi_lead_model "$lead")"
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
  # No HC_TERMINAL_ID: a run started from a desk is not that desk. No
  # ENTIRE_PI_NESTED either: Entire would take the run for the desk's subagent
  # and record nothing of it.
  HANDOFF_START_ARGV=(env -u ANTHROPIC_API_KEY -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN -u BERCAIL_ROLE -u HC_TERMINAL_ID
    -u ENTIRE_PI_NESTED)
  [[ "$stage" == autopilot ]] && HANDOFF_START_ARGV+=(BERCAIL_ROLE=autopilot)
  HANDOFF_START_ARGV+=("$bin" -p --mode json --session-id "$session")
  if [[ ${#replaced[@]} -gt 0 ]]; then
    HANDOFF_START_ARGV+=("${replaced[@]}")
  fi
  HANDOFF_START_ARGV+=(--append-system-prompt "$(handoff_pi_profile)/agents/bstack-headless.md")
  [[ "$stage" == autopilot ]] && HANDOFF_START_ARGV+=(--append-system-prompt "$(handoff_pi_profile)/agents/bstack-autopilot.md")
  HANDOFF_START_ARGV+=(-- "$prompt")
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
  printf 'bercail handoff: stage %s, headless %s, worktree %s.\nWork only in that checkout. Do not open a terminal UI or start another agent. %s\nWhen you stop, write %s as JSON: status ready|blocked|failed, summary, session_id, and post the same summary on this issue as a bd comment. %s If this issue is too thin to act on, write status blocked and say what is missing.' \
    "$stage" "$binary" "$worktree" "$(handoff_policy_line "$worktree")" "$result" "$session_line"
}

# want: --model, or empty for the lead's.
handoff_run_headless() {
  local stage="$1" worktree="$2" issue="$3" resume="$4" dry="$5" want="${6:-}"
  local model session="" resumed=0 prompt bd
  local result log bin="${HANDOFF_PI_BIN:-pi}" cmd_json out rc=0 tid present=false bd_present=false reason="" issue_title="" turn_failed=false
  local provider_error='null' incomplete=false prior_result='' role="${BERCAIL_ROLE:-lead}" phase="${BERCAIL_PHASE:-$stage}" candidate="${BERCAIL_CANDIDATE:-unknown}"

  command -v jq >/dev/null 2>&1 || handoff_die "jq is required"

  [[ -n "$issue" ]] || handoff_die "stage $stage needs --issue <beads id> (the prompt points at that issue)"
  handoff_issue_id_ok "$issue" || handoff_die "not a beads issue id: $issue"
  ! handoff_is_trail "$issue" || handoff_die "headless stages take a beads issue; start a desk for $issue with --branch"
  [[ -n "$worktree" ]] || worktree="$PWD"
  [[ -d "$worktree" ]] || handoff_die "worktree not found: $worktree"
  worktree="$(_git_backend_realpath "$worktree")"
  result="$(handoff_result_path "$worktree")"

  if [[ -n "$resume" ]]; then
    handoff_is_uuid "$resume" || handoff_die "resume session_id must be a uuid: $resume"
    session="$resume"
    resumed=1
  else
    session="$(</proc/sys/kernel/random/uuid)"
    handoff_is_uuid "$session" || handoff_die "could not mint a session uuid"
  fi

  if ! handoff_pi_prepare; then
    # A dry run writes nothing: a blocked result would replace a resumable one.
    [[ "$dry" -ne 1 ]] || handoff_die "$HANDOFF_PI_BLOCK"
    handoff_block "$result" "$HANDOFF_PI_BLOCK" "$session" || true
    cat -- "$result"; printf '\n'
    return 1
  fi
  model="$HANDOFF_PI_MODEL"
  [[ -z "$want" ]] || model="$(handoff_pi_with_thinking "$want" "$HANDOFF_PI_LEAD")"

  bd="$(handoff_bd_bin)"
  if handoff_bin_present "$bd"; then
    bd_present=true
    # Before the issue check: a copied store would hide the issue.
    if [[ "$dry" -ne 1 ]]; then
      handoff_share_main_beads "$worktree"
    fi
    issue_title="$(handoff_issue_title "$worktree" "$issue")"
  fi

  if [[ "$dry" -ne 1 ]]; then
    if [[ "$bd_present" != true ]]; then
      handoff_block "$result" "bd (beads) is not on PATH. The job is a beads issue; install beads (bercail update installs it)." "$session" || true
      handoff_stamp_issue "$result" "$issue" "$issue_title"
      cat -- "$result"; printf '\n'
      return 1
    fi
    if ! handoff_issue_exists "$worktree" "$issue"; then
      handoff_block "$result" "beads issue ${issue} not found from ${worktree} (bd show ${issue})." "$session" || true
      handoff_stamp_issue "$result" "$issue" "$issue_title"
      cat -- "$result"; printf '\n'
      return 1
    fi
    if ! handoff_bin_present "$bin"; then
      handoff_block "$result" "pi is not on PATH. Install it (bercail update)." "$session" || true
      handoff_stamp_issue "$result" "$issue" "$issue_title"
      cat -- "$result"; printf '\n'
      return 1
    fi
    [[ -z "$want" ]] || handoff_pi_model_check "$bin" "$HANDOFF_PI_LEAD" "$model"
  fi

  prompt="$(handoff_issue_prompt "$issue" "$issue_title")"
  handoff_build_pi_argv "$bin" "$session" "$prompt" "$stage" "$HANDOFF_PI_LEAD" "$model"

  cmd_json="$(printf '%s\0' "${HANDOFF_START_ARGV[@]}" | jq -Rs 'split("\u0000") | .[:-1]')"
  if handoff_bin_present "$bin"; then
    present=true
  fi

  out="$(jq -nc \
    --arg stage "$stage" \
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
    '{ok:true,stage:$stage,mode:"headless",binary:"pi",model:$model,worktree:$worktree,issue:$issue,result:$result,session_id:$session_id,resume:$resume,dry_run:$dry_run,present:$present,bd_present:$bd_present,command:$command}
     + (if $issue_title == "" then {} else {issue_title:$issue_title} end)')"

  if [[ "$dry" -eq 1 ]]; then
    printf '%s\n' "$out"
    return 0
  fi

  handoff_issue_comment "$worktree" "$issue" \
    "$(handoff_headless_comment_text "$stage" pi "$worktree" "$result" "$session" "$resumed")"

  mkdir -p "$worktree/.bercail"
  prior_result="$(handoff_preserve_result "$result")" || handoff_die "could not preserve prior handoff evidence; no provider command was started"
  log="$worktree/.bercail/start.log"
  export BERCAIL_ISSUE="$issue"
  export BERCAIL_ISSUE_TITLE="$issue_title"
  export BERCAIL_RESULT_PATH="$result"
  export BERCAIL_SESSION_ID="$session"
  export BERCAIL_STAGE="$stage"
  set +e
  (cd "$worktree" && "${HANDOFF_START_ARGV[@]}" >"$log" 2>&1)
  rc=$?
  set -e
  tid="$(handoff_pi_session_id "$log" || true)"
  if [[ -n "$tid" && "$tid" != "$session" ]]; then
    printf 'handoff: Pi session header is %s, not %s; using the header\n' "$tid" "$session" >&2
    session="$tid"
    out="$(jq --arg session_id "$session" '.session_id = $session_id' <<<"$out")"
  fi
  if pi_turn_failed "$log"; then
    rc=1
    turn_failed=true
  fi
  provider_error="$(handoff_pi_provider_error "$log")"
  # Structured refusal/safety may normalize to a clean stop. The extension projects it before exit.
  if [[ -f "$result" ]] && [[ "$(jq -r --arg session "$session" '
    .provider_error | select(.session_id == $session and (.reason | IN("provider_safety_block", "auth_expired_or_denied", "usage_limit", "transient_transport", "model_refusal", "unknown_provider_error"))) | .reason
  ' "$result" 2>/dev/null)" != "" ]]; then
    if [[ "$(jq -r '.reason // empty' <<<"$provider_error")" != provider_safety_block || "$(jq -r '.provider_error.reason' "$result")" == provider_safety_block ]]; then
      provider_error="$(jq -c '.provider_error' "$result")"
    fi
  fi
  if [[ "$provider_error" != null ]]; then
    provider_error="$(jq -c --arg role "$role" --arg phase "$phase" --arg candidate "$candidate" \
      --arg session "$session" --arg issue "$issue" '{role:$role,phase:$phase,candidate:$candidate,session_id:$session,issue:$issue} + .' <<<"$provider_error")"
    if [[ "$(jq -r .reason <<<"$provider_error")" == provider_safety_block || "$(jq -r .reason <<<"$provider_error")" == model_refusal ]]; then
      incomplete=true
      rc=1
    fi
  fi
  # The exhausted plan cannot be trusted to name its own limit. Classify the CLI
  # log and stamp reason; do not start another command.
  if [[ "$rc" -ne 0 ]]; then
    reason="$(handoff_pi_usage_limit_reason "$log")"
  fi
  # bercail knows the session id; the agent only has to write status and summary.
  # Keep the agent's own uuid if the CLI log had none. Never invent one: a
  # made-up id would look resumable. Say so in the summary instead.
  if [[ -f "$result" ]] && jq -e 'type == "object"' "$result" >/dev/null 2>&1; then
    local filled
    filled="$(jq --arg session_id "$session" --arg none "$HANDOFF_NO_SESSION" --arg reason "$reason" --argjson turn_failed "$turn_failed" "$HANDOFF_VERIFICATION_DEF"'
      (.session_id | type == "string" and test("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")) as $own
      | .status = (if $turn_failed then "failed" elif (.status == "ready" or .status == "blocked" or .status == "failed") then .status else "failed" end)
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
  if [[ "$provider_error" != null ]]; then
    local projected
    projected="$(jq --argjson failure "$provider_error" --argjson incomplete "$incomplete" --arg prior "$prior_result" '
      .provider_error = $failure
      | if $incomplete then
          .status = "blocked" | .completion = "incomplete" | .reason = $failure.reason
          | .summary = ("Provider stop: " + $failure.reason + "; " + $failure.role + "; phase " + $failure.phase + "; candidate " + $failure.candidate + ". Work is incomplete; prior candidate evidence is not approval for this phase. Human review is required.")
        else . end
      | if $prior != "" then .prior_result = $prior else . end
    ' "$result")"
    printf '%s\n' "$projected" >"$result"
  fi
  handoff_stamp_issue "$result" "$issue" "$issue_title"
  if [[ "$rc" -ne 0 ]]; then
    printf 'handoff: %s exited %s; result is %s\n' "$bin" "$rc" "$result" >&2
    return "$rc"
  fi
  printf '%s\n' "$out"
}
