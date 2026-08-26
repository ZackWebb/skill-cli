#!/usr/bin/env bash
# Shared helpers for skill.sh and sync-skills.sh.
#
# Source this AFTER config.sh so SKILLS_DIR / ACTIVE_FILE / MODEL_INVOCABLE are
# already in scope. It adds the group + assignment model on top:
#
#   groups.conf       portable named skill sets (no paths):  name: skill skill ...
#   assignments.conf  the router (machine-local):            scope<TAB>entries
#
# A scope is "global" or an absolute path. Entries are space-separated tokens:
#   skill              a pool skill, inherit source invocation flag
#   @group             expands to the group's members (each inherit)
#   skill:manual       force disable-model-invocation on for this skill here
#   skill:invocable    force the skill model-invocable here
# For the global scope, policies are ignored — global keeps the historical
# force-manual + MODEL_INVOCABLE behavior; only membership matters there.

SKC_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/skill-cli"
GROUPS_FILE="$SKC_CONFIG_DIR/groups.conf"
ASSIGN_FILE="$SKC_CONFIG_DIR/assignments.conf"

# ---- scope helpers ---------------------------------------------------------

# Canonicalize a scope. "global" is returned as-is; a path is resolved to an
# absolute realpath so lookups are stable regardless of how it was typed.
skc_canon_scope() {
  local s="$1"
  if [[ "$s" == "global" ]]; then
    echo "global"
    return 0
  fi
  python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$s"
}

# Human-friendly scope label ("global" or ~-collapsed path).
skc_scope_label() {
  local s="$1"
  [[ "$s" == "global" ]] && { echo "global"; return; }
  echo "${s/#$HOME/~}"
}

# Where a project scope's skills are materialized.
skc_scope_skills_dir() {
  local s="$1"
  if [[ "$s" == "global" ]]; then
    echo "${CLAUDE_TARGET:-}"
  else
    echo "$s/.claude/skills"
  fi
}

# ---- assignments.conf access ----------------------------------------------

# One-time migration: create assignments.conf and seed the global scope from a
# legacy .active list. No-op once the file exists, so it never fights edits.
skc_migrate() {
  [[ -f "$ASSIGN_FILE" ]] && return 0
  mkdir -p "$SKC_CONFIG_DIR"
  {
    echo "# skill-cli assignments — one line per scope: scope<TAB>entries"
    echo "# scope:   'global' or an absolute path"
    echo "# entries: space-separated  skill | @group | skill:manual | skill:invocable"
  } > "$ASSIGN_FILE"
  if [[ -n "${ACTIVE_FILE:-}" && -f "$ACTIVE_FILE" ]]; then
    local names
    names=$(grep -vE '^[[:space:]]*(#|$)' "$ACTIVE_FILE" 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]*$//')
    [[ -n "$names" ]] && printf 'global\t%s\n' "$names" >> "$ASSIGN_FILE"
  fi
}

# Entries string for a scope (empty if unassigned). Scope must be canonical.
skc_assign_get() {
  [[ -f "$ASSIGN_FILE" ]] || return 0
  awk -F'\t' -v s="$1" '$1==s{print $2; exit}' "$ASSIGN_FILE"
}

# Upsert a scope's entries. Empty entries removes the scope line entirely.
skc_assign_set() {
  local scope="$1" entries="$2" tmp
  mkdir -p "$SKC_CONFIG_DIR"
  touch "$ASSIGN_FILE"
  tmp="$ASSIGN_FILE.tmp"
  awk -F'\t' -v s="$scope" '$1!=s{print}' "$ASSIGN_FILE" > "$tmp"
  [[ -n "$entries" ]] && printf '%s\t%s\n' "$scope" "$entries" >> "$tmp"
  mv "$tmp" "$ASSIGN_FILE"
}

# All assigned scopes, one per line (comments/blanks skipped).
skc_assign_scopes() {
  [[ -f "$ASSIGN_FILE" ]] || return 0
  awk -F'\t' '/^[[:space:]]*#/{next} NF{print $1}' "$ASSIGN_FILE"
}

# Project scopes only (everything except global).
skc_project_scopes() {
  skc_assign_scopes | grep -vxF 'global' || true
}

# ---- groups.conf access ----------------------------------------------------

skc_group_get() {
  [[ -f "$GROUPS_FILE" ]] || return 0
  awk -F':' -v g="$1" '$1==g{sub(/^[^:]*:[[:space:]]*/,""); print; exit}' "$GROUPS_FILE"
}

skc_group_exists() {
  [[ -f "$GROUPS_FILE" ]] || return 1
  awk -F':' -v g="$1" '$1==g{found=1} END{exit found?0:1}' "$GROUPS_FILE"
}

skc_group_set() {
  local name="$1" members="$2" tmp
  mkdir -p "$SKC_CONFIG_DIR"
  touch "$GROUPS_FILE"
  tmp="$GROUPS_FILE.tmp"
  awk -F':' -v g="$name" '$1!=g{print}' "$GROUPS_FILE" > "$tmp"
  [[ -n "$members" ]] && printf '%s: %s\n' "$name" "$members" >> "$tmp"
  mv "$tmp" "$GROUPS_FILE"
}

skc_group_names() {
  [[ -f "$GROUPS_FILE" ]] || return 0
  awk -F':' '/^[[:space:]]*#/{next} NF{print $1}' "$GROUPS_FILE"
}

# ---- entry expansion -------------------------------------------------------

# Resolve a scope's entries into "name<TAB>policy" lines, in order, deduped.
# policy is one of: inherit | manual | invocable. A later explicit override
# (skill:manual / skill:invocable) wins over an inherit from a group.
declare -a _SKC_EX_NAMES _SKC_EX_POLS

_skc_ex_put() {
  local name="$1" pol="$2" i
  for ((i = 0; i < ${#_SKC_EX_NAMES[@]}; i++)); do
    if [[ "${_SKC_EX_NAMES[$i]}" == "$name" ]]; then
      # Only a real (non-inherit) override replaces an existing entry.
      [[ "$pol" != "inherit" ]] && _SKC_EX_POLS[$i]="$pol"
      return 0
    fi
  done
  _SKC_EX_NAMES+=("$name")
  _SKC_EX_POLS+=("$pol")
}

skc_expand() {
  local scope="$1" entries tok m
  entries=$(skc_assign_get "$scope")
  _SKC_EX_NAMES=()
  _SKC_EX_POLS=()
  for tok in $entries; do
    if [[ "$tok" == @* ]]; then
      for m in $(skc_group_get "${tok#@}"); do
        _skc_ex_put "$m" inherit
      done
    elif [[ "$tok" == *:* ]]; then
      _skc_ex_put "${tok%%:*}" "${tok#*:}"
    else
      _skc_ex_put "$tok" inherit
    fi
  done
  local i
  for ((i = 0; i < ${#_SKC_EX_NAMES[@]}; i++)); do
    printf '%s\t%s\n' "${_SKC_EX_NAMES[$i]}" "${_SKC_EX_POLS[$i]}"
  done
}
