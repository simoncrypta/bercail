# shellcheck shell=bash
# Read ~/.config/bercail/config.toml.

bercail_layout_review() {
  local config="${HOME}/.config/bercail/config.toml" review="tuicr"
  if [[ -r "$config" ]]; then
    local from_config
    from_config="$(awk -F'"' '/^review[[:space:]]*=/ { print $2; exit }' "$config")"
    [[ -n "$from_config" ]] && review="$from_config"
  fi
  [[ "$review" == "hunk" ]] && review="hunk diff"
  printf '%s' "$review"
}
