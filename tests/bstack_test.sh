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
  --version) echo "${FAKE_PI_VERSION:-1.5.0}" ;;
  install)
    [[ "$2" == npm:pi-claude-bridge@0.11.0 ]] || exit 2
    [[ -z "${FAKE_PI_INSTALL_FAIL:-}" ]] || exit 1
    mkdir -p "$HOME/.pi"
    touch "$HOME/.pi/bridge-installed"
    mkdir -p "$HOME/.pi/agent"
    [[ -f "$HOME/.pi/agent/settings.json" ]] || printf '{}\n' >"$HOME/.pi/agent/settings.json"
    jq '.packages = ((.packages // []) + ["npm:pi-claude-bridge@0.11.0"] | unique)' \
      "$HOME/.pi/agent/settings.json" >"$HOME/.pi/settings.tmp"
    mv "$HOME/.pi/settings.tmp" "$HOME/.pi/agent/settings.json"
    printf '%s\n' "$*" >>"$HOME/.pi/install-log"
    ;;
  list)
    [[ -f "$HOME/.pi/bridge-installed" && -z "${FAKE_PI_BRIDGE_MISSING:-}" ]] || exit 0
    printf 'User packages:\n  npm:pi-claude-bridge@0.11.0\n    /fake/bridge\n'
    ;;
  auth)
    for id in ${FAKE_PI_READY:-}; do
      if [[ "$*" == *"--provider $id "* ]]; then printf '{"status":"ready","provider":"%s"}\n' "$id"; exit 0; fi
    done
    printf '{"status":"not_ready"}\n'; exit 1 ;;
  --offline)
    [[ "$*" == '--offline -e npm:pi-claude-bridge@0.11.0 --list-models' ]] || exit 2
    [[ -f "$HOME/.pi/bridge-installed" && -z "${FAKE_PI_BRIDGE_MISSING:-}" ]] || exit 3
    cat <<'EOF'
provider   model                       context  max-out  thinking  images
claude-bridge claude-opus-4-8          1M       128K     yes       yes
claude-bridge claude-opus-4-5-20251101 200K     64K      yes       yes
claude-bridge claude-opus-5            1M       128K     yes       yes
claude-bridge claude-opus-5-5          1M       128K     yes       yes
claude-bridge claude-sonnet-5-5        1M       128K     yes       yes
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
  *)
    [[ -n "${FAKE_PI_LAUNCH_LOG:-}" ]] || exit 2
    printf '%s\n' "$@" >"$FAKE_PI_LAUNCH_LOG"
    env >"$FAKE_PI_LAUNCH_LOG.env"
    ;;
esac
SH
cat >"$FAKE_BIN/claude" <<'SH'
#!/usr/bin/env bash
[[ "$*" == 'auth status --json' ]] || exit 2
[[ -z "${ANTHROPIC_API_KEY:-}${ANTHROPIC_BASE_URL:-}${ANTHROPIC_AUTH_TOKEN:-}" ]] || exit 4
method="${FAKE_CLAUDE_AUTH_METHOD:-}"
if [[ -z "$method" && " ${FAKE_PI_READY:-} " == *' claude-bridge '* ]]; then
  method=claude.ai
fi
if [[ -z "$method" || "$method" == none ]]; then
  printf '{"loggedIn":false,"authMethod":"none"}\n'
  exit 1
fi
printf '{"loggedIn":true,"authMethod":"%s"}\n' "$method"
SH
chmod +x "$FAKE_BIN/claude"
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
  assert_eq "pi" "$(_bstack_toml_get agent command "$TMP_DIR/on.toml")" "new install desk agent"
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
harness = "opencode"
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
harness = "opencode"
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
harness = "opencode"
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
harness = "opencode"
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

[bstack]
harness = "opencode"
EOF
  bstack_on >/dev/null 2>&1
  assert_eq "opencode" "$(_bstack_toml_get agent command)" "on moves the stock desk agent to opencode"
  [[ -f "$OPENCODE_CONFIG_DIR/agents/bstack.md" ]] || fail "on deploys"
  write_config <<'EOF'
[agent]
command = "claude"

[bstack]
harness = "opencode"
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
harness = "opencode"
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
harness = "opencode"
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
harness = "opencode"
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
  mkdir -p "$(dirname "$AGENTIC_DEV_USER_CONFIG")"
  printf '[bstack]\nharness = "opencode"\n' >"$AGENTIC_DEV_USER_CONFIG"
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
  printf '[bstack]\nharness = "opencode"\n' >"$AGENTIC_DEV_USER_CONFIG"
  assert_eq "openai/gpt-6.1-sol#high" "$(_bstack_pick_model gpt <<<"$m")" "high by default"
  printf '[bstack]\nharness = "opencode"\neffort = "max"\n' >"$AGENTIC_DEV_USER_CONFIG"
  assert_eq "xai/grok-4.7#xhigh" "$(_bstack_pick_model grok <<<"$m")" "grok has no max: the next level down"
  assert_eq "claude-agent/opus#max" "$(_bstack_pick_model claude <<<"$m")" "claude at max"
  printf '[bstack]\nharness = "opencode"\neffort = "none"\n' >"$AGENTIC_DEV_USER_CONFIG"
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
  export FAKE_PI_READY="claude-bridge openai xai"
  _bstack_install_harness >/dev/null
  bstack_load_state reload
  assert_eq "claude-bridge/claude-opus-5-5#high" "$(bstack_resolve_model claude)" "newest plain opus"
  assert_eq "openai/gpt-6.1-sol#high" "$(bstack_resolve_model gpt)" "newest sol"
  assert_eq "xai/grok-4.7#high" "$(bstack_resolve_model grok)" "a dated 4.20 build is not newer"
  assert_eq "claude-bridge/claude-opus-5-5:high" "$(_bstack_pi_model_id "$(bstack_role_model lead)")" "#high maps to :high"
  assert_eq "xai/grok-4.7#high" "$(bstack_role_model build)" "build defaults to grok"

  FAKE_PI_READY="claude-bridge openai-codex" bstack_load_state reload
  assert_eq "openai-codex/gpt-6.1#high" "$(FAKE_PI_READY="claude-bridge openai-codex" bstack_resolve_model gpt)" "openai-codex stands in for openai"
  assert_eq "" "$(FAKE_PI_READY="claude-bridge openai-codex" bstack_resolve_model grok)" "no xai login: no grok"
  assert_eq "openai-codex/gpt-6.1#high" "$(FAKE_PI_READY="claude-bridge openai-codex" bstack_role_model build)" "build falls through to the next family with a login"

  FAKE_PI_READY="" bstack_load_state reload
  assert_eq "" "$(FAKE_PI_READY="" bstack_role_model lead)" "no login at all: Pi's default"

  _bstack_toml_set bstack effort '"none"'
  FAKE_PI_READY="claude-bridge" bstack_load_state reload
  assert_eq "claude-bridge/claude-opus-5-5" "$(FAKE_PI_READY="claude-bridge" bstack_resolve_model claude)" "effort none: no suffix"
  _bstack_toml_set bstack effort '"max"'
  assert_eq "claude-bridge/claude-opus-5-5#max" "$(FAKE_PI_READY="claude-bridge" bstack_resolve_model claude)" "effort max"
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
  export FAKE_PI_READY="claude-bridge xai"
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
  # A desk never falls back to headless; only a headless handoff's own brief says so.
  grep -q 'exception: its system prompt says so' "$p/instructions.md" || fail "headless is only the handoff's exception"
  grep -q 'Work single-agent' "$p/agents/bstack-headless.md" || fail "the headless brief is single-agent"
  grep -q -- '--branch NAME --stage bstack --issue ID' "$p/prompts/handoff.md" || fail "handoff opens a desk"
  cmp "$ROOT/bstack/pi/extensions/fallback.ts" "$p/extensions/fallback.ts" || fail "managed fallback extension"
  cmp "$ROOT/bstack/pi/extensions/guard.ts" "$p/extensions/guard.ts" || fail "managed guard extension"
  [[ -f "$p/agents/bstack-headless.md" ]] || fail "headless lead brief"
  jq -e --arg p "$p" '.[0:3] == ["pi", "--model", "claude-bridge/claude-opus-5-5:high"]
    and (index(["-e", "npm:pi-claude-bridge@0.11.0"]) != null)
    and (index(["-e", "\($p)/extensions/fallback.ts", "-e", "\($p)/extensions/guard.ts"]) != null)
    and (index(["--prompt-template", "\($p)/prompts"]) != null)
    and (index(["--append-system-prompt", "\($p)/instructions.md"]) != null)
    and (index("--skill") != null) and (index("env") == null)' "$p/lead.json" >/dev/null \
    || fail "the desk's lead: $(cat "$p/lead.json")"
  assert_eq "$(printf 'claude\ngpt\ngrok')" "$(<"$p/fallback")" "default runtime fallback"
  grep -q 'bercail.role=agent' "$p/instructions.md" || fail "instructions warn off the desk's label"

  for rel in bstack-builder bstack-judge bstack-autopilot bstack-council-claude bstack-council-grok; do
    [[ -f "$t/$rel.md" ]] || fail "missing template $rel"
    sed -n 1p "$t/$rel.md" | grep -qx -- '---' || fail "frontmatter starts $rel"
    sed -n 2p "$t/$rel.md" | grep -qx "name: $rel" || fail "name $rel"
    sed -n 3p "$t/$rel.md" | grep -q "managed by bercail (bstack)" || fail "marker in the description of $rel"
    sed -n 5p "$t/$rel.md" | grep -qx -- '---' || fail "frontmatter holds only key: value in $rel"
    grep -q ' pi ' "$t/$rel.md" || fail "$rel runs pi"
    grep -q -- "-e $p/extensions/fallback.ts -e $p/extensions/guard.ts" "$t/$rel.md" || fail "$rel loads fallback then guard"
    grep -q -- "-e npm:pi-claude-bridge@0.11.0" "$t/$rel.md" || fail "$rel loads bridge"
    grep -q -- "env -u ANTHROPIC_API_KEY -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN " "$t/$rel.md" || fail "$rel unsets Anthropic env"
    grep -q -- "--prompt-template $p/prompts" "$t/$rel.md" || fail "--prompt-template in $rel"
    grep -q -- "--append-system-prompt $p/instructions.md" "$t/$rel.md" || fail "instructions in $rel"
    grep -q -- '--skill .*/skills/council' "$t/$rel.md" || fail "--skill in $rel"
  done
  [[ ! -e "$t/bstack-council-gpt.md" ]] || fail "no gpt seat without a login"
  grep -q '^command: env -u ANTHROPIC_API_KEY -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN BERCAIL_ROLE=builder pi --model xai/grok-4.7:high ' "$t/bstack-builder.md" || fail "builder: $(cat "$t/bstack-builder.md")"
  grep -q '^command: env -u ANTHROPIC_API_KEY -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN BERCAIL_ROLE=judge pi --model claude-bridge/claude-opus-5-5:high ' "$t/bstack-judge.md" || fail "judge"
  grep -q '^command: env -u ANTHROPIC_API_KEY -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN BERCAIL_ROLE=autopilot pi --model claude-bridge/claude-opus-5-5:high ' "$t/bstack-autopilot.md" || fail "autopilot"
  grep -q '^command: env -u ANTHROPIC_API_KEY -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN BERCAIL_ROLE=council pi --model xai/grok-4.7:high ' "$t/bstack-council-grok.md" || fail "council seat on its own family"
  grep -q -- "--append-system-prompt $p/agents/bstack-council-grok.md" "$t/bstack-council-grok.md" || fail "council brief"
  grep -q 'bstack-builder.md' "$t/bstack-builder.md" || fail "builder brief"

  assert_eq 'mine' "$(jq -r .defaultModel "$HOME/.pi/agent/settings.json")" "unrelated settings preserved"
  jq -e '.packages == ["npm:pi-claude-bridge@0.11.0"]' "$HOME/.pi/agent/settings.json" >/dev/null || fail "bridge installed"
  assert_eq '{"token":"secret"}' "$(cat "$HOME/.pi/agent/auth.json")" "auth.json untouched"
  [[ ! -e "$OPENCODE_CONFIG_DIR/opencode.jsonc" && ! -e "$OPENCODE_CONFIG_DIR/agents/bstack.md" ]] \
    || fail "the Pi harness renders no opencode files"
  [[ ! -e "$BSTACK_RESOLVED" ]] || fail "opencode's resolved models are left for its handoff stages"

  grep -qx 'grok=xai/grok-4.7#high' "$p/models" || fail "resolved models: $(cat "$p/models")"
  # A family that lost its login loses its seat.
  mkdir -p "$p/extensions/bercail-guard"
  printf 'old guard\n' >"$p/extensions/bercail-guard/index.ts"
  FAKE_PI_READY="claude-bridge" deploy_bstack >/dev/null 2>&1
  [[ ! -d "$p/extensions/bercail-guard" ]] || fail "update removes the old managed guard"
  [[ ! -e "$t/bstack-council-grok.md" && ! -e "$p/agents/bstack-council-grok.md" ]] || fail "stale council seat"
  grep -q 'BERCAIL_ROLE=builder pi --model claude-bridge/claude-opus-5-5:high ' "$t/bstack-builder.md" || fail "builder falls through"
  unset FAKE_PI_READY
  printf 'PASS: harness = pi installs bridge and renders profile and hc templates, preserving unrelated settings\n'
}

test_pi_keeps_their_template() {
  reset_home
  write_pi_config
  mkdir -p "$(PI_TEMPLATES)"
  printf 'my own builder\n' >"$(PI_TEMPLATES)/bstack-builder.md"
  FAKE_PI_READY="claude-bridge" deploy_bstack >"$TMP_DIR/pi.log" 2>&1 || fail "deploy"
  grep -qx 'my own builder' "$(PI_TEMPLATES)/bstack-builder.md" || fail "their template changed"
  grep -q 'keeping your' "$TMP_DIR/pi.log" || fail "says it kept theirs: $(cat "$TMP_DIR/pi.log")"
  printf 'PASS: Pi deploy leaves a template without the marker alone\n'
}

test_pi_off_and_switch_back() {
  reset_home
  write_pi_config
  export FAKE_PI_READY="claude-bridge"
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
  export FAKE_PI_READY="claude-bridge xai"
  deploy_bstack >/dev/null 2>&1
  local out
  out="$(bstack_status)"
  grep -q 'harness: pi' <<<"$out" || fail "status names the harness: $out"
  grep -q 'lead = claude-bridge/claude-opus-5-5:high' <<<"$out" || fail "lead: $out"
  grep -q 'build = xai/grok-4.7:high' <<<"$out" || fail "build: $out"
  grep -q 'judge = claude-bridge/claude-opus-5-5:high' <<<"$out" || fail "judge: $out"
  grep -q 'council (grok) = xai/grok-4.7:high' <<<"$out" || fail "council: $out"
  grep -q 'gpt.*/login openai' <<<"$out" || fail "missing login hint: $out"
  grep -q 'opencode' <<<"$out" && fail "status on Pi does not talk about opencode: $out"
  # shellcheck source=lib/harness.sh
  source "$ROOT/lib/harness.sh"
  assert_eq '["claude-bridge/claude-opus-5-5:high"]' "$(harness_pi_models_json)" "bercail harness hints the lead on Pi"
  assert_eq '[]' "$(harness_opencode_models_json)" "and no Pi id for opencode"
  out="$(doctor_bstack)" || fail "doctor ok: $out"
  grep -q 'ok  bstack on pi' <<<"$out" || fail "doctor: $out"
  out="$(FAKE_PI_READY="claude-bridge xai openai" doctor_bstack)" && fail "doctor: a new login is a due update"
  grep -q 'stale  bstack models' <<<"$out" || fail "doctor stale: $out"
  out="$(FAKE_PI_READY="" doctor_bstack)" && fail "doctor: no login"
  grep -q 'none of Claude Code, openai, xai' <<<"$out" || fail "doctor no login: $out"
  rm -f "$(PI_DIR)/instructions.md"
  out="$(doctor_bstack)" && fail "doctor: a missing file"
  grep -q 'missing  bstack .*instructions.md' <<<"$out" || fail "doctor missing: $out"
  deploy_bstack >/dev/null 2>&1
  _bstack_toml_set bstack claude '"claude-agent/opus#high"'
  out="$(doctor_bstack)" && fail "doctor: a pin Pi cannot run"
  grep -q 'claude-agent/opus#high is not in pi --list-models' <<<"$out" || fail "doctor pin: $out"
  grep -q 'not in pi --list-models' <<<"$(bstack_status)" || fail "status flags the pin"
  _bstack_toml_set bstack claude '"claude-bridge/claude-opus-5-5:high"'
  deploy_bstack >/dev/null 2>&1
  out="$(doctor_bstack)" || fail "doctor: a pin in Pi's own :level form is known: $out"
  grep -q 'not in pi --list-models' <<<"$(bstack_status)" && fail "status knows a :level pin"
  unset FAKE_PI_READY
  printf 'PASS: status and doctor report the harness, roles, and missing logins on Pi\n'
}

test_pi_setup() {
  reset_home
  write_pi_config
  FAKE_PI_READY="claude-bridge" bstack_setup >"$TMP_DIR/setup.log" 2>&1 || fail "setup: $(cat "$TMP_DIR/setup.log")"
  [[ -f "$(PI_DIR)/instructions.md" ]] || fail "setup deploys"
  grep -q '/login xai' "$TMP_DIR/setup.log" || fail "setup hints: $(cat "$TMP_DIR/setup.log")"
  assert_eq "" "$(_bstack_toml_get agent command)" "setup leaves the desk agent to the desk issue"
  write_config <<'EOF'
[bstack]
harness = "pi"

[agent]
command = "cursor-agent"
EOF
  FAKE_PI_READY="claude-bridge" bstack_on >/dev/null 2>&1
  assert_eq "pi" "$(_bstack_toml_get agent command)" "on with harness pi moves the stock desk to pi"
  write_config <<'EOF'
[bstack]
enabled = true

[agent]
command = "opencode"
EOF
  FAKE_PI_READY="claude-bridge" bstack_on >/dev/null 2>&1
  assert_eq "pi" "$(_bstack_toml_get agent command)" "on moves bercail's old opencode desk to pi"
  write_config <<'EOF'
[bstack]
enabled = true

[agent]
command = "claude"
EOF
  bstack_on >/dev/null 2>&1
  assert_eq "claude" "$(_bstack_toml_get agent command)" "on keeps a desk agent the person picked"
  printf 'PASS: setup on Pi deploys and prints the logins to run\n'
}
test_pi_launch_contract() {
  reset_home
  write_pi_config
  export FAKE_PI_READY="claude-bridge openai xai"
  deploy_bstack >/dev/null 2>&1
  export ANTHROPIC_API_KEY=secret ANTHROPIC_BASE_URL=https://wrong ANTHROPIC_AUTH_TOKEN=secret
  export FAKE_PI_LAUNCH_LOG="$TMP_DIR/pi-launch"
  local template cmd role
  for template in "$(PI_TEMPLATES)"/bstack-*.md; do
    cmd="$(awk '/^command: / { sub(/^command: /, ""); print }' "$template")"
    eval "$cmd"
    grep -qxF "$(PI_DIR)/extensions/fallback.ts" "$FAKE_PI_LAUNCH_LOG" || fail "fallback in $template"
    grep -qxF "$(PI_DIR)/extensions/guard.ts" "$FAKE_PI_LAUNCH_LOG" || fail "guard in $template"
    grep -qxF 'npm:pi-claude-bridge@0.11.0' "$FAKE_PI_LAUNCH_LOG" || fail "bridge in $template"
    grep -q '^ANTHROPIC_' "$FAKE_PI_LAUNCH_LOG.env" && fail "Anthropic env leaked from $template"
  done
  cmd="$(bstack_pi_command '' "$(bstack_role_model lead)")"
  eval "$cmd"
  grep -qxF "$(PI_DIR)/extensions/fallback.ts" "$FAKE_PI_LAUNCH_LOG" || fail "lead fallback"
  grep -qxF "$(PI_DIR)/extensions/guard.ts" "$FAKE_PI_LAUNCH_LOG" || fail "lead guard"
  grep -qxF 'npm:pi-claude-bridge@0.11.0' "$FAKE_PI_LAUNCH_LOG" || fail "lead bridge"
  grep -q '^ANTHROPIC_' "$FAKE_PI_LAUNCH_LOG.env" && fail "Anthropic env leaked from lead"
  _bstack_pi_claude_ready || fail "Claude auth probe also sanitizes env"
  unset ANTHROPIC_API_KEY ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN FAKE_PI_LAUNCH_LOG FAKE_PI_READY
  printf 'PASS: every Pi role including GPT/Grok council seats and empty-role lead loads bridge, fallback, and guard, and unsets Anthropic env\n'
}

test_pi_fallback_config() {
  reset_home
  write_pi_config
  export FAKE_PI_READY="claude-bridge openai xai"
  _bstack_toml_set bstack fallback '["gpt", "grok"]'
  deploy_bstack >/dev/null 2>&1
  assert_eq "$(printf 'gpt\ngrok')" "$(<"$(PI_DIR)/fallback")" "configured fallback"
  grep -q 'fallback: gpt grok' <<<"$(bstack_status)" || fail "status fallback order"
  grep -qx 'claude=claude-bridge/claude-opus-5-5#high' "$(PI_DIR)/models" || fail "models format unchanged"
  assert_eq 'claude-bridge/claude-opus-5-5#high' "$(bstack_role_model lead)" "runtime order does not change initial role"
  _bstack_toml_set bstack fallback '["grok", "gpt"]'
  local out raw
  out="$(doctor_bstack)" && fail "doctor stale fallback"
  grep -q 'stale  bstack fallback' <<<"$out" || fail "doctor says stale fallback: $out"
  deploy_bstack >/dev/null 2>&1
  doctor_bstack >/dev/null || fail "doctor after fallback redeploy"
  for raw in '["gpt", "gpt"]' '["openai"]' '[1]' '"gpt"' '["gpt",]' ''; do
    [[ -n "$raw" ]] || raw='["claude", "grok", "grok"]'
    _bstack_toml_set bstack fallback "$raw"
    bstack_pi_fallback >/dev/null 2>&1 && fail "invalid fallback accepted: $raw"
    deploy_bstack >/dev/null 2>&1 && fail "deploy accepted invalid fallback: $raw"
    out="$(doctor_bstack 2>&1)" && fail "doctor accepted invalid fallback: $raw"
    grep -q 'invalid  bstack fallback' <<<"$out" || fail "doctor invalid fallback: $out"
  done
  _bstack_toml_set bstack fallback '[]'
  deploy_bstack >/dev/null 2>&1
  [[ ! -s "$(PI_DIR)/fallback" ]] || fail "empty fallback disables candidates"
  rm "$(PI_DIR)/fallback" "$(PI_DIR)/models" "$(PI_DIR)/extensions/guard.ts" "$(PI_DIR)/agents/bstack-headless.md"
  out="$(doctor_bstack)" && fail "doctor missing data files"
  grep -q 'missing  bstack .*fallback' <<<"$out" || fail "missing fallback: $out"
  grep -q 'missing  bstack .*models' <<<"$out" || fail "missing models: $out"
  grep -q 'missing  bstack .*extensions/guard.ts' <<<"$out" || fail "missing guard: $out"
  grep -q 'missing  bstack .*bstack-headless.md' <<<"$out" || fail "missing headless brief: $out"
  unset FAKE_PI_READY
  printf 'PASS: Pi fallback order validates families and duplicates, deploys separately, and doctor catches missing/stale config\n'
}

test_pi_bridge_doctor() {
  reset_home
  write_pi_config
  export FAKE_PI_READY="claude-bridge openai"
  local out
  out="$(bstack_status)"
  grep -q 'bridge: missing' <<<"$out" || fail "status missing bridge: $out"
  [[ ! -e "$HOME/.pi/bridge-installed" ]] || fail "status installed bridge"
  FAKE_PI_INSTALL_FAIL=1 deploy_bstack >/dev/null 2>&1 && fail "deploy must fail without required bridge"
  deploy_bstack >/dev/null 2>&1
  assert_eq 1 "$(wc -l <"$HOME/.pi/install-log")" "bridge installed once"
  deploy_bstack >/dev/null 2>&1
  assert_eq 1 "$(wc -l <"$HOME/.pi/install-log")" "bridge install idempotent"
  out="$(bstack_status)"
  grep -q 'bridge: present' <<<"$out" || fail "status bridge: $out"
  grep -q 'Claude auth: ready' <<<"$out" || fail "status Claude auth: $out"
  out="$(FAKE_PI_BRIDGE_MISSING=1 doctor_bstack)" && fail "doctor missing actual bridge despite declaration"
  grep -q 'missing  bridge npm:pi-claude-bridge@0.11.0' <<<"$out" || fail "doctor bridge: $out"
  out="$(FAKE_PI_BRIDGE_MISSING=1 bstack_status)"
  grep -q 'bridge: missing' <<<"$out" || fail "status broken bridge: $out"
  out="$(FAKE_PI_READY='openai' doctor_bstack)" || true
  grep -q 'Claude auth: no subscription login (claude auth login)' <<<"$out" || fail "doctor actual Claude auth, not bridge dummy key: $out"
  local method
  for method in api_key api_key_helper third_party; do
    FAKE_CLAUDE_AUTH_METHOD="$method" _bstack_pi_claude_ready && fail "$method is not a Claude plan"
    out="$(FAKE_CLAUDE_AUTH_METHOD="$method" bstack_status)"
    grep -q 'Claude auth: no subscription login' <<<"$out" || fail "status rejects $method: $out"
  done
  FAKE_CLAUDE_AUTH_METHOD=oauth_token _bstack_pi_claude_ready || fail "oauth_token is a Claude plan"
  grep -q 'Claude auth: ready' <<<"$(FAKE_CLAUDE_AUTH_METHOD=oauth_token bstack_status)" || fail "status accepts oauth_token"
  unset FAKE_CLAUDE_AUTH_METHOD
  [[ "$(FAKE_PI_READY=anthropic bstack_connected_ids)" != *claude-bridge* ]] || fail "Pi anthropic login must not imply Claude Code login"
  out="$(FAKE_PI_VERSION=1.1.9 doctor_bstack)" && fail "doctor old Pi"
  grep -q 'bstack needs >=1.2.0' <<<"$out" || fail "doctor old version: $out"
  FAKE_PI_VERSION=1.1.9 deploy_bstack >/dev/null 2>&1 && fail "deploy old Pi"
  unset FAKE_PI_READY
  printf 'PASS: Pi bridge install is required and idempotent; doctor verifies actual bridge, Claude Code auth and minimum Pi version\n'
}

test_harness_defaults_to_pi() {
  reset_home
  write_config <<'EOF'
[bstack]
enabled = true
EOF
  assert_eq "pi" "$(bstack_harness)" "unset is pi"
  _bstack_toml_set bstack harness '"nope"'
  assert_eq "pi" "$(bstack_harness)" "unknown falls back to pi"
  local out
  out="$(deploy_bstack 2>&1)" || fail "unknown harness deploys Pi: $out"
  grep -q 'using pi' <<<"$out" || fail "unknown harness warns: $out"
  grep -q 'using opencode' <<<"$out" && fail "unknown harness must not fall back to opencode: $out"
  [[ -f "$(PI_DIR)/lead.json" ]] || fail "unknown harness deploys the Pi profile"
  _bstack_toml_set bstack harness '"opencode"'
  FAKE_CONNECTED="claude-agent" deploy_bstack >/dev/null 2>&1
  [[ ! -d "$(PI_DIR)" && ! -e "$(PI_TEMPLATES)/bstack-builder.md" ]] || fail "pinned opencode renders no Pi profile"
  grep -qx 'model: claude-agent/opus#high' "$OPENCODE_CONFIG_DIR/agents/bstack.md" || fail "opencode rendering is unchanged"
  grep -q 'harness' <<<"$(FAKE_CONNECTED="claude-agent" bstack_status)" && fail "opencode status is unchanged"
  printf 'PASS: Pi is the default harness; opencode only when pinned\n'
}

test_share_dir_defaults_when_unset() {
  local dir
  dir="$(
    env -u AGENTIC_DEV_SHARE_DIR HOME="$HOME" bash --noprofile --norc -c \
      'source "$1"; printf "%s" "$BSTACK_PI_DIR"' _ "$ROOT/lib/bstack.sh"
  )"
  assert_eq "$HOME/.local/share/bercail/pi" "$dir" "unset share dir is ~/.local/share/bercail/pi"
  printf 'PASS: bstack paths default when AGENTIC_DEV_SHARE_DIR is unset\n'
}

test_migrate_opencode_desk_and_summary() {
  reset_home
  # shellcheck source=lib/help.sh
  source "$ROOT/lib/help.sh"
  write_config <<'EOF'
[agent]
command = "opencode"

[bstack]
enabled = true
EOF
  migrate_opencode_desk_command
  assert_eq "pi" "$(_bstack_toml_get agent command)" "update migrates the old desk default"
  local out
  out="$(show_summary)"
  grep -q 'bstack: on (pi)' <<<"$out" || fail "summary harness: $out"
  grep -q 'bstack=pi, autopilot=pi (BERCAIL_ROLE=autopilot)' <<<"$out" || fail "summary stages: $out"
  grep -q 'Agent command: pi ' <<<"$out" || fail "summary agent: $out"
  grep -q 'opencode' <<<"$out" && fail "summary on Pi must not say opencode: $out"
  write_config <<'EOF'
[agent]
command = "opencode"

[bstack]
enabled = true
harness = "opencode"
EOF
  migrate_opencode_desk_command
  assert_eq "opencode" "$(_bstack_toml_get agent command)" "pinned opencode harness keeps its desk"
  out="$(show_summary)"
  grep -q 'bstack: on (opencode)' <<<"$out" || fail "pinned summary: $out"
  grep -q 'bstack=opencode, autopilot=opencode bstack-autopilot' <<<"$out" || fail "pinned stages: $out"
  write_config <<'EOF'
[agent]
command = "claude"

[bstack]
enabled = true
EOF
  migrate_opencode_desk_command
  assert_eq "claude" "$(_bstack_toml_get agent command)" "a chosen desk agent stays"
  grep -q 'Existing configs without harness keep opencode' "$ROOT/lib/help.sh" \
    && fail "help still says unset harness is opencode"
  grep -q 'Pi on the desk' "$ROOT/lib/help.sh" || fail "help --bstack should say Pi on the desk"
  grep -q 'pi -p' "$ROOT/lib/help.sh" || fail "help should say bstack runs pi -p"
  grep -q 'opencode or Pi' "$ROOT/bin/bercail" && fail "usage still leads with opencode"
  printf 'PASS: update migrates the old opencode desk default; summary names the harness\n'
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
test_harness_defaults_to_pi
test_share_dir_defaults_when_unset
test_migrate_opencode_desk_and_summary
test_pi_models
test_pi_deploy
test_pi_keeps_their_template
test_pi_off_and_switch_back
test_pi_status_doctor
test_pi_setup
test_pi_launch_contract
test_pi_fallback_config
test_pi_bridge_doctor
