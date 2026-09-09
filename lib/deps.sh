#!/usr/bin/env bash
# shellcheck shell=bash

HERDR_MIN_VERSION=0.9.0
HUNK_MIN_VERSION=0.20.1
TUICR_MIN_VERSION=0.20.0
GROK_MISE_SPEC="npm:@xai-official/grok"
TUICR_MISE_SPEC="github:agavra/tuicr"

dep_present() {
  command -v "$1" >/dev/null 2>&1
}

ensure_mise_shims() {
  local dir
  for dir in "${HOME}/.local/bin" "${HOME}/.local/share/mise/shims"; do
    [[ -d "$dir" ]] || continue
    case ":${PATH}:" in
      *":${dir}:"*) ;;
      *) PATH="${dir}:${PATH}" ;;
    esac
  done
}

# Allowlist only — never probe `mise registry` (network) or eval `mise hook-env`.
mise_can_install() {
  local spec="$1"
  has_mise || return 1
  [[ -n "$spec" ]] || return 1
  [[ "$spec" == *:* ]] && return 0
  case "$spec" in
    herdr|worktrunk|fzf|jq|neovim|lazygit|pi|hunk) return 0 ;;
    *) return 1 ;;
  esac
}

maybe_mise_install() {
  local bin="$1" spec="${2:-$1}"
  if dep_present "$bin"; then
    info "present: $bin"
    return 0
  fi
  mise_can_install "$spec" || return 1
  info "installing via mise: $spec"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi
  if run mise use -g "$spec"; then
    ensure_mise_shims
    hash -r 2>/dev/null || true
    dep_present "$bin" && return 0
  fi
  return 1
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

herdr_version_at_least() {
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

herdr_parse_version() {
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

herdr_version_output() {
  local herdr_path output_file pid rc
  local elapsed=0 grace_elapsed=0
  local timeout_seconds="${HERDR_VERSION_TIMEOUT_SECONDS:-5}"
  local term_grace_tenths="${HERDR_VERSION_TERM_GRACE_TENTHS:-10}"

  herdr_path="$(command -v herdr)" || return 127
  output_file="$(mktemp)"
  "$herdr_path" --version >"$output_file" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if ((elapsed >= timeout_seconds * 10)); then
      kill -TERM "$pid" 2>/dev/null || true
      while kill -0 "$pid" 2>/dev/null && ((grace_elapsed < term_grace_tenths)); do
        sleep 0.1
        grace_elapsed=$((grace_elapsed + 1))
      done
      if kill -0 "$pid" 2>/dev/null; then
        kill -KILL "$pid" 2>/dev/null || true
      fi
      wait "$pid" 2>/dev/null || true
      rm -f "$output_file"
      return 124
    fi
    sleep 0.1
    elapsed=$((elapsed + 1))
  done
  if wait "$pid"; then
    rc=0
  else
    rc=$?
  fi
  cat "$output_file"
  rm -f "$output_file"
  return "$rc"
}

herdr_installed_version() {
  local output rc
  if output="$(herdr_version_output)"; then
    herdr_parse_version "$output"
    return $?
  else
    rc=$?
    return "$rc"
  fi
}

herdr_install_manager() {
  local herdr_path link_target updater_dir
  herdr_path="$(command -v herdr)"
  link_target="$(readlink "$herdr_path" 2>/dev/null || true)"

  case "$herdr_path $link_target" in
    *'/nix/store/'*|*'/.nix-profile/'*) printf 'nix\n'; return 0 ;;
    *'/.local/share/mise/'*|*'/.mise/'*) printf 'mise\n'; return 0 ;;
    *'/Homebrew/'*|*'/homebrew/'*|*'/linuxbrew/'*|*'/Cellar/'*) printf 'brew\n'; return 0 ;;
  esac

  updater_dir="${HERDR_INSTALL_DIR:-$HOME/.local/bin}"
  if [[ "$herdr_path" == "$updater_dir/herdr" ]]; then
    printf 'updater\n'
  else
    printf 'manual\n'
  fi
}

herdr_upgrade_command() {
  case "$1" in
    brew) printf 'brew upgrade herdr\n' ;;
    mise) printf 'mise use -g herdr\n' ;;
    nix) printf 'nix profile upgrade <index-or-name>\n' ;;
    updater) printf 'herdr update --handoff\n' ;;
    *) printf 'reinstall Herdr >=%s using the method that owns %s\n' \
      "$HERDR_MIN_VERSION" "$(command -v herdr)" ;;
  esac
}

require_herdr_min_version() {
  local found manager command
  if ! found="$(herdr_installed_version)"; then
    warn "cannot determine Herdr version (required >=$HERDR_MIN_VERSION)"
    return 1
  fi
  if herdr_version_at_least "$found" "$HERDR_MIN_VERSION"; then
    info "present: herdr $found (required >=$HERDR_MIN_VERSION)"
    return 0
  fi

  manager="$(herdr_install_manager)"
  command="$(herdr_upgrade_command "$manager")"
  if [[ "$manager" != updater ]]; then
    warn "Herdr $found is below required >=$HERDR_MIN_VERSION; run: $command"
    return 1
  fi

  info "updating Herdr $found to >=$HERDR_MIN_VERSION with live handoff"
  if ! run "$(command -v herdr)" update --handoff; then
    warn "Herdr update failed; run: $command"
    return 1
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi
  if ! found="$(herdr_installed_version)"; then
    warn "Herdr update reported success but its version is unreadable; run: $command"
    return 1
  fi
  if ! herdr_version_at_least "$found" "$HERDR_MIN_VERSION"; then
    warn "Herdr update reported success but found $found; required >=$HERDR_MIN_VERSION; run: $command"
    return 1
  fi
  info "updated: herdr $found (required >=$HERDR_MIN_VERSION)"
}

install_herdr_binary() {
  if dep_present herdr; then
    require_herdr_min_version
    return $?
  fi
  if maybe_mise_install herdr herdr; then
    require_herdr_min_version
    return $?
  fi
  if has_brew; then
    info "installing via brew: herdr"
    if run brew install herdr && dep_present herdr; then
      require_herdr_min_version
      return $?
    fi
    warn "brew install herdr failed — trying herdr.dev installer"
  fi
  dep_present curl || maybe_omarchy_pkg_install curl curl \
    || maybe_apt_install curl curl || maybe_pacman_install curl curl || true
  info "installing via https://herdr.dev/install.sh"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi
  curl -fsSL https://herdr.dev/install.sh | sh
  if ! dep_present herdr; then
    warn "herdr install may have succeeded but herdr is not on PATH"
    return 1
  fi
  require_herdr_min_version
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
      url="https://github.com/max-sixty/worktrunk/releases/latest/download/worktrunk-x86_64-unknown-linux-gnu.tar.gz"
      ;;
    linux-aarch64|linux-arm64)
      url="https://github.com/max-sixty/worktrunk/releases/latest/download/worktrunk-aarch64-unknown-linux-gnu.tar.gz"
      ;;
    macos-x86_64|macos-amd64)
      url="https://github.com/max-sixty/worktrunk/releases/latest/download/worktrunk-x86_64-apple-darwin.tar.gz"
      ;;
    macos-arm64|macos-aarch64)
      url="https://github.com/max-sixty/worktrunk/releases/latest/download/worktrunk-aarch64-apple-darwin.tar.gz"
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
  local tmp
  tmp="$(mktemp -d)"
  curl -fsSL "$url" | tar -xz -C "$tmp"
  if [[ -f "$tmp/wt" ]]; then
    install -m 0755 "$tmp/wt" "$dest"
  elif [[ -f "$tmp/worktrunk" ]]; then
    install -m 0755 "$tmp/worktrunk" "$dest"
  else
    warn "worktrunk archive layout unexpected — install wt manually"
    rm -rf "$tmp"
    return 1
  fi
  rm -rf "$tmp"
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
  curl -fsSL https://tuicr.dev/install.sh | sh
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
    info "keeping existing tuicr config: $dest"
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

# Cursor pstack plugin (poteto-mode). Not vendored here; install with /add-plugin pstack.
pstack_plugin_present() {
  local cursor="${CURSOR_CONFIG_DIR:-$HOME/.cursor}" match
  shopt -s nullglob
  for match in \
    "$cursor/plugins/cache/cursor-public/pstack/"*/skills/poteto-mode/SKILL.md \
    "$cursor/plugins/local/pstack/skills/poteto-mode/SKILL.md"
  do
    if [[ -f "$match" ]]; then
      shopt -u nullglob
      return 0
    fi
  done
  shopt -u nullglob
  return 1
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
  ensure_herdr_agent_integration || true
}

# Map agentic-dev agent command → `herdr integration install` target.
# See https://herdr.dev/docs/integrations/
herdr_integration_for_agent() {
  local cmd="${1%% *}"
  case "$cmd" in
    agent|cursor|cursor-agent) printf 'cursor' ;;
    grok) printf 'grok' ;;
    pi) printf 'pi' ;;
    omp) printf 'omp' ;;
    claude) printf 'claude' ;;
    codex) printf 'codex' ;;
    copilot) printf 'copilot' ;;
    opencode) printf 'opencode' ;;
    kilo) printf 'kilo' ;;
    kimi) printf 'kimi' ;;
    hermes) printf 'hermes' ;;
    droid) printf 'droid' ;;
    devin) printf 'devin' ;;
    qodercli) printf 'qodercli' ;;
    mastracode) printf 'mastracode' ;;
    agy|antigravity|antigravity-cli) printf 'antigravity-cli' ;;
    *) return 1 ;;
  esac
}

# Config dirs that must exist before `herdr integration install` (per Herdr docs).
herdr_integration_config_dir() {
  local target="$1"
  case "$target" in
    cursor) printf '%s' "${CURSOR_CONFIG_DIR:-$HOME/.cursor}" ;;
    grok) printf '%s' "${GROK_HOME:-$HOME/.grok}" ;;
    pi) printf '%s' "${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}" ;;
    omp)
      if [[ -n "${PI_CODING_AGENT_DIR:-}" ]]; then
        printf '%s' "$PI_CODING_AGENT_DIR"
      elif [[ -n "${PI_CONFIG_DIR:-}" ]]; then
        printf '%s' "$HOME/$PI_CONFIG_DIR/agent"
      else
        printf '%s' "$HOME/.omp/agent"
      fi
      ;;
    claude) printf '%s' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" ;;
    codex) printf '%s' "${CODEX_HOME:-$HOME/.codex}" ;;
    copilot) printf '%s' "${COPILOT_HOME:-$HOME/.copilot}" ;;
    opencode) printf '%s' "${XDG_CONFIG_HOME:-$HOME/.config}/opencode" ;;
    kilo) printf '%s' "${XDG_CONFIG_HOME:-$HOME/.config}/kilo" ;;
    kimi) printf '%s' "${KIMI_CODE_HOME:-$HOME/.kimi-code}" ;;
    hermes) printf '%s' "$HOME/.hermes" ;;
    droid) printf '%s' "$HOME/.factory" ;;
    devin) printf '%s' "${XDG_CONFIG_HOME:-$HOME/.config}/devin" ;;
    qodercli) printf '%s' "${QODER_CONFIG_DIR:-$HOME/.qoder}" ;;
    mastracode) printf '%s' "$HOME/.mastracode" ;;
    antigravity-cli) printf '%s' "${ANTIGRAVITY_CLI_CONFIG_DIR:-$HOME/.gemini/config}" ;;
    *) return 1 ;;
  esac
}

ensure_herdr_agent_integration() {
  local cmd target conf
  dep_present herdr || return 0
  cmd="$(read_agent_command 2>/dev/null || printf '%s' "cursor-agent")"
  if ! target="$(herdr_integration_for_agent "$cmd")"; then
    info "no Herdr integration mapped for agent command '$cmd'"
    return 0
  fi
  if conf="$(herdr_integration_config_dir "$target")"; then
    if declare -F ensure_dir >/dev/null 2>&1; then
      ensure_dir "$conf"
    else
      mkdir -p "$conf"
    fi
  fi
  info "installing Herdr integration: $target (agent=$cmd)"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "[dry-run] would run: herdr integration install $target"
    return 0
  fi
  if run herdr integration install "$target"; then
    return 0
  fi
  warn "herdr integration install $target failed — see https://herdr.dev/docs/integrations/"
  return 1
}

install_dependencies() {
  info "checking dependencies..."
  ensure_mise_shims

  install_herdr_binary || {
    warn "Herdr >=$HERDR_MIN_VERSION is required"
    return 1
  }
  install_dep git || true
  install_worktrunk_binary || true
  install_dep fzf || true
  install_dep jq || true
  install_dep lazygit || true
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
  if found="$(herdr_parse_version "$output")" && [[ -n "$found" ]]; then
    if herdr_version_at_least "$found" "$min"; then
      log "  ok  $cmd ($path; found $found, required >=$min) (configured $role)"
      return 0
    fi
    log "  outdated  $cmd ($path; found $found, required >=$min) (configured $role)"
    return 1
  fi
  log "  ok  $cmd ($path) (configured $role)"
}

doctor_dependencies() {
  local missing=0 found path output rc
  for cmd in herdr git wt fzf jq lazygit; do
    if [[ "$cmd" == herdr ]] && dep_present herdr; then
      path="$(command -v herdr)"
      if output="$(herdr_version_output)"; then
        if found="$(herdr_parse_version "$output")"; then
          if herdr_version_at_least "$found" "$HERDR_MIN_VERSION"; then
            log "  ok  herdr ($path; found $found, required >=$HERDR_MIN_VERSION)"
          else
            log "  outdated  herdr ($path; found $found, required >=$HERDR_MIN_VERSION)"
            missing=$((missing + 1))
          fi
        else
          log "  invalid  herdr ($path; found unrecognized output, required >=$HERDR_MIN_VERSION)"
          missing=$((missing + 1))
        fi
      else
        rc=$?
        if [[ "$rc" -eq 124 ]]; then
          found="timeout"
        else
          found="unavailable"
        fi
        log "  invalid  herdr ($path; found $found, required >=$HERDR_MIN_VERSION)"
        missing=$((missing + 1))
      fi
    elif dep_present "$cmd"; then
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
  if declare -F read_layout_file_editor >/dev/null; then
    local editor_cmd editor_bin
    editor_cmd="$(read_layout_file_editor 2>/dev/null || true)"
    editor_bin="${editor_cmd%% *}"
    _doctor_configured_bin "$editor_bin" editor || missing=$((missing + 1))
  fi
  if declare -F read_agent_command >/dev/null; then
    local agent_cmd agent_bin target status_out status_line
    agent_cmd="$(read_agent_command 2>/dev/null || printf '%s' "cursor-agent")"
    agent_bin="${agent_cmd%% *}"
    case "$agent_bin" in
      agent|"") ;;
      *)
        if dep_present "$agent_bin"; then
          log "  ok  $agent_bin ($(command -v "$agent_bin"))"
        else
          log "  missing  $agent_bin (configured agent command)"
          missing=$((missing + 1))
        fi
        ;;
    esac
    if target="$(herdr_integration_for_agent "$agent_cmd" 2>/dev/null)"; then
      if ! dep_present herdr; then
        :
      elif ! status_out="$(herdr integration status 2>/dev/null)"; then
        log "  unverified  herdr integration $target (status unavailable)"
      else
        status_line="$(printf '%s\n' "$status_out" | grep -E "^${target}:" | head -1 || true)"
        if [[ -n "$status_line" && "$status_line" != *": not installed"* ]]; then
          log "  ok  herdr integration $target"
        elif [[ -n "$status_line" ]]; then
          log "  missing  herdr integration $target (run: herdr integration install $target)"
          missing=$((missing + 1))
        else
          log "  unverified  herdr integration $target (not listed by herdr)"
        fi
      fi
    fi
  fi
  return "$missing"
}
