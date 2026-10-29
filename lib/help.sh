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
  -y, --yes    Non-interactive (existing/default config; desk default is cursor-agent)

Post-install CLI (bercail):
  help          This help
  install       Full install from the release mise or packslip unpacked
  doctor        Check dependencies and integration
  harness       JSON: claude, codex, and cursor-agent on PATH (missing is not fatal)
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
  Left: the desk, one agent per space (claude, codex or grok, picked on the desk)
  Center: the space's tabs (Shell; Review runs \`tuicr -w\`, uncommitted only,
          watching, and opens itself when the desk agent finishes)
  Right: files / changes

Keys in the bercail layout:
  Ctrl+Shift+A       Focus the desk agent (start it if there is none)
  Ctrl+Shift+R       Review
  Ctrl+Shift+S       Shell tab
  Ctrl+Shift+F / G   Show or hide files / changes
  Ctrl+Alt+Arrows    Move between panes (left from the leftmost reaches the desk)
  Ctrl+Shift+Q       Close this space
  Herdr's own keys: Ctrl+Shift+T/W tab, Ctrl+Shift+O/E split, Ctrl+Shift+X close
  pane, Alt+1-9 tabs, Alt+Up/Down spaces, Ctrl+Shift+? all keys

Omarchy / Linux:
  Clears fcitx5 Ctrl+Alt+H/J spell-hint hotkeys when fcitx5 is present
  Optionally patches Hyprland SUPER+ALT+RETURN to open (or focus) the Herdr app

Install order:
  The Herdr app (herdr-app, with herdr-core hc) comes from https://herdr.dev
  mise first (install and upgrade worktrunk, beads (bd), fzf, jq, tuicr)
  PATH: mise shims, then ~/.local/bin, then brew (macOS Homebrew stays reachable)
  then omarchy pkg add on Omarchy, then brew / apt / pacman / upstream

Ubuntu / Debian:
  Uses apt for git, fzf, jq, curl when mise is unavailable
  Downloads worktrunk, beads and tuicr from upstream when needed

Config:
  ~/.config/bercail/config.toml               desk agent default, review
  ~/.config/herdr-app/layouts/bercail.json    the layout
  ~/.config/herdr-app/mods/bercail-desk/      the desk mod
  ~/.config/herdr-app/keys.json               its "layout:bercail" keys
  ~/.config/worktrunk/herdr-layout.sh
  ~/.config/worktrunk/config.toml             worktrunk hooks
  ~/.agents/skills/handoff/                   handoff skill (canonical)
  ~/.agents/skills/review/                    tuicr review skill (wait / optional GH publish)
  ~/.config/fcitx5/conf/keyboard.conf         Linux fcitx5 hint trigger override

Agent skills (\`handoff\`, \`review\`):
  Installed to ~/.agents/skills/<id> (https://agentskills.io). cursor-agent
  reads that dir. Extra symlink only if you set another [agent] command.
  Source: skills/handoff/, skills/review/.
  Manual: npx skills add simoncrypta/bercail -s handoff -g
  Handoff stages: start is claude, codex is Codex CLI (codex exec --json),
  cursor is cursor-agent (--print --output-format json). Each works a beads
  issue; the prompt is one line pointing at it. Headless runs write
  .bercail/handoff-result.json; --branch starts a desk agent for any stage.
  claude, codex, and cursor-agent are optional and equal; bercail does not
  pick one. Shep owns the workflow. bercail harness reports which are on PATH
  plus a local model hint.
EOF
}

show_summary() {
  log ""
  log "bercail installed (v${AGENTIC_DEV_VERSION})"
  log ""
  log "Agent command: $(read_agent_command 2>/dev/null || echo cursor-agent) (handoff stages: start=claude, codex=Codex CLI, cursor=cursor-agent; equal, no default)"
  log "Review command: $(read_layout_review 2>/dev/null || echo tuicr)"
  log "Config: ${AGENTIC_DEV_USER_CONFIG}"
  log "Skills: ${AGENTS_SKILLS_DIR}/handoff, ${AGENTS_SKILLS_DIR}/review"
  log ""
  log "Try: dev"
  log "Help: bercail help"
  log ""
}
