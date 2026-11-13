# Work with the bstack agent

The bstack lead is the Pi on your desk. It reads your ask,
matches a playbook, copies its steps into the todo list, and hands each step to
the role that fits.

## The playbooks

| You say | Playbook | What it insists on |
|---------|----------|--------------------|
| how does X work, why is Y like this | investigation | evidence, no edits |
| X is broken | bug fix | a repro before a fix, the root cause |
| add or change behavior | feature | the data shape first, the real path proven |
| same behavior, better shape | refactor | behavior pinned before anything moves |
| review this | review | tests and the verify skill; `/council` when you ask |
| the PR is open | ship | autopilot until green |
| several jobs at once | handoff | one beads issue per job |
| finish this branch | takeover | read the trail before touching it |

No match: the agent writes a five-step plan, each step ending in a check.

The playbooks live in the `bstack` skill (`~/.agents/skills/bstack/SKILL.md`).
Read it once. It is short.

## The roles

Every role but the lead is an `hc` sibling agent the lead starts from a
template in `~/.config/herdr-core/templates/`.

| Role | Template | Gets |
|------|----------|------|
| lead | the desk | your ask; plans, routes, checks, reports |
| build | `bstack-builder` | code from a precise brief |
| judge | `bstack-judge` | hard design calls, prose, and the intent and description check at `/validate` |
| council | `bstack-council-<plan>` | read-only adversarial review, one per plan with a model, on `/council` |
| autopilot | `bstack-autopilot` | an open PR to get green |

By default the lead and judge run on Claude and the builder on Grok. A role
names a plan (`claude`, `gpt`, `grok`) or a full Pi model id. When you are not
signed in to its plan, it takes the next one you are (build: grok, then gpt,
then claude; lead and judge: claude, then gpt, then grok), so bstack works on
one plan and spreads out as you sign in to more. A pinned model is used whether
or not you are signed in to its plan. With no sign-in at all, agents use Pi's
default model.

To run one desk's lead on another model, without changing the lead for every
desk, hand it off with `--model` ([handoff](../handoff.md)). Only that desk's
lead changes; the builder, judge, council, and autopilot it starts keep the
models above.

A sibling knows nothing you didn't put in its brief. The lead writes the
brief, then checks the result itself before passing it on.

## What goes in a prompt

Two things carry most of the weight:

- **What done looks like**, in a form that can pass or fail: a command, an
  output, a test, a screen.
- **What must not change**: an output format, an API, a file you care about.

Add what you already know when it saves a search: the file, the error, the
issue id. Leave out your theory of the cause until the agent has stated its
own. It will look wherever you point.

```text
users get two notifications after a retry. repro first, then fix and prove it.
```

```text
investigate why background jobs time out every few hours. what we know, what data you used, best hypotheses. no code changes yet.
```

"no code changes yet" keeps it in the investigation playbook.

## When the job is a beads issue

When a beads issue names the job, the issue is the spec. Say the id and nothing
else:

```text
your job is beads issue app-12a.
```

The agent reads it with `bd show`, does the work, and re-reads it before it
stops.

Next: [Understand the code](./03-understand.md).
