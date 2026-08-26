# CLAUDE.md — Quick Reference for Claude Code

## Project Overview

A Bash-based skill that bootstraps a Harness environment (Brief, config, feature
registry, evidence) for any project, driven by guided conversational init.

## Build & Run

```bash
bash init.sh                                    # Verify the project initializes cleanly
bash core/harness-status.sh                     # Show harness status
bash core/harness-verify.sh <feature_id> .      # Verify a feature (add --write to associate)
```

`bash init.sh` exit codes: `0` = checks pass AND all Phase 1 start conditions met ("Ready to start work."); `1` = init/validator failure (config, run log, registry, status, WIP, staleness, snapshot/digest/immutable integrity); `2` = checks pass but Phase 1 start conditions NOT met (fail-closed). Master-clean is verified via Git refs (local `master` == `origin/master`) — there is no `HARNESS_MASTER_CLEAN_CONFIRMED` env shortcut; the GitHub pre-release keeps a separate manual in-session authorization gate.

## Key Files

| File | Purpose |
|------|---------|
| `core/lib/evidence.sh` | Canonical NDJSON evidence writer |
| `core/lib/config-validate.sh` | Schema validator for `.harness/config.json` |
| `core/lib/validate-run-log.sh` | Schema validator for NDJSON run logs |
| `core/harness-verify.sh` | Verification runner (real-argv commands, NDJSON run log) |
| `core/harness-feature.sh` | Feature state machine (WIP=1) |
| `scripts/harness-init.sh` | Init executor (F-CONV-06 extends it for rc.3) |
| `.harness/config.json` | Project verification config |
| `.harness/PROJECT_BRIEF.json` | Canonical project configuration (advisory) |
| `feature_list.json` | Feature tracking with status and evidence |
| `docs/superpowers/specs/` | Design specs (frozen executor + rc.3 addendum) |

## Architecture Rules

- Never hand-craft NDJSON run logs — generate them via `core/harness-verify.sh`.
- Verification commands must run under real argv (globs expand only inside `bash -c`).
- `project_type` must be one of node|python|rust|go|docs|generic.
- Zero writes to `~/.claude/`, `~/.agents/`, or local install paths.
- `PROJECT_BRIEF.json` is advisory; current-session user instructions take precedence.

## How to Add a Feature

1. Design it against the frozen specs in `docs/superpowers/specs/`.
2. Add the feature to `feature_list.json` with `status: "not_started"`.
3. Implement it (WIP=1 — one feature at a time).
4. Verify with `bash core/harness-verify.sh <feature_id> . --write`.
5. Mark passing via `bash core/harness-feature.sh status . <feature_id> passing`.

## Testing

```bash
bash init.sh                             # project init check
bash tests/core/test-r4-contracts.sh     # config schema contracts
bash tests/core/test-r5-glob.sh          # glob handling under real argv
bash tests/core/test-validate-run-log.sh # run-log validation
bash tests/core/test-harness-feature.sh  # feature state machine
```
