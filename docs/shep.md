# Shep, the orchestrator

**Shep orchestrates coding agents in the Herdr app through bercail.** It writes beads issues, hands each one to a desk, follows the desks, and tells you what came back. It does not write project code: every coding job runs in a visible desk. It hands jobs to bstack, on Pi.

Shep ships with bercail. Its rules are one file, [`shep/SHEP.md`](../shep/SHEP.md), and it runs on Pi: bercail starts Pi in Shep's own folder and session, on the models bstack already uses. Nothing to set up beyond bercail.

## Let Shep set it up

[Shep](https://x.ai/bot/Yber1TlDZinVy6FQZcPsF) is also a Grok Bot template. Add it, connect this computer to it, and ask it to set up bercail. It installs bercail, checks your plans and repos, and connects the desk webhooks, asking before it runs anything.

## How Shep runs a job

Bercail's workflow (beads issues, named stages, result files, review when a desk is done) is designed around Shep. Shep owns the workflow; bercail runs what Shep asks for and reports back in files Shep reads:

1. Shep writes the job as a [beads](https://beads.gascity.com/) issue (`bd create`): the ask, the repo, links, and any "plan only" note.
2. Shep picks a stage for that issue and runs `handoff-spawn --branch <name> --stage bstack --issue ID` (see [handoff](handoff.md)). bercail never picks the stage and never falls back to another one.
3. bercail checks `bd` and the issue, adds a `bd comment` with the worktree, and starts Pi in a new desk with a one-line prompt pointing at the issue.
4. When the desk finishes or blocks, Shep hears about it [as a message in its session](#desk-events). It reads the [brief](#briefs-and-the-board) for the issue (its desk's state, the question when it is blocked, the latest report, cut short) and reports to you. `hc wait <desk>` also works (`desk` and `space` are in the spawn JSON).

The Shep that ships with bercail never runs headless stages: a coding job or a code follow-up is always a desk you can see. Waiting is different: Shep never blocks its own thread on CI, a deploy, a desk, or a release, and hands that to a [background Shep](#background-sheps). `handoff-spawn` still has headless stages for other callers; a headless run opens nothing in the app, returns when it ends, and leaves `.bercail/handoff-result.json` (`ready`, `blocked`, or `failed`).

To review someone else's PR there is no issue and no stage: Shep runs `bercail review-pr <PR url-or-branch>` and reads the printed JSON for the whole stack. Shep states each PR's intent and CI. Non-thin decisions passes are queued in the review space's visible desk session (parallel headless passes without Herdr), and each PR's `run.json` says when it is `ready`. Read `prs[].thin` and `prs[].pass`: only flagged PRs wait for a decision. For each flagged PR, ask whether to review anyway (`bercail review-pr run N --stack DIR`) or ask the author. A thin PR must not hold up the rest of the stack. When all cards are ready, the desk writes the stack summary shown above the picker. See [review](review.md#someone-elses-pr-bercail-review-pr).

Shep never types into a desk. To move a desk to another model when you ask, or when a [standing rule](#standing-rules) lets it, Shep runs [`bercail desk model <desk> <provider/model[:thinking]>`](config.md#a-desks-model), which the desk takes as a model switch, not as chat.

Bercail works without Shep, but Shep is the intended orchestrator. To do Shep's part by hand, write the issue with `bd create`, then run the same `handoff-spawn` command.

## The Shep view

The bercail layout opens on Shep: its terminal fills the window, with the spaces and agents on the right. It is the control room for every desk; the desks stay in their spaces.

- **Start.** The app starts Shep once per session as one hc terminal, `bercail-shep` (label `bercail.role=shep`), outside every space. The terminal runs `bercail shep run`, which starts Shep on Pi. A Shep that is already running, after a window restart for example, is shown again rather than started twice. Quit it and it stays quit until you click **Start Shep**.
- **Spaces.** Click a space to see it, or press `Ctrl+Space` and search for it: the navigator moves left and the space's desk, tabs and panels fill the rest. **Back to Shep** at the top of the navigator, or `Ctrl+Shift+H`, returns to the same Shep session. Nothing is started or stopped by switching, and the keyboard goes back where it was in each view.
- **Agents.** Click an agent or a desk in the agents list to open its own terminal in a dialog over either view. While it is open, what you type goes to that agent; nothing is sent for you. ✕ or a click beside the dialog closes it and puts the keyboard back where it was; **Show in space** goes to its space.
- **Decisions.** **Decisions N** in Shep's header shows or hides the [Decisions panel](#the-decisions-panel): what Shep asks you, a card each, read-only, with **Discuss** to take it up in Shep. A new card changes the count, nothing else.
- **Authority.** The view only shows things. Shep's tools and approvals are Pi's with bercail's guard, the same as in any other terminal, and the desks' rules don't change. Shep loads the same guard as the desks, so a repo's trusted [git policy](config.md#git-policy-per-repo) lets Shep's commits and pushes there through as it does a desk's. Shep sits in its own folder, not a repo, so instead of a policy in its prompt it runs `bercail policy show <repo>` before it commits, merges, pushes, or releases. It commits or opens a PR with the description the desk's `/validate` wrote (`bercail describe commit|body`), never one of its own; a stale one goes back to the desk. A [high-stakes](config.md#review-by-stakes-and-size) change waits for your LGTM before Shep commits or merges it, even in a repo that integrates straight to main and even under a standing rule to merge without asking.

When Pi exits with an error, its message stays on screen until you press Enter.

## Shep on Pi

Shep on Pi runs in `~/.local/state/bercail/shep/workspace` with its sessions in `pi-sessions/` beside it, whatever folder you are in, and continues the same session each time it starts (`pi --continue`). It uses bstack's lead model and Pi extensions (from `~/.local/share/bercail/pi/lead.json`); the same logins as your desks. Its rules and its [start context](#what-shep-knows) are passed with `--append-system-prompt`, and it loads no context files, so your global Pi `AGENTS.md` (your Pi persona) is neither changed nor read by Shep. Its Pi extensions include `inbox.ts` for [desk events](#desk-events), `compaction.ts` for [compaction](#compaction), and `question-commands.ts` for [targeted questions](#targeted-questions). It gets the `handoff`, `review`, `desk-restore`, `how`, `why`, `unslop`, and `describe` skills, and Pi's own tools. It needs `pi` on the PATH (`bercail bstack setup` installs it).

```bash
bercail shep status      # queued, awaiting persistence, persisted notices, live background Sheps
bercail shep repos       # your known repos: git backend, policy trust, open issues (--json too)
bercail shep board       # one line per open job across those repos, then what waits on you
bercail shep queue       # what waits on your review, with sizes and stakes (--repo DIR: against its budget)
bercail shep brief ID    # one issue: its desk and state, the question it is blocked on, the latest report
bercail shep list        # Shep's standing rules: remember "RULE" [--scope S] adds one, forget N drops one
bercail shep mistake list  # the mistakes ledger: mistake KEY "WHAT" [--repo DIR] [--issue ID] records one
bercail shep diagram FILE  # a Mermaid diagram without its click and link statements (stdin without FILE)
```

An older `~/.config/bercail/config.toml` may still have `backend` and `session` under `[shep]`. bercail no longer reads them; delete them whenever you like. The keys `[shep]` holds now are for [compaction](#compaction).

## Diagrams in chat

Pi draws a `mermaid` code block in Shep's replies as Unicode box art (Pi's `markdown.mermaid` setting, on by default; Shep leaves it so). Shep draws one only when a flow has three or more states or branches, as a `stateDiagram-v2` or `flowchart TD` of about 15 nodes at most, with no deep nesting. Past that the art stops being readable: a 40-state graph with cross jumps came out four screens tall with its labels cut. Edge labels stay under about 20 characters, and only one edge is labeled where a state branches, because labels on edges leaving the same row print over each other. Other guards go in the text. Every diagram is followed by its transitions as a plain list, which is what you read when the art degrades and what a screen reader gets. A diagram too wide for the pane, or over 128 nodes, shows as its source instead.

Pi turns a diagram's `click` and `link` targets into terminal hyperlinks, `javascript:` ones included. HTML labels, `%%{init}%%` directives and `url(...)` styles print as text or are ignored, and nothing is fetched. So a diagram Shep did not write, such as a PR's `chart.mmd` or one in a desk's report, goes through `bercail shep diagram` before Shep pastes it. It prints the diagram without its `click` and `link` statements (`click A href "url"` is one), and says on stderr how many it dropped. It errs toward dropping. The renderer deletes control characters before it parses and splits words on Unicode spaces, so `cl\x01ick` or a no-break space before `click` still makes a link. The helper deletes the same control characters from every line, splits statements on `;` outside double quotes, and skips any leading space or non-ASCII character before it looks for the word, in any case. A statement that merely starts with the word, such as a state named `link`, goes too. Other lines are printed as they were, less those control characters.

## What Shep knows

Shep's session is one long conversation, and most of it is tool output. What it needs to know for good sits outside it, in files bercail keeps, so a compaction or a new session loses none of it.

### Known repos

Shep needs no list of your repos to keep up. bercail works it out each time from what it already knows:

- the `[git]` and `[policy."<path>"]` keys of `config.toml`,
- trusted policies (`~/.local/state/bercail/policy-trust.json`),
- handoff records (`~/.local/state/bercail/handoffs.jsonl`); a record whose worktree is gone gives its main checkout, from the `<main>.<branch>` name `handoff-spawn` uses,
- the folders of live desks,
- and `~/.local/state/bercail/shep/repos`, one path per line (`#` starts a comment), for a repo bercail has not seen yet.

Each folder becomes its main checkout; one that is no longer a git checkout drops out. `bercail shep repos` prints a line per repo: the path, its git backend (as `handoff-spawn` picks it), its [policy](config.md#git-policy-per-repo) (`policy trusted`, `policy untrusted`, or `no policy`), its open issues (not closed; `no beads` when it has no `.beads` or `bd` does not answer within 10 seconds), and where bercail saw it. `--json` gives the same as an array.

### Briefs and the board

`bercail shep brief <id>` is what Shep reads for a desk event, in place of `bd show` and `hc read --lines 60`:

```
app-1: Fix the login timeout
in_progress P1 bug · labels auth · repo ~/Work/app
desk t9 blocked · space Login-timeout_App (sp98de) · branch login-timeout · worktree ~/Work/app.login-timeout
desk t9 is blocked; its screen ends with:
  | Allow git push origin login-timeout? (y/n)
(the whole screen: hc read t9 --lines 60)
latest report: comment 2 of 2, Desk at 2026-11-11 00:43 (812 characters):
Staged, uncommitted. What changed: …
```

The repo is `--repo DIR`, else the issue's handoff record, its live desk, or the known repo whose `bd` has it. When the job's worktree has staged changes, a `staged:` line gives their size and [stakes](config.md#review-by-stakes-and-size), and says when the change waits for your LGTM. The desk is the live terminal labelled with the issue, else the record's (`gone` when it has ended). A desk [handed off with `--model`](handoff.md) ends its line with `model <provider/id:thinking>`, from its `bercail.model` label, or the record's when it has ended. A blocked desk adds the last 15 lines of its screen, where its question is. The report is the latest comment that is not the handoff note. One longer than `--budget` characters (1500 by default) keeps its first two thirds and its last third, and says how much was cut and that `bd comments <id>` has the rest. Measured on three real issues, a brief was 1,600 to 2,000 characters (about 400 to 500 tokens) against 31,000 to 54,000 for `bd show` plus `hc read --lines 60`: 16 to 33 times smaller.

`bercail shep board` lists one line per open job across the known repos: `<id>: <title>`, its status when not `open`, its desk and state, its branch, and its model when it was handed off with `--model`. A job is an issue that is not closed and has a live desk, or is `in_progress` or `blocked`. A repo's other open issues are a count, with how many of them were handed off to a desk that has since ended. Then: the repos with no jobs, desks still open on closed or unknown issues, and **Waiting on the person**: blocked desks, finished desks to review, and finished background Sheps to report and end.

When anything waits on your review, the board ends with the **review queue**, which `bercail shep queue` prints on its own:

```
Review queue: 13 lines in 3 changes
~/Work/app: 13 of 10 lines, over its review budget
- app-2: Add the export · 6 lines staged in 1 file · stakes high, needs the person's LGTM · ~/Work/app.export
- PR #12: Teammate fix · 4 lines · https://github.com/o/app/pull/12
- PR #15: Old job PR · 3 lines · https://github.com/o/app/pull/15
- not counted: app-3: Old job · 2 lines staged in 1 file · stakes low · issue closed, a cleanup candidate · ~/Work/app.old
```

A staged change is on the queue when its desk is not working (done, idle, blocked, or gone); a desk still working is not waiting on you yet. Each one has a state, read from records, never from prose:

- **review**: it waits on you. **lgtm**: the same, and its policy wants your LGTM (it touches a `high_stakes` path).
- **superseded**: `bd supersede` or `bd duplicate` names its issue's replacement, or the issue's latest handoff went to another worktree that is still there (the job moved to a fresh one).
- **cleanup**: its issue is closed. The worktree is left over; remove it, don't review it.
- **unknown**: bd cannot say (the repo has no beads, or bd does not answer for the issue). It still counts, and the line says why.

Superseded and cleanup work is listed last as `not counted` and stays out of the budget. Parent and child links are not read: a child issue does not say it replaces its parent. A change with no issue is review. On a repo with a GitHub remote, an open PR counts when it is not a draft, not approved, and either asks you for a review or comes from a handoff's branch. A staged change's lines leave out lockfiles, generated and binary files; a PR's leave out lockfiles. Each repo's total is weighed against its policy's [`review_budget`](config.md#review-by-stakes-and-size). Before Shep starts a desk it runs `bercail shep queue --repo <checkout>`; when that repo is over budget, Shep tells you what waits and asks whether to start it anyway.

`bercail shep queue --json` is the same queue as data (`schema: "bercail.queue/v1"`), for the Herdr app: `at`, when it was read; `items`, what waits first, the longest waiting first (`since`: when a worktree's changes were last staged, or when a PR was opened), each with its `state`, `why`, `by` (the replacement), `counts`, its `space` (the desk's or the handoff's Herdr space) and its `change` (size and stakes); and `repos`, each repo's counted lines against its budget.

### Review in the Herdr app

The bercail layout's spaces list reads that JSON every five minutes, and after a desk's status changes (at most every 30 seconds). It only shows what bercail says; nothing it reads switches your view or moves the keyboard.

- A space whose work waits on you has a mark after its name: `◆` and the lines that wait, with `?` when its state is unknown. The mark is red when a change there needs your LGTM, and the theme's accent color when review is optional. A cleanup candidate's space says `cleanup`, and superseded work `superseded`, in a dim color. Hover a mark for each item; the tooltip says "needs your LGTM" where it applies, so the red is not the only cue. In the narrow rail, the space's number takes the same color.
- The Spaces header counts what waits (`◆ 3 to review`, red while one needs your LGTM, or `2 to clean up` when only that is left), and adds `(stale)` when the last good read is more than 15 minutes old or the last read failed.
- `Ctrl+Shift+J` goes to the next space that waits, in queue order, from either view ([keys](keys.md)).
- A click on the count opens the **Review** list over either view: each item's space (as Herdr names it), issue and title, lines, stakes, whether it needs your LGTM, how long it has waited, and its state, then what does not count. The header says when bercail read the queue, and whether that is stale or the last read failed. **Open space** shows the space; **Open review** shows it and opens its Review tab; **Open PR** opens a PR in the browser. There is no merge, commit or LGTM button, and nothing answers a desk.

### Standing rules

A rule you give Shep in conversation ("merge bercail work straight to master", "you may answer cm0's prompts") would otherwise live only in its session. Shep records it as soon as you say it, and tells you:

```bash
bercail shep remember "Merge finished desk work straight to master and push" --scope bercail
bercail shep list        # 1. 2026-11-11 [bercail] Merge finished desk work straight to master and push
bercail shep forget 1
```

They live in `~/.local/state/bercail/shep/preferences.md`, one `- DATE [SCOPE] RULE` line each; `--scope` is a repo, an issue, a desk, or `all` (the default). The same rule and scope twice is kept once. A rule for everyone who uses bercail belongs in [`shep/SHEP.md`](../shep/SHEP.md) or a repo's [policy](config.md#git-policy-per-repo) instead.

### Mistakes

A mistake that shows up twice should get a guardrail, not a second fix by hand. Shep keeps a ledger of them in `~/.local/state/bercail/shep/mistakes.jsonl`, one line each time: when, a short key, what happened, and where (repo and issue).

```bash
bercail shep mistake tests-touch-real-state "the handoff test wrote to the real handoffs.jsonl" --repo ~/Work/bercail --issue bercail-4k9
bercail shep mistake list   # each key with its count, most frequent first
```

A key is a-z, 0-9 and `-`, the same each time. When a key reaches its second time, the command says so, and [`SHEP.md`](../shep/SHEP.md) has Shep write an issue for a guardrail (a lint rule, a test, the guard, or a doctor check) and tell you.

### The start context

Each `bercail shep run` writes `~/.local/state/bercail/shep/context.md` and hands it to Pi with `--append-system-prompt`: the known repos, one short line each, and the standing rules. A restart picks up repos and rules that changed while Shep was down.

## Targeted questions

Questions have durable tokens such as `Q42@3`, independent of the conversation.
In text-only Shep:

```text
/questions                 list pending questions, choices and exact targets
/reply Q42@3 yes           propose an answer to that revision only
/thread release-plan       return to that topic's question context
/thread all                clear the selected topic
```

A bare `yes`, `1` or `LGTM` answers nothing, even when one question is pending.
An omitted or stale revision is rejected; a conflicting answer is retained as
rejected rather than overwriting the first proposal. Repeated request IDs are
idempotent; reusing an ID with different content is an error. New notices never
select a thread or change focus. This remains one Pi conversation with shared
context, not separate threads with isolated histories.

**Replies are unverified proposals, not approvals.** Pi commands can be called
by extensions; `interactive`, RPC and terminal keystrokes are not proof of a
human sender. This slice has no trusted confirmation channel and no public
`approve` or `--confirmed` switch. All replies leave the question pending.
`answered` is reserved for a future verified ingress. A proposal never permits
a desk prompt, guard approval, commit, merge, publication, spend or scope change.
Use existing human review/guard procedures separately; a narrative summary
cannot upgrade a proposal into permission.

Shep's `shep_question` tool creates or revises a question after verifying the
explicit checkout/job and desk session against existing beads, hc and
`desk-sessions` records. It does not discover jobs from a bare issue ID. Repo
identity is the canonical local git common-directory path, shared across its
worktrees; another clone is a separate local identity. Review/action questions
record desk, space, session, worktree, intended action, head, staged tree, and
resolved base plus its ref. A planning question records no head or staged tree,
so new commits leave it fresh. Changed intent or candidate supersedes the old
revision; prior proposals remain in history.

### The Decisions panel

Every decision Shep asks you is also a card in the Shep view. **Decisions N**
in Shep's header counts the pending ones; click it to show or hide the panel
under Shep's terminal. A new card only changes the count: nothing opens, moves
or takes the keyboard.

Each card says, in words, where (the desk's space as Herdr names it), what (a
change's lines and stakes), what Shep asks, its choices, and when it was asked;
the panel says when it last checked. A card whose candidate changed since Shep
asked (new commits, a new staged tree, another base, or the desk) says
**stale** and what changed: Shep must ask again. One it cannot check (the desk
ended, the policy could not be read) says **unknown** and why. Question tokens
are the ledger's keys and never show. The panel reloads when the ledger
changes, and every 30 seconds while it shows. With a
[`[herdr] backend`](config.md#bercail-on-another-machine), it reads the
questions on that machine every 30 seconds, shown or not.

The panel is read-only: you answer in Shep's chat. **Discuss** selects the
question's topic (as `/thread` does) and puts the keyboard in Shep's terminal,
so Shep's next turn has that topic's questions. The topic stays selected, and
Shep's question state stays that topic's, until another Discuss or `/thread all`.

Why no answer buttons: a click there would have to count as your decision, and
nothing on a desktop like this one can show a click came from you. Herdr's own
scripted paths cannot click (keys, the palette, `herdr-app do` and toasts reach
a mod's commands, never its click handlers), but any program running as you
can: `/dev/uinput` is often writable by the logged-in user, `wtype` types, and
Hyprland gives every client a virtual pointer. Herdr sees those events exactly
as yours. The ledger is also a plain file every desk can write.

The CLI works without Pi or a mod too:

```bash
bercail shep questions              # bounded pending projection
bercail shep questions --json       # full snapshot and retained revisions
bercail shep question check Q42@3   # recheck candidate/mapping and current policy
bercail shep question thread release-plan
bercail shep question panel         # the Decisions panel's JSON: pending questions, each checked
```

`question create`, `revise` and `reply` read JSON on stdin. For example, a
planning topic without a desk:

```bash
printf '%s\n' '{"requestId":"plan-1","kind":"planning","prompt":"Which approach?","options":["small","full"],"origin":{"event":"conversation:entry-7","session":"shep-session","entry":"entry-7"},"repo":"/path/to/repo","issue":null,"topic":"release-plan","desk":null,"base":null,"action":null}' | bercail shep question create
printf '%s\n' '{"requestId":"answer-1","token":"Q1@1","answer":"small","source":"local-cli:unverified"}' | bercail shep question reply
```

For a job, provide its issue and exact desk address; review/action also require
an action and base ref. `revise` uses the same fields plus `token` and a new
request ID. A revision cannot change repo, job or topic: create another question
instead. `check` always reports `authority: false`, including when fresh. Recheck
target and policy again through existing procedures before an authorized action;
this helper does not execute one or close a race with a separate shipping command.

State lives in `~/.local/state/bercail/shep/questions.json` (or under
`$XDG_STATE_HOME`). Kernel `flock` serializes read/modify/write across processes;
fsync plus atomic rename preserves the previous complete snapshot on interruption.
Process death releases the lock. A corrupt store fails closed and is not
replaced. Selected topic persists separately from incoming notices. Before each
model run and in compaction/rollover, Shep reloads this store rather than
reconstructing question state from narrative. The bounded projection shows up
to 20 pending questions; the JSON snapshot contains the full history.

A read-only Herdr board, unread/reconciliation UI, isolated conversation views
and a provenance-checked confirmation channel are not part of this slice.

## Compaction

Pi compacts a session when its context passes `window - reserveTokens`: it summarizes the older part and keeps the most recent `keepRecentTokens` word for word. Pi's defaults (16384 and 20000) let Shep's 1M-token window fill to about 984k tokens first, which Shep's single session never reached. Shep gets its own numbers, and its own summary.

### Settings

bercail writes Shep's compaction into its workspace's `.pi/settings.json`, which Pi reads as project settings, and Shep leaves `~/.pi/agent/settings.json` alone (bstack's [bridge reserve](bstack.md#how-it-runs) lives there):

```json
{"compaction": {"enabled": true, "keepRecentTokens": 50000,
  "modelOverrides": {"claude-bridge/claude-opus-5-5": {"keepRecentTokens": 50000, "reserveTokens": 750000}}}}
```

Pi loads project settings only from a folder you trust, and `--no-context-files` does not change that: without trust they are skipped, or Pi asks. Shep's workspace is a folder only bercail writes to, so Shep starts Pi with `--approve`, which trusts it for that process and saves nothing. Other keys in that file are kept; bercail rewrites `compaction` at each start, from `config.toml`:

```toml
[shep]
compact_at = 250000   # context tokens at which Pi compacts Shep; 0 leaves Pi's threshold
keep_recent = 50000   # recent tokens kept word for word
rollover = false      # true: a fresh session instead of a threshold compaction, and each new day
```

`compact_at` becomes `reserveTokens = window - compact_at` for the lead model, with its window from `pi --list-models` (1M for Opus 5.5, so 750000). Why 250k: most of Shep's context is `bd`, `hc` and log output that is stale once a job moves on, and every turn sends all of it again; past a quarter of the window that costs time and money for nothing, and a compaction starts over from a fresh board. Why 50k: the last several desk events and your last exchanges stay as they were, briefs included, while the summary is rebuilt. When bercail cannot place `compact_at` (not a number, not below the window, or a window `pi --list-models` does not show), Pi's threshold applies and bercail says why at start. On a model whose window is 250k or less, the default `compact_at` leaves Pi's threshold without a word. On a `claude-bridge` model the reserve is never below bstack's 40000, so a `compact_at` within 40k of the window compacts at `window - 40000` instead, before Claude Code refuses the prompt. Changes take effect at Shep's next start.

### The summary

`compaction.ts` builds the summary Pi saves, for `/compact` and for automatic compaction alike, from four parts:

1. **The job board**, from `bercail shep board` at that moment. It replaces whatever the old messages said about jobs.
2. **The standing rules**, from `preferences.md`.
3. **Durable questions**, reloaded from the ledger with IDs/revisions and unverified proposals. This is a snapshot; `/questions` reloads it.
4. **Narrative decisions and discussion** from Pi's `serializeConversation` text. The model is told not to reconstruct question state or approval authority. This rationale is not permission to act.

If any part fails (the board, the model, an empty answer), it returns nothing and Pi compacts the default way: the session is never lost. Each compaction, each fallback with its reason, and each failed compaction (`session_compact_failed`) is a line in `~/.local/state/bercail/shep/compaction.log`.

### Rollover

With `rollover = true`, Shep does not compact forever. When the context passes `compact_at`, it skips that compaction and, as soon as Shep is idle, starts a fresh session whose first message is the board, rules and durable questions and names the previous session's file. The first turn on a new day does the same. `/shep-rollover` in Shep does it by hand, whatever the setting. A rollover that fails (the board does not build, say) is logged, and compaction takes over again until Shep restarts.

To go back to the old session, run `/resume` in Shep and pick it; the rollover's first message names its file. Once you write in it, it is the most recent session in `pi-sessions/`, so `bercail shep run` continues it from then on.

## Background Sheps

Shep never watches, waits, polls, or sleeps on anything itself. When something needs waiting on (a CI run, a deploy, a desk, a release), or a step you approved has to happen once it is done, Shep writes it as a beads issue (what to wait for, what to do after, when to stop, what not to do), starts a background Shep on it, tells you in one line, and goes back to you.

```bash
bercail shep bg --issue bercail-ow2                    # from the issue's repo
bercail shep bg --issue bercail-ow2 --cwd ~/Work/bercail
```

It prints `{address, name, cwd, issue, issue_title}`. The background Shep is one hc terminal named `shep-bg-<id>`, started in the background with no space, so nothing in the app moves or takes focus; the agents list shows it. It runs `bercail-desk-agent` on the same Pi setup as a desk (bstack's lead from `lead.json`, with the guard, so the repo's [git policy](config.md#git-policy-per-repo) applies), plus a brief of its own, [`shep/BACKGROUND.md`](../shep/BACKGROUND.md): do only what the issue says, never ask in its terminal (post on the issue with `bd comment` and stop instead), post the result as a `bd comment`, and close the issue only when it says to. Its first message is one line pointing at the issue. A second `bg` for an issue whose background Shep is still live is refused.

Its labels are `bercail.role=agent`, `bercail.shep=bg`, `bercail.issue`, and `bercail.issue_title`, with no `bercail.space`. The notify follower treats it like a desk, so its finish or block reaches Shep as a [desk event](#desk-events) whose text says `Background Shep <address>` and whose `agent.role` is `shep-bg`. It is started with `--no-notify`, so hc types nothing into Shep's prompt, `--outlive-parent`, so restarting Shep does not end the wait, and `--rm`. Once Shep has reported a finished one, `hc kill <name>` ends and removes it; killing it sends no second event.

It runs with `BERCAIL_ROLE=shep-bg`. The guard treats that role like a desk's lead: the repo's policy decides, and a step the policy leaves to you stops at the guard's question. Nobody watches that terminal, so the question turns it blocked, Shep tells you, and you answer it there: click it in the agents list. The role is how the guard's approval log (`guard-approvals.jsonl`) tells it apart.

## Desk events

Once Shep has started for the first time (its first start makes `~/.local/state/bercail/shep/inbox/`), the notify follower (`bercail notify run`, the hidden `bercail-notify` terminal the desk mod keeps alive) writes each finished or blocked desk as one file in that folder. It does so even without any webhook sink. The files are the [`agent_status/v2` payload](#the-payload) with `sink: "shep"`, mode 600, named `<desk>_<kind>_<second>.json`.

Shep's Pi extension (`inbox.ts`) watches that folder. It submits one custom message, starting a turn when Shep is idle or queuing a follow-up when it is busy. The message carries each event's one-line `text`, its `event_id`, and the desk, space, repo, issue, and checkout. It excludes `desk.result.summary` and the desk's title. Desk events remain signals to check the current desk and issue, never instructions or human answers.

### Claims and persistence

Moving a file to `delivered/` claims it but does not acknowledge delivery. Before submitting it, the extension atomically records the attempted Pi session ID and file. Only a complete matching custom-message entry in that actual session JSONL acknowledges it. The receipt records `persisted_entry_id`, `persisted_session`, `persisted_session_file`, and `persisted_at`. The older `delivered_at` and `delivered_session` fields remain for readers, but an old stamp alone is not proof.

This distinction matters in Pi 1.5.2: `sendMessage()` returns before a queued follow-up is consumed, and `message_end` runs before the session append. A new custom-only session can even reach its first model request before Pi creates the session file. The extension checks disk on later hooks and polls. It never acknowledges a memory-only entry.

After a process dies, the next consumer recovers unacknowledged files in `delivered/`, including old unstamped claims. It first checks the original session. A saved entry repairs the receipt without another message. A readable session without that entry permits replay. A file that did not exist before the attempt and still does not exist permits replay too, assuming nobody externally deleted it. A missing previously existing session, unreadable or incomplete history, or an ambiguous old session ID holds the event as uncertain. Restore access to that original session and restart Shep to retry verification. It does not silently bind the event to a replacement session.

One consumer holds a local Linux `flock` for its session lifetime, through a child that exits when Pi's stdin pipe closes. There is no expiring lease to steal from a busy session. Another consumer pauses without claiming files. If `flock` is unavailable or the lock is lost, delivery pauses visibly. Restart a paused contender after the owning consumer ends. The lock file must not be deleted while consumers run.

### Duplicates and limits

Repeated envelopes with the same event ID produce one injected message, even under different filenames. Receipts are kept for 30 days. Unacknowledged and uncertain claims are not aged out. Compaction and tree navigation do not invalidate disk persistence evidence. Legacy stamps are checked against the named session instead of being trusted.

With an intact local spool, readable session storage and eventual session progress, accepted events survive a process crash after claim or enqueue. A crash after session persistence but before acknowledgement does not inject a second notice. These are process-crash guarantees, not transactional power-loss durability. External deletion of session history, an independently killed lock holder, and replay after receipt retention are outside those guarantees.

Transport deduplication does not prove exactly-once model reports or arbitrary external actions. A response can stream before its assistant entry is saved, and an external action can complete before its result is recorded. Shep must recheck current source state and use action-specific idempotency where available. Persistence means neither handled, action-completed, nor read by the person. No read or handled acknowledgement is invented here.

The follower's existing filename heuristic is unchanged: it omits the process ID and coalesces changes for the same desk and kind in the same second. It can miss or coalesce source transitions before spool acceptance. The delivery guarantee applies to retained accepted envelopes, not to every historical desk transition.

### Reconciliation after follower gaps

The existing notify follower also writes one private `source-state.json` beside the inbox. It is a current projection from snapshots and status changes, not a second job database or an event log. It includes observed timestamps and desk/space/repo/issue/checkout mappings, but no desk-authored prose, results, event IDs or human answers. Whole snapshots replace gone mappings.

When a done, idle or blocked source mapping has no represented inbox notice, Shep receives an explicitly **reconstructed, possibly stale history-gap observation** with its observation time and a separate local notice ID. That ID is not a historical finish or block event ID. Identical represented observations are suppressed. For status transitions that enqueue an event, the follower queues it before publishing that transition's source state. Shep reads `source-state.json` before claiming the inbox so those writes landing mid-drain cannot also produce a reconstructed notice. A source snapshot cannot recover intervening transitions, a vanished desk, historical completion times or answers. Check the current board or brief before acting.

### Proving it arrived

`bercail shep status` separates queued files, claims awaiting persistence (including uncertain holds), persisted notices and quarantined malformed files. It names the last persistence receipt. In the session, a notice is a `custom_message` with `customType: "bercail-desk-event"`. Its presence is distinct from Shep's subsequent reply or your reading it.

## agent status webhooks

`bercail notify run` follows the desk agents (hc terminals labelled `bercail.role=agent`) with `hc events` and posts their status changes to webhooks, one sink per bot. The desk mod keeps it running as the hidden hc terminal `bercail-notify`. It sends only these:

- `finished`: working or blocked → done or idle
- `blocked`: once each time the agent blocks

Sinks are `~/.config/bercail/notify.d/<name>.toml` (`chmod 600`; see [`notify.sink.example`](../config/agentic-dev/notify.sink.example)). They filter by space name glob, repo, and kind. The key is sent through a private header file, never through argv. A 401 or 403 is recorded and logged; `bercail notify status` and `bercail doctor` show it. Without sinks, and before Shep's first start, the follower idles. `bercail update` restarts a running follower so it runs the new code. `bercail doctor` flags a live follower that missed a desk finishing or blocking.

### Add a sink

`bercail notify add NAME` sets up a sink in one step. It prompts for the webhook URL and the sender key (hidden), writes the file with mode 600, and sends a test. The running follower picks the new sink up on its next delivery, without a restart. A 401 or 403 means the key or the auth mode is wrong.

```bash
bercail notify add work-shep                       # paste the URL, then the key
bercail notify add work-shep --auth bearer --all-repos --notify finished
printf '%s\n%s\n' "$URL" "$KEY" | bercail notify add work-shep --yes   # no terminal
bercail notify status          # sinks, filters, last HTTP code; never prints url or key
bercail notify test work-shep
bercail notify repo add work-shep              # add this checkout's repo to the sink
bercail notify repo remove work-shep myapp
```

`notify add` options: `--auth both|bearer|x-automation-key|none` (default `both`), `--repos LIST` (default: the current checkout's repo, or every repo outside a checkout), `--all-repos`, `--spaces GLOBS`, `--notify finished,blocked` (default both), and `--yes` to replace an existing sink without asking. If the sink exists, it shows it redacted first; without `--yes` it asks on a terminal and refuses without one. With no terminal it reads the URL, then the key, one per line from stdin; `BERCAIL_NOTIFY_URL` and `BERCAIL_NOTIFY_KEY` skip their prompt. It never takes the key as an argument, so the key stays out of shell history and the process list.

### Repos no sink covers

A desk in a repo that no enabled sink covers posts nowhere, so bercail says so. `handoff-spawn --branch` prints one warning on stderr with the `bercail notify repo add` command that fixes it (the spawn still goes ahead), and `bercail doctor` lists each repo with a live desk that no sink covers. `bercail notify check [PATH]` runs the same check by hand. With no sinks at all there is nothing to warn about. `notify repo add` and `remove` change only the sink's `repos` line. On an `--all-repos` sink they do nothing and say so. `remove` refuses to take out the last repo of a sink with no `spaces` filter, because no repos and no spaces means every repo.

Older sink files may have a `panes = agent` line. `agent_status/v2` has no panes: the key is ignored, and the follower drops the line when it starts.

### The payload

Each POST body is `bercail.agent_status/v2`:

```json
{"source":"bercail","schema":"bercail.agent_status/v2","kind":"finished","sink":"work-shep",
 "at":"2026-10-29T22:42:00Z","event_id":"t9:finished:1793312520:4242",
 "agent":{"address":"t9","app":"pi","status":"done","previous_status":"working","title":"...","role":"desk"},
 "space":{"id":"sp98de","name":"Render-preview_Leftlane_app","repo":"leftlane_app","checkout_path":"/path/desk","linked":true},
 "desk":{"branch":"feat/render","issue":"lef2745-2vs","issue_title":"Fix the login timeout","stage":"bstack","harness":"pi",
         "result":{"status":"ready","summary":"...","session_id":"..."}},
 "text":"lef2745-2vs: Fix the login timeout. Desk t9 (Render-preview_Leftlane_app) finished."}
```

`agent.address` is the hc terminal (`hc get`/`hc read` it). `agent.role` is `desk`, or `shep-bg` for a [background Shep](#background-sheps). `desk.issue` and `desk.issue_title` are the terminal's `bercail.issue` and `bercail.issue_title` labels when it has them. `desk.issue`, `desk.issue_title`, `stage`, and `harness` otherwise come from the matching `handoffs.jsonl` record (`harness` falls back to `agent.app`; `issue_title` is null when that record has none); a record or result for another issue than the labels name is left out. `desk.result` is `status`, `summary` (its first 500 characters), and `session_id` from the checkout's `.bercail/handoff-result.json` when one exists (usually `null`: headless runs have no desk terminal, so they send nothing). `text` is one line for a person: `<id>: <title>. Desk <address> (<space name>) finished.` or `is blocked.` (`Background Shep <address>` for a background Shep); the bare id when there is no title, no parentheses when the space has no name, and `Test from bercail (sink <name>).` for a test post.

**Headless runs send nothing.** Only desks (`handoff-spawn --branch`) have a terminal the follower can watch. For a headless run, `handoff-spawn` returns when the run ends and `.bercail/handoff-result.json` holds the outcome. To wait on a desk without the webhook, use `hc wait <desk>`.
