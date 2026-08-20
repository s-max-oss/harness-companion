#!/usr/bin/env bash
# init.sh — Verify the documentation project is intact before starting work.
# Type-specific override (docs): no build; only doc/harness file checks.
set -euo pipefail

echo "=== Project Init (docs) ==="
echo ""

# ---- 1. Verify docs present -------------------------------------------------
echo "[1/1] Verifying documentation..."
FILES_OK=true

for file in README.md; do
  if [ ! -f "$file" ] && [ ! -d docs ]; then
    echo "  MISSING: no README.md and no docs/ directory"
    FILES_OK=false
  else
    echo "  OK: documentation present"
  fi
done

# Harness files
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
  echo "=== Init complete with warnings. Some files are missing. ==="
  exit 1
fi
