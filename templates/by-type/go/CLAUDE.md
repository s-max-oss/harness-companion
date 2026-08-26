# CLAUDE.md — Quick Reference for Claude Code

## Project Overview

[One-sentence summary of what this project is.]

## Build & Run

```bash
go build ./...   # Compile
go run ./cmd/... # Run
go test ./...    # Run test suite
go vet ./...     # Vet
```

## Quick Start

```bash
bash init.sh       # Full verification: build, test
```

## Key Files

| File | Purpose |
|------|---------|
| `cmd/` | Entry points |
| `internal/` | Application packages |
| `go.mod` | Module manifest |
| `feature_list.json` | Feature tracking with pass/fail status and evidence |

## Architecture Rules

- [Add your project's key rules here]

## How to Add a Feature

1. Add the business logic in `internal/`.
2. Add tests alongside the code (`_test.go`).
3. Update `feature_list.json` with the result.
4. Verify with `bash init.sh`.

## Testing

```bash
go test ./...         # Run test suite
go test ./... -run X  # Run a subset by name
```
