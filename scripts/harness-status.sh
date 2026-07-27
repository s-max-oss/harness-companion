#!/bin/bash
# harness-status.sh — Harness health dashboard
#
# Usage: bash harness-status.sh [project-dir]
#
# Scans harness files and outputs a compact health dashboard.

set -euo pipefail

TARGET="${1:-.}"

if [ ! -d "$TARGET" ]; then
  echo "Error: Directory '$TARGET' not found."
  exit 1
fi

cd "$TARGET"
PROJECT_NAME=$(basename "$PWD")

echo "Harness Health: $PROJECT_NAME"
echo "─────────────────────────────"

# --- Helper functions --------------------------------------------------------

check_file() {
  local file="$1"
  local label="$2"
  if [ -f "$file" ]; then
    echo "  ✅ $label: $file"
    return 0
  else
    echo "  ❌ $label: $file (MISSING)"
    return 1
  fi
}

check_optional() {
  local file="$1"
  local label="$2"
  if [ -f "$file" ]; then
    echo "  ✅ $label: $file"
  else
    echo "  ⚪ $label: $file (optional, not found)"
  fi
}

# --- Knowledge Subsystem -----------------------------------------------------
echo "Knowledge:"
check_file "AGENTS.md" "AGENTS.md"
check_file "CLAUDE.md" "CLAUDE.md"
echo ""

# --- Environment Subsystem ---------------------------------------------------
echo "Environment:"
if [ -f "init.sh" ]; then
  echo "  ✅ init.sh exists"
else
  echo "  ❌ init.sh MISSING"
fi
echo ""

# --- Scope/Feature Subsystem -------------------------------------------------
echo "Scope:"
WARNINGS=0
if [ -f "feature_list.json" ]; then
  # Validate JSON
  if command -v jq &> /dev/null; then
    if jq . feature_list.json > /dev/null 2>&1; then
      TOTAL=$(jq '.features | length' feature_list.json 2>/dev/null || echo "0")
      PASSING=$(jq '[.features[] | select(.status=="passing" or .status=="pass")] | length' feature_list.json 2>/dev/null || echo "0")
      IN_PROGRESS=$(jq '[.features[] | select(.status=="in_progress")] | length' feature_list.json 2>/dev/null || echo "0")
      NOT_STARTED=$(jq '[.features[] | select(.status=="not_started")] | length' feature_list.json 2>/dev/null || echo "0")
      BLOCKED=$(jq '[.features[] | select(.status=="blocked")] | length' feature_list.json 2>/dev/null || echo "0")

      echo "  ✅ feature_list.json: $TOTAL features"

      # Progress bar
      if [ "$TOTAL" -gt 0 ]; then
        PCT=$(( PASSING * 100 / TOTAL ))
        echo "     passing: $PASSING/$TOTAL ($PCT%)"
        [ "$IN_PROGRESS" -gt 0 ] && echo "     in_progress: $IN_PROGRESS"
        [ "$NOT_STARTED" -gt 0 ] && echo "     not_started: $NOT_STARTED"
        [ "$BLOCKED" -gt 0 ] && echo "     blocked: $BLOCKED"
      fi

      # WIP=1 check
      if [ "$IN_PROGRESS" -gt 1 ]; then
        echo "  ⚠️  WIP violation: $IN_PROGRESS features in_progress (should be ≤1)"
        WARNINGS=$((WARNINGS + 1))
      fi

      # Unverified passing features
      NO_EVIDENCE=$(jq '[.features[] | select((.status=="passing" or .status=="pass") and (.evidence | length) == 0)] | length' feature_list.json 2>/dev/null || echo "0")
      if [ "$NO_EVIDENCE" -gt 0 ]; then
        echo "  ⚠️  $NO_EVIDENCE passing features have no evidence"
        WARNINGS=$((WARNINGS + 1))
      fi
    else
      echo "  ❌ feature_list.json is INVALID JSON"
      WARNINGS=$((WARNINGS + 1))
    fi
  else
    echo "  ✅ feature_list.json exists (install jq for detailed stats)"
  fi
else
  echo "  ❌ feature_list.json MISSING"
  WARNINGS=$((WARNINGS + 1))
fi
echo ""

# --- Progress Subsystem ------------------------------------------------------
echo "Progress:"
check_optional "claude-progress.md" "claude-progress.md"
if [ -f "claude-progress.md" ]; then
  # Check staleness
  if command -v stat &> /dev/null; then
    MTIME=$(stat -c %Y "claude-progress.md" 2>/dev/null || stat -f %m "claude-progress.md" 2>/dev/null || echo "0")
    NOW=$(date +%s 2>/dev/null || echo "0")
    if [ "$MTIME" != "0" ] && [ "$NOW" != "0" ]; then
      AGE=$(( (NOW - MTIME) / 3600 ))
      if [ "$AGE" -gt 24 ]; then
        echo "  ⚠️  Last updated ${AGE}h ago — stale!"
        WARNINGS=$((WARNINGS + 1))
      else
        echo "     Last updated: ${AGE}h ago"
      fi
    fi
  fi
fi
echo ""

# --- Verification Subsystem --------------------------------------------------
echo "Verification:"
check_optional "checklist.sh" "checklist.sh"
echo ""

# --- Observability Subsystem -------------------------------------------------
echo "Observability:"
check_optional "agent.log" "agent.log"
if [ -f "agent.log" ]; then
  LAST_LINE=$(tail -1 "agent.log" 2>/dev/null || echo "")
  if echo "$LAST_LINE" | grep -q '"CLOSE"'; then
    echo "     Last session: clean close ✓"
  else
    echo "  ⚠️  No CLOSE marker — last session may have ended abruptly"
    WARNINGS=$((WARNINGS + 1))
  fi
fi
echo ""

# --- Handoff Subsystem -------------------------------------------------------
echo "Handoff:"
check_optional "session-handoff.md" "session-handoff.md"
check_optional "clean-state-checklist.md" "clean-state-checklist.md"
echo ""

# --- Summary -----------------------------------------------------------------
echo "─────────────────────────────"
if [ "$WARNINGS" -eq 0 ]; then
  echo "All checks passed. Harness is healthy."
else
  echo "$WARNINGS warning(s) found. Run /harness:audit for detailed diagnosis."
fi
