#!/usr/bin/env bash
# shellcheck shell=bash

HUNK_MIN_VERSION=0.20.1
TUICR_MIN_VERSION=0.20.0
GROK_MISE_SPEC="npm:@xai-official/grok"
TUICR_MISE_SPEC="github:agavra/tuicr"

dep_present() {
  command -v "$1" >/dev/null 2>&1
}

ensure_mise_shims() {
  local dir p new=""
  local -a parts
  IFS=':' read -ra parts <<< "${PATH}"
  # mise shims first so they win over brew / pacman even if those are already on PATH.
  for dir in "${HOME}/.local/share/mise/shims" "${HOME}/.local/bin"; do
    [[ -d "$dir" ]] || continue
    new="${new:+$new:}$dir"
  done
  for p in "${parts[@]}"; do
    [[ -n "$p" ]] || continue
    case ":$new:" in
      *":$p:"*) continue ;;
    esac
    new="${new:+$new:}$p"
  done
  PATH="$new"
}

# Allowlist only — never probe `mise registry` (network) or eval `mise hook-env`.
mise_can_install() {
  local spec="$1"
  has_mise || return 1
  [[ -n "$spec" ]] || return 1
  [[ "$spec" == *:* ]] && return 0
  case "$spec" in
    worktrunk|fzf|jq|pi|hunk) return 0 ;;
    *) return 1 ;;
  esac
}

mise_use_global() {
  local spec="$1"
  mise_can_install "$spec" || return 1
  info "installing via mise: $spec"
  if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
    return 0
  fi
  if run mise use -g "$spec"; then
    ensure_mise_shims
    hash -r 2>/dev/null || true
    return 0
  fi
  return 1
}

maybe_mise_install() {
  local bin="$1" spec="${2:-$1}"
  if dep_present "$bin"; then
    info "present: $bin"
    return 0
  fi
  mise_use_global "$spec" || return 1
  [[ "${DRY_RUN:-0}" -eq 1 ]] && return 0
  dep_present "$bin"
}

maybe_omarchy_pkg_install() {
  local pkg="$1"
  local bin="${2:-$1}"
  if dep_present "$bin"; then
    info "present: $bin"
    return 0
  fi
  is_omarchy && command -v omarchy >/dev/null 2>&1 || return 1
  info "installing via omarchy pkg add: $pkg"
  run omarchy pkg add "$pkg"
}

maybe_brew_install() {
  local pkg="$1"
  if dep_present "$pkg"; then
    info "present: $pkg"
    return 0
  fi
  if ! has_brew; then
    return 1
  fi
  info "installing via brew: $pkg"
  run brew install "$pkg"
}

maybe_pacman_install() {
  local pkg="$1"
  local bin="${2:-$1}"
  if dep_present "$bin"; then
    info "present: $bin"
    return 0
  fi
  if ! command -v pacman >/dev/null 2>&1; then
    return 1
  fi
  info "installing via pacman: $pkg"
  run sudo pacman -S --needed --noconfirm "$pkg"
}

maybe_apt_install() {
  local pkg="$1"
  local bin="${2:-$1}"
  if dep_present "$bin"; then
    info "present: $bin"
    return 0
  fi
  if ! has_apt; then
    return 1
  fi
  info "installing via apt: $pkg"
  run sudo apt-get install -y "$pkg"
}

install_dep() {
  local bin="$1" pkg="${2:-$1}"
  if dep_present "$bin"; then
    info "present: $bin"
    return 0
  fi
  maybe_mise_install "$bin" "$pkg" && return 0
  maybe_omarchy_pkg_install "$pkg" "$bin" && return 0
  if has_brew; then
    info "installing via brew: $pkg"
    if run brew install "$pkg" && dep_present "$bin"; then
      return 0
    fi
  fi
  maybe_apt_install "$pkg" "$bin" && return 0
  if ! is_omarchy; then
    maybe_pacman_install "$pkg" "$bin" && return 0
  fi
  warn "missing $bin (install via mise, omarchy pkg add, brew, apt, or pacman)"
  return 1
}

version_at_least() {
  local current="$1" required="$2"
  local current_major current_minor current_patch
  local required_major required_minor required_patch

  [[ "$current" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 2
  [[ "$required" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 2

  IFS=. read -r current_major current_minor current_patch <<<"$current"
  IFS=. read -r required_major required_minor required_patch <<<"$required"

  ((10#$current_major > 10#$required_major)) && return 0
  ((10#$current_major < 10#$required_major)) && return 1
  ((10#$current_minor > 10#$required_minor)) && return 0
  ((10#$current_minor < 10#$required_minor)) && return 1
  ((10#$current_patch >= 10#$required_patch))
}

parse_version() {
  local output="$1" token
  local -a tokens
  output="${output//$'\n'/ }"
  IFS=$' \t\r\n' read -r -a tokens <<<"$output"
  for token in "${tokens[@]}"; do
    token="${token#v}"
    if [[ "$token" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      printf '%s\n' "$token"
      return 0
    fi
  done
  return 2
}

# The Herdr app (herdr-app) and herdr-core (hc) come from herdr.dev; the app
# keeps both updated. bercail only checks they are here.
check_herdr_app() {
  local missing=0 bin
  for bin in herdr-app hc; do
    if dep_present "$bin"; then
      info "present: $bin"
    else
      warn "missing $bin: install the Herdr app from https://herdr.dev"
      missing=1
    fi
  done
  return "$missing"
}

install_worktrunk_binary() {
  if dep_present wt; then
    info "present: wt"
    return 0
  fi
  if maybe_mise_install wt worktrunk; then
    return 0
  fi
  if has_brew; then
    info "installing via brew: worktrunk"
    if run brew install worktrunk && dep_present wt; then
      return 0
    fi
    warn "brew install worktrunk failed — trying GitHub release"
  fi
  local os arch url dest
  os="$(detect_os)"
  arch="$(detect_arch)"
  case "$os-$arch" in
    linux-x86_64|linux-amd64)
      url="https://github.com/max-sixty/worktrunk/releases/latest/download/worktrunk-x86_64-unknown-linux-musl.tar.xz"
      ;;
    linux-aarch64|linux-arm64)
      url="https://github.com/max-sixty/worktrunk/releases/latest/download/worktrunk-aarch64-unknown-linux-musl.tar.xz"
      ;;
    macos-x86_64|macos-amd64)
      url="https://github.com/max-sixty/worktrunk/releases/latest/download/worktrunk-x86_64-apple-darwin.tar.xz"
      ;;
    macos-arm64|macos-aarch64)
      url="https://github.com/max-sixty/worktrunk/releases/latest/download/worktrunk-aarch64-apple-darwin.tar.xz"
      ;;
    *)
      warn "cannot auto-install worktrunk on $os/$arch — install wt manually"
      return 1
      ;;
  esac
  dest="${LOCAL_BIN}/wt"
  ensure_dir "$LOCAL_BIN"
  dep_present curl || maybe_omarchy_pkg_install curl curl \
    || maybe_apt_install curl curl || true
  info "downloading worktrunk from GitHub releases"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi
  local tmp bin
  tmp="$(mktemp -d)"
  # Releases are .tar.xz with wt inside worktrunk-<target>/. Save to a file so
  # GNU tar and bsdtar both detect the compression themselves.
  if ! curl -fsSL "$url" -o "$tmp/worktrunk.tar.xz" || ! tar -xf "$tmp/worktrunk.tar.xz" -C "$tmp"; then
    warn "worktrunk download failed ($url) — install wt manually"
    rm -rf "$tmp"
    return 1
  fi
  bin="$(find "$tmp" -type f -name wt -perm -u+x 2>/dev/null | head -n 1)"
  if [[ -z "$bin" ]]; then
    warn "worktrunk archive layout unexpected — install wt manually"
    rm -rf "$tmp"
    return 1
  fi
  install -m 0755 "$bin" "$dest"
  rm -rf "$tmp"
}

# beads: the package is beads, the command is bd. Handoff jobs are beads issues.
# Same cascade as worktrunk: present, mise, brew, then the upstream installer
# (it puts bd in /usr/local/bin when writable, else ~/.local/bin).
BEADS_MISE_SPEC="github:gastownhall/beads"
BEADS_INSTALL_URL="https://raw.githubusercontent.com/gastownhall/beads/main/scripts/install.sh"

install_beads_binary() {
  if dep_present bd; then
    info "present: bd"
    return 0
  fi
  if maybe_mise_install bd "$BEADS_MISE_SPEC"; then
    return 0
  fi
  if has_brew; then
    info "installing via brew: beads"
    if run brew install beads && dep_present bd; then
      return 0
    fi
    warn "brew install beads failed — trying the beads installer"
  fi
  dep_present curl || maybe_omarchy_pkg_install curl curl \
    || maybe_apt_install curl curl || true
  info "installing beads: curl -fsSL $BEADS_INSTALL_URL | bash"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi
  if ! curl -fsSL "$BEADS_INSTALL_URL" | bash; then
    warn "beads installer failed — install bd manually (brew install beads)"
    return 1
  fi
  ensure_mise_shims
  hash -r 2>/dev/null || true
  dep_present bd
}

install_hunk_binary() {
  if dep_present hunk; then
    info "present: hunk"
    return 0
  fi
  if maybe_mise_install hunk hunk; then
    return 0
  fi
  if has_brew; then
    info "installing via brew: hunk"
    if run brew install hunk && dep_present hunk; then
      return 0
    fi
    warn "brew install hunk failed — trying hunk.dev installer"
  fi
  dep_present curl || maybe_omarchy_pkg_install curl curl \
    || maybe_apt_install curl curl || maybe_pacman_install curl curl || true
  info "installing via https://hunk.dev/install.sh"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi
  curl -fsSL https://hunk.dev/install.sh | sh
  ensure_mise_shims
  hash -r 2>/dev/null || true
  if dep_present hunk; then
    return 0
  fi
  warn "hunk install may have succeeded but hunk is not on PATH"
  return 1
}

install_tuicr_binary() {
  if dep_present tuicr; then
    info "present: tuicr"
    return 0
  fi
  if maybe_mise_install tuicr "$TUICR_MISE_SPEC"; then
    return 0
  fi
  if has_brew; then
    info "installing via brew: tuicr"
    if run brew install tuicr && dep_present tuicr; then
      return 0
    fi
    warn "brew install tuicr failed — trying tuicr.dev installer"
  fi
  dep_present curl || maybe_omarchy_pkg_install curl curl \
    || maybe_apt_install curl curl || maybe_pacman_install curl curl || true
  info "installing via https://tuicr.dev/install.sh"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi
  # The tuicr installer asks "Continue?" on /dev/tty unless TUICR_INSTALL_YES
  # is set. Under --yes there may be no tty at all, so answer it here.
  if [[ "${YES:-0}" -eq 1 ]]; then
    curl -fsSL https://tuicr.dev/install.sh | TUICR_INSTALL_YES=1 sh
  else
    curl -fsSL https://tuicr.dev/install.sh | sh
  fi
  ensure_mise_shims
  hash -r 2>/dev/null || true
  if dep_present tuicr; then
    return 0
  fi
  warn "tuicr install may have succeeded but tuicr is not on PATH"
  return 1
}

# Watch the local diff while the agent writes. Do not overwrite a user's theme.
ensure_tuicr_watch_config() {
  local dest="${XDG_CONFIG_HOME:-$HOME/.config}/tuicr/config.toml"
  local src=""
  if [[ -f "$dest" ]]; then
    if grep -qE '^[[:space:]]*diff_watch_interval_ms[[:space:]]*=' "$dest"; then
      info "keeping existing tuicr config: $dest"
      return 0
    fi
    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
      info "[dry-run] would set diff_watch_interval_ms in $dest"
      return 0
    fi
    printf '\n# bercail: keep the local diff current while the agent writes.\ndiff_watch_interval_ms = 1000\n' >>"$dest"
    info "enabled tuicr diff watch in $dest"
    return 0
  fi
  if declare -F install_src_dir >/dev/null 2>&1; then
    src="$(install_src_dir)/config/tuicr/config.toml"
  fi
  if declare -F ensure_dir >/dev/null 2>&1; then
    ensure_dir "$(dirname "$dest")"
  else
    mkdir -p "$(dirname "$dest")"
  fi
  if [[ -f "$src" ]]; then
    if declare -F copy_file >/dev/null 2>&1; then
      copy_file "$src" "$dest"
    else
      cp "$src" "$dest"
    fi
    return 0
  fi
  if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
    info "[dry-run] would write $dest (diff_watch_interval_ms=1000)"
    return 0
  fi
  cat >"$dest" <<'EOF'
diff_watch_interval_ms = 1000
review_watch_interval_ms = 1000
q_quits = true
EOF
  info "wrote $dest"
}

_layout_review_bin() {
  local cmd="tuicr"
  if declare -F read_layout_review >/dev/null 2>&1; then
    cmd="$(read_layout_review 2>/dev/null || printf '%s' "tuicr")"
  fi
  printf '%s' "${cmd%% *}"
}

ensure_selected_layout_tools() {
  local review_bin
  review_bin="$(_layout_review_bin)"
  case "$review_bin" in
    hunk)
      install_hunk_binary || warn "missing hunk (review tab needs it)"
      ;;
    *)
      install_tuicr_binary || warn "missing tuicr (review tab needs it)"
      ensure_tuicr_watch_config || true
      ;;
  esac
}

install_grok_binary() {
  if dep_present grok; then
    info "present: grok"
    return 0
  fi
  if maybe_mise_install grok "$GROK_MISE_SPEC"; then
    return 0
  fi
  warn "missing grok (install with: mise use -g $GROK_MISE_SPEC)"
  return 1
}

ensure_selected_agent() {
  local cmd
  cmd="$(read_agent_command 2>/dev/null || printf '%s' "cursor-agent")"
  case "$cmd" in
    grok) install_grok_binary || true ;;
    pi) maybe_mise_install pi pi || true ;;
  esac
}

install_dependencies() {
  info "checking dependencies..."
  # Homebrew first (macOS fallback), then mise shims so they win on PATH.
  ensure_brew_on_path || true
  ensure_mise_shims

  check_herdr_app || true
  install_dep git || true
  install_worktrunk_binary || true
  install_beads_binary || true
  install_dep fzf || true
  install_dep jq || true
}

_doctor_configured_bin() {
  local cmd="$1" role="$2"
  local path
  [[ -n "$cmd" ]] || return 0
  if ! dep_present "$cmd"; then
    log "  missing  $cmd (configured $role command)"
    return 1
  fi
  path="$(command -v "$cmd")"
  log "  ok  $cmd ($path) (configured $role)"
}

_doctor_versioned_bin() {
  local cmd="$1" min="$2" role="$3"
  local path output found
  [[ -n "$cmd" ]] || return 0
  if ! dep_present "$cmd"; then
    log "  missing  $cmd (configured $role command)"
    return 1
  fi
  path="$(command -v "$cmd")"
  output="$("$cmd" --version 2>/dev/null || true)"
  if found="$(parse_version "$output")" && [[ -n "$found" ]]; then
    if version_at_least "$found" "$min"; then
      log "  ok  $cmd ($path; found $found, required >=$min) (configured $role)"
      return 0
    fi
    log "  outdated  $cmd ($path; found $found, required >=$min) (configured $role)"
    return 1
  fi
  log "  ok  $cmd ($path) (configured $role)"
}

doctor_dependencies() {
  local missing=0 cmd
  for cmd in herdr-app hc git wt bd fzf jq; do
    if dep_present "$cmd"; then
      log "  ok  $cmd ($(command -v "$cmd"))"
    else
      log "  missing  $cmd"
      missing=$((missing + 1))
    fi
  done
  local review_bin
  review_bin="$(_layout_review_bin)"
  case "$review_bin" in
    hunk)
      _doctor_versioned_bin hunk "$HUNK_MIN_VERSION" review || missing=$((missing + 1))
      ;;
    tuicr|"")
      _doctor_versioned_bin tuicr "$TUICR_MIN_VERSION" review || missing=$((missing + 1))
      ;;
    *)
      _doctor_configured_bin "$review_bin" review || missing=$((missing + 1))
      ;;
  esac
  if declare -F read_agent_command >/dev/null; then
    local agent_cmd agent_bin
    agent_cmd="$(read_agent_command 2>/dev/null || printf '%s' "cursor-agent")"
    agent_bin="${agent_cmd%% *}"
    case "$agent_bin" in
      agent|"") ;;
      claude|codex|cursor|cursor-agent)
        if dep_present "$agent_bin"; then
          log "  ok  $agent_bin ($(command -v "$agent_bin"))"
        else
          log "  optional  $agent_bin (not on PATH; pick another agent on the desk)"
        fi
        ;;
      *)
        if dep_present "$agent_bin"; then
          log "  ok  $agent_bin ($(command -v "$agent_bin"))"
        else
          log "  missing  $agent_bin (configured agent command)"
          missing=$((missing + 1))
        fi
        ;;
    esac
  fi
  return "$missing"
}
