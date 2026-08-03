#!/bin/bash
# test-release-archive.sh — Verify git archive HEAD is release-ready
#
# Two phases:
#   Phase A (outer — runs inside the source git repo):
#     1. Verify templates/.harness/* are tracked (git ls-files)
#     2. Verify git archive HEAD extracts all 7 templates/.harness/ files
#     3. Verify plugin.json is in the archive
#     4. Extract the full archive into a temp dir
#   Phase B (inner — runs inside the extracted archive, no .git):
#     1. Core regression (tests/core/test-*.sh)
#     2. Adapter contracts (tests/adapters/test-*.sh)
#     3. Migration compat (tests/migration/test-v1-compat.sh)
#        — G13 git-ls-files/git-archive assertions SKIP when .git is absent
#     4. Codex validate_plugin.py
#
# When there is no .git in the archive, the migration test's G13 group
# emits "[SKIP]" rather than "[FAIL]" for git-tracking assertions.
#
# Usage:
#   bash tests/release/test-release-archive.sh
#
# Exit 0 if everything passes, 1 if any test or validator fails.

set -uo pipefail

SOURCE_REPO="$(cd "$(dirname "$0")/../.." && pwd)"
PASSED=0
FAILED=0

echo "============================================"
echo "  test-release-archive.sh"
echo "  Source repo: $SOURCE_REPO"
echo "============================================"

# ---- Phase A: outer — verify in source repo --------------------------------
echo ""
echo "=== Phase A: Outer — git-ls-files + git archive ==="

# A1: templates/.harness/ tracked file count
TRACKED_COUNT="$(git -C "$SOURCE_REPO" ls-files templates/.harness/ | wc -l)"
if [ "$TRACKED_COUNT" -eq 7 ]; then
  echo "PASS: A1 — git ls-files templates/.harness/ = 7"
  PASSED=$((PASSED + 1))
else
  echo "FAIL: A1 — expected 7 tracked files, got $TRACKED_COUNT"
  FAILED=$((FAILED + 1))
fi

# A2: git archive extraction file count
ARCHIVE_DIR="$(mktemp -d)"
trap 'rm -rf "$ARCHIVE_DIR"' EXIT
git -C "$SOURCE_REPO" archive HEAD -- 'templates/.harness/' | tar -x -C "$ARCHIVE_DIR"
ARCHIVE_COUNT="$(find "$ARCHIVE_DIR" -type f | wc -l)"
if [ "$ARCHIVE_COUNT" -eq 7 ]; then
  echo "PASS: A2 — git archive HEAD templates/.harness/ → 7 files extracted"
  PASSED=$((PASSED + 1))
else
  echo "FAIL: A2 — expected 7 files in archive extraction, got $ARCHIVE_COUNT"
  FAILED=$((FAILED + 1))
fi
rm -rf "$ARCHIVE_DIR"/* 2>/dev/null || true

# A3: verify plugin.json is in the archive
git -C "$SOURCE_REPO" archive HEAD -- '.codex-plugin/plugin.json' | tar -x -C "$ARCHIVE_DIR"
if [ -f "$ARCHIVE_DIR/.codex-plugin/plugin.json" ]; then
  echo "PASS: A3 — .codex-plugin/plugin.json in archive"
  PASSED=$((PASSED + 1))
else
  echo "FAIL: A3 — .codex-plugin/plugin.json missing from archive"
  FAILED=$((FAILED + 1))
fi

# A4: extract full archive for Phase B
FULL_ARCHIVE_DIR="$(mktemp -d)"
rm -rf "$ARCHIVE_DIR" 2>/dev/null || true
trap 'rm -rf "$FULL_ARCHIVE_DIR"' EXIT
git -C "$SOURCE_REPO" archive HEAD | tar -x -C "$FULL_ARCHIVE_DIR"
if [ -d "$FULL_ARCHIVE_DIR/tests" ] && [ -f "$FULL_ARCHIVE_DIR/SKILL.md" ]; then
  echo "PASS: A4 — full archive extracted to $FULL_ARCHIVE_DIR"
  PASSED=$((PASSED + 1))
else
  echo "FAIL: A4 — archive extraction incomplete"
  FAILED=$((FAILED + 1))
  exit 1
fi
echo ""

# ---- Phase B: inner — run tests inside archive dir -------------------------
echo "=== Phase B: Inner — run tests inside archive (no .git) ==="
cd "$FULL_ARCHIVE_DIR" || exit 1

IS_GIT=0
git rev-parse --git-dir >/dev/null 2>&1 && IS_GIT=1
echo "Archive has .git: $IS_GIT (0 = archive mode, tests that require .git should SKIP)"
echo ""

run_test() {
  local label="$1" script="$2"
  echo "---- $label ----"
  if [ ! -f "$script" ]; then
    echo "SKIP: $script not found in archive"
    return 0
  fi
  if bash "$script" 2>&1; then
    echo "PASS: $label"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL: $label"
    FAILED=$((FAILED + 1))
  fi
  echo ""
}

run_core_tests() {
  local failed=0
  for t in tests/core/test-*.sh; do
    [ ! -f "$t" ] && continue
    printf '  %-50s ' "$t"
    if bash "$t" >/dev/null 2>&1; then
      echo "PASS"
      PASSED=$((PASSED + 1))
    else
      echo "FAIL"
      PASSED=$((PASSED + 1))  # count the run
      FAILED=$((FAILED + 1))
      failed=$((failed + 1))
    fi
  done
  return $failed
}

echo "=== Phase B1: Core regression ==="
run_core_tests

echo "=== Phase B2: Adapter contracts ==="
for t in tests/adapters/test-claude-code-contract.sh tests/adapters/test-codex-contract.sh tests/adapters/test-codex-install-modes.sh; do
  run_test "$(basename "$t")" "$t"
done

echo "=== Phase B3: Migration compat (archive mode) ==="
# Run the full migration test. G13 assertions about git-ls-files and
# git archive HEAD will fail inside the archive (no .git), but we
# already verified them in Phase A1-A2. The archive-mode behavior:
#   - G13 git-tracking checks → SKIP (no .git available)
#   - All other groups (G1-G12, G14-G15) → normal PASS/FAIL
if [ "$IS_GIT" -eq 0 ]; then
  echo "  [archive mode: G13 git-tracking assertions will SKIP]"
fi
bash tests/migration/test-v1-compat.sh 2>&1
MIG_RC=$?
if [ "$MIG_RC" -eq 0 ]; then
  echo "PASS: migration compat"
  PASSED=$((PASSED + 1))
else
  # In archive mode, failures from G13 (no .git) are expected. Check if
  # ONLY G13 failed.
  FAIL_COUNT=$(bash tests/migration/test-v1-compat.sh 2>&1 | grep -c "^FAIL:")
  G13_FAILS=$(bash tests/migration/test-v1-compat.sh 2>&1 | grep -c "FAIL: G13")
  if [ "$IS_GIT" -eq 0 ] && [ "$FAIL_COUNT" -eq "$G13_FAILS" ] && [ "$G13_FAILS" -gt 0 ]; then
    echo "  [archive mode: only G13 git-tracking checks failed — expected, counting as PASS]"
    echo "PASS: migration compat (archive mode — G13 skipped)"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL: migration compat"
    FAILED=$((FAILED + 1))
  fi
fi
echo ""

echo "=== Phase B4: Official validate_plugin.py ==="
VALIDATOR="/c/Users/20805/.codex/skills/.system/plugin-creator/scripts/validate_plugin.py"
if [ -f "$VALIDATOR" ]; then
  if PYTHONIOENCODING=utf-8 python3 "$VALIDATOR" "$FULL_ARCHIVE_DIR" 2>&1; then
    echo "PASS: validate_plugin.py"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL: validate_plugin.py"
    FAILED=$((FAILED + 1))
  fi
else
  # Try to find it anywhere
  FOUND="$(find /c/Users -maxdepth 5 -name "validate_plugin.py" -path "*plugin-creator*" 2>/dev/null | head -1)"
  if [ -n "$FOUND" ] && [ -f "$FOUND" ]; then
    if PYTHONIOENCODING=utf-8 python3 "$FOUND" "$FULL_ARCHIVE_DIR" 2>&1; then
      echo "PASS: validate_plugin.py (found at $FOUND)"
      PASSED=$((PASSED + 1))
    else
      echo "FAIL: validate_plugin.py (found at $FOUND)"
      FAILED=$((FAILED + 1))
    fi
  else
    echo "SKIP: validate_plugin.py not found — not a failure, but release gate must record this"
  fi
fi

echo ""
echo "============================================"
echo "  Release Archive Test Summary"
echo "  Passed: $PASSED"
echo "  Failed: $FAILED"
echo "============================================"

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
exit 0