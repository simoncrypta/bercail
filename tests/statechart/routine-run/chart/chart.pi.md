```mermaid
---
title: "A routine run"
---
stateDiagram-v2
  s0: Scheduled
  s1: Due
  s2: Paused
  s3: Running
  s4: Skipped
  s5: Failed
  s6: Sending
  s7: Emitted
  [*] --> s0
  s0 --> s1: it comes due
  s0 --> s2: you pause it
  s2 --> s0: you resume it
  s2 --> s1: it comes due
  s1 --> s3: takes its locks
  s1 --> s4: no free slot or it is paused
  s3 --> s5: fails or times out
  s3 --> s4: nothing new
  s4 --> s6: run logged
  s5 --> s6: run logged or 3rd failure
  s3 --> s7: new findings
  s6 --> s0: outbox sent
  s6 --> s2: outbox sent
  s7 --> s6: event in outbox
```

Arrows:
- start -> Scheduled
- Scheduled -> Due: it comes due
- Scheduled -> Paused: you pause it
- Paused -> Scheduled: you resume it
- Paused -> Due: it comes due
- Due -> Running: takes its locks
- Due -> Skipped: no free slot or it is paused
- Running -> Failed: fails or times out
- Running -> Skipped: nothing new
- Skipped -> Sending: run logged
- Failed -> Sending: run logged or 3rd failure
- Running -> Emitted: new findings
- Sending -> Scheduled: outbox sent
- Sending -> Paused: outbox sent
- Emitted -> Sending: event in outbox
