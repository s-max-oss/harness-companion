# AGENTS.md — Agent Operating Manual (Documentation)

## Startup Rules

Before writing any code, complete these steps in order:

1. **Read this file completely.** It defines the boundaries and conventions for this project.
2. **Read `CLAUDE.md`** for the quick reference if using Claude Code.
3. **Read `feature_list.json`** to see the current state of all features.

## Project Context

[Replace with a short paragraph describing what this project documents.]

## Docs Hierarchy

The `docs/` directory is organized for agent readability:

```
docs/
  ARCHITECTURE.md   — System layers, data flow, component relationships
  PRODUCT.md        — Feature requirements and user-facing behavior
  RELIABILITY.md    — Logging, observability, clean state, benchmarking (optional)
```

When adding new content, update the relevant doc.

## Conventions

- Markdown throughout; keep headings hierarchical.
- [Add your project-specific conventions here]

## Definition of Done

A feature is "done" when:

1. The documentation renders correctly and links resolve.
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
