#!/usr/bin/env bash
# shellcheck shell=bash
# A repo's desk secret: a file holding a 1Password service-account token for
# that repo's desks, named per main checkout in config.toml:
#
#   [desk_secrets."~/Work/some-repo"]
#   op_service_account = "~/.config/bercail/secrets/some-repo.op"
#
# The value is a path, never the token. The guard puts bstack's op shim first
# on PATH for a desk, builder, autopilot or headless run there; the shim reads
# the file each time op runs (docs/config.md#a-desk-secret-per-repo).

# shellcheck source=lib/git-backend.sh
source "$(dirname "${BASH_SOURCE[0]}")/git-backend.sh"
# shellcheck source=lib/toml.sh
source "$(dirname "${BASH_SOURCE[0]}")/toml.sh"

# PATH's permission bits, or nothing when stat cannot read them.
_desk_secret_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null
}

# PATH is closed to group and others. Unreadable bits count as open.
_desk_secret_private() {
  local mode
  mode="$(_desk_secret_mode "$1")"
  [[ -n "$mode" && "${mode: -2}" == "00" ]]
}

# The op_service_account file configured for MAIN, ~ expanded, or nothing.
desk_secret_file() {
  local main="$1" config scope path file
  config="$(_git_backend_config_file)"
  [[ -f "$config" ]] || return 0
  while IFS=$'\t' read -r scope file; do
    path="$scope"
    [[ "$path" != \~/* ]] || path="$HOME/${path#\~/}"
    [[ "$(_git_backend_realpath "$path")" == "$main" ]] || continue
    [[ "$file" != \~/* ]] || file="$HOME/${file#\~/}"
    printf '%s' "$file"
    return 0
  done < <(toml_records "$config" | jq -r 'select(.section | length == 2 and .[0] == "desk_secrets")
    | select(.key == "op_service_account" and (.value | type) == "string") | [.section[1], .value] | @tsv')
}

# Why FILE cannot be a desk secret, or nothing when it can: a regular file of
# yours, 0600 in a 0700 folder, outside every repo and worktree, not empty.
desk_secret_problem() {
  local file="$1" dir
  dir="$(dirname "$file")"
  if [[ "$file" != /* ]]; then
    printf '%s is not an absolute path' "$file"
  elif [[ ! -e "$file" && ! -L "$file" ]]; then
    printf '%s does not exist' "$file"
  elif [[ -L "$file" || ! -f "$file" ]]; then
    printf '%s is not a regular file' "$file"
  elif [[ ! -O "$file" ]]; then
    printf '%s is not owned by you' "$file"
  elif ! _desk_secret_private "$file"; then
    printf '%s is readable by others; chmod 600 it' "$file"
  elif [[ ! -O "$dir" ]] || ! _desk_secret_private "$dir"; then
    printf '%s is open to others; chmod 700 it' "$dir"
  elif git -C "$dir" rev-parse >/dev/null 2>&1; then
    printf '%s is inside a git checkout; move it outside every repo and worktree' "$file"
  elif [[ ! -s "$file" ]]; then
    printf '%s is empty' "$file"
  elif [[ "$file" == *.cred ]] && ! command -v systemd-creds >/dev/null 2>&1; then
    printf '%s is a systemd credential and systemd-creds is not installed' "$file"
  fi
}

# MAIN's desk secret as JSON, {file, problem}, or null when it has none.
desk_secret_json() {
  local file
  file="$(desk_secret_file "$1")"
  [[ -n "$file" ]] || { printf 'null'; return 0; }
  jq -cn --arg file "$file" --arg problem "$(desk_secret_problem "$file")" '{file: $file, problem: $problem}'
}

# Each repo with a desk secret: the file passes the check, and op through the
# shim signs in as a service account. Says what is wrong, never the token.
doctor_desk_secrets() {
  local config scope main file problem out rc failures=0
  local shim="${BERCAIL_SHARE_DIR:-$HOME/.local/share/bercail}/pi/op-shim/op"
  config="$(_git_backend_config_file)"
  [[ -f "$config" ]] || return 0
  while IFS= read -r scope; do
    main="$scope"
    [[ "$main" != \~/* ]] || main="$HOME/${main#\~/}"
    main="$(_git_backend_realpath "$main")"
    file="$(desk_secret_file "$main")"
    [[ -n "$file" ]] || continue
    problem="$(desk_secret_problem "$file")"
    if [[ -n "$problem" ]]; then
      log "  unusable  desk secret for $scope: $problem. Its desks ask the 1Password app instead"
      failures=1
    elif [[ ! -x "$shim" ]]; then
      log "  missing  op shim $shim, which the desk secret for $scope needs (run: bercail update)"
      failures=1
    else
      rc=0
      out="$(BERCAIL_OP_SERVICE_ACCOUNT="$file" "$shim" whoami --format json 2>/dev/null </dev/null)" || rc=$?
      if ((rc == 127)); then
        log "  missing  op (the 1Password CLI) in /usr/bin, /usr/local/bin or /opt/homebrew/bin, where you cannot write it, which the desk secret for $scope needs"
        failures=1
      elif [[ "$(jq -r '.user_type // empty' <<<"$out" 2>/dev/null)" == SERVICE_ACCOUNT ]]; then
        log "  ok  desk secret for $scope: present, 0$(_desk_secret_mode "$file"), service account"
      else
        log "  failing  desk secret for $scope: op whoami through the shim is not a service account (an expired or revoked token?)"
        failures=1
      fi
    fi
  done < <(toml_records "$config" | jq -r 'select(.section | length == 2 and .[0] == "desk_secrets") | .section[1]' | awk '!seen[$0]++')
  return "$failures"
}
