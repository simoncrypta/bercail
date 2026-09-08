# Read ~/.config/bercail/config.toml (or leftover ~/.config/agentic-dev).

_agentic_dev_user_config() {
  local candidate
  for candidate in \
    "${HOME}/.config/bercail/config.toml" \
    "${HOME}/.config/agentic-dev/config.toml"; do
    if [[ -r "$candidate" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

agentic_dev_agent_command() {
  local config=""
  config="$(_agentic_dev_user_config)" || config=""
  local cmd="cursor-agent"
  if [[ -r "$config" ]]; then
    cmd="$(awk -F'"' '/^command[[:space:]]*=/ { print $2; exit }' "$config")"
  fi
  printf '%s' "${cmd:-cursor-agent}"
}

# EDITOR/VISUAL first (Linux Omarchy uses e.g. "omarchy-launch-editor --inline").
# macOS often has no EDITOR; nano is the stock terminal editor, then vi.
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
  local config="" editor=""
  config="$(_agentic_dev_user_config)" || config=""
  if [[ -n "$config" && -r "$config" ]]; then
    editor="$(awk -F'"' '/^editor[[:space:]]*=/ { print $2; exit }' "$config")"
    if [[ -z "$editor" ]]; then
      editor="$(awk -F'"' '/^file_editor[[:space:]]*=/ { print $2; exit }' "$config")"
    fi
  fi
  [[ -n "$editor" ]] || editor="$(agentic_dev_default_file_editor)"
  printf '%s' "$editor"
}

agentic_dev_layout_editor() {
  agentic_dev_layout_file_editor
}

agentic_dev_layout_review() {
  local config="" review="hunk diff"
  config="$(_agentic_dev_user_config)" || config=""
  if [[ -n "$config" && -r "$config" ]]; then
    local from_config
    from_config="$(awk -F'"' '/^review[[:space:]]*=/ { print $2; exit }' "$config")"
    [[ -n "$from_config" ]] && review="$from_config"
  fi
  [[ "$review" == "hunk" ]] && review="hunk diff"
  printf '%s' "$review"
}

agentic_dev_layout_auto_review() {
  local config="" v="true" line val
  config="$(_agentic_dev_user_config)" || config=""
  if [[ -n "$config" && -r "$config" ]]; then
    while IFS= read -r line; do
      line="${line%%#*}"
      [[ "$line" =~ ^auto_review[[:space:]]*= ]] || continue
      val="${line#*=}"
      val="${val#"${val%%[![:space:]]*}"}"
      val="${val%"${val##*[![:space:]]}"}"
      val="${val#\"}"
      val="${val%\"}"
      [[ -n "$val" ]] && v="$val"
      break
    done <"$config"
  fi
  case "$v" in
    0|false|False|FALSE|no|off) printf 'false' ;;
    *) printf 'true' ;;
  esac
}
