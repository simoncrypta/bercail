#!/usr/bin/env bats
# Which live Pi processes run older bercail code than is installed
# (lib/pi-code.sh): a fake /proc, a stand-in hc, files in a temp HOME.

setup() {
  load test_helper
  isolate
  export HC_DATA="$BATS_TEST_TMPDIR/hc"
  mkdir -p "$HC_DATA"
  printf '#!/usr/bin/env bash\n[[ "$1" == get ]] && cat "$HC_DATA/$2.json" 2>/dev/null || exit 5\n' >"$BATS_TEST_TMPDIR/bin/hc"
  chmod +x "$BATS_TEST_TMPDIR/bin/hc"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  SHARE="$HOME/.local/share/bercail"
}

# code REL EPOCH [TEXT]: an installed file, last changed at EPOCH.
code() {
  mkdir -p "$(dirname "$SHARE/$1")"
  printf '%s\n' "${3:-}" >"$SHARE/$1"
  touch -d "@$2" "$SHARE/$1"
}

libs() {
  bash -c 'set -euo pipefail; source "$ROOT/lib/common.sh"; for n in "${BERCAIL_LIBS[@]}"; do source "$ROOT/lib/$n.sh"; done; '"$1"
}

@test "update names each live Pi whose loaded code or its imports changed after it started, and how to restart it" {
  local out want
  code pi-extensions/bercail-desk.ts 1500
  code pi/extensions/guard.ts 3000
  code pi/extensions/fallback.ts 1500 'import { x } from "./provider-error.ts";'
  code pi/extensions/provider-error.ts 3000
  code shep/pi/inbox.ts 1500 'import { y } from "./questions.ts";'
  code shep/pi/questions.ts 3000
  code shep/pi/background.ts 1500
  # Shep's Pi is a child of the terminal's bercail shep run.
  fake_proc 100 1 2000 bash t1 bash bercail shep run
  fake_proc 101 100 2000 pi t1 pi -e "$SHARE/pi-extensions/bercail-desk.ts" -e "$SHARE/shep/pi/inbox.ts"
  # A desk, and the wrapper that started it with the same argv.
  fake_proc 200 1 2000 bash t2 bash bercail-desk-agent pi -e "$SHARE/pi/extensions/guard.ts"
  fake_proc 201 200 2000 pi t2 pi -e "$SHARE/pi/extensions/guard.ts"
  # Started after the deploy: up to date.
  fake_proc 301 1 4000 pi t3 pi -e "$SHARE/pi/extensions/guard.ts"
  fake_proc 401 1 2000 pi t4 pi -e "$SHARE/pi/extensions/fallback.ts" -e "$SHARE/shep/pi/background.ts"
  # Run from a desk's shell: it only inherited the desk's env.
  fake_proc 501 999 2000 pi t2 pi --extension="$SHARE/pi/extensions/guard.ts"
  fake_proc 601 1 2000 pi t6 pi -e "$HOME/elsewhere/guard.ts"
  # Not Pi, though its argv names the file.
  fake_proc 701 1 2000 grep t7 grep -e "$SHARE/pi/extensions/guard.ts"
  echo '{"pid": 100, "labels": {"bercail.role": "shep"}}' >"$HC_DATA/t1.json"
  echo '{"pid": 201, "labels": {"bercail.role": "agent", "bercail.issue": "app-1", "bercail.issue_title": "Fix it"}}' >"$HC_DATA/t2.json"
  echo '{"pid": 401, "name": "bg-app-2", "cwd": "/w/app", "labels": {"bercail.role": "agent", "bercail.shep": "bg", "bercail.issue": "app-2"}}' >"$HC_DATA/t4.json"
  mkdir -p "$XDG_STATE_HOME/bercail/desk-sessions"
  echo '{"pid": 201, "session": "abcdef123456"}' >"$XDG_STATE_HOME/bercail/desk-sessions/t2.json"
  out="$(libs pi_code_report)" || fail "report: $out"
  want="
Pi that may still run bercail code older than what is installed (restart each to load it):
  - Shep (t1): quit the Shep terminal, then Start Shep; it continues its session · changed: questions.ts
  - desk t2 (app-1: Fix it): quit its Pi, press Ctrl+Shift+A in its space, then /resume and pick session abcdef12 · changed: guard.ts
  - background Shep bg-app-2 (t4): let it report, then start a new one if app-2 still needs it: bercail shep bg --issue app-2 --cwd /w/app · changed: provider-error.ts
  - pid 501 (started from t2): quit it and start it again · changed: guard.ts"
  [[ "$out" == "$want" ]] || fail "report: $out"
}

@test "update says nothing when every live Pi started after its code last changed" {
  local out
  code pi/extensions/guard.ts 1500
  fake_proc 201 1 2000 pi t2 pi -e "$SHARE/pi/extensions/guard.ts"
  out="$(libs pi_code_report)" || fail "report: $out"
  [[ -z "$out" ]] || fail "nothing is stale: $out"
}

@test "a loaded file changed in the second its Pi started, removed since, or behind an old symlink counts as changed" {
  local out
  code pi/extensions/guard.ts 2000
  code pi/extensions/fallback.ts 1500 'import { x } from "./gone.ts";'
  code pi/extensions/review.ts 3000
  ln -s review.ts "$SHARE/pi/extensions/link.ts"
  touch -h -d @1500 "$SHARE/pi/extensions/link.ts"
  fake_proc 201 1 2000 pi t2 pi -e "$SHARE/pi/extensions/guard.ts" -e "$SHARE/pi/extensions/fallback.ts"
  fake_proc 202 1 2000 node t3 node "$HOME/bin/pi" -e "$SHARE/pi/extensions/link.ts"
  out="$(libs pi_code_stale_json)" || fail "stale: $out"
  [[ "$(jq -c '[.[] | .pid, (.changed | map(split("/")[-1]))]' <<<"$out")" == '[201,["guard.ts","gone.ts"],202,["link.ts"]]' ]] \
    || fail "same second, removed, symlink: $out"
}

@test "with a Herdr core that does not answer, the update's list names each Pi by its pid and does not wait on hc" {
  local out start
  code pi/extensions/guard.ts 3000
  fake_proc 201 1 2000 pi t2 pi -e "$SHARE/pi/extensions/guard.ts"
  fake_proc 202 1 2000 pi t3 pi -e "$SHARE/pi/extensions/guard.ts"
  printf '#!/usr/bin/env bash\nsleep 30\n' >"$BATS_TEST_TMPDIR/bin/hc"
  start="$SECONDS"
  out="$(libs pi_code_report)" || fail "report: $out"
  ((SECONDS - start < 10)) || fail "waited $((SECONDS - start))s on hc"
  grep -qx '  - pid 201 (started from t2): quit it and start it again · changed: guard.ts' <<<"$out" || fail "pid 201: $out"
  grep -qx '  - pid 202 (started from t3): quit it and start it again · changed: guard.ts' <<<"$out" || fail "pid 202: $out"
}

@test "a redeploy keeps the time of a file whose content it did not change, so only a changed file makes a Pi stale" {
  local out src="$BATS_TEST_TMPDIR/src"
  mkdir -p "$src"
  cp -R "$ROOT/shep" "$src/shep"
  export INSTALL_SRC="$src"
  libs deploy_shep >/dev/null
  find "$SHARE/shep/pi" -type f -exec touch -d @1500 {} +
  fake_proc 101 1 2000 pi t1 pi -e "$SHARE/shep/pi/inbox.ts"
  libs deploy_shep >/dev/null
  out="$(libs pi_code_stale_json)" || fail "stale: $out"
  [[ "$out" == '[]' ]] || fail "the same files again: $out"
  printf '// B\n' >>"$src/shep/pi/questions.ts"
  libs deploy_shep >/dev/null
  out="$(libs pi_code_stale_json)" || fail "stale: $out"
  [[ "$(jq -c 'map(.changed | map(split("/")[-1]))' <<<"$out")" == '[["questions.ts"]]' ]] || fail "questions.ts changed: $out"
  # B arrived at 3000 and a Pi loaded it at 4000; back to A is a change for that Pi.
  touch -d @3000 "$SHARE/shep/pi/questions.ts"
  fake_proc 102 1 4000 pi t2 pi -e "$SHARE/shep/pi/inbox.ts"
  cp "$ROOT/shep/pi/questions.ts" "$src/shep/pi/questions.ts"
  libs deploy_shep >/dev/null
  out="$(libs pi_code_stale_json)" || fail "stale: $out"
  [[ "$(jq -c 'map(select(.pid == 102) | .changed | map(split("/")[-1]))' <<<"$out")" == '[["questions.ts"]]' ]] \
    || fail "B back to A: $out"
}

@test "a deploy replaces links and folders where its files go with files of its own, and leaves the links' targets alone" {
  local elsewhere="$BATS_TEST_TMPDIR/elsewhere" rel
  mkdir -p "$elsewhere/pi" "$SHARE/shep"
  export INSTALL_SRC="$ROOT"
  printf 'mine\n' >"$elsewhere/pi/inbox.ts"
  printf 'mine\n' >"$elsewhere/questions.ts"
  ln -s "$elsewhere/pi" "$SHARE/shep/pi"
  libs deploy_shep >/dev/null || fail "deploy, linked pi/"
  [[ -d "$SHARE/shep/pi" && ! -L "$SHARE/shep/pi" ]] || fail "pi/ is still a link"
  rm "$SHARE/shep/pi/questions.ts"
  ln -s "$elsewhere/questions.ts" "$SHARE/shep/pi/questions.ts"
  rm "$SHARE/shep/pi/inbox.ts"
  mkdir "$SHARE/shep/pi/inbox.ts"
  : >"$SHARE/shep/pi/inbox.ts/old.ts"
  libs deploy_shep >/dev/null || fail "deploy, a link and a folder inside"
  for rel in inbox.ts questions.ts; do
    [[ -f "$SHARE/shep/pi/$rel" && ! -L "$SHARE/shep/pi/$rel" ]] || fail "$rel is not a file of its own"
    cmp -s "$ROOT/shep/pi/$rel" "$SHARE/shep/pi/$rel" || fail "$rel not deployed"
  done
  [[ "$(cat "$elsewhere/pi/inbox.ts" "$elsewhere/questions.ts")" == $'mine\nmine' ]] || fail "a link's target was written"
}
