#!/bin/bash
# harness-handoff.sh — Session handoff generator
#
# Usage: bash harness-handoff.sh [project-dir]
#
# Generates/updates session-handoff.md with current state,
# runs checklist.sh if available, and outputs what needs attention.

set -euo pipefail

TARGET="${1:-.}"

if [ ! -d "$TARGET" ]; then
  echo "Error: Directory '$TARGET' not found."
  exit 1
fi

cd "$TARGET"
DATE=$(date +%Y-%m-%d 2>/dev/null || date +%F)

echo "=== Session Handoff — $DATE ==="
echo ""

# --- 1. Run checklist.sh if available ----------------------------------------
if [ -f "checklist.sh" ] && [ -x "checklist.sh" ]; then
  echo "[Checklist]"
  bash checklist.sh 2>&1 || true
  echo ""
fi

# --- 2. Gather state ---------------------------------------------------------

echo "[State Snapshot]"

# Build verification
if [ -f "package.json" ]; then
  echo -n "  typecheck: "
  if npm run check > /dev/null 2>&1; then
    echo "✅ clean"
  else
    echo "❌ has errors"
  fi

  echo -n "  build: "
  if npm run build > /dev/null 2>&1; then
    echo "✅ success"
  else
    echo "❌ failed"
  fi

  echo -n "  tests: "
  if npm test > /dev/null 2>&1; then
    echo "✅ all passing"
  else
    echo "❌ failures"
  fi
fi

# Git status
if git rev-parse --git-dir > /dev/null 2>&1; then
  UNCOMMITTED=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  echo "  uncommitted files: $UNCOMMITTED"
  if [ "$UNCOMMITTED" -gt 0 ]; then
    echo "    $(git diff --stat HEAD 2>/dev/null || true)"
  fi
else
  echo "  (not a git repository)"
fi

# Feature status
if [ -f "feature_list.json" ] && command -v jq &> /dev/null; then
  TOTAL=$(jq '.features | length' feature_list.json 2>/dev/null || echo "0")
  PASSING=$(jq '[.features[] | select(.status=="passing" or .status=="pass")] | length' feature_list.json 2>/dev/null || echo "0")
  echo "  features: $PASSING/$TOTAL passing"

  # Next pending feature
  NEXT=$(jq -r '.features[] | select(.status=="not_started") | "\(.id): \(.title)"' feature_list.json 2>/dev/null | head -1 || echo "none")
  echo "  next: $NEXT"
fi

echo ""

# --- 3. Generate session-handoff.md ------------------------------------------

echo "[Generate session-handoff.md]"

if [ -f "session-handoff.md" ]; then
  echo "  session-handoff.md already exists — update it manually with the state above."
  echo "  Template: $TARGET/templates/session-handoff.md (in harness-companion skill)"
else
  echo "  Creating session-handoff.md from template..."

  # Find template
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  TEMPLATE="$SCRIPT_DIR/../templates/session-handoff.md"

  if [ -f "$TEMPLATE" ]; then
    sed "s/\[Date\]/$DATE/g" "$TEMPLATE" > session-handoff.md
    echo "  ✅ session-handoff.md created. Fill in the details before committing."
  else
    echo "  ⚠️  Template not found. Create session-handoff.md manually."
  fi
fi

echo ""

# --- 4. Summary --------------------------------------------------------------
echo "=== Handoff Summary ==="
echo ""
echo "Before ending the session:"
echo "  [ ] Run 'bash checklist.sh' (or /harness:verify)"
echo "  [ ] Update feature_list.json — sync all statuses"
echo "  [ ] Update claude-progress.md — add session log entry"
echo "  [ ] Update session-handoff.md — fill in the verified/changed/next sections"
echo "  [ ] Commit all changes with a descriptive message"
echo "  [ ] Ensure agent.log has CLOSE marker (if using agent.log)"
