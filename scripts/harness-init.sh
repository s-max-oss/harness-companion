#!/bin/bash
# harness-init.sh — Generate harness scaffold from templates
#
# Usage: bash harness-init.sh [project-dir] [--minimal|--full]
#
# Copies templates from the skill's templates/ directory
# to the target project, filling in project-specific placeholders.

set -euo pipefail

# Resolve script directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATES_DIR="$SCRIPT_DIR/../templates"

TARGET="${1:-.}"
MODE="${2:---minimal}"

if [ ! -d "$TARGET" ]; then
  echo "Error: Target directory '$TARGET' does not exist."
  exit 1
fi

cd "$TARGET"
PROJECT_NAME=$(basename "$PWD")

echo "=== Harness Init: $PROJECT_NAME ==="
echo ""

# --- Helper: copy template with placeholder replacement ----------------------
copy_template() {
  local src="$1"
  local dest="$2"
  local description="$3"

  if [ -f "$dest" ]; then
    echo "  SKIP: $dest already exists"
    return
  fi

  if [ ! -f "$src" ]; then
    echo "  MISSING TEMPLATE: $src"
    return
  fi

  # Copy and replace placeholders
  sed -e "s/replace-with-project-name/$PROJECT_NAME/g" \
      -e "s/YYYY-MM-DD/$(date +%Y-%m-%d 2>/dev/null || date +%F)/g" \
      -e "s/\[Replace with a short paragraph describing what this project is and its key characteristics.\]/[Describe your project here.]/g" \
      -e "s/\[One-sentence summary of what this project is.\]/[Your project summary here.]/g" \
      -e "s/\[Add your project-specific conventions here\]//g" \
      -e "s/\[Add your project's key rules here\]//g" \
      -e "s/\[Describe the architectural layers of your project. For Electron apps:\]//g" \
      "$src" > "$dest"

  echo "  OK: $dest ($description)"
}

# --- Minimal harness (4 files) -----------------------------------------------
echo "[Minimal Harness — 4 files]"

copy_template "$TEMPLATES_DIR/AGENTS.md"   "AGENTS.md"   "Agent operating manual"
copy_template "$TEMPLATES_DIR/CLAUDE.md"  "CLAUDE.md"  "Claude Code quick reference"
copy_template "$TEMPLATES_DIR/feature_list.json" "feature_list.json" "Feature registry"
copy_template "$TEMPLATES_DIR/init.sh"   "init.sh"   "Environment verification"

# Make init.sh executable
if [ -f "init.sh" ]; then
  chmod +x init.sh 2>/dev/null || true
  echo "  OK: init.sh made executable"
fi

echo ""

# --- Full harness (additional files) -----------------------------------------
if [ "$MODE" = "--full" ]; then
  echo "[Extended Harness — +4 files]"

  copy_template "$TEMPLATES_DIR/claude-progress.md"      "claude-progress.md"      "Session progress log"
  copy_template "$TEMPLATES_DIR/session-handoff.md"      "session-handoff.md"      "Session handoff doc"
  copy_template "$TEMPLATES_DIR/clean-state-checklist.md" "clean-state-checklist.md" "Pre-commit verification"
  copy_template "$TEMPLATES_DIR/checklist.sh"             "checklist.sh"             "Executable handoff checklist"

  if [ -f "checklist.sh" ]; then
    chmod +x checklist.sh 2>/dev/null || true
    echo "  OK: checklist.sh made executable"
  fi

  echo ""
fi

# --- Summary -----------------------------------------------------------------
echo "=== Harness scaffold complete ==="
echo ""
echo "Next steps:"
echo "  1. Edit feature_list.json — add your real features"
echo "  2. Edit AGENTS.md — update layer boundaries and conventions"
echo "  3. Edit CLAUDE.md — update build commands and key files"
echo "  4. Run 'bash init.sh' to verify the environment"
echo ""
echo "For full harness: re-run with --full"
