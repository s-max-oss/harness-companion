# CLAUDE.md — Quick Reference for Claude Code

## Project Overview

[One-sentence summary of what this project is.]

## Build & Run

```bash
npm install        # Install dependencies
npm run check      # Type-check without emitting
npm run build      # Compile
npm run dev        # Build + launch
npm test           # Run test suite
```

## Quick Start

```bash
bash init.sh       # Full verification: install, check, build
```

## Key Files

| File | Purpose |
|------|---------|
| `src/main/` | Main process entry point |
| `src/preload/` | Context bridge API |
| `src/renderer/` | UI layer |
| `src/services/` | Business logic |
| `src/shared/types.ts` | Shared types and IPC channel constants |
| `feature_list.json` | Feature tracking with pass/fail status and evidence |

## Architecture Rules

- [Add your project's key rules here]
- Renderer never imports Node.js modules (Electron apps).
- All main-renderer communication goes through IPC (Electron apps).
- Services use constructor-injected dependencies.

## How to Add a Feature

1. Define types/interfaces.
2. Add the business logic in services.
3. Register IPC handlers (if Electron).
4. Expose the API through preload (if Electron).
5. Build the UI.
6. Update `feature_list.json` with the result.

## Testing

```bash
npm test           # Run test suite
npm run test:watch # Run tests in watch mode
```
