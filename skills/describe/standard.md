# The change description standard

A change description is the PR body, or the commit message in a repo that
commits straight to main. Its reader was not there: a reviewer, a teammate a
year from now, or nobody before it merges. It must let them understand the
change without asking.

## What it answers, in this order

1. **Intent.** What changes, and for whom, in one or two sentences. This is the
   title (the PR title or the commit subject) and the opening line.
2. **Why.** The problem or the ask, in words. Link a public tracker (a GitHub
   or Linear issue) when there is one. Never a local tracker's id: a beads id
   (`bd-a1b2`) or a desk name means nothing to a reader outside this
   machine.
3. **How.** The approach, and each choice a reviewer could disagree with next
   to the option not taken: approach, scope, dependency, schema, api,
   behavior, migration, flag. Not a list of files.
4. **Validation.** Each command that ran, its result (exit code, counts) and
   what it proves. Manual checks are marked manual. Say what was not tested,
   and why.
5. **Risks and what's left.** Rollout or data risks, and follow-ups. "None" is
   fine when it is written out.

## Shape

- A PR body fits on one screen: 40 lines at most.
- A commit message is a subject of 72 characters or fewer in the repo's style,
  a blank line, then the body. bercail's style is `area: what changed`.
- Each change lands as one commit whose message is the description: the commit
  itself in a direct-commit repo, the PR's amended commit on Graphite, or the
  squash-merge commit on GitHub and Origin.

## Provenance

The text ends with one line that says an agent wrote it and whether a person
reviewed it: `Written with bercail (Pi, claude-opus-5-5); reviewed by Simon`,
or `...; not yet reviewed`. bercail adds it when it prints the description,
from facts only: the model the desk's record names, and a reviewer only when
one is given. Never write it by hand. The repo's policy picks the form:
`provenance = "line"` (the default), `"trailer"` (`Assisted-by:` and
`Reviewed-by:` git trailers), or `"none"`.

## A repo's template

- The template's headings are the sections, in its order and with its names.
- Each part above goes in the closest section. A part with no fitting section
  gets a short section of its own at the end. Validation and risks are never
  dropped.
- A heading is never left empty: give it content, or `None: <why>`.
- A label line with nothing after it (`Loom:`) is removed, unless the repo's
  rules require it; then it says `none (<why>)`.
- No template comment (`<!-- ... -->`) or placeholder is left in.

## Never

- A claim the diff or the validation evidence does not back: "tests pass"
  without naming them, "no behavior change" when there is one, a check that
  did not run or failed.
- Empty sections, placeholder lines, or leftover template comments.
- Filler: throat-clearing, puffed words, a summary of what was just said.
- A file-by-file inventory.
- Secrets, session ids, beads ids, or local paths outside the repo.

## Grading someone else's description

The same five parts. A description is:

- **complete** when it answers all five and agrees with the diff,
- **thin** when a part is missing (often intent or validation),
- **contradicts** when it says something the diff does not do, or misses
  something the diff does that a reader would need to know.

Missing parts and contradictions are separate findings. Style is not graded.
