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
  [*] --> s0
  s0 --> s1: it comes due
  s0 --> s2: you pause it
  s2 --> s0: you resume it
  s2 --> s1: it comes due
  s1 --> s3: takes its locks
  s3 --> s4: fails or times out
  s3 --> s5: nothing new
  s1 --> s5: no free slot or it is paused
  s4 --> s0: run logged
  s5 --> s0: run logged
  s3 --> s6: new findings
  s5 --> s2: run logged
  s6 --> s0: event, run logged
  s4 --> s2: run logged or 3rd failure
  s6 --> s2: event, run logged
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
- Failed -> Scheduled: run logged
- Skipped -> Scheduled: run logged
- Running -> Emitted: new findings
- Skipped -> Paused: run logged
- Emitted -> Scheduled: event, run logged
- Failed -> Paused: run logged or 3rd failure
- Emitted -> Paused: event, run logged
