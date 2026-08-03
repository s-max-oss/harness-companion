#!/bin/bash
# adapters/codex/uninstall.sh — Uninstall Codex adapter (Phase 5)
#
# Three modes matching install.sh. MUST NOT auto-edit content this script
# did not create (e.g. ~/.codex/config.toml).
#
# Usage:
#   bash adapters/codex/uninstall.sh                 # plugin: print instructions
#   bash adapters/codex/uninstall.sh --repo [path]   # repo-local cleanup
#   bash adapters/codex/uninstall.sh --user          # user: print manual removal

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

MODE=""
REPO_TARGET=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)
      MODE="--repo"
      shift
      if [ $# -gt 0 ] && [[ "$1" != --* ]]; then
        REPO_TARGET="${1:-}"
        shift
      fi
      ;;
    --user) MODE="--user"; shift ;;
    --help|-h) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

# ---- Plugin mode (default) -----------------------------------------------------
if [ -z "$MODE" ]; then
  echo "=== Harness Companion Uninstall (Phase 5 — Codex adapter) ==="
  echo ""
  echo "Plugin mode: uninstall via Codex marketplace."
  echo "  Run: codex plugin uninstall harness-companion"
  echo ""
  echo "This script did NOT install the plugin and will NOT remove plugin files."
  echo "For repo-local cleanup, use --repo <project-dir>."
  echo "For user-mode snippet removal, use --user (prints manual instructions)."
  exit 0
fi

# ---- Repo-local mode (--repo [path]) ------------------------------------------
if [ "$MODE" = "--repo" ]; then
  TARGET="${REPO_TARGET:-$(pwd)}"
  TARGET="$(cd "$TARGET" && pwd 2>/dev/null || { echo "Error: --repo target '$REPO_TARGET' not a directory" >&2; exit 1; })"
  CODEX_DIR="$TARGET/.codex"
  HOOKS_JSON="$CODEX_DIR/hooks.json"

  echo "=== Harness Companion Uninstall (Phase 5 — Codex adapter) ==="
  echo ""
  echo "Mode:       --repo"
  echo "Target:     $CODEX_DIR"
  echo ""

  if [ ! -d "$CODEX_DIR" ]; then
    echo "  nothing to remove (no .codex/ in $TARGET)"
    exit 0
  fi

  # Remove hooks.json only if it points at our hooks (avoid touching other tools).
  if [ -f "$HOOKS_JSON" ]; then
    if grep -qF "adapters/codex/hooks/" "$HOOKS_JSON" 2>/dev/null; then
      rm -f "$HOOKS_JSON"
      echo "  removed: $HOOKS_JSON"
      # Restore latest backup if present. Use find (not ls glob) to survive
      # under set -euo pipefail when no backup exists.
      latest_bak=""
      for cand in "${HOOKS_JSON}".bak.*; do
        if [ -f "$cand" ]; then
          if [ -z "$latest_bak" ] || [ "$cand" -nt "$latest_bak" ]; then
            latest_bak="$cand"
          fi
        fi
      done
      if [ -n "$latest_bak" ] && [ -f "$latest_bak" ]; then
        cp -p "$latest_bak" "$HOOKS_JSON"
        echo "  restored backup: $latest_bak"
      fi
    else
      echo "  hooks.json does not reference adapters/codex — left untouched"
    fi
  fi

  # Remove harness-companion adapter subtree and core/.
  if [ -d "$CODEX_DIR/adapters/codex" ]; then
    rm -rf "$CODEX_DIR/adapters/codex"
    echo "  removed: $CODEX_DIR/adapters/codex/"
  fi
  if [ -d "$CODEX_DIR/core" ]; then
    rm -rf "$CODEX_DIR/core"
    echo "  removed: $CODEX_DIR/core/"
  fi

  echo ""
  echo "=== Repo-local uninstall complete ==="
  exit 0
fi

# ---- User mode (--user) -------------------------------------------------------
if [ "$MODE" = "--user" ]; then
  USER_CODEX="${HOME}/.codex"
  SNIPPET="$USER_CODEX/harness-hooks.toml"

  echo "=== Harness Companion Uninstall (Phase 5 — Codex adapter) ==="
  echo ""
  echo "Mode:  --user"
  echo ""
  echo "Manual removal steps (this script does NOT auto-edit config.toml):"
  echo "  1. Edit ~/.codex/config.toml"
  echo "  2. Remove these blocks:"
  echo "     [[hooks.SessionStart]]"
  echo "     [[hooks.SessionStart.hooks]]"
  echo "     [[hooks.Stop]]"
  echo "     [[hooks.Stop.hooks]]"
  echo "     [[hooks.PreToolUse]]"
  echo "     [[hooks.PreToolUse.hooks]]"
  echo "     (each containing 'harness-companion' command paths)"
  echo ""
  if [ -f "$SNIPPET" ]; then
    echo "Removing snippet file: $SNIPPET"
    rm -f "$SNIPPET"
    echo "  removed: $SNIPPET"
  else
    echo "Snippet not present: $SNIPPET (nothing to remove)"
  fi
  echo ""
  echo "=== User-mode uninstall complete ==="
  exit 0
fi

echo "Error: unknown mode '$MODE'" >&2
exit 2
