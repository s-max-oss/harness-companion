# AGENTS.md — Agent Operating Manual (Shell)

## Startup Rules

Before writing any code, complete these steps in order:

1. **Read this file completely.** It defines the boundaries and conventions for this project.
2. **Read `CLAUDE.md`** for the quick reference if using Claude Code.
3. **Run `bash init.sh`** to verify the project builds and initializes cleanly.
4. **Read `feature_list.json`** to see the current state of all features.

## Project Context

[Replace with a short paragraph describing what this project is and its key characteristics.]

## Layout

- `*.sh` — executable scripts.
- `Makefile` / `*.mk` — build and task automation.

## Conventions

- `set -euo pipefail` in every script.
- Prefer POSIX-compatible constructs; test with `bash`.
- [Add your project-specific conventions here]

## Definition of Done

A feature is "done" when:

1. The scripts run cleanly (`bash init.sh`).
2. The feature appears in `feature_list.json` with status `"passing"` and evidence.
3. Relevant docs are updated.

## WIP=1 Rule

Work on exactly ONE feature at a time. Do not start a second feature until the current one is verified and marked as `passing` in `feature_list.json`.

## Session Handoff

When finishing a session, update `claude-progress.md` with:
- What was accomplished
- What remains
- Any blockers or decisions made
- Files that were modified
