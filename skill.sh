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
CODEX_TARGET="$HOME/.agents/skills"
COPILOT_PLUGIN="$HOME/.copilot/installed-plugins/local/personal-skills"
DEFAULTS
  echo "Created default config at $CONFIG_FILE — review and edit for this machine."
fi

source "$CONFIG_FILE"
source "$SCRIPT_DIR/lib.sh"
SYNC_SCRIPT="$SCRIPT_DIR/sync-skills.sh"

mkdir -p "$SKILLS_DIR"
skc_migrate

usage() {
  cat << 'EOF'
Usage: skill <command> [args]

Global skills (available everywhere):
  ls [-v|--verbose]        Show pooled skills (● = active globally);
                           -v shows every scope (global + projects) at a glance
  on <name>                Activate a skill globally
  off <name>               Deactivate a skill globally
  add <path>               Stage a skill into the pool (symlink)
  rm <name>                Remove a skill from the pool
  invocable [<name> on|off] Manage the global model-invocable allowlist

Groups (portable named skill sets, ~/.config/skill-cli/groups.conf):
  group ls                 List groups
  group show <name>        Show a group's members
  group add <name> <skill...>   Create/extend a group
  group rm <name> [skill...]    Delete a group, or drop members
  import <path>            Register groups from a suite's catalog.json and
                           stage its skills into the pool

Project scoping (--target: absent=global, bare/'.'=cwd, else a path):
  assign <skill|@group> [--target DIR]      Wire a skill/group to a scope
  unassign <skill|@group> [--target DIR]    Remove it from a scope
  policy <skill> <manual|invocable|inherit> --target DIR
                           Override a skill's invocation flag in one project
  where                    Show what applies to the current directory

  sync [--target DIR|--all]  Re-materialize one scope or everything
EOF
}

# --- shared: parse an optional --target flag out of the args -----------------
# Populates SCOPE (canonical, default "global") and POS (positional array).
SCOPE="global"
POS=()
resolve_scope_args() {
  SCOPE="global"
  POS=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --target)
        shift
        if [[ $# -eq 0 || "$1" == "." ]]; then
          SCOPE="$(skc_canon_scope "$PWD")"
          [[ $# -gt 0 && "$1" == "." ]] && shift
        else
          SCOPE="$(skc_canon_scope "$1")"; shift
        fi
        ;;
      --target=*)
        local v="${1#--target=}"
        [[ "$v" == "." || -z "$v" ]] && v="$PWD"
        SCOPE="$(skc_canon_scope "$v")"; shift
        ;;
      *) POS+=("$1"); shift ;;
    esac
  done
}

sync_scope() {
  local scope="$1"
  if [[ "$scope" == "global" ]]; then
    "$SYNC_SCRIPT" --target global
  else
    "$SYNC_SCRIPT" --target "$scope"
  fi
}

# --- entry mutation on a scope's assignment line ----------------------------
# The key of a token is the whole token for @groups, else the skill name
# (before any :policy). Adding replaces a same-key token and appends the new
# one at the end — so an explicit policy override lands after its @group.
_token_key() {
  local t="$1"
  if [[ "$t" == @* ]]; then echo "$t"; else echo "${t%%:*}"; fi
}

entries_add_token() {
  local scope="$1" token="$2" key cur t new=""
  key="$(_token_key "$token")"
  cur="$(skc_assign_get "$scope")"
  for t in $cur; do
    [[ "$(_token_key "$t")" == "$key" ]] && continue
    new+="$t "
  done
  new+="$token"
  skc_assign_set "$scope" "$new"
}

entries_remove_key() {
  local scope="$1" key="$2" cur t new=""
  cur="$(skc_assign_get "$scope")"
  local found=0
  for t in $cur; do
    if [[ "$(_token_key "$t")" == "$key" ]]; then found=1; continue; fi
    new+="$t "
  done
  new="$(echo $new)"   # trim
  skc_assign_set "$scope" "$new"
  return $((found ? 0 : 1))
}

# Drop only a skill's explicit :policy override token, leaving a plain token or
# an @group that also provides the skill intact.
entries_clear_override() {
  local scope="$1" skill="$2" cur t new=""
  cur="$(skc_assign_get "$scope")"
  for t in $cur; do
    [[ "$t" == "$skill:manual" || "$t" == "$skill:invocable" ]] && continue
    new+="$t "
  done
  skc_assign_set "$scope" "$(echo $new)"
}

# --- list -------------------------------------------------------------------
list_skills() {
  local active
  active="$(skc_expand global | cut -f1)"
  for entry in "$SKILLS_DIR"/*; do
    [[ ! -d "$entry" && ! -L "$entry" ]] && continue
    local name marker="  " target
    name=$(basename "$entry")
    grep -qxF -- "$name" <<< "$active" && marker="● "
    target=$(readlink "$entry" 2>/dev/null || echo "(dir)")
    target="${target/#$HOME/~}"
    [[ -e "$entry" ]] || target="$target  (BROKEN)"
    printf "%s%-28s %s\n" "$marker" "$name" "$target"
  done
}

# --- pool: activate globally ------------------------------------------------
activate() {
  local name="$1"
  if [[ ! -d "$SKILLS_DIR/$name" ]]; then
    echo "Not in pool: $name"
    echo "Use 'skill add <path>' to stage it first, or 'skill ls' to see available."
    return 1
  fi
  if grep -qxF -- "$name" <<< "$(skc_expand global | cut -f1)"; then
    echo "Already active: $name"
    return 0
  fi
  entries_add_token global "$name"
  echo "Activated: $name"
  sync_scope global
}

deactivate() {
  local name="$1"
  if entries_remove_key global "$name"; then
    echo "Deactivated: $name"
    sync_scope global
  else
    echo "Not active: $name"
  fi
}

add_skill() {
  local path="$1" abs_path name
  abs_path=$(cd "$(dirname "$path")" && pwd)/$(basename "$path")
  if [[ ! -f "$abs_path/SKILL.md" ]]; then
    echo "No SKILL.md found at: $abs_path"
    return 1
  fi
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
  entries_remove_key global "$name" || true
  rm -rf "$SKILLS_DIR/$name"
  echo "Removed from pool: $name"
  # Warn if any project scope still references it.
  local scope
  while IFS= read -r scope; do
    if grep -qxF -- "$name" <<< "$(skc_expand "$scope" | cut -f1)"; then
      echo "  note: still assigned in $(skc_scope_label "$scope") — 'skill unassign $name --target $scope'"
    fi
  done < <(skc_project_scopes)
  sync_scope global
}

# --- MODEL_INVOCABLE allowlist (global only) --------------------------------
resolve_skill_name() {
  local pool_name="$1" skill_md="$SKILLS_DIR/$1/SKILL.md" fm_name=""
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
  for n in ${MODEL_INVOCABLE}; do echo "$n"; done
}

invocable_on() {
  local pool_name="$1" name n
  if [[ ! -d "$SKILLS_DIR/$pool_name" ]]; then
    echo "Not in pool: $pool_name"
    echo "Use 'skill add <path>' to stage it first, or 'skill ls' to see available."
    return 1
  fi
  name=$(resolve_skill_name "$pool_name")
  for n in ${MODEL_INVOCABLE:-}; do
    if [[ "$n" == "$name" ]]; then echo "Already model-invocable: $name"; return 0; fi
  done
  if awk '/^---$/{n++; next} n==1{print} n>=2{exit}' "$SKILLS_DIR/$pool_name/SKILL.md" 2>/dev/null \
      | grep -q '^disable-model-invocation:[[:space:]]*true'; then
    echo "Note: $name sets disable-model-invocation: true upstream — allowlisting keeps it manual-only until upstream changes."
  fi
  if ! grep -qxF -- "$pool_name" <<< "$(skc_expand global | cut -f1)"; then
    echo "Note: $pool_name is not active globally — 'skill on $pool_name' before it syncs anywhere."
  fi
  write_model_invocable "${MODEL_INVOCABLE:+$MODEL_INVOCABLE }$name"
  echo "Model-invocable: $name"
  sync_scope global
}

invocable_off() {
  local pool_name="$1" name="$1"
  [[ -d "$SKILLS_DIR/$pool_name" ]] && name=$(resolve_skill_name "$pool_name")
  local newval="" found=0 n
  for n in ${MODEL_INVOCABLE:-}; do
    if [[ "$n" == "$name" || "$n" == "$pool_name" ]]; then found=1; else newval="${newval:+$newval }$n"; fi
  done
  if [[ "$found" -eq 0 ]]; then echo "Not in allowlist: $name"; return 0; fi
  write_model_invocable "$newval"
  echo "Manual-only: $name"
  sync_scope global
}

# --- groups -----------------------------------------------------------------
group_ls() {
  local names g members
  names="$(skc_group_names)"
  if [[ -z "$names" ]]; then echo "No groups. Create one with 'skill group add' or 'skill import'."; return 0; fi
  while IFS= read -r g; do
    [[ -z "$g" ]] && continue
    members="$(skc_group_get "$g")"
    printf "%-24s %s\n" "$g" "($(wc -w <<< "$members" | tr -d ' ') skills)"
  done <<< "$names"
}

group_show() {
  local g="$1" members
  if ! skc_group_exists "$g"; then echo "No such group: $g"; return 1; fi
  members="$(skc_group_get "$g")"
  local m
  for m in $members; do echo "$m"; done
}

group_add() {
  local g="$1"; shift
  local cur new m
  cur="$(skc_group_get "$g")"
  new="$cur"
  for m in "$@"; do
    grep -qwF -- "$m" <<< " $new " 2>/dev/null && continue
    [[ -d "$SKILLS_DIR/$m" ]] || echo "  note: $m is not in the pool yet — 'skill add' or 'skill import' it."
    new="${new:+$new }$m"
  done
  skc_group_set "$g" "$new"
  echo "Group $g: $new"
}

group_rm() {
  local g="$1"; shift
  if ! skc_group_exists "$g"; then echo "No such group: $g"; return 1; fi
  if [[ $# -eq 0 ]]; then
    skc_group_set "$g" ""
    echo "Deleted group: $g"
    return 0
  fi
  local cur new="" m keep t
  cur="$(skc_group_get "$g")"
  for t in $cur; do
    keep=1
    for m in "$@"; do [[ "$t" == "$m" ]] && keep=0; done
    [[ "$keep" -eq 1 ]] && new="${new:+$new }$t"
  done
  skc_group_set "$g" "$new"
  echo "Group $g: ${new:-(empty)}"
}

import_catalog() {
  local path="$1" catalog
  if [[ -f "$path" ]]; then
    catalog="$path"
  elif [[ -f "$path/catalog.json" ]]; then
    catalog="$path/catalog.json"
  else
    echo "No catalog.json found at: $path"
    return 1
  fi

  local line kind a b staged=0 grouped=0
  while IFS=$'\t' read -r kind a b; do
    case "$kind" in
      SKILL)
        # a=id  b=abs source path
        if [[ -f "$b/SKILL.md" ]]; then
          if [[ ! -e "$SKILLS_DIR/$a" ]]; then
            ln -s "$b" "$SKILLS_DIR/$a"
            staged=$((staged + 1))
          fi
        else
          echo "  ⚠ skill source missing SKILL.md: $a ($b)"
        fi
        ;;
      GROUP)
        skc_group_set "$a" "$b"
        grouped=$((grouped + 1))
        printf "  group %-24s %s\n" "$a" "($(wc -w <<< "$b" | tr -d ' ') skills)"
        ;;
    esac
  done < <(python3 - "$catalog" << 'PY'
import json, os, sys
cat = sys.argv[1]
base = os.path.dirname(os.path.abspath(cat))
data = json.load(open(cat))
skills = data.get("skills", [])
for s in skills:
    sid = s["id"]
    p = s.get("path") or ("skills/" + sid)
    print("SKILL\t%s\t%s" % (sid, os.path.join(base, p)))
cats = {}
for s in skills:
    c = s.get("category")
    if c:
        cats.setdefault(c, []).append(s["id"])
for c, ids in cats.items():
    print("GROUP\t%s\t%s" % (c, " ".join(ids)))
for w in data.get("workflows", []):
    print("GROUP\t%s\t%s" % (w["id"], " ".join(w.get("includes", []))))
PY
)
  echo "Imported: $staged skill(s) staged, $grouped group(s) registered."
}

# --- assignments ------------------------------------------------------------
validate_entry_token() {
  # token is skill | @group | skill:policy
  local token="$1"
  if [[ "$token" == @* ]]; then
    skc_group_exists "${token#@}" || { echo "No such group: ${token#@}"; return 1; }
  else
    local sk="${token%%:*}"
    [[ -d "$SKILLS_DIR/$sk" ]] || { echo "Not in pool: $sk"; return 1; }
    if [[ "$token" == *:* ]]; then
      local p="${token#*:}"
      case "$p" in manual|invocable|inherit) ;; *) echo "Bad policy '$p' (use manual|invocable|inherit)"; return 1 ;; esac
    fi
  fi
}

cmd_assign() {
  resolve_scope_args "$@"
  [[ ${#POS[@]} -eq 0 ]] && { echo "Usage: skill assign <skill|@group>[:policy] [--target DIR]"; return 1; }
  local token
  for token in "${POS[@]}"; do
    validate_entry_token "$token" || return 1
  done
  for token in "${POS[@]}"; do
    entries_add_token "$SCOPE" "$token"
    echo "Assigned $token → $(skc_scope_label "$SCOPE")"
  done
  sync_scope "$SCOPE"
}

cmd_unassign() {
  resolve_scope_args "$@"
  [[ ${#POS[@]} -eq 0 ]] && { echo "Usage: skill unassign <skill|@group> [--target DIR]"; return 1; }
  local token key
  for token in "${POS[@]}"; do
    key="$(_token_key "$token")"
    if entries_remove_key "$SCOPE" "$key"; then
      echo "Unassigned $key from $(skc_scope_label "$SCOPE")"
    else
      echo "Not assigned in $(skc_scope_label "$SCOPE"): $key"
    fi
  done
  sync_scope "$SCOPE"
}

cmd_policy() {
  resolve_scope_args "$@"
  [[ ${#POS[@]} -lt 2 ]] && { echo "Usage: skill policy <skill> <manual|invocable|inherit> --target DIR"; return 1; }
  local skill="${POS[0]}" pol="${POS[1]}"
  if [[ "$SCOPE" == "global" ]]; then
    echo "policy applies to project scopes; use 'skill invocable' for global."
    return 1
  fi
  [[ -d "$SKILLS_DIR/$skill" ]] || { echo "Not in pool: $skill"; return 1; }
  case "$pol" in
    inherit)
      # Remove any override; keep the skill present as inherit whether it came
      # from a plain token or a group.
      entries_clear_override "$SCOPE" "$skill"
      if ! grep -qxF -- "$skill" <<< "$(skc_expand "$SCOPE" | cut -f1)"; then
        entries_add_token "$SCOPE" "$skill"
      fi
      ;;
    manual|invocable) entries_add_token "$SCOPE" "$skill:$pol" ;;
    *) echo "Bad policy '$pol' (use manual|invocable|inherit)"; return 1 ;;
  esac
  echo "Policy for $skill in $(skc_scope_label "$SCOPE"): $pol"
  sync_scope "$SCOPE"
}

cmd_where() {
  local here entries scope
  here="$(skc_canon_scope "$PWD")"
  echo "cwd: $(skc_scope_label "$here")"
  echo ""
  echo "[global]"
  skc_expand global | sed 's/^/  /'
  # Project scopes that are the cwd or an ancestor of it (Claude loads parent
  # .claude/skills up to the repo root).
  while IFS= read -r scope; do
    if [[ "$here" == "$scope" || "$here" == "$scope"/* ]]; then
      echo ""
      echo "[$(skc_scope_label "$scope")]"
      skc_expand "$scope" | sed 's/^/  /'
    fi
  done < <(skc_project_scopes)
}

# --- ls --verbose: every scope at a glance ---------------------------------
ls_verbose() {
  local pool_count group_count
  pool_count=$(find "$SKILLS_DIR" -mindepth 1 -maxdepth 1 \( -type d -o -type l \) 2>/dev/null | wc -l | tr -d ' ')
  group_count=$(skc_group_names | grep -c . || true)
  echo "pool: $pool_count skill(s)    groups: $group_count"

  local assigned_all="" scopes=() s
  scopes+=("global")
  while IFS= read -r s; do [[ -n "$s" ]] && scopes+=("$s"); done < <(skc_project_scopes | sort)

  local scope entries resolved count name pol
  for scope in "${scopes[@]}"; do
    entries="$(skc_assign_get "$scope")"
    resolved="$(skc_expand "$scope")"
    if [[ -z "$resolved" ]]; then count=0; else count=$(grep -c . <<< "$resolved"); fi
    printf '\n[%s]  %s skill(s)\n' "$(skc_scope_label "$scope")" "$count"
    [[ -n "$entries" ]] && printf '  entries: %s\n' "$entries"
    while IFS=$'\t' read -r name pol; do
      [[ -z "$name" ]] && continue
      assigned_all+="$name"$'\n'
      if [[ "$pol" == "inherit" ]]; then
        printf '    %s\n' "$name"
      else
        printf '    %s [%s]\n' "$name" "$pol"
      fi
    done <<< "$resolved"
  done

  # Orphans: pooled but not active/assigned in any scope.
  local orphans="" entry
  for entry in "$SKILLS_DIR"/*; do
    [[ ! -d "$entry" && ! -L "$entry" ]] && continue
    name=$(basename "$entry")
    grep -qxF -- "$name" <<< "$assigned_all" || orphans+="$name "
  done
  orphans="$(echo $orphans)"
  [[ -n "$orphans" ]] && printf '\n[unassigned in pool]  (staged, not active anywhere)\n  %s\n' "$orphans"
}

# --- dispatch ---------------------------------------------------------------
cmd="${1:-}"
shift || true

case "$cmd" in
  ls|list)
    case "${1:-}" in
      -v|--verbose) ls_verbose ;;
      "")           list_skills ;;
      *)            echo "Usage: skill ls [-v|--verbose]"; exit 1 ;;
    esac
    ;;
  on)        [[ -z "${1:-}" ]] && { echo "Usage: skill on <name>"; exit 1; }; activate "$1" ;;
  off)       [[ -z "${1:-}" ]] && { echo "Usage: skill off <name>"; exit 1; }; deactivate "$1" ;;
  add)       [[ -z "${1:-}" ]] && { echo "Usage: skill add <path>"; exit 1; }; add_skill "$1" ;;
  rm|remove) [[ -z "${1:-}" ]] && { echo "Usage: skill rm <name>"; exit 1; }; remove_skill "$1" ;;
  sync)      "$SYNC_SCRIPT" "$@" ;;
  where)     cmd_where ;;
  assign)    cmd_assign "$@" ;;
  unassign)  cmd_unassign "$@" ;;
  policy)    cmd_policy "$@" ;;
  import)    [[ -z "${1:-}" ]] && { echo "Usage: skill import <path-to-catalog-or-dir>"; exit 1; }; import_catalog "$1" ;;
  group)
    sub="${1:-}"; shift || true
    case "$sub" in
      ls|list|"") group_ls ;;
      show)  [[ -z "${1:-}" ]] && { echo "Usage: skill group show <name>"; exit 1; }; group_show "$1" ;;
      add)   [[ $# -lt 2 ]] && { echo "Usage: skill group add <name> <skill...>"; exit 1; }; group_add "$@" ;;
      rm)    [[ -z "${1:-}" ]] && { echo "Usage: skill group rm <name> [skill...]"; exit 1; }; group_rm "$@" ;;
      on)    [[ -z "${1:-}" ]] && { echo "Usage: skill group on <name> [--target DIR]"; exit 1; }; g="$1"; shift; cmd_assign "@$g" "$@" ;;
      off)   [[ -z "${1:-}" ]] && { echo "Usage: skill group off <name> [--target DIR]"; exit 1; }; g="$1"; shift; cmd_unassign "@$g" "$@" ;;
      *)     echo "Unknown group command: $sub"; usage; exit 1 ;;
    esac
    ;;
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
