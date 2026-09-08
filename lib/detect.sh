#!/usr/bin/env bash
# shellcheck shell=bash

detect_os() {
  case "$(uname -s)" in
    Darwin) printf 'macos' ;;
    Linux) printf 'linux' ;;
    *) printf 'unknown' ;;
  esac
}

detect_linux_distro() {
  [[ "$(detect_os)" == "linux" ]] || return 0
  if [[ -r /etc/os-release ]]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    case "${ID:-}" in
      ubuntu) printf 'ubuntu' ;;
      debian) printf 'debian' ;;
      arch) printf 'arch' ;;
      *) printf '%s' "${ID:-linux}" ;;
    esac
    return 0
  fi
  printf 'unknown'
}

detect_platform() {
  local os distro
  os="$(detect_os)"
  if [[ "$os" == "linux" ]]; then
    distro="$(detect_linux_distro)"
    printf '%s/%s/%s' "$os" "$distro" "$(detect_arch)"
    return 0
  fi
  printf '%s/%s' "$os" "$(detect_arch)"
}

is_ubuntu() {
  [[ "$(detect_linux_distro)" == "ubuntu" ]]
}

is_debian() {
  [[ "$(detect_linux_distro)" == "debian" ]]
}

has_apt() {
  command -v apt-get >/dev/null 2>&1
}

has_hyprland() {
  [[ -f "${HOME}/.config/hypr/hyprland.lua" \
    || -f "${HOME}/.config/hypr/bindings.lua" \
    || -f "${HOME}/.config/hypr/hyprland.conf" \
    || -f "${HOME}/.config/hypr/bindings.conf" ]]
}

detect_arch() {
  uname -m
}

detect_shell_name() {
  basename "${SHELL:-/bin/bash}"
}

is_omarchy() {
  [[ -d "${HOME}/.local/share/omarchy" ]] && return 0
  [[ -n "${OMARCHY_PATH:-}" && -d "$OMARCHY_PATH" ]] && return 0
  command -v omarchy >/dev/null 2>&1 && return 0
  [[ -x /usr/share/omarchy/bin/omarchy ]]
}

has_mise() {
  command -v mise >/dev/null 2>&1
}

has_brew() {
  command -v brew >/dev/null 2>&1
}

brew_shellenv_snippet() {
  if [[ -x /opt/homebrew/bin/brew ]]; then
    printf '%s\n' 'eval "$(/opt/homebrew/bin/brew shellenv)"'
  elif [[ -x /usr/local/bin/brew ]]; then
    printf '%s\n' 'eval "$(/usr/local/bin/brew shellenv)"'
  elif [[ -x /home/linuxbrew/.linuxbrew/bin/brew ]]; then
    printf '%s\n' 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"'
  fi
}

has_marker_block() {
  local file="$1"
  [[ -f "$file" ]] || return 1
  grep -qF "$AGENTIC_DEV_MARKER_START" "$file" \
    || grep -qF "$LEGACY_AGENTIC_DEV_MARKER_START" "$file"
}

shell_rc_for() {
  local shell_name="$1"
  case "$shell_name" in
    zsh) printf '%s' "${HOME}/.zshrc" ;;
    bash) printf '%s' "${HOME}/.bashrc" ;;
    *) printf '%s' "${HOME}/.${shell_name}rc" ;;
  esac
}

detect_conflicts() {
  local rc="$1"
  [[ -f "$rc" ]] || return 0
  local conflicts=()
  if grep -qE 'worktree-dev\(\)|function worktree-dev' "$rc" \
    && ! grep -qF "$AGENTIC_DEV_MARKER_START" "$rc"; then
    conflicts+=("existing worktree-dev() outside agentic-dev marker")
  fi
  if grep -q 'source.*herdr-layout\.sh' "$rc" \
    && ! grep -qF "$AGENTIC_DEV_MARKER_START" "$rc"; then
    conflicts+=("existing herdr-layout.sh source outside agentic-dev marker")
  fi
  if ((${#conflicts[@]} > 0)); then
    printf '%s\n' "${conflicts[@]}"
    return 1
  fi
  return 0
}
