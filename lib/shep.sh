#!/usr/bin/env bash
# shellcheck shell=bash
# Shep, bercail's orchestrator, in the Herdr app's Shep view: Pi in its own
# folder and session, on bercail's Pi models, with Shep's rules (shep/SHEP.md).
#
#   bercail shep run                       what the Shep view's terminal runs
#   bercail shep status
#   bercail shep bg --issue ID [--cwd DIR] a background Shep: waits and follow-through

SHEP_SKILLS=(handoff review desk-restore how why unslop)

shep_state_dir() {
  printf '%s/bercail/shep' "${XDG_STATE_HOME:-$HOME/.local/state}"
}

shep_share_dir() {
  printf '%s/shep' "${AGENTIC_DEV_SHARE_DIR:-$HOME/.local/share/bercail}"
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
# bstack (lead.json) when it is on, Shep's rules, its inbox extension, and its
# own session folder. No context files: the person's global Pi persona and any
# AGENTS.md stay out of Shep.
shep_pi_argv() {
  local lead="${BSTACK_PI_DIR:-${AGENTIC_DEV_SHARE_DIR:-$HOME/.local/share/bercail}/pi}/lead.json"
  local share state id model ext
  share="$(shep_share_dir)"
  state="$(shep_state_dir)"
  SHEP_PI_ARGV=(env -u ANTHROPIC_API_KEY -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN
    BERCAIL_ROLE=shep "BERCAIL_SHEP_INBOX=$state/inbox" pi)
  if [[ -r "$lead" ]]; then
    model="$(jq -r 'index("--model") as $i | if $i then .[$i + 1] else empty end' "$lead" 2>/dev/null || true)"
    [[ -z "$model" ]] || SHEP_PI_ARGV+=(--model "$model")
    while IFS= read -r ext; do
      [[ -n "$ext" ]] && SHEP_PI_ARGV+=(-e "$ext")
    done < <(jq -r '. as $a | range(0; length) | select($a[.] == "-e") | $a[. + 1]' "$lead" 2>/dev/null || true)
  fi
  SHEP_PI_ARGV+=(-e "$share/pi/inbox.ts" --append-system-prompt "$share/SHEP.md"
    --no-context-files --session-dir "$state/pi-sessions" --continue --name Shep)
  for id in "${SHEP_SKILLS[@]}"; do
    [[ -d "$(skill_canonical_dir "$id")" ]] && SHEP_PI_ARGV+=(--skill "$(skill_canonical_dir "$id")")
  done
  return 0
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
    _shep_err "Pi is not installed; install it with: mise use -g pi (or turn bstack on: bercail bstack on)"
    _shep_ended 1
    return 0
  fi
  state="$(shep_state_dir)"
  mkdir -p "$state/workspace" "$state/pi-sessions" "$state/inbox" "$state/delivered"
  shep_pi_argv
  (cd "$state/workspace" && "${SHEP_PI_ARGV[@]}") || code=$?
  _shep_ended "$code"
}

shep_status() {
  local state pending=0 delivered=0 last
  state="$(shep_state_dir)"
  printf 'pi sessions: %s\n' "$state/pi-sessions"
  [[ -d "$state/inbox" ]] && pending="$(find "$state/inbox" -maxdepth 1 -name '*.json' | wc -l)"
  [[ -d "$state/delivered" ]] && delivered="$(find "$state/delivered" -maxdepth 1 -name '*.json' | wc -l)"
  printf 'desk events: %s waiting, %s delivered\n' "$((pending))" "$((delivered))"
  if ((delivered > 0)); then
    last="$(find "$state/delivered" -maxdepth 1 -name '*.json' -printf '%T@ %p\n' | sort -n | tail -n 1 | cut -d' ' -f2-)"
    jq -r '"last delivered: \(.event_id) at \(.delivered_at // "?")"' "$last" 2>/dev/null || true
  fi
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
  lead="${BSTACK_PI_DIR:-${AGENTIC_DEV_SHARE_DIR:-$HOME/.local/share/bercail}/pi}/lead.json"
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

# Install Shep's package: its rules, the background Shep's brief, and Pi extension.
deploy_shep() {
  local share rel
  share="$(shep_share_dir)"
  for rel in SHEP.md BACKGROUND.md pi/inbox.ts; do
    deploy_install_file "shep/$rel" "$share/$rel"
  done
}

cmd_shep() {
  case "${1:-status}" in
    run) shep_run ;;
    status) shep_status ;;
    bg) shift; shep_bg "$@" ;;
    *) _shep_err "usage: bercail shep run | status | bg --issue ID [--cwd DIR]"; return 1 ;;
  esac
}
