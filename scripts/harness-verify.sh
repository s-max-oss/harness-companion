#!/bin/bash
# harness-verify.sh — Run verification chain and fill evidence
#
# Usage: bash harness-verify.sh [feature-id] [project-dir]
#
# Runs: check → build → test chain
# If all pass: auto-fills evidence in feature_list.json

set -euo pipefail

FEATURE_ID="${1:-}"
TARGET="${2:-.}"

if [ ! -d "$TARGET" ]; then
  echo "Error: Directory '$TARGET' not found."
  exit 1
fi

cd "$TARGET"

if [ ! -f "feature_list.json" ]; then
  echo "Error: feature_list.json not found."
  exit 1
fi

# --- Detect verification commands --------------------------------------------
DETECT_CHECK="npm run check"
DETECT_BUILD="npm run build"
DETECT_TEST="npm test"

# Check what's available
if [ -f "package.json" ]; then
  HAS_CHECK=$(grep -c '"check"' package.json 2>/dev/null || echo "0")
  HAS_BUILD=$(grep -c '"build"' package.json 2>/dev/null || echo "0")
  HAS_TEST=$(grep -c '"test"' package.json 2>/dev/null || echo "0")
else
  HAS_CHECK="0"
  HAS_BUILD="0"
  HAS_TEST="0"
fi

echo "=== Harness Verify ==="
if [ -n "$FEATURE_ID" ]; then
  echo "Feature: $FEATURE_ID"
fi
echo ""

PASSED=0
FAILED=0
EVIDENCE=""

# --- Step 1: Typecheck -------------------------------------------------------
echo "[1] Typecheck"
if [ "$HAS_CHECK" != "0" ]; then
  if npm run check 2>&1; then
    echo "  ✅ typecheck passed"
    EVIDENCE+="$(date +%Y-%m-%d): typecheck passed (0 errors)"
    PASSED=$((PASSED + 1))
  else
    echo "  ❌ typecheck failed"
    EVIDENCE+="$(date +%Y-%m-%d): typecheck FAILED"
    FAILED=$((FAILED + 1))
  fi
else
  if npx tsc --noEmit 2>&1; then
    echo "  ✅ tsc --noEmit passed"
    EVIDENCE+="$(date +%Y-%m-%d): tsc --noEmit passed (0 errors)"
    PASSED=$((PASSED + 1))
  else
    echo "  ❌ tsc --noEmit failed"
    EVIDENCE+="$(date +%Y-%m-%d): tsc --noEmit FAILED"
    FAILED=$((FAILED + 1))
  fi
fi
echo ""

# --- Step 2: Build -----------------------------------------------------------
echo "[2] Build"
if [ "$HAS_BUILD" != "0" ]; then
  if npm run build 2>&1; then
    echo "  ✅ build succeeded"
    EVIDENCE+="\n$(date +%Y-%m-%d): build succeeded (exit 0)"
    PASSED=$((PASSED + 1))
  else
    echo "  ❌ build failed"
    EVIDENCE+="\n$(date +%Y-%m-%d): build FAILED"
    FAILED=$((FAILED + 1))
  fi
else
  echo "  ⚪ no build script — skipping"
  EVIDENCE+="\n$(date +%Y-%m-%d): build (skipped — no build script)"
fi
echo ""

# --- Step 3: Tests -----------------------------------------------------------
echo "[3] Tests"
if [ "$HAS_TEST" != "0" ]; then
  if npm test 2>&1; then
    echo "  ✅ tests passed"
    EVIDENCE+="\n$(date +%Y-%m-%d): tests passed (exit 0)"
    PASSED=$((PASSED + 1))
  else
    echo "  ❌ tests failed"
    EVIDENCE+="\n$(date +%Y-%m-%d): tests FAILED"
    FAILED=$((FAILED + 1))
  fi
else
  echo "  ⚪ no test script — skipping"
  EVIDENCE+="\n$(date +%Y-%m-%d): tests (skipped — no test script)"
fi
echo ""

# --- Results -----------------------------------------------------------------
echo "─────────────────────────────"
echo "Results: $PASSED passed, $FAILED failed"

if [ "$FAILED" -gt 0 ]; then
  echo ""
  echo "❌ Verification FAILED. Fix the failing steps before updating feature status."
  exit 1
fi

echo ""
echo "✅ All checks passed!"

# --- Update feature_list.json ------------------------------------------------
if [ -n "$FEATURE_ID" ] && command -v jq &> /dev/null; then
  # Check feature exists
  EXISTS=$(jq -r --arg id "$FEATURE_ID" '.features[] | select(.id==$id) | .id' feature_list.json 2>/dev/null || echo "")
  if [ -n "$EXISTS" ]; then
    # Escape evidence for JSON
    EVIDENCE_JSON=$(printf '%s' "$EVIDENCE" | sed 's/\\/\\\\/g; s/"/\\"/g')

    jq --arg id "$FEATURE_ID" --arg evidence "$EVIDENCE_JSON" \
       '(.features[] | select(.id==$id) | .status) = "passing" |
        (.features[] | select(.id==$id) | .evidence) += [$evidence] |
        .last_updated = "'"$(date +%Y-%m-%d)"'"' \
       feature_list.json > feature_list.json.tmp

    mv feature_list.json.tmp feature_list.json
    echo "Updated feature_list.json: '$FEATURE_ID' → passing (evidence recorded)"
  else
    echo "⚠️  Feature '$FEATURE_ID' not found in feature_list.json — evidence not recorded."
  fi
fi
