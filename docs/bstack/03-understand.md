# Understand the code

An agent that edits code it has not read fixes the symptom at the first
plausible spot. Two skills come first.

## `/how`: what the code does now

```text
/how do we dedupe notifications? is there an n+1 when we look up subscribers?
```

Ask the question you have. For a narrow one, the agent reads and answers. For a
subsystem, it sends two to four `explore` subagents out on separate angles (the
call path, the data, the edges, the tests), then reads what they found itself.

The answer has an overview, the key concepts, the flow with `file:line` at each
step, where things live, and the gotchas. It ends with what it did not read.

## `/why`: why it is that way

```text
/why is the retry limit five? does the reason still hold?
```

`/why` starts from the lines in question and walks the record: `git log -L`,
`git log -S`, blame, the PRs behind each commit and their review threads, the
beads issues named in commit messages, and bercail's handoff log.

Every claim gets a label: **said** (the record states it), **shown** (the code
or a run shows it), **inferred**, **guess**, or **unknown**. "Nobody wrote it
down" is a real answer. Asked before a change, it adds what to keep, what to
change, and what could break.

Both together: `how first, then why`. Mechanics, then history.

## Take over a branch

```text
take over this branch. read the issue, the PR threads, and the last agent's result. figure out what's done and finish the rest. don't redo finished work.
```

The takeover playbook reads the whole trail first: the beads issue, the PR, its
commits, `.bercail/handoff-result.json` or the transcript. Then it rebases,
drops what is already merged, and finishes the rest with the playbook that
fits.

**Pitfall:** skipping these because the agent will read the code anyway. It
reads the code it lands on first. `/how` is cheaper than the second bug.

Next: [Build and clean the change](./04-build-and-clean.md).
