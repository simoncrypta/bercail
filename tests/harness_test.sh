#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

unset BASH_ENV
export __MISE_BASH_ENV_LOADED=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# shellcheck disable=SC1091
source "$ROOT/lib/harness.sh"

test_discover_reports_missing_not_fatal() {
  local out jqbin
  mkdir -p "$TMP_DIR/jqonly"
  jqbin="$(command -v jq)"
  ln -sf "$jqbin" "$TMP_DIR/jqonly/jq"
  ln -sf "$(command -v bash)" "$TMP_DIR/jqonly/bash"
  ln -sf "$(command -v find)" "$TMP_DIR/jqonly/find"
  ln -sf "$(command -v awk)" "$TMP_DIR/jqonly/awk"
  ln -sf "$(command -v sort)" "$TMP_DIR/jqonly/sort"
  ln -sf "$(command -v head)" "$TMP_DIR/jqonly/head"
  out="$(PATH="$TMP_DIR/jqonly" HOME="$TMP_DIR/empty-home" \
    harness_discover_json)"
  printf '%s' "$out" | jq -e '.ok == true' >/dev/null || fail "ok: $out"
  printf '%s' "$out" | jq -e 'has("default_start") | not' >/dev/null || fail "harness must not pick a default: $out"
  printf '%s' "$out" | jq -e '[.harnesses[].id] == ["claude","codex","cursor-agent"]' >/dev/null \
    || fail "ids: $out"
  printf '%s' "$out" | jq -e 'all(.harnesses[]; .present == false and .path == null and .model_hint == null)' >/dev/null \
    || fail "all missing: $out"
  printf 'PASS: discovery reports missing CLIs without failing\n'
}

test_discover_claude_model_hint() {
  local out bin="$TMP_DIR/with-claude"
  mkdir -p "$bin"
  printf '#!/bin/sh\nexit 0\n' >"$bin/claude"
  chmod +x "$bin/claude"
  cat >"$TMP_DIR/catalog.json" <<'JSON'
{"catalog":{"config":{"models":[{"id":"claude-opus-5-5","name":"Opus 5.5"}]}}}
JSON
  out="$(PATH="$bin:/usr/bin:/bin" HOME="$TMP_DIR/empty-home" \
    BERCAIL_CLAUDE_MODEL_CATALOG="$TMP_DIR/catalog.json" \
    harness_discover_json)"
  printf '%s' "$out" | jq -e 'has("default_start") | not' >/dev/null || fail "harness must not pick a default: $out"
  printf '%s' "$out" | jq -e '.harnesses[] | select(.id=="claude") | .present == true and .model_hint == "claude-opus-5-5"' >/dev/null \
    || fail "claude row: $out"
  printf '%s' "$out" | jq -e '.harnesses[] | select(.id=="codex") | .present == false' >/dev/null \
    || fail "codex still missing: $out"
  printf 'PASS: claude row reports a catalog model hint and nothing is picked\n'
}

test_discover_cursor_present_without_running() {
  local out bin="$TMP_DIR/with-cursor"
  mkdir -p "$bin"
  printf '#!/bin/sh\necho should-not-run >&2; exit 9\n' >"$bin/cursor-agent"
  chmod +x "$bin/cursor-agent"
  out="$(PATH="$bin:/usr/bin:/bin" HOME="$TMP_DIR/empty-home" \
    harness_discover_json)"
  printf '%s' "$out" | jq -e '.harnesses[] | select(.id=="cursor-agent") | .present == true and .model_hint == null' >/dev/null \
    || fail "cursor-agent model hint must stay null (no --list-models): $out"
  printf 'PASS: cursor-agent is reported present without running it\n'
}

test_discover_codex_model_from_local_config() {
  local out bin="$TMP_DIR/with-codex" home="$TMP_DIR/codex-home"
  mkdir -p "$bin" "$home/.codex"
  printf '#!/bin/sh\nexit 0\n' >"$bin/codex"
  chmod +x "$bin/codex"
  printf 'model = "gpt-test-local"\n' >"$home/.codex/config.toml"
  out="$(PATH="$bin:/usr/bin:/bin" HOME="$home" CODEX_HOME="$home/.codex" \
    harness_discover_json)"
  printf '%s' "$out" | jq -e '.harnesses[] | select(.id=="codex") | .present == true and .model_hint == "gpt-test-local"' >/dev/null \
    || fail "codex model: $out"
  printf 'PASS: Codex model hint comes from local config.toml\n'
}

test_bercail_harness_command() {
  local out
  mkdir -p "$TMP_DIR/empty"
  out="$(PATH="$TMP_DIR/empty:/usr/bin:/bin" HOME="$TMP_DIR/empty-home" \
    AGENTIC_DEV_LIB="$ROOT/lib" BERCAIL_LIB="$ROOT/lib" \
    "$ROOT/bin/bercail" harness)"
  printf '%s' "$out" | jq -e '.ok == true and (.harnesses|length)==3' >/dev/null \
    || fail "bercail harness: $out"
  printf 'PASS: bercail harness prints discovery JSON\n'
}

test_discover_reports_missing_not_fatal
test_discover_claude_model_hint
test_discover_codex_model_from_local_config
test_discover_cursor_present_without_running
test_bercail_harness_command
