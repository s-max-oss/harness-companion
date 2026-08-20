# AGENTS.md — Agent Operating Manual (Node.js)

## Startup Rules

Before writing any code, complete these steps in order:

1. **Read this file completely.** It defines the boundaries and conventions for this project.
2. **Read `CLAUDE.md`** for the quick reference if using Claude Code.
3. **Read `docs/ARCHITECTURE.md`** (if present) to understand the system structure.
4. **Run `bash init.sh`** to verify the project builds and initializes cleanly.
5. **Read `feature_list.json`** to see the current state of all features.

## Project Context

[Replace with a short paragraph describing what this project is and its key characteristics.]

## Layer Boundaries

[Describe the architectural layers of your project. Common Node.js layers:]

### Services (`src/services/`)
- Pure business logic.
- Constructor-injected dependencies for testability.

### Entry points (`src/index.ts` / `src/main/`)
- Process bootstrap, configuration loading, server startup.

## Conventions

- TypeScript strict mode. No `any` without a comment explaining why.
- Named exports only.
- `npm` is the package manager; do not introduce a second one.
- [Add your project-specific conventions here]

## Definition of Done

A feature is "done" when:

1. TypeScript compiles without errors (`npx tsc --noEmit`).
2. All tests pass (`npm test`).
3. The feature appears in `feature_list.json` with status `"passing"` and evidence.
4. The code respects layer boundaries.
5. Relevant docs are updated.

## WIP=1 Rule

Work on exactly ONE feature at a time. Do not start a second feature until the current one is verified and marked as `passing` in `feature_list.json`.

## Session Handoff

When finishing a session, update `claude-progress.md` with:
- What was accomplished
- What remains
- Any blockers or decisions made
- Files that were modified
