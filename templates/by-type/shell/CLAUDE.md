# CLAUDE.md — Quick Reference for Claude Code

## Project Overview

[One-sentence summary of what this project is.]

## Build & Run

```bash
make              # Build via Makefile
bash init.sh      # Verify the project initializes cleanly
```

## Key Files

| File | Purpose |
|------|---------|
| `*.sh` | Executable scripts |
| `Makefile` | Build automation |
| `feature_list.json` | Feature tracking with pass/fail status and evidence |

## Architecture Rules

- [Add your project's key rules here]

## How to Add a Feature

1. Add or modify the relevant script.
2. Update `feature_list.json` with the result.
3. Verify with `bash init.sh`.

## Testing

```bash
bash init.sh       # Run the project's verification commands
```
