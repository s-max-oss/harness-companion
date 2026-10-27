# AGENTS.md — Agent Operating Manual

## Startup Rules

Before writing any code, complete these steps in order:

1. **Read this file completely.** It defines the boundaries and conventions for this project.
2. **Read the current contract:** `SKILL.md`, `references/`, and the newest package in `docs/acceptance/`. The specs under `docs/superpowers/specs/` are historical design records (multi-host rc.3); consult them for traceability, not as runtime requirements.
3. **Run `bash init.sh`** to verify the project initializes cleanly. Exit codes:
   - `0` — all checks pass AND every Phase 1 start condition is met → "Ready to start work."
   - `1` — init/validator failure (syntax, config, run log, registry, status, WIP, staleness, snapshot/digest/immutable integrity). Fix the failure before continuing.
   - `2` — checks pass but Phase 1 start conditions are NOT met → NOT ready, fail-closed. Resolve the listed unmet conditions.
   `init.sh` fails closed: it never prints "Ready to start work." while any start condition is unmet. The master-clean start condition is verified via Git refs (local `master` == `origin/master`) — there is no `HARNESS_MASTER_CLEAN_CONFIRMED` shortcut; the GitHub pre-release keeps a separate manual in-session authorization gate.
4. **Read `feature_list.json`** to see the current state of all features.

## Project Context

`harness-companion` is a Bash-based skill that bootstraps a Harness environment
for any project. It is itself harness-managed (self-host): `.harness/` holds the
project's Brief, config, snapshot, and evidence, and the tracked harness state
(`feature_list.json`, `claude-progress.md`, `.harness/config.json`,
`.harness/PROJECT_BRIEF.*`, `.harness/.template-snapshot.json`, `.harness/PLAN.json`,
`.harness/reviews/`) is versioned with the code. Runtime artifacts
(`.harness/logs/`, `.harness/acceptance/`, runtime manifests, the registry
journal) are ignored.

As of v2.0.0 the repository ships a **DSH-only** skill. The retired Codex
real-Agent evaluation is replaced by `dsh/acceptance.ps1` (seven scenarios,
NDJSON evidence) plus `docs/acceptance/`. Guided conversational init remains the
core workflow: a deterministic Bash executor (`scripts/harness-init.sh`) plus an
Agent dialog layer (`SKILL.md` + reference files).

## Docs Hierarchy

The current contract lives in `SKILL.md`, `references/`, and
`docs/acceptance/`. The `docs/superpowers/specs/` directory is **historical**: it
records the multi-host rc.3 design and is kept for traceability, not as a
requirement for the DSH-only runtime.

```
docs/superpowers/specs/2026-08-04-harness-init-guided-onboarding.md    — frozen executor spec
docs/superpowers/specs/2026-08-04-rc2-distribution-hardening.md        — rc.2 hardening
docs/superpowers/specs/2026-08-05-rc3-conversational-layer-addendum.md — rc.3 dialog layer
docs/acceptance/2026-10-27-dsh-2.0.0.md                                — current acceptance package
```

## Layer Boundaries

- `core/lib/` — reusable libraries: `evidence.sh` (canonical NDJSON writer),
  `config-validate.sh` (config schema), `staleness.sh`, `workspace-fingerprint.sh`,
  `validate-run-log.sh`, `atomic_write.sh`, `project-detect.sh`.
- `core/` — CLI entry scripts: `harness-verify.sh`, `harness-feature.sh`,
  `harness-status.sh`, `harness-audit.sh`.
- `scripts/` — thin wrappers plus the executor `harness-init.sh` (F-CONV-06 extends it).
- `templates/` — output file templates used by the executor.
- `dsh/` — the only host runtime: launcher, installer, smoke, acceptance, DSH
  references. Business semantics stay in `core/`; this layer only maps the host
  protocol.
- `tests/` — shell test suites (`tests/core/`, `tests/bootstrap/`, `tests/init/`,
  `tests/release/`, `tests/golden/`, `tests/fixtures/`) and committed acceptance
  evidence (`tests/acceptance/evidence/`).

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
- **Repository isolation.** Source work stays inside this repository. The
  installers (`dsh/install.ps1`) write to `%DSH_HOME%\skills` only when the user
  runs them explicitly; no session should write to `~/.claude/` or `~/.agents/`.

## Definition of Done

A feature is "done" when:

1. Shell scripts parse and the relevant `tests/core/*.sh` suites pass.
2. Host-facing behavior is covered by `dsh/acceptance.ps1` when the feature
   changes an entry-point behavior.
3. The change is verified through `core/harness-verify.sh`, producing a valid
   NDJSON run log with `overall_result=passed`.
4. The feature appears in `feature_list.json` with status `"passing"` and an
   evidence association.
5. The independent Reviewer (per `.harness/PLAN.json`) has passed the phase.
6. Relevant specs/docs are updated.

## WIP=1 Rule

Work on exactly ONE feature at a time. Do not start a second feature until the
current one is verified and marked as `passing` in `feature_list.json`.

## Session Handoff

When finishing a session, update `claude-progress.md` with:
- What was accomplished
- What remains
- Any blockers or decisions made
- Files that were modified
