#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2034 # the constants below are read by the libs sourced after this file
set -euo pipefail

BERCAIL_VERSION="0.18.0"
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
BERCAIL_SKILL_IDS=(handoff bstack autopilot how why unslop desk-restore unit-testing describe)

skill_canonical_dir() {
  printf '%s/%s' "$AGENTS_SKILLS_DIR" "$1"
}
BERCAIL_SHARE_DIR="${HOME}/.local/share/bercail"
BERCAIL_SOURCE_PATH_FILE="${BERCAIL_SHARE_DIR}/source-path"
# "client" on a client install: only the Herdr app half is here, and the machine
# [herdr] backend names runs the rest. It keeps a later update client-only.
BERCAIL_INSTALL_MODE_FILE="${BERCAIL_SHARE_DIR}/install-mode"
# The tree a curl install deploys from: its release, unpacked (fetch_release_tree).
BERCAIL_RELEASE_DIR="${BERCAIL_SHARE_DIR}/release"
# The libs every command loads after this file, in order, for install.sh and
# bin/bercail. The others (review.sh, policy.sh, ...) load with their command.
BERCAIL_LIBS=(detect deps config skills shell-rc uninstall help omarchy notify doctor bstack desk pi-code shep)

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

# Readies DIR for a deploy that copies RELS into it, as the remove-and-copy it
# replaces did: every link goes (DIR itself included), and every other file,
# then the folders left empty, one where a file of RELS goes among them. A
# plain file of RELS stays, so copy_file leaves it alone when its content does
# not change, and its mtime says when that content arrived (lib/pi-code.sh).
prune_for_deploy() {
  local dir="$1" rel file
  local -A keep=()
  shift
  [[ ! -L "$dir" ]] || run rm -f "$dir"
  [[ -d "$dir" ]] || return 0
  for rel in "$@"; do keep["$dir/$rel"]=1; done
  while IFS= read -r -d '' file; do
    [[ -v "keep[$file]" && ! -L "$file" ]] || run rm -f "$file"
  done < <(find "$dir" ! -type d -print0)
  run find "$dir" -mindepth 1 -depth -type d -empty -delete
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

is_client_install() {
  [[ "$(cat "$BERCAIL_INSTALL_MODE_FILE" 2>/dev/null)" == client ]]
}

# Where releases come from, for a curl install and for a client's clone alike;
# never a clone's origin, which may be a fork.
BERCAIL_UPSTREAM="https://github.com/simoncrypta/bercail"

# The latest release's tag. github.com redirects /releases/latest to the tag:
# no API token, no jq.
latest_release_tag() {
  local url ref
  url="$(curl -fsSI -o /dev/null -w '%{redirect_url}' "$BERCAIL_UPSTREAM/releases/latest" 2>/dev/null)" || url=""
  ref="${url##*/releases/tag/}"
  [[ "$ref" == v* && "$ref" != */* ]] || return 1
  printf '%s' "$ref"
}

# A curl install's files come from one commit, as one archive: BERCAIL_ARCHIVE_URL,
# else BERCAIL_REF (a tag, branch, or sha), else the latest release. Never master
# by default: master is unreleased trunk. Unpacks it over BERCAIL_RELEASE_DIR.
fetch_release_tree() {
  local ref="${BERCAIL_REF:-}" url tmp
  if [[ -z "${BERCAIL_ARCHIVE_URL:-}" && -z "$ref" ]] && ! ref="$(latest_release_tag)"; then
    warn "cannot find the latest bercail release on github.com; retry, or pick one with BERCAIL_REF=<tag>"
    return 1
  fi
  url="${BERCAIL_ARCHIVE_URL:-$BERCAIL_UPSTREAM/archive/$ref.tar.gz}"
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

# A client's update copies its clone as it sits, so a clone left behind would
# redeploy old files and report success. Go on only from a clean clone at the
# release upstream names: the tag BERCAIL_REF, else the latest. BERCAIL_REF=HEAD
# takes the clone as it sits.
check_client_clone() {
  local src="$1" ref="${BERCAIL_REF:-}" at status q changes=""
  at="$(git -C "$src" describe --tags --always 2>/dev/null)"
  # Untracked files deploy too, whatever status.showUntrackedFiles says.
  status="$(git -C "$src" status --porcelain --untracked-files=normal 2>&1)" || status=failed
  [[ -z "$status" ]] || changes=1
  printf -v q '%q' "$src"
  if [[ "$ref" == HEAD ]]; then
    warn "deploying $src as it sits ($at${changes:+, with changes}): a dev build, not a release, and doctor sees only its version"
    return 0
  fi
  if [[ -z "$ref" ]] && ! ref="$(latest_release_tag)"; then
    warn "cannot find the latest bercail release on github.com to check $src against; nothing was updated. Retry, pin one with BERCAIL_REF=<tag>, or deploy the clone as it sits with BERCAIL_REF=HEAD"
    return 1
  fi
  # The tag, never a branch of that name: a branch is unreleased code under a release's version.
  if ! GIT_TERMINAL_PROMPT=0 git -C "$src" fetch --quiet --no-tags "$BERCAIL_UPSTREAM" "refs/tags/$ref" </dev/null; then
    warn "cannot fetch the tag $ref from $BERCAIL_UPSTREAM into $src; nothing was updated. Retry, or deploy the clone as it sits with BERCAIL_REF=HEAD"
    return 1
  fi
  if [[ "$(git -C "$src" rev-parse HEAD)" != "$(git -C "$src" rev-parse 'FETCH_HEAD^{commit}')" ]]; then
    warn "$src is at $at, not bercail $ref; nothing was updated. Check out the release, then update again:
  git -C $q fetch --no-tags $BERCAIL_UPSTREAM refs/tags/$ref && git -C $q switch --detach FETCH_HEAD
or deploy the clone as it sits with BERCAIL_REF=HEAD bercail update"
    return 1
  fi
  if [[ -n "$changes" ]]; then
    warn "$src is on $ref but has changes (git -C $q status); nothing was updated. Commit or stash them, or deploy the clone as it sits with BERCAIL_REF=HEAD bercail update"
    return 1
  fi
}
