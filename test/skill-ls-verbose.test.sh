#!/usr/bin/env bash
# End-to-end tests for `skill ls -v` — the all-scopes overview.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$SCRIPT_DIR/skill.sh"

pass=0
fail=0
ok() { printf '  ok: %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL: %s\n' "$1"; fail=$((fail + 1)); }
has() { if grep -qF -- "$2" <<< "$1"; then ok "$3"; else no "$3 (missing: $2)"; fi; }
hasnt() { if grep -qF -- "$2" <<< "$1"; then no "$3 (found: $2)"; else ok "$3"; fi; }

ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT

export XDG_CONFIG_HOME="$ROOT/config"
POOL="$ROOT/pool"
CLAUDE_T="$ROOT/claude"
mkdir -p "$XDG_CONFIG_HOME/skill-cli" "$POOL"
cat > "$XDG_CONFIG_HOME/skill-cli/config.sh" << EOF
SKILLS_DIR="$POOL"
ACTIVE_FILE="$POOL/.active"
CLAUDE_TARGET="$CLAUDE_T"
EOF

mk() { mkdir -p "$POOL/$1"; printf -- '---\nname: %s\ndescription: d\n---\nB\n' "$1" > "$POOL/$1/SKILL.md"; }
mk alpha; mk beta; mk gamma; mk lonely

"$SKILL" group add core alpha beta > /dev/null
"$SKILL" on alpha > /dev/null                              # global
PROJ="$ROOT/proj"; mkdir -p "$PROJ"
"$SKILL" assign @core --target "$PROJ" > /dev/null
"$SKILL" policy beta manual --target "$PROJ" > /dev/null
"$SKILL" assign gamma --target "$PROJ" > /dev/null

OUT="$("$SKILL" ls -v)"
echo "$OUT"
echo "---"

has "$OUT" "pool: 4 skill(s)" "header shows pool count"
has "$OUT" "groups: 1" "header shows group count"
has "$OUT" "[global]" "lists the global scope"
has "$OUT" "[$PROJ]" "lists the project scope by path"
has "$OUT" "beta [manual]" "annotates a policy override"
has "$OUT" "entries: @core" "shows raw entries for the project scope"
has "$OUT" "gamma" "shows a directly-assigned skill"
has "$OUT" "[unassigned in pool]" "reports staged-but-unassigned skills"
has "$OUT" "lonely" "lists the orphan skill"
hasnt "$OUT" "lonely [" "orphan is not shown with a policy tag"

echo ""
echo "== $pass passed, $fail failed =="
[[ "$fail" -eq 0 ]]
