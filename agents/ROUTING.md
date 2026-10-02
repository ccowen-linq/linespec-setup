# Provenance-repo subagents

The six subagents in `~/.claude/agents/` — `navigator`, `record-author`,
`spec-author`, `generator-author`, `code-author`, `tuner` — are for repos that
use LineSpec (`.linespec.yml`), provenance records (`provenance/`), or Sedum
generators (`generators/`).

**Any one of those three marks a matching repo.** Check the repo root for
`.linespec.yml`, `provenance/` and `generators/` before starting work; if any
exists, use the subagents. A provenance plugin hook firing (session start, or
editing a provenance-governed file) is the same signal.

Which roles apply depends on what is present:

- **`provenance/` or `.linespec.yml`, no `generators/`** — `navigator`,
  `record-author`, `spec-author` and `code-author` apply. `code-author` is
  gated by the open record's `affected_scope` alone. `tuner` triages record /
  spec / code. Don't dispatch `generator-author`; it is Sedum-only. Keep the
  order: a record first, specs that judge it, then the code, committed with the
  record ID.
- **`generators/` present** — all six apply, with `code-author` limited to
  paths Sedum does not generate.

When a repo matches, dispatch to a subagent instead of working solo:

1. **The task already fits one role** — e.g. "diagnose this failure" is
   `tuner`, "write the record for X" is `record-author` — dispatch straight to
   it.
2. **It's broader or unclear which stage applies** — including "where were we"
   or "what's next" — start with `navigator`; it reads the provenance board and
   dispatches the stage that acts.
3. **It fits none of the roles** — say so, then do it yourself.

Don't use these in a repo with none of the three markers; they assume
`linespec` / `sedum` CLI commands and directory conventions that won't exist
there.
