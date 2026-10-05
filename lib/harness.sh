#!/usr/bin/env bash
# shellcheck shell=bash
# Optional harness discovery. Missing CLIs are reported, not fatal.
# No preference among claude, codex, and cursor-agent.
# Do not call claude/codex/cursor-agent in a way that hits the network.

harness_ids() {
  printf '%s\n' claude codex cursor-agent
}

harness_path() {
  local name="$1" bin
  bin="$(command -v "$name" 2>/dev/null || true)"
  [[ -n "$bin" ]] || return 1
  printf '%s' "$bin"
}

# Local Claude catalog only (same cache handoff_resolve_model reads).
harness_claude_catalog_file() {
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

harness_claude_models_json() {
  local catalog id
  catalog="$(harness_claude_catalog_file 2>/dev/null || true)"
  if [[ -n "$catalog" ]]; then
    id="$(jq -r '
      .catalog.config.models[]?
      | select(.name == "Opus 5.5")
      | .id
      | select(endswith("-max") | not)
    ' "$catalog" 2>/dev/null | awk 'NF { print; exit }')"
    if [[ -z "$id" || "$id" == null ]]; then
      id="$(jq -r '
        .catalog.config.models[]?
        | .id
        | select(startswith("claude-opus"))
        | select(endswith("-max") | not)
      ' "$catalog" 2>/dev/null | awk 'NF { print; exit }')"
    fi
    if [[ -n "$id" && "$id" != null ]]; then
      jq -nc --arg id "$id" '[$id]'
      return 0
    fi
  fi
  # claude --help documents the alias "opus"; it does not list full ids.
  jq -nc '["opus"]'
}

# Top-level model = "..." in config.toml. No Codex CLI invocation.
harness_codex_models_json() {
  local cfg="${CODEX_HOME:-$HOME/.codex}/config.toml" id
  if [[ -f "$cfg" ]]; then
    id="$(awk -F '"' '/^[[:space:]]*model[[:space:]]*=/ { print $2; exit }' "$cfg")"
    if [[ -n "$id" ]]; then
      jq -nc --arg id "$id" '[$id]'
      return 0
    fi
  fi
  jq -nc '[]'
}

# cursor-agent --list-models hits the network. Do not run it.
harness_cursor_models_json() {
  jq -nc '[]'
}

harness_one_json() {
  local id="$1" path present=false models
  path="$(harness_path "$id" || true)"
  if [[ -n "$path" ]]; then
    present=true
  else
    path=""
  fi
  case "$id" in
    claude)
      if [[ "$present" == true ]]; then
        models="$(harness_claude_models_json)"
      else
        models='[]'
      fi
      ;;
    codex)
      if [[ "$present" == true ]]; then
        models="$(harness_codex_models_json)"
      else
        models='[]'
      fi
      ;;
    cursor-agent)
      models="$(harness_cursor_models_json)"
      ;;
    *)
      models='[]'
      ;;
  esac
  jq -nc \
    --arg id "$id" \
    --argjson present "$present" \
    --arg path "$path" \
    --argjson models "$models" \
    '{id:$id, present:$present, path:(if $path == "" then null else $path end), model_hint:($models[0] // null)}'
}

# Always exits 0. Missing harnesses are rows with present:false.
# Reports only. Bercail does not choose a harness; the caller names one.
harness_discover_json() {
  command -v jq >/dev/null 2>&1 || {
    printf 'bercail: jq is required for harness discovery\n' >&2
    return 1
  }
  local rows='[]' id one
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    one="$(harness_one_json "$id")"
    rows="$(jq -nc --argjson rows "$rows" --argjson one "$one" '$rows + [$one]')"
  done < <(harness_ids)
  jq -nc --argjson harnesses "$rows" '{ok:true, harnesses:$harnesses}'
}

cmd_harness() {
  harness_discover_json
  printf '\n'
}
