# Codex plugin manifest (Phase 5a)

This is the Codex plugin manifest for `harness-companion`. Codex discovers
it at `<plugin_root>/.codex-plugin/plugin.json`.

**Phase 5a**: Codex CLI / `plugin-creator` scaffold not available in this
environment. The field set is the conservative minimal per design §5.1:

- `name` — string
- `version` — string (semver)
- `description` — string
- `author` — object (not a string; §5.1 explicitly requires object shape)

**Explicitly NOT included** (per §5.1):
- `hooks` — Codex discovers `hooks/hooks.json` by default at plugin root
- `platforms` — Codex infers from the manifest shape
- `requires_bash` — not part of canonical plugin.json

**Phase 5b**: regenerate from `plugin-creator` scaffold output and remove
any hand-invented fields beyond what the validator accepts. See
`docs/superpowers/plans/2026-08-01-harness-companion-phase5-codex.md`.
