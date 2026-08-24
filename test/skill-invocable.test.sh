#!/usr/bin/env bash
# End-to-end tests for `skill invocable`.
#
# Seam under test: running skill.sh against a throwaway config + pool + Claude
# target, then inspecting config.sh, command output, and the re-synced
# wrapper SKILL.md files. No internal function is called directly.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$SCRIPT_DIR/skill.sh"

pass=0
fail=0

ok() { printf '  ok: %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL: %s\n' "$1"; fail=$((fail + 1)); }

# assert_contains <file> <fixed-string> <description>
assert_contains() {
  if grep -qF -- "$2" "$1"; then ok "$3"; else no "$3 (missing: $2)"; fi
}

# assert_not_contains <file> <fixed-string> <description>
assert_not_contains() {
  if grep -qF -- "$2" "$1"; then no "$3 (found: $2)"; else ok "$3"; fi
}

# Build an isolated environment: config + pool + target under a tmp root.
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT

export XDG_CONFIG_HOME="$ROOT/config"
POOL="$ROOT/pool"
CLAUDE_T="$ROOT/claude"
CONFIG="$XDG_CONFIG_HOME/skill-cli/config.sh"
mkdir -p "$XDG_CONFIG_HOME/skill-cli" "$POOL"

# Deliberately omit MODEL_INVOCABLE: the first `invocable on` must append it.
cat > "$CONFIG" << EOF
SKILLS_DIR="$POOL"
ACTIVE_FILE="$POOL/.active"
CLAUDE_TARGET="$CLAUDE_T"
EOF

# --- Fixture 1: upstream model-invocable
mkdir -p "$POOL/inv"
cat > "$POOL/inv/SKILL.md" << 'EOF'
---
name: inv
description: Upstream model-invocable skill.
---

Body of inv.
EOF

# --- Fixture 2: upstream itself forces manual-only (the second gate)
mkdir -p "$POOL/manual-up"
cat > "$POOL/manual-up/SKILL.md" << 'EOF'
---
name: manual-up
description: Upstream user-invoked skill.
disable-model-invocation: true
---

Body of manual-up.
EOF

# --- Fixture 3: pool dir name differs from frontmatter name; sync matches on
# the frontmatter name, so the allowlist must store that one.
mkdir -p "$POOL/dir-alias"
cat > "$POOL/dir-alias/SKILL.md" << 'EOF'
---
name: fm-name
description: Frontmatter name differs from the directory name.
---

Body of dir-alias.
EOF

printf 'inv\nmanual-up\ndir-alias\n' > "$POOL/.active"
"$SKILL" sync > /dev/null 2>&1 || { echo "initial sync failed"; exit 1; }

echo "== empty allowlist =="
OUT=$("$SKILL" invocable)
if grep -qF "Allowlist empty" <<< "$OUT"; then ok "list: reports empty allowlist"; else no "list: reports empty allowlist (got: $OUT)"; fi
assert_contains "$CLAUDE_T/inv/SKILL.md" "disable-model-invocation: true" "baseline: inv is forced manual before allowlisting"

echo "== invocable on (appends MODEL_INVOCABLE to a config lacking it) =="
OUT=$("$SKILL" invocable inv on)
if grep -qF "Model-invocable: inv" <<< "$OUT"; then ok "on: reports success"; else no "on: reports success (got: $OUT)"; fi
assert_contains "$CONFIG" 'MODEL_INVOCABLE="inv"' "on: appends MODEL_INVOCABLE line to config"
assert_not_contains "$CLAUDE_T/inv/SKILL.md" "disable-model-invocation" "on: re-synced wrapper is model-invocable"

echo "== invocable on is idempotent =="
OUT=$("$SKILL" invocable inv on)
if grep -qF "Already model-invocable: inv" <<< "$OUT"; then ok "on: idempotent"; else no "on: idempotent (got: $OUT)"; fi
assert_contains "$CONFIG" 'MODEL_INVOCABLE="inv"' "on: repeat does not duplicate the entry"

echo "== second gate: upstream-manual skill warns and stays manual =="
OUT=$("$SKILL" invocable manual-up on)
if grep -qF "keeps it manual-only" <<< "$OUT"; then ok "on: warns when upstream forces manual"; else no "on: warns when upstream forces manual (got: $OUT)"; fi
assert_contains "$CONFIG" 'MODEL_INVOCABLE="inv manual-up"' "on: appends second entry"
assert_contains "$CLAUDE_T/manual-up/SKILL.md" "disable-model-invocation: true" "on: upstream's own key still passes through"

echo "== allowlist stores the frontmatter name, not the dir name =="
"$SKILL" invocable dir-alias on > /dev/null
assert_contains "$CONFIG" 'MODEL_INVOCABLE="inv manual-up fm-name"' "on: stores frontmatter name"
assert_not_contains "$CLAUDE_T/dir-alias/SKILL.md" "disable-model-invocation" "on: wrapper matched via frontmatter name"

echo "== list shows entries =="
OUT=$("$SKILL" invocable)
for n in inv manual-up fm-name; do
  if grep -qxF "$n" <<< "$OUT"; then ok "list: shows $n"; else no "list: shows $n (got: $OUT)"; fi
done

echo "== invocable off =="
OUT=$("$SKILL" invocable inv off)
if grep -qF "Manual-only: inv" <<< "$OUT"; then ok "off: reports success"; else no "off: reports success (got: $OUT)"; fi
assert_contains "$CONFIG" 'MODEL_INVOCABLE="manual-up fm-name"' "off: removes only the named entry"
assert_contains "$CLAUDE_T/inv/SKILL.md" "disable-model-invocation: true" "off: re-synced wrapper is forced manual again"

echo "== off accepts the pool dir name for an alias entry =="
"$SKILL" invocable dir-alias off > /dev/null
assert_contains "$CONFIG" 'MODEL_INVOCABLE="manual-up"' "off: dir name removes the frontmatter-name entry"

echo "== edge cases =="
OUT=$("$SKILL" invocable inv off)
if grep -qF "Not in allowlist: inv" <<< "$OUT"; then ok "off: no-op when absent"; else no "off: no-op when absent (got: $OUT)"; fi
if "$SKILL" invocable nope on > "$ROOT/nope.log" 2>&1; then
  no "on: rejects a skill not in the pool"
else
  grep -qF "Not in pool: nope" "$ROOT/nope.log" && ok "on: rejects a skill not in the pool" || no "on: rejects a skill not in the pool (wrong message)"
fi
if "$SKILL" invocable inv sideways > /dev/null 2>&1; then
  no "bad action exits nonzero"
else
  ok "bad action exits nonzero"
fi

echo ""
echo "== $pass passed, $fail failed =="
[[ "$fail" -eq 0 ]]
