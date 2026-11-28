#!/usr/bin/env bash
# shellcheck shell=bash
# Which live Pi processes run older bercail code than is installed. Pi loads its
# -e extensions, and the files they import, once at start: bercail update
# replaces the files, not the code in memory (bercail-wslq). The deploy leaves a
# file whose content is the same in place (copy_file, prune_for_deploy), so a Pi may
# run older code when a file it loaded is not older than its start. That is a
# hint, not proof: a change and a change back count too. Linux only: the
# processes come from /proc (BERCAIL_PROC_DIR in tests).

# The time of the file Pi reads: a symlink's target.
_pi_code_mtime() {
  [[ -f "$1" ]] || return 1
  stat -L -c %Y "$1" 2>/dev/null
}

# FILES and what they import from their own folder ("./x.ts"), one per line.
_pi_code_loaded() {
  local file imp
  local -a todo=("$@")
  local -A seen=()
  while ((${#todo[@]})); do
    file="${todo[0]}"
    todo=("${todo[@]:1}")
    [[ ! -v "seen[$file]" ]] || continue
    seen["$file"]=1
    printf '%s\n' "$file"
    [[ -f "$file" ]] || continue
    while IFS= read -r imp; do
      todo+=("${file%/*}/${imp#./}")
    done < <(grep -oE 'from "\./[^"]+"' "$file" | sed -E 's/^from "(.*)"$/\1/')
  done
}

# The live Pi processes whose loaded bercail code changed since they started,
# as a JSON array of {pid, ppid, terminal (HC_TERMINAL_ID, or ""), started
# (epoch seconds), changed: [paths]}. A file that is gone has changed. Pi is
# the pi command, or node running it; the bash wrappers that start Pi
# (bercail-desk-agent, scratch run) carry the same argv and are not Pi. Equal
# seconds count as changed: the times are whole seconds.
pi_code_stale_json() {
  local proc="${BERCAIL_PROC_DIR:-/proc}" share="${BERCAIL_SHARE_DIR:-$HOME/.local/share/bercail}"
  local cmdline dir pid i btime hz stat started ppid terminal path mtime
  local -a argv exts changed
  btime="$(awk '/^btime/ { print $2 }' "$proc/stat" 2>/dev/null)" || btime=""
  [[ -n "$btime" ]] || { printf '[]'; return 0; }
  # Linux's clock tick is 100 wherever getconf is missing from PATH.
  hz="$(getconf CLK_TCK 2>/dev/null)" || hz=100
  while IFS= read -r -d '' cmdline; do
    dir="${cmdline%/cmdline}"
    pid="${dir##*/}"
    [[ -O "$dir" ]] || continue
    # A process that exited since the grep has an empty argv.
    mapfile -d '' argv 2>/dev/null <"$cmdline" && ((${#argv[@]})) || continue
    path="${argv[1]:-}"
    [[ "${argv[0]##*/}" == pi || ( "${argv[0]##*/}" == node* && "${path##*/}" == pi ) ]] || continue
    exts=()
    for ((i = 1; i < ${#argv[@]}; i++)); do
      case "${argv[i]}" in
        -e | --extension) path="${argv[i + 1]:-}" ;;
        --extension=*) path="${argv[i]#*=}" ;;
        *) continue ;;
      esac
      [[ "$path" != "$share"/* ]] || exts+=("$path")
    done
    ((${#exts[@]})) || continue
    stat="$(cat "$dir/stat" 2>/dev/null)" || continue
    read -r ppid started < <(awk -v b="$btime" -v hz="$hz" '{ print $2, b + int($20 / hz) }' <<<"${stat##*)}")
    changed=()
    while IFS= read -r path; do
      mtime="$(_pi_code_mtime "$path")" || mtime=""
      [[ -n "$mtime" && "$mtime" -lt "$started" ]] || changed+=("$path")
    done < <(_pi_code_loaded "${exts[@]}")
    ((${#changed[@]})) || continue
    terminal="$(tr '\0' '\n' 2>/dev/null <"$dir/environ" | sed -n 's/^HC_TERMINAL_ID=//p' | head -n 1)" || terminal=""
    jq -nc --argjson pid "$pid" --argjson ppid "$ppid" --arg terminal "$terminal" --argjson started "$started" \
      '{pid: $pid, ppid: $ppid, terminal: $terminal, started: $started, changed: $ARGS.positional}' --args -- "${changed[@]}"
  done < <(grep -lZF -- "$share/" "$proc"/[0-9]*/cmdline 2>/dev/null) | jq -sc .
}

# For bercail update: each live Pi that may run code older than what is
# installed, and how to restart it. Nothing when there is none. A Pi counts as
# a terminal's own when it is the terminal's process or its child (Shep's Pi
# under bercail shep run); any other only inherited the terminal's env.
pi_code_report() {
  local stale p terminal detail hc=1 rc
  stale="$(pi_code_stale_json)" || return 1
  [[ "$(jq length <<<"$stale")" -gt 0 ]] || return 0
  log ""
  log "Pi that may still run bercail code older than what is installed (restart each to load it):"
  while IFS= read -r p; do
    terminal="$(jq -r .terminal <<<"$p")"
    detail='null'
    if [[ -n "$terminal" ]] && ((hc)); then
      # A Herdr core that does not answer names no terminal; it must not hold up the update.
      rc=0
      detail="$(_git_backend_bounded 3 _desk_hc get "$terminal" --json 2>/dev/null </dev/null)" || rc=$?
      ((rc != 124)) || hc=0
      ((rc == 0)) || detail='null'
    fi
    jq -nr --argjson d "${detail:-null}" --argjson p "$p" '
      ($d.labels // {}) as $l | ($d.name // $p.terminal) as $name
      | if $d == null or ($d.pid != $p.pid and $d.pid != $p.ppid) then
          "pid \($p.pid)" + (if $p.terminal != "" then " (started from \($p.terminal))" else "" end) + ": quit it and start it again"
        elif $l["bercail.role"] == "shep" then "Shep (\($p.terminal)): quit the Shep terminal, then Start Shep; it continues its session"
        elif $l["bercail.shep"] == "bg" then
          "background Shep \($name) (\($p.terminal)): let it report, then start a new one if \($l["bercail.issue"] // "its job") still needs it: bercail shep bg --issue \($l["bercail.issue"] // "ID") --cwd \($d.cwd // "DIR")"
        elif $l["bercail.role"] == "agent" then
          "desk \($p.terminal)" + (if $l["bercail.issue"] then " (\($l["bercail.issue"]): \($l["bercail.issue_title"] // ""))" else "" end)
          + " is \($d.status.state // "in an unknown state"); bercail desk restart \($p.terminal) restarts it once it is idle"
        else "\($l["bercail.role"] // "terminal") \($name) (\($p.terminal)): let it finish, then start it again" end
      | "  - \(.) · changed: \($p.changed | map(split("/") | if .[-1] == "index.ts" then .[-2] else .[-1] end) | unique | join(", "))"'
  done < <(jq -c '.[]' <<<"$stale")
}
