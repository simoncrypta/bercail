```mermaid
---
title: "A guard card"
---
stateDiagram-v2
  s0: asked
  s1: asked, repo opts in
  s2: card going up
  s3: ran with no card
  s4: defaults to Allow at HH:MM
  s5: waits for you
  s6: you allowed it
  s7: you denied it
  s8: you closed it
  s9: denied: nothing ran
  s10: deadline: class read again
  s11: closed: nothing ran
  s12: deadline: it waited
  s13: changed: nothing ran
  s14: expired: a Deny, nothing ran
  s15: defaulted to Allow
  s16: ran on your Allow
  s17: ran by default
  [*] --> s0
  [*] --> s1
  s0 --> s2: to a card
  s1 --> s3: reads private
  s2 --> s4: card up
  s2 --> s5: card up
  s4 --> s6: you Allow
  s4 --> s7: you Deny
  s4 --> s8: you Close
  s5 --> s6: you Allow
  s5 --> s7: you Deny
  s5 --> s8: you Close
  s7 --> s9: sees your Deny
  s8 --> s11: sees it closed
  s4 --> s10: deadline passes
  s5 --> s12: deadline passes
  s4 --> s13: sees it moved
  s5 --> s13: sees it moved
  s6 --> s10: stale read
  s6 --> s12: stale read
  s7 --> s10: stale read
  s7 --> s12: stale read
  s10 --> s14: withdraws: a Deny
  s12 --> s14: withdraws: a Deny
  s10 --> s6: you picked first
  s12 --> s6: you picked first
  s10 --> s7: you picked first
  s12 --> s7: you picked first
  s10 --> s8: you picked first
  s10 --> s15: records default
  s12 --> s8: you picked first
  s6 --> s16: runs it once
  s6 --> s13: last check fails
  s15 --> s17: runs it once
  s15 --> s13: last check fails
```

Arrows:
- start -> asked
- start -> asked, repo opts in
- asked -> card going up: to a card
- asked, repo opts in -> ran with no card: reads private
- card going up -> defaults to Allow at HH:MM: card up
- card going up -> waits for you: card up
- defaults to Allow at HH:MM -> you allowed it: you Allow
- defaults to Allow at HH:MM -> you denied it: you Deny
- defaults to Allow at HH:MM -> you closed it: you Close
- waits for you -> you allowed it: you Allow
- waits for you -> you denied it: you Deny
- waits for you -> you closed it: you Close
- you denied it -> denied: nothing ran: sees your Deny
- you closed it -> closed: nothing ran: sees it closed
- defaults to Allow at HH:MM -> deadline: class read again: deadline passes
- waits for you -> deadline: it waited: deadline passes
- defaults to Allow at HH:MM -> changed: nothing ran: sees it moved
- waits for you -> changed: nothing ran: sees it moved
- you allowed it -> deadline: class read again: stale read
- you allowed it -> deadline: it waited: stale read
- you denied it -> deadline: class read again: stale read
- you denied it -> deadline: it waited: stale read
- deadline: class read again -> expired: a Deny, nothing ran: withdraws: a Deny
- deadline: it waited -> expired: a Deny, nothing ran: withdraws: a Deny
- deadline: class read again -> you allowed it: you picked first
- deadline: it waited -> you allowed it: you picked first
- deadline: class read again -> you denied it: you picked first
- deadline: it waited -> you denied it: you picked first
- deadline: class read again -> you closed it: you picked first
- deadline: class read again -> defaulted to Allow: records default
- deadline: it waited -> you closed it: you picked first
- you allowed it -> ran on your Allow: runs it once
- you allowed it -> changed: nothing ran: last check fails
- defaulted to Allow -> ran by default: runs it once
- defaulted to Allow -> changed: nothing ran: last check fails
