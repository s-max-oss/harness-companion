#!/bin/bash
# install.sh — Top-level harness-companion installer
#
# Default behavior: install the Claude Code adapter (Phase 4 — Core/Adapter split).
# Use --codex to install the Codex adapter (Phase 5b) or --all to install both.
#
# Usage:
#   bash install.sh [--user|--project] [--codex|--all] [--symlink-core]
#
# --user            Install globally (default)
# --project         Install into the current project's .claude/
# --codex           Install the Codex adapter (default: Claude Code)
# --all             Install both adapters
# --symlink-core    Symlink core/ instead of copying (Linux/macOS only)
#
# All real work lives in adapters/<adapter>/install.sh. This dispatcher
# forwards arguments and reports a unified summary.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

ADAPTERS=("claude-code")
ADAPTERS_ARGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --user|--project|--symlink-core)
      ADAPTERS_ARGS+=("$1")
      shift
      ;;
    --codex)
      ADAPTERS=("codex")
      shift
      ;;
    --all)
      ADAPTERS=("claude-code" "codex")
      shift
      ;;
    --help|-h)
      sed -n '2,30p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

echo "=== harness-companion v2 installer ==="
echo "Adapters:   ${ADAPTERS[*]}"
echo "Args:       ${ADAPTERS_ARGS[*]:-<none>}"
echo ""

# Each adapter install.sh accepts different arguments; pass only those it accepts.
# --symlink-core is a Claude Code flag; Codex install.sh does not consume it.
for adapter in "${ADAPTERS[@]}"; do
  echo ""
  echo "── Installing adapter: $adapter ──"
  case "$adapter" in
    claude-code)
      exec_args=()
      for a in "${ADAPTERS_ARGS[@]}"; do
        case "$a" in
          --user|--project|--symlink-core) exec_args+=("$a") ;;
        esac
      done
      bash "$SCRIPT_DIR/adapters/claude-code/install.sh" "${exec_args[@]}"
      ;;
    codex)
      # Codex adapter is selected by --repo/--user semantics; default = --repo $(pwd).
      # If user passed --user at top level, forward --user to codex install.sh.
      # --project maps to --repo at codex layer.
      codex_args=()
      for a in "${ADAPTERS_ARGS[@]}"; do
        case "$a" in
          --user) codex_args+=("--user") ;;
          --project) codex_args+=("--repo" "$(pwd)") ;;
        esac
      done
      if [ ${#codex_args[@]} -eq 0 ]; then
        codex_args+=("--repo" "$(pwd)")
      fi
      bash "$SCRIPT_DIR/adapters/codex/install.sh" "${codex_args[@]}"
      ;;
  esac
done

echo ""
echo "=== All selected adapters installed ==="
echo ""
echo "Restart Claude Code / Codex to load the new hooks."