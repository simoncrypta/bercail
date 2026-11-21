---
name: decisions-on-cards
description: Every decision Shep needs from the person goes on a card in the Decisions panel, bound to what will still be true when it is acted on, and Shep acts on each answer once. Applies whenever the person's choice changes what happens next.
---

# Decisions go on cards

**Intent:** The person follows many desks and is often not in Shep's chat. The
Decisions panel is where decisions wait and get answered, and the question
ledger, not the transcript or a summary, holds the answer. A decision asked
only in chat is easy to miss, and its answer is hard to bind to the job it
was about.

**Evidence:** What is being decided; the repo and the job (issue or trail) it
belongs to; the desk, when there is one, and any warning the card shows about
it; for a land, the staged tree; the
choices and Shep's pick. For an answer: the card's state in the ledger, and
the live state the action depends on, read again when acting.

**Decision:** Is this a decision, where the person's answer changes what
happens, or ordinary talk? Is it a two-way door that may default to Shep's
pick after a timeout, or a one-way door that waits for the person? What will
the decision bind to after the action runs? A commit moves HEAD and keeps the
tree, so an approval to land binds to the staged tree, not HEAD.

**Execution:** The card first, then the same question in chat, in words: the
desk's space name, the change's size and stakes, the choices, a short brief
and a recommendation. When an answer arrives, Shep checks it against the
ledger and the live state, and acts once. A defaulted answer is reported as
defaulted, never as the person's choice and never as an LGTM, until the person
says OK to it on the card. A card that no longer applies is withdrawn with a
reason.

**Recovery:** A desk problem (gone, another job's terminal, no session
claim) is a warning on the card, not a reason to skip it: the card binds to
the repo and job. When the card is refused anyway, Shep asks in chat, says the
question is not on the panel and why, and files the gap. An answer in chat is
not a pick: the guard still asks the person before any action it covers. When
a chat answer could fit more than one card, Shep asks which. When the ledger
cannot be read, Shep stops deciding rather than rebuilding an answer from
chat.

**Failure modes:**

- A decision asked only in chat.
- An approval bound to something the approved action itself changes.
- Handing a step that needs an answer to a worker nobody watches.
- Shep answering its own card, or taking a bare "yes" for whichever card is
  newest.
- Acting on one answer twice, or calling a default the person's pick.

## Seen in the ledger

G5: `decision-asked-only-in-chat` (deleting old remote branches, asked with
no card) and `asked-in-chat-without-card` (the card, tried afterwards, was
refused because the desk belonged to another job).

G4, Exact-binding authority. Most of its fix removes the exact bindings
(plan jobs J5 and J10); the conduct left is binding a decision to what
survives the action: `approval-invalidated-by-planned-commit` (twice, the
commit of the approved tree moved HEAD), `interactive-write-in-background`
(twice, a background Shep reached an approval prompt nobody could answer),
`review-card-desk-session-unbound` (twice, a card refused for a live desk with
no session claim; in v0.18 that is a warning on the card), `graphite-autopilot-publication-boundary` (the job forbade
the push its own action needed), `executor-assignment-not-durable`, and
`closed-task-unpublished-followup`.
