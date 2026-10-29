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

agentic_dev_layout_review() {
  local config="" review="tuicr"
  config="$(_agentic_dev_user_config)" || config=""
  if [[ -n "$config" && -r "$config" ]]; then
    local from_config
    from_config="$(awk -F'"' '/^review[[:space:]]*=/ { print $2; exit }' "$config")"
    [[ -n "$from_config" ]] && review="$from_config"
  fi
  [[ "$review" == "hunk" ]] && review="hunk diff"
  printf '%s' "$review"
}
