#!/usr/bin/env bash
# init.sh — Verify the Go project builds cleanly before starting work.
# Type-specific override (go): go build / test.
set -euo pipefail

echo "=== Project Init (go) ==="
echo ""

# ---- 1. Download dependencies -----------------------------------------------
echo "[1/3] Downloading dependencies..."
go mod download 2>/dev/null || true
echo ""

# ---- 2. Build ---------------------------------------------------------------
echo "[2/3] Building project..."
go build ./...
echo ""

# ---- 3. Test + harness files ------------------------------------------------
echo "[3/3] Running tests..."
go test ./...
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
