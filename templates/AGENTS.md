# AGENTS.md — Agent Operating Manual

## Startup Rules

Before writing any code, complete these steps in order:

1. **Read this file completely.** It defines the boundaries and conventions for this project.
2. **Read `CLAUDE.md`** for the quick reference if using Claude Code.
3. **Read `docs/ARCHITECTURE.md`** (if present) to understand the system structure.
4. **Read `docs/PRODUCT.md`** (if present) to understand feature requirements.
5. **Run `bash init.sh`** to verify the project builds and initializes cleanly.
6. **Read `feature_list.json`** to see the current state of all features.

## Project Context

[Replace with a short paragraph describing what this project is and its key characteristics.]

## Docs Hierarchy

When present, the `docs/` directory is organized for agent readability:

```
docs/
  ARCHITECTURE.md   — System layers, data flow, component relationships
  PRODUCT.md        — Feature requirements and user-facing behavior
  RELIABILITY.md    — Logging, observability, clean state, benchmarking (optional)
```

When adding new features, update the relevant doc before writing code.

## Layer Boundaries

[Describe the architectural layers of your project. For Electron apps:]

### Main Process (`src/main/`)
- Owns window lifecycle and IPC registration.
- All filesystem access happens here via services.

### Preload (`src/preload/`)
- The ONLY bridge between main and renderer.
- Uses `contextBridge.exposeInMainWorld` to expose typed APIs.

### Renderer (`src/renderer/`)
- UI layer.
- Communicates exclusively through the preload bridge.
- Never imports Node.js modules.

### Services (`src/services/`)
- Pure business logic.
- Constructor-injected dependencies for testability.

## Conventions

- TypeScript strict mode. No `any` without a comment explaining why.
- Named exports only.
- [Add your project-specific conventions here]

## Definition of Done

A feature is "done" when:

1. TypeScript compiles without errors.
2. The app launches and functions correctly.
3. All tests pass (`npm test`).
4. The feature appears in `feature_list.json` with status `"passing"` and evidence.
5. The code respects layer boundaries.
6. Relevant docs are updated.

## WIP=1 Rule

Work on exactly ONE feature at a time. Do not start a second feature until the current one is verified and marked as `passing` in `feature_list.json`.

## Session Handoff

When finishing a session, update `claude-progress.md` with:
- What was accomplished
- What remains
- Any blockers or decisions made
- Files that were modified
