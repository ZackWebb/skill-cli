#!/usr/bin/env bash
# End-to-end tests for sync-skills.sh.
#
# Seam under test: running the sync command against a throwaway pool and
# throwaway targets, then inspecting the generated wrapper SKILL.md files.
# No internal function is called directly — only the observable file output.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SYNC="$SCRIPT_DIR/sync-skills.sh"

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

# assert_count <file> <regex> <expected-count> <description>
assert_count() {
  local n
  n=$(grep -cE -- "$2" "$1" || true)
  if [[ "$n" -eq "$3" ]]; then ok "$4"; else no "$4 (expected $3, got $n)"; fi
}

# Build an isolated environment: config + pool + targets under a tmp root.
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT

export XDG_CONFIG_HOME="$ROOT/config"
POOL="$ROOT/pool"
CLAUDE_T="$ROOT/claude"
CODEX_T="$ROOT/codex"
mkdir -p "$XDG_CONFIG_HOME/skill-cli" "$POOL"

cat > "$XDG_CONFIG_HOME/skill-cli/config.sh" << EOF
SKILLS_DIR="$POOL"
ACTIVE_FILE="$POOL/.active"
MODEL_INVOCABLE="allowed allowed-manual"
CLAUDE_TARGET="$CLAUDE_T"
CODEX_TARGET="$CODEX_T"
EOF

# --- Fixture 1: rich frontmatter, including an upstream disable-model-invocation
mkdir -p "$POOL/rich/reference" "$POOL/rich/scripts"
cat > "$POOL/rich/SKILL.md" << 'EOF'
---
name: rich
description: A rich skill with lots of frontmatter.
argument-hint: <thing>
allowed-tools: Read, Write
disable-model-invocation: false
metadata:
  author: someone
  version: 2
---

Body of the rich skill.
EOF
echo "ref content" > "$POOL/rich/reference/notes.md"
echo "script content" > "$POOL/rich/scripts/run.sh"
echo "top-level supporting file" > "$POOL/rich/helper.txt"

# --- Fixture 2: frontmatter with no name field
mkdir -p "$POOL/noname"
cat > "$POOL/noname/SKILL.md" << 'EOF'
---
description: Skill lacking a name key.
argument-hint: <x>
---

Body without a name field.
EOF

# --- Fixture 3: SKILL.md with no frontmatter at all
mkdir -p "$POOL/plain"
cat > "$POOL/plain/SKILL.md" << 'EOF'
This file has no frontmatter.
Just body text on two lines.
EOF

# --- Fixture 4: body contains shell metacharacters that must NOT be expanded
# or executed when the wrapper is written (heredoc / printf injection).
mkdir -p "$POOL/shellbody"
cat > "$POOL/shellbody/SKILL.md" << 'EOF'
---
name: shellbody
description: Body has shell syntax.
---

Run `$(touch PWNED)` and see ${HOME} and `date`.
EOF

# --- Fixture 5: frontmatter omits name, but the BODY has a name: line that
# must not be mistaken for the skill name.
mkdir -p "$POOL/bodyname"
cat > "$POOL/bodyname/SKILL.md" << 'EOF'
---
description: No name in frontmatter.
---

Example frontmatter field:
name: not-the-skill-name
EOF

# --- Fixture 6: named in MODEL_INVOCABLE, upstream model-invocable — the
# wrapper must NOT force disable-model-invocation.
mkdir -p "$POOL/allowed"
cat > "$POOL/allowed/SKILL.md" << 'EOF'
---
name: allowed
description: Skill allowed to stay model-invocable.
---

Body of the allowed skill.
EOF

# --- Fixture 7: named in MODEL_INVOCABLE, but upstream itself sets
# disable-model-invocation: true — upstream's own value must pass through.
mkdir -p "$POOL/allowed-manual"
cat > "$POOL/allowed-manual/SKILL.md" << 'EOF'
---
name: allowed-manual
description: Upstream user-invoked skill.
disable-model-invocation: true
---

Body of the allowed-manual skill.
EOF

printf 'rich\nnoname\nplain\nshellbody\nbodyname\nallowed\nallowed-manual\n' > "$POOL/.active"

echo "== running sync-skills.sh =="
"$SYNC" > "$ROOT/sync.log" 2>&1 || { echo "sync failed:"; cat "$ROOT/sync.log"; exit 1; }

CLAUDE_RICH="$CLAUDE_T/rich/SKILL.md"
CODEX_RICH="$CODEX_T/rich/SKILL.md"
CLAUDE_NONAME="$CLAUDE_T/noname/SKILL.md"
CLAUDE_PLAIN="$CLAUDE_T/plain/SKILL.md"
CODEX_PLAIN="$CODEX_T/plain/SKILL.md"

echo "== Claude target: rich frontmatter passthrough =="
assert_contains "$CLAUDE_RICH" "disable-model-invocation: true" "claude: appends disable-model-invocation: true"
assert_count "$CLAUDE_RICH" "^disable-model-invocation:" 1 "claude: only one disable-model-invocation line (deduped)"
assert_not_contains "$CLAUDE_RICH" "disable-model-invocation: false" "claude: strips upstream disable-model-invocation: false"
assert_contains "$CLAUDE_RICH" "description: A rich skill with lots of frontmatter." "claude: keeps real description"
assert_not_contains "$CLAUDE_RICH" "Manual only." "claude: does not blank the description"
assert_contains "$CLAUDE_RICH" "argument-hint: <thing>" "claude: preserves argument-hint"
assert_contains "$CLAUDE_RICH" "allowed-tools: Read, Write" "claude: preserves allowed-tools"
assert_contains "$CLAUDE_RICH" "  author: someone" "claude: preserves nested metadata map"
assert_contains "$CLAUDE_RICH" "name: rich" "claude: keeps name"
assert_contains "$CLAUDE_RICH" "Body of the rich skill." "claude: preserves body"

echo "== Claude target: name injection when upstream omits it =="
assert_contains "$CLAUDE_NONAME" "name: noname" "claude: injects name from dir when missing"
assert_contains "$CLAUDE_NONAME" "argument-hint: <x>" "claude: preserves other frontmatter when injecting name"
assert_contains "$CLAUDE_NONAME" "disable-model-invocation: true" "claude: appends disable-model-invocation on noname"

echo "== Claude target: no-frontmatter body preserved =="
assert_contains "$CLAUDE_PLAIN" "This file has no frontmatter." "claude: preserves body when no frontmatter"
assert_contains "$CLAUDE_PLAIN" "Just body text on two lines." "claude: preserves full body when no frontmatter"
assert_contains "$CLAUDE_PLAIN" "name: plain" "claude: injects name when no frontmatter"
assert_contains "$CLAUDE_PLAIN" "disable-model-invocation: true" "claude: appends disable-model-invocation when no frontmatter"

echo "== MODEL_INVOCABLE allowlist =="
CLAUDE_ALLOWED="$CLAUDE_T/allowed/SKILL.md"
CLAUDE_ALLOWED_MANUAL="$CLAUDE_T/allowed-manual/SKILL.md"
CODEX_ALLOWED="$CODEX_T/allowed/SKILL.md"
assert_not_contains "$CLAUDE_ALLOWED" "disable-model-invocation" "claude: allowlisted skill stays model-invocable"
assert_contains "$CLAUDE_ALLOWED" "description: Skill allowed to stay model-invocable." "claude: allowlisted skill keeps description"
assert_contains "$CLAUDE_ALLOWED" "Body of the allowed skill." "claude: allowlisted skill keeps body"
assert_contains "$CLAUDE_ALLOWED_MANUAL" "disable-model-invocation: true" "claude: allowlisted skill keeps upstream's own disable-model-invocation"
assert_count "$CLAUDE_ALLOWED_MANUAL" "^disable-model-invocation:" 1 "claude: upstream key passes through exactly once"
assert_contains "$CODEX_ALLOWED" "Manual only." "codex: allowlist does not affect neutered targets"

echo "== Codex target: neutered description behavior unchanged =="
assert_contains "$CODEX_RICH" "Manual only." "codex: keeps neutered description"
assert_not_contains "$CODEX_RICH" "disable-model-invocation" "codex: does not emit disable-model-invocation"
assert_not_contains "$CODEX_RICH" "argument-hint" "codex: drops extra frontmatter (spec-safe)"
assert_contains "$CODEX_RICH" "name: rich" "codex: keeps name"
assert_contains "$CODEX_PLAIN" "This file has no frontmatter." "codex: preserves body when no frontmatter"

echo "== shell metacharacters in body are written literally, not executed =="
[[ ! -e "$ROOT/PWNED" && ! -e "$CLAUDE_T/shellbody/PWNED" && ! -e "$PWD/PWNED" ]] \
  && ok "no command substitution executed during sync" \
  || no "command substitution from body executed during sync (PWNED created)"
assert_contains "$CODEX_T/shellbody/SKILL.md" '$(touch PWNED)' "codex: body \$() written literally"
assert_contains "$CODEX_T/shellbody/SKILL.md" '${HOME}' "codex: body \${HOME} written literally"
assert_contains "$CLAUDE_T/shellbody/SKILL.md" '$(touch PWNED)' "claude: body \$() written literally"

echo "== name is taken from frontmatter, not the body =="
# Inspect only the frontmatter block; the body legitimately still contains the
# decoy `name:` line.
BODYNAME_FM=$(awk '/^---$/{n++; next} n==1{print} n>=2{exit}' "$CLAUDE_T/bodyname/SKILL.md")
if grep -qxF "name: bodyname" <<< "$BODYNAME_FM"; then ok "claude: frontmatter name is the dir name"; else no "claude: frontmatter name is the dir name (got: $(grep '^name:' <<< "$BODYNAME_FM"))"; fi
if grep -qF "not-the-skill-name" <<< "$BODYNAME_FM"; then no "claude: frontmatter adopted body name: line"; else ok "claude: frontmatter ignores body name: line"; fi

echo "== supporting files symlinked (Claude target) =="
[[ -L "$CLAUDE_T/rich/reference" ]] && ok "claude: subdir 'reference' symlinked" || no "claude: subdir 'reference' symlinked"
[[ -L "$CLAUDE_T/rich/scripts" ]] && ok "claude: subdir 'scripts' symlinked" || no "claude: subdir 'scripts' symlinked"
[[ -L "$CLAUDE_T/rich/helper.txt" ]] && ok "claude: top-level file symlinked" || no "claude: top-level file symlinked"
[[ -L "$CLAUDE_T/rich/SKILL.md" ]] && no "claude: SKILL.md is a real file, not a symlink" || ok "claude: SKILL.md is a real file, not a symlink"

echo ""
echo "== $pass passed, $fail failed =="
[[ "$fail" -eq 0 ]]
