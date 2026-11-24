#!/usr/bin/env bats
# A repo's desk secret (lib/desk-secret.sh) and bstack's op shim
# (bstack/pi/op-shim/op): which files count, what policy show --json and doctor
# say, and where the token goes. A fake op stands in for 1Password; it acts as
# op 2.42 does, whose op run hands its child op's own environment.
# shellcheck disable=SC2016

setup() {
  load test_helper
  isolate
  need git jq
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig" GIT_CONFIG_NOSYSTEM=1
  git config --global user.name test
  git config --global user.email test@example.com
  BIN="$BATS_TEST_TMPDIR/bin"
  # The real op's stand-in, where you cannot write it, as the shim requires.
  SYS="$BATS_TEST_TMPDIR/sys"
  mkdir "$SYS"
  sys_op <<EOF
#!/usr/bin/env bash
printf '%s' "\${OP_SERVICE_ACCOUNT_TOKEN:-}" >"$BATS_TEST_TMPDIR/op.token"
# Only op run takes a --: what follows is its child.
for ((i = 1; i <= \$#; i++)); do [[ "\${!i}" == -- ]] && exec "\${@:i+1}"; done
case "\$1" in
  whoami) [[ -z "\${OP_SERVICE_ACCOUNT_TOKEN:-}" ]] || printf '{"user_type":"SERVICE_ACCOUNT"}\n' ;;
esac
EOF
  export PATH="$BIN:/usr/bin:/bin"
  # The shim runs op from fixed system paths only; this copy's is the stand-in.
  SHIM="$BATS_TEST_TMPDIR/op-shim/op"
  mkdir -p "${SHIM%/*}"
  sed "s|^for candidate in /usr/bin/op /usr/local/bin/op /opt/homebrew/bin/op; do$|for candidate in $SYS/op; do|" \
    "$ROOT/bstack/pi/op-shim/op" >"$SHIM"
  chmod +x "$SHIM"
  grep -q "^for candidate in $SYS/op; do$" "$SHIM" || fail "the shim no longer names where op is"
  TOKEN="ops_dummy-$RANDOM$RANDOM"
  export BERCAIL_CONFIG="$BATS_TEST_TMPDIR/config.toml"
  REPO="$BATS_TEST_TMPDIR/work/repo"
  git_init "$REPO"
  SECRETS="$BATS_TEST_TMPDIR/secrets"
  mkdir -m 700 "$SECRETS"
  SECRET="$SECRETS/repo-agents.op"
  printf '%s\n' "$TOKEN" >"$SECRET"
  chmod 600 "$SECRET"
  printf '[desk_secrets."%s"]\nop_service_account = "%s"\n' "$REPO" "$SECRET" >"$BERCAIL_CONFIG"
}

teardown() { chmod -R u+w "$SYS"; }

# SYS/op from stdin, then it and its folder made read-only. Empty stdin: no op.
sys_op() {
  chmod u+w "$SYS"
  rm -f "$SYS/op"
  cat >"$SYS/op"
  if [[ -s "$SYS/op" ]]; then chmod 555 "$SYS/op"; else rm "$SYS/op"; fi
  chmod 555 "$SYS"
}

secret_json() { "$ROOT/bin/bercail" policy show --json "$1" | jq -c .desk_secret; }
problem() { "$ROOT/bin/bercail" policy show --json "$REPO" | jq -r .desk_secret.problem; }
shim() { BERCAIL_OP_SERVICE_ACCOUNT="$SECRET" "$SHIM" "$@"; }

@test "policy show --json names the desk secret of a repo, and of its linked worktrees" {
  git -C "$REPO" worktree add -q "$BATS_TEST_TMPDIR/work/repo.feature"
  local want
  want="$(jq -cn --arg file "$SECRET" '{file: $file, problem: ""}')"
  [[ "$(secret_json "$REPO")" == "$want" ]] || fail "main: $(secret_json "$REPO")"
  [[ "$(secret_json "$BATS_TEST_TMPDIR/work/repo.feature")" == "$want" ]] || fail "worktree: $(secret_json "$BATS_TEST_TMPDIR/work/repo.feature")"
  git_init "$BATS_TEST_TMPDIR/work/other"
  [[ "$(secret_json "$BATS_TEST_TMPDIR/work/other")" == null ]] || fail "another repo has none"
}

@test "a desk secret whose mode stat cannot read is refused, not taken for 0600" {
  mkdir -p "$BIN"
  printf '#!/bin/sh\nexit 1\n' >"$BIN/stat"
  chmod +x "$BIN/stat"
  [[ "$(problem)" == "$SECRET is readable by others; chmod 600 it" ]] || fail "no mode: $(problem)"
}

@test "a desk secret that is loose, empty, a link, in an open folder or in a repo is refused" {
  chmod 640 "$SECRET"
  [[ "$(problem)" == *"readable by others; chmod 600 it" ]] || fail "0640: $(problem)"
  chmod 600 "$SECRET"
  chmod 750 "$SECRETS"
  [[ "$(problem)" == "$SECRETS is open to others; chmod 700 it" ]] || fail "0750 folder: $(problem)"
  chmod 700 "$SECRETS"
  : >"$SECRET"
  [[ "$(problem)" == "$SECRET is empty" ]] || fail "empty: $(problem)"
  rm "$SECRET"
  [[ "$(problem)" == "$SECRET does not exist" ]] || fail "missing: $(problem)"
  printf '%s\n' "$TOKEN" >"$SECRETS/real"
  chmod 600 "$SECRETS/real"
  ln -s "$SECRETS/real" "$SECRET"
  [[ "$(problem)" == "$SECRET is not a regular file" ]] || fail "symlink: $(problem)"
  rm "$SECRET"
  mkdir -m 700 "$REPO/.secrets"
  printf '%s\n' "$TOKEN" >"$REPO/.secrets/t.op"
  chmod 600 "$REPO/.secrets/t.op"
  printf '[desk_secrets."%s"]\nop_service_account = "%s"\n' "$REPO" "$REPO/.secrets/t.op" >"$BERCAIL_CONFIG"
  [[ "$(problem)" == *"inside a git checkout"* ]] || fail "in the repo: $(problem)"
}

@test "the op shim gives the token to op's environment and nothing else" {
  run shim whoami --format json
  [[ "$status" -eq 0 && "$output" == '{"user_type":"SERVICE_ACCOUNT"}' ]] || fail "whoami: $status $output"
  [[ "$(cat "$BATS_TEST_TMPDIR/op.token")" == "$TOKEN" ]] || fail "op did not get the file's token"
  [[ -z "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]] || fail "the caller's environment has a token"
  # No file named: op as it is, which asks the 1Password app.
  run "$SHIM" whoami
  [[ "$status" -eq 0 && -z "$output" && ! -s "$BATS_TEST_TMPDIR/op.token" ]] || fail "unnamed: $status $output"
}

@test "an op put ahead on PATH, or in the repo, never gets the token from the shim" {
  mkdir "$BATS_TEST_TMPDIR/rogue" "$REPO/bin"
  for op in "$BATS_TEST_TMPDIR/rogue/op" "$REPO/bin/op"; do
    printf '#!/bin/sh\nenv >>"%s"\n' "$BATS_TEST_TMPDIR/rogue.env" >"$op"
    chmod +x "$op"
  done
  cd "$REPO"
  PATH="${SHIM%/*}:$BATS_TEST_TMPDIR/rogue:bin:$PATH" BERCAIL_OP_SERVICE_ACCOUNT="$SECRET" run op whoami
  [[ "$status" -eq 0 && "$(cat "$BATS_TEST_TMPDIR/op.token")" == "$TOKEN" ]] || fail "the real op did not run: $status"
  [[ ! -e "$BATS_TEST_TMPDIR/rogue.env" ]] || fail "an op on PATH ran instead of the real one"
  # An op you can replace (Homebrew's, say) could be swapped for one that keeps the token.
  rm "$BATS_TEST_TMPDIR/op.token"
  chmod u+w "$SYS"
  run shim whoami
  [[ "$status" -eq 127 && "$output" == *"no 1Password CLI you cannot write"* ]] || fail "writable folder: $status $output"
  chmod 555 "$SYS"
  chmod u+w "$SYS/op"
  run shim whoami
  [[ "$status" -eq 127 && ! -e "$BATS_TEST_TMPDIR/op.token" ]] || fail "writable op: $status $output"
}

@test "op run -- printenv OP_SERVICE_ACCOUNT_TOKEN through the shim prints nothing" {
  run shim run -- printenv OP_SERVICE_ACCOUNT_TOKEN
  [[ "$status" -eq 1 && -z "$output" ]] || fail "op run's child saw a token: $status ${output//$TOKEN/<token>}"
  run shim --account me run --env-file .env -- sh -c 'printf "%s|%s" "${OP_SERVICE_ACCOUNT_TOKEN:-none}" "$PATH"'
  [[ "$status" -eq 0 && "$output" == "none|$PATH" ]] || fail "with flags: $status ${output//$TOKEN/<token>}"
  run shim plugin run -- printenv OP_SERVICE_ACCOUNT_TOKEN
  [[ "$status" -eq 1 && -z "$output" ]] || fail "op plugin run's child saw a token: $status"
  run shim run printenv
  [[ "$status" -eq 2 && "$output" == *"op run [flags] -- COMMAND"* && "$output" != *"$TOKEN"* ]] || fail "no --: $status"
  run shim run --help
  [[ "$status" -eq 0 ]] || fail "op run --help: $status"
}

@test "the shim stops on an empty secret, and decrypts a .cred with systemd-creds" {
  : >"$SECRET"
  run shim whoami
  [[ "$status" -eq 1 && "$output" == *"is empty"* && ! -e "$BATS_TEST_TMPDIR/op.token" ]] || fail "empty: $status $output"
  cat >"$BIN/systemd-creds" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >"$BATS_TEST_TMPDIR/creds.argv"
printf '%s\n' "$TOKEN"
EOF
  chmod +x "$BIN/systemd-creds"
  BERCAIL_OP_SERVICE_ACCOUNT="$SECRETS/repo-agents.cred" run "$SHIM" whoami
  [[ "$status" -eq 0 && "$(cat "$BATS_TEST_TMPDIR/op.token")" == "$TOKEN" ]] || fail "cred: $status $output"
  [[ "$(cat "$BATS_TEST_TMPDIR/creds.argv")" == "decrypt --user $SECRETS/repo-agents.cred -" ]] || fail "$(cat "$BATS_TEST_TMPDIR/creds.argv")"
}

@test "doctor says present, 0600, service account, or what is wrong, and never the token" {
  # shellcheck source=/dev/null
  source "$ROOT/lib/common.sh"
  # shellcheck source=/dev/null
  source "$ROOT/lib/desk-secret.sh"
  mkdir -p "$BERCAIL_SHARE_DIR/pi/op-shim"
  cp "$SHIM" "$BERCAIL_SHARE_DIR/pi/op-shim/op"
  local out
  out="$(doctor_desk_secrets)" || fail "ok fails doctor: $out"
  [[ "$out" == "  ok  desk secret for $REPO: present, 0600, service account" ]] || fail "ok: $out"
  # A revoked token: op signs nobody in.
  printf '#!/bin/sh\nexit 1\n' | sys_op
  ! out="$(doctor_desk_secrets)" || fail "a revoked token passes"
  [[ "$out" == *"failing  desk secret for $REPO: op whoami"* ]] || fail "revoked: $out"
  sys_op </dev/null
  ! out="$(doctor_desk_secrets)" || fail "no op passes"
  [[ "$out" == *"missing  op (the 1Password CLI) in /usr/bin, /usr/local/bin or /opt/homebrew/bin"* ]] || fail "no op: $out"
  chmod 644 "$SECRET"
  ! out="$(doctor_desk_secrets)" || fail "a loose file passes"
  [[ "$out" == *"unusable  desk secret for $REPO: $SECRET is readable by others"* ]] || fail "loose: $out"
  out="$("$ROOT/bin/bercail" policy show --json "$REPO")"
  [[ "$out" != *"$TOKEN"* ]] || fail "policy show printed the token"
}

@test "a desk in a repo with a desk secret shows the token nowhere: not its env, record, screen or hc calls" {
  need flock
  export HC_TERMINAL_ID=t9
  # Events keep coming, as hc's do, so the desk's watcher sees it end at once.
  cat >"$BIN/hc" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$BATS_TEST_TMPDIR/hc.log"
[[ "\$1" != get ]] || printf '{"labels":{"bercail.role":"agent","bercail.space":"sp1"}}\n'
[[ "\$1" != events ]] || while printf '{}\\n'; do sleep 0.2; done
EOF
  # The desk's screen: what the harness got, argv and environment.
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*"; env\n' >"$BIN/pi"
  chmod +x "$BIN/hc" "$BIN/pi"
  cd "$REPO"
  # The watcher and the start sweep outlive the desk and write in this HOME, so
  # bats could not remove it. They inherit fd 8 and its lock: the lock frees
  # when the last of them is gone.
  exec 8>"$BATS_TEST_TMPDIR/desk.lock"
  flock 8
  run "$ROOT/bin/bercail-desk-agent" --prompt "Your job is beads issue x-1: t." pi --model m
  exec 8>&-
  flock -w 30 "$BATS_TEST_TMPDIR/desk.lock" true || fail "the desk's watcher or sweep still runs"
  [[ "$status" -eq 0 && "$output" == *"--model m"* ]] || fail "the desk did not start: $status"
  local record="$XDG_STATE_HOME/bercail/desk-sessions/t9.json"
  [[ -s "$record" ]] || fail "no desk record"
  for text in "$output" "$(cat "$record")" "$(cat "$BATS_TEST_TMPDIR/hc.log")"; do
    [[ "$text" != *"$TOKEN"* && "$text" != *"$SECRET"* ]] || fail "the token or its file showed"
  done
}

# bats test_tags=live
@test "live: the real op hands op run's child the token, and the shim takes it back out" {
  [[ -x /usr/bin/op ]] || skip "no /usr/bin/op"
  # No network and a scratch HOME: a dummy token, never a real account or app.
  # A pid namespace of its own: op may start an op daemon, which outlives op
  # run, and the kernel stops it once op ends.
  unshare -rnpf true 2>/dev/null || skip "unshare -rnpf is not allowed here"
  local raw shimmed
  raw="$(unshare -rnpf env OP_SERVICE_ACCOUNT_TOKEN="$TOKEN" /usr/bin/op run -- printenv OP_SERVICE_ACCOUNT_TOKEN || true)"
  shimmed="$(unshare -rnpf env BERCAIL_OP_SERVICE_ACCOUNT="$SECRET" "$ROOT/bstack/pi/op-shim/op" \
    run -- sh -c 'echo ran; printenv OP_SERVICE_ACCOUNT_TOKEN' || true)"
  [[ "$raw" == "$TOKEN" ]] || fail "real op no longer passes the token on; the shim's strip may be moot"
  [[ "$shimmed" == ran ]] || fail "through the shim, op run's child did not run, or saw a token"
}
