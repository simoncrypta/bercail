#!/usr/bin/env bash
# shellcheck shell=bash
# What the unit suite cannot see: a shellcheck warning in any tracked shell
# file (the .bats files too); the format, lint and types of the TypeScript and
# JavaScript (vp check); and the Herdr mods' lint, syntax errors included,
# which `herdr-app check` would catch but CI cannot run. CI runs this.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
command -v shellcheck >/dev/null 2>&1 || { printf 'tests/lint.sh: shellcheck is missing\n' >&2; exit 1; }
vp=node_modules/.bin/vp
[[ -x "$vp" ]] || { printf 'tests/lint.sh: vp is missing; run npm ci\n' >&2; exit 1; }

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

"$vp" check
# Herdr loads the mods as plain JS: no type-aware pass (bercail/mods/lint.config.ts).
"$vp" lint -c bercail/mods/lint.config.ts bercail/mods
printf 'lint: %d shell files, vp check, %d mods\n' "${#files[@]}" "$(printf '%s\n' bercail/mods/*/main.js | wc -l)"
