---------------------------- MODULE GuardCard ----------------------------
(* One guard ask in Shep's session, as guard.ts, bstack/pi/guard-ask.ts and
   the ledger (shep/pi/questions.ts) have them with bercail-mdfb. Where the
   repo's trusted policy lists the operation in shep_may_run and it reads
   private, the guard runs it at once, with no card: the argv a card's worker
   would run, put in place of Shep's words, so what it checked is what runs.
   Otherwise one guard card and its worker: a card nobody answers by its
   deadline counts as an Allow when what it runs is private or local, and as
   a Deny otherwise. Written before the code, from the plan in
   docs/plans/guard-default-allow.md; tests/guard_ask.bats and
   tests/pi_guard_ask.test.ts run each step on the code.

   The worker reads the operation's class (guardDefault in guard.ts: the
   remote's visibility and the repo's policy) and puts the card up saying
   "defaults to Allow at HH:MM" or "waits for you". Then it polls the
   ledger. Before the deadline the person may Allow, Deny or Close it, and
   a fact that moves withdraws it. At the deadline, a card that said it
   defaults reads the class and the facts again: still private or local and
   unchanged, the ledger records the default (only on a pending card, only
   past the deadline); else the card is withdrawn as expired, a Deny. An
   Allow or a default is claimed once, then the worker checks the facts,
   and on a default the class, a last time, and runs the command once.

   The world: the deadline passes once, with the machine awake or asleep
   (asleep, no poll saw the card in its last minutes; the card may also go up
   only after it); the class may flip any number of
   times up to MaxFlips (a repo made public, merge_reversible turned off, a
   visibility read that fails counts as "waits"); the facts may move once.
   The worker may crash at any point; v1 starts no second worker, and hc
   names are unique, so there is one per ticket.

   Left out: what the class is made of (tests/pi_guard.test.ts has each
   row), the guard's own decideLive and the ticket's bytes before the run
   (they refuse or report changed, like a moved fact), the run's exit code
   and a run killed mid-way (outcome unknown), the event's file (one per
   ticket, written whole), and the gap between the last check and the run,
   which the code cannot close either: the rules speak of what the last
   check saw.

   Planted bugs, each off in the real configs: BugNoDeadlineCheck, the
   default trusts the class read when the card went up; BugUpgrade, a card
   that said "waits for you" defaults when the class now says private;
   BugDefaultOverAnswer, the ledger records a default over the person's
   answer; BugEarlyDefault, the ledger records a default before the
   deadline; BugNoLastCheck, the worker runs a claimed default without
   checking the class again; BugUnwatched, a card that went up late, or whose
   machine slept through its deadline, defaults; BugOptInPublic, a repo that
   opts in runs it with no card though it reads public. *)
EXTENDS Naturals

CONSTANTS MaxFlips, CanCrash,
          BugNoDeadlineCheck, BugUpgrade, BugDefaultOverAnswer, BugEarlyDefault, BugNoLastCheck, BugUnwatched,
          BugOptInPublic

Classes == {"defaults", "waits"}

VARIABLES
  optIn,      \* the repo's trusted policy lists the operation in shep_may_run
  world,      \* the class right now: "defaults" (private or local) or "waits"
  flips,      \* how many times it flipped
  moved,      \* a pinned fact moved
  past,       \* the deadline passed
  said,       \* what the card says: "defaults", "waits", or "none" before it is up
  status,     \* the ledger: "none", "pending", "answered", "withdrawn"
  answer,     \* the ledger's answer: "none", "allow", "deny", "default"
  yours,      \* the person's pick, as they made it: "none", "allow", "deny"
  pc,         \* the guard, then the worker: "guard", "classify", "create", "waiting", "deadline", "claim", "check", "run", "done", "dead"
  seen,       \* the class the worker acts on: "none", "defaults", "waits"
  seenMoved,  \* whether the facts had moved at the worker's last read
  atDeadline, \* what the class was when the worker read it at the deadline
  atLast,     \* what it was at the last check before the run
  atGuard,    \* what it was when the guard decided, in Shep's session
  raced,      \* the worker went to its deadline step on a read the person's pick had made stale
  watched,    \* the worker saw the card pending, awake, in the last minutes before its deadline
  claimed,    \* the ledger's one claim
  runs,       \* times the command ran
  event       \* the guard event: "none", "ran", "ran-default", "denied", "expired", "withdrawn", "changed"

env == <<optIn, world, flips, moved, past>>
card == <<said, status, answer, yours>>
work == <<pc, seen, seenMoved, atDeadline, atLast, atGuard, raced, watched, claimed, runs, event>>
vars == <<env, card, work>>

Init ==
  /\ optIn \in BOOLEAN /\ world \in Classes /\ flips = 0 /\ moved = FALSE /\ past = FALSE
  /\ said = "none" /\ status = "none" /\ answer = "none" /\ yours = "none"
  /\ pc = "guard" /\ atGuard = "none" /\ seen = "none" /\ seenMoved = FALSE /\ atDeadline = "none" /\ atLast = "none" /\ raced = FALSE /\ watched = FALSE
  /\ claimed = FALSE /\ runs = 0 /\ event = "none"

(* The world. *)
Tick == ~past /\ past' = TRUE /\ UNCHANGED <<optIn, world, flips, moved, card, work>>
\* The machine sleeps through the deadline: no poll saw the card in its last minutes.
\* Or, past the deadline, the worker is late to act (it slept after its last poll).
Doze == ~past /\ past' = TRUE /\ watched' = FALSE
        /\ UNCHANGED <<optIn, world, flips, moved, card, pc, seen, seenMoved, atDeadline, atLast, atGuard, raced, claimed, runs, event>>
Flip == /\ flips < MaxFlips
        /\ world' = (IF world = "defaults" THEN "waits" ELSE "defaults")
        /\ flips' = flips + 1
        /\ UNCHANGED <<optIn, moved, past, card, work>>
Lag == past /\ watched /\ pc \in {"waiting", "deadline"} /\ watched' = FALSE
       /\ UNCHANGED <<optIn, world, flips, moved, past, card, pc, seen, seenMoved, atDeadline, atLast, atGuard, raced, claimed, runs, event>>
Move == ~moved /\ moved' = TRUE /\ UNCHANGED <<optIn, world, flips, past, card, work>>

(* The person, on the panel. An Allow only on a pending card that checks
   fresh, before its deadline (QuestionStore.answer refuses a guard card's
   Allow past it). A Deny grants nothing, so it takes no live check and
   stands on any pending card, past the deadline too. Close takes any
   pending card off the panel. *)
Pick(c) == /\ status = "pending" /\ (c = "deny" \/ (~past /\ ~moved))
           /\ status' = "answered" /\ answer' = c /\ yours' = c
           /\ UNCHANGED <<env, said, work>>
YouAllow == Pick("allow")
YouDeny == Pick("deny")
YouClose == status = "pending" /\ status' = "withdrawn" /\ UNCHANGED <<env, said, answer, yours, work>>

(* The guard, in Shep's session: a repo that opts in, and reads private,
   runs it now with no card; anything else goes to a card and its worker. *)
GuardDecides == /\ pc = "guard" /\ atGuard' = world
                /\ IF optIn /\ (world = "defaults" \/ BugOptInPublic)
                     THEN runs' = runs + 1 /\ pc' = "done" /\ event' = "ran-optin"
                     ELSE pc' = "classify" /\ UNCHANGED <<runs, event>>
                /\ UNCHANGED <<env, card, seen, seenMoved, atDeadline, atLast, raced, watched, claimed>>

(* The worker. It reads the class, then puts the card up saying it. *)
Classify == pc = "classify" /\ said' = world /\ pc' = "create"
            /\ UNCHANGED <<env, status, answer, yours, seen, seenMoved, atDeadline, atLast, atGuard, raced, watched, claimed, runs, event>>
CardUp == pc = "create" /\ status' = "pending" /\ pc' = "waiting"
          /\ UNCHANGED <<env, said, answer, yours, seen, seenMoved, atDeadline, atLast, atGuard, raced, watched, claimed, runs, event>>

\* Each poll of the ledger, and of the facts while the card waits. A poll of a
\* pending card before the deadline is the worker watching it.
Watch == pc = "waiting" /\ status = "pending" /\ ~past /\ ~watched /\ watched' = TRUE
         /\ UNCHANGED <<env, card, pc, seen, seenMoved, atDeadline, atLast, atGuard, raced, claimed, runs, event>>
Stop(e) == pc' = "done" /\ event' = e
Keep == UNCHANGED <<seen, seenMoved, atDeadline, atLast, atGuard, raced, watched, claimed, runs>>
SeesWithdrawn == pc = "waiting" /\ status = "withdrawn" /\ Stop("withdrawn") /\ Keep /\ UNCHANGED <<env, card>>
SeesDeny == pc = "waiting" /\ status = "answered" /\ answer = "deny" /\ Stop("denied") /\ Keep /\ UNCHANGED <<env, card>>
SeesAllow == pc = "waiting" /\ status = "answered" /\ answer \in {"allow", "default"} /\ pc' = "claim"
             /\ Keep /\ UNCHANGED <<env, card, event>>
SeesMoved == pc = "waiting" /\ status = "pending" /\ ~past /\ moved
             /\ status' = "withdrawn" /\ Stop("changed") /\ Keep /\ UNCHANGED <<env, said, answer, yours>>
\* At the deadline it reads the class and the facts again. Its read of the
\* ledger may be one the person's pick made stale just before the deadline.
SeesDeadline == pc = "waiting" /\ (past \/ BugEarlyDefault)
                /\ (status = "pending" \/ (status = "answered" /\ ~raced))
                /\ raced' = (raced \/ status # "pending")
                /\ pc' = "deadline"
                /\ seen' = (IF BugNoDeadlineCheck THEN said ELSE world)
                /\ atDeadline' = world
                /\ seenMoved' = moved
                /\ UNCHANGED <<env, card, atLast, atGuard, watched, claimed, runs, event>>

\* The default, or the expiry. The ledger refuses either on a card that is no
\* longer pending (the person's pick or Close won the race), and the worker
\* polls again.
Defaults == (said = "defaults" \/ BugUpgrade) /\ seen = "defaults" /\ ~seenMoved /\ (watched \/ BugUnwatched)
Default == /\ pc = "deadline" /\ Defaults
           /\ IF (status = "pending" \/ (BugDefaultOverAnswer /\ status = "answered")) /\ (past \/ BugEarlyDefault)
                THEN status' = "answered" /\ answer' = "default" /\ pc' = "claim"
                ELSE pc' = "waiting" /\ UNCHANGED <<status, answer>>
           /\ UNCHANGED <<env, said, yours, seen, seenMoved, atDeadline, atLast, atGuard, raced, watched, claimed, runs, event>>
Expire == /\ pc = "deadline" /\ ~Defaults
          /\ IF status = "pending"
               THEN status' = "withdrawn" /\ Stop("expired")
               ELSE pc' = "waiting" /\ UNCHANGED <<status, event>>
          /\ UNCHANGED <<env, said, answer, yours, seen, seenMoved, atDeadline, atLast, atGuard, raced, watched, claimed, runs>>

\* QuestionStore.claimGuard: the person's Allow, or a default on a card that
\* said it defaults, past its deadline; once.
Claimable == \/ answer = "allow" /\ yours = "allow"
             \/ answer = "default" /\ (said = "defaults" \/ BugUpgrade) /\ (past \/ BugEarlyDefault)
Claim == /\ pc = "claim"
         /\ IF ~claimed /\ Claimable THEN claimed' = TRUE /\ pc' = "check" ELSE pc' = "done" /\ UNCHANGED claimed
         /\ UNCHANGED <<env, card, seen, seenMoved, atDeadline, atLast, atGuard, raced, watched, runs, event>>

\* The last check before the run: the facts, and on a default the class.
Recheck == answer = "default" /\ ~BugNoLastCheck
LastCheck == /\ pc = "check"
             /\ seenMoved' = moved
             /\ atLast' = world
             /\ seen' = (IF Recheck THEN world ELSE seen)
             /\ IF moved THEN Stop("changed")
                ELSE IF Recheck /\ world # "defaults" THEN Stop("expired")
                ELSE pc' = "run" /\ UNCHANGED event
             /\ UNCHANGED <<env, card, atDeadline, atGuard, raced, watched, claimed, runs>>
Run == /\ pc = "run" /\ runs' = runs + 1
       /\ Stop(IF answer = "default" THEN "ran-default" ELSE "ran")
       /\ UNCHANGED <<env, card, seen, seenMoved, atDeadline, atLast, atGuard, raced, watched, claimed>>

Crash == CanCrash /\ pc \notin {"done", "dead"} /\ pc' = "dead"
         /\ UNCHANGED <<env, card, seen, seenMoved, atDeadline, atLast, atGuard, raced, watched, claimed, runs, event>>

\* The chart's bound: a repo that opts in is drawn only where it runs with no
\* card; its card is the same as any other's, and full.cfg checks it.
ChartLimit == optIn => pc \in {"guard", "done"}

\* An ended worker stays ended; the card is then the person's alone.
Ended == pc \in {"done", "dead"} /\ UNCHANGED vars

Worker == GuardDecides \/ Classify \/ CardUp \/ Watch \/ SeesWithdrawn \/ SeesDeny \/ SeesAllow \/ SeesMoved \/ SeesDeadline
          \/ Default \/ Expire \/ Claim \/ LastCheck \/ Run

Next == Tick \/ Doze \/ Lag \/ Flip \/ Move \/ YouAllow \/ YouDeny \/ YouClose \/ Worker \/ Crash \/ Ended

Fairness == WF_vars(Tick) /\ WF_vars(Worker)

Spec == Init /\ [][Next]_vars /\ Fairness

(* Rules, in Simon's words (bercail-mdfb). *)
\* A command runs only on your Allow, or by default on a card that said it
\* defaults to Allow and still read private or local, with nothing it acts on
\* changed, at its deadline and right before it ran.
RunsOnlyOnAllowOrSafeDefault ==
  runs > 0 => \/ event = "ran-optin" /\ optIn /\ atGuard = "defaults"
              \/ yours = "allow" /\ answer = "allow" /\ ~seenMoved
              \/ /\ yours = "none" /\ answer = "default" /\ said = "defaults" /\ past
                 /\ atDeadline = "defaults" /\ atLast = "defaults" /\ ~seenMoved
\* With no card only where the repo opts in, and reads private.
NoCardOnlyOptedInPrivate == event = "ran-optin" => optIn /\ atGuard = "defaults" /\ status = "none"
\* It runs once at most.
RunsOnce == runs <= 1
\* Your pick stands: a default never replaces it, and your Deny never runs.
YourPickStands == /\ yours # "none" => answer = yours
                  /\ yours = "deny" => runs = 0
\* A card that said "waits for you" never defaults.
WaitsNeverDefaults == said = "waits" => answer # "default"
\* Nothing defaults before the deadline, nor on a card you had no hour to
\* see (one that went up late, or whose machine slept through its deadline),
\* nor long after it.
DefaultOnlyPastDeadline == answer = "default" => past
DefaultOnlyWatched == answer = "default" => watched
\* The event says whether it was your Allow or a default, and nothing ran on
\* a denied, expired, withdrawn or changed card.
EventSaysWhoAllowed ==
  /\ event = "ran" => yours = "allow"
  /\ event = "ran-default" => answer = "default" /\ yours = "none"
  /\ event \in {"expired", "denied", "withdrawn", "changed"} => runs = 0

\* The worker ends, with its event, unless it died.
EveryWorkerEnds == <>(pc \in {"done", "dead"})
=============================================================================
