#!/usr/bin/env bash
# shellcheck shell=bash
# Shep, bercail's orchestrator, in the Herdr app's Shep view: Pi in its own
# folder and session, on bercail's Pi models, with Shep's rules (shep/SHEP.md).
#
#   bercail shep run      what the Shep view's terminal runs
#   bercail shep status

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
  return 0
}

# Install Shep's package: its rules and Pi extension.
deploy_shep() {
  local share rel
  share="$(shep_share_dir)"
  for rel in SHEP.md pi/inbox.ts; do
    deploy_install_file "shep/$rel" "$share/$rel"
  done
}

cmd_shep() {
  case "${1:-status}" in
    run) shep_run ;;
    status) shep_status ;;
    *) _shep_err "usage: bercail shep run | status"; return 1 ;;
  esac
}
