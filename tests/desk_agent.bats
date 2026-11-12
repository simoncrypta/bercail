#!/usr/bin/env bats
# bin/bercail-desk-agent: what the desk runs, from config.toml and its arguments.
# wait_for evals its single-quoted condition on each try.
# shellcheck disable=SC2016

setup() {
  load test_helper
  isolate
  # A flag value can contain a newline; pipelines that check it must still fail the test.
  set -o pipefail
  mkdir -p "$BATS_TEST_TMPDIR/bin" "$XDG_CONFIG_HOME/bercail"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  hash -r
  # A key in the environment would show up as key=none failing. Tests that want one set it inline.
  unset ANTHROPIC_API_KEY ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN
  fake_pi
  cat >"$BATS_TEST_TMPDIR/bin/other" <<'AGENT'
#!/usr/bin/env bash
printf 'other'
for a in "$@"; do printf ' [%s]' "$a"; done
printf '\n'
AGENT
  chmod +x "$BATS_TEST_TMPDIR/bin/other"
  CONFIG="$XDG_CONFIG_HOME/bercail/config.toml"
}

desk() { "$ROOT/bin/bercail-desk-agent" "$@"; }
expect() { [[ "$1" == "$2" ]] || fail "$3: got '$1', want '$2'"; }

# The fake Pi prints its argv and the Anthropic key it got.
fake_pi() {
  cat >"$BATS_TEST_TMPDIR/bin/pi" <<'AGENT'
#!/usr/bin/env bash
printf 'pi'
for a in "$@"; do printf ' [%s]' "$a"; done
printf ' key=%s\n' "${ANTHROPIC_API_KEY:-none}"
AGENT
  chmod +x "$BATS_TEST_TMPDIR/bin/pi"
  hash -r
}

# Fake hc: a labelled desk unless a test says otherwise. Records land under the test HOME.
arrange_record() {
  printf '[bstack]\nenabled = true\n' >"$CONFIG"
  export HC_TERMINAL_ID=t9
  RECORDS="$XDG_STATE_HOME/bercail/desk-sessions"
  EVENTS="$BATS_TEST_TMPDIR/events"
  : >"$EVENTS"
  cat >"$BATS_TEST_TMPDIR/bin/hc" <<HC
#!/usr/bin/env bash
case "\$1" in
  get) cat "$BATS_TEST_TMPDIR/terminal.json" ;;
  events) cat "$EVENTS"; exec sleep 30 ;;
esac
HC
  chmod +x "$BATS_TEST_TMPDIR/bin/hc"
  printf '{"labels":{"bercail.role":"agent","bercail.space":"sp1"}}\n' >"$BATS_TEST_TMPDIR/terminal.json"
  hash -r
}

record() { jq -c "$1" "$RECORDS/t9.json"; }

# Polls a signal (a file, a pid, an mtime). The deadline is long so a loaded machine
# still fails loudly instead of racing a fixed sleep.
wait_for() {
  local _
  for _ in $(seq 1 100); do
    if eval "$1"; then return 0; fi
    sleep 0.1
  done
  fail "timed out: $1"
}

# A hung agent: the sleep is the process, not a wait for something else to be ready.
pi_sleeps() {
  printf '#!/usr/bin/env bash\nexec sleep "${AGENT_LIFE:-2}"\n' >"$BATS_TEST_TMPDIR/bin/pi"
  chmod +x "$BATS_TEST_TMPDIR/bin/pi"
  hash -r
}

# hc events that keep streaming: they wake the watcher, as hc's own exit event does.
# The fake notes its pid to be checked. The 0.2s sleep is the stream, not a readiness wait.
hc_streams_events() {
  cat >"$BATS_TEST_TMPDIR/bin/hc" <<HC
#!/usr/bin/env bash
case "\$1" in
  get) cat "$BATS_TEST_TMPDIR/terminal.json" ;;
  events)
    printf '%s\n' "\$\$" >"$BATS_TEST_TMPDIR/events.pid"
    while :; do printf '{}\n'; sleep 0.2; done
    ;;
esac
HC
  chmod +x "$BATS_TEST_TMPDIR/bin/hc"
  hash -r
}

# The prompt run that writes issue bercail-0uo. The resume case keeps that issue;
# the shell script did this in the previous case, so each @test rebuilds it.
seed_issue() {
  arrange_record
  desk --prompt 'Your job is beads issue bercail-0uo. Run it.' pi --verbose >/dev/null
}

@test "bstack runs the Pi lead from lead.json, with the desk extension and no Anthropic env" {
  local got LEAD EXT
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
}

# A bstack lead with a model and a thinking level, as bercail update writes it.
arrange_lead() {
  LEAD="$HOME/.local/share/bercail/pi/lead.json"
  mkdir -p "$(dirname "$LEAD")"
  jq -n '$ARGS.positional' --args -- pi --model claude-bridge/opus:high -e /bridge.ts \
    --append-system-prompt "/a b/instructions.md" --skill /s >"$LEAD"
}

@test "--model swaps the lead's model and changes nothing else" {
  arrange_lead
  printf '[bstack]\nenabled = true\n' >"$CONFIG"
  expect "$(desk --prompt 'Do bercail-1' --model claude-bridge/fable:high)" \
    "pi [--model] [claude-bridge/fable:high] [-e] [/bridge.ts] [--append-system-prompt] [/a b/instructions.md] [--skill] [/s] [Do bercail-1] key=none" \
    "the lead runs on the given model, the rest of its argv as it was"
  expect "$(desk --model claude-bridge/fable:low --prompt x)" \
    "pi [--model] [claude-bridge/fable:low] [-e] [/bridge.ts] [--append-system-prompt] [/a b/instructions.md] [--skill] [/s] [x] key=none" \
    "the options come in either order"
  expect "$(desk --model m2 pi --model=m1 --verbose)" "pi [--model=m2] [--verbose] key=none" "an equals --model is swapped in place"
  expect "$(desk --model m2 pi --verbose -- --model)" "pi [--model] [m2] [--verbose] [--] [--model] key=none" \
    "a Pi command with no --model gets one; a message after -- is not a flag"
  local got
  got="$(desk --model m2 other --verbose 2>&1)" && fail "--model on a command that is not Pi should fail: $got"
  [[ "$got" == *"--model is for Pi"* ]] || fail "not-Pi message: $got"
}

@test "a desk on --model records it, and its resume relaunches on it" {
  local cmd
  arrange_lead
  arrange_record
  ln -s "$ROOT/bin/bercail-desk-agent" "$BATS_TEST_TMPDIR/bin/bercail-desk-agent"
  desk --prompt 'Your job is beads issue bercail-ev6. Run it.' --model claude-bridge/fable:high >/dev/null
  expect "$(record '.args[0:2]')" '["--model","claude-bridge/fable:high"]' "the record's flags carry the swapped model"
  # shellcheck source=/dev/null
  cmd="$(source "$ROOT/lib/common.sh" && source "$ROOT/lib/desk.sh" \
    && desk_resume_command "$(record '.session = "0199-r"')")"
  [[ "$cmd" == *"bercail-desk-agent pi --session-id 0199-r --model claude-bridge/fable:high "* ]] \
    || fail "the resume line carries the model: $cmd"
  expect "$(bash -c "$cmd")" \
    "pi [--session-id] [0199-r] [--model] [claude-bridge/fable:high] [-e] [/bridge.ts] [--append-system-prompt] [/a b/instructions.md] [--skill] [/s] key=none" \
    "the resumed desk runs Pi on the model it had"
}

@test "bstack off runs plain pi; a given command runs as is" {
  local EXT
  EXT="$HOME/.local/share/bercail/pi-extensions/bercail-desk.ts"
  mkdir -p "$(dirname "$EXT")"
  : >"$EXT"
  printf '[bstack]\nenabled = false\n' >"$CONFIG"
  expect "$(ANTHROPIC_API_KEY=mine desk)" "pi [-e] [$EXT] key=mine" "bstack off runs plain pi; the env stays"
  expect "$(desk --prompt x)" "pi [-e] [$EXT] [x] key=none" "bstack off prompt"
  rm "$CONFIG"
  expect "$(desk)" "pi [-e] [$EXT] key=none" "no config runs plain pi"
  rm -f "$EXT"
  expect "$(desk --prompt x other --verbose)" "other [--verbose] [x]" "a given command runs as is, the prompt last"
}

@test "a desk writes its record and its command stays the same" {
  local got
  arrange_record
  got="$(desk --prompt 'Your job is beads issue bercail-0uo. Run it.' pi --verbose)"
  expect "$got" "pi [--verbose] [Your job is beads issue bercail-0uo. Run it.] key=none" "the argv a desk runs does not change"
  expect "$(record '[.address, .session, .harness, .issue, .issue_title, .space, .args]')" \
    '["t9","","pi","bercail-0uo","","sp1",["--verbose"]]' "a record, with the prompt out of its flags"
  expect "$(record .cwd | jq -r .)" "$PWD" "the record has the folder"
}

@test "a resume keeps session, flags and issue" {
  seed_issue
  desk pi --session-id 0199-given --verbose >/dev/null
  expect "$(record '[.session, .issue, .args]')" '["0199-given","bercail-0uo",["--verbose"]]' \
    "a resume names its session and keeps the terminal's issue"
}

@test "the desk record takes issue_title from the label, and a resume keeps it" {
  arrange_record
  printf '{"labels":{"bercail.role":"agent","bercail.space":"sp1","bercail.issue":"bercail-0uo","bercail.issue_title":"Short title"}}\n' >"$BATS_TEST_TMPDIR/terminal.json"
  desk --prompt 'Your job is beads issue bercail-0uo: Short title. Run it.' pi --verbose >/dev/null
  expect "$(record .issue_title)" '"Short title"' "title comes from the label when it names the issue"
  printf '{"labels":{"bercail.role":"agent","bercail.space":"sp1","bercail.issue":"other-1","bercail.issue_title":"Wrong"}}\n' >"$BATS_TEST_TMPDIR/terminal.json"
  desk pi --session-id 0199-kept --verbose >/dev/null
  expect "$(record '[.issue, .issue_title, .session]')" '["bercail-0uo","Short title","0199-kept"]' \
    "resume keeps the title when the label names a different issue"
}

@test "Pi records its session and resume-safe flags" {
  local got
  arrange_record
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
}

@test "a multiline flag value is one argument" {
  local prompt
  arrange_record
  prompt=$'You review.\nRead only the stack.'
  desk pi --append-system-prompt "$prompt" >/dev/null
  expect "$(record .args)" "$(jq -cn --arg p "$prompt" '["--append-system-prompt", $p]')" \
    "multiline flag values remain one argument"
}

@test "records are private, and an existing dir is left as it was" {
  arrange_record
  rm -rf "$RECORDS"
  (umask 022; desk pi --verbose >/dev/null)
  expect "$(stat -c %a "$RECORDS")" 700 "a new desk-sessions dir is private"
  expect "$(stat -c %a "$RECORDS/t9.json")" 600 "the record is private"
  chmod 755 "$RECORDS"
  (umask 022; desk pi --verbose >/dev/null)
  expect "$(stat -c %a "$RECORDS")" 755 "an existing desk-sessions dir keeps its mode"
  expect "$(stat -c %a "$RECORDS/t9.json")" 600 "rewriting the record stays private"
  printf '#!/usr/bin/env bash\numask\n' >"$BATS_TEST_TMPDIR/bin/pi"
  chmod +x "$BATS_TEST_TMPDIR/bin/pi"
  hash -r
  expect "$(umask 022; desk pi)" 0022 "the agent keeps the umask it was started with"
}

@test "headless runs and other commands get no record" {
  local headless
  arrange_record
  rm -f "$RECORDS/t9.json"
  for headless in "pi -p hi" "pi --model m --print hi" "pi --print=hi" "pi --verbose -p hi"; do
    # shellcheck disable=SC2086
    desk $headless >/dev/null
    [[ ! -e "$RECORDS/t9.json" ]] || fail "headless run got a record: $headless"
  done
  desk other --verbose >/dev/null
  [[ ! -e "$RECORDS/t9.json" ]] || fail "a command that is not Pi got a record"
}

@test "no record outside a desk, and a failure never stops the desk" {
  arrange_record
  rm -f "$RECORDS/t9.json"
  printf '{"labels":{}}\n' >"$BATS_TEST_TMPDIR/terminal.json"
  desk pi >/dev/null
  [[ ! -e "$RECORDS/t9.json" ]] || fail "a terminal that is not a desk got a record"
  printf '{"labels":{"bercail.role":"agent","bercail.space":"sp1"}}\n' >"$BATS_TEST_TMPDIR/terminal.json"
  (unset HC_TERMINAL_ID; desk pi >/dev/null)
  [[ ! -e "$RECORDS/t9.json" ]] || fail "outside hc there is no address to key on"
  printf '#!/usr/bin/env bash\nexit 1\n' >"$BATS_TEST_TMPDIR/bin/hc.down"
  mv "$BATS_TEST_TMPDIR/bin/hc" "$BATS_TEST_TMPDIR/hc.up"
  mv "$BATS_TEST_TMPDIR/bin/hc.down" "$BATS_TEST_TMPDIR/bin/hc"
  chmod +x "$BATS_TEST_TMPDIR/bin/hc"
  hash -r
  [[ "$(desk pi)" == "pi "* ]] || fail "hc down must not stop the desk"
  [[ ! -e "$RECORDS/t9.json" ]] || fail "hc down: no record"
}

@test "hc status cannot overwrite the selected session" {
  arrange_record
  pi_sleeps
  status() { jq -cn --argjson r "$1" '{jsonrpc: "2.0", method: "event", params: {type: "status", terminal: "t9", data: {records: $r}}}'; }
  { status '{"0199-second":{"app":"pi"}}'; } >"$EVENTS"
  AGENT_LIFE=1 desk pi --session-id 0199-given >/dev/null
  expect "$(record .session)" '"0199-given"' "hc reports do not replace the selected session"
  printf '[bstack]\nenabled = false\n' >"$CONFIG"
  AGENT_LIFE=1 desk pi --session-id 0199-given >/dev/null
  expect "$(record .session)" '"0199-given"' "same identity rule without bstack"
}

@test "the record names the running agent" {
  local pid
  arrange_record
  pi_sleeps
  : >"$EVENTS"
  AGENT_LIFE=30 "$ROOT/bin/bercail-desk-agent" pi >/dev/null &
  pid=$!
  wait_for '[[ -f "$RECORDS/t9.json" && "$(record .pid 2>/dev/null)" == "$pid" ]]'
  kill "$pid"
  wait "$pid" 2>/dev/null || true
}

@test "the watcher goes when the agent does" {
  arrange_record
  pi_sleeps
  hc_streams_events
  AGENT_LIFE=1 desk pi >/dev/null
  wait_for '[[ -s "$BATS_TEST_TMPDIR/events.pid" ]] && ! kill -0 "$(cat "$BATS_TEST_TMPDIR/events.pid")" 2>/dev/null'
}

@test "the watcher keeps the record fresh while the agent runs" {
  local pid
  arrange_record
  pi_sleeps
  hc_streams_events
  AGENT_LIFE=30 "$ROOT/bin/bercail-desk-agent" pi >/dev/null &
  pid=$!
  wait_for '[[ "$(record .pid 2>/dev/null)" == "$pid" ]]'
  touch -d '2020-01-01' "$RECORDS/t9.json"
  wait_for '[[ "$(stat -c %Y "$RECORDS/t9.json")" -gt 1600000000 ]]'
  kill "$pid"
  wait "$pid" 2>/dev/null || true
}
