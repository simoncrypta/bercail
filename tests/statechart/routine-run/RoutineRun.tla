---------------------------- MODULE RoutineRun ----------------------------
(* A routine run, its locks and its event, as lib/routine.sh has them
   (bercail routine run|pause|resume; bercail-2qig.1, and the event in
   bercail-2qig.2). Written before the code, from the design Simon said yes
   to; tests/routine.bats runs each step on the code.

   A run p of routine r: takes r's lock with flock -n (held: skipped,
   overlap), takes one of Cap slot locks with flock -n (none free: skipped,
   load), reads state.json (paused: skipped), and runs the query. Then, under
   a short state lock, it compares what it found with the hash sent per key,
   writes its runs.jsonl line and state.json (failures in a row, paused, the
   hashes, and its event in the routine's outbox, in that one rename), and
   lets go of its locks. Then, under the state lock again, every run that
   ended, a skipped one too, flushes the outbox: it writes each event into
   Shep's inbox unless that id is there already, then takes it out of the
   outbox. Before Shep's first start there is no inbox, and events wait.
   Pause and resume take the same state lock.

   A crash ends a run anywhere: the kernel drops its flocks, and nothing it
   had not written is written. A signal to the runner ends its query too; a
   kill -9 leaves the query running without the lock, which the model leaves
   out. A query's findings are one version number per routine (0: nothing
   found), and the world only moves forward.

   An event is named here by the version it counted as sent. The code names
   it by its run, and each emitted run counts a newer version, so the two
   name the same events. Shep's inbox and its delivered/ folder are one
   inbox here, which only grows (the 30 days delivered/ keeps a file are
   left out).

   The scheduler (bercail-2qig.3): a tick starts a run for the routine's
   next_due once the clock has passed it, and writes the first one of a
   routine that never ran. The clock is a number that may step back. A run
   by hand is for no slot. A scheduled run is let in only when its slot is
   still next_due, read under its locks, and not after the clock then,
   which is the run's start; it is skipped as done or early otherwise.
   Every run that ends, emitted, quiet or failed, writes in the same rename
   the highest slot met (the scheduled run's slot, or the next_due a run by
   hand found due when it started) and a next_due one period after the later
   of its start and that slot. tests/routine_loop.bats has the tick's own
   checks, which only make it start fewer runs: paused, still running, no
   free slot, and tried under 15 minutes ago; and the run's own check of
   that last one under its lock, which only skips more runs (tried). The
   model lets a tick start a run whenever one is due. tests/routine_loop.bats has a case for each of
   the scheduler's steps; schedule.cfg checks them, and the other configs
   leave the tick and the clock out.

   Left out: the event
   of a routine the third failure paused (the same outbox, with no
   findings), several keys per routine, output over 64 KB and bad output
   (they are a failed query, like a timeout), the trim to 100 runs, and a
   write that fails (a crash at that point: nothing after it is written).

   Planted bugs, each off in the real configs: BugStaleSlot, a scheduled run
   is let in when its slot is above the last scheduled one, whatever next_due
   says now, and a run by hand records no slot (as first staged);
   BugNoProgress, next_due is one period after the run's start only;
   BugEarly, a scheduled run is let in when its slot is after its start; BugNoLock, no flock on the
   routine; BugNoCap, no slot locks; BugStaleWrite, the end of a run writes
   back the state it read when it was let in; BugLockInChild, the query's
   leftover child process keeps the routine lock; BugTakeOutFirst, a flush
   takes an event out of the outbox before it is in the inbox; BugNoDedup, a
   flush writes an event whose id is in the inbox already. *)
EXTENDS Naturals, FiniteSets

CONSTANTS Procs, ProcsOnA, Routines, Cap, Others, MaxVersion, ShepAtStart,
          Ticks, MaxClock, Period, ClockBack, BugStaleSlot, BugNoProgress, BugEarly,
          BugNoLock, BugNoCap, BugStaleWrite, BugLockInChild, BugTakeOutFirst, BugNoDedup

Owner(p) == IF p \in ProcsOnA THEN "a" ELSE "b"
ProcsOf(r) == {p \in Procs : Owner(p) = r}
Versions == 0..MaxVersion
Events == Versions \ {0}
Holding == {"locked", "running", "emitted", "quiet", "failed"}
Querying == {"running", "emitted", "quiet", "failed"}
Ended == {"emitted", "quiet", "failed", "skipped"}
Child == 99   \* a query's leftover child process, in lock

VARIABLES
  pc,        \* [Procs -> {"idle","due","locked","running","flushing"} \cup Ended]
  why,       \* [Procs -> {"","paused","overlap","load","done","early"}]: why a run was skipped
  readPaused,   \* [Procs -> BOOLEAN]: paused, as this run read state.json once let in
  readFailures, \* [Procs -> 0..3]: failures in a row, as read then
  seen,      \* [Procs -> Versions]: what this run's query found
  lock,      \* [Routines -> Procs \cup {0, Child}]: who holds the routine's flock
  slots,     \* SUBSET Procs: who holds a slot flock
  others,    \* 0..Others: slots held by runs of routines outside the model
  world,     \* [Routines -> Versions]: what a query would find now
  sent,      \* [Routines -> Versions]: the hashes state.json says were sent
  emits,     \* [Routines -> [Versions -> 0..2]]: events state.json counted per version
  failures,  \* [Routines -> 0..3]: failures in a row in state.json
  paused,    \* [Routines -> BOOLEAN]: paused in state.json
  meant,     \* [Routines -> BOOLEAN]: paused, as you or the third failure last set it
  outbox,    \* [Routines -> SUBSET Events]: events in state.json not yet taken out
  inbox,     \* [Routines -> [Events -> 0..2]]: the files Shep's inbox got per event
  shep,      \* BOOLEAN: Shep has started once, so its inbox is there (ShepAtStart: may it have)
  clock,     \* 1..MaxClock: the wall clock, which may step back (ClockBack)
  next,      \* [Routines -> Slots \cup {0}]: next_due in state.json; 0 before it is written
  last,      \* [Routines -> Slots \cup {0}]: the highest slot met, in state.json (its slot)
  slotOf,    \* [Procs -> Slots \cup {0}]: the slot a run is for; 0 for one by hand
  startAt,   \* [Procs -> 0..MaxClock]: the clock when the run started
  met        \* [Routines -> [Slots -> 0..2]]: runs that ended having met each slot

vars == <<pc, why, readPaused, readFailures, seen, lock, slots, others, world, sent,
          emits, failures, paused, meant, outbox, inbox, shep, clock, next, last, slotOf, startAt, met>>
mail == <<outbox, inbox, shep>>
sched == <<clock, next, last, slotOf, startAt, met>>
Slots == 1..(MaxClock + Period)
Max(a, b) == IF a > b THEN a ELSE b

Init ==
  /\ pc = [p \in Procs |-> "idle"] /\ why = [p \in Procs |-> ""]
  /\ readPaused = [p \in Procs |-> FALSE] /\ readFailures = [p \in Procs |-> 0]
  /\ seen = [p \in Procs |-> 0]
  /\ lock = [r \in Routines |-> 0] /\ slots = {} /\ others = 0
  /\ world = [r \in Routines |-> 0] /\ sent = [r \in Routines |-> 0]
  /\ emits = [r \in Routines |-> [v \in Versions |-> 0]]
  /\ failures = [r \in Routines |-> 0]
  /\ paused = [r \in Routines |-> FALSE] /\ meant = [r \in Routines |-> FALSE]
  /\ outbox = [r \in Routines |-> {}] /\ inbox = [r \in Routines |-> [e \in Events |-> 0]]
  /\ shep \in ShepAtStart
  /\ clock = 1 /\ next = [r \in Routines |-> 0] /\ last = [r \in Routines |-> 0]
  /\ slotOf = [p \in Procs |-> 0] /\ startAt = [p \in Procs |-> 0]
  /\ met = [r \in Routines |-> [s \in Slots |-> 0]]

Taken == Cardinality(slots) + others

(* bercail routine run, by hand: for no slot. *)
Start(p) ==
  /\ pc[p] = "idle"
  /\ pc' = [pc EXCEPT ![p] = "due"] /\ why' = [why EXCEPT ![p] = ""]
  /\ slotOf' = [slotOf EXCEPT ![p] = 0]
  /\ UNCHANGED <<clock, next, last, startAt, met, readPaused, readFailures, seen, lock, slots, others,
                 world, sent, emits, failures, paused, meant, mail>>

(* A tick: next_due has passed, so it starts a run for that slot. The clock
   may move before the run is let in. *)
TickStart(p) ==
  LET r == Owner(p) IN
  /\ Ticks /\ pc[p] = "idle" /\ next[r] # 0 /\ next[r] <= clock
  /\ pc' = [pc EXCEPT ![p] = "due"] /\ why' = [why EXCEPT ![p] = ""]
  /\ slotOf' = [slotOf EXCEPT ![p] = next[r]]
  /\ UNCHANGED <<clock, next, last, startAt, met, readPaused, readFailures, seen, lock, slots, others,
                 world, sent, emits, failures, paused, meant, mail>>

(* A tick, under the state lock: an every routine that never ran is due now. *)
TickFirstDue(r) ==
  /\ Ticks /\ next[r] = 0
  /\ next' = [next EXCEPT ![r] = clock]
  /\ UNCHANGED <<clock, last, slotOf, startAt, met, pc, why, readPaused, readFailures, seen, lock,
                 slots, others, world, sent, emits, failures, paused, meant, mail>>

ClockStepsOn ==
  /\ Ticks /\ clock < MaxClock /\ clock' = clock + 1
  /\ UNCHANGED <<next, last, slotOf, startAt, met, pc, why, readPaused, readFailures, seen, lock,
                 slots, others, world, sent, emits, failures, paused, meant, mail>>

ClockStepsBack ==
  /\ ClockBack /\ clock > 1 /\ clock' = clock - 1
  /\ UNCHANGED <<next, last, slotOf, startAt, met, pc, why, readPaused, readFailures, seen, lock,
                 slots, others, world, sent, emits, failures, paused, meant, mail>>

(* Under its locks, a scheduled run's slot must still be next_due, and not
   after the clock then, which is the run's start. *)
StillDue(p) ==
  LET r == Owner(p) IN IF BugStaleSlot THEN slotOf[p] > last[r] ELSE slotOf[p] = next[r]

LetIn(p) ==
  \/ slotOf[p] = 0
  \/ StillDue(p) /\ (slotOf[p] <= clock \/ BugEarly)

Skip(p, reason) ==
  /\ pc' = [pc EXCEPT ![p] = "skipped"] /\ why' = [why EXCEPT ![p] = reason]

(* flock -n on routines/<name>/lock. *)
TakeLock(p) ==
  /\ pc[p] = "due"
  /\ \/ lock[Owner(p)] = 0 /\ lock' = [lock EXCEPT ![Owner(p)] = p]
     \/ BugNoLock /\ lock[Owner(p)] # 0 /\ UNCHANGED lock
  /\ pc' = [pc EXCEPT ![p] = "locked"]
  /\ UNCHANGED <<sched, why, readPaused, readFailures, seen, slots, others, world, sent, emits,
                 failures, paused, meant, mail>>

SkipOverlap(p) ==
  /\ pc[p] = "due" /\ lock[Owner(p)] # 0 /\ ~BugNoLock
  /\ Skip(p, "overlap")
  /\ UNCHANGED <<sched, readPaused, readFailures, seen, lock, slots, others, world, sent, emits,
                 failures, paused, meant, mail>>

Release(p) == [r \in Routines |-> IF lock[r] = p THEN 0 ELSE lock[r]]

(* flock -n on one of the Cap slot files, then the clock and state.json
   read: the run is let in only when the routine is not paused then. *)
TakeSlot(p) ==
  /\ pc[p] = "locked" /\ (Taken < Cap \/ BugNoCap) /\ ~paused[Owner(p)] /\ LetIn(p)
  /\ slots' = slots \cup {p} /\ pc' = [pc EXCEPT ![p] = "running"]
  /\ startAt' = [startAt EXCEPT ![p] = clock]
  /\ readPaused' = [readPaused EXCEPT ![p] = paused[Owner(p)]]
  /\ readFailures' = [readFailures EXCEPT ![p] = failures[Owner(p)]]
  /\ UNCHANGED <<clock, next, last, slotOf, met, why, seen, lock, others, world, sent, emits, failures,
                 paused, meant, mail>>

SkipPaused(p) ==
  /\ pc[p] = "locked" /\ (Taken < Cap \/ BugNoCap) /\ paused[Owner(p)]
  /\ Skip(p, "paused") /\ lock' = Release(p)
  /\ UNCHANGED <<sched, readPaused, readFailures, seen, slots, others, world, sent, emits,
                 failures, paused, meant, mail>>

SkipDone(p) ==
  /\ pc[p] = "locked" /\ (Taken < Cap \/ BugNoCap) /\ ~paused[Owner(p)] /\ ~LetIn(p)
  /\ Skip(p, IF StillDue(p) THEN "early" ELSE "done") /\ lock' = Release(p)
  /\ UNCHANGED <<sched, readPaused, readFailures, seen, slots, others, world, sent, emits,
                 failures, paused, meant, mail>>

SkipLoad(p) ==
  /\ pc[p] = "locked" /\ Taken >= Cap /\ ~BugNoCap
  /\ Skip(p, "load") /\ lock' = Release(p)
  /\ UNCHANGED <<sched, readPaused, readFailures, seen, slots, others, world, sent, emits,
                 failures, paused, meant, mail>>

(* The query prints its findings and exits 0. Only new or changed ones count. *)
QueryEnds(p) ==
  LET r == Owner(p) IN
  /\ pc[p] = "running"
  /\ seen' = [seen EXCEPT ![p] = world[r]]
  /\ pc' = [pc EXCEPT ![p] = IF world[r] # 0 /\ world[r] # sent[r] THEN "emitted" ELSE "quiet"]
  /\ UNCHANGED <<sched, why, readPaused, readFailures, lock, slots, others, world, sent, emits,
                 failures, paused, meant, mail>>

(* A non-zero exit, bad output, output over 64 KB, or 10 minutes: its
   process group is killed. *)
QueryFails(p) ==
  /\ pc[p] = "running"
  /\ pc' = [pc EXCEPT ![p] = "failed"]
  /\ UNCHANGED <<sched, why, readPaused, readFailures, seen, lock, slots, others, world, sent, emits,
                 failures, paused, meant, mail>>

(* A run's own memory goes with its process. *)
Forget(p) ==
  /\ why' = [why EXCEPT ![p] = ""] /\ seen' = [seen EXCEPT ![p] = 0]
  /\ readPaused' = [readPaused EXCEPT ![p] = FALSE] /\ readFailures' = [readFailures EXCEPT ![p] = 0]
  /\ slotOf' = [slotOf EXCEPT ![p] = 0] /\ startAt' = [startAt EXCEPT ![p] = 0]

(* In the same rename as the rest of a run's end: the slot it met, the
   highest slot met, and next_due one period after the later of its start
   and that. *)
Met(p) ==
  LET r == Owner(p) IN
  IF slotOf[p] # 0 THEN slotOf[p]
  ELSE IF next[r] # 0 /\ next[r] <= startAt[p] THEN next[r] ELSE 0

Advance(p) ==
  LET r == Owner(p)
      top == IF BugStaleSlot THEN (IF slotOf[p] # 0 THEN slotOf[p] ELSE last[r])
             ELSE Max(last[r], Met(p))
      from == IF BugNoProgress THEN startAt[p] ELSE Max(startAt[p], top)
  IN
  /\ last' = [last EXCEPT ![r] = top]
  /\ next' = [next EXCEPT ![r] = from + Period]
  /\ met' = IF Met(p) # 0 THEN [met EXCEPT ![r][Met(p)] = IF @ < 2 THEN @ + 1 ELSE 2] ELSE met

(* Under the state lock: the runs.jsonl line, then state.json, an emitted
   run's event in its outbox in the same rename; then the flocks go. *)
Finish(p) ==
  LET r == Owner(p)
      base == IF BugStaleWrite THEN readFailures[p] ELSE failures[r]
      was == IF BugStaleWrite THEN readPaused[p] ELSE paused[r]
      n == IF base < 3 THEN base + 1 ELSE 3
  IN
  /\ pc[p] \in Ended
  /\ pc' = [pc EXCEPT ![p] = "flushing"]
  /\ slots' = slots \ {p}
  /\ lock' = IF BugLockInChild /\ pc[p] \in Querying /\ lock[r] = p
               THEN [lock EXCEPT ![r] = Child] ELSE Release(p)
  /\ IF pc[p] = "skipped" THEN UNCHANGED <<next, last, met>> ELSE Advance(p)
  /\ CASE pc[p] = "skipped" ->
            UNCHANGED <<sent, emits, failures, paused, meant, outbox>>
       [] pc[p] = "failed" ->
            /\ failures' = [failures EXCEPT ![r] = n]
            /\ paused' = [paused EXCEPT ![r] = was \/ n >= 3]
            /\ meant' = IF n >= 3 THEN [meant EXCEPT ![r] = TRUE] ELSE meant
            /\ UNCHANGED <<sent, emits, outbox>>
       [] OTHER ->
            /\ sent' = [sent EXCEPT ![r] = seen[p]]
            /\ emits' = IF pc[p] = "emitted"
                          THEN [emits EXCEPT ![r][seen[p]] = IF @ < 2 THEN @ + 1 ELSE 2]
                          ELSE emits
            /\ outbox' = IF pc[p] = "emitted" THEN [outbox EXCEPT ![r] = @ \cup {seen[p]}] ELSE outbox
            /\ failures' = [failures EXCEPT ![r] = 0]
            /\ paused' = [paused EXCEPT ![r] = was]
            /\ UNCHANGED meant
  /\ Forget(p) /\ UNCHANGED <<clock, others, world, inbox, shep>>

(* The flush, under the state lock: an event's file goes into Shep's inbox
   (tmp, then mv), unless its id is there already... *)
Send(p, e) ==
  LET r == Owner(p) IN
  /\ pc[p] = "flushing" /\ shep /\ e \in outbox[r]
  /\ (inbox[r][e] = 0 \/ BugNoDedup) /\ inbox[r][e] < 2
  /\ inbox' = [inbox EXCEPT ![r][e] = @ + 1]
  /\ UNCHANGED <<sched, pc, why, readPaused, readFailures, seen, lock, slots, others, world, sent,
                 emits, failures, paused, meant, outbox, shep>>

(* ...then state.json without it. *)
TakeOut(p, e) ==
  LET r == Owner(p) IN
  /\ pc[p] = "flushing" /\ e \in outbox[r]
  /\ ((shep /\ inbox[r][e] > 0) \/ BugTakeOutFirst)
  /\ outbox' = [outbox EXCEPT ![r] = @ \ {e}]
  /\ UNCHANGED <<sched, pc, why, readPaused, readFailures, seen, lock, slots, others, world, sent,
                 emits, failures, paused, meant, inbox, shep>>

(* Nothing left to send, or no inbox yet: what is left waits for a later run. *)
Flushed(p) ==
  /\ pc[p] = "flushing" /\ (outbox[Owner(p)] = {} \/ ~shep)
  /\ pc' = [pc EXCEPT ![p] = "idle"]
  /\ UNCHANGED <<sched, why, readPaused, readFailures, seen, lock, slots, others, world, sent,
                 emits, failures, paused, meant, mail>>

(* The runner dies (a reboot, kill -9): the kernel drops its flocks. *)
Crash(p) ==
  /\ pc[p] # "idle"
  /\ pc' = [pc EXCEPT ![p] = "idle"] /\ lock' = Release(p) /\ slots' = slots \ {p}
  /\ Forget(p) /\ UNCHANGED <<clock, next, last, met, others, world, sent, emits, failures, paused,
                              meant, mail>>

(* bercail routine pause / resume, under the state lock. *)
YouPause(r) ==
  /\ ~paused[r]
  /\ paused' = [paused EXCEPT ![r] = TRUE] /\ meant' = [meant EXCEPT ![r] = TRUE]
  /\ UNCHANGED <<sched, pc, why, readPaused, readFailures, seen, lock, slots, others, world, sent,
                 emits, failures, mail>>

YouResume(r) ==
  /\ paused[r]
  /\ paused' = [paused EXCEPT ![r] = FALSE] /\ meant' = [meant EXCEPT ![r] = FALSE]
  /\ failures' = [failures EXCEPT ![r] = 0]
  /\ UNCHANGED <<sched, pc, why, readPaused, readFailures, seen, lock, slots, others, world, sent,
                 emits, mail>>

(* Shep's first start makes its inbox. *)
ShepStarts ==
  /\ ~shep /\ shep' = TRUE
  /\ UNCHANGED <<sched, pc, why, readPaused, readFailures, seen, lock, slots, others, world, sent,
                 emits, failures, paused, meant, outbox, inbox>>

WorldChanges(r) ==
  /\ world[r] < MaxVersion
  /\ world' = [world EXCEPT ![r] = @ + 1]
  /\ UNCHANGED <<sched, pc, why, readPaused, readFailures, seen, lock, slots, others, sent, emits,
                 failures, paused, meant, mail>>

(* Runs of other routines take and free slots. *)
OtherStarts ==
  /\ others < Others /\ Taken < Cap
  /\ others' = others + 1
  /\ UNCHANGED <<sched, pc, why, readPaused, readFailures, seen, lock, slots, world, sent, emits,
                 failures, paused, meant, mail>>

OtherEnds ==
  /\ others > 0
  /\ others' = others - 1
  /\ UNCHANGED <<sched, pc, why, readPaused, readFailures, seen, lock, slots, world, sent, emits,
                 failures, paused, meant, mail>>

Next ==
  \/ \E p \in Procs :
       \/ Start(p) \/ TickStart(p) \/ SkipPaused(p) \/ TakeLock(p) \/ SkipOverlap(p) \/ TakeSlot(p)
       \/ SkipDone(p) \/ SkipLoad(p) \/ QueryEnds(p) \/ QueryFails(p) \/ Finish(p) \/ Crash(p)
       \/ Flushed(p) \/ \E e \in Events : Send(p, e) \/ TakeOut(p, e)
  \/ \E r \in Routines : YouPause(r) \/ YouResume(r) \/ WorldChanges(r) \/ TickFirstDue(r)
  \/ OtherStarts \/ OtherEnds \/ ShepStarts \/ ClockStepsOn \/ ClockStepsBack

(* Each started run moves on by itself; nothing waits on you or the world.
   Each flock -n either takes its lock or skips, so the pair is one step. *)
Fairness ==
  \A p \in Procs :
    /\ WF_vars(TakeLock(p) \/ SkipOverlap(p))
    /\ WF_vars(TakeSlot(p) \/ SkipLoad(p) \/ SkipPaused(p) \/ SkipDone(p))
    /\ WF_vars(QueryEnds(p) \/ QueryFails(p)) /\ WF_vars(Finish(p))
    /\ WF_vars(Flushed(p) \/ \E e \in Events : Send(p, e) \/ TakeOut(p, e))

Spec == Init /\ [][Next]_vars /\ Fairness

(* chart.cfg only, to keep its chart under 500 states: no other routine holds a
   slot while run 1 flushes, which it does after it let go of its own, and no
   event waits in the outbox past the flush that wrote it there (a crash
   then; full.cfg checks the next run sends it). *)
ChartLimit ==
  /\ others = 0 \/ pc[1] # "flushing"
  /\ outbox["a"] = {} \/ pc[1] = "flushing"

----------------------------------------------------------------------------
(* "One run per routine at a time, by hand too." *)
OneRunPerRoutine ==
  \A r \in Routines : Cardinality({p \in ProcsOf(r) : pc[p] \in Holding}) <= 1

(* "At most 2 routines at once." *)
AtMostCap ==
  Cardinality({p \in Procs : pc[p] \in Querying}) + others <= Cap

(* "Only new or changed findings count": the same findings never make a second event. *)
OneEventPerChange ==
  \A r \in Routines : \A v \in Versions : emits[r][v] <= 1

(* "A run's event is never lost": each event state.json counted is in its
   outbox or in Shep's inbox. *)
NoLostEvent ==
  \A r \in Routines : \A e \in Events : emits[r][e] > 0 => e \in outbox[r] \/ inbox[r][e] > 0

(* "Shep gets each event once." *)
OneMessagePerEvent == \A r \in Routines : \A e \in Events : inbox[r][e] <= 1

(* "A pause sticks until you resume": a run that ends never undoes it. *)
PauseSticks == \A r \in Routines : paused[r] = meant[r]

(* "3 failures in a row pause the routine." *)
ThreeFailuresPause == \A r \in Routines : failures[r] >= 3 => paused[r]

(* "Once a run ends, its routine is free": no lock outlives the run that took it. *)
LockOnlyWhileRunning ==
  \A r \in Routines : lock[r] # 0 => lock[r] \in Procs /\ pc[lock[r]] \in Holding

(* "A slot runs once": no two runs end having met the same slot, by a tick
   or by hand, whatever the clock does. It names a scheduled run's event. *)
OneRunPerSlot == \A r \in Routines : \A s \in Slots : met[r][s] <= 1

(* "A scheduled run never looks before its slot": its query runs only when
   its own clock has reached the slot, so it sees what is there in its window. *)
NotBeforeSlot ==
  \A p \in Procs : pc[p] \in Querying /\ slotOf[p] # 0 => startAt[p] >= slotOf[p]

(* "A routine never waits on a slot it already met": next_due is always
   after it, so a tick never comes back to it. *)
NextAfterLast == \A r \in Routines : last[r] # 0 => next[r] > last[r]

(* "Every run ends and is logged": skipped, emitted, quiet or failed. *)
EveryRunEnds == \A p \in Procs : pc[p] # "idle" ~> pc[p] = "idle"
=============================================================================
