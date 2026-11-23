---------------------------- MODULE RoutineRun ----------------------------
(* A routine run and its locks, as lib/routine.sh has them (bercail routine
   run|pause|resume; bercail-2qig.1). Written before the code, from the
   design Simon said yes to; tests/routine.bats runs each step on the code.

   A run p of routine r: takes r's lock with flock -n (held: skipped,
   overlap), takes one of Cap slot locks with flock -n (none free: skipped,
   load), reads state.json (paused: skipped), and runs the query. Then, under
   a short state lock, it compares what it found with the hash sent per key,
   writes its runs.jsonl line and state.json (failures in a row, paused, the
   hashes), and lets go of its locks. Pause and resume take the same state
   lock.

   A crash ends a run anywhere: the kernel drops its flocks, and nothing it
   had not written is written. A signal to the runner ends its query too; a
   kill -9 leaves the query running without the lock, which the model leaves
   out. A query's findings are one version number per routine (0: nothing
   found), and the world only moves forward.

   Left out: when a run is due (the tick and next_due are step 3), the event
   file itself (step 2; here an emit is the event --dry-run prints), the
   event id, several keys per routine, output over 64 KB and bad output (they
   are a failed query, like a timeout), the trim to 100 runs, and a write
   that fails at the end (one step here; the code writes the run's line
   before state.json, so a lost write repeats an event rather than losing
   one).

   Planted bugs, each off in the real configs: BugNoLock, no flock on the
   routine; BugNoCap, no slot locks; BugStaleWrite, the end of a run writes
   back the state it read when it was let in; BugLockInChild, the query's
   leftover child process keeps the routine lock. *)
EXTENDS Naturals, FiniteSets

CONSTANTS Procs, ProcsOnA, Routines, Cap, Others, MaxVersion,
          BugNoLock, BugNoCap, BugStaleWrite, BugLockInChild

Owner(p) == IF p \in ProcsOnA THEN "a" ELSE "b"
ProcsOf(r) == {p \in Procs : Owner(p) = r}
Versions == 0..MaxVersion
Holding == {"locked", "running", "emitted", "quiet", "failed"}
Querying == {"running", "emitted", "quiet", "failed"}
Ended == {"emitted", "quiet", "failed", "skipped"}
Child == 99   \* a query's leftover child process, in lock

VARIABLES
  pc,        \* [Procs -> {"idle","due","locked","running"} \cup Ended]
  why,       \* [Procs -> {"","paused","overlap","load"}]: why a run was skipped
  readPaused,   \* [Procs -> BOOLEAN]: paused, as this run read state.json once let in
  readFailures, \* [Procs -> 0..3]: failures in a row, as read then
  seen,      \* [Procs -> Versions]: what this run's query found
  lock,      \* [Routines -> Procs \cup {0, Child}]: who holds the routine's flock
  slots,     \* SUBSET Procs: who holds a slot flock
  others,    \* 0..Others: slots held by runs of routines outside the model
  world,     \* [Routines -> Versions]: what a query would find now
  sent,      \* [Routines -> Versions]: the hashes state.json says were sent
  emits,     \* [Routines -> [Versions -> 0..2]]: events emitted per version
  failures,  \* [Routines -> 0..3]: failures in a row in state.json
  paused,    \* [Routines -> BOOLEAN]: paused in state.json
  meant      \* [Routines -> BOOLEAN]: paused, as you or the third failure last set it

vars == <<pc, why, readPaused, readFailures, seen, lock, slots, others, world, sent,
          emits, failures, paused, meant>>

Init ==
  /\ pc = [p \in Procs |-> "idle"] /\ why = [p \in Procs |-> ""]
  /\ readPaused = [p \in Procs |-> FALSE] /\ readFailures = [p \in Procs |-> 0]
  /\ seen = [p \in Procs |-> 0]
  /\ lock = [r \in Routines |-> 0] /\ slots = {} /\ others = 0
  /\ world = [r \in Routines |-> 0] /\ sent = [r \in Routines |-> 0]
  /\ emits = [r \in Routines |-> [v \in Versions |-> 0]]
  /\ failures = [r \in Routines |-> 0]
  /\ paused = [r \in Routines |-> FALSE] /\ meant = [r \in Routines |-> FALSE]

Taken == Cardinality(slots) + others

(* bercail routine run, by hand or from a tick. *)
Start(p) ==
  /\ pc[p] = "idle"
  /\ pc' = [pc EXCEPT ![p] = "due"] /\ why' = [why EXCEPT ![p] = ""]
  /\ UNCHANGED <<readPaused, readFailures, seen, lock, slots, others, world, sent, emits,
                 failures, paused, meant>>

Skip(p, reason) ==
  /\ pc' = [pc EXCEPT ![p] = "skipped"] /\ why' = [why EXCEPT ![p] = reason]

(* flock -n on routines/<name>/lock. *)
TakeLock(p) ==
  /\ pc[p] = "due"
  /\ \/ lock[Owner(p)] = 0 /\ lock' = [lock EXCEPT ![Owner(p)] = p]
     \/ BugNoLock /\ lock[Owner(p)] # 0 /\ UNCHANGED lock
  /\ pc' = [pc EXCEPT ![p] = "locked"]
  /\ UNCHANGED <<why, readPaused, readFailures, seen, slots, others, world, sent, emits,
                 failures, paused, meant>>

SkipOverlap(p) ==
  /\ pc[p] = "due" /\ lock[Owner(p)] # 0 /\ ~BugNoLock
  /\ Skip(p, "overlap")
  /\ UNCHANGED <<readPaused, readFailures, seen, lock, slots, others, world, sent, emits,
                 failures, paused, meant>>

Release(p) == [r \in Routines |-> IF lock[r] = p THEN 0 ELSE lock[r]]

(* flock -n on one of the Cap slot files, then state.json read: the run is let
   in only when the routine is not paused then. *)
TakeSlot(p) ==
  /\ pc[p] = "locked" /\ (Taken < Cap \/ BugNoCap) /\ ~paused[Owner(p)]
  /\ slots' = slots \cup {p} /\ pc' = [pc EXCEPT ![p] = "running"]
  /\ readPaused' = [readPaused EXCEPT ![p] = paused[Owner(p)]]
  /\ readFailures' = [readFailures EXCEPT ![p] = failures[Owner(p)]]
  /\ UNCHANGED <<why, seen, lock, others, world, sent, emits, failures, paused, meant>>

SkipPaused(p) ==
  /\ pc[p] = "locked" /\ (Taken < Cap \/ BugNoCap) /\ paused[Owner(p)]
  /\ Skip(p, "paused") /\ lock' = Release(p)
  /\ UNCHANGED <<readPaused, readFailures, seen, slots, others, world, sent, emits,
                 failures, paused, meant>>

SkipLoad(p) ==
  /\ pc[p] = "locked" /\ Taken >= Cap /\ ~BugNoCap
  /\ Skip(p, "load") /\ lock' = Release(p)
  /\ UNCHANGED <<readPaused, readFailures, seen, slots, others, world, sent, emits,
                 failures, paused, meant>>

(* The query prints its findings and exits 0. Only new or changed ones count. *)
QueryEnds(p) ==
  LET r == Owner(p) IN
  /\ pc[p] = "running"
  /\ seen' = [seen EXCEPT ![p] = world[r]]
  /\ pc' = [pc EXCEPT ![p] = IF world[r] # 0 /\ world[r] # sent[r] THEN "emitted" ELSE "quiet"]
  /\ UNCHANGED <<why, readPaused, readFailures, lock, slots, others, world, sent, emits,
                 failures, paused, meant>>

(* A non-zero exit, bad output, output over 64 KB, or 10 minutes: its
   process group is killed. *)
QueryFails(p) ==
  /\ pc[p] = "running"
  /\ pc' = [pc EXCEPT ![p] = "failed"]
  /\ UNCHANGED <<why, readPaused, readFailures, seen, lock, slots, others, world, sent, emits,
                 failures, paused, meant>>

(* A run's own memory goes with its process. *)
Forget(p) ==
  /\ why' = [why EXCEPT ![p] = ""] /\ seen' = [seen EXCEPT ![p] = 0]
  /\ readPaused' = [readPaused EXCEPT ![p] = FALSE] /\ readFailures' = [readFailures EXCEPT ![p] = 0]

(* Under the state lock: state.json and the runs.jsonl line, then the flocks go. *)
Finish(p) ==
  LET r == Owner(p)
      base == IF BugStaleWrite THEN readFailures[p] ELSE failures[r]
      was == IF BugStaleWrite THEN readPaused[p] ELSE paused[r]
      n == IF base < 3 THEN base + 1 ELSE 3
  IN
  /\ pc[p] \in Ended
  /\ pc' = [pc EXCEPT ![p] = "idle"]
  /\ slots' = slots \ {p}
  /\ lock' = IF BugLockInChild /\ pc[p] \in Querying /\ lock[r] = p
               THEN [lock EXCEPT ![r] = Child] ELSE Release(p)
  /\ CASE pc[p] = "skipped" ->
            UNCHANGED <<sent, emits, failures, paused, meant>>
       [] pc[p] = "failed" ->
            /\ failures' = [failures EXCEPT ![r] = n]
            /\ paused' = [paused EXCEPT ![r] = was \/ n >= 3]
            /\ meant' = IF n >= 3 THEN [meant EXCEPT ![r] = TRUE] ELSE meant
            /\ UNCHANGED <<sent, emits>>
       [] OTHER ->
            /\ sent' = [sent EXCEPT ![r] = seen[p]]
            /\ emits' = IF pc[p] = "emitted"
                          THEN [emits EXCEPT ![r][seen[p]] = IF @ < 2 THEN @ + 1 ELSE 2]
                          ELSE emits
            /\ failures' = [failures EXCEPT ![r] = 0]
            /\ paused' = [paused EXCEPT ![r] = was]
            /\ UNCHANGED meant
  /\ Forget(p) /\ UNCHANGED <<others, world>>

(* The runner dies (a reboot, kill -9): the kernel drops its flocks. *)
Crash(p) ==
  /\ pc[p] # "idle"
  /\ pc' = [pc EXCEPT ![p] = "idle"] /\ lock' = Release(p) /\ slots' = slots \ {p}
  /\ Forget(p) /\ UNCHANGED <<others, world, sent, emits, failures, paused, meant>>

(* bercail routine pause / resume, under the state lock. *)
YouPause(r) ==
  /\ ~paused[r]
  /\ paused' = [paused EXCEPT ![r] = TRUE] /\ meant' = [meant EXCEPT ![r] = TRUE]
  /\ UNCHANGED <<pc, why, readPaused, readFailures, seen, lock, slots, others, world, sent,
                 emits, failures>>

YouResume(r) ==
  /\ paused[r]
  /\ paused' = [paused EXCEPT ![r] = FALSE] /\ meant' = [meant EXCEPT ![r] = FALSE]
  /\ failures' = [failures EXCEPT ![r] = 0]
  /\ UNCHANGED <<pc, why, readPaused, readFailures, seen, lock, slots, others, world, sent,
                 emits>>

WorldChanges(r) ==
  /\ world[r] < MaxVersion
  /\ world' = [world EXCEPT ![r] = @ + 1]
  /\ UNCHANGED <<pc, why, readPaused, readFailures, seen, lock, slots, others, sent, emits,
                 failures, paused, meant>>

(* Runs of other routines take and free slots. *)
OtherStarts ==
  /\ others < Others /\ Taken < Cap
  /\ others' = others + 1
  /\ UNCHANGED <<pc, why, readPaused, readFailures, seen, lock, slots, world, sent, emits,
                 failures, paused, meant>>

OtherEnds ==
  /\ others > 0
  /\ others' = others - 1
  /\ UNCHANGED <<pc, why, readPaused, readFailures, seen, lock, slots, world, sent, emits,
                 failures, paused, meant>>

Next ==
  \/ \E p \in Procs :
       \/ Start(p) \/ SkipPaused(p) \/ TakeLock(p) \/ SkipOverlap(p) \/ TakeSlot(p)
       \/ SkipLoad(p) \/ QueryEnds(p) \/ QueryFails(p) \/ Finish(p) \/ Crash(p)
  \/ \E r \in Routines : YouPause(r) \/ YouResume(r) \/ WorldChanges(r)
  \/ OtherStarts \/ OtherEnds

(* Each started run moves on by itself; nothing waits on you or the world.
   Each flock -n either takes its lock or skips, so the pair is one step. *)
Fairness ==
  \A p \in Procs :
    /\ WF_vars(TakeLock(p) \/ SkipOverlap(p))
    /\ WF_vars(TakeSlot(p) \/ SkipLoad(p) \/ SkipPaused(p))
    /\ WF_vars(QueryEnds(p) \/ QueryFails(p)) /\ WF_vars(Finish(p))

Spec == Init /\ [][Next]_vars /\ Fairness

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

(* "A pause sticks until you resume": a run that ends never undoes it. *)
PauseSticks == \A r \in Routines : paused[r] = meant[r]

(* "3 failures in a row pause the routine." *)
ThreeFailuresPause == \A r \in Routines : failures[r] >= 3 => paused[r]

(* "Once a run ends, its routine is free": no lock outlives the run that took it. *)
LockOnlyWhileRunning ==
  \A r \in Routines : lock[r] # 0 => lock[r] \in Procs /\ pc[lock[r]] \in Holding

(* "Every run ends and is logged": skipped, emitted, quiet or failed. *)
EveryRunEnds == \A p \in Procs : pc[p] # "idle" ~> pc[p] = "idle"
=============================================================================
