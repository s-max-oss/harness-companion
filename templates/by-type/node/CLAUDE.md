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
| `src/` | Application source |
| `feature_list.json` | Feature tracking with pass/fail status and evidence |

## Architecture Rules

- [Add your project's key rules here]

## How to Add a Feature

1. Add the business logic in `src/`.
2. Update `feature_list.json` with the result.
3. Verify with `bash init.sh`.

## Testing

```bash
npm test           # Run test suite
npm run test:watch # Run tests in watch mode
```
