#!/usr/bin/env bats
# How a deploy puts a file in place (copy_file, lib/common.sh): a new file
# renamed over the old one, so a bercail or Pi already reading it is not torn.
# Everything under a temp HOME.

setup() {
  load test_helper
  isolate
  BIN="$HOME/.local/bin"
  mkdir -p "$BIN"
}

libs() {
  bash -c 'set -euo pipefail; source "$ROOT/lib/common.sh"; for n in "${BERCAIL_LIBS[@]}"; do source "$ROOT/lib/$n.sh"; done; '"$1"
}

@test "a deploy over a running bercail leaves it reading on in the file it started with" {
  local dir="$BATS_TEST_TMPDIR/run" pid i
  mkdir -p "$dir"
  # The worker that waits on a card while an update runs, then goes on.
  cat >"$BIN/bercail" <<'EOF'
#!/usr/bin/env bash
: >"$1/started"
while [[ ! -e "$1/go" ]]; do sleep 0.05; done
echo old-end
EOF
  chmod +x "$BIN/bercail"
  # Its next line, at the old offset, falls inside this comment.
  { printf '#!/usr/bin/env bash\n#%0200d\n' 0; printf 'echo new-end\n'; } >"$BATS_TEST_TMPDIR/new"
  "$BIN/bercail" "$dir" >"$dir/out" 2>&1 &
  pid=$!
  for ((i = 0; i < 100; i++)); do [[ -e "$dir/started" ]] && break; sleep 0.05; done
  local ok=1
  [[ -e "$dir/started" ]] && libs "copy_file '$BATS_TEST_TMPDIR/new' '$BIN/bercail'" >/dev/null || ok=0
  # Let the worker finish whatever failed, so the test does not wait on it.
  : >"$dir/go"
  ((ok)) || { wait "$pid" || true; fail "the bercail did not start, or copy_file failed"; }
  wait "$pid" || fail "the running bercail failed: $(cat "$dir/out")"
  [[ "$(cat "$dir/out")" == old-end ]] || fail "it read the new file at its old offset: $(cat "$dir/out")"
  cmp -s "$BATS_TEST_TMPDIR/new" "$BIN/bercail" || fail "the new bercail is not in place"
  [[ -x "$BIN/bercail" ]] || fail "the new bercail lost its mode"
  [[ "$(ls -A "$BIN")" == bercail ]] || fail "left behind: $(ls -A "$BIN")"
}

@test "a deploy keeps the mode of the file it replaces, gives a new file the source's under the umask, and writes through a link" {
  local src="$BATS_TEST_TMPDIR/src" dots="$BATS_TEST_TMPDIR/dotfiles"
  mkdir -p "$dots"
  printf 'new\n' >"$src"
  chmod 644 "$src"
  printf 'old\n' >"$BIN/kept"
  chmod 600 "$BIN/kept"
  printf 'old\n' >"$dots/linked"
  ln -s "$dots/linked" "$BIN/linked"
  libs "umask 027; copy_file '$src' '$BIN/kept'; copy_file '$src' '$BIN/linked'; copy_file '$src' '$BIN/new'" >/dev/null \
    || fail "copy_file failed"
  [[ "$(cat "$BIN/kept")" == new && "$(stat -c %a "$BIN/kept")" == 600 ]] \
    || fail "kept: $(stat -c %a "$BIN/kept") $(cat "$BIN/kept")"
  [[ -L "$BIN/linked" && "$(cat "$dots/linked")" == new ]] || fail "the link was not written through"
  [[ "$(stat -c %a "$BIN/new")" == 640 ]] || fail "new: $(stat -c %a "$BIN/new")"
  [[ "$(ls -A "$BIN")" == $'kept\nlinked\nnew' ]] || fail "left behind: $(ls -A "$BIN")"
}

@test "an update's last steps leave the installed bercail whole for a bercail started during it" {
  export INSTALL_SRC="$ROOT" PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  printf '#!/bin/sh\nexit 0\n' >"$BATS_TEST_TMPDIR/bin/omarchy-hook-install"
  chmod +x "$BATS_TEST_TMPDIR/bin/omarchy-hook-install"
  # Opened between the copy of bin/bercail and deploy_finalize_permissions.
  libs "deploy_install_file bin/bercail '$BIN/bercail'
    exec 3<'$BIN/bercail'
    deploy_finalize_permissions
    cmp -s - '$ROOT/bin/bercail' <&3" >/dev/null || fail "the bercail it read was emptied or changed"
}

@test "a deploy onto a folder, or a link to one, fails and leaves the folder as it was" {
  local src="$BATS_TEST_TMPDIR/src" dest
  printf 'new\n' >"$src"
  mkdir -p "$BIN/occupied" "$BATS_TEST_TMPDIR/elsewhere"
  : >"$BIN/occupied/mine"
  ln -s "$BATS_TEST_TMPDIR/elsewhere" "$BIN/linked"
  for dest in "$BIN/occupied" "$BIN/linked"; do
    run libs "copy_file '$src' '$dest'"
    ((status == 1)) || fail "$dest: exit $status: $output"
    [[ "$output" == *"$dest is a folder where a file goes"* ]] || fail "$dest: $output"
  done
  [[ "$(ls -A "$BIN/occupied")" == mine && -z "$(ls -A "$BATS_TEST_TMPDIR/elsewhere")" ]] \
    || fail "a folder changed: $(ls -A "$BIN/occupied" "$BATS_TEST_TMPDIR/elsewhere")"
  [[ "$(ls -A "$BIN")" == $'linked\noccupied' ]] || fail "left behind: $(ls -A "$BIN")"
}
