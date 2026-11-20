# Shep, the orchestrator

**Shep orchestrates coding agents in the Herdr app through bercail.** It writes beads issues, hands each one to a desk, follows the desks, and tells you what came back. It does not write project code: every coding job runs in a visible desk. It hands jobs to bstack, on Pi.

Shep ships with bercail. Its rules are one file, [`shep/SHEP.md`](../shep/SHEP.md), and it runs on Pi: bercail starts Pi in Shep's own folder and session, on the models bstack already uses. Nothing to set up beyond bercail.

## Let Shep set it up

[Shep](https://x.ai/bot/Yber1TlDZinVy6FQZcPsF) is also a Grok Bot template. Add it, connect this computer to it, and ask it to set up bercail. It installs bercail and checks your plans and repos, asking before it runs anything.

## How Shep runs a job

Bercail's workflow (beads issues, named stages, result files, review when a desk is done) is designed around Shep. Shep owns the workflow; bercail runs what Shep asks for and reports back in files Shep reads:

1. Shep writes the job as a [beads](https://beads.gascity.com/) issue (`bd create`): the ask, the repo, links, and any "plan only" note.
2. Shep calls `bercail shep task dispatch` with the explicit repo, issue, logical target and message ([contract below](#dispatch)). It resolves existing ownership before preparing a branch.
3. An existing task continues in its original Pi/session and checkout: the message reaches that desk at its next turn, even while it works. Only a task with no owner reserves a first [visible handoff](handoff.md), with a one-line prompt pointing at the issue. Ambiguous, stale, missing or partial results stop; they never trigger a replacement or headless fallback.
4. When the desk finishes or blocks, Shep hears about it [as a message in its session](#desk-events). It reads the [brief](#briefs-and-the-board) for the issue (its desk's state, the question when it is blocked, the latest report, cut short) and reports to you. `hc wait <desk>` also works (`desk` and `space` are in the spawn JSON).

The Shep that ships with bercail never runs headless stages: a coding job or a code follow-up is always a desk you can see. Waiting is different: Shep never blocks its own thread on CI, a deploy, a desk, or a release, and hands that to a [background Shep](#background-sheps). `handoff-spawn` still has headless stages for other callers; a headless run opens nothing in the app, returns when it ends, and leaves `.bercail/handoff-result.json` (`ready`, `blocked`, or `failed`).

To review someone else's PR there is no issue and no stage: Shep runs `bercail review-pr <PR url-or-branch>` and reads the printed JSON for the whole stack. Shep states each PR's intent and CI. Non-thin decisions passes are queued in the review space's visible desk session (parallel headless passes without Herdr), and each PR's `run.json` says when it is `ready`. Read `prs[].thin` and `prs[].pass`: only flagged PRs wait for a decision. For each flagged PR, ask whether to review anyway (`bercail review-pr run N --stack DIR`) or ask the author. A thin PR must not hold up the rest of the stack. When all cards are ready, the desk writes the stack summary shown above the picker. See [review](review.md#someone-elses-pr-bercail-review-pr).

Shep never types into a desk. To move a desk to another model when you ask, or when a [standing rule](#standing-rules) lets it, Shep runs [`bercail desk model <desk> <provider/model[:thinking]>`](config.md#a-desks-model), which the desk takes as a model switch, not as chat.

Bercail works without Shep, but Shep is the intended orchestrator. To do Shep's part by hand, write the issue with `bd create`, then use the task dispatch below. Raw `handoff-spawn` is create-only, not an existing-task continuation.

## Dispatch

Dispatch takes JSON on stdin. No shell interpolation or terminal typing is
used to deliver work. For example:

```bash
printf '%s\n' '{"repo":"/home/me/Work/app","issue":"app-7","target":"pr:12","requestId":"amend-2","stage":"autopilot","message":"Amend the reviewed changes and publish the new head"}' | bercail shep task dispatch
```

`repo`, `issue`, `target`, `requestId` and `message` are explicit; `stage` is
`bstack` (the default) or `autopilot`. Any other field is refused by name.
Targets are `task:ID`, `pr:N`, or a GitHub PR URL belonging to this repo. Add
`branch` only for first creation. The canonical main checkout/common Git directory
serializes reservations across issue aliases. Native PR branch facts resolve
legacy handoffs before absence can be assumed. A task may later bind its new PR
only when that PR belongs to its original branch. Cross-repository fork PR
adoption is unsupported and remains UNKNOWN, not a new preparation job.

Dispatch reopens the beads issue and keeps who owns it under
`metadata.bercail_task`: the target, the branch, the verified owner (desk,
space, session, process), the latest desk creation, any adoptions, and the
`retired` request ids that never reach a desk again. It keeps no list of
requests and no receipts: whether the work is done is what the
[brief](#briefs-and-the-board) shows, the desk's state, its latest report and
`describe check` on its staged change. A follow-up is saved as `pending`, with
its payload, and a later save clears it once its queue file is written: a retry
of it must carry the same payload, and goes only to the same verified owner. An adoption retires the
creation it replaces and any pending follow-up. A retry finds a queued
follow-up's file before it looks at `retired`. A v0.17 record is read through
its `requests` list: the latest creation not blocked or complete is its
creation, every other request is retired, and a retry of old work is matched on
its message and stage. The next save drops the list. A deliberate exploration uses a separate issue and
`forkReason`; it cannot inherit the original session or authority.

A compatible original Pi must have its live foreground process/start tick,
open-session claim, persisted session header, checkout, branch, issue, desk and
space verified. A second live process claiming that exact session is ambiguous,
even without a desk-role label. A follow-up is a file under
`desk-follow-ups/<desk>/`, and the desk's Pi extension sends it as a custom
DATA message in that same session, not a user message, approval, slash command
or role change. It goes as a Pi steer: a busy desk sees it after the tool calls
running then, before the model's next turn, and an idle desk starts a turn on
it. A tool call is never cut short. Follow-ups go in the order they were
dispatched. A claimed but uncertain send stays UNKNOWN and is never
automatically replayed: this is at-most-once delivery. Reuse the same request
ID and payload after a lost response; a retry finds the follow-up's file under
whichever desk it went to and sends nothing again. Legacy or uninstrumented
owners fail closed rather than being restarted for compatibility.

When the original desk is gone, dispatch stops with `original owner missing/stale`.
With the person's yes, the same dispatch plus `adoptReason` (why, and who asked)
starts a visible desk with a new session in that owner's existing checkout:
the one branch worktree, and its branch, that the owner's records name. A PR
target must still be that branch. Live, stale, ambiguous or unresolved owners
keep their refusals. So do an uncertain creation (UNKNOWN), no record, the
main checkout, and a live desk of any job on the checkout: adoption never
closes or replaces one. The issue's
`metadata.bercail_task.adoptions` keeps the reason, the request, the checkout
and the gone desks, and the handoff's `bd comment` repeats the reason.
Follow-ups queued to the gone desk stay with it; the adopting desk gets only
the new request, and later ones made in the usual way. Its
`handoffs.jsonl` line starts a new ownership epoch, so older records neither
own the task nor conflict with it. `stage: "autopilot"` on a follow-up records
workflow intent: it does not turn a live lead into an autopilot or grant shipping
rights. On a first creation it starts an autopilot desk, which may commit and push
the PR's branch; that needs a `pr:N` target and `branch` set to its head branch.

A first desk on a PR's own branch (a `pr:N` target whose head is `branch`) starts
at origin's head of that branch: handoff-spawn fetches it and checks it out, and
fast-forwards a stale local branch. It never cuts the branch again, and it refuses
a local branch with commits origin lacks.

A new desk's first prompt is its issue. A retry of the creation's request ID,
once the desk is up, binds its session as the owner and queues the message
there; it never launches again.

Dispatch gives handoff-spawn `[shep] spawn_timeout` seconds (600 by default) to
start the desk, then stops it and the processes it started. The creation is then
UNKNOWN. The repo's dispatch lock is held meanwhile, so another dispatch in that
repo stops with `dispatch lock held` until the spawn ends; run it again then. A creation that stopped before its desk can be finished: retry the same
`requestId` and payload. When there is no `handoffs.jsonl` line for the issue
(the spawn writes one when it finishes), no live terminal for the issue, and the
branch's worktree is clean with only idle shells in it, dispatch starts the desk
there. When the spawn left no worktree, it starts the creation again. An
autopilot request also needs the PR's own branch, as on a first dispatch. Anything
else keeps the UNKNOWN, with the reason in `next`, and launches nothing.

A target held by another issue moves only when that issue is closed with
`bd supersede <it> --with <this issue>` and none of its desks is live. Its
`handoffs.jsonl` lines then neither own the target nor conflict with the new desk.

`bercail shep runtime` and `bercail doctor` report source/install resource hashes
separately from live startup evidence. The desk bridge's evaluated generation
marker and captured prompt hash are available for instrumented processes; a
legacy session or uninstrumented guard is explicitly UNKNOWN. Today's file hash,
a version string, and even matching source/install files do not prove what an
old process evaluated. Diagnostics never deploy, reload or replace an owner.

## The Shep view

The bercail layout opens on Shep: its terminal fills the window, with the spaces and agents on the right. It is the control room for every desk; the desks stay in their spaces.

- **Start.** The app starts Shep once per session as one hc terminal, `bercail-shep` (label `bercail.role=shep`), outside every space. The terminal runs `bercail shep run`, which starts Shep on Pi. A Shep that is already running, after a window restart for example, is shown again rather than started twice. Quit it and it stays quit until you click **Start Shep**.
- **Spaces.** Click a space to see it, or press `Ctrl+Space` and search for it: the navigator moves left and the space's desk, tabs and panels fill the rest. **Back to Shep** at the top of the navigator, or `Ctrl+Shift+H`, returns to the same Shep session. Nothing is started or stopped by switching, and the keyboard goes back where it was in each view.
- **Agents.** Click an agent or a desk in the agents list to open its own terminal in a dialog over either view. While it is open, what you type goes to that agent; nothing is sent for you. ✕ or a click beside the dialog closes it and puts the keyboard back where it was; **Show in space** goes to its space.
- **Decisions.** **Decisions N** in Shep's header shows or hides the [Decisions panel](#the-decisions-panel): what Shep asks you, a card each with Shep's brief, its recommendation and a picker, and **Discuss** to talk it over in a read-only branch first. A new card changes the count, nothing else.
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
bercail shep mistake list  # the mistakes ledger by group: mistake KEY "WHAT" [--group ID] [--repo DIR] [--issue ID] records one
bercail shep diagram FILE  # a Mermaid diagram without its click and link statements (stdin without FILE)
```

An older `~/.config/bercail/config.toml` may still have `backend` and `session` under `[shep]`. bercail no longer reads them; delete them whenever you like. The keys `[shep]` holds now are for [compaction](#compaction).

## Diagrams in chat

Pi draws a `mermaid` code block in Shep's replies as Unicode box art (Pi's `markdown.mermaid` setting, on by default; Shep leaves it so). Shep draws one only when a flow has three or more states or branches, as a `stateDiagram-v2` or `flowchart TD` of about 15 nodes at most, with no deep nesting. Past that the art stops being readable: a 40-state graph with cross jumps came out four screens tall with its labels cut. Edge labels stay under about 20 characters, and only one edge is labeled where a state branches, because labels on edges leaving the same row print over each other. Other guards go in the text. Every diagram is followed by its transitions as a plain list, which is what you read when the art degrades and what a screen reader gets. A diagram too wide for the pane, or over 128 nodes, shows as its source instead.

Pi turns a diagram's `click` and `link` targets into terminal hyperlinks, `javascript:` ones included. HTML labels, `%%{init}%%` directives and `url(...)` styles print as text or are ignored, and nothing is fetched. So a diagram Shep did not write, such as a PR's `chart.mmd` or one in a desk's report, goes through `bercail shep diagram` before Shep pastes it. It prints the diagram without its `click` and `link` statements (`click A href "url"` is one), and says on stderr how many it dropped. It errs toward dropping. The renderer deletes control characters before it parses and splits words on Unicode spaces, so `cl\x01ick` or a no-break space before `click` still makes a link. The helper deletes the same control characters from every line, splits statements on `;` outside double quotes, and skips any leading space or non-ASCII character before it looks for the word, in any case. A statement that merely starts with the word, such as a state named `link`, goes too. Other lines are printed as they were, less those control characters.

A statechart from a desk is the [statechart skill](bstack.md#statecharts)'s `chart.pi.md`: 20 states or fewer, either the path to a bug or a smaller view of the model, then the states that break a rule and every arrow in words, since Pi draws no colours and shows the source when the chart is wider than the pane. Over 20 states it has no chart, and Shep gives the bug's path from `report.md` as numbered text. The Shep inbox chart is 78 columns wide, so Pi draws it in a pane of 80 columns or more.

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

The repo is `--repo DIR`, else the issue's handoff record, its live desk, or the known repo whose `bd` has it. When the job's worktree has staged changes, a `staged:` line gives their size and [stakes](config.md#review-by-stakes-and-size), says when the change waits for your LGTM, and ends with what [`bercail describe check`](cli.md) says of it: `describe check ok`, or `describe check fails:` and the first thing it fails on. The desk is the live terminal labelled with the issue, else the record's (`gone` when it has ended). A desk [handed off with `--model`](handoff.md) ends its line with `model <provider/id:thinking>`, from its `bercail.model` label, or the record's when it has ended. A blocked desk adds the last 15 lines of its screen, where its question is. The report is the latest comment that is not the handoff note. One longer than `--budget` characters (1500 by default) keeps its first two thirds and its last third, and says how much was cut and that `bd comments <id>` has the rest. Measured on three real issues, a brief was 1,600 to 2,000 characters (about 400 to 500 tokens) against 31,000 to 54,000 for `bd show` plus `hc read --lines 60`: 16 to 33 times smaller.

`bercail shep board` lists one line per open job across the known repos: `<id>: <title>`, its status when not `open`, its desk and state, its branch, and its model when it was handed off with `--model`. A job is an issue that is not closed and has a live desk, or is `in_progress` or `blocked`. A repo's other open issues are a count, with how many of them were handed off to a desk that has since ended. Then: the repos with no jobs, desks still open on closed or unknown issues, and **Waiting on the person**: blocked desks, finished desks to review, finished background Sheps to report and end, and your [todos](#todos-for-the-person). The board shows no reports: a finished desk's line names the brief that has its report.

When anything waits on your review, the board ends with the **review queue**, which `bercail shep queue` prints on its own:

```
Review queue: 15 lines in 4 changes
~/Work/app: 15 of 10 lines, over its review budget
- app-2: Add the export · 6 lines staged in 1 file · stakes high, needs the person's LGTM · described · ~/Work/app.export
- PR #12: Teammate fix · 4 lines · https://github.com/o/app/pull/12
- PR #15: Old job PR · 3 lines · https://github.com/o/app/pull/15
- app-3: Old job · 2 lines staged in 1 file · stakes low · describe check fails: no .bercail/description.md: run /validate · state unknown: issue closed but staged changes remain; custody/outcome unproven · ~/Work/app.old
```

A staged change is on the queue when its desk is not working (done, idle, blocked, or gone); a desk still working is not waiting on you yet. Each one that counts says `described` when `describe check` passes on it, or `describe check fails:` and why. The check reads a copy of the worktree's index, so reading the queue does not change when the changes were last staged. It skips one rule, no beads ids in the body, since the queue reads no full beads list; the brief runs the whole check. Each one has a state, read from records, never from prose:

- **review**: it waits on you. **lgtm**: the same, and its policy wants your LGTM (it touches a `high_stakes` path).
- **superseded**: `bd supersede` or `bd duplicate` names its issue's replacement, or the issue's latest handoff went to another worktree that is still there (the job moved to a fresh one).
- **unknown**: bd cannot say, or a closed issue still has staged changes without proven custody/outcome. It still counts; closed does not mean safe to clean up.
- **stale**: no open Herdr space has the worktree: not the desk's or the handoff's space, and no space whose folder, or one of whose terminals, is in it. Spaces are read from the open window (`herdr-app ls`); with no window answering, nothing is stale.

Superseded work is listed last as `not counted` and stays out of the budget. Stale worktrees are not counted either, and each repo lists them on one line: `- not counted: 2 stale worktrees with no Herdr space, cleanup candidates: ~/Work/app.a, ~/Work/app.b`. Parent and child links are not read: a child issue does not say it replaces its parent. A change with no issue is review. On a repo with a GitHub remote, an open PR counts when it is not a draft, not approved, and either asks you for a review or comes from a handoff's branch. A staged change's lines leave out lockfiles, generated and binary files; a PR's leave out lockfiles. Each repo's total is weighed against its policy's [`review_budget`](config.md#review-by-stakes-and-size). `queue --repo` reads only that repo's review sources, with a 6-second total bound; board has a 10-second bound. A failed/slow source returns UNKNOWN, not an empty list. Shep reports an over-budget or incomplete snapshot without holding already accepted work for it.

`bercail shep queue --json` is the same queue as data (`schema: "bercail.queue/v1"`), for the Herdr app: `at`, when it was read; `items`, what waits first, the longest waiting first (`since`: when a worktree's changes were last staged, or when a PR was opened), each with its `state`, `why`, `by` (the replacement), `counts`, its `space` (the desk's or the handoff's Herdr space), its `change` (size and stakes) and, for a staged change that counts, `described` (`ok`, and `why` when it fails; `null` otherwise); and `repos`, each repo's counted lines against its budget.

### Review in the Herdr app

The bercail layout's spaces list reads that JSON every five minutes, and after a desk's status changes (at most every 30 seconds). It only shows what bercail says; nothing it reads switches your view or moves the keyboard.

- A space whose work waits on you has a mark after its name: `◆` and the lines that wait, with `?` when its state is unknown. The mark is red when a change there needs your LGTM, and the theme's accent color when review is optional. Superseded work says `superseded` in a dim color; a closed issue with staged work has an UNKNOWN mark until custody/outcome is proven. Hover a mark for each item; the tooltip says "needs your LGTM" where it applies, so the red is not the only cue. In the narrow rail, the space's number takes the same color.
- The Spaces header counts what waits (`◆ 3 to review`, red while one needs your LGTM, or `2 to clean up` when only that is left), and adds `(stale)` when the last good read is more than 15 minutes old or the last read failed.
- `Ctrl+Shift+J` goes to the next space that waits, in queue order, from either view ([keys](keys.md)).
- A click on the count opens the **Review** list over either view: each item's space (as Herdr names it), issue and title, lines, stakes, whether it needs your LGTM, how long it has waited, and its state, then what does not count, then the stale worktrees with no Herdr space under their own cleanup heading. The header shows when bercail read the queue and marks older results stale. If a read fails, the panel clears the rows and shows the error. **Open space** shows the space; **Open review** shows it and opens its Review tab; **Open PR** opens a PR in the browser. There is no merge, commit or LGTM button, and nothing answers a desk.

### Todos for the person

Some steps only you can take: create a tailnet login, make a 1Password vault, plug in a device. bercail puts them on your todo lists, in the tool you already read, instead of a line in Shep's chat or an issue titled "Todo (Simon): …". You can have one list per project or repo: each is a named target, and the job's repo picks it ([set them up](config.md#todos)). Basecamp is the one backend for now.

```bash
bercail todo add "Create a Tailscale login for the HA box" --notes "Admin console, Users, Invite" --due 2026-11-20 --issue app-7 --repo ~/Work/app
# added to home: Create a Tailscale login for the HA box · due 2026-11-20 · https://3.basecamp.com/…/todos/900
# linked on app-7
bercail todo list            # home:  - 900: Create a Tailscale login for the HA box · due 2026-11-20 · app-7 · https://…
bercail todo show 900        # its title, open or done and where, due date, link and notes
bercail todo done 900        # complete it (if you have not), and stop the board showing it
```

- **Which list.** `--target`, else the route of the job's repo (`--repo`, or the checkout of `--issue`), else the default ([routing](config.md#todos)). Shep adds each todo with its job's repo, so the route picks the list. When a todo fits no target, Shep asks you which one; when you name one ("lesentiel todos go to the Lesentiel list"), Shep runs `bercail todo target add` and `bercail todo route`, so the next one goes there by itself. Shep's start context lists the targets and their routes.
- **Who writes.** Shep. A desk proposes a todo in its report as `Todo: "<text>"`, the way it proposes a memory, and Shep adds it. For every role but Shep, the guard blocks `bercail todo add`, `done`, `route`, `target add` and `target rm`, and every `basecamp` command it does not know as a read. The reads are `list` and `show` on a resource (`todos`, `todolists`, `projects`, …), bare `todos`, `todolists` and `projects`, `search`, `show`, `url`, `me`, `timeline`, `help`, `version`, `commands`, `auth status` and `config show`. Logging in or out (`auth`, `login`, `logout`, `setup`, `quick-start`, `profile create` and `profile delete`) and the token commands are yours: the guard blocks them in every role, Shep's included. So is any `basecamp` command with a flag the guard does not know before its command or action: the CLI would read that flag as taking the next word, so the guard could not tell what runs. A Discuss branch runs no commands at all. The guard is a seatbelt: a script it never sees, or a wrapper it does not unwrap (`mise exec`, `find -exec`), can still run `basecamp`, and it does not stop a command that reads the keyring or basecamp's `credentials.json`.
- **The link to the job.** `--issue <id>` (with `--repo`, the issue's checkout, when you are not in it) checks that `bd` knows the issue before anything is written, then comments `bercail todo: "<title>" waits on the person in basecamp (<target>): <url>` on it. `bercail shep brief <id>` shows that comment as its own `todo:` line, and keeps the desk's report as the latest report. The beads id goes only in the todo's last notes line (`bercail: app-7 in app`): beads is local, and Basecamp's reader cannot open it.
- **On the board.** `bercail shep board` lists each open todo under **Waiting on the person**, grouped by target, with its issue, due date, target and link: `open in lesentiel`. Once you tick one off in Basecamp, its line says `done in lesentiel; continue app-7, then bercail todo done 900`, until Shep picks the job up and runs `bercail todo done`. One you remove in Basecamp shows the same way, and so does every older todo once its target names another list. When a target's list does not answer within 10 seconds, or you are logged out, the board says so in one line for that target and shows the others.
- **How completion is noticed.** When the board is read: at Shep's start, after each compaction, and whenever Shep or you run it. One `basecamp todos list` call per target, side by side, against the todos bercail added. There is no poller: it would need a process holding your Basecamp login in the background to save Shep a minute it does not need, since nothing in a job moves until Shep reads the board anyway.
- **What it keeps.** `~/.local/state/bercail/todos.jsonl`: one line per todo bercail added (when, target, backend, id, link, title, issue and repo) and one per `bercail todo done`. The todo itself lives in Basecamp.
- **What goes in one.** Plain words for someone who was not there: what to do and where. No secrets, tokens or vault values; the title and notes are sent to Basecamp as written.

### Standing rules

A rule you give Shep in conversation ("merge bercail work straight to master", "you may answer cm0's prompts") would otherwise live only in its session. Shep records it as soon as you say it, and tells you:

```bash
bercail shep remember "Merge finished desk work straight to master and push" --scope bercail
bercail shep list        # 1. 2026-11-11 [bercail] Merge finished desk work straight to master and push
bercail shep forget 1
```

They live in `~/.local/state/bercail/shep/preferences.md`, one `- DATE [SCOPE] RULE` line each; `--scope` is a repo, an issue, a desk, or `all` (the default). The same rule and scope twice is kept once. A rule for everyone who uses bercail belongs in [`shep/SHEP.md`](../shep/SHEP.md) or a repo's [policy](config.md#git-policy-per-repo) instead.

### Mistakes

A mistake that shows up twice should get a fix in the system, not a second fix by hand. Shep keeps a ledger of them in `~/.local/state/bercail/shep/mistakes.jsonl`, one line each time: when, a short key, what happened, and where (repo and issue).

One cause often shows up under several keys, so each key belongs to a group, and the count that matters is the group's. A group has a short ID, a name, and what its mistakes count against: `process` (a bercail step that caused them), `tool`, or `conduct` (how an agent worked). `~/.local/state/bercail/shep/mistake-groups.json` holds the groups and which group each key is in.

```bash
bercail shep mistake group G7 "Test isolation" --against tool tests-touch-real-state   # make or rename a group, move keys into it
bercail shep mistake tests-touch-real-state "the handoff test wrote to the real handoffs.jsonl" --repo ~/Work/bercail --issue bercail-4k9
bercail shep mistake list   # each group with its count and keys, most frequent first
```

A key is a-z, 0-9 and `-`, the same each time. A key in no group yet needs `--group` when it is recorded, and keeps that group after. Only `mistake group` moves a key, because a move changes the count of all its past entries. When a group reaches its second time, the command says so, with the fix that fits what the group counts against. A `tool` group gets a guardrail (a lint rule, a test, the guard, or a doctor check), a `conduct` group gets a rule in SHEP.md or a skill, or a check, and a `process` group gets the step that caused it removed or simplified. [`SHEP.md`](../shep/SHEP.md) has Shep write that issue and tell you.

What counts as good conduct for Shep is written down as [behavior specs](../.agents/behaviors/README.md), for reviewing its traces rather than for its prompt. Their README maps each group of mistakes to a spec, or marks it a product bug.

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
human sender. There is no public `approve` or `--confirmed` switch. All
replies leave the question pending.
Only your pick in the [Decisions panel](#the-decisions-panel) or a Discuss
branch answers a question (`answered`). A proposal never permits
a desk prompt, guard approval, commit, merge, publication, spend or scope change.

Shep's `shep_question` tool creates or revises a question after verifying the
explicit checkout/job and desk session against existing beads, hc and
`desk-sessions` records. It does not discover jobs from a bare issue ID. Repo
identity is the canonical local git common-directory path, shared across its
worktrees; another clone is a separate local identity. Review/action questions
record desk, space, session, worktree, intended action, head, staged tree, and
resolved base plus its ref. A planning question records no head or staged tree,
so new commits leave it fresh. Changed intent or candidate supersedes the old
revision; prior proposals remain in history. Each question also carries Shep's
`brief` (what is decided, why now, what each choice does) and its
`recommendation` (one of the choices, with one line of why), for the card.
A question that no longer applies (its desk stopped, an event made it moot)
is withdrawn by Shep (`shep_question_withdraw`, or `question withdraw`) with a
reason and the time. A withdrawn question leaves the panel and Shep's question
state and can never be answered. It is not an answer: no picker source and no
decision event.

### Reversible questions

A decision that can be walked back should not keep work waiting on you. Shep
marks such a question `reversible` when it asks it. It waits for you until its
deadline, 30 minutes after it was asked (`[shep] decision_timeout` in
[config](config.md), in minutes; `0` never defaults). If nobody picked by then,
it takes Shep's recommendation. Shep says so on the card and in chat, with the
deadline the helper returned.

What may default follows Bezos's one-way and two-way doors. A two-way door is
cheap to walk back, so it may default. A one-way door always waits for you. The
helper, not Shep, decides with this table (`door()` in `shep/pi/questions.ts`,
one test per row) and refuses `reversible` on a one-way door: Shep asks again
without it. An action question's action is its effect, and only `commit`,
`merge` and `land` are in the table; the helper captured its head, staged tree
and base. A planning pick has no action. The question's prompt, choices and
brief are read too, and can only make it stricter: a one-way row's word there
wins, and so does a merge or commit word without that action.

| Door | Row | For example |
|------|-----|-------------|
| one-way | an LGTM | any review question: its answer is an LGTM, and a default never is one |
| one-way | force push | `force push`, `--force`, `push -f` |
| one-way | publishing to a forge | any push, `gt submit`, publish, a trail, a pull request |
| one-way | an LGTM or approval | approve, `--reviewed-by` |
| one-way | a release or tag | release, tag, ship |
| one-way | a deletion | delete, remove, `rm`, `git clean`, reset, prune |
| one-way | money | pay, buy, spend, a price |
| one-way | an outward post | post, comment, email, announce, send, reply |
| one-way | a device or deploy action | device, deploy |
| one-way | an action no two-way row names | any action but `commit`, `merge` or `land`, and any action on a planning question |
| one-way | a merge asked without action merge or land | merge or land in the words of a planning pick or a commit |
| one-way | a commit asked without action commit | commit in the words of a planning pick |
| two-way or one-way | a merge or land | action `merge` or `land`: two-way only where the repo's policy says [`merge_reversible = true`](config.md#git-policy-per-repo), trusted |
| two-way | a local commit | action `commit` |
| two-way | a planning pick | no action: which desks to start, their order, a scope or approach, keeping or skipping a step that publishes nothing |

A land is asked as action `land`. bercail does not look up whether a forge is public, so the word push makes any
question a one-way door. The words can make a harmless choice one-way ("the
release plan"); they never make a one-way door two-way.

The deadline is in the ledger, so nobody polls by hand and Shep never waits for
it. Shep's question extension runs `bercail shep question expire` in its own
process when Shep starts and every 30 seconds after, so a deadline passed
while Shep was stopped fires at its next start. Each due question gets the
live check first, and the policy is read again. A question that changed since
Shep asked keeps waiting for you, and its card says so. A merge the policy no
longer calls reversible waits too, and its card has no countdown. Past the
deadline of a door that is still two-way, the store refuses your pick and the
panel offers none: the default is recorded at Shep's next check. The check
runs just before the ledger's write, as for your pick, so Shep runs `question
check` again before it acts on a default. For a reversible question it also
gives the door with the policy it just read; Shep acts only while the check is
fresh and the door two-way.

The default is the ledger's answer, not yours. It records the recommendation
with the source `default after timeout`, at most once per question revision.
Shep gets a [decision event](#desk-events) that says nobody picked, and acts on
it once. Once the event is in Shep's inbox, the ledger marks the default
`told`. If it could not be written, every later run tries again, however late;
a told default, or one whose event is already in the inbox or delivered, is
not sent again. One case is not covered: a crash between writing the event and
marking it, then 30 days with no run that succeeds, after Shep's inbox has
dropped the delivered copy. While Shep runs, it marks it within 30 seconds.
Shep's question state lists defaults apart from your picks. Reports and
descriptions say the choice was defaulted. A default is never an LGTM or a
reviewer: a defaulted commit never carries `--reviewed-by`. The guard still
blocks agents from `question answer`, and that op refuses the default's source.

### The Decisions panel

Every decision Shep asks you is also a card in the Shep view. **Decisions N**
in Shep's header counts the pending ones; click it to show or hide the panel
under Shep's terminal. A new card only changes the count: nothing opens, moves
or takes the keyboard.

Each card says, in words, where (the desk's space as Herdr names it), what (a
change's lines and stakes), what Shep asks, Shep's brief, its recommendation
and why, the choices, and when it was asked; the panel says when it last
checked. A card whose candidate changed since Shep asked (new commits, a new
staged tree, another base, or the desk) says **stale** and what changed: Shep
must ask again. One it cannot check (the desk ended, the policy could not be
read) says **unknown** and why. A [two-way door](#reversible-questions) counts
down to its deadline (`two-way door: defaults to auth in 23 min`); other cards
have no timer. Once it defaults, the card says **defaulted** and the choice it
took, has no choices or answer button, and stays a day. **Discuss** on it still
works: say there what you would change, and closing it tells Shep, with the
branch's last reply. **Decisions N** counts only the cards that wait on you. Question tokens are the ledger's keys and never show. The panel reloads when the ledger changes, and every 30 seconds while it
shows. With a [`[herdr] backend`](config.md#bercail-on-another-machine), it
reads, answers and discusses on that machine, and looks at its questions every
30 seconds, shown or not.

#### Answering

The picker on a fresh card starts on Shep's recommendation (★). Click in the
panel to give it the keyboard, then:

| Key | Does |
|-----|------|
| ↑ ↓ (or k j) | move between cards |
| ← → or 1-9 | pick another choice |
| Enter | answer with the picked choice |
| d | open Discuss |

A click on a choice picks it, and **Answer** records it. A card with no
recommendation waits for a pick. Stale and unknown cards have no picker. A
question with no choices is answered in Shep's chat.

An answer runs a live check first, then the store's checked transition: once per
question revision, one of its choices, only while nothing changed. It records
the choice, where you picked it (`panel picker` or `discuss picker`), the time,
and the head and staged tree the check saw. A second pick on the same revision
is refused. Shep gets one [decision event](#desk-events) per pick, and its
question state lists the last ten answers on every turn.

This counts a click or a key in the panel as yours. It is a local record you
own, not proof of who pressed it: any program running as you can type or click
(`wtype`, `ydotool`, `/dev/uinput`, Hyprland's virtual pointer), and Herdr sees
those as yours. Herdr's scripted paths (keys.json, the palette, `herdr-app do`,
toasts) reach a mod's commands, never the panel, and no command answers. The
guard is the seatbelt for agents: it blocks writes to Shep's state folder,
`questions.json` included,
`bercail shep question answer`, and typing or clicking for you (`wtype`,
`ydotool`, `xdotool`, `dotool`, `evemu`, `/dev/uinput`, and `hyprctl`'s
`sendshortcut`, `sendkeystate` and `pass`, or a `dispatch exec` of one). A seatbelt,
not a sandbox: a script file or another language gets past it.

#### Discuss

**Discuss** (or `d`) opens a dialog with Pi on a branch of the session the
question came from, to talk it over before you pick:

- A desk's question (it names a desk) branches that desk's own Pi session at
  its last complete entry (a tool call still waiting for its result is left out).
- A question Shep asked in chat branches Shep's session at the entry that asked
  it, through that turn's tool results and reply, and nothing after.

The branch is a new session file in `~/.local/state/bercail/shep/discuss/`. The
desk's and Shep's sessions are only read, and both keep running. It is not in
Shep's `pi-sessions/`, so Shep's `--continue` never picks it up. Shep compacting
or restarting while a branch is open changes neither: the branch is its own copy
from the moment it was made.

The branch reads but does not act. It runs on the lead's model with Pi's
`read`, `grep`, `find` and `ls` tools only, no discovered extensions, skills,
prompt templates or MCP, and `BERCAIL_ROLE=discuss`, under which the guard
blocks every command and edit. So it cannot spawn or message desks, commit,
merge, push, or record memories or rules. `/pick` in it shows the choices (Shep's
recommendation marked), checks the question live, and records the pick like the
panel does; a stale question says why and records nothing.

The dialog closes with ✕ (a click beside it does not), or by itself after
`/pick`. Closing ends the branch's Pi; **Continue discussion** opens the same
branch again. When it closes without a pick, Shep gets one event saying so. Both
events carry the branch's last reply, cut to 600 characters, as data. Pi's own
branch summary would take a model call at close, so it is not used. Two
questions can be discussed at once: each has its own branch, terminal and events.

Cost: a branch's first turn sends the whole branch (after any compaction, its
summary and the entries since) as new input. Its tools and system prompt differ
from the source's, so the prompt cache does not carry over; later turns in the
branch are cached as usual. With the Claude bridge, the branch gets its own new
Claude Code session and never touches the source's.

The CLI works without Pi or a mod too:

```bash
bercail shep questions              # bounded pending projection
bercail shep questions --json       # full snapshot and retained revisions
bercail shep question check Q42@3   # recheck candidate/mapping and current policy (and a reversible one's door)
bercail shep question thread release-plan
bercail shep question panel         # the Decisions panel's JSON: pending questions, each checked, and a day of defaults
bercail shep question expire        # record the defaults that are due (Shep's runtime runs it every 30 seconds)
bercail shep question discuss Q42@3 # make (or find) the question's branch; prints its session file
bercail shep discuss Q42@3          # Pi on that branch, read-only: what the Discuss dialog runs
```

`question create`, `revise`, `reply`, `answer` and `withdraw` read JSON on
stdin (`answer` is the panel's: `requestId`, `token`, `choice` and `source`; the
guard blocks it for agents; `withdraw` takes `requestId`, `token` and `reason`). For example, a
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
and proof of who picked an answer are not part of this feature.

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
bercail shep bg --kind wait --issue bercail-ow2        # from the issue's repo
bercail shep bg --kind admin --issue bercail-ow2 --cwd ~/Work/bercail
```

It prints `{address, name, cwd, issue, issue_title}`. The background Shep is one hc terminal named `shep-bg-<id>`, started in the background with no space, so nothing in the app moves or takes focus; the agents list shows it. It runs `bercail-desk-agent` with the lead's selected model/provider and guard, but replaces the coding prompt with [`shep/BACKGROUND.md`](../shep/BACKGROUND.md). It disables skill, context, prompt-template, MCP and automatic extension discovery. Its tools are read/search/list, `shep_issue`, `shep_wait` and `shep_report`: observation, bounded waits and reporting on the assigned issue. There is no shell, write/edit tool, agent launch, authoring or publication. Missing required lead/model/guard resources fail admission; no generic Pi fallback. Its first message is one line pointing at the issue. A second `bg` for an issue whose background Shep is still live is refused.

Its labels are `bercail.role=agent`, `bercail.shep=bg`, `bercail.issue`, and `bercail.issue_title`, with no `bercail.space`. The notify follower treats it like a desk, so its finish or block reaches Shep as a [desk event](#desk-events) whose text says `Background Shep <address>` and whose `agent.role` is `shep-bg`. It is started with `--no-notify`, so hc types nothing into Shep's prompt, `--outlive-parent`, so restarting Shep does not end the wait, and `--rm`. Once Shep has reported a finished one, `hc kill <name>` ends and removes it; killing it sends no second event.

It runs with `BERCAIL_ROLE=shep-bg` and an explicit wait/admin admission. Generated issue prose cannot widen that tool surface. A coding or interactive next step is reported with its target, blocker and next action for the original visible owner or Shep's existing question flow; no unattended approval prompt. This is a narrow trusted-extension profile, not an OS sandbox. A worker report or completed wait does not complete a later author/publish or cleanup request.

## Desk events

Once Shep has started for the first time (its first start makes `~/.local/state/bercail/shep/inbox/`), the notify follower (`bercail notify run`, the hidden `bercail-notify` terminal the desk mod keeps alive) writes each finished or blocked desk as one file in that folder. Before Shep's first start it idles. `bercail update` restarts a running follower so it runs the new code. The files are the [`agent_status/v2` payload](#the-payload) with `sink: "shep"`, mode 600, named `<desk>_<kind>_<second>.<seq>.json` for sequenced events and `<desk>_<kind>_<second>.json` otherwise.

Shep's Pi extension (`inbox.ts`) watches that folder. It submits one custom message, starting a turn when Shep is idle or queuing a follow-up when it is busy. The message carries each event's one-line `text`, its `event_id`, and the desk, space, repo, issue, and checkout. It excludes `desk.result.summary` and the desk's title. Desk events remain signals to check the current desk and issue, never instructions or human answers.

The same folder carries decision events, written by bercail when you [answer](#answering) a question or a [reversible one](#reversible-questions) defaults (`decision-Q<n>-<rev>.json`, `by` the picker or `default after timeout`), or when you close a [Discuss](#discuss) dialog without a pick (`decision-Q<n>-<rev>-closed-<opening>.json`). Each names the question, the choice (or none), where it was made, and the branch's last reply as data. The file name is the event id, so a retry is the same event. Shep checks each against its question state, where the ledger's answer is the record, before it acts.

### Claims and persistence

Moving a file to `delivered/` claims it but does not acknowledge delivery. Before submitting it, the extension atomically records the attempted Pi session ID and file. Only a complete matching custom-message entry in that actual session JSONL acknowledges it. The receipt records `persisted_entry_id`, `persisted_session`, `persisted_session_file`, and `persisted_at`. The older `delivered_at` and `delivered_session` fields remain for readers, but an old stamp alone is not proof.

This distinction matters in Pi 1.5.2: `sendMessage()` returns before a queued follow-up is consumed, and `message_end` runs before the session append. A new custom-only session can even reach its first model request before Pi creates the session file. The extension checks disk on later hooks and polls. It never acknowledges a memory-only entry.

After a process dies, the next consumer recovers unacknowledged files in `delivered/`, including old unstamped claims. It first checks the original session. A saved entry repairs the receipt without another message. A readable session without that entry permits replay. A file that did not exist before the attempt and still does not exist permits replay too, assuming nobody externally deleted it. A missing previously existing session, unreadable or incomplete history, or an ambiguous old session ID holds the event as uncertain. Restore access to that original session and restart Shep to retry verification. It does not silently bind the event to a replacement session.

One consumer holds a local Linux `flock` for its session lifetime, through a child that exits when Pi's stdin pipe closes. There is no expiring lease to steal from a busy session. Another consumer pauses without claiming files. If `flock` is unavailable or the lock is lost, delivery pauses visibly. Restart a paused contender after the owning consumer ends. The lock file must not be deleted while consumers run.

### Duplicates and limits

Repeated envelopes with the same event ID produce one injected message, even under different filenames. Receipts are kept for 30 days. Unacknowledged and uncertain claims are not aged out. Compaction and tree navigation do not invalidate disk persistence evidence. Legacy stamps are checked against the named session instead of being trusted.

With an intact local spool, readable session storage and eventual session progress, accepted events survive a process crash after claim or enqueue. A crash after session persistence but before acknowledgement does not inject a second notice. These are process-crash guarantees, not transactional power-loss durability. External deletion of session history, an independently killed lock holder, and replay after receipt retention are outside those guarantees.

Transport deduplication does not prove exactly-once model reports or arbitrary external actions. A response can stream before its assistant entry is saved, and an external action can complete before its result is recorded. Shep must recheck current source state and use action-specific idempotency where available. Persistence means neither handled, action-completed, nor read by the person. No read or handled acknowledgement is invented here.

Within an ordered `hc events` stream, the follower ignores replayed status events by sequence number, before they can change the desk's status or send a second finish. A later finish has a different sequence number, so it is not dropped just because the desk, session and report are unchanged. A new status event is not proof of a new Pi turn; when the core reports a second transition, the follower does not guess whether it's a duplicate.

The inbox filename omits the follower's process ID. For live status events with a valid sequence number, it includes that number so two finishes in the same second reach Shep separately. Without a usable sequence number (for example, when recovering a transition from a snapshot), the follower still coalesces changes for the same desk and kind in the same second. The delivery guarantee applies to retained accepted envelopes, not to every historical desk transition.

### Reconciliation after follower gaps

The follower also writes one private `source-state.json` beside the inbox. It is a current projection from snapshots and status changes, not a second job database or an event log. It includes observed timestamps and desk/space/repo/issue/checkout mappings, but no desk-authored prose, results, event IDs or human answers. Whole snapshots replace gone mappings.

When a done, idle or blocked source mapping has no represented inbox notice, Shep receives an explicitly **reconstructed, possibly stale history-gap observation** with its observation time and a separate local notice ID. That ID is not a historical finish or block event ID. Identical represented observations are suppressed. For status transitions that enqueue an event, the follower queues it before publishing that transition's source state. When the follower looks up changed labels on a desk it already tracks, `hc get` can show a status the stream has not delivered yet. The source keeps the last streamed status until the next status event. A first-seen desk still uses the lookup to recover its current status. Shep reads `source-state.json` before claiming the inbox so those writes landing mid-drain cannot also produce a reconstructed notice. A source snapshot cannot recover intervening transitions, a vanished desk, historical completion times or answers. Check the current board or brief before acting.

### Proving it arrived

`bercail shep status` separates queued files, claims awaiting persistence (including uncertain holds), persisted notices and quarantined malformed files. It names the last persistence receipt. In the session, a notice is a `custom_message` with `customType: "bercail-desk-event"`. Its presence is distinct from Shep's subsequent reply or your reading it.

### The follower

`bercail notify run` follows the desk agents (hc terminals labelled `bercail.role=agent`) with `hc events`. It queues only these:

- `finished`: working or blocked → done or idle
- `blocked`: once each time the agent blocks

`run` is the only `notify` command. The webhook sinks (`notify add`, `status`, `test`, `repo` and `check`, and `~/.config/bercail/notify.d/`) were removed in v0.18; bercail no longer reads that folder and leaves it in place.

### The payload

Each event file is `bercail.agent_status/v2`:

```json
{"source":"bercail","schema":"bercail.agent_status/v2","kind":"finished","sink":"shep",
 "at":"2026-10-29T22:42:00Z","event_id":"t9:finished:1793312520:4242",
 "agent":{"address":"t9","app":"pi","status":"done","previous_status":"working","title":"...","role":"desk"},
 "space":{"id":"sp98de","name":"Render-preview_Leftlane_app","repo":"leftlane_app","checkout_path":"/path/desk","linked":true},
 "desk":{"branch":"feat/render","issue":"lef2745-2vs","issue_title":"Fix the login timeout","stage":"bstack","harness":"pi",
         "result":{"status":"ready","summary":"...","session_id":"..."}},
 "text":"lef2745-2vs: Fix the login timeout. Desk t9 (Render-preview_Leftlane_app) finished."}
```

`agent.address` is the hc terminal (`hc get`/`hc read` it). `agent.role` is `desk`, or `shep-bg` for a [background Shep](#background-sheps). `desk.issue` and `desk.issue_title` are the terminal's `bercail.issue` and `bercail.issue_title` labels when it has them. `desk.issue`, `desk.issue_title`, `stage`, and `harness` otherwise come from the matching `handoffs.jsonl` record (`harness` falls back to `agent.app`; `issue_title` is null when that record has none); a record or result for another issue than the labels name is left out. `desk.result` is `status`, `summary` (its first 500 characters), and `session_id` from the checkout's `.bercail/handoff-result.json` when one exists (usually `null`: headless runs have no desk terminal, so they send nothing). `text` is one line for a person: `<id>: <title>. Desk <address> (<space name>) finished.` or `is blocked.` (`Background Shep <address>` for a background Shep); the bare id when there is no title, and no parentheses when the space has no name.

**Headless runs send nothing.** Only desks (`handoff-spawn --branch`) have a terminal the follower can watch. For a headless run, `handoff-spawn` returns when the run ends and `.bercail/handoff-result.json` holds the outcome. To wait on a desk yourself, use `hc wait <desk>`.
