----------------------------- MODULE ShepInbox -----------------------------
(* Shep's inbox delivery, as master 656d73e has it: shep/pi/inbox.ts (the
   consumer in Shep's Pi) and notify_shep_enqueue / notify_follow in
   lib/notify.sh (the follower that writes the inbox). From the spike in
   bercail-237.9, with the reconcile-race fix of bercail-237.12 as the code now
   has it: a drain reads source-state.json before claim().

   One desk finish. The follower either writes its event E to inbox/ and then
   source-state.json (same hc line, in that order), or missed the change and
   only writes source-state.json; reconcile() then makes notice N. Each Shep
   process p runs the drain (read source and claim+verify, reconcile, send),
   and its own Pi shows queued follow-ups one turn at a time. A crash ends the
   process: its pending set, Pi queue and unwritten session entries are gone;
   files stay.

   Left out: prune after 30 days, malformed or conflicting files, two
   followers, deleted or corrupt session files (all "held" paths), decision
   events, batching E and N into one message, Simon's own turns (followUp
   waits for them; that is Pi's queue, not inbox.ts), and a labels lookup that
   publishes done before its status event (bercail-237.14). verify() also runs
   on Pi's context and agent_settled events; here it runs at claim and at turn
   end, which only makes a receipt later.

   Planted bugs, each off by default (tests/statechart/shep-inbox/bug-*.cfg):
   BugSourceAfterClaim, the race bercail-237.12 fixed; BugReadyClaimedOnly,
   send only what this claim() moved; BugNoLock, no consumer lock. *)
EXTENDS Naturals, FiniteSets

CONSTANTS Procs, MaxStarts, WithNotice, BugSourceAfterClaim, BugReadyClaimedOnly, BugNoLock

Items == IF WithNotice THEN {"E", "N"} ELSE {"E"}
Sessions == 1..MaxStarts
Cap(n) == IF n < 3 THEN n + 1 ELSE 3
VARIABLES
  follower,   \* "idle" | "accepted" (E written) | "missed" (desk finished unseen)
  source,     \* source-state.json says the desk is done
  loc,        \* [Items -> {"none","inbox","delivered"}]
  attempt,    \* [Items -> 0..MaxStarts]: delivery_attempt's session, 0 = none
  receipt,    \* [Items -> BOOLEAN]: persisted_entry_id written
  pc,         \* [Procs -> {"down","paused","idle","claimed","reconciled"}]
  sess,       \* [Procs -> 0..MaxStarts]: this process's Pi session
  pending,    \* [Procs -> SUBSET Items]: inbox.ts's in-memory pending set
  queue,      \* [Procs -> SUBSET Items]: Pi's follow-up queue
  busy,       \* [Procs -> BOOLEAN]: Pi is in the turn an event started
  lock,       \* 0, or the process holding delivered/.consumer.lock
  starts,     \* Pi sessions started so far
  flushed,    \* [Sessions -> BOOLEAN]: Pi has written this session's JSONL
  saved,      \* [Sessions -> SUBSET Items]: custom_message entries on disk
  unsaved,    \* [Sessions -> SUBSET Items]: shown, not yet on disk (empty session)
  shown,      \* [Items -> 0..3]: times Simon saw it in Shep
  lost,       \* [Items -> 0..3]: times a crash lost it from the screen before Pi saved it
  claimer,    \* [Items -> 0..MaxStarts]: the session whose claim() moved it
  seen        \* [Procs -> BOOLEAN]: source-state.json as this drain read it

vars == <<follower, source, loc, attempt, receipt, pc, sess, pending, queue, busy,
          lock, starts, flushed, saved, unsaved, shown, lost, claimer, seen>>

Live(p) == pc[p] \notin {"down", "paused"}

Init ==
  /\ follower = "idle" /\ source = FALSE
  /\ loc = [i \in Items |-> "none"] /\ attempt = [i \in Items |-> 0]
  /\ receipt = [i \in Items |-> FALSE]
  /\ pc = [p \in Procs |-> "down"] /\ sess = [p \in Procs |-> 0]
  /\ pending = [p \in Procs |-> {}] /\ queue = [p \in Procs |-> {}]
  /\ busy = [p \in Procs |-> FALSE] /\ lock = 0 /\ starts = 0
  /\ flushed = [s \in Sessions |-> FALSE]
  /\ saved = [s \in Sessions |-> {}] /\ unsaved = [s \in Sessions |-> {}]
  /\ shown = [i \in Items |-> 0] /\ lost = [i \in Items |-> 0]
  /\ claimer = [i \in Items |-> 0] /\ seen = [p \in Procs |-> FALSE]

(* notify_shep_enqueue: tmp file, then mv into inbox/. *)
FollowerWritesEvent ==
  /\ follower = "idle"
  /\ follower' = "accepted" /\ loc' = [loc EXCEPT !["E"] = "inbox"]
  /\ UNCHANGED <<source, attempt, receipt, pc, sess, pending, queue, busy, lock, starts,
                 flushed, saved, unsaved, shown, lost, claimer, seen>>

(* The desk finished while the follower was down: its next snapshot has no
   previous status, so no event, only the current source state. *)
FollowerMissesEvent ==
  /\ WithNotice /\ follower = "idle" /\ follower' = "missed"
  /\ UNCHANGED <<source, loc, attempt, receipt, pc, sess, pending, queue, busy, lock, starts,
                 flushed, saved, unsaved, shown, lost, claimer, seen>>

(* _notify_follow_source_write, at the end of the same hc line. *)
FollowerWritesSource ==
  /\ WithNotice /\ follower # "idle" /\ ~source /\ source' = TRUE
  /\ UNCHANGED <<follower, loc, attempt, receipt, pc, sess, pending, queue, busy, lock, starts,
                 flushed, saved, unsaved, shown, lost, claimer, seen>>

(* session_start: a new Pi session, empty or with a conversation; flock
   --nonblock on delivered/.consumer.lock, else "Inbox paused". *)
ShepStarts(p) ==
  /\ pc[p] = "down" /\ starts < MaxStarts
  /\ \E f \in BOOLEAN :
       /\ starts' = starts + 1 /\ sess' = [sess EXCEPT ![p] = starts + 1]
       /\ flushed' = [flushed EXCEPT ![starts + 1] = f]
  /\ IF lock = 0 \/ BugNoLock
       THEN /\ pc' = [pc EXCEPT ![p] = "idle"]
            /\ lock' = IF lock = 0 THEN p ELSE lock
       ELSE /\ pc' = [pc EXCEPT ![p] = "paused"] /\ lock' = lock
  /\ UNCHANGED <<follower, source, loc, attempt, receipt, pending, queue, busy, saved, unsaved,
                 shown, lost, claimer, seen>>

(* Kill at any point. Files stay; memory and Pi's queue go. The lock helper's
   stdin closes, so the kernel lock is released. Bounded: a crash needs a
   restart left, so the last session lives. *)
ShepCrashes(p) ==
  /\ pc[p] # "down" /\ starts < MaxStarts
  /\ pc' = [pc EXCEPT ![p] = "down"]
  /\ lock' = IF lock = p THEN 0 ELSE lock
  /\ pending' = [pending EXCEPT ![p] = {}] /\ queue' = [queue EXCEPT ![p] = {}]
  /\ busy' = [busy EXCEPT ![p] = FALSE]
  /\ unsaved' = [unsaved EXCEPT ![sess[p]] = {}]
  /\ lost' = [i \in Items |-> IF i \in unsaved[sess[p]] THEN Cap(lost[i]) ELSE lost[i]]
  /\ UNCHANGED <<follower, source, loc, attempt, receipt, sess, starts, flushed, saved, shown,
                 claimer, seen>>

Confirmed(i) == loc[i] = "delivered" /\ attempt[i] # 0 /\ i \in saved[attempt[i]]

(* checkReceipts(): a receipt only from a complete entry in the attempt's
   session file; a confirmed id leaves pending. *)
VerifyEffect(p) ==
  /\ receipt' = [i \in Items |-> receipt[i] \/ Confirmed(i)]
  /\ pending' = [pending EXCEPT ![p] = {i \in pending[p] : ~(receipt[i] \/ Confirmed(i))}]

(* drain(): read source-state.json, then claim() renames inbox/ files into
   delivered/, then verify(). No follower write between the read and the
   listing changes what the drain does, so they are one step here. *)
Claim(p) ==
  /\ pc[p] = "idle" /\ pc' = [pc EXCEPT ![p] = "claimed"]
  /\ loc' = [i \in Items |-> IF loc[i] = "inbox" THEN "delivered" ELSE loc[i]]
  /\ claimer' = [i \in Items |-> IF loc[i] = "inbox" THEN sess[p] ELSE claimer[i]]
  /\ seen' = [seen EXCEPT ![p] = source]
  /\ VerifyEffect(p)
  /\ UNCHANGED <<follower, source, attempt, sess, queue, busy, lock, starts, flushed, saved,
                 unsaved, shown, lost>>

(* reconcile(): a notice for a done desk whose mapping no delivered/ record has,
   from the source state the drain read before claim() (BugSourceAfterClaim:
   read now, as before bercail-237.12). *)
Reconcile(p) ==
  /\ pc[p] = "claimed" /\ pc' = [pc EXCEPT ![p] = "reconciled"]
  /\ loc' = IF WithNotice /\ (IF BugSourceAfterClaim THEN source ELSE seen[p])
              /\ loc["N"] = "none" /\ loc["E"] # "delivered"
              THEN [loc EXCEPT !["N"] = "delivered"] ELSE loc
  /\ UNCHANGED <<follower, source, attempt, receipt, sess, pending, queue, busy, lock, starts,
                 flushed, saved, unsaved, shown, lost, claimer, seen>>

Ready(p) ==
  IF BugReadyClaimedOnly
    THEN {i \in Items : loc[i] = "delivered" /\ claimer[i] = sess[p] /\ ~receipt[i] /\ i \notin pending[p]}
    ELSE {i \in Items : loc[i] = "delivered" /\ ~receipt[i] /\ i \notin pending[p]}

(* Stamp delivery_attempt durably, add to pending, pi.sendMessage(followUp). *)
Send(p) ==
  /\ pc[p] = "reconciled" /\ pc' = [pc EXCEPT ![p] = "idle"]
  /\ attempt' = [i \in Items |-> IF i \in Ready(p) THEN sess[p] ELSE attempt[i]]
  /\ pending' = [pending EXCEPT ![p] = pending[p] \cup Ready(p)]
  /\ queue' = [queue EXCEPT ![p] = queue[p] \cup Ready(p)]
  /\ UNCHANGED <<follower, source, loc, receipt, sess, busy, lock, starts, flushed, saved,
                 unsaved, shown, lost, claimer, seen>>

(* Pi starts a turn with the queued message: Simon sees it. Pi appends the
   entry now if the session file exists, else only with the first reply. *)
PiShows(p, i) ==
  /\ Live(p) /\ pc[p] = "idle" /\ ~busy[p] /\ i \in queue[p]
  /\ queue' = [queue EXCEPT ![p] = @ \ {i}] /\ busy' = [busy EXCEPT ![p] = TRUE]
  /\ shown' = [shown EXCEPT ![i] = Cap(@)]
  /\ IF flushed[sess[p]]
       THEN saved' = [saved EXCEPT ![sess[p]] = @ \cup {i}] /\ UNCHANGED unsaved
       ELSE unsaved' = [unsaved EXCEPT ![sess[p]] = @ \cup {i}] /\ UNCHANGED saved
  /\ UNCHANGED <<follower, source, loc, attempt, receipt, pc, sess, pending, lock, starts,
                 flushed, lost, claimer, seen>>

(* Shep replies; Pi writes the session (all of it, if it was empty). turn_end
   runs verify(). *)
PiEndsTurn(p) ==
  /\ Live(p) /\ pc[p] = "idle" /\ busy[p]
  /\ busy' = [busy EXCEPT ![p] = FALSE]
  /\ flushed' = [flushed EXCEPT ![sess[p]] = TRUE]
  /\ saved' = [saved EXCEPT ![sess[p]] = @ \cup unsaved[sess[p]]]
  /\ unsaved' = [unsaved EXCEPT ![sess[p]] = {}]
  /\ LET now == [s \in Sessions |-> IF s = sess[p] THEN saved[s] \cup unsaved[s] ELSE saved[s]]
         ok(i) == loc[i] = "delivered" /\ attempt[i] # 0 /\ i \in now[attempt[i]]
     IN /\ receipt' = [i \in Items |-> receipt[i] \/ ok(i)]
        /\ pending' = [pending EXCEPT ![p] = {i \in pending[p] : ~(receipt[i] \/ ok(i))}]
  /\ UNCHANGED <<follower, source, loc, attempt, pc, sess, queue, lock, starts, shown, lost,
                 claimer, seen>>

Next ==
  \/ FollowerWritesEvent \/ FollowerMissesEvent \/ FollowerWritesSource
  \/ \E p \in Procs : ShepStarts(p) \/ ShepCrashes(p) \/ Claim(p) \/ Reconcile(p) \/ Send(p)
                      \/ PiEndsTurn(p) \/ \E i \in Items : PiShows(p, i)

Fairness ==
  /\ WF_vars(FollowerWritesSource)
  /\ \A p \in Procs : /\ WF_vars(ShepStarts(p)) /\ WF_vars(Claim(p)) /\ WF_vars(Reconcile(p))
                      /\ WF_vars(Send(p))
                      \* Pi steps only between drains; the event loop runs them.
                      /\ SF_vars(PiEndsTurn(p)) /\ \A i \in Items : SF_vars(PiShows(p, i))

Spec == Init /\ [][Next]_vars /\ Fairness

SavedSomewhere(i) == \E s \in Sessions : i \in saved[s]

(* Rules, in Simon's words (bercail-237.9 and .13). Delivery is at least once:
   no loss over no repeat. *)
\* Shep's sessions save each event once.
SavedOnce == \A i \in Items : Cardinality({s \in Sessions : i \in saved[s]}) <= 1
\* You see an event again only when Shep died before Pi saved it.
ShownAgainOnlyAfterLostReply == \A i \in Items : shown[i] <= Cap(lost[i])
\* One desk finish reaches you as its event or as a notice, never both.
OneReportPerFinish == WithNotice => ~(shown["E"] > 0 /\ shown["N"] > 0)
\* One Shep consumes the inbox at a time.
OneConsumer == Cardinality({p \in Procs : Live(p)}) <= 1
\* A receipt only from a saved entry.
ReceiptMeansSaved == \A i \in Items : receipt[i] => (attempt[i] # 0 /\ i \in saved[attempt[i]])

\* An accepted event, or the notice for a missed one, is eventually saved.
NeverLost ==
  /\ (follower = "accepted") ~> SavedSomewhere("E")
  /\ WithNotice => ((follower = "missed") ~> SavedSomewhere("N"))
\* A saved event is eventually acknowledged.
EventuallyAcknowledged == \A i \in Items : SavedSomewhere(i) ~> receipt[i]
=============================================================================
