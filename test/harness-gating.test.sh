#!/usr/bin/env bash
# End-to-end tests for per-machine harness gating in project scopes.
#
# Seam under test: the config's target vars decide which harness dirs a project
# scope materializes. An unset/empty target must not create that harness's dir,
# and disabling a previously-enabled target must tear down what we wrote there
# (manifest entries only) on the next sync.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$SCRIPT_DIR/skill.sh"

pass=0
fail=0
ok() { printf '  ok: %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL: %s\n' "$1"; fail=$((fail + 1)); }

assert_absent() { [[ ! -e "$1" && ! -L "$1" ]] && ok "$2" || no "$2 (still present: $1)"; }
assert_present() { [[ -e "$1" || -L "$1" ]] && ok "$2" || no "$2 (missing: $1)"; }

ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT

export XDG_CONFIG_HOME="$ROOT/config"
POOL="$ROOT/pool"
CLAUDE_T="$ROOT/claude"
CODEX_T="$ROOT/agents"
PROJ="$ROOT/proj"
CONFIG="$XDG_CONFIG_HOME/skill-cli/config.sh"
mkdir -p "$XDG_CONFIG_HOME/skill-cli" "$POOL" "$PROJ"

write_config() {  # write_config <with-codex: 0|1>
  {
    echo "SKILLS_DIR=\"$POOL\""
    echo "ACTIVE_FILE=\"$POOL/.active\""
    echo "CLAUDE_TARGET=\"$CLAUDE_T\""
    [[ "$1" -eq 1 ]] && echo "CODEX_TARGET=\"$CODEX_T\""
  } > "$CONFIG"
}

mk_skill() {
  mkdir -p "$POOL/$1"
  printf -- '---\nname: %s\ndescription: The %s skill.\n---\n\nBody of %s.\n' "$1" "$1" "$1" \
    > "$POOL/$1/SKILL.md"
}
mk_skill alpha
mk_skill beta

echo "== both targets configured: both harness dirs materialize =="
write_config 1
"$SKILL" assign alpha --target "$PROJ" > /dev/null 2>&1
assert_present "$PROJ/.claude/skills/alpha" "claude dir written when CLAUDE_TARGET set"
assert_present "$PROJ/.agents/skills/alpha" "agents dir written when CODEX_TARGET set"

echo "== disabling CODEX_TARGET tears down the agents tree on next sync =="
write_config 0
"$SKILL" sync --target "$PROJ" > /dev/null 2>&1
assert_present "$PROJ/.claude/skills/alpha" "claude side untouched by the teardown"
assert_absent "$PROJ/.agents/skills/alpha" "managed skill removed from agents"
assert_absent "$PROJ/.agents" "empty .agents dir cleaned up entirely"

echo "== staying disabled never recreates the agents tree =="
"$SKILL" assign beta --target "$PROJ" > /dev/null 2>&1
assert_present "$PROJ/.claude/skills/beta" "claude still materializes new assignments"
assert_absent "$PROJ/.agents" "disabled harness stays absent on later assigns"

echo "== teardown is manifest-safe: hand-added skills survive =="
write_config 1
"$SKILL" sync --target "$PROJ" > /dev/null 2>&1
assert_present "$PROJ/.agents/skills/alpha" "re-enabling restores the agents tree"
mkdir -p "$PROJ/.agents/skills/handmade"
touch "$PROJ/.agents/skills/handmade/SKILL.md"
write_config 0
"$SKILL" sync --target "$PROJ" > /dev/null 2>&1
assert_absent "$PROJ/.agents/skills/alpha" "managed skill removed on disable"
assert_present "$PROJ/.agents/skills/handmade" "hand-added skill is NOT touched"

echo ""
echo "== $pass passed, $fail failed =="
[[ "$fail" -eq 0 ]]
