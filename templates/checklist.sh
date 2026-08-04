#!/bin/bash
# checklist.sh — End-of-session verification checklist.
# Run before committing and closing the session.
set -euo pipefail

PASS=0
FAIL=0

check() {
  local label="$1"
  shift
  echo -n "  $label ... "
  if "$@" > /dev/null 2>&1; then
    echo "PASS"
    PASS=$((PASS + 1))
  else
    echo "FAIL"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== Session Handoff Checklist ==="
echo ""

# 1. Build verification — prevent dirty exit
echo "[1] Build Verification"
check "typecheck" npx tsc --noEmit
check "build"    npm run build
echo ""

# 2. Feature status sync — prevent status drift
echo "[2] Feature Status Sync"
if [ -f feature_list.json ]; then
  if command -v jq &> /dev/null; then
    IN_PROGRESS=$(jq -r '.features[] | select(.status=="in_progress") | .id' feature_list.json 2>/dev/null || echo "")
    if [ -n "$IN_PROGRESS" ]; then
      echo "  WARNING: Features still in_progress: $IN_PROGRESS"
      echo "  Update their status before ending the session."
      FAIL=$((FAIL + 1))
    else
      echo "  OK: No dangling in_progress features"
      PASS=$((PASS + 1))
    fi
  else
    echo "  SKIP: jq not available"
  fi
else
  echo "  SKIP: feature_list.json not found"
fi
echo ""

# 3. Progress doc updated — prevent context break
echo "[3] Progress Documentation"
if [ -f claude-progress.md ]; then
  echo "  OK: claude-progress.md exists"
  PASS=$((PASS + 1))
else
  echo "  WARNING: claude-progress.md not found — create it before ending"
  FAIL=$((FAIL + 1))
fi
echo ""

# 4. Change record — prevent fuzzy changes
echo "[4] Change Record"
if git rev-parse --git-dir > /dev/null 2>&1; then
  UNCOMMITTED=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  if [ "$UNCOMMITTED" -gt 0 ]; then
    echo "  WARNING: $UNCOMMITTED uncommitted files"
    git diff --stat HEAD 2>/dev/null || true
    FAIL=$((FAIL + 1))
  else
    echo "  OK: Working tree clean"
    PASS=$((PASS + 1))
  fi
else
  echo "  SKIP: Not a git repository"
fi
echo ""

# 5. Agent log close marker
echo "[5] Agent Log Close"
if [ -f agent.log ]; then
  TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ")
  echo "{\"ts\":\"$TIMESTAMP\",\"step\":-1,\"action\":\"CLOSE\"}" >> agent.log
  echo "  OK: CLOSE marker written to agent.log"
  PASS=$((PASS + 1))
else
  echo "  SKIP: agent.log not found"
fi
echo ""

echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  echo "Fix the failures above before ending the session."
  exit 1
else
  echo "Clean handoff ready. Safe to commit and end session."
fi
