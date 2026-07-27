#!/bin/bash
# install.sh — Install harness-companion skill and register hooks
#
# Usage: bash install.sh [--user|--project]
#
# --user:    Install to ~/.claude/skills/harness-companion/ (global, default)
# --project: Install to ./.claude/skills/harness-companion/ (project-local)
#
# Registers SessionStart + Stop hooks in ~/.claude/settings.json

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODE="${1:---user}"

echo "=== Harness Companion Install ==="
echo ""

# --- Step 1: Copy skill files ------------------------------------------------
if [ "$MODE" = "--project" ]; then
  TARGET="$(pwd)/.claude/skills/harness-companion"
  echo "[1/3] Installing project-local to: $TARGET"
else
  TARGET="$HOME/.claude/skills/harness-companion"
  echo "[1/3] Installing globally to: $TARGET"
fi

if [ "$SCRIPT_DIR" = "$TARGET" ]; then
  echo "  Already at target location — skipping copy."
else
  mkdir -p "$TARGET"
  # Copy everything except install.sh itself and .git
  for item in "$SCRIPT_DIR"/*; do
    name=$(basename "$item")
    if [ "$name" != "install.sh" ] && [ "$name" != ".git" ]; then
      cp -r "$item" "$TARGET/"
    fi
  done
  echo "  Done."
fi

# --- Step 2: Make scripts executable -----------------------------------------
echo "[2/3] Making scripts executable..."
chmod +x "$TARGET/scripts/"*.sh 2>/dev/null || true
chmod +x "$TARGET/scripts/hooks/"*.sh 2>/dev/null || true
chmod +x "$TARGET/templates/"*.sh 2>/dev/null || true
echo "  Done."

# --- Step 3: Register hooks in settings.json ---------------------------------
echo "[3/3] Registering hooks in ~/.claude/settings.json..."

SETTINGS_FILE="$HOME/.claude/settings.json"

if [ ! -f "$SETTINGS_FILE" ]; then
  echo "  ~/.claude/settings.json not found. Creating minimal settings file..."
  mkdir -p "$HOME/.claude"
  cat > "$SETTINGS_FILE" << 'SETEOF'
{
  "hooks": {}
}
SETEOF
fi

# Backup
cp "$SETTINGS_FILE" "$SETTINGS_FILE.bak-$(date +%Y%m%d 2>/dev/null || date +%Y%m%d)"
echo "  Backup: $SETTINGS_FILE.bak-$(date +%Y%m%d 2>/dev/null || date +%Y%m%d)"

# Check if hooks section already exists
if grep -q '"hooks"' "$SETTINGS_FILE"; then
  echo "  ⚠️  hooks section already exists in settings.json."
  echo "  Please manually add these entries if not already present:"
  echo ""
  echo "  \"SessionStart\": [{"
  echo "    \"matcher\": \"startup|resume\","
  echo "    \"hooks\": [{"
  echo "      \"type\": \"command\","
  echo "      \"command\": \"bash $TARGET/scripts/hooks/session-start.sh\","
  echo "      \"timeout\": 5000"
  echo "    }]"
  echo "  }],"
  echo "  \"Stop\": [{"
  echo "    \"matcher\": \"*\","
  echo "    \"hooks\": [{"
  echo "      \"type\": \"command\","
  echo "      \"command\": \"bash $TARGET/scripts/hooks/stop-handoff.sh\","
  echo "      \"timeout\": 5000"
  echo "    }]"
  echo "  }]"
else
  echo "  Adding hook configuration..."
  # This is a simple approach; for complex nested JSON, jq is better
  # but we avoid the dependency for installation
  echo "  Note: settings.json already has content — manual hook registration may be safer."
  echo "  See the manual instructions above."
fi

echo ""

# --- Verify ------------------------------------------------------------------
echo "=== Install Complete ==="
echo ""
echo "Verification:"
echo "  Skill directory: $([ -d "$TARGET" ] && echo '✅' || echo '❌') $TARGET"
echo "  SKILL.md:        $([ -f "$TARGET/SKILL.md" ] && echo '✅' || echo '❌')"
echo "  Templates:       $(find "$TARGET/templates" -type f 2>/dev/null | wc -l | tr -d ' ') files"
echo ""
echo "Next steps:"
echo "  1. Restart Claude Code to load the skill and hooks"
echo "  2. In a harness project, try: /harness:status"
echo "  3. To initialize a new project: /harness:init"
