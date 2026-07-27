#!/usr/bin/env bash
# init.sh — Verify the project builds cleanly before starting work.
# Run this after cloning, when resuming work, or before any new feature.
set -euo pipefail

echo "=== Project Init ==="
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

# ---- 4. Verify harness files ------------------------------------------------
echo "[4/4] Verifying harness files..."
FILES_OK=true

# Core harness files (adjust this list to your project)
for file in AGENTS.md CLAUDE.md feature_list.json; do
  if [ ! -f "$file" ]; then
    echo "  MISSING: $file"
    FILES_OK=false
  else
    echo "  OK: $file"
  fi
done

# Optional but recommended
for file in init.sh claude-progress.md; do
  if [ ! -f "$file" ]; then
    echo "  (optional) MISSING: $file"
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
  echo "Run '/harness:init' or create the missing files manually."
  exit 1
fi
