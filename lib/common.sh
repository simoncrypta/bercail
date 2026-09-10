#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

AGENTIC_DEV_VERSION="${AGENTIC_DEV_VERSION:-0.5.2}"
AGENTIC_DEV_MARKER_START="# >>> bercail"
AGENTIC_DEV_MARKER_END="# <<< bercail"
LEGACY_AGENTIC_DEV_MARKER_START="# >>> agentic-dev-setup"
LEGACY_AGENTIC_DEV_MARKER_END="# <<< agentic-dev-setup"

AGENTIC_DEV_CONFIG_DIR="${HOME}/.config/bercail"
AGENTIC_DEV_SHELL_DIR="${AGENTIC_DEV_CONFIG_DIR}/shell"
AGENTIC_DEV_USER_CONFIG="${AGENTIC_DEV_CONFIG_DIR}/config.toml"
LEGACY_AGENTIC_DEV_CONFIG_DIR="${HOME}/.config/agentic-dev"
HERDR_CONFIG_DIR="${HOME}/.config/herdr"
# Legacy local-link path retained only for migrating pre-v0.2.0 installs.
HERDR_DEV_LAYOUT_LEGACY_DIR="${HERDR_CONFIG_DIR}/plugins/dev-layout"
WORKTRUNK_CONFIG_DIR="${HOME}/.config/worktrunk"
FCITX5_CONFIG_DIR="${HOME}/.config/fcitx5"
LOCAL_BIN="${HOME}/.local/bin"
PLUGIN_ID="agentic-dev.layout"
LEGACY_LAYOUT_PLUGIN_ID="agentic-dev.dev-layout"
# Canonical skill install per Agent Skills (https://agentskills.io): ~/.agents/skills.
AGENTS_SKILLS_DIR="${HOME}/.agents/skills"
AGENTIC_DEV_SKILL_IDS=(handoff review)
# First skill kept as a convenience alias (tests, summary, uninstall prompt).
AGENTIC_DEV_SKILL_ID="${AGENTIC_DEV_SKILL_IDS[0]}"
AGENTIC_DEV_SKILL_DIR="${AGENTS_SKILLS_DIR}/${AGENTIC_DEV_SKILL_ID}"

skill_canonical_dir() {
  printf '%s/%s' "$AGENTS_SKILLS_DIR" "$1"
}
AGENTIC_DEV_SHARE_DIR="${HOME}/.local/share/bercail"
AGENTIC_DEV_SOURCE_PATH_FILE="${AGENTIC_DEV_SHARE_DIR}/source-path"
LEGACY_AGENTIC_DEV_SHARE_DIR="${HOME}/.local/share/agentic-dev"

DRY_RUN=0
YES=0
FORCE=0
RECONFIGURE=0

log() { printf '%s\n' "$*"; }
info() { printf '→ %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "[dry-run] $*"
  else
    "$@"
  fi
}

# Read a line from the controlling terminal so prompts work when the
# installer is fed via `curl ... | bash` (stdin is the pipe, not the TTY).
read_tty() {
  local __var="$1"
  if [[ -r /dev/tty ]]; then
    read -r "$__var" </dev/tty
  else
    read -r "$__var"
  fi
}

confirm() {
  local prompt="$1"
  if [[ "$YES" -eq 1 ]]; then
    return 0
  fi
  printf '%s [y/N] ' "$prompt"
  local reply
  read_tty reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

ensure_dir() {
  run mkdir -p "$1"
}

copy_file() {
  local src="$1" dest="$2"
  ensure_dir "$(dirname "$dest")"
  if [[ -f "$dest" ]] && cmp -s "$src" "$dest" 2>/dev/null; then
    info "unchanged: $dest"
    return 0
  fi
  info "install: $dest"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "[dry-run] cp $src -> $dest"
    return 0
  fi
  cp "$src" "$dest"
}

script_dir() {
  local src="${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}"
  while [[ -L "$src" ]]; do
    local dir
    dir="$(cd -P "$(dirname "$src")" && pwd)"
    src="$(readlink "$src")"
    [[ "$src" != /* ]] && src="$dir/$src"
  done
  cd -P "$(dirname "$src")" && pwd
}

install_src_dir() {
  if [[ -n "${INSTALL_SRC:-}" ]]; then
    printf '%s' "$INSTALL_SRC"
    return 0
  fi
  local dir
  dir="$(cd "$(script_dir)/.." && pwd)"
  if [[ -f "$dir/install.sh" && -d "$dir/config" ]]; then
    printf '%s' "$dir"
    return 0
  fi
  printf '%s' "https://setup.simoncrypta.dev"
}

# Remote install assets (config/, bin/, plugins/) come from GitHub raw.
# The CDN only hosts install.sh + lib/ for bootstrap.
github_raw_base() {
  printf '%s' "${GITHUB_RAW_BASE:-https://raw.githubusercontent.com/simoncrypta/agentic-dev-setup/master}"
}

fetch_file() {
  local rel="$1" dest="$2"
  local base
  base="$(install_src_dir)"
  if [[ -d "$base" ]]; then
    copy_file "$base/$rel" "$dest"
    return 0
  fi
  ensure_dir "$(dirname "$dest")"
  local url
  url="$(github_raw_base)/$rel"
  info "download: $url"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi
  curl -fsSL "$url" -o "$dest"
}
