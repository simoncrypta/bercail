#!/usr/bin/env bash
# shellcheck shell=bash

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
  --no-bstack  New install without bstack: the desk runs plain Pi
  --bstack     New install with bstack (the default): bstack's Pi lead on the desk

Post-install CLI (bercail):
  help          This help
  install       Full install from the release mise or packslip unpacked
  doctor        Check dependencies and integration
  bstack        bercail's Pi setup: status | setup | on | off
  desk          Bring back the desk agents a reboot took: desk restore [--dry-run]
  update        Re-sync configs, Herdr layout and mod, helper, and skills
  reconfigure   Refresh skills from config.toml (not a full redeploy)
  dry-run       Show planned actions without changes
  uninstall     Remove marker block and managed files
  notify        Agent status webhooks: status | add NAME | repo add|remove NAME | test NAME | run
  shep          Shep, the orchestrator on Pi: status | run |
                bg --issue ID [--cwd DIR] (a background Shep waits on the issue's job) |
                repos [--json] (your known repos) | board (open jobs, what waits on you) |
                brief ISSUE [--repo DIR] [--budget CHARS] (one issue, its desk, its latest report) |
                remember "RULE" [--scope SCOPE] | list | forget N (Shep's standing rules)
  policy        A repo's git policy (.bercail/policy.toml): show [--json] [repo] |
                trust [repo] (its looser values count until the file changes) | untrust [repo]
  review-pr     Intent and decisions for a whole PR stack: review-pr <PR url-or-branch>
                gathers every PR, with one detached sibling worktree and a Stack tab.
                Cards run in parallel; thin PRs wait. enter: select PR, d: parent diff,
                t: tuicr with [AI Agent] drafts. Then: run | card | ui | select | diff | open | dir

Shell commands:
  dev           Show the Herdr app space for $PWD and start its desk agent
  wtc [branch]  Create worktree + its Herdr app space
  wts [branch]  Switch to existing worktree (fzf if no branch)
  wtd [branch]  Remove worktree + close its space

Herdr app layout "bercail" (switch with Ctrl+Shift+L):
  Left: the desk, one Pi agent per space (bstack when it is on, else plain pi)
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
  council: one read-only reviewer per provider. In Pi: /council, /ready, /handoff,
  /bstack-setup, /how, /why, /unslop, /autopilot (a PR to green; pushes, never
  merges), /pr-review (bercail review-pr's read-only decisions pass).
  Settings: [bstack] in config.toml.
  Pi >=1.2 with pi-claude-bridge@0.11.0. Claude uses claude auth login; GPT and
  Grok use /login openai and /login xai in pi. bercail update renders
  ~/.local/share/bercail/pi/ and herdr-core templates, and sets a 40k compaction
  reserve per claude-bridge model in Pi's settings.json, so Pi compacts before
  Claude Code refuses a prompt near the window. Every role loads the
  bridge, the rate-limit fallback, and bercail's guard, which follows each repo's
  trusted git policy (bercail policy show). [bstack] fallback sets
  candidate order (default ["claude", "gpt", "grok"]). The lead starts roles as
  hc siblings.

Config:
  ~/.config/bercail/config.toml               review, [bstack], [git], [policy."<repo>"]
  ~/.local/state/bercail/policy-trust.json    repos whose git policy you trusted
  ~/.local/state/bercail/guard-approvals.jsonl  what the guard let through, and why
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
  ~/.local/state/bercail/desk-sessions/       which session runs in which desk
  ~/.local/share/bercail/pi/                  bstack's Pi profile
  ~/.config/herdr-core/templates/bstack-*.md  bstack roles as hc templates

Agent skills (\`handoff\`, \`review\`, \`bstack\`, \`council\`, \`how\`, \`why\`, \`unslop\`, \`autopilot\`, \`desk-restore\`, \`unit-testing\`):
  Installed to ~/.agents/skills/<id> (https://agentskills.io), with a link in
  ~/.pi/agent/skills for each. Source: skills/handoff/, skills/review/.
  Manual: npx skills add simoncrypta/bercail -s handoff -g
  Handoff stages: bstack and autopilot, both Pi. Each works a beads issue; the
  prompt is one line pointing at it. Headless runs (\`pi -p\`) write
  .bercail/handoff-result.json; --branch starts a Pi desk instead.
  --model provider/id[:thinking] runs one of them on another Pi model; the
  rest of the lead, and the sibling roles' models, stay.
EOF
}

show_summary() {
  log ""
  log "bercail installed (v${BERCAIL_VERSION})"
  log ""
  if declare -F bstack_enabled >/dev/null && bstack_enabled; then
    log "bstack: on. Log in to Claude, ChatGPT, or xAI: bercail bstack setup"
  fi
  log "Desk agent: pi (handoff stages: bstack, autopilot)"
  log "Review command: $(read_layout_review 2>/dev/null || echo tuicr)"
  log "Config: ${BERCAIL_USER_CONFIG}"
  log "Skills: ${AGENTS_SKILLS_DIR}/{handoff,review,bstack,council,autopilot,how,why,unslop,desk-restore,unit-testing}"
  log ""
  log "Try: dev"
  log "Help: bercail help"
  log ""
}
