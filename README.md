# skill-cli

A small CLI for managing agent skills: keep a single pool of skill sources, then
decide **where** each one is available — globally, or scoped to specific
projects — from one declarative config.

## Model

Four files under `~/.config/skill-cli/`:

| File | Purpose | Portable? |
|------|---------|-----------|
| `config.sh` | Machine knobs: pool location, sync targets, `MODEL_INVOCABLE` | per-machine |
| `groups.conf` | Named skill sets (no paths) — `name: skill skill …` | yes (commit it) |
| `assignments.conf` | The router: `scope<TAB>entries`, `scope` = `global` or an absolute path | per-machine |
| `last-targets` | Target paths the last sync wrote to, so a target later removed from `config.sh` can still be found and cleaned up | generated |

The **pool** (`SKILLS_DIR`, default `~/.local/skills/enabled`) holds symlinks to
skill sources. `assignments.conf` is the source of truth for what is active
where; `sync` materializes it:

- **global** → generated wrappers in every configured target: `CLAUDE_TARGET`,
  `CODEX_TARGET`, and `COPILOT_PLUGIN/skills`. Claude wrappers are forced
  manual-only (`disable-model-invocation: true`) unless the skill is on the
  `MODEL_INVOCABLE` allowlist, in which case upstream frontmatter — including
  its own `disable-model-invocation` — passes through untouched. Codex and
  Copilot get a `"Manual only."` description, except allowlisted skills on the
  Codex target, which are copied verbatim so they stay model-invocable there too.
- **project** (`<dir>`) → each skill is **symlinked** into `<dir>/.claude/skills/`
  and `<dir>/.agents/skills/`, so it inherits the source's own invocation flag
  and updates when the source changes. A per-skill `policy` override swaps a
  single entry for a generated wrapper; Codex has no `disable-model-invocation`
  equivalent, so on the `.agents` side only `manual` differs from `inherit`.

### Targets are per-machine

`config.sh` is the list of harnesses this machine writes to. Comment a target
out or set it to `""` and it is skipped everywhere — global *and* project scopes
— so no `.agents/skills` shows up in a repo on a Claude-only machine.

Every directory the CLI writes to carries a `.skill-cli-manifest` recording what
it placed there, and pruning only ever touches those entries. Skills you added
to a repo by hand, or another tool's skills in a shared `~/.agents/skills`, are
never removed. Disabling a target tears its managed entries down on the next
sync — Copilot also loses its `plugin.json`, so it stops loading an empty
plugin — while a directory with no manifest is not ours and is left alone.

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

Now a session in `~/dev/trade-calc` sees the 14 ML skills — in `.claude/skills`,
and in `.agents/skills` if `CODEX_TARGET` is set on this machine. Other projects
and the global scope are unaffected.

> **Scope note:** Claude Code has no per-agent skill allowlist. Directory scoping
> is the lever: skills in a repo's `.claude/skills` (and nested ones, loaded when
> Claude touches that subtree) are what "certain agents, not all" reduces to in
> practice. This CLI routes skills into those directories from one config.

## Tests

```bash
for t in test/*.test.sh; do "$t"; done
```
