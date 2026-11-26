# Shep, the orchestrator

**Shep orchestrates coding agents in the Herdr app through bercail.** It writes each job as a beads issue, or a trail in an Entire repo, hands each one to a desk, follows the desks, and tells you what came back. It does not write project code: every coding job runs in a visible desk, on bstack's Pi.

Shep ships with bercail. Its runtime steps are one file, [`shep/SHEP.md`](../shep/SHEP.md); this page is the contract behind them. bercail starts Pi in Shep's own folder and session, on the models bstack already uses. Nothing to set up beyond bercail.

## Let Shep set it up

[Shep](https://x.ai/bot/Yber1TlDZinVy6FQZcPsF) is also a Grok Bot template. Add it, connect this computer to it, and ask it to set up bercail. It installs bercail and checks your plans and repos, asking before it runs anything.

## How Shep runs a job

1. Shep writes the job as a [beads](https://beads.gascity.com/) issue, or in an Entire repo as a [trail](#trails-as-jobs): the ask, the repo, links, the main user workflow, the local setup the desk may do, what done looks like, and the proof: the repo's tests and verify skill, recorded by /validate in `.bercail/validate.json`, never bespoke evidence manifests or checker scripts.
2. Shep calls [`bercail shep task dispatch`](#dispatch). A job with a desk continues in that desk's session. Only a job whose records show no owner gets a first [visible handoff](handoff.md), prompted with one line pointing at the issue; a missing or unresolved owner is not no owner.
3. When the desk finishes or blocks, Shep gets [a message](#desk-events), reads the issue's [brief](#briefs-and-the-board), and reports to you.

Every coding job and follow-up is a desk you can see. Shep may wait 10 seconds or less on purpose, and waits for a starting desk with `dispatch --wait-ready` rather than sleeping; longer waits go to a [background Shep](#background-sheps). A command that takes its own time, such as a dispatch spawning a desk, is not such a wait. When a step is refused, Shep tells you, takes the next step SHEP.md gives, and writes a bercail issue when there is none or the refusal looks wrong. It never works around a refusal with something the guard does not see, such as a script file or `python -c`.

For someone else's PR, Shep runs `bercail review-pr <PR url-or-branch>` and asks you only about PRs flagged in `prs[].thin` and `prs[].pass`: review anyway (`bercail review-pr run N --stack DIR`) or ask the author ([review](review.md#someone-elses-pr-bercail-review-pr)). To move a desk to another model, when you ask or a [standing rule](#standing-rules) allows, Shep runs [`bercail desk model`](config.md#a-desks-model); it never types into a desk.

Bercail works without Shep: write the issue with `bd create` (or the trail with `entire trail create`) and use dispatch. Raw `handoff-spawn` only creates; its headless stages leave `.bercail/handoff-result.json` (`ready`, `blocked`, or `failed`).

## Dispatch

Dispatch reads JSON on stdin, so no shell interpolation or typing delivers work:

```bash
printf '%s\n' '{"repo":"/home/me/Work/app","issue":"app-7","target":"pr:12","requestId":"amend-2","stage":"autopilot","message":"Amend the reviewed changes and publish the new head"}' | bercail shep task dispatch
```

`repo`, `issue`, `target`, `requestId` and `message` are required (for a [trail](#trails-as-jobs), `issue` or `target` alone); `stage` is `bstack` (the default) or `autopilot`; `branch` is required for a first desk and only there; `model` (`provider/model[:thinking]`, as `pi --list-models` names it) starts a new desk's Pi on that model instead of the lead's, through [handoff-spawn's `--model`](../skills/handoff/SKILL.md), and is kept in the creation on the issue, the handoff record, and the board's line. A follow-up to a live desk refuses `model`: that desk is switched with [`bercail desk model`](config.md#a-desks-model). For a blocked trail, see [`stackedOn` and `stackReason`](#trails-as-jobs). `adoptReason` and `forkReason` are below. Other fields are refused by name. A target is `task:ID`, `trail:<n>` in an Entire repo, `pr:N`, or a GitHub PR URL of this repo. A job binds a later PR only on its own branch, and a legacy handoff on a fork's PR is UNKNOWN. The repo's dispatch lock serializes dispatches across issue aliases. Each bd call gets 10 seconds, more as the machine's load per core grows, up to a minute. A bd call that still runs out fails the dispatch, which may have recorded part of the request: retry the identical request, the same JSON. When the one that times out is the creation's reservation, no desk has started, so dispatch records the creation UNKNOWN and the retry starts it.

**The record.** Dispatch reopens a beads issue (never a trail) and keeps under `metadata.bercail_task` (a trail: its [local job record](#trails-as-jobs)) the target, branch, verified owner (desk, space, session, process), latest creation, adoptions, and `retired` request ids. There are no receipts: the [brief](#briefs-and-the-board) says whether work is done. A v0.17 `requests` list is still read, and dropped at the next save.

**Follow-ups.** The owner's live process, session, checkout, branch, issue, desk and space are verified first; two processes on one session are ambiguous. A desk that came back on its same session in a new process, after a reboot and `bercail desk restore`, is the same owner: the issue's record takes the new pid. The follow-up is a file under `desk-follow-ups/<desk>/`, which the desk's extension sends into its session as a custom data message (a Pi steer), never a user message, approval or role change. A busy desk sees it after its running tool calls; an idle one starts a turn. Delivery is in order and at most once: an uncertain send stays UNKNOWN and is never replayed. A retry with the same id and payload writes a still-pending follow-up whose file is missing, and never sends a written one again. A legacy owner fails closed.

**A gone owner.** When the original desk is gone (its records name a desk a spawn started, and no terminal at that address is live) and its checkout remains, dispatch adopts the checkout by itself, asking nobody: a visible desk with a new session in the one branch worktree the records name, whose branch a PR target must still be. The result adds `adopted` (checkout, branch, gone desks, reason, and the number of `staged` files) and a `warning` line for Shep to repeat to you; a retry repeats them. The reason defaults to `desk <id> is gone` or `desks <ids> are gone`. Use `adoptReason` if you know why; without a record it is refused.

**A retired checkout.** When `bercail cleanup` retired every checkout the job's desks had, and no desk of the job is live, dispatch starts the job again, asking nobody: a first desk in a new worktree, on its kept branch as it is here (origin's head for a `pr:N` target), or on the `branch` you pass, which may differ from the old one. Cleanup says so in `~/.local/state/bercail/retired.jsonl` once the worktree is gone; a handoff line older than that line names a desk that went on purpose, even after a new checkout takes its path. The requests sent to the gone desks are retired, as an adoption retires them. A checkout gone some other way (by hand, or `wt remove`) still refuses, naming it and its desk, as does a handoff logged in the same second as the retirement, which cannot say which came first. Shep then runs `bercail cleanup --gone <path>`, whose [guard card](#guard-asks) asks you that nothing was lost there (where the repo's [`shep_may_run`](#where-the-repo-opts-in) lists `cleanup`, it runs with no card), and the next dispatch starts again.

The handoff comment gives the reason. If the checkout has staged files, the comment and the new desk's prompt tell it to name them in its first report and leave them staged for your review. The adoption record keeps the staged count, retires the replaced request ids and starts a new ownership epoch in `handoffs.jsonl`. Follow-ups already queued to the gone desk stay there.

Dispatch normally to a verified live owner; it does not need adoption. Adoption refuses stale, ambiguous or unresolved owners, a desk still live without its labels, an UNKNOWN creation, a missing checkout, the main checkout or a checkout with a live desk. Ambiguity lists the desks. Spawn records without a `desk`, or with `ok` or `agent_started` explicitly false, do not establish a gone owner: `original owner missing/stale`, which names the creation's request when it is UNKNOWN. An UNKNOWN creation whose spawn ended partial is settled once the space its line names is closed: then an `adoptReason` adopts its checkout, as a retry of its own id finishes an initial creation.

**A PR's branch.** Any first desk on a PR's own branch (a `pr:N` target whose head is `branch`) starts at origin's head of that branch, fetched and fast-forwarded, never cut again; a local branch with commits origin lacks refuses. With `stage: "autopilot"` that desk may commit and push the branch. A restack any desk prepares is yours to publish: Shep puts its lease push on a [guard card](#guard-asks) with the pinned and new heads, and it runs only on your Allow. On a follow-up, `autopilot` is intent only: a live lead stays a lead.

**Creation.** A new desk's first prompt is its issue. Dispatch gives handoff-spawn `[shep] spawn_timeout` seconds (600), then stops it and the creation is UNKNOWN; meanwhile the repo's other dispatches get `dispatch lock held`. A retry of the same request finishes an initial creation (not an adoption) that stopped before its desk: with no live terminal for the issue and no `handoffs.jsonl` line, or only the line of a spawn that ended partial (`ok` and `agent_started` false, no `desk`) once no live terminal holds the space it names, it starts the desk in a clean worktree holding only idle shells, or creates again when there is no worktree. Anything else stays UNKNOWN, with why in `next`. Once the desk is up, a retry binds its session, queues the message there, and never launches again; that includes a partial creation's desk that came up late with the session and space its last line pinned. An earlier line's pin stops counting once a later spawn followed it and its space is closed; its branch and checkout always count. `bercail shep task dispatch --wait-ready` does that retry itself: once a desk starts, it waits up to 60 seconds for both Pi's desk record and open-session claim to name the pinned session. On success it returns `queued` and `ready: true` with the creation and any adoption. When the minute passes first, or the retry refuses, it returns `started` with `ready: false` and a `next` that says why. A dispatch that starts no desk returns at once.

**Dry run.** `bercail shep task dispatch --dry-run` runs dispatch's checks (the JSON, the target, the owner, an adoption, an UNKNOWN creation, the dispatch lock) and refuses with the words a real dispatch would. It starts no desk, queues no follow-up, writes nothing to the issue or a trail's record, and takes no lock. Its answer has `dry_run: true`. Where a real run would start a desk, `status` is `would-start`, with the `branch`, the arguments it would give handoff-spawn (`spawn`), and an adoption's `adopted` and `warning`; where it would queue a follow-up, `status` is `would-queue`, with the `owner`. Where a real run writes nothing, the answer is the one it would give. A `model` is checked against `pi --list-models` (`handoff-spawn --check-model`) before a creation is recorded, in a dry run too. handoff-spawn's own checks of the branch and worktree (a branch checked out elsewhere, local commits origin lacks, a hook wt has not approved) run only in a real dispatch, so a `would-start` can still be refused there. Any other flag is refused.

Text sent to a desk with `hc send` is submitted: hc pastes it and presses Enter. Press no `hc keys enter` after it, since that key answers whatever prompt the desk shows. A send to a desk still starting can be dropped, so dispatch's own message goes in the desk's queue, never by `hc send`.

**Other owners.** A target held by another issue moves only once `bd supersede <it> --with <this issue>` closes it and none of its desks is live. Parallel exploration is a separate issue with `forkReason`.

`bercail shep runtime` and `bercail doctor` report file hashes apart from what live processes started with (a legacy session is UNKNOWN), and never deploy, reload or replace an owner.

## Trails as jobs

In a repo whose git backend is `entire`, everything is a trail: code, research, admin and waits, and there are no beads. A trail job is `trail:<n>`, the project trail's number, and it goes wherever a beads id goes: dispatch's `issue` and `target` (either alone works; they must match), `shep bg --issue`, `shep brief`, a question's `issue`, `todo add --issue` and `mistake --issue`. A number repeats across repos, so `brief` finds a trail's repo from the desks and handoff records that name it, and needs `--repo` when they name no repo or more than one.

| Step | What |
|------|------|
| Create | Shep: `entire trail create --no-branch --title … --body … --type task --json` from the main checkout. The trail is in the planning phase. It pushes no branch, so the guard runs it with a [warning](config.md#warnings-and-refusals) instead of a push prompt |
| Dispatch | `{"repo": …, "target": "trail:<n>", "requestId": …, "message": …, "branch": …}`. The trail is not changed; a closed one is refused, with the command that reopens it |
| Report | the desk: `bercail job comment trail:<n>` with the report on stdin |
| Link | Shep, once the branch is pushed: `entire trail link <n> --branch <branch>` |
| Merge | Shep, when you ask: `bercail job merge trail:<n> [--change <repo>/<n>]`. It goes to a [guard card](#guard-asks) as a trail merge, pinned to the trail's change. On your Allow the worker runs `bercail job merge` on that change: it merges it with no `--force`, reads the trail again, and closes the trail when no change in any repo is left open. A merge Entire refuses closes nothing, and a closed trail with a change still open is refused until it is reopened. When the merge ran but the close failed, the log says so and names the `entire trail update` that closes it once `entire trail show` shows no open change |
| Supersede | Shep: `bercail job supersede trail:<n> --with trail:<m>\|<commit>`, when the work landed under another trail or commit. It adds `Superseded by: #<m> <url>` or `Superseded by: commit <sha>` to the body, once, and closes the trail in the same `entire trail update`. A desk may run it too, as it may `entire trail update` |
| Close | Shep: `entire trail update <n> --status closed`, once a job with nothing to publish or link is done and reported |

The trail holds the ask. This machine holds the rest, in `~/.local/state/bercail/jobs/<repo>-<hash>/` (`<hash>`: the first 12 hex digits of the main checkout's path's SHA-256):

- `<n>.json`: the job record, the fields beads' `bercail_task` holds (target, branch, the owner's desk, session and pid, the creation), written by dispatch under its lock. `entire trail update` cannot write a trail's metadata, and a desk's address means nothing on another machine anyway.
- `<n>.comments.jsonl`: one `{text, author, created_at}` per line, appended: the handoff note, a todo's link, and the desk's report. Entire refuses `entire trail comment` from an agent session (trail discussions are for people), so a report cannot go on the trail. Feedback on the code goes in `entire trail finding`.

`bercail job show trail:<n>` prints the trail (status, phase, type, priority, URL, body, changes) and those comments: it is what a desk reads for its job. It does not read the people's discussion; it names the command that does (`entire trail comment list --trail <n>`). The reports stay on the machine that ran the job: a person who wants a summary on the hosted trail posts it. Entire needs the network and the person's login: when it does not answer, or answers in a shape bercail does not know, the trail job commands fail and say so, and the board shows the repo as UNKNOWN.

A job with nothing to ship is still a desk on a local branch: nothing is pushed or linked, and the trail stays in planning until Shep closes it once the job is done and reported. Any trail a desk is building reads `planning` on entire.com until its branch is linked; the board, which knows the desk, is where it shows in progress. Dispatch does not link a branch early with `entire trail link --branch-action create`: that makes a remote branch for every job, and the review queue would list its empty change as waiting on review. A wait is a background Shep on the trail (`shep bg --issue trail:<n>`), named `shep-bg-<name>-<hash>-trail-<n>`: the main checkout's folder name and 4 hex digits of its path's SHA-256, since the same number can be another project's.

Entire has no dependency field. A line `Blocked by: #12, #15` in a trail's body names trails of the same project that must be closed or merged (phase `complete`) first. Until they are, dispatch normally refuses a new desk and names them (a live desk carries on, and adopting a gone desk's checkout warns with them), the brief says `blocked: waits on #12`, the board adds `blocked by …` to a job's line and lists a trail not started as blocked or ready, and `bercail job list` shows each open trail as `ready` or `blocked by …`. A number no trail has, or a line that is not a list of `#N`, keeps it blocked and says so. Shep writes the line at create or with `entire trail update <n> --body`.

To start work before those parents land, add `"stackedOn": ["trail:12", "trail:15"], "stackReason": "Build the importer against the staged schema and parser"` to the dispatch JSON. Name exactly the blockers still open and not complete. Each parent needs a verified live desk in this repo or, once its desk is gone, a recorded worktree with staged changes and no unresolved conflicts. A terminal that is still open but cannot be verified does not count as gone. The child finds the parents’ worktree paths and the reason in `bercail job show`. Dispatch records them locally rather than copying changes into the child’s checkout. Leave `Blocked by:` in place: the board still shows what must land first.

The board reads an Entire repo's open trails with one `entire trail list --project <forge>/<project> --repo <origin> --status open` and its pages (100 trails each; past 20 pages, either list fails), the project taken from the origin remote (`entire://host/et/<project>/<repo>`): a repo shows only its own open trails, this list never reads closed history, and there is no `trail show` per trail. A page token that is neither null nor a cursor fails the list. When a `Blocked by:` line names a trail that list lacks (closed, another repo's in the project, or none), one more list reads the whole project, closed trails included, however many such blockers there are. Each repo's list gets 6 of the board's 10 seconds: a slow repo is UNKNOWN and the rest stays. The repos are read at the same time, so slow repos cost the board their slowest list, not the sum of them. While a repo still has `.beads` (Lesentiel until J20 moves its issues), the board shows its beads jobs and its trails together; once `.beads` is gone it reads trails only.

Dispatch, `job show` and `job comment` check that the trail is scoped to the checkout's repo (its `repoIds` hold the id `entire repo view` gives), so a closed trail still has a brief. A question binds project-wide, as `bercail job id trail:<n>` reads it: the trail's Entire id and URL, with no repo check and no local comments. A trail in the `complete` phase was merged and is still open (merged on entire.com, or before `bercail job merge` closed trails): it is not a job, and the board counts those on one line so Shep closes them. Any other open trail is a job when it has a job record, a live desk or background Shep, or has left planning (`draft` and `planning` count as planning); the rest count as other open issues. A job's line shows its phase.

## The Shep view

The bercail layout opens on Shep: its terminal fills the window, with the spaces and agents on the right.

- **Start.** The app starts Shep once per session as one hc terminal, `bercail-shep` (label `bercail.role=shep`), outside every space, running `bercail shep run`. A running Shep is shown again, never started twice. Quit it and it stays quit until **Start Shep**.
- **Spaces.** Click a space, or `Ctrl+Space` and search, to fill the window with it. **Back to Shep**, or `Ctrl+Shift+H`, returns. Switching starts and stops nothing, and the keyboard goes back where it was.
- **Agents.** Click an agent to open its terminal in a dialog; what you type goes to it, and nothing is sent for you. **Show in space** goes to its space.
- **Decisions.** **Decisions N** shows or hides the [Decisions panel](#the-decisions-panel), in a column left of Shep's terminal that it shares with the Routines panel. With neither shown, the terminal takes the full width; drag the column's edge to widen it (280 to 520px).
- **Routines.** **Routines** shows or hides the [Routines panel](routines.md#the-routines-panel): each routine's state, its last run and findings, and **Ask Shep** to send Shep your request about one.
- **Authority.** The view only shows things. The same guard applies the repo's trusted [push policy](config.md#git-policy-per-repo) to Shep and its desks. A foreground Shep commit in any repo runs with a [guard warning](config.md#warnings-and-refusals); a background Shep cannot commit. Shep repeats guard warnings in its report. Warnings and refusals, including your “no”, go in `~/.local/state/bercail/guard-warnings.jsonl`. It runs `bercail policy show <repo>` before it commits, merges, pushes or releases, ships with the desk's `/validate` description, and holds a change that needs [review](config.md#review-by-stakes-and-size) for your LGTM. A trail merge (`bercail job merge`, or `entire trail merge`) needs your Allow, unless the repo lists it in [`shep_may_run`](#where-the-repo-opts-in) or its card [defaults](#when-nobody-answers-a-guard-card). Shep's session never waits on a guard question: what the guard would ask you goes to a [guard card](#guard-asks). An intent-only trail (`entire trail create --no-branch`) and `entire trail update` (and `bercail job supersede`) run with a warning, since you are fine with the team seeing trails. A push the guard asks about is named in its question (`Allow this push to origin: 1a2b3c4 as master?`), so a command that also commits asks about its push alone. A push you already approved on a Decisions card runs without that second question, once: see [A push your answer approves](#a-push-your-answer-approves).

When Pi exits with an error, its message stays until you press Enter.

When the terminal closes or `bercail shep run` gets `SIGHUP`, `SIGINT` or `SIGTERM`, it sends Pi `SIGTERM`. After a grace of 5 seconds by default (up to a second more), what still runs gets `SIGKILL`, since a Pi stuck after a provider switch ignores `SIGTERM`: Pi and the helpers `ps` showed under it, before the `SIGTERM` or, while Pi is the same process, at the end. A helper that left Pi's tree before the first look is not one of them. The stop runs in its own process group, so it finishes even after `hc kill`, which kills the terminal's group, `bercail shep run` included, a second after the hangup. A `bercail shep run` still there, as after a `kill` of its pid, names the pids it sent `SIGKILL`, if any, and exits 128 plus the signal, without waiting for Enter. Without `ps` it can still stop Pi, after the same grace, but not its helpers. Shep's scratch folder (`TMPDIR`) is removed after the stop, once nothing has it as `TMPDIR`, waiting up to a second for that; after `hc kill`, or with a process still holding it, `bercail scratch sweep` removes it later.

## Shep on Pi

Shep runs in `~/.local/state/bercail/shep/workspace`, with sessions in `pi-sessions/` beside it, and continues the most recent session at each start (`pi --continue`). It uses bstack's lead model, extensions and logins (`~/.local/share/bercail/pi/lead.json`). Its rules and [start context](#what-shep-knows) go in with `--append-system-prompt`, and it loads no context files, so your global Pi `AGENTS.md` is untouched. Its extensions include the desk's `bercail-desk.ts`, `inbox.ts` ([desk events](#desk-events)), `compaction.ts` ([compaction](#compaction)) and `question-commands.ts` ([questions](#targeted-questions)). It gets the `handoff`, `desk-restore`, `how`, `why`, `unslop` and `describe` skills that are installed, and needs `pi` on the PATH (`bercail bstack setup`).

Its commands are in [the CLI reference](cli.md#install--cli); `bercail shep diagram [FILE]` is [below](#diagrams-in-chat).

bercail no longer reads `backend` and `session` under `[shep]`; delete them whenever you like.

## Diagrams in chat

Pi draws a `mermaid` block as box art (`markdown.mermaid`, on by default). Shep uses about 15 nodes at most, short labels and at most one labeled edge out of a branching state, then gives the transitions as text. A diagram too wide for the pane, or over 128 nodes, shows as source.

Pi turns `click` and `link` targets into live links, `javascript:` included, so a diagram Shep did not write goes through `bercail shep diagram` first. It drops those statements, erring toward dropping, and says on stderr how many. The renderer deletes control characters and splits words on Unicode spaces, so `cl\x01ick` or a no-break space before `click` still links; the helper deletes the same characters, splits statements on `;` outside quotes, and skips leading spaces and non-ASCII bytes, so those are caught. A state named `link` goes too.

A desk's statechart is the [statechart skill](bstack.md#statecharts)'s `chart.pi.md`, 20 states or fewer with its rule-breaking states in words, since Pi draws no colours. Over 20 states, Shep gives the bug's path from `report.md` as numbered text. The Shep inbox chart is 78 columns wide; in a narrower pane Pi shows its source.

## What Shep knows

What Shep needs for good sits in files bercail keeps, outside its session, so a compaction or a new session loses none of it.

### Known repos

bercail works the repos out each time from `config.toml`'s `[git]` and `[policy."<path>"]` keys, trusted policies, handoff records (a gone worktree gives its main checkout from its `<main>.<branch>` name), live desks' folders, and `~/.local/state/bercail/shep/repos` (one path per line, `#` for comments) for a repo it has not seen. Each becomes its main checkout; a folder that is no longer a checkout drops out. `bercail shep repos [--json]` prints each with its git backend, [policy](config.md#git-policy-per-repo) (`policy trusted`, `policy untrusted`, `no policy`), open issues (`no beads` without a `.beads`, `UNKNOWN` when `bd` fails or takes over 4 seconds), and where it was seen.

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

The repo is `--repo DIR`, else the issue's handoff record, its live desk, or the known repo whose `bd` has it (a trail gets no beads scan). The desk is the live terminal labelled with the issue, else the record's (`gone` when it ended), with `model …` when handed off with `--model`. A `staged:` line gives the staged change's size and [stakes](config.md#review-by-stakes-and-size), whether it needs your LGTM, and what [`bercail describe check`](cli.md) says. A blocked desk adds the end of its screen (up to 15 lines). The report is the latest comment that is not the handoff note or a todo link; past `--budget` characters (1500) it keeps its first two thirds and last third and points to `bd comments <id>` (a trail: `bercail job show <trail> --repo <checkout>`).

`bercail shep board` lists each open job across the known repos (in an Entire repo, its [trails](#trails-as-jobs)) (`<id>: <title>`, status, desk and state, branch, model): an issue not closed with a live desk, or `in_progress` or `blocked`. Then other open issues as a count per repo, repos with no jobs, desks open on closed or unknown issues, and **Waiting on the person**: blocked desks, finished desks and background Sheps, and your [todos](#todos-for-the-person). Under it, **Decisions** lists what waits on you in the [question ledger](#targeted-questions), never Shep's prose: each pending card, stale and unavailable ones included, named by its desk's Herdr space (the window's name, else the one bercail gave a space it made through hc, kept for 10 minutes in `space-names.json` beside the ledger so a settle runs no lookup for a space it already named; all lookups share 1.5 seconds, and a name not found in time is not kept), else its job or folder, with its prompt, why it is not fresh, and a two-way door's countdown as the panel words it (`two-way door: defaults to auth in 23 min`, or `due in 23 min, but it waits for you while it is stale`); and each default you have not said OK to. A reversed default waits on Shep, not you, so it is not listed. With none it says `- nothing`. Its live checks run beside the board's other reads and its queue, within 4 seconds, so they add nothing to the board's 10-second limit: a ledger it cannot read, or checks that take longer, make it `Decisions: UNKNOWN`. They do not read a planning, review or action card's issue back from beads, whose calls on one database queue behind each other; a land card's check still does, and so do the panel and the checks before an action. `bercail shep question waiting` prints the block alone. When anything waits on your review, it ends with the **review queue**, which `bercail shep queue` prints alone:

```
Review queue: 12 lines in 3 changes
~/Work/app: 12 of 10 lines, over its review budget
- app-2: Add the export · 6 lines staged in 1 file · stakes high, needs the person's LGTM · described · ~/Work/app.export
- PR #12: Teammate fix · 4 lines · https://github.com/o/app/pull/12
- app-3: Old job · 2 lines staged in 1 file · stakes low · describe check fails: no .bercail/description.md: run /validate · state unknown: issue closed but staged changes remain; custody/outcome unproven · ~/Work/app.old
```

Parent and child links are not read as replacements. A staged change is queued once its desk is not working, and so is a merge under way that changes no file, since it still lands a commit. A merge of the trunk is measured from the trunk's side, as `describe check` measures it, and its line says `measured against <trunk>, the trunk side of this merge`. Each is marked `described` or `describe check fails:` and why (from a copy of the index, without the no-beads-ids rule). Its state comes from records, never prose:

- **review**: it waits on you. **lgtm**: the same, and its policy requires your review (a `high_stakes` path, or `review = "always"`).
- **superseded**: `bd supersede` or `bd duplicate` names a replacement, or the latest handoff went to another worktree that still exists. Listed last, not counted.
- **unknown**: bd cannot say, or a closed issue still has staged changes. It counts: closed is not safe to clean up.
- **stale**: no open Herdr space has the worktree (from `herdr-app ls`; with no window answering, nothing is stale). Not counted; listed as cleanup candidates.

An open GitHub PR counts when it is not a draft, not approved, and asks you for review or comes from a handoff branch. Lines leave out lockfiles, and generated and binary files in staged changes. Each repo is weighed against its [`review_budget`](config.md#review-by-stakes-and-size). `queue --repo` has a 6-second bound and the board 10; a slow source is UNKNOWN, never an empty list, and never holds accepted work. Repos are read at once, and within each its staged worktrees, open PRs and trails, so their reads overlap instead of adding up. A repo's staged worktrees go one after another, their issues read from bd in one `bd list --id` call, since `bd show` takes up to a few seconds per issue. The board reads its desks only once, and reads each desk and each repo at the same time.

On a repo hosted on Entire (origin `entire://<host>/et/<project>/<repo>`), the queue also lists each trail change in review: an open change in that repo, on an open trail in the building phase. It uses Entire's read-only commands: the repo's one trail list per refresh (`bercail job list`, with its pages; on the board, the list the board already read), then one `entire trail show` per open trail in the building phase and one `entire trail finding list` per open change of this repo on it, the trails and their changes in parallel, so the calls grow with those trails and the list's pages, not with the repo's trails. A change says its trail, the change as `<repo>/<n>`, its open findings by severity, its gates, and its page on entire.com:

```
- trail 7: Read the gateway frames · change kvm/9 · 3 open findings (1 high, 2 low) · gates: waiting on approvals · https://entire.com/et/lab/-/trails/7/changes/kvm/9
```

The gates read as the [background Shep's trail wait](#background-sheps) reads them: `every blocking gate passed`, the blocking gates that `failed`, `waiting on` the others, or `no gate state yet`. A trail change waits on you but brings no lines: they were counted when staged, and its findings and gates are what wait now. A handoff on the change's branch lends it the desk's worktree and space. A failed list page, a failed Entire read, or an answer that is not its JSON makes the queue UNKNOWN, as a failed PR read does.

`bercail shep queue --json` (`schema: "bercail.queue/v1"`) is the same for the Herdr app: `at`, when it was read; `items`, those that count first, each group longest waiting first (`since`: when a worktree's changes were last staged, a PR was opened, or a trail change's `updatedAt`), each with its `kind`, `state`, `counts` and, when known, `space`; and `repos`, each repo's lines against its budget. A staged change adds `why`, `by` (the replacement), `change` (size and stakes) and `described` (`null` when it does not count); a PR or trail change adds its `lines` (a trail change's are 0). A trail change is `kind: "trail"`, with `trail`, `repository` and `number` (the change), `url`, `branch`, `findings` (`open`, `high`, `medium`, `low`) and `gates` (`state`: ready, pending, failed or unknown; `text`).

To retire a landed worktree, use `bercail cleanup <worktree>` from outside its space. The guard asks you first, on a [guard card](#guard-asks) when Shep runs it. Cleanup archives `.bercail/`, ends the desk, its siblings and what they started, parents first, stops your processes still running in it, removes the checkout and closes its space without deleting the branch. With a window open it reports the sidebar's open and recent space counts. See the [CLI reference](cli.md) for refusals. This is separate from [agent scratch](bstack.md#how-it-runs): temporary copies belong under the agent's disk-backed `TMPDIR`. Bercail reclaims managed scratch after the run and its processes exit; `bercail doctor` lists leftovers and `bercail scratch sweep` removes eligible ones.

### Stale code

Pi loads bercail's extensions (`-e`), and the files they import from their own folder, once when it starts; `bercail update` replaces the files, not the code a running Pi holds. A deploy leaves a file whose content did not change in place, so its time says when that content arrived. A live Pi may run stale code when one of the files it loaded changed in or after the second it started, or is gone. That is a hint, not proof: a change and a change back count too, and an extension a release adds to the profile, which an old Pi never loaded, does not. The processes come from `/proc` (Linux), each named by its `HC_TERMINAL_ID`; a Pi counts as a terminal's own only when it is that terminal's process or its child. `bercail update` ends by listing each one and how to restart it: Shep, quit its terminal and **Start Shep**; a desk, quit its Pi, `Ctrl+Shift+A` in its space, then `/resume` its session; a background Shep, let it report and start a new one with `shep bg`. The brief and the board add `, may run stale code` to such a desk, and the board lists those desks under **Waiting on the person**. This names stale processes; it does not stop one from writing.

The guard does not wait for a restart. Each tool call, it hashes its own file (`~/.local/share/bercail/pi/extensions/guard.ts`) against the one it loaded. When they differ, it refuses that call and every one after it, and once the turn ends it reloads Pi (`/reload`: every extension again, the same session) and tells the agent, which goes on under the installed guard; after an Escape the agent waits for you instead. A reload drops the old guard before it loads the new one, and a desk's follow-ups still start turns, so the old guard first loads the new file in its own process, under a name of its own, and checks that it registers. When it does not (a file that does not parse, or an extension that throws), there is no reload: the old guard stays and refuses every call, saying why, until the file changes. Should Pi then fail to load a guard that passed that check, Pi exits rather than run without one, and says why; start it again once bercail is reinstalled, and `/resume` its session. So a guard rule reaches Shep and each desk on its first tool call after `bercail update` installs it, from a release or from the clone bercail was installed from ([development](development.md)), with no restart. A headless run (`pi -p`) cannot reload: it refuses the call and ends. A guard that cannot read its file refuses every call until Pi restarts. The guard hashes its file once it has loaded, so an install that lands in that instant goes unseen until the next change. The guard a release before this one shipped has no such check, so a Pi still on it needs the restart above, once; until then `bercail config set` and `routine enable` write nothing from its shell, since they [take your terminal](config.md).

### Review in the Herdr app

The spaces list reads that JSON every five minutes, and after a desk's status changes (at most every 30 seconds). Nothing it reads moves your view or keyboard.

- A space whose work waits has a mark: `◆` and its lines, `?` when unknown. It is red when a change needs your LGTM, the accent color otherwise; the tooltip says "needs your LGTM" too. Superseded work is dim.
- The Spaces header counts what waits (`◆ 3 to review`, or `2 to clean up`), with `(stale)` when the last good read is over 15 minutes old or the last read failed. A failed read clears the list and shows the error, never "nothing waits".
- `Ctrl+Shift+J` goes to the next space that waits, in queue order ([keys](keys.md)).
- A click on the count opens the **Review** list: each item's space, issue, lines, stakes, LGTM, age and state, then what does not count, then stale worktrees under a cleanup heading. A trail change shows its open findings in place of lines, and its gates. **Open space**, **Open review** (its Review tab), **Open PR** and **Open trail** (a trail change's page) are its only actions: no merge, commit or LGTM button.

### Todos for the person

Steps only you can take (create a login, plug in a device) go on your todo lists, not in Shep's chat. Each list is a named target, picked by the job's repo ([set them up](config.md#todos)); Basecamp is the one backend.

```bash
bercail todo add "Create a Tailscale login for the HA box" --notes "Admin console, Users, Invite" --due 2026-11-20 --issue app-7 --repo ~/Work/app
# added to home: Create a Tailscale login for the HA box · due 2026-11-20 · https://3.basecamp.com/…/todos/900
# linked on app-7
bercail todo list            # home:  - 900: Create a Tailscale login for the HA box · due 2026-11-20 · app-7 · https://…
bercail todo show 900        # its title, open or done and where, due date, link and notes
bercail todo done 900        # complete it (if you have not), and stop the board showing it
```

- **Which list.** `--target`, else the route of the job's repo, else the default. When none fits, Shep asks you, and sets a target and route from your answer.
- **Who writes.** Shep; a desk proposes `Todo: "<text>"`. For every other role the guard blocks `bercail todo add`, `done`, `route`, `target add` and `target rm`, and any `basecamp` command it does not know as a read (`list` and `show` on a resource, bare `todos`, `todolists`, `projects`, `search`, `show`, `url`, `me`, `timeline`, `help`, `version`, `commands`, `auth status`, `config show`). Login, logout and token commands are blocked even for Shep. For an unknown `basecamp` flag before the action, the guard checks both readings (switch or value): it warns if both are allowed for the role, otherwise it refuses. A seatbelt: a script or an unwrapped wrapper (`mise exec`, `find -exec`) gets past it, and reads of the keyring or `credentials.json` are not stopped.
- **The link to the job.** `--issue` (with `--repo` outside the issue's checkout) checks that `bd` knows the issue (a trail: that `bercail job show` finds it), then comments the todo's link on it (a trail: `bercail job comment`), which the brief shows as a `todo:` line. The job's id goes only in the todo's last notes line.
- **On the board.** Open todos are listed by target. One you tick off or remove, or one whose target now names another list, says `done in lesentiel; continue app-7, then bercail todo done 900` until Shep runs `bercail todo done`. A list that does not answer in 10 seconds, or a logout, is one line for that target, and the others still show. The board reads Basecamp each time it runs; there is no poller holding your login.
- **What it keeps.** `~/.local/state/bercail/todos.jsonl`, a line per todo added and per `todo done`. The text goes to Basecamp as written, so no secrets.

### Standing rules

Shep records a rule you give it in conversation as soon as you say it, so it outlives the session:

```bash
bercail shep remember "Merge finished desk work straight to master and push" --scope bercail
bercail shep list        # 1. 2026-11-11 [bercail] Merge finished desk work straight to master and push
bercail shep forget 1
```

They are `- DATE [SCOPE] RULE` lines in `~/.local/state/bercail/shep/preferences.md` (`--scope` is a repo, issue, desk, or `all`, the default; a repeat is kept once), in the start context and every compaction summary. A rule for everyone belongs in [`shep/SHEP.md`](../shep/SHEP.md) or a repo's [policy](config.md#git-policy-per-repo). The [rules routine](routines.md#the-rules-routine) finds the ones that no longer apply: a past night or day, a desk that is gone, a once-only permission already used, or one a later rule may cover. Shep asks you before it forgets any.

In a repo with Entire's Brain, a desk proposes a memory about the code as `Memory: "<text>" --path <p>` and never records one. Shep records it with `entire brain remember` from the repo's main checkout without asking you, and its report shows the text, the path and the fact ID; `entire brain memories retract <id>` takes one back. Brain takes only a taxonomy path, `category.subcategory.type` under `architecture`, `constraints`, `preferences`, `project` or `workflow` (such as `workflow.testing.rules`), so Shep maps a desk's file path to one and names the file in the text as its locus.

### Mistakes

A mistake seen twice should get a fix in the system, not a second fix by hand. Shep keeps a ledger in `~/.local/state/bercail/shep/mistakes.jsonl`: when, a short key, what happened, the repo and issue.

One cause often shows up under several keys, so each key belongs to a group, and the group's count is the one that matters. A group has a short ID, a name, and what its mistakes count against: `process` (a bercail step that caused them), `tool`, or `conduct` (how an agent worked). `~/.local/state/bercail/shep/mistake-groups.json` holds the groups and their keys.

```bash
bercail shep mistake group G7 "Test isolation" --against tool tests-touch-real-state   # make or rename a group, move keys into it
bercail shep mistake tests-touch-real-state "the handoff test wrote to the real handoffs.jsonl" --repo ~/Work/bercail --issue bercail-4k9
bercail shep mistake list   # each group with its count and keys, most frequent first
bercail shep mistake list --json   # the same as data: each group's id, name, against, count, keys with their entries, and the issues they name
```

A key is a-z, 0-9 and `-`, the same each time. A key in no group needs `--group` when it is recorded, and keeps that group after; only `mistake group` moves a key, since a move changes the count of its past entries. At a group's second time the command says so, with the fix that fits: a guardrail for a `tool` group (a lint rule, a test, the guard, or a doctor check), a rule in SHEP.md or a skill, or a check, for a `conduct` group, and removing or simplifying the step for a `process` group. Shep writes that issue, labels it `mistake:<group>` and `routine`, and tells you. The [mistakes routine](routines.md#the-mistakes-routine) reads the label to tell a group with a fix from one without.

What counts as good conduct for Shep is written down as [behavior specs](../.agents/behaviors/README.md), for reviewing its traces rather than for its prompt. Their README maps each group of mistakes to a spec, or marks it a product bug.

### The start context

Each `bercail shep run` writes `~/.local/state/bercail/shep/context.md` and passes it to Pi: the known repos, one line each, the todo targets and routes, and the standing rules. A restart picks up what changed while Shep was down.

## Targeted questions

A question has a durable token such as `Q42@3`, independent of the conversation:

```text
/questions                 list pending questions, choices and exact targets
/reply Q42@3 yes           propose an answer to that revision only
/thread release-plan       return to that topic's question context
/thread all                clear the selected topic
```

A bare `yes`, `1` or `LGTM` answers nothing. A stale revision is rejected, a conflicting reply kept as rejected, and a repeated request id is idempotent (with other content, an error). Notices never select a thread. It is one shared Pi conversation, not isolated threads.

**Replies are unverified proposals.** Extensions can call Pi commands, and no input source, RPC or keystroke proves a person sent one. There is no `approve` switch or trusted confirmation path, so a reply leaves the question pending. Only your pick on the [Decisions panel](#the-decisions-panel) or in Discuss answers. A proposal never permits a desk prompt, guard approval, commit, merge, publication, spend or scope change, and Shep never calls one your decision.

`shep_question` binds a question to an explicit checkout and job, checked against the repo's beads, and never finds a job from a bare issue id. A repo is its git common directory, shared by its worktrees; another clone is a separate repo. The desk is optional: a named desk is checked against hc and its `desk-sessions` record, and only one that passes lends the question its space and session. A desk that is gone, has no record, sits in another folder, belongs to another job or has no verifiable Pi session is a **warning** on the card, as is a job question with no desk; the card still reaches the panel and can be answered. Invalid fields, an unknown issue, an unreadable checkout or a base ref that cannot be resolved stop the request. In an Entire repo the job can be a [trail](#trails-as-jobs), checked with `entire trail show <n>` instead of beads: a trail the repo's project lacks is refused, and the question keeps the trail's Entire ID and URL. An answer holds to the ID: the same number in another project is another job, which makes the card stale and which a revision cannot move to; a moved URL does not. Review and action questions record desk, space, session, worktree, action, branch, head, staged tree, and the base ref with what it resolved to; a planning question records no branch, head or tree, so commits leave it fresh unless it names a base that moves. An answer holds to the job, branch, staged tree and base, not the desk, and to HEAD only loosely: one commit of the approved tree on the asked HEAD and branch (a single parent, that tree) keeps it fresh, as does a base of HEAD or that branch moved by that commit. A question also records a merge under way (`MERGE_HEAD`); while a commit is still owed, a merge started or dropped since makes it stale. On a `merge` or `land` card asked while the desk merges in the asked base, the commit that finishes that merge, with the asked HEAD and then the base as parents, keeps it fresh too. A `merge` card takes HEAD, not the index: once HEAD holds the approved tree (as asked, or by that commit), what the desk stages next leaves it fresh, and a pick records the approved tree. Its base may also move ahead of the asked base while HEAD holds that tree and git merges it into the new base with no conflict, attributes included; config that names a merge driver or renormalizes makes that stale, since a check runs no driver. A `land` card keeps its index and base bound: `bercail land` commits what is staged. A push changes no pinned fact. A changed intent or candidate is a new revision (a revision cannot change repo, job or topic). Withdrawing (`shep_question_withdraw`, with a reason) takes a question off the panel for good, and is not an answer. It applies to a pending question, and to a default you have not said OK to: one Shep found moot, or one you reversed, once Shep has handled it. The ledger keeps the default and your Reverse. Your [Close](#reversible-questions) on the panel is the same withdrawal, recorded as yours.

Shep's model gets back only the token, status, deadline and door, and the live check's status, reasons and warnings, each cut to 300 characters. The whole question and check, policy included, stay in the tool result's details, which the session file keeps and the model does not see. `question get` prints the revision and `question check` the policy when Shep needs them.

`bercail shep question check Q42@3` rechecks target and policy and always reports `authority: false`: fresh is not permission, and guard, shipping and desk-prompt authority stay separate. It re-reads the desk, branch and candidate live. A changed repo, job, branch, head (beyond that one commit), tree, base or action (beyond the passes above) makes it **stale**; an unreadable target or policy makes it **unavailable**. Neither can reuse an answer. Desk problems are its `warnings`, never a reason to bind to a replacement terminal. Shep reports the warnings. It must recheck the target and policy through the usual safeguards before an authorized action: `check` runs nothing and does not close a race with a shipping command.

By default, rebasing the candidate onto a new trunk makes the card stale. A repo can opt in with [`rebase_keeps_pick`](config.md#git-policy-per-repo). For a commit or merge card asked under that policy, a clean replay of the same patch onto the new trunk can keep the revision fresh. The check and the card's brief say `fresh (rebased: patch unchanged)`. It covers a single patch, staged on the trunk's old tip or committed directly on it. A rebased card waits for a person instead of timing out. A changed patch or a conflict still needs review. This exception never approves a push, guard request or land card.

The ledger, not the transcript, owns question state. Shep reloads it before each model run and in compaction or rollover, and stops deciding when it is unavailable. Each time Shep's run settles, its question extension runs `bercail shep question waiting` in its own process. When the block's text differs from the last one on the session's branch (a new card, a countdown, a status), it goes right after the reply that settled; a failed run shows `Decisions: UNKNOWN`. A result that comes back after another reply, a `/tree` move or the session's end is dropped; only the latest reply that settled meanwhile gets another run. That entry is never sent to the model, so Shep cannot write or reword it, and Shep's rules forbid listing pending decisions in its own words. The store is `questions.json` under `$XDG_STATE_HOME/bercail/shep/` (`~/.local/state` by default).

The store never overwrites a `questions.json` it refuses. Its error names the record and the field that failed, as in `corrupt questions.json at Q12@1 (questions[11].guard.defaults): unexpected field` or `at request <id> (requests[3].result.question.answer.at)`. It shows no value from the file, only request ids and field names. Some checks name only a sub-object, such as a proposal or a guard card's op. A process older than the code that wrote the file refuses fields it does not know. So when a file that parses is refused and the refusing process's own `shep/pi/questions.ts` changed since it loaded (a deploy replaced it), the error says `this process cannot validate questions.json` and to restart it and retry before considering a repair. Before each write the store keeps the file it replaces: `questions.json.1` is the newest, then `.2` and `.3`, beside it.

To recover, first run a fresh reader: `bercail shep questions --json --all >/dev/null`. If it reads the file, the file is sound and the refusing process is stale: quit Shep's terminal, then **Start Shep**. Do not restore. Restore only when a fresh reader refuses it too. Then stop Shep and anything that answers cards, and keep the damaged file. Validate the backup you pick in a scratch copy (`XDG_STATE_HOME=<scratch> bercail shep questions --json --all` with the copy at `<scratch>/bercail/shep/questions.json`; check the copy is there first, since an empty folder reads as an empty ledger). Check that the answers and claims made after it (push approvals, guard claims, land claims) match what really ran. Copy it into the same folder under a new name with mode 0600, then rename it over the file while holding the lock: `flock questions.lock mv <copy> questions.json`. Never `cp` a backup over `questions.json` in place: an interrupted copy tears the file, and after an interrupted write `.1` and `questions.json` can be one file.

### Reversible questions

A decision that can be walked back should not keep work waiting on you. Shep marks such a question `reversible`. It waits for you until its deadline, 30 minutes after it was asked by default (`[shep] decision_timeout` in [config](config.md), in minutes; `0` never defaults), then takes Shep's recommendation. Shep's brief on the card says it defaults to the recommendation when the card counts down, and in chat Shep gives the returned deadline; with none returned, it waits for you.

A two-way door is cheap to walk back, so it may default; a one-way door always waits for you. The helper decides with this table (`door()` in `shep/pi/questions.ts`, one test per row) and refuses `reversible` on a one-way door. The door comes from what the card can do: its kind, its action, and whether it carries a push. Only the actions `commit`, `merge` and `land` are in it; a planning pick has no action. No word in the prompt, choices or brief changes the door, so a brief can describe a design that publishes.

| Door | Row | When |
|------|-----|------|
| one-way | an LGTM | any review question: its answer is an LGTM, and a default never is one |
| one-way | a guard or land card | kind `guard` (a [guard card](#guard-asks), whose own deadline is [its own rule](#when-nobody-answers-a-guard-card)), and any kind but planning, review and action |
| one-way | a push | a question with `push`: a default never approves a push |
| one-way | an action no two-way row names | any action but `commit`, `merge` or `land`, and any action on a planning question |
| two-way or one-way | a merge or land | action `merge` or `land`: two-way only where the repo's policy says [`merge_reversible = true`](config.md#git-policy-per-repo), trusted |
| two-way | a local commit | action `commit` |
| two-way | a planning pick | no action: which desks to start, their order, a scope or approach, keeping or skipping a step that publishes nothing |

**A default authorizes only its card's own action:** the local commit on an action `commit` card, or the merge on an action `merge` or `land` card where the policy says `merge_reversible`. A planning card's default decides a plan, an order or a scope, and authorizes no write. "Delete the old branch?" asked as a planning pick can default, but its default does not let Shep run `git branch -D`. That rule is in Shep's prompt, not in the code. The guard and [push approval](#a-push-your-answer-approves) rules still apply, and a default never approves a push.

The deadline is in the ledger. Shep's question extension runs `bercail shep question expire` at start and every 30 seconds, so at its next start it defaults the questions that are due, still fresh and still two-way. Each due question is checked live and the policy reread: one whose candidate changed keeps waiting for you, and a merge the policy no longer calls reversible waits with no countdown and can still be picked. Past the deadline of a door still two-way, the panel offers no pick. Shep checks again before acting on a default, and acts only while fresh and two-way.

The default is the ledger's answer, not yours: source `default after timeout`, once per revision, with a [decision event](#desk-events) saying nobody picked, retried until it is in Shep's inbox (then marked `told`). Shep lists defaults apart from your picks and says the choice was defaulted. Until you say OK to it, a default is never an LGTM or a reviewer, so no `--reviewed-by`; `question answer` refuses its source.

**OK** on a defaulted card makes the default yours. It counts exactly as if you had picked that choice on the card, with its full weight, an LGTM included where the card asked for one; so Shep may then pass `--reviewed-by` for it. (A review question is a one-way door and never defaults, so in practice an OK confirms a planning pick, a commit, or a merge the policy calls reversible.) The ledger keeps the default as it was and adds your OK beside it, once per revision, with the picker that said it (`panel picker` or `discuss picker`), its time, head and tree, only while the live check is fresh. Shep gets a decision event (`decision-Q<n>-<rev>-ok.json`) and lists the question with your picks as a `confirmed default`. Shep keeps what it did on the default and does not do it again, or, if it had not acted on the default yet, acts on it once as your pick. An event that cannot be written when you say it is sent from the ledger at Shep's next expire run, then marked `told`, like a default's.

**Reverse** on a defaulted card rejects the default, with no other choice or with another of the card's choices (pick it first: `2`, then `r`). It is recorded the same way (outcome `reversed`, the other choice or none), once per revision and only while fresh; a second Reverse, or an OK after one, is refused. Shep gets `decision-Q<n>-<rev>-reversed.json`: it undoes what it did on the default (a local commit, a step it took, only what it took), then acts on your other choice once as your pick while the check is fresh, or asks again. The card stays on the panel as **reversed** until Shep has done that and withdraws it with a reason saying what it did.

**Close** (or `x`) takes any card off the panel, whatever its state: pending, stale or unknown, defaulted, or reversed. It is not an answer and carries no weight. It runs no live check, so a default whose own action moved what it was asked about (its commit went on a stacked branch, a restack rewrote it) never sits stuck. The ledger records it as a withdrawal by you (`source` `panel picker`, reason `closed by the person on the panel`), keeping the default and any Reverse, once per revision. Shep gets `decision-Q<n>-<rev>-closed.json` saying what the card was (it reads no Discuss branch): on a pending card it does nothing, a default stands as Shep's, and a reversed default is still undone once, as its Reverse event says; Shep asks again rather than act on your other choice. A guard card's worker reports it as withdrawn, and nothing runs. Only a land card whose chain runs has no Close: closing would hide the chain, not stop it.

### The Decisions panel

Each question Shep asks is also a card. **Decisions N** in Shep's header counts the pending ones and shows or hides the panel; a new card only changes the count. A card says where (the desk's space), what (lines and stakes), what Shep asks, its brief, recommendation and why, the choices, and when. If the live check finds the candidate **stale**, the card says what changed. On a pending planning, review or action card, **Ask again** sits beside **Close**. A card Shep cannot check (the checkout is gone, the policy unreadable) says **unknown**. A desk problem, or no desk at all, is a `Warning:` line on a card that can still be answered. A card bound to a trail has **Open trail**, its page on entire.com. A [two-way door](#reversible-questions) with a deadline counts down (`two-way door: defaults to auth in 23 min`), and once defaulted says **defaulted** and stays until you say **OK** or **Reverse**, or **Close** it (it no longer leaves after a day); the header counts these apart (`Decisions 2 · 1 defaulted`). A defaulted card that went stale or cannot be checked says why: there is nothing to confirm, so it takes no OK or Reverse, only **Close**. Discuss on a defaulted card still works, and closing it without an OK or Reverse tells Shep what you would change. Tokens never show. The panel reloads with the ledger, and every 30 seconds while shown; with a [`[herdr] backend`](config.md#bercail-on-another-machine), on that machine.

**Ask again** records no answer. Shep checks the revision and the reasons it went stale. If the base moved, Shep asks the desk to rebase. For a code change, the desk reports back and its description must pass before Shep revises the question. The new brief tells you which base moved, whether the desk resolved conflicts, and whether the patch changed. Closing the card first stops the request; a late event cannot reopen it.

#### Answering

The picker on a fresh card starts on Shep's recommendation (★), unless its pick is hard to undo (below). Click in the panel to give it the keyboard; showing the panel from the header does not. While the panel has the keyboard, its top edge is the accent color, the chosen card has a solid border, and the hint under the header lists only the keys that card takes now. Then:

| Key | Does |
|-----|------|
| ↑ ↓ (or k j) | choose the next or previous card and scroll it into view; with none chosen, ↓ chooses the first and ↑ the last |
| ← → or 1-9 | pick another choice |
| Enter | answer with the picked choice |
| o | OK a defaulted card: keep its default as your pick |
| r | Reverse a defaulted card, to the picked choice when it is not the default |
| x | Close the card: off the panel, with no answer; a default stays Shep's |
| a | Ask again on a stale planning, review or action card |
| d | open Discuss |
| Esc | give the keyboard back to Shep's terminal |

A click picks a choice and **Answer** records it; on a defaulted card, **OK** or **Reverse** records yours. A card with no recommendation waits for a pick; stale and unknown cards have none; a question with no choices is discussed in chat, which records no answer.

The keys act only on the card you chose, with ↑ ↓ or a click anywhere on it, and no card is chosen until you choose one. A reload never moves the keys to another card: when the chosen card leaves, none is chosen. Enter, o, r, x and a record only on a card that shows, by where the panel laid out its cards, where the list is scrolled, and whether the window cuts the panel off. When it does not show (after the wheel or the scrollbar, or a reload that moved it), the first press scrolls it into view and records nothing; press again to record. A card taller than the panel counts as shown once its title and prompt do, even with its choices below; Enter then records the picked choice. These keys act when you release them, after one short press (under 300 ms) with no modifier, on the card and choice you pressed them for. A key held long enough to repeat does nothing, and a held arrow or number moves once. When the panel gets the keyboard back (a click into it, or the window coming back to the front), the first key you press and release does nothing, Esc aside: it may be the repeat of a key held down elsewhere, which Herdr does not mark on every system. A card whose pick is hard to undo starts on no choice, with ★ still on Shep's recommendation: a push the answer approves, a guard card, a land card, and a review that is not known to be low stakes. Pick its choice (a click, a number or an arrow), then Enter.

The picker records an answer once per revision, only while the live check is fresh, with its source (`panel picker` or `discuss picker`), time, head and tree. A second pick is refused. Shep gets one [decision event](#desk-events) per pick.

A click or key in the panel counts as yours: a record you own, not proof of who pressed it, since any program running as you can type or click. Herdr's scripted paths (keys.json, the palette, `herdr-app do`) never reach the panel. For agents the guard blocks writes to Shep's state folder, `questions.json` included, `bercail shep question answer`, and synthetic input (`wtype`, `ydotool`, `xdotool`, `dotool`, `evemu`, `/dev/uinput`, and `hyprctl`'s `sendshortcut`, `sendkeystate`, `pass`, or a `dispatch exec` of one). A seatbelt, not a sandbox.

#### A push your answer approves

When the guard would ask about a push of Shep's (the repo's `push` policy is `ask`, a push to main under `branch`, or a release tag), Shep can ask it as a question instead, with a `push` field naming the choice that approves it, the remote and the full refs (`refs/heads/master`; `refs/tags/<tag>` only with action `release`). The helper records the remote's one push URL as git would use it, and refuses a planning or reversible question, a choice not among the options, a remote with several push URLs or none, and a URL the card cannot show: only an absolute path, ssh with no password, or http(s) or `entire://` with no user, query or fragment. The card says `Picking "Push it" lets Shep push the answered commit to origin (<url>): refs/heads/master, once.` Discuss shows the same and says a `/pick` there does not approve the push, and its picker marks that choice `approves the push only on the panel card`.

After you pick it on the card, Shep's push runs with a [guard warning](config.md#warnings-and-refusals) that names the question, `Allowed this push without asking: the person's Decisions answer Q42@1 approves it, once.`, and no prompt. Where the guard would ask, it runs `bercail shep question push-approval`, which finds the answer and claims it. Every one of these must hold, or the push goes to a [guard card](#guard-asks):

- The command is only `git -C <absolute folder> push <remote> <hash>^{commit}:<full ref>` (a tag: `<hash>^{tag}`), with nothing before or after it, no flags, quotes, variables, env prefix or `-c`, and `git` itself, not a path to one. A full hash with `^{commit}` names one object that no ref can shadow.
- It is the only tool call of Shep's message. Pi checks every call of a message before it runs any, so a sibling call could otherwise move the remote's URL after the check. A call another tool makes, or a `GIT_DIR` (or `GIT_WORK_TREE`, `GIT_COMMON_DIR`, …) or `GIT_CONFIG` in Shep's environment, never counts.
- You picked the approving choice on the panel card (source `panel picker`). A Discuss pick never counts: Discuss runs in an hc terminal, where an agent can type with `hc send`, and the panel takes no typed input from agents. A default never counts either: a push question is never reversible. A Discuss pick still answers the question; Shep's push then goes to a guard card.
- Its live check is fresh, the folder is in the question's repo, the remote and the set of refs are the question's, and the remote still pushes to the URL the card showed, with no `push.followTags`, `push.recurseSubmodules` (other than `no` or `check`) or `submodule.recurse` to push more. Config it cannot read counts against it.
- Every ref gets the same commit: the answered HEAD, or the live HEAD when it is the one commit of the reviewed tree on it (read from the commit object, so replace refs and grafts cannot fake it). A tag is an annotated tag of that commit, or the commit.
- The answer approved no push before. The claim is in the ledger (`pushed`, under its lock), so the same answer cannot approve a second push. A push that fails after its claim goes to a guard card next time.

Force, `+` refspecs, `--no-verify` and deleting main stay refused. A policy that already lets the push through spends no answer. For agents the guard blocks `question push-approval`. A seatbelt: another process (a desk, or you) changing the repo's remote config in the seconds between the check and the push is not caught, since git reads the config again when it pushes.

#### Discuss

**Discuss** (or `d`) opens Pi on a branch of the session the question came from: if the desk was verified when Shep asked, Discuss branches its last complete entry. Otherwise it branches Shep's session through the turn that asked, including when the job's desk was gone. The branch is a new session in `~/.local/state/bercail/shep/discuss/`; the sources are only read, and `--continue` never picks it up. It runs the lead's model with `read`, `grep`, `find` and `ls` only, and `BERCAIL_ROLE=discuss`, under which the guard blocks every command and edit. `/pick` in it checks live and records the pick like the panel; on a defaulted question it offers OK and Reverse.

✕ or `/pick` closes it; **Continue discussion** reopens it. Closing without a pick sends Shep one event. Both events carry the branch's last reply, cut to 600 characters, as data. Each question has its own branch. A branch's first turn sends it all uncached; with the Claude bridge it gets its own session.

The CLI works without Pi or a mod:

```bash
bercail shep questions              # bounded pending projection (up to 20)
bercail shep questions --json       # what waits on you: pending cards and defaults not yet OK'd, under pending; land chains running, under landing
bercail shep questions --json --all # full snapshot and retained revisions
bercail shep question get Q42@3     # one revision, as the ledger keeps it (the guard's worker polls with it)
bercail shep question check Q42@3   # recheck the candidate and current policy, with desk warnings (and a reversible one's door)
bercail shep question thread release-plan
bercail shep question panel         # the panel's JSON: pending questions and the defaults not yet OK'd or withdrawn, each checked
bercail shep question expire        # record the defaults that are due
bercail shep question discuss Q42@3 # make (or find) the question's branch; prints its session file
bercail shep discuss Q42@3          # Pi on that branch, read-only: what the dialog runs
bercail shep question push-approval DIR REMOTE REFSPEC...  # the guard's: spends the answer that approves this push
```

`question create`, `revise`, `reply`, `answer` and `withdraw` read JSON on stdin. `answer` is the panel's (`requestId`, `token`, `choice`, `source`, or on a default `requestId`, `token`, `source` and `"outcome"`: `"ok"`, or `"reversed"` with an optional `choice`; or the same with `"outcome": "closed"` to close a card, or `"reask"` to request a refresh of a stale question), and the guard blocks it for agents; `withdraw` takes `requestId`, `token` and `reason`. A planning topic without a desk:

```bash
printf '%s\n' '{"requestId":"plan-1","kind":"planning","prompt":"Which approach?","options":["small","full"],"origin":{"event":"conversation:entry-7","session":"shep-session","entry":"entry-7"},"repo":"/path/to/repo","issue":null,"topic":"release-plan","desk":null,"base":null,"action":null}' | bercail shep question create
printf '%s\n' '{"requestId":"answer-1","token":"Q1@1","answer":"small","source":"local-cli:unverified"}' | bercail shep question reply
```

For a job, give its issue and its desk address when it has one (`null` otherwise); review and action also need an action and base ref. `revise` takes the same fields plus `token` and a new request id. `flock` serializes writers, and fsync plus atomic rename keeps the last complete snapshot on interruption. A corrupt store fails closed and is not replaced.

## Compaction

Pi compacts when the context passes `window - reserveTokens`, keeping the last `keepRecentTokens` as they were. Shep has its own threshold and summary.

### Settings

bercail writes `compaction` into Shep's workspace `.pi/settings.json` at each start, keeping its other keys, and leaves `~/.pi/agent/settings.json` alone. Shep starts Pi with `--approve`, which trusts that folder for the process only.

```toml
[shep]
compact_at = 250000   # context tokens at which Pi compacts Shep; 0 leaves Pi's threshold
keep_recent = 50000   # recent tokens kept word for word
rollover = false      # true: a fresh session instead of a threshold compaction, and each new day
```

`compact_at` becomes `reserveTokens = window - compact_at`. 250k because most of Shep's context is `bd`, `hc` and log output, stale once a job moves on and resent every turn; 50k keeps the last desk events and exchanges. A `compact_at` that cannot be placed leaves Pi's threshold, with a word at start; on a window of 250k or less, the default leaves it silently. A `claude-bridge` reserve is never below bstack's 40000. Changes apply at the next start.

### The summary

`compaction.ts` builds it from the job board (`bercail shep board` then), the standing rules, the durable questions reloaded from the ledger, and the narrative, which the model is told not to rebuild question state or approval from. An incomplete board is still used: what answered, under a line naming the sources that were UNKNOWN and, when it ran out of time, saying its end is missing. A board with no output at all, or any other part failing, makes Pi compact its default way. Each compaction, fallback and failure is logged in `~/.local/state/bercail/shep/compaction.log`; a compaction's line gives the summary's size in characters and the tokens before and after (Pi's estimate).

### Rollover

With `rollover = true`, past `compact_at` Shep instead starts a fresh session once idle, whose first message is the board, rules and questions and names the old session's file. So does the first turn of a day, and `/shep-rollover` by hand whatever the setting. A failed rollover is logged, and compaction takes over until Shep restarts. `/resume` goes back to an old session; once you write in it, `bercail shep run` continues it.

## Background Sheps

Shep never deliberately waits more than 10 seconds itself. For a CI run, a deploy, a desk or a release, or a step you approved for after it, Shep writes a job, a beads issue or a no-branch trail in an Entire repo (what to wait for, what to do after, when to stop, what not to do), starts a background Shep on it, tells you in one line, and goes back to you.

```bash
bercail shep bg --issue bercail-ow2        # from the issue's repo, or pass --cwd <checkout>
```

It prints `{address, name, cwd, issue, issue_title}`. The worker is one hc terminal, `shep-bg-<id>`, with no space, so nothing moves. It runs `bercail-desk-agent` on Claude Fable (the `fable` line in `pi/models`; the lead's model when there is none) and the lead's guard, with [`shep/BACKGROUND.md`](../shep/BACKGROUND.md) as its prompt and discovery off. It has read/search/list, guarded `bash` and `shep_wait`. It reads the issue with `bd show` and `bd comments`, reports with `bd comment` (a trail: `bercail job show` and `bercail job comment`), then stops. As `shep-bg` it can run checks but not launch agents, change the checkout, commit, push, tag, release, open a PR, link or merge a trail. It writes only scratch files and its report: the guard refuses a shell write it recognizes outside its temp folders, new unprotected files under `.bercail/` and the standard streams, and a `/tmp` write warns while its `TMPDIR` is elsewhere; there is no write or edit tool. Issue prose cannot widen those limits. The guard is not an OS sandbox. Missing resources fail the start, with no generic fallback. A second `bg` for a live worker's issue is refused.

`shep_wait` waits for CI (`gh run watch`), a desk (`hc wait`), a delay of up to an hour, or a trail. For `kind: trail`, give `target` as `<n>` or `<repo>/<n>` and `head` as at least seven hex digits. Entire finds the project from the worker's checkout, so a trail of another project puts `<forge>/<project>/` before either selector: `et/lesentiel/44` or `et/lesentiel/lesentiel/51`. Every 30 seconds for up to an hour it reads `entire trail show <selector> [--project <forge>/<project>] --json` for the addressed change or the trail's single open change. It returns when that head is mergeable; null gate state means not ready. A different head, failed blocking gate, or merged or closed change stops the wait with an error.

Its labels are `bercail.role=agent`, `bercail.shep=bg`, `bercail.issue` and `bercail.issue_title`, so its finish reaches Shep as a [desk event](#desk-events) saying `Background Shep <address>` (`agent.role` `shep-bg`). It starts with `--no-notify`, `--outlive-parent` and `--rm`; `hc kill <name>` ends it once reported. Its first prompt only names the issue. A step that needs a person comes back in its report with its target, blocker and next action, never as an unwatched prompt, and a finished wait does not complete what it waited for. Shep ends a finished worker; a blocked one stays until its step is settled. The worker never runs the follow-up: a trail merge, for instance, stays in Shep's session after your yes or a standing rule, where the guard hands it to a [guard card](#guard-asks).

## Guard asks

Shep's session never waits on a guard question, so your next message and desk events never queue behind one. When a command Shep runs would make the guard ask you, the guard hands it to a model-free worker instead, and Shep's turn goes on. A push your [answer already approves](#a-push-your-answer-approves) still runs in Shep's session, before any of this. Desks, autopilot and headless runs keep their own rules.

Any one command goes to a card: the command itself, after at most one `cd <absolute dir> &&`. Closing a Herdr space (`herdr-app do space.close`) is one: it ends every terminal in the space. Four operations are pinned to what they act on:

| Operation | Shep runs | Pinned when it asks | The worker runs |
|-----------|-----------|---------------------|-----------------|
| cleanup | `bercail cleanup <worktree>` | the worktree's real path, branch and HEAD | `bercail cleanup <real path>` |
| trail merge | `cd <checkout> && entire trail merge [<trail>]`, or a [trail job](#trails-as-jobs)'s `bercail job merge trail:<n> [--change <repo>/<n>] [--repo <checkout>]` | the repo's main checkout, the trail's Entire ID, its one open change as `<repo>/<number>`, that change's head, and the branch it merges into | `entire trail merge <repo>/<number>` in the main checkout; for a trail job, `bercail job merge trail:<n> --change <repo>/<number> --repo <main checkout>`, which then closes the trail |
| push | `git [-C <dir>] push <remote> <refspec>...`, no flags | the checkout and git dir, the remote's one push URL (a local repo by its real path; an `entire://` remote, shown as its Entire project), and each refspec as a commit to a full branch ref | `git -C <dir> push --no-follow-tags --recurse-submodules=no <URL> <commit>^{commit}:<ref>...` |
| restack push | `git -C <worktree> push --force-with-lease=refs/heads/<branch>:<old head> <remote> <new head>:refs/heads/<branch>`, the worktree as an absolute path with no `cd`, both heads as full hashes | as a push, and the old and new heads. The checkout's last handoff that started a desk names `<branch>` and the checkout's repo, cleanup has not retired the checkout since, and the checkout is on `<branch>` at the new head. On the pinned URL (`git ls-remote --symref`, read at each check, so it needs the network), `<branch>` is at the old head and is not the default branch; a default branch it cannot read fails. Never main or master | the same push with `--force-with-lease=refs/heads/<branch>:<old head>`, so it fails if the branch there moved after the last check |
| config change | `bercail config set <section> <key> <value>`, `config unset <section> <key>`, `bercail routine enable <name> [--at <when>]` or `routine disable <name>`: your `config.toml`, which no other agent may change | the folder's real path, the command's words with bercail itself in place of the program Shep named, and the lines its `--dry-run` adds and removes, under the file's name, which the card shows | bercail with those words and `--expect <the lines' sha256>`, under its write lock (it needs `flock`): it writes only while its edit is still those lines, to the file the card named through its links, and not over a change made since it read the file. An editor that saves in the instant between that last check and the write still loses its save. Once the lines read otherwise (you changed the file), the card is withdrawn as changed |
| desk answer | `bercail desk answer <desk> yes --prompt <id>`, and no other words: a Yes to a desk's [guard prompt](#a-desks-guard-prompt) | the desk's worktree, by its real path, bercail itself in place of the program Shep named, and what the answer's `--dry-run` says: the desk, its job, the prompt's question and its command, which the card shows | bercail with those words, in the desk's worktree. Once that prompt has closed (you answered it at the desk) or another waits, the card is withdrawn as changed |
| command | any other command the guard asks about, such as `entire brain remember "<text>" --json` or `cd <checkout> && entire trail link <n> --branch <b>` | the folder's real path, and the command's words | those words as an argv, with no shell, in that folder |

A command's words are as bash passes them: bare words, and quoted text, single or double, shown on the card as written. Quoted `;`, `|`, `>` or `$(` stay text. Double quotes may not hold `$`, a backtick or a backslash. A command card pins only its folder and words: a publisher such as `gh pr create` or `entire trail link` reads the branch when it runs.

Anything else the guard would ask about in Shep's session is refused, and Shep tells you why: a pipe, a redirect, a substitution, a variable, a glob or `~`, a backslash, a `;`, `||` or `&`, a chain other than one `cd <absolute dir> &&`, an empty argument, a control, format or bidi character, an env prefix, a wrapper (`timeout`, `env`, `sudo`, …) or a shell (`sh`, `bash`, …, by any path), a folder named with `..`, a git command other than a plain push or a restack push, any other force push, a trail merge other than `entire trail merge [<trail>]` or `bercail job merge`, a short push destination (write `refs/heads/<branch>`, since git matches a short one against the remote's refs) or a refspec with no destination where `remote.<name>.push` maps refs, or a tag. So is a push to a remote with several push URLs, a credential in its URL, a `file://` URL (git decodes its `%` escapes; set the remote to the repo's path), or a `url.*` rule that rewrites it again, and a trail with several open changes, unless Shep names one as `<repo>/<number>`.

1. The guard pins the operation's facts and writes a ticket, mode 0600, at `~/.local/state/bercail/guard-asks/<id>.json`. That folder is the guard's: no agent writes it, and the guard refuses `bercail guard ask` and the ledger's `guard-create`, `guard-default` and `guard-claim` when an agent runs them.
2. It starts the worker with `hc run --bg --name guard-ask-<id> --outlive-parent --no-notify --rm`, and waits up to 10 seconds for it to say it started (`<id>.state`). A worker that starts later finds the ticket void and makes no card; then, or when the ticket or `hc run` fails, the guard refuses.
3. Shep's command returns `Handed off, not run:`. Shep tells you in one line, and never retries it or acts on its pick.
4. The worker reads whether nobody answering counts as an Allow ([below](#when-nobody-answers-a-guard-card)), then puts up a guard card, kind `guard`, with **Allow** and **Deny** and no recommendation, and a desktop notice (`Decisions: allow push of …? It defaults to Allow at 15:42.`, or `It waits for you.`). Its brief names the command and every pinned fact, and ends with what its deadline does, and why. You answer it on the panel only: the ledger refuses a Discuss pick on it, since an agent can type into a Discuss terminal. Its deadline is an hour after it was asked; the panel's timer counts down to it. Your Allow counts only before then, on a fresh card; your Deny counts whenever the card still waits, with no live check, so a slow check never lets the deadline pass first, and the panel offers it on a stale or unknown card too.
5. Until you answer, the worker checks the facts every few seconds, and the panel checks them through `bercail guard check`. A fact that moved makes the card stale and the worker withdraws it.
6. On your Allow, or the card's default, the worker claims it once under the ledger's lock, runs nothing if its ticket changed since the card went up, asks the guard again as Shep, pins the facts again, and runs the argv above, never Shep's text through a shell, with stdin closed, in its own process group, for an hour at most. Its output goes to `guard-asks/<id>.log`. A second worker or a restart finds the claim and runs nothing.

The outcome reaches Shep as one inbox event, written from its fields only:

```json
{"source":"bercail","schema":"bercail.guard_ask/v1","kind":"guard","sink":"shep",
 "event_id":"guard:<id>","terminal":"guard-ask-<id>","operation":"trail merge",
 "target":"lesentiel/41","outcome":"ran","exit":0,"log":"<state>/guard-asks/<id>.log"}
```

An event after a default carries `"defaulted": true`, and Shep's line says it ran by default, not on your Allow. `outcome` is `ran` (with `exit`), `unknown` (killed or out of time: some of it may have happened), `denied`, `expired`, `withdrawn`, `changed` (with `why`), `refused` (the guard refuses it now) or `failed` (it stopped before it ran anything, with `why`: its card could not go up, for instance). Your pick's own decision event tells Shep the worker acts on it, and, if no guard event came and `guard-ask-<id>` is not live, to tell you no outcome came and check the target before saying whether it ran.

A few seconds remain between the worker's last check and the run, as with a dialog: entire takes no expected head, and a git config rewrite could land then. A trail's base is pinned by its branch name: a new commit there leaves the card fresh, and entire checks the base's gates again when it merges. A worker that dies while it waits leaves a card that never defaults: past its deadline it counts as a Deny, and an Allow on it runs nothing. One killed while it runs reports `unknown`, or nothing: some of it may have happened. The worker's environment is the Herdr server's plus `BERCAIL_ROLE`, `XDG_STATE_HOME`, `BERCAIL_BIN` and `ENTIRE_BIN`, so a push needs the server's SSH agent or credential helper. A dialog from Pi itself, or from another extension, could still hold Shep's turn.

### Where the repo opts in

A repo can let Shep run a cleanup, a trail link or a [trail job's](#trails-as-jobs) merge with no card at all: `shep_may_run = ["cleanup", "trail link", "trail merge"]` in its `.bercail/policy.toml`, or any of the three. The list counts only once you [trust](config.md#git-policy-per-repo) that exact file, or set it under `[policy."<path>"]` in your own config, so you approve it once. In Shep's session, an ask that pins to one of those operations, as a card would, then runs right away when it is the only tool call of its message and its repo reads private by the [reading below](#when-nobody-answers-a-guard-card), with no `merge_reversible` needed: the list is the grant. What runs is the argv a card's worker would run, in its folder (`bercail cleanup <real path>`, `bercail cleanup --gone <path>`, `bercail job merge trail:<n> --change <repo>/<n> --repo <main checkout>`, `entire trail link <P> --branch <b>`), with the program by the real path the guard found it at on `PATH`, put in place of Shep's words, so a program of the same name elsewhere never gets the grant. A relative or empty `PATH` folder, or a relative helper path, goes to a card. Pi's own bash still runs its configured command prefix and `BASH_ENV` first, as for every Shep command. A trail merge counts only as `bercail job merge`, which checks the job and closes it, not a bare `entire trail merge`; a cleanup only when its worktree's `origin` is private on its forge, and a `cleanup --gone` when its handoff's repo's is. Shep's own environment must hold no git variable that points git elsewhere. The command runs with a warning naming the policy, the repo and what ran, in its result and `guard-approvals.jsonl`, and Shep says so in its report. A trail job's merge has no `--force`, so entire checks the trail's gates on the head it merges. Anything else asks as before: a public or unreadable repo, a link with no `--branch`, a push, a deploy, a release, a tag, a force push, a delete, a spend. When a cleanup, a link or a trail job's merge goes to a card anyway, Shep's handoff text, and `guard-warnings.jsonl`, end with `shep_may_run did not apply:` and the reason, such as `it was one of 2 tool calls in its message`. The guard counts a message's calls at its `message_end`, which Pi awaits before it checks any of them; a call checked with none goes to a card.

### When nobody answers a guard card

A card nobody answers by its deadline counts as an Allow when what it runs stays private or local, and as a Deny otherwise (bercail-mdfb; the reasoning is in [plans/guard-default-allow.md](plans/guard-default-allow.md)). The worker reads it from the remote, never from the command's words, with `guardDefault` in guard.ts:

| Operation | Counts as an Allow at the deadline when |
|-----------|------------------------------------------|
| `bercail cleanup <worktree>` | always: it is local, and the branch stays |
| a restack push | never: it replaces the branch's history on the remote |
| a push | the repo's trusted policy says `merge_reversible = true`; the push goes to that repo's own `origin`, one URL it both fetches from and pushes to; Entire's pre-push hook, if on, sends checkpoints nowhere else; and `origin` is a repo on this machine, or private |
| a trail merge or `bercail job merge` | the repo's trusted policy says `merge_reversible = true`, and the change is in that checkout's own private Entire-native repo (`et/<project>/<repo>`) |
| `entire trail link <P> --branch <b> [--base <b>]`, run as `entire` itself | the same, for the checkout's `origin` |
| any other command | never |

Private means an exact `PRIVATE` from `gh repo view github.com/<owner>/<repo> --json visibility,id`, or `"private": true` for the repo asked from `entire repo view <entire:// URL> --json`. `INTERNAL`, any other host, Entire's mirror of a GitHub repo, a read that fails, and an answer in another shape count as public. A GitHub-backed trail waits: who sees its project on entire.com is not read. For an Entire-native trail, the repo's visibility stands for its project's, which entire does not show. What the worker reads names the repo by its forge's ID and URL, and the card keeps it: a later read must give the same words. Today Lesentiel's trail merges and links default (`et/lesentiel/lesentiel` is private, its policy says `merge_reversible = true`); bercail's wait, since `simoncrypta/bercail` is public.

A card that said it waits for you never defaults, nor does one that went up with less than 50 minutes left (it says it waits), or that its worker did not see pending in the 5 minutes before its deadline, or reach within 5 minutes after it (the machine slept): you had no hour to answer, or its reading is stale. The ledger holds the same bounds, 50 minutes before and 10 after. One that said it defaults reads it all again at the deadline: unless it reads the same, with nothing it acts on changed, the card is withdrawn as `expired`, a Deny. Otherwise the ledger records the default, `guard default at expiry`, on a card still pending only, so your pick, made first, stands. The worker reads it once more right before the run, and runs nothing (`expired`) if it changed. A default takes no OK or Reverse, as the [two-way doors'](#reversible-questions) do: it leaves the panel, and its guard event is the record. It covers the operation and the checkpoints Entire pushes beside it, not what a hook or the remote's own automation does next, as with an Allow; and it is once per card, so two asks for the same thing are two cards.

## A desk's guard prompt

A desk's guard asks you before some commands (`Allow this push to origin: main?`). While it asks, Shep can read the prompt with `bercail desk prompt <desk>` and answer it from outside the desk with `bercail desk answer <desk> yes|no --prompt <id>`, never by typing into it ([the files and checks](config.md#a-desks-guard-prompt)):

- **No**, when the desk goes past what its job, your pick or a standing rule allows (a push after you picked "commit locally, no push"). Shep runs `bercail desk answer <desk> no --prompt <id> --reason "<why>"` itself, with a guard warning, and says so in its report. The desk's command is refused with `Answered No from outside the desk (bercail desk answer): <why>`.
- **Yes**, when a standing rule or your pick already allows what it asks: `bercail desk answer <desk> yes --prompt <id>` goes to a [guard card](#guard-asks) that shows the desk's command, and runs only on your Allow there. It never defaults. The desk's command runs with a guard warning that it was answered from outside, logged in `guard-approvals.jsonl`.

The guard refuses `bercail desk answer` from every other role, a desk's own included, and any shape of it but those two (or either with a last `--dry-run`) from Shep. It refuses a tool's write to `desk-prompts/` or `handoffs.jsonl` too. Like the rest of the guard, this is a seatbelt, not a sandbox: a program an agent runs can still write those files. An answer names the prompt's id, so it answers that prompt only: a desk that asks the same command again asks with a new id. The desk takes an answer once, writes its receipt, then closes its dialog; you answering at the desk first settles it, and an answer written after is taken back.

A desk asks nothing to push its own branch to `origin`: the branch its [handoff record](handoff.md) names, from its worktree, when that is not `main`, `master` or the default branch origin's server names (read with `git ls-remote --symref origin HEAD` on each push; when it cannot be read, it asks). Every refspec must send that branch to itself: `feature`, `refs/heads/feature`, `HEAD` on it, or with a `:<dst>` in full (`HEAD:refs/heads/feature`), since git resolves a short `:<dst>` against the remote's refs, a tag of that name included. No flag but `-u`, `-q`, `-v`, `-n` or `--porcelain`, and no global option such as `-C` or `-c`. The push must be the whole command and the only tool call of its message, origin must push to its one fetch URL, and the branch's name must resolve to the branch (`git rev-parse --symbolic-full-name`), not a tag. Where `push.default` is `upstream` or a `remote.origin.push` maps refs, each refspec must name its `:<dst>`. Where `push.followTags`, `push.recurseSubmodules`, `submodule.recurse` or `remote.origin.mirror` could make a push send more, it asks. Anything else, a bare `git push` included, follows the repo's push policy as before, as does a builder or other sibling in the same worktree.

## Landing a change

### One land card

In a repo whose trusted policy says `push = "main"`, `integrate = "direct"` and names the workflows that must pass in `required_ci` ([config](config.md)), on git backend `gh`, one pick lands a desk's change. Once the desk finished and its description checks out, Shep runs `bercail land ask <worktree>`. It refuses, with the fix, the main checkout or the trunk itself, a repo without that profile, a worktree with no beads issue in its handoff record, a merge of anything but the trunk's tip on origin or one with conflicts left, a description that does not check out, a HEAD that is not the trunk's commit on origin, and a second card for the same worktree, branch or job while one waits or lands. A desk that merged the trunk's tip into its branch gets its HEAD put on that tip with the merged tree still staged, so the merge's exact tree lands as one commit: the trunk takes no merge commit. Otherwise it puts up a land card through the question ledger, which pins the facts below (the ledger itself refuses a profile or a HEAD that do not fit), and prints one line for Shep.

The card pins the linked worktree, its branch and HEAD, the staged tree with nothing unstaged or untracked, the description's tree and the hash of its commit text, the trunk and its commit on origin, origin's one push URL and the GitHub repo it names, the policy with its trust and a hash of its values, each `required_ci` workflow's GitHub ID, the installed `bercail` by its real path, whether review is required and the reviewer, the job and its desk, space and session, and a new branch of its own for CI, `bercail-land/<branch>/<id>`. Its brief writes out each effect with its target. Its choices are **Ship it** and **Not yet** (**LGTM, ship it** when review is required). It has no recommendation, no default and no expiry, and takes a pick only on the panel, never in Discuss.

**Ship it** starts a model-free worker, `bercail land run <Qn@rev>`, in the hc terminal `land-<qn>-<rev>`; nothing else runs it, and the guard refuses it from every agent. It claims the pick once, then runs each effect in order; up to the cleanup, every pinned fact is read again before each one:

1. **commit**: the staged tree with the description's text, as `git commit --cleanup=verbatim`. The commit is read back: another tree, parent or text (a hook changed it) stops at `unknown` with nothing pushed.
2. **push**: that commit to its CI branch, a new branch on origin, so a retry after a stop never needs a force push.
3. **ci**: every 30 seconds for up to two hours, until each `required_ci` workflow's latest push run on that branch and commit has passed. A red, skipped or neutral run stops at `ci-failed`; no complete result in time, or a run list as long as its limit, stops at `ci-timeout`.
4. **trunk**: under a per-repo lock, with the trunk on origin still the pinned commit and CI still green on a second read, the same commit to the trunk with no force. A trunk that moved stops at `behind`.
5. **cleanup**: `bercail cleanup` of the worktree, while it is still on its branch at that commit with its desk.
6. **sync**: `git merge --ff-only` of the main checkout to that commit, when it is on the trunk, clean and behind it.
7. **close**: `bd close` of the job, naming the commit, only when the cleanup and the sync held.

A change that edits the repo's `.bercail/policy.toml` is one the person approves with the policy: the card pins the staged file's sha256 and shows it with the policy diff. Once that commit is on the trunk, after the sync, the worker trusts exactly that hash for the repo, as `bercail policy trust` would, and the landed result and event say so. A policy edited after the pick stops the chain at `changed`; a landed file of any other hash is not trusted, and the result says why. The card's profile and its pushes follow the repo's policy as the main checkout has it, never a desk's edit to it: the pushes run from the main checkout, which shares the worktree's objects.

Before each push the worker asks the guard's own decision and pinning (`bercail guard decide`): it must say allow, with the card's URL and refspec, and for the cleanup the ask the card named. Any other answer stops the chain at `refused`. A cleanup, sync or close that does not hold is a warning on `landed`, that part is left as it was, and the job stays open for Shep to finish. A chain that stops before the trunk push never retries or replays a step; the job stays open, and Shep asks a new card once the desk is ready. Each effect's output goes to `~/.local/state/bercail/land/<Qn>-<rev>.log` (mode 600).

The card shows how far the chain got until it ends, and Shep gets one `bercail.land/v2` event: the outcome (`landed`, `changed`, `refused`, `ci-failed`, `ci-timeout`, `behind`, `push-failed` or `unknown`), its last step, the commit, why it stopped, any warnings and the log. Shep's line is written from those fields only. **Not yet** is a decision event, as any pick is. `bercail shep question expire`, on Shep's timer, starts a worker again for a pick whose worker never started or died before its claim, records `unknown` for a claimed worker that is gone (never while hc cannot answer), and writes an event the worker could not.

### Today's flow

Every other repo lands this way. After review and your request to ship, Shep runs `bercail land <worktree>` with `--reviewed-by "<name>"` when your LGTM is required. Only Shep can run it, on a branch other than trunk, with a valid `/validate` description, and, where the policy says `integrate = "direct"`, not once the trunk moved past HEAD: when origin's trunk as last fetched, or the local one, has commits that neither HEAD nor a merge under way is on, it refuses before it commits, with the line for the desk to bring its change onto the new base and rerun `/validate`. The trunk takes no merge commit, so a commit on the old base could not land as it is. A PR branch only gets the warning: the PR's merge on the forge checks it against the trunk, and bringing the branch onto the trunk each time it moves would mean a force push or a merge. It commits the staged tree with the `bercail describe commit` text, then starts a waiter and returns. In a repo whose git backend is `entire` it starts no waiter: that repo's CI is its trail's gates, which `gh run list` never sees, so Shep pushes the branch, links it to the trail and reads the gates with `entire trail show <n>` ([trails as jobs](#trails-as-jobs)). Rerunning with the described tree already at HEAD makes no second commit. **Land does not push.** Shep uses the push command land prints. For a direct land in bercail's own GitHub repo it pins the commit to `refs/heads/bercail-land/<branch>/<sha>` rather than pushing the work branch. That ref requests the [full CI run](development.md#ci).

The hc terminal `land-<12-character sha>` (`bercail.land=wait`, `bercail.land_head=<sha>`) runs `bercail land --wait <sha> <worktree>` (with `--full <work-branch>` for bercail's direct land). Every 30 seconds for up to two hours it checks `gh run list --commit <sha> --branch <branch> --event push`. For bercail's own direct land, it checks the dedicated ref and requires `.github/workflows/ci.yml` to succeed there. A green work branch or an unrelated green workflow is insufficient. In other repos the legacy waiter still checks push runs on the named work branch without selecting a required workflow.

From the waiter Shep gets one `bercail.land/v1` inbox event (`kind: land`), with the status, commit, branch and runs. Its text comes from those facts, not desk prose; the issue comes from the checkout's handoff record.

- `ready`: all returned runs finished, at least one succeeded and none failed. Shep lands **that SHA**, not the branch tip: `git push origin <sha>:<trunk>` for direct integration, or the PR or trail the policy requires. The guard enforces policy, not CI freshness.
- `failed`: a run failed or finished with a conclusion other than success, skipped or neutral, or every run was skipped or neutral. Report the runs; do not land.
- `moved`: CI passed but the branch moved. The new head needs review and its own land.
- `timeout`: no result in time. Report whether no push run was found or a run was still going; do not land.

The guard refuses `bercail land run` and the question ledger's `land-create`, `land-claim`, `land-step`, `land-result` and `land-tell` for every agent, Shep included: only `bercail land ask` puts up a land card, and only the person's pick starts its chain.

## Desk events

Once Shep has started once (making `~/.local/state/bercail/shep/inbox/`), the follower writes each finished or blocked desk as one file there: the [`agent_status/v2` payload](#the-payload) with `sink: "shep"`, mode 600, named `<desk>_<kind>_<second>.<seq>.json` (no `.<seq>` without a sequence number).

A desk blocked on a prompt is named by its screen instead: `<desk>_blocked_<session>.<screen hash>.json`, with the Pi session the desk record names for hc's pid, else the pid. When a new block arrives, in a status event or a snapshot, the follower asks hc once. Unless hc still says blocked, it sends nothing, and the desk keeps its earlier status and its row in `source-state.json`, so a blocked flicker during a working turn reaches Shep neither as an event nor as a reconstructed notice. A provider error's episode is still sent. An unchanged screen in one session, across flickers or a follower restart, is one file, delivered once. A new screen, a new session, or a new pid the desk record does not name is a new event. When hc gives no screen or pid, the block is sent under the usual name. The hash covers the whole screen, not the prompt alone: moving the selection, or resizing, and then a flicker sends the same prompt again.

Shep's `inbox.ts` submits the waiting events as one custom message, each with its `text`, `event_id`, desk, space, repo, issue and checkout, but not the desk's result summary or title. It is a signal to check the desk and issue, never an instruction or an answer. When Shep is idle, a file that lands wakes the inbox, which sends 200 ms later and starts a turn. While Shep's run is going, the inbox still claims each file as it lands but holds the message, and sends everything ready as one message when the run settles (`agent_settled`), desk events first and decisions after. So four picks in twelve seconds while Shep works become one message that starts one turn, not four messages in the middle of other work. A long run delays them until it ends.

The same folder carries decision events, written when you [answer](#answering) a question or a [reversible one](#reversible-questions) defaults (`decision-Q<n>-<rev>.json`), when you say OK to a default or reverse it (`decision-Q<n>-<rev>-ok.json`, `decision-Q<n>-<rev>-reversed.json`), when you request **Ask again** (`decision-Q<n>-<rev>-reask.json`, with the stale reasons, no choice), or when you close [Discuss](#discuss) without a pick (`decision-Q<n>-<rev>-closed-<opening>.json`). The file name follows from the event id (`decision:<name>`), so a retry is the same event. Shep checks each against its question state before acting.

A [routine](routines.md#the-event) run that found something new or changed, or that just paused, writes one `bercail.routine/v1` event there (`routine_<name>_<run id or slot>.json`). Its line names the routine, its counts and the `bercail routine show` command for the run, never what the query found.

### Claims and persistence

Moving a file to `delivered/` claims it; only a complete matching entry in the session's JSONL acknowledges it, recorded as `persisted_entry_id`, `persisted_session`, `persisted_session_file` and `persisted_at`. Pi 1.5.2 returns from `sendMessage()` before the append, so the extension checks disk on later hooks and polls, never trusting memory.

After a crash, the next consumer recovers unacknowledged claims: a saved entry repairs the receipt with no second message; a readable session without it, or one never created, allows a replay; a missing or unreadable session holds the event as uncertain until that session is restored and Shep restarts; a conflicting claim holds it until the conflict is resolved. Neither is bound to a replacement. One consumer holds a `flock` for its session's life, and delivery pauses visibly without it; restart a paused contender once the owner ends. Do not delete the lock file while consumers run.

### Duplicates and limits

One event id gives one message, under any file name, while its receipt is kept: 30 days; uncertain claims never age out. These are process-crash guarantees, not power-loss ones. Persisted does not mean handled or read, and transport deduplication does not make a model report or an outside action exactly once: Shep rechecks state before acting. The follower drops replayed `hc events` by sequence number; without one, a desk's changes of one kind in one second are coalesced.

### Reconciliation after follower gaps

The follower keeps `source-state.json` beside the inbox: current desk mappings with observed times, and no desk prose, results or answers. A desk idle before it has worked (hc's turn 0, never seen working: Pi starting) is left out, since it has no finish to reconstruct. When a done, idle or blocked desk has no notice, Shep gets a **reconstructed, possibly stale history-gap observation** with its own notice id. The follower queues an event before it publishes that state, and Shep reads the state before claiming the inbox, so a change whose matching mapping is still kept in an event or receipt does not also come back reconstructed. That is no guarantee across a gap or past receipt expiry. Check the board or brief before acting on one.

### Proving it arrived

`bercail shep status` lists queued files, claims awaiting persistence (uncertain ones included), persisted notices and quarantined malformed files, the last receipt, and whether the [routine loop](routines.md#the-scheduler) runs and when it last ticked. In the session a notice is a `custom_message` with `customType: "bercail-desk-event"`, which is not Shep's reply or your reading it.

### The follower

`bercail notify run`, the hidden `bercail-notify` terminal the desk mod keeps alive, follows the desk agents (`bercail.role=agent`) with `hc events` and queues two kinds:

- `finished`: working or blocked → done or idle
- `blocked`: once each time the agent blocks

Before Shep's first start it idles, and `bercail update` restarts it on new code. `run` is the only `notify` command: the webhook sinks were removed in v0.18, and `~/.config/bercail/notify.d/` is no longer read.

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

`agent.address` is the hc terminal. `agent.role` is `desk`, or `shep-bg` for a [background Shep](#background-sheps). `desk.issue` and `issue_title` come from the terminal's labels, else the matching `handoffs.jsonl` record, as do `stage` and `harness` (which falls back to `agent.app`); a record for another issue is left out. `desk.result` is from the checkout's `.bercail/handoff-result.json` (`status`, the first 500 characters of `summary`, `session_id`), usually `null`. `text` is one line: `<id>: <title>. Desk <address> (<space name>) finished.` or `is blocked.`, with `Background Shep <address>` for a worker.

**Headless runs send nothing**: they have no terminal to watch. `handoff-spawn` returns when one ends, with the outcome in `.bercail/handoff-result.json`. To wait on a desk yourself, use `hc wait <desk>`.

## Why

Shep's rules follow the [No AI Slop manifesto](https://www.slopmanifesto.com/); [the docs index](README.md) maps each value to what bercail does.
