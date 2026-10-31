---
name: unslop
description: >-
  Cleans the tells of machine writing out of prose (READMEs, PR bodies, commit
  messages, replies, docs) and out of a diff (narrating comments, guards for
  states that cannot happen, dead code, unrelated edits). Keeps the meaning. Use
  when asked to unslop, deslop, tighten, or clean up text or a change, and before
  anything a person will read.
---

# unslop

Slop is text that sounds like writing and says less than its length. Cut it
until each sentence carries one thing the reader needs. Do not add content,
claims, or sections. Extra rules from the person ("no emdashes", "keep it under
ten lines") win over this file.

## Target

- Named text or files: those.
- "the diff", "the change", or nothing named: `git diff HEAD` plus untracked
  files. Only lines this change adds; leave old code alone.

## Prose

Fix each of these where it shows up:

- **Throat-clearing:** "It's worth noting", "Importantly", "In order to", "Let's
  dive in", "Great question". Delete it and start with the point.
- **Puffed words:** robust, seamless, leverage, comprehensive, crucial, delve,
  elevate, streamline, cutting-edge, game-changer, ensure (when "make sure" or
  nothing works). Use the plain word, or drop it.
- **Em dashes and semicolons** stitching clauses together. Split into sentences,
  or use a comma or colon.
- **Hedges stacked on hedges:** "may potentially", "could possibly help to".
  Say it, or say you don't know.
- **The contrast trick:** "This isn't just X, it's Y." Say Y.
- **Lists of three** made for rhythm, not because there are three things.
- **Bold on every other phrase**, headings over a four-line answer, emoji as
  bullets.
- **A summary of what was just said**, a closing offer ("Let me know if…").
- **Hidden actors:** "the file was updated". Say who or what updated it.
- **Over-compressed notes:** dropped articles and verbs ("fixed parser, added
  test, cleanup"). Write sentences.
- **Numbers and claims with no source.** Cut them or cite them.

Keep the author's voice and terms. A terse README stays terse.

## Code

In the target lines only:

- comments that narrate the code or the edit ("// loop over users", "// added
  for the fix"). Keep the ones that say why a reader would otherwise get it wrong,
- guards, fallbacks, and try/catch for states the types or callers already rule
  out; catch blocks that swallow the error,
- debug output, commented-out code, unused imports, params, and exports,
- a helper, option, or layer with one caller and no reason to exist apart,
- compatibility paths nobody calls,
- edits outside the job (reformatting, renames, drive-by fixes). Revert them or
  name them.

Match the code around it: its naming, its comment density, its error style.

## Finish

- Prose: return the rewrite. For a long text, list the kinds of change in one
  line, not each edit.
- Code: make the edits, rerun the tests the change touches, keep them staged
  (`git add`). Report what you removed in three lines or fewer.
