#!/usr/bin/env bats
# Fixtures contain shell code whose variables must expand only when executed.
# Each @test runs in its own process, so its exports are meant to end with it.
# shellcheck disable=SC2016,SC2030,SC2031

setup() {
  load test_helper
  isolate
  set -o pipefail
  # shellcheck disable=SC1091
  source "$ROOT/skills/handoff/scripts/handoff-spawn"
  # _bd_stub logs here, also when a $(...) subshell runs it.
  export BD_COMMENTS="$BATS_TEST_TMPDIR/bd-comments"
  ISSUE="bercail-0s1"
}

# A failed test must not leave the hung gt this file backgrounds.
teardown() {
  local reap="$BATS_TEST_TMPDIR/reap" pid
  [[ -f "$reap" ]] || return 0
  while IFS= read -r pid; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done <"$reap"
}

# Poll until $1 is true, or $2 seconds pass. The sleep is the poll, not a guess.
wait_for() {
  local cond="$1" secs="${2:-30}" i
  for ((i = 0; i < secs * 10; i++)); do
    # shellcheck disable=SC2294 # the condition is the signal the caller names
    if eval "$cond"; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

# A zombie still answers kill -0. Gone means exited, reaped or not.
_gone() {
  local stat
  stat="$(ps -p "$1" -o stat= 2>/dev/null || true)"
  stat="${stat// /}"
  [[ -z "$stat" || "$stat" == Z* ]]
}

# A Herdr app that is not running.
_no_herdr() {
  printf '#!/bin/sh\nexit 1\n' >"$BATS_TEST_TMPDIR/no-herdr"
  chmod +x "$BATS_TEST_TMPDIR/no-herdr"
}

# A live Herdr app showing space sp26.
_fake_herdr_app() {
  cat >"$BATS_TEST_TMPDIR/fake-herdr-app" <<'EOF'
#!/bin/sh
echo '{"space":"sp26"}'
EOF
  chmod +x "$BATS_TEST_TMPDIR/fake-herdr-app"
}

# Left side of a foreground `writer | script` pipe. A background script does not
# turn this byte into SIGINT. Send it only after gt's pid file exists (the INT
# trap is installed by then), and hold the pipe until the spawn shell is gone
# or it carried on, so EOF is not what stops the session.
_ctrlc_writer() {
  local pids="$1" sent="$2" shellpid="$3" carried="$4" sp cq
  if ! wait_for '[[ -s "$pids" ]]'; then
    return 0
  fi
  sp="$(<"$shellpid")"
  printf '\003'
  : >"$sent"
  printf -v cq '%q' "$carried"
  wait_for "_gone $sp || [[ -e $cq ]]" || true
}

git_dir() { git -C "$1" rev-parse --path-format=absolute --git-common-dir; }

# What any gt command leaves behind in a repo: the config, nothing tracked.
graphite_auto_init() {
  printf '{"trunk":"master","trunks":[{"name":"master"}]}\n' >"$(git_dir "$1")/.graphite_repo_config"
}

@test "dirty copy is working tree only (no git add)" {
  local main="$BATS_TEST_TMPDIR/main" sibling="$BATS_TEST_TMPDIR/sibling"
  git_init "$main"
  git -C "$main" worktree add --detach -q "$sibling"

  printf 'base\nstaged\n' >"$main/file.txt"
  git -C "$main" add file.txt
  printf 'base\nstaged\nunstaged\n' >"$main/file.txt"
  printf 'loose\n' >"$main/untracked.txt"

  handoff_copy_dirty "$main" "$sibling"

  grep -qx 'loose' "$sibling/untracked.txt" || fail "untracked file should be copied"
  git -C "$sibling" diff --cached --quiet \
    || fail "sibling index must stay at HEAD (no git add)"
  git -C "$sibling" diff --quiet HEAD \
    && fail "sibling working tree should include tracked dirty files"
  grep -q unstaged "$sibling/file.txt" || fail "unstaged edit missing in sibling"
  if git -C "$sibling" ls-files --error-unmatch untracked.txt >/dev/null 2>&1; then
    fail "untracked copy must not be git-added"
  fi
}

@test "handoff-spawn --help exits 2" {
  local rc=0
  "$ROOT/skills/handoff/scripts/handoff-spawn" --help >/dev/null 2>&1 || rc=$?
  [[ "$rc" -eq 2 ]] || fail "usage should exit 2, got $rc"
}

@test "the agent prompt is one line pointing at the beads issue" {
  [[ "$(handoff_issue_prompt bercail-0s1)" == 'Your job is beads issue bercail-0s1. Run `bd show bercail-0s1` (read its comments too) and do the work it describes.' ]] \
    || fail "prompt points at the issue: $(handoff_issue_prompt bercail-0s1)"
  [[ "$(handoff_issue_prompt bercail-0s1 'Show the title')" == 'Your job is beads issue bercail-0s1: Show the title. Run `bd show bercail-0s1` (read its comments too) and do the work it describes.' ]] \
    || fail "prompt with a title: $(handoff_issue_prompt bercail-0s1 'Show the title')"
  [[ "$(handoff_issue_prompt bercail-0s1 'Done.')" == 'Your job is beads issue bercail-0s1: Done. Run `bd show bercail-0s1` (read its comments too) and do the work it describes.' ]] \
    || fail "a trailing period on the title must not read as two: $(handoff_issue_prompt bercail-0s1 'Done.')"
  handoff_issue_id_ok bercail-0s1 || fail "plain beads id"
  handoff_issue_id_ok bercail-0s1.2 || fail "child beads id"
  handoff_issue_id_ok --help && fail "flag is not an id"
  handoff_issue_id_ok ../x && fail "path is not an id"
  if handoff_issue_id_ok 'bercail-0s1 rm'; then fail "space is not an id"; fi
}

@test "a new branch in a linked worktree is gt tracked on trunk" {
  local repo="$BATS_TEST_TMPDIR/gt-linked" sibling="$BATS_TEST_TMPDIR/gt-linked.feat" bin="$BATS_TEST_TMPDIR/gt-bin"
  git_init "$repo"
  git -C "$repo" worktree add -q -b feat "$sibling"
  printf '{"trunk":"master"}\n' >"$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir)/.graphite_repo_config"
  mkdir -p "$bin"
  # A fake gt: a new branch has no parent yet.
  cat >"$bin/gt" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$BATS_TEST_TMPDIR/gt.log"
case "\$*" in *" parent "*) exit 1 ;; esac
EOF
  chmod +x "$bin/gt"
  : >"$BATS_TEST_TMPDIR/gt.log"
  PATH="$bin:$PATH" handoff_track_graphite "$sibling"
  grep -qxF -- "--cwd $sibling track --parent master --no-interactive" "$BATS_TEST_TMPDIR/gt.log" \
    || fail "new branch should be tracked on trunk; log=$(cat "$BATS_TEST_TMPDIR/gt.log")"
}

@test "--info reports dirty, git, and herdr without agent inspection" {
  local repo="$BATS_TEST_TMPDIR/info-repo" out
  git_init "$repo"
  printf 'dirty\n' >>"$repo/file.txt"
  printf 'loose\n' >"$repo/untracked.txt"
  # git -C prints the path relative to $repo, not to the cwd.
  printed="$(git -C "$repo" rev-parse --git-path .graphite_repo_config)"
  [[ "$printed" == /* ]] || printed="$repo/$printed"
  mkdir -p "$(dirname "$printed")"
  printf '{}\n' >"$printed"
  printf '#!/bin/sh\nexit 1\n' >"$BATS_TEST_TMPDIR/no-herdr"
  chmod +x "$BATS_TEST_TMPDIR/no-herdr"
  unset HC_TERMINAL_ID HANDOFF_SPACE
  out="$(cd "$repo" && HERDR_APP_BIN="$BATS_TEST_TMPDIR/no-herdr" \
    "$ROOT/skills/handoff/scripts/handoff-spawn" --info)"
  printf '%s' "$out" | jq -e '.git == "gh"' >/dev/null || fail "info with only an auto-created config: $out"
  git -C "$repo" update-ref refs/branch-metadata/feat HEAD
  out="$(cd "$repo" && HERDR_APP_BIN="$BATS_TEST_TMPDIR/no-herdr" \
    "$ROOT/skills/handoff/scripts/handoff-spawn" --info)"
  printf '%s' "$out" | jq -e '.dirty == true' >/dev/null || fail "info dirty: $out"
  printf '%s' "$out" | jq -e '.git == "gt"' >/dev/null || fail "info git: $out"
  printf '%s' "$out" | jq -e '.default_copy == "dirty"' >/dev/null || fail "info default_copy: $out"
  printf '%s' "$out" | jq -e '.herdr == false' >/dev/null || fail "info herdr: $out"
  printf '%s' "$out" | jq -e '.herdr_env == false' >/dev/null || fail "info herdr_env: $out"
  printf '%s' "$out" | jq -e '[has("graphite", "socket", "workspace")] | any | not' >/dev/null \
    || fail "--info still prints a second name for git, herdr or space: $out"
  printf '%s' "$out" | jq -e '.main_checkout == true' >/dev/null || fail "info main_checkout: $out"
}

@test "--info treats a live Herdr app as herdr outside an hc terminal" {
  local repo="$BATS_TEST_TMPDIR/info-app" out
  git_init "$repo"
  cat >"$BATS_TEST_TMPDIR/fake-herdr-app" <<'EOF'
#!/bin/sh
echo '{"space":"sp26"}'
EOF
  chmod +x "$BATS_TEST_TMPDIR/fake-herdr-app"
  unset HC_TERMINAL_ID HANDOFF_SPACE
  out="$(cd "$repo" && HERDR_APP_BIN="$BATS_TEST_TMPDIR/fake-herdr-app" \
    "$ROOT/skills/handoff/scripts/handoff-spawn" --info)"
  printf '%s' "$out" | jq -e '.herdr == true' >/dev/null || fail "herdr: $out"
  printf '%s' "$out" | jq -e '.herdr_env == false' >/dev/null || fail "herdr_env: $out"
  printf '%s' "$out" | jq -e '.space == "sp26"' >/dev/null || fail "space: $out"
}

@test "result JSON is emitted when agent start is unconfirmed" {
  local got
  got="$(handoff_result_json "Lbl" "/tmp/wt" "br" "bercail-0s1" 0 0 gt)"
  printf '%s' "$got" | jq -e '.issue == "bercail-0s1"' >/dev/null || fail "issue: $got"
  printf '%s' "$got" | jq -e '.ok == true' >/dev/null || fail "ok: $got"
  printf '%s' "$got" | jq -e '.agent_started == false' >/dev/null || fail "started: $got"
  printf '%s' "$got" | jq -e '.git == "gt" and (has("graphite")|not)' >/dev/null || fail "git: $got"
  printf '%s' "$got" | jq -e '.path == "/tmp/wt"' >/dev/null || fail "path: $got"
  printf '%s' "$got" | jq -e '(has("stage")|not) and (has("harness")|not) and (has("issue_title")|not)' >/dev/null || fail "no stage: $got"
  got="$(handoff_result_json "Lbl" "/tmp/wt" "br" "bercail-0s1" 1 0 gh bstack pi "" "" "Show the title")"
  printf '%s' "$got" | jq -e '.issue_title == "Show the title" and .stage == "bstack" and .harness == "pi" and (has("space")|not)' >/dev/null \
    || fail "issue_title: $got"
  got="$(handoff_result_json "Lbl" "/tmp/wt" "br" "bercail-0s1" 1 0 gh bstack pi)"
  printf '%s' "$got" | jq -e '.stage == "bstack" and .harness == "pi"' >/dev/null || fail "stage/harness: $got"
  got="$(handoff_result_json L /p b i 1 0 gt bstack pi sp9 t28)"
  printf '%s' "$got" | jq -e '.space == "sp9" and .desk == "t28" and .ok and .stage == "bstack" and .harness == "pi"' >/dev/null \
    || fail "spawn JSON names the space and desk: $got"
}

@test "the space kept shown comes from --space or the shown space" {
  # The shell suite shared one TMP_DIR; these files have to exist in this test.
  _no_herdr
  _fake_herdr_app
  unset HANDOFF_SPACE
  HERDR_APP_BIN="$BATS_TEST_TMPDIR/no-herdr" handoff_shown_space && fail "parent workspace must be empty"
  # shellcheck disable=SC2034 # handoff_shown_space reads it.
  HANDOFF_SPACE=sp26
  [[ "$(HERDR_APP_BIN="$BATS_TEST_TMPDIR/no-herdr" handoff_shown_space)" == sp26 ]] || fail "--space should win"
  unset HANDOFF_SPACE
  [[ "$(HERDR_APP_BIN="$BATS_TEST_TMPDIR/fake-herdr-app" handoff_shown_space)" == sp26 ]] || fail "shown space fallback"
}

@test "--issue is required and validated; --info reports missing beads" {
  local rc=0 err out
  err="$("$ROOT/skills/handoff/scripts/handoff-spawn" --branch foo --stage bstack 2>&1)" || rc=$?
  [[ "$rc" -eq 1 ]] || fail "missing --issue should exit 1, got $rc ($err)"
  grep -q -- '--issue' <<<"$err" || fail "missing --issue message: $err"
  rc=0
  err="$("$ROOT/skills/handoff/scripts/handoff-spawn" --stage bstack --issue '../etc' --dry-run 2>&1)" || rc=$?
  [[ "$rc" -eq 1 ]] || fail "bad issue id should exit 1, got $rc ($err)"
  grep -q 'not a beads issue id' <<<"$err" || fail "bad id message: $err"
  printf '#!/bin/sh\nexit 1\n' >"$BATS_TEST_TMPDIR/no-herdr"
  chmod +x "$BATS_TEST_TMPDIR/no-herdr"
  out="$(HERDR_APP_BIN="$BATS_TEST_TMPDIR/no-herdr" HANDOFF_BD_BIN="$BATS_TEST_TMPDIR/no-bd" \
    "$ROOT/skills/handoff/scripts/handoff-spawn" --info)"
  printf '%s' "$out" | jq -e '.beads == false' >/dev/null \
    || fail "--info should report missing beads: $out"
}

@test "argv after -- is rejected so Auto-review does not bind a payload" {
  local rc=0 err
  err="$("$ROOT/skills/handoff/scripts/handoff-spawn" --branch foo --stage bstack --issue bercail-0s1 --clean -- 'QA cedar-pg' 2>&1)" || rc=$?
  [[ "$rc" -eq 1 ]] || fail "-- prompt should exit 1, got $rc ($err)"
  grep -q 'there is no prompt argument' <<<"$err" \
    || fail "double-dash message: $err"
}

@test "with --base, gt tracks the new branch on that base" {
  local repo="$BATS_TEST_TMPDIR/gt-base" sibling="$BATS_TEST_TMPDIR/gt-base.feat" bin="$BATS_TEST_TMPDIR/gt-base-bin"
  git_init "$repo"
  git -C "$repo" branch parent-branch
  git -C "$repo" worktree add -q -b feat "$sibling" parent-branch
  printf '{"trunk":"master"}\n' >"$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir)/.graphite_repo_config"
  mkdir -p "$bin"
  cat >"$bin/gt" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$BATS_TEST_TMPDIR/gt-base.log"
case "\$*" in *" parent "*) exit 1 ;; esac
EOF
  chmod +x "$bin/gt"
  : >"$BATS_TEST_TMPDIR/gt-base.log"
  PATH="$bin:$PATH" handoff_track_graphite "$sibling" parent-branch
  grep -qxF -- "--cwd $sibling track --parent parent-branch --no-interactive" "$BATS_TEST_TMPDIR/gt-base.log" \
    || fail "--base branch should be the gt parent; log=$(cat "$BATS_TEST_TMPDIR/gt-base.log")"
}

@test "--base needs --branch and is in --help" {
  local rc=0 err
  err="$("$ROOT/skills/handoff/scripts/handoff-spawn" --stage bstack --issue bercail-0s1 --base foo --dry-run 2>&1)" || rc=$?
  [[ "$rc" -eq 1 ]] || fail "--base without --branch should exit 1, got $rc ($err)"
  grep -q -- '--base needs --branch' <<<"$err" || fail "--base message: $err"
  err="$("$ROOT/skills/handoff/scripts/handoff-spawn" --help 2>&1)" || true
  grep -q -- '--base BRANCH' <<<"$err" || fail "--help should document --base"
}

@test "the handoff text follows the repo git policy" {
  local bin="$BATS_TEST_TMPDIR/policy-bin" line
  mkdir -p "$bin"
  cat >"$bin/bercail" <<'EOF'
#!/bin/sh
[ "$1 $2 $3 $4" = "policy show --json /repo" ] && printf '{"brief":"commit allow, push main"}\n'
EOF
  chmod +x "$bin/bercail"
  line="$(BERCAIL_BIN="$bin/bercail" handoff_policy_line /repo)"
  [[ "$line" == "Commit, push, or release only when asked, and then the way this repo's git policy says (bercail policy show: commit allow, push main)." ]] \
    || fail "policy line: $line"
  line="$(BERCAIL_BIN="$BATS_TEST_TMPDIR/no-bercail" handoff_policy_line /repo)"
  [[ "$line" == *"(bercail policy show)." ]] || fail "policy line without bercail: $line"
  [[ "$(BERCAIL_BIN="$BATS_TEST_TMPDIR/no-bercail" handoff_headless_comment_text bstack pi /w /w/r.json s1 0)" == *"git policy says"* ]] \
    || fail "the headless comment does not name the policy"
}

@test "--info reports bstack and autopilot stages" {
  local out
  _no_herdr
  out="$(cd "$BATS_TEST_TMPDIR" && HERDR_APP_BIN="$BATS_TEST_TMPDIR/no-herdr" \
    HANDOFF_BD_BIN="$BATS_TEST_TMPDIR/no-bd" "$ROOT/skills/handoff/scripts/handoff-spawn" --info)"
  jq -e '.stages == ["bstack","autopilot"]' <<<"$out" >/dev/null || fail "stages: $out"
}

@test "an unknown stage fails before starting a handoff" {
  local rc=0 err
  err="$("$ROOT/skills/handoff/scripts/handoff-spawn" --stage unknown --issue "$ISSUE" --dry-run 2>&1)" || rc=$?
  [[ "$rc" -eq 1 && "$err" == *'unknown stage: unknown'* ]] || fail "invalid stage: $rc $err"
}

# Stub bd: knows $BD_KNOWN ids, logs comments, reports $BD_BEADS_DIR.

_bd_stub() {
  mkdir -p "$BATS_TEST_TMPDIR/bdbin"
  cat >"$BATS_TEST_TMPDIR/bdbin/bd" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  show)
    [[ " ${BD_KNOWN:-} " == *" $2 "* ]] || { echo "no issue $2" >&2; exit 1; }
    if [[ -n "${BD_TITLE:-}" ]]; then
      jq -nc --arg id "$2" --arg title "$BD_TITLE" '[{id:$id, title:$title}]'
    else
      jq -nc --arg id "$2" '[{id:$id}]'
    fi
    ;;
  comment)
    [[ "${3:-}" == --stdin ]] || exit 3
    printf '%s\t%s\n' "$2" "$(cat)" >>"${BD_COMMENTS:?}"
    ;;
  context)
    printf '{"beads_dir":"%s"}\n' "${BD_BEADS_DIR:-$PWD/.beads}"
    ;;
  *) exit 2 ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bdbin/bd"
  export HANDOFF_BD_BIN="$BATS_TEST_TMPDIR/bdbin/bd"
  export BD_KNOWN="$ISSUE"
  export BD_COMMENTS="$BATS_TEST_TMPDIR/bd-comments"
  : >"$BD_COMMENTS"
}

# Lead profile so a Pi stage can build argv. The binary is missing until a test overrides it.

_pi_ready() {
  local profile="$BATS_TEST_TMPDIR/pi-profile" guard="$BATS_TEST_TMPDIR/pi-profile/extensions/guard.ts"
  mkdir -p "$profile/extensions" "$profile/agents" "$BATS_TEST_TMPDIR/bin"
  printf '// guard\n' >"$guard"
  jq -n --arg guard "$guard" --arg model "claude-bridge/lead-model:high" \
    '["pi","--model",$model,"-e","npm:pi-claude-bridge@0.11.0","-e",$guard]' >"$profile/lead.json"
  export HANDOFF_PI_PROFILE="$profile"
  export HANDOFF_PI_BIN="$BATS_TEST_TMPDIR/bin/pi-missing"
}

_start_fixture() {
  local wt="$1"
  mkdir -p "$wt"
  _bd_stub
  _pi_ready
  unset BD_BEADS_DIR
}

@test "handoff_result_ok takes an optional, well-formed verification array" {
  local f="$BATS_TEST_TMPDIR/verification.json"
  local base='{"status":"ready","summary":"done","session_id":"s1"}' good bad
  ok_with() { jq -c --argjson v "$1" '. + {verification: $v}' <<<"$base" >"$f"; handoff_result_ok "$f"; }
  printf '%s\n' "$base" >"$f"
  handoff_result_ok "$f" || fail "a result without verification still passes"
  for good in '[]' \
    '[{"kind":"test","command":"bash t.sh","exit_code":0,"evidence":"t.log"}]' \
    '[{"kind":"verify-skill","command":"run.sh","exit_code":1,"evidence":".bercail/verify/x"}]'; do
    ok_with "$good" || fail "should pass: $good"
  done
  for bad in '"passed"' 'false' '[1]' \
    '[{"kind":"vibes","command":"x","exit_code":0,"evidence":"e"}]' \
    '[{"kind":"test","command":"x","exit_code":"0","evidence":"e"}]' \
    '[{"kind":"test","exit_code":0,"evidence":"e"}]' \
    '[{"kind":"test","command":"x","exit_code":0}]'; do
    if ok_with "$bad"; then fail "should fail: $bad"; fi
  done
  jq -nc '{status:"ready", summary:"done"}' >"$f"
  if handoff_result_ok "$f"; then fail "session_id stays required"; fi
}

# A headless run whose agent writes $1 as its result.

_run_with_agent_result() {
  local wt="$1" result="$2" stub="$BATS_TEST_TMPDIR/bin/pi-verify"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  _start_fixture "$wt"
  cat >"$stub" <<STUB
#!/usr/bin/env bash
printf '%s\n' '$result' >"\$BERCAIL_RESULT_PATH"
STUB
  chmod +x "$stub"
  HANDOFF_PI_BIN="$stub" "$ROOT/skills/handoff/scripts/handoff-spawn" --stage bstack --issue "$ISSUE" --worktree "$wt" >/dev/null
}

@test "the runner keeps a good verification list and drops only a malformed one" {
  local wt="$BATS_TEST_TMPDIR/verify-keep" got
  _run_with_agent_result "$wt" '{"status":"ready","summary":"proved","verification":[{"kind":"test","command":"bash t.sh","exit_code":0,"evidence":"t.log"}]}' \
    || fail "run with verification"
  got="$wt/.bercail/handoff-result.json"
  jq -e '.status == "ready" and .summary == "proved" and (.session_id | length > 0)
    and .verification == [{kind:"test",command:"bash t.sh",exit_code:0,evidence:"t.log"}]' "$got" >/dev/null \
    || fail "verification must survive the run: $(cat "$got")"

  wt="$BATS_TEST_TMPDIR/verify-drop"
  _run_with_agent_result "$wt" '{"status":"ready","summary":"proved","verification":"all good"}' \
    || fail "a malformed verification list must not fail the run"
  got="$wt/.bercail/handoff-result.json"
  jq -e '.status == "ready" and (.summary | startswith("proved")) and (.summary | contains("malformed verification"))
    and (has("verification") | not)' "$got" >/dev/null \
    || fail "a malformed list is dropped and the result stands: $(cat "$got")"
}

@test "each headless prompt points at the issue; Pi has no --add-dir" {
  local wt="$BATS_TEST_TMPDIR/prompt-id" stage out
  _start_fixture "$wt"
  for stage in bstack autopilot; do
    out="$(cd "$wt" && "$ROOT/skills/handoff/scripts/handoff-spawn" --stage "$stage" --issue "$ISSUE" --worktree "$wt" --dry-run)"
    printf '%s' "$out" | jq -e --arg id "$ISSUE" '(.command[-1] | startswith("Your job is beads issue \($id).")) and .command[-2] == "--" and .bd_present == true' >/dev/null \
      || fail "$stage prompt must point at the issue: $out"
    printf '%s' "$out" | jq -e 'any(.command[]; . == "--add-dir")|not' >/dev/null \
      || fail "$stage argv must not pass --add-dir: $out"
  done
  export BD_BEADS_DIR="$BATS_TEST_TMPDIR/main-checkout/.beads"
  out="$(cd "$wt" && "$ROOT/skills/handoff/scripts/handoff-spawn" --stage bstack --issue "$ISSUE" --worktree "$wt" --dry-run)"
  printf '%s' "$out" | jq -e 'any(.command[]; . == "--add-dir")|not' >/dev/null \
    || fail "an outside .beads still gets no --add-dir: $out"
  unset BD_BEADS_DIR
}

@test "missing pi writes a blocked result and does not fall through" {
  local wt="$BATS_TEST_TMPDIR/missing-pi" rc=0 err
  _start_fixture "$wt"
  export HANDOFF_PI_BIN="$BATS_TEST_TMPDIR/no-such-pi"
  err="$(cd "$wt" && \
    "$ROOT/skills/handoff/scripts/handoff-spawn" --stage bstack --issue "$ISSUE" --worktree "$wt" 2>"$BATS_TEST_TMPDIR/missing.err")" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "missing pi should exit nonzero, got 0 ($err)"
  grep -q 'not on PATH' "$BATS_TEST_TMPDIR/missing.err" || fail "stderr should say not on PATH: $(cat "$BATS_TEST_TMPDIR/missing.err")"
  jq -e '.status=="blocked" and (.summary|test("pi")) and (.session_id | test("^[0-9a-fA-F-]{36}$"))' \
    "$wt/.bercail/handoff-result.json" >/dev/null \
    || fail "blocked result: $(cat "$wt/.bercail/handoff-result.json")"
  printf '%s' "$err" | jq -e '.status=="blocked" and (has("command")|not)' >/dev/null \
    || fail "stdout should be the blocked result, not a start command: $err"
}

@test "dry-run prints argv for bstack and autopilot; missing pi blocks" {
  local wt="$BATS_TEST_TMPDIR/all-dry" out stage rc=0 err
  _start_fixture "$wt"
  export HANDOFF_PI_BIN="$BATS_TEST_TMPDIR/gone-pi"
  export HANDOFF_BD_BIN="$BATS_TEST_TMPDIR/gone-bd"
  for stage in bstack autopilot; do
    out="$(cd "$wt" && "$ROOT/skills/handoff/scripts/handoff-spawn" \
      --stage "$stage" --issue "$ISSUE" --worktree "$wt" --dry-run)"
    printf '%s' "$out" | jq -e --arg want "$HANDOFF_PI_BIN" --arg stage "$stage" \
      '.dry_run == true and .present == false and .bd_present == false
       and .stage == $stage and .mode == "headless" and .binary == "pi"
       and .model == "claude-bridge/lead-model:high"
       and any(.command[]; . == $want) and (.command | length) > 2' >/dev/null \
      || fail "$stage dry-run should print its argv even when pi is missing: $out"
  done
  [[ ! -f "$wt/.bercail/handoff-result.json" ]] || fail "dry-run must not write a result"
  _bd_stub
  _pi_ready
  export HANDOFF_PI_BIN="$BATS_TEST_TMPDIR/gone-pi"
  err="$(cd "$wt" && "$ROOT/skills/handoff/scripts/handoff-spawn" \
    --stage bstack --issue "$ISSUE" --worktree "$wt" 2>/dev/null)" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "missing pi should exit nonzero"
  jq -e '.status=="blocked" and (.summary|test("pi is not on PATH"))' "$wt/.bercail/handoff-result.json" >/dev/null \
    || fail "missing pi should block: $(cat "$wt/.bercail/handoff-result.json")"
}

@test "missing bd or an unknown issue writes a blocked result and starts nothing" {
  local wt="$BATS_TEST_TMPDIR/bd-block" rc=0 out stub="$BATS_TEST_TMPDIR/bin/pi-ran"
  _start_fixture "$wt"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\necho ran >"%s/pi-ran"\n' "$BATS_TEST_TMPDIR" >"$stub"
  chmod +x "$stub"
  export HANDOFF_PI_BIN="$stub"
  export HANDOFF_BD_BIN="$BATS_TEST_TMPDIR/no-such-bd"
  out="$(cd "$wt" && "$ROOT/skills/handoff/scripts/handoff-spawn" --stage bstack --issue "$ISSUE" --worktree "$wt" 2>/dev/null)" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "missing bd should exit nonzero"
  jq -e '.status=="blocked" and (.summary|test("bd \\(beads\\) is not on PATH"))' "$wt/.bercail/handoff-result.json" >/dev/null \
    || fail "missing bd should block: $(cat "$wt/.bercail/handoff-result.json")"
  _bd_stub
  rc=0
  out="$(cd "$wt" && "$ROOT/skills/handoff/scripts/handoff-spawn" --stage bstack --issue bercail-nope --worktree "$wt" 2>/dev/null)" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "unknown issue should exit nonzero"
  jq -e '.status=="blocked" and (.summary|test("bercail-nope not found"))' "$wt/.bercail/handoff-result.json" >/dev/null \
    || fail "unknown issue should block: $(cat "$wt/.bercail/handoff-result.json")"
  [[ ! -f "$BATS_TEST_TMPDIR/pi-ran" ]] || fail "pi must not start without a real issue"
  [[ ! -s "$BD_COMMENTS" ]] || fail "blocked handoff must not comment: $(cat "$BD_COMMENTS")"
}

@test "--stage is required; a Pi desk needs a lead profile, not [bstack] enabled" {
  local rc=0 err
  err="$("$ROOT/skills/handoff/scripts/handoff-spawn" --branch foo --issue "$ISSUE" 2>&1)" || rc=$?
  [[ "$rc" -eq 1 ]] || fail "missing --stage should exit 1, got $rc ($err)"
  grep -q 'does not pick a stage' <<<"$err" || fail "missing --stage message: $err"
  rc=0
  err="$("$ROOT/skills/handoff/scripts/handoff-spawn" --issue "$ISSUE" --dry-run 2>&1)" || rc=$?
  [[ "$rc" -eq 1 ]] || fail "headless without --stage should exit 1, got $rc ($err)"
  # No config, and enabled = false, both fail on the lead profile only.
  rc=0
  err="$(BERCAIL_CONFIG="$BATS_TEST_TMPDIR/no-config.toml" HANDOFF_PI_PROFILE="$BATS_TEST_TMPDIR/no-pi-profile" \
    "$ROOT/skills/handoff/scripts/handoff-spawn" --branch feat --stage bstack --issue "$ISSUE" --clean --space w1 2>&1)" || rc=$?
  [[ "$rc" -eq 1 ]] || fail "missing lead profile should exit 1, got $rc ($err)"
  grep -q 'lead profile is missing' <<<"$err" || fail "missing profile message: $err"
  if grep -q 'needs bstack on' <<<"$err"; then fail "config enabled is not required: $err"; fi
  if grep -q 'wt ' <<<"$err"; then fail "must fail before wt: $err"; fi
  rc=0
  printf '[bstack]\nenabled = false\n' >"$BATS_TEST_TMPDIR/bstack-off.toml"
  err="$(BERCAIL_CONFIG="$BATS_TEST_TMPDIR/bstack-off.toml" HANDOFF_PI_PROFILE="$BATS_TEST_TMPDIR/no-pi-profile" \
    "$ROOT/skills/handoff/scripts/handoff-spawn" --branch feat --stage bstack --issue "$ISSUE" --clean 2>&1)" || rc=$?
  [[ "$rc" -eq 1 ]] || fail "enabled = false should still exit 1 on the lead profile, got $rc ($err)"
  grep -q 'lead profile is missing' <<<"$err" || fail "enabled = false message: $err"
  if grep -q 'needs bstack on' <<<"$err"; then fail "enabled = false is not a gate: $err"; fi
  if grep -q 'wt ' <<<"$err"; then fail "must fail before wt: $err"; fi
  rc=0
  err="$(HANDOFF_PI_PROFILE="$BATS_TEST_TMPDIR/no-pi-profile" \
    "$ROOT/skills/handoff/scripts/handoff-spawn" --branch feat --stage autopilot --issue "$ISSUE" --clean 2>&1)" || rc=$?
  [[ "$rc" -eq 1 ]] || fail "autopilot --branch should exit 1, got $rc ($err)"
  grep -q 'headless' <<<"$err" || fail "autopilot --branch message: $err"
}

@test "Pi keeps the minted uuid; --resume refuses anything that is not a uuid" {
  local wt="$BATS_TEST_TMPDIR/resume-uuid" rc=0 err stub="$BATS_TEST_TMPDIR/bin/pi-quiet"
  _start_fixture "$wt"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  # A Pi run whose log has no session header keeps the minted uuid.
  printf '#!/usr/bin/env bash\njq -nc %s >"$BERCAIL_RESULT_PATH"\n' \
    "'{status:\"ready\", summary:\"planned the fix\"}'" >"$stub"
  chmod +x "$stub"
  export HANDOFF_PI_BIN="$stub"
  (cd "$wt" && "$ROOT/skills/handoff/scripts/handoff-spawn" --stage bstack --issue "$ISSUE" --worktree "$wt" >/dev/null) || rc=$?
  [[ "$rc" -eq 0 ]] || fail "a ready result without a session header should still exit 0, got $rc"
  jq -e '.status == "ready" and (.session_id | test("^[0-9a-fA-F-]{36}$")) and (.summary | startswith("planned the fix")) and (.summary | test("cannot be resumed") | not)' \
    "$wt/.bercail/handoff-result.json" >/dev/null \
    || fail "minted uuid stays when the log has no header: $(cat "$wt/.bercail/handoff-result.json")"
  rc=0
  (cd "$wt" && "$ROOT/skills/handoff/scripts/handoff-spawn" --stage bstack --issue "$ISSUE" --worktree "$wt" --resume none --dry-run >/dev/null 2>&1) || rc=$?
  [[ "$rc" -eq 1 ]] || fail "--resume none must be refused, got $rc"
  rc=0
  err="$(cd "$wt" && "$ROOT/skills/handoff/scripts/handoff-spawn" --stage bstack --issue "$ISSUE" --worktree "$wt" --resume ses_abc --dry-run 2>&1)" || rc=$?
  [[ "$rc" -eq 1 ]] || fail "non-uuid resume should exit 1, got $rc"
  grep -q 'must be a uuid' <<<"$err" || fail "resume message: $err"
  unset HANDOFF_PI_BIN
}

_fake_gt() {
  local bin="$1" log="$2" body="$3"
  mkdir -p "$bin"
  : >"$log"
  cat >"$bin/gt" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$log"
args=" \$* "
$body
EOF
  chmod +x "$bin/gt"
}

_track_fixture() {
  local repo="$1" sibling="$1.feat"
  git_init "$repo"
  git -C "$repo" branch parent-branch
  git -C "$repo" worktree add -q -b feat "$sibling" parent-branch
  graphite_auto_init "$repo"
}

@test "a branch gt already knows is left alone" {
  local repo="$BATS_TEST_TMPDIR/tr-done" bin="$BATS_TEST_TMPDIR/tr-done-bin" log="$BATS_TEST_TMPDIR/tr-done.log"
  _track_fixture "$repo"
  _fake_gt "$bin" "$log" 'exit 0'
  PATH="$bin:$PATH" handoff_track_graphite "$repo.feat" parent-branch
  if grep -q ' track ' "$log"; then
    fail "a branch with a parent is not tracked again: $(cat "$log")"
  fi
}

@test "an untracked --base is tracked on trunk first, then the branch on it" {
  local repo="$BATS_TEST_TMPDIR/tr-parent" bin="$BATS_TEST_TMPDIR/tr-parent-bin" log="$BATS_TEST_TMPDIR/tr-parent.log" order
  _track_fixture "$repo"
  # Like gt: the new branch can't sit on a parent until that parent is tracked.
  _fake_gt "$bin" "$log" "
case \"\$args\" in
  *' parent --no-interactive '*) exit 1 ;;
  *' track parent-branch --parent master '*) : >'$BATS_TEST_TMPDIR/tr-parent-tracked'; exit 0 ;;
  *' track --parent parent-branch '*) [[ -f '$BATS_TEST_TMPDIR/tr-parent-tracked' ]] ;;
  *' branch info '*) echo 'ERROR: Cannot perform this operation on untracked branch parent-branch.' >&2; exit 1 ;;
  *) exit 7 ;;
esac"
  PATH="$bin:$PATH" handoff_track_graphite "$repo.feat" parent-branch
  order="$(grep -c . "$log")"
  [[ "$order" -eq 5 ]] || fail "parent check, try, is parent tracked, track parent, retry; log=$(cat "$log")"
  [[ "$(sed -n 5p "$log")" == "--cwd $repo.feat track --parent parent-branch --no-interactive" ]] \
    || fail "the branch should end up on its real parent; log=$(cat "$log")"
  if grep -q -- '--force' "$log"; then
    fail "--force must never run: $(cat "$log")"
  fi
}

@test "when the parent cannot be tracked the branch goes on trunk, with a warning" {
  local repo="$BATS_TEST_TMPDIR/tr-trunk" bin="$BATS_TEST_TMPDIR/tr-trunk-bin" log="$BATS_TEST_TMPDIR/tr-trunk.log" err
  _track_fixture "$repo"
  _fake_gt "$bin" "$log" "
case \"\$args\" in
  *' track --parent master '*) exit 0 ;;
  *' branch info '*) echo 'ERROR: Could not find branch parent-branch.' >&2; exit 1 ;;
  *) exit 1 ;;
esac"
  err="$(PATH="$bin:$PATH" handoff_track_graphite "$repo.feat" parent-branch 2>&1)" \
    || fail "fallback must not fail: $err"
  [[ "$(tail -1 "$log")" == "--cwd $repo.feat track --parent master --no-interactive" ]] \
    || fail "should end on trunk; log=$(cat "$log")"
  grep -q 'parent-branch' <<<"$err" || fail "warn that the parent was not used: $err"
  grep -qE '\[[0-9]+\]' <<<"$err" && fail "job notices on stderr: $err"
  if grep -q -- '--force' "$log"; then
    fail "--force must never run: $(cat "$log")"
  fi
}

@test "a gt failure never re-parents a tracked --base or moves the branch to trunk" {
  local repo="$BATS_TEST_TMPDIR/tr-stack" bin="$BATS_TEST_TMPDIR/tr-stack-bin" log="$BATS_TEST_TMPDIR/tr-stack.log" err
  _track_fixture "$repo"
  # The parent is tracked, so this failure is about something else.
  _fake_gt "$bin" "$log" "
case \"\$args\" in
  *' branch info --branch parent-branch '*) exit 0 ;;
  *) exit 1 ;;
esac"
  err="$(PATH="$bin:$PATH" handoff_track_graphite "$repo.feat" parent-branch 2>&1)" || fail "must not fail: $err"
  grep -q ' track parent-branch ' "$log" && fail "re-tracking a tracked parent cuts it out of its stack: $(cat "$log")"
  grep -q ' track --parent master ' "$log" && fail "a stacked branch must not silently move to trunk: $(cat "$log")"
  grep -q 'gt track --parent parent-branch' <<<"$err" || fail "warn with the real parent: $err"
}

# A locked store fails every gt call, then clears: the repair must not run on that.

@test "only an untracked or unknown --base is repaired; a locked store changes nothing" {
  local repo="$BATS_TEST_TMPDIR/tr-lock" bin="$BATS_TEST_TMPDIR/tr-lock-bin" log="$BATS_TEST_TMPDIR/tr-lock.log" err
  _track_fixture "$repo"
  _fake_gt "$bin" "$log" "
case \"\$args\" in
  *' track parent-branch '*) exit 0 ;;
  *' track --parent master '*) exit 0 ;;
  *) echo 'database is locked' >&2; exit 1 ;;
esac"
  err="$(PATH="$bin:$PATH" handoff_track_graphite "$repo.feat" parent-branch 2>&1)" || fail "must not fail: $err"
  grep -q ' track parent-branch ' "$log" && fail "a failure that is not 'untracked' re-parented the base: $(cat "$log")"
  grep -q ' track --parent master ' "$log" && fail "a failure that is not 'untracked' moved the branch to trunk: $(cat "$log")"
  grep -q 'gt track --parent parent-branch' <<<"$err" || fail "warn with the real parent: $err"
}

@test "a child gt leaves behind cannot hold the pipes of the caller" {
  local repo="$BATS_TEST_TMPDIR/tr-left" bin="$BATS_TEST_TMPDIR/tr-left-bin" log="$BATS_TEST_TMPDIR/tr-left.log" err start
  _track_fixture "$repo"
  _fake_gt "$bin" "$log" "
case \"\$args\" in
  *' parent --no-interactive '*) exit 1 ;;
  *' track '*) sleep 300 & exit 1 ;;
  *) exit 0 ;;
esac"
  start=$SECONDS
  err="$(PATH="$bin:$PATH" handoff_track_graphite "$repo.feat" parent-branch 2>&1)" || fail "must not fail: $err"
  [[ $((SECONDS - start)) -lt 15 ]] || fail "a child gt left behind held the capture for $((SECONDS - start))s"
}

@test "a bad HANDOFF_GT_TIMEOUT falls back to the default" {
  local repo="$BATS_TEST_TMPDIR/tr-badt" bin="$BATS_TEST_TMPDIR/tr-badt-bin" log="$BATS_TEST_TMPDIR/tr-badt.log" value err
  _track_fixture "$repo"
  for value in abc 1.5 30s 0 ''; do
    _fake_gt "$bin" "$log" "case \"\$args\" in *' parent --no-interactive '*) exit 1 ;; esac"
    err="$( (set -e; PATH="$bin:$PATH" HANDOFF_GT_TIMEOUT="$value" handoff_track_graphite "$repo.feat"; printf 'still-here\n') 2>&1)" \
      || fail "HANDOFF_GT_TIMEOUT=$value aborted: $err"
    grep -q 'still-here' <<<"$err" || fail "HANDOFF_GT_TIMEOUT=$value: $err"
    grep -q ' track --parent master ' "$log" || fail "HANDOFF_GT_TIMEOUT=$value skipped gt: $(cat "$log")"
  done
}

@test "gt track failing warns and returns" {
  local repo="$BATS_TEST_TMPDIR/tr-fail" bin="$BATS_TEST_TMPDIR/tr-fail-bin" log="$BATS_TEST_TMPDIR/tr-fail.log" err rc=0
  _track_fixture "$repo"
  _fake_gt "$bin" "$log" 'exit 1'
  err="$( (set -e; PATH="$bin:$PATH" handoff_track_graphite "$repo.feat" parent-branch; printf 'still-here\n') 2>&1)" || rc=$?
  [[ "$rc" -eq 0 ]] || fail "a failed gt must not abort: rc=$rc $err"
  grep -q 'still-here' <<<"$err" || fail "must keep going: $err"
  grep -q 'gt track' <<<"$err" || fail "must warn with what to run: $err"
  if grep -q -- '--force' "$log"; then
    fail "--force must never run: $(cat "$log")"
  fi
}

@test "a hung gt is killed with its children, warned about, and not retried" {
  local repo="$BATS_TEST_TMPDIR/tr-hang" bin="$BATS_TEST_TMPDIR/tr-hang-bin" log="$BATS_TEST_TMPDIR/tr-hang.log" err start body
  _track_fixture "$repo"
  # The sleep is a grandchild holding stderr: $(...) below only returns once it is dead.
  for body in \
    'sleep 300 & wait' \
    'trap "" TERM; sleep 300 & wait; sleep 300' \
    'case "$args" in *" parent "*) exit 1 ;; esac; sleep 300 & wait'; do
    _fake_gt "$bin" "$log" "$body"
    start=$SECONDS
    err="$(PATH="$bin:$PATH" HANDOFF_GT_TIMEOUT=1 handoff_track_graphite "$repo.feat" parent-branch 2>&1)" \
      || fail "a hung gt must not abort: $err"
    [[ $((SECONDS - start)) -lt 15 ]] || fail "hung gt held the spawn for $((SECONDS - start))s: $body"
    grep -q 'did not finish' <<<"$err" || fail "must warn that gt hung: $err"
    grep -qE '\[[0-9]+\]' <<<"$err" && fail "job notices on stderr: $err"
    [[ "$(grep -c ' track ' "$log")" -le 1 ]] || fail "no more gt once one has hung: $(cat "$log")"
  done
}

# Spawns usually run from a terminal, where job control has a foreground to manage.

@test "a hung gt is bounded under a controlling terminal, with no job notices" {
  script -qec true /dev/null >/dev/null 2>&1 || unavailable "no util-linux script for a pty"
  local repo="$BATS_TEST_TMPDIR/tr-pty" bin="$BATS_TEST_TMPDIR/tr-pty-bin" log="$BATS_TEST_TMPDIR/tr-pty.log" run="$BATS_TEST_TMPDIR/tr-pty.sh" out rc=0
  _track_fixture "$repo"
  _fake_gt "$bin" "$log" 'sleep 300 & wait'
  cat >"$run" <<EOF
source "$ROOT/skills/handoff/scripts/handoff-spawn"
PATH="$bin:\$PATH" HANDOFF_GT_TIMEOUT=1 handoff_track_graphite "$repo.feat" parent-branch
echo "returned rc=\$?"
EOF
  # handoff_bounded: a regression here is a hang, so the suite must not wait on it.
  out="$(handoff_bounded 20 script -qec "bash $run" /dev/null </dev/null)" || rc=$?
  [[ "$rc" -eq 0 ]] || fail "a hung gt under a terminal held the spawn: rc=$rc $out"
  grep -q 'returned rc=0' <<<"$out" || fail "should return 0: $out"
  grep -q 'did not finish' <<<"$out" || fail "should warn: $out"
  if grep -qE '\[[0-9]+\]\+?[[:space:]]+(Done|Exit|Terminated|Killed)' <<<"$out"; then
    fail "job notices on stderr: $out"
  fi
}

@test "Ctrl-C during a hung gt kills it and stops the spawn" {
  script -qec true /dev/null >/dev/null 2>&1 || unavailable "no util-linux script for a pty"
  env --default-signal=INT true 2>/dev/null || unavailable "env has no --default-signal (coreutils 8.31+)"
  local repo="$BATS_TEST_TMPDIR/tr-int" bin="$BATS_TEST_TMPDIR/tr-int-bin"
  local log="$BATS_TEST_TMPDIR/tr-int.log" run="$BATS_TEST_TMPDIR/tr-int.sh"
  local pids="$BATS_TEST_TMPDIR/tr-int.pid" carried="$BATS_TEST_TMPDIR/tr-int-carried-on"
  local shellpid="$BATS_TEST_TMPDIR/tr-int.shell" out="$BATS_TEST_TMPDIR/tr-int.out"
  local sent="$BATS_TEST_TMPDIR/tr-int.sent" pid
  _track_fixture "$repo"
  _fake_gt "$bin" "$log" "sleep 300 & echo \$! >'$pids'; wait"
  cat >"$run" <<EOF
echo \$\$ >"$shellpid"
source "$ROOT/skills/handoff/scripts/handoff-spawn"
PATH="$bin:\$PATH" handoff_track_graphite "$repo.feat"
: >"$carried"
EOF
  # Foreground pipe: script only delivers Ctrl-C from a foreground pty.
  # timeout is the hang bound, not the signal. The writer waits on gt's pid.
  # A run started in the background inherits SIGINT ignored, and bash cannot
  # trap a signal ignored on entry: give the spawn SIGINT back.
  _ctrlc_writer "$pids" "$sent" "$shellpid" "$carried" \
    | timeout 90 env --default-signal=INT script -qec "bash $run" /dev/null >"$out" 2>&1 || true
  [[ -s "$pids" ]] || fail "the fake gt never ran: $(cat "$log" 2>/dev/null)"
  pid="$(<"$pids")"
  printf '%s\n' "$pid" >>"$BATS_TEST_TMPDIR/reap"
  if ! _gone "$pid"; then
    kill -KILL "$pid" 2>/dev/null || true
    fail "Ctrl-C left gt running with nothing to bound it"
  fi
  [[ "$(grep -c . "$log")" -eq 1 ]] || fail "Ctrl-C must stop the gt calls: $(cat "$log")"
  [[ ! -e "$carried" ]] || fail "Ctrl-C must stop the spawn"
}

@test "gt output never reaches the JSON on stdout" {
  local repo="$BATS_TEST_TMPDIR/tr-out" bin="$BATS_TEST_TMPDIR/tr-out-bin" log="$BATS_TEST_TMPDIR/tr-out.log" out
  _track_fixture "$repo"
  _fake_gt "$bin" "$log" "echo chatter; case \"\$args\" in *' parent --no-interactive '*) exit 1 ;; esac"
  out="$(PATH="$bin:$PATH" handoff_track_graphite "$repo.feat" 2>/dev/null)"
  [[ -z "$out" ]] || fail "spawn's stdout is the JSON result, got: $out"
}

@test "SIGTERM to the spawn process group also kills gt" {
  need setsid
  local repo="$BATS_TEST_TMPDIR/tr-term" bin="$BATS_TEST_TMPDIR/tr-term-bin" log="$BATS_TEST_TMPDIR/tr-term.log"
  local run="$BATS_TEST_TMPDIR/tr-term.sh" ready="$BATS_TEST_TMPDIR/tr-term.ready" pidfile="$BATS_TEST_TMPDIR/tr-term.pid"
  local runner group pid
  _track_fixture "$repo"
  _fake_gt "$bin" "$log" "echo \$\$ >'$pidfile'; exec sleep 300"
  cat >"$run" <<EOF
source "$ROOT/skills/handoff/scripts/handoff-spawn"
echo \$\$ >"$ready"
PATH="$bin:\$PATH" HANDOFF_GT_TIMEOUT=1 handoff_track_graphite "$repo.feat"
EOF
  # The caller and watchdog share this new group; gt has its own.
  setsid bash "$run" >"$BATS_TEST_TMPDIR/tr-term.out" 2>&1 &
  runner=$!
  printf '%s\n' "$runner" >>"$BATS_TEST_TMPDIR/reap"
  # The ready file and gt's pid are the signal. A short poll flakes when the machine is busy.
  if ! wait_for '[[ -s "$ready" && -s "$pidfile" ]]'; then
    kill -TERM "$runner" 2>/dev/null || true
    wait "$runner" 2>/dev/null || true
    fail "the SIGTERM fixture did not start: $(cat "$BATS_TEST_TMPDIR/tr-term.out")"
  fi
  group="$(<"$ready")"
  pid="$(<"$pidfile")"
  printf '%s\n' "$pid" >>"$BATS_TEST_TMPDIR/reap"
  kill -TERM -- "-$group"
  wait "$runner" 2>/dev/null || true
  if ! wait_for '_gone "$pid"'; then
    kill -KILL -- "-$pid" 2>/dev/null || true
    fail "SIGTERM killed the watchdog but left gt running"
  fi
}

@test "trunk is read from trunks[] when trunk is absent" {
  local repo="$BATS_TEST_TMPDIR/tr-list" bin="$BATS_TEST_TMPDIR/tr-list-bin" log="$BATS_TEST_TMPDIR/tr-list.log"
  _track_fixture "$repo"
  printf '{"trunks":[{"name":"develop"}]}\n' >"$(git_dir "$repo")/.graphite_repo_config"
  _fake_gt "$bin" "$log" "case \"\$args\" in *' parent --no-interactive '*) exit 1 ;; esac"
  PATH="$bin:$PATH" handoff_track_graphite "$repo.feat"
  grep -qxF -- "--cwd $repo.feat track --parent develop --no-interactive" "$log" \
    || fail "a config with only trunks[] names trunk; log=$(cat "$log")"
}

@test "Graphite forced on with no gt config warns instead of letting gt auto-init" {
  local repo="$BATS_TEST_TMPDIR/tr-nocfg" bin="$BATS_TEST_TMPDIR/tr-nocfg-bin" log="$BATS_TEST_TMPDIR/tr-nocfg.log" err
  git_init "$repo"
  _fake_gt "$bin" "$log" 'exit 0'
  err="$(PATH="$bin:$PATH" handoff_track_graphite "$repo" 2>&1)" || fail "must not fail: $err"
  [[ ! -s "$log" ]] || fail "gt auto-inits on any command; never run it here: $(cat "$log")"
  grep -q 'gt init' <<<"$err" || fail "should say to run gt init: $err"
}

# A whole --branch spawn with stubs for everything but git and the gt under test.

_spawn_branch() {
  local name="$1" repo="$2" bin="$3" home="$4" base="${5:-}"
  mkdir -p "$home/.config/worktrunk"
  cat >"$bin/wt" <<'WT'
#!/usr/bin/env bash
branch="" base=HEAD
while [[ $# -gt 0 ]]; do
  case "$1" in
    --create) branch="$2"; shift 2 ;;
    --base) base="$2"; shift 2 ;;
    *) shift ;;
  esac
done
main="$(git worktree list --porcelain | awk '/^worktree / { print substr($0, 10); exit }')"
git -C "$main" worktree add -q -b "$branch" "$main.$branch" "$base"
WT
  cat >"$bin/herdr-app" <<'HERDR'
#!/bin/sh
printf '%s\n' '{"space":"sp1"}'
HERDR
  chmod +x "$bin/wt" "$bin/herdr-app"
  _pi_ready
  cat >"$home/.config/worktrunk/herdr-layout.sh" <<HELPER
_wt_herdr_keep_user_focus() { :; }
_wt_generate_session_name() { printf 'Lbl'; }
wt_herdr_handoff_agent() { : >"$BATS_TEST_TMPDIR/$name-desk-started"; }
_wt_herdr_space_by_folder() { printf 'sp1'; }
_wt_herdr_space_desk() { printf 'desk1'; }
HELPER
  _bd_stub
  : >"$BD_COMMENTS"
  (
    cd "$repo"
    HOME="$home" PATH="$bin:$PATH" HERDR_APP_BIN="$bin/herdr-app" HANDOFF_GT_TIMEOUT=1 \
      XDG_STATE_HOME="$BATS_TEST_TMPDIR/$name-state" BERCAIL_BIN="$BATS_TEST_TMPDIR/no-bercail" \
      HANDOFF_PI_PROFILE="$HANDOFF_PI_PROFILE" \
      "$ROOT/skills/handoff/scripts/handoff-spawn" \
      --branch feat --stage bstack --issue "$ISSUE" --clean ${base:+--base "$base"}
  )
}

@test "a plain repo with a stray config spawns with no gt and no gt intro" {
  local repo="$BATS_TEST_TMPDIR/sp-stray" bin="$BATS_TEST_TMPDIR/sp-stray-bin" log="$BATS_TEST_TMPDIR/sp-stray.log" out
  git_init "$repo"
  graphite_auto_init "$repo"
  _fake_gt "$bin" "$log" 'exit 1'
  out="$(_spawn_branch sp-stray "$repo" "$bin" "$BATS_TEST_TMPDIR/sp-stray-home")" || fail "spawn failed: $out"
  printf '%s' "$out" | jq -e '.git == "gh" and .agent_started == true' >/dev/null || fail "spawn json: $out"
  [[ ! -s "$log" ]] || fail "gt must not run in a plain repo: $(cat "$log")"
  grep -q 'Use gt' "$BD_COMMENTS" && fail "no gt intro in a plain repo: $(cat "$BD_COMMENTS")"
  grep -q 'bercail handoff: stage bstack' "$BD_COMMENTS" || fail "intro missing: $(cat "$BD_COMMENTS")"
  grep -q "git policy says (bercail policy show)" "$BD_COMMENTS" || fail "intro does not name the policy: $(cat "$BD_COMMENTS")"
  grep -q 'when the desk agent finishes, Review opens itself in this space' "$BD_COMMENTS" \
    || fail "handoff intro should say Review opens itself"
  grep -q 'post your final report on this issue with bd comment' "$BD_COMMENTS" \
    || fail "a desk reports on the issue, where headless runs and Shep read it"
  grep -q 'leave them uncommitted for human review' "$BD_COMMENTS" \
    || fail "handoff intro should tell the child to keep changes staged, not committed"
  if grep -q 'agentic-dev.layout' "$BD_COMMENTS"; then fail "handoff intro must not name the old Herdr plugin"; fi
  if grep -q 'review/SKILL.md' "$BD_COMMENTS"; then fail "handoff intro must not tell the child to load the review skill"; fi
}

@test "a hung gt warns and the desk still starts" {
  local repo="$BATS_TEST_TMPDIR/sp-hang" bin="$BATS_TEST_TMPDIR/sp-hang-bin" log="$BATS_TEST_TMPDIR/sp-hang.log" out
  git_init "$repo"
  graphite_auto_init "$repo"
  git -C "$repo" update-ref refs/branch-metadata/other HEAD
  _fake_gt "$bin" "$log" 'sleep 300 & wait'
  out="$(_spawn_branch sp-hang "$repo" "$bin" "$BATS_TEST_TMPDIR/sp-hang-home" 2>"$BATS_TEST_TMPDIR/sp-hang.err")" \
    || fail "a hung gt must not abort the spawn: $out $(cat "$BATS_TEST_TMPDIR/sp-hang.err")"
  printf '%s' "$out" | jq -e '.git == "gt" and .agent_started == true' >/dev/null || fail "spawn json: $out"
  [[ -f "$BATS_TEST_TMPDIR/sp-hang-desk-started" ]] || fail "the desk must still start"
  grep -q 'did not finish' "$BATS_TEST_TMPDIR/sp-hang.err" || fail "warn: $(cat "$BATS_TEST_TMPDIR/sp-hang.err")"
  grep -q 'Use gt' "$BD_COMMENTS" || fail "a real Graphite repo keeps the gt intro: $(cat "$BD_COMMENTS")"
}

@test "missing sqlite3 cannot turn a plain repo into Graphite or block the desk" {
  local repo="$BATS_TEST_TMPDIR/sp-nosql" bin="$BATS_TEST_TMPDIR/sp-nosql-bin" log="$BATS_TEST_TMPDIR/sp-nosql.log" out
  git_init "$repo"
  graphite_auto_init "$repo"
  : >"$(git_dir "$repo")/.graphite_metadata.db"
  _fake_gt "$bin" "$log" 'exit 1'
  out="$(HANDOFF_SQLITE3_BIN="$BATS_TEST_TMPDIR/no-sqlite3" \
    _spawn_branch sp-nosql "$repo" "$bin" "$BATS_TEST_TMPDIR/sp-nosql-home" 2>"$BATS_TEST_TMPDIR/sp-nosql.err")" \
    || fail "spawn failed: $out"
  printf '%s' "$out" | jq -e '.git == "gh" and .agent_started == true' >/dev/null || fail "spawn json: $out"
  [[ ! -s "$log" ]] || fail "gt must not run when detection is inconclusive: $(cat "$log")"
  grep -q 'Use gt' "$BD_COMMENTS" && fail "no gt intro without evidence of Graphite"
  grep -q 'cannot read' "$BATS_TEST_TMPDIR/sp-nosql.err" || fail "warn about sqlite3: $(cat "$BATS_TEST_TMPDIR/sp-nosql.err")"
}

@test "a failed gt warns and the desk still starts" {
  local repo="$BATS_TEST_TMPDIR/sp-fail" bin="$BATS_TEST_TMPDIR/sp-fail-bin" log="$BATS_TEST_TMPDIR/sp-fail.log" out
  git_init "$repo"
  graphite_auto_init "$repo"
  git -C "$repo" update-ref refs/branch-metadata/other HEAD
  _fake_gt "$bin" "$log" 'exit 1'
  out="$(_spawn_branch sp-fail "$repo" "$bin" "$BATS_TEST_TMPDIR/sp-fail-home" 2>"$BATS_TEST_TMPDIR/sp-fail.err")" \
    || fail "a failed gt must not abort the spawn: $out"
  printf '%s' "$out" | jq -e '.git == "gt" and .agent_started == true' >/dev/null || fail "spawn json: $out"
  [[ -f "$BATS_TEST_TMPDIR/sp-fail-desk-started" ]] || fail "the desk must still start"
  grep -q 'gt failed' "$BATS_TEST_TMPDIR/sp-fail.err" || fail "warn: $(cat "$BATS_TEST_TMPDIR/sp-fail.err")"
}

@test "a real Graphite repo spawns with gt track and the gt intro, as before" {
  local repo="$BATS_TEST_TMPDIR/sp-real" bin="$BATS_TEST_TMPDIR/sp-real-bin" log="$BATS_TEST_TMPDIR/sp-real.log" out
  git_init "$repo"
  graphite_auto_init "$repo"
  git -C "$repo" update-ref refs/branch-metadata/other HEAD
  _fake_gt "$bin" "$log" "case \"\$args\" in *' parent --no-interactive '*) exit 1 ;; esac"
  out="$(_spawn_branch sp-real "$repo" "$bin" "$BATS_TEST_TMPDIR/sp-real-home" 2>/dev/null)" || fail "spawn failed: $out"
  printf '%s' "$out" | jq -e '.git == "gt" and .agent_started == true' >/dev/null || fail "spawn json: $out"
  grep -qxF -- "--cwd $repo.feat track --parent master --no-interactive" "$log" \
    || fail "a real stack still gets gt track on trunk; log=$(cat "$log")"
  grep -c ' track ' "$log" | grep -qx 1 || fail "one track call is enough: $(cat "$log")"
  grep -q 'Use gt' "$BD_COMMENTS" || fail "a real Graphite repo keeps the gt intro: $(cat "$BD_COMMENTS")"
}

@test "a real stack spawned with --base is tracked on that base, as before" {
  local repo="$BATS_TEST_TMPDIR/sp-stack" bin="$BATS_TEST_TMPDIR/sp-stack-bin" log="$BATS_TEST_TMPDIR/sp-stack.log" out
  git_init "$repo"
  graphite_auto_init "$repo"
  git -C "$repo" branch stack-one
  git -C "$repo" update-ref refs/branch-metadata/stack-one HEAD
  _fake_gt "$bin" "$log" "case \"\$args\" in *' parent --no-interactive '*) exit 1 ;; esac"
  out="$(_spawn_branch sp-stack "$repo" "$bin" "$BATS_TEST_TMPDIR/sp-stack-home" stack-one 2>/dev/null)" || fail "spawn failed: $out"
  printf '%s' "$out" | jq -e '.git == "gt" and .agent_started == true and .base == "stack-one"' >/dev/null || fail "spawn json: $out"
  [[ "$(grep ' track ' "$log")" == "--cwd $repo.feat track --parent stack-one --no-interactive" ]] \
    || fail "a stack gets exactly one gt track, on its base; log=$(cat "$log")"
  grep -q 'Use gt' "$BD_COMMENTS" || fail "a real Graphite repo keeps the gt intro: $(cat "$BD_COMMENTS")"
}

_fake_logger() {
  local bin="$1" name="$2" log="$3"
  mkdir -p "$bin"
  : >"$log"
  cat >"$bin/$name" <<EOF
#!/bin/sh
printf '%s\n' "\$(pwd) \$*" >>"$log"
exit 0
EOF
  chmod +x "$bin/$name"
}

@test "gh --base inits a stack, and a middle parent is not attached" {
  local repo="$BATS_TEST_TMPDIR/gh-init" bin="$BATS_TEST_TMPDIR/gh-init-bin" log="$BATS_TEST_TMPDIR/gh-init.log" trunk
  git_init "$repo"
  trunk="$(git -C "$repo" branch --show-current)"
  git -C "$repo" branch parent-branch
  git -C "$repo" worktree add -q -b feat "$repo.feat" parent-branch
  _fake_logger "$bin" gh "$log"
  _fake_logger "$bin" gt "$BATS_TEST_TMPDIR/gh-init-gt.log"
  PATH="$bin:$PATH" handoff_track_gh "$repo.feat" feat parent-branch
  grep -q "stack init --base $trunk parent-branch feat" "$log" \
    || fail "a new dependent is gh stack init; log=$(cat "$log")"
  [[ "$(awk '{ print $1 }' "$log")" == "$repo.feat" ]] || fail "init runs in the child worktree: $(cat "$log")"
  [[ ! -s "$BATS_TEST_TMPDIR/gh-init-gt.log" ]] || fail "gt must not run for gh: $(cat "$BATS_TEST_TMPDIR/gh-init-gt.log")"
  local catalog
  catalog="$(git_dir "$repo")/gh-stack"
  jq -n --arg p parent-branch '{stacks:[{trunk:{branch:"main"},branches:[{branch:"bottom"},{branch:$p},{branch:"tip"}]}]}' >"$catalog"
  : >"$log"
  local err
  err="$(PATH="$bin:$PATH" handoff_track_gh "$repo.feat" feat parent-branch 2>&1)" || fail "a middle parent must not fail the spawn: $err"
  [[ ! -s "$log" ]] || fail "a middle parent must not call gh stack: $(cat "$log")"
  grep -q 'not the top' <<<"$err" || fail "say why it was not attached: $err"
}

@test "gh stack add uses the parent worktree and does not switch main" {
  local repo="$BATS_TEST_TMPDIR/gh-add" bin="$BATS_TEST_TMPDIR/gh-add-bin" log="$BATS_TEST_TMPDIR/gh-add.log"
  git_init "$repo"
  git -C "$repo" branch parent-branch
  git -C "$repo" worktree add -q "$repo.parent" parent-branch
  git -C "$repo" worktree add -q -b feat "$repo.feat" parent-branch
  jq -n '{stacks:[{trunk:{branch:"main"},branches:[{branch:"parent-branch"}]}]}' >"$(git_dir "$repo")/gh-stack"
  _fake_logger "$bin" gh "$log"
  PATH="$bin:$PATH" handoff_track_gh "$repo.feat" feat parent-branch
  [[ "$(cat "$log")" == "$repo.parent stack add feat" ]] \
    || fail "add runs in the worktree that has the top checked out; log=$(cat "$log")"
}

@test "origin --base is origin stack track, local, not gt" {
  local repo="$BATS_TEST_TMPDIR/ori-track" bin="$BATS_TEST_TMPDIR/ori-track-bin" log="$BATS_TEST_TMPDIR/ori-track.log"
  git_init "$repo"
  git -C "$repo" branch parent-branch
  git -C "$repo" worktree add -q -b feat "$repo.feat" parent-branch
  _fake_logger "$bin" origin "$log"
  _fake_logger "$bin" gt "$BATS_TEST_TMPDIR/ori-track-gt.log"
  PATH="$bin:$PATH" handoff_track_origin "$repo.feat" feat parent-branch
  [[ "$(cat "$log")" == "$repo.feat stack track feat --onto parent-branch --json" ]] \
    || fail "origin stack track --onto; log=$(cat "$log")"
  [[ ! -s "$BATS_TEST_TMPDIR/ori-track-gt.log" ]] || fail "gt must not run for origin"
}

@test "a gh --base spawn uses gh stack, not gt" {
  local repo="$BATS_TEST_TMPDIR/sp-gh" bin="$BATS_TEST_TMPDIR/sp-gh-bin" log="$BATS_TEST_TMPDIR/sp-gh.log" gtlog="$BATS_TEST_TMPDIR/sp-gh-gt.log" out
  git_init "$repo"
  git -C "$repo" branch parent-branch
  _fake_logger "$bin" gh "$log"
  _fake_logger "$bin" gt "$gtlog"
  out="$(_spawn_branch sp-gh "$repo" "$bin" "$BATS_TEST_TMPDIR/sp-gh-home" parent-branch 2>"$BATS_TEST_TMPDIR/sp-gh.err")" \
    || fail "spawn failed: $out $(cat "$BATS_TEST_TMPDIR/sp-gh.err")"
  printf '%s' "$out" | jq -e '.git == "gh" and .agent_started == true and .base == "parent-branch"' >/dev/null \
    || fail "spawn json: $out"
  grep -q 'stack init' "$log" || fail "spawn --base on gh records a stack; log=$(cat "$log")"
  [[ ! -s "$gtlog" ]] || fail "gt must not run: $(cat "$gtlog")"
  grep -q 'Use gt' "$BD_COMMENTS" && fail "no gt intro on gh: $(cat "$BD_COMMENTS")"
  grep -q 'gh stack' "$BD_COMMENTS" || fail "the desk is told to use gh stack: $(cat "$BD_COMMENTS")"
}

@test "a title is truncated, one line, and a missing bd or issue is a bare id" {
  local wt="$BATS_TEST_TMPDIR/title-norm" got err long want messy
  mkdir -p "$wt"
  _bd_stub
  long="$(printf '%70s' '' | tr ' ' 'x')"
  want="${long:0:59}"$'…'
  got="$(BD_TITLE="$long" handoff_issue_title "$wt" "$ISSUE")" || fail "title lookup failed"
  [[ "$got" == "$want" ]] || fail "70-char title should be 60 with an ellipsis: ${#got} [$got]"
  [[ "$(handoff_issue_prompt "$ISSUE" "$got")" == "Your job is beads issue $ISSUE: $want Run \`bd show $ISSUE\` (read its comments too) and do the work it describes." ]] \
    || fail "truncated title in the prompt: $(handoff_issue_prompt "$ISSUE" "$got")"

  messy="$(printf 'say "hi" \\ path\n\tand')"
  got="$(BD_TITLE="$messy" handoff_issue_title "$wt" "$ISSUE")" || fail "messy title lookup failed"
  [[ "$got" == 'say "hi" \ path and' ]] || fail "normalised title: [$got]"
  if grep -q '[[:cntrl:]]' <<<"$got"; then fail "title must be one line: [$got]"; fi

  err="$(HANDOFF_BD_BIN="$BATS_TEST_TMPDIR/no-such-bd" handoff_issue_title "$wt" "$ISSUE" 2>&1)" || fail "missing bd must not fail the lookup"
  [[ -z "$err" ]] || fail "missing bd should print nothing: $err"
  err="$(BD_KNOWN=other handoff_issue_title "$wt" "$ISSUE" 2>&1)" || fail "unknown issue must not fail the lookup"
  [[ -z "$err" ]] || fail "unknown issue should print nothing: $err"
}

@test "headless JSON and the result file carry the title, or the bare id" {
  local wt="$BATS_TEST_TMPDIR/title-head" out stub="$BATS_TEST_TMPDIR/bin/title-pi" rc=0
  local title='Show the title' messy long want
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  _start_fixture "$wt"
  messy="$(printf 'say "hi" \\ path\n\tand')"
  out="$(cd "$wt" && BD_TITLE="$messy" \
    "$ROOT/skills/handoff/scripts/handoff-spawn" --stage bstack --issue "$ISSUE" --worktree "$wt" --dry-run 2>"$BATS_TEST_TMPDIR/title-dry.err")" \
    || fail "dry-run with a title failed: $out $(cat "$BATS_TEST_TMPDIR/title-dry.err")"
  [[ ! -s "$BATS_TEST_TMPDIR/title-dry.err" ]] || fail "title lookup must not write stderr: $(cat "$BATS_TEST_TMPDIR/title-dry.err")"
  printf '%s' "$out" | jq -e --arg id "$ISSUE" --arg t 'say "hi" \ path and' '
    .issue_title == $t
    and (.command[-1] | test("\n|\t") | not)
    and .command[-1] == ("Your job is beads issue " + $id + ": " + $t + ". Run `bd show " + $id + "` (read its comments too) and do the work it describes.")
  ' >/dev/null || fail "dry-run prompt/json: $out"
  [[ ! -f "$wt/.bercail/handoff-result.json" ]] || fail "dry-run must not write a result"

  long="$(printf '%70s' '' | tr ' ' 'x')"
  want="${long:0:59}"$'\u2026'
  out="$(cd "$wt" && BD_TITLE="$long" \
    "$ROOT/skills/handoff/scripts/handoff-spawn" --stage bstack --issue "$ISSUE" --worktree "$wt" --dry-run)"
  printf '%s' "$out" | jq -e --arg t "$want" '.issue_title == $t and (.command[-1] | contains($t))' >/dev/null \
    || fail "dry-run should carry the truncated title: $out"

  out="$(cd "$wt" && BD_KNOWN=other \
    "$ROOT/skills/handoff/scripts/handoff-spawn" --stage bstack --issue "$ISSUE" --worktree "$wt" --dry-run 2>"$BATS_TEST_TMPDIR/title-unk.err")" \
    || fail "unknown issue dry-run must not fail: $(cat "$BATS_TEST_TMPDIR/title-unk.err")"
  printf '%s' "$out" | jq -e --arg id "$ISSUE" '(has("issue_title") | not) and (.command[-1] | startswith("Your job is beads issue " + $id + "."))' >/dev/null \
    || fail "unknown issue stays a bare id: $out"
  [[ ! -s "$BATS_TEST_TMPDIR/title-unk.err" ]] || fail "unknown issue dry-run stderr: $(cat "$BATS_TEST_TMPDIR/title-unk.err")"

  cat >"$stub" <<'STUB'
#!/bin/sh
jq -nc '{status:"ready", summary:"done the work"}' >"$BERCAIL_RESULT_PATH"
STUB
  chmod +x "$stub"
  out="$(cd "$wt" && BD_TITLE="$title" HANDOFF_PI_BIN="$stub" \
    "$ROOT/skills/handoff/scripts/handoff-spawn" --stage bstack --issue "$ISSUE" --worktree "$wt")" \
    || fail "titled run failed: $out"
  printf '%s' "$out" | jq -e --arg t "$title" --arg id "$ISSUE" '.issue == $id and .issue_title == $t' >/dev/null \
    || fail "out json: $out"
  jq -e --arg t "$title" --arg id "$ISSUE" \
    '.status == "ready" and .issue == $id and .issue_title == $t' \
    "$wt/.bercail/handoff-result.json" >/dev/null \
    || fail "result file: $(cat "$wt/.bercail/handoff-result.json")"
  handoff_result_ok "$wt/.bercail/handoff-result.json" || fail "stamped result must still pass handoff_result_ok"

  rm -f "$wt/.bercail/handoff-result.json"
  rc=0
  out="$(cd "$wt" && BD_TITLE="$title" HANDOFF_PI_BIN="$BATS_TEST_TMPDIR/no-such-pi" \
    "$ROOT/skills/handoff/scripts/handoff-spawn" --stage bstack --issue "$ISSUE" --worktree "$wt" 2>/dev/null)" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "missing harness should still block"
  jq -e --arg t "$title" --arg id "$ISSUE" \
    '.status == "blocked" and .issue == $id and .issue_title == $t' \
    "$wt/.bercail/handoff-result.json" >/dev/null \
    || fail "blocked result should carry the title: $(cat "$wt/.bercail/handoff-result.json")"

  rc=0
  out="$(cd "$wt" && HANDOFF_PI_BIN="$stub" \
    "$ROOT/skills/handoff/scripts/handoff-spawn" --stage bstack --issue bercail-nope --worktree "$wt" 2>/dev/null)" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "unknown issue should block"
  jq -e '.status == "blocked" and .issue == "bercail-nope" and (has("issue_title") | not)' \
    "$wt/.bercail/handoff-result.json" >/dev/null \
    || fail "unknown issue is a bare id: $(cat "$wt/.bercail/handoff-result.json")"

  rc=0
  out="$(cd "$wt" && HANDOFF_BD_BIN="$BATS_TEST_TMPDIR/no-such-bd" HANDOFF_PI_BIN="$stub" \
    "$ROOT/skills/handoff/scripts/handoff-spawn" --stage bstack --issue "$ISSUE" --worktree "$wt" 2>"$BATS_TEST_TMPDIR/title-bd.err")" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "missing bd should block"
  jq -e --arg id "$ISSUE" '.status == "blocked" and .issue == $id and (has("issue_title") | not)' \
    "$wt/.bercail/handoff-result.json" >/dev/null \
    || fail "missing bd is a bare id: $(cat "$wt/.bercail/handoff-result.json")"
  grep -q 'jq:' "$BATS_TEST_TMPDIR/title-bd.err" && fail "missing bd must not surface a title error: $(cat "$BATS_TEST_TMPDIR/title-bd.err")"

  out="$(cd "$wt" && HANDOFF_BD_BIN="$BATS_TEST_TMPDIR/no-such-bd" \
    "$ROOT/skills/handoff/scripts/handoff-spawn" --stage bstack --issue "$ISSUE" --worktree "$wt" --dry-run 2>"$BATS_TEST_TMPDIR/title-bd-dry.err")" \
    || fail "dry-run with missing bd failed: $(cat "$BATS_TEST_TMPDIR/title-bd-dry.err")"
  printf '%s' "$out" | jq -e --arg id "$ISSUE" '(has("issue_title") | not) and (.command[-1] | startswith("Your job is beads issue " + $id + "."))' >/dev/null \
    || fail "missing bd dry-run should keep the bare prompt: $out"
  [[ ! -s "$BATS_TEST_TMPDIR/title-bd-dry.err" ]] || fail "missing bd dry-run stderr: $(cat "$BATS_TEST_TMPDIR/title-bd-dry.err")"
  unset HANDOFF_PI_BIN
}

# A --branch spawn through the real herdr-layout.sh, with fake wt, Herdr app and
# hc. hc run's argv lands in $DESK_ARGV, its calls in $DESK_HC_LOG.
_desk_fixture() {
  local name="$1"
  DESK_REPO="$BATS_TEST_TMPDIR/$name"
  DESK_BIN="$BATS_TEST_TMPDIR/$name-bin"
  DESK_HOME="$BATS_TEST_TMPDIR/$name-home"
  DESK_STATE="$BATS_TEST_TMPDIR/$name-state"
  git_init "$DESK_REPO"
  mkdir -p "$DESK_BIN" "$DESK_HOME/.config/worktrunk"
  cp "$ROOT/config/worktrunk/herdr-layout.sh" "$DESK_HOME/.config/worktrunk/herdr-layout.sh"
  cat >"$DESK_BIN/wt" <<'WT'
#!/usr/bin/env bash
branch=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --create) branch="$2"; shift 2 ;;
    *) shift ;;
  esac
done
main="$(git worktree list --porcelain | awk '/^worktree / { print substr($0, 10); exit }')"
git -C "$main" worktree add -q -b "$branch" "$main.$branch" HEAD
printf '%s' "$(cd "$main.$branch" && pwd -P)" >"$DESK_FOLDER"
WT
  cat >"$DESK_BIN/herdr-app" <<'HERDR'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "status ") printf '{"space":"sp-keep"}\n' ;;
  "ls ")
    f=""
    [[ -f "$DESK_FOLDER" ]] && f="$(cat "$DESK_FOLDER")"
    if [[ -n "$f" ]]; then
      jq -nc --arg f "$f" '{spaces:[{id:"sp1",name:"Lbl",folder:$f,tabs:[{terminals:[{terminal:"t9"}]}]}]}'
    else
      printf '{"spaces":[]}\n'
    fi
    ;;
  "do space.new")
    printf '%s' "$6" >"$DESK_FOLDER"
    printf '{"space":"sp1"}\n'
    ;;
  *) printf '{"ok":true}\n' ;;
esac
HERDR
  cat >"$DESK_BIN/hc" <<'HC'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$DESK_HC_LOG"
if [[ "$1" == run ]]; then
  printf '%s\0' "$@" | jq -Rs 'split("\u0000") | .[:-1]' >"$DESK_ARGV"
fi
case "$1" in
  ls) printf '{"terminals":[]}\n' ;;
  *) printf '{}\n' ;;
esac
HC
  chmod +x "$DESK_BIN/wt" "$DESK_BIN/herdr-app" "$DESK_BIN/hc"
  _bd_stub
  _pi_ready
  export DESK_FOLDER="$BATS_TEST_TMPDIR/$name-folder" DESK_HC_LOG="$BATS_TEST_TMPDIR/$name-hc.log"
  export DESK_ARGV="$BATS_TEST_TMPDIR/$name-hc.argv"
  : >"$DESK_HC_LOG"
}

# handoff-spawn --branch feat --stage bstack --issue $ISSUE --clean, plus $@.
_desk_spawn() {
  (cd "$DESK_REPO" && HOME="$DESK_HOME" PATH="$DESK_BIN:$PATH" \
    HERDR_APP_BIN="$DESK_BIN/herdr-app" HC_BIN="$DESK_BIN/hc" \
    XDG_STATE_HOME="$DESK_STATE" BERCAIL_BIN="$BATS_TEST_TMPDIR/no-bercail" \
    HANDOFF_PI_PROFILE="$HANDOFF_PI_PROFILE" \
    "$ROOT/skills/handoff/scripts/handoff-spawn" --branch feat --stage bstack --issue "$ISSUE" --clean "$@")
}

@test "a --branch spawn puts the title in JSON, handoffs.jsonl, and the desk labels" {
  local out title='Say "hi"'
  _desk_fixture title-branch
  out="$(BD_TITLE="$title" _desk_spawn 2>"$BATS_TEST_TMPDIR/title-branch.err")" \
    || fail "branch spawn failed: $out $(cat "$BATS_TEST_TMPDIR/title-branch.err")"
  printf '%s' "$out" | jq -e --arg t "$title" --arg id "$ISSUE" \
    '.issue == $id and .issue_title == $t and .agent_started == true' >/dev/null \
    || fail "branch json: $out $(cat "$BATS_TEST_TMPDIR/title-branch.err")"
  jq -e --arg t "$title" --arg id "$ISSUE" '.issue == $id and .issue_title == $t' \
    "$DESK_STATE/bercail/handoffs.jsonl" >/dev/null \
    || fail "handoffs.jsonl: $(cat "$DESK_STATE/bercail/handoffs.jsonl")"
  jq -e --arg issue "bercail.issue=$ISSUE" --arg titled "bercail.issue_title=$title" \
    'index($issue) and index($titled)' "$DESK_ARGV" >/dev/null \
    || fail "hc run labels: $(cat "$DESK_ARGV" 2>/dev/null) log=$(cat "$DESK_HC_LOG")"
}

# A Pi whose --list-models knows claude-bridge/fable and logs its argv.
_pi_lists_models() {
  local stub="$BATS_TEST_TMPDIR/bin/pi-lists"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat >"$stub" <<'STUB'
#!/usr/bin/env bash
printf '%s\0' "$@" | jq -Rsc 'split("\u0000") | .[:-1]' >>"$PI_LIST_LOG"
[[ " $* " == *" --list-models "* ]] || exit 3
printf 'provider       model         context  max-out  thinking  images\n'
printf 'claude-bridge  fable         1M       128K     yes       yes\n'
printf 'claude-bridge  lead-model    1M       128K     yes       yes\n'
STUB
  chmod +x "$stub"
  export HANDOFF_PI_BIN="$stub" PI_LIST_LOG="$BATS_TEST_TMPDIR/pi-list.log"
  : >"$PI_LIST_LOG"
}

@test "a --branch --model desk runs the lead on that model, labelled and logged" {
  local out lead
  _desk_fixture model-branch
  _pi_lists_models
  out="$(_desk_spawn --model claude-bridge/fable 2>"$BATS_TEST_TMPDIR/model-branch.err")" \
    || fail "spawn failed: $out $(cat "$BATS_TEST_TMPDIR/model-branch.err")"
  lead="$HANDOFF_PI_PROFILE/lead.json"
  jq -e --arg e "$(jq -r '.[6]' "$lead")" '.[0:2] == ["--offline", "--list-models"]
    and index(["-e", "npm:pi-claude-bridge@0.11.0"]) and index(["-e", $e]) and (index("--model") | not)' \
    "$PI_LIST_LOG" >/dev/null || fail "Pi lists models with the lead's extensions: $(cat "$PI_LIST_LOG")"
  printf '%s' "$out" | jq -e '.model == "claude-bridge/fable:high" and .agent_started == true' >/dev/null \
    || fail "no thinking level takes the lead's: $out"
  jq -e '.model == "claude-bridge/fable:high"' "$DESK_STATE/bercail/handoffs.jsonl" >/dev/null \
    || fail "handoffs.jsonl: $(cat "$DESK_STATE/bercail/handoffs.jsonl")"
  jq -e --arg desk "$DESK_HOME/.local/bin/bercail-desk-agent" '
    index("bercail.model=claude-bridge/fable:high")
    and .[index($desk) + 1:] == ["--prompt", .[index($desk) + 2], "--model", "claude-bridge/fable:high"]' \
    "$DESK_ARGV" >/dev/null || fail "the desk gets --model and its label: $(cat "$DESK_ARGV")"
  rm -rf "$DESK_REPO.feat"
  git -C "$DESK_REPO" worktree prune
  git -C "$DESK_REPO" branch -qD feat
  out="$(_desk_spawn --model claude-bridge/fable:low 2>&1)" || fail "spawn failed: $out"
  printf '%s' "$out" | tail -n 1 | jq -e '.model == "claude-bridge/fable:low"' >/dev/null \
    || fail "a given thinking level is kept: $out"
}

@test "a --branch spawn without --model runs the lead's and checks nothing" {
  local out
  _desk_fixture lead-branch
  _pi_lists_models
  out="$(_desk_spawn 2>&1)" || fail "spawn failed: $out"
  printf '%s' "$out" | jq -e 'has("model") | not' >/dev/null || fail "no model in the JSON: $out"
  [[ ! -s "$PI_LIST_LOG" ]] || fail "no model, no list: $(cat "$PI_LIST_LOG")"
  jq -e 'any(.[]; test("model")) | not' "$DESK_ARGV" >/dev/null || fail "no --model or label: $(cat "$DESK_ARGV")"
}

@test "an unknown or malformed --model is refused before a worktree" {
  local out rc=0
  _desk_fixture bad-model
  _pi_lists_models
  out="$(_desk_spawn --model claude-bridge/nope:high 2>&1)" || rc=$?
  [[ "$rc" -eq 1 ]] || fail "an unknown model should exit 1, got $rc ($out)"
  [[ "$out" == *"Pi has no model claude-bridge/nope."* ]] || fail "unknown model message: $out"
  [[ ! -e "$DESK_REPO.feat" && ! -s "$DESK_HC_LOG" ]] || fail "nothing starts on an unknown model"
  rc=0
  out="$(_desk_spawn --model fable 2>&1)" || rc=$?
  [[ "$rc" -eq 1 && "$out" == *"--model takes PROVIDER/MODEL[:thinking]"* ]] || fail "a bare id is refused: $rc $out"
  printf '#!/bin/sh\nexit 1\n' >"$HANDOFF_PI_BIN"
  rc=0
  out="$(_desk_spawn --model claude-bridge/fable 2>&1)" || rc=$?
  [[ "$rc" -eq 1 && "$out" == *"pi --list-models failed"* ]] || fail "a failing Pi is refused: $rc $out"
  [[ ! -e "$DESK_REPO.feat" ]] || fail "no worktree when the model cannot be checked"
}

@test "headless --model swaps only the model; an unknown one starts nothing" {
  local wt="$BATS_TEST_TMPDIR/model-headless" out base rc=0
  _start_fixture "$wt"
  base="$(cd "$wt" && "$ROOT/skills/handoff/scripts/handoff-spawn" --stage autopilot --issue "$ISSUE" --worktree "$wt" --dry-run)"
  out="$(cd "$wt" && "$ROOT/skills/handoff/scripts/handoff-spawn" --stage autopilot --issue "$ISSUE" --worktree "$wt" \
    --dry-run --model claude-bridge/fable)"
  jq -en --argjson a "$base" --argjson b "$out" '
    $b.model == "claude-bridge/fable:high"
    and ($b.command | index("--model")) == ($a.command | index("--model"))
    and $b.command[($b.command | index("--model")) + 1] == "claude-bridge/fable:high"
    and ($a.command | map(select(. != $a.session_id and . != $a.model)))
      == ($b.command | map(select(. != $b.session_id and . != $b.model)))' >/dev/null \
    || fail "only the model changes: $base vs $out"
  _pi_lists_models
  out="$(cd "$wt" && "$ROOT/skills/handoff/scripts/handoff-spawn" --stage bstack --issue "$ISSUE" --worktree "$wt" \
    --model claude-bridge/nope 2>&1)" || rc=$?
  [[ "$rc" -eq 1 && "$out" == *"Pi has no model claude-bridge/nope."* ]] || fail "unknown model: $rc $out"
  jq -e 'all(.[]; index("--list-models"))' -s "$PI_LIST_LOG" >/dev/null || fail "Pi only listed models: $(cat "$PI_LIST_LOG")"
  [[ ! -s "$BD_COMMENTS" && ! -e "$wt/.bercail/handoff-result.json" ]] || fail "an unknown model comments and writes nothing"
}

_pi_profile() {
  local profile="$BATS_TEST_TMPDIR/pi-profile" guard="$BATS_TEST_TMPDIR/pi-profile/extensions/guard.ts"
  mkdir -p "$profile/extensions" "$profile/agents"
  printf '// guard\n' >"$guard"
  jq -n --arg guard "$guard" --arg model "claude-bridge/lead-model:high" \
    --arg prompts "$profile/prompts" --arg instructions "$profile/instructions.md" \
    '["pi","--model",$model,"-e","npm:pi-claude-bridge@0.11.0","-e",$guard,"--prompt-template",$prompts,"--append-system-prompt",$instructions]' \
    >"$profile/lead.json"
  printf '%s' "$profile"
}

@test "headless bstack and autopilot run Pi" {
  local saved_profile="${HANDOFF_PI_PROFILE-}"
  local profile wt out err rc=0 sid stub
  profile="$(_pi_profile)"
  export HANDOFF_PI_PROFILE="$profile"
  export HANDOFF_PI_BIN="$BATS_TEST_TMPDIR/bin/pi-missing"
  wt="$BATS_TEST_TMPDIR/pi-dry"
  mkdir -p "$wt"

  out="$(cd "$wt" && "$ROOT/skills/handoff/scripts/handoff-spawn" --stage bstack --issue "$ISSUE" --worktree "$wt" --dry-run)"
  printf '%s' "$out" | jq -e --arg bin "$HANDOFF_PI_BIN" --arg profile "$profile" --arg model "claude-bridge/lead-model:high" --arg id "$ISSUE" '
    .dry_run == true and .binary == "pi" and .model == $model and .stage == "bstack"
    and .command[0:11] == ["env","-u","ANTHROPIC_API_KEY","-u","ANTHROPIC_BASE_URL","-u","ANTHROPIC_AUTH_TOKEN","-u","BERCAIL_ROLE","-u","HC_TERMINAL_ID"]
    and (any(.command[]; . == "BERCAIL_ROLE=autopilot") | not)
    and .command[11] == $bin
    and .command[12:16] == ["-p","--mode","json","--session-id"]
    and (.command[16] | test("^[0-9a-fA-F-]{36}$"))
    and .session_id == .command[16]
    and .command[(.command | index("--model")) + 1] == $model
    and any(.command[]; . == ($profile + "/extensions/guard.ts"))
    and any(.command[]; . == ($profile + "/agents/bstack-headless.md"))
    and (any(.command[]; . == ($profile + "/agents/bstack-autopilot.md")) | not)
    and (any(.command[]; . == "--add-dir") | not)
    and .command[-2] == "--"
    and (.command[-1] | startswith("Your job is beads issue " + $id))
  ' >/dev/null || fail "bstack pi argv: $out"

  out="$(cd "$wt" && "$ROOT/skills/handoff/scripts/handoff-spawn" --stage autopilot --issue "$ISSUE" --worktree "$wt" --dry-run)"
  printf '%s' "$out" | jq -e --arg bin "$HANDOFF_PI_BIN" --arg profile "$profile" '
    .binary == "pi" and .stage == "autopilot"
    and .command[0:11] == ["env","-u","ANTHROPIC_API_KEY","-u","ANTHROPIC_BASE_URL","-u","ANTHROPIC_AUTH_TOKEN","-u","BERCAIL_ROLE","-u","HC_TERMINAL_ID"]
    and .command[11] == "BERCAIL_ROLE=autopilot"
    and .command[12] == $bin
    and .command[13:17] == ["-p","--mode","json","--session-id"]
    and any(.command[]; . == ($profile + "/agents/bstack-headless.md"))
    and any(.command[]; . == ($profile + "/agents/bstack-autopilot.md"))
    and .command[-2] == "--"
  ' >/dev/null || fail "autopilot pi argv: $out"

  sid=aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee
  out="$(cd "$wt" && "$ROOT/skills/handoff/scripts/handoff-spawn" --stage bstack --issue "$ISSUE" --worktree "$wt" --resume "$sid" --dry-run)"
  printf '%s' "$out" | jq -e --arg sid "$sid" '.resume == true and .session_id == $sid and .command[(.command | index("--session-id")) + 1] == $sid and (any(.command[]; . == "--resume") | not)' >/dev/null \
    || fail "pi resume reuses the uuid: $out"
  rc=0
  err="$(cd "$wt" && "$ROOT/skills/handoff/scripts/handoff-spawn" --stage bstack --issue "$ISSUE" --worktree "$wt" --resume ses_abc --dry-run 2>&1)" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "ses_ resume should fail"
  grep -q 'must be a uuid' <<<"$err" || fail "non-uuid resume message: $err"

  export HANDOFF_PI_PROFILE="$BATS_TEST_TMPDIR/no-pi-profile"
  mkdir -p "$HANDOFF_PI_PROFILE"
  rm -f "$wt/.bercail/handoff-result.json"
  rc=0
  err="$(cd "$wt" && "$ROOT/skills/handoff/scripts/handoff-spawn" --stage bstack --issue "$ISSUE" --worktree "$wt" --dry-run 2>&1)" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "missing lead.json should fail a dry run"
  grep -q 'bercail update' <<<"$err" || fail "missing lead.json dry-run message: $err"
  [[ ! -e "$wt/.bercail/handoff-result.json" ]] || fail "a dry run writes no result file"
  rc=0
  err="$(cd "$wt" && "$ROOT/skills/handoff/scripts/handoff-spawn" --stage bstack --issue "$ISSUE" --worktree "$wt" 2>&1)" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "missing lead.json should block"
  jq -e '.status == "blocked" and (.summary | test("bercail update"))' "$wt/.bercail/handoff-result.json" >/dev/null \
    || fail "missing lead.json result: $(cat "$wt/.bercail/handoff-result.json") $err"
  rm -f "$wt/.bercail/handoff-result.json"
  jq -n --arg model "claude-bridge/lead-model:high" '["pi","--model",$model,"-e","npm:pi-claude-bridge@0.11.0"]' >"$HANDOFF_PI_PROFILE/lead.json"
  rc=0
  err="$(cd "$wt" && "$ROOT/skills/handoff/scripts/handoff-spawn" --stage bstack --issue "$ISSUE" --worktree "$wt" 2>&1)" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "missing guard should block"
  jq -e '.status == "blocked" and (.summary | test("guard")) and (.summary | test("bercail update"))' "$wt/.bercail/handoff-result.json" >/dev/null \
    || fail "missing guard result: $(cat "$wt/.bercail/handoff-result.json")"
  export HANDOFF_PI_PROFILE="$profile"

  _bd_stub
  stub="$BATS_TEST_TMPDIR/bin/pi"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat >"$stub" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${PI_STUB_MODE:-}" == error ]]; then
  printf '%s\n' '{"type":"session","version":3,"id":"bbbbbbbb-cccc-4ddd-8eee-ffffffffffff"}'
  printf '%s\n' '{"type":"message_end","message":{"role":"assistant","stopReason":"error","errorMessage":"provider exploded"}}'
  exit 0
fi
printf '%s\n' '{"type":"session","version":3,"id":"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"}'
printf '%s\n' '{"type":"agent_settled"}'
jq -nc '{status:"ready", summary:"wrote the fix"}' >"$BERCAIL_RESULT_PATH"
exit 0
STUB
  chmod +x "$stub"
  export HANDOFF_PI_BIN="$stub"
  local runwt="$BATS_TEST_TMPDIR/pi-run" errf="$BATS_TEST_TMPDIR/pi-header.err"
  mkdir -p "$runwt"
  out="$(cd "$runwt" && "$ROOT/skills/handoff/scripts/handoff-spawn" --stage bstack --issue "$ISSUE" --worktree "$runwt" 2>"$errf")"
  grep -q 'using the header' "$errf" || fail "header mismatch should be said: $(cat "$errf")"
  jq -e '.status == "ready" and .session_id == "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"' "$runwt/.bercail/handoff-result.json" >/dev/null \
    || fail "header session: $(cat "$runwt/.bercail/handoff-result.json")"
  grep -q "stage bstack, headless pi, worktree $runwt" "$BD_COMMENTS" \
    || fail "handoff should comment the worktree on the issue: $(cat "$BD_COMMENTS")"

  export PI_STUB_MODE=error
  local failwt="$BATS_TEST_TMPDIR/pi-fail"
  mkdir -p "$failwt"
  rc=0
  out="$(cd "$failwt" && "$ROOT/skills/handoff/scripts/handoff-spawn" --stage bstack --issue "$ISSUE" --worktree "$failwt" 2>"$BATS_TEST_TMPDIR/pi-fail.err")" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "pi exit 0 with an error message_end should fail"
  jq -e '.status == "failed" and .session_id == "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff" and (has("reason") | not)' \
    "$failwt/.bercail/handoff-result.json" >/dev/null \
    || fail "pi provider error result: $(cat "$failwt/.bercail/handoff-result.json")"
  unset PI_STUB_MODE

  if [[ -n "$saved_profile" ]]; then export HANDOFF_PI_PROFILE="$saved_profile"; else unset HANDOFF_PI_PROFILE; fi
  unset HANDOFF_PI_BIN
}
