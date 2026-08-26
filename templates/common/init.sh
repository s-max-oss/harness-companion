#!/usr/bin/env bash
# init.sh — Verify the project builds cleanly before starting work.
# Run this after cloning, when resuming work, or before any new feature.
#
# This is the GENERIC (common) environment helper. Type-specific variants live
# in by-type/<type>/init.sh and are selected by the harness init renderer.
set -euo pipefail

echo "=== Project Init ==="
echo ""

# ---- 1. Verify harness files ------------------------------------------------
echo "[1/1] Verifying harness files..."
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
