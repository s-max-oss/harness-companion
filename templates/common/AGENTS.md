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

[Describe the architectural layers of your project. For a type-specific
breakdown (build entry points, module layout, IPC/UI boundaries), see the
matching `by-type/<type>/AGENTS.md` override.]

## Conventions

- [Add your project-specific conventions here]

## Definition of Done

A feature is "done" when:

1. The project builds and functions correctly.
2. All tests pass.
3. The feature appears in `feature_list.json` with status `"passing"` and evidence.
4. The code respects the layer boundaries above.
5. Relevant docs are updated.

## WIP=1 Rule

Work on exactly ONE feature at a time. Do not start a second feature until the current one is verified and marked as `passing` in `feature_list.json`.

## Session Handoff

When finishing a session, update `claude-progress.md` with:
- What was accomplished
- What remains
- Any blockers or decisions made
- Files that were modified
