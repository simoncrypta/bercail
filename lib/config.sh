#!/usr/bin/env bash
# shellcheck shell=bash

default_user_config() {
  cat <<'EOF'
[agent]
command = "cursor-agent"

[layout]
review = "tuicr"
# Open tuicr when the layout agent pane goes done (branch vs origin/main
# plus uncommitted, watching). Someone else's PR uses `tuicr pr`.
# Set false to disable the hook.
auto_review = true
EOF
}

_config_reader_path() {
  local src
  src="$(install_src_dir)"
  if [[ -d "$src" && -f "$src/config/agentic-dev/config-reader.sh" ]]; then
    printf '%s' "$src/config/agentic-dev/config-reader.sh"
    return 0
  fi
  if [[ -f "$AGENTIC_DEV_CONFIG_DIR/config-reader.sh" ]]; then
    printf '%s' "$AGENTIC_DEV_CONFIG_DIR/config-reader.sh"
    return 0
  fi
  return 1
}

ensure_config_reader() {
  declare -F agentic_dev_agent_command >/dev/null 2>&1 && return 0
  local reader
  reader="$(_config_reader_path)" || return 1
  # shellcheck source=/dev/null
  source "$reader"
}

read_agent_command() {
  ensure_config_reader || true
  if declare -F agentic_dev_agent_command >/dev/null 2>&1; then
    agentic_dev_agent_command
  else
    printf '%s' "cursor-agent"
  fi
}

agentic_dev_default_file_editor() {
  local cmd bin
  for cmd in "${EDITOR:-}" "${VISUAL:-}"; do
    [[ -n "$cmd" ]] || continue
    printf '%s' "$cmd"
    return 0
  done
  case "$(uname -s)" in
    Darwin)
      command -v nano >/dev/null 2>&1 && { printf 'nano'; return 0; }
      printf 'vi'
      ;;
    *)
      for bin in nvim vim nano vi; do
        if command -v "$bin" >/dev/null 2>&1; then
          printf '%s' "$bin"
          return 0
        fi
      done
      printf 'vi'
      ;;
  esac
}

read_layout_file_editor() {
  ensure_config_reader || true
  if declare -F agentic_dev_layout_file_editor >/dev/null 2>&1; then
    agentic_dev_layout_file_editor
  elif declare -F agentic_dev_layout_editor >/dev/null 2>&1; then
    agentic_dev_layout_editor
  else
    agentic_dev_default_file_editor
  fi
}

read_layout_editor() {
  read_layout_file_editor
}

read_layout_review() {
  ensure_config_reader || true
  if declare -F agentic_dev_layout_review >/dev/null 2>&1; then
    agentic_dev_layout_review
  else
    printf '%s' "tuicr"
  fi
}

RECONFIGURE=0

export DEV_LAYOUT_PLUGIN_REPO="simoncrypta/agentic-dev-setup/plugins/agentic-layout"
export DEV_LAYOUT_PLUGIN_REF="v0.5.0"
export LEGACY_DEV_LAYOUT_PLUGIN_REPO="simoncrypta/herdr-dev-layout"
PICKR_PLUGIN_REPO="tomasvarga/herdr-pickr"
PICKR_PLUGIN_REF="e393ef593e44d2497f43d20aa7b0e4a26ea3d445"
WORKTRUNK_PLUGIN_REPO="devashish2203/herdr-worktrunk"
WORKTRUNK_PLUGIN_REF="a3107ca566bafcd463bc138007a0c01051970784"

PLUGIN_STATUS=""
PLUGIN_SOURCE_KIND=""
PLUGIN_SOURCE_REPO=""
PLUGIN_SOURCE_REF=""
PLUGIN_SOURCE_PATH=""
PLUGIN_SOURCE_RAW=""

plugin_inspect() {
  local id="$1" output line descriptor payload matches=0 mentions=0

  PLUGIN_STATUS="unknown"
  PLUGIN_SOURCE_KIND=""
  PLUGIN_SOURCE_REPO=""
  PLUGIN_SOURCE_REF=""
  PLUGIN_SOURCE_PATH=""
  PLUGIN_SOURCE_RAW=""

  if ! output="$(herdr plugin list 2>/dev/null)"; then
    return 1
  fi

  while IFS= read -r line; do
    [[ "$line" != *"$id"* ]] || mentions=$((mentions + 1))
    [[ "$line" == "- $id "* ]] || continue
    matches=$((matches + 1))
    PLUGIN_SOURCE_RAW="$line"
  done <<<"$output"

  if [[ "$matches" -eq 0 ]]; then
    [[ "$mentions" -eq 0 ]] || return 1
    PLUGIN_STATUS="missing"
    return 0
  fi
  [[ "$matches" -eq 1 ]] || return 1

  descriptor="${PLUGIN_SOURCE_RAW##*[}"
  [[ "$descriptor" != "$PLUGIN_SOURCE_RAW" && "$descriptor" == *']'* ]] || return 1
  descriptor="${descriptor%%]*}"
  case "$descriptor" in
    local:*)
      PLUGIN_STATUS="present"
      PLUGIN_SOURCE_KIND="local"
      PLUGIN_SOURCE_PATH="${descriptor#local:}"
      [[ -n "$PLUGIN_SOURCE_PATH" ]] || {
        PLUGIN_STATUS="unknown"
        return 1
      }
      ;;
    github:*@*)
      payload="${descriptor#github:}"
      PLUGIN_SOURCE_REPO="${payload%@*}"
      PLUGIN_SOURCE_REF="${payload##*@}"
      [[ "$PLUGIN_SOURCE_REPO" == */* && -n "$PLUGIN_SOURCE_REF" ]] || return 1
      PLUGIN_STATUS="present"
      PLUGIN_SOURCE_KIND="github"
      ;;
    *)
      return 1
      ;;
  esac
}

plugin_is_exact_github() {
  local repo="$1" ref="$2"
  [[ "$PLUGIN_STATUS" == "present" \
    && "$PLUGIN_SOURCE_KIND" == "github" \
    && "$PLUGIN_SOURCE_REPO" == "$repo" \
    && "$PLUGIN_SOURCE_REF" == "$ref" ]]
}

plugin_is_exact_local() {
  local path="$1"
  [[ "$PLUGIN_STATUS" == "present" \
    && "$PLUGIN_SOURCE_KIND" == "local" \
    && "$PLUGIN_SOURCE_PATH" == "$path" ]]
}

_plugin_install_github() {
  local repo="$1" ref="$2"
  info "installing Herdr plugin: $repo@$ref"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "[dry-run] herdr plugin install $repo --ref $ref --yes"
    return 0
  fi
  herdr plugin install "$repo" --ref "$ref" --yes
}

_plugin_remove_registration() {
  local id="$1" kind="$2"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "[dry-run] herdr plugin $([[ "$kind" == "local" ]] && printf unlink || printf uninstall) $id"
    return 0
  fi
  if [[ "$kind" == "local" ]]; then
    herdr plugin unlink "$id"
  else
    herdr plugin uninstall "$id"
  fi
}

_herdr_plugin_registry_path() {
  printf '%s/herdr/plugins.json' "${XDG_CONFIG_HOME:-${HOME}/.config}"
}

_plugin_registry_source_path() {
  local registry="$1" id="$2"
  jq -er --arg id "$id" '
    [.[] | select(.plugin_id == $id)] |
    if length == 1 then (.[0].plugin_root // .[0].source.managed_path // "")
    else error("expected one plugin entry") end
  ' "$registry"
}

ensure_adopted_github_plugin() {
  local id="$1" repo="$2" ref="$3"

  if ! plugin_inspect "$id"; then
    warn "cannot safely inspect Herdr plugin $id; preserving it unchanged"
    return 0
  fi
  if plugin_is_exact_github "$repo" "$ref"; then
    info "unchanged: Herdr plugin $id ($repo@$ref)"
    return 0
  fi
  if [[ "$PLUGIN_STATUS" == "present" ]]; then
    warn "preserving pre-existing Herdr plugin $id: ${PLUGIN_SOURCE_RAW#- }"
    return 0
  fi

  _plugin_install_github "$repo" "$ref" || {
    warn "failed to install Herdr plugin $id from $repo@$ref"
    return 1
  }
  [[ "$DRY_RUN" -eq 1 ]] && return 0
  if plugin_inspect "$id" && plugin_is_exact_github "$repo" "$ref"; then
    return 0
  fi

  warn "Herdr reported success but $id is not registered at $repo@$ref"
  if [[ "$PLUGIN_STATUS" == "present" ]]; then
    _plugin_remove_registration "$id" "$PLUGIN_SOURCE_KIND" || true
  fi
  return 1
}

_managed_plugin_transaction() (
  local id="$1" repo="$2" ref="$3" previous_kind="$4"
  local previous_repo="$5" previous_ref="$6" previous_path="$7"
  local registry snapshot restore_tmp write_tmp source_path source_backup current_path
  local rollback_started=0 rollback_ok=0

  registry="$(_herdr_plugin_registry_path)"
  snapshot="${registry}.agentic-dev-backup.$$"
  restore_tmp="${registry}.agentic-dev-restore.$$"
  write_tmp="${registry}.agentic-dev-write.$$"
  source_path=""
  source_backup=""

  rollback() {
    [[ "$rollback_started" -eq 1 ]] || return 0
    trap '' HUP INT TERM
    # Optional hook after HUP/INT/TERM are masked. Tests use this to inject a
    # second TERM during rollback; production leaves it unset.
    ${AGENTIC_DEV_ON_ROLLBACK_ARMED:-:} || true
    rollback_ok=0
    # In-progress marker for the whole rollback. Keep it distinct from the
    # atomic write temp so fixtures can observe rollback before cleanup.
    : >"$restore_tmp" || rollback_ok=1

    current_path=""
    if [[ -f "$registry" ]]; then
      current_path="$(_plugin_registry_source_path "$registry" "$id" 2>/dev/null || true)"
    fi
    if [[ -n "$current_path" && "$current_path" != "$source_path" ]]; then
      warn "preserving failed-install artifact for $id: $current_path"
    fi

    if [[ "$previous_kind" == "local" ]]; then
      if [[ -d "$source_backup" ]]; then
        rm -rf "$previous_path" || rollback_ok=1
        mv "$source_backup" "$previous_path" || rollback_ok=1
      elif [[ ! -d "$previous_path" ]]; then
        rollback_ok=1
      fi
    else
      if [[ -d "$source_backup" ]]; then
        rm -rf "$source_path" || rollback_ok=1
        mv "$source_backup" "$source_path" || rollback_ok=1
      elif [[ ! -d "$source_path" ]]; then
        rollback_ok=1
      fi
    fi

    if [[ -f "$snapshot" ]]; then
      cp -p "$snapshot" "$write_tmp" && mv "$write_tmp" "$registry" || rollback_ok=1
    else
      rollback_ok=1
    fi

    if [[ "$rollback_ok" -eq 0 ]]; then
      warn "rolled back Herdr plugin $id to its previous $previous_kind source"
    else
      warn "rollback for Herdr plugin $id was incomplete; previous source: ${previous_path:-$previous_repo@$previous_ref}"
    fi
    rm -f "$restore_tmp" "$write_tmp" "$snapshot"
    rollback_started=0
    return "$rollback_ok"
  }

  # shellcheck disable=SC2329
  interrupted() {
    local status="$1"
    if [[ "$rollback_started" -eq 1 ]]; then
      rollback || true
    else
      trap '' HUP INT TERM
      rm -rf "$source_backup"
      rm -f "$restore_tmp" "$write_tmp" "$snapshot"
    fi
    exit "$status"
  }
  trap 'interrupted 129' HUP
  trap 'interrupted 130' INT
  trap 'interrupted 143' TERM

  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "[dry-run] snapshot complete Herdr registry and previous plugin source"
    info "[dry-run] transaction for $id: remove $previous_kind registration"
    if [[ "$previous_kind" == "local" ]]; then
      info "[dry-run] back up $previous_path before migration"
    fi
    _plugin_remove_registration "$id" "$previous_kind"
    _plugin_install_github "$repo" "$ref"
    info "[dry-run] verify $id is exactly $repo@$ref; restore registry/source snapshot on failure or interruption"
    return 0
  fi

  if [[ ! -f "$registry" ]] || ! jq -e 'type == "array"' "$registry" >/dev/null 2>&1; then
    warn "cannot transactionally update $id because the Herdr registry is missing or malformed: $registry"
    return 1
  fi
  source_path="$(_plugin_registry_source_path "$registry" "$id" 2>/dev/null)" || {
    warn "cannot transactionally update $id because its registry entry is ambiguous"
    return 1
  }
  [[ -n "$source_path" ]] || source_path="$previous_path"
  [[ -d "$source_path" ]] || {
    warn "legacy Herdr plugin source is stale or missing: $source_path"
    return 1
  }
  source_backup="${source_path}.agentic-dev-backup.$$"
  [[ ! -e "$snapshot" && ! -e "$restore_tmp" && ! -e "$write_tmp" && ! -e "$source_backup" ]] || {
    warn "refusing migration because a transaction backup path already exists"
    return 1
  }
  cp -p "$registry" "$snapshot" || return 1
  if [[ "$previous_kind" == "github" ]]; then
    cp -a "$source_path" "$source_backup" || {
      rm -f "$snapshot"
      return 1
    }
  fi

  rollback_started=1
  if ! _plugin_remove_registration "$id" "$previous_kind"; then
    rollback || true
    return 1
  fi
  if [[ "$previous_kind" == "local" ]] && ! mv "$source_path" "$source_backup"; then
    rollback || true
    return 1
  fi

  if ! _plugin_install_github "$repo" "$ref" \
    || ! plugin_inspect "$id" \
    || ! plugin_is_exact_github "$repo" "$ref"; then
    warn "transactional install failed for Herdr plugin $id; restoring previous registration"
    rollback || true
    return 1
  fi

  trap - HUP INT TERM
  rollback_started=0
  rm -rf "$source_backup"
  rm -f "$snapshot" "$restore_tmp" "$write_tmp"
)

ensure_managed_github_plugin() {
  local id="$1" repo="$2" ref="$3" legacy_path="$4"
  local previous_kind previous_repo previous_ref previous_path

  if ! plugin_inspect "$id"; then
    warn "cannot safely inspect managed Herdr plugin $id; preserving it unchanged"
    return 1
  fi
  if plugin_is_exact_github "$repo" "$ref"; then
    info "unchanged: managed Herdr plugin $id ($repo@$ref)"
    return 0
  fi
  if [[ "$PLUGIN_STATUS" == "missing" ]]; then
    ensure_adopted_github_plugin "$id" "$repo" "$ref"
    return
  fi

  previous_kind="$PLUGIN_SOURCE_KIND"
  previous_repo="$PLUGIN_SOURCE_REPO"
  previous_ref="$PLUGIN_SOURCE_REF"
  previous_path="$PLUGIN_SOURCE_PATH"
  if [[ "$previous_kind" == "local" && "$previous_path" != "$legacy_path" ]]; then
    warn "preserving Herdr plugin $id from unowned local source: $previous_path"
    return 0
  fi
  if [[ "$previous_kind" == "github" && "$previous_repo" != "$repo" ]]; then
    warn "preserving Herdr plugin $id from unowned GitHub source: $previous_repo@$previous_ref"
    return 0
  fi

  _managed_plugin_transaction "$id" "$repo" "$ref" \
    "$previous_kind" "$previous_repo" "$previous_ref" "$previous_path"
}

ensure_managed_local_plugin() {
  local id="$1" path="$2"
  if ! plugin_inspect "$id"; then
    warn "cannot safely inspect Herdr plugin $id; preserving its registration"
    return 0
  fi
  if plugin_is_exact_local "$path"; then
    info "unchanged: Herdr plugin $id linked at $path"
    return 0
  fi
  if [[ "$PLUGIN_STATUS" == "present" ]]; then
    warn "preserving pre-existing Herdr plugin $id: ${PLUGIN_SOURCE_RAW#- }"
    return 0
  fi
  info "linking Herdr plugin: $id"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "[dry-run] herdr plugin link $path"
  else
    # plugin link needs a running server (ENOENT otherwise).
    if ! herdr status server 2>/dev/null | grep -q '^status: running'; then
      herdr server >/dev/null 2>&1 &
      local _i
      for _i in 1 2 3 4 5 6 7 8 9 10; do
        herdr status server 2>/dev/null | grep -q '^status: running' && break
        sleep 0.2
      done
    fi
    herdr plugin link "$path" 2>/dev/null || herdr plugin link "$path" \
      || warn "herdr plugin link failed — run manually: herdr plugin link $path"
  fi
}

deploy_third_party_plugins() {
  ensure_adopted_github_plugin pickr "$PICKR_PLUGIN_REPO" "$PICKR_PLUGIN_REF"
  ensure_adopted_github_plugin worktrunk "$WORKTRUNK_PLUGIN_REPO" "$WORKTRUNK_PLUGIN_REF"
}

pickr_template_for_platform() {
  case "$(detect_os)" in
    linux) printf '%s' "config/pickr/config.linux.toml" ;;
    macos) printf '%s' "config/pickr/config.macos.toml" ;;
    *) return 1 ;;
  esac
}

herdr_template_for_platform() {
  case "$(detect_os)" in
    macos) printf '%s' "config/herdr/config.macos.toml" ;;
    *) printf '%s' "config/herdr/config.toml" ;;
  esac
}

deploy_pickr_config() {
  local config_dir dest template_rel
  if ! config_dir="$(herdr plugin config-dir pickr 2>/dev/null)" || [[ "$config_dir" != /* ]]; then
    warn "cannot resolve the pickr plugin config dir; keeping any existing pickr config"
    return 0
  fi
  dest="$config_dir/config.toml"
  if [[ -e "$dest" || -L "$dest" ]]; then
    info "keeping existing pickr config: $dest"
    return 0
  fi
  if ! template_rel="$(pickr_template_for_platform)"; then
    warn "no portable pickr defaults for platform $(detect_os); skipping"
    return 0
  fi
  deploy_install_file "$template_rel" "$dest"
}

nvim_config_dir() {
  printf '%s/nvim' "${XDG_CONFIG_HOME:-$HOME/.config}"
}

fresh_config_path() {
  printf '%s/fresh/config.json' "${XDG_CONFIG_HOME:-$HOME/.config}"
}

nvim_is_lazyvim() {
  local dir
  dir="$(nvim_config_dir)"
  [[ -f "$dir/lazyvim.json" ]] && return 0
  [[ -f "$dir/lua/config/lazy.lua" ]] || return 1
  grep -q 'LazyVim/LazyVim' "$dir/lua/config/lazy.lua"
}

deploy_nvim_explorer_defaults() {
  local dir dest plugins
  dir="$(nvim_config_dir)"
  plugins="$dir/lua/plugins"
  dest="$plugins/agentic-dev-explorer.lua"
  nvim_is_lazyvim || return 0
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "[dry-run] would write $dest (file tree on the right)"
    return 0
  fi
  ensure_dir "$plugins"
  deploy_install_file "config/nvim/lua/plugins/agentic-dev-explorer.lua" "$dest"
  info "nvim file tree: neo-tree/snacks on the right (LazyVim)"
}

deploy_fresh_explorer_defaults() {
  local dest dir tmp
  dest="$(fresh_config_path)"
  dir="$(dirname "$dest")"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "[dry-run] would set file_explorer.side=right in $dest"
    return 0
  fi
  ensure_dir "$dir"
  if [[ ! -f "$dest" ]]; then
    printf '%s\n' '{ "file_explorer": { "side": "right" } }' >"$dest"
    info "set Fresh file explorer side to right"
    return 0
  fi
  command -v jq >/dev/null 2>&1 || {
    warn "jq not available; skip Fresh file explorer side default"
    return 0
  }
  if jq -e '.file_explorer.side != null' "$dest" >/dev/null 2>&1; then
    info "keeping existing Fresh file explorer side"
    return 0
  fi
  tmp="$(mktemp)"
  if ! jq '.file_explorer.side = "right"' "$dest" >"$tmp"; then
    rm -f "$tmp"
    warn "could not parse $dest; skip Fresh file explorer side default"
    return 0
  fi
  mv "$tmp" "$dest"
  info "set Fresh file explorer side to right"
}

# Move ~/.config/agentic-dev and ~/.local/share/agentic-dev to bercail names.
migrate_agentic_dev_to_bercail() {
  if [[ ! -d "$AGENTIC_DEV_CONFIG_DIR" && -d "$LEGACY_AGENTIC_DEV_CONFIG_DIR" ]]; then
    info "migrating $LEGACY_AGENTIC_DEV_CONFIG_DIR → $AGENTIC_DEV_CONFIG_DIR"
    if [[ "$DRY_RUN" -eq 1 ]]; then
      info "[dry-run] would mv $LEGACY_AGENTIC_DEV_CONFIG_DIR $AGENTIC_DEV_CONFIG_DIR"
    else
      ensure_dir "$(dirname "$AGENTIC_DEV_CONFIG_DIR")"
      mv "$LEGACY_AGENTIC_DEV_CONFIG_DIR" "$AGENTIC_DEV_CONFIG_DIR"
    fi
  fi
  if [[ ! -d "$AGENTIC_DEV_SHARE_DIR" && -d "$LEGACY_AGENTIC_DEV_SHARE_DIR" ]]; then
    info "migrating $LEGACY_AGENTIC_DEV_SHARE_DIR → $AGENTIC_DEV_SHARE_DIR"
    if [[ "$DRY_RUN" -eq 1 ]]; then
      info "[dry-run] would mv $LEGACY_AGENTIC_DEV_SHARE_DIR $AGENTIC_DEV_SHARE_DIR"
    else
      ensure_dir "$(dirname "$AGENTIC_DEV_SHARE_DIR")"
      mv "$LEGACY_AGENTIC_DEV_SHARE_DIR" "$AGENTIC_DEV_SHARE_DIR"
    fi
  fi
}

write_user_config() {
  local cmd="$1"
  ensure_dir "$AGENTIC_DEV_CONFIG_DIR"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "[dry-run] would write $AGENTIC_DEV_USER_CONFIG (agent=$cmd review=tuicr)"
    return 0
  fi
  cat >"$AGENTIC_DEV_USER_CONFIG" <<EOF
[agent]
command = "$cmd"

[layout]
review = "tuicr"
auto_review = true
EOF
  info "saved config to $AGENTIC_DEV_USER_CONFIG"
}

# No install-time agent picker. Default is cursor-agent + pstack.
# Override [agent] command in config.toml yourself, then bercail reconfigure.
prompt_user_config() {
  if [[ -f "$AGENTIC_DEV_USER_CONFIG" ]]; then
    info "using existing agent command: $(read_agent_command)"
    info "review: $(read_layout_review)  editor: $(read_layout_file_editor)"
    return 0
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "[dry-run] would write default $AGENTIC_DEV_USER_CONFIG (agent=cursor-agent)"
    return 0
  fi
  ensure_dir "$AGENTIC_DEV_CONFIG_DIR"
  default_user_config >"$AGENTIC_DEV_USER_CONFIG"
  info "saved default config to $AGENTIC_DEV_USER_CONFIG (agent=cursor-agent)"
}

prompt_agent_command() {
  prompt_user_config
}

deploy_tree() {
  local src="$1"
  local dest="$2"
  [[ -d "$src" ]] || return 0
  ensure_dir "$dest"
  while IFS= read -r -d '' file; do
    local sub="${file#"$src"/}"
    copy_file "$file" "$dest/$sub"
  done < <(find "$src" -type f -print0)
}

deploy_install_file() {
  local rel="$1" dest="$2"
  local src
  src="$(install_src_dir)"
  if [[ -d "$src" ]]; then
    copy_file "$src/$rel" "$dest"
  else
    fetch_file "$rel" "$dest"
  fi
}

deploy_agentic_dev_config() {
  local src file sub
  src="$(install_src_dir)"
  if [[ -d "$src" ]]; then
    while IFS= read -r -d '' file; do
      sub="${file#"$src/config/agentic-dev"/}"
      [[ "$sub" == "config.toml" ]] && continue
      copy_file "$file" "$AGENTIC_DEV_CONFIG_DIR/$sub"
    done < <(find "$src/config/agentic-dev" -type f -print0 2>/dev/null)
  else
    deploy_install_file "config/agentic-dev/config-reader.sh" "$AGENTIC_DEV_CONFIG_DIR/config-reader.sh"
    deploy_install_file "config/agentic-dev/config.toml.example" "$AGENTIC_DEV_CONFIG_DIR/config.toml.example"
  fi
}

deploy_lib() {
  local src
  src="$(install_src_dir)"
  if [[ -d "$src" ]]; then
    deploy_tree "$src/lib" "${AGENTIC_DEV_SHARE_DIR}/lib"
  else
    local libfile
    for libfile in common.sh detect.sh deps.sh config.sh skills.sh shell-rc.sh uninstall.sh help.sh omarchy.sh doctor.sh; do
      deploy_install_file "lib/$libfile" "${AGENTIC_DEV_SHARE_DIR}/lib/$libfile"
    done
  fi
}

_recorded_install_source() {
  local src
  [[ -f "$AGENTIC_DEV_SOURCE_PATH_FILE" ]] || return 1
  src="$(<"$AGENTIC_DEV_SOURCE_PATH_FILE")"
  [[ -n "$src" && -d "$src" && -f "$src/install.sh" && -d "$src/config" ]] || return 1
  printf '%s' "$src"
}

migrate_cursor_cli_command() {
  local dest="$AGENTIC_DEV_USER_CONFIG" tmp
  [[ -f "$dest" ]] || return 0
  grep -Eq '^command[[:space:]]*=[[:space:]]*"agent"[[:space:]]*$' "$dest" || return 0
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "[dry-run] would migrate agent command agent → cursor-agent"
    return 0
  fi
  tmp="$(mktemp)"
  awk '
    /^command[[:space:]]*=[[:space:]]*"agent"[[:space:]]*$/ {
      sub(/"agent"/, "\"cursor-agent\"")
    }
    { print }
  ' "$dest" >"$tmp"
  mv "$tmp" "$dest"
  info "migrated agent command to cursor-agent"
}

record_install_source() {
  local src
  src="$(install_src_dir)"
  [[ -d "$src" && -f "$src/install.sh" && -d "$src/config" ]] || return 0
  ensure_dir "$AGENTIC_DEV_SHARE_DIR"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "[dry-run] would record install source $src"
    return 0
  fi
  printf '%s\n' "$src" >"$AGENTIC_DEV_SOURCE_PATH_FILE"
  info "recorded install source: $src"
}

migrate_file_editor_config() {
  local dest="$AGENTIC_DEV_USER_CONFIG" tmp
  [[ -f "$dest" ]] || return 0
  grep -qE '^[[:space:]]*editor[[:space:]]*=' "$dest" && return 0
  grep -qE '^[[:space:]]*file_editor[[:space:]]*=' "$dest" || return 0
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "[dry-run] would migrate layout file_editor → editor in $dest"
    return 0
  fi
  tmp="$(mktemp)"
  awk '
    BEGIN { in_layout = 0 }
    /^\[layout\]/ { in_layout = 1 }
    /^\[/ && $0 != "[layout]" { in_layout = 0 }
    in_layout && /^[[:space:]]*file_editor[[:space:]]*=/ {
      sub(/file_editor/, "editor")
    }
    { print }
  ' "$dest" >"$tmp"
  mv "$tmp" "$dest"
  info "migrated layout file_editor → editor in $dest"
}

# Drop the previous fresh default so EDITOR/VISUAL (or a stock terminal
# editor) wins. An explicit non-fresh editor= in config is kept.
# Default review tool is tuicr. Leave a custom hunk command (extra flags) alone.
migrate_hunk_review_to_tuicr() {
  local dest="$AGENTIC_DEV_USER_CONFIG" tmp
  [[ -f "$dest" ]] || return 0
  grep -qE '^[[:space:]]*review[[:space:]]*=[[:space:]]*"(hunk|hunk diff)"[[:space:]]*$' "$dest" || return 0
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "[dry-run] would migrate layout review hunk → tuicr in $dest"
    return 0
  fi
  tmp="$(mktemp)"
  awk '
    BEGIN { in_layout = 0 }
    /^\[layout\]/ { in_layout = 1 }
    /^\[/ && $0 != "[layout]" { in_layout = 0 }
    in_layout && /^[[:space:]]*review[[:space:]]*=[[:space:]]*"(hunk|hunk diff)"[[:space:]]*$/ {
      sub(/"(hunk|hunk diff)"/, "\"tuicr\"")
    }
    { print }
  ' "$dest" >"$tmp"
  mv "$tmp" "$dest"
  info "migrated layout review to tuicr in $dest"
}

migrate_fresh_editor_default() {
  local dest="$AGENTIC_DEV_USER_CONFIG" tmp
  [[ -f "$dest" ]] || return 0
  grep -qE '^[[:space:]]*(file_)?editor[[:space:]]*=[[:space:]]*"fresh"[[:space:]]*$' "$dest" || return 0
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "[dry-run] would drop default editor=fresh in $dest"
    return 0
  fi
  tmp="$(mktemp)"
  awk '
    BEGIN { in_layout = 0 }
    /^\[layout\]/ { in_layout = 1 }
    /^\[/ && $0 != "[layout]" { in_layout = 0 }
    in_layout && /^[[:space:]]*(file_)?editor[[:space:]]*=[[:space:]]*"fresh"[[:space:]]*$/ { next }
    { print }
  ' "$dest" >"$tmp"
  mv "$tmp" "$dest"
  info "dropped default editor=fresh in $dest (using EDITOR or a stock terminal editor)"
}

migrate_legacy_layout_plugin() {
  local old_id="$LEGACY_LAYOUT_PLUGIN_ID"
  local status kind repo ref path
  if ! plugin_inspect "$old_id"; then
    return 0
  fi
  status="$PLUGIN_STATUS"
  kind="$PLUGIN_SOURCE_KIND"
  repo="$PLUGIN_SOURCE_REPO"
  ref="$PLUGIN_SOURCE_REF"
  path="$PLUGIN_SOURCE_PATH"
  if [[ "$status" == "missing" ]]; then
    return 0
  fi
  if [[ "$kind" == "github" && "$repo" == "$LEGACY_DEV_LAYOUT_PLUGIN_REPO" ]]; then
    info "removing legacy layout plugin $old_id ($repo@$ref)"
    _plugin_remove_registration "$old_id" github || warn "failed to remove $old_id"
    return 0
  fi
  if [[ "$kind" == "local" && "$path" == "$HERDR_DEV_LAYOUT_LEGACY_DIR" ]]; then
    info "unlinking legacy layout plugin $old_id at $path"
    _plugin_remove_registration "$old_id" local || warn "failed to unlink $old_id"
    return 0
  fi
  warn "preserving unowned legacy layout plugin $old_id (${PLUGIN_SOURCE_RAW#- })"
}

deploy_plugin() {
  if command -v herdr >/dev/null 2>&1; then
    require_herdr_min_version || return 1
    migrate_legacy_layout_plugin
    ensure_managed_github_plugin \
      "$PLUGIN_ID" \
      "$DEV_LAYOUT_PLUGIN_REPO" \
      "$DEV_LAYOUT_PLUGIN_REF" \
      "$HERDR_DEV_LAYOUT_LEGACY_DIR"
    deploy_third_party_plugins
    deploy_pickr_config
  else
    warn "herdr not on PATH — skipping managed plugin install ($DEV_LAYOUT_PLUGIN_REPO@$DEV_LAYOUT_PLUGIN_REF)"
  fi
}

# Helpers and the shipped template use Branch_Repo. Existing configs from before
# that rename still expand Repo_Branch, so wtd/dev miss workspaces created by
# the other side. Rewrite only that exact default S= line.
WORKTRUNK_SESSION_LABEL_OLD='S="{{ repo | capitalize }}_{{ branch | capitalize }}"'
WORKTRUNK_SESSION_LABEL_NEW='S="{{ branch | capitalize }}_{{ repo | capitalize }}"'

migrate_worktrunk_session_labels() {
  local dest="$WORKTRUNK_CONFIG_DIR/config.toml"
  local tmp line
  [[ -f "$dest" ]] || return 0
  grep -Fq "$WORKTRUNK_SESSION_LABEL_OLD" "$dest" || return 0
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "[dry-run] would migrate worktrunk session labels in $dest"
    return 0
  fi
  tmp="$(mktemp)"
  while IFS= read -r line || [[ -n "$line" ]]; do
    printf '%s\n' "${line//"$WORKTRUNK_SESSION_LABEL_OLD"/"$WORKTRUNK_SESSION_LABEL_NEW"}"
  done <"$dest" >"$tmp"
  mv "$tmp" "$dest"
  info "migrated worktrunk session labels to Branch_Repo in $dest"
}

# Worktrunk post-start must not inherit WT_HERDR_AGENT_PROMPT from a parent agent
# shell — that double-submits with the handoff skill's create.
migrate_worktrunk_clear_handoff_prompt() {
  local dest="$WORKTRUNK_CONFIG_DIR/config.toml"
  local tmp
  [[ -f "$dest" ]] || return 0
  grep -q 'wt_herdr_layout_create' "$dest" || return 0
  grep -q 'unset WT_HERDR_AGENT_PROMPT' "$dest" && return 0
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "[dry-run] would isolate handoff prompt in $dest post-start"
    return 0
  fi
  tmp="$(mktemp)"
  awk '
    /wt_herdr_layout_create/ && !seen_unset {
      print "unset WT_HERDR_AGENT_PROMPT"
      seen_unset = 1
    }
    { print }
  ' "$dest" >"$tmp"
  mv "$tmp" "$dest"
  info "migrated worktrunk post-start to unset WT_HERDR_AGENT_PROMPT in $dest"
}

# Existing installs kept the old 3-tab (review/explorer/terminal) echo copy.
migrate_worktrunk_layout_echo() {
  local dest="$WORKTRUNK_CONFIG_DIR/config.toml" tmp
  [[ -f "$dest" ]] || return 0
  grep -Fq 'tabs: review, explorer, terminal' "$dest" || return 0
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "[dry-run] would migrate worktrunk post-start layout echo in $dest"
    return 0
  fi
  tmp="$(mktemp)"
  awk '
    /tabs: review, explorer, terminal/ {
      sub(/Layout: agent pane \(left, sticky\) \| tabs: review, explorer, terminal/,
          "Layout: agent pane | review/shell center | files pane")
    }
    /review\/explorer\/terminal/ {
      sub(/Switch tabs: Alt\+1\.\.3 \(review\/explorer\/terminal\), prefix\+1 focuses agent, prefix\+2\.\.4 same tabs/,
          "Switch: prefix+1 agent, +2 review, +3 shell, +b/+e files, +g git")
    }
    { print }
  ' "$dest" >"$tmp"
  mv "$tmp" "$dest"
  info "migrated worktrunk post-start layout echo in $dest"
}

deploy_finalize_permissions() {
  run chmod +x "$LOCAL_BIN/bercail" "$LOCAL_BIN/agentic-dev" \
    "$WORKTRUNK_CONFIG_DIR/herdr-layout.sh" \
    "$AGENTIC_DEV_SHELL_DIR/bercail.sh" \
    "$AGENTIC_DEV_SHELL_DIR/bercail.zsh" \
    "$AGENTIC_DEV_SHELL_DIR/bercail.inc.sh" \
    "$AGENTIC_DEV_CONFIG_DIR/config-reader.sh" 2>/dev/null || true
  find "${AGENTIC_DEV_SHARE_DIR}/lib" -name '*.sh' -exec chmod +x {} + 2>/dev/null || true
}

deploy_configs() {
  local herdr_rel
  herdr_rel="$(herdr_template_for_platform)"
  local -a files=(
    "config/shell/bercail.inc.sh|${AGENTIC_DEV_SHELL_DIR}/bercail.inc.sh"
    "config/bash/bercail.sh|${AGENTIC_DEV_SHELL_DIR}/bercail.sh"
    "config/zsh/bercail.zsh|${AGENTIC_DEV_SHELL_DIR}/bercail.zsh"
    "${herdr_rel}|${HERDR_CONFIG_DIR}/config.toml"
    "config/worktrunk/herdr-layout.sh|${WORKTRUNK_CONFIG_DIR}/herdr-layout.sh"
    "bin/bercail|${LOCAL_BIN}/bercail"
    "bin/agentic-dev|${LOCAL_BIN}/agentic-dev"
  )
  local entry rel dest

  migrate_agentic_dev_to_bercail
  prompt_user_config
  migrate_cursor_cli_command
  migrate_file_editor_config
  migrate_fresh_editor_default
  migrate_hunk_review_to_tuicr

  ensure_dir "$AGENTIC_DEV_CONFIG_DIR"
  ensure_dir "$AGENTIC_DEV_SHELL_DIR"
  ensure_dir "$HERDR_CONFIG_DIR"
  ensure_dir "$WORKTRUNK_CONFIG_DIR"
  ensure_dir "$AGENTIC_DEV_SHARE_DIR"

  for entry in "${files[@]}"; do
    rel="${entry%%|*}"
    dest="${entry#*|}"
    deploy_install_file "$rel" "$dest"
  done

  deploy_agentic_dev_config
  deploy_lib
  if [[ -f "${AGENTIC_DEV_SHARE_DIR}/lib/config.sh" ]]; then
    # deploy_lib may have pulled a newer lib/; reload the plugin pin before install.
    # shellcheck source=/dev/null
    source "${AGENTIC_DEV_SHARE_DIR}/lib/config.sh"
  fi
  deploy_plugin
  deploy_skills

  if [[ ! -f "$WORKTRUNK_CONFIG_DIR/config.toml" ]] || [[ "$FORCE" -eq 1 ]]; then
    deploy_install_file "config/worktrunk/config.toml" "$WORKTRUNK_CONFIG_DIR/config.toml"
  else
    info "keeping existing worktrunk config: $WORKTRUNK_CONFIG_DIR/config.toml"
    migrate_worktrunk_session_labels
    migrate_worktrunk_clear_handoff_prompt
    migrate_worktrunk_layout_echo
  fi

  deploy_finalize_permissions
  record_install_source
  ensure_selected_agent
  ensure_selected_layout_tools
  if declare -F sync_omarchy_default_agent >/dev/null 2>&1; then
    sync_omarchy_default_agent
  fi
}
