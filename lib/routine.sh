#!/usr/bin/env bash
# shellcheck shell=bash
# Routines: a model-free query you declare as [routine.<name>] in config.toml,
# run outside Shep's session. It prints findings, one JSON object a line, and
# only new or changed ones count (docs/routines.md). This is the runner, its
# state and its locks; tests/statechart/routine-run/RoutineRun.tla models them.
#
# routines/<name>/ in the state dir holds state.json (next due, failures in a
# row, paused, the hash sent per key, and the outbox: events for Shep not yet
# in its inbox), runs.jsonl (a line per run), outputs/ (what each emitted run
# found), lock, which flock -n holds while a run lasts, and tried.json: the
# slot a scheduled run last let its query run for, and when.
# routines/.slots/slot.N are the 2 slots: at most 2 routines run at once.
# The scheduler, bercail routine loop, holds routines/.loop.lock while it
# runs, and each tick writes routines/tick.json: when it last ticked.
# Every write to state.json and runs.jsonl is under state.lock, and the end of
# a run reads state.json again there, so a pause made meanwhile holds.

# shellcheck source=lib/toml.sh
source "$(dirname "${BASH_SOURCE[0]}")/toml.sh"

ROUTINE_SLOTS=2
ROUTINE_OUTPUT_MAX=65536
ROUTINE_KEEP_RUNS=100
ROUTINE_KEEP_OUTPUTS=10
# A tick a minute. A slot whose run could not write its state is tried again
# after 15 minutes, not every tick.
ROUTINE_TICK=60
ROUTINE_RETRY=900
ROUTINE_LOOP=bercail-routines
# As the desk mod starts it: hc's login shell may not have bercail on PATH.
# shellcheck disable=SC2016 # expanded by that shell
ROUTINE_LOOP_RUN='command -v bercail >/dev/null || PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"; exec bercail routine loop'

# The wall clock, in epoch seconds. date, so a test can stand in for it.
_routine_now() { date +%s; }

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
# run = "issues" adds {repo, label, source, source_command}, with their defaults.
routine_entries() {
  [[ -f "$BERCAIL_USER_CONFIG" ]] || return 0
  toml_records "$BERCAIL_USER_CONFIG" | jq -sc --arg builtins "$(routine_builtins)" '
    def argv: type == "array" and length > 0 and all(.[]; type == "string");
    def given($k; $d): if has($k) then .[$k] else $d end;
    ($builtins | split("\n")) as $builtins
    | reduce (.[] | select(has("key") and (.section | length) == 2 and .section[0] == "routine")) as $r
        ({}; .[$r.section[1]][$r.key] = ($r.value // $r.raw))
    | to_entries[]
    | .key as $name | .value as $v
    | [ if ($name | test("^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$") | not) then "a name is letters, digits, - and _, at most 64 of them"
        else
          (if $v | has("run") and has("command") then "run and command are both set"
           elif ($v | has("run") or has("command")) | not then "no run or command"
           elif $v | has("run") then
             if ($v.run | type) != "string" or ($v.run | IN($builtins[]) | not)
             then "no built-in \($v.run) (lib/routine/<name>.sh)" else empty end
           elif $v.command | argv | not
           then "command must be a list of strings, like [\"~/bin/check\", \"--json\"]"
           else empty end),
          (if $v.run == "issues" then
             (if $v | has("repo") and ($v.repo | type != "string" or . == "")
              then "repo must be a path, like \"~/Work/bercail\"" else empty end),
             (if $v | has("label") and ($v.label | type != "string" or . == "")
              then "label must be a label, like \"routine\"" else empty end),
             (if $v | given("source"; "beads") | IN("beads", "command") | not
              then "source must be beads or command, not \($v.source)"
              elif $v.source == "command" then
                if $v | has("source_command") | not
                then "source = \"command\" needs source_command, like [\"~/bin/issues\", \"--json\"]"
                elif $v.source_command | argv | not
                then "source_command must be a list of strings, like [\"~/bin/issues\", \"--json\"]"
                else empty end
              elif $v | has("source_command") then "source_command is read only with source = \"command\""
              else empty end)
           else
             ("repo", "label", "source", "source_command") as $k
             | select($v | has($k)) | "\($k) is read only with run = \"issues\""
           end),
          (if $v | has("at") and has("every") then "at and every are both set"
           elif ($v | has("at") or has("every")) | not then "no at or every"
           elif $v | has("at") then
             if ($v.at | type) == "string" and ($v.at | test("^((Mon|Tue|Wed|Thu|Fri|Sat|Sun) )?([01][0-9]|2[0-3]):[0-5][0-9]$")) then empty
             else "at must be HH:MM, or a day and HH:MM such as Mon 08:00, not \($v.at)" end
           elif ($v.every | type) == "string" and ($v.every | test("^[1-9][0-9]*[hd]$")) then empty
           else "every must be <n>h or <n>d, at least 1h, not \($v.every)" end)
        end ] as $errors
    | {name: $name, run: $v.run, command: $v.command, at: $v.at, every: $v.every, errors: $errors}
      + if $v.run == "issues" then
          $v | {repo: given("repo"; "~/Work/bercail"), label: given("label"; "routine"), source: given("source"; "beads"),
                source_command}
        else {} end'
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
# it, an at routine at its next local HH:MM, on its day of the week when it
# names one.
_routine_next_due() {
  local entry="$1" from="$2" at every n day=0 got
  # %u, not %a: a day's name depends on the locale, its number does not.
  local -A days=([Mon]=1 [Tue]=2 [Wed]=3 [Thu]=4 [Fri]=5 [Sat]=6 [Sun]=7)
  at="$(jq -r '.at // ""' <<<"$entry")" every="$(jq -r '.every // ""' <<<"$entry")"
  if [[ -n "$every" ]]; then
    n="${every%?}"
    [[ "$every" == *h ]] && printf '%s' $((from + n * 3600)) || printf '%s' $((from + n * 86400))
    return 0
  fi
  [[ "$at" != *" "* ]] || day="${days[${at%% *}]}" at="${at#* }"
  n="$(_routine_next_at "$at" "$from")"
  while ((day)) && printf -v got '%(%u)T' "$n" && ((got != day)); do
    n="$(_routine_next_at "$at" "$n")"
  done
  printf '%s' "$n"
}

# The epoch second after FROM that next reads HH:MM AT, local time.
_routine_next_at() {
  local at="$1" from="$2" n hms h m s mid d got
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

# state.json, with what a routine that never ran has. One that cannot be read
# is an error: writing over it would lose what was sent and the events waiting.
routine_state() {
  local file
  file="$(routine_dir)/$1/state.json"
  if [[ -e "$file" ]]; then
    jq -ce '{next_due: null, failures: 0, paused: false, sent: {}, outbox: []} + .' "$file" 2>/dev/null \
      || { printf 'error: routine %s: cannot read %s; fix it, or move it aside to start the routine over\n' "$1" "$file" >&2; return 1; }
  else
    printf '{"next_due":null,"failures":0,"paused":false,"sent":{},"outbox":[]}'
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

# Write FILE whole (tmp, then mv) with JSON, an object.
_routine_write() {
  local tmp
  jq -e 'type == "object"' <<<"$2" >/dev/null 2>&1 || return 1
  tmp="$(mktemp "$1.XXXXXX")" || return 1
  printf '%s\n' "$2" >"$tmp" && mv -f "$tmp" "$1" || { rm -f "$tmp"; return 1; }
}

# Under the state lock: write state.json.
_routine_put_state() {
  _routine_write "$(routine_dir)/$1/state.json" "$2"
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
  state="$(routine_state "$1")" || return 1
  _routine_put_state "$1" "$(jq -c --argjson p "$2" '.paused = $p | if $p then . else .failures = 0 end' <<<"$state")"
}

# A run that went no further than its locks: logged, and the outbox flushed.
# DUE is the slot it was for, or its start.
_routine_skip() {
  local name="$1" dry="$2" id="$3" start="$4" reason="$5" due="$6" line
  [[ "$dry" == 1 ]] && return 0
  line="$(jq -nc --arg id "$id" --arg t "$(_routine_iso "$start")" --arg d "$(_routine_iso "$due")" --arg r "$reason" \
    '{id: $id, due: $d, start: $t, end: $t, outcome: "skipped", reason: $r, counts: null, event: null, error: null}')"
  _routine_with_state "$name" _routine_skipped "$name" "$line" \
    || { printf 'error: routine %s: could not write its run in %s\n' "$name" "$(routine_dir)/$name" >&2; return 1; }
}

_routine_skipped() {
  _routine_put_run "$1" "$2" || return 1
  _routine_flush "$1" || _routine_flush_failed=1
}

# Waits up to 2 seconds for process group PID to be gone.
_routine_gone() {
  local _
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 -- "-$1" 2>/dev/null || return 0
    sleep 0.2
  done
  return 1
}

# Stop process group PID: TERM, then KILL what is left after 2 seconds, and
# wait for that to go too: a KILL takes a moment, and a runner that returned
# before it would leave its query running behind it.
_routine_stop() {
  kill -TERM -- "-$1" 2>/dev/null || return 0
  _routine_gone "$1" && return 0
  kill -KILL -- "-$1" 2>/dev/null || return 0
  _routine_gone "$1" || true
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

# Under the state lock: write the events in state.json's outbox into Shep's
# inbox, each whole (tmp, then mv) as <event id>.json, then take them out. An
# id already queued or delivered was written by a flush that stopped before
# taking it out, so it is not written twice. Before Shep's first start there is
# no inbox, and they wait. Why they wait goes in $_routine_waiting; status 1
# when a write failed.
_routine_flush() {
  local name="$1" inbox state event id file tmp n=0 total
  state="$(routine_state "$name")" || { _routine_waiting="was not sent: its state.json cannot be read"; return 1; }
  total="$(jq '.outbox | length' <<<"$state")" || return 1
  ((total > 0)) || return 0
  inbox="$(shep_inbox_dir)"
  if [[ -z "$inbox" ]]; then
    _routine_waiting="no Shep inbox in $(shep_state_dir) yet; start Shep once (bercail shep) and the next run sends it"
    return 0
  fi
  while IFS= read -r event; do
    id="$(jq -r .event_id <<<"$event")" && [[ "$id" =~ ^routine:[A-Za-z0-9_-]+:[0-9TZ-]+$ ]] || break
    file="$inbox/${id//:/_}.json"
    if [[ ! -e "$file" && ! -e "$inbox/../delivered/${file##*/}" ]]; then
      tmp="$(umask 077 && mktemp "$inbox/.event.XXXXXX" 2>/dev/null)" || break
      printf '%s\n' "$event" >"$tmp" && mv -f "$tmp" "$file" || { rm -f "$tmp"; break; }
    fi
    n=$((n + 1))
  done < <(jq -c '.outbox[]' <<<"$state")
  if ((n > 0)) && ! _routine_put_state "$name" "$(jq -c --argjson n "$n" '.outbox |= .[$n:]' <<<"$state")"; then
    _routine_waiting="is in Shep's inbox, but could not be taken out of state.json; the next run finds it there and does not send it again"
    return 1
  fi
  ((n < total)) || return 0
  _routine_waiting="could not be written to Shep's inbox $inbox; it waits in state.json, and the next run sends it"
  return 1
}

# The state lock's half of a run's end: from state.json as it is now, the
# outcome, the state to write, the run's line, what it found and the event, as
# one JSON object in $_routine_result. FINDINGS is their file, or empty for a
# failed run. Unless DRY is 1 it writes what an emitted run found, the run's
# line, then state.json with the event in its outbox: that one rename counts
# the findings sent and keeps their event, so a failed write or a crash loses
# neither. Then it flushes the outbox. Status 1 when the state was not
# written; a flush that failed sets $_routine_flush_failed.
# The same rename writes the highest slot met, as slot: a scheduled run's, or
# the next_due a run by hand found due when it started. next_due comes after
# both that slot and the run's start, so no slot runs twice and a clock that
# went back strands nothing (RoutineRun.tla's OneRunPerSlot, NextAfterLast).
_routine_finish() {
  local name="$1" dry="$2" ctx="$3" findings="$4" error="$5" dir state top start next
  local -a found=(--argjson f '[null]')
  [[ -z "$findings" ]] || found=(--slurpfile f "$findings")
  dir="$(routine_dir)/$name"
  state="$(routine_state "$name")" || return 1
  start="$(jq -r .start_s <<<"$ctx")"
  top="$(jq -r --argjson c "$ctx" '[.slot // 0, $c.slot // 0,
    (if .next_due != null and .next_due <= $c.start_s then .next_due else 0 end)] | max' <<<"$state")" || return 1
  next="$(_routine_next_due "$(jq -c .entry <<<"$ctx")" $((top > start ? top : start)))"
  _routine_result="$(jq -c --argjson c "$ctx" "${found[@]}" --arg err "$error" --argjson top "$top" --argjson next "$next" '
    . as $s | $f[0] as $f
    | {id: $c.id, due: $c.due, start: $c.start, end: $c.end} as $run
    | "routine:\($c.name):\($c.slot_stamp // $c.id)" as $eid
    # Its fields only: no finding text or error, which the query wrote.
    | def event($o; $counts): {source: "bercail", schema: "bercail.routine/v1", kind: "routine", sink: "shep",
        at: $c.end, event_id: $eid, routine: $c.name, run: $c.id, outcome: $o, counts: $counts,
        show: "bercail routine show \($c.name) --run \($c.id)"};
    if $c.load != "" then
        {state: ($s + {next_due: $next}), run: ($run + {outcome: "skipped", reason: "load", detail: $c.load, counts: null, event: null, error: null})}
      elif $f == null then
        ($s.failures + 1) as $n
        | (($s.paused | not) and $n >= 3) as $now
        | {state: ($s + {failures: $n, paused: ($s.paused or $n >= 3), next_due: $next}),
           run: ($run + {outcome: "failed", reason: null, counts: null, event: (if $now then $eid else null end), error: $err}),
           paused_now: $now, findings: null, event: (if $now then event("paused"; null) else null end)}
      else
        ($f | map(. + {status: ($s.sent[.key] as $h
          | if $h == null then "new" elif $h == .hash then "same" else "changed" end)})) as $a
        | {found: ($a | length), new: ([$a[] | select(.status == "new")] | length),
           changed: ([$a[] | select(.status == "changed")] | length)} as $counts
        | (if $counts.new + $counts.changed > 0 then "emitted" else "skipped" end) as $o
        | {state: ($s + {failures: 0, next_due: $next, sent: ($a | map({(.key): .hash}) | add // {}), kept: $c.id}),
           run: ($run + {outcome: $o, reason: (if $o == "skipped" then "quiet" else null end), counts: $counts,
                         event: (if $o == "emitted" then $eid else null end), error: null}),
           paused_now: false,
           findings: ($a | map(del(.hash))),
           event: (if $o == "emitted" then event($o; $counts) else null end)}
      end
    | if .event then .state.outbox += [.event] else . end
    | if $top > 0 then .state.slot = $top else . end' <<<"$state")" || return 1
  [[ -n "$_routine_result" ]] || return 1
  [[ "$dry" == 1 ]] && return 0
  if jq -e '.run.outcome == "emitted"' <<<"$_routine_result" >/dev/null; then
    mkdir -p "$dir/outputs" && jq -c '.findings[]' <<<"$_routine_result" >"$dir/outputs/$(jq -r .run.id <<<"$_routine_result").jsonl" \
      || return 1
  fi
  _routine_put_run "$name" "$(jq -c .run <<<"$_routine_result")" || return 1
  _routine_put_state "$name" "$(jq -c .state <<<"$_routine_result")" || return 1
  _routine_flush "$name" || _routine_flush_failed=1
}

# After a run: why an event waits for Shep's inbox, if one does. Status 1 when
# writing it failed.
_routine_tell_waiting() {
  [[ -n "$_routine_waiting" ]] || return 0
  if [[ -n "$_routine_flush_failed" ]]; then
    printf 'error: routine %s: its event %s\n' "$1" "$_routine_waiting" >&2
    return 1
  fi
  log "$1: its event waits: $_routine_waiting"
}

# A run's line in words: "emitted, 2 found (1 new, 0 changed)".
_routine_said() {
  jq -r 'if .outcome == "emitted" then "emitted, \(.counts.found) found (\(.counts.new) new, \(.counts.changed) changed)"
    elif .outcome == "failed" then "failed: \(.error)"
    elif .reason == "quiet" then "skipped (quiet), \(.counts.found) found, nothing new or changed"
    else "skipped (\(.reason))" + (if .detail then ": " + .detail else "" end) end' <<<"$1"
}

# bercail routine run NAME [--dry-run]: run it now, under the same locks and
# limits as a scheduled run. SLOT is the due time (epoch seconds) a scheduled
# run is for: it names the event, and it runs only while it is still
# next_due; otherwise it is skipped (done), so a retried or stale tick sends
# nothing twice. It is skipped (early) when its slot is after its start, and
# (tried) when a run of that slot ran its query under 15 minutes ago and
# could not write its state. Status 1 when it failed, or when it could not
# read or write its state or its event.
routine_run() {
  local name="$1" dry="${2:-0}" slot="${3:-}" entry dir start id micro="${EPOCHREALTIME:-}" state
  local lfd="" sfd="" n slots out err rc=0 error="" findings load=""
  local limit="${BERCAIL_ROUTINE_TIMEOUT:-600}" end ctx tail result line wrote=1 _routine_result
  local _routine_waiting="" _routine_flush_failed=""
  local -a argv
  entry="$(routine_entry "$name" --valid)"
  command -v flock >/dev/null 2>&1 \
    || die "no flock here, and a routine never runs unlocked; install it (util-linux on Linux, brew install flock on macOS)"
  [[ "$limit" =~ ^[1-9][0-9]*$ ]] || die "BERCAIL_ROUTINE_TIMEOUT must be whole seconds above 0, not $limit"
  dir="$(routine_dir)/$name"
  mkdir -p "$dir"
  start="$(_routine_now)"
  # The pid, and with bash 5 the microseconds: two runs from one shell differ.
  id="$(_routine_stamp "$start")-$$${micro: -6}"

  exec {lfd}>"$dir/lock"
  if ! flock -n "$lfd"; then
    exec {lfd}>&-
    _routine_skip "$name" "$dry" "$id" "$start" overlap "${slot:-$start}" || return 1
    log "$name: skipped (overlap): a run of it is still going"
    _routine_tell_waiting "$name" || return 1
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
    _routine_skip "$name" "$dry" "$id" "$start" load "${slot:-$start}" || return 1
    log "$name: skipped (load): $ROUTINE_SLOTS routines are running"
    _routine_tell_waiting "$name" || return 1
    return 0
  fi
  # Let in only now, holding both locks: a pause that returned before this
  # stops the run. Its start is the clock now: the checks below, its try and
  # its next due time all go by it.
  start="$(_routine_now)"
  state="$(routine_state "$name")" || { exec {sfd}>&- {lfd}>&-; return 1; }
  if [[ "$(jq -r .paused <<<"$state")" == true ]]; then
    exec {sfd}>&- {lfd}>&-
    _routine_skip "$name" "$dry" "$id" "$start" paused "${slot:-$start}" || return 1
    log "$name: skipped (paused); bercail routine resume $name"
    _routine_tell_waiting "$name" || return 1
    return 0
  fi
  # A scheduled run is for next_due as it is now: a run that met that slot
  # meanwhile, by hand too, moved it on.
  if [[ -n "$slot" ]] && ! jq -e --argjson s "$slot" '.next_due == null or .next_due == $s' <<<"$state" >/dev/null; then
    exec {sfd}>&- {lfd}>&-
    _routine_skip "$name" "$dry" "$id" "$start" "done" "${slot:-$start}" || return 1
    log "$name: skipped (done): its $(_routine_local "$slot") run is done"
    _routine_tell_waiting "$name" || return 1
    return 0
  fi
  # The clock went back since the tick chose it: the slot stays due, for a
  # query that runs in its window.
  if [[ -n "$slot" ]] && ((slot > start)); then
    exec {sfd}>&- {lfd}>&-
    _routine_skip "$name" "$dry" "$id" "$start" early "$slot" || return 1
    log "$name: skipped (early): its $(_routine_local "$slot") run is not due by this clock, $(_routine_local "$start")"
    _routine_tell_waiting "$name" || return 1
    return 0
  fi
  # A run of this slot whose query ran under 15 minutes ago could not write
  # its state: wait, without moving its stamp. Else stamp it: unless that is
  # written, the query does not run.
  if [[ -n "$slot" && "$dry" != 1 ]]; then
    if _routine_tried "$dir/tried.json" "$slot" "$start"; then
      exec {sfd}>&- {lfd}>&-
      _routine_skip "$name" "$dry" "$id" "$start" tried "$slot" || return 1
      log "$name: skipped (tried): its $(_routine_local "$slot") run ran its query under 15 minutes ago"
      _routine_tell_waiting "$name" || return 1
      return 0
    fi
    if ! _routine_write "$dir/tried.json" "$(jq -nc --argjson s "$slot" --argjson t "$start" '{due: $s, at: $t}')"; then
      exec {sfd}>&- {lfd}>&-
      printf 'error: routine %s: cannot write %s, so its query does not run\n' "$name" "$dir/tried.json" >&2
      return 1
    fi
  fi

  if jq -e '.run' <<<"$entry" >/dev/null; then
    argv=(bash "$(dirname "${BASH_SOURCE[0]}")/routine/$(jq -r .run <<<"$entry").sh" "$name")
  else
    mapfile -d '' -t argv < <(jq -j '.command[] | . + "\u0000"' <<<"$entry")
    [[ "${argv[0]}" != \~/* ]] || argv[0]="$HOME/${argv[0]#\~/}"
  fi
  out="$dir/.out.$$" err="$dir/.err.$$" findings="$dir/.findings.$$"
  # A dry run tells its query, so a built-in that keeps state of its own writes none.
  # The run's id lets a built-in tell, from kept in state.json, that its last run was kept.
  BERCAIL_ROUTINE_DRY_RUN="$dry" BERCAIL_ROUTINE_RUN="$id" _routine_exec "$limit" "$out" "$err" "${argv[@]}" || rc=$?
  if ((rc == 124)); then
    error="timed out after ${limit}s"
  elif (($(wc -c <"$out") > ROUTINE_OUTPUT_MAX)); then
    error="output over 64 KB"
  elif ((rc == 75)) && [[ ! -s "$out" && -s "$err" && $(jq -r .run <<<"$entry") == issues ]]; then
    # No selection was made: keep the previous offer's hash, but meet this slot.
    load="$(tail -n 1 "$err" | cut -c1-300)" findings=""
  elif ((rc != 0)); then
    tail="$(grep -v '^[[:space:]]*$' "$err" | tail -n 1 | cut -c1-300 || true)"
    error="exit $rc${tail:+: $tail}"
  elif ! _routine_findings "$out" "$findings" 2>"$err"; then
    error="bad output: $(cat "$err")"
  elif ! _routine_hashed "$findings"; then
    error="could not hash what it found"
  fi
  [[ -z "$error" ]] || findings=""
  end="$(_routine_now)"
  ctx="$(jq -nc --arg name "$name" --arg id "$id" --arg start "$(_routine_iso "$start")" --arg end "$(_routine_iso "$end")" \
    --arg due "$(_routine_iso "${slot:-$start}")" --arg slot "$slot" --arg ss "${slot:+$(_routine_stamp "$slot")}" \
    --argjson start_s "$start" --argjson entry "$entry" --arg load "$load" \
    '{name: $name, id: $id, due: $due, start: $start, end: $end, start_s: $start_s, entry: $entry, load: $load,
      slot: (if $slot == "" then null else ($slot | tonumber) end), slot_stamp: (if $ss == "" then null else $ss end)}')"
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
  line="$(_routine_said "$(jq -c .run <<<"$result")")"
  log "$name: $line; $([[ "$dry" == 1 ]] && printf 'dry run, nothing written' || printf 'run %s' "$id")"
  # A dry run keeps no findings for show --run, so it prints them.
  [[ "$dry" != 1 ]] || jq -c '.findings[]?' <<<"$result" | _routine_print_findings
  [[ "$(jq -r .paused_now <<<"$result")" != true || "$dry" == 1 ]] \
    || log "$name: failed 3 times in a row and is paused; bercail routine resume $name"
  _routine_tell_waiting "$name" || return 1
  [[ -z "$error" ]]
}

# The last run's line, or nothing.
_routine_last() {
  local file
  file="$(routine_dir)/$1/runs.jsonl"
  [[ -f "$file" ]] && tail -n 1 "$file" || true
}

# When ENTRY with STATE is next due, as of NOW. One that never ran: an every
# routine is due now, an at one at its next slot.
_routine_shown_next() {
  local next
  next="$(jq -r '.next_due // empty' <<<"$2")"
  if [[ -z "$next" ]]; then
    [[ "$(jq -r .every <<<"$1")" != null ]] && next="$3" || next="$(_routine_next_due "$1" "$3")"
  fi
  printf '%s' "$next"
}

# bercail routine list: each routine's schedule, next due, last outcome, and
# whether it is paused; a bad entry says what is wrong.
routine_list() {
  local entries entry name width now state next last
  entries="$(routine_entries)"
  [[ -n "$entries" ]] || { log "No routines. Declare one as [routine.<name>] in $BERCAIL_USER_CONFIG (docs/routines.md)."; return 0; }
  width="$(jq -s 'map(.name | length) | max' <<<"$entries")"
  now="$(_routine_now)"
  while IFS= read -r entry; do
    name="$(jq -r .name <<<"$entry")"
    if jq -e '.errors != []' <<<"$entry" >/dev/null; then
      printf '%-*s  invalid: %s\n' "$width" "$name" "$(jq -r '.errors | join("; ")' <<<"$entry")"
      continue
    fi
    state="$(routine_state "$name")"
    next="$(_routine_shown_next "$entry" "$state" "$now")"
    last="$(_routine_last "$name")"
    [[ -z "$last" ]] && last="never run" || last="$(jq -r 'if .outcome == "skipped" then "skipped (\(.reason))" else .outcome end' <<<"$last")"
    printf '%-*s  %-12s  next %s  %-17s  %s\n' "$width" "$name" "$(_routine_schedule "$entry")" \
      "$(_routine_local "$next")" "$last" "$(jq -r 'if .paused then "paused" else "active" end' <<<"$state")"
  done <<<"$entries"
}

# bercail routine list --json: the same as data, for the Routines panel
# (bercail-shep): each routine's entry and state, its last run, whether a run
# holds its lock, and what its last emitted run found; and the loop. A bad
# entry has its errors and no state; a state.json it cannot read, state_error.
# The last 10 emitted runs' findings outlive their lines in runs.jsonl: one
# whose line is gone has no end, and its counts come from its findings.
routine_list_json() {
  local dir now entry name state next last emitted found running tick
  local -a outputs
  dir="$(routine_dir)"
  now="$(_routine_now)"
  running=false
  command -v flock >/dev/null 2>&1 && ! _routine_unheld "$dir/.loop.lock" && running=true
  tick="$(jq -r '.at // empty' "$dir/tick.json" 2>/dev/null || true)"
  [[ -z "$tick" ]] || tick="$(_routine_iso "$tick")"
  while IFS= read -r entry; do
    name="$(jq -r .name <<<"$entry")"
    entry="$(jq -c '. + {schedule: null, state_error: null, paused: null, failures: null, running: null,
      next_due: null, last: null, found: null}' <<<"$entry")"
    if jq -e '.errors != []' <<<"$entry" >/dev/null; then
      printf '%s\n' "$entry"
      continue
    fi
    entry="$(jq -c --arg s "$(_routine_schedule "$entry")" '.schedule = $s' <<<"$entry")"
    if ! state="$(routine_state "$name" 2>/dev/null)"; then
      jq -c --arg e "cannot read $dir/$name/state.json; fix it, or move it aside to start the routine over" \
        '.state_error = $e' <<<"$entry"
      continue
    fi
    next="$(_routine_shown_next "$entry" "$state" "$now")"
    last="$(_routine_last "$name")"
    found="" emitted=""
    outputs=("$dir/$name"/outputs/*.jsonl)
    [[ ! -f "${outputs[-1]}" ]] || found="${outputs[-1]}"
    if [[ -n "$found" && -f "$dir/$name/runs.jsonl" ]]; then
      emitted="$(jq -c --arg id "$(basename "$found" .jsonl)" 'select(.id == $id)' "$dir/$name/runs.jsonl" | tail -n 1)"
    fi
    jq -c --argjson s "$state" --arg next "$(_routine_iso "$next")" --argjson last "${last:-null}" \
      --arg run "$(basename "$found" .jsonl)" --argjson e "${emitted:-null}" --slurpfile f "${found:-/dev/null}" \
      --argjson running "$(command -v flock >/dev/null 2>&1 && ! _routine_unheld "$dir/$name/lock" && echo true || echo false)" '
      def count($s): [$f[] | select(.status == $s)] | length;
      . + {paused: $s.paused, failures: $s.failures, running: $running, next_due: $next, last: $last,
           found: (if ($f | length) == 0 then null
                   else {run: $run, end: $e.end, findings: $f,
                         counts: ($e.counts // {found: ($f | length), new: count("new"), changed: count("changed")})} end)}' <<<"$entry"
  done < <(routine_entries) | jq -s --arg at "$(_routine_iso "$now")" --argjson running "$running" --arg tick "$tick" \
    '{at: $at, loop: {running: $running, last_tick: (if $tick == "" then null else $tick end)}, routines: .}'
}

# bercail routine ask NAME: the person's request about NAME, read on stdin, as
# one bercail.routine_ask/v1 event in Shep's inbox. The Routines panel sends
# it; the guard keeps agents from it. Their words are data to Shep, and
# SHEP.md's Routine requests says what it may do with them.
routine_ask() {
  local name="$1" text inbox now id tmp file
  routine_entry "$name" >/dev/null
  [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ ]] \
    || die "routine $(_routine_label "$name"): a name is letters, digits, - and _, at most 64 of them, so Shep's inbox cannot take it; rename [routine.$name] in $BERCAIL_USER_CONFIG"
  text="$(cat)"
  text="${text#"${text%%[![:space:]]*}"}"
  text="${text%"${text##*[![:space:]]}"}"
  [[ -n "$text" ]] || die "say what should change on $name: its schedule, what it runs, pause or resume"
  ((${#text} <= 500)) || die "a request is at most 500 characters; this one has ${#text}"
  inbox="$(shep_inbox_dir)"
  [[ -n "$inbox" ]] || die "no Shep inbox in $(shep_state_dir) yet; start Shep once (bercail shep), then ask again"
  now="$(_routine_now)"
  id="routine-ask:$name:$(_routine_stamp "$now")-$$"
  file="$inbox/${id//:/_}.json"
  tmp="$(umask 077 && mktemp "$inbox/.event.XXXXXX")" || die "cannot write to Shep's inbox $inbox"
  if ! jq -nc --arg at "$(_routine_iso "$now")" --arg id "$id" --arg n "$name" --arg t "$text" \
    '{source: "bercail", schema: "bercail.routine_ask/v1", kind: "routine_ask", sink: "shep", at: $at,
      event_id: $id, routine: $n, text: $t}' >"$tmp" || ! mv -f "$tmp" "$file"; then
    rm -f "$tmp"
    die "cannot write to Shep's inbox $inbox"
  fi
  log "$name: your request is in Shep's inbox"
}

# The findings on stdin, one JSON object a line with its status, in words:
# status, key and title, then its detail, repo and issue.
_routine_print_findings() {
  jq -r '"  \(.status + "        " | .[:8]) \(.key)  \(.title)",
    ([.detail, ([.repo, .issue] | map(select(. != null)) | if length > 0 then "(\(join(", ")))" else empty end)]
     | map(select(. != null)) | if length > 0 then "           " + join(" ") else empty end)'
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
  [[ "$run" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9]+$ ]] || die "no run $run; bercail routine show $name lists the last runs"
  output="$(routine_dir)/$name/outputs/$run.jsonl"
  line=""
  [[ ! -f "$file" ]] || line="$(jq -c --arg id "$run" 'select(.id == $id)' "$file" | tail -n 1)"
  [[ -n "$line" || -f "$output" ]] || die "no run $run in $name's last runs; bercail routine show $name lists them"
  if [[ -n "$line" ]]; then
    log "run $run: $(_routine_said "$line")"
  else
    log "run $run: emitted (its line is no longer kept)"
  fi
  if [[ -f "$output" ]]; then
    _routine_print_findings <"$output"
  elif jq -e '.outcome == "emitted"' <<<"${line:-null}" >/dev/null; then
    log "  (what it found is no longer kept: only the last $ROUTINE_KEEP_OUTPUTS emitted runs' findings are)"
  fi
}

routine_pause() {
  routine_entry "$1" >/dev/null
  _routine_with_state "$1" _routine_set_paused "$1" "$2"
}

# --- the scheduler -------------------------------------------------------------

# Seconds since this machine booted, or nothing when it cannot tell.
_routine_uptime() {
  local up rest boot
  if [[ -r /proc/uptime ]]; then
    read -r up rest </proc/uptime && printf '%s' "${up%.*}"
  elif boot="$(sysctl -n kern.boottime 2>/dev/null)" && [[ "$boot" =~ sec\ =\ ([0-9]+) ]]; then
    printf '%s' $(($(_routine_now) - BASH_REMATCH[1]))
  fi
  return 0
}

# Whether tried.json FILE says SLOT's query ran under 15 minutes before NOW.
# One stamped after NOW is from before the clock went back: it is over.
_routine_tried() {
  jq -e --argjson due "$2" --argjson now "$3" --argjson retry "$ROUTINE_RETRY" \
    '.due == $due and .at <= $now and $now - .at < $retry' "$1" >/dev/null 2>&1
}

# Whether nothing holds lock FILE: a routine's run, a slot, or the loop.
_routine_unheld() { [[ ! -e "$1" ]] || flock -n "$1" true; }

_routine_free_slots() {
  local n free=0
  for ((n = 1; n <= ROUTINE_SLOTS; n++)); do
    ! _routine_unheld "$(routine_dir)/.slots/slot.$n" || free=$((free + 1))
  done
  printf '%s' "$free"
}

# Under the state lock: a routine that never ran is first due at DUE.
_routine_first_due() {
  local state
  state="$(routine_state "$1")" || return 1
  jq -e '.next_due == null' <<<"$state" >/dev/null || return 0
  _routine_put_state "$1" "$(jq -c --argjson d "$2" '.next_due = $d' <<<"$state")"
}

# Run NAME for SLOT in the background, in a process group of its own: a loop
# stopped or restarted (bercail update) leaves it to finish. It holds none of
# the scheduler's locks. What it prints goes to loop.log; its line to runs.jsonl.
_routine_launch() {
  local name="$1" slot="$2" log
  log="$(routine_dir)/loop.log"
  set -m
  (
    [[ -z "${_routine_tick_fd:-}" ]] || exec {_routine_tick_fd}>&-
    printf '%s %s: its %s run\n' "$(_routine_local "$(_routine_now)")" "$name" "$(_routine_local "$slot")"
    routine_run "$name" 0 "$slot"
  ) </dev/null >>"$log" 2>&1 &
  set +m
}

# bercail routine tick: start each routine that is due. It reads the wall
# clock against next_due, never a sleep's length, which stops counting while
# the machine sleeps. An overdue routine runs once, for its first missed slot.
# One paused, still running, or tried for the same slot under 15 minutes ago
# waits, and so does one with no free slot, with no run line. Within 5
# minutes of a boot it starts nothing. A paused routine's waiting event goes
# to Shep here too: no run of it comes to send it. The tick decides outside
# the routine's locks; the run it starts checks again under them.
routine_tick() {
  local dir _routine_tick_fd wait="${BERCAIL_ROUTINE_BOOT_WAIT:-300}" rc=0
  command -v flock >/dev/null 2>&1 \
    || die "no flock here, and a routine never runs unlocked; install it (util-linux on Linux, brew install flock on macOS)"
  [[ "$wait" =~ ^[0-9]+$ ]] || die "BERCAIL_ROUTINE_BOOT_WAIT must be whole seconds, not $wait"
  dir="$(routine_dir)"
  mkdir -p "$dir"
  exec {_routine_tick_fd}>>"$dir/.tick.lock"
  if ! flock -n "$_routine_tick_fd"; then
    exec {_routine_tick_fd}>&-
    log "a tick is running already"
    return 0
  fi
  _routine_tick_locked "$dir" "$wait" || rc=$?
  exec {_routine_tick_fd}>&-
  return "$rc"
}

_routine_tick_locked() {
  local dir="$1" wait="$2" now up entry name state due free _routine_waiting
  now="$(_routine_now)"
  if ! _routine_write "$dir/tick.json" "{\"at\":$now}"; then
    printf 'error: cannot write %s, so no routine starts; check that folder\n' "$dir/tick.json" >&2
    return 1
  fi
  if [[ -f "$dir/loop.log" ]] && (($(wc -l <"$dir/loop.log") > 2000)); then
    tail -n 1000 "$dir/loop.log" >"$dir/loop.log.tmp" && mv -f "$dir/loop.log.tmp" "$dir/loop.log"
  fi
  up="$(_routine_uptime)"
  if [[ -n "$up" ]] && ((up < wait)); then
    log "booted $((up / 60)) min ago: no routine starts until $((wait / 60)) min after a boot"
    return 0
  fi
  free="$(_routine_free_slots)"
  while IFS= read -r entry; do
    name="$(jq -r .name <<<"$entry")"
    state="$(routine_state "$name")" || continue
    if jq -e '.outbox != []' <<<"$state" >/dev/null; then
      _routine_waiting=""
      _routine_with_state "$name" _routine_flush "$name" \
        || printf 'error: routine %s: its event %s\n' "$name" "${_routine_waiting:-could not be sent}" >&2
    fi
    ! jq -e .paused <<<"$state" >/dev/null || continue
    due="$(jq -r '.next_due // empty' <<<"$state")"
    # One that never ran: an every routine is due now, an at one at its next
    # slot. Written first, so a retry or a second tick is for the same slot.
    if [[ -z "$due" ]]; then
      jq -e .at <<<"$entry" >/dev/null && due="$(_routine_next_due "$entry" "$now")" || due="$now"
      if ! _routine_with_state "$name" _routine_first_due "$name" "$due"; then
        printf 'error: routine %s: cannot write when it is first due in %s\n' "$name" "$dir/$name" >&2
        continue
      fi
      state="$(routine_state "$name")" || continue
      due="$(jq -r .next_due <<<"$state")"
    fi
    ((due <= now)) || continue
    _routine_unheld "$dir/$name/lock" || continue
    # A run whose query ran for this slot, but that could not write its state,
    # left next_due as it was. The run checks again under its lock; this keeps
    # a tick quiet meanwhile.
    ! _routine_tried "$dir/$name/tried.json" "$due" "$now" || continue
    ((free > 0)) || continue
    _routine_launch "$name" "$due"
    free=$((free - 1))
    log "$name: started its $(_routine_local "$due") run"
  done < <(routine_entries | jq -c 'select(.errors == [])')
}

# bercail routine loop: a tick a minute, for as long as it runs. One per
# machine: a second one refuses while the first holds .loop.lock.
routine_loop() {
  local dir _routine_loop_fd
  command -v flock >/dev/null 2>&1 \
    || die "no flock here, and a routine never runs unlocked; install it (util-linux on Linux, brew install flock on macOS)"
  dir="$(routine_dir)"
  mkdir -p "$dir"
  exec {_routine_loop_fd}>>"$dir/.loop.lock"
  flock -n "$_routine_loop_fd" \
    || die "a routine loop is already running on this machine; bercail shep status says when it last ticked"
  log "routine loop: a tick every ${ROUTINE_TICK}s; what the runs print goes to $dir/loop.log"
  # Only the loop holds its lock: not a tick, a run or a sleep left behind.
  # The tick is a job of its own: a subshell in a || list would run it, and
  # the runs it starts, with set -e off.
  while :; do
    (routine_tick) {_routine_loop_fd}>&- &
    wait "$!" || true
    sleep "$ROUTINE_TICK" {_routine_loop_fd}>&-
  done
}

# The loop in one line: running or not, and when it last ticked. Status 1
# when it is not running.
routine_loop_status() {
  local dir at last
  dir="$(routine_dir)"
  at="$(jq -r '.at // empty' "$dir/tick.json" 2>/dev/null || true)"
  [[ -n "$at" ]] && last="last tick $(_routine_local "$at")" || last="never ticked"
  if command -v flock >/dev/null 2>&1 && ! _routine_unheld "$dir/.loop.lock"; then
    log "routine loop: running, $last"
    return 0
  fi
  log "routine loop: not running ($last); the desk mod starts it while Herdr is open, or run bercail routine start"
  return 1
}

# For Shep's board: one line when a routine failed or is paused, else nothing.
routine_board_line() {
  local entry name state n
  local -a parts=()
  while IFS= read -r entry; do
    name="$(jq -r .name <<<"$entry")"
    if ! state="$(routine_state "$name" 2>/dev/null)"; then
      parts+=("$name's state cannot be read (bercail routine show $name)")
      continue
    fi
    n="$(jq -r .failures <<<"$state")"
    if jq -e .paused <<<"$state" >/dev/null; then
      if ((n > 0)); then
        parts+=("$name is paused after $n failures in a row (bercail routine resume $name once it is fixed)")
      else
        parts+=("$name is paused (bercail routine resume $name)")
      fi
    elif ((n > 0)); then
      parts+=("$name failed $n time$( ((n == 1)) || printf s) in a row (bercail routine show $name)")
    fi
  done < <(routine_entries | jq -c 'select(.errors == [])')
  ((${#parts[@]})) || return 0
  printf 'Routines: %s' "${parts[0]}"
  for ((n = 1; n < ${#parts[@]}; n++)); do printf '; %s' "${parts[n]}"; done
  printf '\n'
}

_routine_backend() { toml_value "$BERCAIL_USER_CONFIG" herdr backend "" 2>/dev/null || true; }

# The address of the loop's live terminal on MACHINE ("" for this one), or
# status 1.
_routine_loop_address() {
  "${HC_BIN:-hc}" ls --json 2>/dev/null </dev/null | jq -er --arg n "$ROUTINE_LOOP" --arg m "$1" '
    [.terminals[]? | select(.name == $n and .state == "live"
      and (if $m == "" then (.address | contains("/") | not) else (.address | startswith($m + "/")) end))
    ][0].address // empty' 2>/dev/null
}

# bercail routine start: the loop as the hidden hc terminal bercail-routines,
# on [herdr] backend when set, unless one is live there. The desk mod does
# the same every minute; the boot path and an update call this.
routine_start_loop() {
  local backend
  local -a on=()
  backend="$(_routine_backend)"
  [[ -z "$backend" ]] || on=(--on "$backend")
  ! _routine_loop_address "$backend" >/dev/null || return 0
  "${HC_BIN:-hc}" run --bg --no-parent --no-notify --rm "${on[@]}" --name "$ROUTINE_LOOP" \
    --label bercail.role=routines bash -lc "$ROUTINE_LOOP_RUN" </dev/null >/dev/null
}

# A live loop keeps running the bercail it started with. After an update, end
# it and start the new one; the runs it started keep going. None live: none
# starts, as with the notify follower.
routine_restart_loop() {
  local backend address i
  backend="$(_routine_backend)"
  address="$(_routine_loop_address "$backend")" || return 0
  "${HC_BIN:-hc}" kill "$address" >/dev/null 2>&1 </dev/null || true
  for ((i = 0; i < 25; i++)); do
    _routine_loop_address "$backend" >/dev/null || break
    sleep 0.2
  done
  if _routine_loop_address "$backend" >/dev/null || ! routine_start_loop; then
    printf 'could not restart the routine loop; run: hc kill %s, then bercail routine start\n' "$address" >&2
  else
    printf 'restarted the routine loop (hc terminal %s)\n' "$ROUTINE_LOOP"
  fi
  return 0
}

# The schedule docs/routines.md gives each built-in, which enable sets when it is given none.
declare -A ROUTINE_BUILTIN_AT=([cleanup]="07:30" [deps]="08:00" [mistakes]="Mon 08:00" [rules]="12:30")
declare -A ROUTINE_BUILTIN_EVERY=([issues]="4h")

# bercail routine enable NAME [--at WHEN]: declare it in config.toml, in one
# write. A built-in runs itself unless it runs something already. --at replaces
# its schedule, every too; with none, it keeps its own or takes the built-in's.
routine_enable() {
  local name="$1" at="$2" entry errors section
  section="routine.$(_routine_label "$name")"
  config_copy
  entry="$(BERCAIL_USER_CONFIG="$CONFIG_WAS" routine_entries | jq -c --arg n "$name" 'select(.name == $n)')"
  if ! jq -e '.run or .command' <<<"${entry:-null}" >/dev/null; then
    # Not grep -q: it stops reading, and the list's printf dies of SIGPIPE under pipefail.
    routine_builtins | grep -xF -- "$name" >/dev/null ||
      die "no built-in $name (lib/routine/<name>.sh); declare [routine.$name] with its command by hand (docs/routines.md)"
    _config_edit "$CONFIG_COPY" set "$section" run "$name"
  fi
  if [[ -n "$at" ]]; then
    _config_edit "$CONFIG_COPY" unset "$section" every
    _config_edit "$CONFIG_COPY" set "$section" at "$at"
  elif ! jq -e '.at or .every' <<<"${entry:-null}" >/dev/null; then
    if [[ -n "${ROUTINE_BUILTIN_EVERY[$name]:-}" ]]; then
      _config_edit "$CONFIG_COPY" set "$section" every "${ROUTINE_BUILTIN_EVERY[$name]}"
    else
      _config_edit "$CONFIG_COPY" set "$section" at "${ROUTINE_BUILTIN_AT[$name]:-}"
    fi
  fi
  errors="$(BERCAIL_USER_CONFIG="$CONFIG_COPY" routine_entries | jq -r --arg n "$name" 'select(.name == $n) | .errors | join("; ")')"
  [[ -z "$errors" ]] || die "routine $(_routine_label "$name"): $errors"
  config_keep
}

# bercail routine disable NAME: take its entry out of config.toml; its state
# stays, so enable brings it back where it was. Your own command lives only in
# the entry, so that one stays: pause it, or remove it by hand. So does an
# issues routine's own source command.
routine_disable() {
  local name="$1" key
  config_copy
  ! BERCAIL_USER_CONFIG="$CONFIG_WAS" routine_entries | jq -e --arg n "$name" 'select(.name == $n) | .command or .source_command' >/dev/null ||
    die "routine $(_routine_label "$name") runs your own command, which only its entry holds; bercail routine pause $name stops it, or remove [routine.$name] by hand"
  for key in run at every repo label source; do
    _config_edit "$CONFIG_COPY" unset "routine.$(_routine_label "$name")" "$key"
  done
  config_keep
}

cmd_routine() {
  local sub="${1:-}" name="${2:-}"
  local usage="usage: bercail routine list [--json] | show <name> [--run <id>] | run <name> [--dry-run] | pause <name> | resume <name> | enable <name> [--at <when>] [--dry-run] | disable <name> [--dry-run] | ask <name> (the request on stdin) | tick | loop | start"
  if [[ "$sub" == enable || "$sub" == disable ]]; then
    config_flags "$usage" "$@"
    set -- "${CONFIG_ARGS[@]}"
    name="${2:-}"
  fi
  case "$sub" in
    enable)
      [[ $# -eq 2 || ($# -eq 4 && "$3" == --at && -n "$4") ]] || die "$usage"
      routine_enable "$name" "${4:-}"
      ;;
    disable) [[ $# -eq 2 ]] || die "$usage"; routine_disable "$name" ;;
    list)
      if [[ $# -eq 1 ]]; then routine_list
      elif [[ $# -eq 2 && "$2" == --json ]]; then routine_list_json
      else die "$usage"; fi
      ;;
    ask) [[ $# -eq 2 ]] || die "$usage"; routine_ask "$name" ;;
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
    tick) [[ $# -eq 1 ]] || die "$usage"; routine_tick ;;
    loop) [[ $# -eq 1 ]] || die "$usage"; routine_loop ;;
    start) [[ $# -eq 1 ]] || die "$usage"; routine_start_loop; log "the routine loop runs as hc terminal $ROUTINE_LOOP" ;;
    *) die "$usage" ;;
  esac
}

# doctor: each routine, and what is wrong with a bad one. Without flock no
# routine can run, so that fails; a bad entry is named, not a failure.
doctor_routines() {
  local entries entry line failures=0
  entries="$(routine_entries)"
  [[ -n "$entries" ]] || return 0
  log ""
  log "Routines ([routine.<name>] in $BERCAIL_USER_CONFIG):"
  if ! command -v flock >/dev/null 2>&1; then
    log "  missing  flock: no routine runs without it; install it (util-linux on Linux, brew install flock on macOS)"
    failures=1
  fi
  if line="$(routine_loop_status)"; then
    log "  ok  $line"
  else
    log "  missing  $line"
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
