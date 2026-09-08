#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$TEST_DIR/.." && pwd)"
TMP_DIR="$(mktemp -d)"
FAKE_BIN="$TMP_DIR/bin"
HERDR_CALL_LOG="$TMP_DIR/herdr-calls.log"
HOST_XDG_STATE_HOME="${XDG_STATE_HOME-}"

cleanup() {
  rm -rf "$TMP_DIR"
  printf 'CLEANUP PASS: removed isolated HOME/XDG fixture: %s\n' "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  local expected="$1" actual="$2" message="$3"
  [[ "$actual" == "$expected" ]] || fail "$message (expected=$expected actual=$actual)"
}

assert_file_eq() {
  local expected="$1" actual="$2" message="$3"
  cmp -s "$expected" "$actual" || fail "$message ($actual differs from $expected)"
}

assert_log_count() {
  local pattern="$1" expected="$2"
  local actual
  actual="$(grep -cE "$pattern" "$HERDR_CALL_LOG" 2>/dev/null || true)"
  assert_eq "$expected" "$actual" "unexpected fake Herdr call count for $pattern"
}

checksum() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d ' ' -f 1
  else
    shasum -a 256 "$1" | cut -d ' ' -f 1
  fi
}

registry_path() {
  printf '%s/herdr/plugins.json' "$XDG_CONFIG_HOME"
}

write_registry() {
  mkdir -p "$(dirname "$(registry_path)")"
  printf '%s\n' "$1" >"$(registry_path)"
}

seed_github() {
  local id="$1" repo="$2" ref="$3"
  local owner="${repo%%/*}" name="${repo#*/}" root
  root="$XDG_CONFIG_HOME/herdr/plugins/github/${id}-${ref}"
  mkdir -p "$root"
  printf 'source-%s\n' "$ref" >"$root/sentinel"
  write_registry "$(jq -n \
    --arg id "$id" --arg owner "$owner" --arg repo "$name" --arg ref "$ref" --arg root "$root" \
    '[{plugin_id:$id,plugin_root:$root,source:{kind:"github",owner:$owner,repo:$repo,resolved_commit:$ref,managed_path:$root}}]')"
}

pickr_config_path() {
  printf '%s/herdr/plugins/config/pickr/config.toml' "$XDG_CONFIG_HOME"
}

registry_source() {
  local id="$1"
  jq -r --arg id "$id" \
    '.[] | select(.plugin_id == $id) | if .source.kind == "local" then "local:" + .plugin_root else "github:" + .source.owner + "/" + .source.repo + "@" + .source.resolved_commit end' \
    "$(registry_path)"
}

seed_pickr_config() {
  local content="$1" path
  path="$(pickr_config_path)"
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$content" >"$path"
}

reset_fixture() {
  rm -rf "$HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME"
  mkdir -p "$HOME" "$XDG_CONFIG_HOME/herdr" "$XDG_STATE_HOME"
  write_registry '[]'
  : >"$HERDR_CALL_LOG"
}

mkdir -p "$FAKE_BIN"
cat >"$FAKE_BIN/herdr" <<'FAKE_HERDR'
#!/usr/bin/env bash
set -euo pipefail

registry="${XDG_CONFIG_HOME}/herdr/plugins.json"
printf '%s\n' "$*" >>"$HERDR_CALL_LOG"

if [[ "${1:-}" == "--version" ]]; then
  printf 'herdr 0.9.0\n'
  exit 0
fi

write_entry() {
  local entry="$1" tmp="${registry}.tmp"
  jq --argjson entry "$entry" \
    '[.[] | select(.plugin_id != $entry.plugin_id)] + [$entry]' "$registry" >"$tmp"
  mv "$tmp" "$registry"
}

remove_entry() {
  local id="$1" tmp="${registry}.tmp"
  jq --arg id "$id" '[.[] | select(.plugin_id != $id)]' "$registry" >"$tmp"
  mv "$tmp" "$registry"
}

case "${1:-} ${2:-}" in
  'plugin list')
    jq -r '.[] | if .source.kind == "local" then
      "- \(.plugin_id) (fixture) enabled [local:\(.plugin_root)]"
    else
      "- \(.plugin_id) (fixture) enabled [github:\(.source.owner)/\(.source.repo)@\(.source.resolved_commit)]"
    end' "$registry"
    ;;
  'integration install'|'integration status'|'integration uninstall')
    exit 0
    ;;
  'plugin install')
    source_name="${3:?missing plugin source}"
    shift 3
    ref=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --ref) ref="${2:?missing ref}"; shift 2 ;;
        --yes) shift ;;
        *) shift ;;
      esac
    done
    case "$source_name" in
      simoncrypta/agentic-dev-setup/plugins/agentic-layout) id='agentic-dev.layout' ;;
      simoncrypta/herdr-agentic-layout) id='agentic-dev.layout' ;;
      simoncrypta/herdr-dev-layout) id='agentic-dev.dev-layout' ;;
      tomasvarga/herdr-pickr) id='pickr' ;;
      devashish2203/herdr-worktrunk) id='worktrunk' ;;
      *) exit 64 ;;
    esac
    owner="${source_name%%/*}"
    repo="${source_name#*/}"
    root="${XDG_CONFIG_HOME}/herdr/plugins/github/${id}-${ref}"
    mkdir -p "$root"
    entry="$(jq -n --arg id "$id" --arg owner "$owner" --arg repo "$repo" \
      --arg ref "$ref" --arg root "$root" \
      '{plugin_id:$id,plugin_root:$root,source:{kind:"github",owner:$owner,repo:$repo,resolved_commit:$ref,managed_path:$root}}')"
    write_entry "$entry"
    ;;
  'plugin link')
    root="${3:?missing plugin root}"
    id="$(grep -m 1 -E '^id[[:space:]]*=' "$root/herdr-plugin.toml" | cut -d '"' -f 2)"
    entry="$(jq -n --arg id "$id" --arg root "$root" \
      '{plugin_id:$id,plugin_root:$root,manifest_path:($root + "/herdr-plugin.toml"),source:{kind:"local"}}')"
    write_entry "$entry"
    ;;
  'plugin unlink')
    remove_entry "${3:?missing plugin id}"
    ;;
  'plugin uninstall')
    remove_entry "${3:?missing plugin id}"
    ;;
  'plugin config-dir')
    printf '%s\n' "${XDG_CONFIG_HOME}/herdr/plugins/config/${3:?missing plugin id}"
    ;;
  *)
    exit 64
    ;;
esac
FAKE_HERDR
chmod +x "$FAKE_BIN/herdr"

export HOME="$TMP_DIR/home"
export XDG_CONFIG_HOME="$TMP_DIR/xdg-config"
export XDG_STATE_HOME="$TMP_DIR/xdg-state"
export HERDR_CALL_LOG
export PATH="$FAKE_BIN:$PATH"
export INSTALL_SRC="$ROOT"

# shellcheck source=/dev/null
source "$ROOT/lib/common.sh"
# shellcheck source=/dev/null
source "$ROOT/lib/deps.sh"
# shellcheck source=/dev/null
source "$ROOT/lib/config.sh"
# shellcheck source=/dev/null
source "$ROOT/lib/skills.sh"
# shellcheck source=/dev/null
source "$ROOT/lib/detect.sh"

HERDR_CONFIG_DIR="$XDG_CONFIG_HOME/herdr"
export HERDR_DEV_LAYOUT_LEGACY_DIR="$HERDR_CONFIG_DIR/plugins/dev-layout"
export AGENTIC_DEV_CONFIG_DIR="$XDG_CONFIG_HOME/agentic-dev"
export AGENTIC_DEV_SHELL_DIR="$AGENTIC_DEV_CONFIG_DIR/shell"
export AGENTIC_DEV_USER_CONFIG="$AGENTIC_DEV_CONFIG_DIR/config.toml"
export WORKTRUNK_CONFIG_DIR="$XDG_CONFIG_HOME/worktrunk"
export FCITX5_CONFIG_DIR="$XDG_CONFIG_HOME/fcitx5"
export LOCAL_BIN="$HOME/.local/bin"
export YES=1
export DRY_RUN=0
export FORCE=0

test_templates_parse_and_platform_shape() {
  local template field
  # mise shims keep trust state under XDG_STATE_HOME, which this fixture isolates.
  for template in config.linux.toml config.macos.toml; do
    if [[ -n "$HOST_XDG_STATE_HOME" ]]; then
      XDG_STATE_HOME="$HOST_XDG_STATE_HOME" \
        python3 -c 'import tomllib, sys; tomllib.load(open(sys.argv[1], "rb"))' \
        "$ROOT/config/pickr/$template" || fail "template does not parse: $template"
    else
      env -u XDG_STATE_HOME python3 -c 'import tomllib, sys; tomllib.load(open(sys.argv[1], "rb"))' \
        "$ROOT/config/pickr/$template" || fail "template does not parse: $template"
    fi
    for field in \
      'auto    = false' \
      'default = "tuicr"' \
      'id  = "tuicr"' \
      'id  = "hunk"' \
      'id  = "diff"' \
      'id  = "browser"'; do
      grep -qF "$field" "$ROOT/config/pickr/$template" \
        || fail "template $template is missing: $field"
    done
  done
  grep -qF 'run  = "xdg-open {url}"' "$ROOT/config/pickr/config.linux.toml" \
    || fail "linux template does not use xdg-open"
  grep -qF 'run  = "open {url}"' "$ROOT/config/pickr/config.macos.toml" \
    || fail "macos template does not use open"
  if grep -qF 'xdg-open' "$ROOT/config/pickr/config.macos.toml"; then
    fail "macos template contains xdg-open"
  fi
  if grep -qE 'run  = "open \{url\}"' "$ROOT/config/pickr/config.linux.toml"; then
    fail "linux template contains the macOS open command"
  fi
  printf 'PASS: both templates parse and carry platform-correct browser commands\n'
}

test_fresh_linux_install_writes_template() {
  reset_fixture
  deploy_plugin >/dev/null
  assert_file_eq "$ROOT/config/pickr/config.linux.toml" "$(pickr_config_path)" \
    "fresh linux install did not write the linux pickr template"
  assert_log_count '^plugin install tomasvarga/herdr-pickr --ref e393ef593e44d2497f43d20aa7b0e4a26ea3d445 --yes$' 1
  assert_log_count '^plugin config-dir pickr$' 1
  printf 'PASS: fresh linux install writes the linux template and installs pickr at the exact SHA\n'
}

test_fresh_macos_install_writes_template() {
  local host_os
  reset_fixture
  host_os="$(detect_os)"
  detect_os() { printf 'macos'; }
  deploy_plugin >/dev/null
  assert_file_eq "$ROOT/config/pickr/config.macos.toml" "$(pickr_config_path)" \
    "fresh macos install did not write the macos pickr template"
  # shellcheck source=/dev/null
  source "$ROOT/lib/detect.sh"
  assert_eq "$host_os" "$(detect_os)" "detect_os was not restored after the macOS branch"
  printf 'PASS: fresh macos install writes the macos template\n'
}

test_second_deploy_is_config_noop() {
  local before after
  reset_fixture
  deploy_plugin >/dev/null
  before="$(checksum "$(pickr_config_path)")"
  : >"$HERDR_CALL_LOG"
  deploy_plugin >/dev/null
  after="$(checksum "$(pickr_config_path)")"
  assert_eq "$before" "$after" "second deploy changed the pickr config"
  assert_log_count '^plugin install tomasvarga/herdr-pickr ' 0
  printf 'PASS: repeated deploy keeps the pickr config and plugin untouched\n'
}

test_existing_config_preserved_across_install_update_force() {
  local before output="$TMP_DIR/preserve.output"
  reset_fixture
  seed_pickr_config 'custom-pickr-config'
  before="$(checksum "$(pickr_config_path)")"

  deploy_plugin >"$output"
  assert_eq "$before" "$(checksum "$(pickr_config_path)")" "install changed an existing pickr config"
  grep -q 'keeping existing pickr config' "$output" || fail "install did not report keeping existing pickr config"
  assert_log_count '^plugin install tomasvarga/herdr-pickr ' 1

  deploy_plugin >"$output"
  assert_eq "$before" "$(checksum "$(pickr_config_path)")" "update changed an existing pickr config"

  export FORCE=1
  deploy_configs >"$output"
  export FORCE=0
  assert_eq "$before" "$(checksum "$(pickr_config_path)")" "update --force changed an existing pickr config"
  grep -q 'keeping existing pickr config' "$output" || fail "update --force did not report keeping existing pickr config"
  assert_eq 'custom-pickr-config' "$(tr -d '\n' <"$(pickr_config_path)")" "pickr config content changed"
  printf 'PASS: existing pickr config is byte-identical across install, update, and update --force\n'
}

test_mismatched_pickr_preserved_with_warning() {
  local before warning_log="$TMP_DIR/mismatch.warning"
  reset_fixture
  seed_github pickr someone/custom-pickr user-ref
  seed_pickr_config 'custom-pickr-config'
  before="$(checksum "$(pickr_config_path)")"
  deploy_plugin >/dev/null 2>"$warning_log"
  assert_eq 'github:someone/custom-pickr@user-ref' "$(registry_source pickr)" \
    "mismatched pickr registration was replaced"
  grep -q 'preserving pre-existing Herdr plugin pickr' "$warning_log" \
    || fail "mismatched pickr source did not produce a preservation warning"
  assert_log_count '^plugin install tomasvarga/herdr-pickr ' 0
  assert_log_count '^plugin (uninstall|unlink) pickr$' 0
  assert_eq "$before" "$(checksum "$(pickr_config_path)")" \
    "mismatched pickr changed an existing pickr config"

  reset_fixture
  seed_github pickr someone/custom-pickr user-ref
  deploy_plugin >/dev/null 2>"$warning_log"
  assert_eq 'github:someone/custom-pickr@user-ref' "$(registry_source pickr)" \
    "mismatched pickr without config was replaced"
  grep -q 'preserving pre-existing Herdr plugin pickr' "$warning_log" \
    || fail "mismatched pickr without config did not warn"
  assert_log_count '^plugin install tomasvarga/herdr-pickr ' 0
  assert_file_eq "$ROOT/config/pickr/config.linux.toml" "$(pickr_config_path)" \
    "mismatched pickr without config did not receive portable defaults"
  printf 'PASS: pre-existing mismatched pickr source is only warned about and preserved\n'
}

test_dry_run_describes_pickr_config_without_mutation() {
  local output="$TMP_DIR/dry-run.output"
  reset_fixture
  export DRY_RUN=1
  deploy_plugin >"$output"
  export DRY_RUN=0
  [[ ! -e "$(pickr_config_path)" ]] || fail "dry-run wrote a pickr config"
  grep -q 'config/pickr/config.linux.toml' "$output" || fail "dry-run omitted the pickr template path"
  grep -q '\[dry-run\]' "$output" || fail "dry-run output missing dry-run markers"

  seed_pickr_config 'custom-pickr-config'
  export DRY_RUN=1
  deploy_plugin >"$output"
  export DRY_RUN=0
  grep -q 'keeping existing pickr config' "$output" \
    || fail "dry-run with an existing config did not say keeping existing"
  assert_eq 'custom-pickr-config' "$(tr -d '\n' <"$(pickr_config_path)")" \
    "dry-run changed an existing pickr config"
  printf 'PASS: dry-run describes the pickr config plan and says keeping existing\n'
}

test_templates_parse_and_platform_shape
test_fresh_linux_install_writes_template
test_fresh_macos_install_writes_template
test_second_deploy_is_config_noop
test_existing_config_preserved_across_install_update_force
test_mismatched_pickr_preserved_with_warning
test_dry_run_describes_pickr_config_without_mutation
printf 'ALL PASS: pickr portable defaults fixture matrix\n'
