#!/usr/bin/env bash
# shellcheck shell=bash
# What the unit suite cannot see: a shellcheck warning in any tracked shell
# file (the .bats files too), and a syntax error in a Herdr mod, which
# `herdr-app check` would catch but CI cannot run. CI runs this.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
for tool in shellcheck node; do
  command -v "$tool" >/dev/null 2>&1 || { printf 'tests/lint.sh: %s is missing\n' "$tool" >&2; exit 1; }
done

# Shell files by name, or by a bash or sh shebang.
files=()
while IFS= read -r f; do
  [[ -f "$f" ]] || continue
  case "$f" in
    *.sh|*.bash|*.bats) files+=("$f") ;;
    *)
      IFS= read -r first <"$f" || true
      [[ "$first" =~ ^'#!'.*[/\ ](ba)?sh($|\ ) ]] && files+=("$f")
      ;;
  esac
done < <(git ls-files)
shellcheck -S warning "${files[@]}"

for f in bercail/mods/*/main.js; do
  node --check "$f"
done
printf 'lint: %d shell files, %d mods\n' "${#files[@]}" "$(printf '%s\n' bercail/mods/*/main.js | wc -l)"
