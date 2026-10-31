---
name: how
description: >-
  Explains how code works now: the runtime flow, the data it moves, where each
  part lives, and what will surprise you. Read-only, with file:line for every
  claim. Use for "how does X work", before changing a subsystem you have not
  read, or when onboarding onto code.
---

# how

Answer the question the person asked, at the level of a senior engineer walking
a new teammate through the code. Change nothing.

## 1. Size it

- **Narrow** (one function, one flag, one path): read it yourself and answer.
- **Wide** (a subsystem, a request end to end, "the whole X"): fan out first.

Write the question in one sentence before you read. When the code answers a
different question than the one asked, say so.

## 2. Fan out (wide only)

Launch 2 to 4 `explore` subagents in parallel, one angle each. Pick the angles
that fit:

- the entry points and the path a call takes, in order,
- the data: the types, where state lives, who writes and who reads it,
- the edges: config, errors, retries, the I/O and the processes it starts,
- the tests: what they pin down, what they skip.

Give each one the question, its angle, and "report file:line for every claim,
no fixes". Then read the files they point at yourself before you trust them.
Outside opencode there are no subagents: take the angles one at a time.

## 3. Answer

```
## Overview        what it does and why it exists, 2-4 sentences
## Key concepts    the 3-6 names a reader must know, one line each
## How it works    the flow in order, file:line per step; a small diagram when the flow branches
## Where things live  a short table: path, what it holds
## Gotchas         the non-obvious parts: hidden state, ordering, things that look dead and are not
```

Drop a section that has nothing in it. End with what you did not read, when it
could change the answer.

`how` explains what the code does; `why` digs into why it is that way. For
both, run `why` second.
