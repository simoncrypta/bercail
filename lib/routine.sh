#!/usr/bin/env bash
# shellcheck shell=bash
# Routines: a model-free query you declare as [routine.<name>] in config.toml,
# run outside Shep's session. It prints findings, one JSON object a line, and
# only new or changed ones count (docs/routines.md). This is the runner, its
# state and its locks; tests/statechart/routine-run/RoutineRun.tla models them.
#
# routines/<name>/ in the state dir holds state.json (next due, failures in a
# row, paused, the hash sent per key), runs.jsonl (a line per run), outputs/
# (what each run found) and lock, which flock -n holds while a run lasts.
# routines/.slots/slot.N are the 2 slots: at most 2 routines run at once.
# Every write to state.json and runs.jsonl is under state.lock, and the end of
# a run reads state.json again there, so a pause made meanwhile holds.

# shellcheck source=lib/toml.sh
source "$(dirname "${BASH_SOURCE[0]}")/toml.sh"

ROUTINE_SLOTS=2
ROUTINE_OUTPUT_MAX=65536
ROUTINE_KEEP_RUNS=100
ROUTINE_KEEP_OUTPUTS=10

routine_dir() {
  printf '%s/bercail/routines' "${XDG_STATE_HOME:-$HOME/.local/state}"
}

# The built-ins, one name a line: lib/routine/<name>.sh.
routine_builtins() {
  local f
  for f in "$(dirname "${BASH_SOURCE[0]}")"/routine/*.sh; do
    [[ -f "$f" ]] || continue
    f="${f##*/}"
    printf '%s\n' "${f%.sh}"
  done
}

# Each [routine.<name>] in config.toml, a JSON line each in file order:
# {name, run, command, at, every, errors}. errors says what is wrong, in words.
routine_entries() {
  [[ -f "$BERCAIL_USER_CONFIG" ]] || return 0
  toml_records "$BERCAIL_USER_CONFIG" | jq -sc --arg builtins "$(routine_builtins)" '
    ($builtins | split("\n")) as $builtins
    | reduce (.[] | select(has("key") and (.section | length) == 2 and .section[0] == "routine")) as $r
        ({}; .[$r.section[1]][$r.key] = ($r.value // $r.raw))
    | to_entries[]
    | .key as $name | .value as $v
    | [ if ($name | test("^[A-Za-z0-9][A-Za-z0-9_-]*$") | not) then "a name is letters, digits, - and _"
        else
          (if $v | has("run") and has("command") then "run and command are both set"
           elif ($v | has("run") or has("command")) | not then "no run or command"
           elif $v | has("run") then
             if ($v.run | type) != "string" or ($v.run | IN($builtins[]) | not)
             then "no built-in \($v.run) (lib/routine/<name>.sh)" else empty end
           elif ($v.command | type) != "array" or ($v.command | length) == 0
                or any($v.command[]; type != "string")
           then "command must be a list of strings, like [\"~/bin/check\", \"--json\"]"
           else empty end),
          (if $v | has("at") and has("every") then "at and every are both set"
           elif ($v | has("at") or has("every")) | not then "no at or every"
           elif $v | has("at") then
             if ($v.at | type) == "string" and ($v.at | test("^([01][0-9]|2[0-3]):[0-5][0-9]$")) then empty
             else "at must be HH:MM, not \($v.at)" end
           elif ($v.every | type) == "string" and ($v.every | test("^[1-9][0-9]*[hd]$")) then empty
           else "every must be <n>h or <n>d, at least 1h, not \($v.every)" end)
        end ] as $errors
    | {name: $name, run: $v.run, command: $v.command, at: $v.at, every: $v.every, errors: $errors}'
}

# The routine's name as config.toml writes it.
_routine_label() {
  if [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]]; then printf '%s' "$1"; else jq -nj --arg n "$1" '$n | tojson'; fi
}

# NAME's entry, or an error with the fix. --valid: a valid one.
routine_entry() {
  local name="$1" valid="${2:-}" entry
  entry="$(routine_entries | jq -c --arg n "$name" 'select(.name == $n)')"
  [[ -n "$entry" ]] || die "no routine $name in $BERCAIL_USER_CONFIG; declare [routine.$name] with command or run, and at or every (docs/routines.md)"
  if [[ -n "$valid" ]] && jq -e '.errors != []' <<<"$entry" >/dev/null; then
    die "routine $(_routine_label "$name"): $(jq -r '.errors | join("; ")' <<<"$entry"); fix [routine.$name] in $BERCAIL_USER_CONFIG"
  fi
  printf '%s' "$entry"
}

_routine_schedule() {
  jq -r 'if .at then "at \(.at)" else "every \(.every)" end' <<<"$1"
}

# The epoch second it is next due after FROM: an every routine that long after
# it, an at routine at its next local HH:MM.
_routine_next_due() {
  local entry="$1" from="$2" at every n hms h m s mid d got
  at="$(jq -r '.at // ""' <<<"$entry")" every="$(jq -r '.every // ""' <<<"$entry")"
  if [[ -n "$every" ]]; then
    n="${every%?}"
    [[ "$every" == *h ]] && printf '%s' $((from + n * 3600)) || printf '%s' $((from + n * 86400))
    return 0
  fi
  printf -v hms '%(%H %M %S)T' "$from"
  read -r h m s <<<"$hms"
  mid=$((from - 10#$h * 3600 - 10#$m * 60 - 10#$s))
  n=$((mid + 10#${at%:*} * 3600 + 10#${at#*:} * 60))
  ((n > from)) || n=$((n + 86400))
  # A day with a clock change is shorter or longer (by an hour, or by half an
  # hour on Lord Howe Island): take the moment that reads HH:MM.
  for d in 0 -3600 3600 -1800 1800; do
    printf -v got '%(%H:%M)T' $((n + d))
    if [[ "$got" == "$at" ]] && ((n + d > from)); then
      n=$((n + d))
      break
    fi
  done
  printf '%s' "$n"
}

_routine_stamp() { TZ=UTC printf '%(%Y%m%dT%H%M%SZ)T' "$1"; }
_routine_iso() { TZ=UTC printf '%(%Y-%m-%dT%H:%M:%SZ)T' "$1"; }
_routine_local() { printf '%(%Y-%m-%d %H:%M)T' "$1"; }

# state.json, with what a routine that never ran has.
routine_state() {
  local file
  file="$(routine_dir)/$1/state.json"
  if [[ -f "$file" ]]; then
    jq -c '{next_due: null, failures: 0, paused: false, sent: {}} + .' "$file"
  else
    printf '{"next_due":null,"failures":0,"paused":false,"sent":{}}'
  fi
}

# Run CMD... holding NAME's state.lock, the only way to write its state.json
# and runs.jsonl. A short lock: only reads and writes of those happen under it.
_routine_with_state() {
  local name="$1" dir fd rc=0
  shift
  dir="$(routine_dir)/$name"
  mkdir -p "$dir"
  exec {fd}>>"$dir/state.lock"
  if ! flock -w 10 "$fd"; then
    exec {fd}>&-
    printf 'error: routine %s: its state stayed locked for 10s; see who holds %s\n' "$name" "$dir/state.lock" >&2
    return 1
  fi
  "$@" || rc=$?
  exec {fd}>&-
  return "$rc"
}

# Under the state lock: write state.json as JSON.
_routine_put_state() {
  local file tmp
  file="$(routine_dir)/$1/state.json"
  tmp="$(mktemp "$file.XXXXXX")" || return 1
  printf '%s\n' "$2" >"$tmp" && mv -f "$tmp" "$file" || { rm -f "$tmp"; return 1; }
}

# Under the state lock: add a run's line, and keep the last 100 runs and the
# last 10 outputs. The trim is best effort: one that fails leaves more, and
# the next run trims them.
_routine_put_run() {
  local dir tmp
  local -a outputs
  dir="$(routine_dir)/$1"
  printf '%s\n' "$2" >>"$dir/runs.jsonl" || return 1
  if (($(wc -l <"$dir/runs.jsonl") > ROUTINE_KEEP_RUNS)); then
    tmp="$(mktemp "$dir/runs.jsonl.XXXXXX")"
    tail -n "$ROUTINE_KEEP_RUNS" "$dir/runs.jsonl" >"$tmp" && mv -f "$tmp" "$dir/runs.jsonl"
  fi
  [[ -d "$dir/outputs" ]] || return 0
  outputs=("$dir"/outputs/*.jsonl)
  ((${#outputs[@]} > ROUTINE_KEEP_OUTPUTS)) || return 0
  rm -f -- "${outputs[@]:0:${#outputs[@]}-ROUTINE_KEEP_OUTPUTS}"
}

_routine_set_paused() {
  local state
  state="$(routine_state "$1" | jq -c --argjson p "$2" '.paused = $p | if $p then . else .failures = 0 end')"
  _routine_put_state "$1" "$state"
}

# A run that went no further than its locks: logged, nothing else.
_routine_skip() {
  local name="$1" dry="$2" id="$3" start="$4" reason="$5" line
  [[ "$dry" == 1 ]] && return 0
  line="$(jq -nc --arg id "$id" --arg t "$(_routine_iso "$start")" --arg r "$reason" \
    '{id: $id, due: $t, start: $t, end: $t, outcome: "skipped", reason: $r, counts: null, event: null, error: null}')"
  _routine_with_state "$name" _routine_put_run "$name" "$line"
}

# Stop process group PID: TERM, then KILL what is left after 2 seconds.
_routine_stop() {
  local _
  kill -TERM -- "-$1" 2>/dev/null || return 0
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 -- "-$1" 2>/dev/null || return 0
    sleep 0.2
  done
  kill -KILL -- "-$1" 2>/dev/null || true
}

# Run CMD... in HOME, as its own process group with nothing on stdin, stdout capped to
# OUT and stderr to ERR, killing the group after LIMIT seconds. The caller's
# lock fds (lfd, sfd) are closed for it, so nothing it leaves behind holds
# them. Status: CMD's, or 124 once it timed out. A signal that stops the
# runner stops CMD's group too.
_routine_exec() {
  local limit="$1" out="$2" err="$3" pid ticks=0 rc=0
  shift 3
  set -m
  { cd "$HOME" || exit 1
    (
      "$@" 2>&1 >&3 3>&- | head -c 4096 >"$err"
      exit "${PIPESTATUS[0]}"
    ) 3>&1 | head -c $((ROUTINE_OUTPUT_MAX + 1)) >"$out"
    exit "${PIPESTATUS[0]}"; } {lfd}>&- {sfd}>&- </dev/null &
  pid=$!
  set +m
  # A runner stopped by a signal takes its query with it.
  # shellcheck disable=SC2064 # pid is fixed now
  trap "_routine_stop $pid; exit 143" INT TERM HUP
  while kill -0 "$pid" 2>/dev/null; do
    if ((ticks >= limit * 5)); then
      _routine_stop "$pid"
      wait "$pid" 2>/dev/null || true
      trap - INT TERM HUP
      return 124
    fi
    sleep 0.2
    ticks=$((ticks + 1))
  done
  wait "$pid" || rc=$?
  trap - INT TERM HUP
  return "$rc"
}

# The query's output OUT as a JSON array of findings in FILE, or the error on
# stderr. Findings go through files: 64 KB of them, with their hashes, is more
# than one argument may hold.
_routine_findings() {
  local got
  if ! got="$(jq -Rsc '
      def str($f; $n): if .[$f] == null or (.[$f] | type) == "string" then .[$f]
        else error("line \($n): \($f) must be a string") end;
      [split("\n") | to_entries[] | select(.value | test("\\S")) | .key += 1
       | .key as $n
       | (try (.value | fromjson) catch null)
       | if type != "object" then error("line \($n) is not a JSON object")
         elif (.key | type) != "string" or .key == "" then error("line \($n) has no key")
         elif (.title | type) != "string" then error("line \($n) has no title")
         else {key, title, detail: str("detail"; $n), repo: str("repo"; $n), issue: str("issue"; $n)} end]
      | ([group_by(.key)[] | select(length > 1)][0]) as $twice
      | if $twice then error("key \($twice[0].key) is there twice: \($twice | map(.title) | join(", "))") else . end
    ' "$1" 2>&1 >"$2")"; then
    printf '%s\n' "$(sed -n 's/^jq: error ([^)]*): //p' <<<"$got" | head -n 1)" >&2
    return 1
  fi
}

# Add to each finding in FILE its hash: sha256 of its canonical JSON line.
# One file a finding, so one sha256sum hashes them all.
_routine_hashed() {
  local file="$1" dir rc=0
  local -a parts
  # Nothing to hash. Some splits (uutils, Ubuntu 26.04's) write an empty file for empty
  # input, which would hash as a finding.
  [[ "$(jq length "$file")" != 0 ]] || return 0
  dir="$(mktemp -d "$file.XXXXXX")" || return 1
  jq -cS '.[]' "$file" | split -l 1 -a 4 - "$dir/f." || rc=1
  parts=("$dir"/f.*)
  ((rc == 0)) && sha256sum "${parts[@]}" | cut -d' ' -f1 >"$dir/hashes" || rc=1
  ((rc == 0)) && jq -c --rawfile h "$dir/hashes" '($h | split("\n") | map(select(. != ""))) as $h
    | if ($h | length) != length then error("\($h | length) hashes for \(length) findings") else . end
    | to_entries | map(.value + {hash: $h[.key]})' "$file" >"$dir/hashed" && mv -f "$dir/hashed" "$file" || rc=1
  rm -rf "$dir"
  return "$rc"
}

# The state lock's half of a run's end: from state.json as it is now, the
# outcome, the state to write, the run's line, what it found and the event, as
# one JSON object in $_routine_result. FINDINGS is their file, or empty for a
# failed run. Unless DRY is 1 it writes what it found, then the run's line,
# then state.json, so a write that fails can repeat an event but never loses
# one; status 1 when one failed.
_routine_finish() {
  local name="$1" dry="$2" ctx="$3" findings="$4" error="$5" dir state
  local -a found=(--argjson f '[null]')
  [[ -z "$findings" ]] || found=(--slurpfile f "$findings")
  dir="$(routine_dir)/$name"
  state="$(routine_state "$name")"
  _routine_result="$(jq -c --argjson c "$ctx" "${found[@]}" --arg err "$error" '
    . as $s | $f[0] as $f
    | {id: $c.id, due: $c.due, start: $c.start, end: $c.end} as $run
    | if $f == null then
        ($s.failures + 1) as $n
        | {state: ($s + {failures: $n, paused: ($s.paused or $n >= 3), next_due: $c.next_due}),
           run: ($run + {outcome: "failed", reason: null, counts: null, event: null, error: $err}),
           paused_now: (($s.paused | not) and $n >= 3), findings: null, event: null}
      else
        ($f | map(. + {status: ($s.sent[.key] as $h
          | if $h == null then "new" elif $h == .hash then "same" else "changed" end)})) as $a
        | {found: ($a | length), new: ([$a[] | select(.status == "new")] | length),
           changed: ([$a[] | select(.status == "changed")] | length)} as $counts
        | (if $counts.new + $counts.changed > 0 then "emitted" else "skipped" end) as $o
        | "routine:\($c.name):\($c.due_stamp)" as $eid
        | {state: ($s + {failures: 0, next_due: $c.next_due, sent: ($a | map({(.key): .hash}) | add // {})}),
           run: ($run + {outcome: $o, reason: (if $o == "skipped" then "quiet" else null end), counts: $counts,
                         event: (if $o == "emitted" then $eid else null end), error: null}),
           paused_now: false,
           findings: ($a | map(del(.hash))),
           event: (if $o == "emitted" then
             {source: "bercail", schema: "bercail.routine/v1", kind: "routine", sink: "shep", at: $c.end,
              event_id: $eid, routine: $c.name, run: $c.id, outcome: $o, counts: $counts,
              text: "Routine \($c.name): \($counts.new) new and \($counts.changed) changed of \($counts.found) found. Read them with bercail routine show \($c.name) --run \($c.id)."}
             else null end)}
      end' <<<"$state")"
  [[ "$dry" == 1 ]] && return 0
  if [[ -n "$findings" ]]; then
    mkdir -p "$dir/outputs" && jq -c '.findings[]' <<<"$_routine_result" >"$dir/outputs/$(jq -r .run.id <<<"$_routine_result").jsonl" \
      || return 1
  fi
  _routine_put_run "$name" "$(jq -c .run <<<"$_routine_result")" || return 1
  _routine_put_state "$name" "$(jq -c .state <<<"$_routine_result")"
}

# A run's line in words: "emitted, 2 found (1 new, 0 changed)".
_routine_said() {
  jq -r 'if .outcome == "emitted" then "emitted, \(.counts.found) found (\(.counts.new) new, \(.counts.changed) changed)"
    elif .outcome == "failed" then "failed: \(.error)"
    elif .reason == "quiet" then "skipped (quiet), \(.counts.found) found, nothing new or changed"
    else "skipped (\(.reason))" end' <<<"$1"
}

# bercail routine run NAME [--dry-run]: run it now, under the same locks and
# limits as a scheduled run. Status 1 when it failed.
routine_run() {
  local name="$1" dry="${2:-0}" entry dir start id lfd="" sfd="" n slots out err rc=0 error="" findings
  local limit="${BERCAIL_ROUTINE_TIMEOUT:-600}" end ctx tail result line wrote=1 _routine_result
  local -a argv
  entry="$(routine_entry "$name" --valid)"
  command -v flock >/dev/null 2>&1 \
    || die "no flock here, and a routine never runs unlocked; install it (util-linux on Linux, brew install flock on macOS)"
  [[ "$limit" =~ ^[1-9][0-9]*$ ]] || die "BERCAIL_ROUTINE_TIMEOUT must be whole seconds above 0, not $limit"
  dir="$(routine_dir)/$name"
  mkdir -p "$dir"
  printf -v start '%(%s)T' -1
  id="$(_routine_stamp "$start")-$$"

  exec {lfd}>"$dir/lock"
  if ! flock -n "$lfd"; then
    exec {lfd}>&-
    _routine_skip "$name" "$dry" "$id" "$start" overlap
    log "$name: skipped (overlap): a run of it is still going"
    return 0
  fi
  slots="$(routine_dir)/.slots"
  mkdir -p "$slots"
  for ((n = 1; n <= ROUTINE_SLOTS; n++)); do
    exec {sfd}>"$slots/slot.$n"
    flock -n "$sfd" && break
    exec {sfd}>&-
    sfd=""
  done
  if [[ -z "$sfd" ]]; then
    exec {lfd}>&-
    _routine_skip "$name" "$dry" "$id" "$start" load
    log "$name: skipped (load): $ROUTINE_SLOTS routines are running"
    return 0
  fi
  # Let in only now, holding both locks: a pause that returned before this
  # stops the run.
  if [[ "$(routine_state "$name" | jq -r .paused)" == true ]]; then
    exec {sfd}>&- {lfd}>&-
    _routine_skip "$name" "$dry" "$id" "$start" paused
    log "$name: skipped (paused); bercail routine resume $name"
    return 0
  fi

  if jq -e '.run' <<<"$entry" >/dev/null; then
    argv=(bash "$(dirname "${BASH_SOURCE[0]}")/routine/$(jq -r .run <<<"$entry").sh" "$name")
  else
    mapfile -d '' -t argv < <(jq -j '.command[] | . + "\u0000"' <<<"$entry")
    [[ "${argv[0]}" != \~/* ]] || argv[0]="$HOME/${argv[0]#\~/}"
  fi
  out="$dir/.out.$$" err="$dir/.err.$$" findings="$dir/.findings.$$"
  _routine_exec "$limit" "$out" "$err" "${argv[@]}" || rc=$?
  if ((rc == 124)); then
    error="timed out after ${limit}s"
  elif (($(wc -c <"$out") > ROUTINE_OUTPUT_MAX)); then
    error="output over 64 KB"
  elif ((rc != 0)); then
    tail="$(grep -v '^[[:space:]]*$' "$err" | tail -n 1 | cut -c1-300 || true)"
    error="exit $rc${tail:+: $tail}"
  elif ! _routine_findings "$out" "$findings" 2>"$err"; then
    error="bad output: $(cat "$err")"
  elif ! _routine_hashed "$findings"; then
    error="could not hash what it found"
  fi
  [[ -z "$error" ]] || findings=""
  printf -v end '%(%s)T' -1
  ctx="$(jq -nc --arg name "$name" --arg id "$id" --arg due "$(_routine_iso "$start")" --arg ds "$(_routine_stamp "$start")" \
    --arg start "$(_routine_iso "$start")" --arg end "$(_routine_iso "$end")" --argjson next "$(_routine_next_due "$entry" "$start")" \
    '{name: $name, id: $id, due: $due, due_stamp: $ds, start: $start, end: $end, next_due: $next}')"
  if [[ "$dry" == 1 ]]; then
    _routine_finish "$name" 1 "$ctx" "$findings" "$error" || wrote=0
  else
    _routine_with_state "$name" _routine_finish "$name" 0 "$ctx" "$findings" "$error" || wrote=0
  fi
  rm -f "$out" "$err" "$dir/.findings.$$"
  exec {sfd}>&- {lfd}>&-
  if ((!wrote)) || [[ -z "${_routine_result:-}" ]]; then
    printf 'error: routine %s: could not write its run in %s, so it may count the same findings again\n' "$name" "$dir" >&2
    return 1
  fi
  result="$_routine_result"
  if [[ "$dry" == 1 ]] && jq -e '.event' <<<"$result" >/dev/null; then
    jq -c .event <<<"$result"
  else
    line="$(_routine_said "$(jq -c .run <<<"$result")")"
    log "$name: $line; $([[ "$dry" == 1 ]] && printf 'dry run, nothing written' || printf 'run %s' "$id")"
  fi
  [[ "$(jq -r .paused_now <<<"$result")" != true || "$dry" == 1 ]] \
    || log "$name: failed 3 times in a row and is paused; bercail routine resume $name"
  [[ -z "$error" ]]
}

# The last run's line, or nothing.
_routine_last() {
  local file
  file="$(routine_dir)/$1/runs.jsonl"
  [[ -f "$file" ]] && tail -n 1 "$file" || true
}

# bercail routine list: each routine's schedule, next due, last outcome, and
# whether it is paused; a bad entry says what is wrong.
routine_list() {
  local entries entry name width now state next last
  entries="$(routine_entries)"
  [[ -n "$entries" ]] || { log "No routines. Declare one as [routine.<name>] in $BERCAIL_USER_CONFIG (docs/routines.md)."; return 0; }
  width="$(jq -s 'map(.name | length) | max' <<<"$entries")"
  printf -v now '%(%s)T' -1
  while IFS= read -r entry; do
    name="$(jq -r .name <<<"$entry")"
    if jq -e '.errors != []' <<<"$entry" >/dev/null; then
      printf '%-*s  invalid: %s\n' "$width" "$name" "$(jq -r '.errors | join("; ")' <<<"$entry")"
      continue
    fi
    state="$(routine_state "$name")"
    # One that never ran: an every routine is due now, an at one at its next slot.
    next="$(jq -r '.next_due // empty' <<<"$state")"
    if [[ -z "$next" ]]; then
      [[ "$(jq -r .every <<<"$entry")" != null ]] && next="$now" || next="$(_routine_next_due "$entry" "$now")"
    fi
    last="$(_routine_last "$name")"
    [[ -z "$last" ]] && last="never run" || last="$(jq -r 'if .outcome == "skipped" then "skipped (\(.reason))" else .outcome end' <<<"$last")"
    printf '%-*s  %-11s  next %s  %-17s  %s\n' "$width" "$name" "$(_routine_schedule "$entry")" \
      "$(_routine_local "$next")" "$last" "$(jq -r 'if .paused then "paused" else "active" end' <<<"$state")"
  done <<<"$entries"
}

# bercail routine show NAME [--run ID]: its last runs, or what one run found.
routine_show() {
  local name="$1" run="${2:-}" entry state file line output
  entry="$(routine_entry "$name")"
  file="$(routine_dir)/$name/runs.jsonl"
  if [[ -z "$run" ]]; then
    state="$(routine_state "$name")"
    log "$name: $(_routine_schedule "$entry"), $(jq -r '(if .paused then "paused" else "active" end)
      + ", \(.failures) failures in a row" + (if .next_due then "" else ", never run" end)' <<<"$state")"
    [[ -f "$file" ]] || return 0
    while IFS= read -r line; do
      log "  $(jq -r .id <<<"$line")  $(_routine_said "$line")"
    done < <(tail -n 10 "$file" | jq -c -s 'reverse[]')
    return 0
  fi
  [[ "$run" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9]+$ ]] && [[ -f "$file" ]] \
    && line="$(jq -c --arg id "$run" 'select(.id == $id)' "$file" | tail -n 1)" && [[ -n "$line" ]] \
    || die "no run $run in $name's last runs; bercail routine show $name lists them"
  log "run $run: $(_routine_said "$line")"
  output="$(routine_dir)/$name/outputs/$run.jsonl"
  if [[ -f "$output" ]]; then
    jq -r '"  \(.status + "        " | .[:8]) \(.key)  \(.title)",
      ([.detail, ([.repo, .issue] | map(select(. != null)) | if length > 0 then "(\(join(", ")))" else empty end)]
       | map(select(. != null)) | if length > 0 then "           " + join(" ") else empty end)' "$output"
  elif jq -e '.counts != null' <<<"$line" >/dev/null; then
    log "  (what it found is no longer kept: only the last $ROUTINE_KEEP_OUTPUTS runs' are)"
  fi
}

routine_pause() {
  routine_entry "$1" >/dev/null
  _routine_with_state "$1" _routine_set_paused "$1" "$2"
}

cmd_routine() {
  local sub="${1:-}" name="${2:-}"
  local usage="usage: bercail routine list | show <name> [--run <id>] | run <name> [--dry-run] | pause <name> | resume <name>"
  case "$sub" in
    list) [[ $# -eq 1 ]] || die "$usage"; routine_list ;;
    show)
      if [[ $# -eq 2 ]]; then routine_show "$name"
      elif [[ $# -eq 4 && "$3" == --run ]]; then routine_show "$name" "$4"
      else die "$usage"; fi
      ;;
    run)
      if [[ $# -eq 2 ]]; then routine_run "$name"
      elif [[ $# -eq 3 && "$3" == --dry-run ]]; then routine_run "$name" 1
      else die "$usage"; fi
      ;;
    pause) [[ $# -eq 2 ]] || die "$usage"; routine_pause "$name" true; log "$name: paused" ;;
    resume) [[ $# -eq 2 ]] || die "$usage"; routine_pause "$name" false; log "$name: resumed" ;;
    *) die "$usage" ;;
  esac
}

# doctor: each routine, and what is wrong with a bad one. Without flock no
# routine can run, so that fails; a bad entry is named, not a failure.
doctor_routines() {
  local entries entry failures=0
  entries="$(routine_entries)"
  [[ -n "$entries" ]] || return 0
  log ""
  log "Routines ([routine.<name>] in $BERCAIL_USER_CONFIG):"
  if ! command -v flock >/dev/null 2>&1; then
    log "  missing  flock: no routine runs without it; install it (util-linux on Linux, brew install flock on macOS)"
    failures=1
  fi
  while IFS= read -r entry; do
    if jq -e '.errors == []' <<<"$entry" >/dev/null; then
      log "  ok  routine $(jq -r .name <<<"$entry"): $(_routine_schedule "$entry")"
    else
      log "  invalid  routine $(_routine_label "$(jq -r .name <<<"$entry")"): $(jq -r '.errors | join("; ")' <<<"$entry")"
    fi
  done <<<"$entries"
  return "$failures"
}
