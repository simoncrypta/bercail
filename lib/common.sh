#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2034 # the constants below are read by the libs sourced after this file
set -euo pipefail

BERCAIL_VERSION="0.14.0"
BERCAIL_MARKER_START="# >>> bercail"
BERCAIL_MARKER_END="# <<< bercail"

BERCAIL_CONFIG_DIR="${HOME}/.config/bercail"
BERCAIL_SHELL_DIR="${BERCAIL_CONFIG_DIR}/shell"
BERCAIL_USER_CONFIG="${BERCAIL_CONFIG_DIR}/config.toml"
HERDR_APP_CONFIG_DIR="${HERDR_APP_CONFIG_DIR:-${HOME}/.config/herdr-app}"
WORKTRUNK_CONFIG_DIR="${HOME}/.config/worktrunk"
OMARCHY_POST_UPDATE_HOOK="${HOME}/.config/omarchy/hooks/post-update.d/bercail.hook"
OMARCHY_POST_BOOT_HOOK="${HOME}/.config/omarchy/hooks/post-boot.d/bercail-desk-restore.hook"
LOCAL_BIN="${HOME}/.local/bin"
# Canonical skill install per Agent Skills (https://agentskills.io): ~/.agents/skills.
AGENTS_SKILLS_DIR="${HOME}/.agents/skills"
BERCAIL_SKILL_IDS=(handoff review bstack council autopilot how why unslop desk-restore unit-testing)

skill_canonical_dir() {
  printf '%s/%s' "$AGENTS_SKILLS_DIR" "$1"
}
BERCAIL_SHARE_DIR="${HOME}/.local/share/bercail"
BERCAIL_SOURCE_PATH_FILE="${BERCAIL_SHARE_DIR}/source-path"

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
  # /dev/tty can exist without a terminal behind it (no controlling tty).
  if [[ -r /dev/tty ]] && { read -r "${__var?}" </dev/tty; } 2>/dev/null; then
    return 0
  fi
  read -r "${__var?}"
}

confirm() {
  local prompt="$1"
  if [[ "$YES" -eq 1 ]]; then
    return 0
  fi
  # Set by the Omarchy post-update hook: nobody is there to answer, so take
  # the default (no) instead of waiting on the update terminal.
  if [[ "${BERCAIL_NO_PROMPT:-0}" == 1 ]]; then
    info "not asking, answering no: $prompt"
    return 1
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
  # The installed CLI (~/.local/share/bercail/lib) is not a tree: use the clone or
  # release it was installed from, so files it added are found before a release has them.
  if [[ -f "$BERCAIL_SOURCE_PATH_FILE" ]]; then
    dir="$(<"$BERCAIL_SOURCE_PATH_FILE")"
    if [[ -n "$dir" && -f "$dir/install.sh" && -d "$dir/config" ]]; then
      printf '%s' "$dir"
      return 0
    fi
  fi
  printf '%s' "https://bercail.dev"
}

# Remote install assets (config/, bin/, skills/) come from GitHub raw, all from
# one commit: GITHUB_RAW_BASE, else BERCAIL_REF (a tag, branch, or sha), else the
# latest release. Never master by default: master is unreleased trunk. Sets
# GITHUB_RAW_BASE, so call it outside $(...) to resolve once per run.
resolve_github_raw_base() {
  [[ -z "${GITHUB_RAW_BASE:-}" ]] || return 0
  local ref="${BERCAIL_REF:-}" url
  if [[ -z "$ref" ]]; then
    # github.com redirects /releases/latest to the tag: no API token, no jq.
    url="$(curl -fsSI -o /dev/null -w '%{redirect_url}' https://github.com/simoncrypta/bercail/releases/latest 2>/dev/null)" || url=""
    ref="${url##*/releases/tag/}"
    if [[ "$ref" != v* || "$ref" == */* ]]; then
      warn "cannot find the latest bercail release on github.com; retry, or pick one with BERCAIL_REF=<tag>"
      return 1
    fi
  fi
  GITHUB_RAW_BASE="https://raw.githubusercontent.com/simoncrypta/bercail/$ref"
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
  resolve_github_raw_base || return 1
  local url
  url="${GITHUB_RAW_BASE%/}/$rel"
  info "download: $url"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi
  curl -fsSL "$url" -o "$dest"
}
