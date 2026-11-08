# Review it

bstack proves a change by running it. `/ready` runs tests, the repo's verify
skill and formal checks. Adversarial review is there when you ask for it.

## `/ready`

```text
/ready
```

The finish line for any build playbook:

1. Re-read the job and check each part is done.
2. Run the tests that cover the diff.
3. Follow the repo's `.agents/skills/verify-<repo>` skill, when it has one.
4. Run any formal check whose coverage the diff touches.
5. Ask `bstack-judge` one question: does the diff match the issue?
6. Run `/unslop` on the diff.
7. Stage everything. No commit, no push.
8. Report what changed, each check with its exit code and evidence path, the
   judge's answer, and what is left.

A headless run also records the checks in the result file's `verification`
array ([handoff](../handoff.md)).

## `/council`

```text
/council
```

With no target, it reviews the uncommitted change. It also takes a branch
(`/council the branch against master`) or a PR (`/council pr 42`).

Every `bstack-council-<plan>` seat gets the same brief, in parallel, without
seeing what the others said. Each seat must prove a finding with a run: a
failing test, a repro, or command output. The lead reruns it and keeps only what
reproduces. Style, naming, YAGNI and anything unproven are dropped, not
reported. When you ask for fixes, it fixes what it kept and runs again until no
blocker or major finding is left, three rounds at most.

The seats exist only with `council = true` in `[bstack]`, after `bercail
update`. With it off (the default), `/council` still works: the lead reviews
alone by the same rules and says the panel did not run.

## tuicr: your review

When the desk goes `done`, tuicr opens on the uncommitted change (how and when:
[review](../review.md)). Leave comments on lines, then ask the agent to wait for
them (the `review` skill); it fixes them and stages again.

You commit and open the PR. That is the line bstack does not cross without
being asked. After it, autopilot takes over.

**Pitfall:** accepting every finding. Reviewers, human or model, mix real
catches with noise. The council reports only what a rerun confirms.

Next: [Ship with autopilot](./06-autopilot.md).
