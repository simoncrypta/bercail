#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$TEST_DIR/.." && pwd)"
TMP_DIR="$(mktemp -d)"
FAKE_BIN="$TMP_DIR/bin"
HERDR_CALL_LOG="$TMP_DIR/herdr-calls.log"

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

append_github() {
  local id="$1" repo="$2" ref="$3"
  local owner="${repo%%/*}" name="${repo#*/}" root tmp
  root="$XDG_CONFIG_HOME/herdr/plugins/github/${id}-${ref}"
  tmp="$(registry_path).tmp"
  mkdir -p "$root"
  printf 'source-%s\n' "$ref" >"$root/sentinel"
  jq --arg id "$id" --arg owner "$owner" --arg repo "$name" --arg ref "$ref" --arg root "$root" \
    '. + [{plugin_id:$id,plugin_root:$root,source:{kind:"github",owner:$owner,repo:$repo,resolved_commit:$ref,managed_path:$root}}]' \
    "$(registry_path)" >"$tmp"
  mv "$tmp" "$(registry_path)"
}

seed_local() {
  local id="$1" path="$2"
  write_registry "$(jq -n --arg id "$id" --arg path "$path" \
    '[{plugin_id:$id,plugin_root:$path,manifest_path:($path + "/herdr-plugin.toml"),source:{kind:"local"}}]')"
}

seed_legacy_dir() {
  mkdir -p "$HERDR_DEV_LAYOUT_LEGACY_DIR"
  printf 'id = "%s"\n' "$PLUGIN_ID" >"$HERDR_DEV_LAYOUT_LEGACY_DIR/herdr-plugin.toml"
  printf 'legacy\n' >"$HERDR_DEV_LAYOUT_LEGACY_DIR/sentinel"
}

registry_source() {
  local id="$1"
  jq -r --arg id "$id" \
    '.[] | select(.plugin_id == $id) | if .source.kind == "local" then "local:" + .plugin_root else "github:" + .source.owner + "/" + .source.repo + "@" + .source.resolved_commit end' \
    "$(registry_path)"
}

reset_fixture() {
  rm -rf "$HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME"
  mkdir -p "$HOME" "$XDG_CONFIG_HOME/herdr" "$XDG_STATE_HOME"
  write_registry '[]'
  : >"$HERDR_CALL_LOG"
  unset FAKE_HERDR_FAIL_INSTALL FAKE_HERDR_MISLEAD_INSTALL \
    FAKE_HERDR_SIGNAL_INSTALL FAKE_HERDR_LIST_OUTPUT FAKE_HERDR_FAIL_ALL_INSTALL \
    FAKE_HERDR_FAIL_REMOVE FAKE_HERDR_SIGNAL_AFTER_REMOVE \
    FAKE_HERDR_UNTRUSTED_PLUGIN_ROOT FAKE_HERDR_SWAP_MANAGED_ROOT \
    FAKE_HERDR_SWAP_MANAGED_ROOT_TARGET FAKE_HERDR_VERSION_OUTPUT \
    AGENTIC_DEV_ON_ROLLBACK_ARMED
}

mkdir -p "$FAKE_BIN"
cat >"$FAKE_BIN/herdr" <<'FAKE_HERDR'
#!/usr/bin/env bash
set -euo pipefail

registry="${XDG_CONFIG_HOME}/herdr/plugins.json"
printf '%s\n' "$*" >>"$HERDR_CALL_LOG"

if [[ "${1:-}" == "--version" ]]; then
  printf '%s\n' "${FAKE_HERDR_VERSION_OUTPUT:-herdr 0.9.0}"
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

remove_managed_source() {
  local id="$1" root
  root="$(jq -r --arg id "$id" '.[] | select(.plugin_id == $id) | .plugin_root // empty' "$registry")"
  [[ -z "$root" ]] || rm -rf "$root"
}

signal_after_remove() {
  local parent="$PPID"
  [[ "${FAKE_HERDR_SIGNAL_AFTER_REMOVE:-0}" != 1 ]] || {
    printf 'signal TERM after-remove\n' >>"$HERDR_CALL_LOG"
    kill -TERM "$parent"
  }
}

case "${1:-} ${2:-}" in
  'plugin list')
    if [[ -n "${FAKE_HERDR_LIST_OUTPUT:-}" ]]; then
      printf '%s\n' "$FAKE_HERDR_LIST_OUTPUT"
      exit 0
    fi
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
    if [[ "${FAKE_HERDR_SIGNAL_INSTALL:-0}" == 1 ]]; then
      if [[ -z "${FAKE_HERDR_FAILURE_REF:-}" || "$ref" == "$FAKE_HERDR_FAILURE_REF" ]]; then
        kill -TERM "$PPID"
        exit 143
      fi
    fi
    if [[ "${FAKE_HERDR_FAIL_INSTALL:-0}" == 1 ]]; then
      if [[ -z "${FAKE_HERDR_FAILURE_REF:-}" || "$ref" == "$FAKE_HERDR_FAILURE_REF" ]]; then
        exit 42
      fi
    fi
    [[ "${FAKE_HERDR_FAIL_ALL_INSTALL:-0}" != 1 ]] || exit 42
    [[ "${FAKE_HERDR_MISLEAD_INSTALL:-0}" != 1 ]] || exit 0
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
    if [[ -n "${FAKE_HERDR_UNTRUSTED_PLUGIN_ROOT:-}" ]]; then
      if [[ -n "${FAKE_HERDR_SWAP_MANAGED_ROOT:-}" ]]; then
        rm -f "$FAKE_HERDR_SWAP_MANAGED_ROOT"
        ln -s "$FAKE_HERDR_SWAP_MANAGED_ROOT_TARGET" "$FAKE_HERDR_SWAP_MANAGED_ROOT"
      fi
      entry="$(jq -n --arg id "$id" --arg owner "$owner" --arg repo "$repo" \
        --arg ref "$ref" --arg root "$FAKE_HERDR_UNTRUSTED_PLUGIN_ROOT" \
        '{plugin_id:$id,plugin_root:$root,source:{kind:"github",owner:$owner,repo:$repo,resolved_commit:$ref,managed_path:$root}}')"
      write_entry "$entry"
      exit 42
    fi
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
    [[ "${FAKE_HERDR_FAIL_REMOVE:-0}" != 1 ]] || exit 43
    remove_entry "${3:?missing plugin id}"
    signal_after_remove
    ;;
  'plugin uninstall')
    [[ "${FAKE_HERDR_FAIL_REMOVE:-0}" != 1 ]] || exit 43
    remove_managed_source "${3:?missing plugin id}"
    remove_entry "${3:?missing plugin id}"
    signal_after_remove
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

# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=lib/deps.sh
source "$ROOT/lib/deps.sh"
# shellcheck source=lib/config.sh
source "$ROOT/lib/config.sh"
# shellcheck source=lib/skills.sh
source "$ROOT/lib/skills.sh"
# shellcheck source=lib/detect.sh
source "$ROOT/lib/detect.sh"
# shellcheck source=lib/shell-rc.sh
source "$ROOT/lib/shell-rc.sh"
# shellcheck source=lib/uninstall.sh
source "$ROOT/lib/uninstall.sh"
# shellcheck source=lib/doctor.sh
source "$ROOT/lib/doctor.sh"

HERDR_CONFIG_DIR="$XDG_CONFIG_HOME/herdr"
HERDR_DEV_LAYOUT_LEGACY_DIR="$HERDR_CONFIG_DIR/plugins/dev-layout"
export AGENTIC_DEV_CONFIG_DIR="$XDG_CONFIG_HOME/agentic-dev"
export AGENTIC_DEV_SHELL_DIR="$AGENTIC_DEV_CONFIG_DIR/shell"
export AGENTIC_DEV_USER_CONFIG="$AGENTIC_DEV_CONFIG_DIR/config.toml"
export WORKTRUNK_CONFIG_DIR="$XDG_CONFIG_HOME/worktrunk"
export FCITX5_CONFIG_DIR="$XDG_CONFIG_HOME/fcitx5"
export LOCAL_BIN="$HOME/.local/bin"
export YES=1
export DRY_RUN=0
export FORCE=0

run_failing_first_proofs() {
  local failures=0 before after install_count

  reset_fixture
  deploy_plugin >/dev/null
  deploy_plugin >/dev/null
  install_count="$(grep -cE '^plugin install simoncrypta/agentic-dev-setup/plugins/agentic-layout ' "$HERDR_CALL_LOG" || true)"
  if [[ "$install_count" != 1 ]]; then
    printf 'FAILING-FIRST: repeated deploy expected one GitHub install, got %s\n' "$install_count" >&2
    failures=$((failures + 1))
  fi

  reset_fixture
  seed_github pickr someone/custom-pickr user-ref
  before="$(checksum "$(registry_path)")"
  if ! declare -F ensure_adopted_github_plugin >/dev/null \
    || ! ensure_adopted_github_plugin pickr tomasvarga/herdr-pickr expected-ref >/dev/null 2>&1; then
    printf 'FAILING-FIRST: third-party preserve helper is absent\n' >&2
    failures=$((failures + 1))
  fi
  after="$(checksum "$(registry_path)")"
  [[ "$before" == "$after" ]] || {
    printf 'FAILING-FIRST: mismatched third-party registry changed\n' >&2
    failures=$((failures + 1))
  }

  reset_fixture
  seed_legacy_dir
  seed_local agentic-dev.layout "$HERDR_DEV_LAYOUT_LEGACY_DIR"
  export FAKE_HERDR_FAIL_INSTALL=1
  if ! declare -F ensure_managed_github_plugin >/dev/null; then
    printf 'FAILING-FIRST: transactional migration helper is absent\n' >&2
    failures=$((failures + 1))
  elif ensure_managed_github_plugin agentic-dev.layout "$DEV_LAYOUT_PLUGIN_REPO" v0.1.0 "$HERDR_DEV_LAYOUT_LEGACY_DIR" >/dev/null 2>&1; then
    printf 'FAILING-FIRST: injected migration failure returned success\n' >&2
    failures=$((failures + 1))
  fi
  [[ -f "$HERDR_DEV_LAYOUT_LEGACY_DIR/sentinel" ]] || {
    printf 'FAILING-FIRST: migration failure lost the legacy directory\n' >&2
    failures=$((failures + 1))
  }

  printf 'FAILING-FIRST RESULT: %d required behaviors missing\n' "$failures"
  [[ "$failures" -eq 0 ]]
}

if [[ "${PLUGIN_TEST_FAILING_FIRST:-0}" == 1 ]]; then
  run_failing_first_proofs
  exit
fi

test_managed_missing_exact_and_update() {
  local before after
  reset_fixture
  ensure_managed_github_plugin agentic-dev.layout \
    "$DEV_LAYOUT_PLUGIN_REPO" "$DEV_LAYOUT_PLUGIN_REF" "$HERDR_DEV_LAYOUT_LEGACY_DIR"
  assert_eq "github:$DEV_LAYOUT_PLUGIN_REPO@$DEV_LAYOUT_PLUGIN_REF" \
    "$(registry_source agentic-dev.layout)" "missing managed plugin was not installed at the exact pin"
  assert_log_count '^plugin install simoncrypta/agentic-dev-setup/plugins/agentic-layout ' 1

  before="$(checksum "$(registry_path)")"
  ensure_managed_github_plugin agentic-dev.layout \
    "$DEV_LAYOUT_PLUGIN_REPO" "$DEV_LAYOUT_PLUGIN_REF" "$HERDR_DEV_LAYOUT_LEGACY_DIR"
  after="$(checksum "$(registry_path)")"
  assert_eq "$before" "$after" "exact managed plugin changed the registry"
  assert_log_count '^plugin install simoncrypta/agentic-dev-setup/plugins/agentic-layout ' 1

  seed_github agentic-dev.layout "$DEV_LAYOUT_PLUGIN_REPO" old-ref
  : >"$HERDR_CALL_LOG"
  ensure_managed_github_plugin agentic-dev.layout \
    "$DEV_LAYOUT_PLUGIN_REPO" "$DEV_LAYOUT_PLUGIN_REF" "$HERDR_DEV_LAYOUT_LEGACY_DIR"
  assert_eq "github:$DEV_LAYOUT_PLUGIN_REPO@$DEV_LAYOUT_PLUGIN_REF" \
    "$(registry_source agentic-dev.layout)" "old managed ref was not updated"
  assert_log_count '^plugin uninstall agentic-dev.layout$' 1
  printf 'PASS: managed missing/exact/wrong-ref matrix\n'
}

test_managed_wrong_source_preserved() {
  local before after warning_log="$TMP_DIR/wrong-source.warning"
  reset_fixture
  seed_github agentic-dev.layout someone/custom-layout user-ref
  before="$(checksum "$(registry_path)")"
  ensure_managed_github_plugin agentic-dev.layout \
    "$DEV_LAYOUT_PLUGIN_REPO" "$DEV_LAYOUT_PLUGIN_REF" "$HERDR_DEV_LAYOUT_LEGACY_DIR" 2>"$warning_log"
  after="$(checksum "$(registry_path)")"
  assert_eq "$before" "$after" "unowned managed-plugin id was replaced"
  grep -q 'preserving Herdr plugin.*unowned GitHub source' "$warning_log" \
    || fail "wrong-source preservation warning was missing"
  assert_log_count '^plugin (install|uninstall|unlink) ' 0
  printf 'PASS: managed wrong source preserved with warning\n'
}

seed_protected_plugin_data() {
  mkdir -p "$XDG_CONFIG_HOME/herdr/plugins/config/agentic-dev.layout" \
    "$XDG_STATE_HOME/herdr/plugins/agentic-dev.layout"
  printf 'user-config\n' >"$XDG_CONFIG_HOME/herdr/plugins/config/agentic-dev.layout/config.toml"
  printf 'workspace-state\n' >"$XDG_STATE_HOME/herdr/plugins/agentic-dev.layout/state.json"
}

assert_protected_plugin_data() {
  assert_eq 'user-config' \
    "$(tr -d '\n' <"$XDG_CONFIG_HOME/herdr/plugins/config/agentic-dev.layout/config.toml")" \
    "plugin config changed"
  assert_eq 'workspace-state' \
    "$(tr -d '\n' <"$XDG_STATE_HOME/herdr/plugins/agentic-dev.layout/state.json")" \
    "plugin state changed"
}

test_legacy_migration_and_rollback() {
  reset_fixture
  seed_legacy_dir
  seed_local agentic-dev.layout "$HERDR_DEV_LAYOUT_LEGACY_DIR"
  seed_protected_plugin_data
  ensure_managed_github_plugin agentic-dev.layout \
    "$DEV_LAYOUT_PLUGIN_REPO" "$DEV_LAYOUT_PLUGIN_REF" "$HERDR_DEV_LAYOUT_LEGACY_DIR"
  assert_eq "github:$DEV_LAYOUT_PLUGIN_REPO@$DEV_LAYOUT_PLUGIN_REF" \
    "$(registry_source agentic-dev.layout)" "legacy plugin did not migrate"
  [[ ! -e "$HERDR_DEV_LAYOUT_LEGACY_DIR" ]] || fail "legacy source remained after successful migration"
  assert_protected_plugin_data

  reset_fixture
  seed_legacy_dir
  seed_local agentic-dev.layout "$HERDR_DEV_LAYOUT_LEGACY_DIR"
  seed_protected_plugin_data
  export FAKE_HERDR_FAIL_INSTALL=1
  if ensure_managed_github_plugin agentic-dev.layout \
    "$DEV_LAYOUT_PLUGIN_REPO" "$DEV_LAYOUT_PLUGIN_REF" "$HERDR_DEV_LAYOUT_LEGACY_DIR"; then
    fail "injected migration failure returned success"
  fi
  assert_eq "local:$HERDR_DEV_LAYOUT_LEGACY_DIR" "$(registry_source agentic-dev.layout)" \
    "failed migration did not restore local registration"
  [[ -f "$HERDR_DEV_LAYOUT_LEGACY_DIR/sentinel" ]] || fail "failed migration did not restore legacy source"
  assert_protected_plugin_data
  printf 'PASS: local legacy migration is transactional and preserves config/state\n'
}

test_github_update_rollback() {
  reset_fixture
  seed_github agentic-dev.layout "$DEV_LAYOUT_PLUGIN_REPO" old-ref
  export FAKE_HERDR_FAIL_INSTALL=1
  if ensure_managed_github_plugin agentic-dev.layout \
    "$DEV_LAYOUT_PLUGIN_REPO" "$DEV_LAYOUT_PLUGIN_REF" "$HERDR_DEV_LAYOUT_LEGACY_DIR"; then
    fail "injected managed-ref update failure returned success"
  fi
  assert_eq "github:$DEV_LAYOUT_PLUGIN_REPO@old-ref" \
    "$(registry_source agentic-dev.layout)" "failed managed-ref update did not roll back"
  printf 'PASS: managed-ref update rollback\n'
}

test_third_party_policy() {
  local before after warning_log="$TMP_DIR/third-party.warning"
  reset_fixture
  ensure_adopted_github_plugin pickr "$PICKR_PLUGIN_REPO" "$PICKR_PLUGIN_REF"
  assert_eq "github:$PICKR_PLUGIN_REPO@$PICKR_PLUGIN_REF" "$(registry_source pickr)" \
    "missing pickr was not installed"
  before="$(checksum "$(registry_path)")"
  ensure_adopted_github_plugin pickr "$PICKR_PLUGIN_REPO" "$PICKR_PLUGIN_REF"
  after="$(checksum "$(registry_path)")"
  assert_eq "$before" "$after" "exact pickr install changed registry"
  assert_log_count '^plugin install tomasvarga/herdr-pickr ' 1

  seed_github worktrunk someone/custom-worktrunk custom-ref
  before="$(checksum "$(registry_path)")"
  ensure_adopted_github_plugin worktrunk "$WORKTRUNK_PLUGIN_REPO" "$WORKTRUNK_PLUGIN_REF" 2>"$warning_log"
  after="$(checksum "$(registry_path)")"
  assert_eq "$before" "$after" "mismatched worktrunk was replaced"
  grep -q 'preserving pre-existing Herdr plugin worktrunk' "$warning_log" \
    || fail "third-party mismatch warning was missing"
  printf 'PASS: third-party missing/exact/mismatch policy\n'
}

test_repeated_external_deploy() {
  local before after second_log="$TMP_DIR/second-deploy.log"
  reset_fixture
  deploy_plugin >/dev/null
  before="$(checksum "$(registry_path)")"
  : >"$HERDR_CALL_LOG"
  deploy_plugin >"$second_log"
  after="$(checksum "$(registry_path)")"
  assert_eq "$before" "$after" "second external deploy changed plugin registry"
  assert_log_count '^plugin (link|install|unlink|uninstall) ' 0
  grep -q "unchanged: managed Herdr plugin agentic-dev.layout ($DEV_LAYOUT_PLUGIN_REPO@$DEV_LAYOUT_PLUGIN_REF)" "$second_log" \
    || fail "second deploy did not report exact external pin no-op"
  assert_eq "github:$DEV_LAYOUT_PLUGIN_REPO@$DEV_LAYOUT_PLUGIN_REF" \
    "$(registry_source agentic-dev.layout)" "deploy_plugin did not pin the external source"
  printf 'PASS: repeated external install/update has no plugin mutations\n'
}

test_deploy_refuses_incompatible_herdr_before_mutation() {
  local version before_registry after_registry before_source after_source
  for version in 'herdr 0.7.1' 'herdr 0.8.2' 'herdr version unknown'; do
    reset_fixture
    mkdir -p "$HERDR_DEV_LAYOUT_LEGACY_DIR"
    printf 'keep-source\n' >"$HERDR_DEV_LAYOUT_LEGACY_DIR/sentinel"
    seed_github pickr someone/custom-pickr keep-ref
    before_registry="$(checksum "$(registry_path)")"
    before_source="$(checksum "$HERDR_DEV_LAYOUT_LEGACY_DIR/sentinel")"
    export FAKE_HERDR_VERSION_OUTPUT="$version"
    if deploy_plugin >/dev/null 2>&1; then
      fail "deploy accepted incompatible Herdr output: $version"
    fi
    after_registry="$(checksum "$(registry_path)")"
    after_source="$(checksum "$HERDR_DEV_LAYOUT_LEGACY_DIR/sentinel")"
    assert_eq "$before_registry" "$after_registry" \
      "incompatible Herdr changed plugin registry: $version"
    assert_eq "$before_source" "$after_source" \
      "incompatible Herdr changed existing plugin destination: $version"
    assert_eq '1' "$(find "$HERDR_DEV_LAYOUT_LEGACY_DIR" -type f | wc -l | tr -d ' ')" \
      "incompatible Herdr added files to plugin destination: $version"
    assert_log_count '^plugin (list|link|install|unlink|uninstall) ' 0
  done
  printf 'PASS: incompatible Herdr blocks deploy before file/registry mutation\n'
}

test_dry_run_describes_without_mutation() {
  local before after output="$TMP_DIR/dry-run.output"
  reset_fixture
  before="$(checksum "$(registry_path)")"
  export DRY_RUN=1
  deploy_plugin >"$output"
  export DRY_RUN=0
  after="$(checksum "$(registry_path)")"
  assert_eq "$before" "$after" "dry-run changed plugin registry"
  grep -q "\[dry-run\] herdr plugin install $DEV_LAYOUT_PLUGIN_REPO --ref $DEV_LAYOUT_PLUGIN_REF --yes" "$output" \
    || fail "dry-run omitted managed external install"
  grep -q "$PICKR_PLUGIN_REPO --ref $PICKR_PLUGIN_REF" "$output" || fail "dry-run omitted pickr install"
  grep -q "$WORKTRUNK_PLUGIN_REPO --ref $WORKTRUNK_PLUGIN_REF" "$output" || fail "dry-run omitted worktrunk install"
  printf 'PASS: dry-run describes external and third-party actions without mutation\n'
}

test_doctor_source_checks() {
  local output="$TMP_DIR/doctor.output"
  reset_fixture
  mkdir -p "$HERDR_DEV_LAYOUT_LEGACY_DIR"
  seed_local agentic-dev.layout "$HERDR_DEV_LAYOUT_LEGACY_DIR"
  ensure_adopted_github_plugin pickr "$PICKR_PLUGIN_REPO" "$PICKR_PLUGIN_REF" >/dev/null
  ensure_adopted_github_plugin worktrunk "$WORKTRUNK_PLUGIN_REPO" "$WORKTRUNK_PLUGIN_REF" >/dev/null
  doctor_plugin >"$output" || fail "doctor rejected exact owned plugin sources"
  grep -q "ok  plugin $PLUGIN_ID \[local:$HERDR_DEV_LAYOUT_LEGACY_DIR\]" "$output" \
    || fail "doctor omitted exact local source"

  export FAKE_HERDR_LIST_OUTPUT='- agentic-dev.layout (fixture) enabled [broken-source]'
  if doctor_plugin >"$output"; then
    fail "doctor accepted malformed plugin-list input"
  fi
  grep -q 'invalid  plugin agentic-dev.layout' "$output" \
    || fail "doctor did not report malformed plugin-list input"
  printf 'PASS: doctor validates exact source and rejects malformed entries\n'
}

test_stale_and_misleading_state() {
  local before after warning_log="$TMP_DIR/stale.warning"
  reset_fixture
  seed_local agentic-dev.layout "$HERDR_DEV_LAYOUT_LEGACY_DIR"
  before="$(checksum "$(registry_path)")"
  if ensure_managed_github_plugin agentic-dev.layout \
    "$DEV_LAYOUT_PLUGIN_REPO" "$DEV_LAYOUT_PLUGIN_REF" "$HERDR_DEV_LAYOUT_LEGACY_DIR" 2>"$warning_log"; then
    fail "stale legacy source returned success"
  fi
  after="$(checksum "$(registry_path)")"
  assert_eq "$before" "$after" "stale legacy source changed registry"
  grep -q 'source is stale or missing' "$warning_log" || fail "stale source warning missing"

  reset_fixture
  export FAKE_HERDR_MISLEAD_INSTALL=1
  if ensure_adopted_github_plugin pickr "$PICKR_PLUGIN_REPO" "$PICKR_PLUGIN_REF" 2>"$warning_log"; then
    fail "misleading successful install was accepted"
  fi
  assert_eq '[]' "$(jq -c . "$(registry_path)")" "misleading success left registry mutation"

  reset_fixture
  seed_github pickr someone/custom-pickr custom-ref
  before="$(checksum "$(registry_path)")"
  export FAKE_HERDR_LIST_OUTPUT='- pickr (fixture) enabled [not-a-source]'
  ensure_adopted_github_plugin pickr "$PICKR_PLUGIN_REPO" "$PICKR_PLUGIN_REF" 2>"$warning_log"
  after="$(checksum "$(registry_path)")"
  assert_eq "$before" "$after" "malformed plugin list caused adoption mutation"
  printf 'PASS: stale, malformed, and misleading-success states fail closed\n'
}

test_repeated_interruption_rollback() {
  local attempt
  reset_fixture
  seed_legacy_dir
  seed_local agentic-dev.layout "$HERDR_DEV_LAYOUT_LEGACY_DIR"
  export FAKE_HERDR_SIGNAL_INSTALL=1
  for attempt in 1 2; do
    if ensure_managed_github_plugin agentic-dev.layout \
      "$DEV_LAYOUT_PLUGIN_REPO" "$DEV_LAYOUT_PLUGIN_REF" "$HERDR_DEV_LAYOUT_LEGACY_DIR" >/dev/null 2>&1; then
      fail "interrupted migration attempt $attempt returned success"
    fi
    assert_eq "local:$HERDR_DEV_LAYOUT_LEGACY_DIR" "$(registry_source agentic-dev.layout)" \
      "interrupted migration attempt $attempt did not restore registration"
    [[ -f "$HERDR_DEV_LAYOUT_LEGACY_DIR/sentinel" ]] \
      || fail "interrupted migration attempt $attempt did not restore source"
  done
  printf 'PASS: repeated interruption rolls back each transaction\n'
}

test_uninstall_ownership() {
  local before after config_path
  reset_fixture
  seed_github agentic-dev.layout someone/custom-layout user-ref
  config_path="$XDG_CONFIG_HOME/herdr/plugins/config/pickr/config.toml"
  mkdir -p "$(dirname "$config_path")" "$WORKTRUNK_CONFIG_DIR"
  printf 'pickr-user-config\n' >"$config_path"
  printf 'worktrunk-user-config\n' >"$WORKTRUNK_CONFIG_DIR/config.toml"
  before="$(checksum "$(registry_path)")"
  uninstall_agentic_dev >/dev/null 2>&1
  after="$(checksum "$(registry_path)")"
  assert_eq "$before" "$after" "uninstall changed unowned plugin registrations"
  [[ -f "$config_path" ]] || fail "uninstall removed third-party pickr config"
  [[ -f "$WORKTRUNK_CONFIG_DIR/config.toml" ]] || fail "uninstall removed third-party worktrunk config"

  reset_fixture
  mkdir -p "$HERDR_DEV_LAYOUT_LEGACY_DIR"
  printf 'managed\n' >"$HERDR_DEV_LAYOUT_LEGACY_DIR/sentinel"
  seed_local agentic-dev.layout "$HERDR_DEV_LAYOUT_LEGACY_DIR"
  ensure_adopted_github_plugin pickr "$PICKR_PLUGIN_REPO" "$PICKR_PLUGIN_REF" >/dev/null
  ensure_adopted_github_plugin worktrunk "$WORKTRUNK_PLUGIN_REPO" "$WORKTRUNK_PLUGIN_REF" >/dev/null
  : >"$HERDR_CALL_LOG"
  uninstall_agentic_dev >/dev/null 2>&1
  [[ ! -e "$HERDR_DEV_LAYOUT_LEGACY_DIR" ]] || fail "uninstall kept confirmed managed local source"
  assert_eq '2' "$(jq 'length' "$(registry_path)")" "uninstall removed third-party plugins"
  assert_log_count '^plugin unlink agentic-dev.layout$' 1
  assert_log_count '^plugin (unlink|uninstall) (pickr|worktrunk)$' 0
  printf 'PASS: uninstall removes only confirmed managed dev-layout ownership\n'
}

test_target_id_format_drift_is_unknown() {
  local before after warning_log="$TMP_DIR/format-drift.warning"
  reset_fixture
  seed_legacy_dir
  before="$(checksum "$(registry_path)")"
  export FAKE_HERDR_LIST_OUTPUT="agentic-dev.layout (fixture) enabled [local:$HERDR_DEV_LAYOUT_LEGACY_DIR]"
  ensure_managed_local_plugin "$PLUGIN_ID" "$HERDR_DEV_LAYOUT_LEGACY_DIR" 2>"$warning_log"
  after="$(checksum "$(registry_path)")"
  assert_eq "$before" "$after" "format-drifted target id was treated as missing and installed"
  assert_log_count '^plugin link ' 0
  grep -q 'cannot safely inspect Herdr plugin' "$warning_log" \
    || fail "format drift did not produce a preservation warning"
  printf 'PASS: target-id human output drift fails closed\n'
}

test_failed_unlink_keeps_managed_source() {
  reset_fixture
  seed_legacy_dir
  seed_local agentic-dev.layout "$HERDR_DEV_LAYOUT_LEGACY_DIR"
  export FAKE_HERDR_FAIL_REMOVE=1
  uninstall_agentic_dev >/dev/null 2>&1
  [[ -f "$HERDR_DEV_LAYOUT_LEGACY_DIR/sentinel" ]] || fail "failed unlink still removed managed source directory"
  assert_eq "local:$HERDR_DEV_LAYOUT_LEGACY_DIR" "$(registry_source agentic-dev.layout)" \
    "failed unlink changed managed registration"
  printf 'PASS: failed unlink keeps managed source directory\n'
}

test_total_install_outage_restores_snapshot() {
  local before after old_root config_path state_path
  reset_fixture
  seed_github agentic-dev.layout "$DEV_LAYOUT_PLUGIN_REPO" old-ref
  append_github pickr "$PICKR_PLUGIN_REPO" "$PICKR_PLUGIN_REF"
  old_root="$XDG_CONFIG_HOME/herdr/plugins/github/agentic-dev.layout-old-ref"
  config_path="$XDG_CONFIG_HOME/herdr/plugins/config/agentic-dev.layout/config.toml"
  state_path="$XDG_STATE_HOME/herdr/plugins/agentic-dev.layout/state.json"
  mkdir -p "$(dirname "$config_path")" "$(dirname "$state_path")"
  printf 'config-stable\n' >"$config_path"
  printf 'state-stable\n' >"$state_path"
  before="$(checksum "$(registry_path)")"
  export FAKE_HERDR_FAIL_ALL_INSTALL=1
  if ensure_managed_github_plugin agentic-dev.layout \
    "$DEV_LAYOUT_PLUGIN_REPO" "$DEV_LAYOUT_PLUGIN_REF" "$HERDR_DEV_LAYOUT_LEGACY_DIR" >/dev/null 2>&1; then
    fail "total install outage returned success"
  fi
  after="$(checksum "$(registry_path)")"
  assert_eq "$before" "$after" "snapshot rollback did not preserve the complete registry"
  [[ -f "$old_root/sentinel" ]] || fail "snapshot rollback did not restore old GitHub source"
  assert_eq '2' "$(jq 'length' "$(registry_path)")" "snapshot rollback lost unrelated registry entries"
  [[ "$(<"$config_path")" == 'config-stable' ]] || fail "snapshot rollback changed plugin config"
  [[ "$(<"$state_path")" == 'state-stable' ]] || fail "snapshot rollback changed plugin state"
  printf 'PASS: total install outage restores registry/source snapshot\n'
}

test_term_immediately_after_unlink_restores_snapshot() {
  local before after
  reset_fixture
  seed_legacy_dir
  seed_local agentic-dev.layout "$HERDR_DEV_LAYOUT_LEGACY_DIR"
  append_github pickr "$PICKR_PLUGIN_REPO" "$PICKR_PLUGIN_REF"
  before="$(checksum "$(registry_path)")"
  export FAKE_HERDR_SIGNAL_AFTER_REMOVE=1
  if ensure_managed_github_plugin agentic-dev.layout \
    "$DEV_LAYOUT_PLUGIN_REPO" "$DEV_LAYOUT_PLUGIN_REF" "$HERDR_DEV_LAYOUT_LEGACY_DIR" >/dev/null 2>&1; then
    fail "TERM-interrupted transaction returned success"
  fi
  after="$(checksum "$(registry_path)")"
  assert_eq "$before" "$after" "TERM immediately after unlink did not restore complete registry"
  [[ -f "$HERDR_DEV_LAYOUT_LEGACY_DIR/sentinel" ]] || fail "TERM immediately after unlink lost local source"
  printf 'PASS: rollback is armed before first removal\n'
}

send_term_during_rollback() {
  printf 'signal TERM during-rollback\n' >>"$HERDR_CALL_LOG"
  kill -TERM "$BASHPID" 2>/dev/null || true
}

test_second_term_during_one_rollback_is_deferred() {
  local before after signal_count
  reset_fixture
  seed_legacy_dir
  seed_local agentic-dev.layout "$HERDR_DEV_LAYOUT_LEGACY_DIR"
  append_github pickr "$PICKR_PLUGIN_REPO" "$PICKR_PLUGIN_REF"
  before="$(checksum "$(registry_path)")"
  export FAKE_HERDR_SIGNAL_AFTER_REMOVE=1
  export AGENTIC_DEV_ON_ROLLBACK_ARMED=send_term_during_rollback
  if ensure_managed_github_plugin agentic-dev.layout \
    "$DEV_LAYOUT_PLUGIN_REPO" "$DEV_LAYOUT_PLUGIN_REF" "$HERDR_DEV_LAYOUT_LEGACY_DIR" >/dev/null 2>&1; then
    fail "double-TERM transaction returned success"
  fi
  signal_count="$(grep -c '^signal TERM ' "$HERDR_CALL_LOG" || true)"
  assert_eq '2' "$signal_count" "fixture did not deliver two TERM signals in one transaction"
  after="$(checksum "$(registry_path)")"
  assert_eq "$before" "$after" "second TERM interrupted registry rollback"
  [[ -f "$HERDR_DEV_LAYOUT_LEGACY_DIR/sentinel" ]] || fail "second TERM interrupted source rollback"
  printf 'PASS: second TERM is deferred until rollback completes\n'
}

test_untrusted_plugin_root_survives_rollback() {
  local must_survive="$TMP_DIR/must-survive-user-directory"
  reset_fixture
  seed_legacy_dir
  seed_local agentic-dev.layout "$HERDR_DEV_LAYOUT_LEGACY_DIR"
  mkdir -p "$must_survive"
  printf 'user-owned\n' >"$must_survive/sentinel"
  export FAKE_HERDR_UNTRUSTED_PLUGIN_ROOT="$must_survive"
  if ensure_managed_github_plugin agentic-dev.layout \
    "$DEV_LAYOUT_PLUGIN_REPO" "$DEV_LAYOUT_PLUGIN_REF" "$HERDR_DEV_LAYOUT_LEGACY_DIR" >/dev/null 2>&1; then
    fail "misleading install with untrusted plugin_root returned success"
  fi
  [[ -f "$must_survive/sentinel" ]] \
    || fail "rollback recursively deleted an untrusted registry-provided plugin_root"
  assert_eq "local:$HERDR_DEV_LAYOUT_LEGACY_DIR" "$(registry_source agentic-dev.layout)" \
    "rollback did not restore the original registration after preserving untrusted path"
  printf 'PASS: rollback preserves untrusted registry-provided plugin_root\n'
}

test_symlinked_managed_root_preexisting_child_survives() {
  local managed_link="$XDG_CONFIG_HOME/herdr/plugins/github"
  local original_root="$TMP_DIR/original-managed-root"
  local replacement_root="$TMP_DIR/replacement-managed-root"
  local must_survive="$replacement_root/pre-existing-child"
  reset_fixture
  seed_legacy_dir
  seed_local agentic-dev.layout "$HERDR_DEV_LAYOUT_LEGACY_DIR"
  mkdir -p "$original_root" "$must_survive" "$(dirname "$managed_link")"
  printf 'pre-existing-user-data\n' >"$must_survive/sentinel"
  ln -s "$original_root" "$managed_link"
  export FAKE_HERDR_UNTRUSTED_PLUGIN_ROOT="$managed_link/pre-existing-child"
  export FAKE_HERDR_SWAP_MANAGED_ROOT="$managed_link"
  export FAKE_HERDR_SWAP_MANAGED_ROOT_TARGET="$replacement_root"
  if ensure_managed_github_plugin agentic-dev.layout \
    "$DEV_LAYOUT_PLUGIN_REPO" "$DEV_LAYOUT_PLUGIN_REF" "$HERDR_DEV_LAYOUT_LEGACY_DIR" >/dev/null 2>&1; then
    fail "symlinked managed-root misleading install returned success"
  fi
  [[ -f "$must_survive/sentinel" ]] \
    || fail "rollback deleted a pre-existing child after managed-root symlink swap"
  assert_eq "local:$HERDR_DEV_LAYOUT_LEGACY_DIR" "$(registry_source agentic-dev.layout)" \
    "rollback did not restore original registration after managed-root symlink swap"
  printf 'PASS: symlinked managed-root pre-existing child survives rollback\n'
}

if [[ "${PLUGIN_TEST_SYMLINK_ROOT:-0}" == 1 ]]; then
  test_symlinked_managed_root_preexisting_child_survives
  exit
fi

if [[ "${PLUGIN_TEST_UNTRUSTED_ROOT:-0}" == 1 ]]; then
  test_untrusted_plugin_root_survives_rollback
  exit
fi

run_verifier_regressions() {
  local failures=0 test_name
  for test_name in \
    test_target_id_format_drift_is_unknown \
    test_failed_unlink_keeps_managed_source \
    test_total_install_outage_restores_snapshot \
    test_term_immediately_after_unlink_restores_snapshot \
    test_second_term_during_one_rollback_is_deferred; do
    if ! ("$test_name"); then
      printf 'VERIFIER-RED: %s failed\n' "$test_name" >&2
      failures=$((failures + 1))
    fi
  done
  printf 'VERIFIER REGRESSION RESULT: %d failures\n' "$failures"
  [[ "$failures" -eq 0 ]]
}

if [[ "${PLUGIN_TEST_VERIFIER_REGRESSIONS:-0}" == 1 ]]; then
  run_verifier_regressions
  exit
fi

test_managed_missing_exact_and_update
test_managed_wrong_source_preserved
test_legacy_migration_and_rollback
test_github_update_rollback
test_third_party_policy
test_repeated_external_deploy
test_deploy_refuses_incompatible_herdr_before_mutation
test_dry_run_describes_without_mutation
test_doctor_source_checks
test_stale_and_misleading_state
test_repeated_interruption_rollback
test_uninstall_ownership
test_target_id_format_drift_is_unknown
test_failed_unlink_keeps_managed_source
test_total_install_outage_restores_snapshot
test_term_immediately_after_unlink_restores_snapshot
test_second_term_during_one_rollback_is_deferred
test_untrusted_plugin_root_survives_rollback
test_symlinked_managed_root_preexisting_child_survives
printf 'ALL PASS: plugin registry ownership fixture matrix\n'
