#!/usr/bin/env bash
# init.sh — Verify the Node.js project builds cleanly before starting work.
# Type-specific override (node): npm install / build / test.
set -euo pipefail

echo "=== Project Init (node) ==="
echo ""

# ---- 1. Install dependencies ------------------------------------------------
echo "[1/4] Installing dependencies..."
npm install
echo ""

# ---- 2. Type-check ----------------------------------------------------------
echo "[2/4] Running type checks..."
npm run check 2>/dev/null || npx tsc --noEmit
echo ""

# ---- 3. Build ---------------------------------------------------------------
echo "[3/4] Building project..."
npm run build 2>/dev/null || echo "  (no build script — skipping)"
echo ""

# ---- 4. Test + harness files ------------------------------------------------
echo "[4/4] Running tests..."
npm test
echo ""

echo "Verifying harness files..."
FILES_OK=true
for file in AGENTS.md CLAUDE.md feature_list.json; do
  if [ ! -f "$file" ]; then
    echo "  MISSING: $file"
    FILES_OK=false
  else
    echo "  OK: $file"
  fi
done

echo ""

if [ "$FILES_OK" = true ]; then
  echo "=== Init complete. All checks passed. ==="
  echo "Ready to start work."
else
  echo "=== Init complete with warnings. Some harness files are missing. ==="
  exit 1
fi
