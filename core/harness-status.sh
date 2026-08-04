#!/bin/bash
# core/harness-status.sh — Harness health dashboard (v2)
#
# Ported from v1.1.2 scripts/harness-status.sh. Uses core/lib/ for shared helpers.
#
# Usage: bash harness-status.sh [project-dir]
#
# Scans all 7 harness subsystems and outputs a compact health dashboard.
# Does NOT abort on missing files — all sections render regardless.
#
# ASCII markers ([OK]/[NO]/[--]/[!!]) for Windows portability.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CORE_LIB="$SCRIPT_DIR/lib"

TARGET="${1:-.}"

if [ ! -d "$TARGET" ]; then
  echo "Error: Directory '$TARGET' not found."
  exit 1
fi

cd "$TARGET" 2>/dev/null || { echo "Error: Cannot cd to $TARGET" >&2; exit 1; }
PROJECT_NAME="$(basename "$PWD")"

echo "Harness Health: $PROJECT_NAME"
echo "─────────────────────────────"

# --- Helper functions --------------------------------------------------------

check_file() {
  local file="$1"
  local label="$2"
  if [ -f "$file" ]; then
    echo "  [OK] $label: \`$file\`"
    return 0
  else
    echo "  [NO] $label: \`$file\` (MISSING)"
    return 1
  fi
}

check_optional() {
  local file="$1"
  local label="$2"
  if [ -f "$file" ]; then
    echo "  [OK] $label: \`$file\`"
  else
    echo "  [--] $label: \`$file\` (optional, not found)"
  fi
}

# --- Knowledge Subsystem -----------------------------------------------------
echo "Knowledge:"
check_file "AGENTS.md" "AGENTS.md" || true
check_file "CLAUDE.md" "CLAUDE.md" || true
echo ""

# --- Environment Subsystem ---------------------------------------------------
echo "Environment:"
if [ -f "init.sh" ]; then
  echo "  [OK] init.sh exists"
else
  echo "  [NO] init.sh MISSING"
fi
if [ -f ".harness/config.json" ]; then
  echo "  [OK] .harness/config.json (config-driven verification)"
elif [ -f "checklist.sh" ]; then
  echo "  [OK] checklist.sh (legacy verification)"
else
  echo "  [--] No verification config (.harness/config.json or checklist.sh)"
fi
echo ""

# --- Scope/Feature Subsystem -------------------------------------------------
echo "Scope:"
WARNINGS=0
if [ -f "feature_list.json" ]; then
  if command -v jq >/dev/null 2>&1; then
    if jq . feature_list.json >/dev/null 2>&1; then
      TOTAL="$(jq '.features | length' feature_list.json 2>/dev/null || echo 0)"
      PASSING="$(jq '[.features[] | select(.status=="passing")] | length' feature_list.json 2>/dev/null || echo 0)"
      IN_PROGRESS="$(jq '[.features[] | select(.status=="in_progress")] | length' feature_list.json 2>/dev/null || echo 0)"
      NOT_STARTED="$(jq '[.features[] | select(.status=="not_started")] | length' feature_list.json 2>/dev/null || echo 0)"
      BLOCKED="$(jq '[.features[] | select(.status=="blocked")] | length' feature_list.json 2>/dev/null || echo 0)"
      UNVERIFIED="$(jq '[.features[] | select(.status=="unverified")] | length' feature_list.json 2>/dev/null || echo 0)"
      DEPRECATED="$(jq '[.features[] | select(.status=="deprecated")] | length' feature_list.json 2>/dev/null || echo 0)"

      echo "  [OK] feature_list.json: $TOTAL features"

      if [ "$TOTAL" -gt 0 ]; then
        PCT=$(( PASSING * 100 / TOTAL ))
        echo "     passing:     $PASSING/$TOTAL ($PCT%)"
        [ "$IN_PROGRESS" -gt 0 ] && echo "     in_progress: $IN_PROGRESS"
        [ "$UNVERIFIED" -gt 0 ] && echo "     unverified:  $UNVERIFIED"
        [ "$NOT_STARTED" -gt 0 ] && echo "     not_started: $NOT_STARTED"
        [ "$BLOCKED" -gt 0 ] && echo "     blocked:     $BLOCKED"
        [ "$DEPRECATED" -gt 0 ] && echo "     deprecated:  $DEPRECATED"
      fi

      # WIP=1 check
      if [ "$IN_PROGRESS" -gt 1 ]; then
        echo "  [!!] WIP violation: $IN_PROGRESS features in_progress (WIP=1 limit)"
        WARNINGS=$((WARNINGS + 1))
      fi

      # Passing / unverified without evidence (v2: check evidence_associations, not v1 .evidence)
      NO_EVIDENCE="$(jq '[.features[] | select((.status=="passing" or .status=="unverified") and (((.evidence_associations // []) | length) == 0))] | length' feature_list.json 2>/dev/null || echo 0)"
      if [ "$NO_EVIDENCE" -gt 0 ]; then
        echo "  [!!] $NO_EVIDENCE passing/unverified features have NO evidence_associations"
        WARNINGS=$((WARNINGS + 1))
      fi

      # Features with override (audit bypass) — v2: also uses evidence_associations
      OVERRIDES="$(jq '[.features[] | select(.override != null and (((.evidence_associations // []) | length) == 0))] | length' feature_list.json 2>/dev/null || echo 0)"
      if [ "$OVERRIDES" -gt 0 ]; then
        echo "  [!!] $OVERRIDES features overridden to unverified without evidence_associations"
        WARNINGS=$((WARNINGS + 1))
      fi
    else
      echo "  [NO] feature_list.json is INVALID JSON"
      WARNINGS=$((WARNINGS + 1))
    fi
  else
    echo "  [OK] feature_list.json exists (install jq for detailed stats)"
  fi
else
  echo "  [NO] feature_list.json MISSING"
  WARNINGS=$((WARNINGS + 1))
fi
echo ""

# --- Progress Subsystem ------------------------------------------------------
echo "Progress:"
check_optional "claude-progress.md" "claude-progress.md"
if [ -f "claude-progress.md" ]; then
  if command -v stat >/dev/null 2>&1; then
    MTIME="$(stat -c %Y "claude-progress.md" 2>/dev/null || stat -f %m "claude-progress.md" 2>/dev/null || echo 0)"
    NOW="$(date +%s 2>/dev/null || echo 0)"
    if [ "$MTIME" != "0" ] && [ "$NOW" != "0" ]; then
      AGE=$(( (NOW - MTIME) / 3600 ))
      if [ "$AGE" -gt 168 ]; then
        echo "  [!!] Last updated ${AGE}h ago (stale >7 days)"
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
if [ -f ".harness/config.json" ]; then
  echo "  [OK] .harness/config.json (config-driven)"
elif [ -f "checklist.sh" ]; then
  echo "  [OK] checklist.sh"
else
  echo "  [--] No verification config"
fi

# Check for recent verification log artifacts
if [ -d ".harness/logs" ]; then
  LOG_COUNT="$(find .harness/logs -type f 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$LOG_COUNT" -gt 0 ]; then
    echo "     $LOG_COUNT verification log(s) in .harness/logs/"
  fi
fi
echo ""

# --- Observability Subsystem -------------------------------------------------
echo "Observability:"
check_optional "agent.log" "agent.log"
if [ -f "agent.log" ]; then
  if grep -q '"CLOSE"' agent.log 2>/dev/null; then
    echo "     CLOSE marker present"
  else
    echo "  [!!] No CLOSE marker — last session may have ended abruptly"
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
