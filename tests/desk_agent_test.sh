#!/usr/bin/env bash
# shellcheck shell=bash
# bin/bercail-desk-agent: what the desk runs, from config.toml and its arguments.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# Fake agents print their name, argv and the opencode CLI config they got.
mkdir -p "$TMP_DIR/bin" "$TMP_DIR/xdg/bercail"
for agent in opencode codex claude cursor-agent; do
  cat >"$TMP_DIR/bin/$agent" <<'AGENT'
#!/usr/bin/env bash
printf '%s' "$(basename "$0")"
for a in "$@"; do printf ' [%s]' "$a"; done
printf ' cli=%s\n' "${OPENCODE_CLI_CONFIG_CONTENT:-none}"
AGENT
  chmod +x "$TMP_DIR/bin/$agent"
done
export PATH="$TMP_DIR/bin:$PATH" XDG_CONFIG_HOME="$TMP_DIR/xdg"
# BASH_ENV can put the real agents back in front of the fakes.
unset OPENCODE_CLI_CONFIG_CONTENT BASH_ENV HC_TERMINAL_ID
CONFIG="$XDG_CONFIG_HOME/bercail/config.toml"
desk() { "$ROOT/bin/bercail-desk-agent" "$@"; }
expect() { [[ "$1" == "$2" ]] || fail "$3: got '$1', want '$2'"; }

printf '[agent]\ncommand = "claude --verbose"  # mine\n\n[bstack]\nenabled = true\n' >"$CONFIG"
got="$(desk)"
[[ "$got" == "opencode cli="* ]] || fail "bstack on runs opencode with no flags: $got"
cli="${got#opencode cli=}"
expect "$(jq -c '.theme' <<<"$cli")" '{"name":"system","mode":"system"}' "bstack's desk takes the terminal's palette"
expect "$(jq -c '.highlights' <<<"$cli")" false "no release highlights on the desk"
expect "$(jq -r '.tabs.mode' <<<"$cli")" off "tabs off: the TUI reports only its own session"
expect "$(desk --prompt 'Do bercail-1')" "opencode [--prompt] [Do bercail-1] cli=$cli" "bstack prompt"
printf 'PASS: bstack on runs opencode (full TUI, system theme), its prompt through --prompt\n'

expect "$(desk --prompt 'Do bercail-1' codex)" "codex [--no-daemon] [Do bercail-1] cli=none" "handoff codex"
expect "$(desk codex --no-daemon)" "codex [--no-daemon] cli=none" "codex keeps one --no-daemon"
expect "$(desk --prompt x claude)" "claude [x] cli=none" "handoff claude"
expect "$(desk --prompt x opencode)" "opencode [--prompt] [x] cli=$cli" "handoff opencode with bstack on"
printf 'PASS: a given command runs as is: codex without its daemon, the prompt last\n'

printf '[agent]\ncommand = "claude --verbose"  # mine\n\n[bstack]\nenabled = false\n' >"$CONFIG"
expect "$(desk)" "claude [--verbose] cli=none" "bstack off runs [agent] command"
expect "$(desk --prompt x)" "claude [--verbose] [x] cli=none" "bstack off prompt"
expect "$(desk opencode)" "opencode cli=none" "plain opencode with bstack off keeps the person's theme"
rm "$CONFIG"
expect "$(desk)" "cursor-agent cli=none" "no config"
printf 'PASS: bstack off runs [agent] command (cursor-agent without a config)\n'

# --- the desk's record, for bercail desk restore ---

export XDG_STATE_HOME="$TMP_DIR/state"
RECORDS="$XDG_STATE_HOME/bercail/desk-sessions"
printf '[bstack]\nenabled = true\n' >"$CONFIG"
EVENTS="$TMP_DIR/events"
: >"$EVENTS"
# Fake hc: a labelled desk unless told otherwise, and events from a file.
cat >"$TMP_DIR/bin/hc" <<HC
#!/usr/bin/env bash
case "\$1" in
  get) cat "$TMP_DIR/terminal.json" ;;
  events) cat "$EVENTS"; exec sleep 30 ;;
esac
HC
chmod +x "$TMP_DIR/bin/hc"
printf '{"labels":{"bercail.role":"agent","bercail.space":"sp1"}}\n' >"$TMP_DIR/terminal.json"
record() { jq -c "$1" "$RECORDS/t9.json"; }
# Waits for the watcher to do its part; it runs beside the agent.
wait_for() {
  local i
  for i in $(seq 1 50); do
    if eval "$1"; then return 0; fi
    sleep 0.1
  done
  fail "timed out: $1"
}

export HC_TERMINAL_ID=t9
got="$(desk --prompt 'Your job is beads issue bercail-0uo. Run it.' opencode --verbose)"
[[ "$got" == "opencode [--verbose] [--prompt] [Your job is beads issue bercail-0uo. Run it.] cli="* ]] \
  || fail "the argv a desk runs does not change: $got"
expect "$(record '[.address, .session, .harness, .issue, .space, .args]')" \
  '["t9","","opencode","bercail-0uo","sp1",["--verbose"]]' "a record, with the prompt out of its flags"
expect "$(record .cwd | jq -r .)" "$PWD" "the record has the folder"
printf 'PASS: a desk writes its record and its command stays the same\n'

desk opencode --session ses_given --verbose >/dev/null
expect "$(record '[.session, .issue, .args]')" '["ses_given","bercail-0uo",["--verbose"]]' \
  "a resume names its session and keeps the terminal's issue"
desk claude --resume abc >/dev/null
expect "$(record '[.session, .harness]')" '["abc","claude"]' "claude's resume flag"
printf 'PASS: a resume keeps session, flags and issue\n'

# Resume replays args beside an explicit session, so a prompt or "continue the
# latest" must not be in them. The command that ran is unchanged.
got="$(desk opencode --verbose --prompt 'Do not replay')"
[[ "$got" == "opencode [--verbose] [--prompt] [Do not replay] cli="* ]] \
  || fail "native --prompt still runs: $got"
expect "$(record .args)" '["--verbose"]' "native opencode --prompt is not replayed"
got="$(desk opencode --prompt='Do not replay' --verbose)"
[[ "$got" == "opencode [--prompt=Do not replay] [--verbose] cli="* ]] \
  || fail "native --prompt= still runs: $got"
expect "$(record .args)" '["--verbose"]' "native opencode --prompt= is not replayed"
got="$(desk opencode --continue --verbose)"
[[ "$got" == "opencode [--continue] [--verbose] cli="* ]] || fail "--continue still runs: $got"
expect "$(record .args)" '["--verbose"]' "opencode --continue is not replayed"
got="$(desk opencode -c --session ses_keep --verbose)"
[[ "$got" == "opencode [-c] [--session] [ses_keep] [--verbose] cli="* ]] || fail "-c still runs: $got"
expect "$(record '[.session, .args]')" '["ses_keep",["--verbose"]]' \
  "-c is dropped and the session flag is not recorded twice"
desk claude -c --verbose >/dev/null
expect "$(record .args)" '["--verbose"]' "claude -c is not replayed beside --resume"
printf 'PASS: a resume does not replay a prompt or continue the latest\n'

desk opencode --session=ses_eq --verbose >/dev/null
expect "$(record '[.session, .args]')" '["ses_eq",["--verbose"]]' \
  "opencode --session= is the session, not a second flag"
desk opencode -s ses_short --verbose >/dev/null
expect "$(record '[.session, .args]')" '["ses_short",["--verbose"]]' "opencode -s names the session once"
desk claude --resume=abc-eq --verbose >/dev/null
expect "$(record '[.session, .harness, .args]')" '["abc-eq","claude",["--verbose"]]' \
  "claude --resume= is the session, not a second flag"
desk claude --session-id=abc-fixed --fork-session --verbose >/dev/null
expect "$(record '[.session, .args]')" '["abc-fixed",["--verbose"]]' \
  "Claude resumes the recorded session without assigning/forking it again"
printf 'PASS: an equals session flag is recorded once\n'

got="$(desk --prompt 'Your job is beads issue bercail-0uo. Run it.' claude --verbose)"
[[ "$got" == "claude [--verbose] [Your job is beads issue bercail-0uo. Run it.] cli=none" ]] \
  || fail "claude's wrapper prompt still runs: $got"
expect "$(record '[.issue, .args]')" '["bercail-0uo",["--verbose"]]' \
  "claude's wrapper prompt is not a recorded positional"
got="$(desk --prompt 'job text' claude --verbose 'job text')"
[[ "$got" == "claude [--verbose] [job text] [job text] cli=none" ]] \
  || fail "claude argv unchanged when the prompt is also positional: $got"
expect "$(record .args)" '["--verbose"]' "that positional prompt is not replayed"
got="$(desk --prompt 'job text' claude --verbose other)"
[[ "$got" == "claude [--verbose] [other] [job text] cli=none" ]] \
  || fail "a different claude positional still runs: $got"
expect "$(record .args)" '["--verbose"]' "native Claude prompts are not replayed either"
desk claude --verbose 'keep me' >/dev/null
expect "$(record .args)" '["--verbose"]' "a native Claude prompt is omitted without a wrapper prompt"
desk claude --model sonnet -- 'another prompt' >/dev/null
expect "$(record .args)" '["--model","sonnet"]' "Claude keeps flag values but not a prompt after --"
printf 'PASS: claude replays no initial prompt\n'

settings=$'{\n  "permissions": {}\n}'
desk claude --settings "$settings" >/dev/null
expect "$(record .args)" "$(jq -cn --arg settings "$settings" '["--settings", $settings]')" \
  "multiline flag values remain one argument"

# A flag's value is not a subcommand: --prompt run stays a desk.
got="$(desk opencode --prompt run --verbose)"
[[ "$got" == "opencode [--prompt] [run] [--verbose] cli="* ]] || fail "prompt run still runs: $got"
[[ -f "$RECORDS/t9.json" ]] || fail "opencode --prompt run is interactive"
expect "$(record .args)" '["--verbose"]' "the prompt value run is not replayed and not a subcommand"
desk opencode --log-level run --verbose >/dev/null
[[ -f "$RECORDS/t9.json" ]] || fail "opencode --log-level run is interactive"
expect "$(record .args)" '["--log-level","run","--verbose"]' "a flag value named run stays with its flag"
desk codex -c exec --verbose >/dev/null
[[ -f "$RECORDS/t9.json" ]] || fail "codex -c exec is a config value, not headless"
expect "$(record .args)" '["-c","exec","--verbose"]' "codex -c takes the next word"
printf 'PASS: a flag value named run is not a subcommand\n'

# Args can name a key. A new dir is private; one already there keeps its mode.
# The file is 0600 even under a loose umask, and the harness is not started with another.
rm -rf "$RECORDS"
(umask 022; desk opencode --verbose >/dev/null)
expect "$(stat -c %a "$RECORDS")" 700 "a new desk-sessions dir is private"
expect "$(stat -c %a "$RECORDS/t9.json")" 600 "the record is private"
chmod 755 "$RECORDS"
(umask 022; desk opencode --verbose >/dev/null)
expect "$(stat -c %a "$RECORDS")" 755 "an existing desk-sessions dir keeps its mode"
expect "$(stat -c %a "$RECORDS/t9.json")" 600 "rewriting the record stays private"
cat >"$TMP_DIR/bin/opencode" <<'AGENT'
#!/usr/bin/env bash
umask
AGENT
expect "$(umask 022; desk opencode)" 0022 "the harness keeps the umask it was started with"
cat >"$TMP_DIR/bin/opencode" <<'AGENT'
#!/usr/bin/env bash
printf '%s' "$(basename "$0")"
for a in "$@"; do printf ' [%s]' "$a"; done
printf ' cli=%s\n' "${OPENCODE_CLI_CONFIG_CONTENT:-none}"
AGENT
chmod +x "$TMP_DIR/bin/opencode"
printf 'PASS: records are private, and an existing dir is left as it was\n'

rm -f "$RECORDS/t9.json"
for headless in "opencode run hi" "claude -p hi" "claude --print hi" "codex exec hi" "cursor-agent -p hi" \
  "opencode --print-logs run hi" "opencode --log-level debug run hi" "opencode --server http://127.0.0.1:1 run hi" \
  "opencode --continue run hi" "codex --no-daemon exec hi" "codex --model gpt exec hi" "codex -m gpt exec" \
  "claude --print=hi" "claude --verbose --print hi" "cursor-agent --print=hi" "cursor-agent --force --print=out"; do
  # shellcheck disable=SC2086
  desk $headless >/dev/null
  [[ ! -e "$RECORDS/t9.json" ]] || fail "headless run got a record: $headless"
done
printf 'PASS: headless runs get no record\n'

printf '{"labels":{}}\n' >"$TMP_DIR/terminal.json"
desk opencode >/dev/null
[[ ! -e "$RECORDS/t9.json" ]] || fail "a terminal that is not a desk got a record"
printf '{"labels":{"bercail.role":"agent","bercail.space":"sp1"}}\n' >"$TMP_DIR/terminal.json"
(unset HC_TERMINAL_ID; desk opencode >/dev/null)
[[ ! -e "$RECORDS/t9.json" ]] || fail "outside hc there is no address to key on"
printf '#!/usr/bin/env bash\nexit 1\n' >"$TMP_DIR/bin/hc.down"
mv "$TMP_DIR/bin/hc" "$TMP_DIR/hc.up"; mv "$TMP_DIR/bin/hc.down" "$TMP_DIR/bin/hc"; chmod +x "$TMP_DIR/bin/hc"
[[ "$(desk opencode)" == "opencode cli="* ]] || fail "hc down must not stop the desk"
[[ ! -e "$RECORDS/t9.json" ]] || fail "hc down: no record"
mv "$TMP_DIR/hc.up" "$TMP_DIR/bin/hc"
printf 'PASS: no record outside a desk, and a failure never stops the desk\n'

# hc status may include other sessions. Only the TUI plugin owns identity.
cat >"$TMP_DIR/bin/opencode" <<'AGENT'
#!/usr/bin/env bash
exec sleep "${AGENT_LIFE:-2}"
AGENT
status() { jq -cn --argjson r "$1" '{jsonrpc: "2.0", method: "event", params: {type: "status", terminal: "t9", data: {records: $r}}}'; }
{ status '{"ses_second":{"app":"opencode"}}'; } >"$EVENTS"
AGENT_LIFE=1 desk opencode --session ses_given >/dev/null
expect "$(record .session)" '"ses_given"' "hc reports do not replace the selected session"
printf '[bstack]\nenabled = false\n' >"$CONFIG"
AGENT_LIFE=1 desk opencode --session ses_given >/dev/null
expect "$(record .session)" '"ses_given"' "same identity rule without bstack"
printf '[bstack]\nenabled = true\n' >"$CONFIG"
printf 'PASS: hc status cannot overwrite the selected TUI session\n'

# The record's pid is the agent's: the wrapper execs, so it stays the same.
: >"$EVENTS"
AGENT_LIFE=30 "$ROOT/bin/bercail-desk-agent" opencode >/dev/null &
pid=$!
wait_for '[[ -f "$RECORDS/t9.json" && "$(record .pid 2>/dev/null)" == "$pid" ]]'
kill "$pid"; wait "$pid" 2>/dev/null || true
printf 'PASS: the record names the running agent\n'

# The watcher ends with the agent, taking its hc events with it: a live stream
# wakes it, as hc's own exit event does. The fake notes its pid to be checked.
cat >"$TMP_DIR/bin/hc" <<HC
#!/usr/bin/env bash
case "\$1" in
  get) cat "$TMP_DIR/terminal.json" ;;
  events)
    printf '%s\n' "\$\$" >"$TMP_DIR/events.pid"
    while :; do printf '{}\n'; sleep 0.2; done
    ;;
esac
HC
AGENT_LIFE=1 desk opencode >/dev/null
wait_for '[[ -s "$TMP_DIR/events.pid" ]] && ! kill -0 "$(cat "$TMP_DIR/events.pid")" 2>/dev/null'
printf 'PASS: the watcher goes when the agent does\n'

# The heartbeat: an idle agent writes nothing, the watcher keeps the record fresh.
AGENT_LIFE=30 "$ROOT/bin/bercail-desk-agent" opencode >/dev/null &
pid=$!
wait_for '[[ "$(record .pid 2>/dev/null)" == "$pid" ]]'
touch -d '2020-01-01' "$RECORDS/t9.json"
wait_for '[[ "$(stat -c %Y "$RECORDS/t9.json")" -gt 1600000000 ]]'
kill "$pid"; wait "$pid" 2>/dev/null || true
printf 'PASS: the watcher keeps the record fresh while the agent runs\n'

# --- the Claude hook ---
HOOK="$ROOT/bin/bercail-desk-claude-hook"
printf '{"harness":"claude","pid":%s,"session":""}\n' "$$" >"$RECORDS/t9.json"
hook_input='{"session_id":"claude-1","source":"startup"}'
printf '%s' "$hook_input" | "$HOOK"
expect "$(record .session)" '"claude-1"' "hook run by the desk's Claude"
printf '{"harness":"claude","pid":%s,"session":""}\n' "$$" >"$RECORDS/t9.json"
printf '%s' "$hook_input" | sh -c "'$HOOK'"
expect "$(record .session)" '"claude-1"' "Claude runs hooks through a shell"
printf '{"harness":"claude","pid":%s,"session":"keep"}\n' "$$" >"$RECORDS/t9.json"
cp "$(command -v bash)" "$TMP_DIR/nested-agent"
printf '%s' "$hook_input" | "$TMP_DIR/nested-agent" -c "'$HOOK'; :"
expect "$(record .session)" '"keep"' "a nested agent directly below the desk is not a hook shell"
printf '%s' "$hook_input" | sh -c "sh -c \"sh -c '$HOOK'; :\"; :"
expect "$(record .session)" '"keep"' "a claude -p the desk started is not the desk"
printf '{"harness":"opencode","pid":%s,"session":"keep"}\n' "$$" >"$RECORDS/t9.json"
printf '%s' "$hook_input" | "$HOOK"
expect "$(record .session)" '"keep"' "a Claude inside an opencode desk is not the desk"
rm -f "$RECORDS/t9.json"
printf '%s' "$hook_input" | "$HOOK"
[[ ! -e "$RECORDS/t9.json" ]] || fail "no record, not a desk: the hook writes nothing"
printf 'PASS: the Claude hook names the session of the desk it belongs to, only\n'
