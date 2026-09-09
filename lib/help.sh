#!/usr/bin/env bash
# shellcheck shell=bash

show_help() {
  cat <<EOF
bercail v${AGENTIC_DEV_VERSION}

Install:
  curl -fsSL https://setup.simoncrypta.dev/install.sh | bash
  curl -fsSL https://setup.simoncrypta.dev/install.sh | bash -s -- --yes

install.sh options:
  -h, --help   Show this help
  -y, --yes    Non-interactive (existing/default config; agent is cursor-agent)

Post-install CLI (bercail):
  help          This help
  doctor        Check dependencies and integration
  update        Re-sync configs, helper, and skill from the install source
  reconfigure   Refresh skills/integrations from config.toml (not a full redeploy)
  dry-run       Show planned actions without changes
  uninstall     Remove marker block and managed files

Shell commands:
  dev           Attach/switch workspace for $PWD and start the configured agent
  wtc [branch]  Create worktree + new Herdr workspace
  wts [branch]  Switch to existing worktree (fzf if no branch)
  wtd [branch]  Remove worktree + close Herdr workspace
  d             Apply layout and start the configured agent (inside Herdr)
  t             Launch herdr

Layout:
  Left 5/12: agent pane (sticky) — command from ~/.config/bercail/config.toml
  Center 5/12: review (`tuicr -r origin/main -w` watching; auto-opens on agent done) or shell tab
  Right 1/6: files / git pane

Herdr keys (prefix = Ctrl-Space):
  prefix+D           Apply layout and start the configured agent
  prefix+1           Focus agent pane (start if the pane is a shell)
  prefix+2/3/4       review / shell / files keys
  Alt+1-9            Focus tab by number (Option+1-9 on macOS)
  Ctrl+Alt+Arrows    Focus panes left/down/up/right (Ctrl+Option on macOS)
  Alt+Left/Right     Previous/next tab (Option on macOS)
  prefix+k           Close file tab
  prefix+x           Close pane (or file tab)
  Alt+Up/Down        Previous/next workspace (Option on macOS)
  prefix+w           Workspace picker
  prefix+shift+k     Close this workspace (not the worktree group)
  prefix+shift+g/c/r Worktree open / open-current / remove
  prefix+q           Reload herdr config
  prefix+shift+q     Detach

Tab switching works without a healthy agent pane. The agent is recreated lazily on
the next tab switch or prefix+1.

Omarchy / Linux:
  Clears fcitx5 Ctrl+Alt+H/J spell-hint hotkeys when fcitx5 is present
  Optionally patches Hyprland SUPER+ALT+RETURN to launch herdr
  Quattro: ~/.config/hypr/bindings.lua with { omarchy = "terminal-herdr" }
  Native Omarchy Herdr is SUPER+CTRL+RETURN; packages via omarchy pkg add

Install order:
  mise first (herdr, worktrunk, fzf, jq, lazygit, tuicr)
  then omarchy pkg add on Omarchy, then brew / apt / pacman / upstream
  layout tools: tuicr (review); sticky agent is cursor-agent; editor follows $EDITOR

Ubuntu / Debian:
  Uses apt for git, fzf, jq, lazygit, curl when mise is unavailable
  Downloads herdr, worktrunk, and tuicr from upstream when needed

Config:
  ~/.config/bercail/config.toml          agent (default cursor-agent), review, editor
  ~/.config/herdr/config.toml            keybindings + plugin actions (Option on macOS)
  ~/.config/herdr/plugins/               layout plugin (managed install)
  ~/.config/worktrunk/herdr-layout.sh
  ~/.config/worktrunk/config.toml        worktrunk hooks
  ~/.agents/skills/handoff/              handoff skill (canonical)
  ~/.agents/skills/review/               tuicr review skill (wait / optional GH publish)
  ~/.config/fcitx5/conf/keyboard.conf    Linux fcitx5 hint trigger override

Agent skills (`handoff`, `review`):
  Installed to ~/.agents/skills/<id> (https://agentskills.io). cursor-agent
  reads that dir. Extra symlink only if you set another [agent] command.
  Source: skills/handoff/, skills/review/.
  Manual: npx skills add simoncrypta/agentic-dev-setup -s handoff -g
  Handoff children: cursor-agent + /poteto-mode. Install pstack in Cursor:
  /add-plugin pstack

Plugin only (see README — review manifest/scripts before install):
  herdr plugin install simoncrypta/agentic-dev-setup/plugins/agentic-layout
  herdr plugin install simoncrypta/agentic-dev-setup/plugins/agentic-layout --ref v0.4.0
  herdr plugin link /path/to/agentic-dev-setup/plugins/agentic-layout
  herdr plugin config-dir agentic-dev.layout
  herdr plugin action invoke agentic-dev.layout.create
EOF
}

show_summary() {
  log ""
  log "bercail installed (v${AGENTIC_DEV_VERSION})"
  log ""
  log "Agent command: $(read_agent_command 2>/dev/null || echo cursor-agent) (handoff children: cursor-agent + pstack)"
  log "Review command: $(read_layout_review 2>/dev/null || echo tuicr)"
  log "Editor command: $(read_layout_editor 2>/dev/null || echo "\$EDITOR")"
  log "Config: ${AGENTIC_DEV_USER_CONFIG}"
  log "Skills: ${AGENTS_SKILLS_DIR}/handoff, ${AGENTS_SKILLS_DIR}/review"
  log ""
  log "Try: dev"
  log "Help: bercail help"
  log ""
}
