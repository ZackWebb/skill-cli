#!/usr/bin/env bash
# End-to-end tests for groups, project-scoped assignment, per-skill policy,
# catalog import, and manifest-safe pruning.
#
# Seam under test: running skill.sh against a throwaway config + pool + project
# dirs, then inspecting the assignments/groups files and the materialized
# .claude/skills output. No internal function is called directly.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$SCRIPT_DIR/skill.sh"

pass=0
fail=0
ok() { printf '  ok: %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL: %s\n' "$1"; fail=$((fail + 1)); }

assert_contains() { if grep -qF -- "$2" "$1" 2>/dev/null; then ok "$3"; else no "$3 (missing: $2 in $1)"; fi; }
assert_not_contains() { if grep -qF -- "$2" "$1" 2>/dev/null; then no "$3 (found: $2)"; else ok "$3"; fi; }
assert_symlink() { [[ -L "$1" ]] && ok "$2" || no "$2 (not a symlink: $1)"; }
assert_absent() { [[ ! -e "$1" && ! -L "$1" ]] && ok "$2" || no "$2 (still present: $1)"; }
assert_present() { [[ -e "$1" || -L "$1" ]] && ok "$2" || no "$2 (missing: $1)"; }

ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT

export XDG_CONFIG_HOME="$ROOT/config"
POOL="$ROOT/pool"
CLAUDE_T="$ROOT/claude"
CONFIG="$XDG_CONFIG_HOME/skill-cli/config.sh"
ASSIGN="$XDG_CONFIG_HOME/skill-cli/assignments.conf"
GRPS="$XDG_CONFIG_HOME/skill-cli/groups.conf"
mkdir -p "$XDG_CONFIG_HOME/skill-cli" "$POOL"

cat > "$CONFIG" << EOF
SKILLS_DIR="$POOL"
ACTIVE_FILE="$POOL/.active"
CLAUDE_TARGET="$CLAUDE_T"
EOF

# --- Pool fixtures ----------------------------------------------------------
mk_skill() {  # mk_skill <name> <extra-frontmatter-line>
  mkdir -p "$POOL/$1"
  {
    echo "---"
    echo "name: $1"
    echo "description: The $1 skill."
    [[ -n "${2:-}" ]] && echo "$2"
    echo "---"
    echo ""
    echo "Body of $1."
  } > "$POOL/$1/SKILL.md"
}
mk_skill alpha
mk_skill beta
mk_skill gamma "disable-model-invocation: true"   # upstream manual-only

echo "== migration seeds nothing when no .active =="
"$SKILL" ls > /dev/null 2>&1
assert_present "$ASSIGN" "migrate: assignments.conf created"

echo "== groups: manual add / show / ls =="
"$SKILL" group add core alpha beta > /dev/null
assert_contains "$GRPS" "core: alpha beta" "group add writes members"
OUT=$("$SKILL" group show core)
grep -qxF alpha <<< "$OUT" && grep -qxF beta <<< "$OUT" && ok "group show lists members" || no "group show lists members (got: $OUT)"
OUT=$("$SKILL" group ls)
grep -qF "core" <<< "$OUT" && ok "group ls shows the group" || no "group ls shows the group (got: $OUT)"

echo "== assign a group to a project scope (symlink-inherit) =="
PROJ="$ROOT/proj"
mkdir -p "$PROJ"
"$SKILL" assign @core --target "$PROJ" > /dev/null
assert_contains "$ASSIGN" "@core" "assign records @core for the scope"
assert_symlink "$PROJ/.claude/skills/alpha" "alpha materialized as symlink"
assert_symlink "$PROJ/.claude/skills/beta" "beta materialized as symlink"
assert_contains "$PROJ/.claude/skills/alpha/SKILL.md" "Body of alpha." "alpha resolves to source via symlink"
assert_not_contains "$PROJ/.claude/skills/alpha/SKILL.md" "disable-model-invocation" "inherit: model-invocable source stays invocable"

echo "== inherit preserves an upstream manual-only skill =="
"$SKILL" assign gamma --target "$PROJ" > /dev/null
assert_symlink "$PROJ/.claude/skills/gamma" "gamma materialized as symlink"
assert_contains "$PROJ/.claude/skills/gamma/SKILL.md" "disable-model-invocation: true" "inherit: upstream manual-only preserved"

echo "== global is untouched by a project assignment =="
assert_absent "$CLAUDE_T/alpha" "project assign does not populate global target"
OUT=$("$SKILL" ls)
grep -qF "● " <<< "$OUT" && no "nothing should be active globally yet" || ok "nothing active globally after project-only assigns"

echo "== policy override: force manual, then invocable =="
"$SKILL" policy alpha manual --target "$PROJ" > /dev/null
[[ -L "$PROJ/.claude/skills/alpha" ]] && no "policy manual should replace symlink with a wrapper" || ok "policy manual replaces symlink with a real wrapper"
assert_contains "$PROJ/.claude/skills/alpha/SKILL.md" "disable-model-invocation: true" "policy manual forces disable-model-invocation"
assert_contains "$ASSIGN" "alpha:manual" "policy manual recorded as alpha:manual"

"$SKILL" policy gamma invocable --target "$PROJ" > /dev/null
assert_not_contains "$PROJ/.claude/skills/gamma/SKILL.md" "disable-model-invocation" "policy invocable strips upstream manual"
assert_contains "$ASSIGN" "gamma:invocable" "policy invocable recorded"

echo "== policy inherit reverts to a symlink =="
"$SKILL" policy alpha inherit --target "$PROJ" > /dev/null
assert_symlink "$PROJ/.claude/skills/alpha" "policy inherit restores the symlink"
assert_not_contains "$ASSIGN" "alpha:manual" "policy inherit clears the override token"

echo "== manifest-safe pruning: hand-added skill survives =="
mkdir -p "$PROJ/.claude/skills/handmade"
echo "hand" > "$PROJ/.claude/skills/handmade/SKILL.md"
"$SKILL" group rm core beta > /dev/null    # beta leaves the group
"$SKILL" sync --target "$PROJ" > /dev/null
assert_absent "$PROJ/.claude/skills/beta" "unassigned member is pruned"
assert_present "$PROJ/.claude/skills/alpha" "still-assigned member survives"
assert_present "$PROJ/.claude/skills/handmade" "hand-added skill is NOT touched"

echo "== unassign clears the scope and prunes its managed skills =="
"$SKILL" unassign @core --target "$PROJ" > /dev/null
"$SKILL" unassign gamma --target "$PROJ" > /dev/null
assert_absent "$PROJ/.claude/skills/alpha" "unassign group prunes alpha"
assert_absent "$PROJ/.claude/skills/gamma" "unassign skill prunes gamma"
assert_present "$PROJ/.claude/skills/handmade" "hand-added skill still survives after full unassign"

echo "== --target . resolves to cwd =="
PROJ2="$ROOT/proj2"
mkdir -p "$PROJ2"
( cd "$PROJ2" && "$SKILL" assign alpha --target . > /dev/null )
assert_symlink "$PROJ2/.claude/skills/alpha" "bare-path '.' assigns to cwd"

echo "== import registers groups and stages skills from a catalog =="
SUITE="$ROOT/suite"
mkdir -p "$SUITE/skills/one" "$SUITE/skills/two"
printf -- '---\nname: one\ndescription: one.\n---\nB\n' > "$SUITE/skills/one/SKILL.md"
printf -- '---\nname: two\ndescription: two.\n---\nB\n' > "$SUITE/skills/two/SKILL.md"
cat > "$SUITE/catalog.json" << 'JSON'
{
  "name": "demo",
  "skills": [
    { "id": "one", "path": "skills/one", "category": "build" },
    { "id": "two", "path": "skills/two", "category": "build" }
  ],
  "workflows": [
    { "id": "flow", "includes": ["one", "two"] }
  ]
}
JSON
"$SKILL" import "$SUITE" > /dev/null
assert_symlink "$POOL/one" "import stages skill 'one' into the pool"
assert_symlink "$POOL/two" "import stages skill 'two' into the pool"
assert_contains "$GRPS" "flow: one two" "import registers the workflow group"
assert_contains "$GRPS" "build: one two" "import registers the category group"

echo "== imported group assigns end-to-end =="
PROJ3="$ROOT/proj3"
mkdir -p "$PROJ3"
"$SKILL" assign @flow --target "$PROJ3" > /dev/null
assert_symlink "$PROJ3/.claude/skills/one" "imported workflow materializes 'one'"
assert_symlink "$PROJ3/.claude/skills/two" "imported workflow materializes 'two'"

echo "== global on/off still works alongside the new model =="
"$SKILL" on alpha > /dev/null
assert_present "$CLAUDE_T/alpha" "global on materializes to the global target"
assert_contains "$CLAUDE_T/alpha/SKILL.md" "disable-model-invocation: true" "global default is force-manual"
"$SKILL" off alpha > /dev/null
assert_absent "$CLAUDE_T/alpha" "global off removes from the global target"

echo ""
echo "== $pass passed, $fail failed =="
[[ "$fail" -eq 0 ]]
