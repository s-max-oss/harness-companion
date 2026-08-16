#!/bin/bash
# adapters/claude-code/uninstall.sh — Uninstall the Claude Code adapter
#
# Phase 2 (rc.2): Safe uninstall with receipt gate, target gate, and fail-closed
# settings.json handling.
#
# Usage:
#   bash adapters/claude-code/uninstall.sh [--user|--project]
#
# --user:    Uninstall from ~/.claude/skills/harness-companion/ (default)
# --project: Uninstall from ./.claude/skills/harness-companion/
#
# Safety gates (AC-4):
#   1. Receipt gate: verify install-receipt.json exists with .skill == "harness-companion"
#   2. Target gate: refuse to delete /, $HOME, or paths not ending with harness-companion
#   3. Settings fail-closed: if settings.json is unparseable, keep original, exit non-zero
#   4. Timestamped backup before any settings.json mutation
#
# Per rc.2 spec §3 GAP-1 — removes target tree, deregisters hooks, prints manual
# steps for anything not auto-removable.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

MODE="--user"
for arg in "$@"; do
  case "$arg" in
    --user)    MODE="--user" ;;
    --project) MODE="--project" ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

# ---- Resolve target ------------------------------------------------------------
if [ "$MODE" = "--project" ]; then
  TARGET="$(pwd)/.claude/skills/harness-companion"
  SETTINGS_FILE="$(pwd)/.claude/settings.json"
else
  TARGET="$HOME/.claude/skills/harness-companion"
  SETTINGS_FILE="$HOME/.claude/settings.json"
fi

echo "=== Harness Companion Uninstall (Claude Code adapter) ==="
echo ""
echo "Mode:       $MODE"
echo "Target:     $TARGET"
echo "Settings:   $SETTINGS_FILE"
echo ""

# ===============================================================================
# AC-4 Safety Gate 1: Target gate — refuse unsafe paths
# ===============================================================================

# Canonicalize target for safe comparison
CANON_TARGET=""
if command -v readlink >/dev/null 2>&1 && readlink -f "$TARGET" >/dev/null 2>&1; then
  CANON_TARGET="$(readlink -f "$TARGET" 2>/dev/null || echo "$TARGET")"
else
  CANON_TARGET="$TARGET"
fi
CANON_TARGET="$(printf '%s' "$CANON_TARGET" | tr '\\' '/')"

# Refuse empty, root, home
CANON_HOME="$(printf '%s' "$HOME" | tr '\\' '/')"

if [ -z "${CANON_TARGET:-}" ]; then
  echo "ERROR: Target path is empty — refusing to delete." >&2
  exit 1
fi

case "$CANON_TARGET" in
  "/"|"$CANON_HOME"|"$CANON_HOME/")
    echo "ERROR: Target '$CANON_TARGET' is root or home — refusing to delete." >&2
    exit 1
    ;;
esac

# Refuse if target does not end with harness-companion
case "$CANON_TARGET" in
  */harness-companion)
    ;;
  *)
    echo "ERROR: Target '$CANON_TARGET' does not end with 'harness-companion' — refusing to delete." >&2
    exit 1
    ;;
esac

# ===============================================================================
# AC-4 Safety Gate 2: Receipt gate — verify identity
# ===============================================================================

RECEIPT="$TARGET/install-receipt.json"

if [ ! -f "$RECEIPT" ]; then
  echo "ERROR: No install-receipt.json found at '$RECEIPT' — cannot verify target identity." >&2
  echo "       If you are certain this is a harness-companion install, manually run:" >&2
  echo "         rm -rf '$TARGET'" >&2
  exit 1
fi

# Verify .skill field
SKILL_FIELD=""
if command -v jq >/dev/null 2>&1 && echo '{}' | jq -e . >/dev/null 2>&1; then
  SKILL_FIELD="$(jq -r '.skill // ""' "$RECEIPT" 2>/dev/null || echo "")"
elif command -v python3 >/dev/null 2>&1; then
  SKILL_FIELD="$(python3 -c "import json; d=json.load(open('$RECEIPT')); print(d.get('skill',''))" 2>/dev/null || echo "")"
fi

if [ "$SKILL_FIELD" != "harness-companion" ]; then
  echo "ERROR: Receipt .skill field is '$SKILL_FIELD', expected 'harness-companion' — refusing to delete." >&2
  echo "       Target does not appear to be a harness-companion install." >&2
  exit 1
fi

echo "[gate] Receipt verified: skill=harness-companion, target=$CANON_TARGET"
echo ""

# ===============================================================================
# Step 1: Deregister hooks from settings.json
# ===============================================================================

echo "[1/3] Deregistering hooks from settings.json..."

if [ -f "$SETTINGS_FILE" ]; then
  # AC-4 fail-closed: verify settings.json is valid JSON before touching it
  SETTINGS_VALID=0
  if command -v jq >/dev/null 2>&1 && jq -e . "$SETTINGS_FILE" >/dev/null 2>&1; then
    SETTINGS_VALID=1
  elif command -v python3 >/dev/null 2>&1 && python3 -c "import json; json.load(open('$SETTINGS_FILE'))" >/dev/null 2>&1; then
    SETTINGS_VALID=1
  fi

  if [ "$SETTINGS_VALID" -eq 0 ]; then
    echo "ERROR: $SETTINGS_FILE exists but cannot be safely parsed as JSON." >&2
    echo "       The file will NOT be modified. Manual hook cleanup required." >&2
    echo "       Remove any SessionStart/Stop entries referencing:" >&2
    echo "         $TARGET/adapters/claude-code/hooks/session-start.sh" >&2
    echo "         $TARGET/adapters/claude-code/hooks/stop-handoff.sh" >&2
    exit 1
  fi

  # Check if our hooks are registered.
  # Use fixed invariant substrings (not --arg paths) because jq --arg mangles
  # MSYS paths (/c/Users) to Windows form (C:/Users) on Git Bash, breaking
  # contains() comparisons.  "harness-companion/scripts/hooks/<script>" is
  # invariant across all path formats (~, MSYS, Windows, Linux).
  SS_KEY="harness-companion/adapters/claude-code/hooks/session-start.sh"
  STOP_KEY="harness-companion/adapters/claude-code/hooks/stop-handoff.sh"

  HAS_OUR_HOOKS=0
  if command -v jq >/dev/null 2>&1; then
    if jq -e '.hooks.SessionStart[]?.hooks[]?.command | select(contains("'"$SS_KEY"'"))' "$SETTINGS_FILE" >/dev/null 2>&1; then
      HAS_OUR_HOOKS=1
    elif jq -e '.hooks.Stop[]?.hooks[]?.command | select(contains("'"$STOP_KEY"'"))' "$SETTINGS_FILE" >/dev/null 2>&1; then
      HAS_OUR_HOOKS=1
    fi
  fi

  if [ "$HAS_OUR_HOOKS" -eq 1 ]; then
    # Timestamped backup before mutation
    STAMP="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || date +%Y%m%dT%H%M%SZ)"
    BACKUP="${SETTINGS_FILE}.bak.uninstall.${STAMP}"
    cp -p "$SETTINGS_FILE" "$BACKUP"
    echo "  backup written: $BACKUP"

    # Remove our SessionStart and Stop entries
    if command -v jq >/dev/null 2>&1; then
      jq '
        .hooks.SessionStart = (
          .hooks.SessionStart
          | map(select((.hooks[]?.command | contains("'"$SS_KEY"'")) | not))
        )
        | .hooks.Stop = (
          .hooks.Stop
          | map(select((.hooks[]?.command | contains("'"$STOP_KEY"'")) | not))
        )
        ' "$SETTINGS_FILE" > "$SETTINGS_FILE.tmp" \
        && mv "$SETTINGS_FILE.tmp" "$SETTINGS_FILE"
      echo "  hooks deregistered from $SETTINGS_FILE"
    fi
  else
    echo "  no harness-companion hooks found in $SETTINGS_FILE (already clean)"
  fi
else
  echo "  no settings.json to clean ($SETTINGS_FILE does not exist)"
fi

# ===============================================================================
# Step 2: Remove target tree
# ===============================================================================

echo "[2/3] Removing target tree..."
if [ -d "$TARGET" ]; then
  rm -rf "$TARGET"
  echo "  removed: $TARGET"
else
  echo "  target does not exist (already removed?): $TARGET"
fi

# ===============================================================================
# Step 3: Manual cleanup instructions
# ===============================================================================

echo "[3/3] Checking for manual cleanup items..."
echo ""

MANUAL_NEEDED=0

# Check if settings.json still has other hooks (not ours)
if [ -f "$SETTINGS_FILE" ]; then
  OTHER_HOOKS=0
  if command -v jq >/dev/null 2>&1; then
    OTHER_HOOKS="$(jq '[.hooks.SessionStart // [], .hooks.Stop // []] | flatten | length' "$SETTINGS_FILE" 2>/dev/null || echo 0)"
  fi
  if [ "${OTHER_HOOKS:-0}" -gt 0 ]; then
    echo "  Note: $SETTINGS_FILE has $OTHER_HOOKS other hook entries (not ours — left intact)"
  else
    echo "  Note: $SETTINGS_FILE has no remaining hooks"
    echo "        You may remove empty hook arrays manually if desired"
  fi
fi

# Check for backup files
BACKUP_COUNT="$(ls -1 "${SETTINGS_FILE}.bak."* 2>/dev/null | wc -l || echo 0)"
if [ "${BACKUP_COUNT:-0}" -gt 0 ]; then
  echo "  Note: $BACKUP_COUNT settings.json backup(s) created during install/uninstall"
  echo "        Remove with: rm -f '${SETTINGS_FILE}.bak.'*"
  MANUAL_NEEDED=1
fi

echo ""
echo "=== Uninstall Complete ==="
echo ""
echo "Removed:"
echo "  - $TARGET/"
echo "  - harness-companion hooks from $SETTINGS_FILE"
echo ""

if [ "$MANUAL_NEEDED" -eq 1 ]; then
  echo "Manual cleanup items listed above (backups, empty hook arrays)."
else
  echo "No manual cleanup needed."
fi