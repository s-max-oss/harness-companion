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
#   --project: Uninstall from project-local location (Claude Code only;
#              for Codex, --project maps to --repo $(pwd))

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"

ADAPTER="claude"
MODE="--user"
EXTRA_CODEX_ARGS=()  # extra positional args for Codex uninstall (e.g. --repo target)

# Parse: collect extras as we see --repo <path> for codex adapter
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
      echo ""
      echo "Note: Codex adapter uses different flags internally:"
      echo "  bash adapters/codex/uninstall.sh --repo [path]"
      echo "  bash adapters/codex/uninstall.sh --user"
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

# Map MODE → adapter-specific flags
# Claude Code: --user / --project
# Codex: --user or --repo $(pwd) for project mode
claude_args=("$MODE")
case "$MODE" in
  --project)
    codex_args=("--repo" "$(pwd)")
    ;;
  --user)
    codex_args=("--user")
    ;;
esac

RC=0
case "$ADAPTER" in
  claude)
    bash "$REPO_ROOT/adapters/claude-code/uninstall.sh" "${claude_args[@]}" || RC=$?
    ;;
  codex)
    bash "$REPO_ROOT/adapters/codex/uninstall.sh" "${codex_args[@]}" || RC=$?
    ;;
  all)
    bash "$REPO_ROOT/adapters/claude-code/uninstall.sh" "${claude_args[@]}" || RC=$?
    bash "$REPO_ROOT/adapters/codex/uninstall.sh" "${codex_args[@]}" || RC=$?
    ;;
esac

exit "$RC"