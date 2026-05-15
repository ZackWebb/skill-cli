#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/skill-cli/config.sh"

if [[ ! -f "$CONFIG_FILE" ]]; then
  mkdir -p "$(dirname "$CONFIG_FILE")"
  cat > "$CONFIG_FILE" << 'DEFAULTS'
# skill-cli config
# Edit per machine. Leave a target empty/unset to disable it.

SKILLS_DIR="$HOME/.local/skills/enabled"
ACTIVE_FILE="$SKILLS_DIR/.active"

# Sync targets. Comment out or set to "" to disable on this machine.
CLAUDE_TARGET="$HOME/.claude/skills"
# CODEX_TARGET="$HOME/.config/codex/skills"
# COPILOT_PLUGIN="$HOME/.copilot/installed-plugins/local/personal-skills"
DEFAULTS
  echo "Created default config at $CONFIG_FILE — review and edit for this machine."
fi

source "$CONFIG_FILE"
SYNC_SCRIPT="$SCRIPT_DIR/sync-skills.sh"

mkdir -p "$SKILLS_DIR"
[[ ! -f "$ACTIVE_FILE" ]] && touch "$ACTIVE_FILE"

usage() {
  echo "Usage: skill <command> [args]"
  echo ""
  echo "Commands:"
  echo "  ls              Show available skills (● = active)"
  echo "  on <name>       Activate a skill"
  echo "  off <name>      Deactivate a skill"
  echo "  add <path>      Stage a skill into the pool (symlink)"
  echo "  rm <name>       Remove a skill from the pool"
  echo "  sync            Re-run sync without toggling"
}

remove_active_line() {
  local name="$1"
  [[ ! -f "$ACTIVE_FILE" ]] && return 0
  grep -vxF -- "$name" "$ACTIVE_FILE" > "$ACTIVE_FILE.tmp" || true
  mv "$ACTIVE_FILE.tmp" "$ACTIVE_FILE"
}

list_skills() {
  local active
  active=$(cat "$ACTIVE_FILE")
  for link in "$SKILLS_DIR"/*/; do
    [[ ! -d "$link" ]] && continue
    local name
    name=$(basename "$link")
    local marker="  "
    if echo "$active" | grep -qxF -- "$name"; then
      marker="● "
    fi
    local target
    target=$(readlink "${link%/}" 2>/dev/null || echo "(dir)")
    target="${target/#$HOME/~}"
    printf "%s%-28s %s\n" "$marker" "$name" "$target"
  done
}

activate() {
  local name="$1"
  if [[ ! -d "$SKILLS_DIR/$name" ]]; then
    echo "Not in pool: $name"
    echo "Use 'skill add <path>' to stage it first, or 'skill ls' to see available."
    return 1
  fi
  if grep -qxF -- "$name" "$ACTIVE_FILE"; then
    echo "Already active: $name"
    return 0
  fi
  echo "$name" >> "$ACTIVE_FILE"
  echo "Activated: $name"
  "$SYNC_SCRIPT"
}

deactivate() {
  local name="$1"
  if ! grep -qxF -- "$name" "$ACTIVE_FILE"; then
    echo "Not active: $name"
    return 0
  fi
  remove_active_line "$name"
  echo "Deactivated: $name"
  "$SYNC_SCRIPT"
}

add_skill() {
  local path="$1"
  local abs_path
  abs_path=$(cd "$(dirname "$path")" && pwd)/$(basename "$path")

  if [[ ! -f "$abs_path/SKILL.md" ]]; then
    echo "No SKILL.md found at: $abs_path"
    return 1
  fi

  local name
  name=$(basename "$abs_path")
  if [[ -e "$SKILLS_DIR/$name" ]]; then
    echo "Already in pool: $name"
    return 0
  fi

  ln -s "$abs_path" "$SKILLS_DIR/$name"
  echo "Added to pool: $name → $abs_path"
}

remove_skill() {
  local name="$1"
  if [[ ! -e "$SKILLS_DIR/$name" ]]; then
    echo "Not in pool: $name"
    return 1
  fi
  remove_active_line "$name"
  rm -rf "$SKILLS_DIR/$name"
  echo "Removed from pool: $name"
  "$SYNC_SCRIPT"
}

cmd="${1:-}"
shift || true

case "$cmd" in
  ls|list)   list_skills ;;
  on)        [[ -z "${1:-}" ]] && echo "Usage: skill on <name>" && exit 1; activate "$1" ;;
  off)       [[ -z "${1:-}" ]] && echo "Usage: skill off <name>" && exit 1; deactivate "$1" ;;
  add)       [[ -z "${1:-}" ]] && echo "Usage: skill add <path>" && exit 1; add_skill "$1" ;;
  rm|remove) [[ -z "${1:-}" ]] && echo "Usage: skill rm <name>" && exit 1; remove_skill "$1" ;;
  sync)      "$SYNC_SCRIPT" ;;
  *)         usage ;;
esac
