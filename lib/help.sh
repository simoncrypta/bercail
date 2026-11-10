#!/usr/bin/env bash
# shellcheck shell=bash

show_help() {
  cat <<EOF
bercail v${AGENTIC_DEV_VERSION}

Install (recommended: mise + packslip, signed release):
  mise use -g packslip:github.com/simoncrypta/bercail && bercail install
  packslip install github.com/simoncrypta/bercail && bercail install   (no mise)

Install (curl, still supported):
  curl -fsSL https://bercail.dev/install.sh | bash
  curl -fsSL https://bercail.dev/install.sh | bash -s -- --yes

install.sh options:
  -h, --help   Show this help
  -y, --yes    Non-interactive (existing/default config)
  --no-bstack  New install without bstack: the desk default stays cursor-agent
  --bstack     New install with bstack (the default): Pi on the desk

Post-install CLI (bercail):
  help          This help
  install       Full install from the release mise or packslip unpacked
  doctor        Check dependencies and integration
  harness       JSON: claude, codex, cursor-agent, opencode, pi on PATH (missing is not fatal)
  bstack        Pi (opencode only with harness = "opencode"): status | setup | on | off
  desk          Bring back the desk agents a reboot took: desk restore [--dry-run]
  update        Re-sync configs, Herdr layout and mod, helper, and skills
  reconfigure   Refresh skills from config.toml (not a full redeploy)
  dry-run       Show planned actions without changes
  uninstall     Remove marker block and managed files
  notify        Agent status webhooks: status | add NAME | repo add|remove NAME | test NAME | openclaw | run
  review-pr     Intent and decisions for a whole PR stack: review-pr <PR url-or-branch>
                gathers every PR, with one detached sibling worktree and a Stack tab.
                Cards run in parallel; thin PRs wait. enter: select PR, d: parent diff,
                t: tuicr with [AI Agent] drafts. Then: run | card | ui | select | diff | open | dir

Shell commands:
  dev, d        Show the Herdr app space for $PWD and start its desk agent
  wtc [branch]  Create worktree + its Herdr app space
  wts [branch]  Switch to existing worktree (fzf if no branch)
  wtd [branch]  Remove worktree + close its space
  t             Open the Herdr app

Herdr app layout "bercail" (switch with Ctrl+Shift+L):
  Left: the desk, one agent per space (bstack when it is on, else [agent] command)
  Center: the space's tabs (Shell; Review runs \`tuicr -w\`, uncommitted only,
          watching, and opens itself when the desk agent finishes)
  Right: files / changes

Keys in the bercail layout:
  Ctrl+Shift+A         Focus the desk agent (start it if there is none)
  Ctrl+Shift+R         Review
  Ctrl+Shift+S         Shell tab
  Ctrl+Shift+F / G     Show or hide files / changes
  Ctrl+Alt+Left/Right  Move between panes (left from the leftmost reaches the desk)
  Alt+Up/Down          Previous/next space (repos and other spaces, not worktrees)
  Ctrl+Alt+Up/Down     Previous/next worktree space of this repo (main checkout too)
  Alt+Shift+Up/Down    Previous/next agent (desks too)
  Ctrl+Shift+Q         Close this space
  Herdr's own keys: Ctrl+Shift+T/W tab, Ctrl+Shift+O/E split, Ctrl+Shift+X close
  pane, Alt+1-9 tabs, Alt+H/J/K/L panes, Ctrl+Shift+? all keys

Omarchy / Linux:
  Clears fcitx5 Ctrl+Alt+H/J spell-hint hotkeys when fcitx5 is present
  Optionally patches Hyprland SUPER+ALT+RETURN to open (or focus) the Herdr app

Install order:
  The Herdr app (herdr-app, with herdr-core hc): herdr.dev's installer if missing
  mise first (install and upgrade worktrunk, beads (bd), fzf, jq, tuicr)
  PATH: mise shims, then ~/.local/bin, then brew (macOS Homebrew stays reachable)
  then omarchy pkg add on Omarchy, then brew / apt / pacman / upstream

Ubuntu / Debian:
  Uses apt for git, fzf, jq, curl when mise is unavailable
  Downloads worktrunk, beads and tuicr from upstream when needed

bstack (Pi by default, bring your own Claude / GPT / Grok subscription):
  bercail bstack setup   install Pi, connect plans (models are picked for you)
  bercail bstack status  what is connected, each model (auto or pinned), each role
  Roles: lead (the bstack agent), build (bstack-builder), judge (bstack-judge);
  council ([bstack] council = true): one read-only reviewer per provider. In opencode: /council,
  /ready, /handoff, /bstack-setup, /how, /why, /unslop, /autopilot (a PR to green;
  pushes, never merges), /pr-review (bercail review-pr's read-only decisions pass).
  Settings: [bstack] in config.toml.
  Pi is the default (>=1.2, pi-claude-bridge@0.11.0). opencode only with
  harness = "opencode". Claude uses claude auth login; GPT and Grok use /login
  openai and /login xai in pi. bercail update renders ~/.local/share/bercail/pi/
  and herdr-core templates. Every role loads the bridge, the rate-limit fallback,
  and bercail's guard. [bstack] fallback sets candidate order (default
  ["claude", "gpt", "grok"]). The lead starts roles as hc siblings.

Config:
  ~/.config/bercail/config.toml               desk agent default, review, [bstack]
  ~/.config/herdr-app/layouts/bercail.json    the layout
  ~/.config/herdr-app/mods/bercail-desk/      the desk mod
  ~/.config/herdr-app/mods/bercail-shep/      the Shep view (openclaw tui) and Back to Shep
  ~/.config/herdr-app/keys.json               its "layout:bercail" keys (update keeps yours)
  ~/.config/worktrunk/herdr-layout.sh
  ~/.config/worktrunk/config.toml             worktrunk hooks
  ~/.agents/skills/handoff/                   handoff skill (canonical)
  ~/.agents/skills/review/                    tuicr review skill (wait / optional GH publish)
  ~/.agents/skills/bstack/, council/          bstack playbooks, cross-provider review
  ~/.agents/skills/{how,why,unslop,autopilot}/  explain, history, cleanup, PR to green
  ~/.agents/skills/desk-restore/              put a desk with no record back by hand
  ~/.local/state/bercail/desk-sessions/       which session runs in which desk
  ~/.config/opencode/opencode.jsonc           bstack's opencode config (agents/, commands/ beside it)
  ~/.local/share/bercail/pi/                  bstack's Pi profile (default harness)
  ~/.config/herdr-core/templates/bstack-*.md  bstack roles as hc templates (default harness)
  ~/.config/fcitx5/conf/keyboard.conf         Linux fcitx5 hint trigger override

Agent skills (\`handoff\`, \`review\`, \`bstack\`, \`council\`, \`how\`, \`why\`, \`unslop\`, \`autopilot\`, \`desk-restore\`):
  Installed to ~/.agents/skills/<id> (https://agentskills.io). cursor-agent
  reads that dir. Extra symlink only if you set another [agent] command.
  Source: skills/handoff/, skills/review/.
  Manual: npx skills add simoncrypta/bercail -s handoff -g
  Handoff stages: start is claude, codex is Codex CLI (codex exec --json),
  cursor is cursor-agent (--print --output-format json). Each works a beads
  issue; the prompt is one line pointing at it. Headless runs write
  .bercail/handoff-result.json; --branch starts a desk agent for any stage.
  bstack and autopilot run \`pi -p\` headless. harness = "opencode" keeps
  opencode run --agent bstack; --binary opencode runs start (Claude) or codex
  (GPT) through those subscriptions.
  claude, codex, cursor-agent, opencode, and pi are optional; bercail does not
  pick one. Shep owns the workflow. bercail harness reports which are on PATH
  plus a local model hint.
EOF
}

show_summary() {
  local harness=pi stages
  if declare -F bstack_harness >/dev/null && [[ "$(bstack_harness)" == opencode ]]; then
    harness=opencode
  fi
  if [[ "$harness" == opencode ]]; then
    stages="bstack=opencode, autopilot=opencode bstack-autopilot"
  else
    stages="bstack=pi, autopilot=pi (BERCAIL_ROLE=autopilot)"
  fi
  log ""
  log "bercail installed (v${AGENTIC_DEV_VERSION})"
  log ""
  if declare -F bstack_enabled >/dev/null && bstack_enabled; then
    log "bstack: on (${harness}). Connect your Claude, ChatGPT, or X subscription: bercail bstack setup"
  fi
  log "Agent command: $(read_agent_command 2>/dev/null || echo cursor-agent) (handoff stages: start=claude, codex=Codex CLI, cursor=cursor-agent, ${stages}; equal, no default)"
  log "Review command: $(read_layout_review 2>/dev/null || echo tuicr)"
  log "Config: ${AGENTIC_DEV_USER_CONFIG}"
  log "Skills: ${AGENTS_SKILLS_DIR}/{handoff,review,bstack,council,autopilot,how,why,unslop,desk-restore}"
  log ""
  log "Try: dev"
  log "Help: bercail help"
  log ""
}
