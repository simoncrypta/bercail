#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

unset BASH_ENV
export __MISE_BASH_ENV_LOADED=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() {
  local expected="$1" actual="$2" msg="${3:-}"
  [[ "$expected" == "$actual" ]] || fail "${msg}: expected '$expected' got '$actual'"
}

export HOME="$TMP_DIR/home"
export XDG_CONFIG_HOME="$HOME/.config"
mkdir -p "$HOME"

# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=lib/detect.sh
source "$ROOT/lib/detect.sh"
# shellcheck source=lib/deps.sh
source "$ROOT/lib/deps.sh"
# shellcheck source=lib/config.sh
source "$ROOT/lib/config.sh"
# shellcheck source=lib/bstack.sh
source "$ROOT/lib/bstack.sh"

export INSTALL_SRC="$ROOT"
OPENCODE_CONFIG_DIR="$XDG_CONFIG_HOME/opencode"
YES=1
DRY_RUN=0

# A stand-in opencode: v2, with the integrations in $FAKE_CONNECTED connected.
FAKE_BIN="$TMP_DIR/bin"
mkdir -p "$FAKE_BIN"
cat >"$FAKE_BIN/opencode" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "--version "*) echo "opencode v2.2.5" ;;
  "auth list")
    printf '['; sep=""
    for id in ${FAKE_CONNECTED:-}; do printf '%s{"id":"%s","connections":[{"type":"credential"}]}' "$sep" "$id"; sep=","; done
    printf ']\n' ;;
  "models "*)
    printf '%s\n' claude-agent/opus claude-agent/sonnet openai/gpt-6.1-sol openai/gpt-6 openai/gpt-6.1-mini \
      xai/grok-5 xai/grok-5-mini xai/grok-4.7 xai/grok-4.20-multi-agent-0309 ;;
  "api get")
    [[ -z "${FAKE_API_DOWN:-}" ]] || exit 1
    printf '%s\n' '{"data":[
      {"providerID":"claude-agent","id":"opus","variants":[{"id":"low"},{"id":"high"},{"id":"max"}]},
      {"providerID":"xai","id":"grok-5","variants":[{"id":"low"},{"id":"high"},{"id":"xhigh"}]},
      {"providerID":"xai","id":"grok-5-mini","variants":[]}]}' ;;
  *) exit 2 ;;
esac
SH
chmod +x "$FAKE_BIN/opencode"
# A stand-in pi: the logins in $FAKE_PI_READY are ready. Refuses --credentials.
cat >"$FAKE_BIN/pi" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *--credentials* ]]; then echo "credentials must never be requested" >&2; exit 9; fi
case "$1" in
  --version) echo "1.5.0" ;;
  auth)
    for id in ${FAKE_PI_READY:-}; do
      if [[ "$*" == *"--provider $id "* ]]; then printf '{"status":"ready","provider":"%s"}\n' "$id"; exit 0; fi
    done
    printf '{"status":"not_ready"}\n'; exit 1 ;;
  --offline)
    [[ "$2" == --list-models ]] || exit 2
    cat <<'EOF'
provider   model                       context  max-out  thinking  images
anthropic  claude-opus-4-8             1M       128K     yes       yes
anthropic  claude-opus-4-5-20251101    200K     64K      yes       yes
anthropic  claude-opus-5               1M       128K     yes       yes
anthropic  claude-opus-5-5             1M       128K     yes       yes
anthropic  claude-sonnet-5-5           1M       128K     yes       yes
openai     gpt-6-sol                   272K     128K     yes       yes
openai     gpt-6.1-sol                 272K     128K     yes       yes
openai     gpt-6.1-terra               272K     128K     yes       yes
openai-codex gpt-6.1                   272K     128K     yes       yes
xai        grok-4.20-0309-reasoning    2M       30K      yes       yes
xai        grok-4.6                    500K     500K     yes       yes
xai        grok-4.7                    500K     500K     yes       yes
xai        grok-plain                  500K     500K     no        yes
EOF
    ;;
  *) exit 2 ;;
esac
SH
chmod +x "$FAKE_BIN/pi"
export PATH="$FAKE_BIN:$PATH"

reset_home() {
  rm -rf "$HOME"
  mkdir -p "$HOME"
  BSTACK_STATE_LOADED=0
}

# JSONC -> JSON for jq: drop whole-line comments and trailing commas.
jsonc_to_json() {
  sed -E 's#^[[:space:]]*//.*$##; s#,[[:space:]]*//.*$#,#' "$1" | tr '\n' ' ' | sed -E 's/,[[:space:]]*([]}])/\1/g'
}

test_toml_get_set() {
  reset_home
  local f="$TMP_DIR/t.toml"
  cat >"$f" <<'EOF'
[agent]
command = "cursor-agent"

[bstack]
claude = "claude-agent/opus#high"   # keeps the variant
enabled = true # bare value
EOF
  assert_eq "claude-agent/opus#high" "$(_bstack_toml_get bstack claude "$f")" "quoted value keeps #"
  assert_eq "true" "$(_bstack_toml_get bstack enabled "$f")" "bare value drops comment"
  assert_eq "" "$(_bstack_toml_get bstack command "$f")" "keys are per section"
  _bstack_toml_set bstack enabled false "$f"
  _bstack_toml_set bstack gpt '"openai/gpt-6.1-sol"' "$f"
  _bstack_toml_set agent command '"opencode"' "$f"
  _bstack_toml_set layout review '"tuicr"' "$f"
  assert_eq "false" "$(_bstack_toml_get bstack enabled "$f")" "set replaces"
  assert_eq "openai/gpt-6.1-sol" "$(_bstack_toml_get bstack gpt "$f")" "set adds to the section"
  assert_eq "opencode" "$(_bstack_toml_get agent command "$f")" "set in another section"
  assert_eq "tuicr" "$(_bstack_toml_get layout review "$f")" "set adds a missing section"
  assert_eq 1 "$(grep -c '^enabled' "$f")" "no duplicate key"
  assert_eq 1 "$(grep -c '^\[bstack\]' "$f")" "no duplicate section"
  printf 'PASS: [bstack] toml get/set keeps variants, sections, and comments apart\n'
}

test_new_install_defaults() {
  reset_home
  BSTACK_NEW_INSTALL=1 default_user_config >"$TMP_DIR/on.toml"
  assert_eq "opencode" "$(_bstack_toml_get agent command "$TMP_DIR/on.toml")" "new install desk agent"
  assert_eq "true" "$(_bstack_toml_get bstack enabled "$TMP_DIR/on.toml")" "new install turns bstack on"
  assert_eq "pi" "$(_bstack_toml_get bstack harness "$TMP_DIR/on.toml")" "new config selects Pi"
  assert_eq "grok" "$(_bstack_toml_get bstack build "$TMP_DIR/on.toml")" "build role default"
  BSTACK_NEW_INSTALL=0 default_user_config >"$TMP_DIR/off.toml"
  assert_eq "cursor-agent" "$(_bstack_toml_get agent command "$TMP_DIR/off.toml")" "--no-bstack desk agent"
  grep -q '^\[bstack\]' "$TMP_DIR/off.toml" && fail "--no-bstack writes no [bstack]"
  AGENTIC_DEV_USER_CONFIG="$TMP_DIR/off.toml" bstack_enabled && fail "--no-bstack is off"
  printf 'PASS: new installs default to bstack; --no-bstack keeps cursor-agent\n'
}

write_config() {
  mkdir -p "$(dirname "$AGENTIC_DEV_USER_CONFIG")"
  cat >"$AGENTIC_DEV_USER_CONFIG"
}

test_roles_resolve() {
  reset_home
  write_config <<'EOF'
[bstack]
enabled = true
claude = "claude-agent/opus#high"
gpt = "openai/gpt-6.1-sol"
grok = ""
build = "grok"
judge = "xai/grok-5#fast"
EOF
  assert_eq "claude-agent/opus#high" "$(bstack_role_model lead)" "lead defaults to claude"
  assert_eq "openai/gpt-6.1-sol" "$(bstack_role_model build)" "build on an unset grok falls to gpt"
  _bstack_toml_set bstack claude '""'
  _bstack_toml_set bstack gpt '""'
  assert_eq "" "$(bstack_role_model lead)" "no family with a model: the session's model"
  assert_eq "xai/grok-5#fast" "$(bstack_role_model judge)" "a full id is used as is"
  printf 'PASS: roles resolve through families or full ids\n'
}

test_deploy_renders_agents() {
  reset_home
  write_config <<'EOF'
[bstack]
enabled = true
claude = "claude-agent/opus#high"
gpt = "openai/gpt-6.1-sol"
grok = ""
lead = "claude"
build = "grok"
judge = "gpt"
council = true
EOF
  deploy_bstack >/dev/null 2>&1 || fail "deploy_bstack failed"
  local oc="$OPENCODE_CONFIG_DIR" rel
  for rel in "${BSTACK_RENDERED[@]}" opencode.jsonc bstack/instructions.md; do
    [[ -f "$oc/$rel" ]] || fail "missing $rel"
  done
  grep -qx 'model: claude-agent/opus#high' "$oc/agents/bstack.md" || fail "lead model: $(cat "$oc/agents/bstack.md")"
  grep -qx 'model: claude-agent/opus#high' "$oc/agents/bstack-pr-review.md" || fail "pr-review follows the lead"
  grep -qx 'model: openai/gpt-6.1-sol' "$oc/agents/bstack-judge.md" || fail "judge model"
  grep -qx 'model: openai/gpt-6.1-sol' "$oc/agents/bstack-builder.md" || fail "builder with no grok falls to gpt"
  grep -q '@' "$oc/agents/bstack-builder.md" "$oc/agents/bstack.md" "$oc/opencode.jsonc" && fail "unrendered token"
  [[ -f "$oc/agents/bstack-council-claude.md" && -f "$oc/agents/bstack-council-gpt.md" ]] || fail "council panel"
  [[ ! -e "$oc/agents/bstack-council-grok.md" ]] || fail "no council seat without a grok model"
  grep -q 'on gpt\.' "$oc/agents/bstack-council-gpt.md" || fail "council family"
  head -1 "$oc/agents/bstack.md" | grep -qx -- '---' || fail "frontmatter starts the agent file"
  jsonc_to_json "$oc/opencode.jsonc" | jq -e '
    .default_agent == "bstack" and .model == "claude-agent/opus"
    and .instructions == [$dir + "/bstack/instructions.md"]
    and ([.permissions[] | select(.resource == "git commit *")] | length == 1)' --arg dir "$oc" >/dev/null \
    || fail "opencode.jsonc: $(cat "$oc/opencode.jsonc")"
  printf 'PASS: deploy renders agents, the council panel, and opencode.jsonc\n'
}

test_deploy_keeps_their_files() {
  reset_home
  write_config <<'EOF'
[bstack]
enabled = true
EOF
  mkdir -p "$OPENCODE_CONFIG_DIR/commands"
  printf '{ "model": "mine/model" }\n' >"$OPENCODE_CONFIG_DIR/opencode.jsonc"
  printf 'my own council\n' >"$OPENCODE_CONFIG_DIR/commands/council.md"
  local out
  out="$(deploy_bstack 2>&1)" || fail "deploy_bstack failed"
  grep -qx '{ "model": "mine/model" }' "$OPENCODE_CONFIG_DIR/opencode.jsonc" || fail "their opencode.jsonc changed"
  grep -qx 'my own council' "$OPENCODE_CONFIG_DIR/commands/council.md" || fail "their command changed"
  grep -q 'default_agent' <<<"$out" || fail "should say what to add: $out"
  [[ -f "$OPENCODE_CONFIG_DIR/agents/bstack.md" ]] || fail "bstack agents still deploy"
  grep -q '^model:' "$OPENCODE_CONFIG_DIR/agents/bstack.md" && fail "no model anywhere: the agent inherits (no model line)"
  printf 'PASS: deploy leaves files without the bstack marker alone\n'
}

test_off_removes_only_ours() {
  reset_home
  write_config <<'EOF'
[bstack]
enabled = true
claude = "claude-agent/opus"
council = true
EOF
  deploy_bstack >/dev/null 2>&1
  printf '{}\n' >"$OPENCODE_CONFIG_DIR/opencode.json"
  printf 'mine\n' >"$OPENCODE_CONFIG_DIR/agents/reviewer.md"
  bstack_off >/dev/null 2>&1
  assert_eq "false" "$(_bstack_toml_get bstack enabled)" "off sets enabled"
  [[ ! -e "$OPENCODE_CONFIG_DIR/agents/bstack.md" && ! -e "$OPENCODE_CONFIG_DIR/opencode.jsonc" ]] \
    || fail "off removes bstack's files"
  [[ ! -e "$OPENCODE_CONFIG_DIR/agents/bstack-council-claude.md" && ! -d "$OPENCODE_CONFIG_DIR/bstack" ]] \
    || fail "off removes the council and instructions"
  [[ -f "$OPENCODE_CONFIG_DIR/opencode.json" && -f "$OPENCODE_CONFIG_DIR/agents/reviewer.md" ]] \
    || fail "off keeps the person's opencode files"
  deploy_bstack >/dev/null 2>&1
  [[ ! -e "$OPENCODE_CONFIG_DIR/agents/bstack.md" ]] || fail "update with bstack off deploys nothing"
  printf 'PASS: bstack off removes only what bstack manages\n'
}

test_council_seats_need_the_setting() {
  reset_home
  local oc="$OPENCODE_CONFIG_DIR" config='[bstack]
enabled = true
claude = "claude-agent/opus#high"
gpt = "openai/gpt-6.1-sol"'
  write_config <<<"$config"
  deploy_bstack >/dev/null 2>&1 || fail "deploy without council"
  [[ ! -e "$oc/agents/bstack-council-claude.md" && ! -e "$oc/agents/bstack-council-gpt.md" ]] \
    || fail "seats rendered with council unset"
  [[ -f "$oc/commands/council.md" ]] || fail "/council must stay callable with the seats off"

  write_config <<<"$config"$'\ncouncil = true'
  deploy_bstack >/dev/null 2>&1 || fail "deploy with council"
  [[ -f "$oc/agents/bstack-council-claude.md" && -f "$oc/agents/bstack-council-gpt.md" ]] || fail "council = true renders seats"

  # Turning it off takes back bstack's seats and leaves one the person owns.
  printf 'my own reviewer\n' >"$oc/agents/bstack-council-gpt.md"
  write_config <<<"$config"$'\ncouncil = false'
  deploy_bstack >/dev/null 2>&1 || fail "deploy with council = false"
  [[ ! -e "$oc/agents/bstack-council-claude.md" ]] || fail "council = false removes bstack's seat"
  grep -qx 'my own reviewer' "$oc/agents/bstack-council-gpt.md" || fail "their seat changed"
  printf 'PASS: council seats render only with [bstack] council = true; /council stays\n'
}

test_ready_verifies_without_the_council() {
  local ready="$ROOT/bstack/commands/ready.md" prev=0 n step
  if grep -qi council "$ready"; then fail "ready.md must not run the council"; fi
  for step in 'tests that cover the diff' 'verify skill above' 'Run any formal check' 'bstack-judge' '`unslop`' 'git add' 'exit code and evidence path'; do
    n="$(grep -nF -- "$step" "$ready" | head -1 | cut -d: -f1)"
    ((${n:-0} > prev)) || fail "ready.md: '$step' is missing or out of order"
    prev="$n"
  done
  grep -qF 'does the diff match the issue?' "$ready" || fail "the judge gets the intent question"
  if grep -q 'settl' "$ROOT/bstack/agents/bstack-judge.md"; then fail "the judge no longer settles disputes"; fi
  if grep -q 'bstack-judge' "$ROOT/skills/council/SKILL.md"; then fail "the council must not call the judge"; fi
  grep -q 'verify-<repo>' "$ROOT/skills/bstack/SKILL.md" || fail "the review playbook proves with the verify skill"
  printf 'PASS: /ready runs tests, verify, formal checks, the judge, unslop, stage, report; no council\n'
}

test_council_keeps_only_rerun_findings() {
  local skill="$ROOT/skills/council/SKILL.md" agent="$ROOT/bstack/agents/bstack-council.md"
  grep -qF 'Prove each finding with a run' "$skill" || fail "skill: a finding needs a run"
  grep -qF 'Prove each finding with a run' "$agent" || fail "agent: a finding needs a run"
  grep -qF 'Run its command yourself' "$skill" || fail "skill: the lead reruns"
  grep -q 'style, naming, or YAGNI' "$skill" || fail "skill: style findings are dropped"
  if grep -qF '`unverified`' "$agent"; then fail "agent: nothing is marked unverified"; fi
  grep -qF 'There is no `unverified` list' "$skill" || fail "skill: unverified findings are dropped"
  grep -qF '[bstack] council' "$skill" || fail "skill: says what to do with no seats"
  printf 'PASS: the council reports only findings a run proved and a rerun confirmed\n'
}

test_verify_skill_shape() {
  local dir="$ROOT/.agents/skills/verify-bercail" run step
  head -2 "$dir/SKILL.md" | grep -qx 'name: verify-bercail' || fail "verify skill frontmatter"
  run="$dir/run.sh"
  [[ -x "$run" ]] || fail "run.sh is executable"
  bash -n "$run" || fail "run.sh parses"
  for step in 'export HOME=' 'bercail" doctor' 'desk restore --dry-run' 'handoff-spawn" --info' 'bstack status' '.bercail/verify' "trap 'rm -rf"; do
    grep -qF -- "$step" "$run" || fail "run.sh is missing: $step"
  done
  printf 'PASS: verify-bercail covers temp HOME, doctor, restore, info, status, evidence, cleanup\n'
}

test_on_switches_stock_desk_agent() {
  reset_home
  write_config <<'EOF'
[agent]
command = "cursor-agent"
EOF
  bstack_on >/dev/null 2>&1
  assert_eq "opencode" "$(_bstack_toml_get agent command)" "on moves the stock desk agent to opencode"
  [[ -f "$OPENCODE_CONFIG_DIR/agents/bstack.md" ]] || fail "on deploys"
  write_config <<'EOF'
[agent]
command = "claude"
EOF
  bstack_on >/dev/null 2>&1
  assert_eq "claude" "$(_bstack_toml_get agent command)" "on keeps a desk agent the person picked"
  printf 'PASS: bstack on takes over only the stock desk agent\n'
}

test_setup_auto_models() {
  reset_home
  write_config <<'EOF'
[agent]
command = "cursor-agent"

[bstack]
council = true
EOF
  FAKE_CONNECTED="claude-agent xai" bstack_setup >"$TMP_DIR/setup.log" 2>&1 || fail "setup: $(cat "$TMP_DIR/setup.log")"
  grep -q 'model' "$TMP_DIR/setup.log" && grep -q 'Pick' "$TMP_DIR/setup.log" && fail "setup must not ask about models"
  assert_eq "" "$(_bstack_toml_get bstack claude)" "setup pins nothing"
  assert_eq "" "$(_bstack_toml_get bstack build)" "setup leaves roles to the person"
  assert_eq "opencode" "$(_bstack_toml_get agent command)" "desk agent"
  grep -qx 'model: claude-agent/opus#high' "$OPENCODE_CONFIG_DIR/agents/bstack.md" || fail "lead is auto claude"
  grep -qx 'model: xai/grok-5#high' "$OPENCODE_CONFIG_DIR/agents/bstack-builder.md" || fail "build is auto grok (not mini), at high effort"
  [[ -f "$OPENCODE_CONFIG_DIR/agents/bstack-council-grok.md" ]] || fail "grok seat"
  [[ ! -e "$OPENCODE_CONFIG_DIR/agents/bstack-council-gpt.md" ]] || fail "no gpt seat"
  grep -qx 'grok=xai/grok-5#high' "$BSTACK_RESOLVED" || fail "resolved file for handoff: $(cat "$BSTACK_RESOLVED")"
  grep -q 'xai/grok-5#high (auto)' "$TMP_DIR/setup.log" || fail "status says auto: $(cat "$TMP_DIR/setup.log")"
  FAKE_API_DOWN=1 FAKE_CONNECTED="claude-agent xai" bstack_load_state reload
  assert_eq "xai/grok-5#high" "$(FAKE_CONNECTED="claude-agent xai" bstack_resolve_model grok)" \
    "a server that doesn't answer keeps the last variants"

  # Connecting ChatGPT later: an update picks it up, and doctor says when it's due.
  doctor_bstack >/dev/null 2>&1 || true
  local out
  out="$(FAKE_CONNECTED="claude-agent xai openai" doctor_bstack)" && fail "doctor: models changed since deploy"
  grep -q 'stale  bstack models' <<<"$out" || fail "doctor stale: $out"
  FAKE_CONNECTED="claude-agent xai openai" deploy_bstack >/dev/null 2>&1
  [[ -f "$OPENCODE_CONFIG_DIR/agents/bstack-council-gpt.md" ]] || fail "gpt seat after update"

  # A pinned model stays, even on a plan that is not connected.
  _bstack_toml_set bstack grok '"openrouter/x-ai/grok-5"'
  FAKE_CONNECTED="openai" bstack_setup >"$TMP_DIR/setup.log" 2>&1 || fail "setup: $(cat "$TMP_DIR/setup.log")"
  assert_eq "openrouter/x-ai/grok-5" "$(_bstack_toml_get bstack grok)" "pinned grok kept"
  assert_eq "openai/gpt-6.1-sol" "$(bstack_role_model lead)" "lead falls to gpt with claude disconnected"
  assert_eq "openrouter/x-ai/grok-5" "$(bstack_role_model build)" "build uses the pinned grok"
  grep -qx 'model: openai/gpt-6.1-sol' "$OPENCODE_CONFIG_DIR/agents/bstack-pr-review.md" \
    || fail "pr-review follows the lead after setup: $(grep '^model:' "$OPENCODE_CONFIG_DIR/agents/bstack-pr-review.md")"
  grep -q 'openrouter/x-ai/grok-5 (pinned' "$TMP_DIR/setup.log" || fail "status says pinned: $(cat "$TMP_DIR/setup.log")"
  printf 'PASS: setup picks models automatically; pinned ones stay; doctor flags a due update\n'
}

test_handoff_bstack_stage() {
  reset_home
  write_config <<'EOF'
[bstack]
claude = "claude-agent/opus#high"
gpt = "openai/gpt-6.1-sol"
lead = "gpt"
EOF
  local spawn="$ROOT/skills/handoff/scripts/handoff-spawn" wt="$TMP_DIR/wt" out
  mkdir -p "$wt"
  out="$(HANDOFF_BD_BIN=/nonexistent "$spawn" --stage bstack --issue bc-1x --worktree "$wt" --dry-run)"
  jq -e '.binary == "opencode" and .model == "openai/gpt-6.1-sol"
    and .command[0:6] == ["opencode","run","--format","json","--agent","bstack"]
    and (.command | index("--auto") | not) and (.command[-1] | startswith("Your job is beads issue bc-1x."))' <<<"$out" >/dev/null \
    || fail "bstack stage (no --auto: asks are rejected headless): $out"
  out="$(HANDOFF_BD_BIN=/nonexistent "$spawn" --stage autopilot --issue bc-1x --worktree "$wt" --dry-run)"
  jq -e '.command[0:6] == ["opencode","run","--format","json","--agent","bstack-autopilot"]
    and .model == "openai/gpt-6.1-sol" and (.command | index("--auto") | not)' <<<"$out" >/dev/null \
    || fail "autopilot stage runs bstack-autopilot on the lead: $out"
  if HANDOFF_BD_BIN=/nonexistent "$spawn" --stage autopilot --branch x --issue bc-1x >/dev/null 2>&1; then
    fail "autopilot is headless only"
  fi
  out="$(HANDOFF_BD_BIN=/nonexistent "$spawn" --stage start --binary opencode --issue bc-1x --worktree "$wt" --dry-run)"
  jq -e '.model == "claude-agent/opus#high"' <<<"$out" >/dev/null || fail "start through opencode is claude: $out"
  out="$(HANDOFF_BD_BIN=/nonexistent "$spawn" --stage bstack --issue bc-1x --worktree "$wt" --resume ses_9zX --dry-run)"
  jq -e '.resume and (.command | index("--session")) and (.command | index("ses_9zX"))' <<<"$out" >/dev/null \
    || fail "resume: $out"
  if HANDOFF_BD_BIN=/nonexistent "$spawn" --stage bstack --issue bc-1x --worktree "$wt" --resume 1234 --dry-run >/dev/null 2>&1; then
    fail "a non-opencode session id must be refused"
  fi
  # shellcheck source=skills/handoff/scripts/handoff-stages.sh
  source "$ROOT/skills/handoff/scripts/handoff-stages.sh"
  printf '{"type":"step_start","sessionID":"ses_abc"}\n{"type":"text","sessionID":"ses_abc"}\n' >"$TMP_DIR/oc.log"
  assert_eq "ses_abc" "$(handoff_opencode_session_id "$TMP_DIR/oc.log")" "session id from run JSON"
  assert_eq "openai/gpt-6.1-sol" "$(handoff_bstack_model build)" "handoff build falls through like bstack status"
  assert_eq "" "$(handoff_bstack_model grok)" "a family named directly does not fall through"
  mkdir -p "$(dirname "$BSTACK_RESOLVED")"
  printf 'claude=claude-agent/opus#high\ngpt=\ngrok=xai/grok-4.7\n' >"$BSTACK_RESOLVED"
  assert_eq "xai/grok-4.7" "$(handoff_bstack_model build)" "handoff reads an auto model from the last deploy"
  assert_eq "xai/grok-4.7" "$(handoff_bstack_model grok)" "auto family named directly"
  printf 'PASS: handoff stage bstack runs opencode with the configured model and resumes by session\n'
}

test_doctor() {
  reset_home
  write_config <<'EOF'
[bstack]
enabled = false
EOF
  doctor_bstack | grep -q 'off  bstack' || fail "doctor off"
  write_config <<'EOF'
[bstack]
enabled = true
claude = "claude-agent/opus"
EOF
  FAKE_CONNECTED="" deploy_bstack >/dev/null 2>&1
  local out
  out="$(FAKE_CONNECTED="" doctor_bstack)" && fail "doctor must fail with no subscription: $out"
  grep -q 'none of Claude, ChatGPT, X' <<<"$out" || fail "doctor says what is missing: $out"
  out="$(FAKE_CONNECTED="claude-agent exa" doctor_bstack)" || fail "doctor ok: $out"
  grep -q 'subscriptions: claude-agent$' <<<"$out" || fail "doctor lists only plans: $out"
  printf 'PASS: doctor reports bstack off, missing subscriptions, and a working setup\n'
}

test_pick_model() {
  local m='xai/grok-4.20-0309-reasoning
xai/grok-4.20-multi-agent-0309
xai/grok-4.3
xai/grok-4.7
xai/grok-build-0.1
openai/gpt-6-sol
openai/gpt-6.1-sol
openai/gpt-6.1-sol-fast
claude-agent/opus
claude-agent/claude-opus-5'
  assert_eq "xai/grok-4.7" "$(_bstack_pick_model grok <<<"$m")" "a dated 4.20 build is not newer than grok-4.7"
  assert_eq "openai/gpt-6.1-sol" "$(_bstack_pick_model gpt <<<"$m")" "newest sol"
  local BSTACK_VARIANTS=""
  assert_eq "xai/grok-4.7" "$(_bstack_pick_model grok <<<"$m")" "a dated 4.20 build is not newer than grok-4.7"
  assert_eq "openai/gpt-6.1-sol" "$(_bstack_pick_model gpt <<<"$m")" "newest sol, no variant without the server's list"
  assert_eq "claude-agent/opus#high" "$(_bstack_pick_model claude <<<"$m")" "the opus alias tracks the newest Opus"
  printf 'PASS: auto recommends the newest plain release per provider\n'
}

test_pick_effort() {
  reset_home
  mkdir -p "$(dirname "$AGENTIC_DEV_USER_CONFIG")"
  local m='xai/grok-4.7
openai/gpt-6.1-sol
claude-agent/opus'
  local BSTACK_VARIANTS='xai/grok-4.7 low,medium,high,xhigh
openai/gpt-6.1-sol low,medium,high,xhigh,max
claude-agent/opus low,medium,high,xhigh,max'
  assert_eq "openai/gpt-6.1-sol#high" "$(_bstack_pick_model gpt <<<"$m")" "high by default"
  printf '[bstack]\neffort = "max"\n' >"$AGENTIC_DEV_USER_CONFIG"
  assert_eq "xai/grok-4.7#xhigh" "$(_bstack_pick_model grok <<<"$m")" "grok has no max: the next level down"
  assert_eq "claude-agent/opus#max" "$(_bstack_pick_model claude <<<"$m")" "claude at max"
  printf '[bstack]\neffort = "none"\n' >"$AGENTIC_DEV_USER_CONFIG"
  assert_eq "openai/gpt-6.1-sol" "$(_bstack_pick_model gpt <<<"$m")" "none: the provider default"
  printf 'PASS: auto adds the [bstack] effort variant each model offers\n'
}

test_installed_cli_reads_its_source() {
  reset_home
  local clone="$TMP_DIR/clone"
  mkdir -p "$clone/config" "$(dirname "$AGENTIC_DEV_SOURCE_PATH_FILE")"
  touch "$clone/install.sh"
  mkdir -p "$TMP_DIR/nowhere/lib"
  printf '%s\n' "$clone" >"$AGENTIC_DEV_SOURCE_PATH_FILE"
  assert_eq "$clone" "$(script_dir() { printf '%s' "$TMP_DIR/nowhere/lib"; }; INSTALL_SRC='' install_src_dir)" \
    "the installed CLI uses the recorded clone, not master"
  rm -f "$AGENTIC_DEV_SOURCE_PATH_FILE"
  assert_eq "https://bercail.dev" "$(script_dir() { printf '%s' "$TMP_DIR/nowhere/lib"; }; INSTALL_SRC='' install_src_dir)" \
    "no recorded source: remote"
  printf 'PASS: the installed CLI reads files from the tree it was installed from\n'
}

PI_DIR() { printf '%s' "$HOME/.local/share/bercail/pi"; }
PI_TEMPLATES() { printf '%s' "$XDG_CONFIG_HOME/herdr-core/templates"; }

write_pi_config() {
  write_config <<'EOF'
[bstack]
enabled = true
harness = "pi"
EOF
}

test_pi_models() {
  reset_home
  write_pi_config
  export FAKE_PI_READY="anthropic openai xai"
  bstack_load_state reload
  assert_eq "anthropic/claude-opus-5-5#high" "$(bstack_resolve_model claude)" "newest plain opus"
  assert_eq "openai/gpt-6.1-sol#high" "$(bstack_resolve_model gpt)" "newest sol"
  assert_eq "xai/grok-4.7#high" "$(bstack_resolve_model grok)" "a dated 4.20 build is not newer"
  assert_eq "anthropic/claude-opus-5-5:high" "$(_bstack_pi_model_id "$(bstack_role_model lead)")" "#high maps to :high"
  assert_eq "xai/grok-4.7#high" "$(bstack_role_model build)" "build defaults to grok"

  FAKE_PI_READY="anthropic openai-codex" bstack_load_state reload
  assert_eq "openai-codex/gpt-6.1#high" "$(FAKE_PI_READY="anthropic openai-codex" bstack_resolve_model gpt)" "openai-codex stands in for openai"
  assert_eq "" "$(FAKE_PI_READY="anthropic openai-codex" bstack_resolve_model grok)" "no xai login: no grok"
  assert_eq "openai-codex/gpt-6.1#high" "$(FAKE_PI_READY="anthropic openai-codex" bstack_role_model build)" "build falls through to the next family with a login"

  FAKE_PI_READY="" bstack_load_state reload
  assert_eq "" "$(FAKE_PI_READY="" bstack_role_model lead)" "no login at all: Pi's default"

  _bstack_toml_set bstack effort '"none"'
  FAKE_PI_READY="anthropic" bstack_load_state reload
  assert_eq "anthropic/claude-opus-5-5" "$(FAKE_PI_READY="anthropic" bstack_resolve_model claude)" "effort none: no suffix"
  _bstack_toml_set bstack effort '"max"'
  assert_eq "anthropic/claude-opus-5-5#max" "$(FAKE_PI_READY="anthropic" bstack_resolve_model claude)" "effort max"
  local BSTACK_MODELS BSTACK_VARIANTS
  BSTACK_MODELS="xai/grok-plain"
  BSTACK_VARIANTS="xai/grok-plain "
  assert_eq "" "$(_bstack_variant xai/grok-plain)" "a model that does not think gets no level"
  unset FAKE_PI_READY
  printf 'PASS: Pi families resolve from the catalog and auth check; variants map to :level\n'
}

test_pi_deploy() {
  reset_home
  write_pi_config
  mkdir -p "$HOME/.pi/agent"
  printf '{"defaultModel":"mine"}\n' >"$HOME/.pi/agent/settings.json"
  printf '{"token":"secret"}\n' >"$HOME/.pi/agent/auth.json"
  export FAKE_PI_READY="anthropic xai"
  deploy_bstack >"$TMP_DIR/pi.log" 2>&1 || fail "deploy: $(cat "$TMP_DIR/pi.log")"
  local p t rel
  p="$(PI_DIR)"
  t="$(PI_TEMPLATES)"
  for rel in instructions.md agents/bstack-builder.md agents/bstack-judge.md \
    agents/bstack-autopilot.md agents/bstack-pr-review.md agents/bstack-council-claude.md agents/bstack-council-grok.md; do
    [[ -f "$p/$rel" ]] || fail "missing $rel"
  done
  for rel in ready council handoff autopilot how why unslop pr-review bstack-setup; do
    [[ -f "$p/prompts/$rel.md" ]] || fail "missing prompt $rel"
    grep -q '!`' "$p/prompts/$rel.md" && fail "Pi templates have no !cmd: $rel"
    grep -q '^agent:' "$p/prompts/$rel.md" && fail "Pi templates have no agent key: $rel"
    head -1 "$p/prompts/$rel.md" | grep -qx -- '---' || fail "frontmatter starts $rel"
  done
  grep -rq '@[a-z_]*@' "$p/prompts" "$p/agents/bstack-builder.md" "$p/instructions.md" && fail "unrendered token"
  grep -q "$p/agents/bstack-pr-review.md" "$p/prompts/pr-review.md" || fail "pr-review names its brief"
  head -1 "$p/agents/bstack-pr-review.md" | grep -q -- '^---$' && fail "a brief has no opencode frontmatter"
  grep -q 'You review someone else' "$p/agents/bstack-pr-review.md" || fail "pr-review keeps its body"
  grep -q 'one reviewer on a council' "$p/agents/bstack-council-claude.md" || fail "council keeps its body"
  grep -q 'Desks only' "$p/instructions.md" || fail "instructions require a desk"
  grep -rqi 'headless' "$p/prompts" "$p/instructions.md" && fail "Pi has no headless fallback"
  grep -q -- '--branch NAME --stage bstack --issue ID' "$p/prompts/handoff.md" || fail "handoff opens a desk"
  [[ ! -d "$p/extensions" ]] || fail "Pi deploys no extensions"
  grep -q 'bercail.role=agent' "$p/instructions.md" || fail "instructions warn off the desk's label"

  for rel in bstack-builder bstack-judge bstack-autopilot bstack-council-claude bstack-council-grok; do
    [[ -f "$t/$rel.md" ]] || fail "missing template $rel"
    sed -n 1p "$t/$rel.md" | grep -qx -- '---' || fail "frontmatter starts $rel"
    sed -n 2p "$t/$rel.md" | grep -qx "name: $rel" || fail "name $rel"
    sed -n 3p "$t/$rel.md" | grep -q "managed by bercail (bstack)" || fail "marker in the description of $rel"
    sed -n 5p "$t/$rel.md" | grep -qx -- '---' || fail "frontmatter holds only key: value in $rel"
    grep -q ' pi ' "$t/$rel.md" || fail "$rel runs pi"
    grep -Eq -- ' (-e|--extension)( |$)' "$t/$rel.md" && fail "$rel loads no bercail extension"
    grep -q -- "--prompt-template $p/prompts" "$t/$rel.md" || fail "--prompt-template in $rel"
    grep -q -- "--append-system-prompt $p/instructions.md" "$t/$rel.md" || fail "instructions in $rel"
    grep -q -- '--skill .*/skills/council' "$t/$rel.md" || fail "--skill in $rel"
  done
  [[ ! -e "$t/bstack-council-gpt.md" ]] || fail "no gpt seat without a login"
  grep -q '^command: env BERCAIL_ROLE=builder pi --model xai/grok-4.7:high ' "$t/bstack-builder.md" || fail "builder: $(cat "$t/bstack-builder.md")"
  grep -q '^command: env BERCAIL_ROLE=judge pi --model anthropic/claude-opus-5-5:high ' "$t/bstack-judge.md" || fail "judge"
  grep -q '^command: env BERCAIL_ROLE=autopilot pi --model anthropic/claude-opus-5-5:high ' "$t/bstack-autopilot.md" || fail "autopilot"
  grep -q '^command: env BERCAIL_ROLE=council pi --model xai/grok-4.7:high ' "$t/bstack-council-grok.md" || fail "council seat on its own family"
  grep -q -- "--append-system-prompt $p/agents/bstack-council-grok.md" "$t/bstack-council-grok.md" || fail "council brief"
  grep -q 'bstack-builder.md' "$t/bstack-builder.md" || fail "builder brief"

  assert_eq '{"defaultModel":"mine"}' "$(cat "$HOME/.pi/agent/settings.json")" "settings.json untouched"
  assert_eq '{"token":"secret"}' "$(cat "$HOME/.pi/agent/auth.json")" "auth.json untouched"
  [[ ! -e "$OPENCODE_CONFIG_DIR/opencode.jsonc" && ! -e "$OPENCODE_CONFIG_DIR/agents/bstack.md" ]] \
    || fail "the Pi harness renders no opencode files"
  [[ ! -e "$BSTACK_RESOLVED" ]] || fail "opencode's resolved models are left for its handoff stages"

  grep -qx 'grok=xai/grok-4.7#high' "$p/models" || fail "resolved models: $(cat "$p/models")"
  # A family that lost its login loses its seat.
  mkdir -p "$p/extensions/bercail-guard"
  printf 'old guard\n' >"$p/extensions/bercail-guard/index.ts"
  FAKE_PI_READY="anthropic" deploy_bstack >/dev/null 2>&1
  [[ ! -d "$p/extensions" ]] || fail "update removes the old managed guard"
  [[ ! -e "$t/bstack-council-grok.md" && ! -e "$p/agents/bstack-council-grok.md" ]] || fail "stale council seat"
  grep -q 'BERCAIL_ROLE=builder pi --model anthropic/claude-opus-5-5:high ' "$t/bstack-builder.md" || fail "builder falls through"
  unset FAKE_PI_READY
  printf 'PASS: harness = pi renders the profile and hc templates, and leaves ~/.pi alone\n'
}

test_pi_keeps_their_template() {
  reset_home
  write_pi_config
  mkdir -p "$(PI_TEMPLATES)"
  printf 'my own builder\n' >"$(PI_TEMPLATES)/bstack-builder.md"
  FAKE_PI_READY="anthropic" deploy_bstack >"$TMP_DIR/pi.log" 2>&1 || fail "deploy"
  grep -qx 'my own builder' "$(PI_TEMPLATES)/bstack-builder.md" || fail "their template changed"
  grep -q 'keeping your' "$TMP_DIR/pi.log" || fail "says it kept theirs: $(cat "$TMP_DIR/pi.log")"
  printf 'PASS: Pi deploy leaves a template without the marker alone\n'
}

test_pi_off_and_switch_back() {
  reset_home
  write_pi_config
  export FAKE_PI_READY="anthropic"
  deploy_bstack >/dev/null 2>&1
  mkdir -p "$(PI_TEMPLATES)"
  printf 'mine\n' >"$(PI_TEMPLATES)/reviewer.md"
  bstack_off >/dev/null 2>&1
  [[ ! -d "$(PI_DIR)" && ! -e "$(PI_TEMPLATES)/bstack-builder.md" ]] || fail "off removes the profile"
  [[ -f "$(PI_TEMPLATES)/reviewer.md" ]] || fail "off keeps the person's templates"

  write_pi_config
  deploy_bstack >/dev/null 2>&1
  _bstack_toml_set bstack harness '"opencode"'
  FAKE_CONNECTED="claude-agent" deploy_bstack >/dev/null 2>&1
  [[ ! -d "$(PI_DIR)" && ! -e "$(PI_TEMPLATES)/bstack-builder.md" ]] || fail "back on opencode: the Pi profile goes"
  [[ -f "$OPENCODE_CONFIG_DIR/agents/bstack.md" ]] || fail "back on opencode: agents render"
  unset FAKE_PI_READY
  printf 'PASS: off and a switch back to opencode remove only the Pi profile\n'
}

test_pi_status_doctor() {
  reset_home
  write_pi_config
  export FAKE_PI_READY="anthropic xai"
  deploy_bstack >/dev/null 2>&1
  local out
  out="$(bstack_status)"
  grep -q 'harness: pi' <<<"$out" || fail "status names the harness: $out"
  grep -q 'lead = anthropic/claude-opus-5-5:high' <<<"$out" || fail "lead: $out"
  grep -q 'build = xai/grok-4.7:high' <<<"$out" || fail "build: $out"
  grep -q 'judge = anthropic/claude-opus-5-5:high' <<<"$out" || fail "judge: $out"
  grep -q 'council (grok) = xai/grok-4.7:high' <<<"$out" || fail "council: $out"
  grep -q 'gpt.*/login openai' <<<"$out" || fail "missing login hint: $out"
  grep -q 'opencode' <<<"$out" && fail "status on Pi does not talk about opencode: $out"
  # shellcheck source=lib/harness.sh
  source "$ROOT/lib/harness.sh"
  assert_eq '["anthropic/claude-opus-5-5:high"]' "$(harness_pi_models_json)" "bercail harness hints the lead on Pi"
  assert_eq '[]' "$(harness_opencode_models_json)" "and no Pi id for opencode"
  out="$(doctor_bstack)" || fail "doctor ok: $out"
  grep -q 'ok  bstack on pi' <<<"$out" || fail "doctor: $out"
  out="$(FAKE_PI_READY="anthropic xai openai" doctor_bstack)" && fail "doctor: a new login is a due update"
  grep -q 'stale  bstack models' <<<"$out" || fail "doctor stale: $out"
  out="$(FAKE_PI_READY="" doctor_bstack)" && fail "doctor: no login"
  grep -q 'none of anthropic, openai, xai' <<<"$out" || fail "doctor no login: $out"
  rm -f "$(PI_DIR)/instructions.md"
  out="$(doctor_bstack)" && fail "doctor: a missing file"
  grep -q 'missing  bstack .*instructions.md' <<<"$out" || fail "doctor missing: $out"
  deploy_bstack >/dev/null 2>&1
  _bstack_toml_set bstack claude '"claude-agent/opus#high"'
  out="$(doctor_bstack)" && fail "doctor: a pin Pi cannot run"
  grep -q 'claude-agent/opus#high is not in pi --list-models' <<<"$out" || fail "doctor pin: $out"
  grep -q 'not in pi --list-models' <<<"$(bstack_status)" || fail "status flags the pin"
  _bstack_toml_set bstack claude '"anthropic/claude-opus-5-5:high"'
  deploy_bstack >/dev/null 2>&1
  out="$(doctor_bstack)" || fail "doctor: a pin in Pi's own :level form is known: $out"
  grep -q 'not in pi --list-models' <<<"$(bstack_status)" && fail "status knows a :level pin"
  unset FAKE_PI_READY
  printf 'PASS: status and doctor report the harness, roles, and missing logins on Pi\n'
}

test_pi_setup() {
  reset_home
  write_pi_config
  FAKE_PI_READY="anthropic" bstack_setup >"$TMP_DIR/setup.log" 2>&1 || fail "setup: $(cat "$TMP_DIR/setup.log")"
  [[ -f "$(PI_DIR)/instructions.md" ]] || fail "setup deploys"
  grep -q '/login xai' "$TMP_DIR/setup.log" || fail "setup hints: $(cat "$TMP_DIR/setup.log")"
  assert_eq "" "$(_bstack_toml_get agent command)" "setup leaves the desk agent to the desk issue"
  write_config <<'EOF'
[bstack]
harness = "pi"

[agent]
command = "cursor-agent"
EOF
  FAKE_PI_READY="anthropic" bstack_on >/dev/null 2>&1
  assert_eq "cursor-agent" "$(_bstack_toml_get agent command)" "on with harness pi does not move the desk to opencode"
  printf 'PASS: setup on Pi deploys and prints the logins to run\n'
}

test_harness_defaults_to_opencode() {
  reset_home
  write_config <<'EOF'
[bstack]
enabled = true
EOF
  assert_eq "opencode" "$(bstack_harness)" "unset is opencode"
  _bstack_toml_set bstack harness '"opencode"'
  FAKE_CONNECTED="claude-agent" deploy_bstack >/dev/null 2>&1
  [[ ! -d "$(PI_DIR)" && ! -e "$(PI_TEMPLATES)/bstack-builder.md" ]] || fail "opencode renders no Pi profile"
  grep -qx 'model: claude-agent/opus#high' "$OPENCODE_CONFIG_DIR/agents/bstack.md" || fail "opencode rendering is unchanged"
  grep -q 'harness' <<<"$(FAKE_CONNECTED="claude-agent" bstack_status)" && fail "opencode status is unchanged"
  printf 'PASS: opencode stays the default harness\n'
}

test_toml_get_set
test_pick_model
test_pick_effort
test_installed_cli_reads_its_source
test_new_install_defaults
test_roles_resolve
test_deploy_renders_agents
test_deploy_keeps_their_files
test_off_removes_only_ours
test_council_seats_need_the_setting
test_ready_verifies_without_the_council
test_council_keeps_only_rerun_findings
test_verify_skill_shape
test_on_switches_stock_desk_agent
test_setup_auto_models
test_handoff_bstack_stage
test_doctor
test_harness_defaults_to_opencode
test_pi_models
test_pi_deploy
test_pi_keeps_their_template
test_pi_off_and_switch_back
test_pi_status_doctor
test_pi_setup
