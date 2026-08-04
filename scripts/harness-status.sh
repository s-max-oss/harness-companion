#!/bin/bash
# v1 compat wrapper — forwards to new core path (Phase 4)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec bash "$SCRIPT_DIR/../core/$(basename "$0")" "$@"