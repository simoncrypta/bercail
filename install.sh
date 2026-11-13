#!/usr/bin/env bash
set -euo pipefail

# bercail.dev pins this to the release tag it serves install.sh from.
BERCAIL_RELEASE=""

# A piped install reads every file from one commit, as one archive:
# BERCAIL_ARCHIVE_URL, else BERCAIL_REF (a tag, branch, or sha), else the release
# pinned above, else the latest release. Never master by default: master is
# unreleased trunk. Unpacks it where bercail update will replace it, and prints
# that path.
fetch_release_tree() {
  local ref="${BERCAIL_REF:-$BERCAIL_RELEASE}" url share="$HOME/.local/share/bercail" tmp
  if [[ -z "${BERCAIL_ARCHIVE_URL:-}" && -z "$ref" ]]; then
    url="$(curl -fsSI -o /dev/null -w '%{redirect_url}' https://github.com/simoncrypta/bercail/releases/latest)" || url=""
    ref="${url##*/releases/tag/}"
    if [[ "$ref" != v* || "$ref" == */* ]]; then
      printf 'error: cannot find the latest bercail release on github.com; retry, or pick one with BERCAIL_REF=<tag>\n' >&2
      return 1
    fi
  fi
  url="${BERCAIL_ARCHIVE_URL:-https://github.com/simoncrypta/bercail/archive/$ref.tar.gz}"
  printf 'bercail: installing from %s\n' "$url" >&2
  mkdir -p "$share"
  tmp="$(mktemp -d "$share/release.XXXXXX")"
  if ! curl -fsSL "$url" -o "$tmp/archive.tar.gz" \
    || ! tar -xzf "$tmp/archive.tar.gz" -C "$tmp" --strip-components=1; then
    rm -rf "$tmp"
    printf 'error: could not download bercail from %s; retry, or pick a release with BERCAIL_REF=<tag>\n' "$url" >&2
    return 1
  fi
  # The check fetch_release_tree in lib/common.sh makes before an update.
  if [[ ! -f "$tmp/install.sh" || ! -f "$tmp/bin/bercail" || ! -d "$tmp/config" || ! -d "$tmp/skills" || ! -d "$tmp/bstack" ]] \
    || ! grep -q '^BERCAIL_LIBS=' "$tmp/lib/common.sh" 2>/dev/null; then
    rm -rf "$tmp"
    printf 'error: %s is not a bercail release that installs from an archive (v0.14.0 and older are not); install an older one with its own install.sh: curl -fsSL https://raw.githubusercontent.com/simoncrypta/bercail/<tag>/install.sh | BERCAIL_REF=<tag> bash\n' "$url" >&2
    return 1
  fi
  rm -rf "$tmp/archive.tar.gz" "$share/release"
  mv "$tmp" "$share/release"
  printf '%s' "$share/release"
}

local_root() {
  local self="${BASH_SOURCE[0]:-${0:-}}"
  [[ -n "$self" && "$self" != bash && "$self" != -bash && -f "$(dirname "$self")/lib/common.sh" ]] || return 1
  cd "$(dirname "$self")" && pwd
}

ROOT="$(local_root)" || ROOT="$(fetch_release_tree)" || exit 1
# Unpacked from a release by mise or packslip: that tool owns the bercail command.
if [[ -f "$ROOT/.bercail-package" ]]; then
  export BERCAIL_PACKAGED=1
fi

# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"
for lib in "${BERCAIL_LIBS[@]}"; do
  # shellcheck source=/dev/null
  source "$ROOT/lib/$lib.sh"
done

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

  log "bercail v${BERCAIL_VERSION}"
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
