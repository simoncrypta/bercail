#!/usr/bin/env bash
# shellcheck shell=bash

# The commands, once: bercail help shows them in full, and a command bercail
# does not know prints only this.
help_commands() {
  cat <<'EOF'
Post-install CLI (bercail):
  help          This help
  install       Full install from the release mise or packslip unpacked;
                --client MACHINE installs only the Herdr app half, for bercail on MACHINE
  doctor        Check dependencies, integration, leftover scratch, /tmp use, test slots and routines (and Entire, in a repo that uses it);
                on a client, the Herdr app half and that the backend runs this version
  bstack        bercail's Pi setup: status | setup
  scratch       Each agent's TMPDIR (~/.cache/bercail/scratch/<pid>, leased by .<pid>): sweep [--dry-run] [--days N]
                (remove the folders of runs that ended, and your /tmp entries unchanged and unread for N
                days, 2 by default, that nothing holds; each recorded desk's start and end runs it) | run -- CMD | dir PID
  config        A config.toml value as bercail reads it: config get <section> <key> |
                set <section> <key> <value> | unset <section> <key> [--dry-run] (change that key alone, and print the diff)
  desk          Desk agents: restore [--dry-run] (bring back what a reboot took) |
                model DESK PROVIDER/MODEL[:thinking] (switch a live desk's model)
  update        Re-sync configs, Herdr layout and mod, helper, and skills (a client: the
                Herdr layout, mods and keys, and the CLI; from a clone, only a clean
                checkout of the latest release, or BERCAIL_REF=<tag>|HEAD); then names each
                live Pi still running older bercail code, and how to restart it
  reconfigure   Refresh skills from config.toml (not a full redeploy)
  dry-run       Show planned actions without changes
  uninstall     Remove marker block and managed files
  notify        run: the desk follower that feeds Shep's inbox (the desk mod starts it)
  shep          Shep, the orchestrator on Pi: status (queued, awaiting persistence, persisted) | run |
                Each ISSUE or ID below is a beads id, or trail:N in an Entire repo (bercail job).
                bg --issue ID [--cwd DIR] (waits and reports: bash under the guard, no commit, push or edit) |
                task dispatch [--wait-ready] (JSON stdin; a first visible desk, or a follow-up into the original desk's session,
                  shown at its next turn even while it works; a gone owner's checkout gets a new desk, unasked;
                  --wait-ready: return once a new desk's Pi is up, with the message queued) |
                runtime (source/installed fingerprints and actual startup evidence; read-only) |
                discuss TOKEN (a read-only Pi on the question's branch: what Discuss runs) |
                repos [--json] (your known repos) | board (open jobs, what waits on you) |
                brief ISSUE [--repo DIR] [--budget CHARS] (the desk state in that repo, describe check, latest report) |
                queue [--repo DIR] [--json] (bounded status; UNKNOWN is not an empty queue or a dispatch gate) |
                remember "RULE" [--scope SCOPE] | list | forget N (Shep's standing rules) |
                mistake KEY "WHAT" [--group ID] [--repo DIR] [--issue ID] | mistake group ID "NAME" --against process|tool|conduct [KEY...] |
                mistake list [--json] (the mistakes ledger, by group) |
                diagram [FILE] (a Mermaid diagram without its click and link statements) |
                questions [--json [--all]] (pending targeted questions; replies are unverified;
                  --json: the pending cards and the defaults not yet OK'd, and the land cards
                  still landing; --all: the whole ledger) |
                question create|revise|reply|answer|withdraw (JSON on stdin) | get TOKEN (one revision) |
                check TOKEN | thread TOPIC |
                panel (the Decisions panel's JSON) | expire (record due defaults and sweep land
                  chains; Shep's runtime runs it) |
                waiting (the board's Decisions block: the cards and defaults waiting on you) |
                discuss TOKEN (make or find its branch) | closed TOKEN OPENING |
                push-approval DIR REMOTE REFSPEC... (the guard's: spends the answer that approves this push)
  job           A trail job in an Entire repo, trail:N (its trail number) wherever an issue id goes:
                show trail:N [--repo DIR] [--json] (the trail, its changes, and its comments) |
                comment trail:N [--repo DIR] (text on stdin; the comment stays on this machine, where
                desks post their report, since Entire refuses trail comments from an agent) |
                list [--repo DIR] [--json] (the repo's open trails, ready or blocked, with the local job record) |
                id trail:N [--repo DIR] (its Entire id and URL, project-wide: what a question binds to) |
                merge trail:N [--change REPO/N] [--repo DIR] (Shep: merge its open change, then close it
                once no change is open) |
                supersede trail:N --with trail:M|COMMIT [--repo DIR] (close it, with a Superseded by: line)
  todo          What only you can do, on one of your todo lists (targets; Basecamp for now):
                add "TITLE" [--notes TEXT] [--due YYYY-MM-DD] [--issue ID|trail:N] [--repo DIR] [--target NAME] |
                list [--target NAME] [--json] | show ID | done ID. Shep adds them; desks propose Todo: "<text>".
                add goes to --target, else the route of the job's repo, else the default.
                target add NAME URL [--backend NAME] [--create "LIST"] [--json] (reads the list first) |
                target list|show NAME [--json] | target rm NAME |
                route REPO TARGET | route --default TARGET | route --rm REPO|--default
  policy        A repo's git policy (.bercail/policy.toml): show [--json] [repo] |
                trust [repo] (its looser values count until the file changes) | untrust [repo] |
                init --repo DIR --profile guarded|branch-pr|branch-trail --backend gh|entire [--verify NAME] [--write]
                init previews fixed repo-local files; --write creates absent files, never overwrites.
                guarded supports both backends; branch-pr requires gh, branch-trail requires entire.
                Entire Trail workflow is rules text, not a new policy enum or runtime enforcement.
                All profiles require human review and leave releases to the person. No trust or
                backend configuration is changed. verify-NAME is an INCOMPLETE /validate starter.
  describe      A change's description (.bercail/description.md, written by /validate):
                check [--json] (also its size and stakes, and a moved base) | stamp (record
                the staged tree) | template | title | body | commit [--reviewed-by NAME]
                (the text for git and the forge, with its provenance line; refuses a stale
                one, and a change that waits for your review where the repo commits
                straight to main)
                [--checkpoints BASE] (keep the Entire-Checkpoint trailers of BASE..HEAD
                through a squash or a reworded amend)
  land          Shep's landing of a desk's branch: land WORKTREE [--reviewed-by NAME] runs
                describe check, commits the staged tree with its text, and starts a
                background wait for the commit's CI that ends in one land event in Shep's
                inbox (ready, failed, moved or timeout); in an Entire repo no wait, as the
                trail's gates decide. It never pushes; desks are refused, and so, where the
                policy says integrate = "direct", is a trunk that moved past HEAD, before
                any commit (the desk reruns /validate); a PR branch gets a warning.
                land ask WORKTREE puts up one land card where the repo's trusted policy says
                push = "main", integrate = "direct" and names required_ci: the person's pick
                commits, pushes, waits for CI, lands, cleans up, syncs main and closes the job
  guard         The guard's worker for an ask it handed from Shep's session to a Decisions card:
                ask ID (only the guard starts it) | check (a guard card's live check, JSON stdin)
                | decide (its decision on a command as Shep, JSON stdin; the land worker's veto)
  review-pr     Intent and decisions for a whole PR stack: review-pr <PR url-or-branch>
                gathers every PR, with one detached sibling worktree and a Stack tab.
                Cards run in parallel; thin PRs wait. enter: select PR, d: parent diff,
                t: tuicr with [AI Agent] drafts. Then: run | card | ui | select | checkout |
                rereview | open | dir. When done, review-pr close <PR url> removes the
                worktree, the run dir, and the space.
  routine       Your [routine.<name>] queries (docs/routines.md): list [--json] | show <name> [--run <id>] |
                run <name> [--dry-run] (now, under its locks; new findings or a pause send Shep one event;
                --dry-run prints what it found and writes nothing) |
                pause <name> | resume <name> | enable <name> [--at <when>] | disable <name> [--dry-run]
                (declare a built-in in config.toml, or take it out; prints the diff) |
                ask <name> (your request on stdin, to Shep's inbox;
                the Routines panel's Ask Shep) | tick (start each one that is due) |
                loop (a tick a minute; the hidden terminal bercail-routines runs it) | start (that terminal)
  cleanup       Retire a finished worktree: cleanup <worktree> copies its .bercail/ to
                ~/Work/worktree-archives/<repo>/, ends its desk and what it started,
                parents first, removes the worktree, closes its space, and keeps the
                branch. Refuses uncommitted work, commits on neither trunk nor a remote
                branch, submodules, and a terminal at work; stops, with every reason,
                when one starts working, is replaced or joins the space meanwhile.
                --check <worktree> makes the same refusals and changes nothing.
                --gone <path>: a checkout removed some other way; records it retired, as
                cleanup does, so dispatch starts its job a new desk.
EOF
}

show_help() {
  cat <<EOF
bercail v${BERCAIL_VERSION}

Install (recommended: mise + packslip, signed release):
  mise use -g packslip:github.com/simoncrypta/bercail && bercail install
  packslip install github.com/simoncrypta/bercail && bercail install   (no mise)

Install (curl, still supported):
  curl -fsSL https://bercail.dev/install.sh | bash
  curl -fsSL https://bercail.dev/install.sh | bash -s -- --yes
  curl -fsSL https://raw.githubusercontent.com/simoncrypta/bercail/master/install.sh | BERCAIL_REF=master bash
                 (unreleased trunk; BERCAIL_REF takes a tag, branch, or sha, for bercail update too)

install.sh options:
  -h, --help   Show this help
  -y, --yes    Non-interactive (existing/default config)
  --client MACHINE
               Only the Herdr app half (CLI, layout, mods, keys) and [herdr] backend =
               MACHINE, its name in hc machine ls; later updates stay client-only

EOF
  help_commands
  cat <<EOF

Shell commands:
  dev           Show the Herdr app space for $PWD and start its desk agent
  wtc [branch]  Create worktree + its Herdr app space
  wts [branch]  Switch to existing worktree (fzf if no branch)
  wtd [branch]  Remove worktree + close its space

Herdr app layout "bercail" (switch with Ctrl+Shift+L):
  Left: the desk, one Pi agent per space (bstack's lead)
  Center: the space's tabs (Shell; Review runs \`tuicr -w\`, uncommitted only,
          watching, and opens itself when the desk agent finishes)
  Right: files / changes

Keys in the bercail layout:
  Ctrl+Shift+H         Shep view / space view
  Ctrl+Space           Go to a space, tab or agent (Herdr's search)
  Ctrl+Shift+A         Focus the desk agent (start it if there is none)
  Ctrl+Shift+R         Review
  Ctrl+Shift+S         Shell tab
  Ctrl+Shift+F / G     Show or hide files / changes
  Ctrl+Alt+Left/Right  Move between panes (left from the leftmost reaches the desk)
  Alt+Up/Down          Previous/next space (repos and other spaces, not worktrees)
                       (Pi moves restore-queued to Alt+Q and model reorder to
                       Shift+Up/Down: ~/.pi/agent/keybindings.json)
  Ctrl+Alt+Up/Down     Previous/next worktree space of this repo (main checkout too)
  Alt+Shift+Up/Down    Previous/next agent (desks too)
  Ctrl+Shift+Q         Close this space
  From the Shep view, Ctrl+Space through Alt+Shift+Up/Down show the space view
  first, then act there.
  Herdr's own keys: Ctrl+Shift+T/W tab, Ctrl+Shift+O/E split, Ctrl+Shift+X close
  pane, Alt+1-9 tabs, Alt+H/J/K/L panes, Ctrl+Shift+? all keys

Omarchy / Linux:
  Optionally patches Hyprland SUPER+ALT+RETURN to open (or focus) the Herdr app

Install order:
  The Herdr app (herdr-app, with herdr-core hc): herdr.dev's installer if missing
  mise first (install and upgrade worktrunk, beads (bd), fzf, jq, tuicr)
  PATH: mise shims, then ~/.local/bin, then brew (macOS Homebrew stays reachable)
  then omarchy pkg add on Omarchy, then brew / apt / pacman / upstream

Ubuntu / Debian:
  Uses apt for git, fzf, jq, curl when mise is unavailable
  Downloads worktrunk, beads and tuicr from upstream when needed

bstack (Pi, bring your own Claude and ChatGPT subscriptions):
  bercail bstack setup   install Pi and the Claude bridge (models are picked for you)
  bercail bstack status  what is logged in, each model (auto or pinned), each role
  Roles: lead (the bstack agent) and build (bstack-builder) on Claude Opus; judge
  (bstack-judge) and review-pr's reviewer on GPT Astra, which review while the
  lead decides; background Shep and the builder trial (bstack-builder-fable) on
  Claude Fable. In Pi: /validate,
  /handoff, /bstack-setup, /how, /why, /unslop, /autopilot (a PR to green;
  pushes, never merges), /pr-review (bercail review-pr's read-only decisions
  pass), /statechart.
  Settings: [bstack] in config.toml. statechart = true installs tla-ts (npm)
  and the statechart skill: TLA+ models of stateful changes, checked with
  tla-ts and replayed on the real code.
  Pi >=1.5.1 with pi-claude-bridge@0.13.0. Claude uses claude auth login; GPT
  uses /login openai in pi. bercail update renders
  ~/.local/share/bercail/pi/ and herdr-core templates, and sets a 40k compaction
  reserve per claude-bridge model in Pi's settings.json, so Pi compacts before
  Claude Code refuses a prompt near the window. Every role loads the
  bridge, the rate-limit extension, pi-emphasis (status pills and icons in
  replies; PI_EMPHASIS_GUIDANCE=0 drops its prompt rules), and bercail's
  guard, which follows each repo's trusted git policy (bercail policy show).
  A commit runs in every repo with a "bercail guard warning:" line in its result
  (the judge, Discuss and background Shep are refused); a push follows the policy.
  Direct, unquoted sole --help on recognized
  git builtins and gt create/modify/submit/merge is a read, not a write approval. Graphite help
  needs a known, unmodified alias configuration with no override of that command.
  Wrappers, extra arguments and ambiguous forms keep the existing checks (docs/config.md).
  The guard also blocks op secret reads
  piped into commands or used before an empty-value check, for every role. In a
  repo with [desk_secrets."<repo>"], the lead, builder, autopilot and headless
  runs get an op shim that hands op a service-account token from a private file,
  and the guard keeps that file, the token and the vault's contents off screen.
  Only Shep writes to your todo lists (bercail todo add|done, basecamp writes) and
  sets where they go (bercail todo target add|rm, route); other roles may read them.
  No role writes todo.json by hand, or runs basecamp's login, logout or token commands.
  On a rate limit a role pauses until the limit resets, shown as blocked, then
  goes on with the same request on the same model; Esc stops waiting. Two
  switch to Claude Fable instead and go back once their model resets: the judge
  while GPT is limited, and a role on Opus while a limit holds Opus alone. A dead provider (402, no credits) or a missing Claude login stops
  the role with the fix. Safety blocks take precedence over quota hints: the
  unfinished role stays incomplete, with sanitized reason data and no switch or
  self-approval.
  Pi's native/provider retries run before final settlement and are not suppressed
  by this extension. The lead starts roles as hc siblings.

Config:
  ~/.config/bercail/config.toml               review, [bstack], [git], [policy."<repo>"], [tests] slots, [routine.<name>]
  ~/.local/state/bercail/routines/            each routine's state, runs, outputs and locks
  ~/.local/state/bercail/policy-trust.json    repos whose git policy you trusted
  ~/.local/state/bercail/guard-approvals.jsonl  what the guard let through, and why
  ~/.local/state/bercail/guard-warnings.jsonl   what it warned about or refused (bercail doctor counts a week's)
  ~/.local/state/bercail/guard-asks/          Shep's asks it handed to a Decisions card: tickets, start states, run logs
  ~/.config/bercail/todo.json                 todo targets, routes and the default (bercail todo target, route)
  ~/.local/state/bercail/todos.jsonl          the todos bercail added, and the ones Shep marked done
  ~/.config/herdr-app/layouts/bercail.json    the layout
  ~/.config/herdr-app/mods/bercail-desk/      the desk mod
  ~/.config/herdr-app/mods/bercail-shep/      the Shep view (bercail shep run) and Back to Shep
  ~/.config/herdr-app/keys.json               its "layout:bercail" keys, Herdr's defaults and Ctrl+Shift+C/V (update keeps yours)
  ~/.config/worktrunk/herdr-layout.sh
  ~/.config/worktrunk/config.toml             worktrunk hooks
  ~/.agents/skills/handoff/                   handoff skill (canonical)
  ~/.agents/skills/bstack/                    bstack playbooks
  ~/.agents/skills/{how,why,unslop,autopilot}/  explain, history, cleanup, PR to green
  ~/.agents/skills/desk-restore/              put a desk with no record back by hand
  ~/.agents/skills/unit-testing/              F.I.R.S.T. rules for writing and reviewing tests
  ~/.agents/skills/describe/                  the change description standard: PR body or commit message
  ~/.agents/skills/statechart/                TLA+ statecharts with tla-ts ([bstack] statechart = true)
  ~/.local/share/bercail/statechart/          tla-ts, from bercail's lockfile
  ~/.local/share/bercail/statechart.env       where tla-ts is, for the statechart skill
  ~/.local/state/bercail/desk-sessions/       which session runs in which desk
  ~/.cache/bercail/scratch/                   each agent run's TMPDIR, removed when it ends
  ~/.local/share/bercail/pi/                  bstack's Pi profile
  ~/.config/herdr-core/templates/bstack-*.md  bstack roles as hc templates

Agent skills (\`handoff\`, \`bstack\`, \`how\`, \`why\`, \`unslop\`, \`autopilot\`, \`desk-restore\`, \`unit-testing\`, \`describe\`):
  Installed to ~/.agents/skills/<id> (https://agentskills.io), with a link in
  ~/.pi/agent/skills for each. Source: skills/<id>/.
  Manual: npx skills add simoncrypta/bercail -s handoff -g
  Handoff stages: bstack and autopilot, both Pi. Each works a beads issue; the
  prompt is one line pointing at it. Headless runs (\`pi -p\`) write
  .bercail/handoff-result.json; --branch starts a Pi desk instead.
  --model provider/id[:thinking] runs one of them on another Pi model; the
  rest of the lead, and the sibling roles' models, stay. Headless runs require
  Node.js with built-in TypeScript support (22.19+ recommended); the runtime
  and deployed provider-error helper are checked before Pi starts.
EOF
}

show_summary() {
  log ""
  log "bercail installed (v${BERCAIL_VERSION})"
  log ""
  log "bstack: log in to Claude and ChatGPT with bercail bstack setup"
  log "Desk agent: pi (handoff stages: bstack, autopilot)"
  log "Review command: $(read_layout_review 2>/dev/null || echo tuicr)"
  log "Config: ${BERCAIL_USER_CONFIG}"
  log "Skills: ${AGENTS_SKILLS_DIR}/{handoff,bstack,autopilot,how,why,unslop,desk-restore,unit-testing,describe}"
  log ""
  log "Try: dev"
  log "Help: bercail help"
  log ""
}

# $1: installed or updated.
show_client_summary() {
  log ""
  log "bercail client $1 (v${BERCAIL_VERSION})"
  log ""
  log "Backend: $(toml_value "$BERCAIL_USER_CONFIG" herdr backend "" 2>/dev/null || true) ([herdr] backend in ${BERCAIL_USER_CONFIG})"
  log "Herdr app: the bercail layout, its mods and keys in ${HERDR_APP_CONFIG_DIR}"
  log ""
  log "Check: bercail doctor"
  log ""
}
