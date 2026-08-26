#!/usr/bin/env bash
# init.sh — Verify the Rust project builds cleanly before starting work.
# Type-specific override (rust): cargo build / test.
set -euo pipefail

echo "=== Project Init (rust) ==="
echo ""

# ---- 1. Check/format --------------------------------------------------------
echo "[1/3] Running checks..."
cargo check 2>/dev/null || cargo build
echo ""

# ---- 2. Build ---------------------------------------------------------------
echo "[2/3] Building project..."
cargo build
echo ""

# ---- 3. Test + harness files ------------------------------------------------
echo "[3/3] Running tests..."
cargo test
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
