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
BERCAIL_SKILL_IDS=(handoff review bstack council autopilot how why unslop desk-restore unit-testing describe)

skill_canonical_dir() {
  printf '%s/%s' "$AGENTS_SKILLS_DIR" "$1"
}
BERCAIL_SHARE_DIR="${HOME}/.local/share/bercail"
BERCAIL_SOURCE_PATH_FILE="${BERCAIL_SHARE_DIR}/source-path"
# The tree a curl install deploys from: its release, unpacked (fetch_release_tree).
BERCAIL_RELEASE_DIR="${BERCAIL_SHARE_DIR}/release"
# The libs every command loads after this file, in order, for install.sh and
# bin/bercail. The others (review.sh, policy.sh, ...) load with their command.
BERCAIL_LIBS=(detect deps config skills shell-rc uninstall help omarchy notify doctor bstack desk shep)

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
  printf '%s' "$BERCAIL_RELEASE_DIR"
}

# A curl install's files come from one commit, as one archive: BERCAIL_ARCHIVE_URL,
# else BERCAIL_REF (a tag, branch, or sha), else the latest release. Never master
# by default: master is unreleased trunk. Unpacks it over BERCAIL_RELEASE_DIR.
fetch_release_tree() {
  local ref="${BERCAIL_REF:-}" url tmp
  if [[ -z "${BERCAIL_ARCHIVE_URL:-}" && -z "$ref" ]]; then
    # github.com redirects /releases/latest to the tag: no API token, no jq.
    url="$(curl -fsSI -o /dev/null -w '%{redirect_url}' https://github.com/simoncrypta/bercail/releases/latest 2>/dev/null)" || url=""
    ref="${url##*/releases/tag/}"
    if [[ "$ref" != v* || "$ref" == */* ]]; then
      warn "cannot find the latest bercail release on github.com; retry, or pick one with BERCAIL_REF=<tag>"
      return 1
    fi
  fi
  url="${BERCAIL_ARCHIVE_URL:-https://github.com/simoncrypta/bercail/archive/$ref.tar.gz}"
  info "download: $url"
  ensure_dir "$BERCAIL_SHARE_DIR"
  # Beside the tree it replaces, so a failed download leaves that one whole.
  tmp="$(mktemp -d "$BERCAIL_SHARE_DIR/release.XXXXXX")"
  if ! curl -fsSL "$url" -o "$tmp/archive.tar.gz" \
    || ! tar -xzf "$tmp/archive.tar.gz" -C "$tmp" --strip-components=1; then
    rm -rf "$tmp"
    warn "could not download bercail from $url; retry, or pick a release with BERCAIL_REF=<tag>"
    return 1
  fi
  # A whole tree whose own update unpacks archives. v0.14.0 and older record this
  # dir as a clone and never download again; install.sh checks the same.
  if [[ ! -f "$tmp/install.sh" || ! -f "$tmp/bin/bercail" || ! -d "$tmp/config" || ! -d "$tmp/skills" || ! -d "$tmp/bstack" ]] \
    || ! grep -q '^BERCAIL_LIBS=' "$tmp/lib/common.sh" 2>/dev/null; then
    rm -rf "$tmp"
    warn "$url is not a bercail release that updates from an archive (v0.14.0 and older are not); install an older one with its own install.sh: curl -fsSL https://raw.githubusercontent.com/simoncrypta/bercail/<tag>/install.sh | BERCAIL_REF=<tag> bash"
    return 1
  fi
  rm -rf "$tmp/archive.tar.gz" "$BERCAIL_RELEASE_DIR"
  mv "$tmp" "$BERCAIL_RELEASE_DIR"
}
