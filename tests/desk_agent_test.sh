#!/usr/bin/env bash
# shellcheck shell=bash
# bin/bercail-desk-agent: what the desk runs, from config.toml and its arguments.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# Fake agents print their name, argv and the opencode CLI config they got.
mkdir -p "$TMP_DIR/bin" "$TMP_DIR/xdg/bercail"
for agent in opencode codex claude cursor-agent; do
  cat >"$TMP_DIR/bin/$agent" <<'AGENT'
#!/usr/bin/env bash
printf '%s' "$(basename "$0")"
for a in "$@"; do printf ' [%s]' "$a"; done
printf ' cli=%s\n' "${OPENCODE_CLI_CONFIG_CONTENT:-none}"
AGENT
  chmod +x "$TMP_DIR/bin/$agent"
done
export PATH="$TMP_DIR/bin:$PATH" XDG_CONFIG_HOME="$TMP_DIR/xdg"
# BASH_ENV can put the real agents back in front of the fakes.
unset OPENCODE_CLI_CONFIG_CONTENT BASH_ENV
CONFIG="$XDG_CONFIG_HOME/bercail/config.toml"
desk() { "$ROOT/bin/bercail-desk-agent" "$@"; }
expect() { [[ "$1" == "$2" ]] || fail "$3: got '$1', want '$2'"; }

printf '[agent]\ncommand = "claude --verbose"  # mine\n\n[bstack]\nenabled = true\n' >"$CONFIG"
got="$(desk)"
[[ "$got" == "opencode cli="* ]] || fail "bstack on runs opencode with no flags: $got"
cli="${got#opencode cli=}"
expect "$(jq -c '.theme' <<<"$cli")" '{"name":"system","mode":"system"}' "bstack's desk takes the terminal's palette"
expect "$(jq -c '.highlights' <<<"$cli")" false "no release highlights on the desk"
expect "$(jq -r '.tabs.mode' <<<"$cli")" off "tabs off: the TUI reports only its own session"
expect "$(desk --prompt 'Do bercail-1')" "opencode [--prompt] [Do bercail-1] cli=$cli" "bstack prompt"
printf 'PASS: bstack on runs opencode (full TUI, system theme), its prompt through --prompt\n'

expect "$(desk --prompt 'Do bercail-1' codex)" "codex [--no-daemon] [Do bercail-1] cli=none" "handoff codex"
expect "$(desk codex --no-daemon)" "codex [--no-daemon] cli=none" "codex keeps one --no-daemon"
expect "$(desk --prompt x claude)" "claude [x] cli=none" "handoff claude"
expect "$(desk --prompt x opencode)" "opencode [--prompt] [x] cli=$cli" "handoff opencode with bstack on"
printf 'PASS: a given command runs as is: codex without its daemon, the prompt last\n'

printf '[agent]\ncommand = "claude --verbose"  # mine\n\n[bstack]\nenabled = false\n' >"$CONFIG"
expect "$(desk)" "claude [--verbose] cli=none" "bstack off runs [agent] command"
expect "$(desk --prompt x)" "claude [--verbose] [x] cli=none" "bstack off prompt"
expect "$(desk opencode)" "opencode cli=none" "plain opencode with bstack off keeps the person's theme"
rm "$CONFIG"
expect "$(desk)" "cursor-agent cli=none" "no config"
printf 'PASS: bstack off runs [agent] command (cursor-agent without a config)\n'
