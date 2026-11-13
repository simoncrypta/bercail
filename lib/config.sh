#!/usr/bin/env bash
# shellcheck shell=bash

# An update that replaces the CLI running it is the old release's code copying
# the new release's files: old steps, and old lists that do not name what the
# new release added. Start again on the new CLI, whose update runs the source
# tree's own bercail (update_from_tree in bin/bercail). Once per update. Only
# v0.14.0's updater gets here.
restart_update() {
  [[ -z "${BERCAIL_UPDATE_RESTARTED:-}" ]] || return 0
  local -a args=(update)
  local lib rel
  # The libs v0.14.0's list leaves out, which the new ones load. Fetched with its
  # own deploy_install_file, so a restart whose download fails still runs.
  lib="$(dirname "${BASH_SOURCE[0]}")"
  for rel in skills/handoff/scripts/toml.sh skills/handoff/scripts/pi-log.sh lib/shep-context.sh lib/describe.sh; do
    deploy_install_file "$rel" "$lib/${rel##*/}" || warn "could not fetch $rel; run bercail update again"
  done
  [[ "${FORCE:-0}" -ne 1 ]] || args+=(--force)
  # The release v0.14.0 already resolved, so both halves read the same one.
  if [[ -z "${BERCAIL_REF:-}" && "${GITHUB_RAW_BASE:-}" == https://raw.githubusercontent.com/simoncrypta/bercail/?* ]]; then
    export BERCAIL_REF="${GITHUB_RAW_BASE#https://raw.githubusercontent.com/simoncrypta/bercail/}"
  fi
  info "restarting the update on the new bercail"
  BERCAIL_UPDATE_RESTARTED=1 exec bash "$LOCAL_BIN/bercail" "${args[@]}"
}

# deploy_configs loads this file again once the lib/ on disk is no longer the
# one it runs from. v0.14.0 does it on every update, right after copying lib/.
# Nothing below this line may run in that process: its names are the old release's.
if [[ "${FUNCNAME[1]:-}" == deploy_configs ]]; then
  restart_update
fi

default_user_config() {
  cat <<'EOF'
[layout]
review = "tuicr"
# Open Review when the desk agent finishes (`tuicr -w`: uncommitted changes
# only, watching; agents stage and do not commit). Someone else's PR uses `tuicr pr`.
# Set false to open Review only with Ctrl+Shift+R.
auto_review = true

[bstack]
# Pi with your own logins. `bercail bstack setup` shows what's missing.
# A model per provider. Empty: auto, the newest model of each connected plan
# (re-picked on bercail update). Set a provider/model id to pin one; :high sets its level.
claude = ""
gpt = ""
grok = ""
# Reasoning effort of auto models: low, medium, high, xhigh, max, or none (the
# provider's default). A model without that level gets the next one down.
effort = "high"
# Which provider each role uses: claude, gpt, grok, or a full model id.
lead = "claude"
build = "grok"
judge = "claude"
EOF
}

# [layout] review, or tuicr. toml.sh is sourced here, not at the top: a v0.14.0
# updater sources this file before lib/toml.sh is on disk.
read_layout_review() {
  local review="tuicr"
  if [[ -r "$BERCAIL_USER_CONFIG" ]]; then
    # shellcheck source=lib/toml.sh
    source "$(dirname "${BASH_SOURCE[0]}")/toml.sh"
    review="$(toml_value "$BERCAIL_USER_CONFIG" layout review tuicr)"
  fi
  [[ "$review" == hunk ]] && review="hunk diff"
  printf '%s' "$review"
}

# Every key bercail reads in config.toml, one "section key" a line; the example
# in docs/config.md shows the same ones. [git] takes a repo path as its key,
# and each [policy."<repo>"] takes the policy keys.
BERCAIL_CONFIG_KEYS='layout review
layout auto_review
bstack fallback
bstack claude
bstack gpt
bstack grok
bstack effort
bstack lead
bstack build
bstack judge
shep compact_at
shep keep_recent
shep rollover
policy commit
policy push
policy integrate
policy pr_draft
policy release
policy agent_may_release
policy rules'

# bercail config get SECTION KEY: the value as bercail reads it. No output and
# status 1 when it is not set.
cmd_config() {
  local status=0
  [[ $# -eq 3 && "$1" == get ]] || die "usage: bercail config get <section> <key>"
  # shellcheck source=lib/toml.sh
  source "$(dirname "${BASH_SOURCE[0]}")/toml.sh"
  toml_get "$BERCAIL_USER_CONFIG" "$2" "$3" >/dev/null 2>&1 || status=$?
  [[ "$status" -ne 1 ]] || return 1
  toml_value "$BERCAIL_USER_CONFIG" "$2" "$3"
  printf '\n'
}

# config.toml keys that nothing reads (a key from an older release, a typo),
# [git] values that are no backend, and lines the reader cannot take. Each one
# changes nothing without a word, so doctor names it; it is not a failure.
doctor_config() {
  local line
  [[ -f "$BERCAIL_USER_CONFIG" ]] || return 0
  # shellcheck source=lib/toml.sh
  source "$(dirname "${BASH_SOURCE[0]}")/toml.sh"
  while IFS= read -r line; do
    log "  $line"
  done < <(toml_records "$BERCAIL_USER_CONFIG" | jq -r --arg known "$BERCAIL_CONFIG_KEYS" '
    def name: if test("^[A-Za-z0-9_-]+$") then . else tojson end;
    ($known | split("\n")) as $known
    | if has("error") then "unread  config.toml line \(.line): \(.error)"
      elif .section == ["git"] then
        (.value // .raw) as $v
        | select($v | IN("gh", "gt", "origin") | not)
        | "unknown  [git] \(.key | name) = \($v) (use gh, gt, or origin)"
      else
        # A bare [policy] names no repo, so nothing reads its keys either.
        (if .section == ["policy"] then "" elif (.section | length) == 2 and .section[0] == "policy" then "policy" else .section | join(".") end) as $table
        | "\($table) \(.key)" as $name
        | select($known | index($name) | not)
        | "unknown  [\(.section | map(name) | join("."))] \(.key) (nothing reads it)"
      end' | awk '!seen[$0]++')
}

# shellcheck disable=SC2034 # Read by the installer that sources this library.
RECONFIGURE=0

# The Herdr app half of bercail: the bercail layout, its mods (the desk, Shep's
# view, the spaces list that switches to a space, and the agents list, which also
# lists each desk and opens agents in a dialog), and its keys.
# Paths are relative to bercail/ (the shared layout folder) in the source and to the app's home.
HERDR_APP_LAYOUT="layouts/bercail.json"
HERDR_APP_MODS=(bercail-desk bercail-shep bercail-spaces bercail-agents bercail-review)
HERDR_APP_MOD_FILES=(mods/bercail-desk/main.js mods/bercail-desk/mod.json
  mods/bercail-shep/main.js mods/bercail-shep/mod.json
  mods/bercail-spaces/main.js mods/bercail-spaces/mod.json
  mods/bercail-agents/main.js mods/bercail-agents/mod.json
  mods/bercail-review/main.js mods/bercail-review/mod.json)
HERDR_APP_KEYS_SECTION="layout:bercail"

# The app rewrites its layout file (the desk mod adds a block per desk with
# layout.set), so the layout is copied only when missing or when bercail ships
# a new one. The last shipped copy is kept to tell the two apart.
_herdr_app_shipped_layout() {
  printf '%s/herdr-app/%s' "$BERCAIL_SHARE_DIR" "$HERDR_APP_LAYOUT"
}

# The layout without what the app changes at run time: the desks' and Shep's blocks
# (and the shared agent block of older layouts), which stack child shows, which view
# shows, and column weights.
_herdr_app_layout_shape() {
  jq -S 'walk(if type == "object" then
      del(.active)
      | if .id == "shep" or .id == "work" then del(.hidden) else . end
      | if .id == "agent-stack" then .children |= map(select(.id != "agent" and (.id | startswith("desk-") | not))) else . end
      | if .id == "shep-stack" then .children |= map(select(.id == "shep-empty")) else . end
      | if (.size | type) == "object" then del(.size.weight) else . end
    else . end)' "$1" 2>/dev/null
}

# The shipped layout ($1) with the desk blocks of the app's copy ($2) in its agent
# stack, and the desk it showed: a running desk mod doesn't add a block it added before.
_herdr_app_layout_with_desks() {
  jq --slurpfile live "$2" '
    [$live[0] | .. | objects | select(.id == "agent-stack")][0] as $old
    | [$old.children[]? | select(.id // "" | startswith("desk-"))] as $desks
    | $old.active as $shown
    | walk(if type == "object" and .id == "agent-stack" then
        .children += $desks
        | if any(.children[]; .id == $shown) then .active = $shown else . end
      else . end)' "$1" 2>/dev/null
}

deploy_herdr_app_layout() {
  local dest="$HERDR_APP_CONFIG_DIR/$HERDR_APP_LAYOUT" shipped new
  shipped="$(_herdr_app_shipped_layout)"
  new="$(mktemp)"
  if ! DRY_RUN=0 deploy_install_file "bercail/$HERDR_APP_LAYOUT" "$new" >/dev/null; then
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
  local out="$new" merged
  merged="$(mktemp)"
  if [[ -f "$dest" ]] && _herdr_app_layout_with_desks "$new" "$dest" >"$merged"; then
    out="$merged"
  fi
  copy_file "$out" "$dest"
  [[ "$DRY_RUN" -eq 1 ]] || copy_file "$new" "$shipped" >/dev/null
  rm -f "$new" "$merged"
}

# keys.json is the person's: only the layout:bercail section is bercail's, and in it
# only the keys still as bercail last shipped them. The last shipped section is kept
# to tell the two apart; with none kept, the section is the person's own.
_herdr_app_shipped_keys() {
  printf '%s/herdr-app/keys.json' "$BERCAIL_SHARE_DIR"
}

# The section bercail ships now and the one it shipped last, compact, one per line.
_herdr_app_keys_sections() {
  local ours="$1" shipped
  shipped="$(_herdr_app_shipped_keys)"
  jq -c --arg s "$HERDR_APP_KEYS_SECTION" '.[$s]' "$ours" || return 1
  if [[ -f "$shipped" ]]; then
    jq -c --arg s "$HERDR_APP_KEYS_SECTION" '.[$s] // {}' "$shipped" || return 1
  else
    printf '{}\n'
  fi
}

# Merge bercail's section into keys.json (stdin), per key:
# - still as bercail last shipped it: bercail's now (or gone, when bercail dropped it);
# - changed or added by the person: theirs;
# - removed by the person: stays removed, unless bercail binds it to something new.
_herdr_app_keys_merge() {
  jq --arg s "$HERDR_APP_KEYS_SECTION" --argjson new "$1" --argjson old "$2" '
    .[$s] as $mine
    | if $mine == null then .[$s] = $new else
        .[$s] = reduce (($new + $old + $mine) | keys_unsorted[]) as $k ({};
          if ($mine | has($k)) then
            if ($old | has($k)) and $mine[$k] == $old[$k] then
              if ($new | has($k)) then .[$k] = $new[$k] else . end
            else .[$k] = $mine[$k] end
          elif ($new | has($k)) and (($old | has($k) | not) or $old[$k] != $new[$k]) then .[$k] = $new[$k]
          else . end)
      end'
}

deploy_herdr_app_keys() {
  local keys="$HERDR_APP_CONFIG_DIR/keys.json" ours tmp base new old
  ours="$(mktemp)"
  tmp="$(mktemp)"
  base="$keys"
  if [[ ! -f "$keys" ]]; then
    base="$(mktemp)"
    printf '{}\n' >"$base"
  fi
  if ! DRY_RUN=0 deploy_install_file "bercail/keys.json" "$ours" >/dev/null \
    || ! { read -r new && read -r old; } < <(_herdr_app_keys_sections "$ours") \
    || ! _herdr_app_keys_merge "$new" "$old" <"$base" >"$tmp"; then
    warn "could not merge the $HERDR_APP_KEYS_SECTION keys into $keys; copy that section from bercail/keys.json"
    rm -f "$ours" "$tmp"
    [[ "$base" == "$keys" ]] || rm -f "$base"
    return 0
  fi
  [[ "$base" == "$keys" ]] || rm -f "$base"
  if [[ -f "$keys" ]] && jq -e --slurpfile new "$tmp" '. == $new[0]' "$keys" >/dev/null 2>&1; then
    info "unchanged: $keys ($HERDR_APP_KEYS_SECTION)"
  else
    info "install: $keys ($HERDR_APP_KEYS_SECTION section)"
    [[ "$DRY_RUN" -eq 1 ]] || cp "$tmp" "$keys"
  fi
  [[ "$DRY_RUN" -eq 1 ]] || DRY_RUN=0 copy_file "$ours" "$(_herdr_app_shipped_keys)" >/dev/null
  [[ "$DRY_RUN" -eq 1 ]] || _herdr_app_keys_conflicts "$keys" "$ours" | while IFS= read -r line; do warn "$line"; done
  rm -f "$ours" "$tmp"
}

# What keeps a bercail key from doing bercail's thing in the bercail layout, one per
# line: the person's own value in the section, a key missing from it, or a `terminal`
# key (that section wins whenever a terminal has the keyboard). $2: bercail's keys.json.
_herdr_app_keys_conflicts() {
  local keys="$1" ours="$2"
  [[ -f "$keys" && -f "$ours" ]] || return 0
  jq -r --arg s "$HERDR_APP_KEYS_SECTION" --slurpfile ours "$ours" '
    ($ours[0][$s] // {}) as $new | (.[$s] // {}) as $mine | (.terminal // {}) as $term
    | $new | to_entries[] | .key as $k | .value as $v
    | if ($term | has($k)) then "key \($k): the terminal section binds it to \($term[$k]) (bercail: \($v))"
      elif ($mine | has($k) | not) then "key \($k): not in \($s) (bercail: \($v))"
      elif $mine[$k] != $v then "key \($k): yours is \($mine[$k]) (bercail: \($v))"
      else empty end' "$keys" 2>/dev/null
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
    deploy_install_file "bercail/$rel" "$HERDR_APP_CONFIG_DIR/$rel"
  done
  deploy_herdr_app_keys || true
  for rel in "${HERDR_APP_MODS[@]}"; do
    if [[ "$DRY_RUN" -ne 1 ]] && ! herdr-app check "$HERDR_APP_CONFIG_DIR/mods/$rel" >/dev/null 2>&1; then
      warn "herdr-app check failed for the $rel mod; run: herdr-app check $HERDR_APP_CONFIG_DIR/mods/$rel"
    fi
  done
  info "Herdr app: switch to the bercail layout with Ctrl+Shift+L"
}

# No install-time picker. The desk runs bstack's Pi lead.
prompt_user_config() {
  if [[ -f "$BERCAIL_USER_CONFIG" ]]; then
    info "using existing config: $BERCAIL_USER_CONFIG (review: $(read_layout_review))"
    return 0
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "[dry-run] would write default $BERCAIL_USER_CONFIG"
    return 0
  fi
  ensure_dir "$BERCAIL_CONFIG_DIR"
  default_user_config >"$BERCAIL_USER_CONFIG"
  info "saved default config to $BERCAIL_USER_CONFIG"
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
  copy_file "$(install_src_dir)/$1" "$2"
}

deploy_bercail_config() {
  local src file sub
  src="$(install_src_dir)"
  while IFS= read -r -d '' file; do
    sub="${file#"$src/config/agentic-dev"/}"
    [[ "$sub" == "config.toml" || "$sub" == "config-reader.sh" ]] && continue
    copy_file "$file" "$BERCAIL_CONFIG_DIR/$sub"
  done < <(find "$src/config/agentic-dev" -type f -print0 2>/dev/null)
  # Older releases installed a reader here; lib/toml.sh replaced it.
  run rm -f "$BERCAIL_CONFIG_DIR/config-reader.sh"
}

deploy_lib() {
  deploy_tree "$(install_src_dir)/lib" "${BERCAIL_SHARE_DIR}/lib"
  # Installed lib/ has no adjacent skills tree.
  deploy_install_file "skills/handoff/scripts/git-backend.sh" "${BERCAIL_SHARE_DIR}/lib/git-backend.sh"
  deploy_install_file "skills/handoff/scripts/pi-log.sh" "${BERCAIL_SHARE_DIR}/lib/pi-log.sh"
  deploy_install_file "skills/handoff/scripts/toml.sh" "${BERCAIL_SHARE_DIR}/lib/toml.sh"
}

# The tree the installed files were copied from: the recorded clone or package,
# else a curl install's release.
_recorded_install_source() {
  local src="$BERCAIL_RELEASE_DIR"
  [[ ! -f "$BERCAIL_SOURCE_PATH_FILE" ]] || src="$(<"$BERCAIL_SOURCE_PATH_FILE")"
  [[ -n "$src" && -d "$src" && -f "$src/install.sh" && -d "$src/config" ]] || return 1
  printf '%s' "$src"
}

# Say what this install or update deploys from. A clone off master (or off a
# release tag) is a dev build: warn, since its version number still reads as the release.
describe_install_source() {
  local src branch sha tag
  src="$(install_src_dir)"
  if ! git -C "$src" rev-parse --git-dir >/dev/null 2>&1; then
    info "source: $src (v${BERCAIL_VERSION})"
    return 0
  fi
  branch="$(git -C "$src" symbolic-ref --quiet --short HEAD 2>/dev/null || printf 'detached')"
  sha="$(git -C "$src" rev-parse --short HEAD 2>/dev/null)"
  tag="$(git -C "$src" describe --tags --exact-match HEAD 2>/dev/null || true)"
  info "source: $src ($branch @ $sha${tag:+, $tag})"
  if [[ -z "$tag" && "$branch" != master && "$branch" != main ]]; then
    warn "installing from branch '$branch', not master or a release tag: this is a dev build of v${BERCAIL_VERSION} (git -C $src switch master to go back)"
  fi
}

record_install_source() {
  local src
  src="$(install_src_dir)"
  # A curl install's release is found without a record, and bercail update replaces it.
  # -ef: with HOME behind a symlink, src is the physical path.
  [[ ! "$src" -ef "$BERCAIL_RELEASE_DIR" && -f "$src/install.sh" && -d "$src/config" ]] || return 0
  ensure_dir "$BERCAIL_SHARE_DIR"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "[dry-run] would record install source $src"
    return 0
  fi
  printf '%s\n' "$src" >"$BERCAIL_SOURCE_PATH_FILE"
  info "recorded install source: $src"
}

# The update copies bin/bercail over the running script in place, and once
# main returns bash reads on from its old offset into the new file. Put a
# fresh copy at the path and empty the old inode so that read hits EOF.
detach_running_bercail() {
  local bin="$LOCAL_BIN/bercail"
  [[ -f "$bin" && ! -L "$bin" && "$DRY_RUN" -ne 1 ]] || return 0
  cp -p "$bin" "$bin.new" && ln -f "$bin" "$bin.old" && mv -f "$bin.new" "$bin" \
    && : >"$bin.old"
  rm -f "$bin.new" "$bin.old"
}

# The records of a handoff log that still name a folder: the worktree, or, once
# that is gone, its main checkout (<main> from <main>.<branch>), which Shep reads.
_handoffs_with_a_folder() {
  local file="$1" path branch
  local -a live=()
  while IFS= read -r -d '' path && IFS= read -r -d '' branch; do
    if [[ -d "$path" ]] || [[ -n "$branch" && "$path" == *".$branch" && -d "${path%".$branch"}" ]]; then
      live+=("$path")
    fi
  done < <(jq -jR 'fromjson? | select(type == "object" and (.path | type) == "string")
    | .path, "\u0000", ((.branch // "") | tostring), "\u0000"' "$file")
  jq -cR 'fromjson? | select(type == "object" and (.path | type) == "string")
    | select(.path as $p | $ARGS.positional | index($p) != null)' "$file" --args "${live[@]}"
}

# Before v1 the handoff log lived in ~/.local/state/agentic-dev. Move what is
# there into bercail's state dir and leave a link at the old path, so code
# started before the update keeps writing to the same log.
migrate_state_dir() {
  local state="${XDG_STATE_HOME:-$HOME/.local/state}"
  local old="$state/agentic-dev" new="$state/bercail" log tmp entry total kept
  [[ -d "$old" && ! -L "$old" ]] || return 0
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "[dry-run] move $old into $new and link the old path to it"
    return 0
  fi
  mkdir -p "$new"
  log="$old/handoffs.jsonl"
  if [[ -f "$log" ]]; then
    tmp="$(mktemp "$new/handoffs.jsonl.XXXXXX")"
    if _handoffs_with_a_folder "$log" >"$tmp"; then
      total="$(wc -l <"$log")" kept="$(wc -l <"$tmp")"
      [[ ! -f "$new/handoffs.jsonl" ]] || cat "$new/handoffs.jsonl" >>"$tmp"
      mv "$tmp" "$new/handoffs.jsonl"
      rm -f "$log"
      info "moved $kept handoff records to $new/handoffs.jsonl (dropped $((total - kept)) with no folder left)"
    else
      rm -f "$tmp"
      warn "could not read $log; leaving $old where it is"
      return 0
    fi
  fi
  for entry in "$old"/* "$old"/.[!.]*; do
    [[ -e "$entry" || -L "$entry" ]] || continue
    [[ -e "$new/${entry##*/}" ]] || mv "$entry" "$new/"
  done
  if rmdir "$old" 2>/dev/null; then
    ln -s bercail "$old"
    info "moved $old into $new; the old path is now a link to it"
  else
    warn "$old still holds $(ls -A "$old" | tr '\n' ' ')($new has the same names). Move them, then run: bercail update"
  fi
}

# Remove the old switch. An off install (including --no-bstack, which wrote no
# [bstack]) needs to know its next desk will run the guarded lead, not plain Pi.
migrate_bstack_switch() {
  local dest="$BERCAIL_USER_CONFIG" tmp was
  [[ -f "$dest" ]] || return 0
  tmp="$(mktemp)"
  was="$(awk -v out="$tmp" '
    /^[[:space:]]*\[/ {
      sec = $0; sub(/#.*/, "", sec); gsub(/[[:space:]]/, "", sec)
      if (sec == "[bstack]") print "section"
    }
    sec == "[bstack]" && /^[[:space:]]*enabled[[:space:]]*=/ {
      sub(/^[^=]*=[[:space:]]*/, ""); sub(/[[:space:]]*(#.*)?$/, "")
      print ($0 == "true" ? "on" : "off")
      next
    }
    sec == "[bstack]" && $0 == "# `bercail bstack off` turns bstack off." { next }
    sec == "[bstack]" && /^# Pi with your own logins\. `bercail bstack setup` shows what\047s missing;$/ { sub(/;$/, ".") }
    { print > out }' "$dest")"
  if grep -qx off <<<"$was" \
    || { [[ -z "$was" && ! -e "${BSTACK_PI_DIR:-$BERCAIL_SHARE_DIR/pi}/lead.json" ]]; }; then
    warn "bstack has no switch from this release on. This update sets up its Pi profile, and the desk runs bstack's lead with bercail's guard, not plain pi (bercail bstack status)"
  fi
  if ! grep -qx -e on -e off <<<"$was"; then
    rm -f "$tmp"
    return 0
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    rm -f "$tmp"
    info "[dry-run] would remove enabled from [bstack] in $dest"
    return 0
  fi
  # Written through, not moved over: the file may be a link into someone's dotfiles.
  cat "$tmp" >"$dest"
  rm -f "$tmp"
  info "removed enabled from [bstack] in $dest: nothing reads it"
}

# [graphite] "<repo>" = true|false chose Graphite until v1; [git] names the
# backend now. Move each entry there once. A repo [git] already names keeps
# that entry: [git] won when a repo was in both.
migrate_graphite_config() {
  local dest="$BERCAIL_USER_CONFIG" tmp
  [[ -f "$dest" ]] || return 0
  grep -Eq '^[[:space:]]*\[[[:space:]]*["\047]?graphite["\047]?[[:space:]]*\]' "$dest" || return 0
  tmp="$(mktemp)"
  awk '
    function section(line) {
      sub(/#.*/, "", line)
      gsub(/[[:space:]"\047]/, "", line)
      return line
    }
    # "<repo>" = true|false as a [git] line, else "". Sets key to the repo of
    # any entry.
    function as_git(line,   q, i, rest, v) {
      key = ""
      sub(/^[[:space:]]*/, "", line)
      q = substr(line, 1, 1)
      if (q != "\"" && q != "\047") return ""
      i = index(substr(line, 2), q)
      if (!i) return ""
      key = substr(line, 2, i - 1)
      rest = substr(line, i + 2)
      v = rest
      sub(/^[[:space:]]*=[[:space:]]*/, "", v)
      sub(/[[:space:]]*(#.*)?$/, "", v)
      if (v != "true" && v != "false") return ""
      sub(/=[[:space:]]*(true|false)/, (v == "true" ? "= \"gt\"" : "= \"gh\""), rest)
      return substr(line, 1, i + 1) rest
    }
    function flush_git(   i) {
      for (i = 1; i <= moved; i++) print entries[i]
      printf "%s", blanks
      blanks = ""
      moved = 0
    }
    NR == FNR {
      if ($0 ~ /^[[:space:]]*\[/) { sec = section($0); if (sec == "[git]") has_git = 1; next }
      line = as_git($0)
      if (sec == "[git]" && key != "") in_git[key] = 1
      if (sec != "[graphite]") next
      if (line != "") { repo[++found] = key; entry[found] = line }
      else if ($0 !~ /^[[:space:]]*(#.*)?$/) other = 1
      next
    }
    FNR == 1 {
      for (i = 1; i <= found; i++) if (!(repo[i] in in_git)) entries[++moved] = entry[i]
      sec = ""
    }
    /^[[:space:]]*\[/ {
      if (sec == "[git]") flush_git()
      sec = section($0)
      if (sec == "[graphite]") {
        if (!has_git) print "[git]"
        else if (other) print
        next
      }
    }
    sec == "[graphite]" && as_git($0) != "" {
      if (!has_git) print as_git($0)
      next
    }
    # Hold the blank lines that end [git], so the moved entries go above them.
    sec == "[git]" && has_git {
      if ($0 ~ /^[[:space:]]*$/) { blanks = blanks $0 "\n"; next }
      printf "%s", blanks
      blanks = ""
    }
    { print }
    END { if (sec == "[git]" && has_git) flush_git() }
  ' "$dest" "$dest" >"$tmp"
  if cmp -s "$tmp" "$dest"; then
    rm -f "$tmp"
    return 0
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    rm -f "$tmp"
    info "[dry-run] would move the [graphite] entries of $dest under [git]"
    return 0
  fi
  # Written through, not moved over: the file may be a link into someone's dotfiles.
  cat "$tmp" >"$dest"
  rm -f "$tmp"
  info "moved the [graphite] entries of $dest under [git]"
}

# v0.14.0 still copies this shim by name. Remove the installed command, but keep
# bin/agentic-dev in the repo until that updater is below the upgrade floor.
remove_agentic_dev_shim() {
  local shim="$LOCAL_BIN/agentic-dev"
  grep -qsx '# Compat shim. The CLI is bercail.' "$shim" || return 0
  info "remove: $shim (the command is bercail)"
  run rm -f "$shim"
}

# A checksum of the installed CLI when it is the one running, else nothing: a
# clone's bin/bercail and install.sh run the tree they deploy.
_running_install_sum() {
  [[ "$(script_dir)" -ef "${BERCAIL_SHARE_DIR}/lib" ]] || return 0
  { cat "$LOCAL_BIN/bercail" "${BERCAIL_SHARE_DIR}/lib"/*.sh 2>/dev/null || true; } | cksum
}

deploy_finalize_permissions() {
  detach_running_bercail
  deploy_install_file "config/pi/extensions/bercail-desk.ts" \
    "${BERCAIL_SHARE_DIR}/pi-extensions/bercail-desk.ts"
  deploy_desk_restore
  run chmod +x "$LOCAL_BIN/bercail" "$LOCAL_BIN/bercail-desk-agent" \
    "$WORKTRUNK_CONFIG_DIR/herdr-layout.sh" \
    "$BERCAIL_SHELL_DIR/bercail.sh" \
    "$BERCAIL_SHELL_DIR/bercail.zsh" \
    "$BERCAIL_SHELL_DIR/bercail.inc.sh" 2>/dev/null || true
  find "${BERCAIL_SHARE_DIR}/lib" -name '*.sh' -exec chmod +x {} + 2>/dev/null || true
}

deploy_configs() {
  local -a files=(
    "config/shell/bercail.inc.sh|${BERCAIL_SHELL_DIR}/bercail.inc.sh"
    "config/bash/bercail.sh|${BERCAIL_SHELL_DIR}/bercail.sh"
    "config/zsh/bercail.zsh|${BERCAIL_SHELL_DIR}/bercail.zsh"
    "config/worktrunk/herdr-layout.sh|${WORKTRUNK_CONFIG_DIR}/herdr-layout.sh"
    "bin/bercail|${LOCAL_BIN}/bercail"
    "bin/bercail-desk-agent|${LOCAL_BIN}/bercail-desk-agent"
  )
  local entry rel dest running

  describe_install_source
  prompt_user_config
  migrate_state_dir
  remove_agentic_dev_shim
  migrate_graphite_config
  migrate_bstack_switch
  notify_rename_workspaces

  ensure_dir "$BERCAIL_CONFIG_DIR"
  ensure_dir "$BERCAIL_SHELL_DIR"
  ensure_dir "$WORKTRUNK_CONFIG_DIR"
  ensure_dir "$BERCAIL_SHARE_DIR"

  running="$(_running_install_sum)"
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

  deploy_bercail_config
  deploy_lib
  # This update replaced the CLI that is running it: the new lib/config.sh
  # takes over as it loads (restart_update, at its top).
  if [[ "$(_running_install_sum)" != "$running" ]]; then
    # shellcheck source=/dev/null
    source "${BERCAIL_SHARE_DIR}/lib/config.sh"
  fi
  deploy_herdr_app
  deploy_skills
  deploy_bstack || true
  deploy_shep
  if [[ ! -f "$WORKTRUNK_CONFIG_DIR/config.toml" ]] || [[ "$FORCE" -eq 1 ]]; then
    deploy_install_file "config/worktrunk/config.toml" "$WORKTRUNK_CONFIG_DIR/config.toml"
  else
    info "keeping existing worktrunk config: $WORKTRUNK_CONFIG_DIR/config.toml"
  fi

  deploy_finalize_permissions
  record_install_source
  ensure_pi
  ensure_tuicr
  sync_omarchy_default_agent
}
