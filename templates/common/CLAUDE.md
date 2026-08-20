# CLAUDE.md — Quick Reference for Claude Code

## Project Overview

[One-sentence summary of what this project is.]

## Build & Run

```bash
bash init.sh       # Verify the project builds and initializes cleanly
```

## Quick Start

```bash
bash init.sh       # Full verification
```

## Key Files

| File | Purpose |
|------|---------|
| `feature_list.json` | Feature tracking with pass/fail status and evidence |

## Architecture Rules

- [Add your project's key rules here]

## How to Add a Feature

1. Design the change against the project spec.
2. Add the feature to `feature_list.json` with `status: "not_started"`.
3. Implement the feature (one at a time).
4. Verify with `bash init.sh`.
5. Mark the feature `"passing"` in `feature_list.json`.

## Testing

```bash
bash init.sh       # Run the project's verification commands
```
