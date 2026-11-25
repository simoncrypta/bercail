#!/usr/bin/env bats
# The rules routine (lib/routine/rules.sh): which standing rules it finds from
# a scratch preferences.md, run as bercail routine run runs it. A stand-in for
# hc and for the clock; the real runner, and the real question CLI reading a
# scratch ledger. Each @test is its own HOME.

DAY=1795478400 # 2026-11-24 00:00 UTC

setup() {
  load test_helper
  isolate
  need jq flock sha256sum node
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH" TZ=UTC
  export HC_BIN="$BATS_TEST_TMPDIR/bin/hc" HC_DESKS="$BATS_TEST_TMPDIR/desks"
  unset HC_TERMINAL_ID HC_FAIL
  STATE="$XDG_STATE_HOME/bercail/shep" RUNS="$XDG_STATE_HOME/bercail/routines/rules/runs.jsonl"
  PREFS="$STATE/preferences.md" WANT=""
  mkdir -p "$STATE/inbox" "$XDG_CONFIG_HOME/bercail"
  printf '[routine.rules]\nrun = "rules"\nat = "07:45"\n' >"$XDG_CONFIG_HOME/bercail/config.toml"
  # hc: ls --json, and nothing else, lists the addresses in $HC_DESKS, one a
  # line. $HC_FAIL: it fails, or as "shape" prints something else.
  cat >"$HC_BIN" <<'SH'
#!/usr/bin/env bash
[[ "$*" == "ls --json" ]] || exit 2
case "${HC_FAIL:-}" in
  "") jq -Rn '{terminals: [inputs | {address: ., state: "live"}]}' "$HC_DESKS" ;;
  shape) echo '[]' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$HC_BIN"
  : >"$HC_DESKS"
  clock $((DAY + 36000))
}

# clock EPOCH: date +%s says EPOCH from now on.
clock() {
  printf '#!/bin/sh\n[ "$1" = "+%%s" ] && echo %s || exec %s "$@"\n' "$1" "$(PATH=/usr/bin:/bin command -v date)" \
    >"$BATS_TEST_TMPDIR/bin/date"
  chmod +x "$BATS_TEST_TMPDIR/bin/date"
}

# rule LINE: a standing rule, "DATE [SCOPE] RULE", as bercail shep remember writes it.
rule() {
  [[ -f "$PREFS" ]] || printf '# Standing rules the person gave Shep.\n\n' >"$PREFS"
  printf -- '- %s\n' "$1" >>"$PREFS"
}

# found TITLE LINE: a rule the next run must find, new, for TITLE.
found() {
  rule "$2"
  WANT+="  new      rules:$(printf '%s' "$2" | sha256sum | cut -c1-12)  $1"$'\n'"           $2"$'\n'
}

routine() { "$ROOT/bin/bercail" routine "$@"; }
# What the last run found, as bercail routine show prints it.
shown() { routine show rules --run "$(tail -n 1 "$RUNS" | jq -r .id)" | tail -n +2; }
# The first run finds the rules given to found, and no other.
finds_them() {
  local out
  out="$(routine run rules)" || fail "run: $out" || return
  [[ "$out" == "rules: emitted, "* ]] || fail "the run: $out" || return
  [[ "$(shown)" == "${WANT%$'\n'}" ]] || fail "expected:"$'\n'"$WANT"$'\n'"got:"$'\n'"$(shown)"
}
# What the query prints, run as the runner runs it: from HOME, nothing on stdin.
query() { (cd "$HOME" && bash "$ROOT/lib/routine/rules.sh" rules </dev/null); }

# A scratch ledger, as the question store keeps it, of four cards on one repo:
# Q1@1, a push the guard claimed on 2026-11-16; Q2@1, the same push, which
# nobody answered; Q3@1, a guard card whose Allow its worker claimed on
# 2026-11-17; and Q4@1, a land card whose chain its worker claimed on 2026-11-18.
cards() {
  jq -n '("a" * 40) as $sha | ("b" * 64) as $hash
    | def card($n; $kind; $options; $target): {id: "Q\($n)", revision: 1, status: "pending", createdAt: "2026-11-15T08:00:00.000Z",
          proposals: [], kind: $kind, prompt: "Card \($n)?", options: $options, origin: {event: "chat", session: "shep-1", entry: null},
          target: ({repo: "/srv/app", issue: null, topic: "card-\($n)", worktree: null, desk: null, space: null, session: null,
            action: null, head: null, stagedTree: null, base: null, baseRef: null} + $target)};
      def picked($at): . + {status: "answered",
          answer: {requestId: "pick-\(.id)", choice: .options[0], source: "panel picker", at: $at, head: null, stagedTree: null}};
      def push($n): card($n; "review"; ["Push it", "Not yet"]; {issue: "app-1", worktree: "/srv/app", action: "stage-only review",
            head: $sha, stagedTree: $sha, base: $sha, baseRef: "master"})
          + {push: {approves: "Push it", remote: "origin", refs: ["refs/heads/master"], url: "/srv/origin.git"}};
      {version: 1, selected: null, requests: [], questions: [
        (push(1) | picked("2026-11-16T09:00:00.000Z")
          + {pushed: {at: "2026-11-16T09:30:00.000Z", remote: "origin", refspecs: ["\($sha):refs/heads/master"]}}),
        push(2),
        (card(3; "guard"; ["Allow", "Deny"]; {})
          + {guard: {ticket: "0123456789ab", worker: "guard-ask-0123456789ab", op: {kind: "push"}, facts: {},
              expires: "2026-11-17T09:00:00.000Z"}}
          | picked("2026-11-17T07:59:00.000Z") + {guardClaim: {at: "2026-11-17T08:00:00.000Z"}}),
        (card(4; "land"; ["Ship it", "Not yet"]; {issue: "app-2", worktree: "/srv/app.importer", desk: "t1d7", space: "sp1",
            session: "s1", action: "land", head: $sha, stagedTree: $sha, base: $sha, baseRef: "master", branch: "refs/heads/importer"})
          + {land: {url: "/srv/origin.git", github: "acme/app", ciRef: "refs/heads/bercail-land/importer/0123456789ab",
              policyTrust: null, registered: true, clean: true, handoffBranch: "importer", description: {tree: $sha, message: $hash},
              policy: {file: $hash, trusted: true, hash: $hash}, requiredCi: [{path: ".github/workflows/ci.yml", id: 1}],
              bercail: "/usr/bin/bercail", review: {required: false, highStakes: []}, reviewer: null}}
          | picked("2026-11-18T10:00:00.000Z") + {landing: {starts: [], claim: {at: "2026-11-18T10:01:00.000Z"}, steps: []}})]}' \
    >"$STATE/questions.json"
  # The real question CLI reads it: four cards, three of them claimed.
  [[ "$("$ROOT/bin/bercail" shep question json | jq -c '[.questions[] | (.pushed // .guardClaim // .landing.claim | .at[:10])]')" \
    == '["2026-11-16",null,"2026-11-17","2026-11-18"]' ]] || fail "the scratch ledger does not read as four cards"
}

@test "the rules routine finds a rule for a day or night now past, a night only from noon the next day, and none for a bare date" {
  local out
  clock $((DAY + 43140)) # 11:59
  found "For the night of 2026-11-22, now past" "2026-11-22 [all] Night of 2026-11-22/23: Shep may land reviewed jobs without asking."
  found "For the night of 2026-11-21, now past" "2026-11-21 [app] 2026-11-21 night: keep every builder on Opus."
  found "For 2026-11-14, now past" "2026-11-14 [app] On 2026-11-14, Shep may restart the staging box."
  found "For 2026-11-23, now past" "2026-11-23 [all] 2026-11-23: Work through the review queue before any new job."
  # No date in the rule: tonight and today are the day it was remembered.
  found "For the night of 2026-11-22, now past" "2026-11-22 [all] Simon is going to sleep: tonight, answer reversible cards without him."
  found "For 2026-11-23, now past" "2026-11-23 [all] No release for today."
  found "For 2026-11-22, now past" "2026-11-22 [app] Today only: the importer may run without its smoke checks."
  found "For 2026-11-21, now past" "2026-11-21 [all] Just today, answer the kvm cards for Simon."
  # Remembered after midnight: the night it names counts, not tonight from its date.
  found "For the night of 2026-11-22, now past" "2026-11-23 [all] Night of 2026-11-22: Simon is going to sleep, answer guard cards with Deny."
  # Last night ends at noon, and today is not over.
  rule "2026-11-23 [all] Night of 2026-11-23: leave the kvm repo alone."
  rule "2026-11-24 [all] Hold every push to kvm, for today."
  # It starts that day: it is not for that day only.
  rule "2026-11-23 [all] Starting today, never push master without a review."
  # One of its two nights is still ahead.
  rule "2026-11-20 [all] Night of 2026-11-22 and night of 2026-11-30: no deploys."
  # A date that says when, not until when; one in a branch name; one that is no
  # date; and a line that is no rule.
  rule "2026-11-23 [all] The GLKVM is back online (2026-11-23), so its jobs may run."
  rule "2026-11-23 [all] Release plans (2026-11-23): ship kvm on Fridays only."
  rule "2026-11-14 [app] Drills run on branch rwx-drill-2026-11-14."
  rule "2026-11-20 [all] On 2026-13-45, a date that is none, nothing is due."
  rule "Tonight only, a line with no date or scope."
  finds_them
  clock $((DAY + 43200)) # 12:00
  out="$(routine run rules)" || fail "run: $out"
  [[ "$out" == "rules: emitted, 10 found (1 new, 0 changed); run "* ]] || fail "the run at noon: $out"
  [[ "$(shown)" == *"new      rules:"*"  For the night of 2026-11-23, now past"$'\n'"           2026-11-23 [all] Night of 2026-11-23: leave the kvm repo alone."* ]] \
    || fail "last night, at noon: $(shown)"
}

@test "the rules routine finds a rule for desks hc no longer has, and none while hc has one of them" {
  printf 't1aa\nt2wr\nvps/t9aa\n' >"$HC_DESKS"
  rule "2026-11-20 [t1aa] Answer its guard cards with Allow."
  found "For desk t9zz, which hc no longer has" "2026-11-20 [t9zz] Stage nothing until the judge has replied."
  found "For desk t1d7, which hc no longer has" "2026-11-20 [app] On desk t1d7 (the importer), never restart the worker."
  rule "2026-11-20 [app] On Lesentiel desks t2wp, t2wr, t2wv and t2wx, skip the describe step."
  found "For desks t3aa, t3ab and t3ac, which hc no longer has" "2026-11-20 [all] On desks t3aa, t3ab and t3ac, the builder runs on Opus."
  # A desk on another machine, which hc lists under its whole address.
  rule "2026-11-20 [app] On desk vps/t9aa, never restart the database."
  # One gone here, one on another machine that may be live.
  rule "2026-11-20 [app] On desks t1d7 and vps/t9aa, do not restart the worker."
  # t4zz is not said to be a desk, and this desk rule names none.
  rule "2026-11-20 [app] Build t4zz first, then the importer."
  rule "2026-11-20 [all] A done desk waits for review before its worktree goes."
  finds_them
}

@test "the rules routine finds a one-use rule whose card was claimed, and none for a card unclaimed, of another revision, or a condition" {
  cards
  found "Names Q1@1, a once-only permission used on 2026-11-16" "2026-11-16 [app] Shep may push master once on Q1@1 without asking again."
  found "Names Q1@1, a once-only permission used on 2026-11-16" "2026-11-16 [all] Skip the judge once, for q1."
  found "Names Q1@1, a once-only permission used on 2026-11-16" "2026-11-16 [app] Q1@1 permits a single push."
  found "Names Q3@1, a once-only permission used on 2026-11-17" "2026-11-17 [app] The Allow on Q3@1 was single-use, for the tag."
  found "Names Q4@1, a once-only permission used on 2026-11-18" "2026-11-18 [app] Q4@1 is a one-time go-ahead to land the importer."
  found "Names Q4@1, a once-only permission used on 2026-11-18" "2026-11-18 [all] Ship the importer one time, on Q4@1."
  # The claim is its condition, not its one use.
  rule "2026-11-16 [app] Once Q1@1 is claimed, deny every subsequent push."
  rule "2026-11-16 [app] Rebuild the site once, when Q2@1 is answered."
  rule "2026-11-16 [app] Q1@2 allows one more push, once."
  rule "2026-11-16 [app] Q1@1 settled how master is pushed."
  rule "2026-11-16 [all] Run the migration once for Q9@1."
  rule "2026-11-20 [all] Once every open job is done, tidy the worktrees."
  finds_them
}

@test "the rules routine names the later rule of the same or wider scope that says the same or shares most of a rule's words, the one sharing the most" {
  local all="2026-11-18 [all] Always run the unit tests and the lint before staging any change."
  found "May be covered by a later rule of the same or wider scope: $all" "2026-11-10 [app] Always run the unit tests before staging a change."
  # Its later rule is narrower, or for another repo.
  rule "2026-11-12 [all] Never restart the database during business hours."
  rule "2026-11-12 [app] Keep the changelog entry short and in the past tense."
  # Its later rule is itself for a day now past.
  rule "2026-11-13 [app] Restart the staging box after lunch on Fridays."
  found "For 2026-11-14, now past" "2026-11-14 [app] On 2026-11-14, restart the staging box after lunch."
  # Four words shared of nine, and three of three: too few.
  rule "2026-11-15 [app] Deploy the worker from master after the smoke checks pass on staging and production."
  rule "2026-11-15 [app] Squash merge commits."
  # Only filler words, numbers, and words under three letters shared.
  rule "2026-11-15 [app] Shep should not land this for Simon."
  rule "2026-11-15 [app] Ports 8080, 8081, 8082 and 8083 stay closed."
  rule "2026-11-15 [app] If CI is red, do not go on to QA."
  # It says the same as a later rule of all, in three words.
  found "May be covered by a later rule of the same or wider scope: 2026-11-21 [all] never push tags" "2026-11-15 [app] Never push tags."
  # It shares five of the first rule's seven words, and the [all] one all seven.
  rule "2026-11-16 [app] Run the unit tests before staging, then time them, log failures and page nobody."
  rule "$all"
  rule "2026-11-19 [app] Never restart the database during business hours or a deploy."
  rule "2026-11-20 [kvm] Keep the changelog entry short and in the past tense."
  rule "2026-11-21 [app] Deploy the worker from master after lunch."
  rule "2026-11-21 [all] Squash merge commits on master."
  rule "2026-11-21 [all] never push tags"
  rule "2026-11-21 [all] Shep should not push that for Simon."
  rule "2026-11-21 [all] Ports 8080, 8081, 8082 and 8083 are the proxy's."
  rule "2026-11-21 [all] If CI is up, do not go on to PR."
  finds_them
}

@test "the rules routine names a covering rule that stays, never one it finds covered itself" {
  local last="2026-11-18 [all] Always encrypt private database backups and archives."
  found "May be covered by a later rule of the same or wider scope: $last" "2026-11-10 [app] Always encrypt private database backups."
  found "May be covered by a later rule of the same or wider scope: $last" "2026-11-12 [all] Always encrypt private database backups."
  rule "$last"
  finds_them
}

@test "the rules routine names each reason a rule has, in order" {
  local later="2026-11-20 [all] Any desk may skip the describe step and the judge."
  found "For 2026-11-19, now past; for desk t9zz, which hc no longer has; may be covered by a later rule of the same or wider scope: $later" \
    "2026-11-19 [t9zz] On 2026-11-19, this desk may skip the describe step and the judge."
  rule "$later"
  finds_them
}

@test "the rules routine finds a line that is there twice once" {
  found "For the night of 2026-11-22, now past" "2026-11-22 [all] Night of 2026-11-22: no deploys."
  rule "2026-11-22 [all] Night of 2026-11-22: no deploys."
  finds_them
}

@test "the rules routine is quiet about a rule it found before, also once an earlier rule is forgotten and the numbers shift" {
  local out
  rule "2026-11-20 [all] Never push a tag without asking."
  found "For 2026-11-14, now past" "2026-11-14 [app] On 2026-11-14, Shep may restart the staging box."
  found "For desk t9zz, which hc no longer has" "2026-11-20 [t9zz] Stage nothing until the judge has replied."
  finds_them
  out="$(routine run rules)" || fail "run: $out"
  [[ "$out" == "rules: skipped (quiet), 2 found, nothing new or changed; run "* ]] || fail "a second run: $out"
  out="$("$ROOT/bin/bercail" shep forget 1)" || fail "forget: $out"
  [[ "$out" == "forgot: 2026-11-20 [all] Never push a tag without asking." ]] || fail "forget 1: $out"
  out="$(routine run rules)" || fail "run: $out"
  [[ "$out" == "rules: skipped (quiet), 2 found, nothing new or changed; run "* ]] || fail "the run after forget 1: $out"
}

@test "the rules routine fails when hc fails or lists no terminals, so the next good run sends nothing again" {
  local out
  found "For desk t9zz, which hc no longer has" "2026-11-20 [t9zz] Stage nothing until the judge has replied."
  finds_them
  if out="$(HC_FAIL=1 routine run rules)"; then fail "a run whose hc failed passed: $out"; fi
  [[ "$out" == "rules: failed: exit 1: error: hc did not list its terminals (hc ls --json)"* ]] || fail "hc failing: $out"
  if out="$(HC_FAIL=shape routine run rules)"; then fail "a run whose hc listed no terminals passed: $out"; fi
  [[ "$out" == "rules: failed: exit 1: error: hc did not list its terminals (hc ls --json)"* ]] || fail "hc printing something else: $out"
  out="$(routine run rules)" || fail "run: $out"
  [[ "$out" == "rules: skipped (quiet), 1 found, nothing new or changed; run "* ]] || fail "the next good run: $out"
}

@test "the rules routine fails when preferences.md cannot be read, so the next good run sends nothing again" {
  local out
  [[ $EUID -ne 0 ]] || skip "root reads a file of mode 000"
  found "For desk t9zz, which hc no longer has" "2026-11-20 [t9zz] Stage nothing until the judge has replied."
  finds_them
  chmod 000 "$PREFS"
  if out="$(routine run rules)"; then fail "a run that could not read preferences.md passed: $out"; fi
  [[ "$out" == "rules: failed: exit 1: error: could not read $PREFS; run "* ]] || fail "an unreadable preferences.md: $out"
  chmod 600 "$PREFS"
  out="$(routine run rules)" || fail "run: $out"
  [[ "$out" == "rules: skipped (quiet), 1 found, nothing new or changed; run "* ]] || fail "the next good run: $out"
}

@test "the rules routine fails when the question ledger cannot be read" {
  local out
  rule "2026-11-20 [all] Never push a tag without asking."
  printf 'not a ledger\n' >"$STATE/questions.json"
  if out="$(routine run rules)"; then fail "a run with an unreadable ledger passed: $out"; fi
  [[ "$out" == "rules: failed: exit 1: error: the question ledger could not be read (bercail shep questions --json --all)"* ]] \
    || fail "an unreadable ledger: $out"
}

@test "the rules routine finds nothing with no preferences.md" {
  local out
  out="$(routine run rules)" || fail "run: $out"
  [[ "$out" == "rules: skipped (quiet), 0 found, nothing new or changed; run "* ]] || fail "no preferences.md: $out"
  out="$(query)" || fail "query: $out"
  [[ -z "$out" ]] || fail "the query printed: $out"
}
