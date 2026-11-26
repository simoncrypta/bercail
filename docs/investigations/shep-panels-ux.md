# Shep's Decisions and Routines panels: a UI/UX review

Review for bercail-e4vw, 2026-11-25, against commit `5e5c9e6`. Mod code is
`bercail/mods/bercail-shep/main.js` (below, `main.js`). It is checked against
the left-column layout that bercail-1hub has in progress. This is a
**proposal**: no code changed, and no issue was created. The fixes at the end
are proposed beads issues for Simon to accept, cut or merge. The judge
(gpt-6.2-astra) reviewed a first draft. Its corrections are folded in, and
what was dropped is listed under [Superseded](#superseded).

Each finding is marked:

- **Observed**: seen in an isolated Herdr app (below).
- **Read**: from the code or docs, not driven.
- **Inferred**: reasoned from the two above, not seen.

## Conclusions

1. **The Decisions keys can answer a card the person never chose.** The keys
   act on an index (`this.sel`), not a card, and moving it never scrolls.
   Three paths were seen to record a pick on a card that was out of view:
   - ↓ ↓ Enter.
   - Scrolling to another card with the wheel, clicking its text, then Enter.
   - A card above the selection leaving on a reload, which moves the
     selection to the next card.

   *Observed.*
2. **Nothing in the panel shows that it has the keyboard.** A click into it
   takes the keys from Shep. The only pixels that change are Shep's cursor,
   which turns hollow. *Observed.*
3. **One card does not fit.** At the default 260 px under Shep, the oldest
   card, a defaulted commit, fills the panel and hides its own OK and Reverse.
   In bercail-1hub's column at its 280 px minimum, with Routines shown too,
   less than one card shows. Cards follow ledger order, oldest first, so the
   newest card and its clock sit furthest down. *Observed.*
4. **The card's kind and clock read last.** The kind (planning, action,
   review, guard) is never shown. The clock is 11 px text in the footer. The
   title is a folder name. *Observed.*
5. **Routines works but has no keyboard.** Esc does not close Ask Shep, and a
   routine with a problem keeps its place in config order. *Observed.*

Fixes for 1 and 2 come first. bercail-1hub's working tree already wraps the
card footer, which settles the clipping this draft first found (see
[Superseded](#superseded)). See [Proposed issues](#proposed-issues).

## How it was checked

An isolated Herdr app 0.1.18 ran under Xvfb. It had its own `HOME`,
`XDG_RUNTIME_DIR` (so its own herdr-core) and display, never the person's.
Each display was checked free before use. It loaded this checkout's
`bercail/layouts/bercail.json` and mods. For the left layout, it loaded a copy
of bercail-1hub's uncommitted layout and mod, read from
`~/Work/bercail.shep-panels-left` without touching it.

A stand-in `bercail` on that `PATH` answered `shep question panel` and
`routine list --json` from fixtures, logged `shep question answer`'s stdin,
and ran a stand-in Shep that only echoes. Input went in through a small XTest
program. Pictures came from `herdr-app shot` and are in
`shep-panels-ux/shots/`. The scripts were scratch and are not kept.

The fixture cards follow the door rules (`shep/pi/questions.ts:811-822`; a
review never defaults, `docs/shep.md:293`), listed in ledger order:

| Token | Kind | State |
|-------|------|-------|
| Q35 | action, commit | defaulted to Commit; the desk is gone |
| Q38 | planning | stale; past its deadline |
| Q40 | review | one-way; LGTM recommended |
| Q41 | planning | two-way; defaults in about 25 min |
| Q42 | action | one-way; approves pushing `refs/tags/v0.42.0` |
| Q43 | guard | counts as a Deny in about 55 min |

Three routines: one active with findings, one running, and one paused after 3
failures.

Limits:

- Zoom was 1.0. Simon runs 1.2, which leaves less room.
- Real Shep, the real ledger checks and real load times were not exercised.
- The Discuss dialog was not opened.
- The stand-in never removes an answered card. Removal was simulated by
  editing the fixture before the 30-second reload.

## Decisions panel

### Selection and scrolling

- **↓ does not scroll.** ↓/↑ change `this.sel` (`main.js:1318-1319`). The
  list has `overflow_y_scrollbar()` and no `ScrollHandle` (`main.js:1263`),
  so nothing reveals the selected card. Herdr has `scroll_to_item`
  (`gpui-kit.d.ts:21294-21300`). After ↓ ↓, `shots/2-keys-select-offscreen.png`
  shows no selected card in view. Enter then recorded
  `{"token":"Q40@1","choice":"LGTM","source":"panel picker"}`, a one-way
  review. In the first draft's run, ↓ Enter on a push card recorded
  `Push it` the same way. *Observed.*
- **The wheel and a click on a card's text don't move the selection.** The
  panel root takes focus on mouse down (`main.js:1273-1275`). Only a click on
  a choice chip selects a card (`main.js:1366-1372`). With Q40 selected, I
  wheeled to Q41, clicked its brief and pressed Enter. The panel recorded
  LGTM on Q40, while Q41 and its "Answer By source" button were the only
  card in view (`shots/3-wheel-click-enter.png`). *Observed.*
- **The selection is an index.** `this.sel` is only clamped to the list
  length (`main.js:1260`), while the picked choice is kept per card
  (`this.picked[token]`, `main.js:774`). When a card above the selection
  leaves, the keys move to the next card. In `shots/4-selection-moves.png`,
  the push card was selected (top). After the card above it left on the
  reload, the border sat on the guard card (bottom). Pressing `1` and Enter
  there would have sent Allow, refused only by its own rules. *Observed.*
- **An answered card hands the keys to the next one.** After a pick, the card
  leaves on reload (`main.js:1529`). The same index then names the next card,
  whose picker starts on Shep's recommendation (`main.js:506-509`). An Enter
  after that reload answers it. A second Enter before the reload does
  nothing, because each card takes one record at a time
  (`main.js:1499-1502`). *Inferred.*
- **Held keys repeat.** `key()` doesn't look at `e.is_held`
  (`main.js:1310-1324`; `gpui-kit.d.ts:468`), so a held Enter or `x` repeats
  on whatever the index names next. *Read.*
- **New cards go to the bottom, and the view never moves.** The panel lists
  the ledger in order (`shep/pi/question-cli.ts:347`). New questions are
  pushed onto the end (`shep/pi/questions.ts:1048`, `:1068`). A reload keeps
  the scroll position, by design (`main.js:330`: "Data never moves the view
  or the keyboard"). That keeps the person's place, but a new card appears
  out of sight, with only the header count to tell. *Read.*
- **At 260 px, the panel shows less than one card.** It has no "1 of 6" and
  no "more below". The scrollbar shows only while scrolling. *Observed*
  (`shots/1-below-default.png`).

### What reads first on a card

Order today (`main.js:1384-1460`). From `shots/6-cards-bottom.png`, the
two-way planning card:

```
bercail                                                          open
Plan for bercail-5mfe: routines show findings by source?
Group a routine's findings by where they came from (HEY, Readwise), or keep…
Shep recommends By source: inbox-triage mixes three sources
[1 By source ★] [2 One list]
asked 21:39       two-way door: defaults to By source in 24 min  [Discuss] [Close] [Answer By source]
```

- **The title is a folder.** It is `where`: the space name, else the
  worktree or repo folder (`main.js:417-422`), in semibold. Cards without a
  worktree read `bercail`, the boldest text on the card. The ledger has
  `target.issue` (`shep/pi/questions.ts:19`), but the panel's JSON leaves it
  out (`shep/pi/question-cli.ts:366`, `:384`), and `topic` is not an issue.
  *Observed, Read.*
- **The kind never shows.** `card.kind` decides what the card can do
  (`main.js:496`), but it is never rendered. The guard card has the same
  layout, colors and border as a review. *Observed.*
- **The clock is last, small, and only relative.** It is 11 px in the
  footer (`main.js:1405-1406`). A two-way door reads "defaults to By source in
  24 min", while the ledger takes it at Shep's next check after the deadline,
  and only if the card is still fresh (`docs/shep.md:289`). A guard card
  reads "waits for you: a Deny in 54 min" (`main.js:408`). A one-way door
  shows nothing, the same as a clock not yet loaded. *Observed.*
- **Explanations crowd out the action.** The defaulted card's explanation
  runs to five lines at 280 px (`main.js:450`; `shots/9-left-min-both.png`).
  *Observed.*
- **"open" is noise. "stale" is red, but its reason comes after the
  choices** (`main.js:456`, `:1398`). *Observed.*
- **The recommendation is in the dimmest color** (`t.dim`, `main.js:1392`),
  after the brief. *Observed.*
- **The push line reads well.** It is in foreground color, says what the
  choice approves, and names the refs (`main.js:474-476`). Keep it, and keep
  it out of any "More" fold. *Observed.*
- **Briefs never truncate** (`main.js:1391`). A land card's brief lists each
  effect a pick allows (`shep/pi/question-cli.ts:312-335`). A guard card's
  brief names the command and every pinned fact (`docs/shep.md:434`). A fold
  must never hide those. *Read.*

### Keys and focus

Today (`main.js:1310-1332`; `docs/shep.md:307-318`): ↑↓/k j card, ←→/1-9
choice, Enter answer, `o` OK a default, `r` reverse, `x` close, `a` ask
again, `d` discuss. Routines has no keys (`main.js:1039-1099`, no focus
handle).

- **No focus cue.** The root tracks a focus handle (`main.js:1273`), but no
  render reads `is_focused()`. The selected card's solid border is drawn
  either way (`main.js:1382`). A shot before and after a click into the
  panel differs only in a 6×16 px area, Shep's cursor. *Observed.*
- **A reply meant for Shep can act on a card.** Plain letters act: "do it"
  opens Discuss, "ok" OKs a default, and a trailing Enter answers. *Inferred*
  from the bindings and the missing cue; not typed.
- **No way out by key.** Esc isn't handled (`main.js:1329`). The keyboard
  goes back to Shep on a click in its terminal, or on a pointer move into it
  with focus follows mouse (`main.js:972-982`). *Read.*
- **The only way in is a click, and that is a contract.** "Keys never come
  from a command (nextCommand): only this panel" (`main.js:1257`). Herdr's
  scripted paths "reach a mod's commands, never the panel"
  (`docs/shep.md:324`, from 537b128). *Read.*
- **The comment overstates the header toggle.** It says opening the panel
  from the header gives it the keyboard (`main.js:1256`). The toggle only
  runs `layout.show` (`main.js:1247-1251`). The comment is wrong, not the
  behavior; showing and taking the keys should stay apart. *Read.*
- **The keys hint is one truncated line.** `KEYS_HINT` (`main.js:105-106`)
  sits after the counts in a `truncate()` cell (`main.js:1289`). At 1280 px
  it ends at "a asks again on a s…". In the left column, "↑↓ car…". At 280 px
  it is gone. It lists keys that don't apply to the card and shows whether or
  not the panel has the keys. *Observed.*
- **No key conflicts.** Every key in `bercail/keys.json` and
  `bercail/herdr-keys/keys.json` takes Ctrl, Alt or Shift, apart from `f2`.
  The panel uses bare keys. *Read.*

### Mismatches that cost a pick

- **The Discuss bar tells a guard card to use `/pick`.** On any card that is
  neither defaulted nor reversed, the bar reads "read-only branch · /pick
  answers" (`main.js:1574-1579`). The branch refuses `/pick` on a guard or
  land card (`shep/pi/discuss.ts:566`; `shep/pi/questions.ts:1145-1146`).
  The bar's ✕ also means something other than the card's Close: ✕ goes back
  and tells Shep, while Close withdraws the card. *Read.*
- **An expired guard card still offers Allow.** `answerable()` checks
  `card.deadline` (`main.js:483-484`), which is null on a guard card
  (`shep/pi/question-cli.ts:381`), not `guard.expires`. Until the card
  leaves, Allow looks enabled, and the ledger refuses it with "it expired at
  …" (`shep/pi/questions.ts:1149-1150`). Deny is meant to work then. *Read.*
- **No receipt.** After Enter, the card just leaves on the next load. `D.done`
  is set only for Ask again (`main.js:1493`, `:1527`), and its banner stays
  until the next record. *Read.*
- **A stale card a day old sits among the fresh ones**, needing Ask again or
  Close, not a pick (`shots/5-cards-top.png`). *Observed.*
- **Errors keep the old cards.** A failed load keeps `D.view` and adds a red
  line (`main.js:311-313`, `:1293`). Only "checked HH:MM" dates the cards. A
  pick still runs its live check. *Read.*
- **Load time grows with the cards.** Each card gets a live check. A card
  with a worktree that is not planning or guard also gets `bercail describe
  check` (up to 10 s), one after another (`shep/pi/question-cli.ts:349-365`),
  under a 60 s timeout (`main.js:305`). *Read*; not measured.
- **The header shows counts, never a clock.** `Decisions 5 · 1 defaulted`
  (`main.js:1252`). The stale card is counted as waiting on you
  (`main.js:285`). With the panel hidden, a two-way door can default unseen.
  *Observed.*
- **The empty states are clear.** "Nothing waits on you." Routines says where
  to declare one. Keep them. *Read.*

## Routines panel

(`shots/7-routines-narrow.png`)

- **Each card is one routine's latest state**: its last run and up to three
  new or changed findings, which can be older than the last run after quiet
  runs (`main.js:611-658`). It is not a feed. A reload never moves the list.
  *Observed, Read.*
- **The hierarchy is good**: name semibold, schedule dim, state word tinted,
  the problem in red, findings in foreground. In the left column, the
  schedule truncates first ("ever…", `shots/9-left-min-both.png`).
  *Observed.*
- **A broken routine can be off screen.** The list is in config order. The
  header says `1 paused`, the same words as a pause by hand, and doesn't name
  it. *Observed.*
- **Esc does not cancel Ask Shep.** The field takes the keyboard and Enter
  sends (`main.js:1182-1190`). Esc changed no pixel. Cancel needs the mouse.
  *Observed.*
- **"and 2 more: bercail routine show deps-watch --run r5"** is a command
  printed as UI (`main.js:658`). *Observed.*
- **"Sent to Shep at HH:MM" stays until the next ask** (`main.js:1217`).
  Acceptable. *Read.*

## Against the left-column layout (bercail-1hub)

bercail-1hub's working tree (uncommitted on 2026-11-25) has these:

- A full-width Shep header, then a row: a `shep-side` column of 280-520 px at
  weight 2 against the terminal's 3, holding Decisions and Routines at equal
  weight (its `bercail/layouts/bercail.json`).
- In the mod, `togglePanel` shows the side column with the first panel and
  hides it with the last.
- A card footer that wraps (`.flex_wrap()`, with a spacer after "asked").

What that means here (`shots/8-left-layout.png` at 1280 px,
`shots/9-left-min-both.png` at 900 px):

- **The footer no longer clips.** It wraps to two or three rows, Answer
  last. *Observed.*
- **Height helps only with one panel.** With Decisions alone at 1280 px, the
  column shows one and a half cards. With both panels at the 280 px minimum,
  the defaulted card's OK and Reverse are below the fold. *Observed.*
- **The keys hint is gone at 280 px, and the Shep header truncates its
  title.** *Observed.*

## Proposals

### P1. The keys act only on the card the person chose

- Keep the selection as a card token (`selToken`).
- Deliberate moves set it: ↑↓, a click anywhere on a card, a chip.
- After a deliberate move, `scroll_to_item` reveals the card, top first, so
  the prompt shows even on a card taller than the panel.
- A reload never scrolls and never moves the selection. When the selected
  card leaves, nothing is selected, and the next card must be chosen.
- A recording key (Enter, `o`, `r`, `x`, `a`) on a card that is not fully in
  view first reveals it and records nothing. The next press records.
- Held keys (`is_held`) never record.
- A card whose pick is hard to undo starts with no choice, with ★ still
  shown as advice. That covers a choice that approves a push, a guard
  card's Allow, and a high-stakes review. Picking is a chip, a number or an
  arrow, then Enter.

Before: ↓ ↓ Enter, or the wheel plus a click on a card's text, then Enter,
records on a card out of view (`shots/2`, `shots/3`).

```
│ Plan for bercail-5mfe: routines show findings by source?      │ ← in view, clicked
│ [1 By source ★] [2 One list]                                  │
│ … [Answer By source]                                          │
└───────────────────────────────────────────────────────────────┘
                                    Enter → LGTM on Q40, out of view
```

After: the click selects the card under it, and Enter answers what shows.

```
┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
┃ Plan for bercail-5mfe: routines show findings by source?      ┃ ← selected
┃ [1 By source ★] [2 One list]                                  ┃
┃ [Answer By source]  Discuss  Close                            ┃
┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛
                                    Enter → By source on Q41
```

After a card above leaves:

```
Decisions  Q42 was answered elsewhere; pick a card    checked 21:47
┌ ACTION · bercail · pushes a tag                          ┐ ← nothing selected
```

### P2. Show where the keyboard is; Esc gives it back

- The render reads `this.h.is_focused()`.
- Focused: the panel's top border is `accent`, the selected card's border is
  `solid`, and the hint row lists only the keys this card takes now (no
  Allow on an expired guard card, no Ask again where `reaskable` is false).
- Not focused: no solid card border, and the hint row reads "Click a card to
  use keys".
- Esc moves the keyboard to Shep's terminal (`pane.focus {terminal}`), the
  same target as `focusPlan` (`main.js:181`).
- The header toggle still only shows the panel. Fix the comment at
  `main.js:1256` instead.

Hint row before:

```
Decisions  5 waiting on you · 1 defaulted · ↑↓ card · ←→ or 1-9 choice · Enter answers · o OKs a defa…
```

After, focused, on Q41, at 280 px (two lines, never truncated):

```
Decisions · keys                                       checked 21:47
Enter By source · 1-2 choice · d discuss · x close
↑↓ card · Esc Shep
```

After, not focused:

```
Decisions  5 · 1 defaulted                             checked 21:47
Click a card to use keys
```

### P3. Kind and clock first; Discuss and expiry tell the truth

- **Title row**: `KIND · where · size · stakes`, with the clock right
  aligned. `where` is the issue when the panel JSON carries it: add
  `target.issue` to `panel()` (`shep/pi/question-cli.ts:366`).
- **Prompt**: the strongest type on the card.
- **Recommendation**: next, in `muted`.
- **Brief**: after it. Clamp long briefs, except a push line or a guard
  card's pinned facts.
- **State**: drop "open". Put the reason a card is stale or defaulted under
  the title, in one line. The defaulted explanation moves into its OK and
  Reverse buttons' tooltips.
- **Guard cards**: a 3 px left border in `blocked`.
- **Discuss bar** on a guard or land card: "Discuss here · answer on the
  panel card". Its ✕ tooltip: "Back, without answering".
- **Expired guard card**: `answerable` and `takes` treat it as past its
  deadline, so Allow is off and Deny stays.

Clock wording, absolute first, because a time does not go stale between
reloads:

| State | Today | Proposed |
|-------|-------|----------|
| two-way, fresh | two-way door: defaults to By source in 24 min | By source after 22:10 if unchanged · 24 min |
| two-way, stale | two-way door: past its deadline; it waits for you while it is stale | due 21:38 · waits while stale |
| guard, counts as Deny | waits for you: a Deny in 54 min | a Deny after 22:40 · 54 min |
| guard, defaults to Allow | defaults to Allow in 54 min, if it still reads private or local | an Allow after 22:40 if still private or local · 54 min |
| one-way | (nothing) | no deadline |

Two-way card, before (`shots/6-cards-bottom.png`):

```
┌──────────────────────────────────────────────────────────────────┐
│ bercail                                                     open │
│ Plan for bercail-5mfe: routines show findings by source?         │
│ Group a routine's findings by where they came from (HEY,         │
│ Readwise), or keep one list newest first.                        │
│ Shep recommends By source: inbox-triage mixes three sources      │
│ [1 By source ★] [2 One list]                                     │
│ asked 21:39  two-way door: defaults to By source in 24 min       │
│                            [Discuss] [Close] [Answer By source]  │
└──────────────────────────────────────────────────────────────────┘
```

After:

```
┌──────────────────────────────────────────────────────────────────┐
│ PLAN · bercail-5mfe          By source after 22:10 if unchanged  │
│ Plan for bercail-5mfe: routines show findings by source?         │
│ ★ By source: inbox-triage mixes three sources                    │
│ Group a routine's findings by where they came from (HEY,         │
│ Readwise), or keep one list newest first.                        │
│ [1 By source ★] [2 One list]                                     │
│ [Answer By source]  Discuss  Close                  asked 21:39  │
└──────────────────────────────────────────────────────────────────┘
```

Guard card, before:

```
┌──────────────────────────────────────────────────────────────────┐
│ bercail.land-wait-commit                                    open │
│ Allow push of land-wait-commit to origin?                        │
│ git push origin land-wait-commit:land-wait-commit, from the      │
│ desk Land-wait-commit_Bercail. Pinned: head 9f8e7d6, remote      │
│ origin (git@github.com:simoncrypta/bercail.git). Nobody          │
│ answering counts as a Deny: it is not private or local.          │
│ [1 Allow] [2 Deny]                                               │
│ asked 21:39       waits for you: a Deny in 54 min                │
│                             [Discuss] [Close] [Pick a choice]    │
└──────────────────────────────────────────────────────────────────┘
```

After (the pinned facts stay whole):

```
┃ GUARD · land-wait-commit · push            a Deny after 22:40
┃ Allow push of land-wait-commit to origin?
┃ git push origin land-wait-commit:land-wait-commit, from the
┃ desk Land-wait-commit_Bercail. Pinned: head 9f8e7d6, remote
┃ origin (git@github.com:simoncrypta/bercail.git). Nobody
┃ answering counts as a Deny: it is not private or local.
┃ [1 Allow] [2 Deny]
┃ [Pick Allow or Deny]  Discuss  Close               asked 21:39
```

### P4. Stable order, and a "Next" line that jumps on request

Keep ledger order, so cards never move under the pointer. Under the header,
one line names the soonest clock: a two-way door's default or a guard card's
expiry. **Show** (or `n` while the panel has the keys) selects that card and
reveals it. That is a deliberate move under P1. The header toggle takes the
same words when a clock runs out within the hour, in `ansi3` under 10
minutes.

Panel before, left column, Decisions alone (`shots/8-left-layout.png`):

```
Decisions  5 waiting on you · 1 defaulted · ↑↓ car…   checked 21:46
┌ bercail.doctor-hc, 12 lines                       defaulted ┐
│ Commit the staged doctor check in bercail.doctor-hc?        │
│ … (five lines on what the default did)                      │
│ [Discuss] [Close] [Reverse] [OK Commit]                     │
┌ bercail                                               stale ┐
│ …                                                           │
                  (Q41's clock and the guard card: far below)
```

After:

```
Decisions  5 · 1 defaulted                          checked 21:46
Next: By source after 22:10 (Q41)  [Show]
Click a card to use keys
┌ ACTION · doctor-hc · 12 lines       defaulted to Commit 21:16 ┐
│ Commit the staged doctor check in bercail.doctor-hc?          │
│ ★ Commit: small and tested                                    │
│ Warning: the desk Doctor-hc_Bercail is gone.                  │
│ [OK Commit]  Reverse  Discuss  Close             asked 19:46  │
┌ PLAN · bercail-77qz                stale: new commits, staged ┐
│ …                                                             │
```

Header toggle, before and after:

```
Decisions 5 · 1 defaulted
Decisions 5 · By source after 22:10
```

### P5. A receipt after each record

After a recorded pick, OK, Reverse or Close, one `dim` line at the top
names it, and it clears on the next load after 10 s. `D.done` follows the
same rule.

```
Decisions  (nothing: the card just leaves)
Decisions  Answered By source on bercail-5mfe at 21:52; pick a card
```

### P6. Routines: name the problem, and Esc

Keep config order, so an open Ask Shep field never moves on a reload. The
header names the routines that need a look, with **Show** to reveal one. Esc
cancels Ask Shep.

```
Routines  3 routines · 1 paused · 1 running         scheduler ticked 21:45
Routines  3 · needs a look: ci-flakes, paused after 3 failures [Show]
```

### Key map, before and after

| Key | Today | Proposed |
|-----|-------|----------|
| ↑ ↓, k j | move an index; no scroll | move the selected card; reveal it (P1) |
| click on a card | focus only; a chip selects | selects that card (P1) |
| ← →, 1-9 | pick a choice | same; hard-to-undo cards start with none (P1) |
| Enter, o, r, x, a | record on the index | record on the selected card when fully in view; reveal first otherwise; never on a held key (P1) |
| d | Discuss | same |
| n | free | go to the card named on the Next line (P4) |
| Esc | nothing | keyboard back to Shep (P2) |
| Routines: Esc in Ask Shep | nothing | cancels (P6) |

## Proposed issues

Not created. Small is under about 80 changed lines with its test. Medium
touches several functions, the panel JSON, or docs and the recipe.

| Priority | Title | Scope | Size |
|----------|-------|-------|------|
| P1 | Decisions panel: the keys act only on the card the person chose | Selection by token; a click on a card selects it; reveal on deliberate moves only; no successor when it leaves; reveal before recording off screen; ignore held keys; hard-to-undo cards start with no choice. Tests for wheel, reload, removal, focus and a card taller than the panel (P1). | medium |
| P1 | Decisions panel: show when it has the keyboard; Esc gives it back to Shep | Focus styling from `is_focused()`, hints for the selected card only, Esc to Shep's terminal, fix the comment at `main.js:1256` (P2). | medium |
| P2 | Decisions: a guard card's Discuss bar and expiry tell the truth | "answer on the panel card" on guard and land Discuss bars; Allow off on an expired guard card (P3, last two points). | small |
| P2 | Decisions cards: kind and clock first, recommendation before the brief | Title row with kind, issue and clock time; `target.issue` in the panel JSON; drop "open"; guard border; clamp briefs except pinned facts; `bercail/RECIPE.md` and `docs/shep.md` (P3). | medium |
| P2 | Decisions: a Next line and `n` to the soonest clock | Next line with Show, `n`, the same words on the header toggle (P4). | small |
| P3 | Decisions: a receipt after each record | One line naming the record, cleared after 10 s; `D.done` too (P5). | small |
| P3 | Routines panel: name what needs a look, and Esc cancels Ask Shep | Header names the problem routines with Show; Esc (P6). | small |

## Open questions

- P1's "start with no choice": which cards? The draft's list is a choice
  that approves a push, a guard card's Allow (guard cards already start with
  none), and a high-stakes review. A land card's ship is a candidate too.
- Opening the panel by key. Deferred: `docs/shep.md:324` promises that
  scripted commands never reach the panel, and a command that hands the
  person's next Enter to the picker bends that, even if it records nothing.
  Worth revisiting only with a change to that contract.
- With both panels shown in the left column, the 1:1 split leaves Decisions
  less than a card at 280 px. Should Decisions get weight 2?
- Should a routine's finding offer Ask Shep with the finding filled in?

## Superseded

- **Footer clipping in a narrow column** (the first draft's conclusion 3 and
  its P3). Seen on master in a 700 px window, where Answer was cut off on a
  card with a clock. bercail-1hub's working tree wraps the footer, and
  `shots/8-left-layout.png` shows Answer kept. What is left is the button
  order and moving the clock, which is now part of P3 here.
- **A second Enter before a push, an Allow or a high-stakes pick** (draft
  P7). Dropped: a held key repeats, and it slows a Deny or a Hold just as
  much. P1's "start with no choice, ignore held keys" replaces it.
- **Ctrl+Shift+D to open Decisions with the keyboard in it** (draft P8).
  Deferred, see Open questions.
- **Sorting cards by urgency** (draft P5). Dropped: cards that move under
  the pointer break the place-keeping P1 is for. P4's Next line replaces it.
- **The first draft's fixtures** had a review card counting down and
  defaulting, which the ledger refuses (`shep/pi/questions.ts:811`,
  `:846-855`). Its screenshots were retaken with valid cards.
- **`main.js:1256`** says opening the panel from the header gives it the
  keyboard. It does not, and should not; fix the comment (P2).
- **`bercail/RECIPE.md:86-99`** describes the card footer as Discuss and
  Answer X. It leaves out Close, Ask again, OK, Reverse, Open trail, the
  guard card and the defaulted state. bercail-1hub edits this section; the
  rest goes with P3.
