#!/usr/bin/env bats
# bercail guard ask: the model-free worker for an ask the guard handed off from
# Shep's session (docs/plans/shep-free-guard.md). Each test writes a ticket the way
# the guard does, runs the worker against a real ledger (bercail shep question), a
# real checkout and a bare remote, and answers its card as the panel does. Stand-ins
# for notify-send and entire; a temp HOME.

setup() {
  load test_helper
  isolate
  need git jq node flock
  set -o pipefail
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig" GIT_CONFIG_NOSYSTEM=1
  git config --global user.name test
  git config --global user.email test@example.com
  git config --global init.defaultBranch main
  unset BERCAIL_CONFIG BERCAIL_BIN ENTIRE_BIN HC_TERMINAL_ID
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH" BERCAIL_GUARD_ASK_POLL_MS=1000 BERCAIL_ROLE=shep
  export LOG="$BATS_TEST_TMPDIR/log"
  : >"$LOG"
  printf '#!/bin/sh\nprintf "notify-send %%s\\n" "$*" >>"$LOG"\n' >"$BATS_TEST_TMPDIR/bin/notify-send"
  chmod +x "$BATS_TEST_TMPDIR/bin/notify-send"
  ASKS="$XDG_STATE_HOME/bercail/guard-asks"
  INBOX="$XDG_STATE_HOME/bercail/shep/inbox"
  REPO="$BATS_TEST_TMPDIR/repo"
  ORIGIN="$BATS_TEST_TMPDIR/origin.git"
  git_init "$REPO"
  git -C "$REPO" branch feature
  git init -q --bare "$ORIGIN"
  # Each update of the remote's refs is in its reflog, so a second push shows.
  git -C "$ORIGIN" config core.logAllRefUpdates always
  git -C "$REPO" remote add origin "$ORIGIN"
}

# Only the workers: bats's timeout watchdog is a background job of this shell too.
teardown() {
  local pid
  for pid in "${WORKERS[@]}"; do kill "$pid" 2>/dev/null || true; done
}

bercail() { "$ROOT/bin/bercail" "$@"; }

# A ticket for Shep's command $1, written by the guard's own writeTicket: its id.
ticket() {
  node --input-type=module -e '
    const [guard, command, reason] = process.argv.slice(1);
    const g = await import(guard);
    const op = g.guardOperation(command, "/", process.env.HOME);
    if (typeof op === "string") throw new Error(op);
    const facts = await g.pinOperation(op);
    const t = g.writeTicket({ command, cwd: "/", reason, op, facts, shep: { terminal: "shep", session: "s1" } });
    console.log(t.id);
  ' "$ROOT/bstack/pi/extensions/guard.ts" "$1" "Allow this push? No keeps it local for the person."
}

# The worker for ticket $1, in the background; its output in $BATS_TEST_TMPDIR/worker-$1.$2.
WORKERS=()
worker() {
  # The script, not the function: $! is then the worker itself, which teardown can end.
  "$ROOT/bin/bercail" guard ask "$1" >"$BATS_TEST_TMPDIR/worker-$1.${2:-1}" 2>&1 &
  WORKERS+=("$!")
}

# The card of ticket $1, once the worker put it up: its token.
card() {
  local token=""
  for _ in $(seq 100); do
    token="$(bercail shep question json | jq -r --arg t "$1" '.questions[] | select(.guard.ticket == $t) | "\(.id)@\(.revision)"')"
    [[ -z "$token" ]] || break
    sleep 0.1
  done
  [[ -n "$token" ]] || fail "no card for ticket $1: $(cat "$BATS_TEST_TMPDIR"/worker-"$1".* 2>/dev/null)"
  printf '%s' "$token"
}

# The person's pick on card $1, from the panel unless $3 says otherwise.
pick() {
  jq -nc --arg t "$1" --arg c "$2" --arg s "${3:-panel picker}" \
    '{requestId: "pick-\($t)-\($c)-\($s)", token: $t, choice: $c, source: $s}' | bercail shep question answer
}

# The worker's guard event for ticket $1, once it wrote it.
event() {
  for _ in $(seq 150); do
    [[ -s "$INBOX/guard-$1.json" ]] && { cat "$INBOX/guard-$1.json"; return 0; }
    sleep 0.1
  done
  fail "no guard event for $1: $(cat "$BATS_TEST_TMPDIR"/worker-"$1".* 2>/dev/null)"
}

# The desktop notice $1, once the worker sent it: the worker does not wait for notify-send.
notice() {
  for _ in $(seq 150); do
    grep -qF "$1" "$LOG" && return 0
    sleep 0.1
  done
  fail "no notice: $(cat "$LOG")"
}

pushes() { git -C "$ORIGIN" reflog show --format=%H refs/heads/feature 2>/dev/null | wc -l; }

@test "on the person's Allow the worker pushes the pinned commit to the pinned URL once, and a restart runs nothing" {
  id="$(ticket "git -C $REPO push origin feature")"
  worker "$id"
  token="$(card "$id")"
  notice "notify-send Bercail Decisions: allow push of $ORIGIN refs/heads/feature?"
  # Allow and Deny, no recommendation; the brief names every pinned fact.
  bercail shep question json | jq -e --arg t "$token" --arg o "$ORIGIN" '.questions[] | select("\(.id)@\(.revision)" == $t)
    | .kind == "guard" and .options == ["Allow", "Deny"] and (has("recommendation") | not)
      and (.brief | contains("to \($o): ")) and .guard.worker == "guard-ask-\(.guard.ticket)"' >/dev/null || fail "card"
  pick "$token" Allow | jq -e '.accepted' >/dev/null || fail "pick refused"
  ev="$(event "$id")"
  jq -e --arg id "$id" --arg log "$ASKS/$id.log" '.kind == "guard" and .outcome == "ran" and .exit == 0
    and .event_id == "guard:\($id)" and .terminal == "guard-ask-\($id)" and .operation == "push" and .log == $log' <<<"$ev" >/dev/null \
    || fail "event: $ev"
  [[ "$(git -C "$ORIGIN" rev-parse refs/heads/feature)" == "$(git -C "$REPO" rev-parse feature)" ]] || fail "not pushed"
  grep -q "To $ORIGIN" "$ASKS/$id.log" || fail "log: $(cat "$ASKS/$id.log")"
  [[ "$(stat -c %a "$ASKS/$id.log")" == 600 ]] || fail "log mode"
  # The same ticket again: the claim is spent, so it runs nothing and says nothing.
  rm "$INBOX/guard-$id.json"
  run bercail guard ask "$id"
  [[ "$status" -eq 0 && "$output" == *"not run: its Allow was already claimed"* ]] || fail "rerun: $output"
  [[ ! -e "$INBOX/guard-$id.json" && "$(pushes)" -eq 1 ]] || fail "ran twice"
}

@test "the worker sends the pinned commit even when a ref is named like its hash" {
  id="$(ticket "git -C $REPO push origin feature")"
  pinned="$(git -C "$REPO" rev-parse feature)"
  # A ref named like the hash, on another commit: a bare hash as the source would send it.
  git -C "$REPO" commit -q --allow-empty -m other
  git -C "$REPO" branch "$pinned" HEAD
  git -C "$REPO" checkout -q feature
  worker "$id"
  pick "$(card "$id")" Allow >/dev/null
  jq -e '.outcome == "ran" and .exit == 0' <<<"$(event "$id")" >/dev/null || fail "event: $(cat "$INBOX/guard-$id.json")"
  [[ "$(git -C "$ORIGIN" rev-parse refs/heads/feature)" == "$pinned" ]] || fail "sent another commit"
}

@test "a Deny, an expiry, a withdrawal or a Discuss pick runs nothing" {
  id="$(ticket "git -C $REPO push origin feature")"
  worker "$id"
  token="$(card "$id")"
  # Discuss can talk but not pick: an agent can type into its terminal.
  pick "$token" Allow "discuss picker" | jq -e '.accepted == false and (.reason | test("panel card only"))' >/dev/null \
    || fail "a Discuss pick was taken"
  pick "$token" Deny >/dev/null
  jq -e '.outcome == "denied" and (has("exit") | not)' <<<"$(event "$id")" >/dev/null || fail "deny"

  id="$(ticket "git -C $REPO push origin feature")"
  worker "$id"
  token="$(card "$id")"
  jq -nc --arg t "$token" '{requestId: "w1", token: $t, reason: "moot"}' | bercail shep question withdraw >/dev/null
  jq -e '.outcome == "withdrawn" and .why == "moot"' <<<"$(event "$id")" >/dev/null || fail "withdrawn"

  # One that expired before anyone answered is withdrawn and counts as a Deny.
  id="$(ticket "git -C $REPO push origin feature")"
  jq '.expires = "2000-01-01T00:00:00.000Z"' "$ASKS/$id.json" >"$ASKS/$id.tmp" && mv "$ASKS/$id.tmp" "$ASKS/$id.json"
  worker "$id"
  jq -e '.outcome == "expired"' <<<"$(event "$id")" >/dev/null || fail "expired"
  bercail shep question json | jq -e --arg t "$id" '.questions[] | select(.guard.ticket == $t) | .status == "withdrawn"' \
    >/dev/null || fail "expired card stays"
  [[ "$(pushes)" -eq 0 ]] || fail "pushed"
}

@test "a pick after the card expired is refused and runs nothing" {
  local clock="$BATS_TEST_TMPDIR/clock.mjs"
  id="$(ticket "git -C $REPO push origin feature")"
  worker "$id"
  token="$(card "$id")"
  # The person picks two hours on, past the card's hour; the worker's clock stays now.
  printf 'const now = Date.now;\nDate.now = () => now() + 7200000;\n' >"$clock"
  NODE_OPTIONS="--import=$clock" pick "$token" Allow | jq -e '.accepted == false and (.reason | test("expired"))' >/dev/null \
    || fail "late Allow taken"
  bercail shep question json | jq -e --arg t "$id" '.questions[] | select(.guard.ticket == $t) | .status == "pending"' \
    >/dev/null || fail "the late Allow answered the card"
  [[ "$(pushes)" -eq 0 ]] || fail "pushed"
}

@test "a change before the pick withdraws the card, and a change after the Allow runs nothing" {
  id="$(ticket "git -C $REPO push origin feature")"
  worker "$id"
  token="$(card "$id")"
  git -C "$REPO" commit -q --allow-empty -m moved
  git -C "$REPO" branch -f feature HEAD
  jq -e '.outcome == "changed" and (.why | test("refspecs changed"))' <<<"$(event "$id")" >/dev/null || fail "stale"
  pick "$token" Allow | jq -e '.accepted == false' >/dev/null || fail "a stale card took a pick"

  # The remote's URL edited after the Allow: not to the new URL, and not to the old one.
  id="$(ticket "git -C $REPO push origin feature")"
  git init -q --bare "$BATS_TEST_TMPDIR/elsewhere.git"
  BERCAIL_GUARD_ASK_POLL_MS=2000 worker "$id"
  token="$(card "$id")"
  pick "$token" Allow >/dev/null
  git -C "$REPO" remote set-url origin "$BATS_TEST_TMPDIR/elsewhere.git"
  jq -e '.outcome == "changed" and (.why | test("url changed"))' <<<"$(event "$id")" >/dev/null || fail "moved remote"
  [[ "$(pushes)" -eq 0 ]] || fail "pushed to the old URL"
  run git -C "$BATS_TEST_TMPDIR/elsewhere.git" rev-parse --verify -q refs/heads/feature
  [[ "$status" -ne 0 ]] || fail "pushed to the new URL"
}

@test "a command the guard now refuses runs nothing on an Allow" {
  id="$(ticket "git -C $REPO push origin feature")"
  # As a guard that refuses it would read it: here, a force-push.
  jq --arg c "git -C $REPO push --force origin feature" '.command = $c' "$ASKS/$id.json" >"$ASKS/$id.tmp"
  mv "$ASKS/$id.tmp" "$ASKS/$id.json"
  worker "$id"
  pick "$(card "$id")" Allow >/dev/null
  jq -e '.outcome == "refused" and (.why | test("Force-push is blocked"))' <<<"$(event "$id")" >/dev/null || fail "refused"
  [[ "$(pushes)" -eq 0 ]] || fail "pushed"
}

@test "a worker that starts after the guard voided its ticket makes no card, and one whose card fails says so" {
  id="$(ticket "git -C $REPO push origin feature")"
  printf void >"$ASKS/$id.state"
  run bercail guard ask "$id"
  [[ "$status" -eq 0 && "$output" == void:* ]] || fail "void: $output"
  [[ "$(bercail shep question json | jq '.questions | length')" -eq 0 && ! -e "$INBOX/guard-$id.json" ]] || fail "card"

  # Its folder is gone, so the ledger cannot bind the card to a repo.
  id="$(ticket "git -C $REPO push origin feature")"
  mv "$REPO" "$REPO.gone"
  run bercail guard ask "$id"
  [[ "$status" -eq 0 && "$(cat "$ASKS/$id.state")" == started ]] || fail "start: $output"
  jq -e '.outcome == "failed"' "$INBOX/guard-$id.json" >/dev/null || fail "failed: $output"
  [[ "$(bercail shep question json | jq '.questions | length')" -eq 0 ]] || fail "a card with no worker"
  mv "$REPO.gone" "$REPO"

  # The ledger keeps the card, but its reply is lost: the worker takes the card down.
  printf '#!/bin/sh
"$REAL" "$@"; rc=$?
[ "$3" = guard-create ] && exit 1
exit $rc
' >"$BATS_TEST_TMPDIR/bin/lossy"
  chmod +x "$BATS_TEST_TMPDIR/bin/lossy"
  id="$(ticket "git -C $REPO push origin feature")"
  REAL="$ROOT/bin/bercail" BERCAIL_BIN="$BATS_TEST_TMPDIR/bin/lossy" run bercail guard ask "$id"
  jq -e '.outcome == "failed"' "$INBOX/guard-$id.json" >/dev/null || fail "lost reply: $output"
  bercail shep question json | jq -e --arg t "$id" '.questions[] | select(.guard.ticket == $t)
    | .status == "withdrawn" and .withdrawal.reason == "its worker stopped"' >/dev/null || fail "an orphan card stays"
}

@test "a worker stopped while it runs ends what it started and says the outcome is unknown" {
  printf '#!/bin/sh
[ "$2" = merge ] || { cat "$BATS_TEST_TMPDIR/trail.json"; exit 0; }
sleep 60 &
echo $! > "$BATS_TEST_TMPDIR/child.pid"
wait
' \
    >"$BATS_TEST_TMPDIR/bin/entire"
  chmod +x "$BATS_TEST_TMPDIR/bin/entire"
  jq -n '{id: "01TRAIL", number: 41, changes: [{repository: "repo", number: 7, status: "open", base: "main",
    current: null, mergeability: {head_sha: ("f" * 40)}}]}' >"$BATS_TEST_TMPDIR/trail.json"
  id="$(ticket "cd $REPO && entire trail merge 41")"
  worker "$id"
  pick "$(card "$id")" Allow >/dev/null
  for _ in $(seq 100); do [[ -s "$BATS_TEST_TMPDIR/child.pid" ]] && break; sleep 0.1; done
  child="$(cat "$BATS_TEST_TMPDIR/child.pid")"
  pkill -TERM -f "guard-ask.ts ask $id"
  jq -e '.outcome == "unknown"' <<<"$(event "$id")" >/dev/null || fail "outcome: $(cat "$INBOX/guard-$id.json")"
  for _ in $(seq 50); do kill -0 "$child" 2>/dev/null || break; sleep 0.1; done
  ! kill -0 "$child" 2>/dev/null || fail "its merge runs on unwatched"
}

@test "the worker polls its own card with question get, never the whole ledger" {
  # bercail as the worker runs it, each call's argv logged.
  printf '#!/bin/sh\nprintf "bercail %%s\\n" "$*" >>"$LOG"\nexec "$REAL" "$@"\n' >"$BATS_TEST_TMPDIR/bin/logged"
  chmod +x "$BATS_TEST_TMPDIR/bin/logged"
  id="$(ticket "git -C $REPO push origin feature")"
  REAL="$ROOT/bin/bercail" BERCAIL_BIN="$BATS_TEST_TMPDIR/bin/logged" BERCAIL_GUARD_ASK_POLL_MS=200 worker "$id"
  token="$(card "$id")"
  for _ in $(seq 100); do
    [[ "$(grep -cx "bercail shep question get $token" "$LOG")" -ge 3 ]] && break
    sleep 0.1
  done
  [[ "$(grep -cx "bercail shep question get $token" "$LOG")" -ge 3 ]] || fail "polls: $(cat "$LOG")"
  pick "$token" Allow >/dev/null
  jq -e '.outcome == "ran" and .exit == 0' <<<"$(event "$id")" >/dev/null || fail "ran"
  [[ "$(pushes)" -eq 1 ]] || fail "pushed $(pushes) times"
  if grep -E '^bercail shep (question json|questions)' "$LOG"; then fail "read the whole ledger"; fi
}

@test "two workers on one ticket run it once" {
  id="$(ticket "git -C $REPO push origin feature")"
  worker "$id" 1
  worker "$id" 2
  token="$(card "$id")"
  sleep 0.5
  pick "$token" Allow >/dev/null
  jq -e '.outcome == "ran"' <<<"$(event "$id")" >/dev/null || fail "ran"
  wait "${WORKERS[@]}"
  [[ "$(pushes)" -eq 1 ]] || fail "pushed $(pushes) times"
  cat "$BATS_TEST_TMPDIR/worker-$id.1" "$BATS_TEST_TMPDIR/worker-$id.2" | grep -q "not run: its Allow was already claimed" \
    || fail "both claimed: $(cat "$BATS_TEST_TMPDIR"/worker-"$id".*)"
  [[ "$(bercail shep question json | jq '[.questions[] | select(.kind == "guard")] | length')" -eq 1 ]] || fail "two cards"
}

@test "a cleanup, a trail merge and a trail job merge run their pinned argv on an Allow" {
  # Stand-ins at the process boundary: bercail cleanup and entire log what they ran.
  WT="$BATS_TEST_TMPDIR/repo.topic"
  git -C "$REPO" worktree add -q "$WT" feature
  printf '#!/bin/sh\nprintf "entire %%s|%%s\\n" "$PWD" "$*" >>"$LOG"\n[ "$2" = merge ] || cat "$BATS_TEST_TMPDIR/trail.json"\n' \
    >"$BATS_TEST_TMPDIR/bin/entire"
  chmod +x "$BATS_TEST_TMPDIR/bin/entire"
  jq -n '{id: "01TRAIL", number: 41, changes: [{repository: "repo", number: 7, status: "open", base: "main",
    current: null, mergeability: {head_sha: ("f" * 40)}}]}' >"$BATS_TEST_TMPDIR/trail.json"
  id="$(ticket "cd $REPO && entire trail merge 41")"
  worker "$id"
  pick "$(card "$id")" Allow >/dev/null
  jq -e '.outcome == "ran" and .operation == "trail merge" and .target == "repo/7"' <<<"$(event "$id")" >/dev/null \
    || fail "merge"
  grep -qx "entire $REPO|trail merge repo/7" "$LOG" || fail "argv: $(cat "$LOG")"

  # A trail job merge: bercail job merge on the pinned change, which merges and then closes.
  printf '#!/bin/sh\n[ "$1 $2" = "job merge" ] || exec "%s" "$@"\nprintf "job %%s|%%s\\n" "$PWD" "$*" >>"$LOG"\n' "$ROOT/bin/bercail" \
    >"$BATS_TEST_TMPDIR/bin/bercail-job"
  chmod +x "$BATS_TEST_TMPDIR/bin/bercail-job"
  id="$(ticket "bercail job merge trail:41 --repo $REPO")"
  BERCAIL_BIN="$BATS_TEST_TMPDIR/bin/bercail-job" worker "$id"
  token="$(card "$id")"
  bercail shep question json | jq -e --arg t "$token" '.questions[] | select("\(.id)@\(.revision)" == $t)
    | .brief | contains("bercail job merge trail:41 --change repo/7") and contains("then closes trail:41")' >/dev/null \
    || fail "brief: $(bercail shep question json | jq -c '.questions[-1].brief')"
  pick "$token" Allow >/dev/null
  jq -e '.outcome == "ran" and .operation == "trail merge" and .target == "repo/7"' <<<"$(event "$id")" >/dev/null \
    || fail "job merge: $(cat "$INBOX/guard-$id.json")"
  grep -qx "job $REPO|job merge trail:41 --change repo/7 --repo $REPO" "$LOG" || fail "argv: $(cat "$LOG")"

  printf '#!/bin/sh\nprintf "bercail %%s\\n" "$*" >>"$LOG"\nexec "$REAL" "$@"\n' >"$BATS_TEST_TMPDIR/bin/bercail-logged"
  chmod +x "$BATS_TEST_TMPDIR/bin/bercail-logged"
  export REAL="$ROOT/bin/bercail"
  id="$(ticket "bercail cleanup $WT")"
  BERCAIL_BIN="$BATS_TEST_TMPDIR/bin/bercail-logged" worker "$id"
  pick "$(card "$id")" Allow >/dev/null
  jq -e '.operation == "cleanup" and .target == $wt and .outcome == "ran"' --arg wt "$WT" <<<"$(event "$id")" >/dev/null \
    || fail "cleanup: $(cat "$INBOX/guard-$id.json")"
  grep -qx "bercail cleanup $WT" "$LOG" || fail "argv: $(cat "$LOG")"
}

@test "bercail guard check says what changed since a card's facts were pinned" {
  id="$(ticket "git -C $REPO push origin feature")"
  input="$(jq -c '{op, facts}' "$ASKS/$id.json")"
  run bercail guard check <<<"$input"
  [[ "$status" -eq 0 && "$output" == '{"reasons":[]}' ]] || fail "fresh: $output"
  git init -q --bare "$BATS_TEST_TMPDIR/elsewhere.git"
  git -C "$REPO" remote set-url origin "$BATS_TEST_TMPDIR/elsewhere.git"
  run bercail guard check <<<"$input"
  [[ "$output" == '{"reasons":["url changed"]}' ]] || fail "moved: $output"
  git -C "$REPO" remote remove origin
  run bercail guard check <<<"$input"
  [[ "$output" == *'no longer pins: '* ]] || fail "gone: $output"
}
