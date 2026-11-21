---
name: statechart
description: "Check a TLA+ model of a stateful change (a lifecycle, retry or resume, lock or lease, queue, recovery, or concurrent writers) with TLC, show the owner a Mermaid statechart in Pi's chat, and replay every step on the real code. The report gives the shortest path to each state that breaks a rule. Use for /statechart, or when bstack's lead names it for such a change. Not for prose, config or one-line fixes."
---

# Statechart

Ported from pstack's statechart skill (MIT, Lauren Tan, at the commit in
UPSTREAM.md). The chart shows how a system moves between states, in the words of the
person who reads it. That person, the owner, decides whether the behavior is right.
A model is a hand copy of the code, so it drifts: every model here comes with a
replay of its steps on the real code.

## Run

Work in the repo's worktree under `.bercail/statechart/<name>/`: `<name>.tla`,
`<name>.cfg`, and `view.mjs`. Check that git ignores it
(`git check-ignore -q .bercail/statechart`). If not, add `.bercail/*` to
`$(git rev-parse --git-path info/exclude)`, which also works in a linked worktree. A spec the repo keeps goes where it keeps its tests, with a
script that reruns it (bercail: `tests/statechart/shep-inbox/check.sh`). Then run:

```sh
~/.agents/skills/statechart/scripts/statechart-bstack <name>.tla --config <name>.cfg --view view.mjs --out out-1
```

Exit 0: every rule holds. 1: a rule breaks. 2: an error. It writes `report.md`,
`tlc.out`, and when there is a chart, `chart.mmd` and, for Pi's chat,
`chart.pi.md`.

It needs TLC and Java, which bercail installs when `[bstack] statechart = true`,
and it never installs them itself. When they are missing it exits 2 with the fix;
tell the person and stop. Each run stops after `STATECHART_TIMEOUT` seconds (600)
and exits 2: make the constants smaller or add a CONSTRAINT rather than raise it.
It needs `timeout` from GNU coreutils for that bound, and exits 2 without it.

Run only specs and views you or the owner wrote, from a trusted checkout. The view
module is JavaScript that the command executes, and a spec can make TLC run for a
long time. In a PR review, never run the PR's `.tla`, `.cfg` or `view.mjs`.

## Write the spec

- Read the code first and model what it does, not what it should do. Name the
  files and the commit in the spec's header, and say what the model leaves out.
- Write each rule the owner agrees to as an INVARIANT, or as a PROPERTY when it
  says something must happen eventually, with the owner's sentence in a comment
  above it. If the model has no variable for a rule, add the variable. Never
  weaken a rule to make it hold. When the code keeps a weaker rule on purpose,
  ask the owner to restate it, and write down why.
- Write `Next` as a disjunction of named actions, so each step has a name.
- A state with no step out breaks `NoDeadlock`, also when it is a correct end
  state. Add an action that is true only in the end states and changes nothing.
- A PROPERTY needs fairness. When an action is enabled only between other steps
  (an event loop's callback between polls), give it strong fairness, or TLC
  reports a loop that the code does not have.
- Plant the bugs you most fear, each behind a constant that is FALSE in the real
  configs, and keep a config per plant. TLC must break the rule each plant
  targets: a rule that cannot break proves nothing.

## Pick the chart

Upstream's rules hold: `state(vars)` returns the owner's words (a string, an array
for parent states, an object for regions), `step(action, from, to)` labels arrows
as the owner sees them happen, `group`, `colors` and `title` are optional, and each
function depends only on its arguments. Merge labels before hiding steps, never
merge two states that break different rules, keep every state reachable, hide all
steps of an arrow or none, and say which you hid. SKILL.upstream.md has the full
rules.

The chart goes to chat in a terminal, so it is small: 20 states or fewer, edge
labels under 20 characters, and one region when you can. A state string reads
better there than regions side by side: the Shep inbox chart is 78 columns wide
flat and 142 with a second region. Make a second, smaller config for the chart
when the full one is too big.

The command refuses a chart whose labels hide what stops a PROPERTY's loop ("Show
in a label what stops it"). Add the state the loop is stuck in to `state()`.

## Read the report

As upstream: `breaks` and `mayBreak` mark states, TLC goes past a broken rule, keep
constants small or add a CONSTRAINT, and after the first break each run stops at
100,000 states and lists "Rules not checked". Above 500 states the chart draws only
the bug paths, and with no rule broken there is no chart.

## Show the chart

Post `chart.pi.md` to the owner as it is: the chart as a `mermaid` block, top to
bottom and without the Legend, then each marked state and every arrow in words.
Pi does not colour the `breaks` or bug-path marks, and draws a chart only when it
fits the pane (it shows the Mermaid source otherwise), so the words carry it.

A chart in chat shows the bug path or a projected view of 20 states or fewer.
Over that, `chart.pi.md` has no chart: post the bug's shortest path from
`report.md` as numbered text instead. With no chart at all (over 500 states and
no rule broken), post report.md's state count and the rules that hold. The
chart marks the states on a bug path but not their order: give the order from
`report.md`. Do not render SVGs with Pele unless the person asks.

## Replay on the real code

Write a test that drives the real code through the model's steps and compares
the code's state with the model's after each one: files, queues, screens,
whatever the rules talk about. Take the steps from TLC's own graph:

```sh
~/.agents/skills/statechart/scripts/statechart-bstack graph <name>.tla replay.cfg graph.json
```

It writes every reachable state and every step, one a line, and the test walks
them. Cover every step, not every state: two orders of the same steps can reach
one state, and the shortest path to it takes only one of them. A step that leaves
the code mid-operation (a model that splits one call into several steps) is
followed to the end of that operation before the states are compared. Keep the
replay config small enough to run in seconds, commit `graph.json` with the
checksums of what made it, and have the test fail when they are stale. Then plant
each bug in a scratch copy of the code and check that the replay fails.
`tests/shep_inbox_statechart.test.ts` in bercail is a worked example.

When TLC breaks a rule, replay its path on the real code before anyone calls it a
bug. If the bug does not occur, treat the model as wrong until you show it is not.
A pass covers the model and its bounds, not the code: the replay and the tests
that run the code carry the rest.

## Hand off

Post the chart and the report on the beads issue (`bd comment <id>`) for the
owner's intent check before code, and again at /validate. One line for each bug:
the rule, the owner's sentence for it, and the path as the report numbers it. Say
what the model leaves out, the command that makes the files again, and the TLC
version. A chart from a run older than the spec, the config, the view or the code
it models is stale. Say so, and never show a green chart after a failed run.

## What changed from upstream

Pi and bstack instead of Cursor: no `disable-model-invocation`, a bstack trigger,
artifacts under `.bercail/statechart/`, no first-run install and a time bound
(`statechart-bstack`), no native Windows command, `chart.pi.md` for Pi's terminal
Mermaid instead of Pele, the trust rule for PR reviews, the graph and the replay on
real code, fairness and planted-bug advice from the Shep inbox spike
(bercail-237.9), and posting on the beads issue.
