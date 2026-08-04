#!/bin/bash
# uninstall.sh — Top-level dispatcher for harness-companion uninstall
#
# Usage:
#   bash uninstall.sh [--user|--project] [--codex|--claude|--all]
#
# Modes:
#   --claude  (default): Run adapters/claude-code/uninstall.sh
#   --codex:             Run adapters/codex/uninstall.sh
#   --all:               Run both adapters' uninstallers
#
# Adapter flags (passed through):
#   --user:    Uninstall from user global location (default)
#   --project: Uninstall from project-local location

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"

ADAPTER="claude"
MODE="--user"

for arg in "$@"; do
  case "$arg" in
    --codex)  ADAPTER="codex" ;;
    --claude) ADAPTER="claude" ;;
    --all)    ADAPTER="all" ;;
    --user)   MODE="--user" ;;
    --project) MODE="--project" ;;
    --help|-h)
      echo "Usage: bash uninstall.sh [--user|--project] [--codex|--claude|--all]"
      echo ""
      echo "  --claude   Uninstall Claude Code adapter (default)"
      echo "  --codex    Uninstall Codex adapter"
      echo "  --all      Uninstall both adapters"
      echo "  --user     User global install (default)"
      echo "  --project  Project-local install"
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

echo "=== harness-companion uninstall ==="
echo ""

RC=0
case "$ADAPTER" in
  claude)
    bash "$REPO_ROOT/adapters/claude-code/uninstall.sh" "$MODE" || RC=$?
    ;;
  codex)
    bash "$REPO_ROOT/adapters/codex/uninstall.sh" "$MODE" || RC=$?
    ;;
  all)
    bash "$REPO_ROOT/adapters/claude-code/uninstall.sh" "$MODE" || RC=$?
    bash "$REPO_ROOT/adapters/codex/uninstall.sh" "$MODE" || RC=$?
    ;;
esac

exit "$RC"