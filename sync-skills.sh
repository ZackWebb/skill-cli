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

# Entries recorded in a manifest, comments and blanks stripped.
manifest_entries() {
  [[ -f "$1" ]] || return 0
  grep -v -e '^#' -e '^$' -- "$1" || true
}

# Tear down targets that the last sync wrote to but the config no longer names.
#
# Only manifest-recorded entries are removed, so a directory we never wrote to
# is left completely alone: no manifest means not ours. That is what keeps a
# typo'd or newly-unset target var from destroying a real skills directory, and
# what keeps us off a shared ~/.agents/skills another tool owns.
teardown_stale_targets() {
  [[ -f "$TARGETS_FILE" ]] || return 0
  local current old manifest entry root
  current=$(printf '%s\n' "$@")
  while IFS= read -r old; do
    [[ -z "$old" || "$old" == \#* ]] && continue
    grep -qxF -- "$old" <<< "$current" && continue
    manifest="$old/.skill-cli-manifest"
    [[ -f "$manifest" ]] || continue
    while IFS= read -r entry; do
      rm -rf "$old/$entry"
      echo "  removed: $entry (from ${old/#$HOME/~} — target disabled)"
    done < <(manifest_entries "$manifest")
    rm -f "$manifest"
    rmdir "$old" 2>/dev/null || true
    # A Copilot skills dir sits inside a plugin root. Once the skills dir is
    # gone, drop the plugin registration too, so Copilot stops loading an empty
    # plugin. If hand-added skills kept the dir alive, leave it registered.
    root=$(dirname "$old")
    if [[ ! -d "$old" && -f "$root/.claude-plugin/plugin.json" ]]; then
      rm -f "$root/.claude-plugin/plugin.json"
      rmdir "$root/.claude-plugin" 2>/dev/null || true
      rmdir "$root" 2>/dev/null || true
      echo "  removed: plugin manifest (${root/#$HOME/~} — target disabled)"
    fi
  done < "$TARGETS_FILE"
}

# --- Global sync (multi-target, historical behavior) ------------------------
sync_global() {
  local -a TARGETS=()
  [[ -n "${CLAUDE_TARGET:-}" ]] && TARGETS+=("$CLAUDE_TARGET")
  [[ -n "${CODEX_TARGET:-}" ]]  && TARGETS+=("$CODEX_TARGET")
  [[ -n "${COPILOT_PLUGIN:-}" ]] && TARGETS+=("$COPILOT_PLUGIN/skills")

  # Runs before the no-targets bail: disabling every target must still clean up.
  teardown_stale_targets "${TARGETS[@]:-}"
  mkdir -p "$SKC_CONFIG_DIR"
  printf '%s\n' "${TARGETS[@]:-}" | grep -v '^$' > "$TARGETS_FILE" || true

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

  # Prune only what we recorded as ours. A target with no manifest yet has
  # nothing to prune — the manifest written below picks it up from here on.
  local target item_name
  for target in "${TARGETS[@]}"; do
    while IFS= read -r item_name; do
      if ! grep -qxF -- "$item_name" <<< "$names"; then
        rm -rf "$target/$item_name"
        echo "  removed: $item_name (from $(basename $(dirname "$target")))"
      fi
    done < <(manifest_entries "$target/.skill-cli-manifest")
  done

  local synced=0 name real_dir mode managed=""
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
    managed+="$name"$'\n'
    echo "  ✓ $name"
    synced=$((synced + 1))
  done <<< "$names"

  for target in "${TARGETS[@]}"; do
    {
      echo "# skill-cli managed skills for this target — do not edit"
      printf '%s' "$managed"
    } > "$target/.skill-cli-manifest"
  done
  echo "  → global: $synced skill(s)"
}

# --- Project scope sync (per-harness, gated on configured targets) ----------
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

  # Which harnesses this machine writes to. The config's target vars are the
  # single source of truth: an empty/unset target disables that harness for
  # project scopes exactly as it already does for the global sync.
  local dir manifest harness old i managed real_dir out mode enabled
  for harness in claude agents; do
    enabled=0
    case "$harness" in
      claude) if [[ -n "${CLAUDE_TARGET:-}" ]]; then enabled=1; fi ;;
      agents) if [[ -n "${CODEX_TARGET:-}" ]]; then enabled=1; fi ;;
    esac

    dir="$scope/.$harness/skills"
    manifest="$dir/.skill-cli-manifest"

    # Harness disabled here: tear down what we previously wrote (manifest
    # entries only — hand-added skills survive) and move on without recreating
    # the directory. Cleans up projects synced before the harness was disabled.
    if [[ "$enabled" -eq 0 ]]; then
      if [[ -f "$manifest" ]]; then
        while IFS= read -r old; do
          [[ -z "$old" || "$old" == \#* ]] && continue
          rm -rf "$dir/$old"
          echo "  removed: $old (.$harness/skills — harness disabled)"
        done < "$manifest"
        rm -f "$manifest"
      fi
      rmdir "$dir" 2>/dev/null || true
      rmdir "$(dirname "$dir")" 2>/dev/null || true
      continue
    fi

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
