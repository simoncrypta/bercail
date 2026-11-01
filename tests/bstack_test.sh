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
EOF
  deploy_bstack >/dev/null 2>&1 || fail "deploy_bstack failed"
  local oc="$OPENCODE_CONFIG_DIR" rel
  for rel in "${BSTACK_RENDERED[@]}" opencode.jsonc bstack/instructions.md; do
    [[ -f "$oc/$rel" ]] || fail "missing $rel"
  done
  grep -qx 'model: claude-agent/opus#high' "$oc/agents/bstack.md" || fail "lead model: $(cat "$oc/agents/bstack.md")"
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
  assert_eq "https://setup.simoncrypta.dev" "$(script_dir() { printf '%s' "$TMP_DIR/nowhere/lib"; }; INSTALL_SRC='' install_src_dir)" \
    "no recorded source: remote"
  printf 'PASS: the installed CLI reads files from the tree it was installed from\n'
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
test_on_switches_stock_desk_agent
test_setup_auto_models
test_handoff_bstack_stage
test_doctor
