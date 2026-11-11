#!/usr/bin/env bash
# shellcheck shell=bash
# bin/bercail-desk-agent: what the desk runs, from config.toml and its arguments.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# The fake Pi prints its argv and the Anthropic key it got; another command
# prints its name and argv.
mkdir -p "$TMP_DIR/bin" "$TMP_DIR/xdg/bercail"
fake_pi() {
  cat >"$TMP_DIR/bin/pi" <<'AGENT'
#!/usr/bin/env bash
printf 'pi'
for a in "$@"; do printf ' [%s]' "$a"; done
printf ' key=%s\n' "${ANTHROPIC_API_KEY:-none}"
AGENT
  chmod +x "$TMP_DIR/bin/pi"
}
fake_pi
cat >"$TMP_DIR/bin/other" <<'AGENT'
#!/usr/bin/env bash
printf 'other'
for a in "$@"; do printf ' [%s]' "$a"; done
printf '\n'
AGENT
chmod +x "$TMP_DIR/bin/other"
# HOME holds the Pi lead and the desk extension bercail update writes.
export PATH="$TMP_DIR/bin:$PATH" XDG_CONFIG_HOME="$TMP_DIR/xdg" HOME="$TMP_DIR/home"
# BASH_ENV can put the real agents back in front of the fakes.
unset BASH_ENV HC_TERMINAL_ID
CONFIG="$XDG_CONFIG_HOME/bercail/config.toml"
desk() { "$ROOT/bin/bercail-desk-agent" "$@"; }
expect() { [[ "$1" == "$2" ]] || fail "$3: got '$1', want '$2'"; }

# --- bstack on: the Pi lead ---

LEAD="$HOME/.local/share/bercail/pi/lead.json"
EXT="$HOME/.local/share/bercail/pi-extensions/bercail-desk.ts"
printf '[bstack]\nenabled = true\n' >"$CONFIG"
got="$(desk 2>&1)" && fail "a bstack desk without its lead should not start: $got"
[[ "$got" == *"lead.json is missing; run bercail update"* ]] || fail "missing lead says what to run: $got"
mkdir -p "$(dirname "$LEAD")" "$(dirname "$EXT")"
jq -n '$ARGS.positional' --args -- pi --model claude-bridge/opus:high --append-system-prompt "/a b/instructions.md" >"$LEAD"
expect "$(ANTHROPIC_API_KEY=secret desk --prompt 'Do bercail-1')" \
  "pi [--model] [claude-bridge/opus:high] [--append-system-prompt] [/a b/instructions.md] [Do bercail-1] key=none" \
  "bstack runs the lead, the prompt as its first message, without an API key"
: >"$EXT"
expect "$(desk)" "pi [-e] [$EXT] [--model] [claude-bridge/opus:high] [--append-system-prompt] [/a b/instructions.md] key=none" \
  "the lead loads the desk extension"
expect "$(desk pi -e "$EXT" --verbose)" "pi [-e] [$EXT] [--verbose] key=none" "the desk extension is loaded once"
expect "$(desk pi -- '- a message')" "pi [-e] [$EXT] [--] [- a message] key=none" "the extension comes before --"
printf 'PASS: bstack runs the Pi lead from lead.json, with the desk extension and no Anthropic env\n'

# --- bstack off: plain Pi ---

printf '[bstack]\nenabled = false\n' >"$CONFIG"
expect "$(ANTHROPIC_API_KEY=mine desk)" "pi [-e] [$EXT] key=mine" "bstack off runs plain pi; the env stays"
expect "$(desk --prompt x)" "pi [-e] [$EXT] [x] key=none" "bstack off prompt"
rm "$CONFIG"
expect "$(desk)" "pi [-e] [$EXT] key=none" "no config runs plain pi"
rm -f "$EXT"
expect "$(desk --prompt x other --verbose)" "other [--verbose] [x]" "a given command runs as is, the prompt last"
printf 'PASS: bstack off runs plain pi; a given command runs as is\n'

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
got="$(desk --prompt 'Your job is beads issue bercail-0uo. Run it.' pi --verbose)"
expect "$got" "pi [--verbose] [Your job is beads issue bercail-0uo. Run it.] key=none" "the argv a desk runs does not change"
expect "$(record '[.address, .session, .harness, .issue, .issue_title, .space, .args]')" \
  '["t9","","pi","bercail-0uo","","sp1",["--verbose"]]' "a record, with the prompt out of its flags"
expect "$(record .cwd | jq -r .)" "$PWD" "the record has the folder"
printf 'PASS: a desk writes its record and its command stays the same\n'

desk pi --session-id 0199-given --verbose >/dev/null
expect "$(record '[.session, .issue, .args]')" '["0199-given","bercail-0uo",["--verbose"]]' \
  "a resume names its session and keeps the terminal's issue"
printf 'PASS: a resume keeps session, flags and issue\n'

printf '{"labels":{"bercail.role":"agent","bercail.space":"sp1","bercail.issue":"bercail-0uo","bercail.issue_title":"Short title"}}\n' >"$TMP_DIR/terminal.json"
desk --prompt 'Your job is beads issue bercail-0uo: Short title. Run it.' pi --verbose >/dev/null
expect "$(record .issue_title)" '"Short title"' "title comes from the label when it names the issue"
printf '{"labels":{"bercail.role":"agent","bercail.space":"sp1","bercail.issue":"other-1","bercail.issue_title":"Wrong"}}\n' >"$TMP_DIR/terminal.json"
desk pi --session-id 0199-kept --verbose >/dev/null
expect "$(record '[.issue, .issue_title, .session]')" '["bercail-0uo","Short title","0199-kept"]' \
  "resume keeps the title when the label names a different issue"
printf '{"labels":{"bercail.role":"agent","bercail.space":"sp1"}}\n' >"$TMP_DIR/terminal.json"
printf 'PASS: the desk record takes issue_title from the label, and a resume keeps it\n'

# Resume replays args beside an explicit session, so a prompt or "continue the
# latest" must not be in them. The command that ran is unchanged.
got="$(desk --prompt 'Your job is beads issue bercail-yql. Run it.' pi --model m:high -e /x.ts --skill /s 'native')"
expect "$got" "pi [--model] [m:high] [-e] [/x.ts] [--skill] [/s] [native] [Your job is beads issue bercail-yql. Run it.] key=none" \
  "a Pi desk's argv does not change"
expect "$(record '[.session, .harness, .issue, .args]')" '["","pi","bercail-yql",["--model","m:high","-e","/x.ts","--skill","/s"]]' \
  "Pi keeps flag values, not its first messages"
desk pi --session-id 0199-a --thinking high -- 'a message' >/dev/null
expect "$(record '[.session, .issue, .args]')" '["0199-a","bercail-yql",["--thinking","high"]]' \
  "Pi's resume names its session and keeps the terminal's issue"
desk pi --session=0199-b -c --resume --fork 0199-c --name desk >/dev/null
expect "$(record '[.session, .args]')" '["0199-b",["--name","desk"]]' \
  "Pi does not replay continue, resume or fork beside its session"
desk pi --session 0199-d --continue --verbose >/dev/null
expect "$(record '[.session, .args]')" '["0199-d",["--verbose"]]' \
  "--continue is dropped and the session flag is not recorded twice"
desk pi --session-id=0199-e --verbose >/dev/null
expect "$(record '[.session, .args]')" '["0199-e",["--verbose"]]' "an equals session flag is recorded once"
printf 'PASS: Pi records its session and resume-safe flags\n'

prompt=$'You review.\nRead only the stack.'
desk pi --append-system-prompt "$prompt" >/dev/null
expect "$(record .args)" "$(jq -cn --arg p "$prompt" '["--append-system-prompt", $p]')" \
  "multiline flag values remain one argument"
printf 'PASS: a multiline flag value is one argument\n'

# Args can name a key. A new dir is private; one already there keeps its mode.
# The file is 0600 even under a loose umask, and the agent is not started with another.
rm -rf "$RECORDS"
(umask 022; desk pi --verbose >/dev/null)
expect "$(stat -c %a "$RECORDS")" 700 "a new desk-sessions dir is private"
expect "$(stat -c %a "$RECORDS/t9.json")" 600 "the record is private"
chmod 755 "$RECORDS"
(umask 022; desk pi --verbose >/dev/null)
expect "$(stat -c %a "$RECORDS")" 755 "an existing desk-sessions dir keeps its mode"
expect "$(stat -c %a "$RECORDS/t9.json")" 600 "rewriting the record stays private"
printf '#!/usr/bin/env bash\numask\n' >"$TMP_DIR/bin/pi"
expect "$(umask 022; desk pi)" 0022 "the agent keeps the umask it was started with"
fake_pi
printf 'PASS: records are private, and an existing dir is left as it was\n'

rm -f "$RECORDS/t9.json"
for headless in "pi -p hi" "pi --model m --print hi" "pi --print=hi" "pi --verbose -p hi"; do
  # shellcheck disable=SC2086
  desk $headless >/dev/null
  [[ ! -e "$RECORDS/t9.json" ]] || fail "headless run got a record: $headless"
done
desk other --verbose >/dev/null
[[ ! -e "$RECORDS/t9.json" ]] || fail "a command that is not Pi got a record"
printf 'PASS: headless runs and other commands get no record\n'

printf '{"labels":{}}\n' >"$TMP_DIR/terminal.json"
desk pi >/dev/null
[[ ! -e "$RECORDS/t9.json" ]] || fail "a terminal that is not a desk got a record"
printf '{"labels":{"bercail.role":"agent","bercail.space":"sp1"}}\n' >"$TMP_DIR/terminal.json"
(unset HC_TERMINAL_ID; desk pi >/dev/null)
[[ ! -e "$RECORDS/t9.json" ]] || fail "outside hc there is no address to key on"
printf '#!/usr/bin/env bash\nexit 1\n' >"$TMP_DIR/bin/hc.down"
mv "$TMP_DIR/bin/hc" "$TMP_DIR/hc.up"; mv "$TMP_DIR/bin/hc.down" "$TMP_DIR/bin/hc"; chmod +x "$TMP_DIR/bin/hc"
[[ "$(desk pi)" == "pi "* ]] || fail "hc down must not stop the desk"
[[ ! -e "$RECORDS/t9.json" ]] || fail "hc down: no record"
mv "$TMP_DIR/hc.up" "$TMP_DIR/bin/hc"
printf 'PASS: no record outside a desk, and a failure never stops the desk\n'

# hc status may include other sessions. Only the Pi desk extension owns identity.
printf '#!/usr/bin/env bash\nexec sleep "${AGENT_LIFE:-2}"\n' >"$TMP_DIR/bin/pi"
status() { jq -cn --argjson r "$1" '{jsonrpc: "2.0", method: "event", params: {type: "status", terminal: "t9", data: {records: $r}}}'; }
{ status '{"0199-second":{"app":"pi"}}'; } >"$EVENTS"
AGENT_LIFE=1 desk pi --session-id 0199-given >/dev/null
expect "$(record .session)" '"0199-given"' "hc reports do not replace the selected session"
printf '[bstack]\nenabled = false\n' >"$CONFIG"
AGENT_LIFE=1 desk pi --session-id 0199-given >/dev/null
expect "$(record .session)" '"0199-given"' "same identity rule without bstack"
printf '[bstack]\nenabled = true\n' >"$CONFIG"
printf 'PASS: hc status cannot overwrite the selected session\n'

# The record's pid is the agent's: the wrapper execs, so it stays the same.
: >"$EVENTS"
AGENT_LIFE=30 "$ROOT/bin/bercail-desk-agent" pi >/dev/null &
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
AGENT_LIFE=1 desk pi >/dev/null
wait_for '[[ -s "$TMP_DIR/events.pid" ]] && ! kill -0 "$(cat "$TMP_DIR/events.pid")" 2>/dev/null'
printf 'PASS: the watcher goes when the agent does\n'

# The heartbeat: an idle agent writes nothing, the watcher keeps the record fresh.
AGENT_LIFE=30 "$ROOT/bin/bercail-desk-agent" pi >/dev/null &
pid=$!
wait_for '[[ "$(record .pid 2>/dev/null)" == "$pid" ]]'
touch -d '2020-01-01' "$RECORDS/t9.json"
wait_for '[[ "$(stat -c %Y "$RECORDS/t9.json")" -gt 1600000000 ]]'
kill "$pid"; wait "$pid" 2>/dev/null || true
printf 'PASS: the watcher keeps the record fresh while the agent runs\n'
