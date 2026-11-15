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
  doctor        Check dependencies and integration (and Entire, run inside a repo that uses it);
                on a client, the Herdr app half and that the backend runs this version
  bstack        bercail's Pi setup: status | setup
  config        A config.toml value as bercail reads it: config get <section> <key>
  desk          Desk agents: restore [--dry-run] (bring back what a reboot took) |
                model DESK PROVIDER/MODEL[:thinking] (switch a live desk's model)
  update        Re-sync configs, Herdr layout and mod, helper, and skills (a client: the
                Herdr layout, mods and keys, and the CLI)
  reconfigure   Refresh skills from config.toml (not a full redeploy)
  dry-run       Show planned actions without changes
  uninstall     Remove marker block and managed files
  notify        Agent status webhooks: status | add NAME | repo add|remove NAME | test NAME | run
  shep          Shep, the orchestrator on Pi: status (queued, awaiting persistence, persisted) | run |
                bg --issue ID [--cwd DIR] (a background Shep waits on the issue's job) |
                discuss TOKEN (a read-only Pi on the question's branch: what Discuss runs) |
                repos [--json] (your known repos) | board (open jobs, what waits on you) |
                brief ISSUE [--repo DIR] [--budget CHARS] (one issue, its desk, its latest report) |
                queue [--repo DIR] [--json] (what waits on your review, against the review budget) |
                remember "RULE" [--scope SCOPE] | list | forget N (Shep's standing rules) |
                mistake KEY "WHAT" [--repo DIR] [--issue ID] | mistake list (the mistakes ledger) |
                diagram [FILE] (a Mermaid diagram without its click and link statements) |
                questions [--json] (pending targeted questions; replies are unverified) |
                question create|revise|reply|answer|withdraw (JSON on stdin) | check TOKEN | thread TOPIC |
                panel (the Decisions panel's JSON) | discuss TOKEN (make or find its branch) | closed TOKEN OPENING
  todo          What only you can do, on your todo list ([todo] backend: basecamp):
                add "TITLE" [--notes TEXT] [--due YYYY-MM-DD] [--issue ID] [--repo DIR] |
                list [--json] | show ID | done ID. Shep adds them; desks propose Todo: "<text>"
  policy        A repo's git policy (.bercail/policy.toml): show [--json] [repo] |
                trust [repo] (its looser values count until the file changes) | untrust [repo]
  describe      A change's description (.bercail/description.md, written by /validate):
                check [--json] (also its size and stakes) | stamp (record the staged tree) |
                template | title | body | commit [--reviewed-by NAME] (the text for git and
                the forge, with its provenance line; refuses a stale one, and a change
                that waits for your review where the repo commits straight to main)
                [--checkpoints BASE] (keep the Entire-Checkpoint trailers of BASE..HEAD
                through a squash or a reworded amend)
  review-pr     Intent and decisions for a whole PR stack: review-pr <PR url-or-branch>
                gathers every PR, with one detached sibling worktree and a Stack tab.
                Cards run in parallel; thin PRs wait. enter: select PR, d: parent diff,
                t: tuicr with [AI Agent] drafts. Then: run | card | ui | select | checkout |
                rereview | open | dir. When done, review-pr close <PR url> removes the
                worktree, the run dir, and the space.
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

bstack (Pi, bring your own Claude / GPT / Grok subscription):
  bercail bstack setup   install Pi and the Claude bridge (models are picked for you)
  bercail bstack status  what is logged in, each model (auto or pinned), each role
  Roles: lead (the bstack agent), build (bstack-builder), judge (bstack-judge);
  council: one read-only reviewer per provider. In Pi: /council, /validate, /handoff,
  /bstack-setup, /how, /why, /unslop, /autopilot (a PR to green; pushes, never
  merges), /pr-review (bercail review-pr's read-only decisions pass).
  Settings: [bstack] in config.toml.
  Pi >=1.5.1 with pi-claude-bridge@0.12.0. Claude uses claude auth login; GPT and
  Grok use /login openai and /login xai in pi. bercail update renders
  ~/.local/share/bercail/pi/ and herdr-core templates, and sets a 40k compaction
  reserve per claude-bridge model in Pi's settings.json, so Pi compacts before
  Claude Code refuses a prompt near the window. Every role loads the
  bridge, the rate-limit fallback, and bercail's guard, which follows each repo's
  trusted git policy (bercail policy show). The guard also blocks op secret reads
  piped into commands or used before an empty-value check, for every role. In a
  repo with [desk_secrets."<repo>"], the lead, builder, autopilot and headless
  runs get an op shim that hands op a service-account token from a 0600 file,
  and the guard keeps that file, the token and the vault's contents off screen.
  Only Shep writes to your todo list (bercail todo add|done, basecamp writes);
  other roles may read it. No role runs basecamp's login, logout or token commands.
  [bstack] fallback sets candidate order: families or Pi model ids
  (default ["claude", "gpt", "grok"]).
  The fallback skips limited models and dead providers (402, no credits), keeps
  the desk's thinking level, and goes back to the desk's model once its limit
  lifts. Safety blocks take precedence over quota hints: the unfinished role
  stays incomplete, with sanitized reason data and no fallback or self-approval.
  Pi's native/provider retries run before final settlement and are not suppressed
  by this extension. The lead starts roles as hc siblings.

Config:
  ~/.config/bercail/config.toml               review, [bstack], [git], [policy."<repo>"]
  ~/.local/state/bercail/policy-trust.json    repos whose git policy you trusted
  ~/.local/state/bercail/guard-approvals.jsonl  what the guard let through, and why
  ~/.local/state/bercail/todos.jsonl          the todos bercail added, and the ones Shep marked done
  ~/.config/herdr-app/layouts/bercail.json    the layout
  ~/.config/herdr-app/mods/bercail-desk/      the desk mod
  ~/.config/herdr-app/mods/bercail-shep/      the Shep view (bercail shep run) and Back to Shep
  ~/.config/herdr-app/keys.json               its "layout:bercail" keys (update keeps yours)
  ~/.config/worktrunk/herdr-layout.sh
  ~/.config/worktrunk/config.toml             worktrunk hooks
  ~/.agents/skills/handoff/                   handoff skill (canonical)
  ~/.agents/skills/review/                    tuicr review skill (wait / optional GH publish)
  ~/.agents/skills/bstack/, council/          bstack playbooks, cross-provider review
  ~/.agents/skills/{how,why,unslop,autopilot}/  explain, history, cleanup, PR to green
  ~/.agents/skills/desk-restore/              put a desk with no record back by hand
  ~/.agents/skills/unit-testing/              F.I.R.S.T. rules for writing and reviewing tests
  ~/.agents/skills/describe/                  the change description standard: PR body or commit message
  ~/.local/state/bercail/desk-sessions/       which session runs in which desk
  ~/.local/share/bercail/pi/                  bstack's Pi profile
  ~/.config/herdr-core/templates/bstack-*.md  bstack roles as hc templates

Agent skills (\`handoff\`, \`review\`, \`bstack\`, \`council\`, \`how\`, \`why\`, \`unslop\`, \`autopilot\`, \`desk-restore\`, \`unit-testing\`, \`describe\`):
  Installed to ~/.agents/skills/<id> (https://agentskills.io), with a link in
  ~/.pi/agent/skills for each. Source: skills/handoff/, skills/review/.
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
  log "bstack: log in to Claude, ChatGPT, or xAI with bercail bstack setup"
  log "Desk agent: pi (handoff stages: bstack, autopilot)"
  log "Review command: $(read_layout_review 2>/dev/null || echo tuicr)"
  log "Config: ${BERCAIL_USER_CONFIG}"
  log "Skills: ${AGENTS_SKILLS_DIR}/{handoff,review,bstack,council,autopilot,how,why,unslop,desk-restore,unit-testing,describe}"
  log ""
  log "Try: dev"
  log "Help: bercail help"
  log ""
}

show_client_summary() {
  log ""
  log "bercail client installed (v${BERCAIL_VERSION})"
  log ""
  log "Backend: $(toml_value "$BERCAIL_USER_CONFIG" herdr backend "" 2>/dev/null || true) ([herdr] backend in ${BERCAIL_USER_CONFIG})"
  log "Herdr app: the bercail layout, its mods and keys in ${HERDR_APP_CONFIG_DIR}"
  log ""
  log "Check: bercail doctor"
  log ""
}
