#!/usr/bin/env bash
# shellcheck shell=bash
# bstack: bercail's opencode setup. One harness (opencode v2), your own Claude,
# GPT, and Grok subscriptions behind it, and bercail's workflow on top.
# [bstack] in config.toml turns it on and maps roles to models.

OPENCODE_CONFIG_DIR="${OPENCODE_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/opencode}"
BSTACK_MARKER="managed by bercail (bstack)"
# The models deploy resolved, family=model per line. handoff-spawn reads it for
# the families config.toml leaves on auto.
BSTACK_RESOLVED="${AGENTIC_DEV_SHARE_DIR}/bstack-models"
BSTACK_FAMILIES=(claude gpt grok)
BSTACK_ROLES=(lead build judge)
# Agents and commands bstack renders into the opencode config dir.
BSTACK_RENDERED=(agents/bstack.md agents/bstack-builder.md agents/bstack-judge.md
  agents/bstack-autopilot.md commands/bstack-setup.md commands/council.md
  commands/handoff.md commands/ready.md commands/autopilot.md commands/how.md
  commands/why.md commands/unslop.md)

# --- config.toml --------------------------------------------------------------

# Value of KEY in [SECTION], unquoted. A quoted value keeps its '#' (model
# variants like claude-agent/opus#high); a bare one loses a trailing comment.
_bstack_toml_get() {
  local section="$1" key="$2" file="${3:-$AGENTIC_DEV_USER_CONFIG}"
  [[ -f "$file" ]] || return 0
  awk -v want="[$section]" -v key="$key" '
    /^[[:space:]]*\[/ { sec = $0; gsub(/[[:space:]]/, "", sec); next }
    sec != want { next }
    {
      line = $0
      if (line !~ "^[[:space:]]*" key "[[:space:]]*=") next
      sub("^[[:space:]]*" key "[[:space:]]*=[[:space:]]*", "", line)
      if (line ~ /^"/) { sub(/^"/, "", line); sub(/".*$/, "", line) }
      else { sub(/[[:space:]]*#.*$/, "", line); sub(/[[:space:]]+$/, "", line) }
      print line
      exit
    }' "$file"
}

# Set KEY in [SECTION] to RAW (written as is: quote strings yourself). Adds the
# key at the end of the section, or the section at the end of the file.
_bstack_toml_set() {
  local section="$1" key="$2" raw="$3" file="${4:-$AGENTIC_DEV_USER_CONFIG}" tmp
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "[dry-run] would set [$section] $key = $raw in $file"
    return 0
  fi
  ensure_dir "$(dirname "$file")"
  [[ -f "$file" ]] || : >"$file"
  tmp="$(mktemp)"
  awk -v want="[$section]" -v key="$key" -v raw="$raw" '
    function flush() { if (insec && !done) { print key " = " raw; done = 1 } }
    /^[[:space:]]*\[/ {
      s = $0; gsub(/[[:space:]]/, "", s)
      if (insec && s != want) { flush(); insec = 0 }
      if (s == want) { insec = 1; seen = 1 }
      print; next
    }
    insec && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" { if (!done) print key " = " raw; done = 1; next }
    { print }
    END {
      flush()
      if (!seen) { print ""; print want; print key " = " raw }
    }' "$file" >"$tmp"
  mv "$tmp" "$file"
}

bstack_enabled() {
  [[ "$(_bstack_toml_get bstack enabled)" == true ]]
}

_bstack_role_default() {
  case "$1" in
    lead|judge) printf 'claude' ;;
    build) printf 'grok' ;;
  esac
}

# Families in the order a role falls back through them, strongest for it first.
_bstack_role_order() {
  case "$1" in
    build) printf '%s\n' grok gpt claude ;;
    *) printf '%s\n' claude gpt grok ;;
  esac
}

# A family name (claude, gpt, grok) resolves to that family's model: the one set
# in config.toml (pinned), else bercail's pick from `opencode models` when the
# plan is connected (auto). Anything else is a full opencode model id. Empty: the
# agent inherits the session model.
bstack_resolve_model() {
  local spec="$1" model
  case "$spec" in
    claude|gpt|grok) ;;
    *) printf '%s' "$spec"; return 0 ;;
  esac
  model="$(_bstack_toml_get bstack "$spec")"
  if [[ -n "$model" ]]; then
    printf '%s' "$model"
    return 0
  fi
  bstack_family_connected "$spec" || return 0
  _bstack_pick_model "$spec" <<<"$BSTACK_MODELS" || true
}

bstack_model_source() {
  if [[ -n "$(_bstack_toml_get bstack "$1")" ]]; then
    printf 'pinned'
  else
    printf 'auto'
  fi
}

# A role that names a family whose plan is not connected takes the next family
# that has a model, so build = "grok" works on Claude alone and moves to Grok
# once SuperGrok is connected. A full model id is used as is.
bstack_role_model() {
  local role="$1" spec family model
  spec="$(_bstack_toml_get bstack "$role")"
  [[ -n "$spec" ]] || spec="$(_bstack_role_default "$role")"
  case "$spec" in
    claude|gpt|grok) ;;
    *) printf '%s' "$spec"; return 0 ;;
  esac
  for family in "$spec" $(_bstack_role_order "$role"); do
    model="$(bstack_resolve_model "$family")"
    if [[ -n "$model" ]]; then
      printf '%s' "$model"
      return 0
    fi
  done
}

# --- opencode -----------------------------------------------------------------

_bstack_integration_id() {
  case "$1" in
    claude) printf 'claude-agent' ;;
    gpt) printf 'openai' ;;
    grok) printf 'xai' ;;
  esac
}

_bstack_family_label() {
  case "$1" in
    claude) printf 'Claude plan (Claude Agent)' ;;
    gpt) printf 'ChatGPT plan (OpenAI)' ;;
    grok) printf 'SuperGrok (xAI)' ;;
  esac
}

# Integration ids with a connection, one per line. Empty when opencode is missing.
bstack_connected_ids() {
  dep_present opencode || return 0
  opencode auth list --format json 2>/dev/null \
    | jq -r '.[]? | select((.connections | length) > 0) | .id' 2>/dev/null || true
}

# Ask opencode once what is connected and which models it lists. Callers load
# this in their own shell, so the many $(...) lookups after it reuse the answer.
bstack_load_state() {
  [[ "${1:-}" == reload ]] && BSTACK_STATE_LOADED=0
  [[ "${BSTACK_STATE_LOADED:-0}" -eq 1 ]] && return 0
  BSTACK_CONNECTED="$(bstack_connected_ids)"
  BSTACK_MODELS=""
  BSTACK_VARIANTS=""
  if [[ -n "$BSTACK_CONNECTED" ]]; then
    BSTACK_MODELS="$(opencode models 2>/dev/null || true)"
    # "provider/model low,medium,high" per line; empty when the server can't say.
    BSTACK_VARIANTS="$(opencode api get /api/model 2>/dev/null \
      | jq -r '.data[]? | "\(.providerID)/\(.id) \([.variants[]?.id] | join(","))"' 2>/dev/null || true)"
  fi
  BSTACK_STATE_LOADED=1
}

bstack_family_connected() {
  bstack_load_state
  grep -qxF "$(_bstack_integration_id "$1")" <<<"$BSTACK_CONNECTED"
}

BSTACK_EFFORTS=(low medium high xhigh max)

# The reasoning variant for MODEL: [bstack] effort (default high), or the highest
# level below it that the model offers (Grok stops at xhigh). Without the server's
# variant list, only Claude Agent's documented #high is assumed.
_bstack_variant() {
  local model="$1" want offered level best=""
  want="$(_bstack_toml_get bstack effort)"
  want="${want:-high}"
  [[ "$want" == none ]] && return 0
  offered="$(awk -v m="$model" '$1 == m { print $2 }' <<<"${BSTACK_VARIANTS:-}")"
  if [[ -z "${BSTACK_VARIANTS:-}" ]]; then
    [[ "$model" == claude-agent/* ]] && printf 'high'
    return 0
  fi
  for level in "${BSTACK_EFFORTS[@]}"; do
    [[ ",$offered," == *",$level,"* ]] && best="$level"
    [[ "$level" == "$want" ]] && break
  done
  printf '%s' "$best"
}

# The recommended model of a family from `opencode models` (stdin), or nothing:
# the newest plain release. Version sort alone ranks grok-4.20-multi-agent-0309
# over grok-4.7, so dated and special builds only count when nothing plain is listed.
_bstack_pick_model() {
  local list model variant
  list="$(cat)"
  case "$1" in
    claude) model="$(grep -x 'claude-agent/opus' <<<"$list")" ;;
    gpt)
      model="$(grep -E '^openai/gpt-[0-9][0-9.]*-sol$' <<<"$list" | sort -V | tail -1 | grep . \
        || grep -E '^openai/gpt-[0-9][0-9.]*$' <<<"$list" | sort -V | tail -1)"
      ;;
    grok)
      model="$(grep -E '^xai/grok-[0-9]+(\.[0-9]+)?$' <<<"$list" | sort -V | tail -1 | grep . \
        || grep -E '^xai/grok-[0-9]' <<<"$list" | grep -vE 'mini|image|vision' | sort -V | tail -1)"
      ;;
  esac
  [[ -n "${model:-}" ]] || return 1
  variant="$(_bstack_variant "$model")"
  printf '%s%s' "$model" "${variant:+#$variant}"
}

bstack_login_command() {
  case "$1" in
    claude) printf 'opencode auth login claude-agent' ;;
    gpt) printf 'opencode auth login openai' ;;
    grok) printf 'opencode auth login xai --method device' ;;
  esac
}

# --- deploy -------------------------------------------------------------------

# Replace @token@ with its value; drop a line whose token resolves to nothing,
# so an agent with no model inherits the session's.
_bstack_render() {
  local src="$1" dest="$2" family="${3:-}" model="${4:-}" lead
  lead="$(bstack_role_model lead)"
  awk -v lead="$lead" -v base="${lead%%#*}" -v build="$(bstack_role_model build)" \
    -v judge="$(bstack_role_model judge)" -v family="$family" -v model="$model" \
    -v instructions="$OPENCODE_CONFIG_DIR/bstack/instructions.md" '
    function sub_token(tok, val) {
      if (index($0, tok) == 0) return 1
      if (val == "") return 0
      gsub(tok, val)
      return 1
    }
    {
      if (!sub_token("@lead_base@", base)) next
      if (!sub_token("@lead@", lead)) next
      if (!sub_token("@build@", build)) next
      if (!sub_token("@judge@", judge)) next
      if (!sub_token("@family@", family)) next
      if (!sub_token("@model@", model)) next
      if (!sub_token("@instructions@", instructions)) next
      print
    }' "$src" >"$dest"
}

_bstack_ours() {
  [[ -f "$1" ]] && grep -qF "$BSTACK_MARKER" "$1"
}

# Write RENDERED to DEST unless DEST is someone else's file (no bstack marker).
_bstack_place() {
  local rendered="$1" dest="$2"
  if [[ -e "$dest" ]] && ! _bstack_ours "$dest"; then
    warn "keeping your $dest (no '$BSTACK_MARKER' line); bstack did not change it"
    return 1
  fi
  copy_file "$rendered" "$dest"
}

_bstack_remove_ours() {
  local dest="$1"
  _bstack_ours "$dest" || return 0
  info "remove: $dest"
  run rm -f "$dest"
}

# family=model for each family, as deploy would render it now.
_bstack_resolved_text() {
  local family
  for family in "${BSTACK_FAMILIES[@]}"; do
    printf '%s=%s\n' "$family" "$(bstack_resolve_model "$family")"
  done
}

deploy_bstack() {
  local work rel family model jsonc
  if ! bstack_enabled; then
    remove_bstack quiet
    return 0
  fi
  bstack_load_state reload
  work="$(mktemp -d)"
  if ! DRY_RUN=0 deploy_install_file "bstack/MANIFEST" "$work/MANIFEST" >/dev/null; then
    warn "could not read bstack/MANIFEST"
    rm -rf "$work"
    return 1
  fi
  while IFS= read -r rel || [[ -n "$rel" ]]; do
    [[ -n "$rel" && "$rel" != \#* && "$rel" != MANIFEST ]] || continue
    DRY_RUN=0 deploy_install_file "bstack/$rel" "$work/src/$rel" >/dev/null || {
      warn "could not read bstack/$rel"
      rm -rf "$work"
      return 1
    }
  done <"$work/MANIFEST"

  ensure_dir "$OPENCODE_CONFIG_DIR"
  for rel in "${BSTACK_RENDERED[@]}"; do
    _bstack_render "$work/src/$rel" "$work/$(basename "$rel")"
    _bstack_place "$work/$(basename "$rel")" "$OPENCODE_CONFIG_DIR/$rel" || true
  done
  # One read-only reviewer per family with a model: the council's panel.
  for family in "${BSTACK_FAMILIES[@]}"; do
    model="$(bstack_resolve_model "$family")"
    if [[ -n "$model" ]]; then
      _bstack_render "$work/src/agents/bstack-council.md" "$work/council-$family.md" "$family" "$model"
      _bstack_place "$work/council-$family.md" "$OPENCODE_CONFIG_DIR/agents/bstack-council-$family.md" || true
    else
      _bstack_remove_ours "$OPENCODE_CONFIG_DIR/agents/bstack-council-$family.md"
    fi
  done
  copy_file "$work/src/instructions.md" "$OPENCODE_CONFIG_DIR/bstack/instructions.md"

  # opencode merges opencode.json, then opencode.jsonc over it. bstack owns the
  # .jsonc unless the person already has one of their own.
  jsonc="$OPENCODE_CONFIG_DIR/opencode.jsonc"
  _bstack_render "$work/src/opencode.jsonc" "$work/opencode.jsonc"
  if ! _bstack_place "$work/opencode.jsonc" "$jsonc"; then
    warn "for bstack, add to $jsonc: \"default_agent\": \"bstack\" and \"instructions\": [\"$OPENCODE_CONFIG_DIR/bstack/instructions.md\"]"
  fi
  _bstack_resolved_text >"$work/resolved"
  copy_file "$work/resolved" "$BSTACK_RESOLVED"
  rm -rf "$work"
  info "bstack: lead=$(bstack_role_model lead || true) build=$(bstack_role_model build || true) judge=$(bstack_role_model judge || true) (empty: the session's model)"
}

# Remove what deploy_bstack wrote, and only files that still carry the marker.
remove_bstack() {
  local quiet="${1:-}" rel family any=0
  for rel in "${BSTACK_RENDERED[@]}" opencode.jsonc; do
    _bstack_ours "$OPENCODE_CONFIG_DIR/$rel" && any=1
  done
  for family in "${BSTACK_FAMILIES[@]}"; do
    _bstack_ours "$OPENCODE_CONFIG_DIR/agents/bstack-council-$family.md" && any=1
  done
  [[ -d "$OPENCODE_CONFIG_DIR/bstack" || -f "$BSTACK_RESOLVED" ]] && any=1
  if [[ "$any" -eq 0 ]]; then
    [[ -n "$quiet" ]] || info "bstack: nothing to remove in $OPENCODE_CONFIG_DIR"
    return 0
  fi
  for rel in "${BSTACK_RENDERED[@]}" opencode.jsonc; do
    _bstack_remove_ours "$OPENCODE_CONFIG_DIR/$rel"
  done
  for family in "${BSTACK_FAMILIES[@]}"; do
    _bstack_remove_ours "$OPENCODE_CONFIG_DIR/agents/bstack-council-$family.md"
  done
  if [[ -d "$OPENCODE_CONFIG_DIR/bstack" ]]; then
    info "remove: $OPENCODE_CONFIG_DIR/bstack"
    run rm -rf "$OPENCODE_CONFIG_DIR/bstack"
  fi
  [[ ! -f "$BSTACK_RESOLVED" ]] || run rm -f "$BSTACK_RESOLVED"
}

# --- bercail bstack -----------------------------------------------------------

bstack_status() {
  local family role ver model
  bstack_load_state reload
  if bstack_enabled; then
    log "bstack: on"
  else
    log "bstack: off (bercail bstack on)"
  fi
  if dep_present opencode; then
    ver="$(opencode --version 2>/dev/null || true)"
    log "  opencode: $(command -v opencode) (${ver:-unknown version})"
  else
    log "  opencode: missing (bercail bstack setup installs it)"
  fi
  log "  subscriptions:"
  for family in "${BSTACK_FAMILIES[@]}"; do
    model="$(bstack_resolve_model "$family")"
    if bstack_family_connected "$family"; then
      log "    ok  $family  $(_bstack_family_label "$family")  ${model:-no model listed} ($(bstack_model_source "$family"))"
    elif [[ -n "$model" ]]; then
      log "    ok  $family  $model (pinned; plan not connected: $(bstack_login_command "$family"))"
    else
      log "    --  $family  $(_bstack_family_label "$family")  connect: $(bstack_login_command "$family")"
    fi
  done
  log "  roles:"
  for role in "${BSTACK_ROLES[@]}"; do
    log "    $role = $(bstack_role_model "$role" | grep . || printf '(session model)')"
  done
  log "  config: [bstack] in $AGENTIC_DEV_USER_CONFIG (auto picks the newest model; set claude/gpt/grok to pin one)"
}

# On: bstack becomes the desk's default agent when the desk still runs bercail's
# old default. Off: remove bstack's opencode files; the agent command stays.
bstack_on() {
  _bstack_toml_set bstack enabled true
  if [[ "$(read_agent_command)" == cursor-agent ]]; then
    _bstack_toml_set agent command '"opencode"'
    info "desk agent default: opencode (was cursor-agent)"
  fi
  install_opencode_binary || true
  deploy_bstack
}

bstack_off() {
  _bstack_toml_set bstack enabled false
  remove_bstack
  info "bstack off; [agent] command is still $(read_agent_command)"
}

# Guided: install opencode, connect the plans you have, and render the agents.
# Models are picked automatically (auto); a model set in config.toml stays.
# --yes connects nothing and uses what is already connected.
bstack_setup() {
  local family reply cmd
  log "bstack setup: one harness (opencode), your own Claude, GPT, and Grok subscriptions."
  bstack_enabled || _bstack_toml_set bstack enabled true
  install_opencode_binary || die "bstack needs opencode 2.2.3+; install it, then run: bercail bstack setup"
  bstack_opencode_version_ok || die "bstack needs opencode 2.2.3+ ($(opencode --version 2>/dev/null)); run: mise use -g opencode@latest"

  bstack_load_state reload
  for family in "${BSTACK_FAMILIES[@]}"; do
    if bstack_family_connected "$family"; then
      info "connected: $(_bstack_family_label "$family")"
      continue
    fi
    [[ "$YES" -eq 1 ]] && continue
    printf 'Connect your %s? [y/N] ' "$(_bstack_family_label "$family")"
    read_tty reply
    [[ "$reply" =~ ^[Yy]$ ]] || continue
    if [[ "$family" == claude ]] && dep_present claude; then
      info "Claude Agent uses Claude Code's login; run 'claude auth login' first if it isn't signed in"
    elif [[ "$family" == claude ]]; then
      warn "Claude Agent runs Claude Code: install it (https://claude.com/claude-code) and run 'claude auth login', then: $(bstack_login_command claude)"
      continue
    fi
    cmd="$(bstack_login_command "$family")"
    info "running: $cmd"
    # shellcheck disable=SC2086
    $cmd </dev/tty || warn "$cmd did not finish; run it again later"
  done
  bstack_load_state reload
  [[ -n "$BSTACK_CONNECTED" ]] || warn "no subscription connected yet; bstack agents will use the session's model"

  if [[ "$(read_agent_command)" == cursor-agent ]]; then
    _bstack_toml_set agent command '"opencode"'
  fi
  deploy_bstack
  bstack_status
  log ""
  log "next: dev (the desk starts opencode as bstack), or opencode in any repo. Try /how, /ready, /autopilot."
}

cmd_bstack() {
  local sub="${1:-status}"
  shift || true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes|-y) YES=1; shift ;;
      *) die "unknown option: $1" ;;
    esac
  done
  case "$sub" in
    status) bstack_status ;;
    on) bstack_on ;;
    off) bstack_off ;;
    setup) bstack_setup ;;
    *) die "usage: bercail bstack status|on|off|setup [--yes]" ;;
  esac
}

doctor_bstack() {
  local rel missing=0 connected
  bstack_load_state reload
  if ! bstack_enabled; then
    log "  off  bstack (bercail bstack on)"
    return 0
  fi
  if ! dep_present opencode; then
    log "  missing  opencode (bstack is on; bercail bstack setup)"
    return 1
  fi
  if bstack_opencode_version_ok; then
    log "  ok  opencode $(opencode --version 2>/dev/null)"
  else
    log "  old  opencode $(opencode --version 2>/dev/null) (bstack needs 2.2.3+)"
    missing=1
  fi
  for rel in "${BSTACK_RENDERED[@]}" opencode.jsonc bstack/instructions.md; do
    if [[ ! -f "$OPENCODE_CONFIG_DIR/$rel" ]]; then
      log "  missing  bstack $OPENCODE_CONFIG_DIR/$rel (bercail update)"
      missing=1
    elif [[ "$rel" != bstack/* ]] && ! _bstack_ours "$OPENCODE_CONFIG_DIR/$rel"; then
      log "  yours  $OPENCODE_CONFIG_DIR/$rel (not managed by bstack)"
    fi
  done
  connected="$BSTACK_CONNECTED"
  if [[ -f "$BSTACK_RESOLVED" ]] && [[ "$(_bstack_resolved_text)" != "$(<"$BSTACK_RESOLVED")" ]]; then
    log "  stale  bstack models (a plan or model changed since the last deploy; bercail update)"
    missing=1
  fi
  if [[ -z "$connected" ]] || ! grep -qxE 'claude-agent|openai|xai' <<<"$connected"; then
    log "  missing  bstack subscription: none of Claude, ChatGPT, SuperGrok is connected (bercail bstack setup)"
    missing=1
  else
    log "  ok  bstack subscriptions: $(grep -xE 'claude-agent|openai|xai' <<<"$connected" | paste -sd, -)"
  fi
  if [[ "$missing" -eq 0 ]]; then
    log "  ok  bstack (lead=$(bstack_role_model lead | grep . || printf 'session'))"
  fi
  return "$missing"
}
