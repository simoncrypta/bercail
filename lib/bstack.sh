#!/usr/bin/env bash
# shellcheck shell=bash
# bstack: bercail's agent setup on Pi. Your own Claude and ChatGPT logins sit
# behind it, and bercail's workflow on top. [bstack] in config.toml maps roles to
# models.

BSTACK_MARKER="managed by bercail (bstack)"
# Paths below expand at source time. Same default as lib/common.sh: an unset
# share dir would otherwise become /pi/...
: "${BERCAIL_SHARE_DIR:=${HOME}/.local/share/bercail}"
BSTACK_FAMILIES=(claude gpt)
BSTACK_ROLES=(lead build judge)
# The Pi profile lives in bercail's share dir: Pi's own files stay the person's,
# and every launch names this dir with flags.
BSTACK_PI_DIR="${BERCAIL_SHARE_DIR}/pi"
BSTACK_PI_TEMPLATES="${XDG_CONFIG_HOME:-$HOME/.config}/herdr-core/templates"
# The bridge declares the Pi it needs (peerDependencies); pi's min in lib/deps.json follows it.
BSTACK_PI_BRIDGE="npm:pi-claude-bridge@0.12.0"
# Claude Code refuses a prompt within min(max output, 20k) + 3k tokens of the
# window, so Pi's default 16384 reserve compacts too late on the bridge. 40k
# compacts first, with room for the tool results Pi only estimates.
BSTACK_PI_BRIDGE_RESERVE=40000
# johnlindquist/pi-emphasis, vendored at the commit lib/deps.json knows
# (bstack/pi/extensions/pi-emphasis/UPSTREAM.md): pills and icons in replies.
BSTACK_PI_EMPHASIS="extensions/pi-emphasis/index.ts"
BSTACK_PI_RENDERED=(instructions.md agents/bstack-builder.md agents/bstack-judge.md
  agents/bstack-autopilot.md agents/bstack-headless.md agents/bstack-pr-review.md prompts/validate.md
  prompts/handoff.md prompts/autopilot.md prompts/how.md prompts/why.md
  prompts/unslop.md prompts/pr-review.md prompts/bstack-setup.md prompts/statechart.md)
# Templates older releases rendered: the council's seats, removed in v0.18.
BSTACK_PI_RETIRED=(bstack-council-claude bstack-council-gpt bstack-council-grok)
# Pi keys the bercail layout's Alt+Up/Down take before Pi sees them, moved.
BSTACK_PI_KEYS='{"app.message.dequeue":"alt+q","app.models.reorderUp":"shift+up","app.models.reorderDown":"shift+down"}'

# --- config.toml --------------------------------------------------------------

# shellcheck source=lib/toml.sh
source "$(dirname "${BASH_SOURCE[0]}")/toml.sh"

# The judge is GPT, a second opinion from another provider; every other role is
# Claude Opus.
_bstack_role_default() {
  case "$1" in
    judge) printf 'gpt' ;;
    *) printf 'claude' ;;
  esac
}

# The families a role is picked from at start, in order: the judge takes Claude
# when ChatGPT is not connected, and every other role takes only Claude.
_bstack_role_order() {
  case "$1" in
    judge) printf '%s\n' gpt claude ;;
    *) printf '%s\n' claude ;;
  esac
}

# Keys and values from before v0.18, when Grok and a fallback list existed:
# each one is ignored, and said so, rather than refused.
bstack_warn_old_config() {
  local role
  [[ -z "$(toml_value "$BERCAIL_USER_CONFIG" bstack grok)" ]] \
    || warn '[bstack] grok is ignored: bstack no longer uses xAI; remove it from config.toml'
  [[ -z "$(toml_value "$BERCAIL_USER_CONFIG" bstack fallback)" ]] \
    || warn '[bstack] fallback is ignored: a limited role now pauses until its limit resets; remove it from config.toml'
  for role in "${BSTACK_ROLES[@]}"; do
    [[ "$(toml_value "$BERCAIL_USER_CONFIG" bstack "$role")" != grok ]] \
      || warn "[bstack] $role = \"grok\" is ignored: $role uses $(_bstack_role_default "$role"); set it to claude or gpt"
  done
}

# A family name (claude, gpt) resolves to that family's model: the one set in
# config.toml (pinned), else bercail's pick from Pi's catalog when the login is
# ready (auto). Anything else is a full Pi model id. Empty: the agent uses Pi's
# default model.
bstack_resolve_model() {
  local spec="$1" model
  case "$spec" in
    claude|gpt) ;;
    *) printf '%s' "$spec"; return 0 ;;
  esac
  model="$(toml_value "$BERCAIL_USER_CONFIG" bstack "$spec")"
  if [[ -n "$model" ]]; then
    printf '%s' "$model"
    return 0
  fi
  bstack_family_connected "$spec" || return 0
  _bstack_pick_model "$spec" <<<"$BSTACK_MODELS" || true
}

bstack_model_source() {
  if [[ -n "$(toml_value "$BERCAIL_USER_CONFIG" bstack "$1")" ]]; then
    printf 'pinned'
  else
    printf 'auto'
  fi
}

# A role that names a family whose plan is not connected takes the next family
# in its order that has a model, so the judge runs on Claude until ChatGPT is
# connected. A full model id is used as is; grok, from older configs, is not.
bstack_role_model() {
  local role="$1" spec family model
  spec="$(toml_value "$BERCAIL_USER_CONFIG" bstack "$role")"
  [[ -n "$spec" && "$spec" != grok ]] || spec="$(_bstack_role_default "$role")"
  case "$spec" in
    claude|gpt) ;;
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
# level below it that the model offers. Without a variant list, none.
_bstack_variant() {
  local model="$1" want offered level best=""
  want="$(toml_value "$BERCAIL_USER_CONFIG" bstack effort)"
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

# Providers the fallback found dead (402, no credits, no subscription) in the
# last day, one "provider<TAB>when<TAB>model<TAB>why" line each, the latest
# per provider. fallback.ts writes the file; nothing probes the providers.
bstack_pi_dead() {
  local file="${XDG_STATE_HOME:-$HOME/.local/state}/bercail/fallback-dead.jsonl"
  [[ -s "$file" ]] || return 0
  jq -rRn '[inputs | fromjson? | objects | select(((.at // "") | sub("\\.[0-9]+Z$"; "Z") | try fromdateiso8601 catch 0) > now - 86400)]
    | group_by(.provider) | map(last) | .[] | [.provider, .at, .model, .reason] | @tsv' "$file" 2>/dev/null || true
}

# The guard's warnings and refusals in the last 7 days, from its log, as
# "<warnings>\t<refusals>\t<count>\t<most frequent reason>". Bad lines are skipped.
bstack_guard_week() {
  local file="${XDG_STATE_HOME:-$HOME/.local/state}/bercail/guard-warnings.jsonl"
  [[ -s "$file" ]] || { printf '0\t0\t0\t\n'; return 0; }
  jq -rRn '[inputs | fromjson? | objects | select(((.at // "") | sub("\\.[0-9]+Z$"; "Z") | try fromdateiso8601 catch 0) > now - 604800)]
    | ([.[] | .reasons // [] | .[] | strings] | group_by(.) | max_by(length) // []) as $top
    | [([.[] | select(.kind == "warning")] | length), ([.[] | select(.kind == "refusal")] | length),
       ($top | length), ($top[0] // "" | .[0:120])] | @tsv' "$file" 2>/dev/null || printf '0\t0\t0\t\n'
}

_bstack_pi_version_ok() {
  local v min
  v="$(pi --version 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)+' | head -1)"
  min="$(dep_min pi)"
  [[ -n "$v" && -n "$min" && "$(printf '%s\n' "$min" "$v" | sort -V | head -1)" == "$min" ]]
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
  esac
}

# Providers with a usable login, one per line. --no-refresh keeps this offline;
# never --credentials, which prints the secret.
_bstack_pi_connected_ids() {
  local provider
  dep_present pi || return 0
  _bstack_pi_claude_ready && printf '%s\n' claude-bridge
  for provider in openai openai-codex; do
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
  BSTACK_PI_ARGV+=(-e "$BSTACK_PI_BRIDGE" -e "$BSTACK_PI_DIR/extensions/fallback.ts" -e "$BSTACK_PI_DIR/extensions/guard.ts"
    -e "$BSTACK_PI_DIR/$BSTACK_PI_EMPHASIS")
  BSTACK_PI_ARGV+=(--prompt-template "$BSTACK_PI_DIR/prompts"
    --append-system-prompt "$BSTACK_PI_DIR/instructions.md")
  [[ -z "$brief" ]] || BSTACK_PI_ARGV+=(--append-system-prompt "$BSTACK_PI_DIR/agents/$brief.md")
  for id in "${BERCAIL_SKILL_IDS[@]}"; do
    BSTACK_PI_ARGV+=(--skill "$(skill_canonical_dir "$id")")
  done
  if statechart_enabled; then
    BSTACK_PI_ARGV+=(--skill "$(skill_canonical_dir statechart)")
  fi
}

# bercail review-pr's reviewer, into BSTACK_PI_ARGV: the lead's model, the
# read-only tools, and review.ts, which keeps it in the stack dir. No skills,
# prompt templates, or context files: the pr-review rules and the description
# standard are its whole brief. --no-approve: no project's .pi/ ever loads, so
# a PR's own extensions never run, whatever Pi's trust settings say.
_bstack_pi_review_argv() {
  local model="$1"
  BSTACK_PI_ARGV=(pi)
  [[ -z "$model" ]] || BSTACK_PI_ARGV+=(--model "$(_bstack_pi_model_id "$model")")
  BSTACK_PI_ARGV+=(-e "$BSTACK_PI_BRIDGE" -e "$BSTACK_PI_DIR/extensions/fallback.ts"
    -e "$BSTACK_PI_DIR/extensions/review.ts" --tools "read,grep,find,ls"
    --no-skills --no-prompt-templates --no-context-files --no-approve
    --append-system-prompt "$BSTACK_PI_DIR/agents/bstack-pr-review.md"
    --append-system-prompt "$(skill_canonical_dir describe)/standard.md")
}

# The command line a bstack agent starts with. BERCAIL_ROLE identifies its role;
# empty is the lead. `bercail scratch run` gives it a TMPDIR of its own and
# removes it when the agent exits. A packaged bercail is the one on PATH: a
# ~/.local/bin/bercail left from before may not know scratch.
bstack_pi_command() {
  local role="$1" model="$2" brief="${3:-}" bercail="$LOCAL_BIN/bercail"
  local -a argv=(env -u ANTHROPIC_API_KEY -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN)
  [[ -z "$role" ]] || argv+=("BERCAIL_ROLE=$role")
  [[ -x "$bercail" && "${BERCAIL_PACKAGED:-0}" != 1 ]] || bercail=bercail
  argv+=("$bercail" scratch run --)
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
  local work="$1" rel name
  [[ ! -d "$BSTACK_PI_DIR" ]] || run rm -rf "$BSTACK_PI_DIR"
  for rel in "${BSTACK_PI_RENDERED[@]}"; do
    _bstack_render "$work/src/pi/$rel" "$work/pi-rendered"
    copy_file "$work/pi-rendered" "$BSTACK_PI_DIR/$rel"
  done
  copy_file "$work/src/pi/extensions/fallback.ts" "$BSTACK_PI_DIR/extensions/fallback.ts"
  copy_file "$work/src/pi/extensions/provider-error.ts" "$BSTACK_PI_DIR/extensions/provider-error.ts"
  copy_file "$work/src/pi/extensions/guard.ts" "$BSTACK_PI_DIR/extensions/guard.ts"
  copy_file "$work/src/pi/extensions/review.ts" "$BSTACK_PI_DIR/extensions/review.ts"
  copy_file "$work/src/pi/$BSTACK_PI_EMPHASIS" "$BSTACK_PI_DIR/$BSTACK_PI_EMPHASIS"
  copy_file "$work/src/pi/extensions/pi-emphasis/LICENSE" "$BSTACK_PI_DIR/extensions/pi-emphasis/LICENSE"
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
    "A second opinion from another provider, read-only. It reviews; the lead decides."
  _bstack_pi_template "$work" bstack-autopilot autopilot "$(bstack_role_model lead)" bstack-autopilot \
    "Drives an open PR to green. Pushes the PR branch, never merges."
  for name in "${BSTACK_PI_RETIRED[@]}"; do
    _bstack_remove_ours "$BSTACK_PI_TEMPLATES/$name.md"
  done
  _bstack_resolved_text >"$work/resolved"
  copy_file "$work/resolved" "$BSTACK_PI_DIR/models"
  info "bstack (pi): lead=$(bstack_role_model lead || true) build=$(bstack_role_model build || true) judge=$(bstack_role_model judge || true) (empty: Pi's default model)"
}

_bstack_pi_template_paths() {
  local name
  for name in bstack-builder bstack-judge bstack-autopilot "${BSTACK_PI_RETIRED[@]}"; do
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

# Absolute, so the record names the same file from any folder.
_bstack_pi_keys_file() {
  local dir="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
  [[ "$dir" == /* ]] || dir="$PWD/$dir"
  printf '%s/keybindings.json' "$dir"
}

# What bercail added to each Pi keybindings.json it wrote, by path: whether it
# created the file, and the keys, so uninstall takes back only those.
_bstack_pi_keys_record() {
  printf '%s/bercail/pi-keybindings.json' "${XDG_STATE_HOME:-$HOME/.local/state}"
}

# FILE as one JSON object, compact, or fail: a file that is not one, such as
# two values in a row, is not one bercail edits.
_bstack_json_object() {
  jq -e -c -s 'select(length == 1 and (.[0] | type) == "object") | .[0]' "$1" 2>/dev/null
}

# Each of BSTACK_PI_KEYS goes into Pi's keybindings.json, unless the person set
# that action: theirs stays, and is said. Their other bindings are kept.
_bstack_pi_keys() {
  local work="$1" file record current='{}' prior='{}' exists=false result line
  file="$(_bstack_pi_keys_file)"
  record="$(_bstack_pi_keys_record)"
  if [[ -s "$file" ]] && ! current="$(_bstack_json_object "$file")"; then
    warn "$file is not one JSON object; set these Pi keys there by hand: $BSTACK_PI_KEYS"
    return 1
  fi
  [[ ! -e "$file" ]] || exists=true
  [[ ! -s "$record" ]] || prior="$(_bstack_json_object "$record")" || prior='{}'
  # Ours: absent, or still as bercail added it to this file. A value equal to
  # ours that bercail did not add is the person's.
  result="$(jq -c --argjson ours "$BSTACK_PI_KEYS" --argjson prior "$prior" --arg file "$file" --argjson exists "$exists" '
    . as $cur
    | ($prior[$file] // {}) as $was
    | ($was.keys // {}) as $added
    | [$ours | keys_unsorted[] as $k | select(($cur | has($k) | not) or ($added | has($k) and .[$k] == $cur[$k])) | $k] as $mine
    | {file: (reduce $mine[] as $k ($cur; .[$k] = $ours[$k])),
       record: ($prior + {($file): {created: (($was.created // false) or ($exists | not)),
         keys: (reduce $mine[] as $k ({}; .[$k] = $ours[$k]))}}),
       kept: [$ours | keys_unsorted[] as $k | select(($cur | has($k)) and ($mine | index([$k]) | not))
         | "keeping your Pi key \($k) = \($cur[$k] | tojson) in \($file) (bercail sets \($ours[$k] | tojson))"]}' \
    <<<"$current")" || return 1
  if [[ "$(jq -c '.file' <<<"$result")" == "$current" ]]; then
    info "unchanged: $file"
  else
    jq '.file' <<<"$result" >"$work/pi-keybindings.json"
    copy_file "$work/pi-keybindings.json" "$file" || return 1
  fi
  jq '.record' <<<"$result" >"$work/pi-keys-record.json"
  copy_file "$work/pi-keys-record.json" "$record" >/dev/null
  while IFS= read -r line; do info "$line"; done < <(jq -r '.kept[]' <<<"$result")
}

# Take back, from each file in the record, the keys bercail added there that the
# person has not changed since. A file bercail created and left empty goes.
_bstack_remove_pi_keys() {
  local record entries file entry left
  record="$(_bstack_pi_keys_record)"
  [[ -f "$record" ]] || return 0
  entries="$(_bstack_json_object "$record")" || entries='{}'
  while IFS= read -r -d '' file; do
    entry="$(jq -c --arg f "$file" '.[$f]' <<<"$entries")"
    [[ -f "$file" ]] && left="$(_bstack_json_object "$file")" || continue
    left="$(jq -c --argjson e "$entry" '
      reduce ($e.keys // {} | to_entries[]) as $k (.; if .[$k.key] == $k.value then del(.[$k.key]) else . end)' <<<"$left")" \
      || continue
    [[ "$left" != "$(_bstack_json_object "$file")" ]] || continue
    info "remove: bercail's Pi keys from $file"
    if [[ "$left" == '{}' && "$(jq -r '.created? // false' <<<"$entry")" == true ]]; then
      run rm -f "$file"
    elif [[ "$DRY_RUN" -ne 1 ]]; then
      jq . <<<"$left" >"$file"
    fi
  done < <(jq -j 'keys[] | . + "\u0000"' <<<"$entries")
  run rm -f "$record"
}

# Install Pi and the Claude bridge.
_bstack_install_pi() {
  maybe_mise_install pi pi || return 1
  _bstack_pi_version_ok || { warn "bstack needs Pi >=$(dep_min pi)"; return 1; }
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
  log "bstack:"
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
  log "  on a limit: a role pauses until it resets, then goes on with the same model; the judge has Claude stand in while GPT is limited"
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
  log "  config: [bstack] in $BERCAIL_USER_CONFIG (auto picks the newest model; set claude/gpt to pin a Pi id)"
  bstack_warn_old_config
}

# Guided: install Pi and the bridge, then render the agents. Models are picked
# automatically (auto); a model set in config.toml stays.
bstack_setup() {
  bstack_load_state reload
  log "bstack setup: Pi, with your own Claude and ChatGPT logins."
  _bstack_install_pi || die "bstack on Pi needs pi; install it (mise use -g pi), then run: bercail bstack setup"
  deploy_bstack
  bstack_status
  log ""
  log "next: run claude auth login for Claude; type the /login lines above in pi for other missing logins, then run: bercail update"
}

doctor_bstack() {
  local rel missing=0 path family any_login=0 model
  bstack_load_state reload
  if ! dep_present pi; then
    log "  missing  pi (bercail bstack setup)"
    return 1
  fi
  if _bstack_pi_version_ok; then
    log "  ok  pi $(pi --version 2>/dev/null)"
  else
    log "  old  pi $(pi --version 2>/dev/null) (bstack needs >=$(dep_min pi))"
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
  for rel in "${BSTACK_PI_RENDERED[@]}" extensions/fallback.ts extensions/provider-error.ts extensions/guard.ts extensions/review.ts \
    "$BSTACK_PI_EMPHASIS" models lead.json review.json; do
    if [[ ! -f "$BSTACK_PI_DIR/$rel" ]]; then
      log "  missing  bstack $BSTACK_PI_DIR/$rel (bercail update)"
      missing=1
    fi
  done
  if [[ -f "$BSTACK_PI_DIR/$BSTACK_PI_EMPHASIS" ]]; then
    log "  ok  pi-emphasis $(jq -r '.[] | select(.name == "pi-emphasis") | .known[0:12]' "$BERCAIL_DEPS_JSON" 2>/dev/null) (reply pills and icons)"
  fi
  for path in "$BSTACK_PI_TEMPLATES/bstack-builder.md" "$BSTACK_PI_TEMPLATES/bstack-judge.md" "$BSTACK_PI_TEMPLATES/bstack-autopilot.md"; do
    if [[ ! -f "$path" ]]; then
      log "  missing  bstack $path (bercail update)"
      missing=1
    elif ! _bstack_ours "$path"; then
      log "  yours  $path (not managed by bstack)"
    fi
  done
  local provider at why
  while IFS=$'\t' read -r provider at model why; do
    log "  dead  bstack $provider ($model) at $at: $why (add credits or a subscription)"
  done < <(bstack_pi_dead)
  local warnings refusals times top
  IFS=$'\t' read -r warnings refusals times top < <(bstack_guard_week)
  if ((warnings + refusals == 0)); then
    log "  ok  guard: no warnings or refusals in the last 7 days"
  else
    log "  guard  $warnings warning(s) and $refusals refusal(s) in the last 7 days; most often ($times): $top"
    log "        (jq . ${XDG_STATE_HOME:-$HOME/.local/state}/bercail/guard-warnings.jsonl)"
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
    log "  missing  bstack login: none of Claude Code, openai is ready in Pi"
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
  local work result=0
  bstack_warn_old_config
  _bstack_install_pi || return 1
  bstack_load_state reload
  work="$(mktemp -d)"
  if ! cp -R "$(install_src_dir)/bstack" "$work/src"; then
    warn "could not read bstack/ from $(install_src_dir)"
    rm -rf "$work"
    return 1
  fi
  _bstack_deploy_pi "$work" || result=$?
  _bstack_pi_bridge_compaction "$work" || true
  _bstack_pi_keys "$work" || true
  rm -rf "$work"
  return "$result"
}

# Remove what deploy_bstack wrote: files that still carry the marker, and the
# Pi keys it added that are still as it set them.
remove_bstack() {
  _bstack_remove_pi_keys
  if ! _bstack_pi_rendered_any; then
    info "bstack: nothing to remove in $BSTACK_PI_DIR"
    return 0
  fi
  _bstack_remove_pi
}

# --- bercail bstack -----------------------------------------------------------

cmd_bstack() {
  local sub="${1:-status}"
  shift || true
  [[ $# -eq 0 ]] || die "unknown option: $1"
  case "$sub" in
    status) bstack_status ;;
    setup) bstack_setup ;;
    *) die "usage: bercail bstack status|setup" ;;
  esac
}
