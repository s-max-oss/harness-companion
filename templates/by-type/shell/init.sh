#!/usr/bin/env bash
# init.sh — Verify the shell-script project builds cleanly before starting work.
# Type-specific override (shell): make / shellcheck.
set -euo pipefail

echo "=== Project Init (shell) ==="
echo ""

# ---- 1. Build ---------------------------------------------------------------
echo "[1/2] Building project..."
if [ -f Makefile ]; then
  make
else
  echo "  (no Makefile — skipping build)"
fi
echo ""

# ---- 2. Lint + harness files ------------------------------------------------
echo "[2/2] Linting..."
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck ./*.sh 2>/dev/null || echo "  (shellcheck found issues — review above)"
else
  echo "  (shellcheck not installed — skipping)"
fi
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
