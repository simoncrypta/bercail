#!/usr/bin/env bats
# Each @test is its own process: a variable one exports does not reach another.
# The libraries read YES, DRY_RUN, and the BSTACK_* locals the cases set.
# shellcheck disable=SC2030,SC2031,SC2034,SC2329

setup() {
  load test_helper
  isolate

  # shellcheck disable=SC1091
  source "$ROOT/lib/common.sh"
  # shellcheck disable=SC1091
  source "$ROOT/lib/detect.sh"
  # shellcheck disable=SC1091
  source "$ROOT/lib/deps.sh"
  # shellcheck disable=SC1091
  source "$ROOT/lib/config.sh"
  # shellcheck disable=SC1091
  source "$ROOT/lib/bstack.sh"

  export INSTALL_SRC="$ROOT"
  YES=1
  DRY_RUN=0

  FAKE_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$FAKE_BIN"
  # A stand-in pi: the logins in $FAKE_PI_READY are ready. Refuses --credentials.
  cat >"$FAKE_BIN/pi" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *--credentials* ]]; then echo "credentials must never be requested" >&2; exit 9; fi
case "$1" in
  --version) echo "${FAKE_PI_VERSION:-1.5.2}" ;;
  install)
    [[ "$2" == npm:pi-claude-bridge@0.12.0 ]] || exit 2
    [[ -z "${FAKE_PI_INSTALL_FAIL:-}" ]] || exit 1
    mkdir -p "$HOME/.pi"
    touch "$HOME/.pi/bridge-installed"
    mkdir -p "$HOME/.pi/agent"
    [[ -f "$HOME/.pi/agent/settings.json" ]] || printf '{}\n' >"$HOME/.pi/agent/settings.json"
    jq '.packages = ((.packages // []) + ["npm:pi-claude-bridge@0.12.0"] | unique)' \
      "$HOME/.pi/agent/settings.json" >"$HOME/.pi/settings.tmp"
    mv "$HOME/.pi/settings.tmp" "$HOME/.pi/agent/settings.json"
    printf '%s\n' "$*" >>"$HOME/.pi/install-log"
    ;;
  list)
    [[ -f "$HOME/.pi/bridge-installed" && -z "${FAKE_PI_BRIDGE_MISSING:-}" ]] || exit 0
    printf 'User packages:\n  npm:pi-claude-bridge@0.12.0\n    /fake/bridge\n'
    ;;
  auth)
    for id in ${FAKE_PI_READY:-}; do
      if [[ "$*" == *"--provider $id "* ]]; then printf '{"status":"ready","provider":"%s"}\n' "$id"; exit 0; fi
    done
    printf '{"status":"not_ready"}\n'; exit 1 ;;
  --offline)
    [[ "$*" == '--offline -e npm:pi-claude-bridge@0.12.0 --list-models' ]] || exit 2
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
  hash -r
}

assert_eq() {
  local expected="$1" actual="$2" msg="${3:-}"
  [[ "$expected" == "$actual" ]] || fail "${msg}: expected '$expected' got '$actual'"
}

reset_home() {
  rm -rf "$HOME"
  mkdir -p "$HOME"
  BSTACK_STATE_LOADED=0
}

write_config() {
  mkdir -p "$(dirname "$BERCAIL_USER_CONFIG")"
  cat >"$BERCAIL_USER_CONFIG"
}

PI_DIR() { printf '%s' "$HOME/.local/share/bercail/pi"; }
PI_TEMPLATES() { printf '%s' "$XDG_CONFIG_HOME/herdr-core/templates"; }

write_pi_config() {
  write_config <<'EOF'
[bstack]
EOF
}

@test "reconfigure refreshes the Pi profile and skills and prepares tuicr even with a custom review command" {
  reset_home
  write_config <<'EOF'
[layout]
review = "my-review"

[bstack]
enabled = false
lead = "gpt"
EOF
  export FAKE_PI_READY="claude-bridge openai"
  printf '#!/bin/sh\necho 99.0.0\n' >"$FAKE_BIN/tuicr"
  chmod +x "$FAKE_BIN/tuicr"
  local out
  out="$("$ROOT/bin/bercail" reconfigure 2>&1)" || fail "reconfigure: $out"
  [[ "$out" == *"the desk runs bstack's Pi lead  review=my-review"* ]] || fail "reconfigure: $out"
  jq -e 'index(["--model", "openai/gpt-6.1-sol:high"]) != null and any(.[]; contains("extensions/guard.ts"))' \
    "$(PI_DIR)/lead.json" >/dev/null || fail "the configured lead with the guard was not deployed"
  [[ -f "$HOME/.agents/skills/bstack/SKILL.md" && -L "$HOME/.pi/agent/skills/bstack" ]] || fail "reconfigure did not refresh the skills"
  grep -qx 'diff_watch_interval_ms = 1000' "$XDG_CONFIG_HOME/tuicr/config.toml" || fail "reconfigure did not prepare tuicr"
}

# Set KEY in [bstack], the last section of the config in these cases.
set_bstack() {
  sed -i "/^$1[[:space:]]*=/d" "$BERCAIL_USER_CONFIG"
  printf '%s = %s\n' "$1" "$2" >>"$BERCAIL_USER_CONFIG"
}

@test "the config reader keeps variants, sections, and comments apart" {
  reset_home
  local f="$BATS_TEST_TMPDIR/t.toml"
  cat >"$f" <<'EOF'
[layout]
review = "tuicr"

[bstack]
claude = "claude-bridge/claude-opus-5-5#high"   # keeps the variant

[shep]
rollover = true # bare value
EOF
  assert_eq "claude-bridge/claude-opus-5-5#high" "$(toml_value "$f" bstack claude)" "quoted value keeps #"
  assert_eq "true" "$(toml_value "$f" shep rollover)" "bare value drops comment"
  assert_eq "" "$(toml_value "$f" bstack review)" "keys are per section"
}

@test "a new install's config names the roles and has no switch, desk command, or harness" {
  reset_home
  default_user_config >"$BATS_TEST_TMPDIR/new.toml"
  assert_eq "grok" "$(toml_value "$BATS_TEST_TMPDIR/new.toml" bstack build)" "build role default"
  if grep -q -e '^\[agent\]' -e '^harness' -e '^enabled' "$BATS_TEST_TMPDIR/new.toml"; then
    fail "no switch, desk command, or harness to pick"
  fi
}

@test "roles resolve through families or full ids" {
  reset_home
  write_config <<'EOF'
[bstack]
claude = "claude-bridge/claude-opus-5-5#high"
gpt = "openai/gpt-6.1-sol"
grok = ""
build = "grok"
judge = "xai/grok-5#fast"
EOF
  assert_eq "claude-bridge/claude-opus-5-5#high" "$(bstack_role_model lead)" "lead defaults to claude"
  assert_eq "openai/gpt-6.1-sol" "$(bstack_role_model build)" "build on an unset grok falls to gpt"
  set_bstack claude '""'
  set_bstack gpt '""'
  assert_eq "" "$(bstack_role_model lead)" "no family with a model: Pi's default model"
  assert_eq "xai/grok-5#fast" "$(bstack_role_model judge)" "a full id is used as is"
}

@test "handoff stages bstack and autopilot run Pi on the lead and resume by its uuid" {
  reset_home
  write_config <<'EOF'
[bstack]
claude = "claude-bridge/claude-opus-5-5#high"
gpt = "openai/gpt-6.1-sol#high"
lead = "gpt"
EOF
  FAKE_PI_READY="claude-bridge openai" deploy_bstack >/dev/null 2>&1 || fail "deploy"
  local spawn="$ROOT/skills/handoff/scripts/handoff-spawn" wt="$BATS_TEST_TMPDIR/wt" out uuid=0199aaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee
  mkdir -p "$wt"
  out="$(HANDOFF_BD_BIN=/nonexistent "$spawn" --stage bstack --issue bc-1x --worktree "$wt" --dry-run)"
  jq -e '.binary == "pi" and (.command | index("-p") != null) and (.command | index("openai/gpt-6.1-sol:high") != null)
    and (.command | index("BERCAIL_ROLE=autopilot") | not) and (.command[-1] | startswith("Your job is beads issue bc-1x."))' \
    <<<"$out" >/dev/null || fail "bstack stage runs Pi headless on the lead: $out"
  out="$(HANDOFF_BD_BIN=/nonexistent "$spawn" --stage autopilot --issue bc-1x --worktree "$wt" --dry-run)"
  jq -e '(.command | index("BERCAIL_ROLE=autopilot") != null) and (.command | index("openai/gpt-6.1-sol:high") != null)' \
    <<<"$out" >/dev/null || fail "autopilot stage is the lead with BERCAIL_ROLE=autopilot: $out"
  if HANDOFF_BD_BIN=/nonexistent "$spawn" --stage autopilot --branch x --issue bc-1x >/dev/null 2>&1; then
    fail "autopilot is headless only"
  fi
  out="$(HANDOFF_BD_BIN=/nonexistent "$spawn" --stage bstack --issue bc-1x --worktree "$wt" --resume "$uuid" --dry-run)"
  jq -e --arg u "$uuid" '.resume and (.command | index($u) != null)' <<<"$out" >/dev/null || fail "resume: $out"
  if HANDOFF_BD_BIN=/nonexistent "$spawn" --stage bstack --issue bc-1x --worktree "$wt" --resume ses_9zX --dry-run >/dev/null 2>&1; then
    fail "a session id that is not Pi's uuid must be refused"
  fi
}

@test "auto adds the [bstack] effort variant each model offers" {
  reset_home
  mkdir -p "$(dirname "$BERCAIL_USER_CONFIG")"
  local m='xai/grok-4.7
openai/gpt-6.1-sol
claude-bridge/claude-opus-5-5'
  local BSTACK_CONNECTED='claude-bridge
openai
xai'
  local BSTACK_VARIANTS='xai/grok-4.7 low,medium,high,xhigh
openai/gpt-6.1-sol low,medium,high,xhigh,max
claude-bridge/claude-opus-5-5 low,medium,high,xhigh,max'
  printf '[bstack]\n' >"$BERCAIL_USER_CONFIG"
  assert_eq "openai/gpt-6.1-sol#high" "$(_bstack_pick_model gpt <<<"$m")" "high by default"
  printf '[bstack]\neffort = "max"\n' >"$BERCAIL_USER_CONFIG"
  assert_eq "xai/grok-4.7#xhigh" "$(_bstack_pick_model grok <<<"$m")" "grok has no max: the next level down"
  assert_eq "claude-bridge/claude-opus-5-5#max" "$(_bstack_pick_model claude <<<"$m")" "claude at max"
  printf '[bstack]\neffort = "none"\n' >"$BERCAIL_USER_CONFIG"
  assert_eq "openai/gpt-6.1-sol" "$(_bstack_pick_model gpt <<<"$m")" "none: the provider default"
}

@test "the installed CLI reads files from the tree it was installed from" {
  reset_home
  local clone="$BATS_TEST_TMPDIR/clone"
  mkdir -p "$clone/config" "$(dirname "$BERCAIL_SOURCE_PATH_FILE")"
  touch "$clone/install.sh"
  mkdir -p "$BATS_TEST_TMPDIR/nowhere/lib"
  printf '%s\n' "$clone" >"$BERCAIL_SOURCE_PATH_FILE"
  assert_eq "$clone" "$(script_dir() { printf '%s' "$BATS_TEST_TMPDIR/nowhere/lib"; }; INSTALL_SRC='' install_src_dir)" \
    "the installed CLI uses the recorded clone, not master"
  rm -f "$BERCAIL_SOURCE_PATH_FILE"
  assert_eq "$BERCAIL_SHARE_DIR/release" "$(script_dir() { printf '%s' "$BATS_TEST_TMPDIR/nowhere/lib"; }; INSTALL_SRC='' install_src_dir)" \
    "no recorded source: the release a curl install unpacked"
}

@test "Pi families resolve from the catalog and auth check; variants map to :level" {
  reset_home
  write_pi_config
  export FAKE_PI_READY="claude-bridge openai xai"
  _bstack_install_pi >/dev/null
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

  set_bstack gpt '"openai/gpt-6.1-sol:xhigh"'
  FAKE_PI_READY="claude-bridge openai xai" bstack_load_state reload
  assert_eq "openai/gpt-6.1-sol:xhigh" "$(_bstack_pi_model_id "$(FAKE_PI_READY="claude-bridge openai xai" bstack_resolve_model gpt)")" "a pin written :level reaches Pi as written"
  _bstack_pi_known "openai/gpt-6.1-sol:xhigh" || fail "a :level pin is a known model"
  set_bstack gpt '""'

  set_bstack effort '"none"'
  FAKE_PI_READY="claude-bridge" bstack_load_state reload
  assert_eq "claude-bridge/claude-opus-5-5" "$(FAKE_PI_READY="claude-bridge" bstack_resolve_model claude)" "effort none: no suffix"
  set_bstack effort '"max"'
  assert_eq "claude-bridge/claude-opus-5-5#max" "$(FAKE_PI_READY="claude-bridge" bstack_resolve_model claude)" "effort max"
  local BSTACK_MODELS BSTACK_VARIANTS
  BSTACK_MODELS="xai/grok-plain"
  BSTACK_VARIANTS="xai/grok-plain "
  assert_eq "" "$(_bstack_variant xai/grok-plain)" "a model that does not think gets no level"
  unset FAKE_PI_READY
}

@test "deploy renders /validate and removes the /ready an older release installed, with no alias" {
  reset_home
  write_pi_config
  export FAKE_PI_READY="claude-bridge xai"
  local p
  p="$(PI_DIR)"
  mkdir -p "$p/prompts"
  printf -- '---\ndescription: old\n---\nGet the current work ready.\n' >"$p/prompts/ready.md"
  deploy_bstack >"$BATS_TEST_TMPDIR/pi.log" 2>&1 || fail "deploy: $(cat "$BATS_TEST_TMPDIR/pi.log")"
  [[ -f "$p/prompts/validate.md" ]] || fail "validate.md missing"
  [[ ! -e "$p/prompts/ready.md" ]] || fail "the old ready.md stays after an update"
  if grep -rlq '/ready\b' "$p"; then fail "a rendered file still names /ready: $(grep -rl '/ready\b' "$p")"; fi
  grep -q 'bercail describe check' "$p/prompts/validate.md" || fail "validate checks the description"
  grep -q 'never commits, pushes, or opens a PR' "$p/prompts/validate.md" || fail "validate never publishes"
}

@test "deploy installs the bridge and renders the Pi profile and hc templates, preserving unrelated settings" {
  reset_home
  write_pi_config
  mkdir -p "$HOME/.pi/agent"
  printf '{"defaultModel":"mine"}\n' >"$HOME/.pi/agent/settings.json"
  printf '{"token":"secret"}\n' >"$HOME/.pi/agent/auth.json"
  export FAKE_PI_READY="claude-bridge xai"
  deploy_bstack >"$BATS_TEST_TMPDIR/pi.log" 2>&1 || fail "deploy: $(cat "$BATS_TEST_TMPDIR/pi.log")"
  local p t rel
  p="$(PI_DIR)"
  t="$(PI_TEMPLATES)"
  for rel in instructions.md agents/bstack-builder.md agents/bstack-judge.md \
    agents/bstack-autopilot.md agents/bstack-pr-review.md agents/bstack-council-claude.md agents/bstack-council-grok.md; do
    [[ -f "$p/$rel" ]] || fail "missing $rel"
  done
  for rel in validate council handoff autopilot how why unslop pr-review bstack-setup; do
    [[ -f "$p/prompts/$rel.md" ]] || fail "missing prompt $rel"
    if grep -q '!`' "$p/prompts/$rel.md"; then fail "Pi templates have no !cmd: $rel"; fi
    if grep -q '^agent:' "$p/prompts/$rel.md"; then fail "Pi templates have no agent key: $rel"; fi
    head -1 "$p/prompts/$rel.md" | grep -qx -- '---' || fail "frontmatter starts $rel"
  done
  if grep -rq '@[a-z_]*@' "$p/prompts" "$p/agents/bstack-builder.md" "$p/instructions.md"; then
    fail "unrendered token"
  fi
  grep -q "$p/agents/bstack-pr-review.md" "$p/prompts/pr-review.md" || fail "pr-review names its brief"
  if head -1 "$p/agents/bstack-pr-review.md" | grep -q -- '^---$'; then
    fail "a brief has no frontmatter"
  fi
  grep -q 'You review someone else' "$p/agents/bstack-pr-review.md" || fail "pr-review keeps its body"
  grep -q 'one reviewer on a council' "$p/agents/bstack-council-claude.md" || fail "council keeps its body"
  grep -q 'Desks only' "$p/instructions.md" || fail "instructions require a desk"
  # A desk never falls back to headless; only a headless handoff's own brief says so.
  grep -q 'exception: its system prompt says so' "$p/instructions.md" || fail "headless is only the handoff's exception"
  grep -q 'Work single-agent' "$p/agents/bstack-headless.md" || fail "the headless brief is single-agent"
  grep -q -- '--branch NAME --stage bstack --issue ID' "$p/prompts/handoff.md" || fail "handoff opens a desk"
  cmp "$ROOT/bstack/pi/extensions/fallback.ts" "$p/extensions/fallback.ts" || fail "managed fallback extension"
  cmp "$ROOT/bstack/pi/extensions/guard.ts" "$p/extensions/guard.ts" || fail "managed guard extension"
  cmp "$ROOT/bstack/pi/extensions/review.ts" "$p/extensions/review.ts" || fail "managed review-pr extension"
  jq -e --arg p "$p" '.[0:3] == ["pi", "--model", "claude-bridge/claude-opus-5-5:high"]
    and (index(["-e", "\($p)/extensions/review.ts"]) != null) and (index(["--tools", "read,grep,find,ls"]) != null)
    and (index(["--append-system-prompt", "\($p)/agents/bstack-pr-review.md"]) != null)
    and (index("--skill") == null) and (index("\($p)/extensions/guard.ts") == null)' "$p/review.json" >/dev/null \
    || fail "review-pr's reviewer: $(cat "$p/review.json")"
  [[ -f "$p/agents/bstack-headless.md" ]] || fail "headless lead brief"
  jq -e --arg p "$p" '.[0:3] == ["pi", "--model", "claude-bridge/claude-opus-5-5:high"]
    and (index(["-e", "npm:pi-claude-bridge@0.12.0"]) != null)
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
    grep -q -- "-e npm:pi-claude-bridge@0.12.0" "$t/$rel.md" || fail "$rel loads bridge"
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
  jq -e '.packages == ["npm:pi-claude-bridge@0.12.0"]' "$HOME/.pi/agent/settings.json" >/dev/null || fail "bridge installed"
  assert_eq '{"token":"secret"}' "$(cat "$HOME/.pi/agent/auth.json")" "auth.json untouched"

  grep -qx 'grok=xai/grok-4.7#high' "$p/models" || fail "resolved models: $(cat "$p/models")"
  # A family that lost its login loses its seat.
  mkdir -p "$p/extensions/bercail-guard"
  printf 'old guard\n' >"$p/extensions/bercail-guard/index.ts"
  FAKE_PI_READY="claude-bridge" deploy_bstack >/dev/null 2>&1
  [[ ! -d "$p/extensions/bercail-guard" ]] || fail "update removes the old managed guard"
  [[ ! -e "$t/bstack-council-grok.md" && ! -e "$p/agents/bstack-council-grok.md" ]] || fail "stale council seat"
  grep -q 'BERCAIL_ROLE=builder pi --model claude-bridge/claude-opus-5-5:high ' "$t/bstack-builder.md" || fail "builder falls through"
  unset FAKE_PI_READY
}

@test "deploy makes Pi compact each claude-bridge model before Claude Code refuses the prompt" {
  reset_home
  write_pi_config
  mkdir -p "$HOME/.pi/agent"
  printf '%s\n' '{"defaultModel":"mine","compaction":{"enabled":true,"modelOverrides":{
    "claude-bridge/claude-opus-5":{"keepRecentTokens":30000},
    "claude-bridge/claude-opus-5-5":{"reserveTokens":750000},
    "xai/grok-4.7":{"reserveTokens":1000}}}}' >"$HOME/.pi/agent/settings.json"
  FAKE_PI_READY="claude-bridge" deploy_bstack >"$BATS_TEST_TMPDIR/pi.log" 2>&1 || fail "deploy: $(cat "$BATS_TEST_TMPDIR/pi.log")"
  jq -e '.defaultModel == "mine" and .compaction == {enabled: true, modelOverrides: {
      "claude-bridge/claude-opus-4-8": {reserveTokens: 40000},
      "claude-bridge/claude-opus-4-5-20251101": {reserveTokens: 40000},
      "claude-bridge/claude-opus-5": {keepRecentTokens: 30000, reserveTokens: 40000},
      "claude-bridge/claude-opus-5-5": {reserveTokens: 750000},
      "claude-bridge/claude-sonnet-5-5": {reserveTokens: 40000},
      "xai/grok-4.7": {reserveTokens: 1000}}}' "$HOME/.pi/agent/settings.json" >/dev/null \
    || fail "settings: $(cat "$HOME/.pi/agent/settings.json")"

  # Settings Pi cannot read stay as they are.
  printf '["not", "settings"]\n' >"$HOME/.pi/agent/settings.json"
  FAKE_PI_READY="claude-bridge" deploy_bstack >"$BATS_TEST_TMPDIR/pi.log" 2>&1 || fail "deploy: $(cat "$BATS_TEST_TMPDIR/pi.log")"
  assert_eq '["not", "settings"]' "$(cat "$HOME/.pi/agent/settings.json")" "unreadable settings untouched"
  grep -q 'is not a JSON object; set compaction.modelOverrides reserveTokens to 40000' "$BATS_TEST_TMPDIR/pi.log" \
    || fail "says how to fix it: $(cat "$BATS_TEST_TMPDIR/pi.log")"
}

@test "Pi deploy leaves a template without the marker alone" {
  reset_home
  write_pi_config
  mkdir -p "$(PI_TEMPLATES)"
  printf 'my own builder\n' >"$(PI_TEMPLATES)/bstack-builder.md"
  FAKE_PI_READY="claude-bridge" deploy_bstack >"$BATS_TEST_TMPDIR/pi.log" 2>&1 || fail "deploy"
  grep -qx 'my own builder' "$(PI_TEMPLATES)/bstack-builder.md" || fail "their template changed"
  grep -q 'keeping your' "$BATS_TEST_TMPDIR/pi.log" || fail "says it kept theirs: $(cat "$BATS_TEST_TMPDIR/pi.log")"
}

@test "uninstall removes only the Pi profile; deploy has no switch, whatever enabled or harness say" {
  reset_home
  write_pi_config
  export FAKE_PI_READY="claude-bridge"
  deploy_bstack >/dev/null 2>&1
  mkdir -p "$(PI_TEMPLATES)"
  printf 'mine\n' >"$(PI_TEMPLATES)/reviewer.md"
  remove_bstack >/dev/null 2>&1
  [[ ! -d "$(PI_DIR)" && ! -e "$(PI_TEMPLATES)/bstack-builder.md" ]] || fail "remove takes the profile"
  [[ -f "$(PI_TEMPLATES)/reviewer.md" ]] || fail "remove keeps the person's templates"

  # Keys left from an older bercail change nothing: bstack is Pi and always deployed.
  write_config <<'EOF'
[bstack]
enabled = false
harness = "old"
EOF
  deploy_bstack >/dev/null 2>&1 || fail "leftover keys deploy"
  [[ -f "$(PI_DIR)/lead.json" && -f "$(PI_TEMPLATES)/bstack-builder.md" ]] || fail "leftover keys still get Pi"
  doctor_bstack | grep -q 'ok  bstack (lead=' || fail "doctor checks bstack whatever enabled says"
  unset FAKE_PI_READY
}

@test "status and doctor report roles and missing logins" {
  reset_home
  write_pi_config
  export FAKE_PI_READY="claude-bridge xai"
  deploy_bstack >/dev/null 2>&1
  local out
  out="$(bstack_status)"
  grep -q 'lead = claude-bridge/claude-opus-5-5:high' <<<"$out" || fail "lead: $out"
  grep -q 'build = xai/grok-4.7:high' <<<"$out" || fail "build: $out"
  grep -q 'judge = claude-bridge/claude-opus-5-5:high' <<<"$out" || fail "judge: $out"
  grep -q 'council (grok) = xai/grok-4.7:high' <<<"$out" || fail "council: $out"
  grep -q 'gpt.*/login openai' <<<"$out" || fail "missing login hint: $out"
  out="$(doctor_bstack)" || fail "doctor ok: $out"
  grep -q 'ok  bstack (lead=claude-bridge/claude-opus-5-5:high)' <<<"$out" || fail "doctor: $out"
  if out="$(FAKE_PI_READY="claude-bridge xai openai" doctor_bstack)"; then
    fail "doctor: a new login is a due update"
  fi
  grep -q 'stale  bstack models' <<<"$out" || fail "doctor stale: $out"
  if out="$(FAKE_PI_READY="" doctor_bstack)"; then fail "doctor: no login"; fi
  grep -q 'none of Claude Code, openai, xai' <<<"$out" || fail "doctor no login: $out"
  rm -f "$(PI_DIR)/instructions.md"
  if out="$(doctor_bstack)"; then fail "doctor: a missing file"; fi
  grep -q 'missing  bstack .*instructions.md' <<<"$out" || fail "doctor missing: $out"
  deploy_bstack >/dev/null 2>&1
  set_bstack claude '"anthropic/claude-opus-9#high"'
  if out="$(doctor_bstack)"; then fail "doctor: a pin Pi cannot run"; fi
  grep -q 'anthropic/claude-opus-9#high is not in pi --list-models' <<<"$out" || fail "doctor pin: $out"
  grep -q 'not in pi --list-models' <<<"$(bstack_status)" || fail "status flags the pin"
  set_bstack claude '"claude-bridge/claude-opus-5-5:high"'
  deploy_bstack >/dev/null 2>&1
  out="$(doctor_bstack)" || fail "doctor: a pin in Pi's own :level form is known: $out"
  if grep -q 'not in pi --list-models' <<<"$(bstack_status)"; then
    fail "status knows a :level pin"
  fi
  unset FAKE_PI_READY
}

@test "setup on Pi deploys and prints the logins to run; on and off are not commands" {
  reset_home
  write_pi_config
  FAKE_PI_READY="claude-bridge" bstack_setup >"$BATS_TEST_TMPDIR/setup.log" 2>&1 || fail "setup: $(cat "$BATS_TEST_TMPDIR/setup.log")"
  [[ -f "$(PI_DIR)/instructions.md" ]] || fail "setup deploys"
  grep -q '/login xai' "$BATS_TEST_TMPDIR/setup.log" || fail "setup hints: $(cat "$BATS_TEST_TMPDIR/setup.log")"
  local sub out
  for sub in on off; do
    if out="$(cmd_bstack "$sub" 2>&1)"; then fail "bstack $sub ran: $out"; fi
    [[ "$out" == 'error: usage: bercail bstack status|setup' ]] || fail "bstack $sub: $out"
  done
  [[ -f "$(PI_DIR)/lead.json" ]] || fail "off removed nothing"
}

@test "every Pi role including GPT/Grok council seats and empty-role lead loads bridge, fallback, and guard, and unsets Anthropic env" {
  reset_home
  write_pi_config
  export FAKE_PI_READY="claude-bridge openai xai"
  deploy_bstack >/dev/null 2>&1
  export ANTHROPIC_API_KEY=secret ANTHROPIC_BASE_URL=https://wrong ANTHROPIC_AUTH_TOKEN=secret
  export FAKE_PI_LAUNCH_LOG="$BATS_TEST_TMPDIR/pi-launch"
  local template cmd
  for template in "$(PI_TEMPLATES)"/bstack-*.md; do
    cmd="$(awk '/^command: / { sub(/^command: /, ""); print }' "$template")"
    eval "$cmd"
    grep -qxF "$(PI_DIR)/extensions/fallback.ts" "$FAKE_PI_LAUNCH_LOG" || fail "fallback in $template"
    grep -qxF "$(PI_DIR)/extensions/guard.ts" "$FAKE_PI_LAUNCH_LOG" || fail "guard in $template"
    grep -qxF 'npm:pi-claude-bridge@0.12.0' "$FAKE_PI_LAUNCH_LOG" || fail "bridge in $template"
    if grep -q '^ANTHROPIC_' "$FAKE_PI_LAUNCH_LOG.env"; then
      fail "Anthropic env leaked from $template"
    fi
  done
  cmd="$(bstack_pi_command '' "$(bstack_role_model lead)")"
  eval "$cmd"
  grep -qxF "$(PI_DIR)/extensions/fallback.ts" "$FAKE_PI_LAUNCH_LOG" || fail "lead fallback"
  grep -qxF "$(PI_DIR)/extensions/guard.ts" "$FAKE_PI_LAUNCH_LOG" || fail "lead guard"
  grep -qxF 'npm:pi-claude-bridge@0.12.0' "$FAKE_PI_LAUNCH_LOG" || fail "lead bridge"
  if grep -q '^ANTHROPIC_' "$FAKE_PI_LAUNCH_LOG.env"; then
    fail "Anthropic env leaked from lead"
  fi
  _bstack_pi_claude_ready || fail "Claude auth probe also sanitizes env"
  unset ANTHROPIC_API_KEY ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN FAKE_PI_LAUNCH_LOG FAKE_PI_READY
}

@test "Pi fallback order validates families and duplicates, deploys separately, and doctor catches missing/stale config" {
  reset_home
  write_pi_config
  export FAKE_PI_READY="claude-bridge openai xai"
  set_bstack fallback '["gpt", "grok"]'
  deploy_bstack >/dev/null 2>&1
  assert_eq "$(printf 'gpt\ngrok')" "$(<"$(PI_DIR)/fallback")" "configured fallback"
  grep -q 'fallback: gpt grok' <<<"$(bstack_status)" || fail "status fallback order"
  grep -qx 'claude=claude-bridge/claude-opus-5-5#high' "$(PI_DIR)/models" || fail "models format unchanged"
  assert_eq 'claude-bridge/claude-opus-5-5#high' "$(bstack_role_model lead)" "runtime order does not change initial role"
  set_bstack fallback '["grok", "gpt"]'
  local out raw
  if out="$(doctor_bstack)"; then fail "doctor stale fallback"; fi
  grep -q 'stale  bstack fallback' <<<"$out" || fail "doctor says stale fallback: $out"
  deploy_bstack >/dev/null 2>&1
  doctor_bstack >/dev/null || fail "doctor after fallback redeploy"
  for raw in '["gpt", "gpt"]' '["openai"]' '[1]' '"gpt"' '["gpt",]' ''; do
    [[ -n "$raw" ]] || raw='["claude", "grok", "grok"]'
    set_bstack fallback "$raw"
    if bstack_pi_fallback >/dev/null 2>&1; then fail "invalid fallback accepted: $raw"; fi
    if deploy_bstack >/dev/null 2>&1; then fail "deploy accepted invalid fallback: $raw"; fi
    if out="$(doctor_bstack 2>&1)"; then fail "doctor accepted invalid fallback: $raw"; fi
    grep -q 'invalid  bstack fallback' <<<"$out" || fail "doctor invalid fallback: $out"
  done
  set_bstack fallback '[]'
  deploy_bstack >/dev/null 2>&1
  [[ ! -s "$(PI_DIR)/fallback" ]] || fail "empty fallback disables candidates"
  rm "$(PI_DIR)/fallback" "$(PI_DIR)/models" "$(PI_DIR)/extensions/guard.ts" "$(PI_DIR)/agents/bstack-headless.md"
  if out="$(doctor_bstack)"; then fail "doctor missing data files"; fi
  grep -q 'missing  bstack .*fallback' <<<"$out" || fail "missing fallback: $out"
  grep -q 'missing  bstack .*models' <<<"$out" || fail "missing models: $out"
  grep -q 'missing  bstack .*extensions/guard.ts' <<<"$out" || fail "missing guard: $out"
  grep -q 'missing  bstack .*bstack-headless.md' <<<"$out" || fail "missing headless brief: $out"
  unset FAKE_PI_READY
}

@test "Pi fallback order takes Pi model ids beside families, so another model on the plan can go first" {
  reset_home
  write_pi_config
  export FAKE_PI_READY="claude-bridge openai xai"
  set_bstack fallback '["claude-bridge/claude-sonnet-5-5", "claude", "gpt"]'
  deploy_bstack >/dev/null 2>&1
  assert_eq "$(printf 'claude-bridge/claude-sonnet-5-5\nclaude\ngpt')" "$(<"$(PI_DIR)/fallback")" "model id kept as written"
  local out raw
  out="$(doctor_bstack)" || fail "doctor: $out"
  grep -qF 'ok  bstack fallback order: claude-bridge/claude-sonnet-5-5 claude gpt' <<<"$out" || fail "doctor shows the order: $out"
  for raw in '["/claude-opus-5-5"]' '["claude-bridge/"]' '["xai/grok-4.7:high"]' '["claude bridge/x"]' '["xai/grok-4.7", "xai/grok-4.7"]'; do
    set_bstack fallback "$raw"
    if bstack_pi_fallback >/dev/null 2>&1; then fail "invalid fallback accepted: $raw"; fi
  done
  unset FAKE_PI_READY
}

@test "doctor reports providers the fallback found dead in the last day, the latest per provider, and skips bad lines" {
  reset_home
  write_pi_config
  export FAKE_PI_READY="claude-bridge openai xai"
  deploy_bstack >/dev/null 2>&1
  local log="$XDG_STATE_HOME/bercail/fallback-dead.jsonl" out
  mkdir -p "$(dirname "$log")"
  {
    printf '{"at":"%s","provider":"openai","model":"openai/gpt-6.1-sol","reason":"old"}\n' "$(date -u -d '-2 days' +%FT%T.000Z)"
    printf 'not json\n'
    printf '{"at":"%s","provider":"xai","model":"xai/grok-4.6","reason":"first"}\n' "$(date -u -d '-1 hour' +%FT%T.000Z)"
    printf '{"at":"%s","provider":"xai","model":"xai/grok-4.7","reason":"402 out of credits"}\n' "$(date -u +%FT%T.000Z)"
  } >"$log"
  out="$(doctor_bstack)" || fail "a dead provider is a report, not a failure: $out"
  [[ "$(grep -c '  dead  ' <<<"$out")" -eq 1 ]] || fail "one dead line: $out"
  grep -q 'dead  bstack xai (xai/grok-4.7) at .*: 402 out of credits (fallback skips it' <<<"$out" || fail "latest xai record: $out"
  unset FAKE_PI_READY
}

@test "Pi bridge install is required and idempotent; doctor verifies actual bridge, Claude Code auth and minimum Pi version" {
  reset_home
  write_pi_config
  export FAKE_PI_READY="claude-bridge openai"
  local out
  out="$(bstack_status)"
  grep -q 'bridge: missing' <<<"$out" || fail "status missing bridge: $out"
  [[ ! -e "$HOME/.pi/bridge-installed" ]] || fail "status installed bridge"
  if FAKE_PI_INSTALL_FAIL=1 deploy_bstack >/dev/null 2>&1; then
    fail "deploy must fail without required bridge"
  fi
  deploy_bstack >/dev/null 2>&1
  assert_eq 1 "$(wc -l <"$HOME/.pi/install-log")" "bridge installed once"
  deploy_bstack >/dev/null 2>&1
  assert_eq 1 "$(wc -l <"$HOME/.pi/install-log")" "bridge install idempotent"
  out="$(bstack_status)"
  grep -q 'bridge: present' <<<"$out" || fail "status bridge: $out"
  grep -q 'Claude auth: ready' <<<"$out" || fail "status Claude auth: $out"
  if out="$(FAKE_PI_BRIDGE_MISSING=1 doctor_bstack)"; then
    fail "doctor missing actual bridge despite declaration"
  fi
  grep -q 'missing  bridge npm:pi-claude-bridge@0.12.0' <<<"$out" || fail "doctor bridge: $out"
  out="$(FAKE_PI_BRIDGE_MISSING=1 bstack_status)"
  grep -q 'bridge: missing' <<<"$out" || fail "status broken bridge: $out"
  out="$(FAKE_PI_READY='openai' doctor_bstack)" || true
  grep -q 'Claude auth: no subscription login (claude auth login)' <<<"$out" || fail "doctor actual Claude auth, not bridge dummy key: $out"
  local method
  for method in api_key api_key_helper third_party; do
    if FAKE_CLAUDE_AUTH_METHOD="$method" _bstack_pi_claude_ready; then
      fail "$method is not a Claude plan"
    fi
    out="$(FAKE_CLAUDE_AUTH_METHOD="$method" bstack_status)"
    grep -q 'Claude auth: no subscription login' <<<"$out" || fail "status rejects $method: $out"
  done
  FAKE_CLAUDE_AUTH_METHOD=oauth_token _bstack_pi_claude_ready || fail "oauth_token is a Claude plan"
  grep -q 'Claude auth: ready' <<<"$(FAKE_CLAUDE_AUTH_METHOD=oauth_token bstack_status)" || fail "status accepts oauth_token"
  unset FAKE_CLAUDE_AUTH_METHOD
  [[ "$(FAKE_PI_READY=anthropic _bstack_pi_connected_ids)" != *claude-bridge* ]] || fail "Pi anthropic login must not imply Claude Code login"
  if out="$(FAKE_PI_VERSION=1.5.0 doctor_bstack)"; then fail "doctor old Pi"; fi
  grep -q 'bstack needs >=1.5.1' <<<"$out" || fail "doctor old version: $out"
  if FAKE_PI_VERSION=1.5.0 deploy_bstack >/dev/null 2>&1; then fail "deploy old Pi"; fi
  unset FAKE_PI_READY
}

@test "the summary names Pi as the desk and the handoff stages" {
  reset_home
  # shellcheck disable=SC1091
  source "$ROOT/lib/help.sh"
  write_pi_config
  local out
  out="$(show_summary)"
  grep -q 'bstack: log in to Claude, ChatGPT, or xAI with bercail bstack setup' <<<"$out" || fail "summary: $out"
  grep -q 'Desk agent: pi (handoff stages: bstack, autopilot)' <<<"$out" || fail "summary desk and stages: $out"
}

@test "bstack paths default when BERCAIL_SHARE_DIR is unset" {
  local dir
  dir="$(
    env -u BERCAIL_SHARE_DIR HOME="$HOME" bash --noprofile --norc -c \
      'source "$1"; printf "%s" "$BSTACK_PI_DIR"' _ "$ROOT/lib/bstack.sh"
  )"
  assert_eq "$HOME/.local/share/bercail/pi" "$dir" "unset share dir is ~/.local/share/bercail/pi"
}
