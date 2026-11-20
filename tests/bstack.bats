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
  assert_eq "claude" "$(toml_value "$BATS_TEST_TMPDIR/new.toml" bstack build)" "build role default"
  assert_eq "gpt" "$(toml_value "$BATS_TEST_TMPDIR/new.toml" bstack judge)" "judge role default"
  if grep -q -e '^grok' -e '^fallback' "$BATS_TEST_TMPDIR/new.toml"; then fail "no xAI and no fallback list"; fi
  if grep -q -e '^\[agent\]' -e '^harness' -e '^enabled' "$BATS_TEST_TMPDIR/new.toml"; then
    fail "no switch, desk command, or harness to pick"
  fi
}

@test "roles resolve through families or full ids: build on Claude, the judge on GPT then Claude" {
  reset_home
  write_config <<'EOF'
[bstack]
claude = "claude-bridge/claude-opus-5-5#high"
gpt = "openai/gpt-6.1-sol"
lead = "openai/gpt-6.2-astra#fast"
EOF
  assert_eq "claude-bridge/claude-opus-5-5#high" "$(bstack_role_model build)" "build defaults to claude"
  assert_eq "openai/gpt-6.1-sol" "$(bstack_role_model judge)" "judge defaults to gpt"
  assert_eq "openai/gpt-6.2-astra#fast" "$(bstack_role_model lead)" "a full id is used as is"
  set_bstack gpt '""'
  assert_eq "claude-bridge/claude-opus-5-5#high" "$(bstack_role_model judge)" "no gpt model: the judge takes claude"
  set_bstack claude '""'
  set_bstack gpt '"openai/gpt-6.1-sol"'
  assert_eq "" "$(bstack_role_model build)" "no claude model: build has no other family, so Pi's default model"
}

@test "an old grok or fallback in config is ignored with a warning, not refused" {
  reset_home
  write_pi_config
  set_bstack grok '"xai/grok-4.7"'
  set_bstack fallback '["claude", "gpt", "grok"]'
  set_bstack build '"grok"'
  set_bstack judge '"grok"'
  local err="$BATS_TEST_TMPDIR/deploy.err"
  FAKE_PI_READY="claude-bridge openai xai" deploy_bstack >/dev/null 2>"$err" || fail "deploy refused an old config: $(cat "$err")"
  grep -q 'grok is ignored: bstack no longer uses xAI' "$err" || fail "grok warning: $(cat "$err")"
  grep -q 'fallback is ignored: a limited role now pauses' "$err" || fail "fallback warning: $(cat "$err")"
  grep -q 'build = "grok" is ignored: build uses claude' "$err" || fail "build warning: $(cat "$err")"
  grep -q 'judge = "grok" is ignored: judge uses gpt' "$err" || fail "judge warning: $(cat "$err")"
  assert_eq "claude-bridge/claude-opus-5-5#high" "$(FAKE_PI_READY="claude-bridge openai xai" bstack_role_model build)" "build = grok takes build's default"
  assert_eq "openai/gpt-6.1-sol#high" "$(FAKE_PI_READY="claude-bridge openai xai" bstack_role_model judge)" "judge = grok takes judge's default"
  [[ ! -e "$(PI_DIR)/fallback" ]] || fail "no fallback list is deployed"
  local out
  out="$(FAKE_PI_READY="claude-bridge openai xai" bstack_status 2>&1)"
  grep -q 'fallback is ignored' <<<"$out" || fail "status warns too: $out"
  if grep -rq 'xai\|grok' "$(PI_DIR)/models" "$(PI_TEMPLATES)"; then fail "a pinned grok reaches no model or seat"; fi
}

@test "handoff stages bstack and autopilot run Pi on the lead and resume by its uuid" {
  need node
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
  local m='openai/gpt-6.1-sol
claude-bridge/claude-opus-5-5'
  local BSTACK_CONNECTED='claude-bridge
openai'
  local BSTACK_VARIANTS='openai/gpt-6.1-sol low,medium,high,xhigh
claude-bridge/claude-opus-5-5 low,medium,high,xhigh,max'
  printf '[bstack]\n' >"$BERCAIL_USER_CONFIG"
  assert_eq "openai/gpt-6.1-sol#high" "$(_bstack_pick_model gpt <<<"$m")" "high by default"
  printf '[bstack]\neffort = "max"\n' >"$BERCAIL_USER_CONFIG"
  assert_eq "openai/gpt-6.1-sol#xhigh" "$(_bstack_pick_model gpt <<<"$m")" "no max offered: the next level down"
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
  assert_eq "claude-bridge/claude-opus-5-5:high" "$(_bstack_pi_model_id "$(bstack_role_model lead)")" "#high maps to :high"
  assert_eq "claude-bridge/claude-opus-5-5#high" "$(bstack_role_model build)" "build defaults to claude"
  assert_eq "openai/gpt-6.1-sol#high" "$(bstack_role_model judge)" "judge defaults to gpt"

  FAKE_PI_READY="claude-bridge openai-codex" bstack_load_state reload
  assert_eq "openai-codex/gpt-6.1#high" "$(FAKE_PI_READY="claude-bridge openai-codex" bstack_resolve_model gpt)" "openai-codex stands in for openai"
  FAKE_PI_READY="claude-bridge" bstack_load_state reload
  assert_eq "claude-bridge/claude-opus-5-5#high" "$(FAKE_PI_READY="claude-bridge" bstack_role_model judge)" "no ChatGPT login: the judge resolves to Opus"
  FAKE_PI_READY="openai" bstack_load_state reload
  assert_eq "" "$(FAKE_PI_READY="openai" bstack_role_model build)" "no Claude login: build takes no other family"

  FAKE_PI_READY="" bstack_load_state reload
  assert_eq "" "$(FAKE_PI_READY="" bstack_role_model lead)" "no login at all: Pi's default"

  set_bstack gpt '"openai/gpt-6.1-sol:xhigh"'
  FAKE_PI_READY="claude-bridge openai" bstack_load_state reload
  assert_eq "openai/gpt-6.1-sol:xhigh" "$(_bstack_pi_model_id "$(FAKE_PI_READY="claude-bridge openai" bstack_resolve_model gpt)")" "a pin written :level reaches Pi as written"
  _bstack_pi_known "openai/gpt-6.1-sol:xhigh" || fail "a :level pin is a known model"
  set_bstack gpt '""'

  set_bstack effort '"none"'
  FAKE_PI_READY="claude-bridge" bstack_load_state reload
  assert_eq "claude-bridge/claude-opus-5-5" "$(FAKE_PI_READY="claude-bridge" bstack_resolve_model claude)" "effort none: no suffix"
  set_bstack effort '"max"'
  assert_eq "claude-bridge/claude-opus-5-5#max" "$(FAKE_PI_READY="claude-bridge" bstack_resolve_model claude)" "effort max"
  local BSTACK_MODELS BSTACK_VARIANTS
  BSTACK_MODELS="openai/gpt-plain"
  BSTACK_VARIANTS="openai/gpt-plain "
  assert_eq "" "$(_bstack_variant openai/gpt-plain)" "a model that does not think gets no level"
  unset FAKE_PI_READY
}

@test "deploy renders /validate and removes the /ready an older release installed, with no alias" {
  reset_home
  write_pi_config
  export FAKE_PI_READY="claude-bridge"
  local p
  p="$(PI_DIR)"
  mkdir -p "$p/prompts"
  printf -- '---\ndescription: old\n---\nGet the current work ready.\n' >"$p/prompts/ready.md"
  deploy_bstack >"$BATS_TEST_TMPDIR/pi.log" 2>&1 || fail "deploy: $(cat "$BATS_TEST_TMPDIR/pi.log")"
  [[ -f "$p/prompts/validate.md" ]] || fail "validate.md missing"
  [[ ! -e "$p/prompts/ready.md" ]] || fail "the old ready.md stays after an update"
}

@test "deploy installs the bridge and renders the Pi profile and hc templates, preserving unrelated settings" {
  reset_home
  write_pi_config
  mkdir -p "$HOME/.pi/agent"
  printf '{"defaultModel":"mine"}\n' >"$HOME/.pi/agent/settings.json"
  printf '{"token":"secret"}\n' >"$HOME/.pi/agent/auth.json"
  export FAKE_PI_READY="claude-bridge openai xai"
  local p t rel
  p="$(PI_DIR)"
  t="$(PI_TEMPLATES)"
  deploy_bstack >"$BATS_TEST_TMPDIR/pi.log" 2>&1 || fail "deploy: $(cat "$BATS_TEST_TMPDIR/pi.log")"
  # Each file is its source; the one rewrite is @pi_dir@ in the Markdown.
  while IFS= read -r rel; do
    case "$rel" in
      */UPSTREAM.md) continue ;;
      *.md) diff <(sed "s|@pi_dir@|$p|g" "$ROOT/bstack/pi/$rel") "$p/$rel" || fail "$rel is not its source, rendered" ;;
      *) cmp "$ROOT/bstack/pi/$rel" "$p/$rel" || fail "$rel is not its source" ;;
    esac
  done < <(cd "$ROOT/bstack/pi" && find . -type f | sed 's|^\./||')
  if grep -rq '@[a-z_]*@' "$p"; then fail "unrendered token: $(grep -rl '@[a-z_]*@' "$p")"; fi
  # Pi reads these as prompt templates: no !cmd, no agent key, frontmatter first.
  for rel in "$p"/prompts/*.md; do
    if grep -q '!`' "$rel"; then fail "Pi templates have no !cmd: $rel"; fi
    if grep -q '^agent:' "$rel"; then fail "Pi templates have no agent key: $rel"; fi
    head -1 "$rel" | grep -qx -- '---' || fail "frontmatter starts $rel"
  done
  if head -1 "$p/agents/bstack-pr-review.md" | grep -q -- '^---$'; then
    fail "a brief has no frontmatter"
  fi
  jq -e --arg p "$p" '.[0:3] == ["pi", "--model", "claude-bridge/claude-opus-5-5:high"]
    and (index(["-e", "\($p)/extensions/review.ts"]) != null) and (index(["--tools", "read,grep,find,ls"]) != null)
    and (index(["--append-system-prompt", "\($p)/agents/bstack-pr-review.md"]) != null)
    and (index("--skill") == null) and (index("\($p)/extensions/guard.ts") == null)
    and (index("\($p)/extensions/pi-emphasis/index.ts") == null)
    and (index("--no-approve") != null)' "$p/review.json" >/dev/null \
    || fail "review-pr's reviewer: $(cat "$p/review.json")"
  [[ -f "$p/agents/bstack-headless.md" ]] || fail "headless lead brief"
  jq -e --arg p "$p" '.[0:3] == ["pi", "--model", "claude-bridge/claude-opus-5-5:high"]
    and (index(["-e", "npm:pi-claude-bridge@0.12.0"]) != null)
    and (index(["-e", "\($p)/extensions/fallback.ts", "-e", "\($p)/extensions/guard.ts"]) != null)
    and (index(["-e", "\($p)/extensions/pi-emphasis/index.ts"]) != null)
    and (index(["--prompt-template", "\($p)/prompts"]) != null)
    and (index(["--append-system-prompt", "\($p)/instructions.md"]) != null)
    and (index("--skill") != null) and (index("env") == null)' "$p/lead.json" >/dev/null \
    || fail "the desk's lead: $(cat "$p/lead.json")"
  [[ ! -e "$p/fallback" ]] || fail "no runtime fallback list"

  for rel in bstack-builder bstack-judge bstack-autopilot; do
    [[ -f "$t/$rel.md" ]] || fail "missing template $rel"
    sed -n 1p "$t/$rel.md" | grep -qx -- '---' || fail "frontmatter starts $rel"
    sed -n 2p "$t/$rel.md" | grep -qx "name: $rel" || fail "name $rel"
    sed -n 3p "$t/$rel.md" | grep -q "managed by bercail (bstack)" || fail "marker in the description of $rel"
    sed -n 5p "$t/$rel.md" | grep -qx -- '---' || fail "frontmatter holds only key: value in $rel"
  done
  grep -q '^command: env -u ANTHROPIC_API_KEY -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN BERCAIL_ROLE=builder [^ ]*bercail scratch run -- pi --model claude-bridge/claude-opus-5-5:high ' "$t/bstack-builder.md" || fail "builder: $(cat "$t/bstack-builder.md")"
  grep -q '^command: env -u ANTHROPIC_API_KEY -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN BERCAIL_ROLE=judge [^ ]*bercail scratch run -- pi --model openai/gpt-6.1-sol:high ' "$t/bstack-judge.md" || fail "judge"
  grep -q '^command: env -u ANTHROPIC_API_KEY -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN BERCAIL_ROLE=autopilot [^ ]*bercail scratch run -- pi --model claude-bridge/claude-opus-5-5:high ' "$t/bstack-autopilot.md" || fail "autopilot"
  grep -q 'bstack-builder.md' "$t/bstack-builder.md" || fail "builder brief"

  assert_eq 'mine' "$(jq -r .defaultModel "$HOME/.pi/agent/settings.json")" "unrelated settings preserved"
  jq -e '.packages == ["npm:pi-claude-bridge@0.12.0"]' "$HOME/.pi/agent/settings.json" >/dev/null || fail "bridge installed"
  assert_eq '{"token":"secret"}' "$(cat "$HOME/.pi/agent/auth.json")" "auth.json untouched"

  assert_eq "$(printf 'claude=claude-bridge/claude-opus-5-5#high\ngpt=openai/gpt-6.1-sol#high')" "$(<"$p/models")" "resolved models, no xAI"
  # A family that lost its login: the judge moves to Claude.
  mkdir -p "$p/extensions/bercail-guard"
  printf 'old guard\n' >"$p/extensions/bercail-guard/index.ts"
  FAKE_PI_READY="claude-bridge" deploy_bstack >/dev/null 2>&1
  [[ ! -d "$p/extensions/bercail-guard" ]] || fail "update removes the old managed guard"
  grep -q 'BERCAIL_ROLE=judge [^ ]*bercail scratch run -- pi --model claude-bridge/claude-opus-5-5:high ' "$t/bstack-judge.md" || fail "judge falls through to Claude"
  unset FAKE_PI_READY
}

@test "an update removes the council seats older releases rendered, and keeps the person's bstack templates" {
  reset_home
  write_pi_config
  export FAKE_PI_READY="claude-bridge openai"
  local t name
  t="$(PI_TEMPLATES)"
  mkdir -p "$t"
  for name in bstack-council-claude bstack-council-gpt bstack-council-grok; do
    printf -- '---\nname: %s\ndescription: x (managed by bercail (bstack))\n---\n' "$name" >"$t/$name.md"
  done
  # A person's own template, whose prompt quotes the marker.
  printf -- '---\nname: bstack-my-review\ndescription: My reviewer\n---\nKeep the managed by bercail (bstack) line.\n' \
    >"$t/bstack-my-review.md"
  deploy_bstack >"$BATS_TEST_TMPDIR/pi.log" 2>&1 || fail "deploy: $(cat "$BATS_TEST_TMPDIR/pi.log")"
  for name in bstack-council-claude bstack-council-gpt bstack-council-grok; do
    [[ ! -e "$t/$name.md" ]] || fail "an update keeps the retired seat $name"
  done
  [[ -f "$t/bstack-my-review.md" ]] || fail "an update removed a template bercail never rendered"
  for name in bstack-builder bstack-judge bstack-autopilot; do
    [[ -f "$t/$name.md" ]] || fail "an update removed the role it renders: $name"
  done
  if grep -rq council "$(PI_DIR)"; then fail "the Pi profile still names the council: $(grep -rl council "$(PI_DIR)")"; fi
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

PI_KEYS() { printf '%s' "$HOME/.pi/agent/keybindings.json"; }

@test "deploy moves the Pi keys the layout's Alt+Up/Down take into a fresh keybindings.json" {
  reset_home
  write_pi_config
  FAKE_PI_READY="claude-bridge" deploy_bstack >"$BATS_TEST_TMPDIR/pi.log" 2>&1 || fail "deploy: $(cat "$BATS_TEST_TMPDIR/pi.log")"
  jq -e '. == {"app.message.dequeue": "alt+q", "app.models.reorderUp": "shift+up", "app.models.reorderDown": "shift+down"}' "$(PI_KEYS)" >/dev/null || fail "keybindings: $(cat "$(PI_KEYS)")"
  FAKE_PI_READY="claude-bridge" deploy_bstack >"$BATS_TEST_TMPDIR/pi.log" 2>&1 || fail "second deploy"
  grep -q "unchanged: $(PI_KEYS)" "$BATS_TEST_TMPDIR/pi.log" || fail "a second deploy changes nothing: $(cat "$BATS_TEST_TMPDIR/pi.log")"
}

@test "deploy adds bercail's Pi keys beside the person's other Pi bindings" {
  reset_home
  write_pi_config
  mkdir -p "$HOME/.pi/agent"
  printf '%s\n' '{"app.session.new": "ctrl+shift+n", "tui.altScreen.pageUp": []}' >"$(PI_KEYS)"
  FAKE_PI_READY="claude-bridge" deploy_bstack >"$BATS_TEST_TMPDIR/pi.log" 2>&1 || fail "deploy: $(cat "$BATS_TEST_TMPDIR/pi.log")"
  jq -e '. == {"app.session.new": "ctrl+shift+n", "tui.altScreen.pageUp": [], "app.message.dequeue": "alt+q", "app.models.reorderUp": "shift+up", "app.models.reorderDown": "shift+down"}' "$(PI_KEYS)" >/dev/null \
    || fail "keybindings: $(cat "$(PI_KEYS)")"

  # A file Pi cannot read stays as it is.
  printf '["not", "keys"]\n' >"$(PI_KEYS)"
  FAKE_PI_READY="claude-bridge" deploy_bstack >"$BATS_TEST_TMPDIR/pi.log" 2>&1 || fail "deploy: $(cat "$BATS_TEST_TMPDIR/pi.log")"
  assert_eq '["not", "keys"]' "$(cat "$(PI_KEYS)")" "unreadable keybindings untouched"
  grep -q 'is not one JSON object; set these Pi keys there by hand' "$BATS_TEST_TMPDIR/pi.log" \
    || fail "says how to fix it: $(cat "$BATS_TEST_TMPDIR/pi.log")"
  printf '{} []\n' >"$(PI_KEYS)"
  FAKE_PI_READY="claude-bridge" deploy_bstack >/dev/null 2>&1 || fail "deploy"
  assert_eq '{} []' "$(cat "$(PI_KEYS)")" "two JSON values untouched"
}

@test "deploy keeps the Pi keys the person set, says so, and uninstall leaves them" {
  reset_home
  write_pi_config
  mkdir -p "$HOME/.pi/agent"
  printf '%s\n' '{"app.message.dequeue": ["ctrl+shift+u"], "app.models.reorderUp": "ctrl+k"}' >"$(PI_KEYS)"
  FAKE_PI_READY="claude-bridge" deploy_bstack >"$BATS_TEST_TMPDIR/pi.log" 2>&1 || fail "deploy: $(cat "$BATS_TEST_TMPDIR/pi.log")"
  jq -e '. == {"app.message.dequeue": ["ctrl+shift+u"], "app.models.reorderUp": "ctrl+k", "app.models.reorderDown": "shift+down"}' \
    "$(PI_KEYS)" >/dev/null || fail "their keys changed: $(cat "$(PI_KEYS)")"
  grep -qF 'keeping your Pi key app.message.dequeue = ["ctrl+shift+u"]' "$BATS_TEST_TMPDIR/pi.log" \
    || fail "says it kept theirs: $(cat "$BATS_TEST_TMPDIR/pi.log")"
  grep -qF 'keeping your Pi key app.models.reorderUp = "ctrl+k"' "$BATS_TEST_TMPDIR/pi.log" \
    || fail "says it kept their reorder key: $(cat "$BATS_TEST_TMPDIR/pi.log")"

  # Their own alt+q is theirs too: bercail did not add it.
  printf '%s\n' '{"app.message.dequeue": "alt+q", "app.models.reorderUp": "ctrl+k"}' >"$(PI_KEYS)"
  FAKE_PI_READY="claude-bridge" deploy_bstack >"$BATS_TEST_TMPDIR/pi.log" 2>&1 || fail "deploy"
  grep -qF 'keeping your Pi key app.message.dequeue = "alt+q"' "$BATS_TEST_TMPDIR/pi.log" \
    || fail "says it kept their alt+q: $(cat "$BATS_TEST_TMPDIR/pi.log")"
  remove_bstack >/dev/null 2>&1
  jq -e '. == {"app.message.dequeue": "alt+q", "app.models.reorderUp": "ctrl+k"}' "$(PI_KEYS)" >/dev/null \
    || fail "uninstall took their keys: $(cat "$(PI_KEYS)" 2>&1)"
}

@test "uninstall takes back only the Pi keys bercail added" {
  reset_home
  write_pi_config
  export FAKE_PI_READY="claude-bridge"
  deploy_bstack >/dev/null 2>&1
  jq -e '.["app.message.dequeue"] == "alt+q"' "$(PI_KEYS)" >/dev/null || fail "deploy adds the key"
  remove_bstack >/dev/null 2>&1
  [[ ! -e "$(PI_KEYS)" ]] || fail "a file left with no binding goes: $(cat "$(PI_KEYS)")"

  printf '%s\n' '{"app.session.new": "ctrl+shift+n"}' >"$(PI_KEYS)"
  deploy_bstack >/dev/null 2>&1
  remove_bstack >/dev/null 2>&1
  jq -e '. == {"app.session.new": "ctrl+shift+n"}' "$(PI_KEYS)" >/dev/null || fail "keybindings: $(cat "$(PI_KEYS)")"

  # Changed after bercail added it: the person's now.
  deploy_bstack >/dev/null 2>&1
  jq '.["app.message.dequeue"] = "alt+w"' "$(PI_KEYS)" >"$BATS_TEST_TMPDIR/k" && mv "$BATS_TEST_TMPDIR/k" "$(PI_KEYS)"
  remove_bstack >/dev/null 2>&1
  jq -e '. == {"app.session.new": "ctrl+shift+n", "app.message.dequeue": "alt+w"}' "$(PI_KEYS)" >/dev/null \
    || fail "uninstall took a changed key: $(cat "$(PI_KEYS)")"

  # An empty file of the person's stays, empty.
  printf '{}\n' >"$(PI_KEYS)"
  deploy_bstack >/dev/null 2>&1
  remove_bstack >/dev/null 2>&1
  jq -e '. == {}' "$(PI_KEYS)" >/dev/null || fail "uninstall removed the person's own file"

  # Uninstall takes the key back from each agent dir it went into, whichever dir
  # Pi is pointed at then, and leaves another dir's own alt+q.
  rm -f "$(PI_KEYS)"
  PI_CODING_AGENT_DIR="$HOME/other-agent" deploy_bstack >/dev/null 2>&1
  printf '%s\n' '{"app.message.dequeue": "alt+q"}' >"$(PI_KEYS)"
  deploy_bstack >/dev/null 2>&1
  PI_CODING_AGENT_DIR="$HOME/third-agent" remove_bstack >/dev/null 2>&1
  [[ ! -e "$HOME/other-agent/keybindings.json" ]] || fail "uninstall left the key in the dir it went into"
  jq -e '. == {"app.message.dequeue": "alt+q"}' "$(PI_KEYS)" >/dev/null || fail "uninstall took another dir's own key"

  # A relative agent dir is the one under the folder deploy ran in.
  mkdir -p "$HOME/a" "$HOME/b/agent"
  (cd "$HOME/a" && PI_CODING_AGENT_DIR=agent deploy_bstack >/dev/null 2>&1)
  printf '%s\n' '{"app.message.dequeue": "alt+q"}' >"$HOME/b/agent/keybindings.json"
  (cd "$HOME/b" && remove_bstack >/dev/null 2>&1)
  [[ ! -e "$HOME/a/agent/keybindings.json" ]] || fail "uninstall left the relative dir's key"
  jq -e '. == {"app.message.dequeue": "alt+q"}' "$HOME/b/agent/keybindings.json" >/dev/null \
    || fail "uninstall from another folder took that folder's own key"

  # A record bercail cannot read stops nothing.
  mkdir -p "$XDG_STATE_HOME/bercail"
  printf '%s\n' "{\"$(PI_KEYS)\": {\"keys\": \"not a map\"}}" >"$XDG_STATE_HOME/bercail/pi-keybindings.json"
  remove_bstack >/dev/null 2>&1 || fail "uninstall stopped on a bad record"
  jq -e '. == {"app.message.dequeue": "alt+q"}' "$(PI_KEYS)" >/dev/null || fail "a bad record changed the file"
  unset FAKE_PI_READY
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
  printf 'mine\n' >"$(PI_TEMPLATES)/bstack-mine.md"
  remove_bstack >/dev/null 2>&1
  [[ ! -d "$(PI_DIR)" && ! -e "$(PI_TEMPLATES)/bstack-builder.md" ]] || fail "remove takes the profile"
  [[ -f "$(PI_TEMPLATES)/reviewer.md" && -f "$(PI_TEMPLATES)/bstack-mine.md" ]] || fail "remove keeps the person's templates"

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
  grep -q 'build = claude-bridge/claude-opus-5-5:high' <<<"$out" || fail "build: $out"
  grep -q 'judge = claude-bridge/claude-opus-5-5:high' <<<"$out" || fail "judge on Opus until ChatGPT is connected: $out"
  grep -q 'gpt.*/login openai' <<<"$out" || fail "missing login hint: $out"
  if grep -qi 'xai\|grok' <<<"$out"; then fail "status lists no xAI, even with an xai login: $out"; fi
  out="$(FAKE_PI_READY="claude-bridge openai" bstack_status)"
  grep -q 'judge = openai/gpt-6.1-sol:high' <<<"$out" || fail "judge on GPT: $out"
  grep -q 'on a limit: a role pauses until it resets' <<<"$out" || fail "status says what a limit does: $out"
  out="$(doctor_bstack)" || fail "doctor ok: $out"
  grep -q 'ok  bstack (lead=claude-bridge/claude-opus-5-5:high)' <<<"$out" || fail "doctor: $out"
  grep -q "ok  pi-emphasis $(jq -r '.[] | select(.name == "pi-emphasis") | .known[0:12]' "$ROOT/lib/deps.json") " <<<"$out" \
    || fail "doctor names the pinned pi-emphasis: $out"
  rm -f "$(PI_DIR)/extensions/pi-emphasis/index.ts"
  if out="$(doctor_bstack)"; then fail "doctor: pi-emphasis missing"; fi
  grep -q 'missing  bstack .*/extensions/pi-emphasis/index.ts (bercail update)' <<<"$out" || fail "doctor missing pi-emphasis: $out"
  deploy_bstack >/dev/null 2>&1
  if out="$(FAKE_PI_READY="claude-bridge openai" doctor_bstack)"; then
    fail "doctor: a new login is a due update"
  fi
  grep -q 'stale  bstack models' <<<"$out" || fail "doctor stale: $out"
  if out="$(FAKE_PI_READY="" doctor_bstack)"; then fail "doctor: no login"; fi
  grep -q 'none of Claude Code, openai is ready' <<<"$out" || fail "doctor no login: $out"
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
  grep -q '/login openai' "$BATS_TEST_TMPDIR/setup.log" || fail "setup hints: $(cat "$BATS_TEST_TMPDIR/setup.log")"
  if grep -qi 'xai\|grok' "$BATS_TEST_TMPDIR/setup.log"; then fail "setup names no xAI: $(cat "$BATS_TEST_TMPDIR/setup.log")"; fi
  local sub out
  for sub in on off; do
    if out="$(cmd_bstack "$sub" 2>&1)"; then fail "bstack $sub ran: $out"; fi
    [[ "$out" == 'error: usage: bercail bstack status|setup' ]] || fail "bstack $sub: $out"
  done
  [[ -f "$(PI_DIR)/lead.json" ]] || fail "off removed nothing"
}

@test "every Pi role template and the empty-role lead runs on a scratch TMPDIR, loads bridge, fallback then guard, pi-emphasis, the prompts, instructions and skill, and unsets Anthropic env" {
  reset_home
  write_pi_config
  export FAKE_PI_READY="claude-bridge openai"
  deploy_bstack >/dev/null 2>&1
  export ANTHROPIC_API_KEY=secret ANTHROPIC_BASE_URL=https://wrong ANTHROPIC_AUTH_TOKEN=secret
  export FAKE_PI_LAUNCH_LOG="$BATS_TEST_TMPDIR/pi-launch"
  # The templates start Pi through this checkout's bercail scratch run.
  ln -s "$ROOT/bin/bercail" "$FAKE_BIN/bercail"
  local template p args scratch
  p="$(PI_DIR)"
  # The fake logs one argument a line: WHAT... must be whole arguments, in order.
  has_run() { # who what...
    local who="$1" run
    shift
    run="$(printf '%s\n' "$@")"
    [[ "$args" == *$'\n'"$run"$'\n'* ]] || fail "$who starts pi without '$*': $args"
  }
  launched() {
    rm -f "$FAKE_PI_LAUNCH_LOG" "$FAKE_PI_LAUNCH_LOG.env"
    eval "$1"
    scratch="$(sed -n 's/^TMPDIR=//p' "$FAKE_PI_LAUNCH_LOG.env")"
    [[ "$scratch" == "$XDG_CACHE_HOME/bercail/scratch/"* && ! -e "$scratch" ]] \
      || fail "$2 runs Pi on a scratch TMPDIR it removes after: $scratch"
    args=$'\n'"$(<"$FAKE_PI_LAUNCH_LOG")"$'\n'
    has_run "$2" -e npm:pi-claude-bridge@0.12.0
    has_run "$2" -e "$p/extensions/fallback.ts" -e "$p/extensions/guard.ts"
    has_run "$2" -e "$p/extensions/pi-emphasis/index.ts"
    has_run "$2" --prompt-template "$p/prompts"
    has_run "$2" --append-system-prompt "$p/instructions.md"
    has_run "$2" --skill "$(skill_canonical_dir bstack)"
    if grep -q '^ANTHROPIC_' "$FAKE_PI_LAUNCH_LOG.env"; then fail "Anthropic env leaked from $2"; fi
  }
  for template in "$(PI_TEMPLATES)"/bstack-*.md; do
    launched "$(awk '/^command: / { sub(/^command: /, ""); print }' "$template")" "$template"
  done
  launched "$(bstack_pi_command '' "$(bstack_role_model lead)")" lead
  _bstack_pi_claude_ready || fail "Claude auth probe also sanitizes env"
  unset ANTHROPIC_API_KEY ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN FAKE_PI_LAUNCH_LOG FAKE_PI_READY
}

@test "doctor catches missing bstack data files" {
  reset_home
  write_pi_config
  export FAKE_PI_READY="claude-bridge openai"
  deploy_bstack >/dev/null 2>&1
  doctor_bstack >/dev/null || fail "doctor after deploy"
  local out
  rm "$(PI_DIR)/models" "$(PI_DIR)/extensions/guard.ts" "$(PI_DIR)/agents/bstack-headless.md"
  if out="$(doctor_bstack)"; then fail "doctor missing data files"; fi
  grep -q 'missing  bstack .*models' <<<"$out" || fail "missing models: $out"
  grep -q 'missing  bstack .*extensions/guard.ts' <<<"$out" || fail "missing guard: $out"
  grep -q 'missing  bstack .*bstack-headless.md' <<<"$out" || fail "missing headless brief: $out"
  unset FAKE_PI_READY
}

@test "doctor reports providers the fallback found dead in the last day, the latest per provider, and skips bad lines" {
  reset_home
  write_pi_config
  export FAKE_PI_READY="claude-bridge openai"
  deploy_bstack >/dev/null 2>&1
  local log="$XDG_STATE_HOME/bercail/fallback-dead.jsonl" out
  mkdir -p "$(dirname "$log")"
  {
    printf '{"at":"%s","provider":"claude-bridge","model":"claude-bridge/claude-opus-5-5","reason":"old"}\n' "$(date -u -d '-2 days' +%FT%T.000Z)"
    printf 'not json\n'
    printf '{"at":"%s","provider":"openai","model":"openai/gpt-6-sol","reason":"first"}\n' "$(date -u -d '-1 hour' +%FT%T.000Z)"
    printf '{"at":"%s","provider":"openai","model":"openai/gpt-6.1-sol","reason":"402 out of credits"}\n' "$(date -u +%FT%T.000Z)"
  } >"$log"
  out="$(doctor_bstack)" || fail "a dead provider is a report, not a failure: $out"
  [[ "$(grep -c '  dead  ' <<<"$out")" -eq 1 ]] || fail "one dead line: $out"
  grep -q 'dead  bstack openai (openai/gpt-6.1-sol) at .*: 402 out of credits (add credits or a subscription)' <<<"$out" || fail "latest openai record: $out"
  unset FAKE_PI_READY
}

@test "doctor counts the guard's warnings and refusals of the last 7 days, names the most frequent, and skips bad lines" {
  reset_home
  write_pi_config
  export FAKE_PI_READY="claude-bridge openai"
  deploy_bstack >/dev/null 2>&1
  local log="$XDG_STATE_HOME/bercail/guard-warnings.jsonl" out now
  out="$(doctor_bstack)" || fail "doctor with no guard log: $out"
  grep -qx '  ok  guard: no warnings or refusals in the last 7 days' <<<"$out" || fail "no log: $out"
  now="$(date -u +%FT%T.000Z)"
  mkdir -p "$(dirname "$log")"
  {
    printf '{"at":"%s","kind":"refusal","reasons":["old"]}\n' "$(date -u -d '-8 days' +%FT%T.000Z)"
    printf 'not json\n'
    printf '{"at":"%s","kind":"warning","reasons":["This commit ran"]}\n' "$now"
    printf '{"at":"%s","kind":"warning","reasons":["This commit ran","lost track"]}\n' "$now"
    printf '{"at":"%s","kind":"refusal","reasons":["Force-push is blocked."]}\n' "$now"
  } >"$log"
  out="$(doctor_bstack)" || fail "guard warnings are a report, not a failure: $out"
  grep -qF '  guard  2 warning(s) and 1 refusal(s) in the last 7 days; most often (2): This commit ran' <<<"$out" \
    || fail "counts: $out"
  grep -qF "(jq . $log)" <<<"$out" || fail "no pointer to the log: $out"
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
  grep -q 'bstack: log in to Claude and ChatGPT with bercail bstack setup' <<<"$out" || fail "summary: $out"
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

@test "a role starts through ~/.local/bin/bercail, or the bercail on PATH when bercail is packaged" {
  mkdir -p "$LOCAL_BIN"
  printf '#!/bin/sh\n' >"$LOCAL_BIN/bercail"
  chmod +x "$LOCAL_BIN/bercail"
  [[ "$(bstack_pi_command judge '')" == *"BERCAIL_ROLE=judge $LOCAL_BIN/bercail scratch run -- pi "* ]] \
    || fail "installed: $(bstack_pi_command judge '')"
  [[ "$(BERCAIL_PACKAGED=1 bstack_pi_command judge '')" == *"BERCAIL_ROLE=judge bercail scratch run -- pi "* ]] \
    || fail "packaged, past an old ~/.local/bin/bercail: $(BERCAIL_PACKAGED=1 bstack_pi_command judge '')"
}
