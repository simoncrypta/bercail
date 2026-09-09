# Read agent/review/editor settings for the agentic layout plugin.
# Prefer ~/.config/bercail/config.toml, then leftover ~/.config/agentic-dev,
# then plugin config.

_agentic_layout_config_file() {
  local candidate
  for candidate in \
    "${HOME}/.config/bercail/config.toml" \
    "${HOME}/.config/agentic-dev/config.toml" \
    "${HERDR_PLUGIN_CONFIG_DIR:+$HERDR_PLUGIN_CONFIG_DIR/config.toml}"; do
    [[ -n "$candidate" && -r "$candidate" ]] && printf '%s' "$candidate" && return 0
  done
  return 1
}

_agentic_toml_value() {
  local key="$1" default="$2" config line val
  if config="$(_agentic_layout_config_file)"; then
    while IFS= read -r line; do
      line="${line%%#*}"
      line="${line#"${line%%[![:space:]]*}"}"
      [[ "$line" =~ ^${key}[[:space:]]*= ]] || continue
      val="${line#*=}"
      val="${val#"${val%%[![:space:]]*}"}"
      val="${val%"${val##*[![:space:]]}"}"
      if [[ "$val" == \"*\" ]]; then
        val="${val#\"}"
        val="${val%\"}"
      fi
      [[ -n "$val" ]] && printf '%s' "$val" && return 0
    done <"$config"
  fi
  printf '%s' "$default"
}

agentic_dev_agent_command() {
  _agentic_toml_value "command" "cursor-agent"
}

agentic_dev_default_file_editor() {
  local cmd bin
  for cmd in "${EDITOR:-}" "${VISUAL:-}"; do
    [[ -n "$cmd" ]] || continue
    printf '%s' "$cmd"
    return 0
  done
  case "$(uname -s)" in
    Darwin)
      command -v nano >/dev/null 2>&1 && { printf 'nano'; return 0; }
      printf 'vi'
      ;;
    *)
      for bin in nvim vim nano vi; do
        if command -v "$bin" >/dev/null 2>&1; then
          printf '%s' "$bin"
          return 0
        fi
      done
      printf 'vi'
      ;;
  esac
}

agentic_dev_layout_file_editor() {
  local editor
  editor="$(_agentic_toml_value "editor" "")"
  if [[ -z "$editor" ]]; then
    editor="$(_agentic_toml_value "file_editor" "")"
  fi
  if [[ -z "$editor" ]]; then
    editor="$(agentic_dev_default_file_editor)"
  fi
  printf '%s' "$editor"
}

agentic_dev_layout_review() {
  local review="$(_agentic_toml_value "review" "tuicr")"
  [[ "$review" == "hunk" ]] && review="hunk diff"
  printf '%s' "$review"
}

# Default true. Unquoted booleans in TOML; also accept quoted strings.
agentic_dev_layout_auto_review() {
  local v
  v="$(_agentic_toml_value "auto_review" "true")"
  case "$v" in
    0|false|False|FALSE|no|off) printf 'false' ;;
    *) printf 'true' ;;
  esac
}

agentic_dev_layout_agent_ratio() {
  _agentic_toml_value "agent_ratio" "0.416667"
}

agentic_dev_layout_sidebar_ratio() {
  _agentic_toml_value "sidebar_ratio" "0.166667"
}
