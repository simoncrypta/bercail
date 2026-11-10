#!/usr/bin/env bash
# shellcheck shell=bash
# Shep, bercail's orchestrator, in the Herdr app's Shep view. Its identity and
# rules (shep/SHEP.md) are the same on every runtime. The runtime is Pi (the
# default: its own folder and session, bercail's Pi models) or an OpenClaw agent
# reached through the person's Gateway. Each keeps its own history.
#
#   bercail shep run [--setup]     what the Shep view's terminal runs
#   bercail shep setup             choose Pi or OpenClaw
#   bercail shep use pi
#   bercail shep use openclaw [--agent ID | --create [ID]] [--session KEY]
#   bercail shep handoff --to pi|openclaw   context for the next runtime, on stdin
#   bercail shep status

SHEP_SKILLS=(handoff review desk-restore how why unslop)
SHEP_SESSION_RE='^agent:[A-Za-z0-9_-]+:[^[:space:]]+$'
SHEP_AGENT_RE='^[a-z0-9][a-z0-9_-]{0,31}$'
SHEP_OPENCLAW_DOCS="https://docs.openclaw.ai"

shep_state_dir() {
  printf '%s/bercail/shep' "${XDG_STATE_HOME:-$HOME/.local/state}"
}

shep_share_dir() {
  printf '%s/shep' "${AGENTIC_DEV_SHARE_DIR:-$HOME/.local/share/bercail}"
}

_shep_err() {
  printf 'bercail shep: %s\n' "$*" >&2
}

_shep_openclaw() {
  "${OPENCLAW_BIN:-openclaw}" "$@"
}

# [shep] backend. Unset with a [shep] session: openclaw, so an OpenClaw Shep set
# up before there was a choice stays on it. Unset otherwise: none yet, and the
# first start asks.
shep_backend() {
  local backend
  backend="$(_bstack_toml_get shep backend)"
  case "$backend" in
    pi|openclaw) printf '%s' "$backend"; return 0 ;;
    "") ;;
    *) _shep_err "[shep] backend = \"$backend\" is not pi or openclaw; run: bercail shep setup" ;;
  esac
  [[ -z "$(_bstack_toml_get shep session)" ]] || printf 'openclaw'
}

# Where the notify follower drops desk events, only while Shep runs on Pi.
shep_inbox_dir() {
  [[ "$(shep_backend 2>/dev/null)" == pi ]] || return 0
  printf '%s/inbox' "$(shep_state_dir)"
}

# --- OpenClaw -----------------------------------------------------------------

shep_openclaw_present() {
  command -v "${OPENCLAW_BIN:-openclaw}" >/dev/null 2>&1
}

# The RPC check, not only the service: a Gateway the TUI can't reach is down.
shep_gateway_up() {
  _shep_openclaw gateway status --json --require-rpc --timeout 5000 </dev/null >/dev/null 2>&1
}

# OpenClaw's agents, one `id<TAB>default` line each.
shep_openclaw_agents() {
  _shep_openclaw agents list --json </dev/null 2>/dev/null \
    | jq -r '.[]? | [.id, (.isDefault // false | tostring)] | @tsv' 2>/dev/null || true
}

# The session Shep opens on OpenClaw: [shep] session, else the default agent's main.
shep_openclaw_session() {
  local key id
  key="$(_bstack_toml_get shep session)"
  if [[ -n "$key" ]]; then
    [[ "$key" =~ $SHEP_SESSION_RE ]] || {
      _shep_err "[shep] session \"$key\" is not an agent:<id>:<key> session key; run: bercail shep setup"
      return 1
    }
    printf '%s' "$key"
    return 0
  fi
  id="$(shep_openclaw_agents | awk -F'\t' '$2 == "true" { print $1; exit }')"
  [[ -n "$id" ]] || {
    _shep_err "OpenClaw has no default agent; run: bercail shep setup"
    return 1
  }
  printf 'agent:%s:main' "$id"
}

_shep_openclaw_guide() {
  cat >&2 <<EOF
OpenClaw is not installed. To run Shep on OpenClaw:
  1. Install it: $SHEP_OPENCLAW_DOCS/install
  2. Set it up and start its Gateway: openclaw onboard --install-daemon
  3. Check it: openclaw gateway status
  4. Then: bercail shep setup
EOF
}

_shep_gateway_guide() {
  cat >&2 <<EOF
OpenClaw's Gateway does not answer (openclaw gateway status --require-rpc).
  Start it: openclaw gateway start   (or set it up: openclaw onboard --install-daemon)
  Then: bercail shep setup
EOF
}

# Agent and session are there, and the Gateway answers. A new agent's main
# session is made on its first message, so only other keys must exist already.
shep_openclaw_verify() {
  local key="$1" id
  [[ "$key" =~ $SHEP_SESSION_RE ]] || { _shep_err "\"$key\" is not an agent:<id>:<key> session key"; return 1; }
  id="${key#agent:}"
  id="${id%%:*}"
  shep_gateway_up || { _shep_gateway_guide; return 1; }
  shep_openclaw_agents | cut -f1 | grep -qxF "$id" || {
    _shep_err "OpenClaw has no agent \"$id\" (openclaw agents list)"
    return 1
  }
  [[ "$key" == "agent:$id:main" ]] && return 0
  _shep_openclaw sessions --agent "$id" --json </dev/null 2>/dev/null \
    | jq -e --arg k "$key" '.sessions[]? | select(.key == $k)' >/dev/null 2>&1 || {
    _shep_err "OpenClaw agent \"$id\" has no session $key (openclaw sessions --agent $id)"
    return 1
  }
}

# A new OpenClaw agent for Shep, in a new folder seeded with Shep's rules
# (OpenClaw keeps an AGENTS.md and IDENTITY.md it finds there).
shep_openclaw_create() {
  local id="$1" ws share
  [[ "$id" =~ $SHEP_AGENT_RE ]] || { _shep_err "\"$id\" is not an agent id (a-z, 0-9, - and _)"; return 1; }
  if shep_openclaw_agents | cut -f1 | grep -qxF "$id"; then
    _shep_err "OpenClaw already has an agent \"$id\"; connect it with: bercail shep use openclaw --agent $id"
    return 1
  fi
  ws="$(shep_state_dir)/openclaw-$id"
  if [[ -e "$ws" ]] && [[ -n "$(ls -A "$ws" 2>/dev/null)" ]]; then
    _shep_err "$ws is not empty; move it away or pick another id"
    return 1
  fi
  share="$(shep_share_dir)"
  [[ -f "$share/SHEP.md" ]] || { _shep_err "Shep's rules are missing ($share/SHEP.md); run: bercail update"; return 1; }
  mkdir -p "$ws"
  cp "$share/SHEP.md" "$ws/AGENTS.md"
  cp "$share/IDENTITY.md" "$ws/IDENTITY.md"
  if ! _shep_openclaw agents add "$id" --non-interactive --workspace "$ws" --json </dev/null >/dev/null; then
    _shep_err "openclaw agents add $id failed"
    return 1
  fi
  _shep_openclaw agents set-identity --agent "$id" --name Shep </dev/null >/dev/null 2>&1 || true
  printf 'Created OpenClaw agent %s (workspace %s).\n' "$id" "$ws"
}

# Asks for an agent on stdin. Prints the pick: an agent id, or `+ID` to create one.
_shep_pick_agent() {
  local -a ids=()
  local id def n=0 pick default=1 line
  while IFS=$'\t' read -r id def; do
    [[ -n "$id" ]] || continue
    ids+=("$id")
    n=$((n + 1))
    [[ "$def" == true ]] && default="$n"
    printf '  %d) %s%s\n' "$n" "$id" "$([[ "$def" == true ]] && printf ' (default)')" >&2
  done < <(shep_openclaw_agents)
  printf '  c) create a dedicated Shep agent\n  q) cancel\n' >&2
  [[ "${#ids[@]}" -gt 0 ]] || default=c
  printf 'Pick [%s]: ' "$default" >&2
  read -r pick || return 1
  pick="${pick:-$default}"
  case "$pick" in
    q|Q) return 1 ;;
    c|C)
      printf 'New agent id [shep]: ' >&2
      read -r line || return 1
      printf '+%s' "${line:-shep}"
      ;;
    *)
      [[ "$pick" =~ ^[0-9]+$ ]] && ((pick >= 1 && pick <= ${#ids[@]})) || { _shep_err "no choice $pick"; return 1; }
      printf '%s' "${ids[$((pick - 1))]}"
      ;;
  esac
}

# Point Shep at an OpenClaw agent. Nothing is written until the agent and its
# session check out. 0: switched; 1: cancelled or failed, config unchanged.
shep_use_openclaw() {
  local agent="" create="" key="" pick
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --agent) agent="${2:-}"; shift 2 ;;
      --create)
        if [[ -n "${2:-}" && "$2" != --* ]]; then create="$2"; shift 2; else create=shep; shift; fi
        ;;
      --session) key="${2:-}"; shift 2 ;;
      *) _shep_err "unknown option for use openclaw: $1"; return 1 ;;
    esac
  done
  shep_openclaw_present || { _shep_openclaw_guide; return 1; }
  shep_gateway_up || { _shep_gateway_guide; return 1; }
  if [[ -z "$agent" && -z "$create" && -z "$key" ]]; then
    if [[ -t 0 || -n "${SHEP_PROMPT:-}" ]]; then
      printf 'Which OpenClaw agent should be Shep?\n' >&2
      pick="$(_shep_pick_agent)" || { printf 'Cancelled; Shep stays as it was.\n' >&2; return 1; }
      if [[ "$pick" == +* ]]; then create="${pick#+}"; else agent="$pick"; fi
    else
      key="$(_bstack_toml_get shep session)"
      [[ -n "$key" ]] || { _shep_err "pass --agent ID or --create [ID]"; return 1; }
    fi
  fi
  if [[ -n "$create" ]]; then
    shep_openclaw_create "$create" || return 1
    agent="$create"
  fi
  [[ -n "$key" ]] || key="agent:$agent:main"
  if [[ -n "$agent" && "$key" != "agent:$agent:"* ]]; then
    _shep_err "--session $key is not a session of agent $agent"
    return 1
  fi
  shep_openclaw_verify "$key" || return 1
  _bstack_toml_set shep session "\"$key\"" >/dev/null
  _bstack_toml_set shep backend '"openclaw"' >/dev/null
  agent="${key#agent:}"
  printf 'Shep runs on OpenClaw: %s.\n' "$key"
  printf 'Desk events reach it once you run: bercail notify openclaw --agent %s\n' "${agent%%:*}"
}

shep_use_pi() {
  if ! command -v pi >/dev/null 2>&1; then
    _shep_err "Pi is not installed; install it with: mise use -g pi (or turn bstack on: bercail bstack on)"
    return 1
  fi
  _bstack_toml_set shep backend '"pi"' >/dev/null
  mkdir -p "$(shep_state_dir)/inbox"
  printf 'Shep runs on Pi, in its own session.\n'
  [[ -z "$(_bstack_toml_get shep session)" ]] \
    || printf 'Your OpenClaw session stays in [shep] session for switching back.\n'
}

# Pi or OpenClaw, asked on stdin. A cancelled or failed OpenClaw setup keeps
# the backend Shep had; with none, it offers Pi. 1: no backend chosen.
shep_setup() {
  local current choice yn
  current="$(shep_backend)"
  printf '\nWhere should Shep run?%s\n' "${current:+ (now: $current)}" >&2
  printf '  1) Pi (recommended): its own session, with bercail'"'"'s Pi models\n' >&2
  printf '  2) OpenClaw: an agent on your OpenClaw Gateway\n' >&2
  printf '  q) %s\n' "$([[ -n "$current" ]] && printf 'keep %s' "$current" || printf 'quit')" >&2
  printf 'Choose [1]: ' >&2
  read -r choice || choice=q
  case "${choice:-1}" in
    1) shep_use_pi && return 0 ;;
    2)
      SHEP_PROMPT=1 shep_use_openclaw && return 0
      if [[ -n "$current" ]]; then
        printf 'Shep stays on %s.\n' "$current" >&2
        return 0
      fi
      printf 'Start Shep on Pi instead? [Y/n] ' >&2
      read -r yn || yn=n
      [[ "$yn" =~ ^[Nn] ]] || { shep_use_pi && return 0; }
      ;;
    *) [[ -n "$current" ]] && return 0 ;;
  esac
  [[ -n "$(shep_backend)" ]]
}

# --- running -------------------------------------------------------------------

# The handoff the other runtime left for BACKEND, as a first message. Taken once.
_shep_take_handoff() {
  local file
  file="$(shep_state_dir)/handoff-$1.md"
  [[ -s "$file" ]] || return 0
  printf 'Context handoff from Shep on your other runtime (it wrote this for you; your own history there is not here):\n\n'
  cat "$file"
  mv -f "$file" "$file.taken"
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

_shep_label() {
  [[ -n "${HC_TERMINAL_ID:-}" ]] || return 0
  "${HC_BIN:-hc}" label "$HC_TERMINAL_ID" "$@" </dev/null >/dev/null 2>&1 || true
}

# A runtime that fails leaves its message on screen until Enter.
_shep_ended() {
  local name="$1" code="$2"
  [[ "$code" -eq 0 ]] && return 0
  printf '\nShep (%s) exited with code %s. Press Enter to close.\n' "$name" "$code" >&2
  read -r _ || true
  return 0
}

_shep_run_pi() {
  local state msg code=0
  if ! command -v pi >/dev/null 2>&1; then
    _shep_err "Pi is not installed: mise use -g pi, or bercail bstack on. Or run: bercail shep setup"
    _shep_ended pi 1
    return 0
  fi
  state="$(shep_state_dir)"
  mkdir -p "$state/workspace" "$state/pi-sessions" "$state/inbox" "$state/delivered"
  _shep_label bercail.shep_backend=pi
  shep_pi_argv
  msg="$(_shep_take_handoff pi)"
  if [[ -n "$msg" ]]; then
    (cd "$state/workspace" && "${SHEP_PI_ARGV[@]}" -- "$msg") || code=$?
  else
    (cd "$state/workspace" && "${SHEP_PI_ARGV[@]}") || code=$?
  fi
  _shep_ended pi "$code"
}

_shep_run_openclaw() {
  local key msg code=0
  if ! shep_openclaw_present; then
    _shep_openclaw_guide
    _shep_ended openclaw 1
    return 0
  fi
  key="$(shep_openclaw_session)" || { _shep_ended openclaw 1; return 0; }
  _shep_label bercail.shep_backend=openclaw "bercail.shep_session=$key"
  msg="$(_shep_take_handoff openclaw)"
  if [[ -n "$msg" ]]; then
    _shep_openclaw tui --session "$key" --message "$msg" || code=$?
  else
    _shep_openclaw tui --session "$key" || code=$?
  fi
  _shep_ended "openclaw tui" "$code"
}

# What the Shep view's terminal runs: the first start (or --setup) asks where
# Shep runs, then the chosen runtime runs in this terminal.
shep_run() {
  local backend
  backend="$(shep_backend)"
  if [[ "${1:-}" == --setup || -z "$backend" ]]; then
    if ! shep_setup; then
      printf '\nShep has no runtime yet. Press Enter to close; Start Shep asks again.\n' >&2
      read -r _ || true
      return 0
    fi
    backend="$(shep_backend)"
  fi
  case "$backend" in
    pi) _shep_run_pi ;;
    openclaw) _shep_run_openclaw ;;
  esac
}

# The handoff for the runtime Shep moves to, from stdin.
shep_handoff() {
  local to="" file text
  [[ "${1:-}" == --to ]] && to="${2:-}"
  [[ "$to" == pi || "$to" == openclaw ]] || { _shep_err "usage: bercail shep handoff --to pi|openclaw < notes"; return 1; }
  text="$(head -c 16384)"
  [[ -n "${text//[[:space:]]/}" ]] || { _shep_err "the handoff is empty; pipe it on stdin"; return 1; }
  file="$(shep_state_dir)/handoff-$to.md"
  mkdir -p "$(shep_state_dir)"
  (umask 077 && printf '%s\n' "$text" >"$file")
  printf 'Shep on %s reads this handoff when it starts (%s).\n' "$to" "$file"
}

shep_status() {
  local backend state pending=0 delivered=0 last key f
  backend="$(shep_backend)"
  state="$(shep_state_dir)"
  printf 'backend: %s\n' "${backend:-none (the first start asks)}"
  key="$(_bstack_toml_get shep session)"
  [[ -z "$key" ]] || printf 'openclaw session: %s\n' "$key"
  printf 'pi sessions: %s\n' "$state/pi-sessions"
  [[ -d "$state/inbox" ]] && pending="$(find "$state/inbox" -maxdepth 1 -name '*.json' | wc -l)"
  [[ -d "$state/delivered" ]] && delivered="$(find "$state/delivered" -maxdepth 1 -name '*.json' | wc -l)"
  printf 'desk events: %s waiting, %s delivered\n' "$((pending))" "$((delivered))"
  if ((delivered > 0)); then
    last="$(find "$state/delivered" -maxdepth 1 -name '*.json' -printf '%T@ %p\n' | sort -n | tail -n 1 | cut -d' ' -f2-)"
    jq -r '"last delivered: \(.event_id) at \(.delivered_at // "?")"' "$last" 2>/dev/null || true
  fi
  for f in "$state"/handoff-*.md; do
    [[ -f "$f" ]] && printf 'handoff waiting: %s\n' "$f"
  done
  return 0
}

# Install Shep's package: its rules, identity, and Pi extension.
deploy_shep() {
  local share rel
  share="$(shep_share_dir)"
  for rel in SHEP.md IDENTITY.md pi/inbox.ts; do
    deploy_install_file "shep/$rel" "$share/$rel"
  done
}

cmd_shep() {
  local sub="${1:-status}"
  shift || true
  case "$sub" in
    run) shep_run "$@" ;;
    setup) SHEP_PROMPT=1 shep_setup ;;
    use)
      case "${1:-}" in
        pi) shep_use_pi ;;
        openclaw) shift; shep_use_openclaw "$@" ;;
        *) _shep_err "usage: bercail shep use pi | use openclaw [--agent ID | --create [ID]] [--session KEY]"; return 1 ;;
      esac
      ;;
    handoff) shep_handoff "$@" ;;
    status) shep_status ;;
    *) _shep_err "usage: bercail shep run | setup | use pi|openclaw | handoff --to pi|openclaw | status"; return 1 ;;
  esac
}
