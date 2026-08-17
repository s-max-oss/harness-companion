# Migration: rc6 Final Contract Migration (2026-08-17)

This is the **one and only** tracked DWM-fixture migration authorized as part
of the rc6 final remediation. It applies the path (b) timeout cap raise
(3600 → 7200) and tightens the runtime-manifest trust chain (Codex r6 final
blockers ① and ②). After this migration is applied, the new hashes re-freeze
the fixture; further drift on any path is a hard violation.

## Scope

Three tracked fixture entries change, and only these three:

| Path | Semantic change | Old SHA-256 | New SHA-256 | Size |
|------|-----------------|-------------|-------------|------|
| `.harness/config.json` | `timeout_seconds` 3600 → 7200 | `6f34581c…4cadfbc` | `8ace6395…74a49a6` | 386 |
| `.harness/.template-snapshot.json` | regenerated to reflect new contract | `9a50ac4b…419b556` | `8fa5eba3…2f375f17` | 1143 |
| `.harness/PROJECT_BRIEF.json` | regenerated to reflect new contract | `07b3ee77…3c3d842` | `2ba3a46a…6da9b8ce` | 6585 |

The concurrent code-side change — adding a genesis anchor to
`.harness/runtime-manifest.jsonl` — is **not** a fixture hash change (the
runtime-manifest is untracked runtime state). It is recorded separately in
the migration JSON under `concurrent_changes`.

## Test anchors (negative + positive)

- **positive exact** — All three old→new pairs match exactly AND no other
  fixture line drifts → apply succeeds.
- **negative extra path** — An unauthorized path change → apply fails.
- **negative mismatch** — Any old→new sha mismatch → apply fails.
- **negative reapply** — A second application after `applied=true` → apply
  fails.
- **negative post-migration drift** — Modifying any of the three paths after
  apply → DWM `not_byte_equal` violation.

The negative tests live in `tests/release/test-rc6-final-migration.sh` and
bind the JSON above byte-for-byte.
