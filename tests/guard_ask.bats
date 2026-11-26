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

@test "on the person's Allow the worker publishes a desk's restack under its lease, and a push over it since withdraws the card" {
  git -C "$REPO" push -q origin main feature
  mkdir -p "$XDG_STATE_HOME/bercail"
  jq -nc --arg p "$REPO" '{at: "2026-11-24T10:00:00Z", ok: true, agent_started: true, desk: "t1", path: $p, repo: $p, branch: "feature"}' \
    >"$XDG_STATE_HOME/bercail/handoffs.jsonl"
  old="$(git -C "$REPO" rev-parse feature)"
  # The desk's restack: feature rewritten, so origin's head is not under the new one.
  git -C "$REPO" checkout -q feature
  git -C "$REPO" commit -q --amend --allow-empty -m restacked
  new="$(git -C "$REPO" rev-parse HEAD)"
  id="$(ticket "git -C $REPO push --force-with-lease=refs/heads/feature:$old origin $new:refs/heads/feature")"
  worker "$id"
  token="$(card "$id")"
  notice "notify-send Bercail Decisions: allow force-with-lease push of $ORIGIN refs/heads/feature? It waits for you."
  bercail shep question json | jq -e --arg t "$token" --arg old "$old" --arg new "$new" '.questions[]
    | select("\(.id)@\(.revision)" == $t)
    | (.brief | contains("the old head \($old) to the new head \($new)")) and (.guard | has("defaults") | not)' >/dev/null \
    || fail "card: $(bercail shep question json)"
  pick "$token" Allow >/dev/null
  jq -e '.outcome == "ran" and .exit == 0' <<<"$(event "$id")" >/dev/null || fail "event: $(cat "$INBOX/guard-$id.json")"
  [[ "$(git -C "$ORIGIN" rev-parse refs/heads/feature)" == "$new" ]] || fail "not published: $(cat "$ASKS/$id.log")"

  # Someone pushed over it before the worker's first check: the card goes stale, and their push stays.
  git -C "$REPO" commit -q --amend --allow-empty -m again
  again="$(git -C "$REPO" rev-parse HEAD)"
  id="$(ticket "git -C $REPO push --force-with-lease=refs/heads/feature:$new origin $again:refs/heads/feature")"
  git -C "$REPO" push -q --force origin "$old:refs/heads/feature"
  worker "$id"
  jq -e '.outcome == "changed" and (.why | test("not the old head"))' <<<"$(event "$id")" >/dev/null \
    || fail "event: $(cat "$INBOX/guard-$id.json")"
  [[ "$(git -C "$ORIGIN" rev-parse refs/heads/feature)" == "$old" ]] || fail "their push was replaced"
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
  grep -qsF "not run: its Allow was already claimed" "$BATS_TEST_TMPDIR/worker-$id.1" "$BATS_TEST_TMPDIR/worker-$id.2" \
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
    | .brief | contains("bercail job merge trail:41 --change repo/7") and contains("then closes trail:41")
      and (contains("config.toml") | not)' >/dev/null \
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

@test "a cleanup --gone goes on the card as a record that removes nothing, and on an Allow records the checkout retired" {
  GONE="$BATS_TEST_TMPDIR/repo.gone"
  mkdir -p "$XDG_STATE_HOME/bercail"
  jq -nc --arg p "$GONE" --arg r "$REPO" '{path: $p, repo: $r, branch: "feature"}' >"$XDG_STATE_HOME/bercail/handoffs.jsonl"
  printf '#!/bin/sh\nprintf "bercail %%s\\n" "$*" >>"$LOG"\nexec "$REAL" "$@"\n' >"$BATS_TEST_TMPDIR/bin/bercail-logged"
  chmod +x "$BATS_TEST_TMPDIR/bin/bercail-logged"
  export REAL="$ROOT/bin/bercail"
  id="$(ticket "bercail cleanup --gone '$GONE'")"
  BERCAIL_BIN="$BATS_TEST_TMPDIR/bin/bercail-logged" worker "$id"
  token="$(card "$id")"
  notice "notify-send Bercail Decisions: allow cleanup --gone of $GONE?"
  bercail shep question json | jq -e --arg t "$token" --arg g "$GONE" --arg r "$REPO" '.questions[] | select("\(.id)@\(.revision)" == $t)
    | .brief | contains("bercail cleanup --gone \($g), the gone checkout a handoff of \($r) names (branch feature): it records it as retired and removes nothing")' \
    >/dev/null || fail "brief: $(bercail shep question json | jq -c '.questions[-1].brief')"
  pick "$token" Allow >/dev/null
  jq -e '.operation == "cleanup" and .target == $g and .outcome == "ran" and .exit == 0' --arg g "$GONE" <<<"$(event "$id")" >/dev/null \
    || fail "cleanup --gone: $(cat "$INBOX/guard-$id.json")"
  grep -qx "bercail cleanup --gone $GONE" "$LOG" || fail "argv: $(cat "$LOG")"
  jq -e --arg g "$GONE" --arg r "$REPO" 'select(.path == $g) | .repo == $r and .branch == "feature" and .gone == true' \
    "$XDG_STATE_HOME/bercail/retired.jsonl" >/dev/null || fail "retired: $(cat "$XDG_STATE_HOME/bercail/retired.jsonl")"
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

# Stand-in entire: one line for where it ran, then one per argument, as it got them.
argv_entire() {
  printf '#!/bin/sh\n[ "$1" = agent-help ] && { echo "{}"; exit 0; }\nprintf "entire %%s\\n" "$PWD" >>"$LOG"\nfor a in "$@"; do printf "arg[%%s]\\n" "$a" >>"$LOG"; done\n' \
    >"$BATS_TEST_TMPDIR/bin/entire"
  chmod +x "$BATS_TEST_TMPDIR/bin/entire"
}

@test "any other one command goes on the card as its words and runs as exactly that argv, once, with its quoted text literal" {
  argv_entire
  # Every shell metacharacter, inside the quotes: none of it may run.
  text='never `touch pwned`; touch pwned | cat > out && $(touch pwned) "q"'
  id="$(ticket "cd $REPO && entire brain remember '$text' --json")"
  worker "$id"
  token="$(card "$id")"
  shown="entire brain remember '$text' --json"
  notice "notify-send Bercail Decisions: allow command $shown?"
  bercail shep question json | jq -e --arg t "$token" --arg s "$shown in $REPO, as these 5 words with no shell" \
    '.questions[] | select("\(.id)@\(.revision)" == $t) | .kind == "guard" and (.brief | contains($s))' >/dev/null \
    || fail "brief: $(bercail shep question json | jq -c '.questions[-1].brief')"
  pick "$token" Allow >/dev/null
  jq -e --arg s "$shown" '.outcome == "ran" and .exit == 0 and .operation == "command" and .target == $s' \
    <<<"$(event "$id")" >/dev/null || fail "event: $(cat "$INBOX/guard-$id.json")"
  [[ "$(grep -c '^entire ' "$LOG")" -eq 1 ]] || fail "ran $(grep -c '^entire ' "$LOG") times: $(cat "$LOG")"
  [[ "$(grep -v '^notify-send' "$LOG")" == "entire $REPO
arg[brain]
arg[remember]
arg[$text]
arg[--json]" ]] || fail "argv: $(cat "$LOG")"
  [[ -z "$(find "$BATS_TEST_TMPDIR" -name pwned -o -name out)" ]] || fail "a quoted metacharacter ran"
  run bercail guard ask "$id"
  [[ "$output" == *"not run: its Allow was already claimed"* && "$(grep -c '^entire ' "$LOG")" -eq 1 ]] || fail "rerun: $output"
}

@test "Shep's config change shows each line on its card, runs as bercail on an Allow, and a Deny or a change by the person writes nothing" {
  export BERCAIL_BIN="$ROOT/bin/bercail"
  config="$HOME/.config/bercail/config.toml"
  mkdir -p "${config%/*}"
  printf '[shep]\nrollover = false\n' >"$config"
  id="$(ticket "cd $REPO && bercail config set shep rollover true")"
  worker "$id"
  token="$(card "$id")"
  bercail shep question json | jq -e --arg t "$token" --arg c "$config" --arg r "$ROOT" '.questions[] | select("\(.id)@\(.revision)" == $t)
    | .brief | contains("runs \($r)/bin/bercail config set shep rollover true --expect ")
      and contains("It changes config.toml so:\n--- \($c)\n+++ \($c)\n-rollover = false\n+rollover = true\n")' \
    >/dev/null || fail "brief: $(bercail shep question json | jq -c '.questions[-1].brief')"
  [[ "$(cat "$config")" == $'[shep]\nrollover = false' ]] || fail "written before the Allow: $(cat "$config")"
  pick "$token" Allow >/dev/null
  jq -e '.outcome == "ran" and .exit == 0' <<<"$(event "$id")" >/dev/null || fail "event: $(cat "$INBOX/guard-$id.json")"
  [[ "$(cat "$config")" == $'[shep]\nrollover = true' ]] || fail "after the Allow: $(cat "$config")"

  id="$(ticket "cd $REPO && bercail routine enable deps")"
  worker "$id"
  pick "$(card "$id")" Deny >/dev/null
  jq -e '.outcome == "denied"' <<<"$(event "$id")" >/dev/null || fail "event: $(cat "$INBOX/guard-$id.json")"
  [[ "$(cat "$config")" == $'[shep]\nrollover = true' ]] || fail "after the Deny: $(cat "$config")"

  id="$(ticket "cd $REPO && bercail config unset shep rollover")"
  BERCAIL_GUARD_ASK_POLL_MS=200 worker "$id"
  token="$(card "$id")"
  printf '[shep]\nrollover = true # the person\n' >"$config"
  jq -e '.outcome == "changed" and .why == "argv changed, diff changed"' <<<"$(event "$id")" >/dev/null \
    || fail "event: $(cat "$INBOX/guard-$id.json")"
  [[ "$(cat "$config")" == $'[shep]\nrollover = true # the person' ]] || fail "written: $(cat "$config")"
}

@test "a command whose argument changed after its card runs nothing on an Allow" {
  argv_entire
  # Its ticket rewritten once the card is up, and before it: neither runs.
  id="$(ticket "cd $REPO && entire trail link 41 --branch feature --base main")"
  BERCAIL_GUARD_ASK_POLL_MS=200 worker "$id"
  token="$(card "$id")"
  bercail shep question json | jq -e --arg t "$token" '.questions[] | select("\(.id)@\(.revision)" == $t)
    | .brief | contains("entire trail link 41 --branch feature --base main in ")' >/dev/null || fail "brief"
  jq '.command |= sub("main$"; "other") | .op.argv[-1] = "other" | .facts.argv[-1] = "other"' "$ASKS/$id.json" >"$ASKS/$id.tmp"
  mv "$ASKS/$id.tmp" "$ASKS/$id.json"
  pick "$token" Allow >/dev/null
  jq -e '.outcome == "changed" and .why == "its ticket changed since the card went up"' <<<"$(event "$id")" >/dev/null \
    || fail "event: $(cat "$INBOX/guard-$id.json")"

  id="$(ticket "cd $REPO && entire trail link 41 --branch feature --base main")"
  jq --arg c "cd $REPO && entire trail link 41 --branch feature --base other" '.command = $c' "$ASKS/$id.json" >"$ASKS/$id.tmp"
  mv "$ASKS/$id.tmp" "$ASKS/$id.json"
  worker "$id"
  pick "$(card "$id")" Allow >/dev/null
  jq -e '.outcome == "changed" and (.why | test("no longer reads as the same operation"))' <<<"$(event "$id")" >/dev/null \
    || fail "event: $(cat "$INBOX/guard-$id.json")"
  ! grep -q '^entire ' "$LOG" || fail "ran: $(cat "$LOG")"
}

@test "a push to an entire:// remote goes on the card as the Entire project, and the worker sends to that URL" {
  url=entire://aws-us-east-2.entire.io/et/acme/widgets
  # git's remote helper for entire://: it logs how git called it, and sends nothing.
  printf '#!/bin/sh\nprintf "git-remote-entire %%s\\n" "$*" >>"$LOG"\nexit 1\n' >"$BATS_TEST_TMPDIR/bin/git-remote-entire"
  chmod +x "$BATS_TEST_TMPDIR/bin/git-remote-entire"
  git -C "$REPO" remote set-url origin "$url"
  id="$(ticket "git -C $REPO push origin feature")"
  worker "$id"
  token="$(card "$id")"
  notice "notify-send Bercail Decisions: allow push of the Entire project et/acme/widgets ($url) refs/heads/feature?"
  bercail shep question json | jq -e --arg t "$token" --arg u "$url" '.questions[] | select("\(.id)@\(.revision)" == $t)
    | .brief | contains("to the Entire project et/acme/widgets (\($u)): ")' >/dev/null || fail "brief"
  pick "$token" Allow >/dev/null
  jq -e '.outcome == "ran" and .exit != 0' <<<"$(event "$id")" >/dev/null || fail "event: $(cat "$INBOX/guard-$id.json")"
  grep -qx "git-remote-entire $url $url" "$LOG" || fail "helper: $(cat "$LOG") $(cat "$ASKS/$id.log")"
}

@test "Shep's trail link runs on an Allow as its words, in the checkout its cd names" {
  argv_entire
  id="$(ticket "cd $REPO && entire trail link 41 --branch feature --base main")"
  worker "$id"
  pick "$(card "$id")" Allow >/dev/null
  jq -e '.outcome == "ran" and .exit == 0 and .operation == "command"' <<<"$(event "$id")" >/dev/null \
    || fail "event: $(cat "$INBOX/guard-$id.json")"
  [[ "$(grep -v '^notify-send' "$LOG" | tr '\n' ' ')" == "entire $REPO arg[trail] arg[link] arg[41] arg[--branch] arg[feature] arg[--base] arg[main] " ]] \
    || fail "argv: $(cat "$LOG")"
}

# bercail-mdfb: a card nobody answers counts as an Allow at its deadline when what it runs
# is private or local. One case per step of tests/statechart/guard-card/GuardCard.tla.

# A clock for every node process from here on: Date runs $CLOCK's milliseconds ahead.
fake_clock() {
  export CLOCK="$BATS_TEST_TMPDIR/clock"
  printf 0 >"$CLOCK"
  printf '%s\n' 'import { readFileSync } from "node:fs";' 'const Real = Date;' \
    'const off = () => Number(readFileSync(process.env.CLOCK, "utf8") || 0);' \
    'globalThis.Date = class extends Real { constructor(...a) { super(...(a.length ? a : [Real.now() + off()])); } static now() { return Real.now() + off(); } };' \
    >"$BATS_TEST_TMPDIR/clock.mjs"
  export NODE_OPTIONS="--import=$BATS_TEST_TMPDIR/clock.mjs"
}
# Moves the clock to $2 seconds before ticket $1's deadline ($2 below 0: past it).
before() {
  NODE_OPTIONS='' node -e 'const t = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    process.stdout.write(String(Date.parse(t.expires) - Date.now() - Number(process.argv[2]) * 1000))' "$ASKS/$1.json" "$2" >"$CLOCK.tmp"
  mv "$CLOCK.tmp" "$CLOCK"
}
# The repo's trusted policy says merge_reversible = true (as the person's local config sets it).
reversible() {
  mkdir -p "$XDG_CONFIG_HOME/bercail"
  printf '[policy."%s"]\nmerge_reversible = %s\n' "$REPO" "${1:-true}" >"$XDG_CONFIG_HOME/bercail/config.toml"
}
# Ticket $1's card, as the ledger has it.
ledger() { bercail shep question json | jq -c --arg t "$1" '.questions[] | select(.guard.ticket == $t)'; }

@test "a card nobody answers counts as an Allow at its deadline when it reads private or local: it runs once, and its event says it was defaulted" {
  reversible
  fake_clock
  id="$(ticket "git -C $REPO push origin feature")"
  worker "$id"
  card "$id" >/dev/null
  notice "notify-send Bercail Decisions: allow push of $ORIGIN refs/heads/feature? It defaults to Allow at "
  ledger "$id" | jq -e --arg o "$ORIGIN" '.guard.defaults.why == "it pushes to the repo \($o) on this machine"
    and (.brief | test("It defaults to Allow at [0-9]{2}:[0-9]{2}: nobody answering by then counts as an Allow, because it pushes to the repo "))' \
    >/dev/null || fail "card: $(ledger "$id")"
  before "$id" 5
  ev="$(event "$id")"
  jq -e '.outcome == "ran" and .exit == 0 and .defaulted == true' <<<"$ev" >/dev/null || fail "event: $ev"
  ledger "$id" | jq -e '.status == "answered" and .answer.source == "guard default at expiry" and .answer.choice == "Allow"
    and (.guardClaim | type == "object")' >/dev/null || fail "ledger: $(ledger "$id")"
  [[ "$(pushes)" -eq 1 && "$(git -C "$ORIGIN" rev-parse refs/heads/feature)" == "$(git -C "$REPO" rev-parse feature)" ]] \
    || fail "pushed $(pushes) times"
}

@test "a card that waits for you counts as a Deny at its deadline, even once it would read private" {
  fake_clock
  id="$(ticket "git -C $REPO push origin feature")"
  worker "$id"
  card "$id" >/dev/null
  notice "It waits for you."
  ledger "$id" | jq -e '(.guard | has("defaults") | not)
    and (.brief | test("It waits for you: nobody answering by [0-9]{2}:[0-9]{2} counts as a Deny, because the repo.s trusted policy does not say merge_reversible = true"))' \
    >/dev/null || fail "card: $(ledger "$id")"
  reversible
  before "$id" 5
  jq -e '.outcome == "expired" and (has("defaulted") | not)' <<<"$(event "$id")" >/dev/null || fail "event: $(cat "$INBOX/guard-$id.json")"
  [[ "$(pushes)" -eq 0 ]] || fail "pushed"
}

@test "a card that said it defaults counts as a Deny when, at its deadline, it no longer reads as it did" {
  reversible
  fake_clock
  id="$(ticket "git -C $REPO push origin feature")"
  worker "$id"
  card "$id" >/dev/null
  reversible false
  before "$id" 5
  jq -e '.outcome == "expired" and (.why | test("at the deadline the repo.s trusted policy does not say merge_reversible"))' \
    <<<"$(event "$id")" >/dev/null || fail "event: $(cat "$INBOX/guard-$id.json")"
  ledger "$id" | jq -e '.status == "withdrawn"' >/dev/null || fail "ledger: $(ledger "$id")"
  [[ "$(pushes)" -eq 0 ]] || fail "pushed"
}

@test "a default that no longer reads private or local right before the run runs nothing" {
  reversible
  # bercail as the worker runs it: once the default is recorded, the policy reads false.
  printf '#!/bin/sh
[ "$3" = guard-default ] && : >"$BATS_TEST_TMPDIR/defaulted"
if [ "$1" = policy ] && [ -e "$BATS_TEST_TMPDIR/defaulted" ]; then
  "$REAL" "$@" | jq -c ".policy.merge_reversible = false"
  exit 0
fi
exec "$REAL" "$@"
' >"$BATS_TEST_TMPDIR/bin/flips"
  chmod +x "$BATS_TEST_TMPDIR/bin/flips"
  fake_clock
  id="$(ticket "git -C $REPO push origin feature")"
  REAL="$ROOT/bin/bercail" BERCAIL_BIN="$BATS_TEST_TMPDIR/bin/flips" worker "$id"
  card "$id" >/dev/null
  before "$id" 5
  jq -e '.outcome == "expired" and .defaulted == true and (.why | test("right before the run"))' <<<"$(event "$id")" \
    >/dev/null || fail "event: $(cat "$INBOX/guard-$id.json")"
  [[ "$(pushes)" -eq 0 ]] || fail "pushed"
}

@test "an origin whose visibility cannot be read waits, and the person's Deny on a card that defaults runs nothing" {
  reversible
  # gh cannot reach GitHub: unknown counts as public.
  printf '#!/bin/sh\necho "gh: could not connect" >&2\nexit 1\n' >"$BATS_TEST_TMPDIR/bin/gh"
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  git -C "$REPO" remote set-url origin git@github.com:acme/app.git
  id="$(ticket "git -C $REPO push origin feature")"
  worker "$id"
  card "$id" >/dev/null
  ledger "$id" | jq -e '(.guard | has("defaults") | not) and (.brief | test("could not read whether gh/acme/app is private"))' \
    >/dev/null || fail "card: $(ledger "$id")"
  pick "$(card "$id")" Deny >/dev/null
  jq -e '.outcome == "denied"' <<<"$(event "$id")" >/dev/null || fail "event"

  # gh says it is private: the card defaults, and the person's Deny still wins.
  printf '#!/bin/sh\necho "{\\"visibility\\":\\"PRIVATE\\",\\"id\\":\\"R_1\\"}"\n' >"$BATS_TEST_TMPDIR/bin/gh"
  id="$(ticket "git -C $REPO push origin feature")"
  worker "$id"
  token="$(card "$id")"
  ledger "$id" | jq -e '.guard.defaults.why == "it pushes to the private GitHub repo acme/app (R_1)"' >/dev/null \
    || fail "card: $(ledger "$id")"
  pick "$token" Deny >/dev/null
  jq -e '.outcome == "denied"' <<<"$(event "$id")" >/dev/null || fail "event: $(cat "$INBOX/guard-$id.json")"
}

@test "a worker that dies before the deadline leaves its card to the person: nothing defaults" {
  reversible
  fake_clock
  id="$(ticket "git -C $REPO push origin feature")"
  worker "$id"
  card "$id" >/dev/null
  kill -9 "${WORKERS[-1]}"
  before "$id" -5
  sleep 2
  ledger "$id" | jq -e '.status == "pending"' >/dev/null || fail "ledger: $(ledger "$id")"
  [[ "$(pushes)" -eq 0 && ! -e "$INBOX/guard-$id.json" ]] || fail "ran"
}

@test "a card that went up late, or whose machine slept through its deadline, counts as a Deny though it reads private" {
  reversible
  fake_clock
  id="$(ticket "git -C $REPO push origin feature")"
  before "$id" -60
  worker "$id"
  jq -e '.outcome == "expired"' <<<"$(event "$id")" >/dev/null || fail "late: $(cat "$INBOX/guard-$id.json")"

  # The machine sleeps through the deadline: no poll saw the card in its last minutes.
  printf 0 >"$CLOCK"
  id="$(ticket "git -C $REPO push origin feature")"
  worker "$id"
  card "$id" >/dev/null
  before "$id" -600
  jq -e '.outcome == "expired" and (.why | test("not watched through its deadline"))' <<<"$(event "$id")" >/dev/null \
    || fail "slept: $(cat "$INBOX/guard-$id.json")"

  # A poll in its last minutes, then the machine sleeps overnight: it acts on a stale reading.
  printf 0 >"$CLOCK"
  id="$(ticket "git -C $REPO push origin feature")"
  worker "$id"
  card "$id" >/dev/null
  before "$id" 60
  sleep 2.5
  before "$id" -36000
  jq -e '.outcome == "expired" and (.why | test("not watched through its deadline"))' <<<"$(event "$id")" >/dev/null \
    || fail "overnight: $(cat "$INBOX/guard-$id.json")"

  # A card that goes up with 40 minutes left says it waits, and expires as a Deny.
  printf 0 >"$CLOCK"
  id="$(ticket "git -C $REPO push origin feature")"
  before "$id" 2400
  worker "$id"
  card "$id" >/dev/null
  ledger "$id" | jq -e '(.guard | has("defaults") | not) and (.brief | test("less than most of its hour left"))' >/dev/null \
    || fail "late card: $(ledger "$id")"
  before "$id" 3
  jq -e '.outcome == "expired"' <<<"$(event "$id")" >/dev/null || fail "late card: $(cat "$INBOX/guard-$id.json")"
  [[ "$(pushes)" -eq 0 ]] || fail "pushed"
}

@test "the guard card's statechart was last checked on the spec, configs and view as they are" {
  cd "$ROOT/tests/statechart/guard-card"
  sha256sum --quiet -c sha256sums || fail "stale: run tests/statechart/guard-card/check.sh"
}
