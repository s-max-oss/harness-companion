# CLAUDE.md — Quick Reference for Claude Code

## Project Overview

[One-sentence summary of what this project is.]

## Build & Run

```bash
pip install -r requirements.txt   # Install dependencies
pytest                            # Run test suite
python -m <package>               # Run the app
```

## Quick Start

```bash
bash init.sh       # Full verification: install, test
```

## Key Files

| File | Purpose |
|------|---------|
| `src/` | Application source |
| `tests/` | Test suite |
| `feature_list.json` | Feature tracking with pass/fail status and evidence |

## Architecture Rules

- [Add your project's key rules here]

## How to Add a Feature

1. Add the business logic in `src/`.
2. Add tests in `tests/`.
3. Update `feature_list.json` with the result.
4. Verify with `bash init.sh`.

## Testing

```bash
pytest            # Run test suite
pytest -k <name>  # Run a subset by name
```
