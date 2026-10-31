#!/usr/bin/env bash
# shellcheck shell=bash

show_help() {
  cat <<EOF
bercail v${AGENTIC_DEV_VERSION}

Install (recommended: mise + packslip, signed release):
  mise use -g packslip:github.com/simoncrypta/bercail && bercail install
  packslip install github.com/simoncrypta/bercail && bercail install   (no mise)

Install (curl, still supported):
  curl -fsSL https://setup.simoncrypta.dev/install.sh | bash
  curl -fsSL https://setup.simoncrypta.dev/install.sh | bash -s -- --yes

install.sh options:
  -h, --help   Show this help
  -y, --yes    Non-interactive (existing/default config)
  --no-bstack  New install without bstack: the desk default stays cursor-agent
  --bstack     New install with bstack (the default): opencode on the desk

Post-install CLI (bercail):
  help          This help
  install       Full install from the release mise or packslip unpacked
  doctor        Check dependencies and integration
  harness       JSON: claude, codex, cursor-agent, opencode on PATH (missing is not fatal)
  bstack        opencode with your own subscriptions: status | setup | on | off
  update        Re-sync configs, Herdr layout and mod, helper, and skills
  reconfigure   Refresh skills from config.toml (not a full redeploy)
  dry-run       Show planned actions without changes
  uninstall     Remove marker block and managed files
  notify        Agent status webhooks: status | add NAME | test NAME | run

Shell commands:
  dev, d        Show the Herdr app space for $PWD and start its desk agent
  wtc [branch]  Create worktree + its Herdr app space
  wts [branch]  Switch to existing worktree (fzf if no branch)
  wtd [branch]  Remove worktree + close its space
  t             Open the Herdr app

Herdr app layout "bercail" (switch with Ctrl+Shift+L):
  Left: the desk, one agent per space (bstack, claude, codex or grok, picked on the desk)
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

bstack (opencode, bring your own Claude / GPT / Grok subscription):
  bercail bstack setup   install opencode, connect plans (models are picked for you)
  bercail bstack status  what is connected, each model (auto or pinned), each role
  Roles: lead (the bstack agent), build (bstack-builder), judge (bstack-judge);
  council: one read-only reviewer per connected provider. In opencode: /council,
  /ready, /handoff, /bstack-setup, /how, /why, /unslop, /autopilot (a PR to green;
  pushes, never merges). Settings: [bstack] in config.toml.

Config:
  ~/.config/bercail/config.toml               desk agent default, review, [bstack]
  ~/.config/herdr-app/layouts/bercail.json    the layout
  ~/.config/herdr-app/mods/bercail-desk/      the desk mod
  ~/.config/herdr-app/keys.json               its "layout:bercail" keys (update keeps yours)
  ~/.config/worktrunk/herdr-layout.sh
  ~/.config/worktrunk/config.toml             worktrunk hooks
  ~/.agents/skills/handoff/                   handoff skill (canonical)
  ~/.agents/skills/review/                    tuicr review skill (wait / optional GH publish)
  ~/.agents/skills/bstack/, council/          bstack playbooks, cross-provider review
  ~/.agents/skills/{how,why,unslop,autopilot}/  explain, history, cleanup, PR to green
  ~/.config/opencode/opencode.jsonc           bstack's opencode config (agents/, commands/ beside it)
  ~/.config/fcitx5/conf/keyboard.conf         Linux fcitx5 hint trigger override

Agent skills (\`handoff\`, \`review\`, \`bstack\`, \`council\`, \`how\`, \`why\`, \`unslop\`, \`autopilot\`):
  Installed to ~/.agents/skills/<id> (https://agentskills.io). cursor-agent
  reads that dir. Extra symlink only if you set another [agent] command.
  Source: skills/handoff/, skills/review/.
  Manual: npx skills add simoncrypta/bercail -s handoff -g
  Handoff stages: start is claude, codex is Codex CLI (codex exec --json),
  cursor is cursor-agent (--print --output-format json). Each works a beads
  issue; the prompt is one line pointing at it. Headless runs write
  .bercail/handoff-result.json; --branch starts a desk agent for any stage.
  bstack is opencode (opencode run --agent bstack); --binary opencode runs
  start (Claude) or codex (GPT) through your opencode subscriptions.
  claude, codex, cursor-agent, and opencode are optional and equal; bercail does not
  pick one. Shep owns the workflow. bercail harness reports which are on PATH
  plus a local model hint.
EOF
}

show_summary() {
  log ""
  log "bercail installed (v${AGENTIC_DEV_VERSION})"
  log ""
  if declare -F bstack_enabled >/dev/null && bstack_enabled; then
    log "bstack: on (opencode). Connect your Claude/ChatGPT/SuperGrok plans: bercail bstack setup"
  fi
  log "Agent command: $(read_agent_command 2>/dev/null || echo cursor-agent) (handoff stages: start=claude, codex=Codex CLI, cursor=cursor-agent, bstack=opencode, autopilot=opencode bstack-autopilot; equal, no default)"
  log "Review command: $(read_layout_review 2>/dev/null || echo tuicr)"
  log "Config: ${AGENTIC_DEV_USER_CONFIG}"
  log "Skills: ${AGENTS_SKILLS_DIR}/{handoff,review,bstack,council,autopilot,how,why,unslop}"
  log ""
  log "Try: dev"
  log "Help: bercail help"
  log ""
}
