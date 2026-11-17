#!/usr/bin/env bash
# shellcheck shell=bash
# Shep, bercail's orchestrator, in the Herdr app's Shep view: Pi in its own
# folder and session, on bercail's Pi models, with Shep's rules (shep/SHEP.md).
#
#   bercail shep run                       what the Shep view's terminal runs
#   bercail shep status
#   bercail shep bg --issue ID [--cwd DIR] a background Shep: waits and follow-through
#   bercail shep diagram [FILE]            a diagram Shep did not write, without its links
#   bercail shep discuss Qn@rev            what the Discuss modal's terminal runs
#   bercail shep repos | brief | board | queue | remember | forget | list | mistake   (lib/shep-context.sh)

# shellcheck source=lib/shep-context.sh
source "$(dirname "${BASH_SOURCE[0]}")/shep-context.sh"

SHEP_SKILLS=(handoff review desk-restore how why unslop describe)
SHEP_USAGE="usage: bercail shep run | status | bg --issue ID [--cwd DIR] | discuss Qn@rev | repos [--json] | brief ISSUE [--repo DIR] [--budget CHARS] | board | queue [--repo DIR] [--json] | remember \"RULE\" [--scope SCOPE] | forget N | list | mistake KEY \"WHAT\" [--repo DIR] [--issue ID] | mistake list | diagram [FILE] | questions [--json] | question create|revise|reply|answer|withdraw|check|thread|panel|discuss|closed"

shep_state_dir() {
  printf '%s/bercail/shep' "${XDG_STATE_HOME:-$HOME/.local/state}"
}

shep_share_dir() {
  printf '%s/shep' "${BERCAIL_SHARE_DIR:-$HOME/.local/share/bercail}"
}

_shep_err() {
  printf 'bercail shep: %s\n' "$*" >&2
}

# Where the notify follower drops desk events, once Shep has started (its first
# run makes the inbox), so events do not pile up for a Shep nobody runs.
shep_inbox_dir() {
  local inbox
  inbox="$(shep_state_dir)/inbox"
  [[ -d "$inbox" ]] && printf '%s' "$inbox"
  return 0
}

# Pi's argv for Shep, into SHEP_PI_ARGV: the lead's model and extensions from
# bstack (lead.json), Shep's rules and start context, its inbox
# and compaction extensions, and its own session folder. No context files: the
# person's global Pi persona and any AGENTS.md stay out of Shep. --approve
# trusts the workspace, a folder only bercail writes, so Pi loads its
# .pi/settings.json (Shep's compaction) without asking.
shep_pi_argv() {
  local lead="${BSTACK_PI_DIR:-${BERCAIL_SHARE_DIR:-$HOME/.local/share/bercail}/pi}/lead.json"
  local share state id model ext rollover=0
  share="$(shep_share_dir)"
  state="$(shep_state_dir)"
  [[ "$(toml_value "$BERCAIL_USER_CONFIG" shep rollover)" != true ]] || rollover=1
  SHEP_PI_ARGV=(env -u ANTHROPIC_API_KEY -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN
    BERCAIL_ROLE=shep "BERCAIL_SHEP_INBOX=$state/inbox" "BERCAIL_SHEP_STATE=$state"
    "BERCAIL_SHEP_BIN=${BERCAIL_SELF:-bercail}" "BERCAIL_SHEP_ROLLOVER=$rollover" pi)
  if [[ -r "$lead" ]]; then
    model="$(jq -r 'index("--model") as $i | if $i then .[$i + 1] else empty end' "$lead" 2>/dev/null || true)"
    [[ -z "$model" ]] || SHEP_PI_ARGV+=(--model "$model")
    while IFS= read -r ext; do
      [[ -n "$ext" ]] && SHEP_PI_ARGV+=(-e "$ext")
    done < <(jq -r '. as $a | range(0; length) | select($a[.] == "-e") | $a[. + 1]' "$lead" 2>/dev/null || true)
  fi
  SHEP_PI_ARGV+=(-e "$share/pi/inbox.ts" -e "$share/pi/compaction.ts" -e "$share/pi/question-commands.ts" --append-system-prompt "$share/SHEP.md"
    --append-system-prompt "$state/context.md" --no-context-files --approve
    --session-dir "$state/pi-sessions" --continue --name Shep)
  for id in "${SHEP_SKILLS[@]}"; do
    [[ -d "$(skill_canonical_dir "$id")" ]] && SHEP_PI_ARGV+=(--skill "$(skill_canonical_dir "$id")")
  done
  return 0
}

# Pi's argv for a Discuss branch, into SHEP_DISCUSS_ARGV: the lead's model and
# extensions (the guard among them), read-only tools and nothing discovered, so
# the branch can read but not run, edit, spawn, send, commit or remember. The
# guard blocks the rest under BERCAIL_ROLE=discuss. SESSION is the branch.
shep_discuss_argv() {
  local token="$1" session="$2"
  local lead="${BSTACK_PI_DIR:-${BERCAIL_SHARE_DIR:-$HOME/.local/share/bercail}/pi}/lead.json"
  local model ext
  SHEP_DISCUSS_ARGV=(env -u ANTHROPIC_API_KEY -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN -u BERCAIL_SHEP_INBOX
    BERCAIL_ROLE=discuss "BERCAIL_SHEP_STATE=$(shep_state_dir)" "BERCAIL_SHEP_BIN=${BERCAIL_SELF:-bercail}"
    "BERCAIL_DISCUSS_TOKEN=$token" pi)
  if [[ -r "$lead" ]]; then
    model="$(jq -r 'index("--model") as $i | if $i then .[$i + 1] else empty end' "$lead" 2>/dev/null || true)"
    [[ -z "$model" ]] || SHEP_DISCUSS_ARGV+=(--model "$model")
    while IFS= read -r ext; do
      [[ -n "$ext" ]] && SHEP_DISCUSS_ARGV+=(-e "$ext")
    done < <(jq -r '. as $a | range(0; length) | select($a[.] == "-e") | $a[. + 1]' "$lead" 2>/dev/null || true)
  fi
  SHEP_DISCUSS_ARGV+=(-e "$(shep_share_dir)/pi/discuss.ts" --tools "read,grep,find,ls" --no-extensions --no-mcp
    --no-skills --no-prompt-templates --no-context-files --session "$session")
}

# What the Discuss modal's terminal runs: Pi on the question's branch, made on the
# first open and continued after.
shep_discuss() {
  local token="${1:-}" out session cwd code=0
  if [[ ! "$token" =~ ^Q[1-9][0-9]*@[1-9][0-9]*$ ]]; then
    _shep_err "usage: bercail shep discuss Qn@rev (a question token from bercail shep questions)"
    return 1
  fi
  if ! out="$(shep_question discuss "$token")"; then
    _shep_ended 1
    return 0
  fi
  session="$(jq -r .session <<<"$out")"
  cwd="$(jq -r .cwd <<<"$out")"
  [[ -d "$cwd" ]] || cwd="$HOME"
  shep_discuss_argv "$token" "$session"
  (cd "$cwd" && "${SHEP_DISCUSS_ARGV[@]}") || code=$?
  _shep_ended "$code"
}

# Pi that fails leaves its message on screen until Enter.
_shep_ended() {
  local code="$1"
  [[ "$code" -eq 0 ]] && return 0
  printf '\nShep (pi) exited with code %s. Press Enter to close.\n' "$code" >&2
  read -r _ || true
  return 0
}

# What the Shep view's terminal runs.
shep_run() {
  local state code=0
  if ! command -v pi >/dev/null 2>&1; then
    _shep_err "Pi is not installed; install it with: mise use -g pi (or run: bercail bstack setup)"
    _shep_ended 1
    return 0
  fi
  state="$(shep_state_dir)"
  mkdir -p "$state/workspace" "$state/pi-sessions" "$state/inbox" "$state/delivered"
  # Neither may keep Shep from starting.
  shep_settings_write "$state/workspace/.pi/settings.json" \
    || _shep_err "could not write $state/workspace/.pi/settings.json; Pi's compaction defaults apply"
  shep_context_write "$state/context.md" || _shep_err "could not write $state/context.md; Shep starts without it"
  shep_pi_argv
  (cd "$state/workspace" && "${SHEP_PI_ARGV[@]}") || code=$?
  _shep_ended "$code"
}

shep_status() {
  local state queued=0 pending=0 persisted=0 uncertain=0 quarantined=0 file row last=""
  state="$(shep_state_dir)"
  printf 'pi sessions: %s\n' "$state/pi-sessions"
  [[ -d "$state/inbox" ]] && queued="$(find "$state/inbox" -maxdepth 1 -name '*.json' | wc -l)"
  if [[ -d "$state/delivered" ]]; then
    while IFS= read -r -d '' file; do
      if row="$(jq -er 'select(.persisted_entry_id | type == "string" and length > 0)
        | [.persisted_at, (.event_id // .notice_id)] | @tsv' "$file" 2>/dev/null)"; then
        persisted=$((persisted + 1))
        [[ "$row" > "$last" ]] && last="$row"
      else
        pending=$((pending + 1))
        if jq -e '.delivery_error | type == "string" and length > 0' "$file" >/dev/null 2>&1; then
          uncertain=$((uncertain + 1))
        fi
      fi
    done < <(find "$state/delivered" -maxdepth 1 -name '*.json' -print0)
    quarantined="$(find "$state/delivered" -maxdepth 1 -name '*.invalid' | wc -l)"
  fi
  printf 'desk notices: %s queued, %s awaiting persistence (%s uncertain), %s persisted to session\n' \
    "$((queued))" "$pending" "$uncertain" "$persisted"
  [[ -z "$last" ]] || printf 'last persisted: %s at %s\n' "${last#*$'\t'}" "${last%%$'\t'*}"
  printf 'quarantined: %s\nPersistence is not handled, action-completed, or read by the person.\n' "$((quarantined))"
  shep_bg_list
  return 0
}

# Live background Sheps, one line each; none when hc does not answer.
shep_bg_list() {
  local rows
  rows="$("${HC_BIN:-hc}" ls --json --label bercail.shep=bg 2>/dev/null </dev/null | jq -r '
    .terminals[]? | select(.state == "live")
    | "- \(.name // .address) (\(.address)) \(.status.state // "?"): \(.labels["bercail.issue"] // "?") \(.labels["bercail.issue_title"] // "")"' 2>/dev/null)" || rows=""
  if [[ -n "$rows" ]]; then
    printf 'background Sheps:\n%s\n' "$rows"
  else
    printf 'background Sheps: none\n'
  fi
}

# Past this, a label title is cut and ends in "…", as handoff-spawn's are.
SHEP_TITLE_MAX=60

# Title of beads issue ID from DIR, one line, cut to SHEP_TITLE_MAX. Fails when
# bd does not know the issue there.
_shep_issue_title() {
  local dir="$1" id="$2" raw
  raw="$(cd "$dir" && bd show "$id" --json 2>/dev/null </dev/null)" || return 1
  jq -er --argjson max "$SHEP_TITLE_MAX" '
    (if type == "array" then .[0] else . end).title // empty
    | gsub("[[:space:][:cntrl:]]+"; " ") | gsub("^ +| +$"; "")
    | if length > $max then (.[0:($max - 1)] | gsub(" +$"; "")) + "…" else . end' <<<"$raw" 2>/dev/null
}

# A background Shep: Pi on the lead's setup (guard and repo policy included) in
# a background hc terminal with no space, so nothing in the app moves. Its
# labels make it a desk to the notify follower, so its finish or block reaches
# Shep's inbox as a desk event; bercail.shep=bg marks it as Shep's own worker.
# --no-notify: the event is the report, not a note typed into Shep's prompt.
# --outlive-parent: a Shep restart does not drop the wait. --rm: `hc kill` is
# the whole cleanup once it has reported.
shep_bg() {
  local issue="" cwd="$PWD" title name lead brief prompt stop="." out
  local hc="${HC_BIN:-hc}" agent="$LOCAL_BIN/bercail-desk-agent"
  local -a cmd
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --issue) issue="${2:-}"; shift 2 || shift $# ;;
      --issue=*) issue="${1#*=}"; shift ;;
      --cwd) cwd="${2:-}"; shift 2 || shift $# ;;
      --cwd=*) cwd="${1#*=}"; shift ;;
      *) _shep_err "usage: bercail shep bg --issue ID [--cwd DIR]"; return 1 ;;
    esac
  done
  [[ -n "$issue" ]] || { _shep_err "usage: bercail shep bg --issue ID [--cwd DIR]"; return 1; }
  [[ "$issue" =~ ^[A-Za-z0-9._-]+$ ]] || { _shep_err "issue id '$issue' has characters a beads id does not"; return 1; }
  cwd="$(cd "$cwd" 2>/dev/null && pwd -P)" || { _shep_err "no folder $cwd; pass the repo's checkout with --cwd"; return 1; }
  title="$(_shep_issue_title "$cwd" "$issue")" \
    || { _shep_err "bd does not know $issue in $cwd; run it from the issue's repo or pass --cwd"; return 1; }
  name="shep-bg-$(printf '%s' "${issue,,}" | tr -c 'a-z0-9_-' '-')"
  name="${name:0:32}"
  if "$hc" get "$name" --json 2>/dev/null </dev/null | jq -e '.state == "live"' >/dev/null 2>&1; then
    _shep_err "$name is already running; see it with: hc read $name, or end it with: hc kill $name"
    return 1
  fi
  [[ -x "$agent" ]] || agent="bercail-desk-agent"
  cmd=(env -u ANTHROPIC_API_KEY -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN -u BERCAIL_SHEP_INBOX
    BERCAIL_ROLE=shep-bg TERM=xterm-256color COLORTERM=truecolor)
  title="${title%.}"
  [[ "$title" != *… ]] || stop=""
  prompt="Your job is beads issue $issue: $title$stop Run \`bd show $issue\` (read its comments too) and do exactly what it describes, then stop."
  cmd+=("$agent" --prompt "$prompt")
  lead="${BSTACK_PI_DIR:-${BERCAIL_SHARE_DIR:-$HOME/.local/share/bercail}/pi}/lead.json"
  if [[ -r "$lead" ]]; then
    while IFS= read -r -d '' out; do
      cmd+=("$out")
    done < <(jq -j '.[] | ., "\u0000"' "$lead")
  else
    cmd+=(pi)
  fi
  brief="$(shep_share_dir)/BACKGROUND.md"
  [[ -r "$brief" ]] || { _shep_err "$brief is missing; run bercail update"; return 1; }
  cmd+=(--append-system-prompt "$brief")
  out="$("$hc" run --bg --json --name "$name" --cwd "$cwd" --outlive-parent --no-notify --rm \
    --label bercail.role=agent --label bercail.shep=bg --label "bercail.issue=$issue" \
    --label "bercail.issue_title=$title" -- "${cmd[@]}" </dev/null)" \
    || { _shep_err "hc could not start $name; its error is above"; return 1; }
  jq -c --arg issue "$issue" --arg title "$title" '{address, name, cwd, issue:$issue, issue_title:$title}' <<<"$out"
}

# Install Shep's package: its rules, the background Shep's brief, and Pi extensions.
deploy_shep() {
  local share rel
  share="$(shep_share_dir)"
  for rel in SHEP.md BACKGROUND.md pi/inbox.ts pi/compaction.ts pi/questions.ts pi/question-commands.ts pi/question-target.ts pi/question-cli.ts pi/discuss.ts pi/scoped-types.ts pi/scoped-questions.ts pi/scoped-target.ts pi/scoped-execution.ts; do
    deploy_install_file "shep/$rel" "$share/$rel"
  done
}

# Use this checkout's helper, or the deployed sibling of lib/ for an installed CLI.
shep_question() {
  local script
  script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/shep/pi/question-cli.ts"
  command -v node >/dev/null 2>&1 || { _shep_err "question commands need Node (installed with Pi)"; return 1; }
  BERCAIL_SHEP_STATE="$(shep_state_dir)" BERCAIL_SHEP_BIN="${BERCAIL_SELF:-bercail}" node "$script" "$@"
}

# Prints Mermaid source (FILE or stdin) without its click and link statements,
# which Pi turns into live links. It errs toward dropping, because Pi's renderer
# deletes controls and splits on Unicode spaces first (docs/shep.md#diagrams-in-chat).
shep_diagram() {
  local src="${1:--}"
  [[ $# -le 1 ]] || { _shep_err "usage: bercail shep diagram [FILE] (stdin without one)"; return 1; }
  [[ "$src" == - || -r "$src" ]] || { _shep_err "cannot read $src; pass a Mermaid file, or the diagram on stdin"; return 1; }
  cat -- "$src" | LC_ALL=C tr -d '\000-\010\013\014\016-\037\177' | LC_ALL=C awk '
    function add(st,   w) {
      w = st; sub(/^([ \t\r\v\f]|[\200-\377])+/, "", w)
      if (tolower(w) ~ /^(click|link)[^a-z0-9_]/) { n++; cut = 1; return }
      gsub(/^[ \t]+|[ \t]+$/, "", st)
      if (st != "") out = out (out == "" ? "" : "; ") st
    }
    {
      gsub(/\302[\200-\237]/, "")
      match($0, /^[ \t]*/); ind = substr($0, 1, RLENGTH)
      cur = ""; tail = ""; out = ""; q = 0; cut = 0
      for (i = 1; i <= length($0); i++) {
        c = substr($0, i, 1)
        if (c == "\"") q = !q
        if (!q && c == "%" && substr($0, i + 1, 1) == "%") { tail = substr($0, i); break }
        if (!q && c == ";") { add(cur); cur = ""; continue }
        cur = cur c
      }
      add(cur)
      if (!cut) print
      else if (out tail != "") print ind out (out != "" && tail != "" ? " " : "") tail
    }
    END { if (n) printf "bercail shep: dropped %d click/link statement(s)\n", n > "/dev/stderr" }'
}

cmd_shep() {
  case "${1:-status}" in
    run) shep_run ;;
    status) shep_status ;;
    bg) shift; shep_bg "$@" ;;
    discuss) shift; shep_discuss "$@" ;;
    repos) shift; shep_repos "$@" ;;
    brief) shift; shep_brief "$@" ;;
    board) shift; shep_board "$@" ;;
    queue) shift; shep_queue "$@" ;;
    remember) shift; shep_remember "$@" ;;
    forget) shift; shep_forget "$@" ;;
    list) shift; shep_list "$@" ;;
    mistake) shift; shep_mistake "$@" ;;
    diagram) shift; shep_diagram "$@" ;;
    questions) shift; if [[ "${1:-}" == --json ]]; then shep_question json; else shep_question list "$@"; fi ;;
    question) shift; shep_question "$@" ;;
    *) _shep_err "$SHEP_USAGE"; return 1 ;;
  esac
}
