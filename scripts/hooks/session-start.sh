#!/bin/bash
# v1 compat wrapper — forwards to new adapter path (Phase 4)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec bash "$SCRIPT_DIR/../../adapters/claude-code/hooks/$(basename "$0")" "$@"