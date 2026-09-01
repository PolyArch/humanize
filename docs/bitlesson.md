# Bitter Lesson Workflow

BitLesson is the repository's Bitter Lesson-style knowledge capture system for RLCR rounds.

## Configuration

The selector reads `bitlesson_model` from the merged config hierarchy:

1. `config/default_config.json`
2. `~/.config/humanize/config.json`
3. `.humanize/config.json`
4. CLI flags where applicable

Provider routing is automatic:

- `gpt-*`, `o[N]-*` (e.g. `o1-*`, `o3-*`, `o4-*`) route to Codex
- `claude-*`, `haiku`, `sonnet`, `opus` route to Claude

If the configured provider binary is missing, the selector falls back to the default Codex model so the loop can still proceed.

On Codex-only installs, Humanize writes `provider_mode: "codex-only"` into the user config.
When that mode is present, the selector forces BitLesson selection onto the Codex/OpenAI path
before provider resolution, even if an older default such as `haiku` would otherwise route to Claude.

## Workflow

Each project keeps its BitLesson knowledge base at `.humanize/bitlesson.md`.

When `start-rlcr-loop` begins:

1. The file is initialized from `templates/bitlesson.md` if it does not already exist
2. Each task or sub-task runs through `scripts/bitlesson-select.sh`
3. The selected lesson IDs are applied during implementation, or `NONE` is recorded when nothing matches
4. The stop gate validates a required `## BitLesson Delta` section in every round summary

## Summary Contract

Required summary shape:

```markdown
## BitLesson Delta
- Action: none|add|update|deprecate
- Lesson ID(s): <IDs or NONE>
- Notes: <what changed and why>
```

Validation rules are strict:

- `Action: none` must use `Lesson ID(s): NONE` or leave the field empty
- `Action: add`, `Action: update`, and `Action: deprecate` must reference concrete `BL-YYYYMMDD-short-name` IDs that exist in `.humanize/bitlesson.md`
- `--require-bitlesson-entry-for-none` can be used to block empty knowledge bases from repeatedly reporting `none`

## Deprecating lessons

The knowledge base would otherwise only grow: when a subsystem is removed or a lesson is
superseded, the entry becomes misleading but there is no contracted way to retire it.
`Action: deprecate` fills that gap. Deprecation is a **tombstone, not a delete**:

- Keep the entry (so its ID still resolves and the history is preserved) and add a
  `Status: deprecated — <reason / superseded by BL-…>` line to it.
- The selector (`scripts/bitlesson-select.sh`) treats any entry with a `Status: deprecated`
  line as retired and never selects it for a sub-task.

## Staleness check

Lesson *content* (the bug→fix knowledge) usually stays valid across refactors, but the
*references* it cites (`Scope:` paths, `path/to/file.py`, `dir:line`) drift when code moves.
The stop gate validates Delta *format* only — it does not re-check that existing lessons still
point at real files — so after a reorg a lesson can silently rot and a rotted lesson handed to
an implementer is worse than none.

`scripts/bitlesson-staleness.sh` scans the knowledge base and reports entries whose cited
paths no longer resolve under the project root:

```bash
scripts/bitlesson-staleness.sh --bitlesson-file .humanize/bitlesson.md
# add --strict to exit non-zero when any entry has unresolved references
```

It is **advisory by default** (exit 0). Deprecated entries are skipped. Path detection is
heuristic: it checks slash-bearing paths against the project root and bare filenames
(e.g. `run_infer.py`) anywhere under the root, and ignores glob/brace tokens and illustrative
snippets it cannot resolve. Use it at loop start (or periodically) to find entries that need an
`update` (fix the references) or a `deprecate`.
