# AGENTS.md — Agent Operating Manual

## Startup Rules

Before writing any code, complete these steps in order:

1. **Read this file completely.** It defines the boundaries and conventions for this project.
2. **Read the design specs in `docs/superpowers/specs/`** — they are the product contract. `2026-08-04-harness-init-guided-onboarding.md` (frozen executor spec) and `2026-08-05-rc3-conversational-layer-addendum.md` (rc.3 conversational dialog layer) jointly define the v2.0.0-rc.3 deliverable.
3. **Run `bash init.sh`** to verify the project initializes cleanly. Exit codes:
   - `0` — all checks pass AND every Phase 1 start condition is met → "Ready to start work."
   - `1` — init/validator failure (syntax, config, run log, registry, status, WIP, staleness, snapshot/digest/immutable integrity). Fix the failure before continuing.
   - `2` — checks pass but Phase 1 start conditions are NOT met → NOT ready, fail-closed. Resolve the listed unmet conditions.
   `init.sh` fails closed: it never prints "Ready to start work." while any start condition is unmet. The master-clean start condition is verified via Git refs (local `master` == `origin/master`) — there is no `HARNESS_MASTER_CLEAN_CONFIRMED` shortcut; the GitHub pre-release keeps a separate manual in-session authorization gate.
4. **Read `feature_list.json`** to see the current state of all features.

## Project Context

`harness-companion` is a Bash-based skill that bootstraps a Harness environment
for any project. It is itself harness-managed (self-host): `.harness/` holds the
project's own Brief, config, snapshot, and evidence. The current round
(v2.0.0-rc.3) delivers guided conversational init as one closed loop: a
deterministic Bash executor (`scripts/harness-init.sh`) + an Agent dialog layer
(SKILL.md + reference files) + shell tests + forward eval + acceptance.

## Docs Hierarchy

The `docs/superpowers/specs/` directory is the design contract:

```
2026-08-04-harness-init-guided-onboarding.md    — frozen executor spec (Brief schema, output manifest)
2026-08-04-rc2-distribution-hardening.md        — rc.2 distribution hardening (shipped prerequisite)
2026-08-05-rc3-conversational-layer-addendum.md — rc.3 conversational dialog layer
```

## Layer Boundaries

- `core/lib/` — reusable libraries: `evidence.sh` (canonical NDJSON writer),
  `config-validate.sh` (config schema), `staleness.sh`, `workspace-fingerprint.sh`,
  `validate-run-log.sh`, `atomic_write.sh`, `project-detect.sh`.
- `core/` — CLI entry scripts: `harness-verify.sh`, `harness-feature.sh`,
  `harness-status.sh`, `harness-audit.sh`.
- `scripts/` — thin wrappers plus the executor `harness-init.sh` (F-CONV-06 extends it).
- `templates/` — output file templates used by the executor.
- `dsh/` — the only host runtime: launcher, installer, smoke, DSH references.
  Business semantics stay in `core/`; this layer only maps the host protocol.
- `tests/` — shell test suites (`tests/core/`, `tests/init/`, `tests/release/`,
  `tests/golden/`, `tests/fixtures/`).

## Conventions

- POSIX bash; scripts use `set -euo pipefail` unless there is a reason not to.
- **Single evidence architecture.** All verification evidence flows through the
  NDJSON run log (`core/lib/evidence.sh`). Never hand-craft NDJSON — always
  generate run logs via `core/harness-verify.sh`.
- **Schema validation is the repo's own validators.** `core/lib/config-validate.sh`
  for `.harness/config.json`, `core/lib/validate-run-log.sh` for run logs,
  `core/harness-feature.sh` for the feature state machine. A bare JSON parse is
  not a schema validation.
- `project_type` must be one of the validator whitelist (node|python|rust|go|docs|generic).
- Verification commands must be executable under real argv — globs expand only
  inside `bash -c`, never as a literal argument.
- **Repository isolation.** No writes to `~/.claude/`, `~/.agents/`, or local
  install paths. All work stays inside this repository.

## Definition of Done

A feature is "done" when:

1. Shell scripts parse and the relevant `tests/core/*.sh` suites pass.
2. The change is verified through `core/harness-verify.sh`, producing a valid
   NDJSON run log with `overall_result=passed`.
3. The feature appears in `feature_list.json` with status `"passing"` and an
   evidence association.
4. The independent Reviewer (per `.harness/PLAN.json`) has passed the phase.
5. Relevant specs/docs are updated.

## WIP=1 Rule

Work on exactly ONE feature at a time. Do not start a second feature until the
current one is verified and marked as `passing` in `feature_list.json`.

## Session Handoff

When finishing a session, update `claude-progress.md` with:
- What was accomplished
- What remains
- Any blockers or decisions made
- Files that were modified
