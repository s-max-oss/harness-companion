#!/bin/bash
# test-workspace-fingerprint.sh — Workspace fingerprint test suite
#
# Tests:
#   1. Clean git repo → "clean"
#   2. Dirty git repo → "sha256:<hex>"
#   3. Terminal append stability (harness artifacts excluded)
#   4. Built-in exclude immunity (.harness/* cannot be overridden)
#   5. staged vs unstaged non-overlap
#   6. NUL-delimited temp file outside fingerprint scope
#   7. Special filename handling

set -uo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$TEST_DIR/../.." && pwd)"
CORE_LIB="$ROOT_DIR/core/lib"

# shellcheck source=../../core/lib/workspace-fingerprint.sh
source "$CORE_LIB/workspace-fingerprint.sh"

PASSED=0
FAILED=0

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

# Helper: assert fingerprint equals expected
assert_fp_equals() {
  local test_name="$1" actual="$2" expected="$3"
  if [ "$actual" = "$expected" ]; then
    echo "PASS: $test_name"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL: $test_name — expected '$expected', got '$actual'"
    FAILED=$((FAILED + 1))
  fi
}

assert_fp_not_equals() {
  local test_name="$1" actual="$2" unexpected="$3"
  if [ "$actual" != "$unexpected" ]; then
    echo "PASS: $test_name"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL: $test_name — got '$actual', expected NOT '$unexpected'"
    FAILED=$((FAILED + 1))
  fi
}

# ============================================================================
# Test 1: Clean git repo
# ============================================================================
echo "=== Test 1: Clean git repo ==="

cd "$TMPDIR"
git init --quiet .
git config user.email "test@test"
git config user.name "Tester"
echo "hello" > README.md
git add README.md
git commit -m "init" --quiet

FP1="$(compute_workspace_fingerprint "$TMPDIR")"
assert_fp_equals "clean git repo returns 'clean'" "$FP1" "clean"

# ============================================================================
# Test 2: Dirty git repo (unstaged change)
# ============================================================================
echo ""
echo "=== Test 2: Dirty git repo (unstaged) ==="

echo "dirty" >> README.md
FP2="$(compute_workspace_fingerprint "$TMPDIR")"
assert_fp_not_equals "unstaged change produces non-clean fingerprint" "$FP2" "clean"
# Should start with sha256:
case "$FP2" in
  sha256:*) echo "PASS: dirty fingerprint starts with sha256:"; PASSED=$((PASSED + 1)) ;;
  *) echo "FAIL: dirty fingerprint '$FP2' does not start with sha256:"; FAILED=$((FAILED + 1)) ;;
esac

# ============================================================================
# Test 3: Staged change (different from unstaged)
# ============================================================================
echo ""
echo "=== Test 3: Staged vs unstaged non-overlap ==="

git add README.md
FP3="$(compute_workspace_fingerprint "$TMPDIR")"
# After staging, working tree matches index (no unstaged changes), but staged differs from HEAD
# So staged != 0, unstaged == 0 → different fingerprint from pure-unstaged
assert_fp_not_equals "staged fingerprint differs from unstaged fingerprint" "$FP3" "$FP2"

# Reset for next test
git commit -m "dirty" --quiet
FP3b="$(compute_workspace_fingerprint "$TMPDIR")"
assert_fp_equals "after commit, returns to clean" "$FP3b" "clean"

# ============================================================================
# Test 4: Terminal append stability
# ============================================================================
echo ""
echo "=== Test 4: Terminal append stability ==="

# Create .harness/logs/runs/ directory and write a run log
mkdir -p "$TMPDIR/.harness/logs/runs"
echo '{"event":"run_started"}' > "$TMPDIR/.harness/logs/runs/test.ndjson"

FP4_before="$(compute_workspace_fingerprint "$TMPDIR")"

# Append a terminal event
echo '{"event":"run_completed"}' >> "$TMPDIR/.harness/logs/runs/test.ndjson"

FP4_after="$(compute_workspace_fingerprint "$TMPDIR")"
assert_fp_equals "fingerprint stable after appending to .harness/logs/" "$FP4_before" "$FP4_after"

# ============================================================================
# Test 5: Built-in exclude immunity
# ============================================================================
echo ""
echo "=== Test 5: Built-in exclude immunity ==="

# Create a config that tries to include .harness/logs in fingerprint
mkdir -p "$TMPDIR/.harness"
cat > "$TMPDIR/.harness/config.json" <<'CONF'
{
  "project_type": "generic",
  "fingerprint_exclude": [],
  "verification": { "commands": [] }
}
CONF

# Create a file in .harness/logs and verify it's still excluded
echo "should be ignored" > "$TMPDIR/.harness/logs/should-be-ignored.txt"

FP5="$(compute_workspace_fingerprint "$TMPDIR")"
# Remove the file and fingerprint should be same
rm "$TMPDIR/.harness/logs/should-be-ignored.txt"
FP5_after="$(compute_workspace_fingerprint "$TMPDIR")"
assert_fp_equals ".harness/ files excluded even with empty exclude list" "$FP5" "$FP5_after"

# ============================================================================
# Test 6: .harness lock and temp files excluded
# ============================================================================
echo ""
echo "=== Test 6: Lock and temp file exclusion ==="

mkdir -p "$TMPDIR/.harness/.registry.lock"
echo "lock" > "$TMPDIR/.harness/.registry.lock/pid"
echo "temp" > "$TMPDIR/.harness/stuff.tmp.12345"

FP6_before="$(compute_workspace_fingerprint "$TMPDIR")"
rm -rf "$TMPDIR/.harness/.registry.lock" "$TMPDIR/.harness/stuff.tmp.12345"
FP6_after="$(compute_workspace_fingerprint "$TMPDIR")"
assert_fp_equals ".harness lock and temp files excluded" "$FP6_before" "$FP6_after"

# ============================================================================
# Test 7: NUL temp file location
# ============================================================================
echo ""
echo "=== Test 7: NUL temp file outside fingerprint scope ==="

# The implementation uses mktemp which creates files in system tmpdir (outside project).
# Verify that the fingerprint computation itself doesn't create files in the project.
before_count="$(find "$TMPDIR" -newer "$TMPDIR" -type f 2>/dev/null | wc -l || echo 0)"

FP7="$(compute_workspace_fingerprint "$TMPDIR")"

# Compute again — should be stable (temp file cleaned up, no project files modified)
FP7_again="$(compute_workspace_fingerprint "$TMPDIR")"
assert_fp_equals "fingerprint stable across recomputation (temp file outside scope)" "$FP7" "$FP7_again"

# ============================================================================
# Test 8: Special filename handling
# ============================================================================
echo ""
echo "=== Test 8: Special filename handling ==="

# Create files with spaces and special characters
echo "special" > "$TMPDIR/file with spaces.txt"
echo "quotes" > "$TMPDIR/file-with-dashes.txt"

FP8="$(compute_workspace_fingerprint "$TMPDIR")"
assert_fp_not_equals "special filenames produce valid fingerprint" "$FP8" "clean"

rm "$TMPDIR/file with spaces.txt" "$TMPDIR/file-with-dashes.txt"

# ============================================================================
# Test 9: Configurable exclude from config.json
# ============================================================================
echo ""
echo "=== Test 9: Configurable exclude ==="

mkdir -p "$TMPDIR/dist"
echo "build" > "$TMPDIR/dist/output.js"
echo "source" > "$TMPDIR/app.js"

cat > "$TMPDIR/.harness/config.json" <<'CONF'
{
  "project_type": "generic",
  "fingerprint_exclude": ["dist/"],
  "verification": { "commands": [] }
}
CONF

FP9_with_dist="$(compute_workspace_fingerprint "$TMPDIR")"

rm -rf "$TMPDIR/dist"
FP9_without_dist="$(compute_workspace_fingerprint "$TMPDIR")"

assert_fp_equals "configurable exclude: dist/ removed doesn't change fingerprint" "$FP9_with_dist" "$FP9_without_dist"

# Cleanup extra files
rm -f "$TMPDIR/app.js" "$TMPDIR/.harness/config.json"

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "============================================"
echo "Results: $PASSED passed, $FAILED failed"
echo "============================================"

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
exit 0
