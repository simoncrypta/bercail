#!/usr/bin/env bash
# shellcheck shell=bash
# Doctor checks. Source after detect/config/omarchy/skills.

# shellcheck source=lib/git-backend.sh
source "$(dirname "${BASH_SOURCE[0]}")/git-backend.sh"

doctor_omarchy_integration() {
  if [[ "$(detect_os)" != "linux" ]]; then
    return 0
  fi
  if is_omarchy || has_hyprland; then
    if hypr_has_herdr_binding; then
      log "  ok  hypr SUPER+ALT+RETURN launches the Herdr app"
    else
      log "  optional  hypr SUPER+ALT+RETURN Herdr app binding (not configured)"
    fi
  fi
  return 0
}

# The bercail layout, its desk mod and its keys in the Herdr app's home.
doctor_herdr_app() {
  local missing=0 src rel dest ours
  src="$(_recorded_install_source 2>/dev/null || true)"
  if [[ -f "$HERDR_APP_CONFIG_DIR/$HERDR_APP_LAYOUT" ]]; then
    log "  ok  Herdr layout bercail"
  else
    log "  missing  Herdr layout $HERDR_APP_CONFIG_DIR/$HERDR_APP_LAYOUT"
    missing=$((missing + 1))
  fi
  for rel in "${HERDR_APP_MOD_FILES[@]}"; do
    dest="$HERDR_APP_CONFIG_DIR/$rel"
    if [[ ! -f "$dest" ]]; then
      log "  missing  Herdr mod file $dest"
      missing=$((missing + 1))
    elif [[ -n "$src" && -f "$src/bercail/$rel" ]] && ! cmp -s "$src/bercail/$rel" "$dest"; then
      log "  stale  Herdr mod file $dest (run: bercail update)"
      missing=$((missing + 1))
    fi
  done
  if [[ "$missing" -eq 0 ]]; then
    log "  ok  Herdr mod bercail-desk"
  fi
  if jq -e --arg s "$HERDR_APP_KEYS_SECTION" '.[$s]["ctrl-shift-a"] == "bercail-desk.agent"' \
    "$HERDR_APP_CONFIG_DIR/keys.json" >/dev/null 2>&1; then
    log "  ok  Herdr keys $HERDR_APP_KEYS_SECTION"
    # The person's choices: reported, not a failure.
    ours="$(_herdr_app_shipped_keys)"
    [[ -z "$src" || ! -f "$src/bercail/keys.json" ]] || ours="$src/bercail/keys.json"
    _herdr_app_keys_conflicts "$HERDR_APP_CONFIG_DIR/keys.json" "$ours" \
      | while IFS= read -r line; do log "  conflict  Herdr $line"; done
  else
    log "  missing  Herdr keys $HERDR_APP_KEYS_SECTION in $HERDR_APP_CONFIG_DIR/keys.json (run: bercail update)"
    missing=$((missing + 1))
  fi
  [[ "$missing" -eq 0 ]]
}

# Herdr updates itself; bercail only says when an update waits on a restart.
# Newest: the top release in the changelog Herdr caches. Running: the older of
# herdr-app --version and the version Herdr last ran. A hint, never a failure.
doctor_herdr_app_update() {
  local newest running last
  newest="$(sed -n 's/^## \[\([0-9][0-9.]*\)\].*/\1/p' "$HERDR_APP_CONFIG_DIR/update-notes-cache.md" 2>/dev/null \
    | sort -V | tail -n 1 || true)"
  [[ -n "$newest" ]] || return 0
  running="$(herdr-app --version 2>/dev/null </dev/null \
    | grep -oE '[0-9]+(\.[0-9]+)+' | sed -n 1p || true)"
  last="$(jq -r '.last_run // empty' "$HERDR_APP_CONFIG_DIR/update-notes.json" 2>/dev/null || true)"
  running="$(printf '%s\n%s\n' "$running" "$last" | sed '/^$/d' | sort -V | sed -n 1p)"
  [[ -n "$running" && "$running" != "$newest" ]] || return 0
  [[ "$(printf '%s\n%s\n' "$running" "$newest" | sort -V | tail -n 1)" == "$newest" ]] || return 0
  log "  hint  Herdr $newest is downloaded (running $running); restart the Herdr window to apply it"
}

# bercail-spaces and bercail-agents are copies of Herdr's mods, and Herdr never
# updates a copy. Each mod.json records the main.js it was copied from, as
# Herdr's installed.json names it; a different one there means Herdr's mod has
# moved on and the copy has not, or that Herdr is older than the copy.
doctor_mod_copies() {
  local mod json name version base now running
  running="$(herdr-app --version 2>/dev/null </dev/null | grep -oE '[0-9]+(\.[0-9]+)+' | sed -n 1p || true)"
  for mod in bercail-spaces bercail-agents; do
    json="$HERDR_APP_CONFIG_DIR/mods/$mod/mod.json"
    IFS=$'\t' read -r name version base < <(jq -r '.cloned_from | [.name, .version, .main_js] | @tsv' "$json" 2>/dev/null) || continue
    now="$(jq -r --arg name "$name" '.[$name]["main.js"] // empty' "$HERDR_APP_CONFIG_DIR/installed.json" 2>/dev/null || true)"
    [[ -n "$base" && -n "$now" && "$now" != "$base" ]] || continue
    if [[ -n "$running" && "$running" != "$version" && "$(printf '%s\n%s\n' "$running" "$version" | sort -V | sed -n 1p)" == "$running" ]]; then
      log "  hint  $mod is bercail's copy of Herdr $version's $name mod and this Herdr is $running; update Herdr"
    else
      log "  hint  Herdr's $name mod changed after $version; $mod is bercail's copy of that one and lacks the change until bercail updates it"
    fi
  done
}

# Did the live follower miss a desk finishing or blocking? Prints what it
# missed and fails. A desk now done or blocked since after the follower
# started, later than the last transition the follower recorded, is one it
# didn't see. A follower without a record runs a bercail older than this check.
doctor_notify_missed() {
  local f started last address ms term issue title
  f="$(notify_follower_file)"
  started="$(jq -r '.started_at // empty' "$f" 2>/dev/null)"
  if [[ ! "$started" =~ ^[0-9]+$ ]]; then
    printf 'runs an older bercail'
    return 1
  fi
  last="$(jq -r '.last_transition_at // 0' "$f" 2>/dev/null)"
  [[ "$last" =~ ^[0-9]+$ ]] || last=0
  while IFS= read -r address; do
    [[ -n "$address" ]] || continue
    term="$("$(notify_hc)" get "$address" --json 2>/dev/null </dev/null)" || continue
    ms="$(jq -r 'select(.status.state == "done" or .status.state == "blocked") | .status_ms // empty' <<<"$term" 2>/dev/null)" || true
    [[ "$ms" =~ ^[0-9]+$ ]] || continue
    # Slack: the follower records a transition a moment after hc stamps it.
    if (( ms / 1000 > started + 5 && ms / 1000 > last + 60 )); then
      issue="$(jq -r '.labels["bercail.issue"] // empty' <<<"$term" 2>/dev/null)" || issue=""
      title="$(jq -r '.labels["bercail.issue_title"] // empty' <<<"$term" 2>/dev/null)" || title=""
      if [[ -n "$issue" && -n "$title" ]]; then
        printf 'missed desk %s (%s: %s) finishing or blocking' "$address" "$issue" "$title"
      elif [[ -n "$issue" ]]; then
        printf 'missed desk %s (%s) finishing or blocking' "$address" "$issue"
      else
        printf 'missed desk %s finishing or blocking' "$address"
      fi
      return 1
    fi
  done < <("$(notify_hc)" ls --json --label bercail.role=agent 2>/dev/null </dev/null \
    | jq -r '.terminals[]? | select(.state == "live") | .address' 2>/dev/null)
  return 0
}

# How long after `bercail update` kills the follower doctor calls it restarting
# rather than missing: the desk mod checks every 60s, plus slack to start.
DOCTOR_NOTIFY_RESTART_WINDOW=90

# Webhook sinks: their last delivery, and the follower that sends to them.
doctor_notify() {
  local f name st at last=0 missing=0 missed restarted now
  [[ -n "$(notify_sink_files)" ]] || return 0
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    name="$(notify_sink_name "$f")"
    st="$(_notify_sink_state_file "$name")"
    if [[ -r "$st" ]] && jq -e '.auth_failed == true' "$st" >/dev/null 2>&1; then
      log "  failing  notify sink $name (key rejected; see bercail notify status)"
      missing=$((missing + 1))
    else
      log "  ok  notify sink $name"
    fi
    at="$(jq -r '.last_ok_at // 0 | floor' "$st" 2>/dev/null || true)"
    if [[ "$at" =~ ^[0-9]+$ ]] && (( at > last )); then
      last="$at"
    fi
  done < <(notify_sink_files)
  # Not a failure: a repo can be left out on purpose.
  while IFS= read -r name; do
    log "  uncovered  repo $name has a live desk but no enabled notify sink covers it (add it: $(_notify_fix_cmd "$name"))"
  done < <(notify_uncovered_desk_repos)
  # A live follower can still be silent; the last post time makes that visible.
  if [[ "$last" -gt 0 ]]; then
    at="$(date -d "@$last" '+%Y-%m-%d %H:%M' 2>/dev/null || date -r "$last" '+%Y-%m-%d %H:%M')"
  else
    at="never"
  fi
  restarted="$(cat "$(notify_restart_file)" 2>/dev/null || true)"
  [[ "$restarted" =~ ^[0-9]+$ ]] || restarted=0
  now="$(_notify_now)"
  if "$(notify_hc)" get bercail-notify --json 2>/dev/null | jq -e '.state == "live"' >/dev/null 2>&1; then
    if missed="$(doctor_notify_missed)"; then
      log "  ok  notify follower (hc terminal bercail-notify; last post $at)"
    else
      log "  deaf  notify follower is live but $missed (restart it: hc kill bercail-notify; the bercail layout starts it again)"
      missing=$((missing + 1))
    fi
  elif (( restarted > 0 && now >= restarted && now - restarted <= DOCTOR_NOTIFY_RESTART_WINDOW )); then
    # bercail update killed it; the desk mod's 60s check starts the new one.
    log "  restarting  notify follower (bercail update restarted it $((now - restarted))s ago; the desk mod starts it within a minute)"
  else
    log "  missing  notify follower (the bercail layout starts it; or: hc run --bg --no-parent --name bercail-notify bercail notify run)"
    missing=$((missing + 1))
  fi
  [[ "$missing" -eq 0 ]]
}

doctor_helper() {
  local src
  if [[ ! -f "$WORKTRUNK_CONFIG_DIR/herdr-layout.sh" ]]; then
    log "  missing  herdr-layout.sh"
    return 1
  fi
  if ! src="$(_recorded_install_source)"; then
    log "  ok  herdr-layout.sh (not compared: installed from a release)"
    return 0
  fi
  if [[ -f "$src/config/worktrunk/herdr-layout.sh" ]] \
    && ! cmp -s "$src/config/worktrunk/herdr-layout.sh" "$WORKTRUNK_CONFIG_DIR/herdr-layout.sh"; then
    log "  stale  herdr-layout.sh (run ./install.sh from $src)"
    return 1
  fi
  log "  ok  herdr-layout.sh"
  return 0
}

_doctor_one_skill() {
  local skill_id="$1" dest src
  dest="$(skill_canonical_dir "$skill_id")"
  if [[ ! -f "${dest}/SKILL.md" ]]; then
    log "  missing  skill $skill_id at $dest"
    return 1
  fi
  if ! src="$(_recorded_install_source)"; then
    log "  ok  skill $skill_id (not compared: installed from a release)"
    return 0
  fi
  if [[ -f "$src/skills/${skill_id}/SKILL.md" ]] \
    && ! cmp -s "$src/skills/${skill_id}/SKILL.md" "${dest}/SKILL.md"; then
    log "  stale  skill $skill_id (run ./install.sh from $src)"
    return 1
  fi
  log "  ok  skill $skill_id [$dest]"
  return 0
}

doctor_skill() {
  local missing=0 link skill_id
  while IFS= read -r skill_id; do
    [[ -n "$skill_id" ]] || continue
    _doctor_one_skill "$skill_id" || missing=$((missing + 1))
  done < <(_skill_ids)

  while IFS= read -r skill_id; do
    [[ -n "$skill_id" ]] || continue
    link="${PI_SKILLS_DIR}/${skill_id}"
    if [[ -L "$link" ]] && _skill_link_is_ours "$link" "$skill_id"; then
      log "  ok  skill link for pi [$link]"
    elif [[ -e "$link" ]]; then
      log "  warning  skill path exists but is not our symlink [$link]"
    else
      log "  missing  skill link for pi [$link]"
      missing=$((missing + 1))
    fi
  done < <(_skill_ids)
  [[ "$missing" -eq 0 ]]
}

# Pi's trust decision for DIR: the closest saved one in trust.json (true or
# false), else defaultProjectTrust (always, ask, never). Desks skip a project's
# .pi/extensions when it is not trusted.
_doctor_pi_trust() {
  local dir="$1" agent="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}" saved
  saved="$(jq -r --arg d "$dir" '[to_entries[] | select(.key as $k | $k == $d or ($d | startswith($k + "/")))]
    | max_by(.key | length) // empty | .value | tostring' "$agent/trust.json" 2>/dev/null)" || saved=""
  if [[ -n "$saved" ]]; then
    printf '%s' "$saved"
  else
    jq -r '.defaultProjectTrust // "ask"' "$agent/settings.json" 2>/dev/null || printf 'ask'
  fi
}

# GitHub's visibility of SLUG (owner/repo): PUBLIC, PRIVATE, INTERNAL, or
# nothing when gh cannot tell within 10 seconds.
_doctor_gh_visibility() {
  _git_backend_bounded 10 gh repo view "$1" --json visibility --jq .visibility </dev/null 2>/dev/null || true
}

# Entire's Brain plugin, when installed: its version, whether setup's files reach
# every worktree, and what runs or leaves the machine unasked (the watcher, hosted
# sync). It only runs version and status. Silent without the plugin.
_doctor_entire_brain() {
  local top="$1" bin brain graph ver status url slug=""
  bin="${ENTIRE_PLUGIN_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/entire/plugins}/bin"
  brain="$bin/entire-brain" graph="$bin/entire-graph"
  [[ -x "$brain" ]] || brain="$(command -v entire-brain)" || return 0
  [[ -x "$graph" ]] || graph="$(command -v entire-graph || true)"
  ver="$("$brain" version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  if version_at_least "${ver:-0}" 0.5.1; then
    log "  ok  Brain $ver"
  else
    log "  old  Brain ${ver:-(unknown version)}; bercail is tested with 0.5.1 (you run: entire plugin upgrade brain)"
  fi
  ver=""
  [[ -z "$graph" ]] || ver="$("$graph" version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  if [[ -z "$graph" ]]; then
    log "  missing  entire-graph, which Brain's code answers need (you run: entire plugin install graph)"
  elif ! version_at_least "${ver:-0}" 0.5.0; then
    log "  old  Graph ${ver:-(unknown version)}; Brain needs 0.5.0 (you run: entire plugin upgrade graph)"
  fi
  if git -C "$top" cat-file -e HEAD:.entire/agent-guide.md 2>/dev/null \
    && git -C "$top" show HEAD:AGENTS.md 2>/dev/null | grep -qF '<!-- entire-agent:begin -->'; then
    log "  ok  Brain's agent guide and AGENTS.md block are committed, so every worktree's desk has them"
  elif [[ -f "$top/.entire/agent-guide.md" ]]; then
    log "  warning  Brain's .entire/agent-guide.md or AGENTS.md block is not committed: desks in other worktrees miss it. Commit them on main, on their own"
  else
    log "  hint  Brain is not set up here (you run, in a clean main checkout: entire brain setup --no-backfill --no-daemon --no-agent-hooks)"
  fi
  status="$(cd "$top" && _git_backend_bounded 10 "$brain" status --json </dev/null 2>/dev/null)" || status='{}'
  jq -e '.onboarding.daemon.installed == true' <<<"$status" >/dev/null 2>&1 \
    && log "  hint  Brain's watcher is installed: it refreshes in the background and, unless its agent is none, distills sessions daily on your tokens (you run: entire brain setup --uninstall-daemon)"
  jq -e '(.hosted.repo_state // "disconnected") != "disconnected"' <<<"$status" >/dev/null 2>&1 || return 0
  url="$(git -C "$top" remote get-url origin 2>/dev/null || true)"
  [[ ! "$url" =~ github\.com[:/]([^/]+/[^/]+)$ ]] || slug="${BASH_REMATCH[1]%.git}"
  if [[ -n "$slug" && "$(_doctor_gh_visibility "$slug")" == PUBLIC ]]; then
    log "  warning  Brain syncs this repo's memories to Entire, and $slug is public: memories distilled from private checkpoints may be readable there (you run: entire brain disconnect)"
  fi
  return 0
}

# Entire in the repo doctor runs from: what desks need for their sessions to be
# captured, and where the transcripts go. Silent outside an Entire repo. Never
# fails doctor: whoever clones a repo that uses Entire may not use it.
doctor_entire() {
  local top hooks hook ver settings trust dest slug url vis
  local -a files=() gone=()
  top="$(git rev-parse --show-toplevel 2>/dev/null)" || return 0
  [[ -f "$top/.entire/settings.json" ]] || return 0
  log ""
  log "Entire ($top):"
  if ! git_backend_entire_capture "$top"; then
    log "  ok  off here (enabled: false)"
    return 0
  fi
  if ! command -v entire >/dev/null 2>&1; then
    log "  missing  entire, so its git hooks skip and nothing is captured (https://docs.entire.com/installation)"
    return 0
  fi
  ver="$(entire version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  # 0.13.3 keeps capturing a Pi session across /reload, /new and /resume;
  # 0.13.4 stops the pre-push hook panicking in repos with config.worktree.
  if version_at_least "${ver:-0}" 0.13.4; then
    log "  ok  entire $ver"
  else
    log "  old  entire ${ver:-(unknown version)}; bercail needs 0.13.4: older ones stop capturing a desk after /reload, /new or /resume, and panic on pre-push with config.worktree (you run: entire update)"
  fi
  hooks="$(git rev-parse --path-format=absolute --git-path hooks)"
  for hook in prepare-commit-msg commit-msg post-commit post-rewrite pre-push; do
    grep -qs '# Entire CLI hooks' "$hooks/$hook" || gone+=("$hook")
  done
  if ((${#gone[@]} == 0)); then
    log "  ok  git hooks in $hooks"
  else
    log "  missing  Entire's ${gone[*]} hook in $hooks, so commits are not linked to sessions (you run: entire configure --force)"
  fi
  if git -C "$top" ls-files --error-unmatch .pi/extensions/entire/index.ts >/dev/null 2>&1; then
    log "  ok  Pi extension committed, so every worktree's desk has it"
  elif [[ -f "$top/.pi/extensions/entire/index.ts" ]]; then
    log "  warning  .pi/extensions/entire/index.ts is not committed: desks in new worktrees go uncaptured"
  else
    log "  missing  Entire's Pi extension: desks go uncaptured (you run: entire agent add pi, then commit it)"
  fi
  trust="$(_doctor_pi_trust "$top")"
  case "$trust" in
    true | always) log "  ok  Pi trusts $top, so desks load the extension" ;;
    *) log "  warning  Pi does not trust $top ($trust): desks skip Entire's extension. Trust it with /trust in a Pi there" ;;
  esac

  if _git_backend_bounded 10 entire auth status </dev/null >/dev/null 2>&1; then
    log "  ok  logged in to Entire"
  else
    log "  hint  not logged in to Entire; only trails need it (you run: entire login)"
  fi
  _doctor_entire_brain "$top"

  files=("$top/.entire/settings.json")
  [[ ! -f "$top/.entire/settings.local.json" ]] || files+=("$top/.entire/settings.local.json")
  settings="$(jq -s 'reduce .[] as $s ({}; . * $s)' "${files[@]}" 2>/dev/null)" || settings='{}'
  jq -e '.commit_linking == "always"' <<<"$settings" >/dev/null \
    || log "  hint  commit_linking is $(jq -r '.commit_linking // "prompt"' <<<"$settings"): a person's commit waits 15 s on Entire's prompt. Set \"commit_linking\": \"always\" in .entire/settings.json"
  jq -e '.telemetry != true' <<<"$settings" >/dev/null \
    || log "  hint  telemetry is on, for everyone who clones. Set \"telemetry\": false in .entire/settings.json"
  jq -e '.redaction.pii.enabled == true' <<<"$settings" >/dev/null \
    || log "  hint  PII redaction is off: emails and phone numbers stay in transcripts. Set redaction.pii.enabled in .entire/settings.json"

  if jq -e '.strategy_options.push_sessions == false' <<<"$settings" >/dev/null; then
    log "  ok  checkpoints stay in this clone (push_sessions: false)"
    return 0
  fi
  if jq -e '.strategy_options.checkpoint_remote' <<<"$settings" >/dev/null; then
    dest="$(jq -r '.strategy_options.checkpoint_remote | "\(.provider):\(.repo)"' <<<"$settings")"
    [[ "$dest" != github:* ]] || slug="${dest#github:}"
  else
    url="$(git -C "$top" remote get-url origin 2>/dev/null || true)"
    dest="origin ($url)"
    [[ ! "$url" =~ github\.com[:/]([^/]+/[^/]+)$ ]] || slug="${BASH_REMATCH[1]%.git}"
  fi
  vis=""
  [[ -z "${slug:-}" ]] || vis="$(_doctor_gh_visibility "$slug")"
  case "$vis" in
    PUBLIC) log "  warning  checkpoints (full agent transcripts) go to $dest, which is public. Set strategy_options.checkpoint_remote to a private repo, or push_sessions: false" ;;
    PRIVATE | INTERNAL) log "  ok  checkpoints go to $dest, which is ${vis,,}" ;;
    *) log "  unknown  checkpoints go to $dest; check that it is private before you push (they are full agent transcripts)" ;;
  esac
}
