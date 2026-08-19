# Migration: rc6 Final Canonical Restoration (2026-08-19)

This is the **active** DWM-fixture migration. It restores the runtime
artifacts (`.harness/config.json`, `.harness/.template-snapshot.json`,
`.harness/PROJECT_BRIEF.json`) to the canonical pre-path(b) state and
re-binds the DWM fixture to that state. The full-suite verification
command (`bash tests/run-all.sh`) is the canonical evidence — there is no
ag-only substitution, no targeted replacement, no synthesized NDJSON.

It **supersedes** the 2026-08-17 record at
`docs/migrations/2026-08-17-rc6-final-contract-migration.json`. The 2026-08-17
record documents the earlier ag-only substitution at `7ba16e74`; its claimed
`new_sha256` values reflected the post-path(b) state which was subsequently
reverted by commits `8d363c4` / `e794483` / `6007c45`. The 2026-08-17 file
is preserved verbatim — its `applied=true` marker and recorded
`new_sha256` values are **not** modified, and historical truth is preserved
exactly. The migration test treats it as historical (schema-only
validation) and binds only the ACTIVE migration (this one, whose
`to_head == current HEAD`) against the current DWM fixture.

## Scope

Three tracked fixture entries change, and only these three:

| Path | Semantic change | Old SHA-256 | New SHA-256 | Size |
|------|-----------------|-------------|-------------|------|
| `.harness/config.json` | restored to canonical full-suite verification command (bash tests/run-all.sh, capability_level=2); ag-only substitution from 2026-08-17 reverted | `127e8342…d8d15f2` | `8ace6395…74a49a6` | 386 |
| `.harness/.template-snapshot.json` | regenerated so config.json sha + captured_from_git_rev match the canonical restored state | `8fa5eba3…2f375f17` | `973d1efb…2c9597e` | 1141 |
| `.harness/PROJECT_BRIEF.json` | regenerated so template_manifest_digest + captured_from_git_rev match the canonical restored snapshot | `2ba3a46a…6da9b8ce` | `81046beb…c53f351` | 6583 |

The historical 2026-08-17 record at
`docs/migrations/2026-08-17-rc6-final-contract-migration.json` is exempt
from this exclusion clause by design — it is a historical document, not
a pending migration.

## DWM fixture binding

The DWM fixture's recorded `sha256` for each of the three paths above MUST
equal the `new_sha256` in this migration. Post-migration drift (modifying
any of the three paths after apply) MUST produce a DWM `not_byte_equal`
violation.

## Test anchors (negative + positive)

- **positive exact** — All three old→new pairs match exactly AND no other
  fixture line drifts → apply succeeds.
- **negative extra path** — An unauthorized path change → apply fails.
- **negative mismatch** — Any old→new sha mismatch → apply fails.
- **negative reapply** — A second application after `applied=true` → apply
  fails.
- **negative post-migration drift** — Modifying any of the three paths after
  apply → DWM `not_byte_equal` violation.

The positive + post-migration-drift checks live in
`tests/release/test-rc6-final-migration.sh` and bind this record
byte-for-byte. The negative extra-path + mismatch + reapply checks remain
as in-script negative cases against this active migration.

## Test discipline (split in-run vs current-HEAD gate)

`tests/run-all.sh` includes both the migration test and the
acceptance-package-shape test. The acceptance-package-shape test uses
fixed synthetic fixtures (`mktemp`-based) and does NOT require the
current-HEAD final package to pre-exist.

The current-HEAD acceptance-package gate lives at
`scripts/acceptance/check-current-head-package.sh` and runs OUTSIDE
`tests/run-all.sh`. It runs only after a real canonical run has produced
a passing full-suite NDJSON. This split eliminates the circular
dependency where the full suite required its own evidence to exist
before running.