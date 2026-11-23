```mermaid
---
title: "A routine run"
---
stateDiagram-v2
  s0: Scheduled
  s1: Due
  s2: Paused
  s3: Running
  s4: Failed
  s5: Skipped
  s6: Emitted
  s7: Sending
  [*] --> s0
  s0 --> s1: it comes due
  s0 --> s2: you pause it
  s2 --> s0: you resume it
  s2 --> s1: it comes due
  s1 --> s3: takes its locks
  s3 --> s4: fails or times out
  s3 --> s5: nothing new
  s1 --> s5: no free slot or it is paused
  s4 --> s7: run logged or 3rd failure
  s5 --> s7: run logged
  s3 --> s6: new findings
  s6 --> s7: event in outbox
  s7 --> s0: outbox sent
  s7 --> s2: outbox sent
```

Arrows:
- start -> Scheduled
- Scheduled -> Due: it comes due
- Scheduled -> Paused: you pause it
- Paused -> Scheduled: you resume it
- Paused -> Due: it comes due
- Due -> Running: takes its locks
- Running -> Failed: fails or times out
- Running -> Skipped: nothing new
- Due -> Skipped: no free slot or it is paused
- Failed -> Sending: run logged or 3rd failure
- Skipped -> Sending: run logged
- Running -> Emitted: new findings
- Emitted -> Sending: event in outbox
- Sending -> Scheduled: outbox sent
- Sending -> Paused: outbox sent
