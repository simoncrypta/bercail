#!/usr/bin/env bash
# shellcheck shell=bash
# bstack: bercail's agent setup on Pi. Your own Claude, GPT, and Grok logins sit
# behind it, and bercail's workflow on top. [bstack] in config.toml turns it on
# and maps roles to models.

BSTACK_MARKER="managed by bercail (bstack)"
# Paths below expand at source time. Same default as lib/common.sh: an unset
# share dir would otherwise become /pi/...
: "${AGENTIC_DEV_SHARE_DIR:=${HOME}/.local/share/bercail}"
BSTACK_FAMILIES=(claude gpt grok)
BSTACK_ROLES=(lead build judge)
# The Pi profile lives in bercail's share dir: Pi's own files stay the person's,
# and every launch names this dir with flags.
BSTACK_PI_DIR="${AGENTIC_DEV_SHARE_DIR}/pi"
BSTACK_PI_TEMPLATES="${XDG_CONFIG_HOME:-$HOME/.config}/herdr-core/templates"
BSTACK_PI_BRIDGE="npm:pi-claude-bridge@0.11.0"
# Claude Code refuses a prompt within min(max output, 20k) + 3k tokens of the
# window, so Pi's default 16384 reserve compacts too late on the bridge. 40k
# compacts first, with room for the tool results Pi only estimates.
BSTACK_PI_BRIDGE_RESERVE=40000
BSTACK_PI_RENDERED=(instructions.md agents/bstack-builder.md agents/bstack-judge.md
  agents/bstack-autopilot.md agents/bstack-headless.md agents/bstack-pr-review.md prompts/ready.md
  prompts/council.md prompts/handoff.md prompts/autopilot.md prompts/how.md prompts/why.md
  prompts/unslop.md prompts/pr-review.md prompts/bstack-setup.md)

# --- config.toml --------------------------------------------------------------

# Value of KEY in [SECTION], unquoted. A quoted value keeps its '#' (model
# variants like claude-bridge/claude-opus-5-5#high); a bare one loses a trailing comment.
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
# in config.toml (pinned), else bercail's pick from Pi's catalog when the login
# is ready (auto). Anything else is a full Pi model id. Empty: the agent uses
# Pi's default model.
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
# once the X subscription is connected. A full model id is used as is.
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

# --- logins and models --------------------------------------------------------

_bstack_family_label() {
  case "$1" in
    claude) printf 'Claude plan (Claude Code via pi-claude-bridge)' ;;
    gpt) printf 'Sign in with ChatGPT (openai, or openai-codex)' ;;
    grok) printf 'xAI login' ;;
  esac
}

# Ask Pi once what is logged in and which models it lists. Callers load this in
# their own shell, so the many $(...) lookups after it reuse the answer.
bstack_load_state() {
  [[ "${1:-}" == reload ]] && BSTACK_STATE_LOADED=0
  [[ "${BSTACK_STATE_LOADED:-0}" -eq 1 ]] && return 0
  BSTACK_CONNECTED="$(_bstack_pi_connected_ids)"
  BSTACK_MODELS=""
  BSTACK_VARIANTS=""
  [[ -z "$BSTACK_CONNECTED" ]] || _bstack_pi_load_models
  BSTACK_STATE_LOADED=1
}

bstack_family_connected() {
  local provider
  bstack_load_state
  for provider in $(_bstack_pi_providers "$1"); do
    grep -qxF "$provider" <<<"$BSTACK_CONNECTED" && return 0
  done
  return 1
}

BSTACK_EFFORTS=(low medium high xhigh max)

# The reasoning variant for MODEL: [bstack] effort (default high), or the highest
# level below it that the model offers (Grok stops at xhigh). Without a variant
# list, none.
_bstack_variant() {
  local model="$1" want offered level best=""
  want="$(_bstack_toml_get bstack effort)"
  want="${want:-high}"
  [[ "$want" == none ]] && return 0
  [[ -n "${BSTACK_VARIANTS:-}" ]] || return 0
  offered="$(awk -v m="$model" '$1 == m { print $2 }' <<<"$BSTACK_VARIANTS")"
  for level in "${BSTACK_EFFORTS[@]}"; do
    [[ ",$offered," == *",$level,"* ]] && best="$level"
    [[ "$level" == "$want" ]] && break
  done
  printf '%s' "$best"
}

# The recommended model of a family from Pi's catalog (stdin), with its variant.
_bstack_pick_model() {
  local model variant
  model="$(_bstack_pi_pick_model "$1")"
  [[ -n "$model" ]] || return 1
  variant="$(_bstack_variant "$model")"
  printf '%s%s' "$model" "${variant:+#$variant}"
}

bstack_login_command() {
  if [[ "$1" == claude ]]; then printf 'claude auth login'; return 0; fi
  printf '/login %s (inside pi)' "$(_bstack_pi_providers "$1" | head -1)"
}

# --- pi -----------------------------------------------------------------------

# Runtime fallback candidates, separate from the initial role model picks.
# The array is a list of family names; an empty array disables fallback.
bstack_pi_fallback() {
  local raw
  raw="$(_bstack_toml_get bstack fallback)"
  [[ -n "$raw" ]] || raw='["claude", "gpt", "grok"]'
  if ! jq -e 'type == "array" and all(.[]; . == "claude" or . == "gpt" or . == "grok") and (length == (unique | length))' \
    <<<"$raw" >/dev/null 2>&1; then
    warn '[bstack] fallback must be an array of claude, gpt, grok, without duplicates'
    return 1
  fi
  jq -r '.[]' <<<"$raw"
}

_bstack_pi_version_ok() {
  local v
  v="$(pi --version 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)+' | head -1)"
  [[ -n "$v" && "$(printf '%s\n' 1.2.0 "$v" | sort -V | head -1)" == 1.2.0 ]]
}

_bstack_pi_bridge_present() {
  dep_present pi || return 1
  local table
  table="$(pi --offline -e "$BSTACK_PI_BRIDGE" --list-models 2>/dev/null)" || return 1
  awk '$1 == "claude-bridge" { found = 1 } END { exit !found }' <<<"$table"
}

# The bridge's dummy key and Claude Code's API-key auth are not plan logins.
_bstack_pi_claude_ready() {
  dep_present claude || return 1
  env -u ANTHROPIC_API_KEY -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN \
    claude auth status --json 2>/dev/null \
    | jq -e '.loggedIn == true and (.authMethod == "claude.ai" or .authMethod == "oauth_token")' >/dev/null 2>&1
}

# The Pi providers behind a family, the one to log in to first.
_bstack_pi_providers() {
  case "$1" in
    claude) printf '%s\n' claude-bridge ;;
    gpt) printf '%s\n' openai openai-codex ;;
    grok) printf '%s\n' xai ;;
  esac
}

# Providers with a usable login, one per line. --no-refresh keeps this offline;
# never --credentials, which prints the secret.
_bstack_pi_connected_ids() {
  local provider
  dep_present pi || return 0
  _bstack_pi_claude_ready && printf '%s\n' claude-bridge
  for provider in openai openai-codex xai; do
    if pi auth check --provider "$provider" --no-refresh --json 2>/dev/null \
      | jq -e '.status == "ready"' >/dev/null 2>&1; then
      printf '%s\n' "$provider"
    fi
  done
}

# From Pi's offline catalog: provider model context max-out thinking images.
# Pi clamps a thinking level the model lacks, so a model that thinks offers them all.
_bstack_pi_load_models() {
  local table
  table="$(pi --offline -e "$BSTACK_PI_BRIDGE" --list-models 2>/dev/null || true)"
  BSTACK_MODELS="$(awk 'NR > 1 && NF >= 5 { print $1 "/" $2 }' <<<"$table")"
  BSTACK_VARIANTS="$(awk 'NR > 1 && NF >= 5 { print $1 "/" $2, ($5 == "yes" ? "low,medium,high,xhigh,max" : "") }' <<<"$table")"
}

# The newest plain release of a family in the catalog on stdin, or nothing.
_bstack_pi_pick_model() {
  local list provider model=""
  list="$(cat)"
  case "$1" in
    claude) model="$(grep -E '^claude-bridge/claude-opus-[0-9]+(-[0-9]{1,2})?$' <<<"$list" | sort -V | tail -1)" ;;
    gpt)
      for provider in openai openai-codex; do
        grep -qxF "$provider" <<<"$BSTACK_CONNECTED" || continue
        model="$(grep -E "^$provider/gpt-[0-9][0-9.]*-sol\$" <<<"$list" | sort -V | tail -1 | grep . \
          || grep -E "^$provider/gpt-[0-9][0-9.]*\$" <<<"$list" | sort -V | tail -1)"
        [[ -z "$model" ]] || break
      done
      ;;
    grok)
      model="$(grep -E '^xai/grok-[0-9]+(\.[0-9]+)?$' <<<"$list" | sort -V | tail -1 | grep . \
        || grep -E '^xai/grok-[0-9]' <<<"$list" | grep -vE 'mini|image|vision' | sort -V | tail -1)"
      ;;
  esac
  printf '%s' "$model"
}

# config.toml writes a variant as model#high; Pi's --model takes model:high.
_bstack_pi_model_id() {
  printf '%s' "${1/\#/:}"
}

# The pi argv a bstack agent runs, into BSTACK_PI_ARGV. Skills are named because
# settings.json may filter them out.
_bstack_pi_argv() {
  local model="$1" brief="${2:-}" id
  BSTACK_PI_ARGV=(pi)
  [[ -z "$model" ]] || BSTACK_PI_ARGV+=(--model "$(_bstack_pi_model_id "$model")")
  BSTACK_PI_ARGV+=(-e "$BSTACK_PI_BRIDGE" -e "$BSTACK_PI_DIR/extensions/fallback.ts" -e "$BSTACK_PI_DIR/extensions/guard.ts")
  BSTACK_PI_ARGV+=(--prompt-template "$BSTACK_PI_DIR/prompts"
    --append-system-prompt "$BSTACK_PI_DIR/instructions.md")
  [[ -z "$brief" ]] || BSTACK_PI_ARGV+=(--append-system-prompt "$BSTACK_PI_DIR/agents/$brief.md")
  for id in "${AGENTIC_DEV_SKILL_IDS[@]}"; do
    BSTACK_PI_ARGV+=(--skill "$(skill_canonical_dir "$id")")
  done
}

# bercail review-pr's reviewer, into BSTACK_PI_ARGV: the lead's model, the
# read-only tools, and review.ts, which keeps it in the stack dir. No skills,
# prompt templates, or context files: the pr-review rules are its whole brief.
_bstack_pi_review_argv() {
  local model="$1"
  BSTACK_PI_ARGV=(pi)
  [[ -z "$model" ]] || BSTACK_PI_ARGV+=(--model "$(_bstack_pi_model_id "$model")")
  BSTACK_PI_ARGV+=(-e "$BSTACK_PI_BRIDGE" -e "$BSTACK_PI_DIR/extensions/fallback.ts"
    -e "$BSTACK_PI_DIR/extensions/review.ts" --tools "read,grep,find,ls"
    --no-skills --no-prompt-templates --no-context-files
    --append-system-prompt "$BSTACK_PI_DIR/agents/bstack-pr-review.md")
}

# The command line a bstack agent starts with. BERCAIL_ROLE identifies its role;
# empty is the lead.
bstack_pi_command() {
  local role="$1" model="$2" brief="${3:-}"
  local -a argv=(env -u ANTHROPIC_API_KEY -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN)
  [[ -z "$role" ]] || argv+=("BERCAIL_ROLE=$role")
  _bstack_pi_argv "$model" "$brief"
  argv+=("${BSTACK_PI_ARGV[@]}")
  printf '%q ' "${argv[@]}" | sed 's/ $//'
}

# herdr-core template: frontmatter is strict key: value, so the marker sits in
# the description. The body becomes the start of the agent's first message.
_bstack_pi_template() {
  local work="$1" name="$2" role="$3" model="$4" brief="$5" description="$6"
  {
    printf -- '---\nname: %s\ndescription: %s (%s)\ncommand: %s\n---\n' \
      "$name" "$description" "$BSTACK_MARKER" "$(bstack_pi_command "$role" "$model" "$brief")"
    printf 'You are %s. Your rules are in your system prompt. Work only the task below.\n' "$name"
  } >"$work/$name.md"
  _bstack_place "$work/$name.md" "$BSTACK_PI_TEMPLATES/$name.md" || true
}

_bstack_deploy_pi() {
  local work="$1" rel family model
  [[ ! -d "$BSTACK_PI_DIR" ]] || run rm -rf "$BSTACK_PI_DIR"
  for rel in "${BSTACK_PI_RENDERED[@]}"; do
    _bstack_render "$work/src/pi/$rel" "$work/pi-rendered"
    copy_file "$work/pi-rendered" "$BSTACK_PI_DIR/$rel"
  done
  copy_file "$work/src/pi/extensions/fallback.ts" "$BSTACK_PI_DIR/extensions/fallback.ts"
  copy_file "$work/src/pi/extensions/guard.ts" "$BSTACK_PI_DIR/extensions/guard.ts"
  copy_file "$work/src/pi/extensions/review.ts" "$BSTACK_PI_DIR/extensions/review.ts"
  bstack_pi_fallback >"$work/fallback" || return 1
  copy_file "$work/fallback" "$BSTACK_PI_DIR/fallback"
  # The desk's lead, as a JSON argv: bercail-desk-agent runs it with the
  # Anthropic env unset.
  _bstack_pi_argv "$(bstack_role_model lead)"
  jq -n '$ARGS.positional' --args -- "${BSTACK_PI_ARGV[@]}" >"$work/lead.json"
  copy_file "$work/lead.json" "$BSTACK_PI_DIR/lead.json"
  _bstack_pi_review_argv "$(bstack_role_model lead)"
  jq -n '$ARGS.positional' --args -- "${BSTACK_PI_ARGV[@]}" >"$work/review.json"
  copy_file "$work/review.json" "$BSTACK_PI_DIR/review.json"

  ensure_dir "$BSTACK_PI_TEMPLATES"
  _bstack_pi_template "$work" bstack-builder builder "$(bstack_role_model build)" bstack-builder \
    "Writes code from a precise brief and proves it with the command the brief names."
  _bstack_pi_template "$work" bstack-judge judge "$(bstack_role_model judge)" bstack-judge \
    "The strongest reasoner, read-only. For the hardest calls and for settling disagreements."
  _bstack_pi_template "$work" bstack-autopilot autopilot "$(bstack_role_model lead)" bstack-autopilot \
    "Drives an open PR to green. Pushes the PR branch, never merges."
  # One read-only reviewer per family with a model: the council's panel.
  for family in "${BSTACK_FAMILIES[@]}"; do
    model="$(bstack_resolve_model "$family")"
    if [[ -n "$model" ]]; then
      copy_file "$work/src/pi/agents/bstack-council.md" "$BSTACK_PI_DIR/agents/bstack-council-$family.md"
      _bstack_pi_template "$work" "bstack-council-$family" council "$model" "bstack-council-$family" \
        "Read-only council reviewer on $family. Tries to break a change and reports only findings it can show."
    else
      _bstack_remove_ours "$BSTACK_PI_TEMPLATES/bstack-council-$family.md"
    fi
  done
  _bstack_resolved_text >"$work/resolved"
  copy_file "$work/resolved" "$BSTACK_PI_DIR/models"
  info "bstack (pi): lead=$(bstack_role_model lead || true) build=$(bstack_role_model build || true) judge=$(bstack_role_model judge || true) (empty: Pi's default model)"
}

_bstack_pi_template_paths() {
  local name
  for name in bstack-builder bstack-judge bstack-autopilot bstack-council-claude bstack-council-gpt bstack-council-grok; do
    printf '%s\n' "$BSTACK_PI_TEMPLATES/$name.md"
  done
}

_bstack_pi_rendered_any() {
  local path
  [[ ! -d "$BSTACK_PI_DIR" ]] || return 0
  while IFS= read -r path; do
    _bstack_ours "$path" && return 0
  done < <(_bstack_pi_template_paths)
  return 1
}

_bstack_remove_pi() {
  local path
  while IFS= read -r path; do
    _bstack_remove_ours "$path"
  done < <(_bstack_pi_template_paths)
  [[ ! -d "$BSTACK_PI_DIR" ]] || { info "remove: $BSTACK_PI_DIR"; run rm -rf "$BSTACK_PI_DIR"; }
}

# Pi reads compaction per model only from its settings.json, so each
# claude-bridge model gets BSTACK_PI_BRIDGE_RESERVE there, beside the bridge
# package. A larger reserve already set stays; other keys are kept.
_bstack_pi_bridge_compaction() {
  local work="$1" file="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/settings.json" current='{}'
  local -a models
  read -ra models <<<"$(pi --offline -e "$BSTACK_PI_BRIDGE" --list-models 2>/dev/null \
    | awk '$1 == "claude-bridge" { printf "%s/%s ", $1, $2 }')"
  ((${#models[@]})) || return 0
  if [[ -s "$file" ]] && ! current="$(jq -e -c 'objects' "$file" 2>/dev/null)"; then
    warn "$file is not a JSON object; set compaction.modelOverrides reserveTokens to $BSTACK_PI_BRIDGE_RESERVE for claude-bridge models by hand"
    return 1
  fi
  jq --argjson r "$BSTACK_PI_BRIDGE_RESERVE" '
    reduce $ARGS.positional[] as $m (.;
      .compaction.modelOverrides[$m].reserveTokens |= ([. // 0, $r] | max))' \
    --args -- "${models[@]}" <<<"$current" >"$work/pi-settings.json" || return 1
  copy_file "$work/pi-settings.json" "$file"
}

# Install Pi and the Claude bridge.
_bstack_install_pi() {
  maybe_mise_install pi pi || return 1
  _bstack_pi_version_ok || { warn 'bstack needs Pi >=1.2.0'; return 1; }
  _bstack_pi_bridge_present || run pi install "$BSTACK_PI_BRIDGE"
}

# Is a model in Pi's catalog? It can carry a level either way: model#high or model:high.
_bstack_pi_known() {
  local id="${1%%#*}"
  [[ "$id" =~ ^(.*):(off|minimal|low|medium|high|xhigh|max)$ ]] && id="${BASH_REMATCH[1]}"
  [[ -z "$BSTACK_MODELS" ]] || grep -qxF "$id" <<<"$BSTACK_MODELS"
}

bstack_status() {
  local family role ver model note
  bstack_load_state reload
  if bstack_enabled; then
    log "bstack: on"
  else
    log "bstack: off (bercail bstack on)"
  fi
  if dep_present pi; then
    ver="$(pi --version 2>/dev/null || true)"
    log "  pi: $(command -v pi) (${ver:-unknown version})"
  else
    log "  pi: missing (bercail bstack setup installs it)"
  fi
  if _bstack_pi_bridge_present; then
    log "  bridge: present ($BSTACK_PI_BRIDGE)"
  else
    log "  bridge: missing (pi install $BSTACK_PI_BRIDGE)"
  fi
  if _bstack_pi_claude_ready; then
    log "  Claude auth: ready (claude auth status --json)"
  else
    log "  Claude auth: no subscription login (claude auth login)"
  fi
  local fallback
  if fallback="$(bstack_pi_fallback)"; then
    log "  fallback: $(paste -sd' ' - <<<"$fallback") (skips current/already attempted)"
  else
    log "  fallback: invalid [bstack] fallback"
  fi
  log "  logins:"
  for family in "${BSTACK_FAMILIES[@]}"; do
    model="$(bstack_resolve_model "$family")"
    if bstack_family_connected "$family"; then
      log "    ok  $family  $(_bstack_family_label "$family")  $(_bstack_pi_model_id "${model:-no model listed}") ($(bstack_model_source "$family"))"
    elif [[ -n "$model" ]]; then
      log "    ok  $family  $(_bstack_pi_model_id "$model") (pinned; not logged in: $(bstack_login_command "$family"))"
    else
      log "    --  $family  $(_bstack_family_label "$family")  log in: $(bstack_login_command "$family")"
    fi
  done
  log "  roles:"
  for role in "${BSTACK_ROLES[@]}"; do
    model="$(bstack_role_model "$role")"
    note=""
    [[ -z "$model" ]] || _bstack_pi_known "$model" || note="  (not in pi --list-models)"
    log "    $role = $(_bstack_pi_model_id "${model:-(the default model in Pi)}")$note"
  done
  for family in "${BSTACK_FAMILIES[@]}"; do
    model="$(bstack_resolve_model "$family")"
    [[ -z "$model" ]] || log "    council ($family) = $(_bstack_pi_model_id "$model")"
  done
  log "  config: [bstack] in $AGENTIC_DEV_USER_CONFIG (auto picks the newest model; set claude/gpt/grok to pin a Pi id)"
}

# Guided: install Pi and the bridge, then render the agents. Models are picked
# automatically (auto); a model set in config.toml stays.
bstack_setup() {
  bstack_load_state reload
  log "bstack setup: Pi, with your own Claude, ChatGPT, and Grok logins."
  bstack_enabled || _bstack_toml_set bstack enabled true
  _bstack_install_pi || die "bstack on Pi needs pi; install it (mise use -g pi), then run: bercail bstack setup"
  deploy_bstack
  bstack_status
  log ""
  log "next: run claude auth login for Claude; type the /login lines above in pi for other missing logins, then run: bercail update"
}

doctor_bstack() {
  local rel missing=0 path family any_login=0 model
  bstack_load_state reload
  if ! bstack_enabled; then
    log "  off  bstack (bercail bstack on)"
    return 0
  fi
  if ! dep_present pi; then
    log "  missing  pi (bstack is on; bercail bstack setup)"
    return 1
  fi
  if _bstack_pi_version_ok; then
    log "  ok  pi $(pi --version 2>/dev/null)"
  else
    log "  old  pi $(pi --version 2>/dev/null) (bstack needs >=1.2.0)"
    missing=1
  fi
  if _bstack_pi_bridge_present; then
    log "  ok  bridge $BSTACK_PI_BRIDGE"
  else
    log "  missing  bridge $BSTACK_PI_BRIDGE (bercail bstack setup)"
    missing=1
  fi
  if _bstack_pi_claude_ready; then
    log "  ok  Claude auth (claude auth status --json)"
  else
    log "  --  Claude auth: no subscription login (claude auth login)"
  fi
  for rel in "${BSTACK_PI_RENDERED[@]}" extensions/fallback.ts extensions/guard.ts extensions/review.ts \
    models fallback lead.json review.json; do
    if [[ ! -f "$BSTACK_PI_DIR/$rel" ]]; then
      log "  missing  bstack $BSTACK_PI_DIR/$rel (bercail update)"
      missing=1
    fi
  done
  for path in "$BSTACK_PI_TEMPLATES/bstack-builder.md" "$BSTACK_PI_TEMPLATES/bstack-judge.md" "$BSTACK_PI_TEMPLATES/bstack-autopilot.md"; do
    if [[ ! -f "$path" ]]; then
      log "  missing  bstack $path (bercail update)"
      missing=1
    elif ! _bstack_ours "$path"; then
      log "  yours  $path (not managed by bstack)"
    fi
  done
  local fallback
  if ! fallback="$(bstack_pi_fallback)"; then
    log "  invalid  bstack fallback (fix [bstack] fallback, then bercail update)"
    missing=1
  elif [[ -f "$BSTACK_PI_DIR/fallback" && "$fallback" != "$(<"$BSTACK_PI_DIR/fallback")" ]]; then
    log "  stale  bstack fallback (bercail update)"
    missing=1
  fi
  if [[ -f "$BSTACK_PI_DIR/models" ]] && [[ "$(_bstack_resolved_text)" != "$(<"$BSTACK_PI_DIR/models")" ]]; then
    log "  stale  bstack models (a login or model changed since the last deploy; bercail update)"
    missing=1
  fi
  for family in "${BSTACK_FAMILIES[@]}"; do
    if bstack_family_connected "$family"; then
      any_login=1
      model="$(bstack_resolve_model "$family")"
      if [[ -n "$model" ]] && ! _bstack_pi_known "$model"; then
        log "  unknown  bstack $family model $model is not in pi --list-models"
        missing=1
      fi
    else
      log "  --  bstack $family: not logged in ($(bstack_login_command "$family"))"
    fi
  done
  if [[ "$any_login" -eq 0 ]]; then
    log "  missing  bstack login: none of Claude Code, openai, xai is ready in Pi"
    missing=1
  fi
  if [[ "$missing" -eq 0 ]]; then
    log "  ok  bstack (lead=$(_bstack_pi_model_id "$(bstack_role_model lead)"))"
  fi
  return "$missing"
}

# --- deploy -------------------------------------------------------------------

# Replace @pi_dir@ with bstack's Pi profile dir.
_bstack_render() {
  awk -v pi_dir="$BSTACK_PI_DIR" '{ gsub("@pi_dir@", pi_dir); print }' "$1" >"$2"
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
  local work rel result=0
  if ! bstack_enabled; then
    remove_bstack quiet
    return 0
  fi
  bstack_pi_fallback >/dev/null || return 1
  _bstack_install_pi || return 1
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
  _bstack_deploy_pi "$work" || result=$?
  _bstack_pi_bridge_compaction "$work" || true
  rm -rf "$work"
  return "$result"
}

# Remove what deploy_bstack wrote, and only files that still carry the marker.
remove_bstack() {
  local quiet="${1:-}"
  if ! _bstack_pi_rendered_any; then
    [[ -n "$quiet" ]] || info "bstack: nothing to remove in $BSTACK_PI_DIR"
    return 0
  fi
  _bstack_remove_pi
}

# --- bercail bstack -----------------------------------------------------------

# On: the desk runs bstack's Pi lead. Off: remove bstack's files; the desk runs
# plain Pi.
bstack_on() {
  _bstack_toml_set bstack enabled true
  _bstack_install_pi || true
  deploy_bstack
}

bstack_off() {
  _bstack_toml_set bstack enabled false
  remove_bstack
  info "bstack off; the desk runs plain pi"
}

cmd_bstack() {
  local sub="${1:-status}"
  shift || true
  [[ $# -eq 0 ]] || die "unknown option: $1"
  case "$sub" in
    status) bstack_status ;;
    on) bstack_on ;;
    off) bstack_off ;;
    setup) bstack_setup ;;
    *) die "usage: bercail bstack status|on|off|setup" ;;
  esac
}
