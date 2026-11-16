```mermaid
---
title: "Shep inbox: one desk finish"
---
stateDiagram-v2
  s0: desk working
  s1: waiting in the inbox
  s2: claimed, not sent yet
  s3: claimed by a Shep that crashed
  s4: queued for Shep's turn
  s5: on screen, not saved yet
  s6: sent, then lost in a crash
  s7: saved in Shep's session
  s8: acknowledged
  [*] --> s0
  s0 --> s1: desk finishes
  s1 --> s2: Shep claims it
  s2 --> s3: Shep crashes
  s2 --> s4: Shep queues it
  s4 --> s5: you see it, unsaved
  s4 --> s6: Shep crashes
  s4 --> s7: you see it, saved
  s5 --> s6: Shep crashes
  s5 --> s8: Shep replies
  s7 --> s8: Shep claims it or Shep replies
  s3 --> s4: Shep queues it
  s6 --> s4: Shep queues it
```

Arrows:
- start -> desk working
- desk working -> waiting in the inbox: desk finishes
- waiting in the inbox -> claimed, not sent yet: Shep claims it
- claimed, not sent yet -> claimed by a Shep that crashed: Shep crashes
- claimed, not sent yet -> queued for Shep's turn: Shep queues it
- queued for Shep's turn -> on screen, not saved yet: you see it, unsaved
- queued for Shep's turn -> sent, then lost in a crash: Shep crashes
- queued for Shep's turn -> saved in Shep's session: you see it, saved
- on screen, not saved yet -> sent, then lost in a crash: Shep crashes
- on screen, not saved yet -> acknowledged: Shep replies
- saved in Shep's session -> acknowledged: Shep claims it or Shep replies
- claimed by a Shep that crashed -> queued for Shep's turn: Shep queues it
- sent, then lost in a crash -> queued for Shep's turn: Shep queues it
