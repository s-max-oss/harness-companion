# AGENTS.md — Codex knowledge entry (Phase 5)
#
# This is the Codex-specific knowledge entry. Codex reads AGENTS.md as its
# default knowledge file (Claude Code reads CLAUDE.md). The content mirrors
# the core Harness Engineering invariants; adapter-specific tokens
# (commands, paths) are Codex-targeted.

# Harness Engineering — Codex Operating Manual

This project uses the **harness-companion** v2 skill (Phase 5: Codex adapter).
The skill enforces a project-local contract for AI-assisted engineering work.

## Startup Rules

1. Read this file and `codex-progress.md` before any action.
2. Honor the WIP limit: at most **1 feature in `in_progress`** at any time.
3. Never mark a feature `passing` without an evidence association pointing
   at a canonically valid run log (NDJSON schema v2).
4. Use `core/harness-verify.sh` to produce evidence. Do not hand-craft
   `run_id`s or fingerprints.

## Definition of Done

A feature is **Done** when:
- its evidence association points at an NDJSON where:
  - `validate_run_log` returns `valid: true`
  - `terminal.overall_result == "passed"`
  - all 3 staleness probes return false (fingerprint, config, VCS revision)
- `feature_list.json` `.revision` is incremented
- `codex-progress.md` records the change in the session log

## Codex Hook Surface

| Hook | Trigger | Behavior (Phase 5a) |
|------|---------|---------------------|
| `SessionStart` | session begin | fail-open (empty stdout) — schema unconfirmed |
| `Stop` | session end | fail-open (empty stdout) — schema unconfirmed |
| `PreToolUse` | before each tool | fail-open (empty stdout) — schema unconfirmed |

Phase 5b will replace fail-open with confirmed-schema output once Codex CLI
research produces `docs/superpowers/research/codex-hook-schemas.md`.

## Slash Commands

- `/harness:status` — read-only status snapshot via core/harness-status.sh
- `/harness:feature add <id> <title>` — register a new feature
- `/harness:verify <feature_id>` — produce evidence association
- `/harness:audit` — 5-axis subsystem audit
