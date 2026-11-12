#!/usr/bin/env bash
set -euo pipefail

# bercail.dev pins this to the release tag it serves install.sh from.
BERCAIL_RELEASE=""

# A piped install reads every file from one commit: GITHUB_RAW_BASE, else
# BERCAIL_REF (a tag, branch, or sha), else the release pinned above, else the
# latest release. Never master by default: master is unreleased trunk.
remote_raw_base() {
  local ref="${BERCAIL_REF:-$BERCAIL_RELEASE}" url
  if [[ -n "${GITHUB_RAW_BASE:-}" ]]; then
    printf '%s' "${GITHUB_RAW_BASE%/}"
    return 0
  fi
  if [[ -z "$ref" ]]; then
    url="$(curl -fsSI -o /dev/null -w '%{redirect_url}' https://github.com/simoncrypta/bercail/releases/latest)" || return 1
    ref="${url##*/releases/tag/}"
    [[ "$ref" == v* && "$ref" != */* ]] || return 1
  fi
  printf 'https://raw.githubusercontent.com/simoncrypta/bercail/%s' "$ref"
}

bootstrap_remote_libs() {
  local tmp lib
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/lib"
  for lib in common detect deps config skills shell-rc uninstall help omarchy notify doctor bstack desk shep shep-context; do
    curl -fsSL "$GITHUB_RAW_BASE/lib/${lib}.sh" -o "$tmp/lib/${lib}.sh"
  done
  printf '%s' "$tmp"
}

local_root() {
  local self="${BASH_SOURCE[0]:-${0:-}}"
  [[ -n "$self" && "$self" != bash && "$self" != -bash && -f "$(dirname "$self")/lib/common.sh" ]] || return 1
  cd "$(dirname "$self")" && pwd
}

if ! ROOT="$(local_root)"; then
  # Mark remote install so install_src_dir() is not treated as a local tree.
  INSTALL_SRC="${INSTALL_SRC:-https://bercail.dev}"
  if ! GITHUB_RAW_BASE="$(remote_raw_base)"; then
    printf 'error: cannot find the latest bercail release on github.com; retry, or pick one with BERCAIL_REF=<tag>\n' >&2
    exit 1
  fi
  printf 'bercail: installing from %s\n' "$GITHUB_RAW_BASE"
  ROOT="$(bootstrap_remote_libs)"
fi
if [[ ! -f "$ROOT/lib/common.sh" ]]; then
  printf 'error: failed to load installer libraries\n' >&2
  exit 1
fi
# Unpacked from a release by mise or packslip: that tool owns the bercail command.
if [[ -f "$ROOT/.bercail-package" ]]; then
  export BERCAIL_PACKAGED=1
fi

# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=lib/detect.sh
source "$ROOT/lib/detect.sh"
# shellcheck source=lib/deps.sh
source "$ROOT/lib/deps.sh"
# shellcheck source=lib/config.sh
source "$ROOT/lib/config.sh"
# shellcheck source=lib/skills.sh
source "$ROOT/lib/skills.sh"
# shellcheck source=lib/shell-rc.sh
source "$ROOT/lib/shell-rc.sh"
# shellcheck source=lib/uninstall.sh
source "$ROOT/lib/uninstall.sh"
# shellcheck source=lib/help.sh
source "$ROOT/lib/help.sh"
# shellcheck source=lib/omarchy.sh
source "$ROOT/lib/omarchy.sh"
# shellcheck source=lib/doctor.sh
source "$ROOT/lib/doctor.sh"
# shellcheck source=lib/notify.sh
source "$ROOT/lib/notify.sh"
# shellcheck source=lib/bstack.sh
source "$ROOT/lib/bstack.sh"
# shellcheck source=lib/desk.sh
source "$ROOT/lib/desk.sh"
# shellcheck source=lib/shep.sh
source "$ROOT/lib/shep.sh"

parse_install_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        show_help
        exit 0
        ;;
      -y|--yes)
        YES=1
        shift
        ;;
      --bstack)
        BSTACK_NEW_INSTALL=1
        shift
        ;;
      --no-bstack)
        BSTACK_NEW_INSTALL=0
        shift
        ;;
      *)
        die "unknown option: $1 (try --help)"
        ;;
    esac
  done
}

main() {
  parse_install_args "$@"

  log "bercail v${AGENTIC_DEV_VERSION}"
  info "platform: $(detect_platform) shell: $(detect_shell_name)"
  is_omarchy && info "omarchy detected"
  is_ubuntu && info "ubuntu detected"
  is_debian && ! is_ubuntu && info "debian detected"
  if [[ "${BERCAIL_PACKAGED:-0}" != 1 ]]; then
    info "recommended install: mise use -g packslip:github.com/simoncrypta/bercail && bercail install (signed release); this curl/clone install stays supported"
  fi

  install_dependencies
  deploy_configs
  deploy_omarchy_integration
  if ! install_shell_integration; then
    warn "shell integration was not installed — run 'bercail update' after resolving conflicts"
  fi
  show_summary
}

main "$@"
