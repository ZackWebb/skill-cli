#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/skill-cli/config.sh"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Config not found: $CONFIG_FILE"
  echo "Run 'skill ls' first to generate defaults, or create it manually."
  exit 1
fi

source "$CONFIG_FILE"

ENABLED="$SKILLS_DIR"
mkdir -p "$ENABLED"
[[ ! -f "$ACTIVE_FILE" ]] && touch "$ACTIVE_FILE"
ACTIVE=$(cat "$ACTIVE_FILE")

# Build TARGETS array from configured paths. Empty/unset entries are skipped.
TARGETS=()
[[ -n "${CLAUDE_TARGET:-}" ]] && TARGETS+=("$CLAUDE_TARGET")
[[ -n "${CODEX_TARGET:-}" ]]  && TARGETS+=("$CODEX_TARGET")
[[ -n "${COPILOT_PLUGIN:-}" ]] && TARGETS+=("$COPILOT_PLUGIN/skills")

if [[ ${#TARGETS[@]} -eq 0 ]]; then
  echo "No sync targets configured in $CONFIG_FILE. Nothing to do."
  exit 0
fi

# Write Copilot plugin manifest only if COPILOT_PLUGIN is set.
if [[ -n "${COPILOT_PLUGIN:-}" ]]; then
  mkdir -p "$COPILOT_PLUGIN/.claude-plugin"
  cat > "$COPILOT_PLUGIN/.claude-plugin/plugin.json" << 'EOF'
{
  "name": "personal-skills",
  "description": "Personal skills synced from skill pool.",
  "version": "1.0.0",
  "author": { "name": "webbz" },
  "skills": "./skills/"
}
EOF
fi

generate_wrapper() {
  local skill_dir="$1"
  local out_dir="$2"

  # Compute the canonical wrapper location by resolving only the parent dir,
  # never following an existing symlink at out_dir itself (which could point
  # into the source and trigger a false positive on the safety check below).
  local real_out
  real_out=$(python3 -c "import os,sys; p=sys.argv[1]; print(os.path.join(os.path.realpath(os.path.dirname(p)), os.path.basename(p)))" "$out_dir")
  if [[ "$real_out" == "$skill_dir" || "$real_out" == "$skill_dir"/* ]]; then
    echo "  ⚠ skipping wrapper: out_dir resolves into source ($real_out)"
    return 0
  fi

  local skill_md="$skill_dir/SKILL.md"
  [[ ! -f "$skill_md" ]] && return 1

  local name
  name=$(sed -n 's/^name: *//p' "$skill_md" | head -1)
  [[ -z "$name" ]] && name=$(basename "$skill_dir")

  [[ -L "$out_dir" ]] && rm -f "$out_dir"
  mkdir -p "$out_dir"

  local body
  body=$(awk 'BEGIN{n=0} /^---$/{n++; if(n==2){found=1; next}} found{print}' "$skill_md")

  cat > "$out_dir/SKILL.md" << EOF
---
name: $name
description: "Manual only."
---

$body
EOF

  for item in "$skill_dir"/*/; do
    [[ ! -d "$item" ]] && continue
    local item_name
    item_name=$(basename "$item")
    local link="$out_dir/$item_name"
    if [[ -L "$link" && "$(readlink "$link")" == "$item" ]]; then
      continue
    fi
    rm -rf "$link"
    ln -s "$item" "$link"
  done

  for item in "$skill_dir"/*; do
    [[ -d "$item" ]] && continue
    [[ "$(basename "$item")" == "SKILL.md" ]] && continue
    local item_name
    item_name=$(basename "$item")
    local link="$out_dir/$item_name"
    if [[ -L "$link" && "$(readlink "$link")" == "$item" ]]; then
      continue
    fi
    rm -rf "$link"
    ln -s "$item" "$link"
  done
}

echo "=== Skill Sync ==="
echo "Source: $ENABLED"
echo "Targets: ${TARGETS[*]}"
echo ""

for t in "${TARGETS[@]}"; do
  mkdir -p "$t"
done

for target in "${TARGETS[@]}"; do
  for item in "$target"/*; do
    [[ ! -e "$item" && ! -L "$item" ]] && continue
    item_name=$(basename "$item")
    [[ "$item_name" == ".claude" ]] && continue
    [[ "$item_name" == ".system" ]] && continue
    [[ "$item_name" == "hooks" ]] && continue
    if ! echo "$ACTIVE" | grep -qxF -- "$item_name"; then
      rm -rf "$item"
      echo "  removed: $item_name (from $(basename $(dirname "$target")))"
    fi
  done
done

synced=0
while IFS= read -r name; do
  [[ -z "$name" ]] && continue
  skill_link="$ENABLED/$name"
  if [[ ! -d "$skill_link" ]]; then
    echo "  ⚠ not in pool: $name"
    continue
  fi

  real_dir=$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$skill_link")
  if [[ ! -f "$real_dir/SKILL.md" ]]; then
    echo "  skip (no SKILL.md): $name"
    continue
  fi

  for target in "${TARGETS[@]}"; do
    generate_wrapper "$real_dir" "$target/$name"
  done
  echo "  ✓ $name"
  synced=$((synced+1))
done <<< "$ACTIVE"

echo ""
echo "✓ $synced skills synced with neutered descriptions."
