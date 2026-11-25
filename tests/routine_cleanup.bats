#!/usr/bin/env bats
# The cleanup routine (lib/routine/cleanup.sh): what it finds from stand-in
# state, one @test per finding, and nothing in a clean one. A real git repo
# with a bare origin, the real question ledger, and stand-ins for hc, bd and
# the Herdr app. Each @test is its own HOME.

assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected '$1' got '$2'"; }

setup() {
  load test_helper
  isolate
  need git jq flock sha256sum node
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH" TZ=UTC
  export HC_DATA="$BATS_TEST_TMPDIR/hc" HERDR="$BATS_TEST_TMPDIR/herdr.json"
  export HC_BIN="$BATS_TEST_TMPDIR/bin/hc" HERDR_APP_BIN="$BATS_TEST_TMPDIR/bin/herdr-app"
  export BERCAIL_HERDR_LAYOUT="$ROOT/config/worktrunk/herdr-layout.sh"
  unset HC_TERMINAL_ID HC_FAIL
  mkdir -p "$HC_DATA" "$XDG_CONFIG_HOME/bercail" "$XDG_STATE_HOME/bercail/shep/inbox"
  echo '[]' >"$HC_DATA/terminals.json"
  RECORDS="$XDG_STATE_HOME/bercail/handoffs.jsonl" SEEN="$XDG_STATE_HOME/bercail/routines/cleanup/seen-done.json"
  printf '[routine.cleanup]\nrun = "cleanup"\nat = "07:30"\n' >"$XDG_CONFIG_HOME/bercail/config.toml"

  # hc: terminals in $HC_DATA/terminals.json, each {address, name, state, cwd,
  # status, labels}. ls, like the real one, prints no labels and filters by
  # them; get prints the whole terminal. $HC_FAIL: the call that fails.
  cat >"$HC_BIN" <<'SH'
#!/usr/bin/env bash
[[ "$*" != "${HC_FAIL:-}" ]] || exit 1
case "$1" in
  ls)
    want=()
    while [[ $# -gt 0 ]]; do [[ "$1" != --label ]] || want+=("$2"); shift; done
    jq --args '{terminals: [.[] | select(. as $t | $ARGS.positional
        | all(split("=") as [$k, $v] | $t.labels[$k] == $v)) | {address, name, state, cwd}]}' \
      "${want[@]}" <"$HC_DATA/terminals.json" ;;
  get) jq -e --arg a "$2" '.[] | select(.address == $a)' "$HC_DATA/terminals.json" ;;
  *) exit 2 ;;
esac
SH
  # bd answers show from the main checkout of the repo it runs in: .beads/fake/<id>.json,
  # after running .beads/fake/<id>.hook when there is one. A hook that fails is bd's status.
  cat >"$BATS_TEST_TMPDIR/bin/bd" <<'SH'
#!/usr/bin/env bash
main="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"
[[ "$1" != show || ! -f "$main/.beads/fake/$2.hook" ]] || bash "$main/.beads/fake/$2.hook" || exit
[[ "$1" == show ]] && cat "$main/.beads/fake/$2.json" 2>/dev/null
SH
  # The Herdr app: a window runs while $HERDR exists, and ls prints it.
  cat >"$HERDR_APP_BIN" <<'SH'
#!/usr/bin/env bash
[[ -f "$HERDR" ]] || exit 1
case "$1" in
  status) echo '{"space":"sp-main"}' ;;
  ls) cat "$HERDR" ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$HC_BIN" "$BATS_TEST_TMPDIR/bin/bd" "$HERDR_APP_BIN"

  # widgets: a main checkout on master, pushed to a bare origin, with beads.
  WORK="$HOME/Work"
  git init -q --bare -b master "$BATS_TEST_TMPDIR/origin.git"
  git_init "$WORK/widgets"
  git -C "$WORK/widgets" branch -M master
  git -C "$WORK/widgets" remote add origin "$BATS_TEST_TMPDIR/origin.git"
  git -C "$WORK/widgets" push -q -u origin master
  WORK="$(cd "$WORK" && pwd -P)" MAIN="$WORK/widgets"
  mkdir -p "$MAIN/.beads/fake"
  printf '.beads/\n' >>"$MAIN/.git/info/exclude"
}

# job ID STATUS: bd's issue ID in widgets, titled "Job ID".
job() {
  jq -n --arg id "$1" --arg s "$2" '[{id: $id, title: "Job \($id)", status: $s}]' >"$MAIN/.beads/fake/$1.json"
}

# worktree NAME ISSUE: widgets.NAME on branch NAME, one commit pushed, and the
# handoff record that made it, with space sp-NAME.
worktree() {
  local wt="$WORK/widgets.$1"
  git -C "$MAIN" worktree add -q -b "$1" "$wt"
  printf '%s\n' "$1" >"$wt/$1.txt"
  git -C "$wt" add "$1.txt"
  git -C "$wt" commit -qm "$1"
  git -C "$wt" push -q origin "$1"
  jq -nc --arg p "$wt" --arg b "$1" --arg i "$2" --arg r "$MAIN" \
    '{v: 1, ok: true, path: $p, branch: $b, issue: $i, desk: "d-\($b)", space: "sp-\($b)", repo: $r}' >>"$RECORDS"
}

# desk ADDRESS CWD ISSUE STATE [bg] [SPACE]: a live desk, or a background Shep,
# with a pid of its own, as hc gives one.
desk() {
  jq --arg a "$1" --arg c "$2" --arg i "$3" --arg s "$4" --arg bg "${5:-}" --arg sp "${6:-}" '. + [{address: $a, name: "n-\($a)", pid: (length + 101),
      state: "live", cwd: $c, status: {state: $s}, labels: ({"bercail.role": "agent", "bercail.issue": $i, "bercail.issue_title": "Job \($i)"}
        + (if $bg == "bg" then {"bercail.shep": "bg"} else {} end) + (if $sp == "" then {} else {"bercail.space": $sp} end))}]' \
    "$HC_DATA/terminals.json" >"$HC_DATA/t.tmp" && mv "$HC_DATA/t.tmp" "$HC_DATA/terminals.json"
}

# What the query prints, run as the runner runs it: from HOME, nothing on stdin.
query() { (cd "$HOME" && bash "$ROOT/lib/routine/cleanup.sh" cleanup </dev/null); }
keys() {
  local out
  out="$(query)" || fail "the query failed: $out" || return
  jq -r .key <<<"$out" | sort | tr '\n' ' ' | sed 's/ $//'
}

# clock EPOCH: date +%s says EPOCH from now on.
clock() {
  printf '#!/bin/sh\n[ "$1" = "+%%s" ] && echo %s || exec %s "$@"\n' "$1" "$(PATH=/usr/bin:/bin command -v date)" \
    >"$BATS_TEST_TMPDIR/bin/date"
  chmod +x "$BATS_TEST_TMPDIR/bin/date"
}

# card TOPIC [ISSUE] [reversible]: a planning card on widgets; prints its token.
card() {
  jq -nc --arg repo "$MAIN" --arg t "$1" --arg i "${2:-}" --arg r "${3:-}" '{requestId: "r-\($t)", kind: "planning",
      prompt: "Which first for \($t)?", options: ["auth", "search"], origin: {event: "chat", session: "shep-1", entry: null},
      repo: $repo, issue: (if $i == "" then null else $i end), topic: $t, desk: null, base: null, action: null}
    + (if $r == "" then {} else {reversible: true, recommendation: {choice: "auth", why: "first"}} end)' \
    | "$ROOT/bin/bercail" shep question create | jq -r '"\(.id)@\(.revision)"'
}

# ledger [JQ ARGS...] FILTER: rewrite the question ledger with JQ.
ledger() {
  local file="$XDG_STATE_HOME/bercail/shep/questions.json"
  jq "$@" "$file" >"$file.tmp" && mv "$file.tmp" "$file"
}

@test "the cleanup routine finds nothing when nothing is left to retire or ask" {
  job w-1 open
  job w-2 in_progress
  worktree alpha w-1
  worktree bravo w-2
  desk d-alpha "$WORK/widgets.alpha" w-1 working
  desk d-bravo "$WORK/widgets.bravo" w-2 blocked
  card plan >/dev/null
  ledger '.selected = "plan"'
  jq -n '{spaces: [{id: "sp-alpha", name: "Alpha", folder: "'"$WORK/widgets.alpha"'", machine: null}]}' >"$HERDR"
  assert_eq "" "$(keys)" "a clean state has no findings"
  assert_eq '{}' "$(jq -c . "$SEEN")" "no desk is seen done"
}

@test "the cleanup routine finds a worktree on a closed job that cleanup --check passes, and leaves the rest" {
  local name
  for name in alpha bravo charlie delta echo foxtrot golf hotel india; do worktree "$name" "w-$name"; job "w-$name" closed; done
  job w-charlie open
  rm "$MAIN/.beads/fake/w-golf.json"
  # bravo has a commit on neither trunk nor the remote: cleanup refuses it.
  git -C "$WORK/widgets.bravo" commit -q --allow-empty -m local
  # delta's live desk is on another job; echo moved to another branch; foxtrot's desk works.
  desk d-delta "$WORK/widgets.delta" w-other idle
  git -C "$WORK/widgets.echo" switch -q -c echo-2
  desk d-foxtrot "$WORK/widgets.foxtrot" w-foxtrot working
  # hotel's space holds a working desk that sits in the main checkout: cleanup would end it.
  # india's folder has a space its handoff did not open, with an idle desk on another job.
  desk d-hotel "$MAIN" w-hotel working "" sp-hotel
  desk d-india "$MAIN" w-other idle "" sp-india-2
  jq -n --arg w "$WORK" '{spaces: [{id: "sp-hotel", name: "Hotel", folder: "\($w)/widgets.hotel", machine: null},
      {id: "sp-india-2", name: "India", folder: "\($w)/widgets.india", machine: null}]}' >"$HERDR"
  # alpha's own desk is done on its job, which does not hold it back.
  desk d-alpha "$WORK/widgets.alpha" w-alpha "done"
  local out
  out="$(query)" || fail "query: $out"
  assert_eq "cleanup:$WORK/widgets.alpha" "$(jq -r .key <<<"$out")" "only alpha is cleanup's"
  assert_eq "w-alpha: Job w-alpha is closed; bercail cleanup can retire its worktree" "$(jq -r .title <<<"$out")" "its title"
  assert_eq "$MAIN w-alpha" "$(jq -r '"\(.repo) \(.issue)"' <<<"$out")" "its repo and issue"
  [[ -d "$WORK/widgets.alpha" ]] || fail "the routine retires nothing itself"
}

@test "the cleanup routine finds a worktree on a closed job that still has staged changes" {
  worktree alpha w-1
  worktree bravo w-2
  job w-1 closed
  job w-2 open
  printf 'more\n' >>"$WORK/widgets.alpha/alpha.txt"
  printf 'more\n' >>"$WORK/widgets.bravo/bravo.txt"
  git -C "$WORK/widgets.alpha" add alpha.txt
  git -C "$WORK/widgets.bravo" add bravo.txt
  desk d-alpha "$WORK/widgets.alpha" w-1 blocked
  assert_eq "staged-closed:$WORK/widgets.alpha" "$(keys)" "only the closed job's staged worktree, its desk blocked"
  # An index git cannot read is not a staged change.
  local index out
  index="$(git -C "$WORK/widgets.alpha" rev-parse --path-format=absolute --git-path index)"
  if [[ "$(id -u)" != 0 ]]; then
    chmod 000 "$index"
    if out="$(query 2>&1)"; then fail "an unreadable index is a finding: $out"; fi
    chmod 600 "$index"
    [[ "$out" == *"error: git could not read the index of $WORK/widgets.alpha"* ]] || fail "the run names the index: $out"
    # A .git or a folder that cannot be read once the run found the worktree: still there, not gone.
    local what rc
    for what in "$WORK/widgets.alpha/.git" "$WORK/widgets.alpha"; do
      printf 'chmod 000 %q\n' "$what" >"$MAIN/.beads/fake/w-1.hook"
      rc=0
      out="$(query 2>&1)" || rc=$?
      chmod 700 "$what"
      ((rc != 0)) || fail "an unreadable $what is a gone worktree: $out"
      [[ "$out" == *"error: git could not read the index of $WORK/widgets.alpha"* ]] || fail "the run names the index: $out"
    done
    chmod 600 "$WORK/widgets.alpha/.git"
    rm "$MAIN/.beads/fake/w-1.hook"
  fi
  jq '(.[] | select(.address == "d-alpha") | .status.state) = "working"' "$HC_DATA/terminals.json" >"$HC_DATA/t.tmp"
  mv "$HC_DATA/t.tmp" "$HC_DATA/terminals.json"
  assert_eq "" "$(keys)" "a desk still working there, as the review queue counts it"
}

@test "the cleanup routine skips a worktree removed while it runs, and finds the rest" {
  job w-1 closed
  job w-2 open
  job w-3 closed
  worktree alpha w-1
  worktree bravo w-2
  worktree charlie w-3
  desk d-bravo "$WORK/widgets.bravo" w-2 "done"
  # The worktrees sit in a checkout of their own, with a change staged there.
  git_init "$WORK"
  printf 'notes\n' >"$WORK/notes.txt"
  git -C "$WORK" add notes.txt
  # Reading alpha's job, the routine meets a cleanup at work: alpha is half
  # removed, its .git gone, and bravo, read later as a done desk's worktree, is gone.
  printf 'rm %q\nrm -rf %q\n' "$WORK/widgets.alpha/.git" "$WORK/widgets.bravo" >"$MAIN/.beads/fake/w-1.hook"
  assert_eq "cleanup:$WORK/widgets.charlie" "$(keys)" "alpha and bravo are skipped, charlie still found"
  assert_eq '{}' "$(jq -c . "$SEEN")" "a desk on a gone worktree is not seen done"
}

@test "the cleanup routine finds a desk done on an open job with nothing staged once two runs a day apart saw it" {
  local day=1795392000 # 2026-11-23 00:00 UTC
  job w-1 open
  job w-2 open
  job w-3 open
  worktree alpha w-1
  worktree bravo w-2
  worktree charlie w-3
  desk d-alpha "$WORK/widgets.alpha" w-1 "done"
  # charlie's desk has staged changes left; delta's job closed.
  desk d-charlie "$WORK/widgets.charlie" w-3 idle
  printf 'more\n' >>"$WORK/widgets.charlie/charlie.txt"
  git -C "$WORK/widgets.charlie" add charlie.txt
  clock $((day + 1800))
  BERCAIL_ROUTINE_DRY_RUN=1 query >/dev/null
  [[ ! -e "$SEEN" ]] || fail "a dry run writes no seen-done.json"
  assert_eq "" "$(keys)" "first seen at 00:30"
  desk d-bravo "$WORK/widgets.bravo" w-2 "done"
  clock $((day + 27000))
  assert_eq "" "$(keys)" "alpha 7 hours on, bravo first seen at 07:30"
  clock $((day + 77400))
  assert_eq "" "$(keys)" "21:30: alpha is 21 hours on, but on the same day"
  clock $((day + 95400))
  assert_eq "done-desk:d-alpha" "$(keys)" "02:30 the next day: alpha is found; bravo is only 19 hours on"
  # Done, then idle once seen, is the same finish: same key, same text.
  jq '(.[] | select(.address == "d-alpha") | .status.state) = "idle"' "$HC_DATA/terminals.json" >"$HC_DATA/t.tmp"
  mv "$HC_DATA/t.tmp" "$HC_DATA/terminals.json"
  clock $((day + 113400))
  assert_eq "done-desk:d-alpha done-desk:d-bravo" "$(keys)" "07:30 the next day: both"
  assert_eq "w-1: Job w-1: desk d-alpha finished, with nothing staged" \
    "$(query | jq -r 'select(.key == "done-desk:d-alpha") | .title')" "its title holds no state or time"
  # bravo goes back to work: its clock starts over.
  jq '(.[] | select(.address == "d-bravo") | .status.state) = "working"' "$HC_DATA/terminals.json" >"$HC_DATA/t.tmp"
  mv "$HC_DATA/t.tmp" "$HC_DATA/terminals.json"
  query >/dev/null
  jq '(.[] | select(.address == "d-bravo") | .status.state) = "done"' "$HC_DATA/terminals.json" >"$HC_DATA/t.tmp"
  mv "$HC_DATA/t.tmp" "$HC_DATA/terminals.json"
  clock $((day + 200000))
  assert_eq "done-desk:d-alpha" "$(keys)" "bravo, seen done again, waits another day"
}

@test "the cleanup routine finds a background Shep that finished, not one working or blocked" {
  job w-1 open
  desk b-1 "$MAIN" w-1 "done" bg
  desk b-2 "$MAIN" w-2 idle bg
  desk b-3 "$MAIN" w-3 working bg
  desk b-4 "$MAIN" w-4 blocked bg
  assert_eq "bg-done:b-1 bg-done:b-2" "$(keys)" "the finished workers"
  assert_eq "background Shep n-b-1 (w-1: Job w-1) finished and is still live" \
    "$(query | jq -r 'select(.key == "bg-done:b-1") | .title')" "its title"
}

@test "the cleanup routine finds a space a handoff opened on a worktree now gone, and no other space" {
  worktree alpha w-1
  worktree bravo w-2
  git -C "$MAIN" worktree remove "$WORK/widgets.alpha"
  jq -n --arg w "$WORK" '{spaces: [
      {id: "sp-alpha", name: "Alpha", folder: "\($w)/widgets.alpha", machine: null},
      {id: "sp-bravo", name: "Bravo", folder: "\($w)/widgets.bravo", machine: null},
      {id: "sp-mine", name: "Notes", folder: "\($w)/notes", machine: null},
      {id: "laptop/sp-alpha", name: "Alpha", folder: "\($w)/widgets.alpha", machine: "laptop"}]}' >"$HERDR"
  assert_eq "space:sp-alpha" "$(keys)" "only the handoff's space on a gone worktree"
  rm "$HERDR"
  assert_eq "" "$(keys)" "with no window, no space is read"
}

@test "the cleanup routine finds old cards that no longer check out or defaulted unseen, and no other card" {
  local day=1795392000 stale new dflt ok
  job w-1 open
  stale="$(card stale w-1)" new="$(card new w-1)"
  card fresh w-1 >/dev/null
  dflt="$(card dflt "" reversible)" ok="$(card ok "" reversible)"
  # stale's head moved since it was asked; new is stale too, but asked today.
  ledger --arg s "${stale%@*}" --arg n "${new%@*}" '(.questions[] | select(.id == $s or .id == $n) | .target.head) = ("0" * 40)'
  # Each but new was asked 6 days ago, and dflt and ok defaulted 5 days ago; ok's default was OKed.
  ledger '(.questions[] | select(.target.topic != "new") | .createdAt) = "2026-11-17T00:00:00.000Z"
    | (.questions[] | select(.deadline) | .deadline) = "2026-11-18T00:00:00.000Z"'
  "$ROOT/bin/bercail" shep question expire >/dev/null
  ledger '(.questions[] | select(.answer) | .answer.at) = "2026-11-18T00:00:00.000Z"'
  jq -nc --arg t "$ok" '{requestId: "ok-1", token: $t, outcome: "ok", source: "panel picker"}' \
    | "$ROOT/bin/bercail" shep question answer >/dev/null
  clock $((day + 3600))
  assert_eq "card:$stale card:$dflt" "$(keys)" "the stale card and the unseen default, both over 3 days"
  assert_eq "$stale (planning) no longer checks out, and was asked over 3 days ago: Which first for stale?" \
    "$(query | jq -r --arg k "card:$stale" 'select(.key == $k) | .title')" "the stale card's title"
  assert_eq "$dflt (planning) defaulted to \"auth\" over 3 days ago, and nobody said OK: Which first for dflt?" \
    "$(query | jq -r --arg k "card:$dflt" 'select(.key == $k) | .title')" "the default's title"
}

@test "the cleanup routine finds a Discuss terminal on a settled card, and Shep's thread topic with no card waiting" {
  local waits settled
  waits="$(card waits)" settled="$(card settled)"
  jq -nc --arg t "$settled" '{requestId: "a-1", token: $t, choice: "auth", source: "panel picker"}' \
    | "$ROOT/bin/bercail" shep question answer >/dev/null
  jq --arg o "$waits" --arg d "$settled" '. + [
      {address: "q-open", state: "live", labels: {"bercail.role": "shep-discuss", "bercail.question": $o}},
      {address: "q-done", state: "live", labels: {"bercail.role": "shep-discuss", "bercail.question": $d}},
      {address: "q-gone", state: "live", labels: {"bercail.role": "shep-discuss", "bercail.question": "Q99@1"}}]' \
    "$HC_DATA/terminals.json" >"$HC_DATA/t.tmp" && mv "$HC_DATA/t.tmp" "$HC_DATA/terminals.json"
  ledger '.selected = "settled"'
  assert_eq "discuss:q-done thread:settled" "$(keys)" "the settled card's terminal and its topic"
  assert_eq "Discuss terminal q-done is open on $settled, whose card is answered" \
    "$(query | jq -r 'select(.key == "discuss:q-done") | .title')" "the terminal's title"
  ledger '.selected = "waits"'
  assert_eq "discuss:q-done" "$(keys)" "a topic with a card waiting"
}

@test "the cleanup routine fails when a source fails, so the next good run sends nothing again" {
  local out
  desk b-1 "$MAIN" w-1 "done" bg
  out="$("$ROOT/bin/bercail" routine run cleanup --dry-run)" || fail "dry run: $out"
  assert_eq "cleanup: emitted, 1 found (1 new, 0 changed); dry run, nothing written" "$(head -n 1 <<<"$out")" "a dry run's line"
  assert_eq "  new      bg-done:b-1  background Shep n-b-1 (w-1: Job w-1) finished and is still live" "$(sed -n 2p <<<"$out")" \
    "a dry run prints what it found"
  [[ ! -e "$SEEN" ]] || fail "a dry run writes no seen-done.json"
  out="$("$ROOT/bin/bercail" routine run cleanup)" || fail "run: $out"
  [[ "$out" == *"emitted, 1 found (1 new, 0 changed)"* ]] || fail "the first run sends it: $out"
  local fails
  for fails in "ls --json --label bercail.role=agent" "ls --json --label bercail.role=shep-discuss"; do
    if out="$(HC_FAIL="$fails" "$ROOT/bin/bercail" routine run cleanup)"; then fail "a run whose source failed is quiet: $out"; fi
    [[ "$out" == *"failed: exit 1: error: hc did not list the"* ]] || fail "the run names the source: $out"
  done
  out="$("$ROOT/bin/bercail" routine run cleanup)" || fail "run: $out"
  [[ "$out" == *"skipped (quiet), 1 found, nothing new or changed"* ]] || fail "the finding is not sent again: $out"
  # hc could not say which space is on the worktree: not a refusal.
  worktree alpha w-1
  job w-1 closed
  if out="$(HC_FAIL="ls --json" query 2>&1)"; then fail "a --check that could not read hc is quiet: $out"; fi
  [[ "$out" == *"error: could not tell which Herdr space is on $WORK/widgets.alpha: hc did not answer in full"* ]] \
    || fail "the run names what it could not read: $out"
  # cleanup --check could not list the terminals of the worktree's space: not a refusal either.
  jq -n --arg f "$WORK/widgets.alpha" '{spaces: [{id: "sp-alpha", name: "Alpha", folder: $f, machine: null}]}' >"$HERDR"
  if out="$(HC_FAIL="ls --json" query 2>&1)"; then fail "a --check that could not read hc is quiet: $out"; fi
  [[ "$out" == *"error: cleanup --check $WORK/widgets.alpha could not read what it needs: hc did not list its terminals"* ]] \
    || fail "the run names what --check could not read: $out"
}

@test "the cleanup routine waits out a slow bd, and fails a run whose bd lookup is killed, so the next good run sends nothing again" {
  local out rc
  worktree alpha w-1
  job w-1 closed
  # bd under load: 5 seconds a show, past the bound of Shep's other reads.
  printf 'sleep 5\n' >"$MAIN/.beads/fake/w-1.hook"
  out="$("$ROOT/bin/bercail" routine run cleanup)" || fail "run: $out"
  [[ "$out" == *"emitted, 1 found (1 new, 0 changed)"* ]] || fail "a slow bd still finds the closed job: $out"
  # Out of time (the bound's 124), or killed: the job is unknown, not open.
  for rc in 124 137; do
    printf 'exit %s\n' "$rc" >"$MAIN/.beads/fake/w-1.hook"
    if out="$("$ROOT/bin/bercail" routine run cleanup)"; then fail "a run whose lookup was cut short is quiet: $out"; fi
    [[ "$out" == *"failed: exit 1: error: the lookup of w-1 in $MAIN was killed or ran out of time (status $rc)"* ]] \
      || fail "the run names the lookup: $out"
  done
  rm "$MAIN/.beads/fake/w-1.hook"
  out="$("$ROOT/bin/bercail" routine run cleanup)" || fail "run: $out"
  [[ "$out" == *"skipped (quiet), 1 found, nothing new or changed"* ]] || fail "the finding is not sent again: $out"
}

@test "the cleanup routine checks an old review card without touching its worktree's index or objects" {
  local day=1795392000 token index before
  job w-1 open
  worktree alpha w-1
  token="$(jq -nc --arg repo "$WORK/widgets.alpha" '{requestId: "r-review", kind: "review", prompt: "LGTM alpha?",
      options: ["LGTM", "Not yet"], origin: {event: "chat", session: "shep-1", entry: null}, repo: $repo, issue: "w-1",
      topic: "review-alpha", desk: null, base: "master", action: "review"}' \
    | "$ROOT/bin/bercail" shep question create | jq -r '"\(.id)@\(.revision)"')"
  [[ "$token" == Q1@1 ]] || fail "no review card: $token"
  ledger '.questions[0].createdAt = "2026-11-17T00:00:00.000Z"'
  # A change staged since: the card's check reads a new staged tree.
  printf 'more\n' >>"$WORK/widgets.alpha/alpha.txt"
  git -C "$WORK/widgets.alpha" add alpha.txt
  index="$(git -C "$WORK/widgets.alpha" rev-parse --path-format=absolute --git-path index)"
  before="$(sha256sum <"$index") $(git -C "$MAIN" count-objects -v | grep -E '^(count|in-pack):')"
  clock $((day + 3600))
  assert_eq "card:Q1@1" "$(BERCAIL_ROUTINE_DRY_RUN=1 keys)" "the review card no longer checks out"
  assert_eq "$before" "$(sha256sum <"$index") $(git -C "$MAIN" count-objects -v | grep -E '^(count|in-pack):')" \
    "the check left the worktree's index and the repo's objects as they were"
  # A colon in the repo's path: git reads its objects folder as one alternate, not two.
  git_init "$WORK/with:colon"
  mkdir -p "$WORK/with:colon/.beads/fake"
  cp "$MAIN/.beads/fake/w-1.json" "$WORK/with:colon/.beads/fake/"
  printf 'more\n' >>"$WORK/with:colon/file.txt"
  git -C "$WORK/with:colon" add file.txt
  jq -nc --arg repo "$WORK/with:colon" '{requestId: "r-colon", kind: "review", prompt: "LGTM?", options: ["LGTM", "Not yet"],
      origin: {event: "chat", session: "shep-1", entry: null}, repo: $repo, issue: "w-1", topic: "colon", desk: null,
      base: "HEAD", action: "review"}' | "$ROOT/bin/bercail" shep question create >/dev/null \
    || fail "a review card on a repo whose path has a colon"
}
