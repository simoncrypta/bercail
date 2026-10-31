# Work with the bstack agent

`bstack` is opencode's default agent once bstack is on. It reads your ask,
matches a playbook, copies its steps into the todo list, and hands each step to
the role that fits.

## The playbooks

| You say | Playbook | What it insists on |
|---------|----------|--------------------|
| how does X work, why is Y like this | investigation | evidence, no edits |
| X is broken | bug fix | a repro before a fix, the root cause |
| add or change behavior | feature | the data shape first, the real path proven |
| same behavior, better shape | refactor | behavior pinned before anything moves |
| review this | review | the council, findings checked |
| the PR is open | ship | autopilot until green |
| several jobs at once | handoff | one beads issue per job |
| finish this branch | takeover | read the trail before touching it |

No match: the agent writes a five-step plan, each step ending in a check.

The playbooks live in the `bstack` skill (`~/.agents/skills/bstack/SKILL.md`).
Read it once. It is short.

## The roles

| Role | Agent | Gets |
|------|-------|------|
| lead | `bstack` | your ask; plans, routes, checks, reports |
| build | `bstack-builder` | code from a precise brief |
| judge | `bstack-judge` | hard design calls, prose, and disagreements |
| council | `bstack-council-<plan>` | read-only review, one per connected plan |
| autopilot | `bstack-autopilot` | an open PR to get green |

By default the lead and judge run on Claude and the builder on Grok. A role
whose plan isn't connected takes the next one that is.

A subagent knows nothing you didn't put in its brief. The lead writes the
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
