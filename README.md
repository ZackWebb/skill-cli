# skill-cli

A small CLI for managing agent skills: keep a single pool of skill sources, then
decide **where** each one is available — globally, or scoped to specific
projects — from one declarative config.

## Model

Three files under `~/.config/skill-cli/`:

| File | Purpose | Portable? |
|------|---------|-----------|
| `config.sh` | Machine knobs: pool location, sync targets, `MODEL_INVOCABLE` | per-machine |
| `groups.conf` | Named skill sets (no paths) — `name: skill skill …` | yes (commit it) |
| `assignments.conf` | The router: `scope<TAB>entries`, `scope` = `global` or an absolute path | per-machine |

The **pool** (`SKILLS_DIR`, default `~/.local/skills/enabled`) holds symlinks to
skill sources. `assignments.conf` is the source of truth for what is active
where; `sync` materializes it:

- **global** → generated wrappers in `CLAUDE_TARGET` (and Codex/Copilot if set),
  forced manual-only (`disable-model-invocation: true`) unless the skill is on
  the `MODEL_INVOCABLE` allowlist. Historical behavior, unchanged.
- **project** (`<dir>`) → each skill is **symlinked** into `<dir>/.claude/skills/`,
  so it inherits the source's own invocation flag and updates when the source
  changes. A per-skill `policy` override swaps a single entry for a generated
  wrapper. A `.skill-cli-manifest` records what the CLI placed, so sync never
  removes skills you added to a repo by hand.

## Commands

```
# Global (available everywhere)
skill ls                        # pool, ● = active globally
skill on|off <name>             # (de)activate globally
skill add <path> | rm <name>    # manage the pool
skill invocable [<name> on|off] # global model-invocable allowlist

# Groups (portable named sets)
skill group ls | show <name>
skill group add <name> <skill...>
skill group rm  <name> [skill...]
skill import <catalog-or-dir>   # register a suite's workflows+categories as
                                # groups and stage its skills into the pool

# Project scoping  (--target: absent=global, bare/'.'=cwd, else a path)
skill assign   <skill|@group> [--target DIR]
skill unassign <skill|@group> [--target DIR]
skill policy   <skill> manual|invocable|inherit --target DIR
skill where                     # what applies to the current directory
skill sync [--target DIR|--all] # re-materialize one scope or everything
```

## Example

```bash
skill import ~/clones/probabl-ai/skills          # → @ml-experimentation, @methodology, …
skill assign @ml-experimentation --target ~/dev/trade-calc
skill policy python-api manual   --target ~/dev/trade-calc   # present but dormant here
```

Now a Claude session in `~/dev/trade-calc` sees the 14 ML skills in its
`.claude/skills`; other projects and the global scope are unaffected.

> **Scope note:** Claude Code has no per-agent skill allowlist. Directory scoping
> is the lever: skills in a repo's `.claude/skills` (and nested ones, loaded when
> Claude touches that subtree) are what "certain agents, not all" reduces to in
> practice. This CLI routes skills into those directories from one config.

## Tests

```bash
for t in test/*.test.sh; do "$t"; done
```
