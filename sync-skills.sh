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
source "$SCRIPT_DIR/lib.sh"

ENABLED="$SKILLS_DIR"
mkdir -p "$ENABLED"
skc_migrate

# --- What to sync ----------------------------------------------------------
# No args        → global + every project scope (full reconcile)
# --all          → same as no args
# --target global→ global targets only
# --target PATH  → that project scope only
SCOPE_FILTER=""   # "" = all
while [[ $# -gt 0 ]]; do
  case "$1" in
    --all) SCOPE_FILTER=""; shift ;;
    --target)
      shift
      if [[ $# -eq 0 || "$1" == "." ]]; then
        SCOPE_FILTER="$(skc_canon_scope "$PWD")"
      else
        SCOPE_FILTER="$(skc_canon_scope "$1")"
      fi
      shift || true
      ;;
    *) echo "sync: unknown argument: $1" >&2; exit 1 ;;
  esac
done

want_global=1
[[ -n "$SCOPE_FILTER" && "$SCOPE_FILTER" != "global" ]] && want_global=0

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

# generate_wrapper <skill_dir> <out_dir> <mode>
#   mode: claude-auto      global Claude behavior (force manual unless the
#                          frontmatter name is in MODEL_INVOCABLE, in which case
#                          upstream frontmatter — including its own
#                          disable-model-invocation — passes through verbatim)
#         claude-manual    always force disable-model-invocation: true
#         claude-invocable strip any disable-model-invocation, never add one
#         neutered         Codex/Copilot: name + "Manual only." description
#         verbatim         preserve upstream SKILL.md exactly
generate_wrapper() {
  local skill_dir="$1"
  local out_dir="$2"
  local mode="${3:-neutered}"

  local real_out
  real_out=$(python3 -c "import os,sys; p=sys.argv[1]; print(os.path.join(os.path.realpath(os.path.dirname(p)), os.path.basename(p)))" "$out_dir")
  if [[ "$real_out" == "$skill_dir" || "$real_out" == "$skill_dir"/* ]]; then
    echo "  ⚠ skipping wrapper: out_dir resolves into source ($real_out)"
    return 0
  fi

  local skill_md="$skill_dir/SKILL.md"
  [[ ! -f "$skill_md" ]] && return 1

  local name
  name=$(awk '/^---$/{n++; next} n==1 && sub(/^name: */,""){print; exit} n>=2{exit}' "$skill_md")
  [[ -z "$name" ]] && name=$(basename "$skill_dir")

  [[ -L "$out_dir" ]] && rm -f "$out_dir"
  mkdir -p "$out_dir"

  local has_fm=0
  [[ "$(head -n1 "$skill_md")" == "---" ]] && has_fm=1

  local body
  if [[ "$has_fm" -eq 1 ]]; then
    body=$(awk 'f{print} /^---$/{n++; if(n==2)f=1}' "$skill_md")
  else
    body=$(cat "$skill_md")
  fi

  if [[ "$mode" == "verbatim" ]]; then
    cp "$skill_md" "$out_dir/SKILL.md"
  elif [[ "$mode" == "neutered" ]]; then
    cat > "$out_dir/SKILL.md" << EOF
---
name: $name
description: "Manual only."
---

$body
EOF
  else
    # Decide the invocation policy for Claude-flavored wrappers.
    local force_manual=1 strip_manual=1
    case "$mode" in
      claude-auto)
        for allowed in ${MODEL_INVOCABLE:-}; do
          if [[ "$allowed" == "$name" ]]; then force_manual=0; strip_manual=0; fi
        done
        ;;
      claude-manual)    force_manual=1; strip_manual=1 ;;
      claude-invocable) force_manual=0; strip_manual=1 ;;
      *) echo "  ⚠ unknown wrapper mode: $mode"; return 1 ;;
    esac

    local fm=""
    [[ "$has_fm" -eq 1 ]] && fm=$(awk '/^---$/{n++; next} n==1{print} n>=2{exit}' "$skill_md")
    if [[ "$strip_manual" -eq 1 ]]; then
      fm=$(printf '%s\n' "$fm" | grep -v '^disable-model-invocation:' || true)
    fi
    if ! printf '%s\n' "$fm" | grep -q '^name:'; then
      if [[ -n "$fm" ]]; then
        fm=$(printf 'name: %s\n%s' "$name" "$fm")
      else
        fm="name: $name"
      fi
    fi
    {
      echo "---"
      [[ -n "$fm" ]] && printf '%s\n' "$fm"
      [[ "$force_manual" -eq 1 ]] && echo "disable-model-invocation: true"
      echo "---"
      echo ""
      printf '%s\n' "$body"
    } > "$out_dir/SKILL.md"
  fi

  for item in "$skill_dir"/*/; do
    [[ ! -d "$item" ]] && continue
    local item_name link
    item_name=$(basename "$item")
    link="$out_dir/$item_name"
    if [[ -L "$link" && "$(readlink "$link")" == "$item" ]]; then
      continue
    fi
    rm -rf "$link"
    ln -s "$item" "$link"
  done

  for item in "$skill_dir"/*; do
    [[ -d "$item" ]] && continue
    [[ "$(basename "$item")" == "SKILL.md" ]] && continue
    local item_name link
    item_name=$(basename "$item")
    link="$out_dir/$item_name"
    if [[ -L "$link" && "$(readlink "$link")" == "$item" ]]; then
      continue
    fi
    rm -rf "$link"
    ln -s "$item" "$link"
  done
}

# Resolve a pool name to its real source dir, or empty on failure.
pool_real_dir() {
  local link="$ENABLED/$1"
  [[ -d "$link" ]] || return 0
  python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$link"
}

# --- Global sync (multi-target, historical behavior) ------------------------
sync_global() {
  local -a TARGETS=()
  [[ -n "${CLAUDE_TARGET:-}" ]] && TARGETS+=("$CLAUDE_TARGET")
  [[ -n "${CODEX_TARGET:-}" ]]  && TARGETS+=("$CODEX_TARGET")
  [[ -n "${COPILOT_PLUGIN:-}" ]] && TARGETS+=("$COPILOT_PLUGIN/skills")

  if [[ ${#TARGETS[@]} -eq 0 ]]; then
    echo "  (no global sync targets configured — skipping global)"
    return 0
  fi

  local names
  names=$(skc_expand global | cut -f1)

  local t
  for t in "${TARGETS[@]}"; do
    mkdir -p "$t"
  done

  # Prune target dirs no longer in the global set.
  local target item item_name
  for target in "${TARGETS[@]}"; do
    for item in "$target"/*; do
      [[ ! -e "$item" && ! -L "$item" ]] && continue
      item_name=$(basename "$item")
      [[ "$item_name" == ".claude" ]] && continue
      [[ "$item_name" == ".system" ]] && continue
      [[ "$item_name" == "hooks" ]] && continue
      if ! grep -qxF -- "$item_name" <<< "$names"; then
        rm -rf "$item"
        echo "  removed: $item_name (from $(basename $(dirname "$target")))"
      fi
    done
  done

  local synced=0 name real_dir mode
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    real_dir=$(pool_real_dir "$name")
    if [[ -z "$real_dir" ]]; then
      echo "  ⚠ not in pool: $name"
      continue
    fi
    if [[ ! -f "$real_dir/SKILL.md" ]]; then
      echo "  skip (no SKILL.md): $name"
      continue
    fi
    for target in "${TARGETS[@]}"; do
      mode="neutered"
      [[ -n "${CLAUDE_TARGET:-}" && "$target" == "$CLAUDE_TARGET" ]] && mode="claude-auto"
      if [[ -n "${CODEX_TARGET:-}" && "$target" == "$CODEX_TARGET" ]]; then
        for allowed in ${MODEL_INVOCABLE:-}; do
          [[ "$allowed" == "$name" ]] && mode="verbatim"
        done
      fi
      generate_wrapper "$real_dir" "$target/$name" "$mode"
    done
    echo "  ✓ $name"
    synced=$((synced + 1))
  done <<< "$names"
  echo "  → global: $synced skill(s)"
}

# --- Project scope sync (Claude + Codex, symlink-inherit + policy) -----------
sync_project_scope() {
  local scope="$1"

  # Resolve entries into parallel name/policy arrays.
  local -a names=() pols=()
  local name pol
  while IFS=$'\t' read -r name pol; do
    [[ -z "$name" ]] && continue
    names+=("$name")
    pols+=("$pol")
  done < <(skc_expand "$scope")

  local new_set=""
  local n
  for n in "${names[@]:-}"; do
    [[ -z "$n" ]] && continue
    new_set+="$n"$'\n'
  done

  local dir manifest harness old i managed real_dir out mode
  for harness in claude agents; do
    dir="$scope/.$harness/skills"
    manifest="$dir/.skill-cli-manifest"
    mkdir -p "$dir"

    # Only prune entries recorded in our manifest; hand-added skills survive.
    if [[ -f "$manifest" ]]; then
      while IFS= read -r old; do
        [[ -z "$old" || "$old" == \#* ]] && continue
        if ! grep -qxF -- "$old" <<< "$new_set"; then
          rm -rf "$dir/$old"
          echo "  removed: $old (from .$harness/skills)"
        fi
      done < "$manifest"
    fi

    managed=""
    for ((i = 0; i < ${#names[@]}; i++)); do
      name="${names[$i]}"
      pol="${pols[$i]}"
      real_dir=$(pool_real_dir "$name")
      [[ -z "$real_dir" ]] && { echo "  ⚠ not in pool: $name"; continue; }
      [[ ! -f "$real_dir/SKILL.md" ]] && { echo "  skip (no SKILL.md): $name"; continue; }
      out="$dir/$name"
      rm -rf "$out"
      if [[ "$harness" == "agents" ]]; then
        case "$pol" in
          manual) generate_wrapper "$real_dir" "$out" neutered ;;
          *)      ln -s "$real_dir" "$out" ;;
        esac
      else
        case "$pol" in
          inherit)   ln -s "$real_dir" "$out" ;;
          manual)    generate_wrapper "$real_dir" "$out" claude-manual ;;
          invocable) generate_wrapper "$real_dir" "$out" claude-invocable ;;
          *)         ln -s "$real_dir" "$out" ;;
        esac
      fi
      managed+="$name"$'\n'
      echo "  ✓ $name [$pol] → .$harness/skills"
    done

    {
      echo "# skill-cli managed skills for this scope — do not edit"
      printf '%s' "$managed"
    } > "$manifest"
  done
  echo "  → $(skc_scope_label "$scope"): ${#names[@]} skill(s)"
}

echo "=== Skill Sync ==="
echo "Pool: $ENABLED"

if [[ "$want_global" -eq 1 ]]; then
  echo ""
  echo "[global]"
  sync_global
fi

# Project scopes: all, or just the filtered one.
if [[ -z "$SCOPE_FILTER" ]]; then
  while IFS= read -r scope; do
    [[ -z "$scope" ]] && continue
    echo ""
    echo "[$(skc_scope_label "$scope")]"
    sync_project_scope "$scope"
  done < <(skc_project_scopes)
elif [[ "$SCOPE_FILTER" != "global" ]]; then
  echo ""
  echo "[$(skc_scope_label "$SCOPE_FILTER")]"
  sync_project_scope "$SCOPE_FILTER"
fi

echo ""
echo "✓ sync complete."
