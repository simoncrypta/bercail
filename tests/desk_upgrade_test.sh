#!/usr/bin/env bash
# The previous updater reloads config.sh, then calls its new finalizer. Its
# already-running body still has the old library, binary and skill lists.
set -euo pipefail

unset BASH_ENV
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
export HOME="$TMP_DIR/home" XDG_CONFIG_HOME="$TMP_DIR/home/.config"
export INSTALL_SRC="$ROOT"
mkdir -p "$HOME"

source "$ROOT/lib/common.sh"
source "$ROOT/lib/detect.sh"
source "$ROOT/lib/config.sh"
source "$ROOT/lib/skills.sh"
DRY_RUN=0
YES=1

# Values/functions retained by the old process. No desktop or real user manager.
AGENTIC_DEV_SKILL_IDS=(handoff review bstack council autopilot how why unslop)
unset OMARCHY_POST_BOOT_HOOK
is_omarchy() { return 1; }
systemctl() { return 1; }
legacy_update() {
  local name
  for name in bercail agentic-dev bercail-desk-agent; do
    deploy_install_file "bin/$name" "$LOCAL_BIN/$name"
  done
  # The old remote library list doesn't include desk.sh.
  deploy_install_file lib/config.sh "$AGENTIC_DEV_SHARE_DIR/lib/config.sh"
  source "$AGENTIC_DEV_SHARE_DIR/lib/config.sh"
  deploy_finalize_permissions
}

legacy_update >"$TMP_DIR/update.log"
[[ -f "$AGENTIC_DEV_SHARE_DIR/lib/desk.sh" ]] || { cat "$TMP_DIR/update.log"; exit 1; }
[[ -f "$AGENTIC_DEV_SHARE_DIR/pi-extensions/bercail-desk.ts" ]] || { cat "$TMP_DIR/update.log"; exit 1; }
[[ -f "$AGENTS_SKILLS_DIR/desk-restore/SKILL.md" ]] || exit 1
[[ -L "$HOME/.pi/agent/skills/desk-restore" ]] || { cat "$TMP_DIR/update.log"; exit 1; }
printf 'PASS: the previous updater installs desk restore and the pi skill link on the first update\n'
