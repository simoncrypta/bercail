#!/usr/bin/env bash
# shellcheck shell=bash
# Shep, bercail's orchestrator, in the Herdr app's Shep view: Pi in its own
# folder and session, on bercail's Pi models, with Shep's rules (shep/SHEP.md).
#
#   bercail shep run                       what the Shep view's terminal runs
#   bercail shep status
#   bercail shep bg --issue ID [--cwd DIR] a background Shep: waits and reports
#   bercail shep diagram [FILE]            a diagram Shep did not write, without its links
#   bercail shep discuss Qn@rev            what the Discuss modal's terminal runs
#   bercail shep repos | brief | board | queue | remember | forget | list | mistake   (lib/shep-context.sh)

# shellcheck source=lib/shep-context.sh
source "$(dirname "${BASH_SOURCE[0]}")/shep-context.sh"
# shellcheck source=lib/scratch.sh
source "$(dirname "${BASH_SOURCE[0]}")/scratch.sh"

SHEP_SKILLS=(handoff desk-restore how why unslop describe)
SHEP_USAGE="usage: bercail shep run | status | runtime | task dispatch (JSON stdin) | bg --issue ID [--cwd DIR] | discuss Qn@rev | repos [--json] | brief ISSUE [--repo DIR] [--budget CHARS] | board | queue [--repo DIR] [--json] | remember \"RULE\" [--scope SCOPE] | forget N | list | mistake KEY \"WHAT\" [--group ID] [--repo DIR] [--issue ID] | mistake group ID \"NAME\" --against process|tool|conduct [KEY...] | mistake list | diagram [FILE] | questions [--json [--all]] | question create|revise|reply|answer|withdraw|get|check|thread|panel|expire|waiting|discuss|closed|push-approval"

shep_state_dir() {
  printf '%s/bercail/shep' "${XDG_STATE_HOME:-$HOME/.local/state}"
}

shep_share_dir() {
  printf '%s/shep' "${BERCAIL_SHARE_DIR:-$HOME/.local/share/bercail}"
}

_shep_err() {
  printf 'bercail shep: %s\n' "$*" >&2
}

# Where the notify follower drops desk events, once Shep has started (its first
# run makes the inbox), so events do not pile up for a Shep nobody runs.
shep_inbox_dir() {
  local inbox
  inbox="$(shep_state_dir)/inbox"
  [[ -d "$inbox" ]] && printf '%s' "$inbox"
  return 0
}

# Pi's argv for Shep, into SHEP_PI_ARGV: the lead's model and extensions from
# bstack (lead.json), Shep's rules and start context, its inbox
# and compaction extensions, and its own session folder. No context files: the
# person's global Pi persona and any AGENTS.md stay out of Shep. --approve
# trusts the workspace, a folder only bercail writes, so Pi loads its
# .pi/settings.json (Shep's compaction) without asking.
shep_pi_argv() {
  local lead="${BSTACK_PI_DIR:-${BERCAIL_SHARE_DIR:-$HOME/.local/share/bercail}/pi}/lead.json"
  local share state id model ext rollover=0
  share="$(shep_share_dir)"
  state="$(shep_state_dir)"
  [[ "$(toml_value "$BERCAIL_USER_CONFIG" shep rollover)" != true ]] || rollover=1
  SHEP_PI_ARGV=(env -u ANTHROPIC_API_KEY -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN
    BERCAIL_ROLE=shep "BERCAIL_SHEP_INBOX=$state/inbox" "BERCAIL_SHEP_STATE=$state"
    "BERCAIL_SHEP_BIN=${BERCAIL_SELF:-bercail}" "BERCAIL_SHEP_ROLLOVER=$rollover"
    "BERCAIL_SHEP_DECISION_TIMEOUT=$(toml_value "$BERCAIL_USER_CONFIG" shep decision_timeout)" pi)
  if [[ -r "$lead" ]]; then
    model="$(jq -r 'index("--model") as $i | if $i then .[$i + 1] else empty end' "$lead" 2>/dev/null || true)"
    [[ -z "$model" ]] || SHEP_PI_ARGV+=(--model "$model")
    while IFS= read -r ext; do
      [[ -n "$ext" ]] && SHEP_PI_ARGV+=(-e "$ext")
    done < <(jq -r '. as $a | range(0; length) | select($a[.] == "-e") | $a[. + 1]' "$lead" 2>/dev/null || true)
  fi
  SHEP_PI_ARGV+=(-e "${BERCAIL_SHARE_DIR:-$HOME/.local/share/bercail}/pi-extensions/bercail-desk.ts" -e "$share/pi/inbox.ts" -e "$share/pi/compaction.ts" -e "$share/pi/question-commands.ts" --append-system-prompt "$share/SHEP.md"
    --append-system-prompt "$state/context.md" --no-context-files --no-skills --approve
    --session-dir "$state/pi-sessions" --continue --name Shep)
  for id in "${SHEP_SKILLS[@]}"; do
    [[ -d "$(skill_canonical_dir "$id")" ]] && SHEP_PI_ARGV+=(--skill "$(skill_canonical_dir "$id")")
  done
  return 0
}

# Pi's argv for a Discuss branch, into SHEP_DISCUSS_ARGV: the lead's model and
# extensions (the guard among them), read-only tools and nothing discovered, so
# the branch can read but not run, edit, spawn, send, commit or remember. The
# guard blocks the rest under BERCAIL_ROLE=discuss. SESSION is the branch.
shep_discuss_argv() {
  local token="$1" session="$2"
  local lead="${BSTACK_PI_DIR:-${BERCAIL_SHARE_DIR:-$HOME/.local/share/bercail}/pi}/lead.json"
  local model ext
  SHEP_DISCUSS_ARGV=(env -u ANTHROPIC_API_KEY -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN -u BERCAIL_SHEP_INBOX
    BERCAIL_ROLE=discuss "BERCAIL_SHEP_STATE=$(shep_state_dir)" "BERCAIL_SHEP_BIN=${BERCAIL_SELF:-bercail}"
    "BERCAIL_DISCUSS_TOKEN=$token" pi)
  if [[ -r "$lead" ]]; then
    model="$(jq -r 'index("--model") as $i | if $i then .[$i + 1] else empty end' "$lead" 2>/dev/null || true)"
    [[ -z "$model" ]] || SHEP_DISCUSS_ARGV+=(--model "$model")
    while IFS= read -r ext; do
      [[ -n "$ext" ]] && SHEP_DISCUSS_ARGV+=(-e "$ext")
    done < <(jq -r '. as $a | range(0; length) | select($a[.] == "-e") | $a[. + 1]' "$lead" 2>/dev/null || true)
  fi
  SHEP_DISCUSS_ARGV+=(-e "$(shep_share_dir)/pi/discuss.ts" --tools "read,grep,find,ls" --no-extensions --no-mcp
    --no-skills --no-prompt-templates --no-context-files --session "$session")
}

# What the Discuss modal's terminal runs: Pi on the question's branch, made on the
# first open and continued after.
shep_discuss() {
  local token="${1:-}" out session cwd code=0
  if [[ ! "$token" =~ ^Q[1-9][0-9]*@[1-9][0-9]*$ ]]; then
    _shep_err "usage: bercail shep discuss Qn@rev (a question token from bercail shep questions)"
    return 1
  fi
  if ! out="$(shep_question discuss "$token")"; then
    _shep_ended 1
    return 0
  fi
  session="$(jq -r .session <<<"$out")"
  cwd="$(jq -r .cwd <<<"$out")"
  [[ -d "$cwd" ]] || cwd="$HOME"
  shep_discuss_argv "$token" "$session"
  (cd "$cwd" && "${SHEP_DISCUSS_ARGV[@]}") || code=$?
  _shep_ended "$code"
}

# Pi that fails leaves its message on screen until Enter.
_shep_ended() {
  local code="$1"
  [[ "$code" -eq 0 ]] && return 0
  printf '\nShep (pi) exited with code %s. Press Enter to close.\n' "$code" >&2
  read -r _ || true
  return 0
}

# Seconds a stopped Pi has to exit on SIGTERM before it is killed.
SHEP_STOP_GRACE="${BERCAIL_SHEP_STOP_GRACE:-5}"
[[ "$SHEP_STOP_GRACE" =~ ^(0|[1-9][0-9]{0,3})$ ]] || SHEP_STOP_GRACE=5

# Every live process at or under pid ROOT, one "pid start" per line. The start
# time (to the second) is what tells a pid the system reused from the process
# that had it. Fails when ps does.
_shep_tree() {
  LC_ALL=C ps -A -o pid=,ppid=,stat=,lstart= | awk -v root="$1" '
    $3 !~ /^Z/ { up[$1] = $2; start[$1] = $4 " " $5 " " $6 " " $7 " " $8 }
    END { for (p in up) { q = p; while (q != root && q in up) q = up[q]; if (q == root) print p, start[p] } }'
}

# The pids in TREE (from _shep_tree) still alive as the same process.
_shep_alive() {
  LC_ALL=C ps -A -o pid=,stat=,lstart= | awk 'NR == FNR { want[$0]; next }
    $2 !~ /^Z/ && ($1 " " $3 " " $4 " " $5 " " $6 " " $7) in want { print $1 }' <(printf '%s\n' "$1") -
}

# TERM to Pi at PID, then SIGKILL to whatever of it and its helpers still runs
# SHEP_STOP_GRACE seconds later: a Pi stuck after a provider switch ignores
# TERM. Helpers are what ps shows under Pi at the first look, taken before the
# TERM because a helper leaves Pi's tree once Pi dies, and at the last look,
# while Pi is the same process. A pid gets a signal only while ps shows it
# with the start time first seen. Prints the pids it sent SIGKILL. Without ps
# it does nothing.
_shep_pi_stop() {
  local pid="$1" tree root last left end p
  tree="$(_shep_tree "$pid")" || return 0
  root="$(grep "^$pid " <<<"$tree")" || return 0
  kill -TERM "$pid" 2>/dev/null || true
  # SECONDS counts whole seconds, so <= waits the full grace, up to a second more.
  end=$((SECONDS + SHEP_STOP_GRACE))
  while ((SECONDS <= end)); do
    left="$(_shep_alive "$tree")" || return 0
    [[ -n "$left" ]] || return 0
    sleep 0.1
  done
  last="$(_shep_tree "$pid")" || last=""
  ! grep -qxF "$root" <<<"$last" || tree+=$'\n'"$last"
  left="$(_shep_alive "$tree")" || return 0
  for p in $left; do
    kill -KILL "$p" 2>/dev/null && printf '%s\n' "$p"
  done
  return 0
}

# Runs Pi in DIR as a job, not in the foreground: bash holds a trap until its
# foreground child exits, so a stop could not reach Pi. The job keeps the
# terminal (its stdin, the foreground group) and gets INT and QUIT back, which
# bash ignores in a job. A stop (HUP, INT or TERM) runs _shep_pi_stop in a
# process group of its own: hc kill SIGKILLs the terminal's group a second
# after its hangup, wrapper included, and the stop must outlive that to kill a
# stuck Pi's helpers. Only a wrapper that survives prints the note and returns
# 128 + the signal, with SHEP_PI_STOPPED set; otherwise Pi's status.
_shep_pi_job() {
  local dir="$1" pid code=0 left end
  shift
  SHEP_PI_STOPPED=""
  trap 'SHEP_PI_STOPPED=HUP' HUP
  trap 'SHEP_PI_STOPPED=INT' INT
  trap 'SHEP_PI_STOPPED=TERM' TERM
  (cd "$dir" && trap - INT QUIT && exec "$@") <&0 &
  pid=$!
  # A trapped signal ends the wait at once. One that came before it is in the
  # flag; one in the instant between the check and the wait is missed.
  [[ -n "$SHEP_PI_STOPPED" ]] || wait "$pid" || code=$?
  if [[ -n "$SHEP_PI_STOPPED" ]]; then
    trap '' HUP INT TERM
    # Bash's job notices ("Killed") go to /dev/null; the note goes to fd 3.
    {
      left="$(exec </dev/null; set -m; _shep_pi_stop "$pid" & wait "$!")"
      left="${left//$'\n'/ }"
      # The stop could not see Pi (no ps). This shell's job table still knows
      # it, Pi being its only job: kill %+ signals Pi only while bash has not
      # reaped it.
      if [[ -n "$(jobs -rp)" ]]; then
        kill -TERM %+ 2>/dev/null || true
        end=$((SECONDS + SHEP_STOP_GRACE))
        while [[ -n "$(jobs -rp)" ]] && ((SECONDS <= end)); do sleep 0.1; done
        [[ -z "$(jobs -rp)" ]] || ! kill -KILL %+ 2>/dev/null || left="${left:+$left }$pid"
      fi
      [[ -z "$left" ]] || _shep_err "force-kill: sent SIGKILL ${SHEP_STOP_GRACE}s after Pi's SIGTERM to pids $left" 2>&3 || true
      wait "$pid" || true
    } 3>&2 2>/dev/null
    code=$((128 + $(kill -l "$SHEP_PI_STOPPED")))
  fi
  trap - HUP INT TERM
  return "$code"
}

# What the Shep view's terminal runs.
shep_run() {
  local state dir="" code=0 i
  if ! command -v pi >/dev/null 2>&1; then
    _shep_err "Pi is not installed; install it with: mise use -g pi (or run: bercail bstack setup)"
    _shep_ended 1
    return 0
  fi
  state="$(shep_state_dir)"
  mkdir -p "$state/workspace" "$state/pi-sessions" "$state/inbox" "$state/delivered"
  # Neither may keep Shep from starting.
  shep_settings_write "$state/workspace/.pi/settings.json" \
    || _shep_err "could not write $state/workspace/.pi/settings.json; Pi's compaction defaults apply"
  shep_context_write "$state/context.md" || _shep_err "could not write $state/context.md; Shep starts without it"
  shep_pi_argv
  # Its own TMPDIR, removed when Shep exits, as a desk's is: bercail scratch
  # run's steps, here, so that Pi stays the job a stop signals.
  if dir="$(scratch_dir "$$")"; then
    export TMPDIR="$dir"
  else
    _shep_err "no scratch folder under $(scratch_root); Pi runs on TMPDIR=${TMPDIR:-/tmp}"
  fi
  _shep_pi_job "$state/workspace" "${SHEP_PI_ARGV[@]}" || code=$?
  # After the stop. A child Pi started as it was killed may hold the folder an
  # instant; one that holds it longer leaves it to bercail scratch sweep.
  if [[ -n "$dir" ]]; then
    for ((i = 0; i < 10; i++)); do
      _scratch_held "$dir" || break
      sleep 0.1
    done
    _scratch_release "$dir"
  fi
  # A stop closes the terminal; nobody is there to press Enter.
  [[ -n "$SHEP_PI_STOPPED" ]] && return "$code"
  _shep_ended "$code"
}

shep_status() {
  local state queued=0 pending=0 persisted=0 uncertain=0 quarantined=0 file row last=""
  state="$(shep_state_dir)"
  printf 'pi sessions: %s\n' "$state/pi-sessions"
  [[ -d "$state/inbox" ]] && queued="$(find "$state/inbox" -maxdepth 1 -name '*.json' | wc -l)"
  if [[ -d "$state/delivered" ]]; then
    while IFS= read -r -d '' file; do
      if row="$(jq -er 'select(.persisted_entry_id | type == "string" and length > 0)
        | [.persisted_at, (.event_id // .notice_id)] | @tsv' "$file" 2>/dev/null)"; then
        persisted=$((persisted + 1))
        [[ "$row" > "$last" ]] && last="$row"
      else
        pending=$((pending + 1))
        if jq -e '.delivery_error | type == "string" and length > 0' "$file" >/dev/null 2>&1; then
          uncertain=$((uncertain + 1))
        fi
      fi
    done < <(find "$state/delivered" -maxdepth 1 -name '*.json' -print0)
    quarantined="$(find "$state/delivered" -maxdepth 1 -name '*.invalid' | wc -l)"
  fi
  printf 'desk notices: %s queued, %s awaiting persistence (%s uncertain), %s persisted to session\n' \
    "$((queued))" "$pending" "$uncertain" "$persisted"
  [[ -z "$last" ]] || printf 'last persisted: %s at %s\n' "${last#*$'\t'}" "${last%%$'\t'*}"
  printf 'quarantined: %s\nPersistence is not handled, action-completed, or read by the person.\n' "$((quarantined))"
  shep_bg_list
  return 0
}

# Live background Sheps, one line each; none when hc does not answer.
shep_bg_list() {
  local rows
  rows="$("${HC_BIN:-hc}" ls --json --label bercail.shep=bg 2>/dev/null </dev/null | jq -r '
    .terminals[]? | select(.state == "live")
    | "- \(.name // .address) (\(.address)) \(.status.state // "?"): \(.labels["bercail.issue"] // "?") \(.labels["bercail.issue_title"] // "")"' 2>/dev/null)" || rows=""
  if [[ -n "$rows" ]]; then
    printf 'background Sheps:\n%s\n' "$rows"
  else
    printf 'background Sheps: none\n'
  fi
}

# Past this, a label title is cut and ends in "…", as handoff-spawn's are.
SHEP_TITLE_MAX=60

# Title of beads issue or trail ID from DIR, one line, cut to SHEP_TITLE_MAX.
# Fails when bd or Entire does not know the job there.
_shep_issue_title() {
  local dir="$1" id="$2" raw
  if _shep_is_trail "$id"; then
    raw="$(_shep_job show "$id" --repo "$dir" --json 2>/dev/null </dev/null)" || return 1
  else
    raw="$(cd "$dir" && _shep_bd show "$id" --json 2>/dev/null </dev/null)" || return 1
  fi
  jq -er --argjson max "$SHEP_TITLE_MAX" '
    (if type == "array" then .[0] else . end).title // empty
    | gsub("[[:space:][:cntrl:]]+"; " ") | gsub("^ +| +$"; "")
    | if length > $max then (.[0:($max - 1)] | gsub(" +$"; "")) + "…" else . end' <<<"$raw" 2>/dev/null
}

# A background Shep: Pi on the lead's setup (guard and repo policy included) in
# a background hc terminal with no space, so nothing in the app moves. Its
# labels make it a desk to the notify follower, so its finish or block reaches
# Shep's inbox as a desk event; bercail.shep=bg marks it as Shep's own worker.
# --no-notify: the event is the report, not a note typed into Shep's prompt.
# --outlive-parent: a Shep restart does not drop the wait. --rm: `hc kill` is
# the whole cleanup once it has reported.
shep_bg() {
  local issue="" cwd="$PWD" title name lead brief prompt stop="." out model ext guard main
  local hc="${HC_BIN:-hc}" agent="$LOCAL_BIN/bercail-desk-agent"
  local -a cmd
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --issue) issue="${2:-}"; shift 2 || shift $# ;;
      --issue=*) issue="${1#*=}"; shift ;;
      --cwd) cwd="${2:-}"; shift 2 || shift $# ;;
      --cwd=*) cwd="${1#*=}"; shift ;;
      *) _shep_err "usage: bercail shep bg --issue ID [--cwd DIR]"; return 1 ;;
    esac
  done
  [[ -n "$issue" ]] || { _shep_err "usage: bercail shep bg --issue ID [--cwd DIR]"; return 1; }
  _shep_job_id_ok "$issue" || return 1
  cwd="$(cd "$cwd" 2>/dev/null && pwd -P)" || { _shep_err "no folder $cwd; pass the repo's checkout with --cwd"; return 1; }
  title="$(_shep_issue_title "$cwd" "$issue")" \
    || { _shep_err "$(_shep_job_unknown "$issue" "$cwd"); run it from the job's repo or pass --cwd"; return 1; }
  name="shep-bg-$(printf '%s' "${issue,,}" | tr -c 'a-z0-9_-' '-')"
  # Trail numbers repeat across projects: a trail's worker is named by its main
  # checkout too (a hash of its path, after a hint of its name), cut to fit hc's 32.
  if _shep_is_trail "$issue"; then
    main="$(_shep_main_of "$cwd" 2>/dev/null)" || main="$cwd"
    name="$(basename "$main")"
    name="$(printf '%s' "${name,,}" | tr -c 'a-z0-9_-' '-')"
    name="shep-bg-${name:0:$((18 - ${#issue}))}-$(printf '%s' "$main" | sha256sum | cut -c1-4)-trail-${issue#trail:}"
  fi
  name="${name:0:32}"
  if "$hc" get "$name" --json 2>/dev/null </dev/null | jq -e '.state == "live"' >/dev/null 2>&1; then
    _shep_err "$name is already running; see it with: hc read $name, or end it with: hc kill $name"
    return 1
  fi
  [[ -x "$agent" ]] || agent="bercail-desk-agent"
  brief="$(shep_share_dir)/BACKGROUND.md"
  # hc run starts the worker from the Herdr server, so only this env prefix reaches it.
  cmd=(env -u ANTHROPIC_API_KEY -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN -u BERCAIL_SHEP_INBOX
    BERCAIL_ROLE=shep-bg "BERCAIL_ISSUE=$issue" "BERCAIL_BG_BRIEF=$brief"
    TERM=xterm-256color COLORTERM=truecolor)
  title="${title%.}"
  [[ "$title" != *… ]] || stop=""
  if _shep_is_trail "$issue"; then
    prompt="Your job is $issue: $title$stop Run \`bercail job show $issue\` (its body and comments) and do exactly what it describes, then stop."
  else
    prompt="Your job is beads issue $issue: $title$stop Run \`bd show $issue\` (read its comments too) and do exactly what it describes, then stop."
  fi
  cmd+=("$agent" --prompt "$prompt")
  lead="${BSTACK_PI_DIR:-${BERCAIL_SHARE_DIR:-$HOME/.local/share/bercail}/pi}/lead.json"
  [[ -r "$lead" ]] && jq -e 'type == "array" and .[0] == "pi" and index("--model") != null
    and any(.[]; test("(^|/)guard\\.ts$"))' "$lead" >/dev/null 2>&1 \
    || { _shep_err "required lead model/guard profile missing or invalid: $lead; no generic Pi fallback"; return 1; }
  guard="$(jq -r '.[] | select(test("(^|/)guard\\.ts$"))' "$lead")"
  [[ -r "$guard" ]] || { _shep_err "required guard resource missing: $guard; no background worker started"; return 1; }
  [[ -r "$brief" && -r "$(shep_share_dir)/pi/background.ts" ]] || { _shep_err "background profile is missing; run bercail update"; return 1; }
  model="$(jq -r 'index("--model") as $i | .[$i + 1]' "$lead")"
  cmd+=(pi --model "$model")
  while IFS= read -r ext; do
    [[ -n "$ext" ]] && cmd+=(-e "$ext")
  done < <(jq -r '. as $a | range(0; length) | select($a[.] == "-e") | $a[. + 1]
    | select(test("review\\.ts$") | not)' "$lead")
  cmd+=(-e "$(shep_share_dir)/pi/background.ts" --no-extensions --no-mcp --no-skills
    --no-prompt-templates --no-context-files --no-approve --tools "read,grep,find,ls,bash,shep_wait"
    --system-prompt "$brief")
  out="$("$hc" run --bg --json --name "$name" --cwd "$cwd" --outlive-parent --no-notify --rm \
    --label bercail.role=agent --label bercail.shep=bg --label "bercail.issue=$issue" \
    --label "bercail.issue_title=$title" -- "${cmd[@]}" </dev/null)" \
    || { _shep_err "hc could not start $name; its error is above"; return 1; }
  jq -c --arg issue "$issue" --arg title "$title" '{address, name, cwd, issue:$issue, issue_title:$title}' <<<"$out"
}

# Install Shep's package: its rules, the background Shep's brief, and Pi extensions.
deploy_shep() {
  local share rel
  share="$(shep_share_dir)"
  # pi/ holds only what this installs, so a file a release dropped goes with it.
  [[ ! -d "$share/pi" ]] || run rm -rf "$share/pi"
  for rel in SHEP.md BACKGROUND.md pi/background.ts pi/inbox.ts pi/compaction.ts pi/questions.ts pi/question-commands.ts pi/question-target.ts pi/question-cli.ts pi/discuss.ts pi/land-chain.ts; do
    deploy_install_file "shep/$rel" "$share/$rel"
  done
}

# Use this checkout's helper, or the deployed sibling of lib/ for an installed CLI.
shep_question() {
  local script
  script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/shep/pi/question-cli.ts"
  command -v node >/dev/null 2>&1 || { _shep_err "question commands need Node (installed with Pi)"; return 1; }
  # [shep] decision_timeout: the minutes a reversible question waits before it defaults.
  BERCAIL_SHEP_STATE="$(shep_state_dir)" BERCAIL_SHEP_BIN="${BERCAIL_SELF:-bercail}" \
    BERCAIL_SHEP_DECISION_TIMEOUT="$(toml_value "$BERCAIL_USER_CONFIG" shep decision_timeout)" node "$script" "$@"
}

# Prints Mermaid source (FILE or stdin) without its click and link statements,
# which Pi turns into live links. It errs toward dropping, because Pi's renderer
# deletes controls and splits on Unicode spaces first (docs/shep.md#diagrams-in-chat).
shep_diagram() {
  local src="${1:--}"
  [[ $# -le 1 ]] || { _shep_err "usage: bercail shep diagram [FILE] (stdin without one)"; return 1; }
  [[ "$src" == - || -r "$src" ]] || { _shep_err "cannot read $src; pass a Mermaid file, or the diagram on stdin"; return 1; }
  cat -- "$src" | LC_ALL=C tr -d '\000-\010\013\014\016-\037\177' | LC_ALL=C awk '
    function add(st,   w) {
      w = st; sub(/^([ \t\r\v\f]|[\200-\377])+/, "", w)
      if (tolower(w) ~ /^(click|link)[^a-z0-9_]/) { n++; cut = 1; return }
      gsub(/^[ \t]+|[ \t]+$/, "", st)
      if (st != "") out = out (out == "" ? "" : "; ") st
    }
    {
      gsub(/\302[\200-\237]/, "")
      match($0, /^[ \t]*/); ind = substr($0, 1, RLENGTH)
      cur = ""; tail = ""; out = ""; q = 0; cut = 0
      for (i = 1; i <= length($0); i++) {
        c = substr($0, i, 1)
        if (c == "\"") q = !q
        if (!q && c == "%" && substr($0, i + 1, 1) == "%") { tail = substr($0, i); break }
        if (!q && c == ";") { add(cur); cur = ""; continue }
        cur = cur c
      }
      add(cur)
      if (!cut) print
      else if (out tail != "") print ind out (out != "" && tail != "" ? " " : "") tail
    }
    END { if (n) printf "bercail shep: dropped %d click/link statement(s)\n", n > "/dev/stderr" }'
}

cmd_shep() {
  case "${1:-status}" in
    run) shep_run ;;
    status) shep_status ;;
    bg) shift; shep_bg "$@" ;;
    # [shep] spawn_timeout: the seconds dispatch gives handoff-spawn to start a desk.
    task) shift; BERCAIL_SPAWN_TIMEOUT="$(toml_value "$BERCAIL_USER_CONFIG" shep spawn_timeout)" \
      node "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/shep-task.ts" "$@" ;;
    runtime) node "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/runtime.ts" ;;
    discuss) shift; shep_discuss "$@" ;;
    repos) shift; shep_repos "$@" ;;
    brief) shift; shep_brief "$@" ;;
    board) shift; shep_board "$@" ;;
    board-snapshot) shift; _shep_board_snapshot "$@" ;;
    queue) shift; shep_queue "$@" ;;
    queue-snapshot) shift; _shep_queue_snapshot "$@" ;;
    remember) shift; shep_remember "$@" ;;
    forget) shift; shep_forget "$@" ;;
    list) shift; shep_list "$@" ;;
    mistake) shift; shep_mistake "$@" ;;
    diagram) shift; shep_diagram "$@" ;;
    # --json is what waits on the person; --json --all the whole ledger.
    questions) shift
      case "$#:${1:-}:${2:-}" in
        1:--json:) shep_question pending ;;
        2:--json:--all | 2:--all:--json) shep_question json ;;
        0::) shep_question list ;;
        *) _shep_err "usage: bercail shep questions [--json [--all]]"; return 1 ;;
      esac ;;
    question) shift; shep_question "$@" ;;
    *) _shep_err "$SHEP_USAGE"; return 1 ;;
  esac
}
