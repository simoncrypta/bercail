#!/usr/bin/env bash
# shellcheck shell=bash

marker_block_content() {
  local shell_name="$1"
  local brew_env=""
  if brew_line="$(brew_shellenv_snippet 2>/dev/null)"; then
    brew_env="${brew_line}"$'\n'
  fi
  case "$shell_name" in
    zsh)
      cat <<EOF
${AGENTIC_DEV_MARKER_START} v${AGENTIC_DEV_VERSION}
${brew_env}export PATH="\$HOME/.local/bin:\$PATH"
source "\$HOME/.config/bercail/shell/bercail.zsh"
${AGENTIC_DEV_MARKER_END}
EOF
      ;;
    bash|*)
      cat <<EOF
${AGENTIC_DEV_MARKER_START} v${AGENTIC_DEV_VERSION}
${brew_env}export PATH="\$HOME/.local/bin:\$PATH"
source "\$HOME/.config/bercail/shell/bercail.sh"
${AGENTIC_DEV_MARKER_END}
EOF
      ;;
  esac
}

upsert_marker_block() {
  local rc="$1" shell_name="$2"
  local tmp content
  content="$(marker_block_content "$shell_name")"
  ensure_dir "$(dirname "$rc")"
  touch "$rc"

  if has_marker_block "$rc"; then
    info "amending marker block in $rc"
    if [[ "$DRY_RUN" -eq 1 ]]; then
      return 0
    fi
    tmp="$(mktemp)"
    awk -v start="$AGENTIC_DEV_MARKER_START" -v end="$AGENTIC_DEV_MARKER_END" \
        -v lstart="$LEGACY_AGENTIC_DEV_MARKER_START" -v lend="$LEGACY_AGENTIC_DEV_MARKER_END" '
      $0 ~ start || $0 ~ lstart { skip=1 }
      !skip { print }
      $0 ~ end || $0 ~ lend { skip=0 }
    ' "$rc" >"$tmp"
    printf '\n%s\n' "$content" >>"$tmp"
    mv "$tmp" "$rc"
  else
    info "adding marker block to $rc"
    if [[ "$DRY_RUN" -eq 1 ]]; then
      return 0
    fi
    printf '\n%s\n' "$content" >>"$rc"
  fi
}

remove_marker_block() {
  local rc="$1"
  [[ -f "$rc" ]] || return 0
  if ! has_marker_block "$rc"; then
    return 0
  fi
  info "removing marker block from $rc"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi
  local tmp
  tmp="$(mktemp)"
  awk -v start="$AGENTIC_DEV_MARKER_START" -v end="$AGENTIC_DEV_MARKER_END" \
      -v lstart="$LEGACY_AGENTIC_DEV_MARKER_START" -v lend="$LEGACY_AGENTIC_DEV_MARKER_END" '
    $0 ~ start || $0 ~ lstart { skip=1; next }
    $0 ~ end || $0 ~ lend { skip=0; next }
    !skip { print }
  ' "$rc" >"$tmp"
  mv "$tmp" "$rc"
}

install_shell_integration() {
  local primary
  primary="$(detect_shell_name)"
  local rc conflicts
  rc="$(shell_rc_for "$primary")"

  if ! conflicts="$(detect_conflicts "$rc")"; then
    warn "conflicts in $rc:"
    while IFS= read -r line; do
      [[ -n "$line" ]] && warn "  - $line"
    done <<< "$conflicts"
    if [[ "$FORCE" -ne 1 ]]; then
      warn "skipping shell integration (use: bercail update --force)"
      return 1
    fi
  fi

  upsert_marker_block "$rc" "$primary"

  if [[ "$DRY_RUN" -eq 1 || "$YES" -eq 1 ]]; then
    return 0
  fi

  if [[ "$primary" != "bash" && -f "${HOME}/.bashrc" ]]; then
    if confirm "Also install bash integration (~/.bashrc)?"; then
      upsert_marker_block "${HOME}/.bashrc" "bash"
    fi
  fi
  if [[ "$primary" != "zsh" && -f "${HOME}/.zshrc" ]]; then
    if confirm "Also install zsh integration (~/.zshrc)?"; then
      upsert_marker_block "${HOME}/.zshrc" "zsh"
    fi
  fi
}
