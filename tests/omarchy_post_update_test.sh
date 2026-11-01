#!/usr/bin/env bash
# shellcheck shell=bash
# The Omarchy post-update hook: installed once on Omarchy, never on other
# hosts, and it never fails an Omarchy update.
set -euo pipefail

unset BASH_ENV
export __MISE_BASH_ENV_LOADED=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

export HOME="$TMP_DIR/home"
mkdir -p "$HOME" "$TMP_DIR/bin"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_NOSYSTEM=1

# Same contract as Omarchy's omarchy-hook-install: copy under the file's name.
cat >"$TMP_DIR/bin/omarchy-hook-install" <<'EOF'
#!/bin/bash
set -e
mkdir -p "$HOME/.config/omarchy/hooks/$1.d"
cp -- "$2" "$HOME/.config/omarchy/hooks/$1.d/$(basename -- "$2")"
chmod 755 "$HOME/.config/omarchy/hooks/$1.d/$(basename -- "$2")"
echo "Installed $1 hook: $HOME/.config/omarchy/hooks/$1.d/$(basename -- "$2")"
EOF
chmod +x "$TMP_DIR/bin/omarchy-hook-install"
export PATH="$TMP_DIR/bin:$PATH"

# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=lib/detect.sh
source "$ROOT/lib/detect.sh"
# shellcheck source=lib/config.sh
source "$ROOT/lib/config.sh"
# shellcheck source=lib/omarchy.sh
source "$ROOT/lib/omarchy.sh"

export INSTALL_SRC="$ROOT"
YES=1
DRY_RUN=0
HOOK_DIR="$HOME/.config/omarchy/hooks/post-update.d"

# --- install ---

out="$(is_omarchy() { return 1; }; deploy_omarchy_post_update_hook)"
[[ ! -e "$OMARCHY_POST_UPDATE_HOOK" ]] || fail "hook installed on a host that is not Omarchy"
[[ -z "$out" ]] || fail "non-Omarchy hosts should not mention the hook: $out"
printf 'PASS: no hook outside Omarchy\n'

mkdir -p "$HOME/.local/share/omarchy" "$HOOK_DIR"
printf '#!/bin/bash\n' >"$HOOK_DIR/setup-agent.hook"
deploy_omarchy_post_update_hook >/dev/null
cmp -s "$ROOT/config/omarchy/bercail.hook" "$OMARCHY_POST_UPDATE_HOOK" || fail "hook not installed on Omarchy"
[[ -x "$OMARCHY_POST_UPDATE_HOOK" ]] || fail "hook not executable"
printf 'PASS: Omarchy gets the post-update hook\n'

out="$(deploy_omarchy_post_update_hook)"
[[ "$out" == *"unchanged: $OMARCHY_POST_UPDATE_HOOK"* ]] || fail "second update should leave the hook alone: $out"
listing="$(cd "$HOOK_DIR" && ls)"
[[ "$listing" == $'bercail.hook\nsetup-agent.hook' ]] || fail "second update duplicated hooks: $listing"
printf 'stale\n' >"$OMARCHY_POST_UPDATE_HOOK"
deploy_omarchy_post_update_hook >/dev/null
cmp -s "$ROOT/config/omarchy/bercail.hook" "$OMARCHY_POST_UPDATE_HOOK" || fail "update should refresh a stale hook"
[[ "$(cd "$HOOK_DIR" && ls)" == "$listing" ]] || fail "refresh duplicated hooks"
printf 'PASS: bercail update keeps one hook in place\n'

# --- the hook ---

REMOTE="$TMP_DIR/remote.git"
SRC="$TMP_DIR/src"
RAN="$TMP_DIR/update-ran"
git init --quiet --bare -b master "$REMOTE"
git clone --quiet "$REMOTE" "$SRC" 2>/dev/null
git -C "$SRC" switch --quiet -c master
mkdir -p "$SRC/bin"
cat >"$SRC/bin/bercail" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >"$RAN"
[[ ! -f "$TMP_DIR/update-fails" ]] || exit 1
[[ -f "$TMP_DIR/ask-binding" ]] || exit 0
# The prompt a real bercail update shows when the Herdr binding is missing.
source "$ROOT/lib/common.sh"
source "$ROOT/lib/detect.sh"
source "$ROOT/lib/omarchy.sh"
patch_hypr_herdr_binding
EOF
chmod +x "$SRC/bin/bercail"
printf 'one\n' >"$SRC/README"
git -C "$SRC" add -A
git -C "$SRC" commit --quiet -m one
git -C "$SRC" push --quiet -u origin master 2>/dev/null
mkdir -p "$HOME/.local/share/bercail"
printf '%s\n' "$SRC" >"$HOME/.local/share/bercail/source-path"

# Pushes a commit to the remote from a second clone.
remote_commit() {
  local other="$TMP_DIR/other"
  rm -rf "$other"
  git clone --quiet "$REMOTE" "$other" 2>/dev/null
  printf '%s\n' "$1" >>"$other/README"
  git -C "$other" commit --quiet -am "$1"
  git -C "$other" push --quiet origin master 2>/dev/null
}

run_hook() {
  rm -f "$RAN"
  out="$(bash "$OMARCHY_POST_UPDATE_HOOK" 2>&1)" || fail "hook exited non-zero: $out"
}

expect_skip() {
  local why="$1" label="$2"
  run_hook
  [[ "$out" == "bercail: skipping update ($why"* ]] || fail "$label: wrong line: $out"
  [[ "$(printf '%s\n' "$out" | wc -l)" -eq 1 ]] || fail "$label: more than one line: $out"
  [[ ! -e "$RAN" ]] || fail "$label: bercail update ran"
  printf 'PASS: hook exits 0 and logs one line when %s\n' "$label"
}

remote_commit two
run_hook
[[ "$(git -C "$SRC" rev-parse HEAD)" == "$(git -C "$REMOTE" rev-parse master)" ]] || fail "hook did not fast-forward: $out"
[[ "$(cat "$RAN" 2>/dev/null)" == update ]] || fail "hook did not run bercail update: $out"
[[ "$out" == "bercail: updating from $SRC (master @ "* ]] || fail "hook should say what it updates from: $out"
printf 'PASS: hook fast-forwards the clone and runs bercail update\n'

touch "$TMP_DIR/update-fails"
run_hook
[[ "$out" == *"bercail: bercail update failed"* ]] || fail "a failed update should be logged: $out"
rm -f "$TMP_DIR/update-fails"
printf 'PASS: hook exits 0 when bercail update fails\n'

# A prompt must take its default instead of waiting: with no terminal, and on
# one, since omarchy-update runs its hooks in a terminal window.
BINDINGS="$HOME/.config/hypr/bindings.lua"
mkdir -p "$(dirname "$BINDINGS")"
printf -- '-- no herdr here\n' >"$BINDINGS"
touch "$TMP_DIR/ask-binding"
expect_no_wait() {
  local label="$1"
  [[ "$(cat "$RAN" 2>/dev/null)" == update ]] || fail "$label: bercail update did not run: $out"
  [[ "$out" == *"not asking, answering no: Patch "*"to launch the Herdr app"* ]] \
    || fail "$label: the prompt should be answered no and logged: $out"
  [[ "$out" != *"[y/N]"* ]] || fail "$label: the hook showed a prompt: $out"
  [[ "$(cat "$BINDINGS")" == "-- no herdr here" ]] || fail "$label: bindings were patched"
  printf 'PASS: hook answers no to prompts %s\n' "$label"
}
rm -f "$RAN"
out="$(timeout 20 setsid -w bash "$OMARCHY_POST_UPDATE_HOOK" </dev/null 2>&1)" \
  || fail "hook with no tty exited non-zero or hung: $out"
expect_no_wait "with no tty"
if command -v script >/dev/null 2>&1; then
  rm -f "$RAN"
  out="$(timeout 20 script -qec "bash '$OMARCHY_POST_UPDATE_HOOK'" /dev/null </dev/null 2>&1)" \
    || fail "hook on a terminal exited non-zero or hung: $out"
  expect_no_wait "on a terminal"
fi
rm -f "$TMP_DIR/ask-binding"

printf 'local edit\n' >>"$SRC/README"
expect_skip "$SRC has uncommitted changes" "the clone is dirty"
git -C "$SRC" checkout --quiet README

git -C "$SRC" remote set-url origin "$TMP_DIR/offline.git"
expect_skip "cannot fetch $SRC (offline?)" "offline"
git -C "$SRC" remote set-url origin "$REMOTE"

git -C "$SRC" switch --quiet -c feature
expect_skip "$SRC is on feature, not master or main" "the clone is off trunk"
git -C "$SRC" switch --quiet master

remote_commit three
printf 'mine\n' >"$SRC/MINE"
git -C "$SRC" add MINE
git -C "$SRC" commit --quiet -m mine
expect_skip "$SRC cannot fast-forward master" "the clone has diverged"

rm -f "$HOME/.local/share/bercail/source-path"
expect_skip "no bercail clone recorded" "no clone is recorded"
