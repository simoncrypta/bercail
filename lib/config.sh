#!/usr/bin/env bash
# shellcheck shell=bash

default_user_config() {
  cat <<'EOF'
[agent]
command = "cursor-agent"

[layout]
review = "tuicr"
# Open Review when the desk agent finishes (`tuicr -w`: uncommitted changes
# only, watching; agents stage and do not commit). Someone else's PR uses `tuicr pr`.
# Set false to open Review only with Ctrl+Shift+R.
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

read_layout_review() {
  ensure_config_reader || true
  if declare -F agentic_dev_layout_review >/dev/null 2>&1; then
    agentic_dev_layout_review
  else
    printf '%s' "tuicr"
  fi
}

RECONFIGURE=0

# The Herdr app half of bercail: the bercail layout, its desk mod, and its keys.
# Paths are relative to config/herdr-app in the source and to the app's home.
HERDR_APP_LAYOUT="layouts/bercail.json"
HERDR_APP_MOD_FILES=(mods/bercail-desk/main.js mods/bercail-desk/mod.json)
HERDR_APP_KEYS_SECTION="layout:bercail"

# The app rewrites its layout file (the desk mod points the agent block with
# layout.set), so the layout is copied only when missing or when bercail ships
# a new one. The last shipped copy is kept to tell the two apart.
_herdr_app_shipped_layout() {
  printf '%s/herdr-app/%s' "$AGENTIC_DEV_SHARE_DIR" "$HERDR_APP_LAYOUT"
}

# The layout without what the app changes at run time: the desk's terminal,
# which stack child shows, and column weights.
_herdr_app_layout_shape() {
  jq -S 'walk(if type == "object" then
      del(.active)
      | if .id == "agent" then del(.content) else . end
      | if (.size | type) == "object" then del(.size.weight) else . end
    else . end)' "$1" 2>/dev/null
}

deploy_herdr_app_layout() {
  local dest="$HERDR_APP_CONFIG_DIR/$HERDR_APP_LAYOUT" shipped new
  shipped="$(_herdr_app_shipped_layout)"
  new="$(mktemp)"
  if ! DRY_RUN=0 deploy_install_file "config/herdr-app/$HERDR_APP_LAYOUT" "$new" >/dev/null; then
    rm -f "$new"
    warn "could not read the shipped bercail layout"
    return 1
  fi
  if [[ "$FORCE" -ne 1 && -f "$dest" ]]; then
    if [[ -f "$shipped" ]] && cmp -s "$new" "$shipped"; then
      info "unchanged: $dest (layout changes made in the app stay)"
      rm -f "$new"
      return 0
    fi
    if [[ ! -f "$shipped" ]] && ! cmp -s "$new" "$dest"; then
      if [[ "$(_herdr_app_layout_shape "$new")" == "$(_herdr_app_layout_shape "$dest")" ]]; then
        # bercail's layout as the app left it: adopt it, keep the app's values.
        info "unchanged: $dest (layout changes made in the app stay)"
        [[ "$DRY_RUN" -eq 1 ]] || DRY_RUN=0 copy_file "$new" "$shipped" >/dev/null
      else
        info "keeping existing $dest (bercail update --force replaces it)"
      fi
      rm -f "$new"
      return 0
    fi
  fi
  copy_file "$new" "$dest"
  [[ "$DRY_RUN" -eq 1 ]] || copy_file "$new" "$shipped" >/dev/null
  rm -f "$new"
}

# keys.json is the person's: only the layout:bercail section is bercail's.
deploy_herdr_app_keys() {
  local keys="$HERDR_APP_CONFIG_DIR/keys.json" ours tmp base
  ours="$(mktemp)"
  tmp="$(mktemp)"
  base="$keys"
  if [[ ! -f "$keys" ]]; then
    base="$(mktemp)"
    printf '{}\n' >"$base"
  fi
  if ! DRY_RUN=0 deploy_install_file "config/herdr-app/keys.json" "$ours" >/dev/null \
    || ! jq --arg s "$HERDR_APP_KEYS_SECTION" --slurpfile ours "$ours" \
      '.[$s] = $ours[0][$s]' "$base" >"$tmp"; then
    warn "could not merge the $HERDR_APP_KEYS_SECTION keys into $keys; copy that section from config/herdr-app/keys.json"
    rm -f "$ours" "$tmp"
    [[ "$base" == "$keys" ]] || rm -f "$base"
    return 0
  fi
  rm -f "$ours"
  [[ "$base" == "$keys" ]] || rm -f "$base"
  if [[ -f "$keys" ]] && jq -e --slurpfile new "$tmp" '. == $new[0]' "$keys" >/dev/null 2>&1; then
    info "unchanged: $keys ($HERDR_APP_KEYS_SECTION)"
    rm -f "$tmp"
    return 0
  fi
  info "install: $keys ($HERDR_APP_KEYS_SECTION section)"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    rm -f "$tmp"
    return 0
  fi
  mv "$tmp" "$keys"
}

deploy_herdr_app() {
  local rel
  if ! command -v herdr-app >/dev/null 2>&1; then
    warn "Herdr app not found: install it from https://herdr.dev, then run: bercail update"
    return 0
  fi
  ensure_dir "$HERDR_APP_CONFIG_DIR"
  deploy_herdr_app_layout || true
  for rel in "${HERDR_APP_MOD_FILES[@]}"; do
    deploy_install_file "config/herdr-app/$rel" "$HERDR_APP_CONFIG_DIR/$rel"
  done
  deploy_herdr_app_keys || true
  if [[ "$DRY_RUN" -ne 1 ]] \
    && ! herdr-app check "$HERDR_APP_CONFIG_DIR/mods/bercail-desk" >/dev/null 2>&1; then
    warn "herdr-app check failed for the bercail-desk mod; run: herdr-app check $HERDR_APP_CONFIG_DIR/mods/bercail-desk"
  fi
  info "Herdr app: switch to the bercail layout with Ctrl+Shift+L"
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

# No install-time agent picker. The desk agent defaults to cursor-agent until
# one is picked on the desk.
# Override [agent] command in config.toml yourself, then bercail reconfigure.
prompt_user_config() {
  if [[ -f "$AGENTIC_DEV_USER_CONFIG" ]]; then
    info "using existing agent command: $(read_agent_command)"
    info "review: $(read_layout_review)"
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
    for libfile in common.sh detect.sh deps.sh config.sh skills.sh shell-rc.sh uninstall.sh help.sh omarchy.sh notify.sh doctor.sh harness.sh; do
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

# Existing installs echo the terminal herdr's layout and prefix keys after
# post-start. Replace those echo lines with the Herdr app's.
migrate_worktrunk_layout_echo() {
  local dest="$WORKTRUNK_CONFIG_DIR/config.toml" tmp
  [[ -f "$dest" ]] || return 0
  grep -Eq 'echo "(✓ Herdr worktree group|  Layout:|  Switch|  Attach with: herdr)' "$dest" || return 0
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "[dry-run] would migrate worktrunk post-start echo in $dest"
    return 0
  fi
  tmp="$(mktemp)"
  awk '
    /^echo "(✓ Herdr worktree group|  Layout:|  Switch|  Attach with: herdr)/ {
      if (!done) {
        print "echo \"✓ Herdr space '"'"'$S'"'"' ready\""
        print "echo \"  Desk: Ctrl+Shift+A agent, Ctrl+Shift+R review, Ctrl+Shift+S shell, Ctrl+Shift+F/G files/changes\""
        done = 1
      }
      next
    }
    { print }
  ' "$dest" >"$tmp"
  mv "$tmp" "$dest"
  info "migrated worktrunk post-start echo in $dest"
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
  local -a files=(
    "config/shell/bercail.inc.sh|${AGENTIC_DEV_SHELL_DIR}/bercail.inc.sh"
    "config/bash/bercail.sh|${AGENTIC_DEV_SHELL_DIR}/bercail.sh"
    "config/zsh/bercail.zsh|${AGENTIC_DEV_SHELL_DIR}/bercail.zsh"
    "config/worktrunk/herdr-layout.sh|${WORKTRUNK_CONFIG_DIR}/herdr-layout.sh"
    "bin/bercail|${LOCAL_BIN}/bercail"
    "bin/agentic-dev|${LOCAL_BIN}/agentic-dev"
  )
  local entry rel dest

  migrate_agentic_dev_to_bercail
  prompt_user_config
  migrate_cursor_cli_command
  migrate_hunk_review_to_tuicr

  ensure_dir "$AGENTIC_DEV_CONFIG_DIR"
  ensure_dir "$AGENTIC_DEV_SHELL_DIR"
  ensure_dir "$WORKTRUNK_CONFIG_DIR"
  ensure_dir "$AGENTIC_DEV_SHARE_DIR"

  for entry in "${files[@]}"; do
    rel="${entry%%|*}"
    dest="${entry#*|}"
    if [[ "$rel" == bin/bercail && "${BERCAIL_PACKAGED:-0}" == 1 ]]; then
      info "keeping bercail from mise/packslip on PATH; not copying $dest"
      continue
    fi
    deploy_install_file "$rel" "$dest"
    # Executable now, not only in deploy_finalize_permissions: a later step
    # can fail and leave the CLI unusable otherwise.
    if [[ "$rel" == bin/* ]]; then
      run chmod +x "$dest"
    fi
  done

  deploy_agentic_dev_config
  deploy_lib
  if [[ -f "${AGENTIC_DEV_SHARE_DIR}/lib/config.sh" ]]; then
    # deploy_lib may have pulled a newer lib/; reload it before the steps below.
    # shellcheck source=/dev/null
    source "${AGENTIC_DEV_SHARE_DIR}/lib/config.sh"
  fi
  # First update from an older bercail still runs the previous deploy_configs,
  # so re-run after the new lib is on disk.
  if declare -F migrate_hunk_review_to_tuicr >/dev/null; then
    migrate_hunk_review_to_tuicr
  fi
  deploy_herdr_app
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
