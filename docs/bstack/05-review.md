# Review it

Different providers miss different bugs. bstack reviews with all of the plans
you have, then checks every finding before it counts.

## `/council`

```text
/council
```

With no target, it reviews the uncommitted change. It also takes a branch
(`/council the branch against master`) or a PR (`/council pr 42`).

Every `bstack-council-<plan>` seat gets the same brief, in parallel, without
seeing what the others said. The lead then reads the code at each `file:line`,
runs the repro when the finding is about behavior, and keeps only what holds up.
Two providers finding the same bug raises confidence, not severity. When seats
disagree, `bstack-judge` settles it. It loops until no blocker is left, three
rounds at most.

With one plan connected, the council is one seat, and the report says so.

## `/ready`

```text
/ready
```

The finish line for any build playbook:

1. Re-read the job and check each part is done.
2. Run the tests and the real path the change touches.
3. Run the council and fix what holds up.
4. Run `/unslop` on the diff.
5. Stage everything. No commit, no push.
6. Report in five lines: what changed, what ran, what the council found, what is left.

## tuicr: your review

When the desk goes `done`, tuicr opens on the staged change (`Ctrl+Shift+R`
opens it any time). Leave comments on lines. The agent waits for them with the
`review` skill, fixes them, and stages again.

You commit and open the PR. That is the line bstack does not cross without
being asked. After it, autopilot takes over.

**Pitfall:** accepting every finding. Reviewers, human or model, mix real
catches with noise. The council drops what it can't show, and says what it
dropped.

Next: [Ship with autopilot](./06-autopilot.md).
