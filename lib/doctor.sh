#!/usr/bin/env bash
# shellcheck shell=bash
# Doctor checks. Source after detect/config/omarchy/skills.

# shellcheck source=lib/git-backend.sh
source "$(dirname "${BASH_SOURCE[0]}")/git-backend.sh"
# shellcheck source=lib/desk-secret.sh
source "$(dirname "${BASH_SOURCE[0]}")/desk-secret.sh"

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
  ! command -v pi >/dev/null 2>&1 || _pi_keys_shadowed "$HERDR_APP_CONFIG_DIR/keys.json" \
    | while IFS= read -r line; do log "  shadowed  $line"; done
  [[ "$missing" -eq 0 ]]
}

# Pi's app.* keys by default on Linux and macOS (Pi 1.6.0, docs/keybindings.md).
PI_APP_KEYS='{"app.interrupt":"escape","app.clear":"ctrl+c","app.exit":"ctrl+d","app.suspend":"ctrl+z",
"app.editor.external":"ctrl+g","app.clipboard.pasteImage":"ctrl+v","app.session.togglePath":"ctrl+p",
"app.session.toggleSort":"ctrl+s","app.session.toggleNamedFilter":"ctrl+n","app.session.rename":"ctrl+r",
"app.session.delete":"ctrl+d","app.session.deleteNoninvasive":"ctrl+backspace","app.model.select":"ctrl+l",
"app.model.cycleForward":"ctrl+p","app.model.cycleBackward":"shift+ctrl+p","app.models.save":"ctrl+s",
"app.thinking.cycle":"shift+tab","app.thinking.save":"ctrl+s","app.thinking.toggle":"ctrl+t",
"app.tools.expand":"ctrl+o","app.message.copy":"ctrl+x","app.message.followUp":"alt+enter",
"app.message.dequeue":"alt+up","app.tree.foldOrUp":["ctrl+left","alt+left"],
"app.tree.unfoldOrDown":["ctrl+right","alt+right"],"app.tree.editLabel":"shift+l",
"app.tree.toggleLabelTimestamp":"shift+t","app.tree.filter.default":"ctrl+d","app.tree.filter.noTools":"ctrl+t",
"app.tree.filter.userOnly":"ctrl+u","app.tree.filter.labeledOnly":"ctrl+l","app.tree.filter.all":"ctrl+a",
"app.tree.filter.cycleForward":"ctrl+o","app.tree.filter.cycleBackward":"shift+ctrl+o","app.models.enableAll":"ctrl+a",
"app.models.clearAll":"ctrl+x","app.models.toggleProvider":"ctrl+p","app.models.reorderUp":"alt+up",
"app.models.reorderDown":"alt+down"}'

# Each Pi app.* key the bercail layout takes before Pi sees it: Pi's default, or
# the one in Pi's keybindings.json. Herdr writes ctrl-shift-p, Pi shift+ctrl+p.
# A key the terminal section hands to the program reaches Pi.
_pi_keys_shadowed() {
  local keys="$1" pi_keys mine='{}'
  pi_keys="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/keybindings.json"
  [[ ! -s "$pi_keys" ]] || mine="$(jq -e -c -s 'select(length == 1 and (.[0] | type) == "object") | .[0]' "$pi_keys" 2>/dev/null)" || mine='{}'
  jq -r --arg s "$HERDR_APP_KEYS_SECTION" --argjson def "$PI_APP_KEYS" --argjson mine "$mine" --arg file "$pi_keys" '
    def norm(sep): ascii_downcase | split(sep)
      | (.[:-1] | map(select(. != "")) | sort)
        + [if .[-1] == "" then sep else .[-1] end | {esc: "escape", return: "enter"}[.] // .]
      | join("+");
    def bound: if type == "object" then to_entries | map(.key |= norm("-")) | from_entries else {} end;
    (.terminal | bound | with_entries(select(.value == "terminal"))) as $pass
    | (.[$s] | bound | with_entries(.key as $k | select(.value != "terminal" and ($pass | has($k) | not)))) as $layout
    | (.[$s] // {} | if type == "object" then with_entries(.value = .key) | to_entries | map({key: (.key | norm("-")), value: .value}) | from_entries else {} end) as $herdr
    | ($def + $mine) | to_entries[] | select(.key | startswith("app."))
    | .key as $a | .value | (if type == "string" then [.] elif type == "array" then map(strings) else [] end)[]
    | norm("+") as $k | select($layout | has($k))
    | "Pi \($a) (\($k)): the bercail layout takes \($herdr[$k]) for \($layout[$k] | tostring); bind it to another key in \($file)"' \
    "$keys" 2>/dev/null
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

# Disk parity and actual startup evidence are separate. This reads no question
# ledger and never installs, reloads or repairs a running owner.
doctor_runtime() {
  local snapshot script
  script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/runtime.ts"
  log ""
  log "Runtime identity (read-only):"
  if ! snapshot="$(node "$script" 2>/dev/null)"; then
    log "  UNKNOWN  runtime evidence unavailable (Node and the diagnostic helper are required)"
    return 0
  fi
  jq -r '"  source revision  " + .source_revision,
    "  installed revision  " + .installed_revision,
    (.files[] | "  sha256  " + .resource + " source=" + .source + " installed=" + .installed),
    (if (.loaded | type) == "string" then "  loaded  " + .loaded
     else .loaded[] | "  loaded  " + (.desk // "Shep") + " generation=" + .generation + " guard=" + .guard_generation end)' <<<"$snapshot"
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
  local top="$1" bin brain graph ver min status url slug=""
  bin="${ENTIRE_PLUGIN_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/entire/plugins}/bin"
  brain="$bin/entire-brain" graph="$bin/entire-graph"
  [[ -x "$brain" ]] || brain="$(command -v entire-brain)" || return 0
  [[ -x "$graph" ]] || graph="$(command -v entire-graph || true)"
  ver="$("$brain" version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  min="$(dep_min entire-brain)"
  if version_at_least "${ver:-0}" "$min"; then
    log "  ok  Brain $ver"
  else
    log "  old  Brain ${ver:-(unknown version)}; bercail is tested with $min (you run: entire plugin upgrade brain)"
  fi
  ver=""
  [[ -z "$graph" ]] || ver="$("$graph" version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  min="$(dep_min entire-graph)"
  if [[ -z "$graph" ]]; then
    log "  missing  entire-graph, which Brain's code answers need (you run: entire plugin install graph)"
  elif ! version_at_least "${ver:-0}" "$min"; then
    log "  old  Graph ${ver:-(unknown version)}; Brain needs $min (you run: entire plugin upgrade graph)"
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
  local top hooks hook ver min settings trust dest slug url vis
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
  min="$(dep_min entire)"
  if version_at_least "${ver:-0}" "$min"; then
    log "  ok  entire $ver"
  else
    log "  old  entire ${ver:-(unknown version)}; bercail needs $min: older ones stop capturing a desk after /reload, /new or /resume, and panic on pre-push with config.worktree (you run: entire update)"
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

# A client's backend: hc reaches it, and the bercail there is this one's version,
# since the mods here speak to it. `bercail help` prints the version on its first
# line in every release, so an older backend answers too.
doctor_backend() {
  local backend err out status=0 found message advice src
  # shellcheck source=lib/toml.sh
  source "$(dirname "${BASH_SOURCE[0]}")/toml.sh"
  backend="$(toml_value "$BERCAIL_USER_CONFIG" herdr backend "" 2>/dev/null || true)"
  if [[ -z "$backend" ]]; then
    log "  missing  [herdr] backend in $BERCAIL_USER_CONFIG (run: bercail install --client <machine>)"
    return 1
  fi
  if ! dep_present hc; then
    log "  unchecked  backend $backend: no hc here to reach it"
    return 1
  fi
  err="$(mktemp)"
  # The PATH the mods give bercail there: a login shell may not have ~/.local/bin.
  # shellcheck disable=SC2016 # expanded on the backend
  out="$(hc exec --on "$backend" --timeout 30 bash -lc \
    'command -v bercail >/dev/null || PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"; bercail help' \
    2>"$err" </dev/null)" || status=$?
  message="$(jq -r '.error.message // empty' "$err" 2>/dev/null || true)"
  rm -f "$err"
  if [[ -n "$message" ]]; then
    log "  unreachable  backend $backend: $message (hc machine ls shows the machines added here)"
    return 1
  fi
  if [[ "$status" -ne 0 ]]; then
    log "  missing  bercail on $backend (exit $status; install bercail there)"
    return 1
  fi
  # A login shell there may print first; only a version reaches this terminal.
  found="$(sed -n 's/^bercail v\([0-9A-Za-z.+-]*\)$/\1/p' <<<"$out" | sed -n 1p)"
  if [[ "$found" != "$BERCAIL_VERSION" ]]; then
    # Which side is older only when both are plain x.y.z: sort -V puts 1.0.0-rc after 1.0.0.
    advice="run bercail update on the older one"
    if [[ "$found.$BERCAIL_VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
      if [[ "$(printf '%s\n' "$found" "$BERCAIL_VERSION" | sort -V | tail -n 1)" == "$BERCAIL_VERSION" ]]; then
        advice="run bercail update on $backend"
      else
        advice="run bercail update here"
        src="$(install_src_dir)"
        [[ ! -e "$src/.git" ]] || advice+=": it checks $src against the latest release and names the checkout"
      fi
    fi
    log "  outdated  bercail on $backend is v${found:-unknown}, this computer's is v${BERCAIL_VERSION} ($advice)"
    return 1
  fi
  log "  ok  backend $backend runs bercail v${found}"
}
