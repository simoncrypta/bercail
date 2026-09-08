# bercail shell integration (zsh)
# Managed by bercail — do not edit; use ~/.config/bercail/config.toml

source "${HOME}/.config/bercail/shell/bercail.inc.sh"

if command -v wt >/dev/null 2>&1; then
  eval "$(command wt config shell init zsh)"
fi
