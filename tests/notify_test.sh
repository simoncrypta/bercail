#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

unset BASH_ENV
export __MISE_BASH_ENV_LOADED=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

export HOME="$TMP_DIR/home"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_STATE_HOME="$HOME/.local/state"
export HERDR_APP_BIN="$TMP_DIR/no-herdr-app"
export NOTIFY_RETRY_SLEEP=0
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
mkdir -p "$XDG_CONFIG_HOME/bercail/notify.d" "$TMP_DIR/bin"

# A fake curl: records the body and headers it was given, answers $CURL_CODE.
cat >"$TMP_DIR/bin/curl" <<EOF
#!/usr/bin/env bash
hdr=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -H) hdr="\${2#@}"; shift 2 ;;
    *) shift ;;
  esac
done
cat >>"$TMP_DIR/bodies.jsonl"
printf '\n' >>"$TMP_DIR/bodies.jsonl"
cat "\$hdr" >>"$TMP_DIR/headers.txt"
printf '%s' "\${CURL_CODE:-200}"
EOF
chmod +x "$TMP_DIR/bin/curl"
export NOTIFY_CURL="$TMP_DIR/bin/curl"

# shellcheck source=lib/notify.sh
source "$ROOT/lib/notify.sh"

sink="$XDG_CONFIG_HOME/bercail/notify.d/work-shep.toml"
cat >"$sink" <<'EOF'
url = "https://example.invalid/hook"
key = "secret-key"
auth = both
repos = myapp
notify = finished, blocked
EOF
chmod 600 "$sink"

# A checkout whose main worktree is named myapp, with a handoff record.
git init -q "$TMP_DIR/myapp"
git -C "$TMP_DIR/myapp" commit -q --allow-empty -m init
git -C "$TMP_DIR/myapp" worktree add -q -b feat "$TMP_DIR/myapp.feat"
desk="$TMP_DIR/myapp.feat"
mkdir -p "$XDG_STATE_HOME/agentic-dev"
jq -nc --arg p "$desk" '{path:$p, branch:"feat", issue:"myapp-1", stage:"start", harness:"claude"}' \
  >"$XDG_STATE_HOME/agentic-dev/handoffs.jsonl"

# One `hc events` line: every terminal, the desk with STATUS.
event() {
  jq -nc --arg s "$1" --arg cwd "$desk" '{seq:1, terminals:[
    {address:"t5", state:"live", status:{state:"working", app:"claude-code"}, labels:{"herdr.space":"sp1"}, cwd:"/"},
    {address:"t9", state:"live", status:(if $s == "" then null else {state:$s, app:"claude-code"} end),
     labels:{"bercail.role":"agent","bercail.space":"sp1"}, cwd:$cwd, title:"Beads\tissue myapp-1"}]}'
}

: >"$TMP_DIR/bodies.jsonl"
{ event done; event working; event working; event done; event idle; event working; event blocked; event blocked; event done; } \
  | notify_follow
kinds="$(jq -sc '[.[] | select(. != null) | .kind]' "$TMP_DIR/bodies.jsonl" 2>/dev/null)"
[[ "$kinds" == '["finished","blocked","finished"]' ]] || fail "kinds: $kinds"
printf 'PASS: a desk seen done first is not reported; working->done, blocked once, blocked->done are\n'

first="$(head -n 1 "$TMP_DIR/bodies.jsonl")"
jq -e --arg p "$desk" '
  .schema == "bercail.agent_status/v2" and .sink == "work-shep"
  and .agent.address == "t9" and .agent.status == "done" and .agent.previous_status == "working"
  and .agent.app == "claude-code" and .agent.title == "Beads issue myapp-1"
  and .space.id == "sp1" and .space.repo == "myapp" and .space.checkout_path == $p and .space.linked == true
  and .desk.issue == "myapp-1" and .desk.stage == "start" and .desk.branch == "feat"' <<<"$first" >/dev/null \
  || fail "payload: $first"
grep -q 'Authorization: Bearer secret-key' "$TMP_DIR/headers.txt" || fail "bearer header"
grep -q 'X-Automation-Key: secret-key' "$TMP_DIR/headers.txt" || fail "automation key header"
grep -q secret-key "$TMP_DIR/bodies.jsonl" && fail "the key must not be in the body"
printf 'PASS: the payload names the desk, its space and handoff; the key goes in headers only\n'

# An agent that reports no app: the empty field must not shift the others.
: >"$TMP_DIR/bodies.jsonl"
{ event working; event working | jq -c '.terminals[1].status = {state:"done"}'; } | notify_follow
jq -e --arg p "$desk" '.agent.app == null and .space.id == "sp1" and .space.checkout_path == $p' \
  "$TMP_DIR/bodies.jsonl" >/dev/null || fail "empty app shifted fields: $(cat "$TMP_DIR/bodies.jsonl")"
printf 'PASS: an empty field keeps the others in place\n'

# Filters: another repo is not sent.
sed -i 's/^repos = myapp/repos = other/' "$sink"
: >"$TMP_DIR/bodies.jsonl"
{ event working; event done; } | notify_follow
[[ ! -s "$TMP_DIR/bodies.jsonl" ]] || fail "a sink for another repo got: $(cat "$TMP_DIR/bodies.jsonl")"
sed -i 's/^repos = other/repos = myapp/' "$sink"
printf 'PASS: repos filter skips other repos\n'

# A readable key is refused.
chmod 644 "$sink"
: >"$TMP_DIR/bodies.jsonl"
{ event working; event done; } | notify_follow 2>"$TMP_DIR/err"
[[ ! -s "$TMP_DIR/bodies.jsonl" ]] || fail "insecure sink must not post"
grep -q 'chmod 600' "$TMP_DIR/err" || fail "insecure message: $(cat "$TMP_DIR/err")"
chmod 600 "$sink"
printf 'PASS: a group/other-readable key is not sent\n'

# A rejected key is recorded, and status shows it without secrets.
{ event working; event done; } | CURL_CODE=401 notify_follow 2>/dev/null
out="$(notify_status)"
printf '%s' "$out" | grep -q 'auth_failed=true' || fail "status: $out"
printf '%s' "$out" | grep -q 'secret-key\|example.invalid' && fail "status leaks: $out"
printf 'PASS: a rejected key is recorded and status prints no url or key\n'

out="$(notify_test work-shep)" || fail "test send: $out"
[[ "$out" == "work-shep HTTP 200" ]] || fail "test output: $out"
jq -e 'select(.kind == "test")' "$TMP_DIR/bodies.jsonl" >/dev/null || fail "test payload"
printf 'PASS: notify test sends a kind=test payload\n'

# notify add: url and key from stdin, written 0600, then tested; the key is never printed.
rm -f "$XDG_CONFIG_HOME/bercail/notify.d/"*.toml
: >"$TMP_DIR/headers.txt"
out="$(cd "$desk" && printf 'https://example.invalid/new\npasted-key\n' | notify_add bot-two --auth bearer 2>&1)" \
  || fail "notify add: $out"
added="$XDG_CONFIG_HOME/bercail/notify.d/bot-two.toml"
[[ "$(_notify_mode "$added")" == 600 ]] || fail "mode: $(_notify_mode "$added")"
[[ "$(notify_sink_value "$added" url)" == https://example.invalid/new ]] || fail "url: $(cat "$added")"
[[ "$(notify_sink_value "$added" repos)" == myapp ]] || fail "repos default: $(cat "$added")"
[[ "$(notify_sink_value "$added" notify)" == "finished, blocked" ]] || fail "notify default"
grep -q 'Authorization: Bearer pasted-key' "$TMP_DIR/headers.txt" || fail "add did not test with the key"
grep -q 'X-Automation-Key' "$TMP_DIR/headers.txt" && fail "--auth bearer sent the automation header"
printf '%s' "$out" | grep -q 'bot-two HTTP 200' || fail "add output: $out"
printf '%s' "$out" | grep -q pasted-key && fail "add printed the key: $out"
notify_status | grep -q '^- bot-two ' || fail "status does not list bot-two"
ls -A "$XDG_CONFIG_HOME/bercail/notify.d" | grep -q '^\.' && fail "temp file left behind"
printf 'PASS: notify add writes a 0600 sink from stdin, defaults repos to this checkout, and tests it\n'

# An existing sink is shown redacted and kept without --yes; --yes replaces it.
out="$(cd "$TMP_DIR" && printf 'https://example.invalid/other\nother-key\n' | notify_add bot-two 2>&1)" \
  && fail "replaced without --yes"
printf '%s' "$out" | grep -q 'url=https://example.invalid/\.\.\. key=set' || fail "redacted show: $out"
printf '%s' "$out" | grep -q 'pasted-key\|/new' && fail "existing values leaked: $out"
[[ "$(notify_sink_value "$added" url)" == https://example.invalid/new ]] || fail "kept sink changed"
out="$(cd "$TMP_DIR" && BERCAIL_NOTIFY_URL=https://example.invalid/env BERCAIL_NOTIFY_KEY=env-key \
  CURL_CODE=401 notify_add bot-two --yes </dev/null 2>&1)" && fail "a 401 must fail add"
printf '%s' "$out" | grep -q 'key or auth mode is wrong' || fail "401 hint: $out"
printf '%s' "$out" | grep -q 'env-key' && fail "401 output leaked the key: $out"
[[ "$(notify_sink_value "$added" repos)" == "" ]] || fail "outside a checkout repos should be all"
printf 'PASS: notify add asks before replacing, reads the environment, and names a 401 as a bad key\n'

notify_add bot-three --key oops </dev/null 2>/dev/null && fail "--key must be refused"
[[ ! -e "$XDG_CONFIG_HOME/bercail/notify.d/bot-three.toml" ]] || fail "--key wrote a sink"
printf 'PASS: notify add refuses a key on the command line\n'

# A stale `panes` line is dropped by the follower, keeping the mode.
printf 'panes = agent\n' >>"$added"
notify_drop_stale_keys "$added"
grep -q panes "$added" && fail "panes kept"
[[ "$(_notify_mode "$added")" == 600 ]] || fail "migration changed the mode"
printf 'PASS: the stale panes key is migrated away\n'
