# CLAUDE.md — Quick Reference for Claude Code

## Project Overview

[One-sentence summary of what this project is.]

## Build & Run

```bash
cargo build       # Compile
cargo run         # Build + run
cargo test        # Run test suite
cargo clippy      # Lint
```

## Quick Start

```bash
bash init.sh       # Full verification: build, test
```

## Key Files

| File | Purpose |
|------|---------|
| `src/` | Application source |
| `Cargo.toml` | Build manifest and dependencies |
| `feature_list.json` | Feature tracking with pass/fail status and evidence |

## Architecture Rules

- [Add your project's key rules here]

## How to Add a Feature

1. Add the business logic in `src/`.
2. Add tests in `tests/` or `#[cfg(test)]` modules.
3. Update `feature_list.json` with the result.
4. Verify with `bash init.sh`.

## Testing

```bash
cargo test        # Run test suite
cargo test <name> # Run a subset by name
```
