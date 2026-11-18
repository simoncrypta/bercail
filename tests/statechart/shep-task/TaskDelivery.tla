------------------------- MODULE TaskDelivery -------------------------
EXTENDS Naturals
\* config/pi/extensions/bercail-desk.ts followUpWatch, working repair on b93c99f.
\* Only the transport: one request, one original session, an idle poll. Omits
\* reservation/concurrent writers, busy scheduling, OS races, native effects,
\* metadata/outcome proof and power-loss durability; isolated regressions cover
\* those separately. A send result never says the requested job completed.
CONSTANTS Replay, AllowStale
VARIABLES phase, bound, attempts
vars == <<phase, bound, attempts>>
Init == /\ phase = "idle" /\ bound = TRUE /\ attempts = 0
Accept == /\ phase = "idle" /\ phase' = "queued"
          /\ UNCHANGED <<bound, attempts>>
ChangeSession == /\ phase = "queued" /\ bound /\ bound' = FALSE
                 /\ UNCHANGED <<phase, attempts>>
Submit == /\ phase = "queued" /\ (bound \/ AllowStale)
          /\ phase' = "submitted" /\ attempts' = attempts + 1
          /\ UNCHANGED bound
Uncertain == /\ phase = "queued" /\ bound
             /\ phase' = "unknown" /\ attempts' = attempts + 1
             /\ UNCHANGED bound
Refuse == /\ phase = "queued" /\ ~bound /\ phase' = "stale"
          /\ UNCHANGED <<bound, attempts>>
Retry == /\ phase = "unknown" /\ Replay /\ phase' = "queued"
         /\ UNCHANGED <<bound, attempts>>
Idle == /\ phase \in {"submitted", "unknown", "stale"} /\ UNCHANGED vars
Next == Accept \/ ChangeSession \/ Submit \/ Uncertain \/ Refuse \/ Retry \/ Idle
Spec == Init /\ [][Next]_vars
StateBound == attempts <= 2
\* No automatic second attempt, including after an uncertain response.
AtMostOnce == attempts <= 1
\* A replacement session cannot receive the original session's work.
OriginalSessionOnly == phase = "submitted" => bound
=======================================================================
