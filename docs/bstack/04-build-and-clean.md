# Build and clean the change

Each build playbook asks for one piece of evidence before code moves. Put what
you know in the prompt, and the playbook supplies the rest.

## A bug: the symptom and a repro

```text
this command emits two records after a retry. repro first, then fix and prove it.
```

The bug fix playbook writes down the exact command and output, finds the first
place the state goes wrong, writes a failing test when there is a cheap path,
fixes it at the root, and runs the repro again. No repro: it stops at a
diagnosis and says so.

## A feature: the behavior and what stays

```text
add a --json flag. text output stays byte-identical. prove both forms.
```

It names the data shape, settles the interface from the caller's side, builds
in small green steps on `bstack-builder`, then drives the real path: the CLI,
the app, the endpoint. A hard design fork goes to `bstack-judge`.

## A refactor: pin it first

```text
move parsing into one module, zero behavior change. record the current output first and prove it's unchanged after.
```

Behavior is pinned before anything moves. Callers move and the old shape goes in
the same change. Before deleting something whose reason is unclear, it runs
`/why` on it.

## Clean it: `/unslop`

```text
/unslop the diff
```

`/unslop` on the diff removes what agents leave behind: comments that narrate
the code, guards for states that cannot happen, catch blocks that swallow
errors, debug output, one-caller helpers, and edits outside the job. It touches
only lines this change adds, reruns the tests, and keeps the result staged.

On prose, it cuts throat-clearing, puffed words, stacked hedges, em dashes, and
closing summaries, and keeps your voice:

```text
/unslop the readme changes, keep it terse
```

`/ready` runs it on the diff for you before it stages.

**Pitfall:** treating cleanup as polish. A padded diff reads as unfinished, and
the extra code is where the next bug hides.

Next: [Review it](./05-review.md).
