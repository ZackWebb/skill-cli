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

# Skills allowed to keep upstream model-invocability (space-separated names).
# Everything else gets disable-model-invocation: true forced on Claude sync.
MODEL_INVOCABLE=""

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
  echo "  invocable       List skills allowed to keep upstream model-invocability"
  echo "  invocable <name> on|off"
  echo "                  Toggle a skill on the Claude-sync allowlist (MODEL_INVOCABLE)"
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
  for entry in "$SKILLS_DIR"/*; do
    [[ ! -d "$entry" && ! -L "$entry" ]] && continue
    local name
    name=$(basename "$entry")
    local marker="  "
    if echo "$active" | grep -qxF -- "$name"; then
      marker="● "
    fi
    local target
    target=$(readlink "$entry" 2>/dev/null || echo "(dir)")
    target="${target/#$HOME/~}"
    [[ -e "$entry" ]] || target="$target  (BROKEN)"
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
  if [[ -e "$SKILLS_DIR/$name" || -L "$SKILLS_DIR/$name" ]]; then
    local current
    current=$(readlink "$SKILLS_DIR/$name" 2>/dev/null || echo "$SKILLS_DIR/$name")
    if [[ "$current" == "$abs_path" ]]; then
      echo "Already in pool: $name"
      return 0
    fi
    echo "Already in pool under a different path: $name"
    echo "  current: $current"
    echo "  new:     $abs_path"
    echo "Repoint it with: skill rm $name && skill add $abs_path"
    return 1
  fi

  ln -s "$abs_path" "$SKILLS_DIR/$name"
  echo "Added to pool: $name → $abs_path"
}

remove_skill() {
  local name="$1"
  if [[ ! -e "$SKILLS_DIR/$name" && ! -L "$SKILLS_DIR/$name" ]]; then
    echo "Not in pool: $name"
    return 1
  fi
  remove_active_line "$name"
  rm -rf "$SKILLS_DIR/$name"
  echo "Removed from pool: $name"
  "$SYNC_SCRIPT"
}

# The allowlist matches on the frontmatter `name` (sync-skills.sh compares
# against it), which can differ from the pool directory name.
resolve_skill_name() {
  local pool_name="$1"
  local skill_md="$SKILLS_DIR/$pool_name/SKILL.md"
  local fm_name=""
  if [[ -f "$skill_md" ]]; then
    fm_name=$(awk '/^---$/{n++; next} n==1 && sub(/^name: */,""){print; exit} n>=2{exit}' "$skill_md")
  fi
  echo "${fm_name:-$pool_name}"
}

write_model_invocable() {
  local newval="$1"
  if grep -q '^MODEL_INVOCABLE=' "$CONFIG_FILE"; then
    awk -v val="$newval" '/^MODEL_INVOCABLE=/{print "MODEL_INVOCABLE=\"" val "\""; next} {print}' \
      "$CONFIG_FILE" > "$CONFIG_FILE.tmp"
    mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
  else
    {
      echo ""
      echo "# Skills allowed to keep upstream model-invocability (space-separated names)."
      echo "# Everything else gets disable-model-invocation: true forced on Claude sync."
      echo "MODEL_INVOCABLE=\"$newval\""
    } >> "$CONFIG_FILE"
  fi
}

invocable_list() {
  if [[ -z "${MODEL_INVOCABLE:-}" ]]; then
    echo "Allowlist empty — every synced skill is manual-only (disable-model-invocation: true)."
    return 0
  fi
  local n
  for n in ${MODEL_INVOCABLE}; do
    echo "$n"
  done
}

invocable_on() {
  local pool_name="$1"
  if [[ ! -d "$SKILLS_DIR/$pool_name" ]]; then
    echo "Not in pool: $pool_name"
    echo "Use 'skill add <path>' to stage it first, or 'skill ls' to see available."
    return 1
  fi
  local name n
  name=$(resolve_skill_name "$pool_name")
  for n in ${MODEL_INVOCABLE:-}; do
    if [[ "$n" == "$name" ]]; then
      echo "Already model-invocable: $name"
      return 0
    fi
  done
  # Two gates: the allowlist passes upstream frontmatter through verbatim, so a
  # skill that sets disable-model-invocation: true itself stays manual-only.
  if awk '/^---$/{n++; next} n==1{print} n>=2{exit}' "$SKILLS_DIR/$pool_name/SKILL.md" 2>/dev/null \
      | grep -q '^disable-model-invocation:[[:space:]]*true'; then
    echo "Note: $name sets disable-model-invocation: true upstream — allowlisting keeps it manual-only until upstream changes."
  fi
  if ! grep -qxF -- "$pool_name" "$ACTIVE_FILE"; then
    echo "Note: $pool_name is not active — 'skill on $pool_name' before it syncs anywhere."
  fi
  write_model_invocable "${MODEL_INVOCABLE:+$MODEL_INVOCABLE }$name"
  echo "Model-invocable: $name"
  "$SYNC_SCRIPT"
}

invocable_off() {
  local pool_name="$1"
  local name="$pool_name"
  if [[ -d "$SKILLS_DIR/$pool_name" ]]; then
    name=$(resolve_skill_name "$pool_name")
  fi
  local newval="" found=0 n
  for n in ${MODEL_INVOCABLE:-}; do
    if [[ "$n" == "$name" || "$n" == "$pool_name" ]]; then
      found=1
    else
      newval="${newval:+$newval }$n"
    fi
  done
  if [[ "$found" -eq 0 ]]; then
    echo "Not in allowlist: $name"
    return 0
  fi
  write_model_invocable "$newval"
  echo "Manual-only: $name"
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
  invocable)
    if [[ -z "${1:-}" ]]; then
      invocable_list
    elif [[ "${2:-}" == "on" ]]; then
      invocable_on "$1"
    elif [[ "${2:-}" == "off" ]]; then
      invocable_off "$1"
    else
      echo "Usage: skill invocable [<name> on|off]"
      exit 1
    fi
    ;;
  *)         usage ;;
esac
