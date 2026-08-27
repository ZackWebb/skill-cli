#!/usr/bin/env bash
# End-to-end tests for manifest-tracked global targets.
#
# Seam under test: enabling and disabling global sync targets in the config,
# then inspecting what survives in each target dir. The manifest is what makes
# teardown precise — anything we did not write must survive, and a directory we
# never wrote to must never be touched at all.
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
COPILOT="$ROOT/copilot"
CONFIG="$XDG_CONFIG_HOME/skill-cli/config.sh"
mkdir -p "$XDG_CONFIG_HOME/skill-cli" "$POOL"

# write_config <codex: on|off> [claude: on|typo]
write_config() {
  {
    echo "SKILLS_DIR=\"$POOL\""
    echo "ACTIVE_FILE=\"$POOL/.active\""
    if [[ "${2:-on}" == "typo" ]]; then
      echo "CLAUDE_TARGE=\"$CLAUDE_T\""      # deliberate typo: var never set
    else
      echo "CLAUDE_TARGET=\"$CLAUDE_T\""
    fi
    if [[ "$1" == "on" ]]; then
      echo "CODEX_TARGET=\"$CODEX_T\""
      echo "COPILOT_PLUGIN=\"$COPILOT\""
    fi
  } > "$CONFIG"
}

mk_skill() {
  mkdir -p "$POOL/$1"
  printf -- '---\nname: %s\ndescription: The %s skill.\n---\n\nBody of %s.\n' "$1" "$1" "$1" \
    > "$POOL/$1/SKILL.md"
}
mk_skill alpha
mk_skill beta

echo "== all targets enabled: everything materializes =="
write_config on
"$SKILL" on alpha > /dev/null 2>&1
"$SKILL" on beta > /dev/null 2>&1
assert_present "$CLAUDE_T/alpha" "claude target populated"
assert_present "$CODEX_T/alpha" "codex target populated"
assert_present "$COPILOT/skills/alpha" "copilot target populated"
assert_present "$CODEX_T/.skill-cli-manifest" "manifest written into the target"

echo "== disabling a target tears it down, leaving other targets alone =="
write_config off
"$SKILL" sync > /dev/null 2>&1
assert_present "$CLAUDE_T/alpha" "still-enabled target untouched"
assert_present "$CLAUDE_T/beta" "still-enabled target keeps every skill"
assert_absent "$CODEX_T" "disabled codex target fully removed"
assert_absent "$COPILOT/.claude-plugin/plugin.json" "copilot plugin registration dropped"

echo "== re-enabling restores from the pool =="
write_config on
"$SKILL" sync > /dev/null 2>&1
assert_present "$CODEX_T/alpha" "codex restored on re-enable"
assert_present "$COPILOT/.claude-plugin/plugin.json" "copilot plugin re-registered"

echo "== teardown is manifest-safe: hand-added content survives =="
mkdir -p "$CODEX_T/handmade" "$COPILOT/skills/handmade"
touch "$CODEX_T/handmade/SKILL.md" "$COPILOT/skills/handmade/SKILL.md"
write_config off
"$SKILL" sync > /dev/null 2>&1
assert_absent "$CODEX_T/alpha" "managed skill torn down"
assert_present "$CODEX_T/handmade" "hand-added skill survives teardown"
assert_present "$COPILOT/.claude-plugin/plugin.json" "plugin stays registered while its skills dir is alive"

echo "== a target we never wrote to is never touched =="
# A directory that exists but has no manifest: not ours, even though the config
# names no target for it. This is the shared ~/.agents/skills case.
rm -rf "$CODEX_T"
mkdir -p "$CODEX_T/from-another-tool"
touch "$CODEX_T/from-another-tool/SKILL.md"
"$SKILL" sync > /dev/null 2>&1
assert_present "$CODEX_T/from-another-tool" "unmanaged directory left alone"

echo "== a typo'd target var removes only our skills, not the whole dir =="
mkdir -p "$CLAUDE_T/handmade"
touch "$CLAUDE_T/handmade/SKILL.md"
write_config off typo
"$SKILL" sync > /dev/null 2>&1
assert_absent "$CLAUDE_T/alpha" "typo tears down our managed skills (recoverable from pool)"
assert_present "$CLAUDE_T/handmade" "typo does NOT destroy hand-added skills"
write_config off
"$SKILL" sync > /dev/null 2>&1
assert_present "$CLAUDE_T/alpha" "fixing the typo restores everything"

echo "== routine prune no longer eats unmanaged skills =="
mkdir -p "$CLAUDE_T/foreign"
touch "$CLAUDE_T/foreign/SKILL.md"
"$SKILL" off beta > /dev/null 2>&1
assert_absent "$CLAUDE_T/beta" "deactivated skill is pruned"
assert_present "$CLAUDE_T/foreign" "unmanaged skill survives a routine prune"
assert_present "$CLAUDE_T/alpha" "still-active skill survives"

echo ""
echo "== $pass passed, $fail failed =="
[[ "$fail" -eq 0 ]]
