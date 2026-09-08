#!/usr/bin/env bash
set -euo pipefail

# Bootstrap libs from GitHub raw so curl|bash always gets the repo tip.
# INSTALL_SRC may still point at the CDN for legacy callers; asset fetches
# use github_raw_base() in lib/common.sh.
bootstrap_remote_libs() {
  local base="${GITHUB_RAW_BASE:-https://raw.githubusercontent.com/simoncrypta/agentic-dev-setup/master}"
  local tmp lib
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/lib"
  for lib in common detect deps config skills shell-rc uninstall help omarchy doctor; do
    curl -fsSL "${base%/}/lib/${lib}.sh" -o "$tmp/lib/${lib}.sh"
  done
  printf '%s' "$tmp"
}

resolve_root() {
  local self="${BASH_SOURCE[0]:-${0:-}}"
  if [[ -n "$self" && "$self" != bash && "$self" != -bash && -f "$(dirname "$self")/lib/common.sh" ]]; then
    cd "$(dirname "$self")" && pwd
    return 0
  fi
  # Mark remote install so install_src_dir() is not treated as a local tree.
  INSTALL_SRC="${INSTALL_SRC:-https://setup.simoncrypta.dev}"
  bootstrap_remote_libs
}

ROOT="$(resolve_root)"
if [[ ! -f "$ROOT/lib/common.sh" ]]; then
  printf 'error: failed to load installer libraries\n' >&2
  exit 1
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

  install_dependencies
  deploy_configs
  deploy_omarchy_integration
  if ! install_shell_integration; then
    warn "shell integration was not installed — run 'bercail update' after resolving conflicts"
  fi
  show_summary
}

main "$@"
