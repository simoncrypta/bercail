# Review it

bstack proves a change by running it. `/validate` runs tests and the repo's
verify skill, writes the change's description, and has the judge check both.
Adversarial review is there when you ask for it.

## `/validate`

```text
/validate
```

The finish line for any build playbook:

1. Re-read the job and check each part is done.
2. Run the tests that cover the diff.
3. Follow the repo's `.agents/skills/verify-<repo>` skill, when it has one.
4. Run `/unslop` on the diff.
5. Stage everything. Desks stage for your review; you or Shep commit it the way
   the repo's [git policy](../config.md#git-policy-per-repo) says, so it does
   not commit even when the policy would let it.
6. Write the change's description with the `describe` skill and check it (see
   below).
7. Ask `bstack-judge`, every time: does the diff do what the issue asks (or,
   with no issue, what the description says it is for), is every claim in the
   description backed by the diff or the recorded checks, and what in the diff
   could be removed? The last is a finding to weigh, not a failure, unless it
   is work nobody asked for.
8. Report what changed, the lines added and removed, each check with its exit
   code and evidence path, the judge's answer, the description, and what is
   left.

It never commits, pushes, or opens a PR. A headless run also records the checks
in the result file's `verification` array ([handoff](../handoff.md)).

### The change description

Every change ships with a description: the PR body, or the commit message in a
repo that commits straight to main. The reader understands the intent, why, how
(with the options not taken), how it was validated, and what is risky or left,
whether you review it first, nobody does, or someone else does. The standard is
the `describe` skill's `standard.md`, the one source for `/validate`, the judge,
and [review-pr](../review.md#someone-elses-pr-bercail-review-pr).

`/validate` writes two files in the worktree's `.bercail/`, which git ignores:

- `validate.json`: the checks it ran, each with its command, exit code and
  evidence, for the staged tree.
- `description.md`: a `title:` line in its frontmatter, then the body. It
  follows the repo's PR template (`.github/`, the root, then `docs/`, or the
  policy's `pr_template`).

`bercail describe stamp` records the staged tree it describes; `bercail describe
check` fails on a stale description, a missing or empty template section, an
empty label line such as `Loom:`, a leftover template comment, a title over 72
characters, a beads id (they mean nothing outside your machine), or no checks
for that tree. When you or Shep commit or open the PR, `bercail describe
commit`, `body` and `title` print the text as written and refuse a stale one.
`body` and `commit` end with a provenance line: `Written with bercail (Pi,
claude-opus-5-5); reviewed by Simon`, or `not yet reviewed` without
`--reviewed-by`. The model comes from the desk's record; the policy's
`provenance` key picks `line`, `trailer` (`Assisted-by:` and `Reviewed-by:`),
or `none`.

Each change lands as one commit whose message is the description. On Graphite
a fix after review amends the PR's commit (`gt m -a`); on GitHub and Origin it
is a new commit, and you squash-merge with the description as the message.
bercail never force-pushes and never merges. See [commands](../cli.md).

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

`bercail update` renders one seat per plan with a model. With none, `/council`
still works: the lead reviews alone by the same rules and says the panel did
not run.

## tuicr: your review

When the desk goes `done`, tuicr opens on the uncommitted change (how and when:
[review](../review.md)). Leave comments on lines, then ask the agent to wait for
them (the `review` skill); it fixes them and stages again.

You commit and open the PR. That is the line bstack does not cross without
being asked. After it, autopilot takes over.

**Pitfall:** accepting every finding. Reviewers, human or model, mix real
catches with noise. The council reports only what a rerun confirms.

Next: [Ship with autopilot](./06-autopilot.md).
