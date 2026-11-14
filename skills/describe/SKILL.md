---
name: describe
description: >-
  Writes, checks and ships a change's description: the PR body, or the commit
  message where the repo commits straight to main. Follows standard.md and the
  repo's PR template, records what it describes so a stale one cannot ship, and
  gives each forge the text as written. Use at /validate, when autopilot changes
  a PR, when Shep commits or opens a PR, and to grade someone else's PR body.
---

# describe

Read [standard.md](standard.md) first: what a description answers, its shape,
the template rules, and what it never contains. This file is how to write one
and ship it.

## Files

Both live in the worktree's `.bercail/`, which git ignores (`bercail describe
stamp` adds it to `info/exclude` when the repo does not). They are never
committed.

- `.bercail/validate.json`: the checks /validate ran for the staged tree.

  ```json
  {"tree": "<git write-tree>", "checks": [{"kind": "test", "command": "bash tests/run.sh", "exit_code": 0, "evidence": "all passed"}]}
  ```

- `.bercail/description.md`: frontmatter, then the body that ships.

  ```markdown
  ---
  title: <the intent, 72 characters or fewer>
  ---
  <the body>
  ```

  `stamp` adds `tree` (the staged tree it describes), `template`, `agent`
  (the harness and model from this desk's record), `stakes` (`high` when a
  staged path matches the policy's `high_stakes`, else `low`) and `review`
  (`required` when the person reviews it before it lands). The style is `commit` when
  the policy integrates straight to main, else `pr`. When the repo has several
  templates, name yours with `template: <path>`.

## Write it

1. Stage the whole change first. The description describes the staged tree.
2. `bercail describe template`: the template to follow, `none`, or the
   choices. On a `commit` style repo there is no template: a subject in the
   repo's style (`git log --format=%s -20`), a blank line, then the body.
3. Write `validate.json` from the commands you ran on this tree, with
   `"tree": "$(git write-tree)"`. Only commands that ran: a check you skipped
   is not evidence.
4. Write `description.md` to the standard. Its validation names the commands in
   `validate.json` and their results.
5. `bercail describe stamp`, then `bercail describe check`. Fix every `fail:`.
   Read every `warn:` and fix the ones that are real. A change over the
   policy's `diff_budget` (lines added and removed, without lockfiles,
   generated and binary files) warns: split it, or say in the body why it is
   one change.

Any change to the staged tree after that makes the description stale: a tuicr
fix, a review fix, a rebase. Rerun the checks it touches, update
`validate.json` and the parts of the text it changed, then stamp and check
again.

## Ship it

Only when the person or the job asks, and the way the repo's git policy says.
Use the text as written: never write a body or a commit message from scratch,
and never patch the forge's copy by hand. `bercail describe title|body|commit`
prints it and refuses a stale or failing description. When it refuses, the
desk reruns /validate. `body` and `commit` end with the provenance line (see
the standard). Pass `--reviewed-by "<name>"` only when that person reviewed
this exact change, for example in tuicr; otherwise it says not yet reviewed.
Where the repo commits straight to main, `commit` refuses a change whose
`review` is `required` until it gets `--reviewed-by`: the person gives their
LGTM first.

Each change lands on the trunk as one commit whose message is the
description. A direct-commit repo gets one commit per finished job. On `gt`,
a fix after review amends the PR's commit. On `gh` and `origin`, a fix is a new
commit on the PR branch, and the PR lands by squash-merge with the description
as the squash commit's message. bercail never force-pushes there. On `entire`
(a repo hosted on Entire), the trail is the PR, and Entire writes the merge.
The person merges: the guard stops agents at a merge or a trail approval, and
nothing auto-merges.

A squash or a reworded amend drops each commit's `Entire-Checkpoint` trailer,
the link to the agent sessions that wrote it. `--checkpoints <base>` carries
the trailers of `<base>..HEAD` into the text. It changes nothing where there
are none, so the commands below always pass it.

| Repo | Open the PR | After a review fix | Land it |
|------|-------------|--------------------|---------|
| direct | `bercail describe commit \| git commit -F -` | the next job is a new commit | the commit is on the trunk |
| `gh` | `bercail describe commit \| git commit -F -`, push, then `bercail describe body \| gh pr create --title "$(bercail describe title)" --body-file -` | commit the fix, push, then `bercail describe body \| gh pr edit <n> --title "$(bercail describe title)" --body-file -` | `bercail describe body --checkpoints origin/<base> \| gh pr merge <n> --squash --subject "$(bercail describe title)" --body-file -` |
| `gh` stack | `gh stack submit --auto`, then the `gh pr edit` above in each layer's worktree | the same, in the layer's worktree | each PR squash-merged as above |
| `gt` | `gt create -m "$(bercail describe commit)"`, `gt submit --no-edit --no-ai`, then the `gh pr edit` above | `gt m -a -m "$(bercail describe commit --checkpoints HEAD~1)"` (`gt modify --all`), `gt submit --no-edit --no-ai`, then `gh pr edit` | the PR's one commit already carries it |
| `origin` | as `gh`, with `bercail describe body \| origin pr create --title "$(bercail describe title)" --body-file - --status open` (`--stack-on <parent>` for a stack) | commit the fix, push, then `bercail describe body \| origin pr edit <n> --title "$(bercail describe title)" --body-file -` | `bercail describe body --checkpoints origin/<base> \| origin pr merge <n> --squash --subject "$(bercail describe title)" --body-file -` (one PR at a time: a stack merge takes no message) |
| `entire` | `bercail describe commit \| git commit -F -`, then `entire trail create --title "$(bercail describe title)" --body "$(bercail describe body)"`: it publishes the branch (`--base <parent>` for a stack) | commit the fix, push, then `entire trail update --title "$(bercail describe title)" --body "$(bercail describe body)"` | the person runs `entire trail merge` once the trail's gates pass; it takes no message, so the trail carries the description |

- A stack layer describes its own diff against its parent. Each layer's
  worktree has its own description.
- Read the backend from `handoff-spawn --info`. Never run `gt` in a `gh`,
  `origin` or `entire` repo.

## Grade someone else's

bercail review-pr grades a PR's description against standard.md: missing parts
apart from claims that contradict the diff, with questions for the author. It
never blocks on style.
